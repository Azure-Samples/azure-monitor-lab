# Azure Monitor Lab - Step-by-Step Deployment with Terraform

This guide is for customers standardizing on Terraform while still using this lab.

## 1) Strategy options

Use one of these patterns.

1. Fastest adoption (recommended first): Terraform orchestrates staged deployments of compiled Bicep/ARM templates, one per stage.
2. Full native Terraform: rewrite each module to azurerm/azapi resources, stage by stage.

Start with option 1 to prove scenario flow quickly, then migrate to option 2 incrementally.

## 2) Guardrails

Before every terraform apply:

```powershell
$sub='<your-subscription-id>'
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
```

### Planning aid

For workshop planning and customer expectation-setting, use:
- [CUSTOMER-STAGE-HANDOUT.md](CUSTOMER-STAGE-HANDOUT.md)

### Per-stage deep dives (deployed inventory + speaker notes + UI/CLI walkthroughs)

- [STAGE-A-FOUNDATION.md](STAGE-A-FOUNDATION.md)
- [STAGE-B-WORKLOADS.md](STAGE-B-WORKLOADS.md)
- [STAGE-C-ALERTING.md](STAGE-C-ALERTING.md)
- [STAGE-D-SECURITY-POSTURE.md](STAGE-D-SECURITY-POSTURE.md)
- [STAGE-E-OPTIONAL-ADVANCED.md](STAGE-E-OPTIONAL-ADVANCED.md)
- [STAGE-AI.md](STAGE-AI.md)
- [STAGE-SRE-AGENT.md](STAGE-SRE-AGENT.md)

## 3) Stage model (same as Bicep)

1. Stage A - Foundation
2. Stage B - Workloads and dashboards
3. Stage C - Alerts and response
4. Stage D - Security posture (47/48/49)
5. Stage E - Optional advanced add-ons
6. Stage AI - Optional Microsoft Foundry GenAI workload (off by default)
7. Stage SRE Agent - Optional Azure SRE Agent (off by default)

Keeping stage boundaries identical across Bicep and Terraform avoids customer confusion.

## 4) Stage details (scenarios + deployed services)

Use this matrix in customer sessions so Terraform users see exactly what each apply wave introduces.

| Stage | High-level scenario goals | Scenario IDs (from DEMO-SCENARIOS.md) | Azure services/resources deployed |
|---|---|---|---|
| Stage A - Foundation | Build the shared monitoring substrate and governance prerequisites. | 1, 5, 6, 9 (foundation portions) | Resource group, central LAW + AppInsights LAW, workspace-based App Insights, Azure Monitor Workspace, DCE baseline, core networking (VNet/NSG), baseline diagnostics and policy assignments, shared storage/event-hub/Key Vault foundations, VM Insights DCR and AzureActivity workspace transform DCR, saved queries, KQL functions, traffic-lights and cost workbooks. |
| Stage B - Workloads and dashboards | Onboard app/compute workloads and expose observability views. | 2, 3, 4, 22, 28, 29, 30, 31, 32, 34, 35, 36, 42 | Optional Linux/Windows VMs with AMA + DCR associations + per-VM 23:00 CET/CEST auto-shutdown schedules, AKS with Container Insights + Managed Prometheus + Grafana, App Service + App Insights, Control Center runner platform with diagnostics/RBAC, custom logs, Connection Monitor, and flow logs. Completion publishes workloads and the digest-pinned runner. |
| Stage C - Alerts and response | Introduce detection, suppression, and auto-response controls. | 7, 8, 12, 15, 17, 19, 23, 37 | Action Group with email + Logic App + optional SIEM webhook, metric/log/AKS/App alerts, AMBA, Service/Resource Health alerts, maintenance/low-severity/nightly-VM suppression rules, and VMSS predictive autoscale. |
| Stage D - Security posture | Deliver Azure Monitor-native security detections without requiring SIEM. | 27, 47, 48, 49 | LAW granular RBAC roles + ABAC assignments, scheduled query alerts for control-plane drift, privilege-escalation watch, and exfil early warning. |
| Stage E - Optional advanced add-ons | Add optional SOC and reliability preview capabilities. | 43, 44, 45, 46 | Optional Sentinel onboarding and analytics rule, Heartbeat data export, Managed Prometheus rule group, availability tests, health model, SLI identity prerequisites. |
| Stage AI - Optional GenAI workload | Add a Microsoft Foundry workload that emits token/trace/cost telemetry, with AI FinOps observability. Off by default (billable models, region-limited). | - | Foundry account + project in swedencentral by default, four model deployments (gpt-5-mini chat, text-embedding-3-small, gpt-5.4, model-router), Application Insights connection, token alerts, AI FinOps query pack + workbook. When Stage E is enabled, its workload health model includes the AI tier. Optional traffic always runs as a finite background batch. |
| Stage SRE Agent - Optional SRE integration | Provision and validate the preview SRE Agent and monitoring connectors. | 54, 55, 56, 57, 58 | Agent pinned to swedencentral, system-assigned and user-assigned identities, Azure Monitor/Application Insights/Log Analytics connectors, resource-group access and subscription-scope Monitoring Contributor. Automatic validation works with or without Stage B. Portal investigation scenarios remain separate from the Control Center MCP assistant. |

