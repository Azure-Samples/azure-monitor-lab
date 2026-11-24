# Optional telemetry ingestion stage

**Status:** default-off infrastructure and bounded senders are implemented and tested offline. No Azure deployment, table-plan check, on-host pipeline install, or live ingestion verification was performed for this change. Do not claim that all seven scenarios work end to end until their separate evidence gates pass.

## What is deployed

Stage 90 adds a dedicated DCE and two Analytics tables in the existing central Log Analytics workspace: `TelemetryIngestionOperational_CL` and `TelemetryIngestionDiagnostic_CL`. A baseline DCR routes the same 100 JSON events to both; a transformed DCR routes only the 50 Error/Warning events to both. The input stream is `Custom-TelemetryIngestion`; the DCRs are `dcr-<prefix>-telemetry-ingestion-baseline` and `dcr-<prefix>-telemetry-ingestion`. An optional *separate* `dcr-<prefix>-telemetry-ingestion-tiered` routes 50 Error/Warning events to the operational Analytics table and 50 Debug events to the new `TelemetryIngestionVerbose_CL` Auxiliary table. No existing `SecurityAudit_CL` or custom-logs DCR is changed.

All DCRs preserve `RunId`, `EventId`, `SampleSetId`, `TimeGenerated`, `Severity`, `Workload`, and `Message` and omit `DebugField` to conform to fixed table schemas. The baseline retains the **synthetic** user and original-case severity; transformed/tiered profiles derive lowercase `NormalizedSeverity` and replace `SyntheticUser` with `[REDACTED]`. One upload per profile uses one DCR with two data flows in one workspace; routing the input stream to two *different* workspaces with the same DCR is not supported. Provisioned outputs include the DCE endpoint, DCR IDs/immutable IDs and table IDs/plans. Verify the actual deployed plans and streams before sending.

## Prerequisites and opt-in

- Deploy Stage A first, including its central workspace; keep DCE, DCRs and workspace in the same supported region. Ensure the deploying identity can create DCRs, DCEs and tables. Optional role assignments require permission to grant access.
- PowerShell 7 and Azure CLI signed into the **intended subscription** are needed for the send/verify scripts. The scripts reject a different subscription/tenant when the local `.azure-target.json` specifies one.
- A sender needs **Monitoring Metrics Publisher** on the exact selected DCR, and the verifier needs workspace query access (for example **Log Analytics Reader** on the central workspace). Supplying `senderPrincipalId` to Stage 90 grants the former to that service principal/managed identity on the scenario DCRs, not workspace reader access. Empty means no sender roles are granted. A signed-in CLI user or the separate Control Center runner identity still needs its own grants.
- The Control Center additionally requires its optional Stage B runner. When the ingestion DCRs are present, bootstrap grants that runner Monitoring Metrics Publisher on the exact scenario DCRs and Log Analytics Reader on the central workspace, using the existing scoped-role helper. The Tiered option is enabled only after its DCR and Auxiliary table plan are separately confirmed. The deployer needs role-assignment permission on these resources; do not grant the runner subscription-wide roles.
- Auxiliary eligibility, regional support, retention, query behavior, and billing must be checked in the selected tenant before setting its flag. The optional Auxiliary table uses the `2025-07-01` Tables API; the older `2022-10-01` API does not support the `Auxiliary` plan. Native OTLP is a **separate experimental opt-in**: enabling its flag provisions a dedicated direct-logs DCR and installs a local-only Collector on the existing Linux VM in the scripted one-shot path. Offline validation cannot settle the documented direct-stream/URL discrepancy or prove ingestion.

For the one-shot deployment, merge these settings into `lab.config.json` rather than replacing existing groups:

```json
{
  "advancedConfiguration": {
    "stageToggles": { "enableStageTelemetryIngestion": true },
    "telemetryIngestion": {
      "enableAuxiliary": false,
      "enableNativeOtlp": false,
      "telemetryIngestionSenderPrincipalId": ""
    }
  }
}
```

The sample configuration documents the fields. All flags default off; enabling Auxiliary requires the stage. To run Stage 90 **after** an existing Stage A deployment, review the target and use the exact central workspace ID/name:

```powershell
az deployment group what-if --subscription '<sub>' --resource-group '<rg>' `
  --template-file infra/stages/90-telemetry-ingestion.bicep `
  --parameters namePrefix='<prefix>' location='<workspace-region>' `
    centralWorkspaceId='<central-workspace-arm-id>' centralWorkspaceName='<workspace-name>' `
    enableAuxiliary=false senderPrincipalId=''
# Only with separate approval, replace "what-if" with "create" and retain the same arguments.
```

Terraform's optional `terraform/telemetry-ingestion.tf` deploys the compiled Stage 90 template, behind its default-off stage flag. Verify the selected subscription and stage variables before planning/applying. This document and the commands above do **not** authorize a deployment.

## Run and verify after an approved deployment

