# Azure Local SFF in Hyper-V – Part 1: from subscription to ownership voucher

15 October 2026 · Alex ter Neuzen

## Introduction

Azure Local has a new flavor: [small form factor](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2609), or SFF for short, currently still in preview. Where classic Azure Local runs on validated servers with Azure Stack HCI OS and Storage Spaces Direct, SFF targets small edge devices. It doesn't run Windows but Azure Linux, and there is no deployment wizard to click through. You boot a maintenance environment, claim the device in Azure with an ownership voucher and let Azure install the operating system through Arc. After that, you run container workloads on it, such as K3s, AKS or Azure IoT Operations.

Not everyone has a supported NUC sitting on their desk. Fortunately, Microsoft also describes how to [test SFF in a Hyper-V VM](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-vm-installation?view=azloc-2609). That is explicitly meant for testing and evaluation and not for production, but for a lab it's exactly what you need.

This is part 1 of a series in which I deploy Azure Local SFF and eventually run Azure IoT Operations on it. In this part we prepare the subscription, build the VM and retrieve the ownership voucher. In part 2 we claim the machine in Azure and let it install Azure Linux.

## What you need

On the local side you need a Windows machine with Hyper-V and enough room for a VM with 16 GB of memory, 4 vCPUs and a 256 GB disk. You also need a network on which the VM gets an address through DHCP and can reach the internet. I use an external switch on my LAN for that, more on that later.

On the Azure side, identity is what matters most. In the [preparation guide](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2609), Microsoft asks for the following permissions and objects.

| Component | Requirement |
| --- | --- |
| Azure RBAC | Owner, or Contributor plus Role Based Access Control Administrator, active and permanent |
| Microsoft Entra | At least the Directory Readers role |
| Operators | An Entra security group with the people who manage the machines |
| Tooling | Azure CLI, signed in with `az login` |

Note that "active and permanent" is meant literally. If you use PIM, an eligible role only counts after you've activated it.

## Step 1: Prepare the subscription

SFF relies on zero-touch provisioning, which sits behind a preview feature. You register that first, together with the resource providers the provisioning process uses.

```powershell
$sub = '<subscription-id>'
az account set --subscription $sub

az feature register --subscription $sub --namespace Microsoft.DeviceOnboarding --name AzureLocalZTP
```

The Azure CLI then tells you to register `Microsoft.DeviceOnboarding` again once the feature shows `Registered`. That usually takes a few minutes, so I let a small loop wait and do that registration right after.

```powershell
do {
    $state = az feature show --subscription $sub --namespace Microsoft.DeviceOnboarding `
        --name AzureLocalZTP --query properties.state -o tsv
    Write-Host "$(Get-Date -Format HH:mm:ss)  AzureLocalZTP: $state"
    if ($state -ne 'Registered') { Start-Sleep -Seconds 30 }
} until ($state -eq 'Registered')

az provider register --namespace Microsoft.DeviceOnboarding --subscription $sub
```

Next, the resource providers. You always need the first eight. The last four are for K3s, AKS Arc and Azure IoT Operations, and since that's where this series is heading, I register them right away.

```powershell
$providers = 'Microsoft.Edge','Microsoft.AzureStackHCI','Microsoft.HybridCompute','Microsoft.Compute',
             'Microsoft.GuestConfiguration','Microsoft.HybridConnectivity','Microsoft.KeyVault','Microsoft.Storage',
             'Microsoft.Kubernetes','Microsoft.KubernetesConfiguration','Microsoft.ExtendedLocation','Microsoft.HybridContainerService'

foreach ($p in $providers) { az provider register --namespace $p --subscription $sub }

