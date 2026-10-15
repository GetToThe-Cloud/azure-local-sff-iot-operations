---
title: "Azure Local | Small Form Factor Part 3 – Connecting K3s to Azure Arc"
date: 2026-10-15
categories: [azure, azure-local, infrastructure]
tags: ["Azure", "Azure Local", "Small Form Factor", "Azure Arc", "K3s"]
excerpt: "K3s runs on the small form factor machine. In part 3 I connect it to Azure Arc from my Windows PC, with the OIDC issuer, workload identity and custom locations that Azure IoT Operations needs. Four steps on paper, three detours in practice: a 32-bit Azure CLI, a dead-end SSH tunnel and an Arc gateway proxy that K3s quietly inherited."
permalink: /azure-local-small-form-factor-part-3-connecting-k3s-to-azure-arc/
series: "Azure Local small form factor with Azure IoT Operations"
---

K3s is running. Now Azure needs to know about it.

Part 2 ended with a single-node K3s cluster on the provisioned machine, the kernel limits for Azure IoT Operations already raised, and root access through just-in-time (JIT) access. This part connects that cluster to Azure Arc. I copy the kubeconfig to my Windows PC, run `az connectedk8s connect` with the options Azure IoT Operations needs, point the cluster's service account issuer at Azure and enable custom locations. At the end, the cluster shows up in Azure as connected and is ready for the Azure IoT Operations deployment in part 4.

On paper that's four steps. In my lab it took three detours: an Azure CLI that couldn't install its own extension, an SSH tunnel that went nowhere, and an Arc gateway proxy that K3s picked up during its installation. I kept all three in, because you'll probably meet at least one of them.

## What you need

| Component | Requirement |
| --- | --- |
| Cluster | Single-node K3s from part 2, `Ready` |
| Root on the machine | JIT as Provisioned Machine Admin |
| Azure roles | Owner, or Contributor plus User Access Administrator |
| Tooling | 64-bit Azure CLI, `kubectl`, OpenSSH |
| Network | Same LAN as the machine |

The tooling runs on your Windows PC, and it says 64-bit for a reason. You'll see why in step 2.

The roles apply to the subscription, and they come from the [cluster preparation guide](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/howto-prepare-cluster) for Azure IoT Operations, which I follow for most of this post. The [K3s instructions for small form factor](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-containerized-workloads?view=azloc-2609) describe the same route from a Windows PC, but stop at a bare `az connectedk8s connect`. The IoT Operations guide adds what the cluster needs later.

## Why not the Microsoft script?

