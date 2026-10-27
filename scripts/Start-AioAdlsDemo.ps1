<#
.SYNOPSIS
    Live demo: a value you change in Home Assistant shows up on the Azure IoT Operations MQTT broker at the edge and
    lands as a row in the Delta table in Azure Data Lake Storage Gen2.

.DESCRIPTION
    Builds on Enable-AioHomeAssistantMqtt.ps1 (Mosquitto bridge), Enable-AioHomeAssistantAdls.ps1 (data flow to ADLS,
    including the Home Assistant automation aio_adls.yaml) and the Home Assistant package aio_demo.yaml (slider
    input_number.aio_demo_temperature that drives sensor.aio_demo_temperature).

    -Mode Prepare   Run 15 minutes or more before the demo:
                    - lowers the batching latency of the ADLS data flow endpoint to -DemoLatencySeconds (default 10),
                      so the lake step takes seconds instead of minutes; the original value is saved for Restore
                    - deploys the mqtt-client pod the demo uses to watch the broker
                    - checks read access to the Delta table, DuckDB and, with -HomeAssistantUrl, the demo entities
    -Mode Run       The demo itself, in steps with a pause between them (-NoPause to run straight through):
                    1. The chain and its health: node, data flow, endpoint batching, latest Delta commit
                    2. Home Assistant -> AIO broker: change the value, the script shows the message arriving at the edge
                    3. AIO broker -> Data Lake: waits for the Delta commit with that message and shows the row
                    4. What you can do with the data: per-sensor summary of the last 24 hours (DuckDB)
                    5. Timings and where to look in the Azure portal
    -Mode Restore   Run after the demo: restores the original batching latency and removes the pod if Prepare created it.

    -Trigger decides what starts step 2:
      Manual            (default) you move the slider in Home Assistant yourself, in front of your audience
      HomeAssistantApi  the script sets the slider through the Home Assistant REST API (-HomeAssistantUrl; long-lived
                        access token from $env:HA_TOKEN, otherwise prompted)
      Synthetic         plan B: publishes the same JSON message straight on the AIO broker, bypassing Home Assistant

    Requires the Azure CLI (logged in) with the azure-iot-ops extension, kubectl with the kubeconfig of the SFF
    cluster and Storage Blob Data Reader on the container (Enable-AioHomeAssistantAdls.ps1 grants it). To show the
    actual rows you need the DuckDB CLI (winget install DuckDB.cli); without it the script shows the Delta commit
    statistics. Works in Windows PowerShell 5.1 and PowerShell 7. Exit code 1 on failure, 0 otherwise.

.PARAMETER Mode
    Prepare, Run (default) or Restore.

.PARAMETER Instance
    Name of the Azure IoT Operations instance ('az iot ops list -o table').

.PARAMETER ResourceGroup
    Resource group of the instance. Looked up by instance name when omitted.

.PARAMETER SubscriptionId
    Subscription. Defaults to the one from 'az account show'.

.PARAMETER DataflowName
    Data flow that writes to ADLS. The endpoint, storage account, container and source topic are read from it.

.PARAMETER DataflowProfile
    Data flow profile. Defaults to 'default'.

.PARAMETER DemoEntity
    Home Assistant entity the demo follows. Must be in a domain the automation publishes (sensor by default).

.PARAMETER SliderEntity
    The input_number the HomeAssistantApi trigger sets.

.PARAMETER Trigger
    Manual (default), HomeAssistantApi or Synthetic. See the description.

.PARAMETER HomeAssistantUrl
    Base URL of Home Assistant, for example http://homeassistant.local:8123. Needed for -Trigger HomeAssistantApi;
    with -Mode Prepare it also checks that the demo entities exist.

.PARAMETER DemoLatencySeconds
    Batching latency that Prepare sets on the endpoint. Defaults to 10.

.PARAMETER RestoreLatencySeconds
    Latency that Restore sets. Defaults to the value Prepare saved, or 300 if nothing was saved.

.PARAMETER NoPause
    Run the demo without waiting for Enter between the steps (rehearsal).

.PARAMETER SkipSummary
    Skip step 4 (the 24-hour summary straight from the Delta table).

.PARAMETER OutputPath
    Folder for the saved state, downloaded Parquet files and DuckDB queries.

.EXAMPLE
    .\Start-AioAdlsDemo.ps1 -Mode Prepare -Instance 'aio-azlsff-01' -HomeAssistantUrl 'http://homeassistant.local:8123'

.EXAMPLE
    .\Start-AioAdlsDemo.ps1 -Instance 'aio-azlsff-01'

    The demo: you move the slider in Home Assistant when the script asks for it.

.EXAMPLE
    .\Start-AioAdlsDemo.ps1 -Instance 'aio-azlsff-01' -Trigger Synthetic

    Plan B when Home Assistant or the bridge doesn't cooperate.

.EXAMPLE
    .\Start-AioAdlsDemo.ps1 -Mode Restore -Instance 'aio-azlsff-01'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Run', 'Restore')][string]$Mode = 'Run',
    [Parameter(Mandatory)][string]$Instance,
    [string]$ResourceGroup,
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$SubscriptionId,
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$DataflowName = 'ha-to-adls',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$DataflowProfile = 'default',
    [ValidatePattern('^[a-z0-9_]+\.[a-z0-9_]+$')][string]$DemoEntity = 'sensor.aio_demo_temperature',
    [ValidatePattern('^input_number\.[a-z0-9_]+$')][string]$SliderEntity = 'input_number.aio_demo_temperature',
    [ValidateSet('Manual', 'HomeAssistantApi', 'Synthetic')][string]$Trigger = 'Manual',
    [ValidatePattern('^$|^https?://')][string]$HomeAssistantUrl,
    [ValidateRange(1, 300)][int]$DemoLatencySeconds = 10,
    [ValidateRange(0, 3600)][int]$RestoreLatencySeconds = 0,
    [switch]$NoPause,
    [switch]$SkipSummary,
    [string]$OutputPath = (Join-Path (Get-Location) 'aio-demo')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # keeps Invoke-WebRequest fast in PS 5.1 and the screen clean
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$ns            = 'azure-iot-operations'
$storageRes    = 'https://storage.azure.com/'
$blobApi       = '2021-08-06'
$mqttClientUrl = 'https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/mqtt-client.yaml'
$inv           = [Globalization.CultureInfo]::InvariantCulture
$degC          = [string][char]0x00B0 + 'C'   # kept out of the source so the file stays ASCII (PS 5.1 reads it as ANSI)
$script:Watch  = $null
$script:PodCreatedByRun = $false