foreach ($p in $providers) {
    "{0,-40} {1}" -f $p, (az provider show --namespace $p --subscription $sub --query registrationState -o tsv)
}
```

Once everything shows `Registered`, the subscription is ready.

## Step 2: Check your permissions

Checking your own role assignments in the portal is doable, but with PIM, group memberships and inheritance from a management group it quickly gets messy. That's why I wrote a script for it: `Test-AzLocalSffPrereqs.ps1`. It only uses your `az login` session for the tokens and queries everything else directly from Azure Resource Manager and Microsoft Graph.

The script checks three things. For Azure RBAC it checks whether you have Owner, or Contributor plus RBAC Administrator, and uses the PIM schedule API to see whether that assignment is permanent or only temporarily activated. For Entra it checks whether Directory Readers or a more privileged role is active. For the operator group it checks whether the group exists, is security-enabled, has members and whether you're a member yourself.

```powershell
.\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -OperatorGroup 'sg-azlocal-sff-operators'

# Or at the level of the resource group you'll provision into
.\Test-AzLocalSffPrereqs.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup 'rg-sff-lab' -OperatorGroup 'sg-azlocal-sff-operators'
```

Each check comes back as PASS, WARN or FAIL, with a summary table at the end. Roles you only hold as eligible are called out explicitly, so you know what you still need to activate. If anything fails, the script exits with code 1, so you can also use it in a pipeline. You can find the full script in the [azure-local-sff-iot-operations](https://github.com/GetToThe-Cloud/azure-local-sff-iot-operations/blob/main/scripts/Test-AzLocalSffPrereqs.ps1) repository on GitHub.

## Step 3: Download the Maintenance OS and Configurator App

You get the two files you need from the Azure portal. Go to **Azure Arc**, choose **Machine Provisioning (preview)** under **Operations**, then **Get started** and **View downloads**. **Download all** gets you both files. Your browser does need to allow multiple downloads, since they arrive separately.

The **Maintenance OS** is the ISO the VM boots from. This is the maintenance environment (also called ROE in the documentation) that registers the device with Azure and handles lifecycle operations. The **Configurator App** is a Windows tool you use to connect to that maintenance environment, download the ownership voucher and collect logs.

Put the ISO somewhere Hyper-V can reach it. I use `C:\Isos\provision-os.iso`, and I install the Configurator App on a PC in the same network as the VM.

## Step 4: Networking

The VM needs a network that provides DHCP for the first connection, lets you assign a static IP later and has internet access. Microsoft provides [`set-network.ps1`](https://github.com/Azure-Samples/AzureLocal/blob/main/small-form-factor/set-network.ps1) for this, which sets up an internal switch with NAT and DHCP. In my lab the LAN already has DHCP and internet, so I keep it simple and connect the VM to an external switch. A nice side effect: the VM simply sits on your LAN, and you can use the Configurator App from any PC on that network.

First check whether you already have an external switch.

```powershell
Get-VMSwitch -SwitchType External
```

If not, look up the physical network adapter and create the switch. With `-AllowManagementOS`, the host itself stays reachable through that adapter as well.

```powershell
Get-NetAdapter -Physical | Where-Object Status -eq 'Up'

