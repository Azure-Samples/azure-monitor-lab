# Azure Monitor Lab — Deployment Summary

**Deployed:** _yyyy-mm-dd_
**Subscription:** `<your-subscription-name>` (`<your-subscription-id>`)
**Tenant:** `<your-tenant-id>`
**Resource Group:** `rg-azure-monitor-lab`
**Region:** North Europe (App Service pinned to West Europe; optional AI stage + Health Model pinned to Sweden Central)

---

## What's running

This is the primary-resource inventory. Child resources, deployment records, policy-generated diagnostics, role assignments, and provider-managed resources can increase the portal count.

| Resource | Name / URL |
|---|---|
| Resource group | `rg-azure-monitor-lab` |
| Central Log Analytics workspace | `law-amlab-central-<suffix>` |
| App Insights LAW | `law-amlab-appinsights-<suffix>` |
| Application Insights | `appi-amlab-<suffix>` |
| Azure Monitor Workspace (Managed Prometheus) | `amw-amlab` |
| Data Collection Endpoint | `dce-amlab` |
| DCR — VM Insights | `dcr-amlab-vminsights` |
| DCR — Prometheus | `dcr-amlab-prometheus` |
| VNet / NSG | `vnet-amlab` / `nsg-amlab` |
| Linux VM (Ubuntu 22.04) | `vm-amlab-lin` |
| Windows VM (Win 2022) | `vmwin<suffix>` |
| AKS cluster | `aks-amlab` (1 × Standard_B2s system node by default) |
| Linux VM auto-shutdown | `shutdown-computevm-vm-amlab-lin` (23:00 CET/CEST) |
| Windows VM auto-shutdown | `shutdown-computevm-vmwin<suffix>` (23:00 CET/CEST) |
| VM scale set | `vmss-amlab` (1 × Standard_B1s by default) |
| Azure Managed Grafana | https://amg-amlab-<suffix>.cse.grafana.azure.com |
| App Service (Linux B1, **West Europe**) | https://app-amlab-<suffix>.azurewebsites.net |
| App Service diag sinks (**West Europe**) | `stapp-amlab<suffix>` (archive) · `evhns-amlab-<suffix>` (stream) |
| AKS frontend (LoadBalancer) | http://<public-ip> |
| Action Group | `ag-amlab-email` → `<your-alert-email>` |
| Alert processing rules | Maintenance, disabled low-severity, and conditional VM auto-shutdown suppression |
| Control Center runner | Basic ACR, Container Apps environment/job, managed identity, diagnostics, custom roles, and scoped assignments |
| Workbook | **Azure Monitor Lab — Traffic Lights** |

> **Optional AI stage** (off by default) adds, in **Sweden Central**: a Microsoft Foundry account `ai<amlab><suffix>` + project `amlab-ai-proj`, `gpt-5-mini` / `text-embedding-3-small` / `gpt-5.4` / `model-router` deployments, `gen_ai.*` App Insights tracing, token anomaly + spike alerts, an AI FinOps query pack + workbook, and an AI tier in the workload health model.

The one-shot deployment also includes custom-log ingestion resources, workspace transforms, storage/Event Hubs/Key Vault telemetry sinks, Heartbeat export, a Prometheus rule group, the workload health model, and the SLI identity. Sentinel is enabled by the one-shot default but belongs to optional Stage E in staged deployments. Platform/metrics export DCRs, LAW replication, SRE Agent, and Observability Agent are conditional.

