#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Zet de OS-disk als eerste boot-device van de SFF-VM, zodat de Maintenance OS ISO niet opnieuw installeert.

.DESCRIPTION
    De VM boot na het aanmaken eerst van de Maintenance OS ISO. Microsoft beschrijft bij fysieke
    apparaten een boot-loop als het installatiemedium voorrang houdt: na elke reboot start de
    installer opnieuw. Omdat de machine tijdens het provisionen reboot, zet dit script de disk vooraan.

    Het script controleert eerst of er daadwerkelijk iets op de VHDX staat (standaard minimaal 2 GB).
    Is dat niet zo, dan stopt het zonder iets te veranderen.

    De VM moet uit staan om de boot-volgorde te wijzigen. Met -Force zet het script een draaiende VM
    hard uit (Stop-VM -TurnOff). Doe dit alleen voordat je de ownership voucher hebt opgehaald.

.PARAMETER VMName
    Naam van de VM. Standaard 'linuxsff-vm'.

.PARAMETER MinUsedGB
    Minimaal gebruikte ruimte op de VHDX om aan te nemen dat de maintenance environment is geinstalleerd.
    Standaard 2.

.PARAMETER Force
    Zet een draaiende VM hard uit zonder te vragen.

.EXAMPLE
    .\03-Set-AzLocalSffBootFromDisk.ps1 -VMName 'linuxsff-vm'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'linuxsff-vm',
    [double]$MinUsedGB = 2,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$vm   = Get-VM -Name $VMName
$disk = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
if (-not $disk) { throw "VM '$VMName' heeft geen harde schijf." }

$vhd    = Get-VHD -Path $disk.Path
$usedGB = [math]::Round($vhd.FileSize / 1GB, 1)
Write-Host ("==> {0}: {1} GB in gebruik van {2} GB" -f $disk.Path, $usedGB, ($vhd.Size / 1GB))

if ($usedGB -lt $MinUsedGB) {
    Write-Warning "Er staat minder dan $MinUsedGB GB op de disk. De maintenance environment lijkt niet geinstalleerd; de boot-volgorde blijft ongewijzigd."
    return
}

$fw = Get-VMFirmware -VMName $VMName
if ($fw.BootOrder[0].Device.Path -eq $disk.Path) {
    Write-Host 'De disk is al het eerste boot-device. Niets te doen.' -ForegroundColor Green
    return
}

$wasRunning = $vm.State -eq 'Running'
if ($wasRunning) {
    if (-not $Force -and -not $PSCmdlet.ShouldContinue("VM '$VMName' draait en wordt hard uitgezet. Doorgaan?", 'Boot-volgorde wijzigen')) {
        return
    }
    if ($PSCmdlet.ShouldProcess($VMName, 'VM hard uitzetten')) { Stop-VM -Name $VMName -TurnOff -Force }
}

if ($PSCmdlet.ShouldProcess($VMName, 'OS-disk als eerste boot-device instellen')) {
    Set-VMFirmware -VMName $VMName -FirstBootDevice $disk
    Write-Host "==> Eerste boot-device: $((Get-VMFirmware -VMName $VMName).BootOrder[0].Device.Path)" -ForegroundColor Cyan
}

if ($wasRunning -and $PSCmdlet.ShouldProcess($VMName, 'VM starten')) {
    Start-VM -Name $VMName
    Write-Host "VM gestart. Wacht in de console op '[Succeeded] Maintenance environment setup completed successfully'." -ForegroundColor Green
}
