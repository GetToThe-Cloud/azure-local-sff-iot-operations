<#
.SYNOPSIS
    Sends Home Assistant states through an Azure IoT Operations data flow as a Delta table to Azure Data Lake
    Storage Gen2: the cheapest cloud destination, with no cluster or capacity running around the clock.

.DESCRIPTION
    Builds on Enable-AioHomeAssistantMqtt.ps1 (Mosquitto bridge from Home Assistant to the AIO MQTT broker).
      1. Creates (or reuses) a storage account with hierarchical namespace: Standard_LRS, Hot, Entra ID only
         (no account keys), TLS 1.2, no public blob access.
      2. Creates a container and grants the system-assigned managed identity of the AIO Arc extension
         Storage Blob Data Contributor on that container. You get Storage Blob Data Reader, for the self-test
         and to read the data later (DuckDB, Fabric shortcut).
      3. Adds a Delta schema to the AIO schema registry; a storage destination requires one.
      4. Creates the AIO data flow endpoint (DataLakeStorage, managed identity) and the data flow from
         -SourceTopic to the container, serialized as Delta.
      5. Self-test: publishes a test message through the mqtt-client pod on the AIO broker and waits for a new
         Delta commit in the container.
      6. Writes a Home Assistant package with an automation that publishes one JSON object per state change.

    Cost: you only pay for storage and transactions. Every data flow batch is one Parquet file plus a commit;
    a longer -LatencySeconds means fewer write operations and fewer small files.

    Why not mqtt_statestream: it publishes a separate JSON value per attribute ("21.5"), not an object.
    A data flow can't map fields from that.

    The script is idempotent: existing resources are reused. Requires the Azure CLI (logged in) with the
    azure-iot-ops extension, Owner (or User Access Administrator) for the role assignments and, for the
    self-test, kubectl with the kubeconfig of the SFF cluster. Works in Windows PowerShell 5.1 and PowerShell 7.
    Exit code 1 on failure, 0 otherwise.

.PARAMETER ResourceGroup
    Resource group of the Azure IoT Operations instance.

.PARAMETER Instance
    Name of the Azure IoT Operations instance ('az iot ops list -o table').

.PARAMETER SubscriptionId
    Subscription. Defaults to the one from 'az account show'.

.PARAMETER StorageResourceGroup
    Resource group for the storage account. Defaults to -ResourceGroup. Created if it doesn't exist.

.PARAMETER Location
    Azure region for the storage account. Defaults to the region of -StorageResourceGroup (or of
    -ResourceGroup if the storage resource group doesn't exist yet).

.PARAMETER StorageAccount
    Storage account name: 3-24 characters, lowercase letters and digits, globally unique. Defaults to 'sthasff'
    plus a fixed hash of subscription and resource group, so a second run picks the same account.

.PARAMETER Container
    Container for the data. The data flow writes the Delta table into a folder with the same name.

.PARAMETER SourceTopic
    MQTT topic filter the data flow reads. Must fall under the topic the Mosquitto bridge forwards to AIO
    (homeassistant/statestream/# by default).

.PARAMETER EndpointName
    Name of the data flow endpoint.

.PARAMETER DataflowName
    Name of the data flow.

.PARAMETER DataflowProfile
    Data flow profile. Defaults to 'default'.

.PARAMETER SchemaName
    Name of the Delta schema in the schema registry.

.PARAMETER SchemaVersion
    Schema version. Versions are immutable: if you change the columns, increase this number.

.PARAMETER LatencySeconds
    Maximum batching time of the data flow in seconds. Defaults to 300: data lands in the container within
    5 minutes, and you get ~288 files per day instead of ~1440 at 60 seconds.

.PARAMETER OutputPath
    Folder for the generated configuration: endpoint and data flow JSON, schema, DuckDB queries and the
    Home Assistant package.

.PARAMETER SkipSelfTest
    Skip the self-test.

.PARAMETER SelfTestMinutes
    How long the self-test waits for a new Delta commit. Defaults to -LatencySeconds plus 10 minutes.

.EXAMPLE
    .\Enable-AioHomeAssistantAdls.ps1 -ResourceGroup 'rg-sff-lab' -Instance 'aio-sff'

.EXAMPLE
    $aioRg = az iot ops list --query "[?name=='aio-azlsff-01'].resourceGroup | [0]" -o tsv
    .\Enable-AioHomeAssistantAdls.ps1 -ResourceGroup $aioRg -Instance 'aio-azlsff-01' -StorageResourceGroup 'rsg-lz-azlocal-sff-aio-dl-01' -StorageAccount 'stlzazlocalsffaiodl01'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Instance,
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$SubscriptionId,
    [string]$StorageResourceGroup,
    [string]$Location,
    [ValidatePattern('^$|^[a-z0-9]{3,24}$')][string]$StorageAccount,
    [ValidatePattern('^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]$')][string]$Container = 'homeassistant',
    [ValidatePattern('^[^\s]+$')][string]$SourceTopic = 'homeassistant/statestream/json/#',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$EndpointName = 'adls-homeassistant',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$DataflowName = 'ha-to-adls',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$DataflowProfile = 'default',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$SchemaName = 'ha-state-adls',
    [ValidatePattern('^[0-9]+$')][string]$SchemaVersion = '1',
    [ValidateRange(1, 3600)][int]$LatencySeconds = 300,
    [string]$OutputPath = (Join-Path (Get-Location) 'ha-adls-config'),
    [switch]$SkipSelfTest,
    [ValidateRange(0, 120)][int]$SelfTestMinutes = 0
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$ns              = 'azure-iot-operations'
$armBase         = 'https://management.azure.com'
$graphBase       = 'https://graph.microsoft.com/v1.0'
$storageApi      = '2023-05-01'
$storageRes      = 'https://storage.azure.com/'
$blobApiVersion  = '2021-08-06'
$aioExtType      = 'microsoft.iotoperations'
$mqttClientUrl   = 'https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/mqtt-client.yaml'
$roleBlobContrib = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'   # Storage Blob Data Contributor
$roleBlobReader  = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'   # Storage Blob Data Reader
if (-not $SelfTestMinutes) { $SelfTestMinutes = [int][math]::Ceiling($LatencySeconds / 60) + 10 }

# Fields Home Assistant publishes per state change, with their Delta type. Same names in the schema and the mapping.
$fields = [ordered]@{
    entity_id     = 'string'
    domain        = 'string'
    friendly_name = 'string'
    state         = 'string'
    value         = 'double'      # numeric state, null for 'on', 'unavailable' and so on
    unit          = 'string'
    device_class  = 'string'
    last_changed  = 'timestamp'   # ISO 8601 in UTC ('...Z'), as in the AIO tutorial for ADLS
    last_updated  = 'timestamp'
}

#region Helpers
function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    [OK]   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    [WARN] $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "           $Text" -ForegroundColor Gray }

function Resolve-Tool {
    param([string]$Name, [string]$Hint)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw "$Name not found. $Hint"
}

function Invoke-Native {
    # Runs a native command; returns stdout as a string and stderr separately (PS 5.1 otherwise turns stderr lines into errors).
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
        throw "$name $($Arguments -join ' ') failed (exit $code):`n$($result.Error)`n$($result.Output)"
    }
    return $result
}

