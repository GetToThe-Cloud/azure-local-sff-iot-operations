# Azure Local SFF in Hyper-V – Deel 1: van subscription tot ownership voucher

15 oktober 2026 · Alex ter Neuzen

## Inleiding

Azure Local heeft er een nieuwe smaak bij: [small form factor](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2609), of kortweg SFF, op dit moment nog in preview. Waar het klassieke Azure Local draait op gevalideerde servers met Azure Stack HCI OS en Storage Spaces Direct, mikt SFF op kleine edge-apparaten. Er draait geen Windows op maar Azure Linux, en je doorloopt geen deployment wizard. Je boot een maintenance environment, claimt het apparaat in Azure met een ownership voucher en laat Azure via Arc het besturingssysteem installeren. Daarna draai je er containerworkloads op, zoals K3s, AKS of Azure IoT Operations.

Niet iedereen heeft een ondersteunde NUC op zijn bureau liggen. Gelukkig beschrijft Microsoft ook hoe je SFF [in een Hyper-V VM test](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-vm-installation?view=azloc-2609). Dat is uitdrukkelijk bedoeld voor test en evaluatie en niet voor productie, maar voor een lab is het precies wat je nodig hebt.

Dit is deel 1 van een serie waarin ik Azure Local SFF neerzet en er uiteindelijk Azure IoT Operations op laat draaien. In dit deel bereiden we de subscription voor, bouwen we de VM en halen we de ownership voucher op. In deel 2 claimen we de machine in Azure en laten we Azure Linux installeren.

## Wat heb je nodig

Aan de lokale kant heb je een Windows-machine met Hyper-V nodig, met genoeg ruimte voor een VM van 16 GB geheugen, 4 vCPU's en een disk van 256 GB. Daarnaast heb je een netwerk nodig waarop de VM via DHCP een adres krijgt en het internet op kan. Ik gebruik daarvoor een external switch op mijn LAN, waarover verderop meer.

Aan de Azure-kant is vooral de identiteit belangrijk. Microsoft vraagt in de [voorbereiding](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2609) om de volgende rechten en objecten.

| Onderdeel | Eis |
| --- | --- |
| Azure RBAC | Owner, of Contributor plus Role Based Access Control Administrator, active en permanent |
| Microsoft Entra | Minimaal de rol Directory Readers |
| Operators | Een Entra security group met de mensen die de machines beheren |
| Tooling | Azure CLI, ingelogd met `az login` |

Let op dat "active en permanent" letterlijk bedoeld is. Werk je met PIM, dan telt een eligible rol pas mee nadat je hem hebt geactiveerd.

## Stap 1: de subscription voorbereiden

SFF leunt op zero-touch provisioning, en dat zit achter een preview-feature. Die registreer je eerst, samen met de resource providers die het provisioningproces gebruikt.

```powershell
$sub = '<subscription-id>'
az account set --subscription $sub

az feature register --subscription $sub --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP
```

De Azure CLI meldt daarna dat je `Microsoft.DeviceOnboarding` opnieuw moet registreren zodra de feature op `Registered` staat. Dat duurt meestal een paar minuten, dus ik laat een lusje wachten en doe die registratie meteen daarna.

```powershell
do {
    $state = az feature show --subscription $sub --namespace Microsoft.DeviceOnboarding `
        --name AzureLocalZTP --query properties.state -o tsv
    Write-Host "$(Get-Date -Format HH:mm:ss)  AzureLocalZTP: $state"
    if ($state -ne 'Registered') { Start-Sleep -Seconds 30 }
} until ($state -eq 'Registered')

az provider register --namespace Microsoft.DeviceOnboarding --subscription $sub
```

Dan de resource providers. De eerste acht heb je altijd nodig. De laatste vier zijn voor K3s, AKS Arc en Azure IoT Operations, en omdat we daar in deze serie naartoe werken, neem ik ze meteen mee.

```powershell
$providers = 'Microsoft.Edge','Microsoft.AzureStackHCI','Microsoft.HybridCompute','Microsoft.Compute',
             'Microsoft.GuestConfiguration','Microsoft.HybridConnectivity','Microsoft.KeyVault','Microsoft.Storage',
             'Microsoft.Kubernetes','Microsoft.KubernetesConfiguration','Microsoft.ExtendedLocation','Microsoft.HybridContainerService'

foreach ($p in $providers) { az provider register --namespace $p --subscription $sub }

foreach ($p in $providers) {
    "{0,-40} {1}" -f $p, (az provider show --namespace $p --subscription $sub --query registrationState -o tsv)
}
```

Als alles op `Registered` staat, is de subscription klaar.

## Stap 2: rechten controleren

In de portal je eigen role assignments nalopen is te doen, maar met PIM, groepslidmaatschappen en overerving vanaf een management group wordt het snel onoverzichtelijk. Daarom heb ik er een script voor geschreven: `Test-AzLocalSffPrereqs.ps1`. Het gebruikt je `az login`-sessie alleen voor de tokens en vraagt de rest rechtstreeks op bij Azure Resource Manager en Microsoft Graph.

Het script controleert drie dingen. Bij Azure RBAC kijkt het of je Owner hebt, of Contributor plus RBAC Administrator, en via de PIM-schedule-API of die toewijzing permanent is of alleen tijdelijk geactiveerd. Bij Entra controleert het of Directory Readers of een zwaardere rol actief is. Bij de operator-groep kijkt het of die bestaat, security-enabled is, leden heeft en of je er zelf in zit.

```powershell
.\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -OperatorGroup 'sg-azlocal-sff-operators'

