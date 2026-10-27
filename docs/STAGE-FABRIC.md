# Stage Fabric - Microsoft Fabric Real-Time Intelligence

Stage Fabric adds an optional Microsoft Fabric F2 capacity and automated Real-Time Intelligence setup. It is disabled by default because F2 bills while active. Automation uses supported Fabric/Kusto APIs; it does not bypass tenant consent, preview enablement, source authorization, or app licensing.

## Cost warning

The deployment is pinned to **F2 in Sweden Central**. Indicative Microsoft PAYG retail pricing is:

| Active time | Approximate F2 compute cost |
|---|---:|
| 1 hour | $0.36 USD |
| 24 hours | $8.64 USD |
| 1 month | $262.80 USD |

Actual pricing varies by agreement, currency, and region. OneLake storage and other Fabric meters can add charges. Suspend the capacity whenever the demo is idle.

> Microsoft currently recommends at least four capacity units (F4) for Eventstreams. This lab intentionally pins to F2 to limit demo cost. F2 is suitable for light, short-lived sample traffic but can throttle under sustained ingestion; use the Capacity Metrics app in scenario 78 to show that tradeoff.

## Architecture

```text
App Service and AKS
        |
        v
Azure Event Hubs diagnostics
        |
        v
Fabric Eventstream
        |
        v
Eventhouse and KQL database
        |
        v
Real-Time Dashboard and KQL exploration
```

Azure Monitor remains the operational monitoring system. Fabric demonstrates streaming analytics, broader event correlation, and Real-Time Intelligence over the same application estate.

## What is automated

The Bicep or Terraform deployment creates:

- One `Microsoft.Fabric/capacities` resource
- SKU fixed to `F2`
- Location fixed to `swedencentral`
- Capacity administrator set to the explicit `fabricAdminEmail` tenant user UPN
- A **Real-Time Intelligence** tier in `hm-amlab-workload`, with the F2 capacity represented as an Azure resource entity using Resource Health
- A dynamic **Fabric F2 Capacity Health** section in the main Azure Monitor Health Dashboard workbook, discovered through Azure Resource Graph

After deployment, `setup-fabric.ps1` creates or reuses:

- Fabric workspace
- Eventhouse
- Read-write KQL database
- Empty Eventstream
- Real-Time Dashboard `Azure Monitor Demo Live Health`, connected to the KQL database, with live ingestion rate and recent raw telemetry tiles
- Four explicitly labelled synthetic operational/business events in `LabSampleEvents` and a correlation dashboard tile (unless sample seeding is disabled). These are not real orders, customer activity, or evidence that the live stream works.

Setup attempts to create the Event Hub connection and publish the source-to-Eventhouse topology automatically. The Listen-only key is held only in process memory, never printed or persisted, and cleared immediately. Some tenants reject Shared Access Key connection creation through the public Fabric API even though the same connection works in the portal. In that case, create the connection once through the guided portal flow and rerun setup; the script discovers it by endpoint and publishes the topology automatically.

Setup polls Eventstream failures and checks for rows ingested into `AzureDiagnosticsRaw` in the last 15 minutes. Its default verification window is 180 seconds, configurable up to 900 seconds. Empty/missing tables remain **Pending**, not healthy; API/authorization/query failures are reported explicitly. A final feature-by-feature summary shows what succeeded and what still requires action. Failures cause setup to throw after reporting results; the main deployment reports optional Fabric setup failure without undoing infrastructure.

Reruns reuse existing items and preserve user-edited dashboards and mirror definitions. Sample rows are deduplicated by their stable synthetic IDs. Changing dashboard/table-selection configuration does not overwrite existing item definitions; use the portal to change an existing item or create a deliberately separate item.

Two additional experiences are opt-in: mirrored Azure Monitor catalog creation from a preauthorized connection, and a daily UTC capacity-suspension Logic App. See the automation settings below.

The Azure Monitor workbook reports the ARM capacity state and provisioning state. Active is Green; Paused or Suspended is Orange; failed provisioning is Red. Fabric Eventstream is a tenant-scoped SaaS item rather than an ARM resource, so its item and data-flow status is inspected in the Fabric workspace instead of queried directly by the Azure workbook.

## Prerequisites

- Microsoft Fabric enabled for the tenant
- Permission to create Fabric workspaces
- Capacity administrator or contributor access
- A Microsoft Entra user UPN from the deployment tenant for `fabricAdminEmail`; an external alert or guest notification address is not sufficient
- Stage A deployed if the Eventstream will use the lab Event Hub
- Azure CLI and PowerShell 7+

## One-shot deployment

Set the Fabric toggle in `lab.config.json` and replace the fictitious `admin@example.com` with a Microsoft Entra user UPN from your deployment tenant:

```json
"stageToggles": {
  "enableStageFabric": true
},
"fabricAdminEmail": "admin@example.com"
```

Then deploy and configure the Fabric items:

```powershell
./scripts/deploy.ps1
```