function Invoke-Az {
    # az with the selected subscription; JSON output becomes an object
    param([string[]]$Arguments, [switch]$AllowFailure, [switch]$Raw)
    $r = Invoke-Native $script:az ($Arguments + @('--subscription', $script:SubscriptionId)) -AllowFailure:$AllowFailure
    if ($Raw -or $r.ExitCode -ne 0) { return $r }
    if (-not $r.Output.Trim()) { return $null }
    return ($r.Output | ConvertFrom-Json)
}

function Write-TextFile {
    # UTF-8 without BOM, LF line endings: az, kubectl and Home Assistant read that everywhere
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
    if ($r.ExitCode -ne 0) { throw "No token for $Resource. Sign in with 'az login' and try again. $($r.Error)" }
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

function Get-HttpStatus {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.Response
    if ($resp -and $resp.StatusCode) { return [int]$resp.StatusCode }
    return 0
}

function Get-HttpErrorText {
    param($ErrorRecord)
    $msg = $ErrorRecord.ErrorDetails.Message
    if ($msg) {
        try {
            $j = $msg | ConvertFrom-Json
            if ($j.error.message) { return "$($j.error.code): $($j.error.message)" }
        } catch { }
        return $msg
    }
    return $ErrorRecord.Exception.Message
}

function New-HttpException {
    param([string]$Text, [int]$StatusCode, [string]$ErrorCode)
    $ex = New-Object System.Exception $Text
    $ex.Data['StatusCode'] = $StatusCode
    $ex.Data['ErrorCode']  = $ErrorCode
    return $ex
}

function Invoke-Arm {
    # ARM call. Errors carry the HTTP status and ARM error code in Exception.Data.
    param([string]$Method = 'Get', [string]$Path, $Body, [string]$ApiVersion, [switch]$AllowNotFound)
    $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    $params = @{
        Method      = $Method
        Uri         = "$armBase$Path$($sep)api-version=$ApiVersion"
        Headers     = @{ Authorization = "Bearer $(Get-AzToken 'https://management.azure.com/')"; Accept = 'application/json' }
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body        = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $code = Get-HttpStatus $_
        if ($AllowNotFound -and $code -eq 404) { return $null }
        $errCode = $null
        try { $errCode = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code } catch { }
        throw (New-HttpException ('{0} {1} returned HTTP {2}: {3}' -f $Method.ToUpper(), $Path, $code, (Get-HttpErrorText $_)) $code $errCode)
    }
}

function Wait-ArmSucceeded {
    # Waits until provisioningState is Succeeded. A 404 right after an asynchronous PUT is normal.
    param([string]$Path, [string]$ApiVersion, [int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        $r = Invoke-Arm -Path $Path -ApiVersion $ApiVersion -AllowNotFound
        $ps = if ($r) { $r.properties.provisioningState } else { 'NotFound' }
        if ($ps -eq 'Succeeded') { return $r }
        if ($ps -eq 'Failed') { throw "Provisioning of $Path failed. Check the Activity log in the portal." }
        if ((Get-Date) -gt $deadline) { throw "$Path is still not ready after $Minutes minutes ($ps)." }
        Start-Sleep -Seconds 10
    }
}

function New-StableGuid {
    # Deterministic GUID from text, like guid() in Bicep: the same role assignment gets the same name on every run
    param([string]$Text)
    $md5 = [Security.Cryptography.MD5]::Create()
    return ([guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.ToLower())))).ToString()
}

