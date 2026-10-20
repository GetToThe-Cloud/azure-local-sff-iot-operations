<#
.SYNOPSIS
    Stuurt Home Assistant-statussen via een Azure IoT Operations-dataflow naar Azure Data Explorer en zet de
    hele ADX-kant op: cluster, database, tabellen, rechten, schema, endpoint en dataflow.

.DESCRIPTION
    Bouwt verder op Enable-AioHomeAssistantMqtt.ps1 (Mosquitto-bridge van Home Assistant naar de AIO MQTT broker).
      1. Registreert de resource provider Microsoft.Kusto en maakt (of hergebruikt) een ADX-cluster met
         streaming ingestion. Standaard de goedkoopste Dev/Test-SKU, zonder SLA.
      2. Maakt de database. Jij krijgt AllDatabasesAdmin op de cluster, de system-assigned managed identity
         van de AIO Arc-extensie krijgt Ingestor op de database.
      3. Maakt met KQL een ruwe landingstabel (alle kolommen string), een getypte tabel en een update policy
         die de ruwe rijen omzet (todatetime, todouble). Zo hangt niets af van typeconversie in de dataflow:
         ADX zet een Parquet-string niet zelf om naar datetime.
      4. Zet een Delta-schema in de schema registry van AIO. Een dataflow naar ADX vereist een schema.
      5. Maakt het AIO-dataflow-endpoint (DataExplorer, managed identity) en de dataflow van -SourceTopic
         naar de ruwe tabel, geserialiseerd als Parquet.
      6. Zelftest: publiceert een testbericht via de mqtt-client-pod op de AIO-broker en wacht tot het
         getypt in ADX staat. Zo test je AIO -> ADX los van Home Assistant.
      7. Schrijft een Home Assistant-automation die per statuswijziging één JSON-object publiceert.

    Waarom niet mqtt_statestream: die publiceert per attribuut een losse JSON-waarde ("21.5"), geen object.
    Een dataflow kan daar geen velden uit mappen.

    Het script is idempotent: bestaande resources worden hergebruikt, dus een tweede run gaat verder waar de
    eerste stopte. Vereist az CLI (ingelogd) met de azure-iot-ops extensie en, voor de zelftest, kubectl met de
    kubeconfig van de SFF-cluster. Werkt in Windows PowerShell 5.1 en PowerShell 7.
    Exit code 1 bij een fout, anders 0.

.PARAMETER ResourceGroup
    Resource group van de Azure IoT Operations-instance.

.PARAMETER Instance
    Naam van de Azure IoT Operations-instance ('az iot ops list -o table').

.PARAMETER SubscriptionId
    Subscription. Standaard die van 'az account show'.

.PARAMETER AdxResourceGroup
    Resource group voor de ADX-cluster. Standaard -ResourceGroup. Wordt aangemaakt als hij niet bestaat.

.PARAMETER Location
    Azure-regio voor de cluster. Standaard de regio van -AdxResourceGroup (of van -ResourceGroup als die
    nog niet bestaat).

.PARAMETER ClusterName
    Naam van de ADX-cluster: 4-22 tekens, kleine letters en cijfers, begint met een letter. Wordt deel van de
    URL <naam>.<regio>.kusto.windows.net en moet dus wereldwijd uniek zijn. Standaard 'adxsff' plus een
    vaste hash van subscription en resource group, zodat een tweede run dezelfde naam kiest.

.PARAMETER Sku
    Cluster-SKU. Standaard 'Dev(No SLA)_Standard_E2a_v4': één node, geen SLA en geen ADX-markup.

.PARAMETER Database
    Naam van de ADX-database.

.PARAMETER RawTable
    Landingstabel waar de dataflow in schrijft (alle kolommen string).

.PARAMETER Table
    Getypte tabel die de update policy vult. Hierop query je.

.PARAMETER RetentionDays
    Bewaartermijn van de database (soft delete) in dagen. De ruwe tabel bewaart 7 dagen.

.PARAMETER HotCacheDays
    Aantal dagen dat data in de hot cache (SSD) staat.

.PARAMETER SourceTopic
    MQTT-topicfilter dat de dataflow leest. Moet onder het topic vallen dat de Mosquitto-bridge naar AIO
    doorstuurt (standaard homeassistant/statestream/#).

.PARAMETER EndpointName
    Naam van het dataflow-endpoint voor ADX.

.PARAMETER DataflowName
    Naam van de dataflow.

.PARAMETER DataflowProfile
    Dataflow-profiel. Standaard 'default'.

.PARAMETER SchemaName
    Naam van het Delta-schema in de schema registry.

.PARAMETER SchemaVersion
    Versie van het schema. Versies zijn onveranderlijk: verander je de kolommen, verhoog dan dit nummer.

.PARAMETER LatencySeconds
    Maximale batchingtijd van het dataflow-endpoint in seconden.

.PARAMETER OutputPath
    Map voor de gegenereerde configuratie: endpoint- en dataflow-JSON, schema, KQL en de Home Assistant-automation.

.PARAMETER SkipSelfTest
    Sla de zelftest over.

.PARAMETER SelfTestMinutes
    Hoe lang de zelftest wacht tot het testbericht in ADX staat.

.EXAMPLE
    .\Enable-AioHomeAssistantAdx.ps1 -ResourceGroup 'rg-sff-lab' -Instance 'aio-sff'

.EXAMPLE
    .\Enable-AioHomeAssistantAdx.ps1 -ResourceGroup 'rg-sff-lab' -Instance 'aio-sff' -AdxResourceGroup 'rg-sff-adx' -ClusterName 'adxgettothecloud'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Instance,
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$SubscriptionId,
    [string]$AdxResourceGroup,
    [string]$Location,
    [ValidatePattern('^$|^[a-z][a-z0-9]{3,21}$')][string]$ClusterName,
    [string]$Sku = 'Dev(No SLA)_Standard_E2a_v4',
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$Database = 'homeassistant',
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$RawTable = 'HomeAssistantRaw',
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$Table = 'HomeAssistantStates',
    [ValidateRange(1, 36500)][int]$RetentionDays = 365,
    [ValidateRange(0, 36500)][int]$HotCacheDays = 31,
    [ValidatePattern('^[^\s]+$')][string]$SourceTopic = 'homeassistant/statestream/json/#',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$EndpointName = 'adx-homeassistant',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$DataflowName = 'ha-to-adx',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$DataflowProfile = 'default',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$SchemaName = 'ha-state-delta',
    [ValidatePattern('^[0-9]+$')][string]$SchemaVersion = '1',
    [ValidateRange(1, 3600)][int]$LatencySeconds = 60,
    [string]$OutputPath = (Join-Path (Get-Location) 'ha-adx-config'),
    [switch]$SkipSelfTest,
    [ValidateRange(1, 60)][int]$SelfTestMinutes = 10
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$ns            = 'azure-iot-operations'
$armBase       = 'https://management.azure.com'
$graphBase     = 'https://graph.microsoft.com/v1.0'
$kustoApi      = '2025-02-14'
$aioExtType    = 'microsoft.iotoperations'
$mqttClientUrl = 'https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/mqtt-client.yaml'
$fnName        = "$($Table)_FromRaw"
# Velden die Home Assistant per statuswijziging publiceert. Dezelfde namen in het schema, de mapping en de ruwe tabel.
$rawColumns    = @('entity_id', 'domain', 'friendly_name', 'state', 'unit', 'device_class', 'last_changed', 'last_updated')

#region Helpers
function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    [OK]   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    [WARN] $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "           $Text" -ForegroundColor Gray }

