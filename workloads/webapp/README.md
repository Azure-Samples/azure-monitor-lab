# Azure Monitor Lab Control Center

The ASP.NET Core 8 app serves **Azure Monitor Lab Control Center** at `/`. Five keyboard-accessible tabs separate Infra Health (first/default), Traffic & Faults, Lab Operations, SRE MCP Assistant, and Foundry Playground. It runs in the existing App Service and uses the existing Application Insights integration. Normal deployment configures operator sign-in, health access, an independent Azure job runner, and available optional agents automatically. Basic traffic actions remain anonymous; protected operations require an approved operator.

Start with the [Control Center guide](../../docs/LAB-CONTROL-CENTER.md) for the application overview, screenshot, and scenario mapping. This page is the technical reference for configuration, local development, deployment, and runtime limits. The shared environment strip reuses existing context/catalog calls; it does not perform background model requests. Guide and Related Scenarios links open repository documentation without executing actions.

## Customer Usage Journey

`/customer/` is a separate customer-facing experience hosted by the same App Service and exported to the same Application Insights component. It keeps operator activity out of the product funnel while preserving browser-to-server W3C correlation. The six-step journey emits page views and business events for home, catalog, product selection, cart, checkout, and purchase completion, with optional support-agent detours and deterministic payment decline.

All users, sessions, products, orders, segments, and A/B variants are synthetic. The browser calls `setAuthenticatedUserContext` with a validated `demo-user-*` identifier so the native Users experience can correlate repeat browser contexts without recording a real identity. Prompt/completion content, request/response headers, and payment details are not collected.

Generate a realistic mix of completed, abandoned, declined, support-assisted, and repeat journeys:

```powershell
./scripts/generate-usage-traffic.ps1 `
  -BaseUrl https://app-amlab-<suffix>.azurewebsites.net `
  -Users 24 `
  -RepeatUsers 6
```

The generator uses isolated Chromium contexts and drives the actual customer UI; it does not post fabricated telemetry directly. Install the existing browser-test dependencies first if needed with `npm ci --prefix workloads\webapp` and `npx --prefix workloads\webapp playwright install chromium`. Application Insights ingestion and Usage aggregation can take several minutes.

## Lab Operations

The [Lab Operations reference](LAB-OPERATIONS.md) covers eight scripts, including cost-aware Start/Stop controls and a bounded CPU simulation on both demo VMs, automatic Azure Container Apps Job provisioning, managed identities, persistent history, exact-operation approvals, and recovery. Normal deployment builds and pins the runner image, configures access, and enables the tab. No GitHub credentials or manual runner setup are required; no shell is exposed through the Web App.

## Infrastructure Health

`GET /api/infra/health` performs read-only checks against one configured lab resource group. It uses `Azure.Identity` with system-assigned managed identity when hosted and `AzureCliCredential` locally, plus `Azure.Monitor.Query.Logs` for fixed workspace queries. The backend never accepts a resource scope, endpoint, time range, or KQL query from the browser.