#region Helpers: output
function Write-Step   { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok     { param([string]$Text) Write-Host "    [OK]   $Text" -ForegroundColor Green }
function Write-Warn   { param([string]$Text) Write-Host "    [WARN] $Text" -ForegroundColor Yellow }
function Write-Info   { param([string]$Text) Write-Host "           $Text" -ForegroundColor Gray }

function Write-Stage {
    param([int]$Number, [string]$Title)
    Write-Host ''
    Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkCyan
    Write-Host ("   STEP {0}  {1}" -f $Number, $Title) -ForegroundColor White
    Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkCyan
}

function Write-Fields {
    # Aligned "name : value" lines
    param([System.Collections.IDictionary]$Fields, [ConsoleColor]$Color = 'White', [int]$Indent = 6)
    $width = ($Fields.Keys | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
    foreach ($k in $Fields.Keys) {
        Write-Host ((' ' * $Indent) + "$k".PadRight($width) + ' : ' + "$($Fields[$k])") -ForegroundColor $Color
    }
}

function Write-Ticker {
    param([string]$Text)
    Write-Host ("`r           " + $Text.PadRight(66)) -NoNewline -ForegroundColor Gray
}
function Clear-Ticker { Write-Host ("`r" + (' ' * 80) + "`r") -NoNewline }

function Wait-Presenter {
    param([string]$Next)
    if ($NoPause) { return }
    Write-Host ''
    Read-Host "    Press Enter for: $Next" | Out-Null
}

function Format-Sec {
    param([double]$Seconds)
    return ([math]::Round($Seconds, 1)).ToString('0.0', $inv) + ' s'
}

function Format-Num {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    return ([double]$Value).ToString('0.##', $inv)
}

function ConvertTo-LocalTime {
    # ISO 8601 text or a DateTime (PS 7's ConvertFrom-Json already turns ISO strings into DateTime) to local time
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.LocalDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc).ToLocalTime() }
        return $Value.ToLocalTime()
    }
    try { return [DateTimeOffset]::Parse([string]$Value, $inv, [Globalization.DateTimeStyles]::AssumeUniversal).LocalDateTime } catch { return $null }
}
#endregion

#region Helpers: processes
function Resolve-Tool {
    param([string]$Name, [string]$Hint, [switch]$Optional)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    if ($Optional) { return $null }
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
    param([string[]]$Arguments, [switch]$AllowFailure)
    $r = Invoke-Native $script:az ($Arguments + @('--subscription', $script:SubscriptionId, '--only-show-errors')) -AllowFailure:$AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    if (-not $r.Output.Trim()) { return $null }
    return ($r.Output | ConvertFrom-Json)
}

function ConvertTo-CommandLine {
    # Quotes arguments the way the Windows C runtime (and Go, for kubectl) splits them again
    param([string[]]$Arguments)
    $bsChar = [char]92
    $parts = foreach ($a in $Arguments) {
        if ($a -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq $bsChar) { $bs++; continue }
            if ($ch -eq [char]34) {
                [void]$sb.Append($bsChar, 2 * $bs + 1)
            } elseif ($bs) {
                [void]$sb.Append($bsChar, $bs)
            }
            [void]$sb.Append($ch)
            $bs = 0
        }
        if ($bs) { [void]$sb.Append($bsChar, 2 * $bs) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

function Start-Proc {
    # Starts a native process with redirected, UTF-8 decoded output (the payload contains a degree sign)
    param([string]$FilePath, [string[]]$Arguments)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ConvertTo-CommandLine $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding  = $utf8
    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-Proc {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 120, [switch]$AllowFailure)
    $p   = Start-Proc $FilePath $Arguments
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        throw "$(Split-Path $FilePath -Leaf) didn't finish within $TimeoutSeconds s."
    }
    $p.WaitForExit()
    $r = [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out.Result; Error = "$($err.Result)".Trim() }
    $p.Dispose()
    if ($r.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "$(Split-Path $FilePath -Leaf) failed (exit $($r.ExitCode)): $($r.Error) $($r.Output)"
    }
    return $r
}

function Write-TextFile {
    # UTF-8 without BOM, LF line endings
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Remove-NullProperty {
    # Removes null values recursively from objects that come in through ConvertFrom-Json
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { Remove-NullProperty $_ })
    }
    if ($InputObject -is [pscustomobject]) {
        $clean = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            if ($null -ne $p.Value) { $clean[$p.Name] = Remove-NullProperty $p.Value }
        }
        return [pscustomobject]$clean
    }
    return $InputObject
}
#endregion

#region Helpers: Azure tokens and blobs
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

function Get-BlobText {
    # Reads a blob or listing as text with your Entra token. 404 returns $null; other errors carry the status code.
    param([string]$Url)
    $headers = @{ Authorization = "Bearer $(Get-AzToken $storageRes)"; 'x-ms-version' = $blobApi }
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop
    } catch {
        $code = Get-HttpStatus $_
        if ($code -eq 404) { return $null }
        $ex = New-Object System.Exception ('GET {0} returned HTTP {1}' -f ($Url -split '\?')[0], $code)
        $ex.Data['StatusCode'] = $code
        throw $ex
    }
    $c = $r.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return ([string]$c).TrimStart([char]0xFEFF)
}

function Save-Blob {
    param([string]$Url, [string]$OutFile)
    $headers = @{ Authorization = "Bearer $(Get-AzToken $storageRes)"; 'x-ms-version' = $blobApi }
    Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
}

function Get-DeltaLogMax {
    # Highest commit version among the _delta_log blobs that start with $ListPrefix, or -1
    param([string]$BlobBase, [string]$ListPrefix)
    $max = -1; $marker = ''; $pages = 0
    do {
        $url = "$($BlobBase)?restype=container&comp=list&maxresults=5000&prefix=$([uri]::EscapeDataString($ListPrefix))"
        if ($marker) { $url += "&marker=$([uri]::EscapeDataString($marker))" }
        $x = [xml](Get-BlobText $url)
        foreach ($b in @($x.EnumerationResults.Blobs.Blob)) {
            if ($b -and $b.Name -match '(\d{20})\.json$') { $n = [long]$Matches[1]; if ($n -gt $max) { $max = $n } }
        }
        $marker = [string]$x.EnumerationResults.NextMarker
        $pages++
    } while ($marker -and $pages -lt 200)
    return $max
}

function Get-DeltaHead {
    # Latest commit version of the Delta table under $Prefix ('homeassistant/' or '' for the container root), or -1
    param([string]$BlobBase, [string]$Prefix)
    $log = "$($Prefix)_delta_log/"
    $cp  = Get-BlobText "$BlobBase/$($log)_last_checkpoint"
    $start = -1
    if ($cp) { try { $start = [long](($cp | ConvertFrom-Json).version) } catch { $start = -1 } }
    if ($start -lt 0) { return (Get-DeltaLogMax $BlobBase $log) }
    # List per block of 1000 versions (the first 17 of the 20 digits), from the checkpoint onwards
    $head  = $start
    $block = [long][math]::Floor($start / 1000)
    while ($true) {
        $m = Get-DeltaLogMax $BlobBase ($log + $block.ToString('D17'))
        if ($m -lt 0) { break }
        if ($m -gt $head) { $head = $m }
        $block++
    }
    return $head
}

function Read-DeltaCommit {
    # Parses one commit file: timestamp, added files and their statistics
    param([string]$CommitText, [string]$Entity, $Value)
    $files = New-Object System.Collections.Generic.List[object]
    $ts = $null
    foreach ($line in ($CommitText -split "`n")) {
        if (-not $line.Trim()) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.commitInfo -and $o.commitInfo.timestamp) {
            try { $ts = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$o.commitInfo.timestamp).LocalDateTime } catch { }
        }
        $a = $o.add
        if (-not $a) { continue }
        $f = [pscustomobject]@{ Path = [string]$a.path; Size = [long]$a.size; Rows = $null; HasStats = $false; InRange = $false; Min = $null }
        if ($a.stats) {
            $s = $a.stats
            if ($s -is [string]) { try { $s = $s | ConvertFrom-Json } catch { $s = $null } }
            if ($s) {
                $f.Rows = [long]$s.numRecords
                $f.Min  = $s.minValues
                $min = $s.minValues.entity_id
                $max = $s.maxValues.entity_id
                if ($null -ne $min -and $null -ne $max) {
                    $f.HasStats = $true
                    $f.InRange  = [string]::CompareOrdinal([string]$min, $Entity) -le 0 -and [string]::CompareOrdinal($Entity, [string]$max) -le 0
                    $vMin = $s.minValues.value; $vMax = $s.maxValues.value
                    if ($f.InRange -and $null -ne $Value -and $null -ne $vMin -and $null -ne $vMax) {
                        $f.InRange = ([double]$vMin -le [double]$Value) -and ([double]$Value -le [double]$vMax)
                    }
                }
            }
        }
        $files.Add($f)
    }
    $rows = 0; $known = $true
    foreach ($f in $files) { if ($null -eq $f.Rows) { $known = $false } else { $rows += $f.Rows } }
    [pscustomobject]@{
        Timestamp = $ts
        Files     = $files
        Rows      = $(if ($known) { $rows } else { $null })
        Candidate = @($files | Where-Object { $_.InRange -or -not $_.HasStats })
        HasStats  = @($files | Where-Object { $_.HasStats }).Count -gt 0
    }
}