function Resolve-Tool {
    param([string]$Name, [string]$Hint)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw "$Name niet gevonden. $Hint"
}

function Invoke-Native {
    # Draait een native command; stdout als string terug, stderr apart (PS 5.1 maakt anders fouten van stderr-regels).
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [switch]$AllowFailure)
    $ErrorActionPreference = 'Continue'
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out  = & $FilePath @Arguments 2> $errFile
        $code = $LASTEXITCODE
        $err  = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
    $result = [pscustomobject]@{ ExitCode = $code; Output = (@($out) -join "`n"); Error = "$err".Trim() }
    if ($code -ne 0 -and -not $AllowFailure) {
        $name = Split-Path $FilePath -Leaf
        throw "$name $($Arguments -join ' ') faalde (exit $code):`n$($result.Error)`n$($result.Output)"
    }
    return $result
}

function Invoke-Az {
    # az met de gekozen subscription; JSON-uitvoer wordt een object
    param([string[]]$Arguments, [switch]$AllowFailure, [switch]$Raw)
    $r = Invoke-Native $script:az ($Arguments + @('--subscription', $script:SubscriptionId)) -AllowFailure:$AllowFailure
    if ($Raw -or $r.ExitCode -ne 0) { return $r }
    if (-not $r.Output.Trim()) { return $null }
    return ($r.Output | ConvertFrom-Json)
}

function Write-TextFile {
    # UTF-8 zonder BOM, LF-regeleinden: az, kubectl en Home Assistant lezen dat overal goed
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

$script:TokenCache = @{}
function Get-AzToken {
    param([string]$Resource)
    $c = $script:TokenCache[$Resource]
    if ($c -and $c.Expires -gt (Get-Date).AddMinutes(5)) { return $c.Token }
    $r = Invoke-Native $script:az @('account', 'get-access-token', '--subscription', $script:SubscriptionId,
        '--resource', $Resource, '-o', 'json') -AllowFailure
    if ($r.ExitCode -ne 0) { throw "Geen token voor $Resource. Log in met 'az login' en probeer opnieuw. $($r.Error)" }
    $t   = $r.Output | ConvertFrom-Json
    $exp = (Get-Date).AddMinutes(30)
    if ($t.expires_on) {
        try { $exp = [DateTimeOffset]::FromUnixTimeSeconds([long]$t.expires_on).LocalDateTime } catch { }
    } elseif ($t.expiresOn) {
        try { $exp = [datetime]$t.expiresOn } catch { }
    }
    $script:TokenCache[$Resource] = @{ Token = $t.accessToken; Expires = $exp }
    return $t.accessToken
}

function Get-HttpErrorText {
    param($ErrorRecord)
    $msg = $ErrorRecord.ErrorDetails.Message
    if ($msg) {
        try {
            $j = $msg | ConvertFrom-Json
            if ($j.error.message)    { return $j.error.message }
            if ($j.error.'@message') { return $j.error.'@message' }
        } catch { }
        return $msg
    }
    return $ErrorRecord.Exception.Message
}

function Invoke-Http {
    # REST-call met bearer token. Fouten krijgen de HTTP-status mee in Exception.Data['StatusCode'].
    param([string]$Method = 'Get', [string]$Uri, [string]$Token, $Body, [switch]$AllowNotFound)
    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $params.Body        = [Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $code = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
        if ($AllowNotFound -and $code -eq 404) { return $null }
        $ex = New-Object System.Exception ('{0} {1} gaf HTTP {2}: {3}' -f $Method.ToUpper(), ($Uri -split '\?')[0], $code, (Get-HttpErrorText $_))
        $ex.Data['StatusCode'] = $code
        throw $ex
    }
}

function Invoke-Arm {
    param([string]$Method = 'Get', [string]$Path, $Body, [string]$ApiVersion, [switch]$AllowNotFound)
    $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    Invoke-Http -Method $Method -Uri "$armBase$Path$($sep)api-version=$ApiVersion" -Body $Body `
        -Token (Get-AzToken 'https://management.azure.com/') -AllowNotFound:$AllowNotFound
}

function Get-KustoToken {
    if ($script:KustoResource) { return Get-AzToken $script:KustoResource }
    $last = $null
    foreach ($res in @($script:KustoUri, 'https://api.kusto.windows.net')) {
        try {
            $t = Get-AzToken $res
            $script:KustoResource = $res
            return $t
        } catch { $last = $_ }
    }
    throw $last
}

function Invoke-Kusto {
    # Management-command (.create ...) of query tegen de database. Wacht bij 401/403 op het doorvoeren van rechten.
    param([string]$Csl, [ValidateSet('mgmt', 'query')][string]$Kind = 'mgmt', [int]$RetryAuthSeconds = 0)
    $deadline = (Get-Date).AddSeconds($RetryAuthSeconds)
    while ($true) {
        try {
            $r = Invoke-Http -Method Post -Uri "$($script:KustoUri)/v1/rest/$Kind" -Token (Get-KustoToken) `
                -Body ([ordered]@{ db = $Database; csl = $Csl })
            $t = @($r.Tables)[0]
            if (-not $t) { return }
            $cols = @($t.Columns | ForEach-Object { $_.ColumnName })
            foreach ($row in @($t.Rows)) {
                $o = [ordered]@{}
                for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = @($row)[$i] }
                [pscustomobject]$o
            }
            return
        } catch {
            $code = $_.Exception.Data['StatusCode']
            if (($code -in @(401, 403)) -and ((Get-Date) -lt $deadline)) {
                Write-Info "Nog geen toegang tot de database (HTTP $code); rechten worden doorgevoerd. Opnieuw over 20 s."
                Start-Sleep -Seconds 20
                continue
            }
            throw
        }
    }
}