function Set-RoleAssignment {
    param([string]$Scope, [string]$RoleId, [string]$PrincipalId, [ValidateSet('User', 'ServicePrincipal')][string]$PrincipalType,
          [string]$Label, [string]$RoleName)
    $name = New-StableGuid "$Scope|$RoleId|$PrincipalId"
    $path = "$Scope/providers/Microsoft.Authorization/roleAssignments/$name"
    if (Invoke-Arm -Path $path -ApiVersion '2022-04-01' -AllowNotFound) {
        Write-Ok "$Label already has $RoleName"
        return
    }
    $body = @{ properties = [ordered]@{
        roleDefinitionId = "/subscriptions/$($script:SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$RoleId"
        principalId      = $PrincipalId
        principalType    = $PrincipalType
    } }
    try {
        Invoke-Arm -Method Put -Path $path -ApiVersion '2022-04-01' -Body $body | Out-Null
        Write-Ok "$Label granted $RoleName"
    } catch {
        if ($_.Exception.Data['ErrorCode'] -eq 'RoleAssignmentExists') { Write-Ok "$Label already has $RoleName"; return }
        if ($_.Exception.Data['StatusCode'] -eq 403) {
            throw "Not allowed to assign roles on $Scope. You need Owner or User Access Administrator. $($_.Exception.Message)"
        }
        throw
    }
}

function Get-BlobText {
    # Reads a blob or listing as text with your Entra token. 404 returns $null.
    param([string]$Url)
    $headers = @{ Authorization = "Bearer $(Get-AzToken $storageRes)"; 'x-ms-version' = $blobApiVersion }
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop
    } catch {
        $code = Get-HttpStatus $_
        if ($code -eq 404) { return $null }
        throw (New-HttpException ('GET {0} returned HTTP {1}' -f ($Url -split '\?')[0], $code) $code $null)
    }
    $c = $r.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return ([string]$c).TrimStart([char]0xFEFF)
}

function Get-DeltaHead {
    # Latest commit version of the Delta table under $Prefix (for example 'homeassistant/'), or -1 if there is no log yet
    param([string]$BlobBase, [string]$Prefix)
    $log = "$($Prefix)_delta_log/"
    $v   = -1
    $cp  = Get-BlobText "$BlobBase/$($log)_last_checkpoint"
    if ($cp) { try { $v = [long](($cp | ConvertFrom-Json).version) } catch { $v = -1 } }
    if ($v -lt 0) {
        # No checkpoint yet: the log is small enough to list
        $marker = ''
        $pages  = 0
        do {
            $url = "$($BlobBase)?restype=container&comp=list&maxresults=5000&prefix=$([uri]::EscapeDataString($log))"
            if ($marker) { $url += "&marker=$([uri]::EscapeDataString($marker))" }
            $x = [xml](Get-BlobText $url)
            foreach ($b in @($x.EnumerationResults.Blobs.Blob)) {
                if ($b -and $b.Name -match '(\d{20})\.json$') { $n = [long]$Matches[1]; if ($n -gt $v) { $v = $n } }
            }
            $marker = [string]$x.EnumerationResults.NextMarker
            $pages++
        } while ($marker -and $pages -lt 100)
        return $v
    }
    # Walk forward from the checkpoint to the latest commit
    while (Get-BlobText ('{0}/{1}{2:D20}.json' -f $BlobBase, $log, ($v + 1))) { $v++ }
    return $v
}

function Get-DeltaCommitInfo {
    # Counts the rows in a commit and checks whether its statistics can contain the test message
    param([string]$CommitText, [string]$Entity)
    $rows = 0; $hasStats = $false; $inRange = $false; $files = 0
    foreach ($line in ($CommitText -split "`n")) {
        if (-not $line.Trim()) { continue }
        $a = $null
        try { $a = ($line | ConvertFrom-Json).add } catch { continue }
        if (-not $a) { continue }
        $files++
        if ($a.stats) {
            $s = $a.stats | ConvertFrom-Json
            $rows += [long]$s.numRecords
            $min = $s.minValues.entity_id
            $max = $s.maxValues.entity_id
            if ($null -ne $min -and $null -ne $max) {
                $hasStats = $true
                if ([string]::CompareOrdinal($min, $Entity) -le 0 -and [string]::CompareOrdinal($Entity, $max) -le 0) { $inRange = $true }
            }
        }
    }
    [pscustomobject]@{ Files = $files; Rows = $rows; HasStats = $hasStats; InRange = $inRange }
}
#endregion

