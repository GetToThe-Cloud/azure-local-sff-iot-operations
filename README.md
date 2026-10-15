# Azure Local SFF met Azure IoT Operations

Scripts en blogmateriaal bij de [gettothe.cloud](https://gettothe.cloud)-serie over Azure Local small form factor (SFF), op dit moment in preview. In de serie zet ik SFF neer in een Hyper-V lab en laat ik er uiteindelijk Azure IoT Operations op draaien.

> SFF in een VM is volgens Microsoft alleen bedoeld voor test en evaluatie. Voor productie heb je ondersteunde hardware nodig.

## Inhoud

| Pad | Wat |
| --- | --- |
| `scripts/01-Register-AzLocalSffProviders.ps1` | Registreert de AzureLocalZTP-feature en de resource providers (stap 1) |
| `scripts/Test-AzLocalSffPrereqs.ps1` | Controleert Azure RBAC, de Entra-rol en de operator-groep (stap 2) |
| `scripts/02-New-AzLocalSffVm.ps1` | Maakt de Hyper-V VM aan volgens de SFF-eisen (stap 5) |
| `scripts/03-Set-AzLocalSffBootFromDisk.ps1` | Zet de OS-disk vooraan in de boot-volgorde (stap 6) |
| `docs/part-1-azure-local-sff-hyper-v.docx` | Blogpost deel 1 (Engels): from subscription to ownership voucher |
| `docs/part-1-azure-local-sff-hyper-v.md` | Dezelfde blogpost als Markdown |
| `docs/azure-local-sff-identity-prerequisites.docx` | Blogpost (Engels): deep dive in `Test-AzLocalSffPrereqs.ps1` |
| `docs/azure-local-sff-identity-prerequisites.md` | Dezelfde blogpost als Markdown |

## Deel 1 in het kort

Log in met de Azure CLI en bereid de subscription voor.

```powershell
az login
.\scripts\01-Register-AzLocalSffProviders.ps1 -SubscriptionId '<subscription-id>'
```

Controleer daarna of je account de juiste rechten heeft. Je hebt Owner nodig, of Contributor plus Role Based Access Control Administrator (active en permanent), minimaal Directory Readers in Entra en een Entra security group voor de operators.

```powershell
.\scripts\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -OperatorGroup '<groepsnaam of object-id>'
```

Download in de Azure portal de Maintenance OS ISO en de Configurator App via **Azure Arc > Operations > Machine Provisioning (preview) > Get started > View downloads**.

De VM hangt aan een external Hyper-V switch op een LAN met DHCP en internet. Heb je die nog niet, maak hem dan aan. De host verliest daarbij kort zijn netwerkverbinding.

```powershell
Get-NetAdapter -Physical | Where-Object Status -eq 'Up'
New-VMSwitch -Name 'EXTERNAL' -NetAdapterName '<naam van je netwerkkaart>' -AllowManagementOS $true
```

Maak de VM aan en start hem op een Hyper-V host (als administrator).

```powershell
.\scripts\02-New-AzLocalSffVm.ps1 -Path 'F:\VMs' -IsoPath 'C:\Isos\provision-os.iso'
Start-VM 'linuxsff-vm'
vmconnect.exe localhost 'linuxsff-vm'
```

Wacht tot de console `[Succeeded] Maintenance environment setup completed successfully` toont, met een IP-adres en `Connectivity: Online`. Zet daarna de disk vooraan in de boot-volgorde, zodat de ISO na een reboot niet opnieuw installeert.

```powershell
.\scripts\03-Set-AzLocalSffBootFromDisk.ps1 -VMName 'linuxsff-vm'
```

Haal tot slot met de Configurator App de ownership voucher op (`edgeuser` / `Password1`, de standaardgegevens van de maintenance environment). Die voucher gebruik je in deel 2 om de machine in Azure Arc te claimen.

## Let op

Ownership vouchers en SSH-keys zijn `.pem`-bestanden en horen niet in Git. De `.gitignore` sluit ze uit.

## Bronnen

- [What are small form factor deployments of Azure Local (preview)?](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2609)
- [Prepare to deploy Azure Local on small form factor devices (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2609)
- [Test small form factor deployments of Azure Local in a Hyper-V virtual machine (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-vm-installation?view=azloc-2609)
- [Troubleshoot small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-troubleshoot?view=azloc-2609)
