# Health Model Demo (optional)

This stage brings the original [Café tutorial](HEALTH-MODEL-TUTORIAL.md) and the lab user-flow model into the lab's own resource group. The core lab and its existing workload Health Model remain unchanged. The stage defaults **off**.

## What it adds

- A Node.js Café on a dedicated Linux B1 App Service plan, with private Storage access, Blob menu/orders and Queue notifications.
- Dedicated monitoring, availability tests and explicit Azure Monitor instrumentation.
- `hm-lab-cafe`: 13 entities, 12 relationships and two reusable metric definitions, including failed-order request signals.
- `hm-amlab-flows`: 21 entities, 20 relationships and four reusable definitions, backed by the existing lab workloads.
- Model-scoped Control Center read/report permissions and both model targets in the Health Model tab.

The original contribution and tutorial are by [@abossard](https://github.com/abossard), from [PR #42](https://github.com/Azure-Samples/azure-monitor-lab/pull/42). Its commits are retained.

## Enable

Set `advancedConfiguration.stageToggles.enableStageHealthModelDemo` to `true` in your private `lab.config.json`, then use the normal [scripted deployment](../README.md#option-2-scripted-deployment-recommended). Stages A, B, C and E must also be enabled; E supplies the core availability test used by the flow model. For the portal, select **Enable Health Model Demo** under **Optional stages**, then run the README's Cloud Shell completion command.

Terraform uses `enable_stage_health_model_demo = true`. Run config sync before planning, review the plan, and run the [normal staged completion](DEPLOY-TERRAFORM-STEP-BY-STEP.md) after applying. Compiled templates are committed; no Health Models CLI extension is required for normal stage completion.

For staged Bicep, deploy the dedicated [stage 80 template](../infra/stages/80-health-model-demo.bicep) only after stages A, B, C and E. Use the template's explicit resource-ID parameters with the existing core outputs; do not create a second foundation or workload deployment. Defaults derive standard staged names. When adopting a one-shot lab, pass its actual `availabilityTestName` rather than the staged default.

After deploying those prerequisite stages, continue in the same PowerShell session with the [Bicep guide's input bootstrap](DEPLOY-BICEP-STEP-BY-STEP.md) already loaded:

```powershell
./scripts/sync-config.ps1
. ./scripts/staged-deploy-helpers.ps1
Invoke-LabStage -Stage 80-health-model-demo
./scripts/post-staged-deploy.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix $sourceParameters.namePrefix.value
```

The shared helper previews stage 80 and requires confirmation before deployment. It uses your configured `location` for Café hosting. One-shot, portal and Terraform deployments default Café hosting to Sweden Central; the preview models also default there. The four demo outputs are available from the stage deployment and Terraform; the full-lab template preserves its existing output contract.

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

The B1 plan, private networking, Storage, monitoring and retained data add charges. **Stop Lab** stops both web apps but does not stop App Service plan or retained-data billing. **Start Lab** starts both. The usual lab teardown removes the demo resources in the same resource group; never delete Azure Monitor-managed groups directly.

Setting the stage back to `false` does **not** remove its resources or stop their billing. Bicep incremental deployments retain them; Terraform removes only the stage's deployment-history record, not its nested workloads, models or RBAC. Use explicit lab teardown for cleanup. No fault injection runs during deployment or completion. Use the standalone tutorial's break/fix exercises only when you intentionally want to demonstrate failures.

The [standalone tutorial](HEALTH-MODEL-TUTORIAL.md) remains available without deploying this lab; do not run its model builder merely to repair stage publication, because that builder replaces model entities.