# Of op het niveau van de resource group waarin je gaat provisionen
.\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup 'rg-sff-lab' -OperatorGroup 'sg-azlocal-sff-operators'
```

Elke check komt terug als PASS, WARN of FAIL, met een samenvattende tabel aan het eind. Rollen die je alleen eligible hebt, noemt het script expliciet, zodat je weet wat je nog moet activeren. Faalt er iets, dan eindigt het script met exit code 1, zodat je het ook in een pipeline kunt gebruiken. Het volledige script vind je in de repository [azure-local-sff-iot-operations](https://github.com/GetToThe-Cloud/azure-local-sff-iot-operations/blob/main/scripts/Test-AzLocalSffPrereqs.ps1) op GitHub.

## Stap 3: Maintenance OS en Configurator App downloaden

De twee bestanden die je nodig hebt, haal je uit de Azure portal. Ga naar **Azure Arc**, kies onder **Operations** voor **Machine Provisioning (preview)** en daarna **Get started** en **View downloads**. Met **Download all** krijg je beide bestanden binnen. Je browser moet wel meerdere downloads toestaan, want ze komen los binnen.

De **Maintenance OS** is de ISO waarvan de VM boot. Dit is de maintenance environment (in de documentatie ook wel ROE genoemd) die het apparaat bij Azure aanmeldt en de lifecycle-operaties afhandelt. De **Configurator App** is een Windows-tool waarmee je verbinding maakt met die maintenance environment, de ownership voucher downloadt en logs verzamelt.

Zet de ISO op een plek waar Hyper-V erbij kan. Ik gebruik `C:\Isos\provision-os.iso`, en de Configurator App installeer ik op een pc in hetzelfde netwerk als de VM.

## Stap 4: het netwerk

De VM heeft een netwerk nodig dat DHCP levert voor de eerste verbinding, waarop je later een statisch IP kunt toekennen en dat internet heeft. Microsoft levert daarvoor [`set-network.ps1`](https://github.com/Azure-Samples/AzureLocal/blob/main/small-form-factor/set-network.ps1), dat een interne switch met NAT en DHCP opzet. In mijn lab heeft het LAN al DHCP en internet, dus ik houd het simpel en hang de VM aan een external switch. Bijkomend voordeel: de VM staat dan gewoon op je LAN, en je kunt de Configurator App vanaf elke pc in dat netwerk gebruiken.

Kijk eerst of je al een external switch hebt.

```powershell
Get-VMSwitch -SwitchType External
```

Is die er nog niet, zoek dan de fysieke netwerkkaart op en maak de switch aan. Met `-AllowManagementOS` blijft de host zelf ook via die kaart bereikbaar.

```powershell
Get-NetAdapter -Physical | Where-Object Status -eq 'Up'

New-VMSwitch -Name 'EXTERNAL' -NetAdapterName '<naam van je netwerkkaart>' -AllowManagementOS $true
```

Reken erop dat de host bij het aanmaken van de switch even zijn netwerkverbinding kwijt is, omdat het IP-adres naar de nieuwe virtuele adapter `vEthernet (EXTERNAL)` verhuist. Doe dit dus niet via een RDP-sessie op de enige netwerkkaart van een server op afstand.

## Stap 5: de VM aanmaken

De documentatie loopt de wizard in Hyper-V Manager door, maar met PowerShell is het herhaalbaar en sneller. De eisen zijn duidelijk: Generation 2, 16000 MB geheugen, minimaal 4 vCPU's, een disk van 256 GB, Secure Boot uit en een TPM aan. Die combinatie is opvallend, want een TPM zonder Secure Boot zie je niet vaak. De maintenance environment heeft de TPM nodig voor de identiteit van het apparaat, terwijl Secure Boot in de VM-variant uit moet.

```powershell
$vm   = 'linuxsff-vm'
$path = 'F:\VMs'
$iso  = 'C:\Isos\provision-os.iso'

New-VM -Name $vm -Generation 2 -MemoryStartupBytes 16000MB -SwitchName 'EXTERNAL' `
       -Path $path -NewVHDPath "$path\$vm\os.vhdx" -NewVHDSizeBytes 256GB

Set-VMMemory       -VMName $vm -DynamicMemoryEnabled $false
Set-VMProcessor    -VMName $vm -Count 4
Set-VMFirmware     -VMName $vm -EnableSecureBoot Off
Set-VMKeyProtector -VMName $vm -NewLocalKeyProtector
Enable-VMTPM       -VMName $vm

Add-VMDvdDrive -VMName $vm -Path $iso
Set-VMFirmware -VMName $vm -FirstBootDevice (Get-VMDvdDrive -VMName $vm)
```

