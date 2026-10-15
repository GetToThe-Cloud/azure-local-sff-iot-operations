#Requires -Version 5.1
<#
.SYNOPSIS
    Bereidt een subscription voor op Azure Local small form factor (preview).

.DESCRIPTION
    1. Registreert de preview-feature Microsoft.DeviceOnboarding/AzureLocalZTP.
    2. Wacht tot de feature op 'Registered' staat en registreert daarna
       Microsoft.DeviceOnboarding opnieuw, zodat de wijziging wordt doorgezet.
    3. Registreert de resource providers die SFF gebruikt. Met -IncludeWorkloadProviders
       (standaard aan) komen ook de providers voor K3s, AKS Arc en Azure IoT Operations mee.
    4. Toont per provider de registratiestatus.

    Gebruikt de Azure CLI; log eerst in met 'az login'.

.PARAMETER SubscriptionId
    De subscription waarin je gaat provisionen.

.PARAMETER IncludeWorkloadProviders
    Registreer ook Microsoft.Kubernetes, Microsoft.KubernetesConfiguration,
    Microsoft.ExtendedLocation en Microsoft.HybridContainerService. Standaard $true.

.PARAMETER TimeoutMinutes
    Hoe lang het script maximaal wacht op de feature-registratie. Standaard 30.

.EXAMPLE
    .\01-Register-AzLocalSffProviders.ps1 -SubscriptionId '<subscription-id>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [bool]$IncludeWorkloadProviders = $true,

    [int]$TimeoutMinutes = 30
)

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) niet gevonden.' }

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Kan subscription $SubscriptionId niet selecteren. Draai eerst 'az login'." }

# 1. Preview-feature registreren
Write-Host '==> AzureLocalZTP-feature registreren' -ForegroundColor Cyan
az feature register --subscription $SubscriptionId --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP --only-show-errors | Out-Null

# 2. Wachten tot de feature Registered is, daarna de provider opnieuw registreren
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $state = az feature show --subscription $SubscriptionId --namespace Microsoft.DeviceOnboarding `
        --name AzureLocalZTP --query properties.state -o tsv
    Write-Host "    $(Get-Date -Format HH:mm:ss)  AzureLocalZTP: $state"
    if ($state -eq 'Registered') { break }
    if ((Get-Date) -gt $deadline) { throw "AzureLocalZTP staat na $TimeoutMinutes minuten nog op '$state'." }
    Start-Sleep -Seconds 30
} while ($true)

Write-Host '==> Microsoft.DeviceOnboarding opnieuw registreren' -ForegroundColor Cyan
az provider register --namespace Microsoft.DeviceOnboarding --subscription $SubscriptionId --only-show-errors

# 3. Resource providers
$providers = @(
    'Microsoft.Edge', 'Microsoft.AzureStackHCI', 'Microsoft.HybridCompute', 'Microsoft.Compute',
    'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.KeyVault', 'Microsoft.Storage'
)
if ($IncludeWorkloadProviders) {
    $providers += 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
                  'Microsoft.ExtendedLocation', 'Microsoft.HybridContainerService'
}

Write-Host '==> Resource providers registreren' -ForegroundColor Cyan
foreach ($p in $providers) {
    az provider register --namespace $p --subscription $SubscriptionId --only-show-errors
}

# 4. Status tonen
Write-Host '==> Registratiestatus' -ForegroundColor Cyan
$notReady = 0
foreach ($p in @('Microsoft.DeviceOnboarding') + $providers) {
    $state = az provider show --namespace $p --subscription $SubscriptionId --query registrationState -o tsv
    $color = if ($state -eq 'Registered') { 'Green' } else { $notReady++; 'Yellow' }
    Write-Host ('    {0,-40} {1}' -f $p, $state) -ForegroundColor $color
}

if ($notReady) {
    Write-Host "`n$notReady provider(s) nog niet op 'Registered'. Dat kan een paar minuten duren; draai het script gerust opnieuw." -ForegroundColor Yellow
} else {
    Write-Host "`nSubscription is klaar voor Azure Local SFF." -ForegroundColor Green
}
