# Health Model Tutorial: Lab Café ☕🩺

In this tutorial you've finally done it. You run your own coffee shop! In the cloud. 

But you will see that a lot can go wrong, luckily a health model can help you you.

**After this tutorial you can:**

1. Read a health model and know what it can do for you. Convert signals into health information.
2. Explain where health comes from: signals, thresholds and rollup.
3. Be ready to think about workload health for your application and services.

| | |
|---|---|
| ⏱️ Time | About 45 minutes, depedning on how much you explore. |
| 💶 Cost | Roughly EUR 1-2 per day: App Service B1, two private endpoints, two availability tests, a little Log Analytics. Delete the resource group when you're done ([§6](#6-clean-up)) |
| 📍 Region | `swedencentral` by default, everything in its own resource group `rg-healthmodel-tutorial`. Other regions that offer health models work too (`-Location`) |
| 🧩 Standalone | You don't need the rest of the lab. Its own health models are in [scenario 45](DEMO-SCENARIOS.md#s45) |
| ✅ Last verified | 2026-11-05 with Azure CLI 2.92, `health-models` extension 1.0.0b2, API `2026-11-01` |

## Before you start

### Install the health models CLI

The health models CLI is the `health-models` extension for Azure CLI. Use PowerShell 7 (`pwsh`) on Windows, macOS or Linux, or Azure Cloud Shell switched to **PowerShell**.

