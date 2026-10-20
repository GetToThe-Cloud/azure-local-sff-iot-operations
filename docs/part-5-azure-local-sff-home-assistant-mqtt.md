---
title: "Azure Local | Small Form Factor Part 5 – Bridging Home Assistant to the MQTT Broker"
date: 2026-10-20
categories: [azure, azure-local, infrastructure]
tags: ["Azure", "Azure Local", "Small Form Factor", "Azure IoT Operations", "Home Assistant"]
excerpt: "Azure IoT Operations runs on the small form factor machine, but nothing talks to it yet. In part 5 I bridge the Mosquitto broker in my Home Assistant to the Azure IoT Operations MQTT broker: a TLS listener with X.509 client certificates, one script for the Azure side, and four small surprises on the way."
permalink: /azure-local-small-form-factor-part-5-bridging-home-assistant-to-the-mqtt-broker/
series: "Azure Local small form factor with Azure IoT Operations"
---

The broker is running. Nothing is talking to it.

Part 4 ended with Azure IoT Operations deployed on `linuxsff-k3s`, secure settings enabled and `az iot ops check` passing. I promised a first device and asset for this part. The first real data turned out to come from somewhere closer to home: my Home Assistant. It already knows every sensor in the house, and it already runs an MQTT broker.

So this part connects the two brokers. On the Azure IoT Operations side, that's a dedicated listener with TLS and X.509 client certificates, set up by one PowerShell script. On the Home Assistant side, it's a Mosquitto bridge that forwards a chosen set of topics. At the end, sensor states from Home Assistant arrive on the Azure IoT Operations broker, and you know how to prove that they do.

The Azure side needed no fixes. What cost me time were four small things around the edges: a lost kubeconfig, a broken CLI extension, a folder that didn't exist and a switch that was still off. They're all in here.

## Why a bridge?

The MQTT integration in Home Assistant talks to one broker. I could point it at Azure IoT Operations, but then everything in my house that uses MQTT moves along with it. I don't want the house to depend on a preview deployment in a lab VM.

A bridge keeps the local broker in charge. Mosquitto, which runs as the Mosquitto broker app in Home Assistant, opens its own connection to Azure IoT Operations and forwards only the topics I pick:

| Direction | Topic filter |
| --- | --- |
| Home Assistant to Azure IoT Operations | `homeassistant/statestream/#` |
| Azure IoT Operations to Home Assistant | `aio/to-ha/#` |

The two filters must not overlap. If a topic matches both directions, a message goes out, comes back in, goes out again, and keeps doing that. The script refuses to write a bridge configuration with overlapping filters.

If you'd rather have the MQTT integration talk to Azure IoT Operations directly, the script supports that too, with `-Target HomeAssistant`. I stick to the bridge.

