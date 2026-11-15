# Agentic AI observability: three evidence-led demos

Use GitHub Copilot CLI, Azure Monitor/Application Insights, and optional Azure specialist agents to investigate three problems:

1. **Follow the time:** a successful task hides retries and unnecessary work.
2. **Follow the decision:** a successful tool call performs the wrong task.
3. **Follow the tokens:** successful answers consume more tokens per execution.

The reusable method is **Observe -> Investigate -> Challenge -> Act with approval -> Verify**.
The presenter or operator triggers scenarios, approves investigations, checks the evidence, and controls any next action. The troubleshooting assistant helps analyze; it does not automatically conduct the entire demonstration.

## What is real, and what is simulated?

| Demo | Execution | Evidence and limitations |
|---|---|---|
| Retry amplification | Deterministic synthetic model/tool spans | Real telemetry ingestion; simulated attempts, statuses, token counts, and delays |
| Wrong tool selection | Deterministic synthetic model/tool spans | Real telemetry ingestion; expected tool and task outcome are defined by the scenario |
| Token growth | Real, billable Foundry agent calls with synthetic input | Returned run usage and actual elapsed time; no real customer data or downstream tool execution |

A request normally has one trace containing multiple spans. Separate executions produce separate traces; comparison traces are not one continuous workflow.

Broken/Fixed profiles in the first two demos demonstrate controlled comparisons, **not an actual backend repair**. The third demo demonstrates observed token growth, not automatically a persistent regression, a fired alert, or an SRE-executed mitigation.

## Prerequisites and preparation

