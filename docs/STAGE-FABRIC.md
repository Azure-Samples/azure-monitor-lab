# Stage Fabric - Microsoft Fabric Real-Time Intelligence

Stage Fabric adds an optional Microsoft Fabric F2 capacity and a guided Real-Time Intelligence scenario. It is disabled by default because F2 bills while active.

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

Setup attempts to create the Event Hub connection and publish the source-to-Eventhouse topology automatically. The Listen-only key is held only in process memory, never printed or persisted, and cleared immediately. Some tenants reject Shared Access Key connection creation through the public Fabric API even though the same connection works in the portal. In that case, create the connection once through the guided portal flow and rerun setup; the script discovers it by endpoint and publishes the topology automatically. Real-Time Dashboard creation remains a guided portal step.

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

Normally `setup-fabric.ps1` creates the Event Hubs connection and publishes the complete Eventstream topology automatically. Confirm that `AzureDiagnosticsRaw` receives events, then create a Real-Time Dashboard from `MonitoringTelemetry`.

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

### 5. Create the Real-Time Dashboard

In the Fabric workspace, select **+ New item** > **Real-Time Dashboard**, name it `Azure Monitor Demo Live Health`, then select **Add data source** > **KQL Database** and connect `MonitoringTelemetry`.

### 6. Add a live tile

Switch to **Editing**, select **New visual**, and use:

```kusto
AzureDiagnosticsRaw
| summarize Events = count() by bin(ingestion_time(), 5m)
| render timechart
```

Select **Done**, then **Save**. Optionally enable **Manage** > **Refresh settings** > **Live refresh**.

### 7. Check Azure health views

In Azure Monitor, open the lab Health Dashboard workbook and confirm the Fabric F2 capacity row. Open `hm-amlab-workload` and confirm the optional **Real-Time Intelligence** tier.

### 8. Suspend F2 when finished

Use the suspend command below. Resume F2 before the next Fabric session.

`start-the-lab.ps1 -Wait` also detects and resumes the optional F2 capacity together with the lab's VMs, VMSS, AKS, and App Service resources.

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