Dynamic memory zet ik bewust uit. De documentatie noemt alleen het opstartgeheugen, maar een VM die straks containerworkloads draait, wil ik niet laten schommelen. Voordat je de VM start, kun je snel controleren of alles goed staat.

```powershell
Get-VM $vm         | Select Name, Generation, ProcessorCount, MemoryStartup, DynamicMemoryEnabled
Get-VMFirmware $vm | Select SecureBoot, @{n='FirstBoot';e={$_.BootOrder[0].Device}}
Get-VMSecurity $vm | Select TpmEnabled
```

## Stap 6: opstarten en de boot-volgorde

Start de VM en open de console.

```powershell
Start-VM $vm
vmconnect.exe localhost $vm
```

Na een minuut of vijf verschijnt het welkomstscherm van de maintenance environment. Daarop zie je de versie, de hostnaam en het serienummer. Belangrijker zijn de regels **Network Info**, die het IP-adres uit je LAN moet tonen, **Connectivity**, die op `Online` moet staan, en **Status**, met de melding `[Succeeded] Maintenance environment setup completed successfully`. Je hoeft niet in te loggen op de prompt eronder, want de rest gaat via de Configurator App.

Voordat je verdergaat, is er nog één ding dat ik zou regelen: de boot-volgorde. De VM boot nu eerst van de ISO. De [troubleshooting-pagina](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-troubleshoot?view=azloc-2609) beschrijft bij fysieke NUC's een boot-loop als het installatiemedium voorrang blijft houden: na elke reboot begint de installer opnieuw. Tijdens het provisionen in deel 2 reboot de machine, dus dat wil je voorkomen.

Kijk eerst of de maintenance environment echt op de disk staat. Is er meer dan een paar GB in gebruik, dan is dat zo.

```powershell
Get-VHD "$path\$vm\os.vhdx" |
    Select @{n='UsedGB';e={[math]::Round($_.FileSize/1GB,1)}}, @{n='SizeGB';e={$_.Size/1GB}}
```

Zet daarna de disk als eerste boot-device. Dat kan alleen als de VM uit staat, en omdat er nog niets belangrijks op draait, mag hij hard uit.

```powershell
Stop-VM $vm -TurnOff
Set-VMFirmware -VMName $vm -FirstBootDevice (Get-VMHardDiskDrive -VMName $vm)
Start-VM $vm
```

Wacht opnieuw op de `[Succeeded]`-melding, die nu van de disk komt. Doe dit vóór je de voucher ophaalt, zodat je voucher hoort bij de installatie die blijft staan.

## Stap 7: de ownership voucher ophalen

De ownership voucher is een cryptografisch document dat het fysieke apparaat (hier dus de VM) koppelt aan een digitale identiteit. Het mechanisme leunt op de [FIDO Device Onboard-specificatie](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-security?view=azloc-2609): Azure gebruikt de voucher om het apparaat te authenticeren en te claimen voordat het iets gaat provisionen.

Open de Configurator App, vul het IP-adres uit de console in en kies **Next**. Log in met gebruiker `edgeuser`, kies **Password** als methode met het wachtwoord `Password1` en klik op **Sign in**. Dit zijn de standaardgegevens van de maintenance environment uit de documentatie. Kies daarna **Download Ownership Voucher** en sla het `.pem`-bestand op.

Behandel dat bestand als een geheim. Een voucher is eenmalig te gebruiken: na het claimen weigert de provisioning-service een tweede poging voor hetzelfde apparaat. Microsoft raadt aan de voucher veilig te bewaren tot de registratie gelukt is en hem daarna te verwijderen.

## Tot slot

Je hebt nu een subscription met de juiste features en resource providers, de rechten die SFF vraagt, een Hyper-V VM met de maintenance environment op je LAN en een ownership voucher in handen. Daarmee is alles klaar voor het echte werk.

In deel 2 maken we in Azure Arc een site aan, koppelen we een Arc gateway, uploaden we de voucher en kiezen we Azure Linux 2607 als besturingssysteem. Daarna is het 40 tot 60 minuten wachten tot de machine op **Provisioned** staat, en dan kan Azure IoT Operations erop.

## Bronnen

- [What are small form factor deployments of Azure Local (preview)?](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2609)
- [Prepare to deploy Azure Local on small form factor devices (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2609)
- [Test small form factor deployments of Azure Local in a Hyper-V virtual machine (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-vm-installation?view=azloc-2609)
- [Security features for small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-security?view=azloc-2609)
- [Troubleshoot small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-troubleshoot?view=azloc-2609)
- [Connect a provisioned machine from the Azure portal (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-connect-portal?view=azloc-2609)
- [set-network.ps1 in Azure-Samples/AzureLocal](https://github.com/Azure-Samples/AzureLocal/blob/main/small-form-factor/set-network.ps1)
