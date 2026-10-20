<#
.SYNOPSIS
    Zet een extern MQTT-endpoint (TLS + X.509) op de Azure IoT Operations broker voor Home Assistant: via een
    Mosquitto-bridge (standaard) of rechtstreeks vanuit de MQTT-integratie.

.DESCRIPTION
    Regelt de broker-kant van een Home Assistant-koppeling met de AIO MQTT broker op Azure Local SFF (K3s):
      1. Maakt een eigen client-CA en een clientcertificaat voor Home Assistant (EC P-256, via openssl).
         Bestaande bestanden in -OutputPath worden hergebruikt, zodat een tweede run niets breekt.
      2. Zet de client-CA als ConfigMap in de namespace azure-iot-operations.
      3. Maakt een BrokerAuthentication-policy met X.509 die alleen die CA vertrouwt.
      4. Maakt de LoadBalancer-listener met een TLS-poort (automatisch servercertificaat via de AIO-issuer),
         met het IP en de hostnaam van de SFF-node als SAN. Bestaat er al een LoadBalancer-listener,
         dan wordt de poort daaraan toegevoegd (AIO staat maar één listener per service type toe).
      5. Wacht op het externe IP, exporteert de AIO root-CA (trust bundle) en test de verbinding zoals
         de client dat doet: TLS met servervalidatie, clientcertificaat en een echte MQTT v5 CONNECT.
      6. Met -Target MosquittoBridge (standaard): schrijft bridge-aio.conf voor de Mosquitto add-on van
         Home Assistant, zodat Home Assistant zijn eigen broker houdt en alleen gekozen topics doorzet.
         Met -Target HomeAssistant: toont de instellingen voor de MQTT-integratie zelf.

    De default listener (18883, ClusterIp) blijft onaangeroerd. Authenticatie- en listenerconfiguratie gaan via
    'az iot ops' (de ondersteunde route), alleen de ConfigMap gaat via kubectl.

    Vereist: az CLI met de azure-iot-ops extensie (ingelogd), kubectl met een kubeconfig naar de K3s-cluster,
    en openssl (zit bij Git for Windows). Werkt in Windows PowerShell 5.1 en PowerShell 7.
    Exit code 1 bij een fout, anders 0.

.PARAMETER ResourceGroup
    Resource group van de Azure IoT Operations-instance.

.PARAMETER Instance
    Naam van de Azure IoT Operations-instance ('az iot ops list -o table').

.PARAMETER BrokerIp
    IP waarop Home Assistant de broker benadert. Standaard het InternalIP van de (eerste) K3s-node;
    met de ingebouwde K3s ServiceLB is dat ook het externe IP van de LoadBalancer-service.

.PARAMETER DnsName
    Hostnaam die in het servercertificaat komt. Standaard de nodenaam.

.PARAMETER Port
    TLS-poort voor externe clients. Standaard 8883. Mag niet 18883 zijn (default listener).

.PARAMETER ListenerName
    Naam van de nieuwe LoadBalancer-listener (wordt ook de servicenaam). Genegeerd als er al een
    LoadBalancer-listener bestaat.

.PARAMETER AuthnName
    Naam van de BrokerAuthentication-policy.

.PARAMETER ClientCaConfigMap
    Naam van de ConfigMap met de client-CA (alleen kleine letters, cijfers en '-').

.PARAMETER Target
    MosquittoBridge (standaard): je houdt de broker in Home Assistant en koppelt die via een bridge aan AIO.
    HomeAssistant: de MQTT-integratie van Home Assistant praat direct met AIO (vervangt je huidige broker).

.PARAMETER ClientName
    CN van het clientcertificaat en basis van de bestandsnamen. Standaard 'mosquitto-bridge' of 'home-assistant',
    afhankelijk van -Target. Bij een bridge is dit ook de remote client ID.

.PARAMETER BridgeAddress
    Adres waarmee Mosquitto de AIO-broker benadert. Standaard het externe IP van de service.