New-VMSwitch -Name 'EXTERNAL' -NetAdapterName '<name of your network adapter>' -AllowManagementOS $true
```

Expect the host to briefly lose its network connection when the switch is created, because its IP address moves to the new virtual adapter `vEthernet (EXTERNAL)`. So don't do this over an RDP session on the only network adapter of a remote server.

## Step 5: Create the VM

The documentation walks through the wizard in Hyper-V Manager, but PowerShell makes it repeatable and faster. The requirements are clear: Generation 2, 16000 MB of memory, at least 4 vCPUs, a 256 GB disk, Secure Boot off and a TPM on. That combination stands out, because you don't often see a TPM without Secure Boot. The maintenance environment needs the TPM for the device identity, while Secure Boot has to be off for the VM variant.

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

I deliberately turn off dynamic memory. The documentation only mentions startup memory, but I don't want a VM that will run container workloads later to fluctuate. Before you start the VM, you can quickly check that everything is set correctly.

```powershell
Get-VM $vm         | Select Name, Generation, ProcessorCount, MemoryStartup, DynamicMemoryEnabled
Get-VMFirmware $vm | Select SecureBoot, @{n='FirstBoot';e={$_.BootOrder[0].Device}}
Get-VMSecurity $vm | Select TpmEnabled
```

## Step 6: Boot and fix the boot order

Start the VM and open the console.

```powershell
Start-VM $vm
vmconnect.exe localhost $vm
```

After about five minutes the welcome screen of the maintenance environment appears. It shows the version, the hostname and the serial number. More important are the lines **Network Info**, which should show the IP address from your LAN, **Connectivity**, which should say `Online`, and **Status**, with the message `[Succeeded] Maintenance environment setup completed successfully`. You don't need to log in at the prompt below it, because the rest goes through the Configurator App.

Before you move on, there's one more thing I would take care of: the boot order. The VM currently boots from the ISO first. The [troubleshooting page](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-troubleshoot?view=azloc-2609) describes a boot loop on physical NUCs when the installation media keeps priority: after every reboot the installer starts again. The machine reboots during provisioning in part 2, so you want to avoid that.

First check whether the maintenance environment is actually on the disk. If more than a few GB is in use, it is.

```powershell
Get-VHD "$path\$vm\os.vhdx" |
    Select @{n='UsedGB';e={[math]::Round($_.FileSize/1GB,1)}}, @{n='SizeGB';e={$_.Size/1GB}}
```

Then make the disk the first boot device. That only works with the VM turned off, and since nothing important runs on it yet, a hard power-off is fine.

```powershell
Stop-VM $vm -TurnOff
Set-VMFirmware -VMName $vm -FirstBootDevice (Get-VMHardDiskDrive -VMName $vm)
Start-VM $vm
```

Wait for the `[Succeeded]` message again, which now comes from the disk. Do this before you retrieve the voucher, so your voucher belongs to the installation that stays.

## Step 7: Retrieve the ownership voucher

The ownership voucher is a cryptographic document that links the physical device (in this case the VM) to a digital identity. The mechanism is based on the [FIDO Device Onboard specification](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-security?view=azloc-2609): Azure uses the voucher to authenticate and claim the device before it provisions anything.

Open the Configurator App, enter the IP address from the console and choose **Next**. Sign in with user `edgeuser`, choose **Password** as the method with the password `Password1` and click **Sign in**. These are the default credentials of the maintenance environment from the documentation. Then choose **Download Ownership Voucher** and save the `.pem` file.

Treat that file as a secret. A voucher can only be used once: after the claim, the provisioning service rejects a second attempt for the same device. Microsoft recommends keeping the voucher in a secure place until registration succeeds and deleting it afterwards.

## Wrapping up

You now have a subscription with the right features and resource providers, the permissions SFF asks for, a Hyper-V VM with the maintenance environment on your LAN and an ownership voucher in hand. With that, everything is ready for the real work.

In part 2 we create a site in Azure Arc, attach an Arc gateway, upload the voucher and choose Azure Linux 2607 as the operating system. After that it's 40 to 60 minutes of waiting until the machine shows **Provisioned**, and then Azure IoT Operations can go on it.

## Sources

- [What are small form factor deployments of Azure Local (preview)?](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2609)
- [Prepare to deploy Azure Local on small form factor devices (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2609)
- [Test small form factor deployments of Azure Local in a Hyper-V virtual machine (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-vm-installation?view=azloc-2609)
- [Security features for small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-security?view=azloc-2609)
- [Troubleshoot small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-troubleshoot?view=azloc-2609)
- [Connect a provisioned machine from the Azure portal (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-connect-portal?view=azloc-2609)
- [set-network.ps1 in Azure-Samples/AzureLocal](https://github.com/Azure-Samples/AzureLocal/blob/main/small-form-factor/set-network.ps1)
