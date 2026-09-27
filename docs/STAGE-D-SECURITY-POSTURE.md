# Stage D — Security posture (Azure-Monitor native)

> **Goal of this stage:** show that customers can get a credible **security posture story without buying Sentinel/Defender**. We lean on the data already in `law-amlab-central` (AzureActivity, RoleAssignments writes, Traffic Analytics) and add three scheduled-query alerts plus a granular LAW RBAC layer. Output goes to the Stage C Action Group.
>
> **Maps to scenarios:** 27, 47, 48, 49.

## 1) What gets created

| Group | Resource(s) | Purpose |
|---|---|---|
| Granular LAW RBAC (`law-rbac.bicep`) | Workspace-scoped role assignments | Demonstrates *least-privilege query access* on `law-amlab-central` (e.g., read-only reader on specific tables). The Bicep is idempotent — if no `principalIds` are supplied, only the role plumbing is laid down. |
| Scheduled query alert #1 — control-plane drift | `alert-security-control-plane-drift` | KQL on `AzureActivity` last 15 min; fires when **success-only write/delete/action ops > 40**. Severity 2. |
| Scheduled query alert #2 — privilege escalation | `alert-security-privilege-escalation-watch` | KQL on `AzureActivity` last 30 min; fires on **any successful `roleAssignments/write`, `roleDefinitions/write`, or `elevateAccess/action`**. Severity 1. |
| Scheduled query alert #3 — exfil early warning | `alert-security-exfil-early-warning` | KQL on `NTANetAnalytics` (Traffic Analytics) last 30 min; fires when **outbound bytes > 1 GB across the VNet in any 30-min window**. Severity 2. |
| Action routing | All three alerts attach to `ag-amlab-email` from Stage C. | Single Action Group, three new detections. |

> Cross-stage references: `law-amlab-central` (Stage A), `ag-amlab-email` (Stage C). Stage C must be live first or the Action Group lookup fails.

### Scenario mapping

| Scenario | Resource |
|---|---|
| **27** — Granular LAW RBAC | `law-rbac.bicep` |
| **47** — Control-plane drift | `alert-security-control-plane-drift` |
| **48** — Privilege escalation | `alert-security-privilege-escalation-watch` |
| **49** — Exfil early warning | `alert-security-exfil-early-warning` |

## 2) Speaker notes

1. **"Sentinel is *one option*, not *the* option."**
   Open with this framing. Many customers default to "we need Sentinel for security." Stage D shows you can deliver three credible detections using just Azure Monitor.

2. **"Detections without ingestion are detections you can't have."**
   Tie back to Stage A's diagnostic-settings policy (AzureActivity routed to LAW) and Stage B's Flow Logs + Traffic Analytics. *That's why* these three queries work.

3. **"Severity 1 vs Severity 2 — pick deliberately."**
   Privilege escalation is sev 1 (page someone). Drift and exfil are sev 2 (ticket). This is the conversation you want with the customer: how loud is loud enough?

4. **"Thresholds are starting points, not final answers."**
   `>40 ops/15m` is a lab number; in real life this comes from baselining. Show how easy it is to tune in the rule editor.

5. **"Granular RBAC = workspace governance."**
   Show the LAW *Access control* + *Tables* views. Explain how a workspace-reader role + table-level constraints lets a team see *their* logs without seeing everyone else's. This is the "we can give Security a read-only seat without granting them subscription Reader" story.

6. **"No new compute does not mean zero cost."**
   Price the three scheduled-query evaluations plus their diagnostic ingestion, retention, notifications, and any action execution. Use the [cost guide](COST-GUIDE.md) and measured volume instead of a flat range.

## 3) Portal walkthrough (UI)

