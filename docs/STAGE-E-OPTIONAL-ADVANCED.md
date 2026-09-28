# Stage E — Optional advanced add-ons

> **Goal of this stage:** showcase reliability, SOC, and preview capabilities that sit on top of everything Stages A–D built — *only* when the customer specifically asks for them. This stage is opt-in: nothing here is required to tell the core observability story.
>
> **Maps to scenarios:** 43, 44, 45, 46.

## 1) What gets created

| Group | Resource(s) | Purpose |
|---|---|---|
| Microsoft Sentinel (conditional) | Sentinel onboarding on `law-amlab-central` (only when `enableSentinel=true`) + one starter analytics rule | Turn the central workspace into a Sentinel workspace. Useful when a customer wants to compare "Azure Monitor native" (Stage D) vs "SOC-grade" (Sentinel). |
| Data export | `exp-amlab-heartbeat` exporting `Heartbeat` rows from `law-amlab-central` to `st<amlab><suffix>` | Demonstrates *continuous export to ADLS/Blob* for long-term retention, audit pipelines, and analytics outside LAW. |
| Managed Prometheus rule group | `prg-amlab` against `amw-amlab`, scoped to `aks-amlab`, alerting via `ag-amlab-email` | Recording + alerting rules in PromQL. Stage B set up the metrics; this stage acts on them. |
| Availability test | `test-amlab-app` against the Stage B web app, results into `appi-amlab`, alerting via `ag-amlab-email` | Classic synthetic ping test demonstrating "is the URL up from outside?" with multi-region probes. |
| Health model | `hm-amlab-workload` wiring web app, App Insights, AKS, Linux VM, Windows VM, VMSS, Key Vault, storage, action group into a single health graph | Preview capability — gives an executive-level "service health" rollup with traffic-light entities. |
| SLI identity | `id-sli-amlab` (User-Assigned Managed Identity) bound to `amw-amlab` | Identity used by SLI/SLO tooling and Grafana service connections. Prereq for the SLI scripts shipped in `scripts/`. |

> Cross-stage references: `law-amlab-central`, `amw-amlab`, `appi-amlab`, `st<amlab><suffix>`, `kv-amlab-<suffix>` (Stage A); `aks-amlab`, web app (Stage B); `vmss-amlab`, `ag-amlab-email`, both VMs (Stage C).

## 2) Speaker notes

1. **"This stage answers 'what's next?' — not 'what's required?'"**
   Set expectations clearly. Stages A–D are the *core story*. Stage E shows the customer the *next two years* of their observability roadmap.

2. **"Sentinel vs Stage D — explicit, not implicit."**
   If you enable Sentinel here, do a side-by-side: the same `roleAssignments/write` query that powered scenario 48 now becomes a Sentinel analytics rule with incident, entity mapping, and playbooks. Customers see what extra they get for the Sentinel SKU.

3. **"Data export = your retention escape hatch."**
   Open the `Heartbeat` export. Explain that LAW retention is one tier (90 days default for analytics), and Blob is *much* cheaper for long-term/cold archive. Pair with the cost workbook.

4. **"Prometheus rules close the loop on Stage B's metrics."**
   Stage B brought `amw-amlab` and Grafana in. Stage E adds the *alerting* and *recording* layer. Show one PromQL recording rule and one alert rule.

5. **"Availability tests are the cheapest insurance you'll ever buy."**
   Standard web tests are billed per execution; the public retail row checked September 27, 2026 was EUR 0.0005/execution. Price the configured frequency and probe locations using the current [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/). Show the *Availability* blade in App Insights — green/red world map.

6. **"Health model is a preview — frame it correctly."**
   Pitch as "executive dashboarding for your service graph." Don't oversell — the entity types and API are still moving. Show the visual graph and the health states; that's the demoable surface area.

7. **"SLI identity is plumbing for SLOs."**
   Not a flashy demo on its own. Mention that the `scripts/setup-slis.ps1` and Grafana service connections rely on this identity existing.

## 3) Portal walkthrough (UI)

