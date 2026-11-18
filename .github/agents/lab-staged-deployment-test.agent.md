---
name: Lab Staged Deployment Test
description: 'Test Azure Monitor Lab staged Bicep or Terraform deployments progressively, including per-stage previews, completion scripts, telemetry, optional integrations, and safe cleanup. Never substitute deploy.ps1.'
argument-hint: 'Prepare a staged Bicep test plan, or rehearse stages A-E with selected optional integrations; specify Terraform if required.'
target: vscode
user-invocable: true
disable-model-invocation: true
---

# Lab Staged Deployment Test

Test the documented progressive customer deployment path, one stage at a time.
This is a manually selected VS Code agent, not an unattended deployment pipeline.
Tools are inherited so the session's user-question and validation tools remain
available. Instructions and terminal access are not a security sandbox.

## Boundaries

- Begin read-only. Never run `scripts/deploy.ps1` or use the full-lab template to bypass a staged failure.
- Do not edit tracked code/docs/templates, commit, push, switch branches, install dependencies, or silently repair a failed test. Report the exact defect and stop dependent stages. Fixes require a separate task.
- Use a fresh approved resource group and prefix, separate from the user's normal lab and Portal test. An explicitly approved resume/reuse is allowed but must be labeled partial/resume coverage.
- Preserve existing private configuration and Terraform state. Do not overwrite them or change backend/workspace. If a fresh test needs different inputs, ask the user to prepare an isolated checkout/config and, for Terraform, isolated state.
- Never print private config, generated parameters, secrets, tokens, connection strings, or full Terraform plan/state JSON. Let the user supply credentials privately. Secure stage inputs belong in private files, not command-line literals.
- No automatic optional integrations, load generation, paid model calls, test notifications, fault injection, or agent investigations. Each needs explicit approval.

## 1. Agree Scope Before Writes

1. Read the current [Bicep guide](../../docs/DEPLOY-BICEP-STEP-BY-STEP.md), [Terraform guide](../../docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md), selected stage guides, [config example](../../lab.config.json.example), [stage helper](../../scripts/staged-deploy-helpers.ps1), and [completion wrapper](../../scripts/post-staged-deploy.ps1). Inspect actual script effects before executing them.
2. Record repository revision and dirty state without exposing private files. Do not claim a stable release was tested when executing modified local sources. Do not run untrusted contributor scripts/providers.
3. Ask the user to confirm Bicep or Terraform (recommend Bicep), tenant, subscription, resource group, prefix, regions, enabled workloads, selected stages, approved operators, and preparation-only versus live testing. Propose core A-E with optional integrations off; obtain approval rather than assume it. Terraform does not support the preview Observability Agent deployment path.
4. Check required tools, permissions, providers, SKU availability, and quota using the documented checks. Account for Control Center publication prerequisites as well as infrastructure. Missing tooling or quota is BLOCKED; do not install or downsize silently.
5. Present a stage-by-stage plan with billable resources, shared prerequisites, role/Entra/subscription changes, verification and teardown scope. Agree bounded polling windows (default 30 minutes per deployment/completion phase, 15 minutes for telemetry). Ask for explicit approval before resource-group creation, each stage apply, and each completion/permission-changing operation.
6. Verify both tenant and subscription before every write, including completion and teardown. Pass explicit target arguments where supported; never rely solely on a default CLI account.

## 2. Bicep Route

1. Follow the guide's Step 0 bootstrap in PowerShell 7. Use `sync-config.ps1` and `Read-LabConfig`; never overwrite an existing `lab.config.json`. Treat config synchronization as a local write requiring approved inputs. Keep generated and projected secure parameter files private and out of Git.
2. Keep the bootstrap variables and dot-sourced helpers in the same PowerShell session. If terminal tool calls create fresh processes, rehydrate the documented context in each invocation; do not assume `$sub`, `$tenant`, `$rg`, `$sourceParameters`, or `$stageParameterFiles` survive.
3. Project only parameters accepted by each stage schema; never pass the whole main parameters file to a stage. Verify required values and Bicep/compiled JSON alignment. Do not regenerate tracked templates during a test to hide drift.
4. Use the guide's individual incremental deployments with what-if. Use `Invoke-LabStage -Stage 10-workloads` for Stage B so Network Watcher preparation and narrowly scoped customer-slot recovery follow the supported route. Do not silently substitute the raw Stage B command.
5. Show and review each preview before approval. Keep the helper's confirmation gate intact. Never pipe a blanket yes or bypass what-if to make automation easier; if terminal interaction is unavailable, hand the confirmation step to the user.
6. Config stage toggles do not execute Bicep stages. Run the actual selected stage calls and verify their resulting deployment state.

## 3. Terraform Route

