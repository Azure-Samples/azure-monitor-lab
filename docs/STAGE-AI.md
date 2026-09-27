# Stage AI — Optional Microsoft Foundry GenAI workload

> **Goal of this stage:** add a real **GenAI workload** to the lab so the observability stack has token/trace/cost telemetry to reason about — the "AI FinOps" story. It layers a Microsoft Foundry account + models, wires them into the lab's Application Insights, and lands token-spike alerting plus an AI FinOps query pack, workbook, and health model. Fully **opt-in** and **off by default** (it deploys billable models).
>
> **Depends only on Stage A** (it connects to `appi-amlab`). Pinned to **swedencentral** regardless of the lab region, because the `gpt-5-*` / `model-router` SKUs, the Foundry portal, and the CloudHealth preview are region-limited — the same reason the workload Health Model is pinned.

## 1) What gets created

| Group | Resource(s) | Purpose |
|---|---|---|
| Foundry workload | `ai<amlab><suffix>` (AI Services account) + `amlab-ai-proj` project, both swedencentral | The GenAI control plane. Project management enabled; system-assigned identity. |
| Model deployments | `gpt-5-mini` (chat), `text-embedding-3-small` (embeddings), `gpt-5.4` (optimization), **`model-router`** — all `GlobalStandard` | The models the agents + traffic simulator exercise. `model-router` picks a cheaper/stronger underlying model per request. |
| Tracing connection | Project → `appi-amlab` Application Insights connection | Lights up the Foundry portal Observability/Tracing tab and lands `gen_ai.*` spans in the lab App Insights. |
| Token alerts | `alert-amlab-token-anomaly` (dynamic threshold) + `alert-amlab-token-spike` (static ceiling) on the account's `TotalTokens` metric, split per deployment | Anomaly detection + a hard guardrail for runaway token spend. Optional `ag-amlab-ai` action group when `alertEmail` is set. |
| AI FinOps observability | `qp-ai-finops` query pack (14 GenAI KQL queries) + a shared **AI FinOps workbook** | Token usage, cached-token ratio, model-router distribution, tokens per successful request, an illustrative rate-configured PTU comparison, and latency/error percentiles. |
| AI health tier | An **"AI" tier folded into the workload health model** (`hm-amlab-workload`): an `aiworkload` node → the Foundry account entity (Latency / TotalErrors / TotalTokens metric signals) + 4 agent entities carrying error-rate + token-volume Log Analytics signals | One health model for the whole estate — the AI workload rolls up next to frontend/compute/platform; high token volume or error rate turns an agent unhealthy. A separate `ai-healthmodel.bicep` exists as an opt-in fallback for standalone A+AI deployments (no Stage E). |
| Agents + traffic | 4 agents (`Support Triage`, `FinOps Q&A`, `Doc Summarizer`, `Context-Rich Assistant`) + a traffic simulator, provisioned by `scripts/setup-ai.ps1` | Generates the live token/trace/cost telemetry the queries, workbook, health model, and alerts consume. Python packages listed in [`workloads/ai/requirements.txt`](../workloads/ai/requirements.txt) are pip-installed first. |

> Cross-stage references: `appi-amlab` and its backing App Insights LAW (Stage A). No dependency on Stages B–E; the AI stage creates its own action group.

## 2) Speaker notes

1. **"This is the observability stack pointed at AI spend."**
   Everything in Stages A–E is infra/platform telemetry. Stage AI adds the *GenAI* pillar: tokens are the new unit of cost, and this stage treats them exactly like any other signal — queried, charted, alerted, and rolled up into a health model.

2. **"swedencentral on purpose."**
   Call out that only the AI resources move to swedencentral (co-located with the workload Health Model); the rest of the lab stays in its region. One resource group, mixed regions — a normal Azure pattern.

