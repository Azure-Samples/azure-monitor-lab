# Azure Monitor Lab - Step-by-Step Deployment with Bicep

This guide shows how to deploy the lab in controlled stages so you can enable scenarios progressively instead of shipping everything at once.

## 1) What you have today

The repository has dedicated [stage templates](../infra/stages) for the core lab and optional add-ons. Bicep supports the preview Observability Agent stage; Terraform does not because that provisioning path is not supported by the preview. [The one-shot script](../scripts/deploy.ps1) continues to use [the full-lab template](../infra/main.bicep); it is a separate deployment path, not a foundation-only deployment.

## 2) Guardrails (must-do)

1. Select and verify the expected subscription and tenant before every write. The helper below does this before preview and again before deployment.
2. Pass the resource group and subscription explicitly; local config is not automatically consumed by raw Azure CLI commands.
3. Review each stage's what-if before confirming it. Use incremental mode. Reapplying a stage is not a teardown of stages omitted from that template.
4. Use PowerShell 7 and Azure CLI with Bicep support. Stage B completion also needs the [.NET, workload-tool, Azure RBAC, and tenant permissions](../workloads/webapp/LAB-OPERATIONS.md#prerequisites) required for the Control Center. AI needs Python; optional SRE packaging also needs npm/tar.

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
- [STAGE-OBSERVABILITY-AGENT.md](STAGE-OBSERVABILITY-AGENT.md)

## 3) Stage model (recommended)

Deploy in this order.

1. Stage A - Core observability foundation
2. Stage B - Workload telemetry and dashboards
3. Stage C - Alerts and auto-mitigation
4. Stage D - Security posture scenarios
5. Stage E - Optional advanced/security add-ons
6. Stage AI - Optional Microsoft Foundry GenAI workload (off by default)
7. Stage SRE Agent - Optional Azure SRE Agent evaluation (off by default)
8. Stage Observability Agent - Optional autonomous alert correlation and agentic-application investigation (off by default)

## 4) Stage details (scenarios + deployed services)

Use this as the workshop script: each stage adds a bounded set of capabilities and scenarios.

| Stage | High-level scenario goals | Scenario IDs (from DEMO-SCENARIOS.md) | Azure services/resources deployed |
|---|---|---|---|
| Stage A - Core observability foundation | Establish the telemetry backbone and governance baseline. | 1, 5, 6, 9 (foundation portions) | Central LAW + AppInsights LAW, workspace-based App Insights, Azure Monitor Workspace, DCE, VNet/NSG, shared storage/Event Hub/Key Vault, VM Insights and workspace-transform DCRs, diagnostic policy, saved queries, KQL functions, traffic-lights and cost workbooks. Create the resource group separately. No VMs, AKS, or Web App yet. |
| Stage B - Workload telemetry and dashboards | Onboard compute and app workloads into the monitoring plane and expose dashboards. | 2, 3, 4, 22, 28, 29, 30, 31, 32, 34, 35, 36, 42 | Optional Linux/Windows VMs + AMA/DCR associations + per-VM 23:00 CET/CEST auto-shutdown schedules, AKS + Container Insights + Managed Prometheus, Managed Grafana, App Service + App Insights, Control Center runner platform with diagnostics/RBAC, custom logs, connection monitor, and flow logs. Completion publishes workloads and the digest-pinned runner. |
| Stage C - Alerts and response | Add actionable detection and automated response controls. | 7, 8, 12, 15, 17, 19, 23, 37 | Action Group, metric/log/activity alerts, AMBA, dynamic thresholds, VMSS predictive autoscale, maintenance/low-severity/nightly-VM suppression rules, and the auto-mitigation Logic App. |
| Stage D - Security posture (Azure Monitor native) | Build non-SIEM security posture detections directly in Azure Monitor. | 27, 47, 48, 49 | Log Analytics RBAC model (workspace/table/row scope), AzureActivity routing prerequisite, scheduled query alerts for control-plane drift, role assignment changes, and exfil early-warning correlation, alert routing via existing Action Group. |
| Stage E - Optional advanced/security add-ons | Layer advanced SOC and reliability preview capabilities. | 43, 44, 45, 46 | Optional Sentinel onboarding + analytics rule, Heartbeat data export, Managed Prometheus rule group, availability test, workload health model, SLI identity prerequisites, and optional platform-logs/metrics-export DCRs. Completion configures the Service Group and verifies SLI prerequisites; preview SLIs remain a portal step. |
| Stage AI - Optional GenAI workload | Add a Microsoft Foundry workload emitting token/trace/cost telemetry, with AI FinOps observability. Off by default (billable models, region-limited). | - | Foundry account + project in swedencentral by default, four model deployments (gpt-5-mini, text-embedding-3-small, gpt-5.4, model-router), App Insights connection, token alerts, AI FinOps query pack + workbook. Stage E can add the AI health tier after AI is deployed; a standalone AI health model is separately opt-in. Agent setup starts a finite background traffic batch unless skipped. |
| Stage SRE Agent - Optional incident investigation | Add Azure SRE Agent investigation and Review-mode response workflows. Off by default (preview and billable). | 54, 55, 56, 57, 58 | Azure SRE Agent hard pinned to swedencentral, system-assigned and user-assigned managed identities, Azure Monitor, Application Insights, and Log Analytics connectors, resource-group reader roles, and subscription-scope Monitoring Contributor. |
| Stage Observability Agent - Optional autonomous operations | Correlate agentic-application alerts, create issues, investigate failures, and compare broken/fixed trace evidence. Off by default (preview; investigations consume Azure Agent Credits). | 61, 62, 63, 64, 65, 66, 67 | Azure Copilot Observability Agent and a dedicated Azure Monitor workspace in a supported region, one monitored Application Insights resource, system-assigned identity, Issue Contributor on the workspace, and subscription-scope Monitoring Reader. |

### Stage dependency chain

1. Stage A is mandatory for all other stages.
2. Stage B depends on Stage A outputs (workspaces/network/monitor workspace).
3. Stage C depends on Stage B resources for alert scopes.
4. Stage D depends on Stage A ingestion and Stage C action routing.
5. Stage E depends on A, B, and C. Its AI health tier additionally requires Stage AI to have been deployed.
6. Stage AI depends only on Stage A (it connects to `appi-amlab`); deploy it any time after Stage A.
7. Stage SRE Agent depends only on Stage A (Application Insights and central LAW); deploy it any time after Stage A.
8. Stage Observability Agent depends only on Stage A (Application Insights); deploy it any time after Stage A. Its Control Center scenario runner additionally requires Stage B.

The Control Center requires Stage B. Its Foundry Playground additionally requires AI; its SRE MCP Assistant requires both AI and SRE. An A+AI or A+SRE lab is valid without a Web App. Portal investigators and response plans are separate scenarios, not prerequisites for the MCP assistant.

### Stage acceptance criteria (high level)

1. Stage A done: the shared monitoring/network resources, DCRs, workbooks, and policy are present. Workload telemetry is not expected before workloads exist.
2. Stage B done: the completion script verifies the new app publication, approved console sign-in/access work, and enabled VM/AKS/App Service telemetry reaches the monitoring plane.
3. Stage C done: at least one alert test reaches the Action Group.
4. Stage D done: scenario 47/48/49 queries return data and alert rules evaluate.
5. Stage E done: optional feature endpoints/blades become accessible and testable.
6. Stage AI done: Foundry model deployments exist, App Insights receives AI telemetry, and the AI FinOps queries return data after `setup-ai.ps1` runs.
7. Stage SRE Agent done: the agent is in `swedencentral`, all three connectors are configured, and identity-specific RBAC validation passes.
8. Stage Observability Agent done: the agent and dedicated workspace share a supported region, Application Insights is monitored, automatic issue creation is enabled, investigation mode matches the explicit selection, and least-privilege RBAC validation passes.

## 5) Practical deployment commands (stage-by-stage)

Run these examples from the repository root in the same PowerShell 7 session. Each call previews one dedicated stage and asks for confirmation before deployment. Raw Bicep is infrastructure-only until the documented completion step succeeds.

### Step 0 - Bootstrap inputs (recommended)

Create a private config from [the example](../lab.config.json.example), fill in the subscription, tenant, resource group, prefix, region, notification address, and VM credentials, then generate the local inputs. Do not overwrite an existing config:

```powershell
if (-not (Test-Path ./lab.config.json)) { Copy-Item ./lab.config.json.example ./lab.config.json }
```

After editing the config, run:

```powershell
./scripts/sync-config.ps1
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$config = Get-Content ./lab.config.json -Raw | ConvertFrom-Json
$sub = [guid]$config.subscriptionId
$tenant = [guid]$config.tenantId
$rg = $config.resourceGroup
$sourceParameters = (Get-Content ./infra/main.parameters.json -Raw | ConvertFrom-Json -AsHashtable).parameters
$prefix = $sourceParameters.namePrefix.value
$location = $sourceParameters.location.value

az account set --subscription $sub
$account = az account show --query '{id:id,tenantId:tenantId}' --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $sub.ToString() -or $account.tenantId -ne $tenant.ToString()) {
   throw 'Subscription or tenant mismatch. Stop before deploying.'
}
az group create --subscription $sub --name $rg --location $location --output none

$stageNames = @(
   '00-foundation', '10-workloads', '20-alerting', '30-security-posture',
   '40-optional-advanced', '41-sentinel-content', '50-ai', '60-sre-agent',
   '70-observability-agent'
)
$stageParameterDirectory = Join-Path ([IO.Path]::GetTempPath()) ('azure-monitor-lab-stages-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stageParameterDirectory
$stageParameterFiles = @{}
foreach ($stage in $stageNames) {
   $schema = Get-Content "./infra/stages/$stage.json" -Raw | ConvertFrom-Json -AsHashtable
   $parameters = @{}
   foreach ($name in $schema.parameters.Keys) {
      if ($sourceParameters.ContainsKey($name)) { $parameters[$name] = $sourceParameters[$name] }
   }
   foreach ($name in $schema.parameters.Keys) {
      if (-not $parameters.ContainsKey($name) -and -not $schema.parameters[$name].ContainsKey('defaultValue')) {
         throw "Missing required parameter '$name' for $stage."
      }
   }
   $parameterFile = Join-Path $stageParameterDirectory "$stage.parameters.json"
   if (-not $IsWindows) {
      New-Item -ItemType File -Path $parameterFile | Out-Null
      [IO.File]::SetUnixFileMode($parameterFile, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
   }
   @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
      ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterFile
   $stageParameterFiles[$stage] = $parameterFile
}
```

The bootstrap projects only the parameters accepted by each stage and preserves secure values or ARM Key Vault references in private temporary files. Do not pass the complete main parameters file directly to a stage template. Keep the config, generated files, and temporary directory private. If editing Bicep, rebuild the corresponding JSON schema too, as described in [the Terraform guide](DEPLOY-TERRAFORM-STEP-BY-STEP.md#regenerating-stage-templates-from-bicep).

Config stage toggles select one-shot/Terraform stages; they do not execute these Bicep stage calls. Run only the stages you want. Rerun the bootstrap block after changing shared config. Keep the same resource group, prefix, and VM-enable settings across dependent stages.

### Stage A deploy

```powershell
az deployment group create `
   --subscription $sub `
   --resource-group $rg `
   --name stage-00-foundation `
   --template-file ./infra/stages/00-foundation.bicep `
   --parameters "@$($stageParameterFiles['00-foundation'])" `
   --mode Incremental `
   --confirm-with-what-if `
   --output none
```

This deploys [foundation only](../infra/stages/00-foundation.bicep). `--confirm-with-what-if` previews the changes and asks for confirmation before deployment. There is no AKS node pool or Web App in Stage A.

### Stage B deploy

```powershell
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-10-workloads `
   --template-file ./infra/stages/10-workloads.bicep `
   --parameters "@$($stageParameterFiles['10-workloads'])" `
   --mode Incremental --confirm-with-what-if --output none
./scripts/post-staged-deploy.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -EnableStageE $false
```

Completion publishes and verifies the App Service, initializes the Control Center and approved operator access, applies AKS workloads, and creates the summary rule. It prepares available AI agents without traffic and validates any deployed SRE Agent. Stage E is explicitly off here because it has not been deployed yet. For noninteractive setup, pass approved user IDs through `-ConsoleOperatorObjectIds`; otherwise existing operators or the signed-in user are used.

### Stage C deploy

```powershell
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-20-alerting `
   --template-file ./infra/stages/20-alerting.bicep `
   --parameters "@$($stageParameterFiles['20-alerting'])" `
   --mode Incremental --confirm-with-what-if --output none
```

This stage requires the VMSS administrator password and notification email from the private inputs, even when the optional standalone VMs are disabled.

### Stage D deploy

Ensure AzureActivity is routed to the actual suffixed central LAW before validating the security scenarios:

```powershell
$workspaces = az monitor log-analytics workspace list --subscription $sub -g $rg -o json | ConvertFrom-Json
$centralLaw = $workspaces | Where-Object { $_.name -like "law-$prefix-central-*" } | Select-Object -First 1
if (-not $centralLaw.id) { throw 'Central workspace not found.' }
$logs = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
az monitor diagnostic-settings subscription create --subscription $sub --name "$prefix-activity-to-law" --location global --workspace $centralLaw.id --logs $logs
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-30-security-posture `
   --template-file ./infra/stages/30-security-posture.bicep `
   --parameters "@$($stageParameterFiles['30-security-posture'])" `
   --mode Incremental --confirm-with-what-if --output none
```

The security template reuses the Stage A LAW and Stage C action group. It does not deploy workloads or enable a SIEM.

### Stage E deploy

```powershell
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-40-optional-advanced `
   --template-file ./infra/stages/40-optional-advanced.bicep `
   --parameters "@$($stageParameterFiles['40-optional-advanced'])" `
   --mode Incremental --confirm-with-what-if --output none
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-41-sentinel-content `
   --template-file ./infra/stages/41-sentinel-content.bicep `
   --parameters "@$($stageParameterFiles['41-sentinel-content'])" `
   --mode Incremental --confirm-with-what-if --output none
./scripts/post-staged-deploy.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $prefix -EnableStageE $true
```

If Stage 40 already succeeded with Sentinel enabled, resume at Stage 41, then run the completion script. Stages A through D do not need to be rerun.

Stage E's `enableAi` value follows `stages.enableStageAI` from the central config; enable it only when Stage AI already exists. Sentinel onboarding and the optional DCRs follow the supplied parameters or stage defaults; review the preview and billing implications. Run `41-sentinel-content` only when Sentinel is enabled. Completion configures the Service Group and verifies SLI prerequisites. Create the preview SLIs in the portal using the printed handoff.

Sentinel uses two deployments because its analytics-rule provider cannot preview a rule until the workspace is already onboarded. Stage E first creates the onboarding state, then `41-sentinel-content` previews and creates the dependent demo rule with normal provider validation.

### Stage AI deploy (optional)

Deploy after Stage A. Verify Model Router version availability for `aiLocation` before opting in; the default is `swedencentral`. If Stage B already exists, refresh its package, inventory, and agent permissions before starting optional traffic:

```powershell
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-50-ai `
   --template-file ./infra/stages/50-ai.bicep `
   --parameters "@$($stageParameterFiles['50-ai'])" `
   --mode Incremental --confirm-with-what-if --output none
$apps = az webapp list --subscription $sub --resource-group $rg -o json | ConvertFrom-Json
$webApp = $apps | Where-Object { $_.name -like "app-$prefix-*" } | Select-Object -First 1
if ($webApp) {
   ./scripts/deploy-webapp.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -WebAppName $webApp.name
}
./scripts/setup-ai.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -NamePrefix $prefix
```

The refresh uses [the existing app deployment helper](../scripts/deploy-webapp.ps1), which configures console access and verifies the new publication without reapplying AKS workloads. Its bootstrap prepares agents with `-SkipTraffic`. The final [AI setup](../scripts/setup-ai.ps1) reuses those agents and always starts a finite background batch, default 150 conversations. Add `-SkipTraffic` there to prepare agents without model traffic. The [Cloud Shell AI wrapper](../scripts/setup-ai-cloud-shell.ps1) offers the same background behavior with core ARM discovery.

Without Stage B, the refresh is skipped and the standalone AI scenario still works. Adding Stage B later initializes its console normally. To add the AI tier to an existing Stage E health model, set `stages.enableStageAI` to `true` in `lab.config.json`, rerun the bootstrap block, then rerun the native Stage 40 command above. Do not deploy Stage E solely for an A+AI lab.

The worker prints its PID and log/status paths. Keep the deployment host and Azure CLI sign-in available until it finishes; Cloud Shell/CI termination can stop it. Startup is not evidence of successful model responses. See [Stage AI traffic behavior](STAGE-AI.md#6-enable--run).

### Stage SRE Agent deploy (optional)

Deploy after Stage A. The template creates the `swedencentral` agent, managed identities, monitoring connectors, and RBAC. Subscription-scope role-assignment permission is required. Validate the deployed resource before refreshing any existing console:

```powershell
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-60-sre-agent `
   --template-file ./infra/stages/60-sre-agent.bicep `
   --parameters "@$($stageParameterFiles['60-sre-agent'])" `
   --mode Incremental --confirm-with-what-if --output none
./scripts/setup-sre-agent.ps1 -SubscriptionId $sub -ResourceGroup $rg
$apps = az webapp list --subscription $sub --resource-group $rg -o json | ConvertFrom-Json
$webApp = $apps | Where-Object { $_.name -like "app-$prefix-*" } | Select-Object -First 1
if ($webApp) {
   ./scripts/deploy-webapp.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -WebAppName $webApp.name
}
```

An A+SRE deployment needs no Web App or AKS, so it uses [the standalone validator](../scripts/setup-sre-agent.ps1), not the Stage B completion wrapper. With B and AI present, the refresh enables the Control Center's SRE MCP Assistant. The validator is read-only unless explicitly asked to grant missing roles; it does not start an investigation.

Follow [Stage SRE Agent](STAGE-SRE-AGENT.md) only when demonstrating the separate portal investigator and Review-mode response-plan scenarios. Those are not required for Control Center MCP questions and approved operations.

### Stage Observability Agent deploy (optional)

Deploy after Stage A. The template creates the agent and dedicated Azure Monitor workspace in a supported region, monitors the Stage A Application Insights resource, and assigns least-privilege RBAC. Subscription-scope role-assignment permission is required. Automatic deep investigation remains off unless explicitly enabled.

```powershell
az deployment group create `
   --subscription $sub --resource-group $rg --name stage-70-observability-agent `
   --template-file ./infra/stages/70-observability-agent.bicep `
   --parameters "@$($stageParameterFiles['70-observability-agent'])" `
   --mode Incremental --confirm-with-what-if --output none
./scripts/setup-observability-agent.ps1 -SubscriptionId $sub -ResourceGroup $rg
$apps = az webapp list --subscription $sub --resource-group $rg -o json | ConvertFrom-Json
$webApp = $apps | Where-Object { $_.name -like "app-$prefix-*" } | Select-Object -First 1
if ($webApp) {
   ./scripts/deploy-webapp.ps1 -SubscriptionId $sub -TenantId $tenant -ResourceGroup $rg -WebAppName $webApp.name
}
```

An A+Observability Agent deployment can correlate and investigate Application Insights signals without a Web App. Stage B adds the Control Center's deterministic broken/fixed scenario runner. Follow [Stage Observability Agent](STAGE-OBSERVABILITY-AGENT.md) for supported regions, cost and privacy boundaries, validation, and the demo workflow.

After the final stage in the current session, remove the temporary parameter files:

```powershell
Remove-Item -LiteralPath $stageParameterDirectory -Recurse -Force
```

## 6) Stage boundaries and reruns

The stage templates resolve prior-stage resources using the resource group and shared prefix. They do not accept the full-lab parameter set or redeploy earlier workloads. Keep shared naming and VM-enable settings consistent. When rerunning an earlier stage, inspect its what-if and rerun its documented completion step if app configuration or workloads changed. Incremental deployment does not remove resources just because a stage or optional parameter is omitted.

## 7) Validation checklist per stage

After each stage:
1. Inspect the deployment named `stage-<template-stem>`, for example `stage-00-foundation`, in the selected resource group.
2. Verify expected resources exist.
3. Run at least one saved query relevant to that stage.
4. For security stage, run:

```kql
AzureActivity
| where TimeGenerated > ago(1d)
| summarize count()
```

If count is zero, security-posture scenarios 47/48/49 will not fire.

## 8) Tearing down the lab

When done, run the teardown script. It first disables LAW replication and removes nested DCR associations, DCRs, and DCEs in dependency order, then starts the resource-group deletion. Azure-managed DCEs that reject direct deletion are left for the LAW/RG cascade.

### Step 1 - Run the teardown wrapper

```powershell
$sub='<your-subscription-id>'
$rg='rg-azure-monitor-lab'   # set this to the RG where you deployed the lab; this is the default
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
./scripts/teardown.ps1 -ResourceGroup $rg -Yes
```

`teardown.ps1` validates the subscription guardrail, disables LAW replication, removes nested DCR associations and other monitoring dependencies, removes the tenant-scoped SLI and Service Group artifacts, and then deletes the resource group. This works for both staged Bicep and one-shot Bicep deployments.

### Step 2 - Clean up artifacts that live outside the RG

A few resources are subscription-scoped or live in `NetworkWatcherRG` and survive RG deletion.

1. Soft-deleted Log Analytics workspaces (14-day grace period; names stay reserved):

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

5. Custom role definition from Stage D (`AMLAB - Granular Log Reader`). Auto-removed once no scopes reference it; force-delete if it lingers:

```powershell
az role definition list --custom-role-only true --subscription $sub --query "[?starts_with(roleName,'AMLAB - Granular Log Reader')]" -o table
# az role definition delete --name "AMLAB - Granular Log Reader" --subscription $sub
```

6. Sentinel onboarding (if Stage E enabled it) lives on the LAW, so it goes with the RG. No extra action needed.

### Step 4 - Confirm

```powershell
az group exists -n $rg --subscription $sub   # false once the async delete completes
```
