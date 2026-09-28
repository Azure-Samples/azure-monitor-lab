# Stage B — Workloads and dashboards

> **Goal of this stage:** put actual workloads on top of the substrate so the empty workbooks from Stage A start lighting up. By the end of Stage B the customer sees VM telemetry, AKS Container Insights, Managed Prometheus + Grafana dashboards, App Service + App Insights data, plus network observability (Connection Monitor + Flow Logs / Traffic Analytics).
>
> **Maps to scenarios:** 2, 3, 4, 22, 28-32, 34-36, 42.

## 1) What gets created

| Group | Resource(s) | Purpose |
|---|---|---|
| Linux VM | `vm-amlab-lin` (Standard_B2s) + NIC, public IP, OS disk + `shutdown-computevm-vm-amlab-lin` schedule | AMA-equipped and attached to `dcr-amlab-vminsights`. Automatically shuts down at 23:00 CET/CEST. The Linux Dependency Agent is not deployed, so Service Map is unavailable on this VM. |
| Windows VM | `vmwin<suffix>` (Standard_B2s) + NIC, public IP, OS disk + `shutdown-computevm-vmwin<suffix>` schedule | AMA and Dependency Agent equipped, attached to `dcr-amlab-vminsights`, and automatically shut down at 23:00 CET/CEST. |
| AKS cluster | `aks-amlab` (1× Standard_B2s system node) | Container Insights enabled (writes to `law-amlab-central`). Managed Prometheus is on (writes metrics to `amw-amlab` via `dcr-amlab-prometheus`). DCE attached. |
| Managed Grafana | `amg-amlab-<suffix>` | Connected to `amw-amlab`. Default Azure dashboards (Node Exporter, Kubelet, K8s/Compute resources, etc.) appear automatically. |
| App Service | `plan-amlab` + `app-amlab-<suffix>` | Linux App Service plan + web app. Auto-instrumented with `appi-amlab` (connection string baked in). Diagnostic settings send `AppServiceHTTPLogs` to `law-amlab-central`, `storage`, and event hub. |
| Control Center runner | Basic `acrlabops<suffix>` registry, `cae-labops-<suffix>` Consumption environment, `id-labops-<suffix>` identity, `job-labops-<suffix>` manual job, `console-runner-logs` diagnostic setting, three custom roles, and scoped role assignments | The workload template provisions the platform; completion builds the image, deploys the digest-pinned job and launcher role, and configures operator sign-in and scoped access. Runner logs use the central workspace. |
| Connection Monitor | `cm-amlab-*` (in `NetworkWatcherRG`) | Probes between the two VMs and the web app's default hostname. Populates `NetworkMonitoring` table. |
| Flow Logs + Traffic Analytics | `fl-amlab` against `vnet-amlab`; flow logs storage = `st<amlab><suffix>`; analytics workspace = `law-amlab-central` | Network-layer telemetry for security/exfil scenarios in Stage D and reliability scenarios in Stage E. |

> Cross-stage references (no module-to-module wiring): `law-amlab-central`, `law-amlab-appinsights`, `appi-amlab`, `amw-amlab`, `dce-amlab`, `dcr-amlab-vminsights`, `vnet-amlab`/`snet-workload`, `st<amlab><suffix>`, `evhns-amlab-<suffix>` are all `existing` references from Stage A.