function Get-BlobPath {
    # Delta stores paths as relative, percent-encoded URIs; turn one into an encoded blob URL path
    param([string]$Prefix, [string]$DeltaPath)
    $plain = [uri]::UnescapeDataString($DeltaPath)
    return (("$Prefix$plain" -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}
#endregion

#region Helpers: AIO broker through the mqtt-client pod
function Get-SatArgs {
    return '--cafile /var/run/certs/ca.crt -D CONNECT authentication-method K8S-SAT -D CONNECT authentication-data $(cat /var/run/secrets/tokens/broker-sat)'
}

function Initialize-MqttClient {
    # Makes sure the mqtt-client pod from the Microsoft quickstart runs and has mosquitto-clients. Returns $true if it was created.
    $created = $false
    $pod = Invoke-Native $script:kubectl @('get', 'pod', 'mqtt-client', '-n', $ns, '-o', 'name') -AllowFailure
    if ($pod.ExitCode -ne 0) {
        Invoke-Native $script:kubectl @('apply', '-f', $mqttClientUrl) | Out-Null
        $created = $true
        Write-Ok 'Deployed the mqtt-client pod (sample from the Microsoft docs)'
    }
    Invoke-Native $script:kubectl @('wait', '--for=condition=Ready', 'pod/mqtt-client', '-n', $ns, '--timeout=180s') | Out-Null
    # The sample pod installs mosquitto-clients after it starts and is already Ready by then
    $deadline = (Get-Date).AddMinutes(3)
    while ($true) {
        $chk = Invoke-Native $script:kubectl @('exec', 'mqtt-client', '-n', $ns, '--', 'sh', '-c', 'command -v mosquitto_sub') -AllowFailure
        if ($chk.ExitCode -eq 0) { break }
        if ((Get-Date) -gt $deadline) {
            throw "mosquitto_sub is still missing in the mqtt-client pod after 3 minutes. Does the cluster have internet access to dl-cdn.alpinelinux.org?"
        }
        Start-Sleep -Seconds 5
    }
    Write-Ok 'mqtt-client pod is ready'
    return $created
}

function Remove-MqttClient {
    $r = Invoke-Native $script:kubectl @('delete', '-f', $mqttClientUrl, '--ignore-not-found', '--wait=false') -AllowFailure
    if ($r.ExitCode -ne 0) {
        Invoke-Native $script:kubectl @('delete', 'pod', 'mqtt-client', '-n', $ns, '--ignore-not-found', '--wait=false') -AllowFailure | Out-Null
    }
    Write-Info 'Removed the mqtt-client pod'
}

function Send-BrokerMessage {
    # Publishes through the pod. With -Async it returns the running process instead of waiting for it.
    param([string]$Topic, [string]$Payload, [int]$Qos = 0, [switch]$Async)
    # Base64 keeps quoting out of the way of the JSON
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Payload))
    $sh   = "echo $b64 | base64 -d | mosquitto_pub --host aio-broker --port 18883 -V mqttv5 --qos $Qos --topic '$Topic' -s $(Get-SatArgs)"
    $kargs = @('exec', 'mqtt-client', '-n', $ns, '--', 'sh', '-c', $sh)
    if ($Async) { return (Start-Proc $script:kubectl $kargs) }
    Invoke-Proc $script:kubectl $kargs -TimeoutSeconds 60 | Out-Null
}

function Start-BrokerWatch {
    # mosquitto_sub in the pod, output streamed line by line as 'topic|payload'
    param([string[]]$Topics, [int]$TimeoutSeconds)
    $t  = ($Topics | ForEach-Object { "-t '$_'" }) -join ' '
    $sh = "mosquitto_sub --host aio-broker --port 18883 -V mqttv5 $(Get-SatArgs) $t -W $TimeoutSeconds -F '%t|%p'"
    $p  = Start-Proc $script:kubectl @('exec', 'mqtt-client', '-n', $ns, '--', 'sh', '-c', $sh)
    return [pscustomobject]@{
        Process  = $p
        LineTask = $p.StandardOutput.ReadLineAsync()
        ErrTask  = $p.StandardError.ReadToEndAsync()
        Eof      = $false
    }
}

function Read-WatchLine {
    # Next output line, or $null when nothing arrived within $WaitMs (check .Eof for the end of the stream)
    param($Watch, [int]$WaitMs = 250)
    if ($Watch.Eof) { Start-Sleep -Milliseconds $WaitMs; return $null }
    try {
        if (-not $Watch.LineTask.Wait($WaitMs)) { return $null }
        $line = $Watch.LineTask.Result
    } catch {
        $Watch.Eof = $true; return $null
    }
    if ($null -eq $line) { $Watch.Eof = $true; return $null }
    $Watch.LineTask = $Watch.Process.StandardOutput.ReadLineAsync()
    return $line
}

function Stop-BrokerWatch {
    param($Watch)
    if (-not $Watch) { return }
    try { if (-not $Watch.Process.HasExited) { $Watch.Process.Kill() } } catch { }
    try { $Watch.Process.Dispose() } catch { }
}
#endregion

#region Helpers: DuckDB
function ConvertTo-SqlPath {
    param([string]$Path)
    return ($Path -replace '\\', '/') -replace "'", "''"
}

function Invoke-DuckDbCsv {
    # Runs SQL that ends in COPY (...) TO '__OUT__'; returns the rows of that CSV
    param([string]$Sql, [string]$Name, [int]$TimeoutSeconds = 300)
    $sqlFile = Join-Path $script:WorkPath "$Name.sql"
    $csvFile = Join-Path $script:WorkPath "$Name.csv"
    Remove-Item -LiteralPath $csvFile -ErrorAction SilentlyContinue
    Write-TextFile $sqlFile $Sql.Replace('__OUT__', (ConvertTo-SqlPath $csvFile))
    # .read instead of -f: works in every DuckDB CLI version and returns exit code 1 on an error
    $r = Invoke-Proc $script:duckdb @('-bail', '-c', ".read '$($sqlFile -replace '\\', '/')'") -TimeoutSeconds $TimeoutSeconds -AllowFailure
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $csvFile)) {
        # Full message to a log, first line on screen
        $full = ("$($r.Error)`n$($r.Output)").Trim()
        $log  = Join-Path $script:WorkPath "$Name.error.log"
        Write-TextFile $log $full
        $first = @($full -split "`r?`n" | Where-Object { $_.Trim() })[0]
        throw "DuckDB: $first (details: $log)"
    }
    return @(Import-Csv -LiteralPath $csvFile -Encoding UTF8)
}