function Wait-ArmState {
    # Wacht tot een ARM-resource klaar is. Bij een cluster ook tot hij draait.
    param([string]$Path, [string]$ApiVersion, [int]$Minutes, [switch]$Cluster)
    $deadline = (Get-Date).AddMinutes($Minutes)
    $last = ''
    while ($true) {
        $r  = Invoke-Arm -Path $Path -ApiVersion $ApiVersion
        $ps = $r.properties.provisioningState
        $st = $r.properties.state
        if ($ps -eq 'Failed') { throw "Provisioning van $($r.name) is mislukt. Kijk in de portal bij Activity log." }
        if ($ps -eq 'Succeeded' -and (-not $Cluster -or $st -eq 'Running')) { return $r }
        $now = if ($Cluster) { "$ps / $st" } else { "$ps" }
        if ($now -ne $last) {
            Write-Info ('{0:HH:mm:ss}  {1}: {2}' -f (Get-Date), $r.name, $now)
            $last = $now
        }
        if ((Get-Date) -gt $deadline) {
            throw "$($r.name) is na $Minutes minuten nog niet klaar ($now). Draai het script later opnieuw; het gaat verder waar het was."
        }
        Start-Sleep -Seconds 20
    }
}

function Set-KustoPrincipal {
    # Idempotente rol-toewijzing op cluster- of databaseniveau via ARM.
    param([string]$ScopePath, [string]$Name, [string[]]$Candidates, [string[]]$KnownIds,
          [ValidateSet('User', 'App', 'Group')][string]$Type, [string]$Role, [string]$Label)
    $existing = @((Invoke-Arm -Path "$ScopePath/principalAssignments" -ApiVersion $kustoApi).value)
    foreach ($a in $existing) {
        if ($a.properties.role -ne $Role) { continue }
        foreach ($id in @($KnownIds + $Candidates)) {
            if ($id -and $a.properties.principalId -and $a.properties.principalId -ieq $id) {
                Write-Ok "$Label heeft al $Role"
                return
            }
        }
    }
    $lastError = $null
    foreach ($candidate in $Candidates) {
        if (-not $candidate) { continue }
        $body = @{ properties = [ordered]@{ principalId = $candidate; principalType = $Type; role = $Role; tenantId = $script:TenantId } }
        try {
            Invoke-Arm -Method Put -Path "$ScopePath/principalAssignments/$Name" -ApiVersion $kustoApi -Body $body | Out-Null
            Wait-ArmState -Path "$ScopePath/principalAssignments/$Name" -ApiVersion $kustoApi -Minutes 5 | Out-Null
            Write-Ok "$Label krijgt $Role"
            return
        } catch {
            $lastError = $_
            $code = $_.Exception.Data['StatusCode']
            if ($code -lt 400 -or $code -ge 500) { throw }
        }
    }
    throw "Kon $Role niet toekennen aan ${Label}: $($lastError.Exception.Message)"
}
#endregion