One note on naming. Since [Home Assistant 2026.2](https://www.home-assistant.io/blog/2026/02/04/release-20262/), add-ons are called apps. The Mosquitto broker is the same software, it just sits under a different name in **Settings**.

## What you need

| Component | Requirement |
| --- | --- |
| Instance | `aio-azlsff-01` from part 4 |
| Network | Home Assistant and the machine on the same LAN |
| Home Assistant | Mosquitto broker app, Samba share or Terminal & SSH |
| Tooling | Azure CLI with `azure-iot-ops`, `kubectl`, OpenSSL |

The network line is where a decision from part 1 pays off. The lab VM hangs on an external Hyper-V switch, so it has an address on my LAN and Home Assistant can reach it directly. Behind the NAT switch from Microsoft's network script, you'd need port forwarding first.

OpenSSL comes with Git for Windows. The script finds it there when it isn't in your `PATH`.

## How the Azure side fits together

The broker already has a listener: the default one on port 18883, of type `ClusterIp`, reachable only from inside the cluster. The [connectivity guide](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection) recommends leaving it alone and keeping it for internal Azure IoT Operations traffic. So the script creates a second listener.

That listener is of type `LoadBalancer`. K3s has a built-in load balancer, ServiceLB, that publishes such a service on the node's own address. With the VM on my LAN, Home Assistant reaches the broker on `<vm-ip>:8883`.

There's one rule to know about: [only one listener per service type](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-brokerlistener). If you already have a `LoadBalancer` listener, for example because you used `--add-insecure-listener` in part 4, you can't create a second one. You add a port to the existing one instead. The script checks for this and does exactly that.

The port uses TLS in automatic mode. cert-manager issues the server certificate from the issuer that Azure IoT Operations deployed, `azure-iot-operations-aio-certificate-issuer`, with the node's IP address and host name as subject alternative names. Mosquitto checks those names when it connects, so the address in the bridge configuration has to be in that list.

For authentication I use X.509 client certificates. That brings two certificate authorities into play, and they're easy to mix up:

| CA | Trusted by | Used to check |
| --- | --- | --- |
| Azure IoT Operations quickstart root CA | Mosquitto | The broker's server certificate |
| My own client CA | The AIO broker | Mosquitto's client certificate |

The first one comes with the deployment. Its public part sits in the ConfigMap `azure-iot-operations-aio-ca-trust-bundle`, and the [certificate issuer documentation](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/howto-bring-your-own-issuer#default-self-signed-issuer-and-root-ca-certificate) is clear about it: its subject literally says *Not for Production*. The second one I create myself, put in a ConfigMap and reference from a `BrokerAuthentication` resource. The [authentication documentation](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication#x509) takes the time to warn against confusing the two. It's right to.

## Step 0: Get the session back

Five days after part 4, in a fresh PowerShell window, I ran `kubectl get nodes`. Shortened, it said this:

```text
PS C:\...\scripts> kubectl get nodes
E1020 14:12:49.376227   27520 memcache.go:265] "Unhandled Error" err="couldn't get
current server API group list: Get \"http://localhost:8080/api?timeout=32s\": ..."
...
Unable to connect to the server: dial tcp [::1]:8080: connectex: No connection
could be made because the target machine actively refused it.
```

`localhost:8080` is where `kubectl` goes when it can't find a kubeconfig at all. Mine is `$HOME\.kube\sff.yaml`, and in part 3 I pointed `kubectl` at it with `$env:KUBECONFIG`. That variable lives exactly as long as the PowerShell window. Part 4 sets it again in its first step, and this time I hadn't.

To stop forgetting, make it a user environment variable as well:

```powershell
$env:KUBECONFIG = "$HOME\.kube\sff.yaml"
[Environment]::SetEnvironmentVariable('KUBECONFIG', "$HOME\.kube\sff.yaml", 'User')
kubectl get nodes
```

The first line fixes the current window, the second one every window you open after it.

Then the Azure CLI fell over:

```text
PS C:\...\scripts> az iot ops list -o table
The command failed with an unexpected error. Here is the traceback:
[Errno 13] Permission denied: 'C:\\Users\\<user>\\.azure\\cliextensions\\
azure-iot-ops\\azext_edge\\azext_metadata.json'
...
PermissionError: [Errno 13] Permission denied: ...
```

The CLI couldn't read a file inside its own extension folder. On Windows, that pattern usually means a file that's still locked or half removed: an extension update that didn't finish cleanly, or a second `az` process working in the same folder at the same time. Part 4 runs `az extension add --upgrade --name azure-iot-ops`, so an update is a likely suspect.

The reliable fix is to throw the extension away and install it again. Close other terminals and VS Code windows that might be running `az`, then:

```powershell
Remove-Item "$HOME\.azure\cliextensions\azure-iot-ops" -Recurse -Force
az extension add --name azure-iot-ops
az iot ops list --output table
```

I remove the folder directly instead of using `az extension remove`, because that command can trip over the same file. If `Remove-Item` reports access denied as well, a reboot releases the lock.

## Step 1: Run the script

With `kubectl` and `az` working again, the Azure side is one command. It uses `$RG` and `$AIO` from part 4:

```powershell
.\scripts\Enable-AioHomeAssistantMqtt.ps1 -ResourceGroup $RG -Instance $AIO
```

The script works through these steps:

1. Check the tools and the cluster, and read the node's IP address and name with `kubectl`.
2. Create a client CA and a client certificate with CN `mosquitto-bridge`, both EC P-256, with OpenSSL.
3. Put the client CA in the ConfigMap `ha-client-ca`.
4. Create the authentication policy `ha-x509` with `az iot ops broker authn apply`.
5. Create the `LoadBalancer` listener with TLS port 8883 with `az iot ops broker listener apply`, or add the port to an existing one.
6. Wait for the service to get an external IP, export the AIO root CA and test the connection.
7. Write `bridge-aio.conf` for Mosquitto.

Existing certificates in the output folder are reused, so a second run doesn't invalidate the certificate Home Assistant already has.

The authentication policy is small. This is the file the script applies:

```json
{
  "authenticationMethods": [
    {
      "method": "X509",
      "x509Settings": { "trustedClientCaCert": "ha-client-ca" }
    }
  ]
}
```

`trustedClientCaCert` names the ConfigMap, not a file. That's also why the script only accepts lowercase letters, digits and hyphens for that name. The broker operator uses it as a Kubernetes volume name, and according to the documentation a name with a dot in it makes the reconciliation fail silently.

The listener definition carries the TLS details:

```json
{
  "serviceType": "LoadBalancer",
  "ports": [
    {
      "port": 8883,
      "protocol": "Mqtt",
      "authenticationRef": "ha-x509",
      "tls": {
        "mode": "Automatic",
        "certManagerCertificateSpec": {
          "issuerRef": {
            "name": "azure-iot-operations-aio-certificate-issuer",
            "kind": "ClusterIssuer",
            "group": "cert-manager.io"
          },
          "san": { "dns": [ "<node-name>" ], "ip": [ "<vm-ip>" ] }
        }
      }
    }
  ]
}
```

Both go through `az iot ops`, which is the supported route. Only the ConfigMap uses `kubectl`.

The test at the end deserves a word. The obvious check is `openssl s_client` with the client certificate, but that proves less than it seems. With TLS 1.3, the handshake is complete from the client's point of view before the server has judged the client certificate. And as the [X.509 authentication flow](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication#understand-mqtt-broker-x509-client-authentication-flow) shows, the broker only finishes authentication when the client sends its MQTT CONNECT packet.

So the script does what Mosquitto will do. It validates the server certificate against the AIO root CA, checks that the IP address is in its subject alternative names, presents the client certificate, sends a real MQTT v5 CONNECT and reads the CONNACK. Success means both certificates and the authentication policy work together. The test uses a random client ID, so it never kicks off a bridge that's already connected.

The console output is in Dutch, like the comments in the other scripts in this repo. The line to look for near the end is the `[OK]` line that reports `MQTT CONNECT` as `geslaagd` (succeeded).

![Terminal: the last lines of Enable-AioHomeAssistantMqtt.ps1, with the OK line for MQTT CONNECT and the summary for the Mosquitto bridge](placeholder)

Everything lands in a folder `ha-mqtt-certs` under the current directory, with a `.gitignore` that excludes all of it. Two files deserve care. `ha-client-ca.key` stays on your PC: whoever has it can create certificates the broker accepts. And `aio-broker-ca.crt` is the file you'll copy again one day, as the end of this post explains.

## Step 2: The bridge configuration

The script writes `bridge-aio.conf`. Without its comments, and with my address replaced, it looks like this:

```conf
connection aio-sff
address <vm-ip>:8883
remote_clientid mosquitto-bridge
bridge_protocol_version mqttv311
try_private false
cleansession true
start_type automatic
restart_timeout 10 60
keepalive_interval 60
notifications true
notifications_local_only true

bridge_cafile   /share/mosquitto/certs/aio-broker-ca.crt
bridge_certfile /share/mosquitto/certs/mosquitto-bridge.crt
bridge_keyfile  /share/mosquitto/certs/mosquitto-bridge.key
bridge_insecure false

topic homeassistant/statestream/# out 1
topic aio/to-ha/# in 1
```

Most of it is ordinary Mosquitto. Three settings are there because the broker on the other side isn't Mosquitto.

`try_private false`. By default, a Mosquitto bridge signals to the remote broker that it's a bridge and not an ordinary client. The [mosquitto.conf documentation](https://www.mankier.com/5/mosquitto.conf) notes that not every broker supports that signal, and advises turning it off when a bridge doesn't connect. I turn it off up front.

The `1` at the end of each `topic` line. That's the QoS for the bridged messages. The Azure IoT Operations broker [supports QoS 0 and 1 and rejects every PUBLISH with QoS 2](https://learn.microsoft.com/azure/iot-operations/reference/mqtt-support#broker-limits), and that limit isn't configurable. QoS 1 is the most you can ask for.

`notifications_local_only true`. Mosquitto publishes the state of the bridge as a retained message on `$SYS/broker/connection/mosquitto-bridge/state`. That's useful locally. The broker on the other side has no use for it: it accepts subscriptions to `$SYS` topics but publishes no `$SYS` messages of its own. So the bridge status stays on the Home Assistant side.

And `bridge_insecure false` keeps Mosquitto's check of the server's name and address switched on. That check is why the subject alternative names in step 1 matter.

## Step 3: Get the files into Home Assistant

The Mosquitto app reads extra configuration from a folder under `/share`. Four files go there:

| File | Destination |
| --- | --- |
| `bridge-aio.conf` | `/share/mosquitto/` |
| `aio-broker-ca.crt` | `/share/mosquitto/certs/` |
| `mosquitto-bridge.crt` | `/share/mosquitto/certs/` |
| `mosquitto-bridge.key` | `/share/mosquitto/certs/` |

The first surprise: `/share/mosquitto` didn't exist. Nothing creates it for you, not the app and not the option that reads from it. So create it first, in the Terminal & SSH app:

```bash
mkdir -p /share/mosquitto/certs
```

Or do it in Explorer through the Samba share app, at `\\homeassistant.local\share`. Samba is also the easiest way to copy the files: drag them from `ha-mqtt-certs` into the right folders. If you go that way, check the name of the configuration file. Windows hides file extensions by default, and Mosquitto only loads files that end in `.conf`, so a `bridge-aio.conf.txt` is ignored without a word.

Then check that everything is where it should be:

```text
[core-ssh ~]$ ls -la /share/mosquitto /share/mosquitto/certs
/share/mosquitto:
total 16
drwxr-xr-x    3 root     root          4096 Oct 20 14:50 .
drwxr-xr-x    3 root     root          4096 Oct 20 14:49 ..
-rwxr--r--    1 root     root           974 Oct 20 14:19 bridge-aio.conf
drwxr-xr-x    2 root     root          4096 Oct 20 14:50 certs

/share/mosquitto/certs:
total 20
drwxr-xr-x    2 root     root          4096 Oct 20 14:50 .
drwxr-xr-x    3 root     root          4096 Oct 20 14:50 ..
-rwxr--r--    1 root     root          1280 Oct 20 14:19 aio-broker-ca.crt
-rwxr--r--    1 root     root           660 Oct 20 14:17 mosquitto-bridge.crt
-rwxr--r--    1 root     root           241 Oct 20 14:17 mosquitto-bridge.key
```

Four files, right names, right folders.

`/share` is shared, as the name says, and every app that maps it can read that private key. For one bridge in a lab, I accept that. The certificate only opens one port on one broker, and if it ever leaks, I replace the client CA in the ConfigMap and the old certificate is worthless.

## Step 4: Switch the folder on

The Mosquitto app only reads that folder when you tell it to, with the `customize` option in its configuration:

```yaml
customize:
  active: true
  folder: mosquitto
```

According to the [app documentation](https://github.com/home-assistant/addons/blob/master/mosquitto/DOCS.md), `active` makes the app read additional configuration files, and `folder` is where those `*.conf` files come from.

After a restart of the app I looked for the bridge in its log:

```text
[core-ssh ~]$ ha addons logs core_mosquitto |
  grep -i -E "bridge|error|include|warn"
The use of 'addons' is deprecated, please use 'apps' instead!
time="2026-10-20T14:51:41+02:00" level=error msg="http request error: Post
\"http://127.0.0.1:80/superuser\": read tcp 127.0.0.1:57936->127.0.0.1:80: ..."
time="2026-10-20T14:51:41+02:00" level=error msg="http request error: Post
\"http://127.0.0.1:80/acl\": dial tcp 127.0.0.1:80: connect: connection refused"
...
2026-10-20 14:51:51: Warning: Mosquitto should not be run as root/administrator.
2026-10-20 14:51:51: Bridge support available.
2026-10-20 14:51:52: Protocol error from ::1:34118: First packet not CONNECT (0A).
2026-10-20 14:51:52: Client ::1 [::1:34118] disconnected: protocol error.
```

Plenty of errors, and as far as I can tell none of them is the problem. The HTTP errors come from the app's authentication plugin, which can't reach the app's internal API for a moment around the restart, ten seconds before Mosquitto logs its own start. The protocol error is a local connection that doesn't speak MQTT, most likely the app's own health check. And `Bridge support available.` sounds promising but only means that this Mosquitto build can do bridges. It says that at every start.

What's missing is the line that matters: `Connecting bridge aio-sff`. Mosquitto hadn't loaded the bridge configuration at all. One command later, I knew why:

```text
[core-ssh ~]$ ha apps info core_mosquitto | grep -A2 customize
  customize:
    active: false
    folder: mosquitto
```

`folder` is filled in by default, so the section looks configured at a glance. `active` is what counts, and it was still `false`.

Switch it on in the **Configuration** tab of the app, save and restart. I'd avoid `ha apps options` for this: it can replace the app's options as a whole, and a partial set could wipe the logins you've configured. Note the first line of the earlier output as well. The CLI wants `ha apps` now instead of `ha addons`, in line with the rename.

After the restart, the bridge shows up:

```bash
ha apps logs core_mosquitto | grep -i bridge
```

![Home Assistant > Settings > Apps > Mosquitto broker > Log, showing Connecting bridge aio-sff (<vm-ip>:8883) after the restart](placeholder)

## Step 5: Give the bridge something to carry

A connected bridge with nothing to forward stays quiet. The outgoing filter is `homeassistant/statestream/#`, and nothing in Home Assistant publishes there until you enable [MQTT Statestream](https://www.home-assistant.io/integrations/mqtt_statestream). It publishes the state changes of the entities you select to MQTT.

I started with the `sensor` domain only. An exclude list for the chatty ones is worth adding right away:

```yaml
mqtt_statestream:
  base_topic: homeassistant/statestream
  publish_attributes: false
  include:
    domains:
      - sensor
  exclude:
    entity_globs:
      - sensor.*_uptime
      - sensor.*_signal_strength
```

Without any filter, every entity is included. `sensor` alone can already be busy: power meters, Wi-Fi signal strength and uptime counters change every few seconds, and every change crosses the bridge. Leave `publish_attributes` off for now, because each attribute becomes a topic of its own. Door and motion sensors live in `binary_sensor`, a separate domain you can add later.

Two things to know before you wait for messages. Statestream lives in `configuration.yaml`, so it needs a full restart of Home Assistant, not just a YAML reload. And it publishes on change: a sensor that sits still sends nothing.

Each state lands on `homeassistant/statestream/<domain>/<entity>/state`, and the payload is JSON-serialized. Home Assistant states are strings, so a temperature arrives as `"21.4"`, quotes included. That detail matters in the next part.

## Step 6: Check that it arrives

Start in Home Assistant. Under **Settings > Devices & services > MQTT > Configure**, listen to `homeassistant/statestream/#`. If messages show up there, Home Assistant is publishing.

Then the Azure IoT Operations side, with the test client from the [connectivity guide](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection#connect-to-the-default-listener-inside-the-cluster). It's a pod with the Mosquitto clients that authenticates with a service account token on the default listener:

```powershell
$url = 'https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/' +
       'main/samples/quickstarts/mqtt-client.yaml'
kubectl apply -f $url
kubectl exec --stdin --tty mqtt-client -n azure-iot-operations -- sh
```

Inside the pod, subscribe to the Home Assistant topics:

```bash
mosquitto_sub --host aio-broker --port 18883 \
  --topic "homeassistant/statestream/#" -v \
  --cafile /var/run/certs/ca.crt \
  -D CONNECT authentication-method 'K8S-SAT' \
  -D CONNECT authentication-data $(cat /var/run/secrets/tokens/broker-sat)
```

Every state change shows up as the topic followed by its payload, along the lines of `homeassistant/statestream/sensor/<entity>/state "21.4"`.

![Terminal: mosquitto_sub in the mqtt-client pod, showing homeassistant/statestream/sensor/... messages arriving](placeholder)

Nothing at first? Then it's probably step 5: Home Assistant hasn't restarted yet, or none of your sensors has changed. Add `--debug` to the command. If you see `received CONNACK (0)` and `received SUBACK`, the subscriber is fine and simply waiting.

I haven't needed the return direction yet, but you test it the same way. Listen to `aio/to-ha/#` in the MQTT settings of Home Assistant, and publish from the pod:

```bash
mosquitto_pub --host aio-broker --port 18883 \
  --topic "aio/to-ha/test" --message "hello" \
  --cafile /var/run/certs/ca.crt \
  -D CONNECT authentication-method 'K8S-SAT' \
  -D CONNECT authentication-data $(cat /var/run/secrets/tokens/broker-sat)
```

When you're done, remove the test client:

```powershell
kubectl delete pod mqtt-client -n azure-iot-operations
```

## Where does the data go now?

Nowhere.

That was my own first question once the messages scrolled by. The MQTT broker is a switchboard, not a database. It hands each message to whoever is subscribed at that moment and keeps no history. While the test pod ran, it was the only subscriber. Now nobody listens.

Doing something with the data is the job of [data flows](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/overview-dataflow). A data flow subscribes to topics on the local broker, can filter and reshape the messages, and sends them to an [endpoint](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-dataflow-endpoint): Event Hubs or another Kafka broker, Azure Data Explorer, Microsoft Fabric OneLake, Azure Data Lake Storage, another MQTT broker, local storage or an OpenTelemetry collector. The storage destinations need a schema, and that's where the quoted `"21.4"` comes back.

## When the bridge doesn't connect

**No `Connecting bridge` line at all.** Mosquitto didn't load the file. Check `customize.active`, the folder name and the `.conf` extension, in that order.

**`certificate verify failed` in the log.** Mosquitto no longer trusts the server certificate. cert-manager rotates the quickstart root CA automatically and trust-manager updates the ConfigMap, but your copy in `/share` doesn't follow. Run the script again, which reuses your client certificates, copy the new `aio-broker-ca.crt` and restart the app.

**`Connection refused` or endless reconnects.** Port 8883 isn't reachable from Home Assistant. Check that the service has an external IP with `kubectl get service -n azure-iot-operations` (the script names it `aio-broker-external`, unless it added the port to a `LoadBalancer` listener you already had), and look for a firewall between the two. A service without an external IP usually means ServiceLB is disabled in K3s.

**A new IP address for the VM.** The server certificate carries the address that was valid when you ran the script, and so does `bridge-aio.conf`. If DHCP hands the VM a new one, the bridge connects to the wrong place or to an address that isn't in the certificate. Give the VM a DHCP reservation. After a change, run the script again and copy the new configuration along.

## I think

Bridging Home Assistant to Azure IoT Operations is mostly a certificate exercise. Two CAs, one listener, one authentication policy, and a bridge configuration with a few settings that exist because the other side isn't Mosquitto. The script handles the Azure side. The Home Assistant side is four files and one switch.

The surprises weren't in Azure IoT Operations at all. They were a session variable, a CLI extension, a missing folder and an option that looked configured but wasn't. That's how lab work usually goes.

So, can you answer these for your own setup? Which CA does Mosquitto need, and which one does the broker need? Why does the bridge ask for QoS 1 and not 2? What happens to the bridge when the quickstart CA rotates, and when the VM gets a new address?

In part 6 the data gets a destination: a data flow that picks up the Home Assistant topics and sends them somewhere they're kept. If you bridge your own Home Assistant, I'm curious which topics you send across, and why. And the usual reminder: K3s on small form factor is preview, and the quickstart CA is not for production. Test it on your own setup before anything depends on it.

## Download contents

The script is in the [azure-local-sff-iot-operations](https://github.com/GetToThe-Cloud/azure-local-sff-iot-operations/blob/main/scripts/Enable-AioHomeAssistantMqtt.ps1) repository on GitHub, at `scripts/Enable-AioHomeAssistantMqtt.ps1`. It runs in Windows PowerShell 5.1 and PowerShell 7, and it creates:

- the client CA and the `mosquitto-bridge` client certificate
- the ConfigMap `ha-client-ca` and the authentication policy `ha-x509`
- the `LoadBalancer` listener with TLS port 8883, or a new port on your existing one
- `aio-broker-ca.crt` and `bridge-aio.conf` for Home Assistant

With `-BrokerIp`, `-DnsName`, `-Port`, `-OutTopic` and `-InTopic` you change the defaults. `Get-Help` lists every parameter.

Sources:

- [Secure MQTT broker communication by using BrokerListener](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-brokerlistener)
- [Configure MQTT broker authentication](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication)
- [MQTT feature support in MQTT broker](https://learn.microsoft.com/azure/iot-operations/reference/mqtt-support)
- [Test connectivity to MQTT broker with MQTT clients](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection)
- [Set up your own certificate issuer](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/howto-bring-your-own-issuer)
- [Process and route data with data flows](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/overview-dataflow)
- [Configure data flow endpoints](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-dataflow-endpoint)
- [Mosquitto broker app documentation](https://github.com/home-assistant/addons/blob/master/mosquitto/DOCS.md)
- [MQTT Statestream](https://www.home-assistant.io/integrations/mqtt_statestream)
- [Home Assistant 2026.2 release notes](https://www.home-assistant.io/blog/2026/02/04/release-20262/)
- [mosquitto.conf man page](https://www.mankier.com/5/mosquitto.conf)