Microsoft publishes [setup-k3s-arc.sh](https://github.com/Azure-Samples/AzureLocal/blob/main/small-form-factor/setup-k3s-arc.sh), a script that installs K3s, connects it to Arc and configures Azure RBAC, and the small form factor documentation points to it. It runs the Azure CLI from a container through the containerd that comes with K3s, so nothing extra lands on the host. That's a neat approach.

It just isn't built for Azure IoT Operations. Its `az connectedk8s connect` doesn't pass `--enable-oidc-issuer`, `--enable-workload-identity` or `--disable-auto-upgrade`, the location defaults to `eastus`, and it does nothing with proxy settings. You could add the missing options afterward with `az connectedk8s update`, but then you're repairing the script's result instead of doing it right once.

So I do it by hand, from my Windows PC.

## Step 1: Get the kubeconfig to Windows

K3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml`, and only root can read that file. That rules out `clouduser`, which has no `sudo` (see part 2). Everything in this post that touches the machine goes through the JIT account.

Because I needed that account a lot, I first put the SSH command in a small PowerShell function. The values come from the `Usage:` line that `az provisionedmachine ssh-cert-create` prints:

```powershell
$IP  = '<vm-ip>'
$JIT = '<username>_jit'
$KEY = '<path>\id_rsa.pem'
$CRT = '<path>\id_rsa.pem-cert.pub'

function Invoke-Sff { ssh -i $KEY -o "CertificateFile=$CRT" "$JIT@$IP" $args }
```

`Invoke-Sff "<command>"` runs one command on the machine, and `Invoke-Sff` without arguments opens an interactive session. If it suddenly returns `Permission denied (publickey)`, the short-lived certificate has most likely expired. Request a new one with `ssh-cert-create`, and activate your PIM roles again first if they have run out too.

Now copy the kubeconfig and point it at the machine:

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
$kc = "$HOME\.kube\sff.yaml"

Invoke-Sff "sudo cat /etc/rancher/k3s/k3s.yaml" | Set-Content $kc -Encoding ascii
$env:KUBECONFIG = $kc

kubectl config set-cluster default --server="https://$($IP):6443"
kubectl get nodes
```

Two details in there are deliberate. `Set-Content -Encoding ascii` replaces a plain `>` redirect, because in Windows PowerShell 5.1 that redirect writes UTF-16, and you end up with a kubeconfig that `kubectl` won't load. And the URL uses `$($IP)` instead of `$IP`: PowerShell reads `$IP:6443` as a variable with a drive prefix, like `$env:PATH`, and quietly replaces it with nothing.

The kubeconfig from K3s points at `127.0.0.1`, which only works on the machine itself. `set-cluster` swaps that for the machine's address on the LAN, as the small form factor instructions describe. When `kubectl get nodes` shows the node as `Ready`, your PC can reach the API server.

### Detour: the SSH tunnel

My first attempt didn't use the direct route. I forwarded local port 6443 to the API server through the JIT session, in a second PowerShell window, and pointed the kubeconfig at `127.0.0.1`:

```powershell
ssh -N -L 6443:127.0.0.1:6443 -i $KEY -o "CertificateFile=$CRT" "$JIT@$IP"
```

That gave me this:

```text
PS C:\> kubectl get nodes
...
Unable to connect to the server: read tcp 127.0.0.1:58042->127.0.0.1:6443:
wsarecv: An existing connection was forcibly closed by the remote host.
```

The error says more than it seems to. Something on my PC accepted the connection, so the tunnel was listening. Then the connection was dropped immediately, which means SSH couldn't complete the forward on the machine's side. The tunnel window shows the reason, for example that port forwarding isn't allowed. I didn't dig further, because I didn't need the tunnel in the first place.

Test the direct route before you build anything around it:

```powershell
Test-NetConnection $IP -Port 6443 | Select-Object TcpTestSucceeded
```

`True` means the API server is reachable over the LAN and the commands above work as they are. That's the route the Microsoft instructions describe, and it's the one to use.

If it returns `False`, a firewall on the machine is probably blocking the port. You can open it temporarily for your LAN:

```powershell
Invoke-Sff "sudo iptables -I INPUT -p tcp --dport 6443 -s <lan-cidr> -j ACCEPT"
```

The rule doesn't survive a reboot, and that's fine. You need port 6443 from your PC while you set up the cluster. For later access, the cluster connect feature from step 3 gives you a route through Azure.

## Step 2: Connect the cluster to Azure Arc

First the variables, the resource providers and a resource group:

```powershell
$SUB = '<subscription-id>'
$RG  = '<resource-group>'
$CL  = 'linuxsff-k3s'
$LOC = 'westeurope'

az account set --subscription $SUB
az extension add --upgrade --name connectedk8s

'Microsoft.ExtendedLocation', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
'Microsoft.IoTOperations', 'Microsoft.DeviceRegistry', 'Microsoft.SecretSyncController' |
    ForEach-Object { az provider register --namespace $_ --wait }

az group create --name $RG --location $LOC
```

The first three providers were already registered by the script from part 1. The last three are new: they belong to Azure IoT Operations, and registering them now saves a failed deployment later. `--wait` returns once the registration is finished, and right away for a provider that's already registered.

The region matters more than usual. Azure IoT Operations supports Arc-enabled clusters only in a [limited set of regions](https://learn.microsoft.com/azure/iot-operations/overview-support#supported-regions), and that limit applies to the region you pick here, for the cluster. In Europe that means `westeurope`, `northeurope` or `germanywestcentral`. The resource group is a new one, because Azure IoT Operations supports only one instance per resource group, and I prefer to keep the cluster and its IoT Operations instance apart from the site and the machine.

Then the connect itself:

```powershell
az connectedk8s connect --name $CL --resource-group $RG --location $LOC `
    --kube-config $kc --kube-context default `
    --enable-oidc-issuer `
    --enable-workload-identity `
    --disable-auto-upgrade
```

Each option has a job. `--enable-oidc-issuer` and `--enable-workload-identity` give the cluster an OIDC issuer URL in Azure and install the workload identity webhook; Azure IoT Operations needs workload identity to run with secure settings. `--disable-auto-upgrade` stops the Arc agents and the system extensions that IoT Operations depends on from updating on their own schedule, so you upgrade them when you choose. And `--kube-config` with `--kube-context` makes sure the command talks to this cluster, not to whatever your default kubeconfig points at.

There's no `--gateway-resource-id` in there. The machine itself goes through the Arc gateway (part 2, step 1), but my LAN has direct internet access, so I connect the cluster's agents without it. If your network requires a proxy or the gateway, the IoT Operations guide tells you to add the proxy parameters and to put `169.254.169.254` in `--proxy-skip-range`, because Azure Device Registry uses that local endpoint to get its tokens.

The connect works through a list of steps and takes a few minutes. Mine stopped twice before it got that far.

### Detour 1: Pip failed with status code 1

The first stop came before the connect, at `az extension add`:

```text
An error occurred. Pip failed with status code 1. Use --debug for more information.
```

That message only says that pip failed, not why. The reason is in the debug output, so I wrote it to a file and filtered it:

```powershell
az extension add --upgrade --name connectedk8s --debug 2> "$HOME\az-ext.log"
Select-String -Path "$HOME\az-ext.log" `
    -Pattern 'ERROR:|SSL|Retrying|OSError|PermissionError|WinError|PYTHON' |
    Select-Object -Last 15
```

The pattern catches the usual suspects: network and certificate errors, locked files, and a clash with another Python installation. Trimmed, this is what came back:

```text
DEBUG: cli.azure.cli.core.extension.operations: Running:
['C:\\Program Files (x86)\\Microsoft SDKs\\Azure\\CLI2\\python.exe', '-m', 'pip',
'install', '--target', 'C:\\Users\\<user>\\.azure\\cliextensions\\connectedk8s', ...]
Collecting python-dateutil>=2.5.3 (from kubernetes==24.2.0->connectedk8s==1.11.4)
  error: subprocess-exited-with-error
  ModuleNotFoundError: No module named '_ctypes'
error: metadata-generation-failed
```

Two things stand out. The path: `Program Files (x86)`, so this is the 32-bit Azure CLI. And `No module named '_ctypes'`: pip ended up building one of the dependencies of `connectedk8s` from source, which usually means there was no ready-made package for this platform, and the Python that ships inside the 32-bit CLI can't do that build.

The fix is the one Microsoft [recommends anyway](https://learn.microsoft.com/cli/azure/install-azure-cli-windows#migrate-to-64-bit-azure-cli): move to the 64-bit Azure CLI. The 64-bit installer removes the 32-bit version automatically. Extensions have to be reinstalled afterward, so rename the old extension folder first, in case you want to go back:

```powershell
Rename-Item "$HOME\.azure\cliextensions" "cliextensions.x86"

$ProgressPreference = 'SilentlyContinue'
$msi = "$env:TEMP\AzureCLI-x64.msi"
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile $msi
Start-Process msiexec.exe -Wait -ArgumentList '/I', $msi, '/quiet'
Remove-Item $msi
```

Run that as administrator, then close the terminal and open a new one. Check the result and reinstall the extensions:

```powershell
az --version
az extension add --name connectedk8s
az extension add --source <path>\provisionedmachine-1.0.0b5-py3-none-any.whl
```

`az --version` should now show a Python location under `C:\Program Files\`, without `(x86)`. Don't forget the `provisionedmachine` extension from part 2: without it, you can't request a new JIT certificate. A new terminal also means your variables and the `Invoke-Sff` function are gone, so run those blocks again before you continue.

### Detour 2: The pre-onboarding check and the Arc proxy

With the 64-bit CLI, the connect got a lot further:

```text
Step: 2026-10-15T12-58-56Z: Checking Connectivity to Cluster
Step: 2026-10-15T12-58-56Z: Do node validations
...
Step: 2026-10-15T12-59-06Z: Starting Pre-onboarding-check
...
Step: 2026-10-15T12-59-06Z: Pulling HelmChart:
mcr.microsoft.com/azurearck8s/helmchart/stable/clusterdiagnosticchecks, Version: 1.31.2
[AZK8S0601] PrediagnosticsJobExecutionFailed: The pre-onboarding diagnostic job
failed to execute. (500)
Reason: Internal Server Error
...
"message":"Get \"https://<vm-ip>:10250/containerLogs/azure-arc-release/
cluster-diagnostic-checks-job-mjjck/cluster-diagnostic-checks-container\":
proxyconnect tcp: proxy error from 127.0.0.1:6443 while dialing
localhost:40343, code 502: 502 Bad Gateway"
```

The connectivity check passed, so the API server was reachable. The failure is further on. Before it onboards the cluster, `az connectedk8s connect` runs a diagnostic job on it and then reads that job's logs. Reading pod logs goes from the API server to the kubelet on port 10250. And that's where it broke: the API server didn't call the kubelet directly, it went through a proxy at `localhost:40343`.

That port belongs to the Arc proxy, the local forward proxy that comes with the [Arc gateway](https://learn.microsoft.com/azure/azure-arc/servers/arc-gateway). My site uses the Arc gateway (part 2), so on my machine the HTTPS proxy points there. The [K3s install script](https://docs.k3s.io/advanced#configuring-an-http-proxy) copies `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` from the shell you run it in into `/etc/systemd/system/k3s.service.env`. K3s then adds the pod and service ranges and the cluster domain to `NO_PROXY` by itself, but the IP addresses of the nodes are your job. Mine wasn't in there, so K3s sent the traffic for its own kubelet to the Arc proxy, which can't do anything with it.

Neither the small form factor K3s instructions nor the Microsoft script mention this. And it isn't limited to the Arc onboarding: `kubectl logs` and `kubectl exec` fail the same way on a cluster in this state.

Check first what K3s actually got. Open a session with `Invoke-Sff` and look:

```bash
env | grep -i proxy
sudo cat /etc/systemd/system/k3s.service.env
```

On a machine that uses the Arc gateway, you'll find `HTTPS_PROXY=http://localhost:40343` in both. The fix, as the K3s documentation describes it, is to add your node addresses to `NO_PROXY`. I add the whole LAN range, so a new DHCP address for the machine doesn't break it again:

```bash
LAN=192.168.1.0/24          # your LAN range
F=/etc/systemd/system/k3s.service.env
sudo cp "$F" "$F.bak"

if sudo grep -qi '^no_proxy=' "$F"; then
  sudo sed -i -E "s#^(no_proxy=.*)#\1,${LAN}#I" "$F"
else
  echo "NO_PROXY=localhost,127.0.0.0/8,${LAN}" | sudo tee -a "$F"
fi

sudo cat "$F"
sudo systemctl daemon-reload && sudo systemctl restart k3s
```

The `sed` adds the range to every `NO_PROXY` line, whether it's written in uppercase or lowercase. When there's no such line, the script adds one. The proxy itself stays: only traffic within your LAN now goes around it.

After about half a minute, test from Windows:

```powershell
kubectl logs -n kube-system deploy/coredns --tail 3
```

If you see the last lines of the CoreDNS log, the path from the API server to the kubelet works again. Before you run the connect again, check that the failed attempt didn't leave a connected cluster resource behind:

```powershell
az resource list --resource-group $RG --output table
```

If there's a `connectedClusters` resource in the list, remove it with `az connectedk8s delete --name $CL --resource-group $RG --kube-config $kc --yes`. Then run the `az connectedk8s connect` command from the start of this step again.

## Step 3: Service account issuer and custom locations

Once the cluster is connected, two things remain on the cluster side.

The first is the service account issuer. Workload identity federation only works when the cluster issues its service account tokens under the OIDC issuer URL that Azure created during the connect. For K3s that's an API server argument in `/etc/rancher/k3s/config.yaml`. Get the URL first:

```powershell
$issuer = az connectedk8s show --resource-group $RG --name $CL `
    --query oidcIssuerProfile.issuerUrl --output tsv
$issuer
```

Check that `$issuer` really contains a URL before you continue. If it's empty, the next command writes a broken configuration, and K3s might not come back after the restart.

Then write the configuration on the machine:

```powershell
$cmd = "printf 'kube-apiserver-arg:\n - service-account-issuer=$issuer\n" +
       " - service-account-max-token-expiration=24h\n'" +
       " | sudo tee /etc/rancher/k3s/config.yaml"
Invoke-Sff $cmd
```

`printf` runs on the machine, so the file gets Linux line endings no matter where the command comes from. `tee` overwrites the file. In part 2 I installed K3s with command-line options only, so there was no `config.yaml` yet. If you already have one, add the two lines to it instead. The 24-hour token lifetime comes from the same IoT Operations guide.

The second is custom locations. Azure IoT Operations is deployed into a custom location on the cluster, and enabling that feature needs the object ID of the Custom Locations application in your tenant:

```powershell
$OBJECT_ID = az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b `
    --query id --output tsv

az connectedk8s enable-features --name $CL --resource-group $RG `
    --kube-config $kc --kube-context default `
    --custom-locations-oid $OBJECT_ID `
    --features cluster-connect custom-locations
```

The GUID in the lookup is a fixed application ID; use it exactly as written. Run the lookup as a user, not as a service principal, and in the tenant where your Arc resources live. The object ID differs per tenant, and the IoT Operations guide warns that an ID from another tenant seems to work, until the IoT Operations deployment fails on namespace permissions much later.

`cluster-connect` comes along because custom locations depend on it. It's also the feature that lets you reach the cluster API through Azure later on.

Finally, restart K3s so the API server picks up the new issuer:

```powershell
Invoke-Sff "sudo systemctl restart k3s"
```

## Step 4: Verify

The API server is gone for about half a minute after the restart. Then check from the bottom up:

```powershell
kubectl get nodes
kubectl get --raw /.well-known/openid-configuration
az connectedk8s show --resource-group $RG --name $CL `
    --query connectivityStatus --output tsv
kubectl get pods -n azure-arc
```

The node should be `Ready`. The `issuer` field in the OpenID configuration should be the same URL as `$issuer`, which proves that K3s picked up the new configuration. The connectivity status should read `Connected`, and all pods in `azure-arc` should be `Running`.

![Terminal: output of the four verification commands, with the issuer URL matching $issuer and connectivityStatus Connected](placeholder)

![Azure portal > Azure Arc > Kubernetes clusters > linuxsff-k3s, Overview showing Status Connected and Distribution k3s](placeholder)

## Key Things to Know

**Use the 64-bit Azure CLI.** The 32-bit version in `Program Files (x86)` can fail to install `connectedk8s` with nothing more than "Pip failed with status code 1". `az --version` shows which one you have, and the migration takes a few minutes.

**Test port 6443 before you tunnel.** `Test-NetConnection` tells you in a second whether the documented direct route works. A tunnel through the JIT session only adds a failure point.

**The Arc gateway reaches into K3s.** On a machine that uses the Arc gateway, the K3s install script copies the Arc proxy into the K3s service. Add your node addresses to `NO_PROXY` before you connect, not after the pre-onboarding check has failed.

**Everything with sudo goes through JIT.** `clouduser` can't read the kubeconfig or change K3s files. Keep the JIT helper at hand, and when SSH answers with `Permission denied (publickey)`, request a new certificate.

**Check the inputs of step 3.** An empty issuer URL breaks the K3s configuration, and a Custom Locations object ID from the wrong tenant breaks the IoT Operations deployment much later.

## I think

Connecting the cluster to Arc is one command. Everything around it decides whether that command works: which CLI you run it from, how you reach the API server, and which proxy K3s inherited from the machine. The small form factor image is built to send its traffic through the Arc gateway, and K3s can't tell the machine's proxy from its own.

That last one is worth remembering beyond this series. Anything you install on an Arc gateway machine from your shell may take the Arc proxy along.

So, can you now answer these? Is the Azure CLI on your PC 32-bit or 64-bit? What's in your `k3s.service.env`? Why does Azure IoT Operations need the OIDC issuer, and how does the cluster learn about it?

In part 4 I deploy Azure IoT Operations on this cluster: the schema registry, the device registry namespace, `az iot ops init` and `az iot ops create`. If you're following along and hit a detour I didn't, let me know.

Sources:

- [Run containerized workloads on a provisioned machine (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-containerized-workloads?view=azloc-2609)
- [Container orchestrators on small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-container-orchestrators?view=azloc-2609)
- [Prepare a cluster for Azure IoT Operations](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/howto-prepare-cluster)
- [Azure IoT Operations versions, support, and licensing](https://learn.microsoft.com/azure/iot-operations/overview-support)
- [Create and manage custom locations on Azure Arc-enabled Kubernetes](https://learn.microsoft.com/azure/azure-arc/kubernetes/custom-locations)
- [az connectedk8s](https://learn.microsoft.com/cli/azure/connectedk8s)
- [Simplify network configuration requirements with Azure Arc gateway](https://learn.microsoft.com/azure/azure-arc/servers/arc-gateway)
- [Install the Azure CLI on Windows](https://learn.microsoft.com/cli/azure/install-azure-cli-windows)
- [K3s: Configuring an HTTP proxy](https://docs.k3s.io/advanced#configuring-an-http-proxy)