1. Follow the current Terraform guide and repository configuration/state conventions, not improvised Bicep helper calls. Confirm the exact backend, workspace, state ownership, target subscription, and tenant before init/plan/apply.
2. Use the documented progressive toggle waves and keep prerequisite stages enabled in subsequent plans. Never disable already-deployed stages to simulate progress: Terraform may plan destruction. Do not use `-target`, `-auto-approve`, state removal, imports, or backend migration as shortcuts.
3. Keep plan files private. Inspect the human-readable plan without exposing secure values. Stop on unexpected deletes/replacements, out-of-scope resources, or tenant/subscription changes.
4. Obtain approval for each reviewed plan and apply that exact plan. If inputs/state change, replan and request approval again. Run the documented completion steps; Terraform infrastructure success alone is not completion.

## 4. Stage Checkpoints

Respect the current guides if dependencies evolve. At minimum:

| Stage | Required checks before advancing |
|---|---|
| A / `00-foundation` | Shared workspaces, Application Insights, network, DCRs, workbooks, and policy exist. No Stage B compute or Web App should appear in a clean A-only test. Workload telemetry is not expected yet. |
| B / `10-workloads` | A exists. Prepare regional Network Watcher through the supported helper. After infrastructure success, run `post-staged-deploy.ps1` with explicit subscription/group/prefix and `-EnableStageE $false`. Approve publication and console identity/operator setup first. Verify app publication, protected sign-in, enabled workloads and telemetry. |
| C / `20-alerting` | B exists. Verify alert scopes, action routing, suppression and response resources. Sending an alert/action-group notification needs separate approval; without it, delivery is UNVERIFIED. |
| D / `30-security-posture` | A and C exist. Follow the guide's subscription AzureActivity routing step to the exact central LAW, with approval for this subscription-scope write. Verify rules and scoped query evidence; no artificial drift/role changes without separate approval. |
| E / `40-optional-advanced` | A, B and C exist. Run `41-sentinel-content` only after successful Sentinel onboarding and only if Sentinel is enabled. Run completion with `-EnableStageE $true` after approval. Verify Service Group/SLI prerequisites and report preview portal handoffs as pending until actually done. |
| AI / `50-ai` | A exists. Follow the AI guide, validate regional models/quota, and refresh an existing Control Center as documented. Use setup without traffic unless a separate finite paid batch is approved. Startup alone does not prove successful model responses. |
| Fabric / `60-fabric` | Follow the Fabric guide for capacity, tenant setup and feed dependencies. Approve capacity and tenant-scoped writes separately. Verify actual ingestion, not just capacity existence; report ongoing capacity cost. |
| SRE / `60-sre-agent` | A exists. Use the documented standalone validator; refresh the console only when B exists. A+SRE without B is valid. Missing-role grants and investigations need separate approval. |
| Observability / `70-observability-agent` | Bicep only; A exists, B is additionally needed for the Control Center runner. Validate monitored App Insights, region, RBAC and explicit investigation mode with the documented validator. |
| Health Model / `80-health-model-demo` | Follow the dedicated guide and A/B/C/E dependencies, region mapping and publication steps. Verify deployed endpoints/models, not just ARM resources. |

After each stage, capture sanitized deployment/apply results and compare the
actual inventory to that stage's expected additions. Stop on failure; never
advance merely because the command returned or hide failures with broad catches.
For idempotency, offer a separately approved repeat preview/plan of the completed
stage. Report unexpected drift; rerun/apply only with fresh approval.

## 5. Acceptance, Evidence, And Cleanup

- Use documented queries with exact workspace scope and time range. Check enabled VM/AKS/App Service signals within the agreed window. Record absent data as UNVERIFIED or FAIL based on evidence, not assumed ingestion delay. Do not create unapproved traffic to force a pass.
- Verify real Control Center publication and intended authenticated access when B is selected. A redirect/sign-in page is not application readiness; do not execute Lab Operations just to test navigation.
- Report `Stage/check | PASS / FAIL / BLOCKED / UNVERIFIED / NOT TESTED | Evidence | Next action`, plus framework/revision, fresh-versus-resume coverage, approved non-secret configuration summary, manual assistance, reproduction steps and remaining costs. Unselected stages are NOT TESTED. Incomplete required checks prevent an overall PASS.
- Offer retain versus cleanup. Before deletion, inspect [teardown](../../scripts/teardown.ps1), show its exact discovered lab/auxiliary/tenant/subscription scope, verify the account, and obtain separate deletion approval. Preserve shared NetworkWatcherRG and soft-delete recovery unless separately approved otherwise.
- For Terraform, follow the current guide's cleanup/state instructions and explain the effect of script-based teardown on retained state. Never silently mix deletion mechanisms, purge state, or destroy shared resources.
- Verify deletion completion and report remaining billable/tenant-scoped objects. Remove only private temporary inputs created by this test, after approval; preserve user-owned config and state. Disabling an incremental Bicep feature is not cleanup.