.PARAMETER OutTopic
    Topicfilter dat van Home Assistant naar AIO gaat. Standaard homeassistant/statestream/# (mqtt_statestream).

.PARAMETER InTopic
    Topicfilter dat van AIO naar Home Assistant gaat. Standaard aio/to-ha/#. Mag niet overlappen met -OutTopic.

.PARAMETER OutputPath
    Map voor certificaten, sleutels en configbestanden. Er komt een .gitignore in die alles uitsluit.

.PARAMETER ValidityDays
    Geldigheid van het clientcertificaat in dagen. De client-CA is 10 jaar geldig.

.EXAMPLE
    .\Enable-AioHomeAssistantMqtt.ps1 -ResourceGroup 'rg-sff-lab' -Instance 'aio-sff'

    Bridge-scenario: maakt alles aan en schrijft ha-mqtt-certs\bridge-aio.conf.

.EXAMPLE
    .\Enable-AioHomeAssistantMqtt.ps1 -ResourceGroup 'rg-sff-lab' -Instance 'aio-sff' -Target HomeAssistant

.EXAMPLE
    .\Enable-AioHomeAssistantMqtt.ps1 -ResourceGroup 'rg-sff-lab' -Instance 'aio-sff' -BrokerIp '192.168.1.50' -DnsName 'linuxsff-vm.lan'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Instance,
    [string]$BrokerIp,
    [string]$DnsName,
    [ValidateRange(1, 65535)][int]$Port = 8883,
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$ListenerName = 'aio-broker-external',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$AuthnName = 'ha-x509',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$ClientCaConfigMap = 'ha-client-ca',
    [ValidateSet('MosquittoBridge', 'HomeAssistant')][string]$Target = 'MosquittoBridge',
    [ValidatePattern('^[A-Za-z0-9._-]*$')][string]$ClientName,
    [string]$BridgeAddress,
    [ValidatePattern('^[^\s]+$')][string]$OutTopic = 'homeassistant/statestream/#',
    [ValidatePattern('^[^\s]+$')][string]$InTopic = 'aio/to-ha/#',
    [string]$OutputPath = (Join-Path (Get-Location) 'ha-mqtt-certs'),
    [ValidateRange(1, 3650)][int]$ValidityDays = 825
)

$ErrorActionPreference = 'Stop'
$ns     = 'azure-iot-operations'
if (-not $ClientName) { $ClientName = if ($Target -eq 'MosquittoBridge') { 'mosquitto-bridge' } else { 'home-assistant' } }
$issuer = [ordered]@{ name = 'azure-iot-operations-aio-certificate-issuer'; kind = 'ClusterIssuer'; group = 'cert-manager.io' }

#region Helpers
function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    [OK]   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    [WARN] $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "           $Text" -ForegroundColor Gray }

function Resolve-Tool {
    param([string]$Name, [string[]]$Fallback = @(), [string]$Hint)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in $Fallback) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
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

function Write-TextFile {
    # UTF-8 zonder BOM: openssl, kubectl en az lezen dat overal goed
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding $false))
}

function Remove-NullProperty {
    # Haalt null-waarden recursief weg uit objecten die via ConvertFrom-Json binnenkomen
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { Remove-NullProperty $_ })
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

