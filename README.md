<h1 align="center">
  <img src="docs/azure-monitor-lab-logo.svg" alt="Azure Monitor Lab" width="680">
</h1>

A self-contained demo centered on Azure Monitor, AI, Azure Copilot Observability Agent, and Azure SRE Agent, with optional Microsoft Sentinel and Microsoft Fabric Real-Time Intelligence scenarios. Everything runs from a single config file that stays out of git, so you can stand the whole thing up in your own subscription and tear it back down when you're finished.

- One primary resource group: Azure resources land in `rg-azure-monitor-lab`; AKS has a managed resource group, and Fabric workspace items and Entra registrations are tenant-scoped.
- Two ways to deploy it: Bicep or Terraform.
- Three ways to deploy it: a [Deploy to Azure](#option-1-deploy-to-azure-portal-no-local-setup) portal wizard, a scripted one-shot deployment using PowerShell, or a five-stage core workshop with optional AI, SRE Agent, Observability Agent, and Fabric extensions.
- **80 numbered demo scenarios**, plus a 30-second introductory pitch, covering Azure Monitor, agentic-application observability, customer application dependencies, GitHub Copilot CLI, Azure SRE Agent, and Fabric Real-Time Intelligence.

It's built for demos, microhacks, and hackathons. Deploy it, poke around, break it, restore it, and tear it down.

## Use The Lab

| Experience | Start here |
|---|---|
| **Guided Scenarios** | Follow the existing [scenario walkthroughs](docs/DEMO-SCENARIOS.md) for the story, Azure portal steps, queries, and expected results. |
| **Lab Control Center** | Check infrastructure health, generate traffic, try Foundry agents, and perform approved SRE MCP operations. Open the [Control Center guide](docs/LAB-CONTROL-CENTER.md) for screenshots, access requirements, and linked scenarios. |

These are complementary entry points into the same lab. The Control Center links to the guided scenarios; it does not replace their setup or walkthroughs.

### Scenario coverage

| Scenarios | What you can demonstrate |
|---|---|
| [1-52](docs/DEMO-SCENARIOS.md#s1) | Workbooks, VM and AKS insights, Application Insights, OpenTelemetry, alerts, automation, networking, data routing, cost controls, security, and workload Health Models |
| [53](docs/DEMO-SCENARIOS.md#s53) | GenAI token, trace, and cost observability |
| [54-59](docs/DEMO-SCENARIOS.md#s54) | Azure SRE Agent readiness, investigation, change correlation, alert merging, and recovery verification |
| [60](docs/DEMO-SCENARIOS.md#s60) | Cross-stack operations in the Lab Control Center |
| [61-67](docs/DEMO-SCENARIOS.md#s61) | Agentic failures, customer impact, AI cost spikes, and Observability Agent triage |
| [68-73](docs/DEMO-SCENARIOS.md#s68) | Evidence-first Copilot investigations, end-to-end Application Insights incidents, customer journeys, broken-slot rollback, and real SQL / Service Bus / Functions dependencies |
| [74-80](docs/DEMO-SCENARIOS.md#s74) | Fabric streaming, Eventhouse queries, Real-Time Dashboards, business-event correlation, capacity monitoring, suspend/resume, and Azure Monitor mirroring (preview) |

Optional scenarios need their corresponding stages, permissions, and sometimes manual preparation; deploying the core lab does not enable every scenario. Start with the [workload-based scenario index](docs/DEMO-SCENARIOS.md#demo-scenarios--organized-by-workload) to choose a demo path.

## Architecture

Workloads feed a shared Azure Monitor telemetry backbone for dashboards, alerts, and agent-assisted investigation. Optional Microsoft Fabric extends it with streaming analytics and Azure Monitor mirroring (preview), without replacing operational monitoring. See the [resource inventory](docs/REFERENCE.md#what-gets-deployed) and [Fabric guide](docs/STAGE-FABRIC.md) for details.

[![Azure Monitor Lab architecture: operational telemetry and response, customer application, and optional Event Hubs to Fabric Real-Time Intelligence analytics](docs/architecture-overview-sre.svg)](docs/architecture.drawio)

## Prerequisites

- Azure CLI (`az`) 2.60 or later, logged in with `az login`
- `kubectl` (any recent version)
- Bicep CLI (bundled with `az` 2.20+), or Terraform 1.6+ if you take the Terraform path
- PowerShell 7+
- .NET 8 SDK for publishing the Control Center
- Azure and Microsoft Entra permissions to deploy the lab and configure Control Center access. See [console deployment prerequisites](workloads/webapp/LAB-OPERATIONS.md#prerequisites) for the required roles.
- Optional AI stage: [Python 3.10+](https://www.python.org/downloads/)
- Optional SRE Agent stage: [npm](https://docs.npmjs.com/downloading-and-installing-node-js-and-npm) and [tar](https://www.gnu.org/software/tar/)
- Optional Fabric stage: Fabric enabled in the tenant, workspace creation/administration and capacity administration permissions, and `fabricAdminEmail` set to a Microsoft Entra user UPN in that tenant. Automated source authorization also needs Azure RBAC administration at the event hub and source Log Analytics workspaces, plus custom-role administration. Default mirroring requires a tenant administrator to enable the preview; Azure Monitor table/row/column protections do not carry into Fabric, so review workspace access first. Capacity Metrics needs separate installation and eligible Power BI licensing/OAuth. See [Fabric prerequisites and cost caveats](docs/STAGE-FABRIC.md#prerequisites).

## Deploy

> Recommended region: `northeurope` (the default), which has the widest feature availability. The Health Model preview and optional GenAI / AI stage (Microsoft Foundry and its models) go to `swedencentral`. App Service and its co-located diagnostic Storage and Event Hub dependencies use configurable `appServiceLocation` (default `westeurope`) so subscriptions closed to new customers in that region can select another supported region.

### Option 1: Deploy to Azure (portal, no local setup)

> The stable `main` button does not yet include this branch's Fabric stage. To test Fabric, use `feature/fabric-stage` with Option 2, or supply that branch's raw ARM template and UI definition URLs in a Custom deployment.

<div align="center">

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure-Samples%2Fazure-monitor-lab%2Fmain%2Finfra%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure-Samples%2Fazure-monitor-lab%2Fmain%2Finfra%2FcreateUiDefinition.json)

</div>

Opens a guided Custom deployment wizard in the Azure Portal, where you enter every value in the UI and don't need any local files. Sensible defaults are pre-filled throughout; the only things you have to supply are an alert email and a VM admin password.

This button deploys the stable `main` templates.

| Tab | You provide |
|---|---|
| **Basics** | Resource group (recommended `rg-azure-monitor-lab`), Region (recommended `northeurope`), name prefix, alert email, VM admin username + password |
| **Workloads** | Deploy Linux/Windows VMs, VM size, AKS node size + count |
| **Monitoring & cost** | Daily ingestion cap, Sentinel, platform-logs/metrics-export DCRs, LAW replication |
| **Advanced** | Owner tag, optional Grafana administrator object ID, App Service sample repo, optional SIEM/Teams webhook, optional AI, SRE Agent, and Observability Agent stages |

After the portal deployment succeeds, open **[Cloud Shell](https://learn.microsoft.com/en-us/azure/cloud-shell/get-started/ephemeral?tabs=azurecli#start-cloud-shell)** in the Azure portal, select **PowerShell**, and run the commands below. The Cloud Shell wrapper discovers the deployed resources, publishes the App Service sample, installs the AKS and Health Model demo components, and prepares the identity and RBAC prerequisites for the SLI demo without requiring optional Azure CLI extensions. It attempts to verify the Managed Prometheus source metrics and continues with a warning if Cloud Shell cannot request that token audience:

```powershell
git clone --branch main https://github.com/Azure-Samples/azure-monitor-lab.git
cd azure-monitor-lab
$tenantId = Read-Host 'Tenant ID'
$subscriptionId = Read-Host 'Subscription ID'
$resourceGroup = Read-Host 'Resource group name'
./scripts/post-cloud-shell-deploy.ps1 -TenantId $tenantId -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
```

If you enabled the optional AI stage and want to generate AI telemetry, run this next from the same Cloud Shell session. Skip it when AI is disabled:

```powershell
./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -NamePrefix amlab
```

After the wrapper succeeds, deployment is complete. Continue with the [manual scenario setup](docs/POST-DEPLOYMENT.md) for only the scenarios you plan to present.

For a portal deployment using the `feature/fabric-stage` templates, run `git switch feature/fabric-stage` after cloning and before running the completion wrappers above. With Fabric enabled, also run `./scripts/setup-fabric-cloud-shell.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup` to complete its tenant-scoped items. Follow the [Fabric completion checklist](docs/STAGE-FABRIC.md#after-deployps1-checklist) and suspend F2 when idle.

### Option 2: Scripted one-shot (Bicep / Terraform, full control)

```powershell
# 1. Clone the repo and enter it
git clone --branch main https://github.com/Azure-Samples/azure-monitor-lab.git
cd azure-monitor-lab

# Fabric preview only: omit this switch when deploying stable main.
git switch feature/fabric-stage

# 2. Copy the template and fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, ...
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json
# Save your changes and close Notepad before continuing.
# One-shot ignores enableStageA-E; AI, SRE Agent, Observability Agent, and customer scenarios remain optional.
# Fabric is also opt-in: stageToggles.enableStageFabric plus fabricAdminEmail.

# 3. Deploy (deploy.ps1 calls sync-config.ps1 for you)
./scripts/deploy.ps1

# Or target a custom resource group / region (created if it doesn't exist yet):
./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
```

Defaults: resource group `rg-azure-monitor-lab`, region `northeurope`. Override them with `-ResourceGroup` / `-Location` (explicit args win over `lab.config.json`, then defaults). The group is created or reused. Infrastructure provisioning, native packaging, and the cloud runner build can take tens of minutes. A successful run includes console sign-in, health, the eight-operation Azure runner, and access to selected optional agents. See [deployment reference](docs/REFERENCE.md#deploy) for config and guardrails.

<details>
<summary><b>Pre-flight check</b> (region SKU / quota validation before deploy)</summary>

Before creating anything, `deploy.ps1` runs [`scripts/preflight-check.ps1`](scripts/preflight-check.ps1), which checks in about 15 seconds that every VM SKU, vCPU quota, and PaaS resource type the lab needs is actually available in the region you picked for your subscription. It fails fast with a PASS/WARN/FAIL table instead of blowing up 20 minutes into the deployment. You can run it on its own to vet a region before committing (`./scripts/preflight-check.ps1 -Location westeurope`), or skip it with `./scripts/deploy.ps1 -SkipPreflight`.

The pre-flight checks *availability and quota*, not *live service capacity*. Transient, region-wide shortages like AKS `AksCapacityHeavyUsage` have no pre-check API and only surface at deploy time. If one hits, `deploy.ps1` catches it and points you to the fix: deploy to another region (`-Location northeurope`) or retry (`-MaxDeployRetries 3`), since capacity frees up as other clusters are deleted.

</details>

A successful `deploy.ps1` run completes the selected setup. Continue with the [manual scenario setup](docs/POST-DEPLOYMENT.md) for only the scenarios you plan to present.

For Fabric, set `stageToggles.enableStageFabric` to `true` and supply `fabricAdminEmail`. `deploy.ps1` runs setup automatically. Review `fabricAutomation` in the [config template](lab.config.json.example) for mirroring, sample data, workspace naming, verification timeout, and daily suspension settings. Resolve any reported prerequisites and verify ingestion using the [Fabric checklist](docs/STAGE-FABRIC.md#after-deployps1-checklist). Setup can be rerun safely; it reuses existing items and preserves edited dashboards.

### Option 3: Staged workshop (progressive deployment)

Use the staged approach when you want to pause between capabilities, walk through the lab with an audience, or deploy only the stages needed for a particular demo. Stages A to E can be toggled in `lab.config.json`. The optional AI, SRE Agent, Observability Agent, and Fabric stages have separate toggles and prerequisites. Bicep deploys SRE Agent with `infra/stages/60-sre-agent.bicep`; Terraform deploys the compiled stage when `enable_stage_sre_agent = true`.

Step-by-step guides:

- Optional [Stage Fabric](docs/STAGE-FABRIC.md) uses `infra/stages/60-fabric.bicep` or Terraform's `enable_stage_fabric`; its end-to-end stream requires Stage A's Event Hub. For staged Bicep, deploy Fabric before Stage E, or rerun Stage E with `enableFabric=true` to include capacity health in the Health Model. Terraform orders this dependency automatically.
- [Bicep staged deployment](docs/DEPLOY-BICEP-STEP-BY-STEP.md)
- [Terraform staged deployment](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md)

Each staged guide includes the required completion command for every selected stage. After completion, use the [manual scenario setup](docs/POST-DEPLOYMENT.md) for only the scenarios you plan to present.

### Lab Control Center

The [Lab Control Center](docs/LAB-CONTROL-CENTER.md) runs in the lab's existing **Web App**. Use it to control the lab from your browser, including starting, breaking, and restoring it.

Retrieve its URL in PowerShell or Azure Cloud Shell (PowerShell):

```powershell
$subscriptionId = Read-Host 'Subscription ID'
$resourceGroup = Read-Host 'Resource group name'
az webapp list --subscription $subscriptionId --resource-group $resourceGroup --query "[].defaultHostName" --output tsv | ForEach-Object { "https://$_" }
```

## Cost and lifecycle

Fabric F2 adds billable active capacity hours, plus possible OneLake storage and other usage charges. The branch's indicative estimate is **USD 0.36/hour** (about **USD 8.64 per 24 active hours**); verify current regional pricing before deploying. F2 is a cost-controlled light demo choice, below Microsoft's documented F4 recommendation for Eventstreams. Both Log Analytics workspaces default to **3 GB/day each**, not a shared budget or total-cost limit.

Fabric setup enables daily **20:00 UTC** suspension unless explicitly disabled. This fixed schedule is **not an idle detector**: it interrupts active queries and ingestion and does not automatically resume capacity. Run `./scripts/suspend-fabric.ps1` when idle and `./scripts/resume-fabric.ps1` before the next Fabric demo; `./scripts/start-the-lab.ps1 -Wait` also resumes F2. See [Fabric setup, permissions and lifecycle](docs/STAGE-FABRIC.md).

> [!WARNING]
> **Ballpark:** default Stages A-E lab: **EUR 6-10/day** (EUR 180-300/month). Everything enabled with light Foundry and agent use: **EUR 10-25/day** (EUR 300-750/month), assuming an eligible SRE Agent trial and automatic Observability Agent investigations remain off. These September 2026 public-retail estimates are not quotes; heavier token/AAC use, post-trial SRE Agent charges, region, agreement, telemetry, and traffic can exceed the range. See the [cost guide](docs/COST-GUIDE.md).

> [!IMPORTANT]
> **Control costs:** VMs auto-shutdown at **23:00 CET/CEST**; VM notifications are suppressed until **07:00**. When idle, use **Control Center → Lab Operations → Stop Lab**. Fixed services and retained data still bill. When finished, tear down the lab and verify deletion.

When the lab is no longer needed, set `$rg` to the resource group where you deployed the lab, then run the command below. If you used the default configuration, use `rg-azure-monitor-lab`.

```powershell
$rg = "rg-azure-monitor-lab"   # change this to the RG used for your deployment
./scripts/teardown.ps1 -ResourceGroup $rg -Yes   # deletes the whole resource group
```

For Fabric, the teardown script also attempts to remove the tenant-scoped workspace and its items, generated mirror connections, and source-scoped mirroring permissions before deleting the resource group. Check its output and verify cleanup: deleting the Azure resource group or running `terraform destroy` alone does not remove tenant-scoped Fabric items. Use a distinct `fabricAutomation.workspaceName` for each lab to keep setup and teardown isolated. See [Fabric cleanup](docs/STAGE-FABRIC.md#suspend-and-resume).

## Documentation

| Doc | What's in it |
|---|---|
| [REFERENCE.md](docs/REFERENCE.md) | Full capability matrix · every deployed resource · demo walkthrough · cost breakdown · folder layout · optional add-ons · troubleshooting |
| [STAGE-FABRIC.md](docs/STAGE-FABRIC.md) | Optional F2 capacity, keyless Extended Eventstream, three dashboards, dual-workspace mirroring, verification, administrator prerequisites, scheduled suspension, and tenant-item cleanup |
| [COST-GUIDE.md](docs/COST-GUIDE.md) | Dated resource inventory · public-rate examples · usage formulas · optional agents · stop-versus-delete guidance |
| [Lab Control Center](docs/LAB-CONTROL-CENTER.md) | Application guide, screenshot, traffic and agent capabilities, safety boundaries, and links to the guided scenarios |
| [DEMO-SCENARIOS.md](docs/DEMO-SCENARIOS.md) | 80 numbered scenarios plus an introductory pitch, with stories, click-paths, starter prompts, and workload-based shortlists; includes [application troubleshooting](docs/DEMO-SCENARIOS.md#s72), [real customer PaaS dependencies](docs/DEMO-SCENARIOS.md#s73), and [Fabric Real-Time Intelligence](docs/DEMO-SCENARIOS.md#s74) |
| [POST-DEPLOYMENT.md](docs/POST-DEPLOYMENT.md) | Manual and optional preparation required by specific demo scenarios after deployment is complete |
| [PM feature integration guide](docs/PM-FEATURE-INTEGRATION-GUIDE.md) | End-to-end workflow and validation checklist for product managers adding new Azure features to every deployment path |
| [docs/DEPLOY-BICEP-STEP-BY-STEP.md](docs/DEPLOY-BICEP-STEP-BY-STEP.md) · [docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md) | Staged deployment tutorials |
| Stage notes: [A](docs/STAGE-A-FOUNDATION.md) · [B](docs/STAGE-B-WORKLOADS.md) · [C](docs/STAGE-C-ALERTING.md) · [D](docs/STAGE-D-SECURITY-POSTURE.md) · [E](docs/STAGE-E-OPTIONAL-ADVANCED.md) · [AI](docs/STAGE-AI.md) · [SRE Agent](docs/STAGE-SRE-AGENT.md) · [Observability Agent](docs/STAGE-OBSERVABILITY-AGENT.md) · [Fabric](docs/STAGE-FABRIC.md) | Per-stage speaker notes, including optional AI FinOps, agent evaluation, and Real-Time Intelligence stages |
| [docs/CUSTOMER-STAGE-HANDOUT.md](docs/CUSTOMER-STAGE-HANDOUT.md) | Per-stage time + cost cheat sheet |

## Contributing & license

Contributions are welcome. See [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the [Code of Conduct](.github/CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](.github/SECURITY.md).

Licensed under the [MIT License](LICENSE): free to use, modify, and redistribute (including for microhacks, hackathons, and your own demos), and provided as-is without warranty.
