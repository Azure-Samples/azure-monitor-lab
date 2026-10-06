# Lab Operations

The **Lab Operations** tab runs nine repository scripts in an independent **Azure Container Apps Job**. Normal lab deployment creates the infrastructure, builds the image in Azure, configures operator sign-in and managed-identity access, and enables the console. No GitHub App, runner repository, manual image publication, or separate enablement command is required.

The Web App prepares approvals and reads execution status. It does not execute PowerShell, Azure CLI, or Kubernetes commands inside the app process. GitHub Actions is used only for repository tests, not runtime execution.

## Available Actions

| Action | Script | Scope and effect |
|---|---|---|
| Start Lab | [start-the-lab.ps1](../../scripts/start-the-lab.ps1) | Starts stopped VMs, VMSS instances, AKS, and web apps. Waits up to 20 minutes for startup. Running resources incur charges. |
| Stop Lab | [stop-the-lab.ps1](../../scripts/stop-the-lab.ps1) | Deallocates VMs and VMSS instances, stops AKS, then stops the Web App hosting the Control Center. This reduces compute usage but does not stop fixed services, disks/IPs, retained data, telemetry, or optional-agent charges. |
| Break Lab | [break-the-lab.ps1](../../scripts/break-the-lab.ps1) | Deallocates VMs, replaces the AKS demo frontend image, changes the load-generator error rate, starts a short load job, and adds an incident annotation. |
| Restore Lab | [restore-the-lab.ps1](../../scripts/restore-the-lab.ps1) | Starts VMs and restores the known demo frontend/load-generator configuration. Adds a release annotation. This is not a rollback of arbitrary changes. |
| Start Load Ramp | [start-ramp.ps1](../../scripts/start-ramp.ps1) | Replaces the named ramp job/configuration and submits approximately 60 minutes of AKS traffic against the lab app. |
| Generate Customer Traffic | [generate-usage-traffic.ps1](../../scripts/generate-usage-traffic.ps1) | Runs 1-100 isolated Chromium users through the deployed `/customer/` journey, with concurrency 1-10 and repeat users no greater than total users. |
| Simulate High CPU | [simulate-high-cpu.ps1](../../scripts/simulate-high-cpu.ps1) | Submits fixed, self-expiring 10-minute CPU loads on both running demo VMs through Azure VM Run Command. No AKS dependency or VM restart. |
| Send Custom Logs | [send-custom-logs.ps1](../../scripts/send-custom-logs.ps1) | Ingests 1-100 sample audit events into the existing custom table. |
| Add Release Marker | [send-release-annotation.ps1](../../scripts/send-release-annotation.ps1) | Adds a marker with a 1-80 character name and Deployment or Incident category. |

No arbitrary commands, script paths, deployment, teardown, permission setup, or AI execution are exposed. Existing SRE MCP approvals and health permissions are unchanged.

### Generate Customer Traffic

Select **Generate Customer Traffic**, set the bounded user, browser-concurrency, and repeat-user values, review the exact target and parameters, then approve. The runner requires exactly one app-prefixed Web App in the resource group and a healthy `/customer/` endpoint before it opens Chromium. The generator drives real routes and UI interactions; it does not submit fabricated telemetry directly.