`deploy.ps1` calls `setup-fabric.ps1` automatically when Fabric is enabled. Run `setup-fabric.ps1` separately only when the deployment output asks you to create a connection and rerun, or when resuming setup after a timeout.

Fabric item creation is asynchronous and can be slower on F2. The setup script waits up to 30 minutes by default, honors the service `Retry-After` header, and prints operation IDs and progress. Override the ceiling with `-MaxOperationMinutes <5-120>`. If a caller times out, the Fabric operation can still finish; rerun the same command safely and the script will reuse every item that already exists.

## Staged Bicep deployment

```powershell
az deployment group create `
  --subscription '<subscription-id>' `
  --resource-group '<resource-group>' `
  --name stage-fabric-capacity `
  --template-file infra/stages/60-fabric.bicep `
  --parameters namePrefix=amlab fabricAdminEmail=admin@example.com

./scripts/setup-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>'
```

## Terraform deployment

Set `enable_stage_fabric = true` in `terraform/stages.tfvars`, then run:

```powershell
terraform -chdir=terraform plan -var-file stages.tfvars
terraform -chdir=terraform apply -var-file stages.tfvars
./scripts/setup-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>'
```

## Complete the Eventstream in Fabric

Normally `setup-fabric.ps1` creates the Event Hubs connection and publishes the complete Eventstream topology automatically. It also provisions the dashboard and checks that `AzureDiagnosticsRaw` receives recent events.

Some tenants reject Event Hubs Shared Access Key credentials through the public Fabric Connections API even though the portal supports them. In that case, create only the connection once:

1. Open `AzureMonitorEvents`, switch to **Edit** mode, and select **Add source** > **Connect data sources** > **Azure Event Hubs**.
2. Create a **Shared Access Key** connection for the deployed namespace and the `diagnostics` Event Hub.
3. Use Shared Access Key Name `diagnostics-listen` and retrieve its primary or secondary key from **Event Hubs namespace** > **Shared access policies**. Do not use `diagnostics-send`; it cannot consume events.
4. Set Consumer group to `$Default`, Data format to **JSON**, and Data gateway to **none**.
5. After the connection test succeeds, cancel before adding or publishing the source.
6. Rerun `setup-fabric.ps1`. It discovers the connection by Event Hub endpoint and publishes the source, default stream, and `MonitoringTelemetry` Eventhouse destination automatically.

Use `-SkipEventstreamConnection` to keep all connection and topology configuration manual.

## After deploy.ps1 checklist

### 1. Read the setup result

If the terminal says `Eventstream source and Eventhouse destination configured`, continue to step 3.

### 2. Complete the one-time connection fallback

If connection creation was rejected, follow the connection-only steps above. Cancel before adding or publishing topology, then rerun:

```powershell
./scripts/setup-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>'
```

### 3. Verify the stream

Open `AzureMonitorEvents` in **Live** view and confirm events arrive from the `diagnostics` Event Hub.

### 4. Verify ingestion

Open `MonitoringTelemetry` and run:

```kusto
AzureDiagnosticsRaw
| take 10
```

### 5. Open the automatically provisioned dashboard

Open `Azure Monitor Demo Live Health` in the workspace. Its data source is already `MonitoringTelemetry`; the tiles show ingestion rate, recent raw diagnostics, and (by default) a separately labelled synthetic business-correlation example. Empty live tiles do not prove a healthy stream: use the setup verification result.

### 6. Customize if desired

No tile creation is required. To add your own visual, switch to **Editing**, select **New visual**, and use:

```kusto
AzureDiagnosticsRaw
| summarize Events = count() by bin(ingestion_time(), 5m)
| render timechart
```

Select **Done**, then **Save**. The generated dashboard refreshes every five minutes; tune refresh and service-specific parsing for your demo. Setup preserves your edits on rerun.

### 7. Check Azure health views

In Azure Monitor, open the lab Health Dashboard workbook and confirm the Fabric F2 capacity row. Open `hm-amlab-workload` and confirm the optional **Real-Time Intelligence** tier.

### 8. Review remaining actions and suspend F2 when finished

Install the Capacity Metrics app once if needed (capacity administrator plus Power BI Pro/PPU/trial). There is no documented public API to install this app, so setup reports **ActionRequired** rather than pretending it is installed. See [Microsoft's installation guide](https://learn.microsoft.com/fabric/enterprise/metrics-app-install).

Use the suspend command below, or explicitly enable the daily schedule. Resume F2 before the next Fabric session.

`start-the-lab.ps1 -Wait` also detects and resumes the optional F2 capacity together with the lab's VMs, VMSS, AKS, and App Service resources.

## Automation settings

The setup helpers read `fabricAutomation` directly from `lab.config.json`; these settings do not need ARM/Terraform parameter projection. Explicit script parameters override config. The Cloud Shell wrapper exposes the same options.

```json
"fabricAutomation": {
  "seedSampleData": true,
  "verificationTimeoutSeconds": 180,
  "enableMirroring": false,
  "mirrorConnectionId": "",
  "mirrorScope": [],
  "mirrorTables": ["AzureActivity", "ContainerLogV2", "AppServiceHTTPLogs", "Perf"],
  "enableAutoSuspend": false,
  "autoSuspendHourUtc": 20,
  "autoSuspendMinuteUtc": 0
}
```

### Azure Monitor mirroring (preview)

1. A tenant administrator enables the **Mirrored Azure Monitor** preview. Review Fabric workspace access first: preview Log Analytics table/row/column protections do not carry into Fabric.
2. Authorize an Azure Monitor connection to the lab's **central** Log Analytics workspace once in Fabric. Prefer workspace identity where supported; the necessary source RBAC and interactive consent remain administrator/user actions. Setup does not create service-principal secrets or grant itself additional source access.
3. Set `enableMirroring=true` and `mirrorConnectionId` to that Fabric connection GUID, then rerun setup. Without an explicit ID, setup only reuses a unique Azure Monitor/Log Analytics connection whose returned path contains the exact central workspace ARM ID.
4. Setup discovers selectable source scopes and tables using the catalog discovery APIs, creates the `Azure Monitor Demo Mirrored Logs` catalog item, and reports its status. If the connection exposes multiple selectable scopes, set `mirrorScope` to the exact `fullyQualifiedScope` array returned by Fabric discovery. An explicitly supplied connection ID is the operator's selection of the authorized source; ensure it targets central Log Analytics.

Only the explicit `mirrorTables` allowlist is mounted. A missing/ambiguous table stops creation and reports an action; setup never falls back to mirroring every table. Adjust the list explicitly if your enabled stages collect different tables. Existing mirrored items are reused without changing their source or selection.

Data remains in Azure Monitor Delta storage, exposed through read-only OneLake shortcuts. Allow about 15 minutes and verify data separately; catalog creation or a Running status is not proof of available rows. Preview does not backfill historical data. See [scenario 80](DEMO-SCENARIOS.md#s80), [the MirroredCatalog definition API](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/mirrored-catalog-definition), and [the preview guidance](https://learn.microsoft.com/fabric/mirroring/catalog-mirroring/azure-monitor).

### Opt-in daily suspension

Set `enableAutoSuspend=true` and the desired UTC hour/minute, or run:

```powershell
./scripts/setup-fabric-auto-suspend.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>' -Enabled $true -HourUtc 20 -MinuteUtc 0
```

This deploys a Consumption Logic App with a managed identity authorized **only to read and suspend this one capacity**. Creating its custom role and assignment requires RBAC administration permissions. Its first run is in the future, at least 15 minutes after configuration; setup never immediately suspends F2. Execution history is available in the Logic App.

This is a fixed daily schedule, **not an idle detector**. It interrupts active queries and ingestion and can incur Logic Apps transaction charges. It does not automatically resume F2. Set `enableAutoSuspend=false` and rerun setup (or run the helper with `-Enabled $false`) to disable an existing schedule without changing capacity state. Disabled schedules/role definitions remain until teardown. The setup helper uses an ARM deployment for all deployment methods; these extra resources are outside Terraform state and are removed with the lab resource group, not by `terraform destroy` alone.

## Suspend and resume

```powershell
./scripts/suspend-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>'
./scripts/resume-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>'
```

Both commands require confirmation by default and verify the explicit subscription before changing the capacity.

Full lab teardown also removes the tenant-scoped workspace and its contained Eventhouse, KQL database, and Eventstream before deleting the resource group. To run only that cleanup:

```powershell
./scripts/setup-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>' -Teardown
```

## Authorization troubleshooting

`Unable to authorize with Azure Active Directory` during `Microsoft.Fabric/capacities` creation means the administrator value could not be authorized in the deployment tenant. Confirm that:

1. `fabricAdminEmail` is not empty.
2. It is a Microsoft Entra user UPN in the subscription tenant, not an external alert address.
3. The user can sign in to Microsoft Fabric and the tenant has Fabric enabled.

Use your deployment tenant's actual Microsoft Entra user UPN, not the fictitious example address. The portal, Bicep, config-sync, and Terraform inputs require a separate Fabric administrator value. `setup-fabric.ps1` also compares the signed-in Azure CLI user with the deployed capacity administrators before requesting a Fabric API token.

## Demo scenarios

See scenarios [74 through 80](DEMO-SCENARIOS.md#s74), including the guided [Mirror Azure Monitor data](DEMO-SCENARIOS.md#s80) preview scenario. The [README architecture](../README.md#architecture) shows Fabric alongside the shared Azure Monitor operational path and distinguishes Azure capacity from tenant-scoped items.

For staged Bicep deployment, deploy Stage Fabric before Stage E, or rerun `40-optional-advanced.bicep` with `enableFabric=true` afterward so the Real-Time Intelligence tier is added to the Health Model. Terraform enforces this dependency automatically.