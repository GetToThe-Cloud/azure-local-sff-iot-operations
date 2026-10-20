---
title: "Azure Local | Small Form Factor Part 6 – Home Assistant Data in Azure Data Lake Storage"
date: 2026-10-20
categories: [azure, azure-local, infrastructure]
tags: ["Azure", "Azure Local", "Azure IoT Operations", "Home Assistant", "Data Lake"]
excerpt: "Home Assistant data reaches the Azure IoT Operations broker, and then it disappears. In part 6 a data flow writes it to Azure Data Lake Storage Gen2 as a Delta table: one script for the Azure side, a Home Assistant package for clean JSON, DuckDB to read it, and nothing that has to run around the clock."
permalink: /azure-local-small-form-factor-part-6-home-assistant-data-in-azure-data-lake-storage/
series: "Azure Local small form factor with Azure IoT Operations"
---

Part 5 ended with a question I asked myself while the messages scrolled by: where does the data go now?

Nowhere. The MQTT broker hands each message to whoever is subscribed at that moment and forgets it. To keep anything, you need a data flow and a destination. This part adds both. A data flow on the small form factor machine picks up the Home Assistant states, writes them as a Delta table into Azure Data Lake Storage Gen2, and I read that table from my PC with DuckDB.

The interesting part wasn't the plumbing. It was picking a destination I could afford to leave running, and finding out that the Statestream setup from part 5 couldn't feed a data flow at all. One PowerShell script does the Azure side, one YAML file does the Home Assistant side, and you'll see the first rows from my lab at the end.

## Picking a destination you can leave running

A data flow can write to [several cloud destinations](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-dataflow-endpoint). For sensor history, three are obvious: Azure Data Explorer, Microsoft Fabric OneLake and Azure Data Lake Storage Gen2.

