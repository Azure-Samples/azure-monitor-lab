# Stage SRE Agent - Azure Monitor incident investigation

> **Goal:** connect an Azure SRE Agent to the lab's Azure Monitor alerts and observability data, then demonstrate alert-driven investigation across Application Insights, Log Analytics, metrics, Resource Graph, and Activity Logs.
>
> **Deployment model:** the one-shot Bicep path deploys `Microsoft.App/agents`, a dedicated managed identity, least-privilege RBAC, and Azure Monitor connectors. `scripts/setup-sre-agent.ps1` validates the deployed agent and prints its portal URL.
>
> **Region:** the SRE Agent is hard pinned to **Sweden Central** (`swedencentral`). Do not select another region for this lab.
>
> **Preview API:** deployment currently uses `Microsoft.App/agents@2025-05-01-preview`. Preview schemas can change or be retired. `setup-sre-agent.ps1` reports a targeted upgrade error if this API is no longer available.

## Trial cost facts

The 30-day evaluation waives the fixed always-on charge, not all SRE Agent charges.

| Item | Trial behavior |
|---|---|
| Eligibility | Azure customers without an SRE Agent as of August 25, 2026 |
| Allowance | Up to 3 agents per customer, including deleted agents |
| Duration | 30 days from each agent's creation |
| Always-on flow | Waived during the 30-day window |
| Active flow | Billed whenever chat, incidents, tasks, or other processing runs |
| Day 31 | Always-on billing starts automatically unless the agent is deleted |
| Feature limits | No trial-specific feature limitations |

Use one agent for this lab. In **Settings > Agent consumption**, set the smallest active-flow allocation appropriate for the demo and monitor consumption by thread. Stopping an agent stops active flow but does not stop always-on billing after the trial. Delete the agent before day 31 to stop all SRE Agent billing.

References:

