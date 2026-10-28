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
- Workspace identity, with **Azure Event Hubs Data Receiver** assigned only at the lab's `diagnostics` event hub
- Keyless Event Hubs connection and published **Extended** Eventstream source, default stream and Eventhouse destination
- Real-Time Dashboard `Azure Monitor Demo Live Health`, bound to the KQL database item GUID, with wide ingestion-rate and parsed recent-telemetry tiles
- Four explicitly labelled synthetic operational/business events in `LabSampleEvents` and a correlation dashboard tile (unless sample seeding is disabled). These are not real orders, customer activity, or evidence that the live stream works.
- Azure Monitor connections and explicit mirrored catalogs for **both central and Application Insights Log Analytics**, unless mirroring is explicitly disabled
- Separate `Azure Monitor Mirrored Logs - Central` and `Azure Monitor Mirrored Logs - Application Insights` dashboards, with numbers, charts, detail tables and source-receipt/freshness metrics
- A daily **20:00 UTC** suspension schedule for the lab capacity, unless explicitly disabled

Setup provisions or reuses the workspace identity, assigns hub-scoped receiver access, creates a **Workspace identity** connection and publishes `AzureEventHubExtended`. The Basic `AzureEventHub` source does **not** support WorkspaceIdentity; selecting Extended features is essential, not a portal-versus-API workaround. Setup never retrieves shared keys, enables local authentication, or overwrites an existing connection's credentials. `NotEncrypted` is the connector's required connection-encryption enum, not a request to disable transport TLS.

These operations require Fabric workspace administration and source-scoped Azure RBAC administration. Keep `disableLocalAuth=true` on Entra-only namespaces. An existing Basic connection is preserved and reported for action rather than silently converted. New sources start at `Latest`; old Event Hub messages are not replayed. See [Event Hubs source authentication](https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/add-source-azure-event-hubs).

Setup polls Eventstream failures and checks for rows ingested into `AzureDiagnosticsRaw` in the last 15 minutes. Its default verification window is 180 seconds, configurable up to 900 seconds. Empty/missing tables remain **Pending**, not healthy; API/authorization/query failures are reported explicitly. A final feature-by-feature summary shows what succeeded and what still requires action. Failures cause setup to throw after reporting results; the main deployment reports optional Fabric setup failure without undoing infrastructure.

Reruns reuse existing items and preserve user-edited dashboards and mirror definitions. Sample rows are deduplicated by their stable synthetic IDs. A conflicting mirror source/table selection is reported, not overwritten. Custom Eventstream nodes are not replaced: use a distinct `EventstreamName` or `-SkipEventstreamConnection`. A workspace on another capacity is rejected rather than moved or coupled to the wrong suspension schedule.

Mirroring and daily suspension default on **within the optional Fabric stage**. Existing explicit `false` values in local config remain opt-outs; update them to adopt these defaults. Both Log Analytics workspaces default to **3 GB/day each**, not a shared 3 GB budget. The cap can still interrupt ingestion; it is not a total-cost limit. No live Azure caps or tenant settings are changed merely by updating these scripts.

The Azure Monitor workbook reports the ARM capacity state and provisioning state. Active is Green; Paused or Suspended is Orange; failed provisioning is Red. Fabric Eventstream is a tenant-scoped SaaS item rather than an ARM resource, so its item and data-flow status is inspected in the Fabric workspace instead of queried directly by the Azure workbook.

## Prerequisites

- Microsoft Fabric enabled for the tenant
- Permission to create Fabric workspaces
- Capacity administrator or contributor access
- A Microsoft Entra user UPN from the deployment tenant for `fabricAdminEmail`; an external alert or guest notification address is not sufficient
- Stage A deployed if the Eventstream will use the lab Event Hub
- Azure CLI and PowerShell 7+
- Fabric workspace-admin permission to provision its identity
- Azure role-assignment write permission at the source event hub and both source Log Analytics workspaces; custom-role administration to create the source mirroring roles
- Tenant admin enables **Mirrored catalog item** under **OneLake catalog > Govern > Configurations > Tenant settings**. Capacity admin/Azure Owner alone does not grant this tenant role.
- Review Fabric workspace membership before enabling mirrors: Azure Monitor table/row/column protections do not carry into Fabric

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

`deploy.ps1` calls `setup-fabric.ps1` automatically when Fabric is enabled. Run it separately to resume pending provisioning or after resolving a reported prerequisite. No Eventstream or dashboard editing is needed for a fresh supported deployment with the prerequisites satisfied.

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