try {
    #region 0. Context
    Write-Host "`nAzure IoT Operations - Home Assistant-data naar Azure Data Explorer" -ForegroundColor White

    Write-Step 'Tools en context controleren'
    $script:az = Resolve-Tool 'az' -Hint 'Installeer de Azure CLI.'
    $ext = Invoke-Native $az @('extension', 'show', '--name', 'azure-iot-ops', '--query', 'version', '-o', 'tsv') -AllowFailure
    if ($ext.ExitCode -ne 0) { throw "De az-extensie 'azure-iot-ops' ontbreekt. Draai: az extension add --upgrade --name azure-iot-ops" }
    Write-Ok "azure-iot-ops extensie $($ext.Output.Trim())"

    $acctArgs = @('account', 'show', '-o', 'json')
    if ($SubscriptionId) { $acctArgs += @('--subscription', $SubscriptionId) }
    $acct = Invoke-Native $az $acctArgs -AllowFailure
    if ($acct.ExitCode -ne 0) { throw "Geen az-context. Draai 'az login' (eventueel met --tenant <tenant-id>)." }
    $acct = $acct.Output | ConvertFrom-Json
    $script:SubscriptionId = $acct.id
    $script:TenantId       = $acct.tenantId
    $sid                   = $acct.id
    Write-Ok "Subscription $($acct.name) ($sid)"

    $graphToken = Get-AzToken 'https://graph.microsoft.com'
    if ($acct.user.type -eq 'servicePrincipal') {
        $me = Invoke-Http -Uri "$graphBase/servicePrincipals(appId='$($acct.user.name)')?`$select=id,appId,displayName" -Token $graphToken
        $meType       = 'App'
        $meCandidates = @($me.appId)
        $meKnown      = @($me.id, $me.appId)
        $meLabel      = $me.displayName
    } else {
        $me = Invoke-Http -Uri "$graphBase/me?`$select=id,userPrincipalName" -Token $graphToken
        $meType       = 'User'
        $meCandidates = @($me.userPrincipalName, $me.id)
        $meKnown      = @($me.id, $me.userPrincipalName)
        $meLabel      = $me.userPrincipalName
    }
    Write-Ok "Ingelogd als $meLabel"

    $inst = Invoke-Az @('iot', 'ops', 'show', '--resource-group', $ResourceGroup, '--name', $Instance, '-o', 'json')
    $customLocationId = $inst.extendedLocation.name
    $registryId       = $inst.properties.schemaRegistryRef.resourceId
    if (-not $customLocationId) { throw "Kon de custom location van $Instance niet bepalen." }
    if (-not $registryId)       { throw "$Instance heeft geen schema registry. Die is nodig voor een dataflow naar ADX." }
    Write-Ok "IoT Operations-instance $Instance gevonden"

    # Managed identity van de AIO Arc-extensie: instance -> custom location -> Arc-cluster -> extensie
    $cl     = Invoke-Arm -Path $customLocationId -ApiVersion '2021-08-15'
    $hostId = $cl.properties.hostResourceId
    $exts   = @((Invoke-Arm -Path "$hostId/providers/Microsoft.KubernetesConfiguration/extensions" -ApiVersion '2023-05-01').value)
    $aioExt = @($exts | Where-Object { $_.properties.extensionType -ieq $aioExtType }) | Select-Object -First 1
    if (-not $aioExt) { throw "Geen extensie van type $aioExtType gevonden op $hostId." }
    if (-not $aioExt.identity.principalId) { throw "Extensie $($aioExt.name) heeft geen system-assigned identity." }
    $mi = Invoke-Http -Uri "$graphBase/servicePrincipals/$($aioExt.identity.principalId)?`$select=id,appId,displayName" -Token $graphToken
    Write-Ok "Managed identity van de AIO-extensie: $($mi.displayName) (appId $($mi.appId))"
    #endregion

    #region 1. ADX-cluster
    Write-Step 'Azure Data Explorer-cluster'
    if (-not $AdxResourceGroup) { $AdxResourceGroup = $ResourceGroup }
    $rgPath = "/subscriptions/$sid/resourcegroups/$AdxResourceGroup"
    $rg     = Invoke-Arm -Path $rgPath -ApiVersion '2021-04-01' -AllowNotFound
    if (-not $rg) {
        if (-not $Location) {
            $Location = (Invoke-Arm -Path "/subscriptions/$sid/resourcegroups/$ResourceGroup" -ApiVersion '2021-04-01').location
        }
        $rg = Invoke-Arm -Method Put -Path $rgPath -ApiVersion '2021-04-01' -Body @{ location = $Location }
        Write-Ok "Resource group $AdxResourceGroup aangemaakt in $Location"
    }
    if (-not $Location) { $Location = $rg.location }
    $Location = $Location.ToLower() -replace '\s', ''

    $prov = Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Kusto" -ApiVersion '2021-04-01'
    if ($prov.registrationState -ne 'Registered') {
        Write-Info 'Resource provider Microsoft.Kusto registreren (eenmalig, duurt een paar minuten)'
        Invoke-Arm -Method Post -Path "/subscriptions/$sid/providers/Microsoft.Kusto/register" -ApiVersion '2021-04-01' | Out-Null
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 15
            $prov = Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Kusto" -ApiVersion '2021-04-01'
        } while ($prov.registrationState -ne 'Registered' -and (Get-Date) -lt $deadline)
        if ($prov.registrationState -ne 'Registered') { throw "Microsoft.Kusto is na 10 minuten nog niet geregistreerd ($($prov.registrationState))." }
    }
    Write-Ok 'Resource provider Microsoft.Kusto geregistreerd'

    if (-not $ClusterName) {
        # Vaste naam per subscription + resource group, zodat een tweede run dezelfde cluster vindt
        $sha  = [Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$sid/$AdxResourceGroup".ToLower()))
        $ClusterName = 'adxsff' + ((@($hash[0..3]) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    $clusterPath = "$rgPath/providers/Microsoft.Kusto/clusters/$ClusterName"
    $cluster     = Invoke-Arm -Path $clusterPath -ApiVersion $kustoApi -AllowNotFound

    if (-not $cluster) {
        # SKU beschikbaar in deze regio? Fout in de check zelf is geen blokkade.
        try {
            $skus  = @((Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Kusto/skus" -ApiVersion $kustoApi).value)
            $match = @($skus | Where-Object {
                $_.name -eq $Sku -and @($_.locations | ForEach-Object { ($_ -replace '\s', '').ToLower() }) -contains $Location
            })
            if ($skus.Count -and -not $match.Count) {
                $dev = @($skus | Where-Object { $_.name -like 'Dev*' -and @($_.locations | ForEach-Object { ($_ -replace '\s', '').ToLower() }) -contains $Location } |
                         ForEach-Object { $_.name } | Sort-Object -Unique)
                throw "SKU '$Sku' is niet beschikbaar in $Location. Dev-SKU's daar: $($dev -join ', ')"
            }
            $blocked = @($match | ForEach-Object { $_.restrictions } | Where-Object { $_ })
            if ($blocked.Count) { throw "SKU '$Sku' is in $Location beperkt voor deze subscription: $(@($blocked | ForEach-Object { $_.reasonCode }) -join ', ')" }
        } catch {
            if ($_.Exception.Message -like 'SKU *') { throw }
            Write-Warn "Kon de SKU-beschikbaarheid niet controleren: $($_.Exception.Message)"
        }

        $avail = Invoke-Arm -Method Post -Path "/subscriptions/$sid/providers/Microsoft.Kusto/locations/$Location/checkNameAvailability" `
            -ApiVersion $kustoApi -Body @{ name = $ClusterName; type = 'Microsoft.Kusto/clusters' }
        if (-not $avail.nameAvailable) {
            throw "Clusternaam '$ClusterName' is niet beschikbaar ($($avail.message)). Kies een andere met -ClusterName."
        }

        $tier     = if ($Sku -like 'Dev(No SLA)*') { 'Basic' } else { 'Standard' }
        $capacity = if ($tier -eq 'Basic') { 1 } else { 2 }
        $body = [ordered]@{
            location   = $Location
            sku        = [ordered]@{ name = $Sku; tier = $tier; capacity = $capacity }
            properties = [ordered]@{ enableStreamingIngest = $true; publicNetworkAccess = 'Enabled' }
        }
        Invoke-Arm -Method Put -Path $clusterPath -ApiVersion $kustoApi -Body $body | Out-Null
        Write-Ok "Cluster $ClusterName ($Sku) wordt aangemaakt in $Location. Dit duurt meestal 10 tot 20 minuten."
        $cluster = Wait-ArmState -Path $clusterPath -ApiVersion $kustoApi -Minutes 45 -Cluster
    } else {
        Write-Ok "Bestaande cluster $ClusterName hergebruikt"
        if ($cluster.properties.provisioningState -ne 'Succeeded') {
            $cluster = Wait-ArmState -Path $clusterPath -ApiVersion $kustoApi -Minutes 45
        }
        $deadline = (Get-Date).AddMinutes(15)
        while ($cluster.properties.state -eq 'Stopping' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 20
            $cluster = Invoke-Arm -Path $clusterPath -ApiVersion $kustoApi
        }
        if ($cluster.properties.state -eq 'Stopped') {
            Write-Info 'Cluster is gestopt; starten (duurt een paar minuten)'
            Invoke-Arm -Method Post -Path "$clusterPath/start" -ApiVersion $kustoApi | Out-Null
            Start-Sleep -Seconds 20
        }
        if ($cluster.properties.state -ne 'Running') {
            $cluster = Wait-ArmState -Path $clusterPath -ApiVersion $kustoApi -Minutes 30 -Cluster
        }
        if (-not $cluster.properties.enableStreamingIngest) {
            Write-Info 'Streaming ingestion aanzetten op de cluster (duurt een paar minuten)'
            Invoke-Arm -Method Patch -Path $clusterPath -ApiVersion $kustoApi -Body @{ properties = @{ enableStreamingIngest = $true } } | Out-Null
            Start-Sleep -Seconds 20
            $cluster = Wait-ArmState -Path $clusterPath -ApiVersion $kustoApi -Minutes 45 -Cluster
        }
    }
    $script:KustoUri = $cluster.properties.uri.TrimEnd('/')
    Write-Ok "Cluster draait: $($script:KustoUri)"

    Set-KustoPrincipal -ScopePath $clusterPath -Name "admin-$($me.id)" -Candidates $meCandidates -KnownIds $meKnown `
        -Type $meType -Role 'AllDatabasesAdmin' -Label $meLabel
    #endregion

    #region 2. Database en rechten voor AIO
    Write-Step "Database $Database"
    $dbPath = "$clusterPath/databases/$Database"
    $db     = Invoke-Arm -Path $dbPath -ApiVersion $kustoApi -AllowNotFound
    if (-not $db) {
        $body = [ordered]@{
            location   = $Location
            kind       = 'ReadWrite'
            properties = [ordered]@{ softDeletePeriod = "P$($RetentionDays)D"; hotCachePeriod = "P$($HotCacheDays)D" }
        }
        Invoke-Arm -Method Put -Path $dbPath -ApiVersion $kustoApi -Body $body | Out-Null
        Wait-ArmState -Path $dbPath -ApiVersion $kustoApi -Minutes 10 | Out-Null
        Write-Ok "Database aangemaakt (bewaren $RetentionDays dagen, hot cache $HotCacheDays dagen)"
    } else {
        Write-Ok 'Bestaande database hergebruikt'
    }

    Set-KustoPrincipal -ScopePath $dbPath -Name "aio-$($aioExt.name)-ingestor" -Candidates @($mi.appId) -KnownIds @($mi.id, $mi.appId) `
        -Type 'App' -Role 'Ingestor' -Label "$($mi.displayName) (AIO)"
    #endregion

    #region 3. Tabellen, update policy en streaming ingestion (KQL)
    Write-Step 'Tabellen en update policy'
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

    $rawSchema = ($rawColumns | ForEach-Object { "$($_): string" }) -join ', '
    $commands = [ordered]@{
        'Streaming ingestion op de database' = ".alter database ['__DB__'] policy streamingingestion enable"
        "Ruwe tabel $RawTable"               = ".create-merge table __RAW__ ($rawSchema) with (folder = 'HomeAssistant', docstring = 'Ruwe Home Assistant-statussen uit de AIO-dataflow, alle kolommen string')"
        "Getypte tabel $Table"               = ".create-merge table __TBL__ (Timestamp: datetime, EntityId: string, Domain: string, FriendlyName: string, State: string, Value: real, Unit: string, DeviceClass: string, LastUpdated: datetime, IngestedAt: datetime) with (folder = 'HomeAssistant', docstring = 'Getypte Home Assistant-statussen')"
        "Functie $fnName"                    = @'
.create-or-alter function with (folder = 'HomeAssistant', docstring = 'Zet __RAW__ om naar __TBL__') __FN__() {
    __RAW__
    | project
        Timestamp    = todatetime(last_changed),
        EntityId     = entity_id,
        Domain       = domain,
        FriendlyName = friendly_name,
        State        = state,
        Value        = todouble(state),
        Unit         = unit,
        DeviceClass  = device_class,
        LastUpdated  = todatetime(last_updated),
        IngestedAt   = now()
}
'@
        "Update policy op $Table"            = @'
.alter table __TBL__ policy update @'[{"IsEnabled": true, "Source": "__RAW__", "Query": "__FN__()", "IsTransactional": true, "PropagateIngestionProperties": false}]'
'@
        "Bewaartermijn $RawTable (7 dagen)"  = '.alter-merge table __RAW__ policy retention softdelete = 7d recoverability = disabled'
        # Valt de ingestion terug op queued ingestion, dan staat data hiermee binnen ~30 s in plaats van 5 min
        "Batching $RawTable (30 s)"          = ".alter table __RAW__ policy ingestionbatching '{""MaximumBatchingTimeSpan"": ""00:00:30"", ""MaximumNumberOfItems"": 500, ""MaximumRawDataSizeMB"": 1024}'"
    }
    $kqlFile = Join-Path $OutputPath 'adx-setup.kql'
    $kqlText = New-Object System.Text.StringBuilder
    [void]$kqlText.AppendLine("// Gegenereerd door Enable-AioHomeAssistantAdx.ps1 op $(Get-Date -Format 'yyyy-MM-dd HH:mm'), database $Database")
    $first = $true
    foreach ($k in $commands.Keys) {
        $csl = $commands[$k].Replace('__DB__', $Database).Replace('__RAW__', $RawTable).Replace('__TBL__', $Table).Replace('__FN__', $fnName).Trim()
        [void]$kqlText.AppendLine("`n// $k`n$csl")
        $retry = if ($first) { 300 } else { 60 }
        Invoke-Kusto -Csl $csl -RetryAuthSeconds $retry | Out-Null
        Write-Ok $k
        $first = $false
    }
    Write-TextFile $kqlFile $kqlText.ToString()
    Write-Info "KQL opgeslagen in $kqlFile"
    #endregion

    #region 4. Delta-schema in de schema registry
    Write-Step "Schema $SchemaName (versie $SchemaVersion)"
    if ($registryId -notmatch '/resourceGroups/([^/]+)/providers/Microsoft\.DeviceRegistry/schemaRegistries/([^/]+)$') {
        throw "Onverwacht schema registry-ID: $registryId"
    }
    $regRg   = $Matches[1]
    $regName = $Matches[2]
    $schema = [ordered]@{
        '$schema'  = 'Delta/1.0'
        type       = 'object'
        properties = [ordered]@{
            type   = 'struct'
            fields = @($rawColumns | ForEach-Object { [ordered]@{ name = $_; type = 'string'; nullable = $true; metadata = @{} } })
        }
    }
    $schemaFile = Join-Path $OutputPath "schema-$SchemaName-v$SchemaVersion.json"
    Write-TextFile $schemaFile ($schema | ConvertTo-Json -Depth 10)
    $wanted = ($rawColumns | ForEach-Object { "$($_):string" }) -join ','

    $regArgs = @('--registry', $regName, '--resource-group', $regRg)
    $verRes = Invoke-Az (@('iot', 'ops', 'schema', 'version', 'show', '--version', $SchemaVersion, '--schema', $SchemaName,
        '-o', 'json') + $regArgs) -AllowFailure -Raw
    if ($verRes.ExitCode -eq 0 -and $verRes.Output.Trim()) {
        $content = ($verRes.Output | ConvertFrom-Json).properties.schemaContent
        if ($content -is [string]) { $content = $content | ConvertFrom-Json }
        $have = (@($content.properties.fields) | ForEach-Object { "$($_.name):$($_.type)" }) -join ','
        if ($have -ne $wanted) {
            throw "Schemaversie $SchemaVersion van $SchemaName bestaat al met andere velden ($have). Versies zijn onveranderlijk; draai opnieuw met -SchemaVersion $([int]$SchemaVersion + 1)."
        }
        Write-Ok 'Schemaversie bestaat al met dezelfde velden'
    } else {
        $schemaExists = Invoke-Az (@('iot', 'ops', 'schema', 'show', '--name', $SchemaName, '-o', 'none') + $regArgs) -AllowFailure -Raw
        try {
            if ($schemaExists.ExitCode -eq 0) {
                Invoke-Az (@('iot', 'ops', 'schema', 'version', 'add', '--schema', $SchemaName, '--version', $SchemaVersion,
                    '--content', $schemaFile, '-o', 'none') + $regArgs) -Raw | Out-Null
            } else {
                Invoke-Az (@('iot', 'ops', 'schema', 'create', '--name', $SchemaName, '--format', 'delta', '--type', 'message',
                    '--version-content', $schemaFile, '--version', $SchemaVersion, '--desc', 'Home Assistant-statussen voor ADX',
                    '-o', 'none') + $regArgs) -Raw | Out-Null
            }
        } catch {
            throw "$($_.Exception.Message)`nTip: het storage account van de schema registry moet public network access hebben om een schema toe te voegen."
        }
        Write-Ok "Schema toegevoegd aan registry $regName"
    }

    # Referentie voor de dataflow: aio-sr://<namespace>/<schema>:<versie>
    $schemaRef = $null
    $refs = Invoke-Az (@('iot', 'ops', 'schema', 'show-dataflow-refs', '--schema', $SchemaName, '--version', $SchemaVersion,
        '-o', 'json', '--only-show-errors') + $regArgs) -AllowFailure -Raw
    if ($refs.ExitCode -eq 0 -and $refs.Output -match ('aio-sr://[^"\s]+/' + [regex]::Escape($SchemaName) + ':' + [regex]::Escape($SchemaVersion) + '(?!\d)')) {
        $schemaRef = $Matches[0]
    }
    if (-not $schemaRef) {
        $reg = Invoke-Az (@('iot', 'ops', 'schema', 'registry', 'show', '--name', $regName, '--resource-group', $regRg, '-o', 'json'))
        $schemaRef = "aio-sr://$($reg.properties.namespace)/$($SchemaName):$SchemaVersion"
    }
    Write-Ok "Schema-referentie: $schemaRef"
    #endregion

    #region 5. Dataflow-endpoint en dataflow
    Write-Step "Dataflow-endpoint $EndpointName"
    $endpoint = [ordered]@{
        endpointType         = 'DataExplorer'
        dataExplorerSettings = [ordered]@{
            authentication = [ordered]@{ method = 'SystemAssignedManagedIdentity'; systemAssignedManagedIdentitySettings = @{} }
            batching       = [ordered]@{ latencySeconds = $LatencySeconds; maxMessages = 100000 }
            host           = $script:KustoUri
            database       = $Database
        }
    }
    $endpointFile = Join-Path $OutputPath "endpoint-$EndpointName.json"
    Write-TextFile $endpointFile ($endpoint | ConvertTo-Json -Depth 10)
    Invoke-Az @('iot', 'ops', 'dataflow', 'endpoint', 'apply', '--resource-group', $ResourceGroup, '--instance', $Instance,
        '--name', $EndpointName, '--config-file', $endpointFile, '-o', 'none') -Raw | Out-Null
    Write-Ok "Endpoint toegepast ($($script:KustoUri), database $Database)"

    Write-Step "Dataflow $DataflowName"
    $dataflow = [ordered]@{
        mode       = 'Enabled'
        operations = @(
            [ordered]@{
                operationType  = 'Source'
                sourceSettings = [ordered]@{ endpointRef = 'default'; serializationFormat = 'Json'; dataSources = @($SourceTopic) }
            },
            [ordered]@{
                operationType                 = 'BuiltInTransformation'
                builtInTransformationSettings = [ordered]@{
                    # ADX neemt Parquet aan; het Delta-schema beschrijft de kolommen. Elk veld expliciet, geen wildcard:
                    # een extra veld in het bericht laat dan niet de hele batch vallen.
                    serializationFormat = 'Parquet'
                    schemaRef           = $schemaRef
                    map                 = @($rawColumns | ForEach-Object { [ordered]@{ inputs = @($_); output = $_ } })
                }
            },
            [ordered]@{
                operationType       = 'Destination'
                destinationSettings = [ordered]@{ endpointRef = $EndpointName; dataDestination = $RawTable }
            }
        )
    }
    $dataflowFile = Join-Path $OutputPath "dataflow-$DataflowName.json"
    Write-TextFile $dataflowFile ($dataflow | ConvertTo-Json -Depth 10)
    Invoke-Az @('iot', 'ops', 'dataflow', 'apply', '--resource-group', $ResourceGroup, '--instance', $Instance,
        '--profile', $DataflowProfile, '--name', $DataflowName, '--config-file', $dataflowFile, '-o', 'none') -Raw | Out-Null
    Write-Ok "Dataflow toegepast: $SourceTopic -> $RawTable"

    $deadline = (Get-Date).AddMinutes(5)
    $dfState  = $null
    do {
        $df = Invoke-Az @('iot', 'ops', 'dataflow', 'show', '--resource-group', $ResourceGroup, '--instance', $Instance,
            '--profile', $DataflowProfile, '--name', $DataflowName, '-o', 'json')
        $dfState = $df.properties.provisioningState
        if ($dfState -in @('Succeeded', 'Failed')) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($dfState -eq 'Failed') { throw "Dataflow $DataflowName staat op Failed. Bekijk hem in de operations experience of met 'az iot ops dataflow show'." }
    if ($dfState -eq 'Succeeded') { Write-Ok 'Dataflow is uitgerold op de cluster' }
    else { Write-Warn "Dataflow staat na 5 minuten op '$dfState'. Dat kan even duren; de zelftest laat zien of hij werkt." }
    #endregion

    #region 6. Zelftest
    $testOk = $null
    if ($SkipSelfTest) {
        Write-Warn 'Zelftest overgeslagen (-SkipSelfTest)'
    } else {
        Write-Step 'Zelftest: testbericht via de AIO-broker naar ADX'
        $kubectlCmd = Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $nsCheck    = if ($kubectlCmd) { Invoke-Native $kubectlCmd.Source @('get', 'namespace', $ns, '-o', 'name') -AllowFailure }
        if (-not $kubectlCmd -or $nsCheck.ExitCode -ne 0) {
            Write-Warn 'kubectl ontbreekt of bereikt de cluster niet (staat KUBECONFIG goed?). Zelftest overgeslagen.'
        } else {
            $kubectl    = $kubectlCmd.Source
            $createdPod = $false
            try {
                $pod = Invoke-Native $kubectl @('get', 'pod', 'mqtt-client', '-n', $ns, '-o', 'name') -AllowFailure
                if ($pod.ExitCode -ne 0) {
                    Invoke-Native $kubectl @('apply', '-f', $mqttClientUrl) | Out-Null
                    $createdPod = $true
                    Write-Ok 'Tijdelijke mqtt-client-pod uitgerold (sample uit de Microsoft-docs)'
                }
                Invoke-Native $kubectl @('wait', '--for=condition=Ready', 'pod/mqtt-client', '-n', $ns, '--timeout=180s') | Out-Null

                # Topic onder -SourceTopic, voor een nep-entiteit die je in ADX makkelijk herkent
                $testEntity = 'sensor.aio_selftest'
                $base       = $SourceTopic -replace '/?#$', '' -replace '\+', 'selftest'
                $testTopic  = if ($SourceTopic -match '#$') { "$base/$testEntity" } else { $base }
                $marker     = [string](Get-Random -Minimum 100000 -Maximum 999999)
                $now        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffff+00:00')
                $payload    = [ordered]@{
                    entity_id = $testEntity; domain = 'sensor'; friendly_name = 'AIO zelftest'; state = $marker
                    unit = 'test'; device_class = ''; last_changed = $now; last_updated = $now
                } | ConvertTo-Json -Compress
                # Base64 voorkomt quotingproblemen met JSON in een native argument onder PS 5.1
                $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
                $sh  = 'echo ' + $b64 + ' | base64 -d | mosquitto_pub --host aio-broker --port 18883 --qos 1 --topic ' + $testTopic +
                       ' -s --cafile /var/run/certs/ca.crt -D CONNECT authentication-method K8S-SAT' +
                       ' -D CONNECT authentication-data $(cat /var/run/secrets/tokens/broker-sat)'
                $sent = Get-Date
                Invoke-Native $kubectl @('exec', 'mqtt-client', '-n', $ns, '--', 'sh', '-c', $sh) | Out-Null
                Write-Ok "Testbericht gepubliceerd op $testTopic (state $marker)"

                $query    = "$Table | where EntityId == '$testEntity' and State == '$marker' | project Timestamp, Value, IngestedAt | take 1"
                $deadline = (Get-Date).AddMinutes($SelfTestMinutes)
                $row      = $null
                do {
                    Start-Sleep -Seconds 20
                    try { $row = @(Invoke-Kusto -Kind query -Csl $query) | Select-Object -First 1 } catch { Write-Info "Query mislukt: $($_.Exception.Message)" }
                    if (-not $row) { Write-Info ('{0:HH:mm:ss}  nog niet in {1}' -f (Get-Date), $Table) }
                } while (-not $row -and (Get-Date) -lt $deadline)

                if ($row) {
                    $secs = [int]((Get-Date) - $sent).TotalSeconds
                    if ([double]$row.Value -eq [double]$marker) {
                        Write-Ok "Testbericht staat na ~$secs s in $Table, Value $($row.Value) (todouble werkt)"
                        $testOk = $true
                    } else {
                        Write-Warn "Testbericht staat in $Table, maar Value is '$($row.Value)' in plaats van $marker"
                        $testOk = $false
                    }
                } else {
                    $testOk = $false
                    Write-Warn "Testbericht staat na $SelfTestMinutes min nog niet in $Table."
                    try {
                        $raw = @(Invoke-Kusto -Kind query -Csl "$RawTable | where state == '$marker' | summarize n = count()") | Select-Object -First 1
                        if ($raw -and [int]$raw.n -gt 0) {
                            Write-Info "Wel in ${RawTable}: de update policy faalt. Controleer met: .show table $Table policy update"
                        } else {
                            Write-Info "Ook niet in ${RawTable}: de dataflow schrijft (nog) niet naar ADX."
                        }
                    } catch { }
                    foreach ($diag in @(
                        ".show ingestion failures | where FailedOn > ago(1h) and Database == '$Database' | top 3 by FailedOn desc",
                        '.show streamingingestion failures | take 3')) {
                        try {
                            foreach ($f in @(Invoke-Kusto -Csl $diag)) { Write-Info ('ADX: ' + ($f | ConvertTo-Json -Compress -Depth 3)) }
                        } catch { }
                    }
                    Write-Info "Net aangemaakte tabellen kunnen tot 5 minuten nodig hebben voor streaming ingestion: draai het script dan nog eens."
                    Write-Info "Dataflow-logs: kubectl get pods -n $ns  (aio-dataflow-*), daarna kubectl logs <pod> -n $ns"
                }
            } catch {
                $testOk = $false
                Write-Warn "Zelftest mislukt: $($_.Exception.Message)"
            } finally {
                if ($createdPod) {
                    Invoke-Native $kubectl @('delete', '-f', $mqttClientUrl, '--ignore-not-found', '--wait=false') -AllowFailure | Out-Null
                    Write-Info 'Tijdelijke mqtt-client-pod opgeruimd'
                }
            }
        }
    }
    #endregion

    #region 7. Home Assistant-automation en samenvatting
    $topicBase = $SourceTopic -replace '/?#$', ''
    if ($topicBase -match '\+') {
        Write-Warn "-SourceTopic bevat '+'; pas het topic in de automation zelf aan zodat het onder '$SourceTopic' valt."
    }
    $haFile = Join-Path $OutputPath 'ha-automation-aio-json.yaml'
    $haYaml = @'
# Gegenereerd door Enable-AioHomeAssistantAdx.ps1 op __DATE__.
# Instellingen > Automatiseringen en scènes > Automatisering maken > Nieuwe automatisering >
# drie puntjes > Bewerken in YAML > alles vervangen door dit bestand > Opslaan.
# Pas 'domeinen' en 'uitsluiten' aan naar wat je naar ADX wilt sturen.
alias: AIO - statussen als JSON naar MQTT
description: >-
  Publiceert elke statuswijziging als één JSON-object op __TOPIC__/<entity_id>.
  De Mosquitto-bridge zet het door naar Azure IoT Operations, een dataflow schrijft het naar Azure Data Explorer.
mode: queued
max: 500
max_exceeded: silent
variables:
  domeinen:
    - sensor
  uitsluiten: "_(uptime|rssi|signal_strength|last_boot)$"
triggers:
  - trigger: event
    event_type: state_changed
conditions:
  - condition: template
    value_template: >-
      {% set n = trigger.event.data.new_state %}
      {% set o = trigger.event.data.old_state %}
      {{ n is not none
         and n.domain in domeinen
         and (uitsluiten == '' or n.entity_id is not search(uitsluiten))
         and (o is none or o.state != n.state) }}
actions:
  - action: mqtt.publish
    data:
      topic: "__TOPIC__/{{ trigger.event.data.entity_id }}"
      qos: 1
      retain: false
      payload: >-
        {% set n = trigger.event.data.new_state %}
        {{ {
          'entity_id': n.entity_id,
          'domain': n.domain,
          'friendly_name': n.name,
          'state': n.state,
          'unit': n.attributes.get('unit_of_measurement') or '',
          'device_class': n.attributes.get('device_class') or '',
          'last_changed': n.last_changed.isoformat(),
          'last_updated': n.last_updated.isoformat()
        } | to_json }}
'@
    Write-TextFile $haFile ($haYaml.Replace('__DATE__', (Get-Date -Format 'yyyy-MM-dd HH:mm')).Replace('__TOPIC__', $topicBase))

    Write-Host "`nKlaar" -ForegroundColor White
    Write-Host ("  Cluster        : {0}  ({1})" -f $script:KustoUri, $Sku)
    Write-Host ("  Database       : {0}   tabellen {1} (ruw) -> {2} (getypt)" -f $Database, $RawTable, $Table)
    Write-Host ("  Dataflow       : {0}  ({1} -> {2})" -f $DataflowName, $SourceTopic, $EndpointName)
    Write-Host ("  Configuratie   : {0}" -f $OutputPath)

    Write-Host "`nHome Assistant" -ForegroundColor White
    Write-Host "  1. Maak een automation van $(Split-Path $haFile -Leaf) (instructie staat bovenin het bestand)."
    Write-Host "  2. Haal mqtt_statestream uit configuration.yaml; de automation vervangt hem en AIO gebruikt zijn berichten niet."
    Write-Host "  3. Controleer in MQTT > Configureren > Luisteren naar '$topicBase/#' dat er JSON binnenkomt."
    Write-Host "     De bridge stuurt het door zolang het onder het bridge-topic valt (standaard homeassistant/statestream/#)."

    Write-Host "`nQuery in ADX ($($script:KustoUri) > database $Database)" -ForegroundColor White
    Write-Host "  $Table"
    Write-Host  "  | where Timestamp > ago(1d) and isnotnull(Value)"
    Write-Host  "  | summarize avg(Value) by bin(Timestamp, 15m), FriendlyName"
    Write-Host  "  | render timechart"
    if ($testOk) { Write-Host "  De zelftest laat een rij 'sensor.aio_selftest' achter; filter die weg of negeer hem." -ForegroundColor Gray }

    Write-Host "`nLet op: de cluster draait continu en kost geld zolang hij aan staat, ook als Dev-SKU." -ForegroundColor Yellow
    Write-Host "Stoppen (er komt dan niets meer binnen):" -ForegroundColor Yellow
    Write-Host "  az rest --method post --url `"https://management.azure.com$($clusterPath)/stop?api-version=$kustoApi`"" -ForegroundColor Yellow

    if ($testOk -eq $false) {
        Write-Host "`nDe zelftest is niet geslaagd; zie de waarschuwingen hierboven." -ForegroundColor Red
        exit 1
    }
    exit 0
    #endregion
}
catch {
    Write-Host "`n[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