I started with Azure Data Explorer. KQL on time series is a joy, and I had the script written before I did the math. The [free cluster doesn't work](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-adx-endpoint) as a data flow destination, so you need a full cluster. Even the smallest Dev/Test cluster is a VM that has to run as long as data comes in.

Fabric OneLake looked like the cheaper alternative. It isn't. A data flow writes to a lakehouse through a Fabric capacity, and [a paused capacity rejects every OneLake transaction](https://learn.microsoft.com/fabric/onelake/onelake-consumption#paused-capacity). So the capacity has to run as long as data comes in. The smallest one, F2, was announced at [$0.36 per hour, or $262.80 per month](https://blog.fabric.microsoft.com/blog/announcing-microsoft-fabric-capacities-are-available-for-purchase) in US West 2, before you store a single byte.

| Destination | What has to keep running |
| --- | --- |
| Azure Data Explorer | A cluster, 24/7 |
| Fabric OneLake | A Fabric capacity, 24/7 |
| ADLS Gen2 | Nothing. You pay for storage and transactions |

That last row decided it. A storage account with a hierarchical namespace holds the Delta table, and the data flow writes to it in batches. When I want to analyze the data in Fabric later, a lakehouse shortcut points at the storage account, and the capacity only runs while I query.

Sensor history is a slow trickle of small facts. It doesn't need a cluster waiting for it.

## Why Statestream had to go

Part 5 used MQTT Statestream to get states onto the bridge, and I warned that the quoted `"21.4"` would come back. Here it is.

A data flow maps fields out of a message: `entity_id` goes here, `value` goes there. That needs a JSON object with named fields. Statestream publishes something else: one bare value per topic, like `"21.4"` on `homeassistant/statestream/sensor/<entity>/state`. The entity name only exists in the topic. Attributes such as the unit either get a topic of their own or, with `publish_attributes: false` as in part 5, aren't sent at all. There's nothing for a mapping to grab.

So Home Assistant has to publish the object itself. An automation listens to every state change and publishes one JSON message per change on `homeassistant/statestream/json/<entity_id>`. With example values, a message looks like this:

```json
{
  "entity_id": "sensor.living_room_temperature",
  "domain": "sensor",
  "friendly_name": "Living room temperature",
  "state": "21.4",
  "value": 21.4,
  "unit": "°C",
  "device_class": "temperature",
  "last_changed": "2026-10-20T18:04:12.518390Z",
  "last_updated": "2026-10-20T18:04:12.518390Z"
}
```

`state` stays a string, because Home Assistant states can be `on`, `unavailable` or `21.4`. `value` is the same state as a number, or `null` when it isn't one. That gives you something to average without throwing away the text.

The topic sits under `homeassistant/statestream/#`, which the bridge from part 5 already forwards. The bridge doesn't change at all.

## What you need

| Component | Requirement |
| --- | --- |
| Instance | `aio-azlsff-01` from part 4, with its schema registry |
| Bridge | The Mosquitto bridge from part 5 |
| Rights | Owner, or Contributor plus RBAC Administrator |
| Tooling | Azure CLI with `azure-iot-ops`, `kubectl`, DuckDB |

The rights are there because the script creates role assignments: one for the Azure IoT Operations identity to write, and one for you to read. `kubectl` is only for the self-test, and DuckDB only for reading the data afterwards. Make sure `$env:KUBECONFIG` points at the cluster; since part 5 that's a user environment variable, so a new window has it too.

## Step 1: Run the script

The Azure side is one command. It uses `$RG` and `$AIO` from part 4. I keep the data lake in a resource group of its own:

```powershell
.\scripts\Enable-AioHomeAssistantAdls.ps1 `
    -ResourceGroup $RG `
    -Instance $AIO `
    -StorageResourceGroup 'rsg-lz-azlocal-sff-aio-dl-01' `
    -StorageAccount '<storageaccount>'
```

Leave out `-StorageResourceGroup` and the storage account lands next to the instance. Leave out `-StorageAccount` and the script picks `sthasff` plus a hash of your subscription and resource group, the same name on every run. The resource group is created if it doesn't exist, in the region of the instance's resource group unless you pass `-Location`.

The script works through these steps:

1. Check the tools, find the instance, and follow it to the Azure IoT Operations Arc extension and its system-assigned managed identity.
2. Create the storage account and the container `homeassistant`.
3. Give the extension identity Storage Blob Data Contributor on the container, and yourself Storage Blob Data Reader.
4. Add a Delta schema to the schema registry.
5. Create the data flow endpoint `adls-homeassistant` and the data flow `ha-to-adls`.
6. Publish a test message on the broker and wait until it shows up in the Delta table.
7. Write the Home Assistant package and the DuckDB queries to `ha-adls-config`.

Every step reuses what's already there, so a second run only repeats the self-test.

### The storage account

The account is Standard_LRS, StorageV2, with the access tier on Hot. The [ADLS Gen2 tutorial](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/tutorial-opc-ua-to-data-lake) is clear that the hierarchical namespace is required for Azure IoT Operations to write to the account. Hot looks like the expensive choice, but a data flow produces many small writes, and write operations cost more in the cooler tiers.

Account keys are switched off. Everything authenticates with Entra ID: the data flow with its managed identity, DuckDB with your `az login`. Public blob access is off as well, and TLS 1.2 is the minimum.

The roles sit on the container, not on the account. The extension identity can write to that one container and nowhere else.

### The schema

Storage destinations need a schema. The [schema documentation](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/concept-schema-registry) explains why: the data flow serializes to Parquet or Delta, and that format wants to know its columns up front. The script uploads this one as `ha-state-adls`, version 1:

```json
{
  "$schema": "Delta/1.0",
  "type": "object",
  "properties": {
    "type": "struct",
    "fields": [
      { "name": "entity_id", "type": "string",
        "nullable": true, "metadata": {} },
      { "name": "domain", "type": "string",
        "nullable": true, "metadata": {} },
      { "name": "friendly_name", "type": "string",
        "nullable": true, "metadata": {} },
      { "name": "state", "type": "string",
        "nullable": true, "metadata": {} },
      { "name": "value", "type": "double",
        "nullable": true, "metadata": {} },
      { "name": "unit", "type": "string",
        "nullable": true, "metadata": {} },
      { "name": "device_class", "type": "string",
        "nullable": true, "metadata": {} },
      { "name": "last_changed", "type": "timestamp",
        "nullable": true, "metadata": {} },
      { "name": "last_updated", "type": "timestamp",
        "nullable": true, "metadata": {} }
    ]
  }
}
```

Every field is nullable, and that's deliberate. If a field is `nullable: false` and one record lacks it, the data flow drops the entire pending batch, not just that record, and keeps running as if nothing happened. The only trace is a line in the data flow log.

Schema versions are immutable. If you add a column later, run the script with `-SchemaVersion 2`. The script compares an existing version with what it wants and stops with that advice when they differ.

One requirement from part 4 comes back here: `az iot ops schema create` uploads from your PC, so the storage account behind the schema registry needs public network access. If a landing zone policy has closed it since, this is the step that fails.

### The endpoint and the data flow

The endpoint tells Azure IoT Operations where to write and how to authenticate:

```json
{
  "endpointType": "DataLakeStorage",
  "dataLakeStorageSettings": {
    "authentication": {
      "method": "SystemAssignedManagedIdentity",
      "systemAssignedManagedIdentitySettings": {}
    },
    "batching": { "latencySeconds": 300, "maxMessages": 100000 },
    "host": "https://<storageaccount>.blob.core.windows.net"
  }
}
```

I use the system-assigned identity of the Arc extension. The user-assigned cloud identity from part 4 would work too, but then the endpoint needs its client ID and tenant ID. The system-assigned one needs nothing but the role assignment.

The batching is the setting that matters for your bill. The [endpoint documentation](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-adlsv2-endpoint#advanced-settings) gives 60 seconds as the default. I raised it to 300, more on that further down. `-LatencySeconds` changes it.

The data flow itself has three operations. Shortened to the essentials, it reads:

```json
{
  "mode": "Enabled",
  "operations": [
    {
      "operationType": "Source",
      "sourceSettings": {
        "endpointRef": "default",
        "serializationFormat": "Json",
        "dataSources": [ "homeassistant/statestream/json/#" ]
      }
    },
    {
      "operationType": "BuiltInTransformation",
      "builtInTransformationSettings": {
        "serializationFormat": "Delta",
        "schemaRef": "aio-sr://<schema-namespace>/ha-state-adls:1",
        "map": [
          { "inputs": [ "entity_id" ], "output": "entity_id" },
          { "inputs": [ "value" ],     "output": "value" },
          { "inputs": [ "last_changed" ], "output": "last_changed" }
        ]
      }
    },
    {
      "operationType": "Destination",
      "destinationSettings": {
        "endpointRef": "adls-homeassistant",
        "dataDestination": "homeassistant"
      }
    }
  ]
}
```

The real file maps all nine fields, one by one. The tutorials use a single wildcard mapping, `*` to `*`, and that's shorter. But with Delta, a wildcard expands to every field in the incoming message, and a field the schema doesn't declare gets the record dropped. Explicit mappings ignore extra fields. If Home Assistant ever sends one more key, nothing breaks.

`default` as the source endpoint is the local broker, so the data flow reads the topics the bridge delivers. `dataDestination` is the container. The Delta table ends up in a folder with the same name, so the full path is `homeassistant/homeassistant/` with a `_delta_log` folder next to the Parquet files.

![Azure portal > Storage account > Containers > homeassistant > folder homeassistant, showing the _delta_log folder and part-*.snappy.parquet files (authentication method: Microsoft Entra user account)](placeholder)

## The self-test, and a pod that said Ready too early

The script doesn't trust a green provisioning state. It deploys the `mqtt-client` sample pod from the [connectivity guide](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection), publishes a message for a fake entity `sensor.aio_selftest` with a random number as its state, and then reads the Delta log in the container until a new commit shows up. When a commit carries statistics, they hold the minimum and maximum `entity_id` of its rows, so the script can tell its own message from live Home Assistant data that lands in the same batch.

The first run ended like this:

```text
    [WARN] ... faalde (exit 127):
sh: mosquitto_pub: not found
command terminated with exit code 127
```

The script was still in Dutch at the time, hence the `faalde` (failed). The rest needs no translation. The sample pod is an Alpine container that installs the Mosquitto clients with `apk add` after it starts, and Kubernetes reports it as Ready before that install finishes. My script waited for Ready and ran `mosquitto_pub` straight away.

The fix is to wait for the tool, not for the pod:

```powershell
$deadline = (Get-Date).AddMinutes(3)
while ($true) {
    $chk = Invoke-Native $kubectl @('exec', 'mqtt-client', '-n', $ns, '--',
        'sh', '-c', 'command -v mosquitto_pub') -AllowFailure
    if ($chk.ExitCode -eq 0) { break }
    if ((Get-Date) -gt $deadline) { throw 'mosquitto_pub is still missing.' }
    Start-Sleep -Seconds 5
}
```

If it times out, the real script shows the last lines of the pod log. The likely cause then is a cluster that can't reach `dl-cdn.alpinelinux.org`.

The same applies to part 5, by the way. If you open a shell in that pod right after `kubectl apply` and get `not found`, give `apk` a minute.

Two more waits are built in. Your own read access to the container is brand new, and Azure RBAC can take a few minutes to catch up, so a 403 makes the script retry for up to ten minutes. And the data flow writes at most once per batch window, so the self-test waits the batch time plus ten minutes before it gives up.

![Terminal: the end of Enable-AioHomeAssistantAdls.ps1, with the OK line for the test message in the Delta table and the summary with the Delta table path](placeholder)

## Step 2: Home Assistant publishes JSON

The script writes `aio_adls.yaml`. My first attempt was to paste the automation into the automation editor, in YAML mode. Home Assistant refused to save it, both in YAML and after I rebuilt it in the visual editor. I didn't chase the cause. I moved the automation into a [package](https://www.home-assistant.io/docs/configuration/packages/), which doesn't depend on the editor or on `automations.yaml`, and where the configuration check points at the exact line if something is wrong.

This is the package, without its header comments:

```yaml
automation:
  - id: aio_states_json_mqtt
    alias: AIO - states as JSON to MQTT
    mode: queued
    max: 500
    max_exceeded: silent
    variables:
      domains:
        - sensor
      exclude: "_(uptime|rssi|signal_strength|last_boot)$"
    triggers:
      - trigger: event
        event_type: state_changed
    conditions:
      - condition: template
        value_template: >-
          {% set n = trigger.event.data.new_state %}
          {% set o = trigger.event.data.old_state %}
          {{ n is not none
             and n.domain in domains
             and (exclude == '' or n.entity_id is not search(exclude))
             and (o is none or o.state != n.state) }}
    actions:
      - action: mqtt.publish
        data:
          topic: "homeassistant/statestream/json/{{ trigger.event.data.entity_id }}"
          qos: 1
          retain: false
          payload: >-
            {% set n = trigger.event.data.new_state %}
            {{ {
              'entity_id': n.entity_id,
              'domain': n.domain,
              'friendly_name': n.name,
              'state': n.state,
              'value': n.state | float(none),
              'unit': n.attributes.get('unit_of_measurement') or '',
              'device_class': n.attributes.get('device_class') or '',
              'last_changed': n.last_changed.strftime('%Y-%m-%dT%H:%M:%S.%fZ'),
              'last_updated': n.last_updated.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
            } | to_json }}
```

It triggers on every `state_changed` event and lets the condition do the filtering: only the domains in `domains`, no entities that match `exclude`, and only real state changes. An attribute that changes on its own doesn't produce a row. `float(none)` turns a non-numeric state into `null`, and `to_json` makes sure the payload is valid JSON whatever a friendly name contains. Home Assistant keeps `last_changed` in UTC, which is what the trailing `Z` claims.

`mode: queued` matters on a busy house. With the default mode, a second state change while the first one is still publishing would be dropped.

To install it:

1. Create the folder `/config/packages` with the File editor or Studio Code Server app, and put `aio_adls.yaml` in it.
2. In `configuration.yaml`, add `packages: !include_dir_named packages` under the existing `homeassistant:` key. Don't add a second `homeassistant:` key.
3. Remove the `mqtt_statestream:` block from part 5. The data flow ignores those topics, and they only double the traffic over the bridge.
4. Run **Developer tools > YAML > Check configuration** and restart Home Assistant.

After the restart, the automation shows up in the list with its traces. You change it in the file, not in the editor.

## Step 3: Check that it arrives

Check one link of the chain at a time. Start in Home Assistant under **Settings > Devices & services > MQTT > Configure**, and listen to `homeassistant/statestream/json/#`.

Then wait. A sensor that doesn't change publishes nothing, and that's where I lost ten minutes. The quicker way is to force a change: under **Developer tools > States**, pick a `sensor.` entity, set its state to `99` and select **Set state**. That's a real state change as far as the automation is concerned, and the next sensor update puts the real value back.

![Home Assistant > Settings > Devices & services > MQTT > Configure, listening to homeassistant/statestream/json/# with a JSON state message received](placeholder)

If nothing appears even then, publish a test message from the same page to `homeassistant/statestream/json/test`. If you see that one, listening works and the problem is the automation. Open it and look at its traces.

I did exactly that, with `{"test": 1}` as the payload. Remember it, because it shows up again in a minute.

## Reading the Delta table with DuckDB

There's nothing to deploy for reading. [DuckDB](https://duckdb.org/docs/current/core_extensions/delta.html) reads Delta tables straight from the storage account, with its `azure` and `delta` extensions and your Azure CLI login. Install it once and open a new terminal:

```powershell
winget install DuckDB.cli
```

The script left `query-duckdb.sql` in `ha-adls-config`. The part that does the work:

```sql
INSTALL azure; LOAD azure;
INSTALL delta; LOAD delta;
CREATE OR REPLACE SECRET ha (TYPE azure, PROVIDER credential_chain,
    CHAIN 'cli', ACCOUNT_NAME '<storageaccount>');

SELECT last_changed, friendly_name, state, value, unit
FROM delta_scan('abfss://homeassistant@<storageaccount>.dfs.core.windows.net/homeassistant')
ORDER BY last_changed DESC
LIMIT 20;
```

`CHAIN 'cli'` means DuckDB borrows the token from `az login`, and the Storage Blob Data Reader role from step 1 does the rest. The `abfss://` scheme is the [Data Lake Storage route](https://duckdb.org/docs/current/core_extensions/azure.html) through the `dfs` endpoint. The file also has a second query with 15-minute averages per sensor over the last day.

My first run, from the folder the script ran in:

```text
PS C:\...\scripts\ha-adls-config> duckdb -c ".read query-duckdb.sql"
...
┌───────────────────────────────┬───────────────┬─────────┬──────────┬─────────┐
│         last_changed          │ friendly_name │  state  │  value   │  unit   │
│   timestamp with time zone    │    varchar    │ varchar │  double  │ varchar │
├───────────────────────────────┼───────────────┼─────────┼──────────┼─────────┤
│ 2026-10-20 16:47:19.035071+02 │ AIO self-test │ 550896  │ 550896.0 │ test    │
│ 2026-10-20 16:28:06.561521+02 │ AIO zelftest  │ 623588  │ 623588.0 │ test    │
│ NULL                          │ NULL          │ NULL    │     NULL │ NULL    │
└───────────────────────────────┴───────────────┴─────────┴──────────┴─────────┘
```

Three rows, and no sensors yet. Each row tells a story.

The two self-test rows are the runs of the script: the first from the Dutch version, the second after I switched it to English. Same pipeline, different `friendly_name`. Note the `+02`. The table stores UTC; DuckDB shows it in the time zone of my PC.

The row of nulls is my `{"test": 1}`. It matched the topic filter, crossed the bridge and went through the data flow. None of the mapped fields were in it, and the schema says every field may be null, so it became an empty row. That's the nullable behavior from the schema section, working as designed. It's also proof that the whole chain works, from the MQTT page in Home Assistant to a Parquet file in Azure.

And the sensors? The automation had been running for about six minutes at that point. Between sensors that hadn't changed yet and a batch window of 300 seconds, the first batch with real data most likely hadn't landed. Three minutes later it had.

![Terminal: DuckDB query-duckdb.sql output with real Home Assistant sensors, their values and units](placeholder)

To keep the test rows out of your results, filter them:

```sql
SELECT last_changed, friendly_name, state, value, unit
FROM delta_scan('abfss://homeassistant@<storageaccount>.dfs.core.windows.net/homeassistant')
WHERE entity_id IS NOT NULL AND entity_id <> 'sensor.aio_selftest'
ORDER BY last_changed DESC
LIMIT 20;
```

## What it costs, and what it doesn't do

With nothing running in Azure, the bill is storage plus operations. Storage for a house full of sensors is small. Operations are where the batching comes in.

Every batch the data flow writes is a Parquet file plus a commit in `_delta_log`, and each of those is a handful of write operations. At the default of 60 seconds, a steady stream of state changes means up to 1,440 batches a day. At 300 seconds it's 288. The data is five minutes later in the lake, which is irrelevant for sensor history, and there are five times fewer small files to write and, later, to read. I'll check Cost Management after a week for the real number, but the order of magnitude is set by those batches, not by a capacity or a cluster.

The setup deliberately leaves a few things out:

- No compaction. The table collects small files, which DuckDB handles fine at this scale. A Spark job with `OPTIMIZE` can merge them later.
- No retention. Don't point a lifecycle rule at the table folder: deleting Parquet files behind Delta's back leaves a log that refers to files that are gone.
- No dashboards. A Fabric lakehouse shortcut or Power BI can read the table, but that's a choice for later.

## When nothing shows up

**No JSON in the MQTT listener.** It's the Home Assistant side. Check that the package loaded (the automation is in the list), look at its traces, and force a state change under **Developer tools > States**.

**JSON in Home Assistant, nothing in the lake.** Check whether the messages reach the Azure IoT Operations broker with `mosquitto_sub` in the `mqtt-client` pod, exactly as in part 5, but on `homeassistant/statestream/json/#`. If they arrive there, the data flow is next: find its pod with `kubectl get pods -n azure-iot-operations` and read the log of the `aio-dataflow` pod.

**`AuthorizationPermissionMismatch` or 403 in the data flow log.** The role assignment for the extension identity hasn't propagated yet, or sits on another container than the data flow writes to. Wait ten minutes and run the script again; it reuses everything and checks the role.

**`ParquetEncoding` errors in the data flow log.** The message doesn't fit the schema. With the nullable schema and explicit mappings from this post that shouldn't happen, but it's the first thing to look for after you change either one.

**Rows with only nulls.** A message on the topic without the expected fields, like my test message. Harmless, and easy to filter on `entity_id IS NOT NULL`.

## I think

Sending Home Assistant data to Azure is mostly a matter of picking the destination that doesn't need to stay awake. A storage account with a Delta table costs storage and operations, and everything that reads it, from DuckDB on my PC to a Fabric shortcut, can come and go.

The two things that cost me time had nothing to do with storage: Statestream sends values where a data flow needs objects, and a sample pod that reports Ready before its tools are installed.

So, can you answer these for your own setup? Why does every field in the schema stay nullable? What happens to a message with an extra field under a wildcard mapping, and under explicit mappings? What does a longer batch window buy you, and what does it cost?

Where this goes next is open: a Fabric shortcut and a dashboard on top of this table, or the return topic `aio/to-ha` that has been waiting since part 5. Tell me which one you'd like to see first. And as always: K3s on small form factor is preview. Test this on your own setup before anything depends on it.

## Download contents

The script is in the [azure-local-sff-iot-operations](https://github.com/GetToThe-Cloud/azure-local-sff-iot-operations/blob/main/scripts/Enable-AioHomeAssistantAdls.ps1) repository on GitHub, at `scripts/Enable-AioHomeAssistantAdls.ps1`. It runs in Windows PowerShell 5.1 and PowerShell 7, and it creates:

- the storage account with hierarchical namespace and the container `homeassistant`
- the role assignments for the Azure IoT Operations extension identity and for you
- the Delta schema `ha-state-adls`, the endpoint `adls-homeassistant` and the data flow `ha-to-adls`
- `aio_adls.yaml` for Home Assistant and `query-duckdb.sql`, plus the endpoint, data flow and schema files it applied

With `-Container`, `-SourceTopic`, `-LatencySeconds`, `-SchemaVersion` and `-SkipSelfTest` you change the defaults. `Get-Help` lists every parameter.

Sources:

- [Configure data flow endpoints](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-dataflow-endpoint)
- [Configure data flow endpoints for Azure Data Lake Storage Gen2](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-adlsv2-endpoint)
- [Tutorial: Send data from an OPC UA server to Azure Data Lake Storage Gen 2](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/tutorial-opc-ua-to-data-lake)
- [Understand message schemas](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/concept-schema-registry)
- [Configure data flow endpoints for Azure Data Explorer](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-adx-endpoint)
- [OneLake compute and storage consumption](https://learn.microsoft.com/fabric/onelake/onelake-consumption)
- [Announcing Microsoft Fabric capacities are available for purchase](https://blog.fabric.microsoft.com/blog/announcing-microsoft-fabric-capacities-are-available-for-purchase)
- [Test connectivity to MQTT broker with MQTT clients](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection)
- [Home Assistant packages](https://www.home-assistant.io/docs/configuration/packages/)
- [DuckDB Delta extension](https://duckdb.org/docs/current/core_extensions/delta.html)
- [DuckDB Azure extension](https://duckdb.org/docs/current/core_extensions/azure.html)