- [Evaluate Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/evaluate)
- [Azure SRE Agent pricing and billing](https://sre.azure.com/docs/reference/pricing-billing)
- [Azure Monitor alerts in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts)
- [Diagnose with Azure Observability](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability)

## 1. Deploy the agent

The deploying identity needs Owner or User Access Administrator at subscription scope. Bicep uses that permission to grant the agent connector identity Monitoring Contributor so it can acknowledge and close Azure Monitor alerts.

Enable the stage in `lab.config.json`:

```json
"stageToggles": {
  "enableStageSreAgent": true
}
```

For a one-shot deployment, `deploy.ps1` maps this toggle to the Bicep `enableSreAgent` parameter. The deployment creates:

- `Microsoft.App/agents` in `swedencentral`
- A regional user-assigned managed identity
- Reader, Monitoring Reader, and Log Analytics Reader access to the lab resource group
- Monitoring Contributor access for the connector system identity at subscription scope
- When `enableSlotFailureScenario=true`, a custom role scoped to the lab Web App that permits the action identity to read slots and perform only the slot-swap rollback action
- SRE Agent Administrator access for the deploying user and agent identity
- Azure Monitor, Application Insights, and Log Analytics connectors

For a strict staged Bicep deployment, deploy Stage A first and then deploy the dedicated SRE Agent stage:

```powershell
az deployment group create `
  -g <resource-group> `
  --name stage-sre-agent `
  --template-file infra/stages/60-sre-agent.bicep `
  --parameters namePrefix=amlab
```

The staged template deploys the same agent, connectors, identities, and role assignments as the one-shot path.

The agent uses Review mode, Low access, the Microsoft Foundry automatic model, and a 1,000 monthly Agent Unit limit. Creating the resource can start billing. Eligible new customers receive the 30-day always-on charge waiver automatically; confirm the evaluation status in **Settings > Agent consumption** after deployment.

The agent remains in `swedencentral` even when the lab and its observability resources are deployed elsewhere. This creates an intentional cross-region query and reliability dependency. Treat this lab topology as an evaluation design, not a production colocation recommendation.

You can rerun validation directly after deployment:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group>
```

The check pins Azure CLI to the explicit subscription and verifies the lab resources, SRE Agent region, connectors, managed identity, and RBAC.

## 2. Review the deployed agent

1. Open the URL printed by `deploy.ps1`, or open [sre.azure.com](https://sre.azure.com/).
2. Select the deployed `sre-amlab-<suffix>` agent.
3. Confirm the region is **Sweden Central** and the action mode is **Review**.
4. Open **Settings > Agent consumption** and confirm whether the 30-day evaluation applies.
5. Open **Settings > Azure settings > Go to Identity** to inspect the managed identity.

Reader mode supports investigation and uses on-behalf-of approval when a write is needed. Only an SRE Agent Administrator using a work or school account can approve that elevation.

## 3. Verify permissions

Run the validation script. It discovers the agent identity automatically:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group>
```

The documented role set is:

| Role | Scope | Purpose |
|---|---|---|
| Reader | Lab resource group | Discover resources and inspect configuration |
| Log Analytics Reader | Lab resource group | Query workspace and Application Insights logs |
| Monitoring Reader | Lab resource group | Read metrics and monitoring data |
| Monitoring Contributor | Subscription | Acknowledge and close Azure Monitor alerts |
| Lab SRE Slot Rollback *(only when enabled)* | Lab Web App | Read deployment slots and reverse the controlled `broken`-to-production swap after Review-mode approval |

The Bicep deployment assigns all roles in the table, including subscription-scope Monitoring Contributor. If that assignment was removed or an older deployment is being upgraded, review the scope and grant the missing role explicitly:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group> `
  -GrantMissingRoles
```

The script requires typing `GRANT` before it creates role assignments. Use `-Yes` only in controlled automation.

## 4. Verify Azure Monitor

1. In the SRE Agent portal, open **Builder > Connectors** and confirm Azure Monitor, Application Insights, and Log Analytics are present.
2. Open **Incidents > Triggers & response plans**.
3. If the page displays **Connect an incident platform**, select it, choose **Azure Monitor**, select the lab subscription, and save. The **Create a response plan** button remains disabled until this connection is complete.
4. On the **Triggers & response plans** tab, delete any generated quickstart plan before adding the plans below. Leaving it active can process the same incident twice or route it to the wrong custom agent.

The Azure Monitor scanner checks approximately every minute. Its initial lookback is one day, repeated firings from the same alert rule merge into one active thread, and alert status synchronizes approximately every five minutes.

## 5. Create the custom agents

Open **Builder > Agent Canvas** and select **Create > Custom Agent**. Custom-agent names can contain only letters, numbers, or hyphens and must be 36 characters or fewer. Enter the name and supplied **Instructions**, leave Skills, Tools, and Hooks at their inherited defaults, and select **Create**. The current creation dialog does not expose a handoff field. A handoff description is not required here because each incident response plan explicitly selects its response subagent.

<details>
<summary><b>Optional: add handoff instructions after creation</b></summary>

Open **Builder > Agent Canvas > Test playground**, select the custom agent from the **Custom agent/Tool** list, and use **Form view**. Enter the handoff text in **Handoff instructions**, then select **Apply**:

- `amlab-app-investigator`: `Investigates App Service and Application Insights incidents.`
- `amlab-platform-investigator`: `Investigates AKS and virtual machine incidents.`

This text helps chat orchestration decide when to delegate. It does not control incident routing; the response plan does that.

</details>

### Application Investigator

Create a custom agent named `amlab-app-investigator` with these instructions:

```text
Investigate Azure Monitor incidents for the Azure Monitor Lab resource group.
Start with the affected resource and alert time. Inspect Application Insights
requests, exceptions, traces, and dependencies, then App Service metrics,
resource configuration, Activity Logs, and deployment operations. Release
annotations are Application Insights chart metadata, not customEvents. If they
are unavailable through the connector, state that limitation instead of using
an empty KQL result as evidence that no annotation exists.
Correlate evidence from 15 minutes before the first signal through 30 minutes
after it. State the observed impact, timeline, likely cause, confidence, and the
smallest reversible mitigation. For agent-task or efficiency incidents, require
the Observability Agent trace-specialist handoff when available. Validate its
technical, task, performance, trace-quality, retry, token, version, and critical-
path evidence against Azure Monitor and platform signals; treat it as a cited
hypothesis rather than an approved action. Separate evidence from inference.
Do not modify resources without approval. After an approved action, require a
Fixed trace for the same scenario and verify availability, alert state, the
original signal, and application failure rate before declaring recovery. Do not
wait for a follow-up question. End every response-plan run with an `Incident command
brief` containing current status, customer impact, affected resources, first
signal, likely cause and confidence, three timestamped evidence bullets with
their sources, the smallest safe next action, and any missing evidence.
```

### Platform Investigator

Create a custom agent named `amlab-platform-investigator` with these instructions:

```text
Investigate Azure Monitor incidents for AKS and virtual machines in the Azure
Monitor Demo Lab resource group. For AKS, inspect KubePodInventory,
ContainerLogV2, Kubernetes events, pod status, restart counts, and Azure Monitor
metrics. For virtual machines, inspect power state, heartbeat, metrics, Resource
Health, and Activity Logs. Build a timestamped evidence chain and identify the
affected component and blast radius. Separate evidence from inference. Use
passive diagnostics first. Ask for approval before active VM commands or any
resource change. Verify the original signal after an approved mitigation. Do
not wait for a follow-up question. End every response-plan run with an `Incident
command brief` containing current status, workload impact, affected resources,
first signal, likely cause and confidence, three timestamped evidence bullets
with their sources, the smallest safe next action, and any missing evidence.
```

## 6. Create response plans

Keep both plans in **Review** mode for the trial. Open **Incidents > Triggers & response plans** and select **Create a response plan**. For each row below, enter the plan name, severity, title filter, and response custom agent in **Step 1: Response plan**. Set **Agent autonomy level** to **Review** because the default is Autonomous. Select **Next**, choose **Last 7 days** in **Step 2: Incidents preview**, review any matches, and select **Create**. An empty preview is expected when no matching alert has fired yet.

| Plan | Severity | Title contains | Custom agent |
|---|---|---|---|
| `amlab-app-alerts` | Sev2 | `webapp`, `failed-requests`, `agent-task`, or `agent-efficiency` | `amlab-app-investigator` |
| `amlab-platform-alerts` | Sev2, Sev3 | `aks`, `pod`, or `vm` | `amlab-platform-investigator` |

The portal currently accepts one **Title contains** value per plan. Use `webapp` for `amlab-app-alerts` and `aks` for `amlab-platform-alerts`. To cover each additional title fragment in the table, clone the corresponding plan with a unique name and replace the title filter. Confirm every plan shows status **On** and mode **Review**. Turn off plans when the demo is idle to prevent expected lab alerts from consuming active-flow AAUs.

### Coordinated Scenario 69 flow

1. Generate the Broken trace and let the agent-task or efficiency alert open or update the SRE incident.
2. Run the Control Center's Observability Agent prompt and copy its SRE handoff packet into the incident thread.
3. Run the generated SRE incident-command prompt. The application investigator reconciles trace evidence with Azure changes and platform health, then drafts a Review-mode action and rollback boundary.
4. Obtain human approval and generate the matching Fixed trace; this deterministic profile demonstrates the approved correction rather than editing or redeploying source.
5. Use Observability Agent to validate trace-level recovery and SRE Agent to validate availability, alert state, application failure rate, and incident closure criteria.

## 7. Run the scenarios

Scenarios 54 through 59 in `DEMO-SCENARIOS.md` form one 23-minute SRE Agent flow:

1. Validate the trial, scope, and permissions.
2. Trigger an App Service incident and watch automatic investigation start.
3. Diagnose the AKS crash loop with the platform investigator.
4. Correlate the incident with Activity Log changes and release annotations.
5. Demonstrate repeated-alert merging, restore the lab, and verify recovery.
6. Show the incident command brief generated automatically by the response-plan investigator.

## 8. Done when

1. The trial banner and creation date are recorded.
2. The SRE Agent location is Sweden Central (`swedencentral`).
3. The lab resource group is the only managed resource group.
4. All four documented role checks pass.
5. Azure Monitor is connected as the incident platform.
6. The quickstart response plan is removed.
7. Both lab response plans are enabled in Review mode only during the demo.
8. A fired lab alert creates or updates an investigation thread.
9. The agent cites evidence from at least two Azure observability sources.
10. The agent confirms recovery after `restore-the-lab.ps1`.
11. The selected investigator produces an incident command brief without waiting for a user prompt.

## 9. Stop costs

After the demo:

1. Turn off both incident response plans.
2. Open **Settings > Agent consumption** and review active-flow AAUs by thread.
3. Stop the agent when it is not being evaluated.
4. Run `./scripts/teardown.ps1 -ResourceGroup <resource-group>` or delete the agent directly before day 31 if you do not intend to pay the fixed always-on charge.

The teardown script deletes the SRE Agent before submitting asynchronous resource-group deletion. A successful resource-group deletion also deletes an agent contained in that group. Verify completion with `az group exists -n <resource-group>`; it must return `false`. If group deletion fails, confirm that no `Microsoft.App/agents` resource remains so billing does not continue.