The tab includes only `Microsoft.Compute/virtualMachines`, `Microsoft.Compute/virtualMachineScaleSets`, `Microsoft.ContainerService/managedClusters`, and `Microsoft.Web/sites`. This case-insensitive filter is applied before selecting telemetry queries and computing the response, so supporting resources do not appear in rows or status totals. The tab combines Azure Resource Health availability with the existing [workbook](../../infra/modules/workbook.bicep) thresholds for VM heartbeats, AKS node/pod reporting, and App Service HTTP 5xx. Signals join by resource ID, not resource name. Read failures, absent telemetry, and partial query results remain explicit. Provisioning success is not an availability signal. The [Control Center guide](../../docs/LAB-CONTROL-CENTER.md#infrastructure-health) explains thresholds and limitations.

### Hosted Access

The normal deployment bootstrap discovers the central workspace, configures single-tenant sign-in, grants the app **Reader** on the lab resource group and **Log Analytics Reader** on its workspaces, and enables health after setup succeeds. This works without AI or SRE stages. The deploying user becomes the default operator; automation supplies `ConsoleOperatorObjectIds` or Terraform's `console_operator_object_ids` as deployment inputs.

The caller needs role-assignment and app-configuration permissions, plus permission to manage the sign-in registration under the tenant's policy. A setup failure stops deployment. Allow Azure RBAC and telemetry propagation before treating missing data as a workload fault. The existing [health access helper](../../scripts/setup-webapp-health-access.ps1) remains available for targeted administrative repair; it is not required after a successful normal deployment.

The shared backend identity can read metadata across this lab and logs in the assigned workspaces. The API fixes the scope and returns only aggregates; this is not delegated browser-user access. Disabling `LabConsole__Health__Enabled` stops future queries but does not revoke existing roles.

### Configuration And Limits

| Setting | Value |
|---|---|
| `LabConsole__Health__Enabled` | Set to `true` by deployment; unconfigured/local builds default to `false` |
| `LabConsole__Health__SubscriptionId` | Expected lab subscription GUID |
| `LabConsole__Health__TenantId` | Intended Azure CLI tenant for local runs; stored by hosted setup too |
| `LabConsole__Health__CentralWorkspaceResourceId` | Full ARM ID of the central workspace in this lab resource group |
| `LabConsole__Health__AppInsightsWorkspaceResourceId` | Retained for setup compatibility; the infra-only view does not query this workspace |
| `LabConsole__ResourceGroup` | Resource group used by the existing console context |

For local access, use the existing config helper with `-EnableInfrastructureHealth -TenantId '<lab-tenant-id>'`, or set the health environment variables before starting the app. Local requests require loopback IP and Host; hosted requests use the existing authenticated operator allowlist. Use the intended signed-in Azure CLI account with read access. Do not overwrite an existing local agent configuration without preserving its settings.

The UI checks once on first opening and offers manual refresh. A per-instance semaphore coalesces concurrent checks; snapshots are cached for 60 seconds and top-level failures for 15 seconds. The endpoint allows 30 requests per minute per app instance. One check is bounded by 45 seconds, at most 10 pages / 500 resources per ARM list, and at most three concurrent fixed telemetry queries against the central workspace. Each Logs query has a 15-second server timeout, a one-hour upper time range, a 500-row cap, and at most one SDK retry. Pagination cannot change the ARM host or scoped path; redirects are disabled. No background queries or model calls are scheduled. Usual Azure Monitor data/query charges and workspace policies still apply.

Snapshot age and failed refreshes remain visible. Platform reports older than 30 minutes are unknown. Missing tables are not created; missing or partial queries are discarded for that signal. VM scale sets use platform availability only; other supporting resource types and out-of-group resources such as AKS-managed infrastructure are excluded. This is not the preview Azure Monitor Health Model or an autonomous remediation engine.

The shared **Web app health** header independently probes `/healthz` on initial page load and each accepted Infra Health refresh. The probe bypasses the browser cache, rejects redirects, and times out after 10 seconds. It never contributes to traffic counters, latency charts, or request history, but the server can still record the HTTP request in telemetry. Manual health actions continue to update both the header and traffic results. Clearing traffic preserves the last header result; request sequencing prevents an older response from overwriting a newer check. These probes do not poll in the background or depend on Azure operator access.

References: [Azure Monitor Logs SDK](https://learn.microsoft.com/en-us/dotnet/api/overview/azure/monitor.query.logs-readme?view=azure-dotnet), [Resource Health list by resource group](https://learn.microsoft.com/en-us/rest/api/resourcehealth/availability-statuses/list-by-resource-group?view=rest-resourcehealth-2025-05-01).

## Agent Views

**SRE MCP Assistant** uses an existing Foundry model to select direct Azure MCP management tools and explain their results. Ask about agents, connectors, incidents, scheduled tasks, memories, prompts, and workflows. Read calls run within a bounded question budget. Writes produce an exact tool-and-arguments preview and require a separate one-time approval in the app. Results appear in an operation log. No SRE thread is created, no investigation starts, and no browser evidence is attached. The model is the MCP host, not an SRE investigation agent. See [SRE-MCP.md](SRE-MCP.md) for supported operations, setup, model permissions, limits, and recovery.

**Foundry Playground** invokes existing classic persistent service agents created by [create_agents.py](../ai/create_agents.py): Support Triage, FinOps Q&A, Doc Summarizer, and Context-Rich Assistant. It does not create agents, replace their instructions, or route requests to an unrelated chat-completions endpoint. Each approved task starts a fresh thread. Up to ten results are held in browser memory, with answer text, the model reported by the run, token usage, latency, run ID, and trace ID. Switching tabs preserves local state. Clear removes browser results only.

The backend uses `Azure.AI.Agents.Persistent` and `Azure.Identity`. Catalog discovery does not generate model traffic. Discovery is cached for 60 seconds when available and 15 seconds on failure, scans at most 100 agents newest-first, and includes only known lab names with no tools. Optional `LabConsole:Foundry:AgentIds:<key>` settings pin exact IDs; otherwise the newest matching agent is selected. Missing configuration, identity permissions, or supported agents produce explicit unavailable states.

### Enable Foundry Access

Select Stage AI in the lab deployment. The bootstrap discovers its single project and chat deployment, reuses or creates the four matching agents without sending conversations, grants the Web App **Foundry User** at project scope, and enables the tab. Operator sign-in and allowlists are configured automatically. Ambiguous resource targets or failed agent creation stop deployment rather than selecting an arbitrary project or leaving an empty enabled tab.

Terraform reruns console initialization when the AI stage changes. For a raw staged Bicep deployment, the normal workload completion wrapper publishes the newly selected integrations. No additional Foundry enablement flag or role command is required. The SRE assistant also needs the SRE stage and uses the AI stage's existing host model; see [SRE-MCP.md](SRE-MCP.md).

The UI and resource-discovery helper never create roles or resources; the deployment bootstrap does. HTTPS-only public Foundry endpoints are accepted, and the browser never receives credentials. Hosted calls use system-assigned managed identity; local calls use `AzureCliCredential` and require loopback IP and Host. Generic self-hosted authentication proxies are not supported. Do not trust client-supplied `X-MS-*` headers outside App Service.

For local execution, log into the intended lab tenant with Azure CLI, then set `$env:LabConsole__Foundry__Enabled = 'true'` before starting the app. Alternatively, generate local configuration with the helper's `-EnableFoundryPlayground` switch. Each submitted task still requires explicit billable-usage consent. Tests force execution off and use fake service responses, so they do not spend model tokens.

### Agent Limits And Telemetry

- One concurrent task and six submissions per fixed minute per app instance, not a distributed quota. Invalid submissions count toward the rate limit. Inputs are limited to 4,000 characters and 20,000 request bytes.
- Runs use at most 8,192 prompt tokens and 2,048 completion tokens, with a 90-second deadline. Reasoning tokens may consume the completion budget; incomplete runs are reported as failures rather than silently retried. SDK retries are disabled to avoid duplicate billable run creation.
- The backend rechecks the selected agent and overrides run tools with an empty list. It does not execute function calls or submit tool outputs. Agents with tools are excluded from the catalog and rejected if changed before invocation.
- On completion, failure, timeout, or browser cancellation, the backend attempts to cancel a known active run and delete its own temporary thread within a bounded cleanup window. Cancellation and deletion are best-effort. If a network failure prevents receipt of a created run/thread ID, full cleanup cannot be guaranteed; consult project retention and server cleanup warnings. Previously incurred usage remains billable. Persistent agents themselves are never deleted.
- Usage is taken from the service, never estimated from text. Missing usage is shown as not reported. Cached-token counts are not fabricated because this persistent-agent API does not reliably report them.
- Cost is unavailable by default. Optional `LabConsole:Foundry:Pricing:<reported-model>:InputUsdPerMillion` and `OutputUsdPerMillion` decimal settings enable an estimated USD cost. These are operator-supplied rates, not a live pricing feed, and ignore cached-input discounts. Reconcile estimates against Cost Management.
- The existing Application Insights SDK records HTTP requests/dependencies. Known agent runs also emit a `GenAI` dependency named `invoke_agent`, with `gen_ai.agent.name`, `gen_ai.response.model`, `run.id`, and available token counts in custom dimensions. Successful tasks emit `AgentPlaygroundCompleted` with numerical usage metrics. No prompt or response body is included in these custom records. Sampling and ingestion delay still apply; existing workbook filters may need to include `source=web-console`.

### Application Insights agent investigation

The deterministic troubleshooting catalog has eleven broken/fixed scenarios: slow tool, wrong tool, partial state-changing workflow failure, retry amplification, safe dependency fallback, context explosion, multi-agent handoff, model regression, broken trace propagation, model throttling, and parallel fan-out. These calls do not invoke a billable model. They emit synthetic request, `GenAI`, `OpenAI`, `AgentHandoff`, and `AgentTool` telemetry with separate technical/task/performance/trace outcomes, latency budgets, retries, tokens, versions, cohort, and semantic routing evidence.

The browser Application Insights SDK initializes only when `APPLICATIONINSIGHTS_CONNECTION_STRING` is configured. It uses W3C correlation for same-origin API calls and records page views, browser exceptions, dependencies, and a random session-storage-only synthetic session ID. Cookies and request/response header capture are disabled. Prompt, completion, tool payload, and response body content is never added by this feature. If telemetry configuration is absent or invalid, the UI remains functional and does not report a false setup success.

`GET /api/agent-task-availability` runs the fixed multi-agent handoff profile for the standard availability test. It is anonymous by design, deterministic, rate-limited, metadata-only, and never calls Foundry. Use the `qp-<prefix>-appinsights` query pack and **Application Insights — End-to-End Agent Investigation** workbook to compare broken/fixed outcomes and trace quality. See [Scenario 69](../../docs/DEMO-SCENARIOS.md#s69).

## Interactions

| Control | Endpoint | Result |
|---|---|---|
| Check Health | `GET /healthz` | Web app health and browser round-trip latency, not whole-lab health |
| Agent task availability | `GET /api/agent-task-availability` | Deterministic fixed customer-function trace used by the multi-region availability test |
| Slow Request | `GET /api/slow` | A deliberately delayed response, approximately 1.5-3 seconds |
| Trigger Error | `GET /api/explode` | Intentional HTTP 500 and exception telemetry |
| Test Dependency | `GET /api/dep` | An outbound HTTPS dependency |
| Simulate Checkout | `GET /api/checkout` | Cart metrics and `CheckoutCompleted` event; channel and payment outcome controls |
| Run Inefficient Code | `POST /api/console/performance` | Confirmation-gated CPU/exception/dependency experiment with a cooldown |

Requests update session counts, failure percentage, average latency, the latest 30 latency measurements, and an expandable activity table. The table retains the latest 100 requests; statistics cover the whole session until cleared. Response details include a copyable `X-Amlab-Trace-Id`, matching the server's W3C trace ID and Application Insights operation ID. No response HTML is executed.

Checkout supports `outcome=random`, `outcome=success`, and `outcome=declined`. Omitting the parameter retains the original random behavior, including approximately 5% declined payments. `X-Amlab-Channel` accepts up to 32 ASCII letters, digits, or hyphens. Cart values are illustrative numbers, not billed purchases.

## Traffic And Safety

- Normal traffic cycles through health, successful checkout, and dependency requests. Latency spike mixes health and slow requests. Error burst mixes health and intentional failures.
- Console traffic runs are sequential, capped at 30 requests, and start requests no more often than once per second. Settings offer 1, 2, or 5-second minimum intervals. Slow responses naturally lower throughput.
- Stop prevents future requests. An in-flight server request can still finish. Closing the page also stops the browser-generated run; there is no background server job.
- The browser times out requests after 15 seconds. Server-side outbound HTTP calls time out after 10 seconds.
- The performance control requires confirmation and a 30-second browser cooldown. Its POST endpoint also permits one request per fixed 30-second window per app instance and returns HTTP 429 with `Retry-After` when limited. This is not a distributed quota across scaled-out instances.
- Existing script endpoints, including `GET /api/inefficient`, remain available for compatibility. They are not protected by the new console performance limiter. This is an intentional-failure demo, not a hardened public production application. Use App Service access restrictions or authentication when broader access is inappropriate.
- Session results are kept in browser memory only. Clear resets the UI, not Azure telemetry. Counts cover this browser's actions, not other users or the existing load generator.
- Azure ingestion, sampling, alert evaluation windows, and thresholds still apply. A successful button action does not guarantee an alert. Code Optimizations recommendations require profiling and sufficient traffic and may take hours.

## Run Locally

From this directory, with the .NET 8 SDK or later:

```powershell
dotnet run --no-launch-profile --urls http://localhost:5189
```

Open `http://localhost:5189`. Built frontend assets are kept in `wwwroot`, so Node is not required to run or publish the app. Leave the Application Insights connection string unset for local testing that should not send telemetry to Azure.

After changing frontend source, use Node.js 20 or later:

```powershell
npm ci
npm run build
npx playwright install chromium
npm test
./tests/console-config.Tests.ps1
./tests/webapp-package.Tests.ps1
./tests/webapp-access.Tests.ps1
./tests/webapp-health-access.Tests.ps1
../../scripts/tests/lab-operations.Tests.ps1
../../scripts/tests/lab-operations-execution.Tests.ps1
../../scripts/tests/console-bootstrap.Tests.ps1
../../scripts/tests/console-deployment.Tests.ps1
dotnet test ../webapp.Tests/AmlabHello.Tests.csproj -c Release
```

Playwright starts and stops its own app at `http://127.0.0.1:5188`; keep that port free. Tests force all integrations off and mock service responses, so no jobs, paid traffic, or Azure changes occur. Coverage includes health freshness and failures, API guards, traffic controls, tab navigation, approvals and job status, MCP questions, usage consent, safe rendering, and desktop/mobile screenshots. Unit tests cover scoped ARM requests, pinned job identity/image/inputs, ownership, single-use approvals, persistent journaling, rejected investigations, and the actual model SDK wire format. Bootstrap and deployment tests fake all Azure and Graph calls and exercise failure ordering and automatic configuration.

Commit regenerated `wwwroot` bundles/assets with frontend source changes. `dotnet publish` includes those assets and excludes frontend sources, Node dependencies, tests, and local `lab-console.json`. Packaging generates disabled configuration first; the deployment bootstrap configures access and enables the selected integrations before ZIP publication. App Service uses `dotnet AmlabHello.dll`.

## Monitoring Destinations

To update an existing Web App without reapplying AKS workloads, use [deploy-webapp.ps1](../../scripts/deploy-webapp.ps1). It publishes the current checkout and automatically provisions/configures the console runner, sign-in, and scoped access:

```powershell
../../scripts/deploy-webapp.ps1 `
  -SubscriptionId '<lab-subscription-id>' -TenantId '<lab-tenant-id>' `
  -ResourceGroup '<lab-resource-group>' -WebAppName '<lab-web-app>' -WhatIf
```

Remove `-WhatIf` after reviewing the target and infrastructure/access scope. Unrelated app settings are preserved. Existing operators are retained unless replacement IDs are supplied. To open the deployed console, select the App Service and choose **Browse**.

The shared [post-deploy script](../../scripts/post-deploy.ps1) runs [prepare-webapp-package.ps1](../../scripts/prepare-webapp-package.ps1) followed by [initialize-webapp-console.ps1](../../scripts/initialize-webapp-console.ps1) before creating the ZIP. Packaging verifies assets, discovers context, and bundles the pinned Linux MCP runtime when SRE exists. Initialization provisions the runner, image, authentication, roles, health, and optional agents. Either failure stops publication. See [deployment prerequisites](LAB-OPERATIONS.md#prerequisites).

The four destinations are Application Insights, the central workspace's Logs view, the lab Health Dashboard/Traffic Lights workbook, and the Grafana endpoint. Missing resources remain unavailable; no destination is guessed. Opening them uses the signed-in user's Azure permissions. The Infrastructure Health tab separately fetches its read-only snapshot with the backend identity.

For a local preview with links to an existing lab, run from this directory:

```powershell
../../scripts/write-webapp-console-config.ps1 `
  -SubscriptionId '<lab-subscription-id>' `
  -ResourceGroup '<lab-resource-group>' `
  -OutputPath ./lab-console.json
```

The generated local file is git-ignored. It contains nonsecret resource context, public HTTPS URLs, and the disabled-by-default Foundry setting, never credentials or connection strings. Environment settings such as `LabConsole__Links__ApplicationInsights`, `LabConsole__Links__Logs`, `LabConsole__Links__Workbook`, and `LabConsole__Links__Grafana` override it. Agent destinations use `LabConsole__Links__SreAgent` and `LabConsole__Links__Foundry`. `/api/console/config` exposes only monitoring links and cooldown; `/api/agents/context` exposes resource group, app name, and validated agent portal links. Neither endpoint exposes arbitrary application configuration.

## Frontend Assets

The UI bundles [Lucide](https://lucide.dev/license) icons (ISC), [Chart.js](https://github.com/chartjs/Chart.js/blob/master/LICENSE.md) (MIT), and [Manrope](https://github.com/fontsource/fontsource/tree/main/fonts/variable/manrope) (SIL Open Font License). Dependency versions are recorded in `package-lock.json`; the build preserves license notices in `wwwroot/third-party-notices.txt`. The Azure Monitor mark reuses the repository's existing Azure architecture asset. No CDN requests are required for fonts, charts, or icons.