function Test-MqttConnect {
    # Doet wat Home Assistant doet: TLS met servervalidatie (AIO-CA + IP in SAN), clientcertificaat aanbieden,
    # MQTT v5 CONNECT sturen en de CONNACK lezen. Een openssl s_client-test zegt bij TLS 1.3 niets over het
    # clientcertificaat (de server weigert dat pas na de handshake), daarom een echte CONNECT.
    param([string]$HostIp, [int]$TcpPort, [string]$CaFile, [string]$PfxFile, [string]$PfxPassword, [string]$ClientId)

    $X509 = 'System.Security.Cryptography.X509Certificates'
    $ca      = New-Object "$X509.X509Certificate2" -ArgumentList $CaFile
    $cliCert = New-Object "$X509.X509Certificate2" -ArgumentList $PfxFile, $PfxPassword
    $certs   = New-Object "$X509.X509CertificateCollection"
    [void]$certs.Add($cliCert)
    $state = @{ Reason = $null }

    $validate = [System.Net.Security.RemoteCertificateValidationCallback] {
        param($sender, $certificate, $chain, $sslErrors)
        $server = New-Object "$X509.X509Certificate2" -ArgumentList (, $certificate.GetRawCertData())
        $c = New-Object "$X509.X509Chain"
        $c.ChainPolicy.RevocationMode    = 'NoCheck'
        $c.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
        [void]$c.ChainPolicy.ExtraStore.Add($ca)
        [void]$c.Build($server)
        $root = $c.ChainElements[$c.ChainElements.Count - 1].Certificate
        if ($root.Thumbprint -ne $ca.Thumbprint) {
            $state.Reason = "servercertificaat ($($server.Subject)) is niet uitgegeven door de AIO-CA"; return $false
        }
        $san = $server.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) }
        if ("$san" -notmatch "(^|[^0-9.])$([regex]::Escape($HostIp))([^0-9.]|$)") {
            $state.Reason = "IP $HostIp staat niet in de SAN van het servercertificaat ($san)"; return $false
        }
        return $true
    }
    $select = [System.Net.Security.LocalCertificateSelectionCallback] {
        param($sender, $targetHost, $localCerts, $remoteCert, $acceptableIssuers)
        return $cliCert
    }

    $tcp = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    try {
        if (-not $tcp.ConnectAsync($HostIp, $TcpPort).Wait(5000)) { throw 'TCP-verbinding time-out' }
        $ssl = New-Object System.Net.Security.SslStream -ArgumentList $tcp.GetStream(), $false, $validate, $select
        $ssl.ReadTimeout = 10000; $ssl.WriteTimeout = 10000
        try {
            $ssl.AuthenticateAsClient($HostIp, $certs, [System.Security.Authentication.SslProtocols]::None, $false)
        } catch {
            $msg = if ($state.Reason) { $state.Reason } else { $_.Exception.GetBaseException().Message }
            return [pscustomobject]@{ Success = $false; Detail = "TLS-handshake mislukt: $msg" }
        }

        # MQTT v5 CONNECT: clean start, keep-alive 60 s, geen properties, alleen een client ID
        $id   = [Text.Encoding]::UTF8.GetBytes($ClientId)
        $body = New-Object System.Collections.Generic.List[byte]
        $body.AddRange([byte[]](0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x05, 0x02, 0x00, 0x3C, 0x00))
        $body.AddRange([byte[]]([byte]($id.Length -shr 8), [byte]($id.Length -band 0xFF)))
        $body.AddRange($id)
        $packet = New-Object System.Collections.Generic.List[byte]
        $packet.Add(0x10)
        $len = $body.Count
        do { $b = $len -band 0x7F; $len = $len -shr 7; if ($len -gt 0) { $b = $b -bor 0x80 }; $packet.Add([byte]$b) } while ($len -gt 0)
        $packet.AddRange($body)
        $ssl.Write($packet.ToArray(), 0, $packet.Count); $ssl.Flush()

        $buf  = New-Object byte[] 64
        $read = 0
        while ($read -lt 4) {
            $n = $ssl.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt 4 -or $buf[0] -ne 0x20) {
            return [pscustomobject]@{ Success = $false; Detail = 'Broker sloot de verbinding zonder CONNACK (clientcertificaat of authenticatie geweigerd?)' }
        }
        $reason = $buf[3]
        try { $ssl.Write([byte[]](0xE0, 0x00), 0, 2) } catch { }   # DISCONNECT
        if ($reason -eq 0) { return [pscustomobject]@{ Success = $true; Detail = 'CONNACK: Success' } }
        $names = @{ 0x86 = 'Bad user name or password'; 0x87 = 'Not authorized'; 0x8C = 'Bad authentication method'; 0x84 = 'Unsupported protocol version' }
        $name  = if ($names.ContainsKey([int]$reason)) { $names[[int]$reason] } else { 'zie MQTT v5 reason codes' }
        return [pscustomobject]@{ Success = $false; Detail = ('CONNACK reason 0x{0:X2} ({1})' -f $reason, $name) }
    } catch {
        $msg = $_.Exception.GetBaseException().Message
        return [pscustomobject]@{ Success = $false; Detail = "Verbinding verbroken: $msg (clientcertificaat geweigerd?)" }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        $tcp.Dispose()
        $cliCert.Reset()
    }
}

