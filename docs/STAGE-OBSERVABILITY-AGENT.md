# Stage Observability Agent - autonomous operations for agentic applications

> **Goal:** use Azure Copilot Observability Agent (preview) to correlate alerts from the lab Application Insights resource, create issues, and investigate agentic-application failures with trace evidence.
>
> **Deployment model:** optional and off by default. Bicep creates a dedicated Azure Monitor workspace, `Microsoft.Monitor/observabilityAgents`, its monitored Application Insights child, and least-privilege RBAC. Terraform provisioning is not supported for this preview.
>
> **Safety default:** issue creation is automatic; deep investigation is manual. The agent does not automatically remediate resources.

## What this stage demonstrates

The Control Center emits bounded, synthetic dependency telemetry for eleven recognizable failure patterns:

1. A tool call is slow.
2. The agent chooses the wrong tool while HTTP remains successful.
3. A multi-step task fails after a state-changing step succeeded.
4. A retry loop amplifies latency and token usage.
5. A primary dependency outage requires a safe read-only fallback.
6. Unbounded context increases model latency and tokens.
7. A multi-agent handoff loses required context.
8. A model/deployment version regresses task quality.
9. Broken propagation disconnects a tool span from the trace.
10. Model throttling exposes retry behavior.
11. Parallel fan-out reveals the critical-path dependency.

Each scenario has deterministic `broken` and `fixed` profiles. Run the broken profile, investigate it, make or explain the targeted correction, run the fixed profile, and compare the evidence. Prompts and tool payloads are not recorded; the demo emits metadata such as scenario, operation, selected tool, expected tool, technical/task/performance success, trace completeness, retries, tokens, versions, outcome, duration, and trace ID.

## Product boundaries

| Experience | Role in this lab |
|---|---|
| Azure Copilot Observability Agent | Portal-based alert correlation, issue creation, chat, and optional deep investigation over Application Insights telemetry. |
| Azure SRE Agent | Alert-driven incident investigation and Review-mode response plans across Azure Monitor resources. It is a separate optional stage. |
| Microsoft Foundry | Hosts the optional model workload and existing lab agents. |
| GitHub Copilot CLI / Azure tooling | Terminal-side code and resource investigation after an issue is identified. There is no documented direct Observability Agent integration with GitHub Copilot CLI in this preview. |
| Azure Monitor health models | Companion business-impact view using shared workload terminology. The lab does not claim that Observability Agent ingests health-model topology. |

MCP and coding-agent integration appeared as roadmap content in the LevelUp material used to design this stage. Do not present roadmap content as a deployed capability.

## Prerequisites and limits

- Stage A must already exist because the agent monitors `appi-<prefix>`.
- The deploying identity needs permission to create resources and role assignments. Owner or User Access Administrator plus an appropriate resource-deployment role is the practical lab setup.
- Supported public regions in this implementation are Australia East, Canada Central, Central US, East Asia, East US, South Central US, UK South, West Central US, and West Europe.
- The agent and its Azure Monitor workspace must be in the same supported region. The monitored Application Insights resource can remain in the primary lab region.
- The preview allows at most five Observability Agent resources per subscription.
- The one-shot Bicep wrapper checks the configured agent region and attempts to count existing agents before deployment. A failed preview-list query produces a warning rather than a false success; verify the count manually before continuing in that case. The standalone staged commands do not run this preflight automatically.
- The portal supports one Application Insights target per agent. The API supports up to ten monitored targets; this lab deliberately uses one.
- ARM/Bicep and portal provisioning are supported. Azure CLI and Terraform provisioning are not supported preview provisioning paths. The validation script uses Azure CLI only to read the deployed ARM resources.

## Cost and privacy

- Pricing guidance checked **September 26, 2026**. Review the current [Observability Agent billing guidance](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-billing) and [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/) before deployment.
- Autonomous alert correlation is currently unbilled during preview.
- Chat and deep investigation consume Azure Agent Credits (AAC).
- Deep investigation can consume up to 500 AAC per investigation.
- Estimate variable agent spend as `chat AAC + (investigation count × AAC consumed per investigation)`, multiplied by the current regional AAC price. Do not assume every investigation consumes the 500-AAC maximum.
- The dedicated Azure Monitor workspace can also incur ingestion, retention, and query charges. With zero chats and zero investigations, the lab assumes no AAC usage, but workspace data charges can still remain.
- Automatic deep investigation can create unplanned usage, so `enableObservabilityAgentAutomaticInvestigation` defaults to `false`.
- Use only synthetic demo data. The Control Center requires explicit consent for every scenario run and records metadata only.

## Deploy

In `lab.config.json`, set:

```json
"observabilityAgentLocation": "westeurope",
"enableObservabilityAgentAutomaticInvestigation": false,
"observabilityAgentInstructions": "Correlate alerts for the lab application and its dependencies when they describe the same customer impact. Keep unrelated infrastructure alerts separate. Always create an issue for severity 1 or severity 2 agent task failures. Add [OPS-REVIEW] to issue titles.",
"stageToggles": {
  "enableStageObservabilityAgent": true
}
```

The one-shot Bicep deployment reads those values through `scripts/sync-config.ps1`.

For a staged deployment after Stage A:

```powershell
az deployment group create `
  --subscription '<subscription-id>' `
  --resource-group '<resource-group>' `
  --name stage-observability-agent `
  --template-file infra/stages/70-observability-agent.bicep `
  --parameters namePrefix=amlab `
               observabilityAgentLocation=westeurope `
               enableObservabilityAgentAutomaticInvestigation=false `
               observabilityAgentInstructions='Correlate alerts for the same demonstrated customer impact.'
```

The stage creates:

- `obs-<prefix>-<suffix>` with a system-assigned identity.
- `amw-<prefix>-obs`, a dedicated Azure Monitor workspace in the same region.
- One enabled Application Insights monitored-resource child.
- Issue Contributor on the dedicated workspace.
- Monitoring Reader on the monitored subscription.

Monitoring Contributor is intentionally not assigned because the lab does not enable remediation.

## Validate

Deployment wrappers run the validator automatically when the stage is enabled. You can rerun the read-only checks:

```powershell
./scripts/setup-observability-agent.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup '<resource-group>'
```

The script verifies the subscription and tenant guard, region, identity, issue and investigation operations, monitored Application Insights resource, and both RBAC assignments. It prints the portal URL only after validation succeeds.

## Demo workflow

1. Open the deployed App Service and sign in as an approved lab operator.
2. Open **Foundry Playground** and find **Troubleshooting scenarios**.
3. Choose any deterministic scenario. Start with **Retry loop and token amplification** for efficiency or **Multi-agent handoff** for a technically successful semantic failure.
4. Select **Broken**, approve synthetic telemetry generation, and select **Generate Trace**.
5. Open Application Insights transaction search and follow the returned trace ID through the browser/request, `GenAI`, `OpenAI`, `AgentHandoff`, and `AgentTool` telemetry.
6. Open Observability Agent from the Control Center, start a chat, and paste the trace-specific investigation prompt shown after the run. It asks the agent to explain evidence, identify the likely fault domain, state uncertainty, propose concrete next checks, and define measurable fixed-run verification.
7. Challenge the conclusion: verify technical, task, and performance health separately; then verify timestamps, critical path, tool selection, retries, tokens, versions, downstream dependency, trace completeness, and missing evidence.
8. Select **Fixed**, approve another run, and compare the new trace. Confirm the measured outcome changed; do not accept a code or configuration change as proof by itself.

The always-on `qp-<prefix>-appinsights` query pack and **Application Insights — End-to-End Agent Investigation** workbook provide broken-versus-fixed, retry/token efficiency, trace-quality, version/cohort, and browser-to-agent views. The optional Observability Agent stage consumes the same Application Insights evidence but is not required to generate or inspect the traces.

For Scenario 64, the same tab includes a bounded alert-storm generator with request-count, duration, progress, and Stop controls. Its default batch is designed to cross the two deployed failed-request conditions; it does not affect the availability-test endpoint or trigger a separate latency alert. For Scenario 65, it includes a separately consented generator that makes 3, 5, or 10 real Foundry calls and reports actual token totals. It reports estimated cost only when model pricing is configured. These controls never automatically replay failed or ambiguous requests.

Use the additional customer scenarios in [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md) for alert storms, token-cost spikes, deployment regressions, and platform-versus-application failures.

For an independent terminal workflow against the same Azure Monitor evidence, use [Scenario 68](DEMO-SCENARIOS.md#s68). It configures GitHub Copilot CLI with read-only Azure MCP access, provides a copyable trace-investigation prompt, and verifies the result against KQL. It is complementary to Observability Agent and is not a direct integration with it.

## Teardown

Use the lab teardown so the Observability Agent is deleted explicitly before asynchronous resource-group removal:

```powershell
./scripts/teardown.ps1 -Yes
```

If retaining the rest of the lab, delete the Observability Agent before its dedicated workspace and remove its subscription role assignment. Confirm that no billable investigation is still running.

## References

- [Azure Monitor Copilot Observability Agent: What's new at Build](https://techcommunity.microsoft.com/blog/azureobservabilityblog/azure-monitor-copilot-observability-agent-what%E2%80%99s-new-at-build/4522927)
- [Autonomous operations - Azure Copilot Observability Agent](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-autonomous-operations)
