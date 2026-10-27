# Product Manager Guide: Integrate a Feature into the Lab

This guide is for Microsoft product managers who want customers to experience a new Azure feature in the Azure Monitor Lab without completing a separate, potentially complex setup.

The intended outcome is that a customer deploys the lab through any supported deployment option and receives a working, documented, cost-aware feature in a realistic environment with traffic and telemetry.

Use this guide together with the repository's [general contribution guide](../.github/CONTRIBUTING.md). The contribution guide defines the branch policy, security rules, and engineering conventions that apply to every change.

## Contribution workflow

Changes follow this staged promotion path:

```text
feature branch -> integration -> main
```

Each transition has a separate purpose:

1. **Feature branch to `integration`:** Open the feature pull request against `integration`. Reviewers validate the implementation, deployment parity, tests, documentation, cost, and cleanup evidence. Feature branches must never target `main` directly.
2. **Validate on `integration`:** Rehearse the feature together with other accepted changes. Confirm the combined lab still deploys and behaves correctly before release promotion.
3. **`integration` to `main`:** A maintainer opens and manually merges the promotion pull request after `integration` contains the latest `main` commit and the required promotion gate passes. The PM does not bypass this release gate.

Merging the feature pull request into `integration` means the contribution has been accepted for integration testing. It does not mean the feature has been released. The feature reaches the supported release branch only after the separate `integration` to `main` promotion succeeds.

### 1. Fork the repository

Fork the repository into your GitHub account or approved organization, then clone your fork.

```powershell
git clone https://github.com/<your-account>/azure-monitor-lab.git
cd azure-monitor-lab
git remote add upstream https://github.com/Azure-Samples/azure-monitor-lab.git
```

### 2. Create a feature branch

Start from the current `integration` branch and use a descriptive branch name.

```powershell
git fetch upstream
git switch --create feature/<short-feature-name> upstream/integration
```

Keep the branch focused on one feature integration. Do not commit local configuration, state files, credentials, subscription IDs, tenant IDs, object IDs, email addresses, or generated logs.

### 3. Design the complete customer journey

Write down what should happen from deployment to first successful use:

- Which configuration value controls the feature, and what is its default?
- Which Azure resources, providers, identities, role assignments, policies, extensions, or marketplace terms are required?
- Which regions, subscriptions, quotas, SKUs, API versions, and product states are supported?
- What sample workload or existing traffic proves the feature in a realistic environment?
- What telemetry should appear, where should the customer find it, and how long can it take?
- What does success look like in the Azure portal or Lab Control Center?
- How is the feature disabled, redeployed, and removed?
- What is the incremental daily cost and what can cause that cost to increase?

Prefer an unattended and repeatable setup. A customer should not need to copy resource IDs, create role assignments manually, or run undocumented portal steps after deployment. When an Azure platform limitation makes a manual step unavoidable, automate every prerequisite and document the smallest remaining action in the owning deployment or stage guide.

### 4. Implement every supported deployment path

The lab supports multiple entry points. Updating only one does not complete the integration.

| Surface | Expected update |
|---|---|
| Configuration | Add the setting to `lab.config.json.example` and map it in `scripts/sync-config.ps1` when customer choice is required. Use a secure parameter for sensitive input. |
| One-shot Bicep | Update the relevant files under `infra/`, including `infra/main.bicep` and its modules. |
| Portal deployment | Update `infra/createUiDefinition.json`, Bicep parameters, and the committed compiled `infra/main.json` when the feature is configurable or visible in the portal flow. |
| Staged Bicep | Update the owning file under `infra/stages/` and any stage helper or guide needed to deploy it independently. Commit the compiled stage JSON used by supported flows. |
| Terraform | Add equivalent resources, variables, outputs, and stage conditions under `terraform/`. |
| Post-deployment automation | Update the appropriate script under `scripts/` for setup that cannot be expressed in infrastructure as code. Keep it idempotent so rerunning it is safe. |
| Customer experience | Connect the feature to a workload, traffic source, dashboard, alert, scenario, or Control Center experience that demonstrates its value. |
| Cleanup | Extend `scripts/teardown.ps1` or the relevant cleanup helper for resources not deleted with the resource group, especially tenant-scoped identities and shared resources. |

Keep Bicep and Terraform behavior equivalent. Use the same defaults, naming approach, stage boundary, outputs, and customer-visible behavior unless a documented platform limitation prevents it.

### 5. Update customer documentation and costs

At minimum, review and update the documents affected by the feature:

- `README.md` for capabilities, prerequisites, regional constraints, deployment behavior, and the headline cost range.
- `docs/REFERENCE.md` for the resource inventory, configuration reference, architecture, detailed cost table, and troubleshooting.
- The owning deployment or stage guide for any conditional verification or unavoidable customer action.
- The relevant stage guide under `docs/` for deployment and presenter notes.
- `docs/DEMO-SCENARIOS.md` for a customer-ready scenario with a story, portal path, expected result, cleanup or reset steps, and a concise value statement.
- `docs/CUSTOMER-STAGE-HANDOUT.md` when stage timing or cost changes.
- `docs/architecture.drawio` and the generated architecture image when topology changes.

Cost updates must include the incremental resource cost at the documented default configuration, the region and pricing assumptions, usage-sensitive charges, free or trial limits, and the cost when the feature is disabled. Do not describe a feature as free when it consumes shared compute, storage, telemetry ingestion, model tokens, or network egress.

### 6. Test the integration

Complete the checks that apply to the change. Record commands and results in the pull request.

#### Static and automated checks

- [ ] Build `infra/main.bicep` and each changed stage file with `az bicep build`.
- [ ] Run `scripts/tests/compiled-templates.Tests.ps1` and confirm committed ARM JSON matches its Bicep source.
- [ ] Run `terraform fmt -check`, `terraform validate`, and relevant Terraform tests from the `terraform/` directory.
- [ ] Run the relevant PowerShell tests under `scripts/tests/`.
- [ ] Run `dotnet test workloads/webapp.Tests/AmlabHello.Tests.csproj -c Release` when the web application or Control Center changes.
- [ ] Review the complete diff for secrets, personal data, internal URLs, real IDs, generated state, and unrelated changes.

#### Deployment checks

Use a non-production subscription and a new resource group. Verify all deployment options affected by the feature:

- [ ] Scripted one-shot Bicep deployment.
- [ ] Portal deployment using the compiled ARM template and UI definition.
- [ ] Staged Bicep deployment, including deployment of the owning stage by itself at the documented boundary.
- [ ] Terraform deployment with equivalent configuration.
- [ ] Default configuration and feature-disabled configuration, when the feature is optional.
- [ ] Redeployment to the same resource group to confirm idempotency.

For each deployment, confirm that the feature becomes usable without undocumented setup, receives realistic traffic or data, produces the expected telemetry, and exposes a clear customer verification path.

#### Operational and cleanup checks

- [ ] Confirm least-privilege role assignments and managed identity use where supported.
- [ ] Confirm preflight checks detect required providers, quotas, SKUs, and regional restrictions where they can be checked in advance.
- [ ] Confirm failures provide an actionable message and do not leave the deployment in an unexplained partial state.
- [ ] Confirm `scripts/teardown.ps1` removes feature resources and lab-owned tenant-scoped artifacts without deleting shared or customer-owned resources.
- [ ] Confirm documentation matches the deployed names, defaults, portal labels, expected wait times, and actual customer steps.
- [ ] Recalculate the lab's daily cost range from the deployed default and update all cost references.

If a deployment option cannot support the feature, document the technical reason in the issue and pull request and obtain maintainer agreement before submission. A missing implementation is not considered an acceptable difference by default.

### 7. Open a pull request to `integration`

Push the branch to your fork and open a pull request against this repository's `integration` branch. Do not target `main`.

```powershell
git push --set-upstream origin feature/<short-feature-name>
```

Include the following in the pull request:

- Customer problem and feature value.
- Customer journey after deploying the lab.
- Default-on or opt-in decision and rationale.
- Deployment paths and stages changed.
- New resources, permissions, dependencies, regions, quotas, and limitations.
- Incremental daily cost and pricing assumptions.
- Automated test results.
- Live deployment evidence for Bicep, portal, staged, and Terraform paths, as applicable.
- Screenshots or queries showing the feature receiving traffic and producing the expected result.
- Teardown result and confirmation that no unexpected resources remain.
- Documentation updated.

Respond to review feedback and keep the branch current with `integration`. After the feature branch is merged into `integration`, support any combined lab validation requested by the maintainer. A maintainer will then manage the separate `integration` to `main` promotion.

## Definition of done

A feature integration is complete when:

- Customers receive the intended feature through every supported deployment path without undocumented setup.
- Default behavior is safe, cost-aware, region-aware, and appropriate for a public demo lab.
- Bicep, compiled ARM, portal UI, staged deployment, Terraform, scripts, and configuration agree.
- The feature has realistic traffic or data and a repeatable customer demo scenario.
- Automated checks and fresh live deployments pass.
- Redeployment is safe and teardown is complete.
- Costs, permissions, dependencies, limitations, expected wait times, and verification steps are documented.
- No secrets, personal data, customer data, or Microsoft-confidential information are present.
- The feature pull request targets `integration`, contains enough evidence for a maintainer to reproduce the result, and follows the `feature branch -> integration -> main` promotion path.

The goal is not only to deploy a resource. The goal is to deliver a feature experience that a customer can discover, trust, demonstrate, and remove as part of the lab.