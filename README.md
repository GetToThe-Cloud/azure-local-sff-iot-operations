# Azure Local SFF with Azure IoT Operations

Scripts and blog material for the [gettothe.cloud](https://gettothe.cloud) series on Azure Local small form factor (SFF), currently in preview. In this series I set up SFF in a Hyper-V lab and eventually run Azure IoT Operations on it.

> According to Microsoft, SFF in a VM is intended for testing and evaluation only. For production you need supported hardware.

## Contents

| Path | What |
| --- | --- |
| `scripts/01-Register-AzLocalSffProviders.ps1` | Registers the AzureLocalZTP feature and the resource providers (step 1) |
| `scripts/Test-AzLocalSffPrereqs.ps1` | Checks Azure RBAC, the Entra role and the operator group (step 2) |
| `scripts/02-New-AzLocalSffVm.ps1` | Creates the Hyper-V VM according to the SFF requirements (step 5) |
| `scripts/03-Set-AzLocalSffBootFromDisk.ps1` | Moves the OS disk to the top of the boot order (step 6) |
| `scripts/Enable-AioHomeAssistantMqtt.ps1` | Sets up a TLS listener with X.509 on the AIO MQTT broker and writes the Mosquitto bridge config for Home Assistant (part 5) |
| `scripts/Enable-AioHomeAssistantAdls.ps1` | Creates a storage account with hierarchical namespace, a Delta schema, a dataflow endpoint and a dataflow to ADLS Gen2, and writes the Home Assistant package and the DuckDB queries (part 6) |
| `scripts/Enable-AioHomeAssistantAdx.ps1` | Sends Home Assistant states to Azure Data Explorer through an AIO dataflow and sets up the whole ADX side: cluster (Dev/Test SKU), database, raw and typed tables with an update policy, permissions, Delta schema, dataflow endpoint and dataflow. Includes a self-test via the mqtt-client pod and writes the Home Assistant automation |
| `scripts/ha-adls-config/` | Example output of `Enable-AioHomeAssistantAdls.ps1`: schema, dataflow endpoint and dataflow definitions, the Home Assistant package and automation, and the DuckDB queries |

## Part 1 in brief

Sign in with the Azure CLI and prepare the subscription.

```powershell
az login
.\scripts\01-Register-AzLocalSffProviders.ps1 -SubscriptionId '<subscription-id>'
```

Next, check that your account has the right permissions. You need Owner, or Contributor plus Role Based Access Control Administrator (active and permanent), at least Directory Readers in Entra, and an Entra security group for the operators.

```powershell
.\scripts\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -OperatorGroup '<group name or object ID>'
```

In the Azure portal, download the Maintenance OS ISO and the Configurator App via **Azure Arc > Operations > Machine Provisioning (preview) > Get started > View downloads**.

The VM is connected to an external Hyper-V switch on a LAN with DHCP and internet access. If you don't have one yet, create it. The host briefly loses its network connection while you do this.

```powershell
Get-NetAdapter -Physical | Where-Object Status -eq 'Up'
New-VMSwitch -Name 'EXTERNAL' -NetAdapterName '<name of your network adapter>' -AllowManagementOS $true
```

If your Hyper-V host is not set to UTC, switch it to UTC temporarily before you start the VM for the first time. At boot, Hyper-V passes the host's local time to the VM, the maintenance environment reads it as UTC, and your voucher then only becomes valid in Azure hours later ("Certificate is not yet valid").

```powershell
$hostTz = (Get-TimeZone).Id
Set-TimeZone -Id 'UTC'
```

Create the VM and start it on a Hyper-V host (as administrator).

```powershell
.\scripts\02-New-AzLocalSffVm.ps1 -Path 'F:\VMs' -IsoPath 'C:\Isos\provision-os.iso'
Start-VM 'linuxsff-vm'
vmconnect.exe localhost 'linuxsff-vm'
```

Wait until the console shows `[Succeeded] Maintenance environment setup completed successfully`, along with an IP address and `Connectivity: Online`. Then move the disk to the top of the boot order, so the ISO doesn't reinstall after a reboot.

```powershell
.\scripts\03-Set-AzLocalSffBootFromDisk.ps1 -VMName 'linuxsff-vm'
```

Finally, use the Configurator App to retrieve the ownership voucher (`edgeuser` / `Password1`, the default credentials of the maintenance environment). You use that voucher in part 2 to claim the machine in Azure Arc.

After that, check that the VM's clock is correct, and only then switch the host back to its own time zone.

```powershell
ssh edgeuser@<vm-ip> "date -u"
[DateTime]::UtcNow.ToString('u')
Set-TimeZone -Id $hostTz
```

## Note

Ownership vouchers and SSH keys are `.pem` files and don't belong in Git. The `.gitignore` excludes them.

## Sources

- [What are small form factor deployments of Azure Local (preview)?](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2609)
- [Prepare to deploy Azure Local on small form factor devices (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2609)
- [Test small form factor deployments of Azure Local in a Hyper-V virtual machine (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-vm-installation?view=azloc-2609)
- [Troubleshoot small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-troubleshoot?view=azloc-2609)