The default 24 users, 4 concurrent browsers, and 6 repeat users provide completed, abandoned, declined, support-assisted, cohort, variant, and repeat-session paths for [Scenario 70](../../docs/DEMO-SCENARIOS.md#s70). The operation has no automatic retry and only one Lab Operations run can be active. Container Apps Job compute, Application Insights ingestion, and retention charges apply. Usage aggregation can lag behind raw telemetry.

The runner image now includes Node.js dependencies and Chromium, so an existing environment must rebuild the operations image and republish the Web App. Rerun `deploy.ps1`, or use the normal [console upgrade](../../scripts/deploy-webapp.ps1); updating only the browser bundle is insufficient.

### Simulate High CPU

Select **Simulate High CPU**, review the fixed operation, confirm the lab resource group, and approve. The runner requires exactly one Linux and one Windows VM tagged `purpose=azure-monitor-lab` in that resource group. It checks both VMs are running and their Azure VM Agents are ready before submitting either command. Missing, stopped, ambiguous, or out-of-scope targets fail closed; run **Start Lab** first if needed.

The guest scripts target every logical CPU for 600 seconds without installing packages or changing the VM size. Linux uses independently timed workers with cleanup and a file lock; Windows uses bounded background threads and a named mutex. Guest locks prevent overlapping copies. Azure also permits only one Action Run Command at a time per VM, so another active command can reject a submission. The two submissions are asynchronous; their actual startup times can differ.

**Succeeded means both requests were submitted**, not that guest execution or alert firing was verified. A later guest failure is not reflected in the completed runner job. Check each VM's **Metrics > Percentage CPU** in Azure Monitor and the `alert-vm-cpu-high` rule. CPU load consumes burst credits on B-series VMs; exhausted credits can prevent the expected CPU level. Dynamic thresholds also need a learned baseline. Allow for metric and alert evaluation delays. The Control Center's VM health rows track heartbeats, not CPU, so they need not turn red during this test.

The load stops itself after approximately 10 minutes from guest startup, including a short Linux termination grace period. Closing the browser, cancelling the runner, or **Restore Lab** does not stop an accepted CPU command. If only one submission succeeds, that VM may continue independently; inspect both VMs before trying again. No submission is automatically retried. The operation creates no new VM or paid service, but existing compute, credits, and telemetry charges apply.

For an existing lab, use the normal [console upgrade](../../scripts/deploy-webapp.ps1) so the new Web App, runner image, and VM-scoped role assignments are deployed together. Updating only the browser bundle or pulling Git does not update Azure. Standalone script use requires explicit `-SubscriptionId`, `-TenantId`, and `-ResourceGroup`, or the matching local Azure target file; `-WhatIf` performs readiness checks without submitting guest commands.

## Approval And Progress

1. Open **Lab Operations** and verify the resource group, Azure job, and image digest.
2. Select an action and its supported parameters. **Review Operation** creates a five-minute proposal without starting a job.
3. Review the exact script, frozen parameters, target, and image. Type the resource group and approve the changes and associated Azure charges.
4. **Approve & Run** consumes that proposal once. **Run activity** shows Azure's queued, running, failed, cancelled, or completed state. An active or unresolved persisted run blocks another app-submitted operation.
5. Use **Open Azure job** for that job's execution history and cancellation controls in the portal. Refresh **Infra Health** after resources and telemetry settle.

Status refresh runs every ten seconds only while the tab and browser document are visible and a run is nonterminal. It stops after three read failures; manual refresh remains available. Progress is sanitized step metadata, not raw PowerShell output. No credentials are stored in the browser and failed or uncertain writes are never automatically resubmitted.

**Cancellation is not rollback.** A cancelled or failed runner may have made partial changes. Start commands already issued continue in Azure. A submitted ramp job continues in AKS even after the runner exits or is cancelled; stopping it requires removing that exact job through the normal operator workflow. **Stop Lab is not teardown or rollback.** It stops the lab's startable compute surfaces; it does not cancel already submitted guest commands or Kubernetes jobs, and it does not delete resources.

## Automatic Deployment

- **Scripted Bicep:** the normal [deploy.ps1](../../scripts/deploy.ps1) includes console initialization.
- **Terraform:** a successful `terraform apply -var-file stages.tfvars` with Stage B enabled includes workload publication and console initialization. Relevant source, stage, or operator changes rerun the hook.
- **Raw ARM/Bicep or portal templates:** these remain infrastructure-only. Follow the wrapper documented for the relevant [deployment option](../../README.md#deploy); it also initializes the console, with no additional console-specific setup. Use scripted deployment or Terraform for the complete automated flow.
- **Existing lab upgrade:** [deploy-webapp.ps1](../../scripts/deploy-webapp.ps1) publishes the app and provisions missing console dependencies without reapplying AKS workloads. Its `-WhatIf` describes the infrastructure and access scope.

After successful deployment, open the Web App and sign in. The default operator is the signed-in Azure CLI user, or existing operators on an upgrade. Noninteractive deployments supply user object IDs using `-ConsoleOperatorObjectIds` or Terraform's `console_operator_object_ids`. These are deployment inputs, not a separate setup step.

Infrastructure updates preserve runtime-owned sign-in and console app settings through a secure settings merge. Bootstrap retains the selected lab tags and any runner-specific tags present when bootstrap starts. Both publishing paths wait for the exact new assembly's publication ID, so a reachable older app cannot satisfy deployment completion. A deployment that stops during bootstrap must be completed before using the controls. Before promoting deployment changes, test a fresh lab and a rerun with the same approved operators, then verify the published version, operator sign-in, health and runner readiness, and retained tags.

### Prerequisites

The deployment machine needs PowerShell 7, Azure CLI, the .NET 8 SDK, and the existing lab workload tools. Optional AI setup needs Python 3.10+; SRE packaging needs npm and tar. Local Docker is not required: ACR Tasks builds an isolated eleven-file context containing only the scripts, manifests, and Dockerfile. CPU simulation additionally needs both demo VMs, ready VM Agents with outbound access to Azure, and the Linux image's standard `timeout`, `flock`, and `getconf` commands.

The deploying identity must be able to deploy resources, create custom roles and role assignments, create/manage the single-tenant Entra application and service principal for sign-in, and validate operator users. AI-enabled deployment needs agent-creation access to its Foundry project. Azure ownership does not override tenant restrictions on application registration. Scripted and Terraform deployments register required providers automatically.

The subscription/region must support Basic Container Registry, ACR Tasks, and a Consumption Container Apps environment. Some free-credit subscriptions restrict ACR Tasks. Required policy, permission, capacity, build, or agent-creation failures stop deployment rather than silently leaving disabled controls. Newly assigned permissions and telemetry can take time to propagate; infrastructure success is not proof that telemetry has arrived.

### Included Configuration

1. Single-tenant App Service Authentication and provider/backend operator allowlists, retaining anonymous demo traffic endpoints. The sign-in credential is transferred in memory to protected App Service settings. Redeployment renews a missing, expired, or near-expiry credential; no scheduled renewal service is installed.
2. A Basic registry with admin and anonymous access disabled, a Consumption environment with logs sent to the existing central workspace, and a separate user-assigned runner identity.
3. A cloud-built image pinned by SHA-256 digest and a manual job with one replica, zero replica retries, and a 30-minute timeout.
4. Scoped runner, image-pull, job-start, health-query, and custom-log ingestion permissions. A separate Run Command role is assigned only on the two demo VMs when the pair is present. Missing custom-log resources are created for older labs.
5. A private persistent journal at `/home/data/lab-operations/journal.json` and generated settings, followed by enablement. Unrelated app settings are preserved.
6. With Stage AI, four matching demo agents are reused or created without simulated conversations. With both AI and SRE stages, native MCP and host-model access are configured. An SRE-only deployment does not include the separate host model required by this console's SRE assistant.

The registry has ongoing service/storage charges. Builds, jobs, logs, running workloads, and optional model use have their usual Azure charges. The runner has no always-running application replica. Deployment does not execute any of the nine lab operations.

## Access Boundaries

| Identity | Access |
|---|---|
| Browser operator | Single-tenant sign-in, explicit allowlist, same-origin POST checks, and expiring single-use approvals. |
| Web App managed identity | Read-only lab inventory/workspace access and read/start access on one runner job. Optional agent roles are resource-scoped. |
| Runner managed identity | Reader and a custom lifecycle/annotation role at the lab resource group, AcrPull on its registry, Monitoring Metrics Publisher on the custom-log DCR, and a separate Run Command role on the two selected demo VMs. |

Azure job-start permission supports template overrides. It is not an RBAC restriction to nine scripts: a compromised Web App identity could exercise the runner identity's permissions through that job. The application validates the image, execution limits, identity, fixed lab environment, and approved inputs. Keep deployment access and both identities restricted to a disposable lab.

`Microsoft.Compute/virtualMachines/runCommand/action` allows elevated guest execution as root on Linux and SYSTEM on Windows. Azure RBAC cannot restrict that permission to the fixed CPU payload or its duration. The CPU role is assigned on individual VM resources, never at subscription or resource-group scope; the existing lifecycle role does not gain guest execution. Removing a VM from the selected pair prevents future script submission but incremental deployment does not revoke older role assignments. Review and remove obsolete VM assignments when repurposing a lab.

The wrapper pins the subscription, verifies tenant/resource group, and requires one running AKS cluster and one app-prefixed web app for Kubernetes scenarios. It requests non-admin credentials, isolates kubeconfig/context, converts every refresh for noninteractive login, and checks required `demo` permissions before disruption.

The default AKS template uses Kubernetes RBAC without Entra integration. Cluster-user certificates can grant broader Kubernetes access than namespace-specific Entra credentials. This feature does not redesign cluster authentication. Private or custom-authentication clusters need a separately reviewed network/RBAC deployment design.

This lab uses authenticated public registry endpoints and public Azure APIs, not a private-network production baseline. Registry admin credentials and anonymous pull are disabled. The job has no ingress endpoint. Intentional-failure endpoints and shared lab identities are not intended for production workloads.

## Persistent State

Use one Web App instance with persistent `/home` storage. The journal is outside the web root, file-locked, and atomically replaced. Missing/unwritable storage, corrupt history, or a held lock fails closed. Do not delete an existing journal to clear an uncertain operation.

Limits: 100 unexpired proposals, 200 retained runs, seven-day pruning of completed records on approval, 10 approval/preparation requests and 30 reads per minute per app instance. Pending approvals disappear on restart; saved executions do not. ARM responses are bounded, HTTP calls time out, and redirects are rejected. The application blocks overlapping submissions; a job's one-replica limit alone does not prevent an administrator from starting another execution outside the app.

## Failure And Recovery

- **Unavailable:** inspect the deployment error, job/image/identity configuration, operator sign-in, and journal storage. Availability checks do not execute an action or prove all data-plane permissions have propagated.
- **Queued/running:** inspect the Azure job's executions and central workspace logs. App closure or restart does not cancel the independent job.
- **Dispatch outcome unknown:** refresh status. Bounded execution discovery matches the request ID, all approved inputs, scope, and image without resubmitting. A definite rejection can remain conservatively blocked until inspected.
- **App restart:** reopen Lab Operations to reload this operator's persisted history. An approval cannot be replayed. Other operators' active runs block new submissions but their details are private; the originating operator or administrator must resolve them.
- **App/image upgrade:** new approvals use the new digest. Saved executions remain queryable using their original digest in the same job and lab scope.
- **Unrecoverable ambiguity:** disable Operations, inspect Azure and actual workload state, back up the journal, and reconcile it through an administrative change process. Do not mark success without evidence.
- **Start rejected:** an explicit validation, authentication, permission, or throttling rejection is saved as Failed with its HTTP status. No execution was created. Correct the cause and prepare a fresh approval; the old approval cannot be replayed. Timeouts, conflicts, and server failures remain Unknown until reconciled.
- **Runner startup or script failure:** container logs identify a fixed phase and, when available, the failed Azure command name without exposing raw authentication output or command arguments. An action-start message is emitted only after its prerequisites pass.
- **Failed/cancelled:** inspect partial changes before approving another action. Restore Lab restores the repository's known demo configuration, not a captured snapshot. Refresh health after Azure and telemetry settle.
- **Web app stopped:** the UI cannot receive clicks. Start the Web App through Azure management. Do not repeatedly start a saved job template in the portal because it may contain an old request.

Do not put secrets or sensitive data in marker text. Execution metadata is visible to operators with Azure job/log access. Raw script output is suppressed. Deleting the lab resource group removes the registry, environment, job, and runner identity; the tenant-scoped sign-in application is separate and should be reviewed during cleanup.

## Verification

[Lab Operations Tests](../../.github/workflows/lab-operations-tests.yml) covers approval/journal/ARM contracts, [nine real scripts under fake commands](../../scripts/tests/lab-operations-execution.Tests.ps1), [automatic bootstrap](../../scripts/tests/console-bootstrap.Tests.ps1), [deployment handoffs](../../scripts/tests/console-deployment.Tests.ps1), and browser regressions. Customer-traffic tests cover immutable browser limits, target discovery, endpoint readiness, and wrapper invocation without opening a browser. CPU tests cover both OS payloads, readiness and target failures, no-write `-WhatIf`, partial submission, and temporary-file cleanup without running CPU load. These offline tests do not prove live Chromium execution, guest execution, alert firing, tenant policy, ACR build availability, role propagation, or Kubernetes access.

The runner's `-CheckAccessOnly` mode validates its managed-identity login, target account, resource group, and action-specific prerequisites. For Start Lab, it also runs the real script's complete resource discovery with `-WhatIf`, including expanded VMSS instance views, without issuing start commands. For CPU simulation it verifies both VM targets and agents with `-WhatIf`, without submitting Run Command. It can acquire credentials and create temporary local files, but it does not execute a lab operation or prove that every later write will succeed. `-ValidateOnly` checks parameters without authenticating. Offline coverage includes duplicate Azure CLI paths, running and stopped VMSS instances, write-blocked discovery with all four resource types stopped, and sanitized failure phases and command names.

References: [Container Apps jobs](https://learn.microsoft.com/azure/container-apps/jobs), [managed identities](https://learn.microsoft.com/azure/container-apps/managed-identity), [ACR Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview), [App Service authentication](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization).

CPU execution references: [Linux Action Run Command](https://learn.microsoft.com/azure/virtual-machines/linux/run-command) and [Windows Action Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command).