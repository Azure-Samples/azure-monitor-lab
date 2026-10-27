# Contributing

Thanks for your interest in improving the **Azure Monitor Lab**! This is a
community demo project for learning Azure Monitor and Microsoft Sentinel, and
contributions that make it clearer, more reliable, or more useful for demos,
microhacks, and hackathons are very welcome.

## Ways to contribute

- **Report bugs** — open an issue describing what you deployed, what you
  expected, and what happened (include the IaC path: Bicep or Terraform, and the
  stage).
- **Suggest scenarios** — new demo scenarios or improvements to existing ones.
- **Improve docs** — fixes to the README, stage guides, or `docs/DEMO-SCENARIOS.md`.
- **Fix code** — Bicep/Terraform modules, PowerShell scripts, or the sample
  workloads.

## Before you start

1. Search existing issues/PRs to avoid duplicates.
2. For anything non-trivial, open an issue first to discuss the approach.

## Ground rules (please read)

This repo is built around the principle that **it ships zero secrets**. When
contributing:

- **Never commit** `lab.config.json`, `.azure-target.json`,
  `main.parameters.json`, `*.tfvars`, `*.tfstate*`, `.rbac-demo-config.json`,
  or any `*.log`. These are already gitignored — keep them that way.
- **Never hardcode** subscription IDs, tenant IDs, object IDs, emails,
  passwords, or connection strings. Use the `lab.config.json` →
  `scripts/sync-config.ps1` flow, or parameters/variables.
- Keep Bicep and Terraform **feature-equivalent** and aligned on the same stage
  boundaries (A–E).
- Prefer **placeholders** (`<YOUR-SUBSCRIPTION-ID>`, `your.alias@example.com`)
  in any example or template files.

## Development workflow

1. Fork the repo and create a feature branch:
   `git checkout -b feature/short-description`.
2. Make your changes.
3. Validate what you touched:
   - **Bicep:** `az bicep build --file infra/main.bicep` (and any stage files
     you changed under `infra/stages/`).
   - **Terraform:** `terraform fmt -check` and `terraform validate` in
     `terraform/`.
   - **PowerShell:** make sure scripts still parse (e.g. run with `-WhatIf`
     where supported) and don't introduce hardcoded values.
4. Test a real deployment into **your own** subscription where practical, then
   tear it down with `scripts/teardown.ps1`.
5. Commit with a clear message and either push directly to `integration` or open a
  pull request against it, describing the change and how you validated it. Do not
  target `main` directly.

## Branch promotion

The release route is `dev -> integration -> main`. Feature branches also target
`integration`. Use integration to rehearse the combined changes and validate the
lab before a maintainer manually promotes it.

- `dev` remains the normal development branch.
- `integration` accepts direct fast-forward pushes and pull requests. Force-pushes
  and deletion are blocked.
- `main` has the same protections and additionally requires the
  **Integration promotion gate**. Only this repository's `integration` branch
  can pass it; a fork branch with the same name is not accepted.
- GitHub permits opening PRs from other branches, but the policy automatically
  closes those targeting `main`. Reopen the change against `integration`.
- Keep integration current with main through a `main -> integration` PR
  after promotion. Merge commits preserve the shared branch ancestry. Update
  dev from integration before starting the next development cycle.
- For `integration -> main`, integration must already contain the latest
  main commit. CI tests the PR's combined result; the source gate checks live
  PR metadata, validates that PR's exact test-merge commit, and reports the
  required status against the validated integration head.
- A passing gate does not perform a merge or prove a live deployment was tested.
  Complete the lab rehearsal and explicitly merge the promotion PR yourself.

The privileged source check uses `pull_request_target` and checks out only its
trusted workflow revision. It never runs PR code. Test jobs use read-only
permissions. Missing checks and API failures block promotion; if GitHub has not
computed a conflict-free test merge yet, resolve conflicts or rerun the check.

Required independent approvals are not enabled until another maintainer is
available. Administrators can still edit repository rules. These protections are
not a security boundary against an administrator changing policy or a trusted
writer deliberately replacing CI checks. Review workflow changes carefully and
add independent/code-owner review when a second maintainer is available.

## Pull request checklist

- [ ] No secrets, real IDs, emails, or passwords added (check your diff).
- [ ] Bicep builds / Terraform validates (for the paths you touched).
- [ ] Docs updated if behavior or deployment steps changed.
- [ ] Bicep and Terraform kept in sync if you changed deployed resources.

## Code of Conduct

By participating, you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).