- An accessible [Lab Control Center](LAB-CONTROL-CENTER.md) with the deployed **Foundry Playground -> Troubleshooting scenarios** panel.
- Application Insights telemetry ingestion and read access to the actual linked workspace.
- For demo 3, a completed [AI stage](STAGE-AI.md), an available tool-free lab agent, and permission to approve billable calls.
- Authenticated GitHub Copilot CLI opened in this repository. Select the existing [application-troubleshooter](../.github/agents/application-troubleshooter.agent.md) with `/agent`.
- Configure Monitor/inventory MCP in CLI using [scenario 68](DEMO-SCENARIOS.md#s68). VS Code MCP configuration is not automatically inherited by standalone CLI.
- For specialist collaboration, follow [scenario 72](DEMO-SCENARIOS.md#s72) and the [SRE stage](STAGE-SRE-AGENT.md). Verify the selected SRE Agent's tools, access, and retained action approvals before dispatch.
- Observability Agent is optional; see the [Observability Agent stage](STAGE-OBSERVABILITY-AGENT.md).

Do not deploy, grant roles, change authentication context, or enable autonomy just to make a live demo work. Complete any necessary setup separately with the appropriate approvals.

### Operator checklist before presenting

1. Verify the intended tenant, subscription, resource group, Control Center, Foundry project, Application Insights component, and linked workspace. Do not assume the central lab workspace contains every app's telemetry.
2. Confirm the scenarios below appear in the deployed dropdown. If missing, report the version/setup gap; typing a scenario name into an AI prompt will not activate it.
3. Rehearse the CLI agent and tool connections. Keep tool approvals enabled; the profile's instructions are not a security boundary.
4. Prepare Broken and Fixed traces for demos 1 and 2. For demo 3, prepare baseline executions and one explicitly approved context-heavy batch.
5. Wait for ingestion and confirm the evidence is queryable. Record trace IDs, run IDs, batch ID, agent/model, profiles, and exact UTC windows outside source control.
6. Bookmark relevant portal views, enlarge terminal/browser fonts, and prepare screenshots or a recording as fallback. Label recorded evidence when used.
7. Do not display secrets, whole configuration files, customer payloads, or credentials. Use synthetic content and sanitized handoff summaries.

### Suggested live timing

| Segment | Time |
|---|---|
| Healthy trace and agent selection | 4 minutes |
| Demo 1: retry amplification | 13 minutes |
| Demo 2: wrong tool selection | 7 minutes |
| Demo 3: token growth and optional SRE handoff | 9 minutes |

These are live-demo budgets within a 60-minute session, leaving time for concept introductions, the lab overview, and questions. Prepare evidence beforehand: model calls, ingestion, and specialist responses may exceed the live budget.

## Approval rules for every demo

1. **Generation:** the operator explicitly approves synthetic telemetry or billable model usage in the Control Center.
2. **Investigation:** the custom agent displays its numbered read-only plan. Review it and separately approve starting the investigation.
3. **Specialist dispatch:** creating or starting an SRE thread needs separate approval; telemetry investigation approval does not cover it.
4. **Change:** any resource/configuration change requires a separate exact proposal covering target, impact/cost, rollback, and verification. None is required for the basic walkthrough.

If the agent asks to broaden scope, change authentication, or generate more calls, decide explicitly before it proceeds. Do not automatically approve pending SRE actions.

## Demo 1: correct answer, three attempts

**Question:** What does eventual success hide?

### Operator steps: generate and capture

1. Open **Control Center -> Foundry Playground -> Troubleshooting scenarios**.
2. Set **Failure** to **Retry loop and token amplification**.
3. Select **Broken**, check the synthetic metadata-only telemetry consent, and click **Generate Trace**.
4. Save the trace ID and UTC run time before the next run overwrites the displayed result.
5. Repeat with **Fixed** and save its trace ID. Use the prepared comparison if live generation fails.

The broken execution records:

```text
customer_support_agent
  model:retry_decision
  order_lookup -> 503
  model:retry_decision
  order_lookup -> 503
  model:retry_decision
  order_lookup -> 200
```

| Evidence | Broken | Fixed |
|---|---|---|
| Model/tool attempts | 3 / 3 | 1 / 1 |
| Retries | 2 | 0 |
| Synthetic input/output tokens | 900 / 75 | 300 / 25 |
| Final task | Successful | Successful |

Use actual recorded durations. The scenario's Performance result also incorporates scenario-defined degradation; do not assume it is solely a calculation against the request latency budget.

### CLI investigation prompt

Replace all placeholders before submitting:

```text
Investigate execution efficiency for this completed task.

Tenant/subscription: <VERIFIED IDS>
Application Insights/application: <VERIFIED TARGET>
Broken trace: <TRACE_ID>
Fixed comparison trace: <TRACE_ID>
UTC window covering both executions: <START AND END>

Present a numbered read-only investigation plan and wait for my approval.
After approval:
1. Reconstruct model and tool operations in order.
2. Identify failed attempts hidden by eventual success.
3. Compare retries, elapsed time, recorded tokens, and task outcome.
4. Verify trace hierarchy and explain any missing evidence.
5. Separate observed facts from hypotheses about the dependency.
6. Propose the next discriminating check and verification criteria.

These are synthetic lab executions. Recorded tokens are not actual billing.
Do not modify resources, generate calls, or create specialist threads.
```

### Operator steps: inspect and challenge

1. Review and approve the displayed plan.
2. Let Copilot query the scoped evidence, then open the broken trace in Application Insights.
3. Point to the two failed tools followed by success. Check a reported count or duration yourself.
4. Paste the follow-up:

```text
You proved that retries happened. What proves why the tool failed?
Give evidence for and against the leading cause, and one next check.
Do not infer a real backend outage from synthetic status codes.
```

5. Show the Fixed trace and the comparison. Explain that its tool succeeds on the first attempt: changing retry policy alone has not been proven to repair an unavailable dependency.

**Takeaway:** final status is not execution efficiency. A meaningful real mitigation needs evidence of the underlying failure and a bounded retry policy; do not reflexively restart or scale.

### Optional visual: parallel fan-out

If time permits, generate **Parallel tool fan-out -> Broken** in the same panel. Three tools overlap: customer lookup, inventory lookup, and a slower order lookup. Ask:

```text
For trace <TRACE_ID>, identify overlapping operations and the critical path.
Explain why summing dependency durations misrepresents elapsed time.
Which branch would most reduce the wait if improved?
```

Use this instead of extending the retry discussion, not as a required fourth demo.

## Demo 2: successful call, wrong tool

**Question:** Would an availability dashboard catch this?

### Operator steps

1. In **Troubleshooting scenarios**, select **Wrong tool selection -> Broken**.
2. Approve synthetic telemetry, click **Generate Trace**, and save the trace ID/time.
3. Prepare or generate **Fixed** and record the second trace.
4. Show the Technical and Task results without immediately revealing the mismatch.
5. Ask Copilot to investigate using the prompt below and approve its displayed plan.
6. In Application Insights, inspect the selected tool, expected tool, selection correctness, and task outcome.
7. Compare with Fixed. Do not claim the model or prompt was actually repaired.

```text
Investigate task correctness.

Tenant/subscription: <VERIFIED IDS>
Application Insights/application: <VERIFIED TARGET>
Broken trace: <TRACE_ID>
Fixed trace: <TRACE_ID>
UTC window: <START AND END>

Present a numbered read-only plan and wait for approval.
After approval, compare selected tool, expected tool, dependency status,
technical success, and task success. Identify the mismatch from evidence
and report uncertainties. Do not infer hidden model reasoning.

These are synthetic scenarios with an explicit expected-tool label.
Do not modify resources, invoke models, or create specialist threads.
```

Expected contrast:

| Evidence | Broken | Fixed |
|---|---|---|
| Customer intent | Order status | Order status |
| Selected tool | inventory_lookup | order_lookup |
| Dependency execution | Successful | Successful |
| Task | Failed | Successful |

Challenge prompt:

```text
If the dependency call succeeded, what evidence shows the task failed?
Which correctness judgment comes from the scenario's expected-tool label?
What ground truth would a production application need?
```

**Takeaway:** HTTP 200 is not task success. Production correctness requires trustworthy rules, tests, evaluations, or other ground truth; ordinary telemetry does not universally judge an answer.

## Demo 3: correct answers, more tokens

**Question:** Did more executions complete, or did each execution consume more?

Use [scenario 65](DEMO-SCENARIOS.md#s65). This makes real, billable Foundry calls with synthetic context, unlike the simulated tokens in demo 1.

### Operator steps: establish a baseline

1. In **Foundry Playground -> New task**, select an available agent, preferably **FinOps Q&A**.
2. Explicitly approve billable usage and submit:

```text
Using this synthetic example, identify one token-cost risk,
one monitoring check, and one guardrail. Reply in three concise bullets.
```

3. Record trace/run ID, UTC start/completion times, agent/model, input/output tokens, and duration.
4. If approved, collect a few baseline executions rather than relying on one. Keep agent and prompt shape consistent and record the total number of calls.

### Operator steps: generate the context-heavy batch

1. Find **Token anomaly generator** in Foundry Playground.
2. Select the same agent and **3 calls** initially.
3. Approve the billable batch and select **Generate Token Anomaly**.
4. Save the batch ID, completed-call count, reported usage, and exact UTC window. Include starts and completions where possible; do not accidentally exclude the first run's start.
5. Wait for telemetry ingestion before investigating.

The generator constructs repeated synthetic context and requests three concise bullets. The live-agent path is tool-free: it does not query real customer, shipping, or inventory systems.

Stopping requests cancellation; submitted usage may still be billed. An incomplete or ambiguous run is not automatically replayed. Record returned usage and the gap rather than resubmitting blindly.

A small batch is **not guaranteed** to cross the static token alert threshold or trigger dynamic anomaly detection. Use the AI FinOps workbook and any actual alert evidence, but never depict an alert that did not fire.

### Step 3: Copilot investigation prompt

```text
Investigate a controlled token-usage increase.

Tenant/subscription: <VERIFIED IDS>
Foundry account/project: <VERIFIED TARGET>
Application Insights and linked workspace: <VERIFIED TARGETS>
Agent/model: <REPORTED IDENTITY>
Baseline UTC window and run/trace IDs: <WINDOW AND IDS>
Batch UTC window: <START AND END>
Batch ID: <BATCH_ID>

Present a numbered read-only investigation plan and wait for approval.
After approval:
1. Verify scope, schema, execution identity, and measurement sources.
2. Compare input/output/total tokens per completed execution, counts,
   latency, and observed failures.
3. Distinguish completion volume from incoming request volume.
4. Inspect retry/cache evidence only where actually available.
5. Check historical model/agent changes where supported.
6. Separate observations from hypotheses and report sample limitations.

Do not modify resources, change authentication, invoke models,
generate additional traffic, or create SRE threads.
Do not treat token estimates as billing or a small sample as a
persistent regression.
```

Review and approve the plan. Check a token total and cohort filter yourself, preferably using `AgentPlaygroundCompleted` records and distinct run IDs. Do not double-count tokens copied onto both completion events and dependency spans. Missing usage is unknown, not zero. Account metrics have different aggregation windows and may not exactly reproduce execution cohorts.

### Step 4: challenge the accounting and causality

```text
Decompose the increase in mean total tokens per completed execution:
input delta, output delta, and each delta's share of total growth.

Verify what output tokens measure in this instrumentation, including
whether reasoning tokens are included. Do not infer displayed answer
length from usage totals alone.

Distinguish the observed larger input from any hypothesis about a higher
completion-token ceiling. Check whether observed usage demonstrates a
ceiling-binding effect. Use existing evidence only.
```

The current implementation copies Foundry `PromptTokens`/`CompletionTokens` into usage telemetry. Normal tasks permit 2,048 completion tokens; token-anomaly tasks permit 4,096. Verify deployed behavior before attributing differences to local source. A higher maximum is not proof of increased consumption, and an absent reasoning breakdown leaves that contribution unresolved.

### Rehearsal example, not a guaranteed result

| Mean tokens per completed execution | Baseline (1 run) | Batch (3 runs) | Increase |
|---|---:|---:|---:|
| Input | 122 | 912 | 790 |
| Output | 894 | 1,425.33 | 531.33 |
| Total | 1,016 | 2,337.33 | 1,321.33 |

Total tokens grew about **2.30x**. Input accounted for **59.8%** of additional tokens and output for **40.2%**. These are shares of token growth, not cost. The decomposition does not prove input growth caused output growth.

All observed output totals in that rehearsal were below the original 2,048 ceiling; no ceiling-binding effect was demonstrated. One baseline versus three batch completions cannot establish persistence. Replace these values with your own measurements.

### Step 5: optional SRE Agent MCP handoff

Give the specialist a concrete job: challenge the interpretation and propose the smallest useful next check, rather than repeat the entire report.

```text
Prepare an SRE Agent investigation handoff using the verified targets,
UTC windows, batch ID, run/trace IDs, and sanitized findings above.

Ask the specialist to:
1. Challenge the token-growth interpretation.
2. Identify the smallest discriminating next check.
3. Propose a controlled comparison with explicit success criteria.

Report the cohort sizes, input/output contributions, observed limits,
and unresolved retry/cache/reasoning and deployment-parity evidence.

Discover the supported MCP schemas and exact SRE target. Verify retained
action approvals and check for an ongoing investigation/action.
Present the handoff and request my separate approval before creating or
starting an SRE investigation. If approvals cannot be verified, do not
dispatch; provide a manual handoff and explain the gap.

Investigation only: no model calls, resource changes, role grants,
configuration changes, auto-approval, or YOLO mode.
```

Operator actions:

1. Review the proposed target and packet, then separately approve dispatch if safe.
2. Use supported approval-preserving tools, not guessed endpoints or tool arguments.
3. Capture the returned thread ID and reuse it for at most three follow-ups.
4. Read actual thread findings. Listing threads or reading agent metadata is not a completed specialist investigation.
5. If SRE lacks telemetry access, label its analysis as based on the supplied evidence packet. Do not claim independent verification.
6. Surface any action request without accepting it. Investigation consent does not approve mitigation.

Useful specialist follow-up:

```text
Using existing evidence only, what comparison would distinguish larger
input from output variability? State the variables to hold constant,
required sample information, and which conclusions remain unproven.
Do not run the proposed experiment.
```

### Step 6: optional controlled comparison and verification

The generator is not a clean input-only experiment because its completion ceiling differs from normal tasks. For a cleaner comparison, use **New task** for both compact and expanded synthetic inputs with the same agent, output requirements, and normal run limits.

1. Present the planned prompts, call count, cost implications, and success criteria.
2. Obtain separate approval for additional billable calls.
3. Keep agent/model and instructions unchanged where verified; record any unknown version or configuration differences.
4. Compare tokens per completed execution, latency, and answer usefulness over multiple runs. Do not assume output usage is deterministic.
5. Treat unknown retries, cache behavior, and reasoning usage as gaps.
6. Report the comparison as an input experiment, not an SRE-executed code repair.

**Takeaway:** measured growth is not proven cause. A useful answer can still consume excessive context, but an operational regression needs comparable workloads and stronger evidence.

## Finding and cross-checking traces

In Application Insights **Logs** (resource scope), replace the trace ID:

```kusto
union requests, dependencies
| where timestamp > ago(1h)
| where operation_Id == "<TRACE_ID>"
| order by timestamp asc
| project timestamp, itemType, name, id, operation_ParentId,
          duration, success, resultCode, customDimensions
```

For a token batch, use completion records in the same resource scope:

```kusto
customEvents
| where timestamp > ago(1h)
| where name == "AgentPlaygroundCompleted"
| where tostring(customDimensions["batch.id"]) == "<BATCH_ID>"
| project timestamp, operation_Id,
          RunId=tostring(customDimensions["run.id"]),
          Agent=tostring(customDimensions["gen_ai.agent.name"]),
          Model=tostring(customDimensions["gen_ai.response.model"]),
          InputTokens=todouble(customMeasurements["gen_ai.usage.input_tokens"]),
          OutputTokens=todouble(customMeasurements["gen_ai.usage.output_tokens"]),
          DurationMs=todouble(customMeasurements["duration_ms"])
| order by timestamp asc
```

Inspect schema first. Linked-workspace queries use `AppRequests`, `AppDependencies`, and `AppEvents`, with different field names. Do not mix schemas. In a shared workspace, filter verified resource and app identity. Account for sampling, duplicates, missing usage, and ingestion lag before aggregating.

For the baseline, filter its recorded run IDs and exact UTC window; do not treat every non-batch event as baseline.

## Optional Observability Agent portal comparison

For demos 1 and 2, use **Copy Trace Prompt** and **Open Observability Agent** if configured. For demo 3, supply the same scoped comparison packet through the supported portal experience.

The documented baseline is portal resource-scoped chat, not a direct CLI-to-Observability-Agent connection. Label manual transfer as a human-mediated handoff. Reading Observability Agent metadata does not mean it investigated the incident.

Ask it to distinguish evidence, hypotheses, gaps, and next checks. Cross-check one conclusion yourself; a specialist recommendation does not authorize a change.

## Fallbacks and end-of-demo checklist

- **Missing scenario or agent:** report the deployed-version/setup gap and use prepared evidence. Do not silently substitute a different workload.
- **No telemetry:** verify target/window and ingestion before concluding anything; no rows is not health.
- **Tenant mismatch or permission failure:** report it. Any authentication change requires explicit approval; do not automatically grant roles.
- **Slow SRE response:** show the handoff and evidence already gathered. Say specialist verification is pending.
- **No alert:** show measured token growth without claiming alert detection.
- **Incomplete Foundry run:** report status and any returned usage; do not automatically replay.
- **Live timing exceeded:** use labeled recordings or saved traces, not fabricated results.
- **End state:** stop any active batch, record pending checks, and verify that no unapproved changes were made. No lab teardown, rollback, or configuration reset is required by these basic demos.

Close with: **The assistant accelerates investigation. Evidence earns confidence. Verification establishes the outcome.**
