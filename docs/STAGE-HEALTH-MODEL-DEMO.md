# Health Model Demo (optional)

This stage brings the original [Café tutorial](HEALTH-MODEL-TUTORIAL.md) and the lab user-flow model into the lab's own resource group. The core lab and its existing workload Health Model remain unchanged. The stage defaults **off**.

For a presenter-ready walkthrough of the deployed stage, follow [scenario 81: user-flow Health Models, failure and recovery](DEMO-SCENARIOS.md#s81). It includes a read-only tour and an optional, scoped Café order-failure exercise with recovery verification.

## What it adds

- A Node.js Café on a dedicated Linux Standard S1 App Service plan, with private Storage access, Blob menu/orders and Queue notifications.
- Dedicated monitoring, availability tests and explicit Azure Monitor instrumentation.
- `hm-lab-cafe`: 13 entities, 12 relationships and two reusable metric definitions, including failed-order request signals.
- `hm-amlab-flows`: 21 entities, 20 relationships and four reusable definitions, backed by the existing lab workloads.
- Model-scoped Control Center read/report permissions and both model targets in the Health Model tab.

The original contribution and tutorial are by [@abossard](https://github.com/abossard), from [PR #42](https://github.com/Azure-Samples/azure-monitor-lab/pull/42). Its commits are retained.

## Enable

Set `advancedConfiguration.stageToggles.enableStageHealthModelDemo` to `true` in your private `lab.config.json`, then use the normal [scripted deployment](../README.md#option-2-scripted-deployment-recommended). Stages A, B, C and E must also be enabled; E supplies the core availability test used by the flow model. For the portal, select **Enable Health Model Demo** under **Optional stages**, then run the README's Cloud Shell completion command.

Terraform uses `enable_stage_health_model_demo = true`. Run config sync before planning and review the plan. Apply invokes [normal staged completion](DEPLOY-TERRAFORM-STEP-BY-STEP.md) automatically; do not run a second wrapper after a successful apply. Compiled templates are committed; no Health Models CLI extension is required for normal stage completion.

For staged Bicep, deploy the dedicated [stage 80 template](../infra/stages/80-health-model-demo.bicep) only after stages A, B, C and E. Use the template's explicit resource-ID parameters with the existing core outputs; do not create a second foundation or workload deployment. Defaults derive standard staged names. When adopting a one-shot lab, pass its actual `availabilityTestName` rather than the staged default.

After deploying those prerequisite stages, continue in the same PowerShell session with the [Bicep guide's input bootstrap](DEPLOY-BICEP-STEP-BY-STEP.md) already loaded:

```powershell
./scripts/sync-config.ps1
$sourceParameters = (Get-Content ./infra/main.parameters.json -Raw | ConvertFrom-Json -AsHashtable).parameters
. ./scripts/staged-deploy-helpers.ps1
Invoke-LabStage -Stage 80-health-model-demo
./scripts/post-staged-deploy.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $sourceParameters.namePrefix.value
```

The shared helper previews stage 80 and requires confirmation before deployment. Café hosting defaults to **France Central** across one-shot, portal, staged Bicep, Terraform and standalone tutorial deployments. Both health models remain in **Sweden Central**, independently of the workload region, because preview region support is limited. Stage 80 does not inherit the core lab's `location`; use `-Overrides @{ location = '<region>' }` to explicitly preserve an existing Café deployment's region. One-shot uses `healthModelDemoCafeLocation`, and Terraform uses `health_model_demo_cafe_location`.

Config sync preserves `healthModelDemoCafeLocation` and
`healthModelDemoCafeMonitoringReaderAssignmentName` from the private config
(`advancedConfiguration.other` for grouped configs) in both deployment formats.
The Bicep stage helper maps the reader-assignment override to Stage 80's
`cafeMonitoringReaderAssignmentName`; Terraform uses
`health_model_demo_cafe_monitoring_reader_assignment_name`. Preserve these values
when adopting an existing Cafe instead of changing its region or duplicating RBAC.

Scripted deployment preflight separately checks the Café's configured App Service region and **Standard S1** quota when the demo is enabled, independently of the core app's region and tier. Standard quota does not use the Basic B1 quota, but offering/quota checks still do not guarantee live capacity. Changing defaults does not move existing resources: if a Café was already deployed in another region, retain its region override or plan an explicit migration; do not redeploy the same resource names in a different region as an in-place move.

The four demo outputs are available from the stage deployment and Terraform; the full-lab template preserves its existing output contract.

The subscription must support the Cloud Health preview and register `Microsoft.CloudHealth`. Deployment requires resource-write permissions plus custom-role and role-assignment writes (for example Owner, or Contributor with User Access Administrator). Completion also needs query access to the Café workspace. Keep the existing core-stage and tenant prerequisites.

## Complete or repair publication

Normal completion runs this automatically when the stage is enabled or discovered. To rerun only its completion:

```powershell
./scripts/setup-health-model-demo.ps1 -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -NamePrefix $namePrefix
```

Completion publishes the locked Café source using ZipDeploy/Oryx, connects both existing models to the console, reads the current menu, submits and retrieves one ordinary order, and waits for actual `AppRequests` and `AppDependencies` records. The account needs workspace query access as well as deployment access. It fails explicitly if required resources, publication, storage operations or telemetry are missing. Allow up to ten minutes for telemetry ingestion.

Rerunning **completion** does not rebuild models, overwrite entity edits, change report permissions or inject faults. Republishing the app can briefly affect availability signals. Infrastructure redeployment remains declarative: edits to template-managed model properties can be overwritten; keep lasting changes in source.

Open **Control Center > Health Model** and switch between **Lab user flows** and **Café tutorial**. A zero-failure signal alone does not establish that telemetry is working. Health evaluation can lag behind successful requests.

## Costs and lifecycle

The Standard S1 plan costs more than Basic B1; private networking, Storage, monitoring and retained data also add charges. An existing Café plan in the same region is upgraded to S1 on redeployment. **Stop Lab** stops both web apps but does not stop App Service plan or retained-data billing. **Start Lab** starts both. The usual lab teardown removes the demo resources in the same resource group; never delete Azure Monitor-managed groups directly.

Setting the stage back to `false` does **not** remove its resources or stop their billing. Bicep incremental deployments retain them; Terraform removes only the stage's deployment-history record, not its nested workloads, models or RBAC. Use explicit lab teardown for cleanup. No fault injection runs during deployment or completion. Use the standalone tutorial's break/fix exercises only when you intentionally want to demonstrate failures.

The [standalone tutorial](HEALTH-MODEL-TUTORIAL.md) remains available without deploying this lab; do not run its model builder merely to repair stage publication, because that builder replaces model entities.