3. **"model-router is the cost lever."**
   Open the *Model router routed-model distribution* query. Easy prompts get a cheap model, hard prompts a strong one — surfaced as `gen_ai.response.model`. Even a modest routing rate compounds into real savings.

4. **"Prompt caching can reduce input cost."**
   The `Context-Rich Assistant` uses a >1024-token static system prompt, so repeated calls can hit the prompt cache. Show the *Cached-input token ratio* query, then use the actual model's current cached-input rate for the saving.

5. **"Token alerts = guardrails before the bill."**
   Two alerts on `TotalTokens`: a dynamic-threshold anomaly detector that learns each deployment's baseline, and a static ceiling as a hard stop. Trigger it live by running the simulator hot (`--conversations 100 --interval 5`).

6. **"One health model, AI included."**
   The AI workload is folded into `hm-amlab-workload` as a fourth **AI** tier (alongside frontend/compute/platform). The 4 agent entities carry error-rate and token-volume signals. Frame the CloudHealth blade as executive dashboarding (preview; API still moving).

## 3) Portal walkthrough (UI)

1. **Foundry portal (`ai.azure.com`) → project `amlab-ai-proj` → Observability / Tracing** — show agent runs, token consumption by model, and traces from the simulated conversations.
2. **`appi-amlab` → Logs** — run a query from the `qp-ai-finops` pack (Queries hub), e.g. *Token usage by agent (24h)* or *Model router routed-model distribution*.
3. **Monitor → Workbooks → Shared → "AI FinOps — Foundry Agents"** — time-range picker, token/efficiency tiles, token-share pie, and rate-configured PTU comparison.
4. **Monitor → Alerts → Alert rules** — `alert-amlab-token-anomaly` + `alert-amlab-token-spike`.
5. **Monitor → Health models → `hm-amlab-workload`** *(preview)* — open the graph; show the **AI** tier (`aiworkload` → Foundry account + 4 agent entities) rolling up alongside frontend/compute/platform.

## 4) CLI validation

```powershell
$sub = '<your-subscription-id>'
$rg  = 'rg-azure-monitor-lab'   # or your test RG
az account set --subscription $sub

# Foundry account + model deployments (incl. model-router)
$acct = az cognitiveservices account list -g $rg --query "[?kind=='AIServices'].name | [0]" -o tsv
az cognitiveservices account deployment list -g $rg -n $acct --query "[].{name:name,model:properties.model.name,version:properties.model.version,sku:sku.name}" -o table

# Query pack (14 queries) — count via az rest (avoid --query on Windows az.cmd with ? URLs)
$qp = az resource list -g $rg --resource-type Microsoft.OperationalInsights/queryPacks --query "[?starts_with(name,'qp-ai-finops')].name | [0]" -o tsv
$url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/queryPacks/$qp/queries?api-version=2019-09-01"
(az rest --method get --url $url | ConvertFrom-Json).value.Count   # -> 14

# Token alerts
az monitor metrics alert list -g $rg --query "[?contains(name,'token')].{name:name,enabled:enabled}" -o table

# AI health model
az resource list -g $rg --resource-type Microsoft.CloudHealth/healthmodels --query "[?ends_with(name,'-ai')].{name:name,location:location}" -o table

# Telemetry landed? (after running scripts/setup-ai.ps1, allow a few minutes)
az monitor app-insights query --app appi-amlab -g $rg --analytics-query "dependencies | where timestamp > ago(1h) | extend agent=tostring(customDimensions['gen_ai.agent.name']) | where isnotempty(agent) | summarize calls=count() by agent" --query "tables[0].rows" -o json
```

## 5) Done-when

1. The Foundry account has **4** model deployments including `model-router`, all `GlobalStandard`.
2. `qp-ai-finops` contains **14** saved queries and the AI FinOps workbook is visible under Monitor → Workbooks → Shared.
3. `alert-amlab-token-anomaly` and `alert-amlab-token-spike` exist and are enabled.
4. `hm-amlab-workload` renders in the Health Models preview blade with an **AI** tier (`aiworkload` → Foundry + 4 agent entities) alongside the original frontend/compute/platform tiers.
5. After `scripts/setup-ai.ps1`, App Insights `dependencies` shows `gen_ai.agent.name` spans for all agents plus Model Router.