### Dependency and apply order

1. Apply Stage A first; it provides shared IDs and telemetry sinks.
2. Apply Stage B next; workload resources require Stage A workspaces/network.
3. Apply Stage C after Stage B; alert scopes/actions depend on deployed workloads.
4. Apply Stage D after Stage A and C; security detections need Activity data and action routing.
5. Apply Stage E last; optional features rely on the previously deployed monitor estate.
6. Apply Stage AI any time after Stage A; it uses the Stage A Application Insights component and is independent of Stages B to E.
7. Apply Stage SRE Agent any time after Stage A; it uses the Stage A monitoring resources and does not require workloads.

The Control Center requires Stage B. Its Foundry Playground also needs AI; its SRE MCP Assistant needs both AI and SRE. A+AI and A+SRE remain valid standalone scenarios without a Web App.

### Acceptance criteria by stage

1. Stage A: shared monitoring/network resources, DCRs, workbooks, and policy are present. No compute or Web App workload is expected yet.
2. Stage B: completion verifies the new app publication and configures console access; workload telemetry becomes visible in queries/workbooks.
3. Stage C: at least one alert path test reaches the Action Group.
4. Stage D: scenarios 47/48/49 query outputs are non-empty and alert rules evaluate.
5. Stage E: optional Sentinel/health/SLI capabilities are reachable and testable.
6. Stage AI: Foundry model deployments exist, App Insights receives AI telemetry, and the AI FinOps queries return data after `setup-ai.ps1` runs.
7. Stage SRE Agent: the agent is in `swedencentral`, all three connectors are configured, and identity-specific RBAC validation passes.

## 5) Terraform scaffold (orchestrating staged ARM/Bicep)

This repo ships a working staged Terraform scaffold at `terraform/` and pre-compiled stage templates at `infra/stages/`:

| Stage toggle | Template (compiled from Bicep) |
|---|---|
| `enable_stage_a` | `infra/stages/00-foundation.json` |
| `enable_stage_b` | `infra/stages/10-workloads.json` |
| `enable_stage_c` | `infra/stages/20-alerting.json` |
| `enable_stage_d` | `infra/stages/30-security-posture.json` |
| `enable_stage_e` | `infra/stages/40-optional-advanced.json` and, when Sentinel is enabled, `infra/stages/41-sentinel-content.json` |
| `enable_stage_ai` | `infra/stages/50-ai.json` |
| `enable_stage_sre_agent` | `infra/stages/60-sre-agent.json` |

