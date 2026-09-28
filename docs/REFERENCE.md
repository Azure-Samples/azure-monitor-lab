# Azure Monitor Lab — Full reference

> 👈 **New here? Start with the [README](../README.md).** This is the deep-dive reference: full capability matrix, every deployed resource, the demo walkthrough, cost breakdown, folder layout, operational helpers, and troubleshooting.

A self-contained, reproducible demo of the **Azure Monitor + Microsoft Sentinel** stack. The lab primarily uses one resource group, plus the AKS-managed resource group and optional tenant-scoped artifacts. It provides two IaC paths (Bicep or Terraform), two delivery modes (**one-shot** for internal demos or a staged workshop for customer-facing progressive enablement), and 68 numbered demo scenarios (`0` through `67`), all driven from one central config file.

## Capabilities

| Capability | What this lab shows | Pillar docs |
|---|---|---|
| **VM Insights** | Ubuntu + Windows VMs with **AMA** + DCR → Performance data into the central LAW; the Windows VM also has the Dependency Agent for Service Map. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/monitor-vm) |
| **Application Insights** | Workspace-based App Insights, **codeless auto-instrumentation** of a .NET 8 sample on Linux App Service, **Live Metrics**, **Smart Detection**, **Code Optimizations**, **Profiler / Snapshot**, **Availability Tests**, **Release annotations**, custom `TrackMetric`. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview?tabs=webapps) |
| **Kubernetes monitoring** | AKS cluster with **Container Insights** (logs → LAW), **Managed Prometheus** (metrics → AMW) with custom Prometheus rule group, **Azure Managed Grafana** (Standard SKU) with alert rule, **OpenTelemetry** node.js + .NET caller pods tracing back to App Insights. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/kubernetes-monitoring-overview) |
| **VMSS + Predictive autoscale** | Linux VMSS with autoscale settings demonstrating predictive scaling on CPU. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-predictive) |
| **Networking observability** | **Connection Monitor**, **NSG Flow Logs** + **Traffic Analytics**, **Network Insights**. | [docs](https://learn.microsoft.com/en-us/azure/network-watcher/network-watcher-monitoring-overview) |
| **Platform telemetry** | **Key Vault** + **Storage** + **Event Hub** with diag settings, Insights workbooks. | — |
| **Diagnostic Settings via Policy** | Built-in **DeployIfNotExists** policy assignments at RG scope (App Service, VNet, NSG, Public IP, Key Vault, Storage) → central LAW, plus a multi-destination *diag fan-out* example (LAW + Event Hub + Storage). | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/platform/diagnostic-settings-policy) |
| **Cross-workspace queries** | 12+ saved KQL searches that `union`/`workspace()` join the central LAW with the App Insights LAW for cross-team stories. KQL **functions** included for reuse. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cross-workspace-query) |
| **DCR Workspace Transformation** | `microsoft-default` association on the central LAW that drops `*/read` `AzureActivity` rows + enriches survivors at ingest. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-transformations-workspace) |
| **Custom Logs (Logs Ingestion API)** | Custom-table DCR + sample sender script (`send-custom-logs.ps1`). | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview) |
| **Cost & data routing** | Daily ingestion caps, **Basic vs Analytics** table-plan toggle (`toggle-table-plan.ps1`), **Summary Rules**, **Data Export** to Storage/Event Hub, optional **LAW cross-region replication**, dedicated **Cost workbook**. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cost-logs) |
| **Search Jobs + Restore from archive** | `run-search-job.ps1` + `restore-archived-logs.ps1` demonstrate long-term retention recovery. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/search-jobs?tabs=portal) |
| **Workbooks** | *Traffic Lights* (Green/Orange/Red single pane), *Central LAW ingestion volume*, *Security posture*. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview) |
| **Action Group + Alerts** | Email + optional SIEM webhook + 7+ alerts: VM CPU, App 5xx, AKS node CPU, AppI failed requests (KQL), AKS pod restart spike (KQL), Service Health (sub-scope), Resource Health (RG-scope), plus **AMBA**-generated best-practice alerts. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups) |
| **Auto-mitigation** | Logic App triggered by an alert that runs a remediation action. **Alert Processing Rules** provide scheduled and severity-based action suppression. | — |
| **Dynamic Thresholds** | Metric alert that learns its own baseline (vs static threshold). | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds) |
| **Microsoft Sentinel** | Sentinel onboarded on the central LAW with security-posture alert rules + dedicated *Security* workbook. Demo queries for control-plane drift, privilege escalation, exfil early warning. | [docs](https://learn.microsoft.com/en-us/azure/sentinel/overview) |
| **Granular RBAC** | 3 service principals scoped at workspace / table / row level (`setup-rbac-demo.ps1` + `demo-granular-rbac.ps1`). | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access) |
| **Service Groups + Health Models (preview)** | `setup-health-model.ps1` provisions an Azure **Service Group** and links the RG. SLI/SLO scaffolding in `setup-slis.ps1`. | [docs](https://learn.microsoft.com/en-us/azure/azure-monitor/health-model) |
| **GenAI observability (optional AI stage)** | Off-by-default Microsoft **Foundry** workload (account + project pinned to swedencentral) with chat / embedding / optimization / **model-router** deployments; OpenTelemetry `gen_ai.*` tracing into App Insights; **token anomaly + spike** alerts; an **AI FinOps** query pack + workbook; an AI tier folded into the workload health model; demo agents + traffic via `setup-ai.ps1`. | [docs](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/trace) · [stage](STAGE-AI.md) |
| **Azure SRE Agent (optional trial)** | Off-by-default guided SRE Agent evaluation pinned to `swedencentral`; connects Azure Monitor alerts to specialized Review-mode investigators and validates managed identity RBAC with `setup-sre-agent.ps1`. | [docs](https://learn.microsoft.com/en-us/azure/sre-agent/azure-monitor-alerts) · [stage](STAGE-SRE-AGENT.md) |
| **Azure Copilot Observability Agent (optional preview)** | Off-by-default alert correlation and trace-based investigation over the lab Application Insights resource; includes deterministic broken/fixed agentic-failure telemetry and least-privilege validation. | [docs](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations) · [stage](STAGE-OBSERVABILITY-AGENT.md) |
| **"Break the lab" + "Start the lab"** | Scripted incident injection (`break-the-lab.ps1`, `start-the-lab.ps1`, `start-ramp.ps1`) + one-shot restore (`restore-the-lab.ps1`). | — |

---

## What gets deployed

```
rg-azure-monitor-lab/
├─ Observability backbone
│   ├─ law-amlab-central-XXXXX    ← Log Analytics — infra + AKS + AzureActivity (name suffixed per deployment)
│   ├─ law-amlab-appinsights-XXXXX ← Log Analytics — App Insights backend
│   ├─ appi-amlab                 ← Application Insights (workspace-based)
│   ├─ amw-amlab                  ← Azure Monitor Workspace (Managed Prometheus)
│   ├─ amw-amlab-obs              ← Optional dedicated Observability Agent issue workspace
│   ├─ obs-amlab-XXXXX            ← Optional Observability Agent with a system-assigned identity
│   │  └─ monitored resource      ← Enabled Application Insights target (`appi-amlab`)
│   ├─ dce-amlab                  ← Data Collection Endpoint (Linux)
│   ├─ dcr-amlab-vminsights       ← DCR — VM perf + Map → central LAW
│   ├─ dcr-amlab-prometheus       ← DCR — Prometheus → AMW
│   ├─ dcr-amlab-workspace-...    ← Workspace transformation DCR (drops /read)
│   ├─ dcr-amlab-customlogs       ← Custom-table DCR (Logs Ingestion API)
│   ├─ Perf_Hourly_CL             ← Summary-rule destination table in the central LAW
│   ├─ summary rule               ← Hourly Perf aggregation into Perf_Hourly_CL
│   ├─ export-amlab-heartbeat      ← LAW Heartbeat data export to Storage
│   └─ amg-amlab-XXXX             ← Azure Managed Grafana (Standard) bound to AMW
├─ Compute workloads
│   ├─ vm-amlab-lin               ← Optional Ubuntu VM + AMA + DCR association
│   │  └─ shutdown-computevm-*    ← Daily 23:00 CET/CEST auto-shutdown schedule
│   ├─ vmwinXXXX                  ← Optional Windows VM + AMA + Dependency Agent + DCR
│   │  └─ shutdown-computevm-*    ← Daily 23:00 CET/CEST auto-shutdown schedule
│   ├─ vmss-amlab                 ← Linux VMSS + Predictive autoscale
│   ├─ aks-amlab                  ← AKS (Free tier, 1 × B2s by default) + Container Insights + Managed Prom
│   ├─ amlab-aks-prom-rules        ← Managed Prometheus recording + alerting rule group
│   ├─ plan-amlab + app-amlab-XX  ← Linux App Service B1 + .NET 8 sample (auto-instrumented), pinned to westeurope
│   └─ availability test + alert   ← Standard URL test from 5 global locations
├─ Networking
│   ├─ vnet-amlab + nsg-amlab     ← /16 with workload, AKS, and VMSS subnets
│   ├─ Connection Monitor         ← VM → VM + VM → public endpoint probes
│   └─ NSG Flow Logs              ← into Storage + Traffic Analytics
├─ Platform telemetry sources
│   ├─ st-amlabXXXX               ← Storage account (NSG flow logs + LAW data export target)
│   ├─ stapp-amlabXXXX            ← Storage account — App Service archive diag (westeurope, co-located)
│   ├─ evhns-amlab-XXXX           ← Event Hub namespace — App Service diag stream (westeurope, co-located)
│   └─ kv-amlab-XXXX              ← Key Vault (RBAC mode)
├─ Governance & policy
│   ├─ amlab-diag-* (×N)          ← Built-in DINE policy assignments → central LAW
│   └─ amlab-diag-fanout          ← Multi-destination diag setting (LAW + EH + Storage)
├─ Alerting & response
│   ├─ ag-amlab-email             ← Action Group → email (+ optional SIEM webhook)
│   ├─ alert-* (×7+)              ← Metric + KQL + activity-log + dynamic-threshold alerts
│   ├─ AMBA-* (×N)                ← Azure Monitor Baseline Alerts
│   ├─ apr-amlab-maintenance-window ← Enabled weekly RG-wide action suppression
│   ├─ apr-amlab-suppress-low-sev   ← Disabled-by-default Sev3/Sev4 action suppression
│   ├─ apr-amlab-vm-auto-shutdown   ← Nightly suppression scoped to enabled lab VMs
│   └─ logic-amlab-automitigate   ← Logic App auto-mitigation runbook
├─ Security
│   ├─ Sentinel onboarded         ← on law-amlab-central + security-posture alert rules
│   └─ scheduled query rules      ← control-plane drift, privilege escalation, and exfiltration detections
├─ Workload health and reliability
│   ├─ hm-amlab-workload          ← Health Model with entities, signals, and relationships
│   ├─ id-sli-amlab               ← UAMI used by SLI/SLO scaffolding
│   └─ amlab-workload             ← tenant-scoped Service Group + RG membership, created by deploy.ps1
└─ Workbooks
    ├─ wb-amlab-trafficlights     ← 🚦 Traffic Lights — single pane of glass
    ├─ wb-amlab-cost              ← Central LAW ingestion volume
    └─ wb-amlab-security          ← Security posture
```

> **Opt-in (default off):** `dcr-amlab-platformlogs` (platform-logs DCR, preview) and `dcr-amlab-metricsexport` (metrics-export DCR, GA) — enable via `enablePlatformLogsDcr` / `enableMetricsExportDcr` (Bicep) or `enable_platform_logs_dcr` / `enable_metrics_export_dcr` (Terraform).

> **Optional AI stage (default off, billable):** a Microsoft **Foundry** account + project (pinned to `swedencentral`) with `gpt-5-mini` / `text-embedding-3-small` / `gpt-5.4` / **`model-router`** deployments, App Insights `gen_ai.*` tracing, **token anomaly + spike** alerts, an **AI FinOps** query pack + workbook, and an AI tier folded into the workload health model. Enable via `enableStageAI` (Bicep) / `enable_stage_ai` (Terraform), then run `scripts/setup-ai.ps1`. See [STAGE-AI.md](STAGE-AI.md).

> **Optional SRE Agent stage (default off, trial/billable):** an SRE Agent and user-assigned identity in `swedencentral`, Azure Monitor / Application Insights / Log Analytics connectors, resource-group and subscription RBAC, and deployment validation through `setup-sre-agent.ps1`. Enable via `enableStageSreAgent`. Investigators and response plans are configured in `sre.azure.com`. See [STAGE-SRE-AGENT.md](STAGE-SRE-AGENT.md).

> **Optional Observability Agent stage (default off, preview/billable):** an Observability Agent and dedicated Azure Monitor workspace in `observabilityAgentLocation`, one monitored Application Insights child, Issue Contributor on the dedicated workspace, and Monitoring Reader at subscription scope. The Monitor service can create managed resource groups for supporting resources. Enable via `enableStageObservabilityAgent`; automatic investigation remains off unless explicitly enabled. See [STAGE-OBSERVABILITY-AGENT.md](STAGE-OBSERVABILITY-AGENT.md).

> **Optional LAW replication (default off, billable):** cross-region replication on the central LAW. Enable during deployment with `enableLawReplication`, or enable it on an existing workspace with `scripts/enable-law-replication.ps1` without redeploying the complete Bicep template.

> **Region pinning:** the **App Service** (plan + site) and its diagnostic sinks (dedicated storage + Event Hub) are pinned to **`westeurope`**; the **Health Model** preview and the **AI stage** are pinned to **`swedencentral`**. Everything else follows the lab region (default `northeurope`).

The Control Center provisions four primary runner resources in the Web App's region: a Basic `acrlabops<suffix>` registry, a `cae-labops-<suffix>` Consumption environment, an `id-labops-<suffix>` managed identity, and a manual `job-labops-<suffix>` job. Supporting resources include the `console-runner-logs` diagnostic setting, three custom roles, scoped role assignments, and the Web App's system-assigned identity. Workload publication builds the image and deploys the digest-pinned job and launcher role. The Entra sign-in registration is tenant-level and is not removed by resource-group deletion. Counts vary with selected stages and whether child resources, deployments, RBAC, diagnostics, and tenant objects are included.

Inside the central LAW you also get **12+ saved KQL searches** and **KQL functions** under category `AzureMonitorDemoLab` (Logs > Saved searches / Functions). The one-shot deployment wrapper runs `post-deploy.ps1`, creates the Service Group and RG membership with `setup-health-model.ps1`, and verifies SLI prerequisites with `setup-slis.ps1`. Optional operational helpers layer demos and telemetry on top. See [Operational and optional helpers](#operational-and-optional-helpers) below.

---

## Prerequisites

- Azure CLI (`az`) ≥ 2.60, logged in to the right tenant: `az login`
- `kubectl` (any recent version)
- Bicep CLI (bundled with `az` ≥ 2.20) — **OR** Terraform ≥ 1.6 if you prefer the Terraform path
- PowerShell 7+ (the deploy scripts and helpers are `.ps1`)
- A subscription with quota for: 1 AKS cluster (1 × `Standard_B2s` node), 2 VMs (1 Linux and 1 Windows, both `Standard_B2s`), 1 Linux VMSS (1 × `Standard_B1s`), 1 App Service B1 (in `westeurope`), 1 Managed Grafana Standard instance, 2 Storage accounts, 1 Event Hubs Basic namespace, 1 Key Vault, and the other resources listed in the [cost guide](COST-GUIDE.md).
- *(Optional AI stage only)* Python 3.10+ for `scripts/setup-ai.ps1` (creates the demo agents + traffic simulator in `workloads/ai/`); the Foundry models it deploys are **billable**.
- Console completion additionally requires the .NET 8 SDK, ACR Tasks availability, Container Apps Consumption capacity, and rights to manage the sign-in registration and scoped roles. See [Lab Operations prerequisites](../workloads/webapp/LAB-OPERATIONS.md#prerequisites).

The deploy script lazily registers `Microsoft.ContainerService`, `Microsoft.OperationsManagement`, `Microsoft.Dashboard`, `Microsoft.AlertsManagement`, and `Microsoft.CloudHealth` (Service Groups preview) — that may already be done in your sub, otherwise it takes ~3 min.

> **Two IaC paths, one config.** Bicep is the primary path (`infra/main.bicep` for one-shot, `infra/stages/*.bicep` for staged customer workshops). Terraform is a parallel implementation (`terraform/main.tf`) driven from the same `lab.config.json`. Pick **one** — don't mix.

---

## Bootstrap (fresh clone → ready to deploy)

This repo ships zero secrets. After cloning, populate **one** central config file and let `sync-config.ps1` generate every other per-user input file from it.

```powershell
# 1. Copy the template and edit it (gitignored, never committed)
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json   # fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, ...

# 2. (Optional) regenerate the derived files manually
./scripts/sync-config.ps1

# 3. Deploy — deploy.ps1 calls sync-config.ps1 for you if lab.config.json exists
./scripts/deploy.ps1
```

`scripts/sync-config.ps1` materializes (all gitignored):

| Derived file | Consumer |
|---|---|
| `.azure-target.json` | Subscription guardrail used by `scripts/deploy.ps1` + `scripts/teardown.ps1` + `scripts/setup-rbac-demo.ps1` |
| `infra/main.parameters.json` | Bicep parameters file consumed by `az deployment group create` |
| `terraform/stages.tfvars` | Terraform variable file consumed by `terraform apply -var-file` |

To change a value (e.g. region, alert email, password, stage toggles), edit `lab.config.json` and re-run `sync-config.ps1` (or just run `deploy.ps1` again).

### Granular RBAC demo (scenario 27)

`scripts/setup-rbac-demo.ps1` creates 3 Microsoft Entra service principals (workspace-, table-, row-scoped) and writes their credentials to `scripts/.rbac-demo-config.json` (gitignored). The file is regenerated on every run — there is no committed copy to bootstrap. See `scripts/.rbac-demo-config.json.example` for the shape.

---

## Deploy

Two delivery modes — pick whichever fits your audience.

### Option 1 — One-shot (fastest, internal demos)

```powershell
# from repo root
./scripts/deploy.ps1
```

Defaults: resource group `rg-azure-monitor-lab`, region `northeurope`, parameters in `infra/main.parameters.json` (auto-generated from `lab.config.json` — see Bootstrap above). Some resources auto-pin to their own region regardless of the lab region: the **App Service** tier (plan + site + its diagnostic storage + Event Hub) to **`westeurope`** (no Basic App Service quota in `northeurope` on the sponsored subs), and the **Health Model** preview + optional **AI stage** to **`swedencentral`**.

End-to-end deployment can take tens of minutes, including AKS/Grafana provisioning, the runner image build, MCP packaging, ZIP upload, and app-version verification. The script prints the App Service URL, the AKS LB IP, the Grafana URL, and the Workbook resource ID. Optional AI traffic starts last as a finite background batch; setup completion does not wait for every conversation.

### Option 2 — Staged workshop (customer-facing, progressive enablement)

Same lab, broken into 5 progressive stages so you can pause for discussion after each one. Each stage is its own Bicep/Terraform deployment with a dedicated speaker-notes doc. Skip stages you don't need (toggles in `lab.config.json` → `stageToggles`).

| Stage | Theme | Adds | Scenarios | Time | Incremental cost basis |
|---|---|---|---|---|---|
| **A — Foundation** | Telemetry backbone | LAWs · AppI · AMW · DCE · network · storage · Event Hub · Key Vault · diag policies · saved queries · KQL functions · cost + traffic-lights workbooks | 1, 5, 6, 9 | 8–15 min | Provisioned Event Hubs/ACR/storage plus telemetry and operations |
| **B — Workloads & dashboards** | Compute + app telemetry | Optional Linux/Windows VMs · per-VM auto-shutdown schedules · AKS + Container Insights + Managed Prom · Grafana · App Service + auto-instrumented .NET · Control Center runner platform · custom logs · OTel pods · Connection Monitor · NSG Flow Logs | 2, 3, 4, 22, 28–32, 34–36, 42 | 20–35 min | Compute hours, disks/IPs, App Service, Grafana Standard/users, ACR, runner executions, Prometheus, network monitoring and telemetry |
| **C — Alerts & response** | Detection + suppression | Action Group · 7+ metric/KQL/activity alerts · AMBA · dynamic thresholds · three suppression-oriented Alert Processing Rules when VMs are enabled · auto-mitigation Logic App · VMSS predictive autoscale | 7, 8, 12, 15, 17, 19, 23, 37 | 5–12 min | Rule/series evaluations, notifications, action executions and VMSS compute |
| **D — Security posture** | Monitor-native detections | Granular RBAC roles · control-plane drift / privilege escalation / exfil scheduled-query alerts | 27, 47, 48, 49 | 5–12 min | Scheduled-query evaluations plus diagnostic ingestion/retention |
| **E — Optional advanced** | SOC + reliability previews | Conditional Sentinel onboarding · data export · Prometheus rule group · availability test · Health Model (preview) · SLI identity · optional platform/metrics DCRs | 43, 44, 45, 46 | 10–20 min | Sentinel analysis, export, web tests, preview resources and extra telemetry |
| **AI — GenAI observability** *(optional, off)* | AI FinOps on Foundry | Microsoft Foundry account + project (swedencentral) · chat/embedding/optimization/model-router deployments · App Insights tracing · token anomaly + spike alerts · AI FinOps query pack + workbook · AI health tier · agents + traffic (`setup-ai.ps1`) | 53 | 10–15 min | Model-specific tokens or provisioned throughput plus telemetry |
| **SRE Agent (optional, off)** | AI-assisted incident response | Bicep-deployed agent (swedencentral) · managed identity + RBAC · Azure Monitor, App Insights, and LAW connectors · two Review-mode investigators with automatic incident briefs · deployment validation (`setup-sre-agent.ps1`) | 54-59 | 20-25 min | Always-on AAUs plus active AAUs, subject to current trial terms |

Stage E completion can also create the tenant-scoped Service Group and RG membership and verify SLI prerequisites. Search jobs, archive restores, and sample SLIs/SLOs are operational or portal-driven actions, not resources created by `40-optional-advanced.bicep`.

Walk-through docs:

- Bicep staged tutorial → [DEPLOY-BICEP-STEP-BY-STEP.md](DEPLOY-BICEP-STEP-BY-STEP.md)
- Terraform staged tutorial → [DEPLOY-TERRAFORM-STEP-BY-STEP.md](DEPLOY-TERRAFORM-STEP-BY-STEP.md)
- Per-stage speaker notes → [STAGE-A](STAGE-A-FOUNDATION.md) · [STAGE-B](STAGE-B-WORKLOADS.md) · [STAGE-C](STAGE-C-ALERTING.md) · [STAGE-D](STAGE-D-SECURITY-POSTURE.md) · [STAGE-E](STAGE-E-OPTIONAL-ADVANCED.md)
- Customer handout (time + cost cheat sheet) → [CUSTOMER-STAGE-HANDOUT.md](CUSTOMER-STAGE-HANDOUT.md)

> Stage A is mandatory; B/C/D/E layer on top, and **AI** is a fully optional, off-by-default add-on (depends only on Stage A). **SRE Agent** is also off by default. In the one-shot Bicep path, `enableStageSreAgent` deploys the agent and connectors; custom investigators and response plans are configured afterward in `sre.azure.com`.

---

## Demo flow

The lab supports **68 numbered demo scenarios** (`0` through `67`), each with a story, a click-path, and a "killer line". See [`DEMO-SCENARIOS.md`](DEMO-SCENARIOS.md) for the full catalogue, including audience-pivoted shortlists (App Service, AKS, Cost, Security, Workload health, and agentic applications).

**Suggested 25-minute "first taste" walkthrough** (covers the cross-stack story):

1. **Resource group overview** - show the resources from the selected stages, including the Control Center runner, and filter by `purpose=azure-monitor-lab`.
2. **🚦 Traffic Lights workbook** ([scenario 1](DEMO-SCENARIOS.md#s1)) → currently all **Green**. Talk through the cross-workspace KQL behind it.
3. **VM Insights** ([scenario 2](DEMO-SCENARIOS.md#s2)) → portal → Insights → Map → topology + Performance for the Linux VM, same for Windows.
4. **AKS → Insights** ([scenario 4](DEMO-SCENARIOS.md#s4)) → Container Insights blades, then **Workbooks → AKS Prometheus**, then **Grafana** with AMW data source pre-wired.
5. **App Insights** ([scenario 3](DEMO-SCENARIOS.md#s3)) → *Live Metrics* (load-gen is hitting the App Service), *Application Map*, *Failures*, *Performance*, *Smart Detection*.
6. **Saved queries** ([scenario 6](DEMO-SCENARIOS.md#s6)) → central LAW → Logs → Saved searches → run `10 — CROSS-WS …` and `11 — CROSS-WS End-to-end story`.
7. **Diagnostic Settings via Policy** ([scenario 5](DEMO-SCENARIOS.md#s5)) → Policy → Compliance → walk the `amlab-diag-*` assignments and the auto-created `setByPolicy-LogAnalytics` setting on the App Service.
8. **Alerts + Action Group** ([scenario 7](DEMO-SCENARIOS.md#s7)) → Monitor → Alert rules → walk the 7 rules + the single Action Group.
9. **Break the lab** ⚠️ ([scenario 8](DEMO-SCENARIOS.md#s8))
    ```powershell
    ./scripts/break-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
    ```
    Wait ~2-3 minutes, refresh the Workbook → rows turn **Orange** then **Red**. Email alerts arrive.
10. **Restore**:
    ```powershell
    ./scripts/restore-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
    ```

---

## Cost notes

The former flat monthly estimate was removed because it did not match the deployed bill of materials and omitted usage-based meters. Current defaults include **1 x AKS B2s node**, **1 x Linux B2s VM**, **1 x Windows B2s VM**, **1 x Linux B1s VMSS instance**, **App Service Basic B1**, **Managed Grafana Standard**, **Event Hubs Basic with 1 TU**, **ACR Basic**, managed disks and public IPs, plus usage-based Monitor, networking, storage, alerting, web-test, and Control Center job charges.

See the dated [cost guide](COST-GUIDE.md) for:

- a complete service/meter inventory and public-rate examples;
- formulas for ingestion, retention, archive, search, restore, export, replication, metrics, alerts, web tests, network monitoring, and runner executions;
- correct Sentinel, Foundry, SRE Agent, and Observability Agent billing boundaries;
- external GitHub Copilot CLI and MCP cost boundaries;
- a stop/deallocate/delete matrix.

Both Log Analytics workspaces default to a **1 GB/day ingestion cap**, but each cap applies only to that workspace's ingestion. It does not cap Grafana, compute, App Service, Event Hubs, ACR, disks, IPs, Prometheus, network monitoring, alerts, tests, agents, or other meters. The in-lab cost workbook reports central-workspace ingestion volume only; Azure Cost Management remains the billing source of truth.

To reduce compute charges between sessions, deallocate VMs and stop AKS:

```powershell
az aks stop -g rg-azure-monitor-lab -n aks-amlab
```

App Service Plan, Grafana Standard, Event Hubs, ACR, retained disks/IPs/data, telemetry, and enabled optional agents can continue billing. Delete the lab when it is no longer needed and verify asynchronous deletion completes.

---

## Tear down

```powershell
./scripts/teardown.ps1 -Yes
```

Before starting the RG deletion, the script disables LAW replication and removes nested DCR associations, DCRs, and DCEs in dependency order. Some Azure-managed DCEs cannot be deleted directly and are left for the LAW/RG cascade. The final RG deletion runs in the background (`--no-wait`).

---

## Folder layout

```
azure-monitor-lab/
├─ lab.config.json.example          ← Copy → lab.config.json (gitignored), fill in real values
├─ README.md
├─ .github/                         ← CODE_OF_CONDUCT · CONTRIBUTING · SECURITY · workflows
├─ docs/
│   ├─ REFERENCE.md · DEMO-SCENARIOS.md · DEPLOYMENT-SUMMARY.md
│   ├─ architecture.drawio          ← Editable architecture diagram
│   ├─ CUSTOMER-STAGE-HANDOUT.md    ← Per-stage time + cost cheat sheet
│   ├─ DEPLOY-BICEP-STEP-BY-STEP.md
│   ├─ DEPLOY-TERRAFORM-STEP-BY-STEP.md
│   └─ STAGE-{A,B,C,D,E,AI}-*.md    ← Stage narratives for workshops
├─ infra/                           ← Bicep IaC
│   ├─ main.bicep                   ← One-shot, end-to-end deployment
│   ├─ main.parameters.json         ← (gitignored, generated by sync-config.ps1)
│   ├─ stages/                      ← Staged deployment for customer workshops
│   │   ├─ 00-foundation.bicep      ← LAW · AppI · AMW · DCE · network · storage · EH · KV
│   │   ├─ 10-workloads.bicep       ← VMs · VMSS · AKS · App Service · Grafana
│   │   ├─ 20-alerting.bicep        ← Action Group · alerts · AMBA · processing rules
│   │   ├─ 30-security-posture.bicep← Security alerts · LAW RBAC
│   │   ├─ 40-optional-advanced.bicep ← Sentinel onboarding · data export · health model · etc.
│   │   ├─ 41-sentinel-content.bicep ← Sentinel analytics rule after onboarding
│   │   ├─ 50-ai.bicep              ← (optional) Foundry GenAI workload · token alerts · AI FinOps observability
│   │   └─ 60-sre-agent.bicep       ← (optional) SRE Agent · connectors · identity and RBAC
│   └─ modules/                     ← 45 reusable Bicep modules (including optional AI and SRE stages)
│       ├─ law.bicep · appinsights.bicep · azure-monitor-workspace.bicep
│       ├─ network.bicep · vm-linux.bicep · vm-windows.bicep · vmss.bicep · aks.bicep
│       ├─ grafana.bicep · appservice.bicep · availability-test.bicep
│       ├─ actiongroup.bicep · alerts.bicep · alert-processing-rules.bicep
│       ├─ amba.bicep · health-alerts.bicep · automitigation-logicapp.bicep
│       ├─ policy-diagnostics.bicep · saved-queries.bicep · kql-functions.bicep
│       ├─ workbook.bicep · cost-workbook.bicep
│       ├─ summary-rules.bicep · prometheus-rules.bicep · dcr-workspace-transforms.bicep
│       ├─ custom-logs.bicep · data-export.bicep · connection-monitor.bicep · flow-logs.bicep
│       ├─ storage-account.bicep · eventhub.bicep · keyvault.bicep
│       ├─ sentinel.bicep · security-posture-alerts.bicep
│       ├─ health-model.bicep · sli-identity.bicep · law-rbac.bicep
│       ├─ platform-logs-dcr.bicep · metrics-export-dcr.bicep · security-workbook.bicep
│       ├─ foundry.bicep · ai-observability.bicep · ai-healthmodel.bicep ← (optional AI stage)
│       └─ sre-agent.bicep · sre-agent-subscription-rbac.bicep ← (optional SRE Agent stage)
├─ terraform/                       ← Parallel Terraform path (azurerm + azapi)
│   ├─ main.tf · variables.tf · providers.tf
│   ├─ stages.tfvars.example        ← Copy → stages.tfvars (gitignored, or regen via sync-config.ps1)
│   └─ stage*.plan                  ← Pre-generated tf plans per stage
├─ scripts/                         ← PowerShell deployment and demo helpers (29 tracked .ps1 files)
│   ├─ sync-config.ps1              ← lab.config.json → all derived files
│   ├─ deploy.ps1 · post-deploy.ps1 · post-staged-deploy.ps1 · post-cloud-shell-deploy.ps1
│   ├─ preflight-check.ps1 · teardown.ps1 · gen-architecture-svg.ps1
│   ├─ break-the-lab.ps1 · restore-the-lab.ps1
│   ├─ start-the-lab.ps1 · start-ramp.ps1
│   ├─ setup-rbac-demo.ps1 · demo-granular-rbac.ps1 · demo-slis.ps1
│   ├─ setup-health-model.ps1 · setup-slis.ps1 · setup-grafana-alerts.ps1
│   ├─ setup-ai.ps1 · setup-ai-cloud-shell.ps1 ← optional AI setup and traffic
│   ├─ setup-sre-agent.ps1          ← optional SRE Agent validation and RBAC repair
│   ├─ create-summary-rule.ps1 · toggle-table-plan.ps1 · enable-law-replication.ps1
│   ├─ run-search-job.ps1 · restore-archived-logs.ps1
│   ├─ send-custom-logs.ps1 · send-release-annotation.ps1
│   └─ trigger-code-optimization.ps1
└─ workloads/
    ├─ k8s/                         ← Pods deployed onto AKS by post-deploy.ps1
    │   ├─ 01-frontend.yaml · 02-loadgen.yaml · 03-loadgen-ramp.yaml
    │   ├─ 04-otel-caller.yaml      ← .NET OTel caller traced to App Insights
    │   └─ 05-nodeapp-otel.yaml     ← Node.js OTel app
    ├─ ai/                          ← (optional AI stage) Foundry agents + traffic simulator (Python)
    │   ├─ create_agents.py · simulate_traffic.py · requirements.txt · .env.example
    └─ webapp/                      ← .NET 8 sample (AmlabHello) deployed to App Service
```

---

## Ideas to extend beyond current scope

The lab covers 68 numbered scenarios (`0` through `67`) out of the box; here are well-scoped follow-ups for deeper sessions:

- **Multi-region DR drill** — pair the central LAW with a paired region (the `enableLawReplication` parameter wires this up) and walk alert + workbook continuity during a regional outage.
- **Cross-subscription workbook rollup** — clone the Traffic Lights workbook into a management-group-scoped variant.
- **Change Analysis pre/post-incident drift** — combine `break-the-lab.ps1` with the App Service Change Analysis blade for a deployment-drift story.
- **SRE Agent remediation** — move selected response plans from Review to Autonomous only after repeated read-only validation and least-privilege remediation design.

---

## Operational and optional helpers

These scripts operate or extend an already deployed lab. Most are manual demo helpers. `setup-health-model.ps1` and `setup-slis.ps1` are also called by the one-shot deployment wrapper, while AI and SRE Agent setup run automatically only when their stage toggles are enabled.

| Script | What it does | Scenario |
|---|---|---|
| `scripts/start-the-lab.ps1` · `start-ramp.ps1` | Generate sustained / ramping load against the App Service so Live Metrics, Smart Detection, and Code Optimizations have data to chew on. | 3, 13, 17, 18 |
| `scripts/trigger-code-optimization.ps1` | Hammer the inefficient endpoints (string concat, sync-over-async, excessive exceptions) so **App Insights Code Optimizations** surfaces recommendations. | 18 |
| `scripts/send-release-annotation.ps1` | Posts a release annotation to App Insights — overlays a vertical line on every chart. | 33 |
| `scripts/setup-grafana-alerts.ps1` | Creates a Grafana alert rule against the AMW data source. | 32 |
| `scripts/create-summary-rule.ps1` | Adds a LAW **Summary Rule** that pre-aggregates expensive queries into a custom table. | 21 |
| `scripts/toggle-table-plan.ps1` | Flips a chosen table between **Analytics** and **Basic** plan to demo the cost tradeoff. | 20 |
| `scripts/enable-law-replication.ps1` | Enables paid cross-region replication on an existing central LAW without rerunning the complete Bicep deployment. | 41 |
| `scripts/run-search-job.ps1` | Runs a **Search Job** over archived data and waits for the resulting custom table. | 44 |
| `scripts/restore-archived-logs.ps1` | Triggers a **Restore** of an archived table range and surfaces it as a hot table. | 44 |
| `scripts/send-custom-logs.ps1` | Sends sample rows through the **Logs Ingestion API** into the custom-table DCR. | 24 |
| `scripts/setup-rbac-demo.ps1` + `demo-granular-rbac.ps1` | Provisions 3 service principals (workspace / table / row scope) and replays cross-SP queries to show **Granular RBAC**. | 27 |
| `scripts/setup-health-model.ps1` | Provisions the tenant-scoped Azure **Service Group** (preview), attaches the RG, and prints links to the Bicep-populated Health Model. Run with `-Teardown` to remove the tenant-scoped artifacts. | 45 |
| `scripts/setup-slis.ps1` | Verifies the Service Group, identity permissions, and source metrics required for the portal-created sample **SLIs / SLOs**. | 46 |
| `scripts/demo-slis.ps1` | Creates, degrades, restores, or removes isolated AKS workloads that drive the SLI demo. | 46 |
| `scripts/setup-ai.ps1` | Creates the optional Foundry demo agents and generates traced token traffic when the AI stage is enabled. | 53 |
| `scripts/setup-sre-agent.ps1` | Validates the optional SRE Agent, connectors, identities, and RBAC; missing roles are granted only with `-GrantMissingRoles`. | 54-59 |
| `scripts/setup-observability-agent.ps1` | Read-only validation of the optional Observability Agent, monitored Application Insights resource, operations, identity, and RBAC. | 61-67 |

## Troubleshooting

- **App Service Logs panes are empty** for the first ~10 min — the source-control deployment from GitHub is still building (Oryx).
- **`AppRequests` / `AppDependencies` empty** in App Insights LAW → ensure the Web App restarted at least once after the App Settings landed: `az webapp restart -g rg-azure-monitor-lab -n <webApp>`.
- **AKS LB IP stuck `<pending>`** → wait 1-2 min, or `kubectl describe svc hello-frontend -n demo`.
- **Workbook says "No data" the first time** → wait 5-10 minutes for AMA + Container Insights to land their first batches, then refresh.
- **`Assert-AllowedSubscription` aborts the deploy** → `lab.config.json` doesn't exist yet, or `az` is logged into a different tenant. Run `Copy-Item lab.config.json.example lab.config.json`, edit it, then `az login --tenant <your-tenant-id>`.
- **Sentinel costs unexpectedly high** → review Sentinel analysis, Log Analytics ingestion/retention, automation, Logic Apps, notebooks, and other enabled features in Cost Analysis. A qualifying new workspace can receive a conditional 31-day, 10 GB/day trial, but there is no unconditional permanent-free state. The LAW cap limits only that workspace's ingestion.

---

See the [README](../README.md) for contributing, security, and license information.
