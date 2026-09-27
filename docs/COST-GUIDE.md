# Cost guide

This guide maps the resources deployed by the lab to the meters that can appear on an Azure bill. It is a planning aid, not a quote. Public retail prices, negotiated agreements, currencies, taxes, free allowances, preview terms, and regional availability change over time.

**Price check date:** September 27, 2026.  
**Default regions:** North Europe, with App Service and its diagnostic Event Hub in West Europe; optional AI, SRE Agent, and Health Model resources in Sweden Central; the optional Observability Agent workspace in a supported region selected at deployment.

Use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for a pre-deployment estimate and [Azure Cost Management](https://learn.microsoft.com/azure/cost-management-billing/costs/quick-acm-cost-analysis) for actual and forecast charges. The public [Azure Retail Prices API](https://prices.azure.com/api/retail/prices) is useful for reproducible list-price checks but does not represent a customer-specific quote.

## How to estimate this lab

Estimate monthly cost as:

```text
fixed provisioned resources
+ compute hours
+ storage capacity, operations, and data transfer
+ telemetry ingestion, retention, query, export, and replication
+ alert, web-test, network-monitoring, and automation executions
+ Container Apps job and ACR build usage
+ optional Foundry model, SRE Agent, and Observability Agent usage
```

Use 730 hours for a continuously provisioned month. Do not multiply a daily ingestion cap by a price and call the result the lab total: the cap covers only one ingestion path and many resources continue billing independently.

## Default deployed inventory and cost model

The table reflects the current Bicep defaults. Optional stages are excluded unless enabled.

| Area | Current deployment | How it is billed | Lifecycle note |
|---|---|---|---|
| AKS | Free-tier control plane; **1 x Standard_B2s** node | Node VM, OS disk, load balancer/public IP, outbound data; Managed Prometheus and Container Insights by usage | `az aks stop` stops node compute, but retained disks, IPs, and telemetry can still bill |
| Demo VMs | **1 Linux B2s + 1 Windows B2s** | VM hours, managed OS/data disks, public IPs, bandwidth, monitoring | Deallocation stops VM compute; disks, IPs, and monitoring remain |
| VM scale set | **1 Linux Standard_B1s** instance | VM hours, disk, public IP/load-balancing as applicable, monitoring | Scaling to zero stops instance compute, not retained resources |
| App Service | Linux Basic B1 plan and web app | App Service plan instance-hours, even when the web app is stopped | Delete the plan to stop plan billing |
| Managed Grafana | **Standard**, not Essential | Standard instance/node-hours plus active users | Continues billing while provisioned |
| Event Hubs | **Basic**, 1 throughput unit | TU-hours, ingress events, retention/operations where applicable | Continues billing while provisioned |
| Container Registry | Basic | Registry-days, storage, data transfer, and ACR Tasks build vCPU-seconds | Continues billing while provisioned |
| Control Center runner | Container Apps job, 1 vCPU/2 GiB, at most 1,800 seconds per execution | Job vCPU-seconds, GiB-seconds, executions, logs; image builds use ACR Tasks | No always-running app replica, but each run/build is billable |
| Storage and Key Vault | Two LRS storage accounts and Standard Key Vault | Capacity, transactions, retrieval, data transfer, and Key Vault operations | Continue billing while data/resources remain |
| Network monitoring | Network Watcher features, Connection Monitor, NSG flow logs, Traffic Analytics | Test/monitoring operations, flow-log GB, storage, and Traffic Analytics processed GB | Disabling one workload does not remove stored logs |
| Azure Monitor | Two Log Analytics workspaces, Application Insights, Azure Monitor workspace, DCRs, workbooks | Logs, classic/custom metrics, Prometheus samples/query processing, retention, archive, search, restore, export, replication | The default 1 GB/day cap is set independently on each LAW; it is not a total-spend cap |
| Alerts and tests | Metric, log-search, activity-log, dynamic-threshold alerts; standard web test; action/automation paths | Rule/series evaluations, web-test executions, notifications, Logic Apps or other actions as applicable | Cost depends on frequency, dimensions, and executions |
| Sentinel (optional) | Onboards the central LAW | Sentinel analysis plus applicable Log Analytics ingestion/retention and optional automation/features | There is no unconditional “Sentinel is free” state |
| Advanced log features (optional) | Export, archive/search/restore, replication, metrics export | Exported/replicated/scanned/restored GB, retention GB-month, metric samples | These meters are additive |

### Reproducible public-rate examples

The following EUR retail rows were returned for the stated regions on the price-check date. They illustrate the calculation; always retrieve current rows for your currency and region.

| Meter | Public rate | Monthly formula |
|---|---:|---:|
| North Europe Linux B2s | EUR 0.0386/hour | `instances x running hours x 0.0386` |
| North Europe Windows B2s | EUR 0.0460/hour | `instances x running hours x 0.0460` |
| North Europe Linux B1s | EUR 0.0097/hour | `instances x running hours x 0.0097` |
| Managed Grafana Standard node | EUR 0.0353/hour | `nodes x provisioned hours x 0.0353` |
| Managed Grafana Standard user | EUR 5.152/user-month | `billable active users x 5.152` |
| West Europe Event Hubs Basic TU | EUR 0.0129/hour | `TUs x provisioned hours x 0.0129` |
| Event Hubs Basic ingress | EUR 0.024/million events | `millions of ingress events x 0.024` |
| ACR Basic | EUR 0.1431/day | `provisioned days x 0.1431` |
| Analytics Logs ingestion, North Europe | EUR 2.3699/GB | `billable ingested GB x 2.3699`, after applicable allowances |
| Standard web test | EUR 0.0005/execution | `executions x 0.0005` |
| Managed Prometheus ingestion | EUR 0.1374/10 million samples | `sample blocks x 0.1374` |
| Prometheus query processing | EUR 0.0009/10 million samples | `processed-sample blocks x 0.0009` |
| VNet flow logs | EUR 0.4293/GB | `billable flow-log GB x 0.4293`, after applicable allowances |
| Traffic Analytics, 10-minute interval | EUR 3.0053/GB | `processed GB x 3.0053` |

Examples intentionally omitted from the table when a reliable single row cannot represent the deployment include managed disks, public IPs, load balancer rules/data, App Service, storage transactions, Key Vault operations, alert dimensions, and Container Apps executions. Add them in the calculator rather than silently treating them as zero.

Useful Azure Monitor variable rates from the same check include Analytics extended retention at EUR 0.103/GB-month, archive at EUR 0.0206/GB-month, search jobs at EUR 0.0052/scanned GB, restore at EUR 0.103/GB-day, data export at EUR 0.103/exported GB, workspace replication at EUR 0.2576/replicated GB, and metrics export at EUR 0.0031/1,000 samples. Allowances and tier boundaries can appear as zero-price API rows; they do not prove that all usage is permanently free.

## Optional AI and agent costs

| Optional feature | Cost boundary |
|---|---|
| Microsoft Foundry | Model-specific input, cached-input, output, embedding, routing, and provisioned-throughput rates. The lab deploys `gpt-5-mini`, `text-embedding-3-small`, `gpt-5.4`, and `model-router`; one token rate cannot correctly price all four. Use observed token/model dimensions with the current [Azure OpenAI pricing](https://azure.microsoft.com/pricing/details/azure-openai/) or Cost Management. |
| Azure SRE Agent | `always-on AAUs x current always-on rate + active AAUs x current active rate`, subject to current trial eligibility and terms. Stopping active work does not stop the post-trial always-on charge; delete the agent when no longer evaluating it. See [SRE Agent pricing and billing](https://learn.microsoft.com/azure/sre-agent/pricing-billing). |
| Azure Copilot Observability Agent | `AAC consumed x current regional AAC rate + dedicated workspace data charges`. As checked on the date above, preview correlation is unbilled; chat and deep investigations consume AAC, and each deep investigation is capped at 500 AAC. Automatic investigation is off by default. See [Observability Agent billing](https://learn.microsoft.com/azure/azure-monitor/aiops/observability-agent-billing). |
| Sentinel | Resource onboarding has no standalone instance fee, but Sentinel analysis and underlying data services can bill. A qualifying new workspace may receive a conditional 31-day, 10 GB/day trial; retention, automation, Logic Apps, notebooks, and other services remain separate. See [Sentinel billing](https://learn.microsoft.com/azure/sentinel/billing). |

## External developer tooling

These tools are not part of the Azure lab infrastructure estimate:

- GitHub Copilot CLI requires an eligible GitHub Copilot plan and interactions can consume premium requests under the applicable [GitHub Copilot billing](https://docs.github.com/copilot/reference/copilot-billing/request-based-billing-legacy/copilot-requests).
- Azure MCP Server has no standalone lab resource charge, but Azure operations it invokes can create or use billable resources. See the [Azure MCP Server overview](https://learn.microsoft.com/azure/developer/azure-mcp-server/overview).
- Microsoft Learn MCP is external documentation access and does not deploy an Azure resource into the lab subscription. See [Microsoft Learn MCP](https://learn.microsoft.com/training/support/mcp).

## Stop, deallocate, or delete

| Action | Compute charge | Charges that commonly remain |
|---|---|---|
| Stop the web app | App Service plan still bills | Plan, storage, logs, networking |
| Deallocate VMs / scale VMSS to zero | VM compute stops | Disks, public IPs, backup/monitoring, data |
| Stop AKS | Node compute stops | Disks, public IP/load balancer, registry, logs and metrics |
| Control Center **Stop Lab** | Deallocates VMs/VMSS and stops AKS and the Web App | App Service Plan, Grafana, Event Hubs, ACR, disks/IPs, retained data, telemetry, and optional agents |
| Stop SRE Agent activity | Active usage can stop | Post-trial always-on AAU allocation |
| Leave optional agents idle | Usage may fall | Provisioned workspaces, retained data, and any fixed allocations |
| Delete the resource group with `scripts/teardown.ps1 -Yes` | Resources are requested for deletion | Charges can continue until asynchronous deletion completes; tenant-scoped/shared resources require the documented cleanup path |

After teardown, verify the resource group and separately managed agent, replication, diagnostic, and tenant resources are gone before assuming billing has stopped.

## Cost controls and verification

1. Set a subscription or resource-group budget and alerts in Cost Management.
2. Use the lab workbook only for **central LAW ingestion volume**. It reads the `Usage` table and does not reconcile the Azure invoice.
3. Review both LAW daily caps, table plans, retention, archive, export, and replication independently.
4. Deallocate VMs, stop AKS, and scale the VMSS down between sessions.
5. Keep automatic agent investigations disabled unless their usage is explicitly approved.
6. Review Cost Analysis by service name, meter, resource, and tag after each workshop.
7. Delete the lab when it is no longer required and confirm deletion completes.

## Public pricing references

- [Virtual Machines](https://azure.microsoft.com/pricing/details/virtual-machines/linux/)
- [Managed Disks](https://azure.microsoft.com/pricing/details/managed-disks/)
- [AKS](https://azure.microsoft.com/pricing/details/kubernetes-service/)
- [Load Balancer](https://azure.microsoft.com/pricing/details/load-balancer/)
- [Public IP addresses](https://azure.microsoft.com/pricing/details/ip-addresses/)
- [App Service](https://azure.microsoft.com/pricing/details/app-service/linux/)
- [Azure Monitor](https://azure.microsoft.com/pricing/details/monitor/)
- [Managed Grafana](https://azure.microsoft.com/pricing/details/managed-grafana/)
- [Storage](https://azure.microsoft.com/pricing/details/storage/blobs/)
- [Event Hubs](https://azure.microsoft.com/pricing/details/event-hubs/)
- [Key Vault](https://azure.microsoft.com/pricing/details/key-vault/)
- [Container Registry](https://azure.microsoft.com/pricing/details/container-registry/)
- [Container Apps](https://azure.microsoft.com/pricing/details/container-apps/)
- [Network Watcher](https://azure.microsoft.com/pricing/details/network-watcher/)
- [Azure Monitor Logs cost](https://learn.microsoft.com/azure/azure-monitor/logs/cost-logs)
- [Azure Monitor data retention](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure)
- [Azure Monitor cost and usage](https://learn.microsoft.com/azure/azure-monitor/fundamentals/cost-usage)