Use synthetic events only. `send-telemetry-ingestion.ps1` produces 100 fixed IDs (`event-001` through `event-100`) with a fresh run ID. It sends a UTF-8 JSON batch of at most 1 MiB and retries only bounded transient HTTP responses. The sender checks each destination by default, with a five-minute deadline; `-SkipVerification` distinguishes an accepted request from later ingestion, **not** success.

```powershell
$sub = '<subscription-guid>'
$rg = '<resource-group>'
$prefix = '<deployed-prefix>'
./scripts/send-telemetry-ingestion.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -Profile Baseline
./scripts/send-telemetry-ingestion.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -Profile Transformed
# Only after the Auxiliary table and tiered DCR/plan are checked:
./scripts/send-telemetry-ingestion.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -Profile Tiered
# To investigate a previously accepted run without uploading again:
./scripts/test-telemetry-ingestion.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -Profile Transformed -RunId '<printed-run-guid>'
```

Use a **new run ID** after each profile change; the fixture definitions and IDs remain the same. Baseline expects 100 exact IDs in each Analytics table; Transformed expects 50 in each; Tiered expects 50 Operational Analytics and 50 Verbose Auxiliary. Each query is independent; the verifier checks duplicate, missing and unexpected IDs, workload/message schema, normalization and `[REDACTED]` masking. Tiered queries Auxiliary through the workspace `/search` endpoint and the Analytics table through `/query`. HTTP 204, a DCR resource existing, or a successful query against just one destination does not prove delivery to both.

For negative checks in a separately approved test environment, submit malformed or mismatched JSON against the dedicated DCR and inspect its explicit HTTP failure; remove publisher permission from a **test identity only** to observe denial; deny a verifier's workspace query to confirm it fails rather than reporting an empty success. Recheck permissions and restore any test grants. Invalid DCR transforms require a reviewed deployment change, not a production demo toggle. Investigate table plan, DCR stream/output mapping, diagnostics, ingest latency, query permission and exact run ID if a destination times out. These negative cases and DCR propagation have not been live tested.

## Native OTLP, edge, and combined scenarios

The separate [OTLP guide](../workloads/telemetry-ingestion/otel/README.md) provides a native HTTP/protobuf log sender and pinned Collector. Its loopback receiver is not the JSON ingestion API. With the native flag on, the scripted one-shot path provisions a separate native logs DCR and sets up the Collector on the existing VM; it still needs a bounded live compatibility probe before claiming that 100 resource/scope/record-tagged logs arrived in `OTelLogs`. The existing application exporters are not redirected.

The [edge guide](../workloads/telemetry-ingestion/edge/README.md) describes a separate, default-off **Azure Monitor pipeline** option. When `advancedConfiguration.stageToggles.enableStageAzureMonitorPipeline` is explicitly true for the scripted one-shot deployment, it installs a small single-node K3s cluster on the **existing** lab Linux VM, connects that cluster to Azure Arc, installs the managed certificate and pipeline extensions, and deploys a scenario-owned Syslog DCR, associations and publisher role. It does **not** create another VM or an AKS cluster, and is independent of `enableStageTelemetryIngestion`. Set a compatible `vmSize` explicitly; the default 2-vCPU VM is rejected. Changing `vmSize` in an existing lab's main deployment can **resize and restart both Linux and Windows VMs**; the pipeline option never chooses a SKU for you. Confirm the preview's region/permissions and extra host/ingestion costs before opting in. The read-only SSH readiness check installs nothing even with `-OptIn`; it remains useful before a separately approved staged experiment. Its Syslog policy marks 40 Debug IDs for edge removal and targets the standard `Syslog` table; the 100 received / 40 filtered / 60 forwarded counts and exact cloud IDs still need live evidence. Restore the filtered policy after a bypass run and stop any loopback port forward; do not remove ordinary VM/AMA resources.

**Combined scenario remains experimental:** when both the JSON ingestion stage and the Arc pipeline flag are on, the scripted path configures a *structured RFC5424 Syslog* edge-to-two-custom-table variant: 40 marked events are filtered at the edge, 50 Error/Warning IDs target Operational Analytics, and all 60 retained IDs target Diagnostic Analytics. This is **not** OTLP-to-custom-table fan-out or the 50/10 Auxiliary combined variant. Verify each listener, DCR, association, identity and exact cloud ID set before claiming that this composition works. See [scenarios 82–88](DEMO-SCENARIOS.md#s82) and the [implementation plan](TELEMETRY-INGESTION-PLAN.md) for all acceptance criteria and evidence gates.

## Cost and cleanup

Every retained destination may incur separate Analytics/Auxiliary ingestion and retention charges; search/query, DCE/diagnostics and optional host/Arc resources can add cost. Repeating the 100-record run or using fan-out changes usage. Verify actual regional prices and measured usage in the [cost guide](COST-GUIDE.md). The optional resources are scenario-owned in the lab resource group; before removing them, identify exact DCRs, DCE, tables and any sender/runner role assignments. A deleted DCR does not automatically clean up an independently installed Arc cluster or extension; do not remove the shared lab workspace, VM, AMA, existing custom logs or other users' resources. No extra host or external resource was created by this change.