try {
    #region 0. Context
    Write-Host "`nAzure IoT Operations - Home Assistant data to Azure Data Lake Storage Gen2" -ForegroundColor White

    Write-Step 'Checking tools and context'
    $script:az = Resolve-Tool 'az' -Hint 'Install the Azure CLI.'
    $ext = Invoke-Native $az @('extension', 'show', '--name', 'azure-iot-ops', '--query', 'version', '-o', 'tsv') -AllowFailure
    if ($ext.ExitCode -ne 0) { throw "The az extension 'azure-iot-ops' is missing. Run: az extension add --upgrade --name azure-iot-ops" }
    Write-Ok "azure-iot-ops extension $($ext.Output.Trim())"

    $acctArgs = @('account', 'show', '-o', 'json')
    if ($SubscriptionId) { $acctArgs += @('--subscription', $SubscriptionId) }
    $acct = Invoke-Native $az $acctArgs -AllowFailure
    if ($acct.ExitCode -ne 0) { throw "No az context. Run 'az login' (optionally with --tenant <tenant-id>)." }
    $acct = $acct.Output | ConvertFrom-Json
    $script:SubscriptionId = $acct.id
    $sid = $acct.id
    Write-Ok "Subscription $($acct.name) ($sid)"

    $graphHeaders = @{ Authorization = "Bearer $(Get-AzToken 'https://graph.microsoft.com')" }
    if ($acct.user.type -eq 'servicePrincipal') {
        $me = Invoke-RestMethod -Headers $graphHeaders -Uri "$graphBase/servicePrincipals(appId='$($acct.user.name)')?`$select=id,displayName"
        $meType  = 'ServicePrincipal'
        $meLabel = $me.displayName
    } else {
        $me = Invoke-RestMethod -Headers $graphHeaders -Uri "$graphBase/me?`$select=id,userPrincipalName"
        $meType  = 'User'
        $meLabel = $me.userPrincipalName
    }
    Write-Ok "Signed in as $meLabel"

    $inst = Invoke-Az @('iot', 'ops', 'show', '--resource-group', $ResourceGroup, '--name', $Instance, '-o', 'json')
    $customLocationId = $inst.extendedLocation.name
    $registryId       = $inst.properties.schemaRegistryRef.resourceId
    if (-not $customLocationId) { throw "Couldn't determine the custom location of $Instance." }
    if (-not $registryId)       { throw "$Instance has no schema registry. A data flow to ADLS needs one." }
    Write-Ok "Found IoT Operations instance $Instance"

    # Managed identity of the AIO Arc extension: instance -> custom location -> Arc cluster -> extension
    $cl     = Invoke-Arm -Path $customLocationId -ApiVersion '2021-08-15'
    $hostId = $cl.properties.hostResourceId
    $exts   = @((Invoke-Arm -Path "$hostId/providers/Microsoft.KubernetesConfiguration/extensions" -ApiVersion '2023-05-01').value)
    $aioExt = @($exts | Where-Object { $_.properties.extensionType -ieq $aioExtType }) | Select-Object -First 1
    if (-not $aioExt) { throw "No extension of type $aioExtType found on $hostId." }
    $miId = $aioExt.identity.principalId
    if (-not $miId) { throw "Extension $($aioExt.name) has no system-assigned identity." }
    Write-Ok "Managed identity of the AIO extension: $($aioExt.name)"
    #endregion

    #region 1. Storage account
    Write-Step 'Storage account (Data Lake Storage Gen2)'
    if (-not $StorageResourceGroup) { $StorageResourceGroup = $ResourceGroup }
    $rgPath = "/subscriptions/$sid/resourcegroups/$StorageResourceGroup"
    $rg     = Invoke-Arm -Path $rgPath -ApiVersion '2021-04-01' -AllowNotFound
    if (-not $rg) {
        if (-not $Location) {
            $Location = (Invoke-Arm -Path "/subscriptions/$sid/resourcegroups/$ResourceGroup" -ApiVersion '2021-04-01').location
        }
        $rg = Invoke-Arm -Method Put -Path $rgPath -ApiVersion '2021-04-01' -Body @{ location = $Location }
        Write-Ok "Created resource group $StorageResourceGroup in $Location"
    }
    if (-not $Location) { $Location = $rg.location }
    $Location = $Location.ToLower() -replace '\s', ''

    if (-not $StorageAccount) {
        # Fixed name per subscription + resource group, so a second run finds the same account
        $sha  = [Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$sid/$StorageResourceGroup".ToLower()))
        $StorageAccount = 'sthasff' + ((@($hash[0..3]) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    $saPath = "$rgPath/providers/Microsoft.Storage/storageAccounts/$StorageAccount"
    $sa     = Invoke-Arm -Path $saPath -ApiVersion $storageApi -AllowNotFound

    if (-not $sa) {
        $prov = Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Storage" -ApiVersion '2021-04-01'
        if ($prov.registrationState -ne 'Registered') {
            Invoke-Arm -Method Post -Path "/subscriptions/$sid/providers/Microsoft.Storage/register" -ApiVersion '2021-04-01' | Out-Null
            $deadline = (Get-Date).AddMinutes(10)
            do {
                Start-Sleep -Seconds 15
                $prov = Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Storage" -ApiVersion '2021-04-01'
            } while ($prov.registrationState -ne 'Registered' -and (Get-Date) -lt $deadline)
            Write-Ok 'Registered resource provider Microsoft.Storage'
        }
        $avail = Invoke-Arm -Method Post -Path "/subscriptions/$sid/providers/Microsoft.Storage/checkNameAvailability" `
            -ApiVersion $storageApi -Body @{ name = $StorageAccount; type = 'Microsoft.Storage/storageAccounts' }
        if (-not $avail.nameAvailable) {
            throw "Name '$StorageAccount' isn't available ($($avail.message)). Pick another one with -StorageAccount."
        }
        $body = [ordered]@{
            location   = $Location
            kind       = 'StorageV2'
            sku        = @{ name = 'Standard_LRS' }
            properties = [ordered]@{
                isHnsEnabled                 = $true    # hierarchical namespace: required by AIO
                accessTier                   = 'Hot'    # many small writes: Hot is cheaper than Cool for that
                minimumTlsVersion            = 'TLS1_2'
                supportsHttpsTrafficOnly     = $true
                allowBlobPublicAccess        = $false
                allowSharedKeyAccess         = $false   # Entra ID only, no account keys
                defaultToOAuthAuthentication = $true
            }
        }
        Invoke-Arm -Method Put -Path $saPath -ApiVersion $storageApi -Body $body | Out-Null
        $sa = Wait-ArmSucceeded -Path $saPath -ApiVersion $storageApi -Minutes 10
        Write-Ok "Created storage account $StorageAccount in $Location (Standard_LRS, Hot, hierarchical namespace)"
    } else {
        if ($sa.properties.provisioningState -ne 'Succeeded') { $sa = Wait-ArmSucceeded -Path $saPath -ApiVersion $storageApi }
        if (-not $sa.properties.isHnsEnabled) {
            throw "Storage account $StorageAccount already exists but has no hierarchical namespace. Pick another name with -StorageAccount."
        }
        Write-Ok "Reusing existing storage account $StorageAccount"
    }

    $containerPath = "$saPath/blobServices/default/containers/$Container"
    if (Invoke-Arm -Path $containerPath -ApiVersion $storageApi -AllowNotFound) {
        Write-Ok "Container $Container already exists"
    } else {
        Invoke-Arm -Method Put -Path $containerPath -ApiVersion $storageApi -Body @{ properties = @{ publicAccess = 'None' } } | Out-Null
        Write-Ok "Created container $Container"
    }

    Set-RoleAssignment -Scope $containerPath -RoleId $roleBlobContrib -PrincipalId $miId -PrincipalType 'ServicePrincipal' `
        -Label "$($aioExt.name) (AIO)" -RoleName 'Storage Blob Data Contributor on the container'
    Set-RoleAssignment -Scope $containerPath -RoleId $roleBlobReader -PrincipalId $me.id -PrincipalType $meType `
        -Label $meLabel -RoleName 'Storage Blob Data Reader on the container'
    #endregion

    #region 2. Delta schema in the schema registry
    Write-Step "Schema $SchemaName (version $SchemaVersion)"
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

    if ($registryId -notmatch '/resourceGroups/([^/]+)/providers/Microsoft\.DeviceRegistry/schemaRegistries/([^/]+)$') {
        throw "Unexpected schema registry ID: $registryId"
    }
    $regRg   = $Matches[1]
    $regName = $Matches[2]
    $schema = [ordered]@{
        '$schema'  = 'Delta/1.0'
        type       = 'object'
        properties = [ordered]@{
            type   = 'struct'
            fields = @($fields.Keys | ForEach-Object { [ordered]@{ name = $_; type = $fields[$_]; nullable = $true; metadata = @{} } })
        }
    }
    $schemaFile = Join-Path $OutputPath "schema-$SchemaName-v$SchemaVersion.json"
    Write-TextFile $schemaFile ($schema | ConvertTo-Json -Depth 10)
    $wanted = (@($fields.Keys) | ForEach-Object { "$($_):$($fields[$_])" }) -join ','

    $regArgs = @('--registry', $regName, '--resource-group', $regRg)
    $verRes = Invoke-Az (@('iot', 'ops', 'schema', 'version', 'show', '--version', $SchemaVersion, '--schema', $SchemaName,
        '-o', 'json') + $regArgs) -AllowFailure -Raw
    if ($verRes.ExitCode -eq 0 -and $verRes.Output.Trim()) {
        $content = ($verRes.Output | ConvertFrom-Json).properties.schemaContent
        if ($content -is [string]) { $content = $content | ConvertFrom-Json }
        $have = (@($content.properties.fields) | ForEach-Object { "$($_.name):$($_.type)" }) -join ','
        if ($have -ne $wanted) {
            throw "Schema version $SchemaVersion of $SchemaName already exists with different fields ($have). Versions are immutable; run again with -SchemaVersion $([int]$SchemaVersion + 1)."
        }
        Write-Ok 'Schema version already exists with the same fields'
    } else {
        $schemaExists = Invoke-Az (@('iot', 'ops', 'schema', 'show', '--name', $SchemaName, '-o', 'none') + $regArgs) -AllowFailure -Raw
        try {
            if ($schemaExists.ExitCode -eq 0) {
                Invoke-Az (@('iot', 'ops', 'schema', 'version', 'add', '--schema', $SchemaName, '--version', $SchemaVersion,
                    '--content', $schemaFile, '-o', 'none') + $regArgs) -Raw | Out-Null
            } else {
                Invoke-Az (@('iot', 'ops', 'schema', 'create', '--name', $SchemaName, '--format', 'delta', '--type', 'message',
                    '--version-content', $schemaFile, '--version', $SchemaVersion, '--desc', 'Home Assistant states for ADLS',
                    '-o', 'none') + $regArgs) -Raw | Out-Null
            }
        } catch {
            throw "$($_.Exception.Message)`nTip: the storage account of the schema registry needs public network access to add a schema."
        }
        Write-Ok "Added schema to registry $regName"
    }

    # Reference for the data flow: aio-sr://<namespace>/<schema>:<version>
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
    Write-Ok "Schema reference: $schemaRef"
    #endregion

    #region 3. Data flow endpoint and data flow
    Write-Step "Data flow endpoint $EndpointName"
    $blobHost = "https://$StorageAccount.blob.core.windows.net"
    $endpoint = [ordered]@{
        endpointType            = 'DataLakeStorage'
        dataLakeStorageSettings = [ordered]@{
            authentication = [ordered]@{ method = 'SystemAssignedManagedIdentity'; systemAssignedManagedIdentitySettings = @{} }
            batching       = [ordered]@{ latencySeconds = $LatencySeconds; maxMessages = 100000 }
            host           = $blobHost
        }
    }
    $endpointFile = Join-Path $OutputPath "endpoint-$EndpointName.json"
    Write-TextFile $endpointFile ($endpoint | ConvertTo-Json -Depth 10)
    Invoke-Az @('iot', 'ops', 'dataflow', 'endpoint', 'apply', '--resource-group', $ResourceGroup, '--instance', $Instance,
        '--name', $EndpointName, '--config-file', $endpointFile, '-o', 'none') -Raw | Out-Null
    Write-Ok "Endpoint applied ($blobHost, batching $LatencySeconds s)"

    Write-Step "Data flow $DataflowName"
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
                    # Every field mapped explicitly, no wildcard: an extra field in a message then doesn't drop the whole batch
                    serializationFormat = 'Delta'
                    schemaRef           = $schemaRef
                    map                 = @($fields.Keys | ForEach-Object { [ordered]@{ inputs = @($_); output = $_ } })
                }
            },
            [ordered]@{
                operationType       = 'Destination'
                destinationSettings = [ordered]@{ endpointRef = $EndpointName; dataDestination = $Container }
            }
        )
    }
    $dataflowFile = Join-Path $OutputPath "dataflow-$DataflowName.json"
    Write-TextFile $dataflowFile ($dataflow | ConvertTo-Json -Depth 10)
    Invoke-Az @('iot', 'ops', 'dataflow', 'apply', '--resource-group', $ResourceGroup, '--instance', $Instance,
        '--profile', $DataflowProfile, '--name', $DataflowName, '--config-file', $dataflowFile, '-o', 'none') -Raw | Out-Null
    Write-Ok "Data flow applied: $SourceTopic -> $StorageAccount/$Container (Delta)"

    $deadline = (Get-Date).AddMinutes(5)
    $dfState  = $null
    do {
        $df = Invoke-Az @('iot', 'ops', 'dataflow', 'show', '--resource-group', $ResourceGroup, '--instance', $Instance,
            '--profile', $DataflowProfile, '--name', $DataflowName, '-o', 'json')
        $dfState = $df.properties.provisioningState
        if ($dfState -in @('Succeeded', 'Failed')) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($dfState -eq 'Failed') { throw "Data flow $DataflowName is in state Failed. Check it in the operations experience or with 'az iot ops dataflow show'." }
    if ($dfState -eq 'Succeeded') { Write-Ok 'Data flow is deployed to the cluster' }
    else { Write-Warn "Data flow is still '$dfState' after 5 minutes. That can take a while; the self-test shows whether it works." }
    #endregion

    #region 4. Self-test
    $testOk   = $null
    $blobBase = "$blobHost/$Container"
    if ($SkipSelfTest) {
        Write-Warn 'Self-test skipped (-SkipSelfTest)'
    } else {
        Write-Step 'Self-test: test message through the AIO broker to the container'
        $kubectlCmd = Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $nsCheck    = if ($kubectlCmd) { Invoke-Native $kubectlCmd.Source @('get', 'namespace', $ns, '-o', 'name') -AllowFailure }
        if (-not $kubectlCmd -or $nsCheck.ExitCode -ne 0) {
            Write-Warn 'kubectl is missing or can''t reach the cluster (is KUBECONFIG set?). Self-test skipped.'
        } else {
            $kubectl    = $kubectlCmd.Source
            $createdPod = $false
            try {
                # Your read access was just granted; Azure RBAC sometimes needs a few minutes
                $deadline = (Get-Date).AddMinutes(10)
                $roots    = [ordered]@{}
                while ($true) {
                    try {
                        # The data flow writes the Delta table into a folder named after the container; the root as a fallback
                        foreach ($p in @("$Container/", '')) { $roots[$p] = Get-DeltaHead -BlobBase $blobBase -Prefix $p }
                        break
                    } catch {
                        if ($_.Exception.Data['StatusCode'] -eq 403 -and (Get-Date) -lt $deadline) {
                            Write-Info 'No read access to the container yet (role assignment is propagating). Retrying in 20 s.'
                            Start-Sleep -Seconds 20
                            continue
                        }
                        throw
                    }
                }
                foreach ($p in $roots.Keys) {
                    if ($roots[$p] -ge 0) { Write-Info "Existing Delta table in /$p (latest commit $($roots[$p]))" }
                }

                $pod = Invoke-Native $kubectl @('get', 'pod', 'mqtt-client', '-n', $ns, '-o', 'name') -AllowFailure
                if ($pod.ExitCode -ne 0) {
                    Invoke-Native $kubectl @('apply', '-f', $mqttClientUrl) | Out-Null
                    $createdPod = $true
                    Write-Ok 'Deployed temporary mqtt-client pod (sample from the Microsoft docs)'
                }
                Invoke-Native $kubectl @('wait', '--for=condition=Ready', 'pod/mqtt-client', '-n', $ns, '--timeout=180s') | Out-Null

                # The sample pod installs mosquitto-clients after it starts (apk add) and is already Ready by then
                $deadline = (Get-Date).AddMinutes(3)
                while ($true) {
                    $chk = Invoke-Native $kubectl @('exec', 'mqtt-client', '-n', $ns, '--', 'sh', '-c', 'command -v mosquitto_pub') -AllowFailure
                    if ($chk.ExitCode -eq 0) { break }
                    if ((Get-Date) -gt $deadline) {
                        $logs = Invoke-Native $kubectl @('logs', 'mqtt-client', '-n', $ns, '--tail=5') -AllowFailure
                        throw ("mosquitto_pub is still missing in the mqtt-client pod after 3 minutes. The pod installs it with 'apk add'; " +
                               "does the cluster have internet access to dl-cdn.alpinelinux.org? Last pod log lines:`n$($logs.Output)$($logs.Error)")
                    }
                    Start-Sleep -Seconds 5
                }
                Write-Ok 'mosquitto-clients is ready in the pod'

                # Topic under -SourceTopic, for a fake entity that is easy to spot in the data
                $testEntity = 'sensor.aio_selftest'
                $base       = $SourceTopic -replace '/?#$', '' -replace '\+', 'selftest'
                $testTopic  = if ($SourceTopic -match '#$') { "$base/$testEntity" } else { $base }
                $marker     = Get-Random -Minimum 100000 -Maximum 999999
                $now        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')
                $payload    = [ordered]@{
                    entity_id = $testEntity; domain = 'sensor'; friendly_name = 'AIO self-test'; state = [string]$marker
                    value = [double]$marker; unit = 'test'; device_class = ''; last_changed = $now; last_updated = $now
                } | ConvertTo-Json -Compress
                # Base64 avoids quoting problems with JSON in a native argument under PS 5.1
                $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
                $sh  = 'echo ' + $b64 + ' | base64 -d | mosquitto_pub --host aio-broker --port 18883 --qos 1 --topic ' + $testTopic +
                       ' -s --cafile /var/run/certs/ca.crt -D CONNECT authentication-method K8S-SAT' +
                       ' -D CONNECT authentication-data $(cat /var/run/secrets/tokens/broker-sat)'
                $sent = Get-Date
                Invoke-Native $kubectl @('exec', 'mqtt-client', '-n', $ns, '--', 'sh', '-c', $sh) | Out-Null
                Write-Ok "Published test message on $testTopic"
                Write-Info "The data flow writes per batch (at most $LatencySeconds s); waiting for a new Delta commit, up to $SelfTestMinutes min."

                $deadline = (Get-Date).AddMinutes($SelfTestMinutes)
                $next     = [ordered]@{}
                foreach ($p in $roots.Keys) { $next[$p] = $roots[$p] + 1 }
                $found    = $null
                $lastInfo = Get-Date
                while (-not $found -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 20
                    foreach ($p in @($next.Keys)) {
                        try {
                            # Walk through every new commit: live Home Assistant data can arrive in between
                            while ($true) {
                                $url    = '{0}/{1}_delta_log/{2:D20}.json' -f $blobBase, $p, $next[$p]
                                $commit = Get-BlobText $url
                                if (-not $commit) { break }
                                $info = Get-DeltaCommitInfo -CommitText $commit -Entity $testEntity
                                Write-Info ("New commit {0} in /{1}: {2} file(s), {3} row(s)" -f $next[$p], $p, $info.Files, $info.Rows)
                                $next[$p]++
                                if ($info.Files -gt 0 -and (-not $info.HasStats -or $info.InRange)) {
                                    $found = [pscustomobject]@{ Prefix = $p; Version = $next[$p] - 1; Info = $info }
                                    break
                                }
                            }
                        } catch {
                            Write-Info "Read failed: $($_.Exception.Message)"
                        }
                        if ($found) { break }
                    }
                    if (-not $found -and ((Get-Date) - $lastInfo).TotalSeconds -ge 60) {
                        Write-Info ('{0:HH:mm:ss}  no new commit yet' -f (Get-Date))
                        $lastInfo = Get-Date
                    }
                }

                if ($found) {
                    $secs  = [int]((Get-Date) - $sent).TotalSeconds
                    $table = "$($found.Prefix)".TrimEnd('/')
                    $where = if ($table) { "folder /$table" } else { 'the root of the container' }
                    if ($found.Info.HasStats) {
                        Write-Ok "Test message in the Delta table in $where after ~$secs s (commit $($found.Version))"
                    } else {
                        Write-Ok "New Delta commit in $where after ~$secs s (commit $($found.Version)); the commit has no statistics, so check the contents with DuckDB"
                    }
                    $script:TablePath = $table
                    $testOk = $true
                } else {
                    $testOk = $false
                    Write-Warn "No new Delta commit with the test message after $SelfTestMinutes min."
                    Write-Info "Check the data flow pod: kubectl get pods -n $ns  (aio-dataflow-*), then kubectl logs <pod> -n $ns"
                    Write-Info 'If you see 403/AuthorizationPermissionMismatch, wait 10 minutes (RBAC) and run the script again.'
                }
            } catch {
                $testOk = $false
                Write-Warn "Self-test failed: $($_.Exception.Message)"
            } finally {
                if ($createdPod) {
                    Invoke-Native $kubectl @('delete', '-f', $mqttClientUrl, '--ignore-not-found', '--wait=false') -AllowFailure | Out-Null
                    Write-Info 'Removed temporary mqtt-client pod'
                }
            }
        }
    }
    #endregion

    #region 5. Home Assistant automation and summary
    $topicBase = $SourceTopic -replace '/?#$', ''
    if ($topicBase -match '\+') {
        Write-Warn "-SourceTopic contains '+'; adjust the topic in the automation yourself so it falls under '$SourceTopic'."
    }
    # A package instead of the automation editor: it doesn't depend on automations.yaml, keeps the file in one place,
    # and the configuration check reports the exact line if something is wrong.
    $haFile = Join-Path $OutputPath 'aio_adls.yaml'
    $haYaml = @'
# Home Assistant package, generated by Enable-AioHomeAssistantAdls.ps1 on __DATE__.
# 1. Copy this file to /config/packages/aio_adls.yaml (create the packages folder if needed).
# 2. In configuration.yaml, under the existing 'homeassistant:' key (or add that key), add:
#      packages: !include_dir_named packages
# 3. Developer tools > YAML > Check configuration, then restart Home Assistant.
# Adjust 'domains' and 'exclude' to what you want to keep.
automation:
  - id: aio_states_json_mqtt
    alias: AIO - states as JSON to MQTT
    description: >-
      Publishes every state change as one JSON object on __TOPIC__/<entity_id>.
      The Mosquitto bridge forwards it to Azure IoT Operations, and a data flow writes it as a Delta table
      to Azure Data Lake Storage.
    mode: queued
    max: 500
    max_exceeded: silent
    variables:
      domains:
        - sensor
      exclude: "_(uptime|rssi|signal_strength|last_boot)$"
    triggers:
      - trigger: event
        event_type: state_changed
    conditions:
      - condition: template
        value_template: >-
          {% set n = trigger.event.data.new_state %}
          {% set o = trigger.event.data.old_state %}
          {{ n is not none
             and n.domain in domains
             and (exclude == '' or n.entity_id is not search(exclude))
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
              'value': n.state | float(none),
              'unit': n.attributes.get('unit_of_measurement') or '',
              'device_class': n.attributes.get('device_class') or '',
              'last_changed': n.last_changed.strftime('%Y-%m-%dT%H:%M:%S.%fZ'),
              'last_updated': n.last_updated.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
            } | to_json }}