Each toggle gates its own `azapi_resource "Microsoft.Resources/deployments@2022-09-01"` block. Disabling a flag removes its deployment record, not the nested Azure resources. Console and SRE completion also follow explicit Terraform selections; they do not require matching flags in a local central config.

Folder layout:

- `terraform/providers.tf`
- `terraform/variables.tf`
- `terraform/main.tf`
- [terraform/console.tf](../terraform/console.tf)
- `terraform/stages.tfvars`

### Regenerating stage templates from Bicep

If you change anything under `infra/stages/*.bicep`, recompile the JSON templates that Terraform consumes:

```powershell
az bicep build --file infra/stages/00-foundation.bicep        --outfile infra/stages/00-foundation.json
az bicep build --file infra/stages/10-workloads.bicep         --outfile infra/stages/10-workloads.json
az bicep build --file infra/stages/20-alerting.bicep          --outfile infra/stages/20-alerting.json
az bicep build --file infra/stages/30-security-posture.bicep  --outfile infra/stages/30-security-posture.json
az bicep build --file infra/stages/40-optional-advanced.bicep --outfile infra/stages/40-optional-advanced.json
az bicep build --file infra/stages/41-sentinel-content.bicep    --outfile infra/stages/41-sentinel-content.json
az bicep build --file infra/stages/50-ai.bicep               --outfile infra/stages/50-ai.json
az bicep build --file infra/stages/60-sre-agent.bicep        --outfile infra/stages/60-sre-agent.json
```

The legacy `infra/main.bicep` continues to work unchanged for the original Bicep-only deployment path.

## 6) Deployment runbook

Run the commands from the repository root. `-chdir=terraform` keeps Terraform in its own directory without changing the working directory for the later setup scripts.

### Step 1 - Confirm the existing terraform files

The shipped files already contain the staged wiring described above. Open them and confirm:

- `terraform/providers.tf` declares `azurerm ~> 4.0` and `azapi ~> 2.0` and threads `subscription_id` through both providers.
- `terraform/variables.tf` declares seven stage toggles plus shared inputs (`subscription_id`, `resource_group_name` (default `rg-azure-monitor-lab`), `location`, `alert_email`, `vm_admin_password`, etc.).
- `terraform/main.tf` declares one `data "azurerm_resource_group"` (BYO RG, looked up by name) plus seven `azapi_resource` deployments, each guarded by its own stage toggle.
- [terraform/console.tf](../terraform/console.tf) runs console completion when B is enabled, or standalone SRE validation when SRE is enabled without B.

### Step 2 - Set inputs in `terraform/stages.tfvars`

**Recommended:** bootstrap from the central `lab.config.json` instead of hand-editing this file. From the repo root:

```powershell
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json   # fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, stageToggles, ...
./scripts/sync-config.ps1 # regenerates terraform/stages.tfvars + .azure-target.json + infra/main.parameters.json
```

`scripts/sync-config.ps1` writes `terraform/stages.tfvars` from your central config, including all seven stage toggles. Re-run it any time you change `lab.config.json` (e.g. to flip the next stage).

**Or hand-edit `terraform/stages.tfvars` directly** (skip `sync-config.ps1`; the file is gitignored):

```hcl
subscription_id     = "<your-subscription-id>"
resource_group_name = "rg-azure-monitor-lab"   # optional - default is rg-azure-monitor-lab
location            = "northeurope"
alert_email         = "your.alias@example.com"
vm_admin_password   = "<STRONG-PASSWORD>"

enable_stage_a = true
enable_stage_b = false
enable_stage_c = false
enable_stage_d = false
enable_stage_e = false
enable_stage_ai = false   # optional Foundry GenAI workload (swedencentral)
enable_stage_sre_agent = false
```

> Note: if `lab.config.json` exists, running `scripts/deploy.ps1` will auto-overwrite `terraform/stages.tfvars` on its next invocation. Pick **one** workflow (central config OR hand-edit) and stick with it.

### Step 3 - Create the resource group (BYO)