1. [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75 or later. Azure Cloud Shell already includes it. Check your version:

   ```powershell
   az version
   ```

2. Install the health models extension, then check that its commands are available:

   ```powershell
   az extension add --name health-models
   az monitor health-models --help
   ```

   The help output should list commands such as `create`, `show` and `entity`. See the [official CLI installation steps](https://learn.microsoft.com/azure/azure-monitor/health-models/cli#install-the-extension).

3. Sign in to Azure:

   ```powershell
   az login
   ```

### Permissions and repository setup

- Owner, or Contributor plus User Access Administrator, on the subscription or resource group. The scripts create role assignments for the app and for the health model.
- The health model resource provider registered on the subscription. The build script registers it if needed, which takes rights on the subscription; with rights on the resource group only, ask an admin to run `az provider register --namespace Microsoft.CloudHealth` once.
- Run everything from the repository root. Put your subscription in `.azure-target.json` (copy [.azure-target.json.template](../.azure-target.json.template)) or pass `-SubscriptionId` to every script.

## What you'll build

```mermaid
flowchart LR
    C["Customers and<br/>synthetic customers"]:::user --> APP["App Service<br/>Lab Café (Node)"]:::az
    APP -- "private endpoint" --> ST["Storage<br/>menu, orders, barista queue"]:::az
    APP -- "requests, storage calls" --> AI["Application Insights<br/>+ Log Analytics"]:::az
    HM["Health model<br/>hm-lab-cafe"]:::hm -- "KQL queries" --> AI
    HM -- "platform metrics" --> APP & ST

    classDef user fill:#dcfce7,stroke:#15803d,color:#14532d
    classDef az fill:#dbeafe,stroke:#2563eb,color:#1e3a8a
    classDef hm fill:#164e63,stroke:#0891b2,color:#ffffff
```

And this is the health model, in **Monitor → Health models → hm-lab-cafe → Graph**:

![The finished hm-lab-cafe health model in the portal graph: the root, two user flows, five system components and five Azure resources, all Healthy](images/healthmodel-cafe-graph.png)


## 1. Health model basics

In Azure Monitor health models, we use these terms to describe certain things:

| Term | What it means at the café |
|---|---|
| **Entity** | Anything that has a health state: something customers do ("Order coffee"), a part of the system ("Order API") or an Azure resource ("App Service: app-cafe-..."). Every model has a **root** entity named like the model |
| **User flow entity** | Something that a user trigger or does, like a use case. |
| **System component entity** | A part of the system that supports user flows, like an API or a database. |
| **Other entities** | In the end, all entities are the same, the notion of type is just the icon you see in the graph. |
| **Signal** | Data e.g. metrics or query results that will make an entity to become healthy, degraded, or unhealthy |
| **Relationship** | Connection between entities, where the health will roll up to. |
| **Health state** | 🟢 Healthy, 🟡 Degraded, 🔴 Unhealthy, ⚪ Unknown (no evidence, for example a query that returns nothing) |

Other terms will show up, you find all of them here 📚 [Health model concepts](https://learn.microsoft.com/azure/azure-monitor/health-models/concepts)

## 2. Open the café

```powershell
./scripts/deploy-healthmodel-tutorial.ps1
./scripts/build-healthmodel-tutorial.ps1 -SkipFailedOrderSignal
```

The first script deploys the café ([infra/healthmodel-tutorial/workload.bicep](../infra/healthmodel-tutorial/workload.bicep)), publishes the app and places a test order (about 5 minutes). The second builds the health model with the `az monitor health-models` CLI (about 2 minutes). It leaves one signal out on purpose: you add it in §4.

| Route | What it does | What it touches |
|---|---|---|
| `GET /` and `GET /api/menu` | Shows the menu | Reads blob `menu/menu.json` |
| `POST /api/orders` | Places an order | Reads the menu, writes blob `orders/<id>.json`, then tells the barista display through a queue. If the queue fails, the order **still succeeds** |
| `GET /api/orders/<id>` | Looks up an order | Reads blob `orders/<id>.json` |
| `GET /healthz` | App Service health check | Nothing |

Application Insights records every request and every storage call. Two availability tests act as synthetic customers that open the menu and order a flat white every 5 minutes, so the model has data even at 3 a.m. Storage only accepts private traffic, through VNet integration and private endpoints, which gives us a realistic way to break things later.

> ✅ **Done when:** the printed URL opens the café, and **Monitor → Health models → hm-lab-cafe** shows the graph. Startup failures leave the signal windows after five minutes, plus telemetry and evaluation delay. Log signals can also say *insufficient access* for about 10 minutes while the model's role arrives. Wait; don't rerun the build or recreate entities, that deletes their history. Start §3 in the meantime.

## 3. Look around

Open **Monitor → Health models → hm-lab-cafe → Graph** (the picture under [What you'll build](#what-youll-build)). Read it top down:

- **User flows**: what customers come to do. *Browse the menu* and *Order coffee* have no signals of their own; they get their health from their children.
- **System components**: the parts each flow needs, named by what they do (*Order API*, *Order store*). Their signals are KQL queries on Application Insights that measure what customers feel: failed requests, slow orders, failed storage calls.
- **Azure resources**: the web app and storage account, with platform metrics (health check, storage availability). The same web app shows up twice, once under each flow. A health model is a tree, so each flow gets its own copy and every entity has exactly one parent.
- **Barista display (optional)**: a missing notification is annoying, not an outage. Its *impact*, how much it counts for its parent, is Limited: when it turns Unhealthy, *Order coffee* only turns Degraded. Keep it in mind for §5.

Select **Order API** to open its details. They show its state, the rollup rule (*Worst of*: a parent takes the worst state of its children; Unknown children don't count) and a 24-hour history:

![Entity details of Order API](images/healthmodel-cafe-entity-details.png)

Now select **Order coffee** and choose **Edit**. A user flow carries what the business cares about. The *General* tab holds the impact and the **health objective**, the share of time the flow should be Healthy. Only Unhealthy time counts against it; Degraded doesn't. 99.9% over 30 days allows about 43 minutes of Unhealthy time. The *Alerts* tab has one alert per state:

| General | Alerts |
|---|---|
| ![Entity editor General tab for Order coffee: impact Standard, Limited or Suppressed, icon User flow, health objective 99.9 percent](images/healthmodel-cafe-entity-general.png) | ![Entity editor Alerts tab for Order coffee: Degraded alert Sev3 "Ordering coffee is slow or partly failing", Unhealthy alert Sev1 "Customers cannot order coffee"](images/healthmodel-cafe-entity-alerts.png) |

Close the editor without saving. Last stop: **Signal definitions**. A signal definition is a signal you can reuse. Both App Service entities share the health check, all three storage entities share availability, and changing a definition changes every entity that uses it:

![Signal definitions page of hm-lab-cafe: Storage availability used 3 times, degraded below 99.9 percent and unhealthy below 99 percent; Web app health check used 2 times, degraded below 100 percent and unhealthy below 50 percent](images/healthmodel-cafe-signal-definitions.png)

📚 [Analyze the health state](https://learn.microsoft.com/azure/azure-monitor/health-models/analyze-health), [alerts](https://learn.microsoft.com/azure/azure-monitor/health-models/alerts), [health objective](https://learn.microsoft.com/azure/azure-monitor/health-models/concepts#health-objective). Why the model looks like this: [docs/healthmodel/cafe/plan.md](healthmodel/cafe/plan.md).

## 4. Add a signal

*Order API* watches slow orders and the synthetic customer, but nothing counts orders that fail for real customers. Add that signal.

First try the query yourself in **Log Analytics workspace `law-cafe-…` → Logs**, time range *Last 5 minutes*, the same window the signal looks at:

```kusto
AppRequests
| where TimeGenerated > ago(5min)
| where Url has "/api/orders"
| summarize value = countif(ResultCode startswith "5")
```

It returns one row, `value = 0` (more if the café is still starting). That's what a signal needs: one number, also when nobody orders. A query that returns no row, or a metric filtered to HTTP 500s that never happen, leaves the signal ⚪ Unknown, and an Unknown signal can't warn you. It counts only server errors (5xx): a 404 for a mistyped order ID is the customer's mistake, not an outage.

Now add it in the portal:

1. **hm-lab-cafe → Designer**, then **Edit** on **Order API**, then the **Signals** tab. Order API already reads from the workspace `law-cafe-…`, so you don't need to add a data source.
2. **Add log query signal** → **Create new**, and fill in:

   | Field | Value |
   |---|---|
   | Display name | Failed order requests |
   | Query | **Edit query**, paste the query above, time range 5 minutes (how far back it looks), **Run**, **Done** |
   | Value column name | `value` |
   | Data unit | Count |
   | Degraded threshold | greater than 0 |
   | Unhealthy threshold | greater than 2 |

3. **Add to entity**, then **Save**.

> ✅ **Done when:** within a few minutes the Order API's signal table shows *Failed order requests* at 0, Healthy:
>
> ![Signals table of Order API: Failed order requests 0, Order time for most customers 596 ms, Synthetic customer cannot order 0, all Healthy, with their degraded and unhealthy thresholds](images/healthmodel-cafe-entity-signals.png)

📚 [Configure signals](https://learn.microsoft.com/azure/azure-monitor/health-models/tutorial-signals). The [build script](../scripts/build-healthmodel-tutorial.ps1) creates every other signal, entity and relationship from one table; [Create a health model with the Azure CLI](https://learn.microsoft.com/azure/azure-monitor/health-models/cli) walks through the commands.

## 5. Break it: predict, then look 🔨

Each break changes one thing, then sends a few customers so failures show within minutes. Before you run one, write down your prediction:

> **My prediction:** these entities change, to these states: ... These stay Healthy: ... It recovers after about ... minutes.

Then break, watch the signals, compare and restore. Open the answer only after you've looked.

### Watch health and signal values

All KQL signals look back five minutes and refresh every minute after telemetry arrives.

Show entity health:

```powershell
az monitor health-models entity list -g rg-healthmodel-tutorial --health-model-name hm-lab-cafe `
  --query "[].{Entity:properties.displayName,Health:properties.healthState}" -o table
```

Select **Barista display (optional)** in the portal for values and thresholds, or inspect its signals:

```powershell
az monitor health-models entity show -g rg-healthmodel-tutorial --health-model-name hm-lab-cafe -n barista-display `
   --query "properties.signalGroups.azureLogAnalytics.signals[].{Signal:displayName,Value:status.value,Health:status.healthState,Window:timeGrain,Updated:status.reportedAt,Error:status.error}" -o table
```

You can rerun that instead of checking in the Portal. **Updated** is the last evaluation; check **Error** before trusting values. For other experiments, replace `barista-display` with `order-api`, `cafe-website` or `menu-catalog`.

### 5.1 The optional barista

The barista queue gets deleted, so the barista display misses orders. Orders still go through. First see what happens *without* limited impact:

```powershell
az monitor health-models entity update -g rg-healthmodel-tutorial --health-model-name hm-lab-cafe -n barista-display --impact Standard
./scripts/break-healthmodel-tutorial.ps1 -Scenario BaristaQueue
```

Predict: what color does *Order coffee* turn?

You can again check with this command, or in the Portal:
```powershell
az monitor health-models entity show -g rg-healthmodel-tutorial --health-model-name hm-lab-cafe -n barista-display `
   --query "properties.signalGroups.azureLogAnalytics.signals[].{Signal:displayName,Value:status.value,Health:status.healthState,Window:timeGrain,Updated:status.reportedAt,Error:status.error}" -o table
```

Then switch the impact back and predict again:

```powershell
az monitor health-models entity update -g rg-healthmodel-tutorial --health-model-name hm-lab-cafe -n barista-display --impact Limited
```

<details>
<summary><b>Check your prediction</b></summary>

- With `Standard` impact: Barista display 🔴 Unhealthy, Order coffee 🔴 Unhealthy, Lab Café 🔴 Unhealthy. A missing notification looks like an outage.
- With `Limited` impact: Barista display stays 🔴 Unhealthy, but Order coffee and Lab Café drop to 🟡 Degraded. Browse the menu stays 🟢 Healthy throughout.
- Limited impact passes Unhealthy up as only Degraded, and Degraded time doesn't count against the health objective.

📚 [Impact in health rollup](https://learn.microsoft.com/azure/azure-monitor/health-models/rollup)

</details>

```powershell
./scripts/break-healthmodel-tutorial.ps1 -Scenario BaristaQueue -Restore
```

Watch the barista signal again after restoring. It counts failed notifications in the **last five minutes**, not failures since the café started. Successful notifications do not cancel earlier failures. The count falls to 0 as those failures leave the window, then the signal turns Healthy on a following evaluation. A burst can disappear all at once rather than count down one by one. Allow five minutes after the last failed notification, plus telemetry and evaluation delay.

Wait for this signal to reach 0 before the next experiment, so its remaining failures don't obscure the new result. A healthy queue-storage resource alone doesn't prove notifications have recovered.

### 5.2 A bad software configuration

An app setting makes every order fail with HTTP 500, like a bad deploy. Predict: what happens to *Order API*, *Order coffee*, *Browse the menu* and the root? Which signal fires first?

```powershell
./scripts/break-healthmodel-tutorial.ps1 -Scenario BadRelease
```

<details>
<summary><b>Check your prediction</b></summary>

- Order API 🔴 Unhealthy. Your signal from §4 fires first, within about 2 minutes; the synthetic customer follows on its next run. Order coffee 🔴 Unhealthy and its Sev1 alert fires. Lab Café 🔴 Unhealthy.
- Browse the menu stays 🟢 Healthy: the Café website's signals only count menu requests. The web app is shared, but the failure is in the order code.
- Both App Service entities stay 🟢 Healthy: `/healthz` still answers.

</details>

```powershell
./scripts/break-healthmodel-tutorial.ps1 -Scenario BadRelease -Restore
```

Watch recovery with `-n order-api`. All its signals look back five minutes. Allow five minutes after the last bad result, plus telemetry and evaluation delay, before starting 5.3.

### 5.3 A network change

The web app loses its VNet integration, so storage, which only accepts private traffic, turns it away. Predict: will the web app's health check turn red? Storage availability? The Order store? The barista display?

```powershell
./scripts/break-healthmodel-tutorial.ps1 -Scenario NetworkCut
```

<details>
<summary><b>Check your prediction</b></summary>

- Café website, Menu catalog and Order API 🔴 Unhealthy; Browse the menu, Order coffee and Lab Café 🔴 Unhealthy.
- Order store and Barista display stay 🟢 Healthy: every order fails at the menu lookup, before it gets that far.
- The App Service health checks and storage availability stay 🟢 Healthy too. `/healthz` doesn't touch storage, and requests turned away by the network don't count against storage availability.

</details>

If you clean up next ([§6](#6-clean-up)), skip the restore. Otherwise it redeploys the workload template (3 to 5 minutes), then old failures must leave the signal windows:

```powershell
./scripts/break-healthmodel-tutorial.ps1 -Scenario NetworkCut -Restore
```

Watch the signals on **Café website**, **Menu catalog** and **Order API**. All look back five minutes, so old failures can keep the flows red after storage access works again.

### Look back

Open **Timeline**. It shows every entity on one time axis; expand a row to see its children. The boxes mark state changes, and the number in a box is how many happened close together. Find your three breaks:

![Timeline of hm-lab-cafe over 24 hours with the root, Browse the menu, Order coffee and its three components; numbered boxes mark the state changes from the experiments](images/healthmodel-cafe-timeline.png)

What the breaks teach:

- **A healthy resource doesn't mean a healthy flow.** During the network change, Azure reports the web app and storage as fine. Only the component signals, which measure what customers experience, catch it.
- **A component only sees what reaches it.** Read the whole tree, not just the reddest box.
- **Impact is a business decision.** The same failure is an outage or a nuisance, depending on one setting you choose.

📚 [Analyze the health state](https://learn.microsoft.com/azure/azure-monitor/health-models/analyze-health)

## 6. Clean up

```powershell
az group delete -n rg-healthmodel-tutorial --yes
```

## Where to go next

- **Build a model yourself:** the official quickstarts for the [portal](https://learn.microsoft.com/azure/azure-monitor/health-models/create), [Bicep](https://learn.microsoft.com/azure/azure-monitor/health-models/tutorial-bicep) and the [CLI](https://learn.microsoft.com/azure/azure-monitor/health-models/quickstart-cli).
- **Design one for your app:** [health modeling in the Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/design-guides/health-modeling). Using an AI coding agent? The `healthmodel-plan` skill writes a plan like [the café's](healthmodel/cafe/plan.md) from your code and IaC.
- **Grow a model without hand work:** [discovery rules](https://learn.microsoft.com/azure/azure-monitor/health-models/discoveries) add entities for resources that match a query.
- **Everything else:** the [official documentation table](#official-documentation) above.

## Official documentation

Dig deeper into the health modelling topics with our documentation:

| Topic | Microsoft Learn | Used in |
|---|---|---|
| What health models are | [Overview](https://learn.microsoft.com/azure/azure-monitor/health-models/overview), [concepts](https://learn.microsoft.com/azure/azure-monitor/health-models/concepts) | §1 |
| How to design one | [Health modeling with health models](https://learn.microsoft.com/azure/azure-monitor/health-models/health-modeling), [Well-Architected health modeling](https://learn.microsoft.com/azure/well-architected/design-guides/health-modeling) | §3 |
| Graph, timeline, entity details | [Analyze health state](https://learn.microsoft.com/azure/azure-monitor/health-models/analyze-health), [designer](https://learn.microsoft.com/azure/azure-monitor/health-models/designer) | §3, §5 |
| Alerts and health objectives | [Alerts](https://learn.microsoft.com/azure/azure-monitor/health-models/alerts), [health objective](https://learn.microsoft.com/azure/azure-monitor/health-models/concepts#health-objective) | §3 |
| Signals and signal definitions | [Signals](https://learn.microsoft.com/azure/azure-monitor/health-models/signals), [configure signals](https://learn.microsoft.com/azure/azure-monitor/health-models/tutorial-signals) | §3, §4 |
| Rollup and impact | [Configure health rollup](https://learn.microsoft.com/azure/azure-monitor/health-models/rollup) | §5 |
| Build with the CLI | [Create a health model with the Azure CLI](https://learn.microsoft.com/azure/azure-monitor/health-models/cli) | §4 |
| Questions | [FAQ](https://learn.microsoft.com/azure/azure-monitor/health-models/health-models-faq) | |