## 6) Enable + run

[AI setup](../scripts/setup-ai.ps1) installs the [Python dependencies](../workloads/ai/requirements.txt), reuses or creates the four matching agents, then starts a finite background batch of 150 conversations. `-Conversations` changes the finite batch size. `-SkipTraffic` prepares agents without traffic. The legacy `-BackgroundTraffic` switch is accepted but no longer needed; false does not restore foreground mode.

**Bicep one-shot:** set `stageToggles.enableStageAI = true` in the central config. [The deployment script](../scripts/deploy.ps1) prepares console agents/access before publication, validates selected SRE resources, then starts background AI traffic as its final step.

**Terraform:** set `enable_stage_ai = true` and follow [the Terraform runbook](DEPLOY-TERRAFORM-STEP-BY-STEP.md#step-7---enable-stage-ai-optional). With B enabled, apply refreshes console inventory/access and prepares agents with `-SkipTraffic`, including when AI is added later. No second console wrapper is required. Optional traffic is a separate background setup invocation. Without B, use the standalone AI helper to prepare agents.

**Raw Bicep:** follow [the Stage AI preview, deploy, and completion sequence](DEPLOY-BICEP-STEP-BY-STEP.md#stage-ai-deploy-optional). It uses the dedicated AI template's parameter schema, refreshes an existing Web App before optional traffic, and skips Web App work for an A+AI lab. Do not pass the entire main parameters file to the AI template.

**Portal/Cloud Shell:** finish the [portal deployment and Cloud Shell wrapper](../README.md#option-1-deploy-to-azure-portal-no-local-setup) first. Then request optional traffic with the [AI Cloud Shell helper](../scripts/setup-ai-cloud-shell.ps1), which verifies and forwards account context and uses core ARM discovery without optional CLI extensions:

```powershell
./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId $sub -ResourceGroup $rg -NamePrefix amlab
```

The Cloud Shell helper also works locally. Both helpers return after the worker acknowledges startup, not after the conversations finish. The PID and log/status paths are printed; keep the host and its Azure CLI sign-in available. Cloud Shell or CI termination can interrupt traffic, there is no automatic restart, and each invocation starts a new billable batch. The worker runs on the deployment machine, not in the Web App or an Azure job. Its status and logs are stored under `%LOCALAPPDATA%/azure-monitor-lab/ai-traffic` on Windows or `$XDG_STATE_HOME/azure-monitor-lab/ai-traffic` on Linux, defaulting to `~/.local/state`. A `running` status confirms startup only; inspect the log for successful model responses.

When adding AI after Stage E, rerun Stage E with `enableAi=true` to add its AI health tier. An A+AI deployment can instead opt into Stage AI's separate health model with `enableHealthModel=true`. Neither health-model option is required for the Foundry Playground; that console tab requires Stage B plus AI.

Verify the Model Router version available in the chosen AI region before deployment. Supply `routerModelVersion` through the staged helper's nonsecret overrides, or `router_model_version` in Terraform, when the default is no longer available.

## 7) Tear-down nuance

- Deleting the resource group removes everything. CognitiveServices accounts are **soft-deleted** — if you plan to redeploy the same name, purge it: `az cognitiveservices account purge -l swedencentral -g <rg> -n <account>`.
- The health model's role assignments (Reader / Monitoring Reader / Log Analytics Reader on the RG) are removed with the RG.
- Agents created by `setup-ai.ps1` live in the Foundry project and go with the account; `workloads/ai/agents.json` (their ids) is git-ignored local state.
- To stop token spend without deleting anything, just stop the traffic simulator — models bill per token, near-zero when idle.