1. **Monitor → Alerts → Alert rules** — filter by name `alert-security-*`. Show all three rules: severity, evaluation frequency (5 min), window (15–30 min), and *Actions → ag-amlab-email*.
2. **Open `alert-security-control-plane-drift`** — click *Condition*. Show the KQL on `AzureActivity`. Click *Edit alert rule → Custom log search* to demonstrate threshold tuning.
3. **Open `alert-security-privilege-escalation-watch`** — show *severity 1*. Open *History* to see whether it's ever fired. If empty, that's the right answer.
4. **Open `alert-security-exfil-early-warning`** — note the table is `NTANetAnalytics`. Make sure Stage B's Traffic Analytics has been ingesting for ≥ 15 min (otherwise the query has nothing to evaluate).
5. **`law-amlab-central` → Access control (IAM)** — show the granular role assignments laid down by `law-rbac.bicep`.
6. **`law-amlab-central` → Tables** — show table-level access if customer wants the deep dive (this is a powerful "we can constrain Security to just these tables" demo).
7. **Trigger scenario 47 live** — flip a tag or restart a VM ~50 times in 15 min (or use `Restart-AzVM` in a loop) to push past the threshold. Wait ~5 min. Alert fires, Action Group emails, Logic App runs.
8. **Trigger scenario 48 live** — assign yourself an Owner role at the RG (then remove it). This single op is enough to fire the privilege-escalation rule.
9. **Review the three security alerts together** — use the alert rules list and each rule's query/history to compare control-plane drift, privilege escalation, and exfiltration detection. The security operations workbook is not deployed because it is currently disabled in the IaC templates.

## 4) CLI validation

```powershell
$sub = '<your-subscription-id>'
$rg  = 'rg-azure-monitor-lab-terraform-test'
az account set --subscription $sub

# All three rules exist and are enabled
az monitor scheduled-query list -g $rg --query "[?starts_with(name, 'alert-security-')].{name:name,severity:properties.severity,enabled:properties.enabled,windowSize:properties.windowSize,actions:properties.actions.actionGroups[0]}" -o table

# AzureActivity is flowing (foundation for 47/48)
# The central LAW name carries a per-deployment suffix (law-amlab-central-<hash>), so
# resolve it by prefix instead of guessing the exact name.
$lawName = (az monitor log-analytics workspace list -g $rg -o json | ConvertFrom-Json | Where-Object { $_.name -like 'law-amlab-central*' } | Select-Object -First 1).name
$lawId = az monitor log-analytics workspace show -g $rg -n $lawName --query customerId -o tsv
az monitor log-analytics query -w $lawId --analytics-query "AzureActivity | where TimeGenerated > ago(1d) | summarize Rows = count(), LastSeen = max(TimeGenerated)" -o table

# Dry-run each detection query manually
$q47 = "AzureActivity | where TimeGenerated > ago(15m) | where ActivityStatusValue == 'Success' | where OperationNameValue has_any ('/write', '/delete', '/action') | summarize Changes = count()"
$q48 = "AzureActivity | where TimeGenerated > ago(30m) | where ActivityStatusValue == 'Success' | where OperationNameValue has_any ('roleAssignments/write', 'roleDefinitions/write', 'elevateAccess/action') | summarize Hits = count()"
$q49 = "NTANetAnalytics | where TimeGenerated > ago(30m) | where SubType == 'FlowLog' | where FlowDirection == 'O' | summarize OutboundBytes = sum(BytesSrcToDest)"
az monitor log-analytics query -w $lawId --analytics-query $q47 -o table
az monitor log-analytics query -w $lawId --analytics-query $q48 -o table
az monitor log-analytics query -w $lawId --analytics-query $q49 -o table

# Force a scenario-47 trigger (only run if you understand the impact)
$vm = az vm list -g $rg --query "[?starts_with(name, 'vm-amlab-lin')].name | [0]" -o tsv
1..50 | ForEach-Object { az tag update --resource-id (az vm show -g $rg -n $vm --query id -o tsv) --operation merge --tags "demoBeat=$_" | Out-Null }

# Force a scenario-48 trigger — assign and remove an RBAC role at the RG scope
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Reader" --scope (az group show -n $rg --query id -o tsv)
az role assignment delete --assignee $me --role "Reader" --scope (az group show -n $rg --query id -o tsv)
```

## 5) Done-when

1. All three `alert-security-*` rules exist and are enabled.
2. Manual KQL runs of the three queries return data (or zero with no error — meaning the table exists and shape is valid).
3. Scenario 47 triggered → alert fires → email + Logic App run visible.
4. Scenario 48 triggered → severity 1 alert fires.
5. (Optional) `NTANetAnalytics` returns rows. If Stage B hasn't been live long enough, mark this acceptance "deferred" rather than failed.
6. `wb-amlab-security` exists under *Monitor → Workbooks* and renders the eight sections without query errors.