Console completion requires permission to manage its Entra sign-in registration and scoped Azure roles, plus ACR Tasks availability. The registry has ongoing charges; image builds, job execution, and logs add usage charges. Stage B does not enable the optional Stage E Service Group or SLI setup. See [deployment prerequisites and upgrade behavior](../workloads/webapp/LAB-OPERATIONS.md#automatic-deployment).

The templates grant **Grafana Admin** at the Managed Grafana instance scope to the deploying identity by default. For service-principal deployments, set `grafanaAdminObjectId` in Bicep or `grafana_admin_object_id` in Terraform to the intended operator or group object ID. New role assignments can take time to propagate. Azure resource ownership and Monitoring Reader on the Grafana managed identity do not grant a user Grafana data-plane access.

## 2) Speaker notes

1. **"Watch the workbooks light up."**
   Open `wb-amlab-trafficlights` *before* Stage B and *after*. Heartbeats appear, AKS rows fill, App Service shows 200s. This is the most viscerally satisfying demo moment in the entire lab.

2. **"AMA + DCR is the only modern path."**
   Both VMs attach to the *existing* `dcr-amlab-vminsights`. Show the DCR's *Resources* tab now has entries. This is exactly how customers onboard fleets — DCR-first, VMs-later.

3. **"AKS gives you Container Insights *and* Managed Prometheus, side by side."**
   Container Insights = the operations view (logs, KubeNodeInventory, KubePodInventory). Managed Prometheus = the metrics view (rate, histogram quantiles, etc.). Grafana visualises the Prometheus side. Customers often ask "which do I pick?" — the answer is *both*, and this lab shows why.

4. **"App Service auto-instrumentation is one connection string."**
   Open the web app's *Application settings*; show `APPLICATIONINSIGHTS_CONNECTION_STRING`. That's the whole onboarding. Then open *Live Metrics* in App Insights — telemetry flows in real time.

5. **"Network observability isn't optional."**
   Connection Monitor proves *east-west* and *north-south* connectivity continuously. Flow Logs + Traffic Analytics build the dataset Stage D's exfil-detection query alert depends on.

6. **"Stage B is where money happens."**
   Two VMs + AKS + App Service dominate the lab's bill. Tell customers: *deallocate VMs and stop AKS between workshops.* This is the moment to introduce the cost workbook from Stage A.

## 3) Portal walkthrough (UI)

1. **Resource group → filter by tag `owner=demo-lab`** — show the new resources stacked on top of the foundation.
2. **`vm-amlab-lin` → Insights** — open VM Insights. Charts populate within a few minutes. Click *Map* to show ServiceMap.
3. **`vmwin<suffix>` → Insights** — same story on the Windows side.
4. **`dcr-amlab-vminsights` → Resources** — the previously-empty list now lists both VMs.
5. **`aks-amlab` → Insights** — Container Insights. Cluster, Nodes, Controllers, Containers tabs.
6. **`aks-amlab` → Monitoring → Workbooks** — built-in Container Insights workbooks.
7. **`amw-amlab` → Prometheus explorer** — try `up{}` or `kube_node_info{}`.
8. **`amg-amlab-<suffix>` → Endpoint** — click the Grafana URL. Default Azure dashboards are ready to demo (e.g., *Kubernetes / Compute Resources / Cluster*).
9. **`app-amlab-<suffix>` → Application Insights** (via *Settings → Application Insights*) — confirm it's linked to `appi-amlab`. Then *App Insights → Live Metrics*.
10. **`NetworkWatcherRG → Connection monitors`** — open the connection monitor and show test groups (VM→Web, VM→VM).
11. **Network Watcher → Traffic Analytics** — flow data appears after ~15 min; helpful to leave running before the session.
12. **`wb-amlab-trafficlights`** — re-open from Stage A and call out filled cells. "Same workbook, new world."

## 4) CLI validation

```powershell
$sub = '<your-subscription-id>'
$rg  = 'rg-azure-monitor-lab-terraform-test'
az account set --subscription $sub

# New compute exists
az vm list -g $rg --query "[].{name:name,state:powerState,size:hardwareProfile.vmSize}" -o table
az aks show -g $rg -n aks-amlab --query "{name:name,nodeCount:agentPoolProfiles[0].count,size:agentPoolProfiles[0].vmSize}" -o table
az webapp show -g $rg -n (az webapp list -g $rg --query "[?starts_with(name, 'app-amlab')].name | [0]" -o tsv) --query "{name:name,state:state,host:defaultHostName}" -o table

# DCR now has associations
az monitor data-collection rule association list --rule-name dcr-amlab-vminsights -g $rg -o table

# Container Insights is on
az aks show -g $rg -n aks-amlab --query "addonProfiles.omsagent.enabled" -o tsv

# Heartbeats are flowing
$lawId = az monitor log-analytics workspace show -g $rg -n law-amlab-central --query customerId -o tsv
az monitor log-analytics query -w $lawId --analytics-query "Heartbeat | where TimeGenerated > ago(15m) | summarize LastBeat = max(TimeGenerated) by Computer" -o table

# App Insights is receiving
az monitor log-analytics query -w $lawId --analytics-query "AppRequests | where TimeGenerated > ago(15m) | summarize requests = count(), failures = countif(Success == false)" -o table

# Connection monitor + flow logs
az network watcher connection-monitor list -l northeurope -o table
az network watcher flow-log list -l northeurope --query "[?starts_with(name, 'fl-amlab')]" -o table
```

If `Heartbeat` returns zero rows, wait 3–5 min for AMA to handshake; if still empty, check the VM has the AMA extension installed and the DCR association exists.

## 5) Done-when

1. Both VMs report `Heartbeat` in the last 15 min.
2. AKS shows nodes Ready and Container Insights tables (`KubeNodeInventory`, `KubePodInventory`) are populated.
3. `amw-amlab` returns data from a Prometheus query (`up{}` ≥ 1 series).
4. Web app responds at `https://<webAppName>.azurewebsites.net` and `AppRequests` rows appear in the LAW.
5. Traffic-Lights workbook shows green rows for VMs, AKS, App Service, App Insights — same workbook you opened during Stage A. Visual proof of value.
6. The expected Web App publication ID is verified, an approved operator can sign in to Infra Health and Lab Operations, and unapproved users cannot use protected endpoints.
7. The runner registry, environment, identity, and digest-pinned job exist with the expected lab tags. With Stage E disabled, completion makes no Service Group or SLI setup calls.