If setup reports an identity or RBAC error, resolve that specific permission and rerun. Newly granted permissions can take time to propagate. For a deliberately manual pipeline, choose Azure Event Hubs **Extended features**, **Workspace identity**, consumer group `$Default`, and an Eventhouse destination targeting `MonitoringTelemetry.AzureDiagnosticsRaw`. Basic-source WorkspaceIdentity errors cannot be fixed by publishing the same Basic source in the portal. Never enable shared-key authentication to bypass the error.

Use `-SkipEventstreamConnection` to keep all connection and topology configuration manual.

## After deploy.ps1 checklist

### 1. Read the setup result

If the terminal says `Eventstream source and Eventhouse destination configured`, continue to step 3.

### 2. Resolve any reported prerequisite

If an API, identity or source-authorization step failed, correct the reported cause, then rerun:

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

Open `Azure Monitor Demo Live Health` in the workspace. Its data source is already `MonitoringTelemetry`; the tiles show envelope/batch ingestion rate, parsed recent diagnostics, and (by default) a separately labelled synthetic business-correlation example. New dashboards use vertically stacked, 24-unit-wide tiles with height at least 7. Empty live tiles do not prove a healthy stream: use the setup verification result.

The dashboard's Fabric data source binds to the KQL database **item ID**, not its display name. If every tile reports `Entity ID ... of kind 'Database' was not found`, edit the dashboard data source and reselect the existing `MonitoringTelemetry` database, then save. Setup preserves existing dashboards, so rerunning it does not repair an older binding.

The recent-telemetry tile expands diagnostic `records` batches into individual events and shows time, resource, category, level, HTTP method/path/status/duration, message, and metric name/average. Fields that do not apply to an event remain empty; nested JSON-string HTTP properties are parsed automatically.

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

The daily 20:00 UTC schedule is enabled by default by Fabric setup. It is not an idle detector. Resume F2 before the next Fabric session; you can also suspend it immediately with the command below.

`start-the-lab.ps1 -Wait` also detects and resumes the optional F2 capacity together with the lab's VMs, VMSS, AKS, and App Service resources.

## Automation settings

The setup helpers read `fabricAutomation` directly from `lab.config.json`; these settings do not need ARM/Terraform parameter projection. Explicit script parameters override config. The Cloud Shell wrapper exposes the same options.

```json
"fabricAutomation": {
  "workspaceName": "Azure Monitor Demo Lab",
  "seedSampleData": true,
  "verificationTimeoutSeconds": 180,
  "enableMirroring": true,
  "mirrorConnectionId": "",
  "mirrorScope": [],
  "mirrorTables": ["AzureActivity", "ContainerLogV2", "AppServiceHTTPLogs", "Perf"],
  "appInsightsMirrorConnectionId": "",
  "appInsightsMirrorTables": ["AppRequests", "AppDependencies", "AppExceptions", "AppTraces"],
  "enableAutoSuspend": true,
  "autoSuspendHourUtc": 20,
  "autoSuspendMinuteUtc": 0
}
```

For multiple lab resource groups in the same tenant, set a distinct `workspaceName` for each one. The same name is honored during setup and teardown; explicit `-WorkspaceName` overrides config. Never point a lab's teardown at another lab's workspace.

### Azure Monitor mirroring (preview)

1. A tenant administrator enables the **Mirrored Azure Monitor** preview. Review Fabric workspace access first: preview Log Analytics table/row/column protections do not carry into Fabric.
2. With the default `enableMirroring=true`, setup discovers both lab Log Analytics workspaces in the explicit resource group and reads their **customer GUIDs**, not their ARM IDs. It reuses an exact source connection or creates a same-tenant WorkspaceIdentity connection through the supported connector API.
3. For each new mirror connection, setup creates a resource-group-available custom role with exactly `Microsoft.OperationalInsights/workspaces/read`, `Microsoft.OperationalInsights/workspaces/query/read`, and **`Microsoft.Authorization/roleAssignments/write`**, assigned to the workspace identity **only at that source LAW**. The last permission is privileged; do not extend these assignments to a resource group/subscription. No Owner role, client secret, shared key, tenant toggle or Fabric membership change is created.
4. Setup enumerates selectable scopes and their leaf namespaces, mounts the explicit allowlist, and creates `Azure Monitor Demo Mirrored Logs` (central) and `Azure Monitor Demo Mirrored App Insights`. `mirrorConnectionId` and `appInsightsMirrorConnectionId` optionally select existing authorized connections; an ID targeting another LAW is rejected. Multiple selectable scopes require an explicit `mirrorScope` for central.
5. Setup starts both mirrors before waiting up to 15 minutes per source for the automatically provisioned Eventhouse endpoint/external tables. It creates each dashboard as soon as its endpoint is discoverable and verifies the **saved** queries. Provisioning/empty data remains **Pending**, not Verified. Resolve missing collection or rerun after an unusually long service delay if necessary; no arbitrary database or synthetic telemetry substitutes for mirrored logs.