function Test-TcpPort {
    param([string]$HostName, [int]$TcpPort, [int]$TimeoutMs = 5000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $TcpPort)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}
#endregion

try {
    #region 0. Context en tools
    Write-Host "`nAzure IoT Operations - extern MQTT-endpoint voor Home Assistant" -ForegroundColor White

    Write-Step 'Tools en context controleren'
    $kubectl = Resolve-Tool 'kubectl' -Hint 'Installeer kubectl en zet de kubeconfig van de SFF-cluster klaar.'
    $az      = Resolve-Tool 'az' -Hint 'Installeer de Azure CLI.'
    $openssl = Resolve-Tool 'openssl' -Fallback @(
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe' })
    ) -Hint 'Installeer Git for Windows (bevat openssl) of zet openssl in je PATH.'
    Write-Ok "openssl: $openssl"

    if ($Port -eq 18883) { throw 'Poort 18883 is van de default listener. Kies een andere poort.' }
    if ($Target -eq 'MosquittoBridge') {
        # In- en uitgaande topics mogen elkaar niet raken, anders pingen berichten eindeloos heen en weer
        $outRoot = $OutTopic -replace '/?[#+].*$', ''
        $inRoot  = $InTopic  -replace '/?[#+].*$', ''
        if (-not $outRoot -or -not $inRoot -or $outRoot -eq $inRoot -or
            $outRoot.StartsWith("$inRoot/") -or $inRoot.StartsWith("$outRoot/")) {
            throw "-OutTopic '$OutTopic' en -InTopic '$InTopic' overlappen; dat geeft een berichtenlus in de bridge."
        }
    }

    Invoke-Native $kubectl @('get', 'namespace', $ns, '-o', 'name') | Out-Null
    Write-Ok "kubectl bereikt de cluster, namespace $ns bestaat"

    $ext = Invoke-Native $az @('extension', 'show', '--name', 'azure-iot-ops', '--query', 'version', '-o', 'tsv') -AllowFailure
    if ($ext.ExitCode -ne 0) { throw "De az-extensie 'azure-iot-ops' ontbreekt. Draai: az extension add --upgrade --name azure-iot-ops" }
    Write-Ok "azure-iot-ops extensie $($ext.Output.Trim())"

    Invoke-Native $az @('iot', 'ops', 'show', '--resource-group', $ResourceGroup, '--name', $Instance, '-o', 'none') | Out-Null
    Write-Ok "IoT Operations-instance $Instance gevonden in $ResourceGroup"

    $nodes = (Invoke-Native $kubectl @('get', 'nodes', '-o', 'json')).Output | ConvertFrom-Json
    $node  = @($nodes.items)[0]
    if (-not $DnsName)  { $DnsName = $node.metadata.name }
    if (-not $BrokerIp) { $BrokerIp = @($node.status.addresses | Where-Object { $_.type -eq 'InternalIP' })[0].address }
    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$BrokerIp, [ref]$parsedIp)) {
        throw "Kon geen geldig broker-IP bepalen ('$BrokerIp'). Geef -BrokerIp op."
    }
    Write-Ok "Broker-adres: $BrokerIp ($DnsName), poort $Port"
    #endregion

    #region 1. Client-CA en clientcertificaat
    Write-Step 'Client-CA en clientcertificaat voor Home Assistant'
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    # Sleutels horen nooit in Git (de map staat mogelijk in de blog-repo)
    Write-TextFile (Join-Path $OutputPath '.gitignore') "*`n"

    $cnf    = Join-Path $OutputPath 'openssl-ha.cnf'
    $caKey  = Join-Path $OutputPath 'ha-client-ca.key'
    $caCrt  = Join-Path $OutputPath 'ha-client-ca.crt'
    $cliKey = Join-Path $OutputPath "$ClientName.key"
    $cliCsr = Join-Path $OutputPath "$ClientName.csr"
    $cliCrt = Join-Path $OutputPath "$ClientName.crt"
    $aioCa  = Join-Path $OutputPath 'aio-broker-ca.crt'

    Write-TextFile $cnf @'
