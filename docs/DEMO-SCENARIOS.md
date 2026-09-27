# Azure Monitor Lab — Demo Scenarios

A curated set of demo scenarios you can run with this lab. Each one has a **story**, a **click-path / commands**, and **what to point at** so the audience walks away with the value.

> **Active subscription:** `<your-subscription-name>` (`<your-subscription-id>`) · **RG:** `rg-azure-monitor-lab` · **Region:** North Europe (App Service pins to West Europe; optional AI stage + Health Model pin to Sweden Central)

---

## Demo scenarios — organized by workload

Pick a workload (or theme) and run only those scenarios. Each row links to the numbered scenario below.

| Workload / theme | Scenarios |
|---|---|
| **Cross-stack — single pane of glass** | <ul><li>[1](#s1) Traffic-Lights workbook</li><li>[60](#s60) Lab Control Center</li></ul> |
| **Workload health (Service Groups + Health Models, preview)** | <ul><li>[45](#s45) Service Group + Health Model</li><li>[46](#s46) SLIs / SLOs</li></ul> |
| **App Service (.NET web app — `app-amlab-*`)** | <ul><li>[3](#s3) Code-less App Insights</li><li>[22](#s22) Availability Tests</li><li>[13](#s13) Smart Detection</li><li>[18](#s18) Code Optimizations</li><li>[25](#s25) Change Analysis</li><li>[28](#s28) Custom TrackMetric</li><li>[29](#s29) Profiler + Snapshot</li><li>[33](#s33) Release annotations</li></ul> |
| **AKS (`aks-amlab`)** | <ul><li>[4](#s4) Container Insights + Prom + Grafana</li><li>[14](#s14) OTel tracing AKS→App Service</li><li>[30](#s30) Node.js OTel</li><li>[31](#s31) Prom rule group</li><li>[32](#s32) Grafana alert rule</li></ul> |
| **Azure VMs (Linux + Windows)** | <ul><li>[2](#s2) VM Insights cross-OS</li></ul> |
| **VMSS (`vmss-amlab`)** | <ul><li>[19](#s19) Predictive autoscale</li></ul> |
| **Networking (VNet + NSG)** | <ul><li>[34](#s34) Connection Monitor</li><li>[35](#s35) Flow Logs + Traffic Analytics</li><li>[50](#s50) Network Insights</li></ul> |
| **Platform resources (Key Vault, Storage)** | <ul><li>[36](#s36) Key Vault + Storage Insights</li></ul> |
| **Alerts & incident response** | <ul><li>[7](#s7) Alerts + Action Group</li><li>[12](#s12) AMBA</li><li>[17](#s17) Dynamic Thresholds</li><li>[23](#s23) Processing Rules</li><li>[15](#s15) Auto-mitigation</li><li>[8](#s8) Break the lab</li><li>[37](#s37) Nightly maintenance</li><li>[38](#s38) SIEM webhook</li></ul> |
| **Cost & data routing** | <ul><li>[9](#s9) Daily caps</li><li>[11](#s11) DCR Transform</li><li>[20](#s20) Basic vs Analytics</li><li>[21](#s21) Summary Rules</li><li>[39](#s39) Data Export</li><li>[40](#s40) Diag fan-out</li><li>[41](#s41) LAW replication</li><li>[42](#s42) Cost workbook</li><li>[51](#s51) Platform logs at scale (DCR)</li><li>[52](#s52) Metrics Export (DCR)</li></ul> |
| **Security** | <ul><li>[27](#s27) Granular RBAC</li><li>[43](#s43) Sentinel</li><li>[44](#s44) Search jobs + Restore</li><li>[47](#s47) Control-plane drift watch</li><li>[48](#s48) Privilege escalation watch</li><li>[49](#s49) Exfil early warning</li></ul> |
| **AI / ML in Azure Monitor** | <ul><li>[16](#s16) Copilot</li><li>[13](#s13) Smart Detection</li><li>[17](#s17) Dynamic Thresholds</li><li>[18](#s18) Code Optimizations</li><li>[19](#s19) Predictive autoscale</li></ul> |
| **GenAI observability (optional AI stage)** | <ul><li>[53](#s53) AI FinOps — token / trace / cost</li></ul> |
| **Azure SRE Agent (optional trial)** | <ul><li>[54](#s54) Trial readiness</li><li>[55](#s55) Alert-driven App Service investigation</li><li>[56](#s56) AKS crash-loop diagnosis</li><li>[57](#s57) Change correlation</li><li>[58](#s58) Alert merging and verified recovery</li><li>[59](#s59) Automatic incident command brief</li></ul> |
| **Azure Copilot Observability Agent (optional preview)** | <ul><li>[61](#s61) Slow tool</li><li>[62](#s62) Wrong tool</li><li>[63](#s63) Partial failure</li><li>[64](#s64) Alert storm correlation</li><li>[65](#s65) Token-cost spike</li><li>[66](#s66) Deployment regression</li><li>[67](#s67) Platform versus application failure</li></ul> |
| **Platform foundations** | <ul><li>[5](#s5) Policy auto-onboard</li><li>[6](#s6) Cross-workspace KQL</li><li>[24](#s24) Custom Logs Ingestion API</li><li>[26](#s26) KQL Functions</li><li>[51](#s51) Platform logs at scale (DCR)</li></ul> |

> **Suggested 25-min "by-workload" demos:** App Service → 3, 22, 28, 29, 33 · AKS → 4, 14, 30, 31 · Cost → 9, 11, 20, 39, 42 · Security → 27, 47, 48 · Workload health → 1 + 45 + 46.

---

<a id="s0"></a>
## 0 · 30-second elevator pitch (every demo starts here)

> *"This is one resource group with a Linux VM, a Windows VM, an AKS cluster, and an App Service. All telemetry flows to two Log Analytics workspaces: one **central** workspace for infrastructure logs, and one **dedicated** to Application Insights. Azure Policy ensures every new resource is auto-wired with diagnostic settings. Everything you see today is built on top of that pipeline."*

Open the resource group → expand the resource list → **show the count**: ~30 resources, all tagged `purpose=azure-monitor-lab`.

---

<a id="s1"></a>
## 1 · Traffic-Lights Workbook — the "single pane of glass"

**Audience:** anyone (ops leads, business stakeholders, architects).
**Time:** 3–5 min.

### Story
Modern teams don't want to chain through 10 portal blades to know "is anything broken right now?". This workbook answers that in one screen, with a clear per-resource threshold legend.

### Click-path
1. **Monitor → Workbooks** → search **"Azure Monitor Lab"** → open *Traffic Lights*.
2. Read the **legend table** out loud (Green/Orange/Red thresholds per resource type).
3. Click any Red or Orange row → scroll down to the matching detail pane (VM heartbeat / AKS pods / App Service status codes / App Insights timechart).
4. Change the time-range pill (15 min / 1 hour / 24 h) and re-run.

### Killer line
> *"This is just KQL — including a `workspace()` join across two LAWs in one query. You can build the same in 10 minutes for your environment."*

---

<a id="s2"></a>
## 2 · VM Insights — cross-OS, agent-based monitoring

**Audience:** infra / Ops teams.
**Time:** 5 min.

### Story
A single agent (Azure Monitor Agent) + a Data Collection Rule = full perf, heartbeat, and process telemetry on both Linux and Windows. No more split tooling.

### Click-path
1. Resource group → **`vmwin-<suffix>`** (Windows) → **Insights** → *Performance* and *Map* tab. Show the auto-discovered TCP connections.
2. Switch to **`vm-amlab-lin`** (Linux) → **Insights** → *Performance* tab. (Map view is unavailable on Ubuntu 22.04+ — kernel-incompatible Dependency Agent.)
3. Open **`law-amlab-central`** → **Logs** → run saved query `03 — VM Heartbeat · which VMs are alive?`.

### Killer line
> *"Identical UI, identical KQL, identical alerts — across both OS families. The agent is the only thing the VM needs."*

---

<a id="s3"></a>
## 3 · Application Insights — code-less .NET auto-instrumentation

**Audience:** developers, app owners.
**Time:** 5–8 min.

### Story
A small .NET 8 web app (`AmlabHello`) is running on Linux App Service. We did **not** add the App Insights SDK manually — `ApplicationInsightsAgent_EXTENSION_VERSION=~3` does it for us. App Insights captures requests, dependencies, exceptions, and logs automatically.

### Click-path
1. **`app-amlab-<suffix>`** → click the URL in the Overview blade → open `/`, `/api/slow`, `/api/dep`, `/api/explode`.
2. **`appi-amlab`** → *Live Metrics* — show throughput, failure rate, and the load gen heartbeat.
3. *Application Map* — show outbound dependency to `aka.ms` from `/api/dep`.
4. *Failures* → click into `/api/explode` → show the full call stack of the `InvalidOperationException`.
5. *Performance* → sort by p95 → `/api/slow` is on top.
6. *Smart Detection* → walk through any auto-detected anomalies.

### Killer line
> *"Zero lines of telemetry code in the app. The platform took care of everything you see here."*

---

<a id="s4"></a>
## 4 · Kubernetes monitoring — Container Insights + Managed Prometheus + Managed Grafana

**Audience:** platform / SRE teams.
**Time:** 7–10 min.

### Story
AKS gets two parallel telemetry pipelines out of the box:
- **Container Insights** → Log Analytics (logs, perf snapshots, inventory) — for KQL & alerting.
- **Managed Prometheus** → Azure Monitor Workspace → **Azure Managed Grafana** — for high-cardinality metrics & PromQL.

### Click-path
1. **`aks-amlab`** → **Insights** → cluster → nodes → controllers → containers. Show drilling from cluster CPU to a single container.
2. **Monitor → Workbooks** → *AKS Prometheus* category → open one of the prebuilt dashboards.
3. **`amg-amlab-tr75…`** → click the Grafana endpoint → log in → import dashboard ID **`19623`** (Kubernetes / Cluster) from grafana.com → the AMW data source is already wired.
4. **`law-amlab-central`** → Logs → run saved query `04 — AKS · Pod restarts in last 24h` and `05 — AKS · Container log errors (last 1h)`.

### Killer line
> *"Same cluster, one click to add. Two world-class observability stacks, fully managed by Microsoft."*

---

<a id="s5"></a>
## 5 · Diagnostic Settings via Policy — "auto-onboard every new resource"

**Audience:** governance / cloud center of excellence.
**Time:** 5 min.

### Story
Manually setting diagnostic settings on every new resource doesn't scale. We assigned four built-in **DeployIfNotExists** policies at RG scope; they ensure every App Service, VNet, NSG, and Public IP sends `allLogs` to the central LAW.

### Click-path
1. **Policy → Assignments** → filter scope to `rg-azure-monitor-lab` → show the four `amlab-diag-*` assignments.
2. **Policy → Compliance** → click `amlab-diag-appservice` → show the App Service is **compliant**.
3. Open `app-amlab-<suffix>` → **Diagnostic settings** → show the `setByPolicy-LogAnalytics` setting that Policy created automatically.
4. *(Optional)* delete the diagnostic setting in the portal → wait ~10 min → Policy re-creates it.

### Killer line
> *"Onboarding is no longer a checklist item — it's a guarantee enforced by Azure Policy."*

---

<a id="s6"></a>
## 6 · Cross-workspace KQL — cross-team collaboration

**Audience:** ops + dev, joint session.
**Time:** 5 min.

### Story
Ops owns the infra workspace, devs own App Insights. But during an incident you need both. KQL has `workspace()` — point at any workspace by name and `join` / `union` like it's local.

### Click-path
1. Open `law-amlab-central` → **Logs** → **Queries** → category **`AzureMonitorDemoLab`**.
2. Run **`10 — CROSS-WS · App Insights failed requests vs central LAW VM CPU (normalized 0–100)`** — both series rendered on one chart.
3. Run **`11 — CROSS-WS · End-to-end story (HTTP → AppI request → AKS pod logs)`** — `union` across three tables in two workspaces.
4. Run **`12 — CROSS-WS · App Insights failures grouped by operation`**.

### Killer line
> *"Two teams, one query. No data movement. No copy-paste."*

---

<a id="s7"></a>
## 7 · Alerts — Action Group fan-out

**Audience:** on-call / SRE.
**Time:** 3 min.

### Story
Seven alerts are wired to a single Action Group (`ag-amlab-email` → `<your-alert-email>`). Mix of **metric**, **scheduled-query**, and **activity-log** alerts.

### Click-path
1. **Monitor → Alerts → Alert rules** → filter RG → show the 7 rules:
   - `alert-vm-cpu-high` (metric, multi-VM)
   - `alert-webapp-5xx` (metric)
   - `alert-aks-node-cpu-high` (metric)
   - `alert-appinsights-failed-requests` (KQL)
   - `alert-aks-pod-restart-spike` (KQL)
   - `alert-service-health` (activity log, sub scope)
   - `alert-resource-health` (activity log, RG scope)
2. Click any rule → **Edit** → walk the condition, threshold, evaluation period.
3. **Action Groups → ag-amlab-email** → show the single email receiver.

### Killer line
> *"One action group can route to email, SMS, webhooks, Logic Apps, ITSM connectors, Functions. Build alerts once, plug in receivers as the team grows."*

---

<a id="s8"></a>
## 8 · Break the lab — show the workbook turn Red live

**Audience:** anyone (highest "wow" factor).
**Time:** 5 min + 2-min wait.

### Story
Watch what a real incident looks like end-to-end: agents stop reporting, alerts fire, workbook flips colour, email arrives, then we recover.

### Click-path
1. Have the **Workbook open in one tab** and **App Insights → Failures** in another.
2. In a terminal:
   ```powershell
   ./scripts/break-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
   ```
   This deallocates both VMs, crashloops the AKS frontend, and cranks the load-gen failure rate to 80%.
3. Wait 2–3 min. Refresh the workbook:
   - **VM (Linux)** and **VM (Windows)** — heartbeat ages out.
   - **AKS Cluster** — pod restart spike.
   - **App Service** — 5xx surge.
   - **App Insights** — failed requests > 10.
4. Email alerts arrive (Service Health may not, the others should).
5. Recover:
   ```powershell
   ./scripts/restore-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
   ```
6. Workbook returns to Green within ~3 min.

### Killer line
> *"This is not slides. This is live telemetry, real alerts, real auto-mitigation hooks you could plug into."*

---

<a id="s9"></a>
## 9 · Cost control — daily caps + change visibility

**Audience:** FinOps / cloud architects.
**Time:** 3 min.

### Story
Observability can become an unbounded bill. We capped both LAWs at **1 GB/day** and we can trace every config change via the Activity Log.

### Click-path
1. **`law-amlab-central`** → **Usage and estimated costs** → show the daily cap (1 GB/day) and current burn.
2. **Logs** → run saved query `09 — Activity log · Who changed what in this RG (last 24h)`.
3. *(Optional)* enable **Change Analysis** on the App Service → open *Diagnose and solve problems* → *Change Analysis*.

### Killer line
> *"Observability with guardrails. The same LAW that detects problems also reports its own cost — and rejects ingestion past your cap."*

---

<a id="s10"></a>
## 10 · Bonus: extend the lab during the demo

If you have time, ad-hoc additions show the platform's elasticity:

| Demo idea | One-liner |
|---|---|
| Add a **second App Service** in this RG | `az webapp create … -p plan-amlab` → wait 5 min → Policy auto-creates its diagnostic setting → it shows up in the workbook automatically (after redeploy + minor query tweak). |
| Add a **DCR transformation** | Edit `dcr-amlab-vminsights` → add `transformKql` to drop noisy `Heartbeat` rows. |
| Switch a high-volume table to **Basic Logs** | `law-amlab-central` → *Tables* → `ContainerLogV2` → change plan. |
| Pin a workbook **tile to a Dashboard** | Open the workbook → *Pin* → choose any Azure Dashboard. |

---

<a id="s11"></a>
## 11 · DCR Workspace Transformation — cost control at the source

**Audience:** FinOps, platform architects.
**Time:** 5 min.

### Story
Observability bills come from **ingestion**. The cleanest way to control them is **before** data hits Log Analytics — Data Collection Rule transformations let you `where`, `extend`, `project`, even hash columns in KQL **at ingest**.

This lab uses a **Workspace Transformation DCR** — the simplest, lowest-risk variant of the pattern. It applies to data that is *already flowing* into the central LAW (in this case `AzureActivity`), via a special DCR association named `microsoft-default` on the workspace itself. **No agent change. No custom table. No new IAM.**

```
Azure platform        Workspace Transformation DCR             Log Analytics
─────────────         ───────────────────────────────          ────────────────
AzureActivity   ───>  dcr-amlab-workspace-transforms  ───>     AzureActivity table
   (every                • where /read         (FILTER)              (only the
    operation)           • bag_merge(Properties,                      surviving
                            FilteredBy + FilteredAt)  (ENRICH)        rows are billed)
                         transformKql applied HERE
```

The `microsoft-default` DCR association on the LAW is the magic that wires this in. It's also fully toggleable — break the link, transforms stop. Restore it, they're back.

### Click-path

1. *(Optional)* Show the DCR's `transformKql` so the audience sees the code:
   ```powershell
   az resource show -g rg-azure-monitor-lab `
     --resource-type Microsoft.Insights/dataCollectionRules `
     -n dcr-amlab-workspace-transforms `
     --query "properties.dataFlows[0]" -o json
   ```
   Expected:
   ```json
   {
     "streams":      [ "Microsoft-Table-AzureActivity" ],
     "destinations": [ "centralLaw" ],
     "transformKql": "source\n| where tolower(OperationNameValue) !endswith \"/read\"\n| extend Properties = bag_merge(parse_json(Properties), pack(\"FilteredBy\",\"amlab-workspace-transform\",\"FilteredAt\", tostring(now())))"
   }
   ```

2. Show the **association** wiring the DCR to the LAW (the magic name `microsoft-default`):
   ```powershell
   az monitor data-collection rule association list `
     --resource "/subscriptions/<your-subscription-id>/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.OperationalInsights/workspaces/law-amlab-central" `
     --query "[].{name:name, dcr:properties.dataCollectionRuleId}" -o table
   ```
   You should see a `microsoft-default` row pointing at `dcr-amlab-workspace-transforms`.

3. Wait ~5 min for the next batch of activity-log rows, then in `law-amlab-central` → Logs → Saved searches run **`14 — Cost · Workspace Transformation effect on AzureActivity (proof)`**.

### How to read query 14 (the proof)

Returns a **single row**. The transform is alive iff:

| Column | Expected | What it proves |
|---|---:|---|
| `RowsTotal` | > 0 | AzureActivity rows are still flowing — your transform didn't break the stream. |
| `RowsWithReadOperation` | **0** | Every `/read` operation was dropped at ingest. **This is the cost win.** In real environments, /read activities can be 60-90% of `AzureActivity` volume. |
| `RowsWithFilteredBy` | Equal to `RowsTotal` | The `bag_merge(Properties, ...)` enrich ran on every row. 100% coverage. |
| `DistinctOperations` | A list of non-/read operations (write, action, delete) | Sanity check that real-world operations still come through. |

> If `RowsWithReadOperation > 0`, you're seeing rows ingested *before* the transform took effect — the DCR association can take a couple of minutes to propagate. Run the query again with `ago(15m)` instead of `ago(1h)`.

### How to read query 15 (the eyeball check)

20 most recent `AzureActivity` rows. Look at any single row:

- `OperationNameValue` never ends with `/read` — filter proof.
- `FilteredBy` is always `"amlab-workspace-transform"` — enrich proof #1.
- `FilteredAt` is a recent ISO timestamp injected at ingest — enrich proof #2.

### Toggle the transform on/off live

To show "before vs after" cost on the same table, remove the DCR association:

```powershell
# Save it for later first (so you can restore quickly)
az monitor data-collection rule association show `
  --association-name microsoft-default `
  --resource "/subscriptions/<your-subscription-id>/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.OperationalInsights/workspaces/law-amlab-central" `
  > C:\temp\dcra.json

# Detach the transform
az monitor data-collection rule association delete `
  --association-name microsoft-default `
  --resource "/subscriptions/<your-subscription-id>/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.OperationalInsights/workspaces/law-amlab-central"
```

Force a few activity-log events (e.g. `az group show -n rg-azure-monitor-lab`) and within 5–10 min you'll see `/read` rows reappear in `AzureActivity`. To restore, simply re-run `scripts/deploy.ps1` (idempotent — recreates the association).

### Killer line
> *"Every row we don't ingest is a row we don't pay for. Same DCR pattern, same KQL skill set, end-to-end IaC, and the only switch is one association named `microsoft-default`."*

> **Where to edit a transformation in the portal**
> `dcr-amlab-workspace-transforms` → top-right **JSON View** button → look for `properties.dataFlows[0].transformKql`. The "Add transformation" UI in the *Data sources* blade only appears for **custom logs / DCE-based** flows, so for workspace transforms the JSON View (or Bicep) is canonical.

---

<a id="s12"></a>
## 12 · AMBA-aligned baseline alerts — best practice as code

**Audience:** SRE leads, operations managers.
**Time:** 3 min.

### Story
[Azure Monitor Baseline Alerts](https://aka.ms/amba) is Microsoft's open-source curation of "these are the alerts every workload should have". We deployed **9** of those rules across VM, App Service, App Service Plan, and AKS — wired to the same Action Group as the rest of the lab.

### Click-path
1. **Monitor → Alerts → Alert rules** → filter RG `rg-azure-monitor-lab` → sort by name.
2. Point at the `amba-*` prefix (9 rules):
   - VM: `amba-vm-available-memory-low`, `amba-vm-network-in-spike-{0,1}`
   - App Service: `amba-webapp-response-time`, `amba-webapp-4xx-rate`
   - App Service Plan: `amba-appplan-cpu-high`, `amba-appplan-memory-high`
   - AKS: `amba-aks-memory-working-set-high`, `amba-aks-disk-used-high`, `amba-aks-pods-not-ready`
3. Click any one → show the threshold + Action Group binding.

### Killer line
> *"You're not building alerts from scratch — you're standing on the shoulders of Microsoft's own field engineering. Same Action Group → same email → same Logic App auto-mitigation hook."*

---

<a id="s13"></a>
## 13 · Smart Detection ramp — anomaly detection with no alert rule

**Audience:** developers, AIOps-curious customers.
**Time:** 3 min setup + ~15 min wait, then 2 min closure.

### Story
Some signals are too noisy or subtle to set thresholds for. App Insights **Smart Detection** uses ML to find anomalies you didn't tell it to look for — and it costs $0 extra. We'll launch a 60-min "slow ramp" load test where failures climb from 1% → 30%. No alert rule will catch this on day 1, but Smart Detection will.

### Click-path
1. Start the ramp:
   ```powershell
   ./scripts/start-ramp.ps1
   ```
2. *(Optionally watch)*: `kubectl logs -f job/loadgen-ramp -n demo`
3. Carry on with **the rest of the demo for 15 minutes** (this is the time to do Application Map, KQL queries, etc).
4. ~15 min in, refresh **`appi-amlab` → Smart Detection** → expand the detection. You'll also have an **email from Azure** titled *"Smart Detection: Abnormal rise in failed request rate"*.
5. Open the detection card → show the root-cause analysis with the auto-generated KQL.

### Killer line
> *"This isn't a rule. This is ML watching every signal in the background, and it just told you about a problem in plain English."*

> **Reset:** the job ends automatically after 60 min, or stop it early: `kubectl delete job/loadgen-ramp -n demo`.

---

<a id="s14"></a>
## 14 · OpenTelemetry distributed tracing — AKS → App Service

**Audience:** developers, modern app teams.
**Time:** 4 min.

### Story
One App Insights instance, two different runtimes (Python on AKS + .NET on App Service), connected by an HTTP call. Both use **OpenTelemetry** — the AKS pod uses the `azure-monitor-opentelemetry` Python distro; the App Service uses the .NET auto-instrumentation. App Insights stitches them together automatically via the W3C `traceparent` header.

### Click-path
1. **`appi-amlab` → Application Map** → 2 nodes:
   - `demo.otel-caller-aks` (the AKS pod)
   - `app-amlab-<suffix>` (the App Service)
   - …with an arrow showing the cross-service dependency.
2. Click the arrow → see latency stats + a sample end-to-end trace.
3. **Investigate → End-to-end transaction details** → expand one trace → see both sides of the call (request on App Service + outbound dependency from AKS) **with the same Operation Id**.
4. **Failures** → drill into `/api/explode` calls coming **from the AKS pod** → show the call stack of the .NET exception, even though the origin is a Python service.

### Killer line
> *"Polyglot. Distributed. Zero correlation code. OTel + Azure Monitor — that's the modern app observability story."*

---

<a id="s15"></a>
## 15 · Auto-mitigation — Logic App reacts to alerts

**Audience:** SRE, on-call, automation-as-code.
**Time:** 5 min.

### Story
Most alerts end with an email. That's not enough. We deployed a Consumption Logic App with a managed identity that has **Contributor on the RG** — it's already a webhook receiver on the Action Group. When any VM alert fires, it parses the Common Alert Schema payload, identifies the target VM, and calls `…/start?api-version=2024-03-01` with its MSI.

### Which alert rule actually triggers the Logic App?

Three lab alerts touch VMs, but only **one** fires when you simply `az vm deallocate` — it's important to understand why:

| Alert rule | Type | Fires on a deallocation? | Why |
|---|---|:---:|---|
| `alert-resource-health` | Activity-log alert (RG scope) | **Yes** | Azure platform health writes a `ResourceHealth` event with `currentHealthStatus = Unavailable` (cause `UserInitiated`). The condition `category == ResourceHealth AND currentHealthStatus in (Unavailable, Degraded)` matches → alert fires within **2-10 minutes**. |
| `alert-vm-cpu-high` | Multi-resource metric alert (CPU > 80% / 5 min) | No | A deallocated VM emits **no** Azure Monitor metrics. CPU is `null`, not 100%. This alert only fires under real CPU pressure. |
| `amba-vm-available-memory-low` | Multi-resource metric alert (free memory < 200 MB / 5 min) | No | Same as above — no host emitting → no metric → no evaluation. |

So the demo path is:

```
az vm deallocate
   │
   ▼ (Azure platform health detects state change, ~2-10 min)
ResourceHealth event in Activity Log: currentHealthStatus = Unavailable
   │
   ▼ (continuous evaluation)
alert-resource-health  FIRES
   │
   ▼ (fan-out)
Action Group  ag-amlab-email
   ├── 📧 email to <your-alert-email>
   └── 🪝 webhook (Common Alert Schema) to Logic App
          │
          ▼
       la-amlab-automitigation
          • Parse_target  = data.essentials.alertTargetIDs[0]
          • Is_VM ?  (contains "microsoft.compute/virtualmachines")
              ├── true  → POST {target}/start?api-version=2024-03-01  (MSI auth)
              └── false → no-op (logs payload)
          • 200 OK response
   │
   ▼ (ARM kicks off VM start, ~30-90 s)
VM is running again → next ResourceHealth event flips back to Available.
```

> Why **`/start` and not `/restart`** in the Logic App?
> `/restart` only works on a **running** VM (returns 409 on `VM deallocated`). `/start` is idempotent: it boots a deallocated VM and is a no-op-ish 409 on a running one. We want one workflow that handles both "stuck running" *and* "stopped" scenarios.

### Click-path
1. Resource group → **`la-amlab-automitigation`** → *Overview*.
2. *Designer* → walk the workflow:
   - HTTP trigger (Common Alert Schema schema)
   - `Parse_target` Compose → extracts `alertTargetIDs[0]`
   - `Is_VM` condition → if the target is a `Microsoft.Compute/virtualMachines`
   - `Start_VM` HTTP action → uses Managed Identity to call ARM
   - Response back to the Action Group.
3. **Action Group `ag-amlab-email` → *Webhook* receiver** → show it's pointed at the Logic App callback URL.
4. **Live demo:**
   ```powershell
   # 1. Stop the Windows VM (or the Linux one)
   az vm deallocate -g rg-azure-monitor-lab -n vmwin-<suffix> --no-wait

   # 2. While waiting, refresh the Resource Health blade on the VM every minute.
   #    Within ~2-10 min it flips to "Unavailable".

   # 3. Open la-amlab-automitigation → "Runs history".
   #    You should see a run with green "Start_VM = 202 Accepted".

   # 4. Confirm the VM is back up
   az vm get-instance-view -g rg-azure-monitor-lab -n vmwin-<suffix> `
     --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv
   ```
5. *(If you don't want to wait 2-10 min)* — trigger the workflow directly to prove the path end-to-end:
   ```powershell
   # Grab the Logic App callback URL from its Overview blade or via:
   $cbUrl = az rest --method post `
     --uri "$(az resource show -g rg-azure-monitor-lab -n la-amlab-automitigation --resource-type Microsoft.Logic/workflows --query id -o tsv)/triggers/manual/listCallbackUrl?api-version=2019-05-01" `
     --query "value" -o tsv

   # Send a synthetic Common Alert Schema payload
   $vmId = az vm show -g rg-azure-monitor-lab -n vmwin-<suffix> --query id -o tsv
   $body = @{
     schemaId = 'azureMonitorCommonAlertSchema'
     data = @{
       essentials = @{
         alertId = "manual-test-$(Get-Random)"
         alertRule = "manual-test"
         severity = "Sev2"
         signalType = "Activity Log"
         monitorCondition = "Fired"
         alertTargetIDs = @($vmId)
       }
     }
   } | ConvertTo-Json -Depth 6
   Invoke-RestMethod -Method POST -Uri $cbUrl -Body $body -ContentType 'application/json'
   ```
   The Logic App will start the VM immediately, without waiting on Resource Health.

### Killer line
> *"From observability to operations as code in 70 lines of Logic App JSON. The same hook can run a runbook, kick off an Azure Function, post to Teams with one-click actions, or open a ServiceNow ticket."*

> **Safety note:** the workflow only acts on VM alerts (filtered by `microsoft.compute/virtualmachines` in `alertTargetIDs`). Every other alert (App Service 5xx, AKS pod restarts, App Insights failures, etc.) skips the `Is_VM` branch and just hits email.

---

<a id="s16"></a>
## 16 · AI in Azure Monitor — Copilot, natural language KQL, and intelligent diagnostics

**Audience:** everyone — especially skeptics who think "AI in ops" is marketing.
**Time:** 5–7 min.

### Story
Azure Monitor now has AI woven into every blade. You don't need to memorize KQL syntax, manually correlate alerts, or dig through docs to understand what's happening. **Copilot in Azure** turns monitoring from a specialist skill into a conversation — and the answers are grounded in *your* live telemetry, not generic training data.

### Prerequisites
- Copilot in Azure must be enabled on the tenant (it is on MCAP tenants by default).
- No additional cost — Copilot in Azure is included with Azure portal access.

### Click-path

#### A) Natural Language → KQL in Log Analytics (2 min)

1. **`law-amlab-central` → Logs** → click the **Copilot** button in the query editor toolbar.
2. Type a plain-English question:
   > *"Show me the top 5 VMs by average CPU in the last hour"*
3. Copilot generates KQL — review it, then **Run**.
4. Try a harder one:
   > *"Which AKS pods restarted more than 3 times in the last 24 hours and what namespace are they in?"*
5. Point out the generated KQL uses `KubePodInventory` — Copilot knows the table schema of *this* workspace.
6. One more — cross-workspace:
   > *"Show me failed requests from App Insights in the last hour with their duration"*
   Copilot generates the `workspace("law-amlab-appinsights").AppRequests` cross-workspace query automatically.

> **Killer line:** *"You just wrote three KQL queries without knowing KQL. The model sees your workspace schema — tables, columns, types — and writes idiomatic queries against your real data."*

#### B) Copilot explains existing KQL (1 min)

1. Open saved query **`10 — Cross-workspace · App Insights failed requests joined with AKS logs`** (one of the complex cross-workspace queries).
2. Select the full query text → click **Explain** (or right-click → *Explain query*).
3. Copilot produces a step-by-step plain-English breakdown of the joins, filters, and projections.

> **Killer line:** *"New team member can't read KQL? They don't have to. Copilot turns the query into documentation on demand."*

#### C) Alert summarization with Copilot (2 min)

1. **Monitor → Alerts** → find a recently fired alert (e.g. `alert-resource-health` or `alert-webapp-5xx` from a previous demo).
   - If no alert has fired, trigger one quickly:
     ```powershell
     # Generate 5xx errors to fire the webapp alert
     1..20 | ForEach-Object { Invoke-WebRequest -Uri "https://app-amlab-<suffix>.azurewebsites.net/api/explode" -SkipHttpErrorCheck }
     ```
   - Wait ~5 min for `alert-webapp-5xx` to fire.
2. Click the fired alert → open the **Alert details** blade.
3. Click **Summarize** (Copilot icon) — Copilot produces:
   - A plain-English summary of *what* happened.
   - The affected resource and time window.
   - Suggested next steps for investigation.
4. Click **Diagnose** → Copilot opens a guided investigation with relevant logs and metrics pre-loaded.

> **Killer line:** *"The on-call engineer doesn't start from zero anymore. Copilot reads the alert, pulls context from three data sources, and gives you a summary before you've finished your coffee."*

#### D) App Insights Copilot investigation (2 min)

1. **`appi-amlab` → Investigate (preview)** (left nav).
2. Copilot shows a summary of recent application health — anomalies, failure spikes, latency changes.
3. Ask a follow-up question in the chat:
   > *"Why did failure rate increase in the last 30 minutes?"*
4. Copilot correlates across `requests`, `dependencies`, `exceptions`, and `traces` tables — and explains the root cause chain.
5. *(If OTel caller is running)* Ask:
   > *"Show me the slowest end-to-end transactions between the AKS pod and the App Service"*

> **Killer line:** *"This is the same data you'd get from 15 minutes of manual KQL — delivered in 10 seconds as a conversation."*

### What's actually happening under the hood

```
User question (natural language)
   │
   ▼
Copilot in Azure
   ├── Reads workspace schema (tables, columns, types)
   ├── Reads resource context (RG, subscription, resource type)
   ├── Generates KQL grounded in YOUR data
   │     ├── No hallucinated table names
   │     └── Cross-workspace aware (sees linked LAWs)
   └── Executes against Log Analytics API
         │
         ▼
      Results + plain-English explanation
```

### The AI capabilities across Azure Monitor — cheat sheet

| Feature | Where | What it does |
|---|---|---|
| **NL → KQL** | Log Analytics → Copilot | Converts plain English to runnable KQL queries |
| **Explain query** | Log Analytics → select query → Explain | Breaks down complex KQL into plain English |
| **Alert summary** | Fired alert → Summarize | AI-generated context + next steps |
| **Investigate** | App Insights → Investigate | AI-driven root cause analysis across telemetry |
| **Smart Detection** | App Insights → Smart Detection | ML anomaly detection (see scenario 13) |
| **Dynamic thresholds** | Metric alerts → Dynamic condition | ML-learned baselines per metric — no manual threshold needed |
| **Code Optimizations** | App Insights → Performance → Code Optimizations | AI-powered .NET performance recommendations from profiler data |
| **Predictive autoscale** | VMSS → Autoscale → Predictive | ML forecasts future load and pre-scales VMSS ahead of demand |
| **Copilot chat** | Azure Portal → Copilot side panel | Ask anything about your monitoring data in context |
| **Workbook assistance** | Workbooks → Copilot | Help writing/understanding workbook queries |

### Killer line (closing)
> *"AI doesn't replace your monitoring stack — it makes every engineer on the team 10× faster at using it. The KQL is still there, the alerts are still there, the data is still yours. AI is just the fastest path from 'something's wrong' to 'here's why and here's the fix'."*

---

<a id="s17"></a>
## 17 · Dynamic Thresholds — ML-learned baselines, zero manual tuning

**Audience:** SRE, ops teams tired of alert fatigue.
**Time:** 3–4 min.

### Story
Static thresholds break the moment your traffic pattern changes — CPU 70% is fine at 2 AM but a crisis at 2 PM. **Dynamic thresholds** use ML to learn each metric's seasonal pattern (hourly, daily, weekly) and alert only on *true* deviations. No threshold to guess. No alert fatigue from false positives on weekends.

### What's deployed

The main Bicep/ARM deployment includes this dynamic threshold alert. The staged Stage C template does not currently define it.

| Resource | Value |
|---|---|
| Alert rule | `alert-vm-cpu-dynamic` |
| Metric | `Percentage CPU` (multi-resource, both VMs) |
| Criterion type | `DynamicThresholdCriterion` |
| Operator | Greater than the learned upper threshold |
| Aggregation | Average |
| Sensitivity | Medium |
| Check every | 5 minutes |
| Lookback period | 15 minutes |
| Failing periods | 1 of 1 aggregated point (within 15 minutes) |
| Ignore data before | Not set |
| Severity | Sev3 (Informational) |

A 10-minute CPU simulation can raise the 15-minute average above the learned upper threshold; the load does not need to last the full lookback period. This one-violation setting favors a short lab demonstration over filtering transient spikes. Dynamic thresholds still require at least three days and 30 metric samples, and a load run is not guaranteed to exceed the learned threshold.

A **static** alert (`alert-vm-cpu-high`, threshold 80%) is deployed alongside it — perfect for a side-by-side comparison.

### Click-path

1. **Monitor → Alerts → Alert rules** → filter RG `rg-azure-monitor-lab`.
2. Open **`alert-vm-cpu-dynamic`** → show the condition:
   - **Threshold type** = `Dynamic` (not Static).
   - **Value is** = Greater than; **Aggregation** = Average.
   - **Sensitivity** = Medium.
   - **Check every** = 5 minutes; **Lookback period** = 15 minutes.
   - **Failing periods** = 1 of 1 aggregated point within 15 minutes.
3. Click **Preview** and compare the CPU average with the learned upper threshold. Look for normal samples below that bound and the simulation spike above it; confirm actual fired alerts separately in **Monitor > Alerts**.
4. Now open **`alert-vm-cpu-high`** (static, threshold 80%) side-by-side → show the rigid flat line vs the dynamic ML band.
5. Point out:
   - **Sensitivity**: High / Medium / Low — controls how tight the band is.
   - **Lookback period**: the window used to average the metric at each check, not the model's historical learning period or a required duration of continuous load.
   - **Number of violations**: how many aggregated points must breach the threshold within the configured period; this lab default requires one of one.

### Deeper story: when dynamic beats static

| Scenario | Static threshold | Dynamic threshold |
|---|---|---|
| Weekend traffic drop | CPU at 15% — static threshold 80% never fires, but a sudden jump to 40% (anomalous for a weekend) goes unnoticed | ML band narrows on weekends → 40% spike triggers alert |
| Black Friday traffic surge | CPU at 85% — static threshold 80% fires every minute for hours (alert fatigue) | ML band widens during expected surges → only alerts on *unexpected* deviation above the surge |
| Gradual memory leak | Creeps from 60% → 79% over days — never hits 80% | Trend detection flags the anomalous upward drift |

### Killer line
> *"You set the sensitivity — the ML sets the threshold. It learns your workload's rhythm, and it adapts when the rhythm changes."*

---

<a id="s18"></a>
## 18 · Code Optimizations — AI finds your .NET performance bottlenecks

**Audience:** .NET developers, performance engineers.
**Time:** 3–4 min.

### Story
Application Insights doesn't just *measure* latency — with **Code Optimizations**, it analyzes your .NET profiler traces and tells you *exactly which lines of code* are slow and what to do about it. It's like having a senior performance engineer review your code 24/7.

### Prerequisites
- The App Service (`app-amlab-<suffix>`) is already auto-instrumented with App Insights (the .NET 8 auto-instrumentation handles profiling).
- Code Optimizations works on production profiler data — no code changes needed.
- For a *guaranteed* recommendation on demand, the lab webapp ships a `GET /api/inefficient` endpoint with four detectable anti-patterns (string concat in loop, exception-throwing in loop, sync-over-async, O(n²) `List.Contains`) — see [workloads/webapp/Program.cs](../workloads/webapp/Program.cs).

### Click-path

**Option A — Force a recommendation (lab/demo prep, ~30 min of load + 1-24 h wait):**

```powershell
./scripts/trigger-code-optimization.ps1                  # publishes + drives 30 min of load
./scripts/trigger-code-optimization.ps1 -SkipPublish -DurationMinutes 60   # additional run if nothing surfaces yet
```

The script publishes the updated webapp (so `/api/inefficient` is live), then runs 8 parallel workers against it for 30 min. It also posts a `code-optimization-load-*` release annotation so you can see the load window on every chart. Recommendations typically appear within 1-24 h.

**Option B — Walk the UI live:**

1. **`appi-amlab` → Performance** (left nav) → **Code Optimizations** tab (or *Investigate* → *Code Optimizations*).
2. If recommendations are available, expand one:
   - **Insight type** — e.g. "String concatenation in a hot path", "Synchronous I/O on async call stack", "Excessive allocations in request pipeline".
   - **Call tree** — the exact method chain from your code (e.g. `Program.cs → SlowEndpoint → Thread.Sleep`).
   - **Recommendation** — concrete code change with expected impact.
3. If no recommendations yet (the lab app is small), show the **UI and explain the concept**:
   - Profiler snapshots are collected automatically on production traffic.
   - AI analyzes CPU usage, allocations, and contention across thousands of traces.
   - Results surface as actionable code-level recommendations — not just "CPU is high" but "*this method in this file* is spending 40% of CPU on string allocations".

### What Code Optimizations can find

| Category | Example insight |
|---|---|
| **CPU** | `StringBuilder` vs string concatenation in a loop |
| **Allocations** | Large object heap pressure from repeated `ToArray()` calls |
| **Async** | `Task.Result` blocking an async call stack (sync-over-async anti-pattern) |
| **I/O** | Synchronous database calls in request pipeline |
| **Contention** | Lock contention on a shared dictionary in a hot path |

### Killer line
> *"The profiler runs in production with <1% overhead. The AI reads the traces. You get a pull-request-ready recommendation. That's the gap between 'it's slow' and 'here's the fix on line 47'."*

---

<a id="s19"></a>
## 19 · Predictive Autoscale — ML pre-scales VMSS before the traffic arrives

**Audience:** infra architects, capacity planners, cost-conscious ops.
**Time:** 3–4 min.

### Story
Reactive autoscale has a fundamental problem: by the time CPU hits 80% and you scale out, users already experienced latency. **Predictive autoscale** for VMSS uses the same ML engine as dynamic thresholds to learn your traffic pattern and **pre-provisions instances *before* the load arrives** — so when the spike hits, capacity is already there.

### What's deployed

The lab includes a live VMSS with predictive autoscale already configured:

| Resource | Value |
|---|---|
| VMSS | `vmss-amlab` (1 × Standard_B1s, Ubuntu 22.04, Uniform orchestration) |
| Autoscale setting | `autoscale-vmss-amlab` |
| Reactive rule | Scale out when CPU > 70% for 10 min; scale in when CPU < 30% |
| Predictive mode | **ForecastOnly** (shows predictions without acting — safe for demo) |
| Look-ahead time | 10 minutes |
| Instance range | min 1 / max 5 / default 1 |

### Click-path

1. Resource group → **`vmss-amlab`** → **Scaling** (left nav).
2. Show the autoscale setting is already **Custom autoscale** with:
   - Scale-out rule: *"When CPU > 70% for 10 min → add 1 instance"*.
   - Scale-in rule: *"When CPU < 30% for 10 min → remove 1 instance"*.
3. Scroll to **Predictive autoscale** → it's already set to **Forecast only**.
   - Explain the three modes: *Disabled* / *Forecast only* / *Forecast and scale*.
   - The lab uses *Forecast only* so you can see predictions without cost impact.
4. Show the **prediction chart** (visible after ~14 days of metric history):
   - X-axis: time (next 24–72 hours).
   - Blue shaded area: predicted instance count.
   - Orange line: reactive autoscale (what *would* happen without prediction).
   - **Gap between the two** = time you'd be under-provisioned with reactive-only.
5. Point out the **lead time**: the model pre-scales **~10 minutes ahead** of predicted demand (configurable via `scaleLookAheadTime`).
6. *(Optional)* Show the Bicep definition:
   ```powershell
   az monitor autoscale show -g rg-azure-monitor-lab -n autoscale-vmss-amlab \
     --query "{predictiveMode:predictiveAutoscalePolicy.scaleMode, lookAhead:predictiveAutoscalePolicy.scaleLookAheadTime, rules:profiles[0].rules[].{metric:metricTrigger.metricName, op:metricTrigger.operator, threshold:metricTrigger.threshold, action:scaleAction.direction}}" -o json
   ```

### How it works under the hood

```
Historical metrics (14 days min)
   │
   ▼
ML model (same engine as dynamic thresholds)
   ├── Learns hourly, daily, weekly patterns
   ├── Detects recurring spikes (e.g. 9 AM login surge)
   └── Forecasts instance count for next window
         │
         ▼
   Predictive autoscale engine
   ├── Compares forecast vs current instance count
   ├── Pre-scales OUT if forecast > current (ahead of demand)
   └── Scale-IN still uses reactive rules (conservative wind-down)
```

### When predictive autoscale shines

| Pattern | Reactive only | With predictive |
|---|---|---|
| **9 AM daily login surge** | Scale-out starts at 9:05 when CPU spikes. Users get 5 min of latency. | Instances are already running at 8:45. Zero impact. |
| **Weekly batch job (Sunday 2 AM)** | Over-provisions 24/7 "just in case", or under-provisions and the job runs slow. | Learns the Sunday pattern, scales only when needed. |
| **Marketing campaign launch** | Can't predict — still falls back to reactive rules. | Same — predictive helps with *recurring* patterns, not one-off events. |

### Key constraints to mention
- Requires **14 days of metric history** for the initial model.
- Works on **VMSS only** (not App Service, not AKS — those have their own autoscale mechanisms).
- Scale-IN is always reactive (never predictively removes instances — safety first).
- The prediction uses **CPU percentage** as the primary signal.

### Killer line
> *"Reactive autoscale is like hiring staff after the restaurant is full. Predictive autoscale reads the reservation book and has the staff ready before the guests arrive."*

---

<a id="s20"></a>
## 20 · Basic vs Analytics Logs — 8× cheaper ingestion with one toggle

**Audience:** FinOps, platform architects, cost-conscious ops.
**Time:** 3–4 min.

### Story
Not every log table needs full KQL power. **Basic Logs** costs ~8× less per GB — with the trade-off of 30-day interactive retention and limited KQL operators (no `join`, `summarize`, `union`). For high-volume, low-query tables like `ContainerLogV2`, it's a massive cost win.

### Click-path

1. **`law-amlab-central` → Tables** → find **`ContainerLogV2`** → note the current plan is **Analytics**.
2. Show the current daily ingestion:
   ```
   Usage | where DataType == "ContainerLogV2" | where TimeGenerated > ago(7d)
   | summarize DailyGB = sum(Quantity)/1024 by bin(TimeGenerated, 1d)
   ```
3. Toggle to Basic:
   ```powershell
   ./scripts/toggle-table-plan.ps1 -ResourceGroup $resourceGroup -Plan Basic
   ```
4. Show what changes:
   - **Works:** `ContainerLogV2 | where LogMessage has "error" | take 10`
   - **Fails:** `ContainerLogV2 | summarize count() by PodName` → error: *summarize not supported on Basic Logs*
5. Toggle back:
   ```powershell
   ./scripts/toggle-table-plan.ps1 -ResourceGroup $resourceGroup -Plan Analytics
   ```

### Key comparison

| | Analytics Logs | Basic Logs |
|---|---|---|
| **Ingestion cost** | ~$2.76/GB | ~$0.55/GB (8× cheaper) |
| **Retention** | 30d–730d interactive | 30 days interactive |
| **KQL** | Full | where, extend, parse, project only |
| **Alerts** | Standard log search alerts | Supported (higher per-eval cost) |
| **Search Jobs** | N/A | Use for ad-hoc complex queries |

### Killer line
> *"One property change on the table, zero code changes, and your Container Insights bill drops 80%. For tables you query rarely but ingest constantly, Basic Logs is the answer."*

---

<a id="s21"></a>
## 21 · Summary Rules — pre-aggregate data, pay less, query faster

**Audience:** FinOps, platform architects, dashboard builders.
**Time:** 4–5 min.

### Story
Dashboards that scan millions of raw `Perf` rows every refresh are slow and expensive. **Summary Rules** run hourly in the background, pre-aggregate raw data into a compact custom table (`Perf_Hourly_CL`), and give you the same answer from orders-of-magnitude fewer rows. Same KQL, same charts — fraction of the scan cost.

### What's deployed

| Resource | Value |
|---|---|
| Summary rule | `rule-perf-hourly` on `Perf_Hourly_CL` |
| Source table | `Perf` (ObjectName: Processor, Memory, LogicalDisk) |
| Aggregation | avg, min, max, count per Computer per CounterName per hour |
| Target table | `Perf_Hourly_CL` (180-day retention) |
| Schedule | Runs every hour automatically |

### Click-path

1. **`law-amlab-central` → Tables** → find **`Perf_Hourly_CL`** → show it exists as a custom table with 180-day retention.
2. Run saved query **`18 — Cost · Summary Rule: raw Perf vs aggregated Perf_Hourly_CL`** — shows the compression ratio (typically 50:1 to 200:1).
3. Compare two dashboard queries side by side:
   ```kql
   // RAW (slow, expensive — scans millions of rows)
   Perf | where TimeGenerated > ago(7d)
   | where CounterName == "% Processor Time"
   | summarize avg(CounterValue) by Computer, bin(TimeGenerated, 1h)
   | render timechart
   ```
   ```kql
   // SUMMARY (fast, cheap — scans hundreds of rows)
   Perf_Hourly_CL | where TimeGenerated > ago(7d)
   | where CounterName == "% Processor Time"
   | project TimeGenerated, Computer, AvgValue
   | render timechart
   ```
4. *(Optional)* Show the summary rule definition:
   ```powershell
   az monitor log-analytics workspace table show -g rg-azure-monitor-lab --workspace-name law-amlab-central -n Perf_Hourly_CL --query "properties.summaryRules" -o json
   ```

### When to use summary rules

| Pattern | Without summary | With summary |
|---|---|---|
| **Executive dashboard (7-day view)** | Scans 5M Perf rows per refresh | Scans ~2,000 pre-aggregated rows |
| **Long-term trending (90-day)** | Raw data expired at 30 days | Summary retained for 180 days |
| **Multi-team workbook** | Each viewer re-scans raw data | All viewers hit the same tiny table |

### Killer line
> *"The summary rule runs once per hour in the background. Every dashboard that reads from it is instant. You're trading one hourly write for thousands of avoided reads."*

---

<a id="s22"></a>
## 22 · Availability Tests — synthetic monitoring from 5 global locations

**Audience:** app owners, SRE, business stakeholders.
**Time:** 3–4 min.

### Story
Real users are spread across the world. **Availability Tests** ping your app from 5 global Azure regions every 5 minutes. If 2+ locations fail, an alert fires instantly. No real traffic needed — the test is synthetic, always-on, and checks SSL certificate expiry too.

### What's deployed

| Resource | Value |
|---|---|
| Test | `avail-amlab-appservice` (Standard URL test) |
| URL | `https://app-amlab-*.azurewebsites.net/` |
| Locations | South Central US, North Central US, UK South, West Europe, Southeast Asia |
| Frequency | Every 5 min |
| Alert | `alert-avail-amlab-appservice` — fires when 2+ locations fail |
| SSL check | Enabled — warns if cert expires within 7 days |

### Click-path

1. **`appi-amlab` → Availability** (left nav) → show the scatter chart: each dot is a test execution from a global location.
2. Click any dot → see response time, HTTP status, SSL validation result.
3. **Map view** → show the 5 probe locations on a world map with green/red status.
4. Run saved query **`22 — Availability · Global test results (last 1h)`** — tabular view with pass/fail per location.
5. **Live failure demo:** (ties into Scenario 8)
   ```powershell
   # Stop the App Service to trigger failures
   az webapp stop -g rg-azure-monitor-lab -n $(az webapp list -g rg-azure-monitor-lab --query "[0].name" -o tsv)
   ```
   Wait 5 min → map goes red worldwide → alert fires → email arrives.
   ```powershell
   # Restore
   az webapp start -g rg-azure-monitor-lab -n $(az webapp list -g rg-azure-monitor-lab --query "[0].name" -o tsv)
   ```

### Killer line
> *"Your users are in Singapore, London, and Texas. Now your monitoring is too. Five locations, five minutes, zero instrumentation code."*

---

<a id="s23"></a>
## 23 · Alert Processing Rules — enterprise-grade alert management

**Audience:** SRE leads, on-call engineers, operations managers.
**Time:** 3–4 min.

### Story
Alert rules define *what* to detect. **Alert Processing Rules** define *what happens next* — without touching the rules themselves. Suppress all alerts during a maintenance window. Route Sev0 to PagerDuty and Sev4 to a Teams channel. Override any Action Group, any time, any scope. It's the enterprise control plane for alert routing.

### What's deployed

| Resource | Value |
|---|---|
| `apr-amlab-maintenance-window` | Suppresses ALL alerts every Sunday 02:00–06:00 UTC (recurring) |
| `apr-amlab-suppress-low-sev` | Suppresses Sev3+Sev4 alerts (disabled by default — enable during demo) |

### Click-path

1. **Monitor → Alerts → Alert processing rules** → show the two rules.
2. Open **`apr-amlab-maintenance-window`** → walk the schedule:
   - **Scope:** entire resource group.
   - **Schedule:** recurring, every Sunday 02:00–06:00 UTC.
   - **Action:** Remove all action groups (= suppress all notifications).
3. Open **`apr-amlab-suppress-low-sev`** → walk the condition filter:
   - **Condition:** Severity equals Sev3 or Sev4.
   - **Action:** Remove all action groups.
   - **Status:** Disabled (safe default — enable it live during the demo).
4. **Live demo:**
   ```powershell
   # Enable the low-sev suppression rule
   az rest --method PATCH \
     --uri "/subscriptions/{sub}/resourceGroups/rg-azure-monitor-lab/providers/Microsoft.AlertsManagement/actionRules/apr-amlab-suppress-low-sev?api-version=2024-03-01-preview" \
     --body '{"properties":{"enabled":true}}'
   ```
   Now fire a Sev3 alert (e.g. the dynamic threshold) → it fires but **no email arrives**.
   Disable the rule → next firing sends the email again.

### Real-world use cases

| Scenario | Processing rule |
|---|---|
| **Planned maintenance** | Suppress all alerts in RG during window |
| **Severity routing** | Sev0-1 → PagerDuty + Teams, Sev2 → email, Sev3-4 → suppress |
| **Regional failover** | Suppress alerts from DR region during active failover |
| **Noisy resource** | Suppress alerts from one specific VM without disabling the rule |

### Killer line
> *"You don't rewrite alert rules for every operational scenario. You layer processing rules on top — like a mail filter that routes, suppresses, and enriches without touching the source."*

---

<a id="s24"></a>
## 24 · Custom Logs via Ingestion API — any system can ship logs to LAW

**Audience:** platform engineers, security teams, integration architects.
**Time:** 5–7 min.

### Story
Log Analytics isn't just for Azure resources. The **Logs Ingestion API** lets any system — on-prem servers, SaaS webhooks, IoT devices, CI/CD pipelines — push structured JSON into a custom table. The pipeline: your code → Data Collection Endpoint → Data Collection Rule (with optional KQL transform) → custom table in LAW. Full KQL, alerts, workbooks — on data from anywhere.

### What's deployed

| Resource | Value |
|---|---|
| Data Collection Endpoint | `dce-amlab-customlogs` |
| Data Collection Rule | `dcr-amlab-customlogs` |
| Custom table | `SecurityAudit_CL` (9 columns: TimeGenerated, EventType, Severity, UserPrincipal, SourceIP, Resource, Action, Result, Details) |
| Demo script | `scripts/send-custom-logs.ps1` |

### Click-path

1. Show the custom table schema: **`law-amlab-central` → Tables → `SecurityAudit_CL`** → expand columns.
2. Run the ingestion script:
   ```powershell
   ./scripts/send-custom-logs.ps1 -Count 20
   ```
3. Wait ~2-5 min, then run saved query **`16 — Custom Logs · SecurityAudit_CL events (last 1h)`**.
4. Run saved query **`17 — Custom Logs · Security event breakdown`** — shows aggregation works exactly like any native table.
5. *(Optional)* Show the DCR → Data flows → `transformKql` is `source` (passthrough). Explain that you could add filtering, enrichment, or redaction here — same pattern as Scenario 11.
6. *(Optional)* Show the ingestion pipeline diagram:
   ```
   PowerShell script
      │ POST /dataCollectionRules/{dcrId}/streams/Custom-SecurityAudit_CL
      ▼
   Data Collection Endpoint (dce-amlab-customlogs)
      │ authenticates via Entra ID token
      ▼
   Data Collection Rule (dcr-amlab-customlogs)
      │ validates schema
      │ applies transformKql (passthrough in this demo)
      ▼
   SecurityAudit_CL table in law-amlab-central
      │ full KQL, alerts, workbooks, RBAC
   ```

### Killer line
> *"If it can make an HTTPS POST with a JSON body, it can ship logs to Log Analytics. Same KQL. Same alerts. Same RBAC. The table doesn't know or care where the data came from."*

---

<a id="s25"></a>
## 25 · Change Analysis — correlate config changes with failures

**Audience:** on-call engineers, developers, SRE.
**Time:** 3–4 min.

### Story
The first question in any incident: *"did anything change?"*. **Change Analysis** tracks every Azure resource configuration change and correlates it with application performance data. When the failure spike started 10 minutes after someone changed an app setting, Change Analysis shows you the exact diff.

### Click-path

1. **`app-amlab-*` → Diagnose and solve problems** → search for **"Change Analysis"**.
2. Show the change timeline — every config modification to the App Service (app settings, connection strings, platform version, etc.).
3. **Live demo — cause a change and watch it appear:**
   ```powershell
   # Add a dummy app setting
   $appName = az webapp list -g rg-azure-monitor-lab --query "[0].name" -o tsv
   az webapp config appsettings set -g rg-azure-monitor-lab -n $appName --settings DEMO_CHANGE="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -o none

   # Simultaneously break the app
   1..10 | ForEach-Object { Invoke-WebRequest "https://$appName.azurewebsites.net/api/explode" -SkipHttpErrorCheck | Out-Null }
   ```
4. Wait ~5 min → refresh Change Analysis → the new `DEMO_CHANGE` app setting appears in the timeline.
5. Overlay with **App Insights → Failures** → show the spike started right after the change.
6. *(Optional)* **`app-amlab-*` → Activity Log** → filter to the same timeframe → show the ARM write operation that modified the app setting.

### Killer line
> *"The hardest 30 minutes of any incident is 'what changed?'. Change Analysis answers that question in 3 seconds — and shows you the exact diff."*

---

<a id="s26"></a>
## 26 · KQL Functions — reusable query abstractions

**Audience:** KQL power users, platform teams, workbook builders.
**Time:** 3–4 min.

### Story
Writing the same complex query in every workbook, alert, and ad-hoc investigation is error-prone and hard to maintain. **KQL functions** let you save a query once and call it by name — like a stored procedure. Update the function, and every consumer gets the new logic automatically.

### What's deployed

Three saved functions in `law-amlab-central`:

| Function | What it returns |
|---|---|
| `vmHealth()` | One row per VM with traffic-light status (Green/Orange/Red) based on heartbeat age + CPU |
| `aksHealth()` | One row per AKS pod with traffic-light status based on pod state + restarts |
| `envHealth()` | Combined view: unions `vmHealth()` + `aksHealth()` + App Insights failure rate. Cross-workspace. |

### Click-path

1. **`law-amlab-central` → Logs** → type `vmHealth()` → Run. Show the traffic-light table.
2. Type `aksHealth()` → Run. Same pattern for AKS pods.
3. Type `envHealth()` → Run. **One function call**, all resources, cross-workspace, sorted Red → Orange → Green.
4. Show how functions compose:
   ```kql
   // Filter to only Red resources
   envHealth() | where Status == "Red"

   // Use in an alert rule
   envHealth() | where Status == "Red" | summarize RedCount = count()
   ```
5. Show the function definition: **Logs → Saved searches** → category `AzureMonitorDemoLab` → find `Function: vmHealth()` → show the underlying KQL.
6. *(Optional)* Edit `vmHealth()` to change the CPU threshold from 90 → 80 → re-run → all consumers see the update.

### Killer line
> *"One function, one truth. Every workbook, every alert, every ad-hoc query calls the same logic. Update the function — the whole platform updates with it."*

---

<a id="s27"></a>
## 27 · Log Analytics Granular RBAC — table and row-level access with ABAC conditions

**Audience:** security teams, compliance officers, platform architects.
**Time:** 5–7 min.

### Story
Not everyone should see everything. Log Analytics now has **Granular RBAC** (GA Nov 2025) — using Azure ABAC (Attribute-Based Access Control) conditions on role assignments to restrict data access at the **table** and **row** level. One custom role + different conditions per assignment = precise data boundaries. No extra tools, fully IaC-deployable, auditable in the Activity Log.

### What's deployed

| Tier | Mechanism | What's in the lab |
|---|---|---|
| **Workspace-level** | Built-in role: `Log Analytics Reader` | Grants read on ALL tables, ALL rows. No ABAC conditions. |
| **Table-level** | Custom role `AMLAB - Granular Log Reader` + ABAC condition | Condition: only `SecurityAudit_CL` table is readable. All other tables return 0 rows. |
| **Row-level** | Same custom role + ABAC condition with row filter | Condition: only `SecurityAudit_CL` AND only rows where `Severity == Critical`. Non-critical rows are invisible. |

**Custom role:** `AMLAB - Granular Log Reader`
- `Actions:` `workspaces/read`, `workspaces/query/read`
- `DataActions:` `workspaces/tables/data/read` ← this is the key — ABAC conditions filter on this DataAction

### Click-path

#### A) Workspace-level: unrestricted (1 min)

1. **`law-amlab-central` → Access control (IAM)** → show current role assignments.
2. Show the built-in `Log Analytics Reader` role → explain it grants read on every table, every row — no conditions.
3. Point out: **anyone with this role sees all data**. This is the broadest tier.

#### B) Table-level: ABAC condition restricting to one table (3 min)

1. **Access control (IAM) → Roles** → search for `AMLAB - Granular Log Reader`.
2. Open the custom role → show:
   - `Actions:` `workspaces/read`, `workspaces/query/read` — control plane.
   - `DataActions:` `workspaces/tables/data/read` — data plane. **This is what ABAC filters.**
3. Show a table-level assignment → click the **Conditions** tab → show the ABAC condition:
   ```
   IF action matches tables/data/read
     THEN table name MUST equal "SecurityAudit_CL"
   ```
4. Explain the CLI equivalent:
   ```powershell
   # Assign with ABAC condition (restrictive strategy)
   az role assignment create `
     --assignee <user-object-id> `
     --role "AMLAB - Granular Log Reader" `
     --scope "<law-resource-id>" `
     --condition "((!(ActionMatches{'Microsoft.OperationalInsights/workspaces/tables/data/read'})) OR (@Resource[Microsoft.OperationalInsights/workspaces/tables:name] StringEquals 'SecurityAudit_CL'))" `
     --condition-version "2.0"
   ```
5. **What the user experiences:** `SecurityAudit_CL | take 10` returns rows, but `Heartbeat | take 10` → **0 rows**.

#### C) Row-level: ABAC condition filtering by column value (3 min)

1. Show a row-level assignment → click the **Conditions** tab → show the compound ABAC condition:
   ```
   IF action matches tables/data/read
     THEN table name MUST equal "SecurityAudit_CL"
     AND  Severity column MUST equal "Critical"
   ```
2. Run saved query **`21 — RBAC · Granular RBAC proof (ABAC conditions)`**:
   - Full-access user sees all severities: Info, Warning, Critical.
   - Row-filtered user sees **only Critical** rows — everything else is silently filtered.
3. Show the filtering logic:
   ```
   User has: Granular Log Reader + ABAC (Severity == Critical)
      │
      ▼
   Queries: SecurityAudit_CL | summarize count() by Severity
      │
      ▼
   Log Analytics data plane checks ABAC condition per row:
      ├── Severity == "Critical" → returned
      ├── Severity == "Warning"  → filtered out silently
      └── Severity == "Info"     → filtered out silently
   ```
4. Point out: you can filter on **any column** — `UserPrincipal`, `SourceIP`, `EventType`, etc.

### ABAC operators available

| Operator | Use case |
|---|---|
| `StringEquals` / `StringNotEquals` | Exact match (case-sensitive) |
| `ForAllOfAnyValues:StringEquals` | Column value must be in a set |
| `ForAnyOfAnyValues:StringLikeIgnoreCase` | Wildcard + case-insensitive match |

### Two strategies

| Strategy | Description | Condition pattern |
|---|---|---|
| **Restrictive** ("No access except allowed") | Deny by default, allow specific tables/rows | `!(ActionMatches{...}) OR (table == X AND column == Y)` |
| **Permissive** ("Access to all except denied") | Allow by default, deny specific rows | `!(ActionMatches{...}) OR (table != X)` or `column != Y` |

### The three tiers visualised

```
┌───────────────────────────────────────────────────────┐
│  WORKSPACE-LEVEL (Log Analytics Reader — no conditions)│
│  Can see: ALL tables, ALL rows                         │
│  ┌───────────────────────────────────────────────────┐ │
│  │  TABLE-LEVEL (Granular role + ABAC on table name) │ │
│  │  Can see: SPECIFIC tables, ALL rows in those      │ │
│  │  ┌─────────────────────────────────────────────┐  │ │
│  │  │  ROW-LEVEL (Granular role + ABAC on column) │  │ │
│  │  │  Can see: SPECIFIC tables, SPECIFIC rows    │  │ │
│  │  │  (e.g., Severity == Critical only)          │  │ │
│  │  └─────────────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────┘
```

### Important notes for the demo
- **Propagation delay:** ABAC conditions take up to **15 minutes** to propagate after assignment.
- **Additive model:** If a user also has `Log Analytics Reader` (no conditions), ABAC cannot restrict them — the broader role wins. Remove the broader assignment first.
- **Workspace access mode:** The LAW is set to "Require workspace permissions" (`enableLogAccessUsingOnlyResourcePermissions: false`) so ABAC is fully enforced.

### Killer line
> *"One role, three access levels — just by changing the ABAC condition. Table-level, row-level, column-value filtering — all native Azure, all deployable as Bicep, all auditable."*

---

<a id="s28"></a>
## 28 · App Insights — Custom TrackMetric + custom events (`/api/checkout`)

**Audience:** developers, app owners — anyone who's heard "auto-instrumentation isn't enough".
**Time:** 4–5 min.

### Story
Auto-instrumentation captures requests, dependencies, exceptions — the *generic* shape of the app. But every app has **business-specific** signals: cart value, checkouts per minute, payment-decline rate. Those need a couple lines of code via `TrackMetric` and `TrackEvent`. The lab's `/api/checkout` endpoint does exactly that and intentionally fails 5% of the time with HTTP 402.

### What's in the code

```csharp
// Program.cs — runs alongside the auto-instrumentation
app.MapPost("/api/checkout", (HttpRequest req, TelemetryClient telemetry) =>
{
    var cart = Random.Shared.Next(5, 250);                          // EUR
    var paymentOk = Random.Shared.Next(100) >= 5;                   // 5% decline rate
    var channel = req.Headers.TryGetValue("X-Amlab-Channel", out var v) ? v.ToString() : "web";

    telemetry.GetMetric("amlab.cartValue").TrackValue(cart);        // pre-aggregated metric
    telemetry.TrackEvent("CheckoutCompleted", new Dictionary<string, string> {
        { "channel", channel },
        { "paymentResult", paymentOk ? "ok" : "declined" }
    });

    return paymentOk ? Results.Ok(new { ok = true, cart })
                     : Results.StatusCode(402);
});
```

### Click-path

1. Trigger a wave of checkouts (mix of channels):
   ```powershell
   $url = "https://app-amlab-<suffix>.azurewebsites.net/api/checkout"
   1..120 | ForEach-Object {
     $h = @{ 'X-Amlab-Channel' = (@('web','mobile','partner') | Get-Random) }
     Invoke-WebRequest -Uri $url -Method POST -Headers $h -SkipHttpErrorCheck -UseBasicParsing | Out-Null
   }
   ```
2. **`appi-amlab` → Metrics** → namespace **azure.applicationinsights** → metric **`amlab.cartValue`** → split by anything → render as line chart. Show p50 / p95 / avg pivots.
3. Run saved query **`27 — Custom · App Insights amlab.cartValue metric (1h)`** — same data via KQL on `AppMetrics`.
4. Run saved query **`28 — Custom · CheckoutCompleted events (1h)`** — `ok` vs `declined` stacked column — the **5% intentional decline** is plainly visible.
5. Optional: add an alert directly on the custom metric — *"Avg cart value drops below €40 for 10 min"*. Same alert engine, same Action Group.

### Why this matters

| Auto-instrumentation gives you | TrackMetric / TrackEvent adds |
|---|---|
| HTTP requests, status codes, duration | **Business meaning** — what was sold, in which channel, for how much |
| Dependency call latency | **Domain KPI alerts** — checkout success rate, cart value drift |
| Exceptions with stack traces | **Funnel analysis** — which channel converts best |

### Killer line
> *"Auto-instrumentation tells you the app is healthy. Custom metrics tell you the **business** is healthy. Three lines of code per signal — and you alert on revenue, not on HTTP status codes."*

---

<a id="s29"></a>
## 29 · App Insights — Profiler + Snapshot Debugger

**Audience:** .NET developers, performance engineers, support escalation.
**Time:** 3–4 min.

### Story
When `/api/slow` is slow you want to know **which line of code** is hot. When `/api/explode` throws you want the **full state of every local variable** at the moment it threw. **Profiler** and **Snapshot Debugger** answer those — turned on with two app settings, zero code changes, <1% production overhead.

### What's deployed

The lab's App Service `app-amlab-<suffix>` has both turned on via `infra/modules/appservice.bicep`:

| App setting | Value | What it does |
|---|---|---|
| `APPINSIGHTS_PROFILERFEATURE_VERSION` | `1.0.0` | Enables continuous .NET Profiler |
| `DiagnosticServices_EXTENSION_VERSION` | `~3` | Enables Snapshot Debugger |
| `APPINSIGHTS_SNAPSHOTFEATURE_VERSION` | `1.0.0` | Activates Snapshot Debugger |

### Click-path

1. Generate slow traffic + exceptions:
   ```powershell
   1..30 | ForEach-Object { Invoke-WebRequest "https://app-amlab-<suffix>.azurewebsites.net/api/slow"    -UseBasicParsing | Out-Null }
   1..15 | ForEach-Object { Invoke-WebRequest "https://app-amlab-<suffix>.azurewebsites.net/api/explode" -SkipHttpErrorCheck -UseBasicParsing | Out-Null }
   ```
2. **`appi-amlab` → Performance → Profiler** → wait until a profile is collected (5-15 min). Click a sample → flame graph appears → **`Thread.Sleep`** lights up red as the hot frame.
3. **`appi-amlab` → Failures → click an `/api/explode` row → Open debug snapshot** → you see the local `boom` variable, the call stack, and parameters captured at the exception moment.
4. *(Optional)* Verify the app settings are in place:
   ```powershell
   az webapp config appsettings list -g rg-azure-monitor-lab -n app-amlab-<suffix> `
     --query "[?contains(name,'PROFILER') || contains(name,'SNAPSHOT') || contains(name,'DiagnosticServices')]" -o table
   ```

### Killer line
> *"Two app settings. No deploy. No code change. You get a flame graph and a debugger snapshot from production traffic — the gap between 'it's slow' and 'fix line 47'."*

---

<a id="s30"></a>
## 30 · AKS — Node.js auto-instrumentation (`@azure/monitor-opentelemetry`)

**Audience:** developers running Node.js services, polyglot platform teams.
**Time:** 3–4 min.

### Story
Scenario 14 showed Python + .NET wired into the same App Insights via OpenTelemetry. Now a **Node.js** workload joins the trace graph using Microsoft's GA distro **`@azure/monitor-opentelemetry`** — one require, one env var, full request/dependency/log capture. No webpack-style instrumentation hooks, no manual `tracer.startSpan`.

### What's deployed

`workloads/k8s/05-nodeapp-otel.yaml` deploys 1 pod in namespace `demo`:
- Image: `node:20-alpine`
- Runtime script (inlined via ConfigMap): on boot, `npm install @azure/monitor-opentelemetry@^1.10.0`, then `require('@azure/monitor-opentelemetry').useAzureMonitor()` — the whole process is instrumented before user code runs.
- Calls `${APP_SERVICE_URL}/api/echo` every 5 seconds.
- Env var `APPLICATIONINSIGHTS_CONNECTION_STRING` is injected at apply time by `scripts/post-deploy.ps1`.

### Click-path

1. Verify the pod is running:
   ```powershell
   kubectl -n demo get pods -l app=nodeapp-otel
   kubectl -n demo logs -l app=nodeapp-otel --tail=20
   ```
2. **`appi-amlab` → Application Map** → now **three** cloud-role-name nodes:
   - `app-amlab-<suffix>` (.NET on App Service)
   - `demo.otel-caller-aks` (Python on AKS)
   - 🟣 `demo.nodeapp-otel-aks` (Node.js on AKS) ← **new**
3. Click the arrow `demo.nodeapp-otel-aks → app-amlab-<suffix>` → end-to-end transaction → both sides correlated by `operation_Id`.
4. **`appi-amlab` → Logs** → `dependencies | where cloud_RoleName == "demo.nodeapp-otel-aks" | take 50` — every outbound HTTP call captured.

### Killer line
> *"Same App Insights, same operation correlation, same KQL — and now from Node.js with **a single `require`**. Polyglot observability without polyglot ops."*

---

<a id="s31"></a>
## 31 · AKS — Managed Prometheus rule group (recording + alerting)

**Audience:** SRE teams that already love PromQL.
**Time:** 3–4 min.

### Story
Prometheus has two superpowers Container Insights doesn't: **recording rules** (pre-aggregate expensive expressions) and **alerting rules** (alert on PromQL, not KQL). Azure exposes both on **Azure Monitor Workspace** via `Microsoft.AlertsManagement/prometheusRuleGroups` — IaC-deployable, evaluated server-side, results visible in Grafana and routable to the same Action Group as the rest of the lab.

### What's deployed

Rule group **`amlab-prom-rules`** on `amw-amlab`:

| Type | Name | Expression |
|---|---|---|
| Recording | `node:cpu_utilization:avg5m` | `100 - (avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| Recording | `pod:restarts_total:rate30m` | `sum by (namespace, pod) (rate(kube_pod_container_status_restarts_total[30m]))` |
| Alerting (Warning) | `KubePodHighRestartRate` | `pod:restarts_total:rate30m > 0` for 15m → routes to `ag-amlab-email` |
| Alerting (Critical) | `KubeNodeCpuSaturation` | `node:cpu_utilization:avg5m > 90` for 10m → routes to `ag-amlab-email` |

### Click-path

1. **`amw-amlab` → Prometheus rule groups** → open `amlab-prom-rules` → walk the 4 rules.
2. **Grafana** (`amg-amlab-tr75…`) → *Explore* → data source = AMW → query `node:cpu_utilization:avg5m` — the **recording rule output**, queried like a native metric.
3. Compare query cost: `avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` (raw) vs `node:cpu_utilization:avg5m` (pre-aggregated). The recording rule is a fraction of the scan.
4. *(Optional)* Show the deployment definition:
   ```powershell
   az resource show -g rg-azure-monitor-lab `
     --resource-type Microsoft.AlertsManagement/prometheusRuleGroups `
     -n amlab-prom-rules --query "properties" -o json
   ```

### Killer line
> *"Same PromQL skill set. Same Grafana dashboards. But now the recording rules run **inside Azure**, evaluate continuously, and the alerts fan out to the same Action Group as your Azure Monitor metric alerts. One stack, two engines."*

---

<a id="s32"></a>
## 32 · AKS — Grafana alert rule via data-plane API

**Audience:** SRE teams centralising notifications inside Grafana.
**Time:** 3 min.

### Story
You can deploy ARM resources with Bicep. You **cannot** deploy Grafana folders, contact points, or alert rules with Bicep — those live in the Grafana **data plane**. The lab solves that with `scripts/setup-grafana-alerts.ps1`: it acquires an AAD token (`audience=https://management.azure.com/.default`), talks to `<grafana>/api/v1/...`, and provisions a folder + Azure Monitor contact point + 1 alert rule.

### What's deployed when you run the script

| Object | Value |
|---|---|
| Folder | `amlab` |
| Contact point | `amlab-azure-monitor` (Azure Monitor type — routes alerts back into Azure Monitor Alerts) |
| Alert rule | `AMLAB · AKS pod restart > 0 over 30m` — fires on the recording rule from scenario 31 |

### Click-path

1. Provision (idempotent):
   ```powershell
   ./scripts/setup-grafana-alerts.ps1 -ResourceGroup rg-azure-monitor-lab
   ```
2. Open Grafana → *Alerting → Alert rules* → folder **amlab** → open the rule → show the PromQL query + condition.
3. *Contact points* → **amlab-azure-monitor** → show it's a managed Azure Monitor receiver — alerts raised in Grafana appear in **Azure Monitor → Alerts** too.
4. Force a trigger by crash-looping a pod:
   ```powershell
   kubectl -n demo set image deployment/hello-frontend hello=mcr.microsoft.com/azuredocs/aks-helloworld:does-not-exist
   ```
   Wait ~30 min for the recording rule + alert to fire, then restore from scenario 8.

### Killer line
> *"Bicep is great for control plane. Grafana provisioning lives in the data plane — one 60-line script bridges them and keeps your alert routing fully scripted."*

---

<a id="s33"></a>
## 33 · App Insights — Release annotations on deploy / break / restore

**Audience:** SRE, dev, change-management — everyone who's asked "what changed at 14:03?"
**Time:** 2 min.

### Story
Every chart in App Insights now sprouts **vertical lines** at the exact second the lab was deployed, broken, or restored. No more "is that spike from the deployment or from real load?" — the chart tells you. Annotations are dirt-cheap (one REST call) and the lab fires them automatically from `deploy.ps1`, `break-the-lab.ps1`, and `restore-the-lab.ps1`.

### What's deployed

| Script | Annotation name | Event category |
|---|---|---|
| `scripts/post-deploy.ps1` | `deploy-YYYYMMDD-HHMMSS` | Deployment |
| `scripts/break-the-lab.ps1` | `break-the-lab-YYYYMMDD-HHMMSS` | Incident |
| `scripts/restore-the-lab.ps1` | `restore-YYYYMMDD-HHMMSS` | Deployment |

All three call `scripts/send-release-annotation.ps1`, which PUTs to `…/Annotations?api-version=2015-05-01`. Application Insights only displays markers whose wire-level category is `Deployment`, so the helper uses that display category for every marker and stores the logical value above as `EventCategory` metadata. Release annotations are chart metadata, not `customEvents`, and cannot be found with a `customEvents` KQL query.

### Click-path

1. **`appi-amlab` → Performance** (or Failures, or any metric chart) → look at the timechart — vertical dashed lines mark every annotation.
2. Hover any line → tooltip shows name + category.
3. Run the break/restore sequence:
   ```powershell
   ./scripts/break-the-lab.ps1   -ResourceGroup rg-azure-monitor-lab
   # ... ~3 min ...
   ./scripts/restore-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
   ```
   Within ~30 seconds you'll see **two new vertical lines** — incident start and recovery — perfectly aligned with the 5xx spike and recovery on the same chart.

### Killer line
> *"Every deploy, every incident, every restore — annotated on every chart automatically. No more eyeballing timestamps from Outlook. The chart is the timeline."*

---

<a id="s34"></a>
## 34 · Network — Connection Monitor (VMs → App Service hop-by-hop)

**Audience:** network engineers, hybrid-cloud architects, anyone debugging "is it the app or the network?"
**Time:** 4 min.

### Story
VM Insights tells you what a VM is *doing*. **Connection Monitor v2** tells you whether the VM can *talk to the things it should* — every minute, hop-by-hop, with latency + packet-loss + traceroute. Results land in the central LAW as `NWConnectionMonitorTestResult`, so you can graph end-to-end availability per (source, destination) pair without leaving Azure Monitor.

### What's deployed

The module is scoped to the singleton **`NetworkWatcher_northeurope`** in `NetworkWatcherRG` (Azure auto-creates one Network Watcher per region per subscription — only one allowed):

| Object | Value |
|---|---|
| Connection Monitor | `cm-amlab-vms-to-appservice` |
| Sources | both lab VMs (NetworkWatcherAgent extension installed on each) |
| Destination | `app-amlab-<suffix>.azurewebsites.net` over TCP/443 |
| Frequency | 60 s |
| Output workspace | `law-amlab-central` (table: `NWConnectionMonitorTestResult`) |

### Click-path

1. **Network Watcher → Connection monitor → `cm-amlab-vms-to-appservice`** → *Test groups* → drill into a hop. Show round-trip-time histogram + topology view.
2. **`law-amlab-central` → Logs** → run saved query **`23 — Network · Connection Monitor results (VMs → App Service)`** — table with `ChecksFailedPct` + `AvgRttMs` per (source, destination, 5-min bucket).
3. **Run query 30 — Network · End-to-end availability over 24h** — timechart with availability % per pair.
4. **Live failure demo** (ties back into scenario 8):
   ```powershell
   az vm deallocate -g rg-azure-monitor-lab -n vm-amlab-lin --no-wait
   ```
   Within ~2 min `SourceName == "src-vm-linux"` rows transition to `TestResult == "Fail"`. Restart the VM and they flip back.

### Killer line
> *"VM Insights says the VM is fine. App Insights says the app is fine. Then a user reports timeouts. Connection Monitor is the **third** witness — it tells you the **network path** between them is broken, hop by hop, every minute."*

---

<a id="s35"></a>
## 35 · Network — VNet Flow Logs + Traffic Analytics

**Audience:** security teams, network engineers, FinOps (egress is expensive).
**Time:** 3–4 min.

### Story
**VNet flow logs** (the GA successor to NSG flow logs) capture every accepted/denied flow on every interface in the VNet. Raw flows land in a storage account; **Traffic Analytics** enriches them with topology + geo + threat intel and writes `NTANetAnalytics` to the central LAW. Result: a single KQL query reveals top talkers, unexpected egress destinations, and east-west chatter — without any agents.

### What's deployed

| Object | Value |
|---|---|
| Flow log | `fl-amlab-vnet` (deployed under `NetworkWatcherRG` to satisfy the parent-Network-Watcher constraint) |
| Target | `vnet-amlab` |
| Raw storage | the lab's `st<prefix>` storage account → container **`insights-logs-flowlogflowevent`** |
| Traffic Analytics | enabled, processed every 10 min, written to `law-amlab-central` |
| Schema version | VNet Flow Logs v2 (richer than NSG flow logs) |

### Click-path

1. **Network Watcher → Flow logs → `fl-amlab-vnet`** → confirm status `Succeeded` + Traffic Analytics `Enabled`.
2. **Storage account → containers → `insights-logs-flowlogflowevent`** → drill into the date partition → open a `PT1H.json` block — show the raw JSON.
3. **`law-amlab-central` → Logs** → run saved query **`24 — Network · Traffic Analytics top-talkers (Flow Logs)`** — top inbound/outbound IP pairs by flow count.
4. Run **Traffic Analytics dashboard** (`Network Watcher → Traffic Analytics`) — geo map, top conversations, expected vs blocked. Use this **standalone dashboard**, not the *Network Insights → Traffic* tab — see the gotcha box below.

> **Known portal gap (May 2026):** the *Network Insights → Traffic* tab still queries the **legacy `AzureNetworkAnalytics_CL`** table populated by NSG flow logs (being retired 30-Sep-2027). VNet flow logs only populate the modern **`NTANetAnalytics`** table, so that tab will read "No results found" in this lab. That is **expected**, not a deployment bug. The data is fully visible in the standalone Traffic Analytics dashboard (step 4) and via saved query 24 (step 3). Microsoft docs confirm: *"NTANetAnalytics in virtual network flow logs replaces AzureNetworkAnalytics_CL used in network security group flow logs."*

### Killer line
> *"NSG rules tell you what you **allowed**. Traffic Analytics tells you what actually **happened** — including the legitimate flows you forgot to whitelist and the noisy chatter you didn't know you were paying egress for."*

---

<a id="s36"></a>
## 36 · Platform — Key Vault & Storage Insights

**Audience:** security operations, governance.
**Time:** 3 min.

### Story
Both `keyvault-amlab-*` and `st<prefix>...` ship `allLogs` to the central LAW via diagnostic settings. **Key Vault Insights** and **Storage Insights** workbooks read those rows and turn them into ready-made dashboards — every secret/key/cert operation, every storage transaction by API, throttling, latency.

### Click-path

1. **`keyvault-amlab-*` → Insights** → built-in workbook → top operations, callers, failures.
2. Run saved query **`25 — Key Vault · AuditEvent operations (last 1h)`** — same data via KQL on `AzureDiagnostics` filtered to `ResourceType == "VAULTS"`.
3. Optional — force traffic to see live rows:
   ```powershell
   az keyvault secret show --vault-name $kv --name amlab-demo-secret -o none
   ```
4. **`st<prefix> → Insights`** → built-in **Storage Insights** workbook → transactions per API + success-rate.
5. Run saved query **`26 — Storage · Transactions per API (last 1h)`** for the raw KQL.

### Killer line
> *"Two `diagnosticSettings` resources in Bicep — and you instantly get full-fidelity audit + insights workbooks on Key Vault and Storage, with the same KQL surface as everything else in the lab."*

---

<a id="s37"></a>
## 37 · Alerts — Nightly maintenance suppression rule

**Audience:** SRE leads, change-management.
**Time:** 2 min.

### Story
Lab nights (02:00–04:00 UTC) are when synthetic load-gen pauses, summary rules run, and AKS image updates roll. Alerts during that window are noise. An **Alert Processing Rule** with a daily recurrence silences the whole RG without disabling a single rule.

### What's deployed

| Resource | Value |
|---|---|
| APR | `apr-amlab-nightly-maintenance` |
| Scope | `rg-azure-monitor-lab` |
| Schedule | Recurring every day 02:00–04:00 UTC |
| Action | Remove all action groups (= no notifications, no Logic App webhook) |

### Click-path

1. **Monitor → Alert processing rules → `apr-amlab-nightly-maintenance`** → show schedule, scope, action.
2. Trigger a quick test by editing the schedule to "now + 1 minute → now + 5 minutes" (don't forget to revert).
3. Fire any alert in that window → confirm no email arrives. Wait past the window → next firing emails as normal.

### Killer line
> *"Maintenance windows are operational metadata, not alert configuration. One processing rule mutes the whole RG on a recurring schedule — and reactivates itself the moment the window closes."*

---

<a id="s38"></a>
## 38 · Alerts — Common Alert Schema 2nd webhook (SIEM forwarder)

**Audience:** security operations, integration architects.
**Time:** 2 min.

### Story
The Action Group already fans out to email + the auto-mitigation Logic App. To **also** forward every alert to a SIEM / SOAR / ticketing system, add a second webhook on the same Action Group — payload uses **Common Alert Schema**, so any consumer can parse it. The lab exposes this as a Bicep parameter `siemWebhookUrl`; pass it at deploy time and the receiver is wired automatically.

### What's deployed

When `siemWebhookUrl` is non-empty, `ag-amlab-email` ends up with three webhooks:

| Receiver name | Target |
|---|---|
| `automitigation-logicapp` | `la-amlab-automitigation` callback URL |
| `siem-forward` | the URL you provided (e.g. Sentinel logic app, Splunk HEC, ServiceNow) |

### Click-path

1. Redeploy with the parameter:
   ```powershell
   ./scripts/deploy.ps1 -ResourceGroup rg-azure-monitor-lab `
     -Location northeurope
   # When prompted for the secure param, or in main.parameters.json:
   # "siemWebhookUrl": { "value": "https://<your-siem-webhook>" }
   ```
   *(Idempotent — only the Action Group is mutated; no other resources change.)*
2. **Monitor → Action groups → `ag-amlab-email` → Webhook** receivers — show both rows.
3. Force a Sev3 alert (e.g. fire the dynamic-threshold rule) → both webhooks receive the **same** Common Alert Schema JSON.

### Killer line
> *"Same alert, two destinations. Email + auto-mitigation + a SIEM forward — all from one Action Group, all in CAS JSON, all deployed as one Bicep param."*

---

<a id="s39"></a>
## 39 · Cost — LAW continuous Data Export to Storage

**Audience:** compliance, long-term retention, FinOps.
**Time:** 3 min.

### Story
LAW retention costs money. For **compliance retention** of low-query tables, the cheapest option is **continuous data export** to Blob — 1¢/GB-month for cool storage vs. ~10¢/GB-month for LAW archive. The lab exports `Heartbeat` (volume proxy) every ~5 minutes to the `law-export` container.

### What's deployed

| Object | Value |
|---|---|
| Data export rule | `dx-amlab-heartbeat` on `law-amlab-central` |
| Tables exported | `Heartbeat` |
| Destination | `<storageAccount>` → container **`am-heartbeat`** (one container per table by design) |
| Format | JSON Lines, partitioned by `y=/m=/d=/h=/m=` |

### Click-path

1. **`law-amlab-central` → Data export** → open `dx-amlab-heartbeat` → show source = `Heartbeat`, target = storage container.
2. **Storage account → Containers → `am-heartbeat`** → drill into a `y=2026/m=05/d=18/...` partition → open a `.json` blob → show a `Heartbeat` row in NDJSON.
3. Compare ingest path:
   ```
   AMA agent  →  Heartbeat  →  LAW table  (queryable, billed at ingest + retention)
                                        ↘
                                          Data Export  →  Storage (cool tier)
                                                          ↘
                                                            ~1¢/GB-month for years
   ```
4. *(Optional)* Show the underlying resource:
   ```powershell
   az monitor log-analytics workspace data-export list -g rg-azure-monitor-lab `
     --workspace-name law-amlab-central -o table
   ```

### Killer line
> *"Keep 30 days hot in LAW for incident response. Keep 7 years cold in Blob for the auditor. One continuous export rule, two storage tiers, **no Logic App** copying rows around."*

---

<a id="s40"></a>
## 40 · Cost — Diagnostic settings fan-out (Storage archive + Event Hub stream)

**Audience:** SecOps, FinOps, architects designing SIEM ingestion.
**Time:** 3 min.

### Story
The App Service has **three** diagnostic settings stacked on it — same source logs, three independent destinations:

| Diagnostic setting | Destination | Why |
|---|---|---|
| `send-to-central-law` | `law-amlab-central` | Operations + workbooks (hot, queryable) |
| `archive-to-blob` | `<storageAccount>` → `diag-archive` container | Long-term archive — cool tier, ~1¢/GB-month |
| `stream-to-eventhub` | `evhns-amlab-...` → hub `diagnostics` | Real-time stream to downstream SIEM / SOAR (AMQP or Kafka surface) |

### Click-path

1. **`app-amlab-<suffix>` → Diagnostic settings** → show all three rows.
2. Trigger traffic (e.g. 20 `/api/explode` calls).
3. **LAW path** — run any saved query — rows visible within ~3 min.
4. **Storage path** — `<storageAccount>` → `insights-logs-appserviceconsolelogs` (or similar by category) → drill into today's partition → open the JSON.
5. **Event Hub path** — `evhns-amlab-... → diagnostics → Process data → Capture` (or use `eh-capture` Function/Logic App) → show one event landing.

### Killer line
> *"Diagnostic settings are not 1:1. The same log can simultaneously feed a workspace (KQL), a storage account (archive), and an Event Hub (stream). One source — three half-lives — zero duplication of agent config."*

---

<a id="s41"></a>
## 41 · Cost: LAW cross-region replication (BCDR knob)

**Audience:** BCDR architects, regulated industries.
**Time:** 2 min: fact-check + click-path.

### Story
LAW workspace replication creates a secondary shadow instance in another supported region. New logs are copied to it, but switching ingestion and queries to that region is a manual operation. **Off by default in this lab** because replication adds a charge for all billable ingested data. The Bicep parameter and a focused command for existing workspaces are both available.

Source: [Enhance resilience by replicating your Log Analytics workspace across regions](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication?tabs=azure-cli#enable-workspace-replication).

### What's wired

`infra/modules/law.bicep` accepts two params:

```bicep
param enableReplication bool = false
param replicationLocation string = ''  // e.g. 'westeurope'
```

When `enableReplication = true`, the property `replication: { enabled: true, location: '<region>' }` is set on the workspace.

### Click-path

1. Show current state (replication off):
   ```powershell
    $workspaceName = az monitor log-analytics workspace list `
       --resource-group $resourceGroup `
       --query "[?starts_with(name, 'law-amlab-central-')].name | [0]" -o tsv

    az monitor log-analytics workspace show `
       --resource-group $resourceGroup `
       --workspace-name $workspaceName `
       --query "replication"
   ```
2. Enable for the demo:
   ```powershell
   ./scripts/enable-law-replication.ps1 `
     -SubscriptionId $subscriptionId `
     -ResourceGroup $resourceGroup `
     -ReplicationLocation westeurope
   ```
   This uses the documented `az rest --method put` request with API `2025-02-01` and updates only the existing central workspace. Historical logs remain in the primary workspace, but only new logs ingested after replication becomes active are copied to the secondary region.
3. **`law-amlab-central-*` → Overview** → wait for the *Replication* tile to become **Active** with the second region listed. Individual data types can take up to one hour to begin replicating.
4. Before demonstrating switchover, associate eligible DCRs with the workspace system DCE and confirm each DCR targets only this workspace. This is required for DCR-based ingestion continuity.
5. Trigger switchover explicitly when the secondary contains enough useful data. Microsoft recommends waiting at least one week after enablement before relying on it for a planned switchover.

> **Compatibility note:** The cited Microsoft Learn page currently lists Container Insights, VM Insights, and Application Insights over Log Analytics workspaces as unsupported for replication and switchover. Do not present those lab paths as protected by this feature.

### Killer line
> *"Two regions, one workspace, one KQL surface, and one focused command to turn it on for an existing environment."*

---

<a id="s42"></a>
## 42 · Cost — Cost-of-monitoring workbook

**Audience:** FinOps, platform owners.
**Time:** 3 min.

### Story
Every workbook in the lab so far has been about **the workload's** health. This one is about the central Log Analytics workspace's ingestion volume — how much each table ingested, which solution dominates that volume, and which day spiked. It is not a complete cost or invoice view. The data comes from the workspace's `Usage` table.

### What's deployed

| Object | Value |
|---|---|
| Workbook | `Azure Monitor Lab — Central LAW ingestion volume` (id stored as a GUID under `rg-azure-monitor-lab`) |
| Source | `law-amlab-central.Usage` |
| Panels | Daily ingest GB, top 10 tables by ingest, ingest by solution, GB billed vs included (1 GB/day cap) |

### Click-path

1. **Monitor → Workbooks** → category **Azure Monitor Lab** → *Azure Monitor Lab — Central LAW ingestion volume*.
2. Walk the panels:
   - **Daily ingest** — flat line vs spike days.
   - **Top tables** — usually `ContainerLogV2`, `Perf`, `AzureActivity` — the candidates for Basic Logs (scenario 20) or DCR transforms (scenario 11).
   - **Cap utilization** — % of the 1-GB/day cap consumed.
3. Click any panel → "Edit" → show the underlying `Usage` KQL — every chart is just `Usage | summarize sum(Quantity) by ...`.

### Killer line
> *"This is the central workspace's ingestion feedback loop: use it to validate ingestion optimizations, then use Cost Management for the complete Azure bill."*

---

<a id="s43"></a>
## 43 · Security — Microsoft Sentinel onboarding + analytics rule

**Audience:** SecOps, SOC analysts.
**Time:** 4 min.

### Story
The central LAW is already collecting Activity Log, signin logs (when assigned), audit events, custom logs. Onboarding **Microsoft Sentinel** turns that same workspace into a SIEM — incidents, analytics rules, hunting, workbooks, SOAR. Same data, second persona. The lab deploys this as **optional** via param `enableSentinel` (default `true` on re-deploy).

> **Portal note (July 2025+):** the standalone Sentinel experience in the **Azure portal is retired**. All Sentinel features — Analytics, Incidents, Hunting, Workbooks, Notebooks, Threat Intelligence — now live in the **unified Microsoft Defender portal** at <https://security.microsoft.com>, side-by-side with Defender XDR. The Bicep onboarding resource (`Microsoft.SecurityInsights/onboardingStates`) is unchanged — only the click-path moves.

### What's deployed (when `enableSentinel=true`)

| Object | Value |
|---|---|
| Sentinel onboarding | `Microsoft.SecurityInsights/onboardingStates@2024-09-01` (workspace state = onboarded) |
| Solution | `SecurityInsights(law-amlab-central)` (legacy solutions resource — required for analytics rules API) |
| Scheduled analytics rule | `0a1b2c3d-amlab-rg-delete-alert` — fires on **any successful `*/delete` Activity Log event** in the last hour, severity Medium, runs every 15 min |
| Subscription Activity Log → LAW | Diagnostic setting `amlab-activity-to-law` (created by `deploy.ps1`, not Bicep — subscription-scope settings can't live in RG-scope Bicep). Without this the `AzureActivity` table is empty and the rule never fires. |

### Prerequisites for the Defender portal experience

- Sign in to <https://security.microsoft.com> with an account that has the **Microsoft Sentinel Reader** (or Contributor) role on the workspace **and** at least **Security Reader** in the Defender tenant.
- The workspace's tenant must be onboarded to Defender XDR. For lab tenants this is typically already done — if not, the portal will prompt you with a one-click "Connect workspace" wizard the first time you open the Sentinel blade.
- Only **one primary workspace** can be connected to the unified portal per tenant. The lab uses `law-amlab-central`.
- **Subscription Activity Log must ship to `law-amlab-central`.** `deploy.ps1` creates the `amlab-activity-to-law` subscription-level diagnostic setting that does this. If you bootstrap manually, run:
  ```powershell
  $lawArmId = az resource show -g rg-azure-monitor-lab -n law-amlab-central `
    --resource-type 'Microsoft.OperationalInsights/workspaces' --query id -o tsv
  $logs = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
  az monitor diagnostic-settings subscription create --name amlab-activity-to-law `
    --location global --workspace $lawArmId --logs $logs
  ```

### Click-path (Defender portal)

1. Open **<https://security.microsoft.com>** → left nav → **Microsoft Sentinel**.
2. If this is the first run for the tenant, choose **Connect a workspace** → pick `law-amlab-central` → **Connect**. Otherwise you land directly on the Sentinel home page for the connected workspace.
3. **Microsoft Sentinel → Configuration → Analytics → Active rules** → open the **amlab — Resource deletion in lab RG** rule → show its KQL:
   ```kql
   AzureActivity
   | where TimeGenerated > ago(1h)
   | where ActivityStatusValue == "Success"
   | where OperationNameValue endswith "/delete"
   | project TimeGenerated, Caller, OperationNameValue, _ResourceId
   ```
4. **Live demo (safe — deletes a throw-away resource, not the lab):**
   ```powershell
   # Create a tiny throw-away resource group, then delete it. The /delete event
   # lands in AzureActivity within ~5-10 min, then the rule's next 15-min run
   # raises an incident.
   $rgTemp = "rg-sentinel-demo-$(Get-Random -Maximum 9999)"
   az group create -n $rgTemp -l northeurope --tags purpose=sentinel-demo | Out-Null
   az group delete -n $rgTemp --yes --no-wait
   ```
5. **Microsoft Defender → Investigation & response → Incidents & alerts → Incidents** — wait ~10-15 min — the Sentinel-generated incident appears in the **same queue** as Defender XDR incidents, with severity, MITRE tactics (`Impact` / `T1485`), entity mapping (`Caller`, `_ResourceId`), and a `Detection source = Microsoft Sentinel` tag.
6. **Microsoft Sentinel → Threat management → Hunting** — open any default query (e.g. *"Successful logon by unusual user"*) → runs against the same LAW data.
7. (Optional) **Microsoft Sentinel → Threat management → Workbooks** — open the built-in *Azure Activity* workbook to show that the classic Sentinel workbook gallery is fully reachable from the Defender portal.

### Troubleshooting — "I deleted a real RG and no incident appeared"

Most common cause: **`AzureActivity` is empty in `law-amlab-central`**, because the subscription's Activity Log diagnostic setting points at a different workspace (often a corporate governance LAW). The Sentinel rule reads from `AzureActivity` in *this* workspace, so without ingestion, no incident.

Quick checks (all from PowerShell):

```powershell
$sub = '<your sub id>'
$rg  = 'rg-azure-monitor-lab'
az account set --subscription $sub | Out-Null

# 1. Is the subscription-level diag setting pointed at law-amlab-central?
az monitor diagnostic-settings subscription list `
  --query "value[].{name:name, workspace:workspaceId}" -o table

# 2. Is AzureActivity actually populated in the lab LAW?
$lawId = az monitor log-analytics workspace show -g $rg -n law-amlab-central `
  --query customerId -o tsv
az monitor log-analytics query -w $lawId --analytics-query `
  'AzureActivity | where TimeGenerated > ago(1d) | summarize count()' -o table

# 3. Is the rule enabled?
az rest --method get --url ("https://management.azure.com/subscriptions/$sub" +
  "/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/" +
  "law-amlab-central/providers/Microsoft.SecurityInsights/alertRules" +
  "?api-version=2024-09-01") `
  --query "value[].{name:name, enabled:properties.enabled}" -o table
```

If check #1 shows no setting pointing at `law-amlab-central`, run the bootstrap command in *Prerequisites* above, then wait 5-10 min and re-trigger a delete. Historical delete events from before the setting was created **do not backfill** — Activity Log collection is forward-only.

### Killer line
> *"Same workspace, same KQL, second persona — and now a third pane: Sentinel incidents land in the **same unified queue** as Defender XDR. One ingestion bill, one investigation surface for the SOC."*

> Disable for cost: set `enableSentinel=false` and redeploy — Sentinel onboarding is removed, data stays. The workspace will disappear from the Defender portal's Sentinel blade within a few minutes.

---

<a id="s44"></a>
## 44 · Security — Search jobs + restore archived logs

**Audience:** incident responders, compliance/legal.
**Time:** 3 min.

### Story
Two LAW capabilities you only need *occasionally* but desperately when you do:
- **Search jobs** — run a full-table scan on `Basic` / `Auxiliary` / archived rows that would be too slow / impossible in interactive mode. Result lands in a `<table>_SRCH` table you can KQL like any other.
- **Restore** — surface a slice of archived data back into interactive tier as `<table>_RST` for a window of hours/days, then drop.

The lab ships two ready-to-run scripts.

### Click-path

**A) Search job over a long window:**
```powershell
./scripts/run-search-job.ps1 `
  -ResourceGroup rg-azure-monitor-lab `
  -Workspace law-amlab-central `
  -Table ContainerLogV2 `
  -StartTime (Get-Date).AddDays(-7).ToString('o') `
  -EndTime (Get-Date).ToString('o') `
  -Query 'ContainerLogV2 | where LogMessage has "error"'
```
- Returns a job id; result lands in `ContainerLogV2_SRCH` typically within 5–30 min.
- Query it once it appears: `ContainerLogV2_SRCH | take 100`.

**B) Restore archived rows for ad-hoc investigation:**
```powershell
./scripts/restore-archived-logs.ps1 `
  -ResourceGroup rg-azure-monitor-lab `
  -Workspace law-amlab-central `
  -Table AzureActivity `
  -StartTime (Get-Date).AddDays(-365).ToString('o') `
  -EndTime   (Get-Date).AddDays(-358).ToString('o')
```
- Surfaces 7 days of rows into `AzureActivity_RST`.
- Query interactively. Restore expires after 24 h unless extended.

### Killer line
> *"Archived doesn't mean unreachable. Basic Logs and archive cost a fraction of analytics — and when forensics calls, search jobs and restore put the data back in front of you within minutes."*

---

<a id="s45"></a>
## 45 · Health Models — workload-level health on top of Service Groups (preview)

**Audience:** SRE leads, platform owners, anyone who manages a *workload* (not just resources).
**Time:** 5–6 min.

### Story
Every other scenario in this lab alerts on a **signal** — CPU > 90%, HTTP 5xx rate > 1%, latency p95 > 2 s. **Health Models** invert the question: instead of "which metric crossed which line?", they answer *"is my **workload** healthy right now?"*. They sit on top of **Azure Service Groups** (also preview) — a tenant-scoped, hierarchy-independent way to group Azure resources that work together.

Two preview features stacked:
1. **Azure Service Groups** (`Microsoft.Management/serviceGroups`) — tenant-scoped grouping, lives **alongside** Management Groups / Subscriptions / RGs (not inside them). A resource can belong to many service groups. Access on a service group does *not* grant access to its members.
2. **Azure Monitor Health Models** (`Microsoft.CloudHealth/healthmodels`, preview) — discover the members of a service group, build a tree of entities, attach metric / log-query signals to each, and propagate health up to a Root entity. Alert on the Root, not on 30 individual metrics.

### What's deployed by the lab

`infra/modules/health-model.bicep` provisions the full Health Model — Root entity + tier-1 service entities + tier-2 Azure-resource entities + signal definitions + relationships — as part of the regular `deploy.ps1` run. The graph is populated at deploy time, not via a portal designer click-through. A separate helper script provisions the *optional* service group (tenant-scoped, can't be in RG Bicep):

| # | Resource | Created by |
|---|---|---|
| 1 | `Microsoft.CloudHealth/healthmodels/hm-amlab-workload` (RG-scoped, system-assigned MI) | `infra/modules/health-model.bicep` via `deploy.ps1` |
| 2 | 9 child entities + 11 relationships (frontend / compute / platform tiers + their Azure-resource children) and signal definitions | same Bicep module |
| 3 | `Microsoft.CloudHealth/.../authenticationsettings/systemAssigned` (so signals can read Azure Monitor metrics) | same Bicep module |
| 4 | `Microsoft.Management/serviceGroups/amlab-workload` (tenant scope) | `scripts/setup-health-model.ps1` (optional) |
| 5 | `Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg` extension on the lab RG | same helper script (optional) |

### Topology

```
Root (hm-amlab-workload, auto-created)
├── frontend       — WorstOf rollup, Sev1 alert
│     ├── webapp      — Http5xx > 30, p95 > 3 s, CpuTime > 180 s
│     └── appinsights — failed requests > 50 (Impact = Suppressed → telemetry blips don't poison Root)
├── compute        — MaxNotHealthy 50% rollup, Sev3 + Sev1 alerts
│     ├── linuxvm     — Percentage CPU > 90 %
│     ├── winserver   — Percentage CPU > 90 %
│     ├── vmss        — Percentage CPU > 85 %
│     └── aks         — node_cpu_usage_percentage > 90 %
└── platform       — WorstOf rollup
      ├── keyvault    — Availability < 99 % (Impact = Limited → degraded, not unhealthy)
      └── storage     — Availability < 99 % (Impact = Limited)
```

### Click-path

```powershell
./scripts/deploy.ps1
# -> registers Microsoft.CloudHealth automatically
# -> deploys the full Health Model along with everything else
```

Then open the model in the portal (link printed at the end of `deploy.ps1`, or navigate to **Resource group → hm-amlab-workload → Designer**):

1. **Graph view** already shows the three-tier tree — no portal authoring needed.
2. **Optional**: run `./scripts/setup-health-model.ps1` to also create the service group + RG-member relationship if you want to demo the Designer's "Add from service group" flow on top of the existing model.
3. Wait ~5 min for the first health rollup. The system-assigned MI on the Health Model auto-gets *Monitoring Reader* on the resources whose IDs are wired into the signals.

### What you'll see

| View | What it shows |
|---|---|
| **Graph** | Tree: Root entity → one **Azure-resource entity** per lab resource (App Service, AKS, VMSS, VMs, KV, Storage, App Insights, LAW, …). Each entity shows current state with an icon. |
| **Timeline** | History of health states (Healthy / Degraded / Unhealthy / Unknown) per entity, over time. |
| **Entity editor** | Per-entity signals (e.g. App Service: requests, errors, response time; AKS: node CPU, pod restart rate). Each signal has degraded + unhealthy thresholds. |
| **Health objective** | Optional target % (e.g. "99.5% healthy") at the Root — measured against the timeline. |

### Health propagation walkthrough

Two demo trips, both already covered by existing scripts:

* `./scripts/break-the-lab.ps1` — hits `/api/explode` on the App Service → **Http5xx** signal exceeds 30 → `webapp` flips **Unhealthy** → `frontend` (WorstOf) flips **Unhealthy** → **Root flips Unhealthy**. The Sev1 alert on `frontend` fires once. App Insights (Impact = *Suppressed*) does **not** affect Root.
* `./scripts/start-ramp.ps1` — predictive-autoscale ramp pushes VMSS over 85 % → `vmss` flips **Unhealthy** → `compute` (MaxNotHealthy 50 %) flips **Degraded**, then **Unhealthy** if more children break → Root **Degraded → Unhealthy**.

Switch the App Service entity's **Impact** to *Limited* (in the Designer) → its unhealthy state propagates to Root as **Degraded** instead of Unhealthy. Switch it to *Suppressed* → Root stays **Healthy** even though the webapp is on fire (use for true non-critical components — telemetry, batch reports).

### Alert on health, not on signals

Classic alert: *"App Insights p95 latency > 2 s for 10 min"* — fires per resource, per signal.
Health Model alert: *"Root entity health = Unhealthy for 10 min"* — **one** alert that fires when **the workload** is impacted, regardless of which underlying signal caused it. Uses the same Action Group as everything else (`ag-amlab-email`).

| Classic alert rule | Health model alert |
|---|---|
| One metric / log query, one resource | Aggregate of all signals + child entities |
| N alerts on the same incident (CPU + memory + p95 latency simultaneously) | One alert |
| Same severity for the resource regardless of role | Different impact for the same resource in different models |
| "CPU > 90%" | "Workload is unhealthy" |

### Why Service Groups (and not Management Groups / RGs / tags)?

| Need | Service Groups | Management Groups | Resource Groups | Tags |
|---|---|---|---|---|
| Cross-subscription grouping | Yes | Yes (above subs) | No | Yes |
| Multiple membership per resource | Yes | No (one parent) | No | Yes |
| Permission inheritance | No (parent/child SG only) | Yes (policies + RBAC) | Yes | No |
| Designed for data-aggregation / views | Yes | No | No | metadata only |

Health Models *require* Service Groups precisely because the same resource may have **different** roles (and therefore different signals + thresholds) in different workloads — that's something the RG / MG hierarchy can't express.

### Teardown

```powershell
./scripts/setup-health-model.ps1 -Teardown
# DELETEs the optional member relationship + service group (tenant-scoped).
# The Health Model + entities + relationships are torn down with the lab RG:
#   ./scripts/teardown.ps1   (or 'az group delete -n rg-azure-monitor-lab').
```

### Killer line
> *"Every other alert in this lab fires on a signal. **This one fires on the workload.** Service Groups give you a hierarchy that matches the **application**, not the resource tree — and Health Models turn 30 signals into one answer: is my workload healthy?"*

---

<a id="s46"></a>
## 46 · Service Level Indicators (SLIs / SLOs) - error budgets on the workload (preview)

**Audience:** SRE leads, platform owners — same crowd as #45, one layer up from "healthy yes/no".
**Time:** 4–5 min.

### Why it's interesting
- Same shape as Health Models (preview, hangs off a **Service Group**, no extra cost), but answers a **quantitative** question: *"Are we hitting our SLO, and how much error budget is left?"*
- Two SLI shapes baked in: **Availability** + **Latency**, both **window-based** against Managed Prometheus metrics already flowing into the AMW.
- Outputs a baseline compliance % over a 7-day rolling window, an **error-budget remaining** view, and optional fast/slow **burn-rate alerts** — all on the same service group as the Health Model.

### What's deployed by the lab

| Resource | Created by | Notes |
|---|---|---|
| UAMI `id-sli-amlab` + Monitoring Reader + Monitoring Metrics Publisher on `amw-amlab` | `infra/modules/sli-identity.bicep` (auto) | SLI plane needs a UAMI with read on the source AMW and write back to the destination AMW. |
| Monitoring Metrics Publisher on AMW default DCR + DCE | `scripts/setup-slis.ps1` (auto) | The AMW's auto-created DCR/DCE live in `MA_amw-amlab_<region>_managed`. SLI ingestion fails without grants here too. |
| Service group `amlab-workload` | `scripts/setup-health-model.ps1` (auto) | Same SG that hosts the Health Model. |
| AKS Managed Prometheus source metrics | AKS monitoring add-on (auto) | The setup script verifies `up`, `kube_pod_status_phase`, and the pod-start histogram bucket/count series before the demo. |
| Sample SLIs | Azure portal (manual) | Create the two preview resources using the field values below. The script intentionally avoids depending on a changing preview API contract. |

> The `Microsoft.Monitor/slis` API remains in preview. Portal creation is intentional: the portal tracks current control-plane validation while the script provides stable prerequisite, RBAC, and metric-flow checks.

### Pre-demo: verify metrics and create the two SLIs

`scripts/setup-slis.ps1` runs as part of `deploy.ps1`, `post-staged-deploy.ps1`, and the Cloud Shell post-deployment wrapper. It verifies the service group, identity, destination permissions, and source metric series, then prints the portal URL and resource IDs:

```powershell
$subscriptionId = '<subscription-id>'
$resourceGroup = '<resource-group>'

./scripts/start-the-lab.ps1 `
   -ResourceGroup $resourceGroup `
   -Wait

./scripts/setup-slis.ps1 `
   -SubscriptionId $subscriptionId `
   -ResourceGroup $resourceGroup `
   -ServiceGroupId amlab-workload
```

The AKS cluster must be running before the portal can preview these signals. After a stopped cluster starts, allow Managed Prometheus time to emit fresh samples. Do not continue if `setup-slis.ps1` reports a missing metric. A successful run confirms that all four documented source metric families currently return at least one series from `amw-amlab`.

> `https://portal.azure.com/#@<tenant>/resource/providers/Microsoft.Management/serviceGroups/amlab-workload/serviceLevelIndicators`

Open the URL, select **+ Add SLI**, and create these definitions:

> Resource names are reused across lab deployments. In both portal pickers, verify the full resource ID and select `amw-amlab` and `id-sli-amlab` from the target resource group. Selecting identically named resources from another RG can leave Signal Preview empty.

**SLI #1: `sli-aks-pods-running`** (Availability, Window-Based)
- Source AMW: `amw-amlab`, identity = UAMI `id-sli-amlab`
- Signal A: metric `kube_pod_status_phase`, metric aggregation `Average`, filter `phase eq running`, **Summarize `Sum` for dimension `cluster`**
- Signal B: metric `kube_pod_status_phase`, metric aggregation `Average`, no filter, **Summarize `Sum` for dimension `cluster`**
- Signal formula: `(100 * A) / B`. Signal IDs are uppercase and the formula must use uppercase letters.
- Window uptime criteria: `>= 95`
- Baseline: `99` / `7d` / RollingDays
- Destination AMW: `amw-amlab` (same UAMI)

**SLI #2: `sli-aks-pod-start-latency`** (Latency, Window-Based)
- Same source AMW + identity
- Signal A: metric `kubelet_pod_start_duration_seconds_bucket`, metric aggregation `Rate` over `5` minutes, filter `le eq 30`, **Summarize `Sum` for dimension `cluster`**
- Signal B: metric `kubelet_pod_start_duration_seconds_count`, metric aggregation `Rate` over `5` minutes, no filter, **Summarize `Sum` for dimension `cluster`**
- Signal formula: `(100 * A) / B`. Signal IDs are uppercase and the formula must use uppercase letters.
- Window uptime criteria: `>= 95`
- Baseline: `95` / `7d` / RollingDays
- Destination AMW: `amw-amlab`

> The portal requires every signal in a formula to use the same spatial aggregation configuration. For both Signal A and Signal B, select **Summarize = Sum** and **dimension = cluster**. Choosing Average for one signal and Sum for the other produces the "different spatial aggregation types" validation error.

> Select **Validate** after entering the signals and formula. The Signal Preview pane is populated by validation and can show "Could not find appropriate columns for Line Chart" before the first successful validation. Treat an error returned by **Validate**, rather than the pre-validation preview placeholder, as the configuration result.

The pod-start histogram counters only change when pods start. A rolling restart generates fresh samples while keeping the deployment available, but healthy starts normally leave the latency SLI at 100%:

```powershell
kubectl -n demo rollout restart deployment/hello-frontend
kubectl -n demo rollout status deployment/hello-frontend
```

First data points can take 10-15 minutes to appear after a valid source window, once the streaming rule provisions and the destination metrics start emitting in the AMW.

### Reading error budget and burn rate

Azure Monitor compares the measured SLI with the **baseline target**, which is the SLO. The gap between perfect reliability and that target is the allowed unreliability. For example, a `99%` baseline provides a `1%` error budget over the selected evaluation period.

- **Error Budget Remaining** shows how much of that allowed unreliability is still available before the service misses its baseline target. It answers: *"How much more failure can we absorb?"* A falling value means unsuccessful requests or bad windows are consuming the budget. An exhausted budget means there is no remaining tolerance for failure within the evaluation period.
- **Burn Rate** shows how quickly the error budget is being consumed. It answers: *"At the current rate, how urgently do we need to act?"* A fast-burn condition usually indicates a sudden regression. A slow-burn condition indicates sustained degradation that can still cause an SLO miss if it continues.
- **Use them together:** Error Budget Remaining describes the reliability margin left; Burn Rate describes the urgency. A healthy remaining budget with a sharp fast burn can require immediate action, while a gradual slow burn calls for investigation before it becomes an SLO miss.

Azure Monitor can alert when the SLI falls below its baseline, when a fast burn consumes budget rapidly over a short lookback, or when a slow burn persists over a longer lookback. See [Service level indicators in Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/fundamentals/service-level-indicators-create#understand-baseline-target-error-budget-and-burn-rate).

### Click-through (4 min)
1. **Portal > Service groups > `amlab-workload` > Service Level Indicators**. Open the two manually created SLIs.
2. Open `sli-aks-pods-running`:
   - **Definition** tab - show the `(100 * A) / B` formula, uptime criteria `>= 95`, and SLO baseline (`99` / 7d rolling).
   - **Compliance** tab - show current compliance and error budget remaining. Explain that remaining budget is the failure margin left before the SLO is missed.
   - **Burn Rate** - explain that this is the speed of budget consumption: fast burn points to a sudden regression; slow burn points to sustained degradation.
3. Open `sli-aks-pod-start-latency` - show the percentage of pod starts completed within 30 seconds.
4. Show the **destination metrics** the SLI emits back into the AMW: `<sli-name>:Value`, `<sli-name>:Uptime`, and `<sli-name>:Downtime`, in the service-group metric namespace. These can be graphed in Grafana or fed back into the Health Model as additional signals, closing the SLO-to-workload-health loop.

### Break-the-lab story (≈90 s)
Use the dedicated helper to move both SLIs without changing `hello-frontend`:

```powershell
./scripts/demo-slis.ps1 `
   -SubscriptionId $subscriptionId `
   -ResourceGroup $resourceGroup `
   -Mode Degrade
```

The script replaces two temporary deployments in the `demo` namespace, so each `Degrade` run generates fresh pod-start samples:

- `sli-unavailable` creates five pods that remain Pending because the image tag intentionally does not exist. This adds non-running pod states and lowers `sli-aks-pods-running`.
- `sli-slow-start` creates three pods with a 45-second init-container delay. These starts fall outside the SLI's 30-second latency bucket and lower `sli-aks-pod-start-latency` during the active rate window.

Inspect the test workloads at any time:

```powershell
./scripts/demo-slis.ps1 `
   -SubscriptionId $subscriptionId `
   -ResourceGroup $resourceGroup `
   -Mode Status
```

Allow one or two 5-minute source windows plus the SLI processing delay. The live latency value is event-driven and can recover after the slow starts leave the five-minute source window. Seven-day compliance and error-budget changes are more gradual.

Restore both signals by deleting only the temporary test deployments:

```powershell
./scripts/demo-slis.ps1 `
   -SubscriptionId $subscriptionId `
   -ResourceGroup $resourceGroup `
   -Mode Restore
```

Do not scale `hello-frontend` to zero for this test. When its pod series disappear, the formula can lose both numerator and denominator instead of producing a clear bad ratio.

### Where it lives in the code
```
infra/modules/sli-identity.bicep   UAMI + role assignments on AMW
infra/main.bicep                   Wires sliIdentity in + exports outputs
scripts/setup-slis.ps1             Verifies source and destination RBAC on the AMW/DCR/DCE
                                   + verifies source metrics + prints portal inputs.
scripts/demo-slis.ps1              Creates, inspects, or removes temporary SLI degradation workloads.
scripts/deploy.ps1                 Chains setup-health-model.ps1 + setup-slis.ps1
scripts/teardown.ps1               Tears SLIs down before deleting the RG (idempotent)
```

### Why this matters next to the Health Model
- **Health Model** (#45) answers *"Is the workload healthy right now?"* — instantaneous, binary-ish.
- **SLIs** (#46) answer *"Are we keeping our promise to users this quarter?"* — quantitative, time-weighted, with an error budget.
- They share the same hierarchy (the service group), so the same workload story moves cleanly from "fix the breakage" (HM) to "decide whether to ship more features or invest in reliability" (SLO error budget).

### Teardown

```powershell
./scripts/setup-slis.ps1 -Teardown
# Deletes the two documented portal-created SLIs. Idempotent.
```

### Killer line
> *"Health Models tell you the workload is sick. SLIs tell you **how much sicker you can get this month before customers care.** Same hierarchy, same service group — two complementary answers to the only question SREs really care about: how is the workload doing?"*

---

<a id="s47"></a>
## 47 · Security posture — control-plane drift watch (without SIEM)

**Audience:** cloud governance, platform security, incident responders.
**Time:** 5 min.

### Story
Many Azure breaches start with a tiny control-plane change: someone disables diagnostic settings, opens a network rule, or weakens access controls. You can detect this with plain Azure Monitor log alerts on `AzureActivity`, no Sentinel required.

### Click-path
1. **Monitor → Logs** (workspace `law-amlab-central`) → run:
   ```kql
   let lookback = 24h;
   AzureActivity
   | where TimeGenerated > ago(lookback)
   | where ActivityStatusValue == "Success"
   | where OperationNameValue has_any (
       "MICROSOFT.INSIGHTS/DIAGNOSTICSETTINGS/DELETE",
       "MICROSOFT.INSIGHTS/DIAGNOSTICSETTINGS/WRITE",
       "MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/SECURITYRULES/WRITE",
       "MICROSOFT.KEYVAULT/VAULTS/WRITE",
       "MICROSOFT.STORAGE/STORAGEACCOUNTS/WRITE")
   | project TimeGenerated, Caller, CallerIpAddress, OperationNameValue, ResourceGroup, _ResourceId
   | order by TimeGenerated desc
   ```
2. **Monitor → Alerts → Create → Alert rule**:
   - Scope: `law-amlab-central`
   - Signal: **Custom log search**
   - Query: same as above
   - Evaluation: every 5 min, lookback 15 min, threshold `> 0`
   - Action: existing `ag-amlab-email`
3. Safe demo trigger (choose one):
   - Create then remove a temporary NSG rule in a throw-away NSG, or
   - Update a non-critical tag on the lab Storage account (still proves control-plane write detection).

### Killer line
> *"Security posture is configuration hygiene over time. Azure Monitor catches drift the minute the control plane changes, before data-plane abuse starts."*

---

<a id="s48"></a>
## 48 · Security posture — privilege escalation watch with Activity Log

**Audience:** identity engineers, cloud security, platform owners.
**Time:** 4 min.

### Story
Role assignment changes are one of the highest-signal events in Azure. A single Owner/User Access Administrator grant can bypass many preventive controls. Azure Monitor can flag this immediately from Activity Log streams.

### Click-path
1. **Monitor → Logs** (`law-amlab-central`) → run:
   ```kql
   AzureActivity
   | where TimeGenerated > ago(7d)
   | where ActivityStatusValue == "Success"
   | where OperationNameValue has "MICROSOFT.AUTHORIZATION/ROLEASSIGNMENTS/WRITE"
      or OperationNameValue has "MICROSOFT.AUTHORIZATION/ROLEASSIGNMENTS/DELETE"
   | extend Principal = tostring(parse_json(Properties).entity)
   | project TimeGenerated, Caller, CallerIpAddress, OperationNameValue, Principal, ResourceGroup, _ResourceId
   | order by TimeGenerated desc
   ```
2. Build a scheduled query alert:
   - Frequency: 5 min
   - Lookback: 15 min
   - Condition: count `> 0`
   - Severity: 2 or 1
   - Action Group: `ag-amlab-email`
3. Optional hardening pattern in query: add an allow-list for known automation principals and page only on unexpected callers.

### Killer line
> *"You do not need a SIEM to catch privilege changes. For Azure control-plane IAM events, Azure Monitor plus one KQL rule gets you immediate guardrails."*

---

<a id="s49"></a>
## 49 · Security posture — data exfiltration early warning (egress + sensitive reads)

**Audience:** SecOps, data governance, platform SRE.
**Time:** 6 min.

### Story
Exfiltration usually has two phases: prep and pull. Prep appears as policy/firewall/config changes; pull appears as egress spikes or unusual secret/read operations. Azure Monitor can correlate these in one workspace.

### Click-path
1. Run correlation query:
   ```kql
   let window = 6h;
   let controlPlane = AzureActivity
   | where TimeGenerated > ago(window)
   | where ActivityStatusValue == "Success"
   | where OperationNameValue has_any (
       "MICROSOFT.STORAGE/STORAGEACCOUNTS/WRITE",
       "MICROSOFT.KEYVAULT/VAULTS/WRITE",
       "MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/SECURITYRULES/WRITE")
   | project ChangeTime = TimeGenerated, Caller, OperationNameValue, Target = _ResourceId;
   let egress = InsightsMetrics
   | where TimeGenerated > ago(window)
   | where Name in ("NetworkOutTotal", "BytesSent")
   | summarize Egress=max(Val) by bin(TimeGenerated, 15m), _ResourceId;
   controlPlane
   | join kind=leftouter (
       egress
       | project EgressTime = TimeGenerated, _ResourceId, Egress
   ) on $left.Target == $right._ResourceId
   | where isnull(EgressTime) or abs(datetime_diff('minute', ChangeTime, EgressTime)) <= 30
   | project ChangeTime, Caller, OperationNameValue, Target, Egress
   | order by ChangeTime desc
   ```
2. Build two alerts (fewer false positives than one broad rule):
   - Alert A: control-plane risky changes (query in scenario 47)
   - Alert B: abnormal egress by resource baseline (metric alert with dynamic thresholds where available)
3. In incident review, open **Monitor → Alerts** and show timeline overlap between A and B.

### Killer line
> *"Single signals are noisy. Correlating change events with egress behavior in Azure Monitor gives a practical, low-cost exfiltration tripwire."*

---

<a id="s50"></a>
## 50 · Network — Network Insights (single pane of glass for everything network)

**Audience:** network engineers, platform SREs, anyone who has ever asked *"why am I jumping between five blades to triage a network issue?"*.
**Time:** 4–5 min.

### Story
Scenarios [34](#s34) (Connection Monitor) and [35](#s35) (Flow Logs + Traffic Analytics) each emit a stream of network telemetry into the central LAW. **Network Insights** is the portal blade that auto-discovers every networking resource in the subscription and stitches all of those streams — plus per-resource diagnostic settings, Network Watcher tools, and VM dependency maps — into one navigable view. **You don't deploy Network Insights itself** — it lights up automatically as soon as the data is there. The lab makes sure all four data sources are wired.

### What's already wired (no extra deployment needed)

| Network Insights surface | Data source in the lab | Module |
|---|---|---|
| **Topology / Resource health** per VNet, NSG, Public IP | Auto-discovery + resource diagnostic settings | [`policy-diagnostics.bicep`](../infra/modules/policy-diagnostics.bicep) — DINE assignments push `allLogs` for VNet / NSG / Public IP / App Service to `law-amlab-central` |
| **Connection Monitor tab** | `NWConnectionMonitorTestResult` | [`connection-monitor.bicep`](../infra/modules/connection-monitor.bicep) (scenario [34](#s34)) |
| **Traffic Analytics tab** | `NTANetAnalytics` + `NTAIpDetails` | [`flow-logs.bicep`](../infra/modules/flow-logs.bicep) (scenario [35](#s35)) |
| **Dependency map** (VM-to-VM, VM-to-service edges) | `VMConnection` + `Microsoft-InsightsMetrics` from AMA | VM Insights DCR in [`stages/00-foundation.bicep`](../infra/stages/00-foundation.bicep) + agents on both VMs |
| **Network Watcher tools** (IP flow verify, NSG diagnostics, packet capture, next hop) | Network Watcher in `NetworkWatcherRG` | Created on first use by Connection Monitor module |

### Click-path

1. **Monitor → Insights hub → Networks** → opens the cross-subscription Network Insights blade.
2. **Search & filter** tab → scope to `Subscription: <your-subscription-name>` and `Resource group: rg-azure-monitor-lab`. The grid shows every VNet, NSG, Public IP, AKS LB IP, and outbound IP discovered in the lab — each with health, alert count, and a sparkline.
3. Click **`vnet-amlab`** → the per-VNet view opens:
   - *Overview* — peerings, subnets, attached resources, drop counts (from flow logs).
   - *Topology* — auto-rendered VNet + subnet diagram with NSG associations.
   - *Diagnostic toolkit* — one-click **Connection Troubleshoot** and **NSG Diagnostic** powered by Network Watcher.
4. Back at the Insights index, switch the resource-type filter to **Network Security Groups** → open `nsg-amlab`:
   - *Rule hit counts* per rule, per direction — sourced from the diagnostic logs that the DINE policy from scenario [5](#s5) auto-applied.
   - *Top traffic flows* — surfaced from Traffic Analytics (scenario [35](#s35)).
5. Open the **Connection Monitor** tab inside Network Insights → shows the `cm-amlab-vms-to-appservice` test groups with pass-rate and RTT trend (same data as scenario [34](#s34), different visualization).
6. **Skip** the top-level *Network Insights → Traffic* tab — it queries the legacy `AzureNetworkAnalytics_CL` table (NSG flow logs, retired Sep-2027) and will show "No results found" in this lab. Open **Network Watcher → Traffic Analytics** instead (the standalone dashboard, sourced from `NTANetAnalytics`) — geo map of inbound/outbound flows for `vnet-amlab` (same data as scenario [35](#s35)).
7. In any **VM Insights** blade for `vm-amlab-lin` or `vmwin-<suffix>`, open the **Map** tab — Network Insights and VM Insights share the same dependency model, so connections to the App Service, AKS LB, and external endpoints all appear here too.
8. (Optional) Run **Network Watcher → Topology** for `rg-azure-monitor-lab` — auto-renders the entire RG's network graph: VNets, subnets, NICs, public IPs, AKS LB, all without clicking a single "deploy" button.

### Killer line
> *"You deployed two Connection Monitor tests and one VNet flow log. Network Insights gives you a topology view, NSG rule-hit dashboards, packet-capture launchpads, a dependency map, and a cross-subscription health grid for free — because it just reads what's already in the LAW."*

---

<a id="s51"></a>
## 51 · Cost — Platform logs at scale with DCRs (public preview)

**Audience:** platform teams, FinOps, architects managing telemetry across 1,000+ resources.
**Time:** 4 min.

### Story
Today the lab collects Azure resource platform logs the classic way: **one diagnostic setting per resource**, pushed by the DINE policy in scenario [5](#s5). That works for ~30 resources — but a team responsible for 8,000 resources across 14 subscriptions has to configure, audit, monitor for drift, and re-enable each one individually. Azure Monitor's new **Data Collection Rules (DCRs) for Azure Resource Platform Logs** (public preview, Jun 2026) collapses all of that into **one rule associated with thousands of resources** — the same declarative model already used for agents, metrics, and custom logs. Define once, govern centrally, scale infinitely.

### Diagnostic settings vs. DCR-based platform logs

| Dimension | Diagnostic settings (today) | DCR-based platform logs (preview) |
|---|---|---|
| **Configuration** | One setting per resource; drift goes unnoticed | One DCR + DCR Associations (DCRA) across thousands of resources |
| **Cost** | No pre-ingestion filtering | Filter & transform at ingestion time (Log Analytics destination) — drop noise before billing |
| **Security** | Mixed auth patterns | Managed identity (system/user-assigned) + least-privilege RBAC for Storage & Event Hubs — no shared keys |
| **Operations** | Manual onboarding, hard to roll back | ARM / Bicep / Terraform / Azure Policy; version-controlled like IaC |
| **Governance** | Different pattern per telemetry type | One declarative model, auditable associations |

### What's wired (opt-in IaC)

The lab ships the DCR as code but **off by default** — the DCR and the central LAW must sit in a region that supports the preview.

| Object | Value |
|---|---|
| Module | [`infra/modules/platform-logs-dcr.bicep`](../infra/modules/platform-logs-dcr.bicep) — `PlatformTelemetry` DCR + DCR association |
| Feature flag | `enablePlatformLogsDcr` (Bicep) / `enable_platform_logs_dcr` (Terraform) — default `false` |
| Stream | `microsoft.dashboard/grafana:Logs-Group-All` |
| Monitored resource | `amg-amlab-<suffix>` (via one DCR association; add any supported resources as needed) |
| Destination | `law-amlab-central` (Log Analytics — no managed identity / RBAC required) |

> Enable it: `az deployment group create ... --parameters enablePlatformLogsDcr=true` (Bicep) or `enable_platform_logs_dcr = true` in `stages.tfvars` (Terraform).

### Click-path

1. **Contrast the current model** — `app-amlab-<suffix>` → **Diagnostic settings** → show the per-resource `send-to-central-law` row (scenario [40](#s40)). Point out that every resource in the RG has its own copy, pushed by the DINE policy from scenario [5](#s5).
2. **Show the new model** — **Monitor → Data Collection Rules** → *Create* → **Platform logs (preview)** as the data source type → pick log categories once → target `law-amlab-central`.
3. **Associate at scale** — instead of touching each resource, one DCRA (or an Azure Policy assignment) attaches the single rule to many resources. Show the association list.
4. **Filter before billing** — add an ingestion-time transform on the Log Analytics destination (e.g. drop verbose categories) — the same lever as scenario [11](#s11), now applied to platform logs. Loop the saving back to the cost workbook in scenario [42](#s42).
   > ⓘ **Preview limits:** transformations are supported only for the **Log Analytics** destination; coverage is a growing list of resource types/regions — check the [supported resource types reference](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/platform-logs-reference) before relying on it.
5. *(Optional)* Route the same rule to Storage (archive) and Event Hubs (SIEM stream) with managed identity — the DCR equivalent of the fan-out in scenario [40](#s40), but governed by one rule instead of three per-resource settings.

### Killer line
> *"Diagnostic settings are per-resource toil. A single DCR for platform logs is per-resource toil deleted — one rule, thousands of resources, filtered before it's billed, governed like your Bicep."*

**Reference:** [Platform log collection with data collection rules (Preview)](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/platform-logs-collect?tabs=azure-portal%2Clog-analytics-workspace) · [Announcement blog](https://techcommunity.microsoft.com/blog/azureobservabilityblog/public-preview---azure-monitor---collect-azure-resource-platform-logs-at-scale-w/4525296)

---

<a id="s52"></a>
## 52 · Cost — Azure Monitor Metrics Export via DCRs (GA)

**Audience:** FinOps, SRE, architects building metrics pipelines.
**Time:** 3 min.

### Story
Scenario [39](#s39) exports **logs** out of LAW. This one exports **platform metrics** out of Azure Monitor. **Azure Monitor Metrics Export** — now **Generally Available** (Jun 2026) and expanded from 12 to **44 Azure regions** — continuously streams supported platform metrics via **data collection rules** to Storage, Event Hubs, or Log Analytics. Unlike the metrics half of diagnostic settings, DCR-based export **preserves metric dimensions**, lets you **filter by metric name** to control volume and cost, and delivers with **end-to-end latency typically under ~3 minutes**.

### DCR metrics export vs. diagnostic-settings metrics

| Capability | Diagnostic settings (metrics) | Metrics Export via DCR (GA) |
|---|---|---|
| **Dimensions** | Flattened / limited | Multidimensional fidelity preserved |
| **Filtering** | All-or-nothing per category | Filter by specific metric names |
| **Destinations** | Storage / Event Hubs / LAW | Storage / Event Hubs / LAW |
| **Latency** | Higher | Typically within ~3 min end-to-end |
| **Scale / regions** | — | 44 regions, tuned for large environments |

### What's wired (opt-in IaC)

The export DCR ships as code but **off by default** — the DCR and the central LAW must be in the same region.

| Object | Value |
|---|---|
| Module | [`infra/modules/metrics-export-dcr.bicep`](../infra/modules/metrics-export-dcr.bicep) — `PlatformTelemetry` DCR + DCR association |
| Feature flag | `enableMetricsExportDcr` (Bicep) / `enable_metrics_export_dcr` (Terraform) — default `false` |
| Stream | `Microsoft.KeyVault/vaults:Metrics-Group-All` (narrow to specific metric names to cut volume) |
| Monitored resource | `kv-amlab-<suffix>` (dimensional metrics like `ServiceApiLatency` by `StatusCode`) |
| Destination | `law-amlab-central` → `AzureMetricsV2` table (no managed identity / RBAC required) |

> Enable it: `az deployment group create ... --parameters enableMetricsExportDcr=true` (Bicep) or `enable_metrics_export_dcr = true` in `stages.tfvars` (Terraform).

### Click-path

1. **Create the export** — **Monitor → Data Collection Rules** → *Create* → **Metrics export** data source → scope to a lab resource (e.g. `app-amlab-<suffix>` or `aks-amlab`).
2. **Control what you export** — select **all supported metrics** for the resource type, or **filter to specific metric names** (e.g. only `Http5xx` + `Requests` for the App Service) to keep downstream volume — and cost — down.
3. **Pick a destination**:
   - **Storage** → cheap long-term metric archive (pairs with scenario [39](#s39)'s log archive).
   - **Event Hubs** → real-time stream into a third-party observability / FinOps pipeline (pairs with scenario [40](#s40)'s fan-out).
   - **Log Analytics** → correlate metrics with logs in KQL.
4. **Show dimensional fidelity** — open the destination and point at a metric that still carries its dimensions (e.g. per-status-code, per-instance) — the thing diagnostic settings drops.
5. *(Optional)* Note the latency: trigger traffic, then show the metric landing at the destination within ~3 minutes.

### Killer line
> *"Diagnostic settings flatten your metrics and give you all-or-nothing. DCR-based Metrics Export keeps every dimension, lets you ship only the metric names you care about, and lands them in under three minutes — now GA across 44 regions."*

**Reference:** [Metrics export using data collection rules](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-metrics) · [Announcement blog](https://techcommunity.microsoft.com/blog/azureobservabilityblog/azure-monitor-metrics-export-generally-available/4523712)

---

<a id="s53"></a>
## 53 · AI FinOps — GenAI token / trace / cost observability (optional AI stage)

**Audience:** FinOps, AI platform teams, architects putting GenAI into production.
**Time:** 5 min.

> **Requires the optional AI stage** — off by default (it deploys billable models pinned to `swedencentral`). Enable `stageToggles.enableStageAI` (Bicep) / `enable_stage_ai` (Terraform), deploy, then run `./scripts/setup-ai.ps1` to create the demo agents and simulate traffic.

### Story
Every other scenario watches infra/platform telemetry. This one points the **exact same Azure Monitor stack** at **AI usage**. A Microsoft Foundry workload runs four agents against `gpt-5-mini`, `text-embedding-3-small`, `gpt-5.4`, and a **model-router**; their OpenTelemetry GenAI spans land in the lab's Application Insights as `gen_ai.*` dependencies. The lab charts and alerts on measured token volume and rolls it into the workload health model. Convert that evidence to cost with the actual request/response model and current customer-specific pricing; one hard-coded rate cannot price this mixed deployment correctly.

### What's deployed

| Object | Value |
|---|---|
| Foundry workload | `ai<amlab><suffix>` AI Services account + `amlab-ai-proj` project (swedencentral) |
| Model deployments | `gpt-5-mini` · `text-embedding-3-small` · `gpt-5.4` · **`model-router`** (all GlobalStandard) |
| Tracing | Project → `appi-amlab` connection → `gen_ai.*` spans in the App Insights LAW |
| Query pack | `qp-ai-finops` — 14 GenAI KQL queries (token usage, cached ratio, router mix, efficiency, and an illustrative PTU query with rates disabled until configured) |
| Workbook | **"AI FinOps — Foundry Agents"** (Monitor → Workbooks → Shared) |
| Alerts | `alert-amlab-token-anomaly` (dynamic threshold) + `alert-amlab-token-spike` (static ceiling) on `TotalTokens` |
| Health tier | An **AI tier** folded into `hm-amlab-workload` — `aiworkload` → Foundry account + 4 agent entities (error-rate + token-volume signals) |

### Click-path

1. **Foundry portal (`ai.azure.com`) → project `amlab-ai-proj` → Observability / Tracing** — show agent runs + token consumption per model from the simulated conversations.
2. **`appi-amlab` → Logs → Queries** — run *Token usage by agent (24h)* and *Model router routed-model distribution* from the `qp-ai-finops` pack.
3. **model-router is the cost lever** — the router query shows easy prompts routed to a cheap model, hard prompts to a strong one (surfaced as `gen_ai.response.model`). Even a modest routing rate compounds into real savings.
4. **Prompt caching reduces billable input** — the `Context-Rich Assistant` uses a >1024-token static system prompt, so repeated calls can hit the prompt cache; open *Cached-input token ratio*, then apply the actual model's current cached-input rate.
5. **Monitor → Workbooks → "AI FinOps — Foundry Agents"** — token/efficiency tiles, token-share pie, and an illustrative PTU comparison that remains unavailable until current model-specific rates are entered.
6. **Monitor → Alerts** — `alert-amlab-token-anomaly` + `alert-amlab-token-spike`. Trigger live by running the simulator hot: `python workloads/ai/simulate_traffic.py --conversations 100 --interval 5`.
7. **Monitor → Health models → `hm-amlab-workload`** *(preview)* — the **AI** tier rolls up next to frontend/compute/platform; excessive hourly token volume can turn an agent Unhealthy.

### Killer line
> *"Tokens are the measurable input to AI cost. The same workspace, KQL, alerts, and health model expose volume and model routing; current model-specific prices and Cost Management provide the bill."*

**Reference:** [docs/STAGE-AI.md](STAGE-AI.md)

---

<a id="s54"></a>
## 54 · Azure SRE Agent trial readiness

**Audience:** SRE leads, operations teams, platform engineers.
**Time:** 3 min.

### Story
Start with one known workload and a bounded cost envelope. The trial removes the fixed always-on charge for 30 days, but agent processing still consumes billable Azure Agent Units. The setup check proves that the agent can see the lab without granting broad write access.

### Click-path / commands

1. Run `./scripts/setup-sre-agent.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>`.
2. In `sre.azure.com`, show the trial banner and its remaining days.
3. Show that the agent location is **Sweden Central** (`swedencentral`), the lab's required SRE Agent region.
4. Open **Settings > Agent consumption** and show the active-flow allocation and usage by thread.
5. Run the setup script again without `-AgentPrincipalId`; it discovers the agent's user-assigned identity automatically. Show the three action-UAMI checks and four connector-system-identity checks.

   <details>
   <summary><b>Optional: find the action UAMI object ID</b></summary>

   Open the agent in `sre.azure.com`, select **Settings > Azure settings > Go to Identity**, and copy **Object (principal) ID** from the managed identity Overview page. Alternatively, retrieve it with Azure CLI:

    ```powershell
    $agentId = az resource list `
       --subscription <subscription-id> `
       --resource-group <resource-group> `
       --resource-type Microsoft.App/agents `
       --query '[0].id' -o tsv

    $identityId = az resource show `
       --subscription <subscription-id> `
       --ids $agentId `
       --api-version 2025-05-01-preview `
       --query 'identity.userAssignedIdentities | keys(@)[0]' -o tsv

    az identity show `
       --subscription <subscription-id> `
       --ids $identityId `
       --query principalId -o tsv
    ```

    Passing the returned value with `-AgentPrincipalId` is optional and is mainly useful when validating a specific identity explicitly.

   </details>

6. Open **Incidents > Triggers & response plans** and show Azure Monitor connected to the lab subscription. If **Connect an incident platform** is displayed, connect Azure Monitor before continuing.

### Required setup before Scenario 55

Complete this setup once before triggering any alerts:

1. Open **Builder > Agent Canvas**, select **Create > Custom Agent**, and create `amlab-app-investigator`. Custom-agent names can contain only letters, numbers, or hyphens and must be 36 characters or fewer. Paste the instructions from [Stage SRE Agent - Application Investigator](STAGE-SRE-AGENT.md#application-investigator), leave Skills, Tools, and Hooks at their inherited defaults, and select **Create**.
2. Create `amlab-platform-investigator` the same way with the instructions from [Stage SRE Agent - Platform Investigator](STAGE-SRE-AGENT.md#platform-investigator). A handoff description is not required for this lab because each response plan explicitly selects its response subagent.
3. Open **Incidents > Triggers & response plans** and select **Create a response plan**. If the button is disabled, connect Azure Monitor first and wait for the green connected status.
4. Create the application plan:
   - **Incident response plan name:** `amlab-app-alerts`
   - **Severity:** `Sev2`
   - **Title contains:** `webapp`
   - **Response subagent:** `amlab-app-investigator`
   - **Agent autonomy level:** `Review` (the default is Autonomous)
5. Select **Next**, choose **Last 7 days** for the incidents preview, review any matches, and select **Create**. An empty preview does not block creation when no matching alert has fired yet.
6. Repeat the wizard for the platform plan:
   - **Incident response plan name:** `amlab-platform-alerts`
   - **Severity:** `Sev2` and `Sev3`
   - **Title contains:** `aks`
   - **Response subagent:** `amlab-platform-investigator`
   - **Agent autonomy level:** `Review`
7. Confirm both rows show status **On** and mode **Review**. Delete or turn off any generated quickstart response plan to prevent duplicate routing.

The portal currently accepts one **Title contains** value per plan. To route the `failed-requests`, `pod`, or `vm` title variants as well, clone the appropriate plan with a unique name and replace the title filter.

### Killer line
> *"The trial removes idle agent cost for 30 days, while this scope and consumption view keep every investigation deliberate, measurable, and attributable."*

**Reference:** [Stage SRE Agent](STAGE-SRE-AGENT.md)

---

<a id="s55"></a>
## 55 · Alert-driven App Service investigation

**Audience:** application teams, incident commanders, SREs.
**Time:** 5 min plus alert evaluation delay.

### Story
An Azure Monitor alert should begin an evidence-based investigation without an engineer opening several portal blades. The agent acknowledges the alert, opens a thread, and correlates App Service metrics with Application Insights telemetry.

### Click-path / commands

1. In `sre.azure.com`, open the lab agent and select **Incidents > Triggers & response plans**. Confirm the `amlab-app-alerts` row created in Scenario 54 is **On** and its mode is **Review**. If it is absent, complete the required setup in Scenario 54 before continuing.
2. Run `./scripts/break-the-lab.ps1 -ResourceGroup <resource-group>`.
3. Wait for `alert-webapp-5xx` to fire. If you also cloned the plan with the `failed-requests` title filter, `alert-appinsights-failed-requests` can start the same workflow.
4. In the SRE Agent portal, open the new incident thread.
5. Ask: `Which endpoint failed, when did impact begin, and what evidence supports the likely cause?`
6. Point out evidence from App Service metrics plus Application Insights requests, exceptions, traces, or dependencies.

### Killer line
> *"The alert is no longer a notification. It is the start of a grounded investigation with the relevant telemetry already correlated."*

---

<a id="s56"></a>
## 56 · AKS crash-loop diagnosis

**Audience:** Kubernetes operators, platform teams, SREs.
**Time:** 4 min.

### Story
The same break action gives the AKS frontend an invalid image and raises pod health signals. A specialized platform investigator follows the Kubernetes evidence instead of applying an App Service runbook to every incident.

### Click-path / commands

1. Keep the lab broken from scenario 55, or run `break-the-lab.ps1` again after restoring it.
2. Wait for `alert-aks-pod-restart-spike` or `amba-aks-pods-not-ready` to fire.
3. Open the SRE Agent investigation routed to `amlab-platform-investigator`.
4. Ask: `Identify the failing Kubernetes object and show the pod status, event, and log evidence.`
5. Confirm that the agent inspects `KubePodInventory`, `ContainerLogV2`, Kubernetes events, and relevant metrics.
6. Do not approve remediation yet.

### Killer line
> *"The response plan selects Kubernetes expertise automatically, while Review mode keeps resource changes under human control."*

---

<a id="s57"></a>
## 57 · Correlate changes with the incident

**Audience:** incident commanders, application owners, change managers.
**Time:** 3 min.

### Story
Symptoms alone do not establish cause. The agent checks Activity Logs, deployment operations, and telemetry around the first failure, then separates observed changes from its inference about causality. The presenter independently verifies the release annotation in the Application Insights chart because release annotations are chart metadata rather than KQL telemetry.

### Click-path / commands

1. Continue in either investigation from scenarios 55 or 56.
2. Ask: `What changed in the 15 minutes before this incident, and which change is most likely related? Separate evidence from inference.`
3. Show the VM deallocation operations in Activity Logs.
4. Open Application Insights **Performance** or **Failures** and show the `break-the-lab-*` annotation. Do not ask the agent to find it in `customEvents`; release annotations are not stored there.
5. Compare each timestamp with the first failed request and unhealthy pod signal.

### Killer line
> *"The agent does not merely find a nearby change. It builds a timestamped evidence chain and tells us how confident it is that the change caused the impact."*

---

<a id="s58"></a>
## 58 · Repeated-alert merging and verified recovery

**Audience:** operations leads, incident commanders, automation owners.
**Time:** 5 min plus alert synchronization delay.

### Story
Repeated alert firings should enrich one active investigation instead of producing duplicate toil. Recovery is not complete until the original signals return to healthy.

### Click-path / commands

1. While the incident is active, generate another failure cycle by rerunning `break-the-lab.ps1`.
2. Show that repeated firings from the same alert rule merge into the active thread.
3. Run `./scripts/restore-the-lab.ps1 -ResourceGroup <resource-group>`.
4. Ask: `Verify recovery using the original alert condition, application failure rate, and AKS pod health. Do not close the incident until all three are healthy.`
5. Show the investigation timeline update and Azure Monitor alert state synchronization.
6. Turn off both lab response plans after the demo to prevent expected alerts from consuming active-flow AAUs.

### Killer line
> *"One incident thread carries the signal from detection through diagnosis to measured recovery, without multiplying tickets every time the rule fires."*

**Reference:** [Stage SRE Agent](STAGE-SRE-AGENT.md)

---

<a id="s59"></a>
## 59 · Automatic incident command brief

**Audience:** incident commanders, SRE leads, service owners.
**Time:** 3 min.

### Story
An incident commander should not need to interrogate the agent before the first useful update appears. The response plan automatically invokes the selected specialist, and the specialist's output contract turns its investigation into a consistent brief with status, impact, evidence, confidence, and the next safe action.

### Click-path / commands

1. Open either investigation created by the response plans in Scenario 55 or 56. Do not enter a prompt.
2. Show the **Incident command brief** produced automatically by the selected custom investigator.
3. Confirm that the brief contains the current status, customer or workload impact, affected resources, first signal, likely cause with confidence, timestamped evidence, the smallest safe next action, and missing evidence.
4. Show that the application route cites Application Insights and App Service evidence, while the platform route cites AKS, VM, or Resource Health evidence.
5. Compare the initial brief with the recovery evidence collected in Scenario 58, highlighting the difference between the first hypothesis and verified recovery.
6. Point out that Review mode still requires approval for resource changes even though investigation and incident communication begin automatically.

### Killer line
> *"Nobody had to ask the first question. The alert selected the specialist, the specialist built the evidence chain, and the incident commander opened a ready-to-use brief."*

**Reference:** [Stage SRE Agent](STAGE-SRE-AGENT.md)

---

<a id="s60"></a>
## 60 · Lab Control Center - cross-stack operations

**Audience:** operations teams, SREs, demo facilitators, and service owners.
**Time:** 5-8 min.

### Story
The Lab Control Center brings health, traffic generation, approved lab operations, and optional agent experiences into the deployed web app. It gives operators one place to create a signal, inspect its cross-stack effect, and continue into the detailed Azure Monitor view without replacing the Azure portal.

### Click-path
1. In the lab resource group, open the App Service and select **Browse**. Confirm the resource group and App Service in the environment strip.
2. Open **Traffic & Faults**. Send a slow request, a dependency request, and an intentional error. Show the response time, status, and trace ID for each result.
3. Sign in with an approved operator account, open **Infra Health**, and refresh the snapshot. Point out that Azure platform availability and telemetry health are reported separately.
4. Open **Lab Operations** and select **Add Release Marker**. Review the script, image digest, parameters, and target resource group before approving it.
5. Track the Container Apps Job to completion, then use the related scenario links to open Application Insights, the Traffic-Lights workbook, or another detailed monitoring workflow.
6. If the optional stages are deployed, briefly show the **Foundry Playground** and **SRE MCP Assistant** tabs without running billable prompts.

### Killer line
> *"One interface creates the signal, checks the estate, and launches a controlled operation, while Azure Monitor remains the evidence and investigation layer."*

**Reference:** [Lab Control Center](LAB-CONTROL-CENTER.md)

---

<a id="s61"></a>
## 61 · Agentic application - slow tool call

**Audience:** application developers, SREs, AI platform teams.
**Time:** 5-8 min.

### Story
The agent eventually returns the right answer, but the customer waits too long. A top-level duration alone cannot tell whether the model, orchestration, tool, or downstream system caused the delay. The trace can.

### Click-path
1. Deploy the [Observability Agent stage](STAGE-OBSERVABILITY-AGENT.md) and open the Control Center.
2. Under **Troubleshooting scenarios**, choose **Slow customer lookup**, select **Broken**, approve synthetic telemetry, and generate the trace.
3. In Application Insights transaction search, locate the trace and compare the parent `GenAI` operation with the `AgentTool` dependency. Confirm the tool is correct but slow.
4. Select **Open Observability Agent**, start a chat, and paste the trace-specific prompt generated by the Control Center. The prompt requires evidence, a bounded fault-domain hypothesis, three next checks, a targeted fix, and measurable verification instead of only a list of slow spans.
5. Check that the answer uses `tool.latency_budget_ms`, `tool.latency_budget_exceeded`, and `tool.simulation_profile` to identify the agent-tool backend as the likely fault domain. The synthetic trace proves where time was spent; it does not by itself prove why a real backend was slow.
6. Run the **Fixed** profile and use its generated prompt to compare tool duration against the latency budget and the overall request duration.

### Example investigation prompt

The Control Center inserts the current trace ID automatically. If investigating directly in the portal, use:

```text
Investigate the Application Insights transaction with operation/trace ID <trace-id> from the last 30 minutes.
It was generated by POST /api/agents/scenarios/run with scenario=slow-tool and demo.mode=broken.

Do not only list the longest spans. Return these sections:
1. Evidence - reconstruct the request and dependency path; quantify each major span's contribution to end-to-end duration. Include gen_ai.tool.name, dependency target, success/result code, tool.latency_budget_ms, tool.latency_budget_exceeded, and tool.simulation_profile.
2. Hypothesis - identify the most likely fault domain (model, orchestration, agent tool, or tool backend) and distinguish telemetry facts from inference.
3. Trace quality - verify that the hierarchy is request -> customer_support_agent -> tool dependency. Report any missing or flattened parent-child relationship before drawing a causal conclusion.
4. Next checks - give three concrete checks or queries that would confirm or disprove the hypothesis. Do not claim the synthetic delay reveals a real backend cause.
5. Targeted fix - recommend the smallest appropriate remediation for the identified fault domain.
6. Verification - explain which broken-versus-fixed measurements would prove the fix, including tool duration against its latency budget and total request duration.
```

### Killer line
> *"The agent was not thinking slowly; it was waiting on the right tool. The trace tells us where the user's time went."*

---

<a id="s62"></a>
## 62 · Agentic application - wrong tool selection

**Audience:** agent developers, support engineering, SREs.
**Time:** 5-8 min.

### Story
The model responds quickly but chooses an inventory lookup for an order-status request. Availability and latency look healthy while task correctness is broken.

### Click-path
1. Choose **Wrong tool selection**, run the **Broken** profile, and capture the trace ID.
2. Inspect `gen_ai.tool.name`, `expected_tool`, and `tool.selection.correct` in Application Insights.
3. Ask Observability Agent to explain why this is an orchestration failure rather than a tool-service outage.
4. Challenge the answer by checking that the selected dependency succeeded technically.
5. Run **Fixed** and verify that the selected and expected tools match.

### Killer line
> *"A 200 response can still be a failed agent task. Correctness needs semantic telemetry, not just uptime."*

---

<a id="s63"></a>
## 63 · Agentic application - partial task failure

**Audience:** workflow owners, developers, incident responders.
**Time:** 6-10 min.

### Story
A multi-step task retrieves the right customer record, then fails while completing the requested action. Without trace hierarchy, support sees either a generic failure or misleading evidence that the first tool succeeded.

### Click-path
1. Choose **Partial task failure** and run **Broken**.
2. Follow the trace through the successful first dependency and failed later dependency.
3. In Observability Agent, ask which work completed, which step failed, and whether retrying the entire workflow is safe.
4. Check the agent's conclusion against span ordering and status.
5. Run **Fixed** and verify the full task completes.

### Killer line
> *"The trace preserves partial progress, so engineers can fix or retry the failed step instead of guessing from the final error."*

---

<a id="s64"></a>
## 64 · Customer impact - alert storm correlation

**Audience:** NOC teams, SRE leads, incident commanders.
**Time:** 5-8 min after alerts fire.

### Story
Repeated customer-facing dependency failures cross two existing lab alert conditions: the App Service HTTP 5xx metric alert and the Application Insights failed-request alert. The slow requests add trace evidence but do not trigger a separate latency alert, and the generator does not make the availability-test endpoint unavailable. The demo tests whether the two related failure alerts become one issue without claiming signals the generator cannot produce.

### Click-path
1. In the Control Center **Foundry Playground**, use **Scenario 64 - Alert storm generator**. Choose the number of requests and duration, approve synthetic telemetry, and select **Start Alert Storm**. The default sends 18 requests over 5 minutes in a repeating one-slow/two-failed pattern; **Stop** cancels the active request and prevents further submissions.
2. Wait for the deployed `Http5xx > 5` and `failed requests > 10` evaluation windows, then open the Observability Agent issue list and inspect whether those related failure signals were correlated. Alert evaluation and issue correlation are asynchronous and are not guaranteed to complete during the request batch.
3. Compare timestamps, affected Application Insights resource, operation, and customer impact.
4. Confirm unrelated infrastructure alerts remain separate, as required by the configured instructions.
5. Run fixed profiles and verify recovery against those same two alert conditions.

### Killer line
> *"Correlation turns a page storm into one customer-impact story without hiding unrelated failures."*

---

<a id="s65"></a>
## 65 · AI FinOps - token or model-cost spike

**Audience:** AI platform owners, FinOps, engineering leads.
**Time:** 6-10 min.

### Story
A routing or retry change increases token use and cost even though requests still succeed. Operations needs to connect the cost anomaly to the deployment and trace behavior before optimizing it.

### Click-path
1. In the Control Center **Foundry Playground**, use **Scenario 65 - Token anomaly generator**. Choose an available lab agent and 3, 5, or 10 calls, approve the explicitly billable batch, and select **Generate Token Anomaly**. The generator uses unique context-heavy prompts, reports actual returned token totals, and never automatically replays an ambiguous failure. It reports an estimate only when model pricing is configured; otherwise it explicitly marks cost as unavailable.
2. Review the AI FinOps workbook and token alert evidence.
3. Ask Observability Agent to correlate the time window with Application Insights traces and recent changes, while treating unsupported causal claims as hypotheses.
4. Use terminal-side GitHub Copilot/Azure tooling to inspect code or configuration if desired; do not describe this as direct Observability Agent MCP integration.
5. Generate a bounded post-fix batch and compare token and request outcomes.

> A bounded Control Center batch demonstrates a token-volume change but is not guaranteed to cross the 200,000-token static alert threshold. Token-anomaly runs receive additional completion-token headroom because model reasoning counts against that limit. If Foundry still returns an incomplete run, the batch stops without replay and reports any returned token usage. Use the larger [Scenario 53](#s53) simulator when the demo specifically requires that alert to fire. Stopping a live batch requests cancellation; usage already submitted to Foundry may still be billed.

### Killer line
> *"Successful requests can still be an operational regression when every answer suddenly costs three times as much."*

---

<a id="s66"></a>
## 66 · Change correlation - deployment regression

**Audience:** developers, release engineers, SREs.
**Time:** 6-10 min.

### Story
Agent failures begin shortly after a deployment. Temporal correlation is useful evidence, but it is not proof that the release caused the problem.

### Click-path
1. Add a release annotation, then generate a broken agent scenario.
2. In Application Insights, align the annotation with failure rate, dependency behavior, and trace attributes.
3. Ask Observability Agent for the likely regression and the evidence that supports or weakens it.
4. Inspect the targeted code or configuration in the terminal and make only the bounded demo correction.
5. Run the fixed profile and verify the same telemetry dimensions now show the expected outcome.

### Killer line
> *"The release is a lead, not a verdict; the trace and the controlled post-fix run close the evidence loop."*

---

<a id="s67"></a>
## 67 · Triage - platform failure versus application failure

**Audience:** application and platform teams, incident commanders.
**Time:** 6-10 min.

### Story
An agent request fails while Azure platform signals and application dependencies are both visible. The first operational decision is ownership: application, model/tool chain, or Azure platform.

### Click-path
1. Generate a broken agent scenario and open the corresponding application trace.
2. Open the Traffic-Lights workbook or health model as a companion business-impact view.
3. Ask Observability Agent to separate direct trace evidence from platform-health context and list missing evidence.
4. Confirm whether failures are isolated to one operation/tool or coincide with platform Resource Health, availability, or broader workload signals.
5. Route the incident to the appropriate owner and verify recovery using both the original application signal and the companion platform signal.

### Killer line
> *"Shared context shortens the ownership debate, but engineers still verify whether the evidence points to the app, its tools, or the platform."*

---

## Updated demo flow (≈50 min)

| Min | Scenario |
|---:|---|
| 0–2 | 0. Elevator pitch + RG overview |
| 2–6 | 1. Traffic-Lights Workbook |
| 6–11 | 4. Kubernetes monitoring (Container Insights + Grafana) |
| 11–14 | **14. OTel distributed tracing (Application Map)** + 30. Node.js OTel pod |
| 14–18 | 3. Application Insights live (Failures, Performance) + 28. /api/checkout custom metric |
| 18–21 | 5. Diagnostic Settings via Policy |
| 21–24 | 6. Cross-workspace KQL (queries 10 + 11) |
| 24–27 | **11. DCR transformation cost story** |
| 27–29 | **12. AMBA + 15. Auto-mitigation walk-through** |
| 29–34 | **16. AI in Azure Monitor (NL→KQL, alert summary, Investigate)** |
| 34–36 | **17. Dynamic Thresholds + 18. Code Optimizations + 29. Profiler** |
| 36–38 | **19. Predictive Autoscale (VMSS walkthrough)** |
| 38–40 | 31. Managed Prometheus rule group + 34. Connection Monitor |
| 40–43 | **20. Basic vs Analytics Logs (cost toggle)** + 42. Cost workbook |
| 43–46 | **21. Summary Rules + 22. Availability Tests** |
| 46–48 | **23. Alert Processing Rules** + 37. Nightly maintenance |
| 48–52 | **24. Custom Logs (Ingestion API demo)** + 35. Flow Logs |
| 52–55 | **26. KQL Functions** + 36. KV / Storage Insights |
| 55–58 | **27. RBAC (three tiers walkthrough)** + 43. Sentinel |
| 58–62 | 8. **Break the lab** (live failure) + 33. release annotations + restore + 45. Health Model flips Unhealthy |

> Pick 30 min of scenarios for shorter sessions. Scenarios 20–21, 42 (cost) and 27, 43 (security) are strong closers.
> Scenario **25** (Change Analysis) is a portal-only demo — insert it ad-hoc when the audience is dev-heavy.
> 44 (Search jobs / Restore), 41 (LAW replication), and 45 (Health Models / Service Groups) are best done as **bonus** content for audiences who ask about archiving, BCDR, or workload-level health.
> 46 (SLIs / SLOs) pairs naturally with #45 — run them back-to-back for an SRE-leaning audience.

### "By-workload" short demos (≈25 min each)

| Audience | Run scenarios |
|---|---|
| **App developers** | 3 → 28 → 29 → 14 → 30 → 18 → 33 → 25 |
| **Platform / SRE on AKS** | 4 → 14 → 30 → 31 → 32 → 8 → 15 |
| **Infra ops (VM + network)** | 2 → 50 → 34 → 35 → 7 → 12 → 15 |
| **FinOps** | 9 → 11 → 20 → 21 → 39 → 42 → 51 → 52 |
| **SecOps** | 27 → 47 → 48 → 49 → 44 |
| **AI/ML curious** | 16 → 13 → 17 → 18 → 19 → 53 |
| **Workload owners / SRE leads** | 60 → 1 → 45 → 12 → 7 → 8 (Root entity flips Unhealthy) |
| **SRE Agent evaluation** | 54 → 55 → 56 → 57 → 58 → 59 |
| **Agentic application troubleshooting** | 61 → 62 → 63 → 64 → 66 → 67 |

## Reset between demos

```powershell
# Quick reset (stops VMs, recreates load gen, returns to Green)
./scripts/restore-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab

# Full reset (delete + re-deploy from scratch — ~15 min)
./scripts/teardown.ps1 -Yes
./scripts/deploy.ps1
```