function Get-SummarySql {
    param($Ctx)
    $table = "abfss://$($Ctx.Container)@$($Ctx.StorageAccount).dfs.core.windows.net/$($Ctx.TablePrefix.TrimEnd('/'))"
    $sql = @'
INSTALL azure; LOAD azure;
INSTALL delta; LOAD delta;
CREATE OR REPLACE SECRET aio_demo (TYPE azure, PROVIDER credential_chain, CHAIN 'cli', ACCOUNT_NAME '__ACCOUNT__');
SET TimeZone = 'UTC';
COPY (
    SELECT friendly_name AS sensor,
           any_value(unit) AS unit,
           count(*) AS changes,
           min(value) AS min_value,
           avg(value) AS avg_value,
           max(value) AS max_value,
           epoch_ms(max(CAST(last_changed AS TIMESTAMPTZ))) AS last_ms
    FROM delta_scan('__TABLE__')
    WHERE CAST(last_changed AS TIMESTAMPTZ) > now() - INTERVAL 24 HOUR
    GROUP BY friendly_name
) TO '__OUT__' (HEADER, DELIMITER ',');
'@
    return $sql.Replace('__ACCOUNT__', $Ctx.StorageAccount).Replace('__TABLE__', $table)
}
#endregion

#region Context
function Get-DemoContext {
    Write-Step 'Checking tools and context'
    $script:az      = Resolve-Tool 'az' 'Install the Azure CLI.'
    $script:kubectl = Resolve-Tool 'kubectl' 'Install kubectl and set KUBECONFIG to the SFF cluster.'
    $script:duckdb  = Resolve-Tool 'duckdb' -Optional

    $ext = Invoke-Native $script:az @('extension', 'show', '--name', 'azure-iot-ops', '--query', 'version', '-o', 'tsv') -AllowFailure
    if ($ext.ExitCode -ne 0) { throw "The az extension 'azure-iot-ops' is missing. Run: az extension add --upgrade --name azure-iot-ops" }

    $acctArgs = @('account', 'show', '-o', 'json')
    if ($SubscriptionId) { $acctArgs += @('--subscription', $SubscriptionId) }
    $acct = Invoke-Native $script:az $acctArgs -AllowFailure
    if ($acct.ExitCode -ne 0) { throw "No az context. Run 'az login' (optionally with --tenant <tenant-id>)." }
    $acct = $acct.Output | ConvertFrom-Json
    $script:SubscriptionId = $acct.id

    $rg = $ResourceGroup
    if (-not $rg) {
        $all = @(Invoke-Az @('iot', 'ops', 'list', '-o', 'json'))
        $hit = @($all | Where-Object { $_.name -eq $Instance }) | Select-Object -First 1
        if (-not $hit -or $hit.id -notmatch '/resourceGroups/([^/]+)/') {
            throw "IoT Operations instance '$Instance' not found in subscription $($acct.name). Pass -ResourceGroup or -SubscriptionId."
        }
        $rg = $Matches[1]
    }
    Write-Ok "Instance $Instance in $rg ($($acct.name))"

    $nsCheck = Invoke-Native $script:kubectl @('get', 'namespace', $ns, '-o', 'name') -AllowFailure
    if ($nsCheck.ExitCode -ne 0) { throw "kubectl can't reach the cluster or namespace $ns. Is KUBECONFIG set to the SFF cluster?" }
    $nodes = (Invoke-Native $script:kubectl @('get', 'nodes', '-o', 'json')).Output | ConvertFrom-Json
    $node  = @($nodes.items)[0].metadata.name
    Write-Ok "kubectl reaches the cluster (node $node)"

    $df = Invoke-Az @('iot', 'ops', 'dataflow', 'show', '--resource-group', $rg, '--instance', $Instance,
        '--profile', $DataflowProfile, '--name', $DataflowName, '-o', 'json') -AllowFailure
    if (-not $df) { throw "Data flow '$DataflowName' not found in profile '$DataflowProfile'. Run Enable-AioHomeAssistantAdls.ps1 first." }
    $ops = @($df.properties.operations)
    $src = @($ops | Where-Object { $_.operationType -eq 'Source' })[0]
    $dst = @($ops | Where-Object { $_.operationType -eq 'Destination' })[0]
    $sourceFilter = [string]@($src.sourceSettings.dataSources)[0]
    $endpointName = [string]$dst.destinationSettings.endpointRef
    $container    = [string]$dst.destinationSettings.dataDestination

    $ep = Invoke-Az @('iot', 'ops', 'dataflow', 'endpoint', 'show', '--resource-group', $rg, '--instance', $Instance,
        '--name', $endpointName, '-o', 'json')
    if ($ep.properties.endpointType -ne 'DataLakeStorage') {
        throw "Endpoint '$endpointName' of data flow '$DataflowName' is $($ep.properties.endpointType), not DataLakeStorage."
    }
    $dls     = $ep.properties.dataLakeStorageSettings
    $account = ([uri]$dls.host).Host.Split('.')[0]
    $latency = 60   # service default
    if ($dls.batching -and $dls.batching.latencySeconds) { $latency = [int]$dls.batching.latencySeconds }
    Write-Ok "Data flow $DataflowName -> endpoint $endpointName ($account/$container, batching $latency s)"

    # Topic the demo entity is published on, derived from the source filter of the data flow
    $base = $sourceFilter -replace '/?#$', ''
    $demoTopic = if ($sourceFilter -match '#$' -and $base -notmatch '\+') { "$base/$DemoEntity" } else { $sourceFilter }

    return [pscustomobject]@{
        ResourceGroup  = $rg
        TenantId       = $acct.tenantId
        Node           = $node
        Dataflow       = $df
        SourceFilter   = $sourceFilter
        DemoTopic      = $demoTopic
        EndpointName   = $endpointName
        Endpoint       = $ep
        Latency        = $latency
        StorageAccount = $account
        Container      = $container
        BlobBase       = "https://$account.blob.core.windows.net/$container"
        TablePrefix    = $null
        Heads          = $null
    }
}

function Update-LakeHeads {
    # The data flow writes the Delta table into a folder named after the container; the container root as a fallback
    param($Ctx)
    $heads = [ordered]@{}
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        try {
            foreach ($p in @("$($Ctx.Container)/", '')) { $heads[$p] = Get-DeltaHead -BlobBase $Ctx.BlobBase -Prefix $p }
            break
        } catch {
            if ($_.Exception.Data['StatusCode'] -eq 403 -and (Get-Date) -lt $deadline) {
                Write-Info 'No read access to the container yet (role assignment propagating). Retrying in 20 s.'
                Start-Sleep -Seconds 20
                continue
            }
            if ($_.Exception.Data['StatusCode'] -eq 403) {
                throw "No read access to $($Ctx.BlobBase). You need Storage Blob Data Reader on the container (Enable-AioHomeAssistantAdls.ps1 grants it)."
            }
            throw
        }
    }
    $Ctx.Heads = $heads
    $Ctx.TablePrefix = $null
    foreach ($p in $heads.Keys) { if ($heads[$p] -ge 0) { $Ctx.TablePrefix = $p; break } }
}

function Get-CommitTime {
    param($Ctx, [long]$Version)
    $t = Get-BlobText ('{0}/{1}_delta_log/{2:D20}.json' -f $Ctx.BlobBase, $Ctx.TablePrefix, $Version)
    if (-not $t) { return $null }
    return (Read-DeltaCommit -CommitText $t -Entity $DemoEntity -Value $null).Timestamp
}