Only the explicit `mirrorTables`/`appInsightsMirrorTables` allowlists are mounted. A missing/ambiguous table stops that source's creation and reports an action; setup never falls back to mirroring every table. Preview discovery only returns tables with recent streaming data. Adjust the list explicitly if your enabled stages collect different tables. Existing mirrored items are reused without changing their source or selection.

The Application Insights dashboard has **14 tiles**: six numeric cards, four time-series charts and four tables covering sampling-adjusted requests/exceptions, server errors, weighted latency percentiles, dependencies, endpoint reliability and freshness. The central dashboard has **10 tiles** over the selected infrastructure tables. Numeric visuals serialize as lowercase `multistat`, with explicit `Metric`/`Value` mappings; cards are 12x7, charts at least 12x7, and tables 12/24x8, with no overlapping tiles.

Queries use `external_table('AppRequests')` and equivalent external tables, not ordinary KQL table names. **Source receipt delay** is `_TimeReceived - TimeGenerated`, excluding negative intervals from percentiles and reporting missing/negative receipt counts separately. Latest-event age is `now() - max(TimeGenerated)`. Neither is end-to-end Fabric mirror latency. `_ReceivedTime` must not be used for this calculation because its rounding can produce misleading negative values. Counts use `ItemCount` sampling weights and duration percentiles use `percentilew` for Application Insights.

Data remains in Azure Monitor Delta storage, exposed through read-only OneLake shortcuts. Allow about 15 minutes and verify data separately; catalog creation or a Running status is not proof of available rows. Preview does not backfill historical data. See [scenario 80](DEMO-SCENARIOS.md#s80), [the MirroredCatalog definition API](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/mirrored-catalog-definition), and [the preview guidance](https://learn.microsoft.com/fabric/mirroring/catalog-mirroring/azure-monitor).

### Default daily suspension

Fabric setup defaults `enableAutoSuspend=true` at 20:00 UTC. Override the hour/minute in config, or run the standalone helper explicitly:

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

Full lab teardown also removes the tenant-scoped workspace and its contained Eventhouse, KQL databases, Eventstream, mirrors and dashboards before deleting the resource group. Generated mirror connection objects and the workspace identity's source-LAW-scoped mirroring assignments are removed; unused generated custom roles are deleted, while definitions still assigned elsewhere are preserved with a warning. Independently named preauthorized connections are not deleted. A workspace assigned to another capacity is rejected. To run only that cleanup:

```powershell
./scripts/setup-fabric.ps1 -SubscriptionId '<subscription-id>' -ResourceGroup '<resource-group>' -Teardown
```

The standalone helper honors the root config's `namePrefix` unless explicitly overridden; use a distinct `workspaceName` for each lab. Tenant resources are not removed by `terraform destroy` alone.

## Capacity Metrics credentials

The Metrics app is the one non-scriptable scenario: install it from Microsoft's link using a capacity administrator with Power BI Pro/PPU/trial, then connect it to the correct capacity. If it reports **Data source Extension is missing credentials**, open the app's workspace, select its semantic model **Settings > Data source credentials > Edit credentials**, and authenticate with the appropriate organizational account/OAuth in the same tenant. Apply the app's required capacity parameters and refresh. Azure CLI login, Azure Owner, or assigning a Fabric workspace identity does not supply these Power BI OAuth credentials. A missing tenant-settings page requires a Fabric tenant administrator (including activating an eligible role), not merely capacity administration.

## Authorization troubleshooting

`Unable to authorize with Azure Active Directory` during `Microsoft.Fabric/capacities` creation means the administrator value could not be authorized in the deployment tenant. Confirm that:

1. `fabricAdminEmail` is not empty.
2. It is a Microsoft Entra user UPN in the subscription tenant, not an external alert address.
3. The user can sign in to Microsoft Fabric and the tenant has Fabric enabled.

Use your deployment tenant's actual Microsoft Entra user UPN, not the fictitious example address. The portal, Bicep, config-sync, and Terraform inputs require a separate Fabric administrator value. `setup-fabric.ps1` also compares the signed-in Azure CLI user with the deployed capacity administrators before requesting a Fabric API token.

## Demo scenarios

See scenarios [74 through 80](DEMO-SCENARIOS.md#s74), including the guided [Mirror Azure Monitor data](DEMO-SCENARIOS.md#s80) preview scenario. The [README architecture](../README.md#architecture) shows Fabric alongside the shared Azure Monitor operational path and distinguishes Azure capacity from tenant-scoped items.

For staged Bicep deployment, deploy Stage Fabric before Stage E, or rerun `40-optional-advanced.bicep` with `enableFabric=true` afterward so the Real-Time Intelligence tier is added to the Health Model. Terraform enforces this dependency automatically.