1. **`law-amlab-central` → Microsoft Sentinel** *(only if `enableSentinel=true`)* — show the workspace is Sentinel-enabled. Open *Analytics → Active rules* and find the starter rule.
2. **`law-amlab-central` → Data Export → `exp-amlab-heartbeat`** — show the destination storage account and the `Heartbeat` table mapping. After ~30 min you can browse the container in `st<amlab><suffix>` to see exported blobs.
3. **`amw-amlab` → Rule groups → `prg-amlab`** — show recording + alerting rules in PromQL.
4. **`appi-amlab` → Availability → `test-amlab-app`** — show the world map of probe locations and the test history.
5. **Monitor → Health models → `hm-amlab-workload`** *(preview blade)* — open the graph view. Show entities (web app, AKS, VMs, VMSS, Key Vault, storage) and their roll-up health.
6. **Resource group → `id-sli-amlab`** — managed identity; show *Azure role assignments* on `amw-amlab`.
7. **Optional: Grafana → Data sources** — show that `amg-amlab-<suffix>` already has `amw-amlab` wired in; `id-sli-amlab` is the identity used for Azure Monitor data sources in custom Grafana dashboards.

## 4) CLI validation

```powershell
$sub = '<your-subscription-id>'
$rg  = 'rg-azure-monitor-lab-terraform-test'
az account set --subscription $sub

# Sentinel onboarding (if enabled)
az sentinel onboarding-state list --resource-group $rg --workspace-name law-amlab-central -o table 2>$null
az sentinel alert-rule list --resource-group $rg --workspace-name law-amlab-central --query "[].{name:name,kind:kind,enabled:enabled}" -o table 2>$null

# Continuous export
az monitor log-analytics workspace data-export list -g $rg --workspace-name law-amlab-central -o table

# Prometheus rule group
az resource list -g $rg --resource-type Microsoft.AlertsManagement/prometheusRuleGroups --query "[].{name:name,scopes:properties.scopes,rules:length(properties.rules)}" -o table

# Availability test
$webApp = az webapp list -g $rg --query "[?starts_with(name, 'app-amlab')].name | [0]" -o tsv
az monitor app-insights web-test list -g $rg --query "[?starts_with(name, 'test-amlab-app')].{name:name,enabled:propertiesEnabled,frequency:properties.Frequency}" -o table

# Health model
az resource list -g $rg --resource-type Microsoft.CloudHealth/healthmodels --query "[].{name:name,location:location}" -o table

# SLI identity
az identity show -g $rg -n id-sli-amlab --query "{name:name,principalId:principalId,clientId:clientId}" -o table

# Verify exported blobs appear (after first export cycle ~30 min)
$storage = az storage account list -g $rg --query "[?starts_with(name, 'stamlab')].name | [0]" -o tsv
az storage container list --account-name $storage --auth-mode login --query "[?contains(name, 'heartbeat')].name" -o table
```

## 5) Done-when

1. *(If enabled)* Sentinel is onboarded on `law-amlab-central` and at least one analytics rule is enabled.
2. `exp-amlab-heartbeat` exists and (after ≥ 30 min) the destination storage container contains blobs.
3. `prg-amlab` returns ≥ 1 rule and the rules show in `amw-amlab`'s rule groups blade.
4. `test-amlab-app` returns success from ≥ 1 probe location in App Insights *Availability*.
5. `hm-amlab-workload` graph renders in the Health Models preview blade with all expected entities visible.
6. `id-sli-amlab` is a UAMI with a `principalId` and has a role assignment on `amw-amlab`.

## 6) Tear-down nuance

Stage E adds resources that *outlive* the rest if not removed in the right order:

1. Sentinel onboarding must be removed *before* deleting the workspace (or the deletion is blocked).
2. The data export and managed identity should be removed before storage / AMW.
3. The simplest path is the `scripts/teardown.ps1` helper which understands these orderings; for staged tear-down via Terraform, flip `enable_stage_e = false` first and apply, then `enable_stage_d = false`, and so on down to A.