function Set-EndpointLatency {
    param($Ctx, [int]$Seconds)
    $props = Remove-NullProperty $Ctx.Endpoint.properties
    $clean = [ordered]@{}
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -notin @('provisioningState', 'status')) { $clean[$p.Name] = $p.Value }
    }
    $dls = $clean['dataLakeStorageSettings']
    if (-not $dls.PSObject.Properties['batching']) {
        $dls | Add-Member -NotePropertyName batching -NotePropertyValue ([pscustomobject]@{ maxMessages = 100000 })
    }
    $dls.batching | Add-Member -NotePropertyName latencySeconds -NotePropertyValue $Seconds -Force

    $file = Join-Path $script:WorkPath "endpoint-$($Ctx.EndpointName).json"
    Write-TextFile $file (([pscustomobject]$clean) | ConvertTo-Json -Depth 20)
    $r = Invoke-Native $script:az @('iot', 'ops', 'dataflow', 'endpoint', 'apply', '--resource-group', $Ctx.ResourceGroup,
        '--instance', $Instance, '--name', $Ctx.EndpointName, '--config-file', $file, '--subscription', $script:SubscriptionId,
        '--only-show-errors', '-o', 'none') -AllowFailure
    if ($r.ExitCode -ne 0) { throw "Couldn't update endpoint $($Ctx.EndpointName): $($r.Error)" }

    $deadline = (Get-Date).AddMinutes(5)
    do {
        $ep = Invoke-Az @('iot', 'ops', 'dataflow', 'endpoint', 'show', '--resource-group', $Ctx.ResourceGroup,
            '--instance', $Instance, '--name', $Ctx.EndpointName, '-o', 'json')
        $state = $ep.properties.provisioningState
        if ($state -eq 'Succeeded' -or $state -eq 'Failed') { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($state -eq 'Failed') { throw "Endpoint $($Ctx.EndpointName) is in state Failed after the update." }
    $Ctx.Endpoint = $ep
    $Ctx.Latency  = $Seconds
    Write-Ok "Endpoint $($Ctx.EndpointName): batching latency is now $Seconds s ($state)"
}

function Get-HaHeaders {
    $token = $env:HA_TOKEN
    if (-not $token) {
        $sec   = Read-Host '    Home Assistant long-lived access token' -AsSecureString
        $bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $env:HA_TOKEN = $token   # only for this session, so the next run doesn't ask again
    }
    return @{ Authorization = "Bearer $token" }
}
#endregion

#region Modes
function Invoke-Prepare {
    param($Ctx)
    $stateFile = Join-Path $script:WorkPath 'demo-state.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }

    Write-Step 'Batching latency for the demo'
    if ($state -and $state.Instance -eq $Instance) {
        Write-Info "Original latency already saved earlier: $($state.OriginalLatency) s"
    } else {
        $original = $Ctx.Latency
        if ($original -eq $DemoLatencySeconds) {
            $original = 300
            Write-Warn "The endpoint already batches at $DemoLatencySeconds s and no earlier value is saved; Restore will set 300 s."
        }
        $state = [pscustomobject]@{ Instance = $Instance; EndpointName = $Ctx.EndpointName; OriginalLatency = $original; CreatedPod = $false; PreparedAt = (Get-Date).ToString('s') }
    }
    if ($Ctx.Latency -ne $DemoLatencySeconds) { Set-EndpointLatency $Ctx $DemoLatencySeconds }
    else { Write-Ok "Endpoint already batches at $DemoLatencySeconds s" }
    Write-TextFile $stateFile ($state | ConvertTo-Json)

    Write-Step 'mqtt-client pod for watching the broker'
    if (Initialize-MqttClient) { $state.CreatedPod = $true; Write-TextFile $stateFile ($state | ConvertTo-Json) }

    Write-Step 'Delta table in the data lake'
    Update-LakeHeads $Ctx
    if ($Ctx.TablePrefix -ne $null) {
        $v = $Ctx.Heads[$Ctx.TablePrefix]
        $t = Get-CommitTime $Ctx $v
        $when = if ($t) { " written $($t.ToString('yyyy-MM-dd HH:mm:ss'))" } else { '' }
        Write-Ok "Delta table in /$($Ctx.TablePrefix) - latest commit $v$when"
    } else {
        Write-Warn 'No Delta table in the container yet. Does Home Assistant publish JSON (aio_adls.yaml) and does the bridge forward it?'
    }

    Write-Step 'DuckDB'
    if (-not $script:duckdb) {
        Write-Warn 'DuckDB CLI not found. Without it the demo shows commit statistics instead of the rows. Install: winget install DuckDB.cli'
    } else {
        $ver = Invoke-Proc $script:duckdb @('-version') -AllowFailure
        Write-Ok "DuckDB $(($ver.Output -split ' ')[0])"
        if ($Ctx.TablePrefix -ne $null) {
            Write-Info 'Warming up the azure and delta extensions and querying the last 24 hours (can take a minute the first time)...'
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $rows = Invoke-DuckDbCsv (Get-SummarySql $Ctx) 'prepare-summary'
                $n = 0; foreach ($r in $rows) { $n += [long]$r.changes }
                Write-Ok "delta_scan works: $n state changes from $($rows.Count) sensors in the last 24 hours ($(Format-Sec $sw.Elapsed.TotalSeconds))"
            } catch {
                Write-Warn "Step 4 (the 24-hour summary) won't work: $($_.Exception.Message)"
                Write-Info 'The core demo (steps 1-3 and 5) doesn''t need it. Run with -SkipSummary, or check that az login works for DuckDB.'
            }
        }
    }

    if ($HomeAssistantUrl) {
        Write-Step 'Home Assistant'
        $headers = Get-HaHeaders
        foreach ($e in @($SliderEntity, $DemoEntity)) {
            try {
                $s = Invoke-RestMethod -Uri "$($HomeAssistantUrl.TrimEnd('/'))/api/states/$e" -Headers $headers -ErrorAction Stop
                Write-Ok "$e = $($s.state) $($s.attributes.unit_of_measurement)"
            } catch {
                Write-Warn "$e not found or not reachable ($(Get-HttpStatus $_)). Is aio_demo.yaml in /config/packages and did you restart Home Assistant?"
            }
        }
    }

    Write-Host "`nReady. Give the data flow two minutes to pick up the new batching, then rehearse:" -ForegroundColor White
    Write-Host "  .\Start-AioAdlsDemo.ps1 -Instance '$Instance' -NoPause"
    Write-Host "After the demo:"
    Write-Host "  .\Start-AioAdlsDemo.ps1 -Instance '$Instance' -Mode Restore"
}

function Invoke-Restore {
    param($Ctx)
    $stateFile = Join-Path $script:WorkPath 'demo-state.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }

    Write-Step 'Batching latency'
    $target = $RestoreLatencySeconds
    if (-not $target -and $state) { $target = [int]$state.OriginalLatency }
    if (-not $target) { $target = 300; Write-Warn 'No saved original latency found; using 300 s (the default of Enable-AioHomeAssistantAdls.ps1).' }
    if ($Ctx.Latency -ne $target) { Set-EndpointLatency $Ctx $target } else { Write-Ok "Endpoint already batches at $target s" }

    if ($state -and $state.CreatedPod) {
        Write-Step 'mqtt-client pod'
        Remove-MqttClient
    }
    Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
    Write-Host "`nRestored." -ForegroundColor White
}