> **VM OpenTelemetry metrics are on by default:** `enableVmOtelMetrics` defaults to `true`, adding `dcr-<prefix>-vm-otel` and `vm-otel-metrics-association` on enabled standalone Linux/Windows VMs, reusing `amw-<prefix>`. Classic VM Insights stays enabled and VMSS is unchanged. Explicitly set `false` to opt out. See [configuration, both views, and cleanup](STAGE-B-WORKLOADS.md#optional-vm-opentelemetry-metrics).

### Endpoints on the App Service (.NET 8 minimal API)

- `GET /` — 200 "Hello from Azure Monitor Lab"
- `GET /healthz` — 200 "OK"
- `GET /api/slow` — 200 after 1.5–3 s (slow-trace demo)
- `GET /api/dep` — outbound HTTPS call → produces `AppDependencies`
- `GET /api/explode` — 500 on purpose (used by k6 load gen)

---

## Alerts deployed

- `alert-vm-cpu-high` — VM CPU > 80% / 5 min (multi-resource)
- `alert-webapp-5xx` — App Service HTTP 5xx > 5 / 5 min
- `alert-aks-node-cpu-high` — AKS node CPU > 80% / 5 min
- `alert-appinsights-failed-requests` — KQL log alert against App Insights `requests`
- `alert-aks-pod-restart-spike` — KQL log alert against `KubePodInventory`
- `alert-service-health` — Activity-log alert (subscription scope)
- `alert-resource-health` — Activity-log alert (RG scope, Unavailable/Degraded)

## Diagnostic Settings via Policy (RG scope, DeployIfNotExists)

- `amlab-diag-appservice` — App Services → central LAW
- `amlab-diag-vnet` — Virtual Networks → central LAW
- `amlab-diag-nsg` — Network Security Groups → central LAW
- `amlab-diag-pip` — Public IP Addresses → central LAW

## Saved KQL queries (central LAW → Logs → Saved searches, category `AzureMonitorDemoLab`)

12 queries including VM Insights top-CPU, Heartbeat, AKS pod restarts, App Service 5xx, **and 3 cross-workspace queries** that `workspace("law-amlab-appinsights").AppRequests` join with the central LAW.

---

## Known caveats

| Item | Status | Notes |
|---|---|---|
| Linux Dependency Agent | **skipped** | Not supported on Ubuntu 22.04.5+ kernels. VM Insights still gets perf, heartbeat, processes via AMA + DCR. Service Map demo runs on the Windows VM. |
| App Service GitHub deployment | **replaced** | Tenant has no GitHub source-control token. `post-deploy.ps1` now builds the bundled `workloads/webapp/AmlabHello` project locally and zip-deploys it instead. |
| AKS node count | **1 by default** | Both one-shot and staged IaC default to one `Standard_B2s` system node. Increase `aksNodeCount` when the selected subscription, add-ons, or workshop workloads require more capacity. |
| Daily ingestion cap | 1 GB/day on each LAW | Prevents runaway ingest costs. |

---

## Demo flow (suggested ~25 min)

1. **Resource group overview** — show all resources in `rg-azure-monitor-lab`.
2. **Workbook → Traffic Lights** → currently all Green. Walk through the cross-workspace KQL behind the table.
3. **VM Insights** → portal → Insights → Map (on the Windows VM) → Performance.
4. **AKS → Insights** → Container Insights pages → Workbooks → Prometheus.
5. **Grafana** → import dashboard ID `19623` (Kubernetes/Cluster) onto the bundled AMW data source.
6. **App Insights** → Live Metrics (load gen is firing) → Application Map → Failures → Performance → Smart Detection.
7. **Saved queries** → run `10 — CROSS-WS …` and `11 — CROSS-WS End-to-end story`.
8. **Policy → Compliance** → show the 4 `amlab-diag-*` assignments and confirm `setByPolicy-LogAnalytics` was auto-created on the App Service.
9. **Alerts → Action Groups → ag-amlab-email** → walk the 7 alerts.
10. **Break the lab** ⚠️
    ```powershell
    ./scripts/break-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
    ```
    Wait 2–3 min; refresh the Workbook → rows turn Orange/Red, email alerts arrive.
11. **Restore**
    ```powershell
    ./scripts/restore-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
    ```

---

## Operational commands

```powershell
# Trigger an immediate load-gen run
kubectl create job --from=cronjob/loadgen loadgen-now -n demo

# Get AKS credentials (already merged into kube config during post-deploy)
az aks get-credentials -g rg-azure-monitor-lab -n aks-amlab --overwrite-existing

# Inspect the Workbook
az resource show --ids /subscriptions/<your-subscription-id>/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.Insights/workbooks/<workbook-guid>

# Tear down everything
./scripts/teardown.ps1 -Yes
```

---

## Suggested next steps

1. **Open the Workbook** — all rows should turn Green within ~10 min once agents send their first batches.
2. **Open App Insights → Live Metrics** to watch k6 traffic in real time.
3. **Run `scripts/break-the-lab.ps1`** when you want to demo the Red state.
4. Wire your own Grafana dashboards on top of `amw-amlab` (Managed Prometheus data source is pre-linked).

---

## Subscription guardrail

All scripts in `scripts/` enforce the active subscription via `.azure-target.json` (auto-generated from `lab.config.json` by `scripts/sync-config.ps1`):

- **Allowed:** `<your-subscription-id>` (`<your-subscription-name>`, tenant `<your-tenant-id>`)
- **Forbidden:** any subscription IDs listed in `lab.config.json` → `forbiddenSubscriptionIds`

A script will throw before any `az` write op if the active sub doesn't match the allowed one.