'@
    Write-TextFile $haFile ($haYaml.Replace('__DATE__', (Get-Date -Format 'yyyy-MM-dd HH:mm')).Replace('__TOPIC__', $topicBase))

    $tablePath = if ($null -ne $script:TablePath) { $script:TablePath } else { $Container }
    $abfss     = "abfss://$Container@$StorageAccount.dfs.core.windows.net/$tablePath"
    $duckFile  = Join-Path $OutputPath 'query-duckdb.sql'
    $duckSql   = @'
-- Generated by Enable-AioHomeAssistantAdls.ps1. Local and free: duckdb -c ".read query-duckdb.sql"
-- Uses your 'az login' (Storage Blob Data Reader on the container is already granted).
INSTALL azure; LOAD azure;
INSTALL delta; LOAD delta;
CREATE OR REPLACE SECRET ha (TYPE azure, PROVIDER credential_chain, CHAIN 'cli', ACCOUNT_NAME '__ACCOUNT__');

-- Latest 20 state changes
SELECT last_changed, friendly_name, state, value, unit
FROM delta_scan('__ABFSS__')
ORDER BY last_changed DESC
LIMIT 20;

-- 15-minute averages over the last day
SELECT time_bucket(INTERVAL 15 MINUTE, last_changed) AS quarter_hour, friendly_name, round(avg(value), 2) AS average, any_value(unit) AS unit
FROM delta_scan('__ABFSS__')
WHERE value IS NOT NULL AND last_changed > now() - INTERVAL 1 DAY
GROUP BY ALL
ORDER BY quarter_hour, friendly_name;
'@
    Write-TextFile $duckFile ($duckSql.Replace('__ACCOUNT__', $StorageAccount).Replace('__ABFSS__', $abfss))

    Write-Host "`nDone" -ForegroundColor White
    Write-Host ("  Storage account : {0}  (Standard_LRS, Hot, hierarchical namespace)" -f $StorageAccount)
    Write-Host ("  Delta table     : {0}" -f $abfss)
    Write-Host ("  Data flow       : {0}  ({1} -> {2}, batching {3} s)" -f $DataflowName, $SourceTopic, $EndpointName, $LatencySeconds)
    Write-Host ("  Configuration   : {0}" -f $OutputPath)

    Write-Host "`nHome Assistant" -ForegroundColor White
    Write-Host "  1. Copy $(Split-Path $haFile -Leaf) to /config/packages/ and enable packages (instructions at the top of the file)."
    Write-Host "  2. Remove mqtt_statestream from configuration.yaml; the automation replaces it and AIO can't use its messages."
    Write-Host "  3. In MQTT > Configure > Listen to a topic, check that JSON arrives on '$topicBase/#'."
    Write-Host "     The bridge forwards it as long as it falls under the bridge topic (homeassistant/statestream/# by default)."

    Write-Host "`nView the data" -ForegroundColor White
    Write-Host "  Local, free     : duckdb -c `".read $duckFile`""
    $dfsUrl = "https://$StorageAccount.dfs.core.windows.net/$Container/$tablePath"
    Write-Host "  Microsoft Fabric: lakehouse > Tables > New shortcut > Azure Data Lake Storage Gen2"
    Write-Host "                   $dfsUrl"
    Write-Host "                   Only run the capacity while you query; the data lives in your storage account regardless."
    if ($testOk) { Write-Host "  The self-test leaves a 'sensor.aio_selftest' row behind; filter it out or ignore it." -ForegroundColor Gray }

    if ($testOk -eq $false) {
        Write-Host "`nThe self-test didn't pass; see the warnings above." -ForegroundColor Red
        exit 1
    }
    exit 0
    #endregion
}
catch {
    Write-Host "`n[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