Terraform looks the RG up via data source rather than creating it, so `terraform destroy` will not nuke it. Create it once (idempotent - safe to re-run):

```powershell
$config = Get-Content ./lab.config.json -Raw | ConvertFrom-Json
$sub = $config.subscriptionId.ToString()
$tenant = $config.tenantId.ToString()
$rg = $config.resourceGroup
$location = $config.location
az account set --subscription $sub
$active = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $active.id -ne $sub -or $active.tenantId -ne $tenant) {
	throw 'Subscription or tenant mismatch.'
}
az group create --subscription $sub -n $rg -l $location --tags purpose=azure-monitor-lab owner=demo-lab
```

This uses the same central config that `sync-config.ps1` projects into `terraform/stages.tfvars`. If you chose the hand-edited tfvars workflow instead, set `$sub`, `$tenant`, `$rg`, and `$location` manually to the matching values. If you omit `resource_group_name` from `stages.tfvars`, Terraform defaults to `rg-azure-monitor-lab`. If you skip this step, `terraform plan` will fail because the configured resource group was not found.

### Step 4 - Init

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform validate
```

### Step 5 - Plan/apply Stage A

```powershell
terraform -chdir=terraform plan -var-file stages.tfvars
terraform -chdir=terraform apply -var-file stages.tfvars
```

Expected plan summary with only Stage A enabled:

```
Plan: 1 to add, 0 to change, 0 to destroy.
```

If your shell reports "Too many command line arguments", retype the command manually (to avoid smart dashes from copy/paste) and keep the space-separated form shown above.

### Step 6 - Enable Stage B, then C, then D, then E

Flip one stage flag at a time in `stages.tfvars` and rerun plan/apply. Stage B adds both its ARM deployment and `terraform_data.console_ready`. This completion hook publishes the app and AKS workloads and automatically provisions console sign-in, health permissions, the registry/image/job, and selected agent integrations. Do not run another post-deployment command after a successful apply.

The machine running apply needs PowerShell 7, Azure CLI signed into the selected subscription, the .NET 8 SDK, and the lab workload tools. The deployer needs Azure role-definition/assignment and Entra registration permissions. Optional AI/SRE packaging also needs Python/npm/tar. For a service-principal deployment, set `console_operator_object_ids` to approved tenant user object IDs. See [console prerequisites](../workloads/webapp/LAB-OPERATIONS.md#prerequisites).

Changes to relevant stages or source files rerun initialization. Terraform passes Stage E and SRE selections explicitly, including false, so stale central config cannot enable or skip that completion work. A failed completion hook fails apply, so incomplete setup is not reported as deployment success. The hook has no destroy-time provisioner: the registry/job and other nested resources follow the lab's existing resource-group cleanup model.

### Step 7 - Enable Stage AI (optional)

Stage AI can be enabled after Stage A, independently of Stages B to E. It is off by default because the Foundry model deployments are billable and pinned to `swedencentral`.

Set the AI flag in `stages.tfvars`:

```hcl
enable_stage_ai = true
ai_location = "swedencentral"
router_model_version = "2025-08-07"  # verify with: az cognitiveservices account list-models -l swedencentral
```

Then apply the stage:

```powershell
terraform -chdir=terraform plan -var-file stages.tfvars
terraform -chdir=terraform apply -var-file stages.tfvars
```

When Stage B is enabled, apply automatically installs the [AI dependencies](../workloads/ai/requirements.txt), prepares four matching agents, and refreshes the published console inventory and access without simulated conversations. This also happens when AI is added after an earlier Stage B apply; do not run another console wrapper.

To generate optional AI telemetry from the repo root, run the account-scoped helper below. Use the deployed prefix if it is not `amlab`:

```powershell
./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix amlab
```

This helper also works locally. It verifies and forwards the subscription and tenant, discovers Foundry and App Insights through core ARM commands, and starts a finite 150-conversation batch in the background. Add `-SkipTraffic` to prepare agents without traffic, or `-Conversations <count>` to select a finite batch size. Keep the host/sign-in available; see [Stage AI traffic behavior](STAGE-AI.md#6-enable--run).

An AI-only deployment without Stage B has no Web App completion hook and uses the same helper to prepare its standalone scenario. Stage AI creates the Foundry resources, model deployments, tracing connection, token alerts, query pack, and workbook. Its workload health tier is present only when Stage E is also enabled.

### Step 8 - Enable Stage SRE Agent (optional)

Terraform deploys the compiled Stage 60 Bicep template through AzAPI. The stage depends on Stage A, remains off by default, and hard pins the SRE Agent to `swedencentral`. Enable it in `stages.tfvars`:

```hcl
enable_stage_sre_agent = true
```

The deploying identity needs subscription-scope resource deployment and role-assignment permission, for example Owner, because Stage 60 grants the agent connector identity Monitoring Contributor. Review the plan and apply it:

```powershell
terraform -chdir=terraform plan -var-file stages.tfvars
terraform -chdir=terraform apply -var-file stages.tfvars
```

The stage creates the preview `Microsoft.App/agents` resource, managed identities, Azure Monitor, Application Insights, and Log Analytics connectors, and required RBAC. With Stage B, `terraform_data.console_ready` refreshes the console and invokes SRE validation with Terraform's explicit flag. Without B, `terraform_data.sre_ready` runs the same standalone validator without requiring App Service or AKS. Validation failure fails apply. No second setup or post-deployment wrapper is needed after success.

SRE-only completion requires PowerShell 7 and Azure CLI signed into the selected subscription, but no Web App build tools. The validator is read-only by default; it does not start investigations or auto-grant missing roles. Active usage is billable and always-on billing can begin after an eligible trial.

> Setting `enable_stage_sre_agent = false` or running `terraform destroy` removes the ARM deployment record but does not delete resources created by that nested deployment. Run `./scripts/teardown.ps1 -ResourceGroup $rg` or delete the SRE Agent explicitly before the trial ends to stop billing.

Follow [Stage SRE Agent](STAGE-SRE-AGENT.md) for optional portal investigators and Review-mode response plans. Those are separate scenarios, not prerequisites for the Control Center's MCP questions and approved operations.

### Step 9 - Security stage validation

After Stage D, verify Activity Log ingestion:

```powershell
$lawId = az monitor log-analytics workspace show -g rg-azure-monitor-lab -n law-amlab-central --query customerId -o tsv
az monitor log-analytics query -w $lawId --analytics-query "AzureActivity | where TimeGenerated > ago(1d) | summarize count()" -o table
```

If count is zero, scenarios 47/48/49 alerts will not trigger.

## 7) Native Terraform migration path (after orchestration works)

Migrate in this order:

1. Foundation resources (LAW, App Insights workspace binding, AMW, networking)
2. Workload resources (VM, AKS, App Service, Grafana)
3. Alerting resources (action groups, metric/log/activity alerts)
4. Security posture query alerts and RBAC
5. Optional preview resources (health model, SLI, Sentinel)

Use `azapi_resource` for preview/control-plane resources not fully covered in `azurerm`.

## 8) Scenario parity matrix

Keep this matrix during migration:

- 27 -> LAW RBAC resources (Stage D, `30-security-posture.json`)
- 47 -> AzureActivity control-plane drift query alert (Stage D)
- 48 -> roleAssignments write/elevateAccess query alert (Stage D)
- 49 -> exfil early-warning query alert on Traffic Analytics (Stage D)

A stage is complete only when both resource deployment and scenario validation are done.

## 9) Recommended definition of done

For each stage:
1. `terraform plan` shows only expected changes.
2. `terraform apply` is idempotent on second run.
3. Required scenario query returns data.
4. At least one alert test is executed and received in Action Group.

## 10) Tearing down the lab

The resource group is BYO (Terraform does not own it via data source), so `terraform destroy` alone will not cascade-delete the LAWs, VMs, AKS, alerts, etc. - it only removes the seven staged deployment records. Use Option A.

### Option A - run the teardown wrapper (recommended)

The wrapper cleans up Azure dependencies before deleting the resource group. This is the same cleanup path used after one-shot or staged Bicep deployments.

```powershell
$config = Get-Content ./lab.config.json -Raw | ConvertFrom-Json
$sub = $config.subscriptionId.ToString()
$rg = $config.resourceGroup
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
.\scripts\teardown.ps1 -ResourceGroup $rg -Yes
```

If you used hand-edited tfvars without `lab.config.json`, set `$sub` and `$rg` manually to the matching Terraform values.

After the asynchronous resource-group deletion completes, clear the Terraform deployment records so the next apply starts clean:

```powershell
terraform -chdir=terraform state list | ForEach-Object { terraform -chdir=terraform state rm $_ }
```

### Option B - terraform destroy + manual RG cleanup

Use this if you want to drive teardown through Terraform first (e.g. for state-machine cleanliness in CI), then clean the RG yourself.

```powershell
terraform -chdir=terraform destroy -var-file stages.tfvars
az group delete --subscription $sub -n $rg --yes --no-wait
```

### Post-teardown: cleanup of artifacts that live outside the RG

A few resources are subscription-scoped or live in `NetworkWatcherRG` and survive RG deletion.

1. Soft-deleted Log Analytics workspaces (14-day grace period; names stay reserved until purged or expired):

```powershell
# Keep the filter in PowerShell. Windows Azure CLI can strip quoted JMESPath
# expressions before az receives them, producing "] was unexpected at this time."
$deletedLaw = az monitor log-analytics workspace list-deleted-workspaces --subscription $sub -o json | ConvertFrom-Json
$deletedLaw | Where-Object { $_.name -like '*amlab*' } | Format-Table
# Permanent purge if needed:
# az rest --method delete --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.OperationalInsights/locations/northeurope/deletedWorkspaces/<name>?api-version=2023-09-01"
```

2. Soft-deleted Application Insights components (also 14-day grace):

```powershell
$deletedAppInsights = az monitor app-insights component list-deleted --subscription $sub -o json | ConvertFrom-Json
$deletedAppInsights | Where-Object { $_.name -like '*amlab*' } | Format-Table
```

3. Soft-deleted Key Vault (7-day retention, `enablePurgeProtection: null` so it can be purged). Key Vault names are deterministic (`kv-${namePrefix}-${take(suffix,5)}` from `resourceGroup().id`), so redeploying to the **same RG name** before the vault is purged fails with `VaultAlreadyExists`:

```powershell
$deletedVaults = az keyvault list-deleted --subscription $sub -o json | ConvertFrom-Json
$deletedVaults | Where-Object { $_.name -like 'kv-amlab-*' } | Format-Table name, @{n='location';e={$_.properties.location}}
# Purge before redeploying to the same RG name:
# az keyvault purge --name <vaultName> --subscription $sub
```

4. NSG/VNet flow logs in `NetworkWatcherRG` (Stage B creates them outside the lab RG):

```powershell
$flowLogs = az network watcher flow-log list -l northeurope --subscription $sub -o json | ConvertFrom-Json
$flowLogs | Where-Object { $_.name -like '*amlab*' } | Select-Object name, enabled | Format-Table
# az network watcher flow-log delete -l northeurope -n <flowLogName> --subscription $sub
```

5. Custom role definition from Stage D (`AMLAB - Granular Log Reader (<hash>)`). Auto-removed once no scopes reference it; force-delete if it lingers:

```powershell
az role definition list --custom-role-only true --subscription $sub --query "[?starts_with(roleName,'AMLAB - Granular Log Reader')]" -o table
# az role definition delete --name "AMLAB - Granular Log Reader (<hash>)" --subscription $sub
```

6. Confirm the RG is gone:

```powershell
az group exists -n $rg --subscription $sub   # false once the async delete completes
```
