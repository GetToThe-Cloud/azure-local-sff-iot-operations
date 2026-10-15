#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Maakt een Hyper-V VM aan voor een Azure Local small form factor (preview) lab.

.DESCRIPTION
    Bouwt een VM volgens de eisen uit de Microsoft-documentatie voor het testen van SFF in Hyper-V:
    Generation 2, 16000 MB geheugen, minimaal 4 vCPU's, een disk van 256 GB, Secure Boot uit en
    een vTPM aan. De VM boot van de Maintenance OS ISO uit de Azure portal
    (Azure Arc > Machine Provisioning (preview) > Get started > View downloads).

    De VM wordt aangesloten op een bestaande Hyper-V switch. In deze serie is dat een external
    switch op een LAN met DHCP en internet.

    Dynamic memory staat bewust uit. De VM wordt niet gestart; doe dat zelf met Start-VM.

.PARAMETER VMName
    Naam van de VM. Standaard 'linuxsff-vm'.

.PARAMETER Path
    Map waarin de VM en de VHDX komen.

.PARAMETER IsoPath
    Pad naar de Maintenance OS ISO.

.PARAMETER SwitchName
    Naam van de Hyper-V switch. Standaard 'EXTERNAL'.

.PARAMETER MemoryStartupMB
    Opstartgeheugen in MB. Standaard 16000.

.PARAMETER ProcessorCount
    Aantal vCPU's. Minimaal en standaard 4.

.PARAMETER DiskSizeGB
    Grootte van de OS-disk in GB. Standaard 256.

.EXAMPLE
    .\02-New-AzLocalSffVm.ps1 -Path 'F:\VMs' -IsoPath 'C:\Isos\provision-os.iso'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'linuxsff-vm',

    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$IsoPath,

    [string]$SwitchName = 'EXTERNAL',

    [ValidateRange(8000, 1048576)]
    [int]$MemoryStartupMB = 16000,

    [ValidateRange(4, 64)]
    [int]$ProcessorCount = 4,

    [ValidateRange(256, 4096)]
    [int]$DiskSizeGB = 256
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell-module niet gevonden.' }
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue)       { throw "Er bestaat al een VM met de naam '$VMName'." }
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' niet gevonden. Maak hem eerst aan (zie de README)."
}

$vhdPath = Join-Path (Join-Path $Path $VMName) 'os.vhdx'

if ($PSCmdlet.ShouldProcess($VMName, 'Hyper-V VM aanmaken')) {
    Write-Host "==> VM '$VMName' aanmaken op switch '$SwitchName'" -ForegroundColor Cyan
    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ([int64]$MemoryStartupMB * 1MB) -SwitchName $SwitchName `
           -Path $Path -NewVHDPath $vhdPath -NewVHDSizeBytes ([int64]$DiskSizeGB * 1GB) | Out-Null

    Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false
    Set-VMProcessor -VMName $VMName -Count $ProcessorCount

    Write-Host '==> Secure Boot uit, vTPM aan' -ForegroundColor Cyan
    Set-VMFirmware     -VMName $VMName -EnableSecureBoot Off
    Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
    Enable-VMTPM       -VMName $VMName

    Write-Host '==> Maintenance OS ISO koppelen als eerste boot-device' -ForegroundColor Cyan
    Add-VMDvdDrive -VMName $VMName -Path $IsoPath
    Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMDvdDrive -VMName $VMName)

    # Controle
    $vm   = Get-VM -Name $VMName
    $fw   = Get-VMFirmware -VMName $VMName
    $sec  = Get-VMSecurity -VMName $VMName
    [pscustomobject]@{
        Name           = $vm.Name
        Generation     = $vm.Generation
        vCPU           = $vm.ProcessorCount
        MemoryStartMB  = [int]($vm.MemoryStartup / 1MB)
        DynamicMemory  = $vm.DynamicMemoryEnabled
        SecureBoot     = $fw.SecureBoot
        TpmEnabled     = $sec.TpmEnabled
        FirstBoot      = $fw.BootOrder[0].Device.Name
        Switch         = (Get-VMNetworkAdapter -VMName $VMName).SwitchName
        Vhd            = $vhdPath
    } | Format-List

    Write-Host "Klaar. Start de VM met: Start-VM '$VMName'; vmconnect.exe localhost '$VMName'" -ForegroundColor Green
}