[ req ]
distinguished_name = req_dn
prompt             = no

[ req_dn ]
CN = placeholder

[ v3_ca ]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash

[ v3_client ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid, issuer
'@

    if ((Test-Path -LiteralPath $caKey) -and (Test-Path -LiteralPath $caCrt)) {
        Write-Ok 'Bestaande client-CA hergebruikt'
    } else {
        Invoke-Native $openssl @('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', $caKey) | Out-Null
        Invoke-Native $openssl @('req', '-x509', '-new', '-key', $caKey, '-sha256', '-days', '3650',
            '-subj', '/CN=Home Assistant MQTT Client CA', '-config', $cnf, '-extensions', 'v3_ca', '-out', $caCrt) | Out-Null
        Write-Ok "Client-CA aangemaakt: $caCrt"
    }

    if ((Test-Path -LiteralPath $cliKey) -and (Test-Path -LiteralPath $cliCrt)) {
        Write-Ok "Bestaand clientcertificaat hergebruikt ($ClientName)"
    } else {
        Invoke-Native $openssl @('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', $cliKey) | Out-Null
        Invoke-Native $openssl @('req', '-new', '-key', $cliKey, '-subj', "/CN=$ClientName", '-config', $cnf, '-out', $cliCsr) | Out-Null
        Invoke-Native $openssl @('x509', '-req', '-in', $cliCsr, '-CA', $caCrt, '-CAkey', $caKey, '-CAcreateserial',
            '-days', "$ValidityDays", '-sha256', '-extfile', $cnf, '-extensions', 'v3_client', '-out', $cliCrt) | Out-Null
        Remove-Item -LiteralPath $cliCsr -ErrorAction SilentlyContinue
        Write-Ok "Clientcertificaat aangemaakt: $cliCrt (CN=$ClientName, $ValidityDays dagen)"
    }
    Invoke-Native $openssl @('verify', '-CAfile', $caCrt, $cliCrt) | Out-Null
    Write-Ok 'Keten client-CA -> clientcertificaat klopt'
    #endregion

    #region 2. ConfigMap met de client-CA
    Write-Step "ConfigMap $ClientCaConfigMap in $ns"
    $cmYaml = (Invoke-Native $kubectl @('create', 'configmap', $ClientCaConfigMap, '-n', $ns,
        "--from-file=client_ca.pem=$caCrt", '--dry-run=client', '-o', 'yaml')).Output
    $cmFile = Join-Path $OutputPath "configmap-$ClientCaConfigMap.yaml"
    Write-TextFile $cmFile $cmYaml
    Invoke-Native $kubectl @('apply', '-f', $cmFile) | Out-Null
    Write-Ok 'ConfigMap toegepast'
    #endregion

    #region 3. BrokerAuthentication (X.509)
    Write-Step "Authenticatiepolicy $AuthnName (X.509)"
    $authnConfig = [ordered]@{
        authenticationMethods = @(
            [ordered]@{ method = 'X509'; x509Settings = [ordered]@{ trustedClientCaCert = $ClientCaConfigMap } }
        )
    }
    $authnFile = Join-Path $OutputPath "authn-$AuthnName.json"
    Write-TextFile $authnFile ($authnConfig | ConvertTo-Json -Depth 10)
    Invoke-Native $az @('iot', 'ops', 'broker', 'authn', 'apply', '--resource-group', $ResourceGroup, '--instance', $Instance,
        '--broker', 'default', '--name', $AuthnName, '--config-file', $authnFile, '-o', 'none') | Out-Null
    Write-Ok 'Authenticatiepolicy toegepast'
    #endregion

    #region 4. LoadBalancer-listener met TLS-poort
    Write-Step 'LoadBalancer-listener'
    $tlsPort = [ordered]@{
        port              = $Port
        protocol          = 'Mqtt'
        authenticationRef = $AuthnName
        tls               = [ordered]@{
            mode                       = 'Automatic'
            certManagerCertificateSpec = [ordered]@{
                issuerRef = $issuer
                san       = [ordered]@{ dns = @($DnsName); ip = @($BrokerIp) }
            }
        }
    }

    # Twee stappen: in PS 5.1 levert ConvertFrom-Json een JSON-array als één object in de pipeline
    $rawListeners = (Invoke-Native $az @('iot', 'ops', 'broker', 'listener', 'list', '--resource-group', $ResourceGroup,
        '--instance', $Instance, '--broker', 'default', '-o', 'json')).Output | ConvertFrom-Json
    $listeners = @($rawListeners)

    # Poortconflict met een andere listener?
    $lbListener = @($listeners | Where-Object { $_.properties.serviceType -eq 'LoadBalancer' }) | Select-Object -First 1
    foreach ($l in $listeners) {
        if ($lbListener -and $l.name -eq $lbListener.name) { continue }
        if (@($l.properties.ports | ForEach-Object { $_.port }) -contains $Port) {
            throw "Poort $Port is al in gebruik door listener '$($l.name)'. Kies een andere poort met -Port."
        }
    }

    $serviceName = $null
    if ($lbListener) {
        $ListenerName = $lbListener.name
        $serviceName  = $lbListener.properties.serviceName
        $keep  = @($lbListener.properties.ports | Where-Object { $_.port -ne $Port } | ForEach-Object { Remove-NullProperty $_ })
        $ports = @($keep) + @([pscustomobject]$tlsPort)
        Write-Warn "Er bestaat al een LoadBalancer-listener '$ListenerName'; poort $Port wordt daaraan toegevoegd (bestaande poorten blijven: $(@($keep | ForEach-Object { $_.port }) -join ', '))."
    } else {
        $ports = @([pscustomobject]$tlsPort)
    }

    $listenerConfig = [ordered]@{ serviceType = 'LoadBalancer'; ports = $ports }
    if ($serviceName) { $listenerConfig.serviceName = $serviceName }
    $listenerFile = Join-Path $OutputPath "listener-$ListenerName.json"
    Write-TextFile $listenerFile ($listenerConfig | ConvertTo-Json -Depth 10)
    Invoke-Native $az @('iot', 'ops', 'broker', 'listener', 'apply', '--resource-group', $ResourceGroup, '--instance', $Instance,
        '--broker', 'default', '--name', $ListenerName, '--config-file', $listenerFile, '-o', 'none') | Out-Null
    Write-Ok "Listener '$ListenerName' toegepast met TLS-poort $Port"
    #endregion

    #region 5. Service, trust bundle en TLS-test
    Write-Step 'Wachten op de LoadBalancer-service'
    $svcName  = if ($serviceName) { $serviceName } else { $ListenerName }
    $deadline = (Get-Date).AddMinutes(5)
    $extIp    = $null
    do {
        $r = Invoke-Native $kubectl @('get', 'service', $svcName, '-n', $ns, '-o', 'json') -AllowFailure
        if ($r.ExitCode -eq 0) {
            $svc    = $r.Output | ConvertFrom-Json
            $hasPort = @($svc.spec.ports | ForEach-Object { $_.port }) -contains $Port
            $extIp  = @($svc.status.loadBalancer.ingress | Where-Object { $_.ip } | ForEach-Object { $_.ip }) | Select-Object -First 1
            if ($hasPort -and $extIp) { break }
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    if (-not $extIp) {
        Write-Warn "Service '$svcName' heeft na 5 minuten geen extern IP. Staat de K3s ServiceLB uit (--disable servicelb)?"
        Write-Info "Controleer: kubectl get svc $svcName -n $ns  en  kubectl get pods -A -l svccontroller.k3s.cattle.io/svcname=$svcName"
    } else {
        Write-Ok "Service '$svcName' luistert op ${extIp}:$Port"
        if ($extIp -ne $BrokerIp) {
            Write-Warn "Extern IP ($extIp) wijkt af van het IP in het servercertificaat ($BrokerIp). Draai opnieuw met -BrokerIp $extIp."
        }
    }

    Write-Step 'AIO root-CA (trust bundle) exporteren'
    $bundle = (Invoke-Native $kubectl @('get', 'configmap', 'azure-iot-operations-aio-ca-trust-bundle', '-n', $ns, '-o', 'json')).Output | ConvertFrom-Json
    $caPem  = $bundle.data.'ca.crt'
    if (-not $caPem) { throw "Geen 'ca.crt' gevonden in de ConfigMap azure-iot-operations-aio-ca-trust-bundle." }
    Write-TextFile $aioCa $caPem
    Write-Ok "Opgeslagen: $aioCa"

    Write-Step 'Verbinding testen zoals Home Assistant (TLS + clientcertificaat + MQTT CONNECT)'
    $testIp = if ($extIp) { $extIp } else { $BrokerIp }
    if (-not (Test-TcpPort -HostName $testIp -TcpPort $Port)) {
        Write-Warn "Geen TCP-verbinding met ${testIp}:$Port. Check een firewall op de SFF-host of tussen je netwerken."
    } else {
        # Tijdelijke PFX alleen voor deze test (3DES/SHA1 zodat ook .NET Framework 4.x hem kan lezen)
        $pfx    = Join-Path $OutputPath "$ClientName-test.pfx"
        $pfxPwd = [guid]::NewGuid().ToString('N')
        try {
            Invoke-Native $openssl @('pkcs12', '-export', '-inkey', $cliKey, '-in', $cliCrt, '-out', $pfx, '-passout', "pass:$pfxPwd",
                '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1') | Out-Null
            # Eigen client ID, zodat een al verbonden Home Assistant niet wordt afgemeld
            $testId = "$ClientName-test-$(Get-Random -Maximum 99999)"
            $mqtt   = $null
            for ($i = 1; $i -le 6; $i++) {
                $mqtt = Test-MqttConnect -HostIp $testIp -TcpPort $Port -CaFile $aioCa -PfxFile $pfx -PfxPassword $pfxPwd -ClientId $testId
                if ($mqtt.Success) { break }
                if ($i -lt 6) { Write-Info "Poging ${i}: $($mqtt.Detail) - opnieuw over 15 s"; Start-Sleep -Seconds 15 }
            }
        } finally {
            Remove-Item -LiteralPath $pfx -ErrorAction SilentlyContinue
        }
        if ($mqtt.Success) {
            Write-Ok "MQTT CONNECT als '$testId' geslaagd: servercertificaat klopt voor $testIp en het clientcertificaat wordt geaccepteerd"
        } else {
            Write-Warn "Test mislukt: $($mqtt.Detail)"
            Write-Info "Zoek de frontend-pods met 'kubectl get pods -n $ns' (aio-broker-frontend-*) en bekijk hun logs."
        }
    }
    #endregion

    #region Samenvatting
    if ($Target -eq 'MosquittoBridge') {
        $address = if ($BridgeAddress) { $BridgeAddress } else { $testIp }
        $confFile = Join-Path $OutputPath 'bridge-aio.conf'
        $conf = @"
# Bridge van de Mosquitto-broker in Home Assistant naar de Azure IoT Operations MQTT broker.
# Gegenereerd door Enable-AioHomeAssistantMqtt.ps1 op $(Get-Date -Format 'yyyy-MM-dd HH:mm').
# Plaats in /share/mosquitto/ en de certificaten in /share/mosquitto/certs/.

connection aio-sff
address ${address}:$Port
remote_clientid $ClientName
bridge_protocol_version mqttv311
# AIO herkent de Mosquitto-specifieke bridge-vlag niet
try_private false
cleansession true
start_type automatic
restart_timeout 10 60
keepalive_interval 60
# Bridge-status alleen lokaal publiceren (`$SYS hoort niet op AIO)
notifications true
notifications_local_only true

bridge_cafile   /share/mosquitto/certs/aio-broker-ca.crt
bridge_certfile /share/mosquitto/certs/$ClientName.crt
bridge_keyfile  /share/mosquitto/certs/$ClientName.key
bridge_insecure false

# Home Assistant -> AIO (QoS 1; AIO ondersteunt geen QoS 2)
topic $OutTopic out 1
# AIO -> Home Assistant
topic $InTopic in 1
"@
        Write-TextFile $confFile (($conf -replace "`r`n", "`n") + "`n")
        Write-Host "`nMosquitto-bridge in Home Assistant" -ForegroundColor White
        Write-Host  "  1. Kopieer naar de share van Home Assistant (Samba of SSH):"
        Write-Host ("       {0,-48} -> /share/mosquitto/bridge-aio.conf" -f (Split-Path $confFile -Leaf))
        Write-Host ("       {0,-48} -> /share/mosquitto/certs/" -f 'aio-broker-ca.crt')
        Write-Host ("       {0,-48} -> /share/mosquitto/certs/" -f "$ClientName.crt")
        Write-Host ("       {0,-48} -> /share/mosquitto/certs/" -f "$ClientName.key")
        Write-Host  "  2. Mosquitto broker add-on > Configuratie:  customize: { active: true, folder: mosquitto }"
        Write-Host  "  3. Herstart de add-on en zoek in het log naar 'Connecting bridge aio-sff'."
        Write-Host ("  Topics: '{0}' gaat naar AIO, '{1}' komt van AIO." -f $OutTopic, $InTopic)
        Write-Host "`nBridge-config: $confFile"
        Write-Host "`nLet op: de AIO quickstart-CA roteert automatisch. Kopieer aio-broker-ca.crt opnieuw naar de share" -ForegroundColor Yellow
        Write-Host "als het add-on-log certificate verify failed meldt. Bewaar ha-client-ca.key goed." -ForegroundColor Yellow
    } else {
        Write-Host "`nHome Assistant -> Instellingen > Apparaten & diensten > MQTT (toevoegen of opnieuw configureren)" -ForegroundColor White
        Write-Host ("  Broker                        : {0}" -f $testIp)
        Write-Host ("  Poort                         : {0}" -f $Port)
        Write-Host  "  Gebruikersnaam / wachtwoord   : leeg laten"
        Write-Host  "  Geavanceerde opties           : aan"
        Write-Host ("  Client ID                     : {0}" -f $ClientName)
        Write-Host  "  Clientcertificaat gebruiken   : aan"
        Write-Host ("    Clientcertificaat           : {0}" -f $cliCrt)
        Write-Host ("    Private key                 : {0}" -f $cliKey)
        Write-Host  "  Broker certificate validation : Custom"
        Write-Host ("    CA-certificaat              : {0}" -f $aioCa)
        Write-Host  "  MQTT-protocol                 : 5"
        Write-Host  "  Transport                     : TCP"
        Write-Host "`nLet op: de AIO quickstart-CA roteert automatisch. Upload aio-broker-ca.crt opnieuw in Home Assistant" -ForegroundColor Yellow
        Write-Host "als de verbinding ooit met CERTIFICATE_VERIFY_FAILED stopt. Bewaar ha-client-ca.key goed." -ForegroundColor Yellow
    }
    exit 0
    #endregion
}
catch {
    Write-Host "`n[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