function Invoke-Run {
    param($Ctx)
    $result = [ordered]@{}

    #--- Step 1: the chain
    Write-Host ''
    Write-Host '  =========================================================================' -ForegroundColor DarkCyan
    Write-Host '    Home Assistant  ->  Azure IoT Operations at the edge  ->  Azure Data Lake' -ForegroundColor White
    Write-Host '  =========================================================================' -ForegroundColor DarkCyan
    Write-Stage 1 'The chain'

    $df      = $Ctx.Dataflow
    # Names and phases only; the full pod JSON of this namespace is large
    $podText = (Invoke-Native $script:kubectl @('get', 'pods', '-n', $ns, '--no-headers', '-o', 'custom-columns=NAME:.metadata.name,PHASE:.status.phase')).Output
    $dfPods  = @($podText -split "`r?`n" | ForEach-Object { $c = $_.Trim() -split '\s+'; if ($c.Count -ge 2) { [pscustomobject]@{ Name = $c[0]; Phase = $c[1] } } } |
                 Where-Object { $_.Name -like 'aio-dataflow-*' -and $_.Name -notlike '*operator*' })
    $running = @($dfPods | Where-Object { $_.Phase -eq 'Running' }).Count
    Update-LakeHeads $Ctx
    $table   = if ($null -eq $Ctx.TablePrefix) { "container $($Ctx.Container) (no table yet)" }
               elseif ($Ctx.TablePrefix) { "container $($Ctx.Container), Delta table /$($Ctx.TablePrefix.TrimEnd('/'))" }
               else { "container $($Ctx.Container), Delta table in the root" }

    Write-Host ''
    Write-Host '      [ Home Assistant ]      Mosquitto add-on; an automation publishes every state change as JSON' -ForegroundColor White
    Write-Host '              |               MQTT over TLS with an X.509 client certificate (Mosquitto bridge)' -ForegroundColor Gray
    Write-Host '              v' -ForegroundColor Gray
    Write-Host ("      [ AIO MQTT broker ]     {0} on Azure Local small form factor, node {1}" -f $Instance, $Ctx.Node) -ForegroundColor White
    Write-Host ("              |               data flow {0}: {1}" -f $DataflowName, $Ctx.SourceFilter) -ForegroundColor Gray
    Write-Host ("              v               -> Delta format, batches of at most {0} s, managed identity (no keys)" -f $Ctx.Latency) -ForegroundColor Gray
    Write-Host ("      [ Azure Data Lake ]     {0}, {1}" -f $Ctx.StorageAccount, $table) -ForegroundColor White
    Write-Host ''

    $health = [ordered]@{}
    $health['Data flow']      = "$($df.properties.mode), $($df.properties.provisioningState)" + $(if ($dfPods.Count) { ", $running/$($dfPods.Count) pods running" } else { '' })
    $health['Batching']       = "$($Ctx.Latency) s (endpoint $($Ctx.EndpointName))"
    if ($Ctx.TablePrefix -ne $null) {
        $v = $Ctx.Heads[$Ctx.TablePrefix]
        $t = Get-CommitTime $Ctx $v
        $age = ''
        if ($t) { $age = " at $($t.ToString('HH:mm:ss')) ($([int]((Get-Date) - $t).TotalMinutes) min ago)" }
        $health['Latest commit'] = "$v$age"
    }
    Write-Fields $health -Color Gray
    if ($Ctx.Latency -gt 60) {
        Write-Warn "Batching is $($Ctx.Latency) s, so step 3 can take that long. Run -Mode Prepare beforehand to bring it down."
    }
    Wait-Presenter 'step 2, change a value in Home Assistant'

    #--- Step 2: Home Assistant -> AIO broker
    $stageTitle = if ($Trigger -eq 'Synthetic') { 'Message straight on the AIO broker (plan B, bypasses Home Assistant)' } else { 'Home Assistant -> AIO MQTT broker at the edge' }
    Write-Stage 2 $stageTitle
    $pod = Invoke-Native $script:kubectl @('get', 'pod', 'mqtt-client', '-n', $ns, '-o', 'name') -AllowFailure
    if ($pod.ExitCode -ne 0) { $script:PodCreatedByRun = Initialize-MqttClient }

    # Remember where the lake stands before anything is sent
    Update-LakeHeads $Ctx
    $startHeads = [ordered]@{}
    foreach ($p in $Ctx.Heads.Keys) { $startHeads[$p] = $Ctx.Heads[$p] }

    $probeTopic = "aio-demo/probe/$(Get-Random -Minimum 100000 -Maximum 999999)"
    $waitMax    = 240
    $script:Watch = Start-BrokerWatch -Topics @($Ctx.DemoTopic, $probeTopic) -TimeoutSeconds ($waitMax + 60)
    $watch = $script:Watch

    # Confirm the subscription is live before anything changes: publish a probe until it comes back
    Write-Info "Subscribing to $($Ctx.DemoTopic) on the AIO broker..."
    $ready = $false; $nextProbe = Get-Date; $deadline = (Get-Date).AddSeconds(45)
    while (-not $ready -and (Get-Date) -lt $deadline -and -not $watch.Eof) {
        if ((Get-Date) -ge $nextProbe) { Send-BrokerMessage -Topic $probeTopic -Payload 'ready'; $nextProbe = (Get-Date).AddSeconds(3) }
        $line = Read-WatchLine $watch 250
        if ($line -and $line.StartsWith("$probeTopic|")) { $ready = $true }
    }
    if (-not $ready) {
        $err = if ($watch.ErrTask.IsCompleted) { $watch.ErrTask.Result } else { '' }
        throw "Couldn't subscribe on the AIO broker. $err"
    }
    Write-Ok 'Watching the AIO broker (subscription confirmed)'

    $expected  = $null
    $triggerAt = $null
    $pubProc   = $null
    switch ($Trigger) {
        'Manual' {
            Write-Host ''
            Write-Host "    >>> Move the demo slider ($SliderEntity) in Home Assistant now <<<" -ForegroundColor Yellow
            Write-Host ''
        }
        'HomeAssistantApi' {
            if (-not $HomeAssistantUrl) { throw '-Trigger HomeAssistantApi needs -HomeAssistantUrl.' }
            $haBase  = $HomeAssistantUrl.TrimEnd('/')
            $headers = Get-HaHeaders
            $slider  = Invoke-RestMethod -Uri "$haBase/api/states/$SliderEntity" -Headers $headers -ErrorAction Stop
            $lo = [double]$slider.attributes.min; $hi = [double]$slider.attributes.max
            $lo = [math]::Max($lo, 18.0); $hi = [math]::Min($hi, 26.0); if ($hi -le $lo) { $lo = [double]$slider.attributes.min; $hi = [double]$slider.attributes.max }
            do { $expected = [math]::Round($lo + (Get-Random -Maximum 1000) / 1000.0 * ($hi - $lo), 1) } while ($expected.ToString($inv) -eq [string]$slider.state)
            $body = '{"entity_id":"' + $SliderEntity + '","value":' + $expected.ToString($inv) + '}'
            $triggerAt = Get-Date
            Invoke-RestMethod -Method Post -Uri "$haBase/api/services/input_number/set_value" -Headers $headers -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            Write-Ok ("Set {0} to {1} {2} through the Home Assistant API" -f $SliderEntity, $expected.ToString($inv), $degC)
        }
        'Synthetic' {
            $expected = [math]::Round(18 + (Get-Random -Maximum 80) / 10.0, 1)
            $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ', $inv)
            $payload = [ordered]@{
                entity_id = $DemoEntity; domain = $DemoEntity.Split('.')[0]; friendly_name = 'AIO demo temperature'
                state = $expected.ToString($inv); value = $expected; unit = $degC; device_class = 'temperature'
                last_changed = $now; last_updated = $now
            } | ConvertTo-Json -Compress
            $triggerAt = Get-Date
            $pubProc   = Send-BrokerMessage -Topic $Ctx.DemoTopic -Payload $payload -Qos 1 -Async
            Write-Ok "Publishing a synthetic message on $($Ctx.DemoTopic) (not from Home Assistant)"
        }
    }

    # Wait for the demo entity on the broker
    $msg = $null; $waitSw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $msg -and $waitSw.Elapsed.TotalSeconds -lt $waitMax -and -not $watch.Eof) {
        $line = Read-WatchLine $watch 250
        if ($line -and -not $line.StartsWith("$probeTopic|")) {
            $parts = $line.Split([char]'|', 2)
            if ($parts.Count -eq 2) {
                $obj = $null
                try { $obj = $parts[1] | ConvertFrom-Json } catch { }
                if ($obj -and $obj.entity_id -eq $DemoEntity -and ($null -eq $expected -or [math]::Abs([double]$obj.value - $expected) -lt 1e-6)) {
                    $msg = [pscustomobject]@{ Topic = $parts[0]; Payload = $obj; Received = Get-Date }
                }
            }
        }
        if (-not $msg) { Write-Ticker ("waiting for {0} ... {1:0} s" -f $DemoEntity, $waitSw.Elapsed.TotalSeconds) }
    }
    Clear-Ticker
    Stop-BrokerWatch $watch; $script:Watch = $null
    if ($pubProc) {
        if (-not $pubProc.WaitForExit(30000)) { try { $pubProc.Kill() } catch { } }
        $pubProc.Dispose()
    }
    if (-not $msg) {
        throw "No message for $DemoEntity on the AIO broker within $waitMax s. Check the Mosquitto add-on log (bridge aio-sff), and that aio_adls.yaml publishes the sensor domain. Plan B: -Trigger Synthetic."
    }

    $data = $msg.Payload
    $changed = ConvertTo-LocalTime $data.last_changed
    Write-Ok ("Message arrived on the AIO broker at {0}" -f $msg.Received.ToString('HH:mm:ss.fff'))
    Write-Info "Topic: $($msg.Topic)"
    $fields = [ordered]@{}
    foreach ($prop in $data.PSObject.Properties) {
        $val = $prop.Value
        if ($prop.Name -in @('last_changed', 'last_updated')) {
            $lt = ConvertTo-LocalTime $prop.Value
            if ($lt) { $val = $lt.ToString('yyyy-MM-dd HH:mm:ss.fff') + ' (local)' }
        }
        $fields[$prop.Name] = $val
    }
    Write-Host ''
    Write-Fields $fields -Color White -Indent 8
    $expected = [double]$data.value

    $result['Value'] = "$(Format-Num $data.value) $($data.unit) ($DemoEntity)"
    if ($triggerAt) {
        $label = if ($Trigger -eq 'Synthetic') { 'Publish -> broker' } else { 'Home Assistant API -> broker' }
        $result[$label] = Format-Sec ($msg.Received - $triggerAt).TotalSeconds
    } elseif ($changed) {
        $hop = ($msg.Received - $changed).TotalSeconds
        if ($hop -ge 0 -and $hop -lt 60) { $result['Home Assistant -> broker'] = "~$(Format-Sec $hop) (state change in HA to arrival here)" }
    }
    Wait-Presenter 'step 3, the data lake'

    #--- Step 3: AIO broker -> Data Lake
    Write-Stage 3 'AIO data flow -> Azure Data Lake Storage Gen2 (Delta)'
    Write-Info ("The data flow collects messages for at most {0} s and then writes one Parquet file plus a Delta commit." -f $Ctx.Latency)
    $next = [ordered]@{}
    foreach ($k in $startHeads.Keys) { $next[$k] = $startHeads[$k] + 1 }
    Get-ChildItem -LiteralPath $script:WorkPath -Filter 'commit-*' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    $found = $null
    $lakeMax = [math]::Max(120, $Ctx.Latency + 180)
    $lakeSw  = [Diagnostics.Stopwatch]::StartNew()
    while (-not $found -and $lakeSw.Elapsed.TotalSeconds -lt $lakeMax) {
        foreach ($pfx in @($next.Keys)) {
            while (-not $found) {
                $url    = '{0}/{1}_delta_log/{2:D20}.json' -f $Ctx.BlobBase, $pfx, $next[$pfx]
                $commit = $null
                try { $commit = Get-BlobText $url } catch { Clear-Ticker; Write-Info "Read failed: $($_.Exception.Message)"; break }
                if (-not $commit) { break }
                $version = $next[$pfx]; $next[$pfx]++
                $info = Read-DeltaCommit -CommitText $commit -Entity $DemoEntity -Value $expected
                if ($info.Candidate.Count -eq 0) { continue }   # statistics say the message isn't in this commit

                $c = [pscustomobject]@{ Prefix = $pfx; Version = $version; Info = $info; Detected = Get-Date; Rows = @(); File = $null }
                $c.File = Split-Path ([uri]::UnescapeDataString(@($info.Candidate)[0].Path)) -Leaf
                $canVerify = [bool]$script:duckdb
                if ($canVerify) {
                    try {
                        # Download the candidate Parquet files and look for the row
                        $byLocal = @{}
                        $i = 0
                        foreach ($f in $info.Candidate) {
                            $i++
                            $out = Join-Path $script:WorkPath ("commit-{0}-{1}.parquet" -f $version, $i)
                            Save-Blob -Url "$($Ctx.BlobBase)/$(Get-BlobPath $pfx $f.Path)" -OutFile $out
                            $byLocal[($out -replace '\\', '/')] = $f.Path
                        }
                        $list = ($byLocal.Keys | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
                        $sql = @"
SET TimeZone = 'UTC';
COPY (
    SELECT entity_id, friendly_name, state, value, unit,
           epoch_ms(CAST(last_changed AS TIMESTAMPTZ)) AS last_changed_ms,
           filename
    FROM read_parquet([$list], union_by_name = true, filename = true)
    WHERE entity_id = '$DemoEntity'
) TO '__OUT__' (HEADER, DELIMITER ',');
"@
                        $rows   = Invoke-DuckDbCsv $sql "commit-$version"
                        $c.Rows = @($rows | Where-Object { $_.value -ne '' -and [math]::Abs([double]$_.value - $expected) -lt 1e-6 })
                        if ($c.Rows.Count -and $byLocal.ContainsKey([string]$c.Rows[0].filename)) {
                            $c.File = Split-Path ([uri]::UnescapeDataString($byLocal[[string]$c.Rows[0].filename])) -Leaf
                        }
                    } catch {
                        Clear-Ticker; Write-Warn "Couldn't read the Parquet file, falling back to the commit statistics: $($_.Exception.Message)"
                        $canVerify = $false
                    }
                }
                # Found: the row itself, or (without DuckDB) statistics that cover the message or the first new commit
                if ($c.Rows.Count -or -not $canVerify) { $found = $c }
            }
            if ($found) { break }
        }
        if (-not $found) {
            Write-Ticker ("waiting for the next Delta commit ... {0:0} s" -f $lakeSw.Elapsed.TotalSeconds)
            Start-Sleep -Seconds 3
        }
    }
    Clear-Ticker
    if (-not $found) {
        throw "The message didn't show up in the Delta table within $lakeMax s. Check the data flow pod: kubectl get pods -n $ns (aio-dataflow-*) and its logs."
    }

    $lakeSec = ($found.Detected - $msg.Received).TotalSeconds
    $Ctx.TablePrefix = $found.Prefix
    $info = $found.Info
    $file = $found.File
    Write-Ok ("Landed in the data lake {0} after the broker received it (Delta commit {1})" -f (Format-Sec $lakeSec), $found.Version)
    $commitFields = [ordered]@{}
    $commitFields['Table']  = "abfss://$($Ctx.Container)@$($Ctx.StorageAccount).dfs.core.windows.net/$($found.Prefix.TrimEnd('/'))"
    $commitFields['File']   = $file
    $commitFields['Batch']  = $(if ($null -ne $info.Rows) { "$($info.Rows) row(s) in $($info.Files.Count) file(s)" } else { "$($info.Files.Count) file(s)" })
    if ($info.Timestamp) { $commitFields['Commit written'] = $info.Timestamp.ToString('HH:mm:ss.fff') + ' (clock of the data flow)' }
    Write-Fields $commitFields -Color Gray

    if ($found.Rows.Count) {
        Write-Host ''
        Write-Host '        The row, read straight from that Parquet file with DuckDB:' -ForegroundColor White
        $view = foreach ($r in $found.Rows) {
            [pscustomobject]@{
                entity_id     = $r.entity_id
                friendly_name = $r.friendly_name
                value         = Format-Num $r.value
                unit          = $r.unit
                last_changed  = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$r.last_changed_ms).LocalDateTime.ToString('HH:mm:ss.fff')
            }
        }
        $tableText = ($view | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
        foreach ($l in ($tableText -split "`r?`n")) { if ($l.Trim()) { Write-Host "        $l" -ForegroundColor White } }
        Write-Host ''
        $origin = if ($Trigger -eq 'Synthetic') { 'in the published message' } else { 'in Home Assistant' }
        Write-Ok ("Same value end to end: {0} {1} {2}, on the broker and in the data lake" -f (Format-Num $expected), $data.unit, $origin)
    } elseif ($info.HasStats) {
        $one = @($info.Candidate | Where-Object { $_.Rows -eq 1 })[0]
        if ($one) {
            Write-Host ''
            Write-Host '        The row, from the Delta statistics (the batch holds only this message):' -ForegroundColor White
            $sf = [ordered]@{}
            foreach ($prop in $one.Min.PSObject.Properties) { $sf[$prop.Name] = $prop.Value }
            Write-Fields $sf -Color White -Indent 8
        } else {
            Write-Info "The statistics of this commit cover $DemoEntity with value $(Format-Num $expected). Install DuckDB to show the row itself."
        }
    } else {
        Write-Warn 'First new commit after the message; this table has no statistics and DuckDB is missing, so the row itself isn''t verified.'
    }

    $result['Broker -> data lake'] = "$(Format-Sec $lakeSec) (batching window $($Ctx.Latency) s)"
    if ($changed) {
        $total = ($found.Detected - $changed).TotalSeconds
        $from = if ($Trigger -eq 'Synthetic') { 'message created' } else { 'state change in Home Assistant' }
        if ($total -ge 0 -and $total -lt 3600) { $result['End to end'] = "~$(Format-Sec $total) ($from to visible in the lake)" }
    }
    $result['Delta commit'] = "$($found.Version), $file"

    #--- Step 4: what you can do with it
    if (-not $SkipSummary -and $script:duckdb) {
        Wait-Presenter 'step 4, query the data lake'
        Write-Stage 4 'Query the data lake directly: last 24 hours per sensor (DuckDB, no cluster)'
        Write-Info 'DuckDB reads the Delta table in the storage account with your az login.'
        try {
            $qs = [Diagnostics.Stopwatch]::StartNew()
            $rows = Invoke-DuckDbCsv (Get-SummarySql $Ctx) 'summary'
            $total = 0; foreach ($r in $rows) { $total += [long]$r.changes }
            $view = $rows | Sort-Object { [long]$_.changes } -Descending | Select-Object -First 12 | ForEach-Object {
                [pscustomobject]@{
                    sensor  = $(if ("$($_.sensor)".Length -gt 34) { "$($_.sensor)".Substring(0, 33) + '~' } else { $_.sensor })
                    changes = [long]$_.changes
                    min     = Format-Num $_.min_value
                    avg     = $(if ($_.avg_value -ne '') { ([double]$_.avg_value).ToString('0.0', $inv) } else { '' })
                    max     = Format-Num $_.max_value
                    unit    = $_.unit
                    last    = $(if ($_.last_ms) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.last_ms).LocalDateTime.ToString('HH:mm:ss') } else { '' })
                }
            }
            Write-Host ''
            $tableText = ($view | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
            foreach ($l in ($tableText -split "`r?`n")) { if ($l.Trim()) { Write-Host "        $l" -ForegroundColor White } }
            Write-Host ''
            Write-Ok ("{0} state changes from {1} sensors in the last 24 hours, queried in {2}" -f $total, $rows.Count, (Format-Sec $qs.Elapsed.TotalSeconds))
        } catch {
            Write-Warn "Summary query failed: $($_.Exception.Message)"
        }
    }

    #--- Step 5: summary
    Wait-Presenter 'the summary'
    Write-Stage 5 'Summary'
    Write-Host ''
    Write-Fields $result -Color White
    $saId = $null
    $res  = Invoke-Az @('resource', 'list', '--name', $Ctx.StorageAccount, '--resource-type', 'Microsoft.Storage/storageAccounts', '-o', 'json') -AllowFailure
    if ($res) { $saId = @($res)[0].id }
    Write-Host ''
    Write-Host '      Azure portal' -ForegroundColor White
    if ($saId) {
        Write-Host "        https://portal.azure.com/#@$($Ctx.TenantId)/resource$saId/overview" -ForegroundColor Gray
        Write-Host "        -> Storage browser > Blob containers > $($Ctx.Container) > $($Ctx.TablePrefix)" -ForegroundColor Gray
        if ($saId -match '/resourceGroups/([^/]+)/') { Write-Host "        -> Costs: resource group $($Matches[1]) > Cost analysis" -ForegroundColor Gray }
    } else {
        Write-Host "        Storage account $($Ctx.StorageAccount) > Storage browser > Blob containers > $($Ctx.Container)" -ForegroundColor Gray
    }
    if ($Ctx.Latency -lt 60) {
        Write-Host "`n      After the demo: .\Start-AioAdlsDemo.ps1 -Instance '$Instance' -Mode Restore" -ForegroundColor Yellow
    }
}
#endregion

try {
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $script:WorkPath = (Resolve-Path -LiteralPath $OutputPath).Path
    Write-TextFile (Join-Path $script:WorkPath '.gitignore') "*`n"

    $ctx = Get-DemoContext
    switch ($Mode) {
        'Prepare' { Invoke-Prepare $ctx }
        'Restore' { Invoke-Restore $ctx }
        'Run'     { Invoke-Run $ctx }
    }
    exit 0
}
catch {
    Clear-Ticker
    Write-Host "`n[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Stop-BrokerWatch $script:Watch
    if ($script:PodCreatedByRun) { Remove-MqttClient }
}
