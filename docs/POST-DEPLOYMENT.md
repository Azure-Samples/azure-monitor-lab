# Manual scenario setup

Deployment is complete before this guide begins. The normal deployment scripts intentionally leave some portal, data-plane, and demo-identity tasks to the presenter. Complete only the rows for scenarios you plan to use.

| Scenario | Remaining step | Applies to |
|---|---|---|
| [4 - Managed Grafana](DEMO-SCENARIOS.md#s4) | Sign in to Grafana and import dashboard `19623`. | All deployment methods when demonstrating this dashboard. |
| [27 - Granular RBAC](DEMO-SCENARIOS.md#s27) | Run `./scripts/setup-rbac-demo.ps1 -ResourceGroup $resourceGroup`, wait up to 15 minutes for ABAC propagation, and send sample records with `./scripts/send-custom-logs.ps1 -ResourceGroup $resourceGroup -Count 10`. | All deployment methods when demonstrating access as the three test identities. |
| [32 - Grafana alerting](DEMO-SCENARIOS.md#s32) | Run `./scripts/setup-grafana-alerts.ps1 -ResourceGroup $resourceGroup`. | All deployment methods when demonstrating Grafana-managed alert rules. |
| [43 - Microsoft Sentinel](DEMO-SCENARIOS.md#s43) | On first use, connect the deployed workspace to the unified Defender portal if the tenant is not already onboarded. Required Defender and workspace roles must be assigned separately. | Only when Sentinel was enabled. |
| [46 - SLIs and SLOs](DEMO-SCENARIOS.md#s46) | Create `sli-aks-pods-running` and `sli-aks-pod-start-latency` in the Azure portal using the URL and resource IDs printed by the setup script. | Only when the Health Model and SLI prerequisites were deployed. |

The SLI helper verifies prerequisites but intentionally does not create the preview `Microsoft.Monitor/slis` resources. Wait until it confirms all four source metric families are flowing, follow the exact fields in Scenario 46, and allow 10-15 minutes for evaluated metrics to appear.

## SRE Agent

This section applies only when the optional SRE Agent stage was enabled. Infrastructure deployment creates the Sweden Central agent, identities, RBAC, and monitoring connectors. The setup script validates those resources but does not create portal-owned investigators or response plans.

Before running Scenarios [55 through 59](DEMO-SCENARIOS.md#s55):

1. Open the deployed agent in `sre.azure.com`.
2. Connect Azure Monitor under **Incidents > Triggers & response plans** if it is not already connected.
3. Create `amlab-app-investigator` and `amlab-platform-investigator` using the instructions in [Stage SRE Agent](STAGE-SRE-AGENT.md).
4. Create the `amlab-app-alerts` and `amlab-platform-alerts` response plans in Review mode.
5. Confirm both response plans are On before generating incidents.

The exact investigator instructions, filters, and response-plan values are in [Scenario 54](DEMO-SCENARIOS.md#s54).

## Other conditional features

These features are deployed only when selected in the portal or enabled in the deployment configuration. They do not require another general post-deployment script.

| Feature | What remains after deployment |
|---|---|
| [VM OpenTelemetry metrics](STAGE-B-WORKLOADS.md#optional-vm-opentelemetry-metrics) | Enabled by default alongside classic VM Insights unless `enableVmOtelMetrics=false`. Allow AMA configuration and metrics to arrive in the existing AMW; verify both views. No extra setup script. Incremental redeployment with `false` does not remove existing OTel associations; use the linked targeted opt-out. |
| [Platform Logs DCR](DEMO-SCENARIOS.md#s51) | Nothing when `enablePlatformLogsDcr` was enabled successfully. If it was disabled, enable the flag and redeploy before using the scenario. |
| [Metrics Export DCR](DEMO-SCENARIOS.md#s52) | Nothing when `enableMetricsExportDcr` was enabled successfully. If it was disabled, enable the flag and redeploy before using the scenario. |
| [LAW replication](DEMO-SCENARIOS.md#s41) | Allow replication to become active when it was enabled. If disabled, enable it and provide a secondary region before redeploying. |
| [SIEM webhook](DEMO-SCENARIOS.md#s38) | Nothing when a valid `siemWebhookUrl` was supplied. Otherwise provide the external endpoint and redeploy before demonstrating fan-out. |
| [AI FinOps](DEMO-SCENARIOS.md#s53) | Allow generated telemetry to arrive after the applicable AI setup script completes. Skip this scenario when the AI stage was not enabled. |

## Optional demo data preparation

These actions are not required to complete deployment. Run them shortly before the corresponding demonstration when you need fresh or visible data.

| Scenario | Preparation |
|---|---|
| [13 - Smart Detection](DEMO-SCENARIOS.md#s13) | Run `./scripts/start-ramp.ps1 -ResourceGroup $resourceGroup` and allow time for anomaly detection. |
| [18 - Code Optimizations](DEMO-SCENARIOS.md#s18) | Run `./scripts/trigger-code-optimization.ps1 -ResourceGroup $resourceGroup`; recommendations can take 1-24 hours. |
| [19 - Predictive autoscale](DEMO-SCENARIOS.md#s19) | Allow about 14 days of metric history for the prediction chart. |
| [24 - Custom logs](DEMO-SCENARIOS.md#s24) | Run `./scripts/send-custom-logs.ps1 -ResourceGroup $resourceGroup -Count 10`. |
| [28 - Checkout metrics](DEMO-SCENARIOS.md#s28) | Send requests to `/api/checkout`. |
| [29 - Profiler and Snapshot Debugger](DEMO-SCENARIOS.md#s29) | Generate slow requests and exceptions, then allow time for collection. |
| [43 - Microsoft Sentinel](DEMO-SCENARIOS.md#s43) | Generate a new qualifying Activity Log event after ingestion is active. Historical events do not backfill. |

## Already handled

After the required wrapper for your deployment path succeeds, no separate setup is needed for the baseline Health Model, Service Group, summary rule, Managed Prometheus rule group, security posture alerts, App Service sample, or AKS OpenTelemetry workloads. Follow the individual scenario instructions only to generate demo traffic, trigger an alert, or change a feature during the presentation.

See [scripts/README.md](../scripts/README.md) for the complete script catalog and [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md) for all scenario walkthroughs.
