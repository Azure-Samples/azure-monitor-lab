# Generates docs/architecture-overview-sre.svg, the self-contained README architecture
# diagram with a light card layout and Azure service icons from the draw.io azure2 library.
# Keep the corresponding overview in docs/architecture.drawio in sync.
#
# Icons are downloaded from the jgraph/drawio public library and base64-embedded into a
# single SVG so the result renders on GitHub with no external dependencies.
#
# Re-run after changing nodes/edges:  ./scripts/gen-architecture-svg.ps1

$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/jgraph/drawio/dev/src/main/webapp/img/lib/azure2'

# --- icon key -> library path ---------------------------------------------------------
$iconPaths = @{
  vm       = 'compute/Virtual_Machine.svg'
  vmss     = 'compute/VM_Scale_Sets.svg'
  aks      = 'compute/Kubernetes_Services.svg'
  app      = 'compute/App_Services.svg'
  acr      = 'containers/Container_Registries.svg'
  job      = 'other/Worker_Container_App.svg'
  net      = 'networking/Virtual_Networks.svg'
  ama      = 'general/Input_Output.svg'
  otel     = 'local:OpenTelemetry.png'
  flow     = 'networking/Network_Watcher.svg'
  pol      = 'management_governance/Policy.svg'
  law      = 'management_governance/Log_Analytics_Workspaces.svg'
  ai       = 'management_governance/Application_Insights.svg'
  # Azure Portal resource icon, pinned to the portal-icon catalog revision.
  amw      = 'https://raw.githubusercontent.com/maskati/azure-icons/9ced4c629a4edfd2a31946e320ed0c309381787e/svg/Microsoft_Azure_Monitoring/MonitoringAccount.svg'
  storage  = 'storage/Storage_Accounts.svg'
  eventhub = 'iot/Event_Hubs.svg'
  keyvault = 'security/Key_Vaults.svg'
  graf     = 'general/Dashboard.svg'
  wb       = 'general/Workbooks.svg'
  ag       = 'management_governance/Alerts.svg'
  logic    = 'integration/Logic_Apps.svg'
  sent     = 'security/Azure_Sentinel.svg'
  health   = 'other/03528-icon-service-Monitor-Health-Models.svg'
  querypack = 'other/01085-icon-service-Log-Analytics-Query-Pack.svg'
  foundry  = 'ai_machine_learning/AI_Foundry.svg'
  agents   = 'ai_machine_learning/Bot_Services.svg'
  router   = 'general/Gear.svg'
  sre      = 'https://sre.azure.com/SreAgent.svg'
  # Azure Portal resource icon, pinned to the portal-icon catalog revision.
  obs      = 'https://raw.githubusercontent.com/maskati/azure-icons/9ced4c629a4edfd2a31946e320ed0c309381787e/svg/Microsoft_Azure_Monitoring_Alerts/ObservabilityAgent.svg'
  copilot  = 'local:github/GitHubCopilotCLI.png'
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$iconDir  = Join-Path $repoRoot 'docs/icons/azure'
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null

# --- download + base64-embed ----------------------------------------------------------
$dataUri = @{}
foreach ($k in $iconPaths.Keys) {
  if ($iconPaths[$k] -match '^local:(.+)$') {
    $dest = Join-Path $repoRoot "docs/icons/$($Matches[1])"
    if (-not (Test-Path $dest)) { throw "Required local architecture icon not found: $dest" }
  } else {
    $name = Split-Path $iconPaths[$k] -Leaf
    $dest = Join-Path $iconDir $name
    if (-not (Test-Path $dest)) {
      $source = if ($iconPaths[$k] -match '^https://') { $iconPaths[$k] } else { "$base/$($iconPaths[$k])" }
      Invoke-WebRequest $source -UseBasicParsing -OutFile $dest
    }
  }
  $bytes = [IO.File]::ReadAllBytes($dest)
  $mediaType = if ([IO.Path]::GetExtension($dest) -ieq '.png') { 'image/png' } else { 'image/svg+xml' }
  $dataUri[$k] = "data:$mediaType;base64," + [Convert]::ToBase64String($bytes)
}

# --- tiers (columns) ------------------------------------------------------------------
$cols = [ordered]@{
  WL   = @{ x = 30;   w = 300; title = 'Workloads';                  fill = '#EAF0F7' }
  COL  = @{ x = 380;  w = 300; title = 'Collection & lab operations'; fill = '#E8F2F2' }
  DATA = @{ x = 730;  w = 350; title = 'Telemetry backplane';        fill = '#EAF0F7' }
  USE  = @{ x = 1130; w = 340; title = 'Consumption & response';     fill = '#EEEDF5' }
}

# --- nodes (id, column, label lines, icon key(s)) -------------------------------------
$nodes = [ordered]@{
  VM    = @{ col = 'WL';   i = 0; lines = @('Linux & Windows VMs');            icons = @('vm') }
  VMSS  = @{ col = 'WL';   i = 1; lines = @('Linux VMSS','predictive autoscale'); icons = @('vmss') }
  AKS   = @{ col = 'WL';   i = 2; lines = @('AKS','Container Insights');       icons = @('aks') }
  APP   = @{ col = 'WL';   i = 3; lines = @('.NET 8 App Service','Control Center + telemetry'); icons = @('app') }
  NET   = @{ col = 'WL';   i = 4; lines = @('VNet / NSG','Connection Monitor'); icons = @('net') }
  FDRY  = @{ col = 'WL';   i = 5; lines = @('GenAI · Foundry + agents','chat/embed/router · optional'); icons = @('foundry','agents','router') }

  AMA   = @{ col = 'COL';  i = 0; lines = @('Azure Monitor Agent','DCRs · DCE'); icons = @('ama') }
  OTEL  = @{ col = 'COL';  i = 1; lines = @('OpenTelemetry','Standalone VM metrics via AMA'); icons = @('otel') }
  FLOW  = @{ col = 'COL';  i = 2; lines = @('NSG Flow Logs');                   icons = @('flow') }
  POL   = @{ col = 'COL';  i = 3; lines = @('Diag Settings via','Policy (DINE)'); icons = @('pol') }
  ACR   = @{ col = 'COL';  i = 4; lines = @('Container Registry (ACR)','digest-pinned runner image'); icons = @('acr') }
  JOB   = @{ col = 'COL';  i = 5; lines = @('Container Apps Job','approved lab operations'); icons = @('job') }

  LAW   = @{ col = 'DATA'; i = 0; lines = @('Log Analytics','central');         icons = @('law') }
  LAWAI  = @{ col = 'DATA'; i = 1; lines = @('Log Analytics','App Insights');     icons = @('law') }
  QUERY  = @{ col = 'DATA'; i = 2; lines = @('Log Analytics Query Pack');        icons = @('querypack') }
  AI     = @{ col = 'DATA'; i = 3; lines = @('Application Insights');             icons = @('ai') }
  AMW    = @{ col = 'DATA'; i = 4; lines = @('Azure Monitor Workspace','Managed Prometheus'); icons = @('amw') }
  OAMW   = @{ col = 'DATA'; i = 5; lines = @('Dedicated Monitor Workspace','Observability Agent issues'); icons = @('amw') }
  PLAT   = @{ col = 'DATA'; i = 6; lines = @('Storage · Event Hub · Key Vault');  icons = @('storage','eventhub','keyvault') }

  GRAF  = @{ col = 'USE';  i = 0; lines = @('Managed Grafana');                  icons = @('graf') }
  WB    = @{ col = 'USE';  i = 1; lines = @('Workbooks','Traffic Lights · Cost · AI FinOps'); icons = @('wb') }
  AG    = @{ col = 'USE';  i = 2; lines = @('Action Group','Alerts · AMBA · token spikes');     icons = @('ag') }
  OBS   = @{ col = 'USE';  i = 3; lines = @('Observability Agent','correlation · investigation'); icons = @('obs') }
  SRE   = @{ col = 'USE';  i = 4; lines = @('Azure SRE Agent','incident response · optional'); icons = @('sre') }
  LOGIC = @{ col = 'USE';  i = 5; lines = @('Logic App','auto-mitigation');      icons = @('logic') }
  SENT  = @{ col = 'USE';  i = 6; lines = @('Microsoft Sentinel');               icons = @('sent') }
  HEALTH = @{ col = 'USE'; i = 7; lines = @('Health Models','workload health');  icons = @('health') }
  COPILOT = @{ col = 'USE'; i = 8; lines = @('GitHub Copilot CLI','guided investigation'); icons = @('copilot') }
}

# --- edges (source -> target) ---------------------------------------------------------
$edges = @(
  @('VM','AMA'), @('VMSS','AMA'), @('AKS','AMA'), @('NET','FLOW'),
  @('AMA','LAW'), @('AMA','AMW'), @('AMA','OTEL'), @('OTEL','AMW'), @('FLOW','PLAT'), @('POL','LAW'), @('LAW','QUERY'), @('AI','LAWAI'), @('PLAT','LAW'),
  @('LAW','WB'), @('LAWAI','WB'), @('AMW','GRAF'), @('LAW','AG'), @('AI','AG'), @('AI','OBS'), @('AG','OBS'), @('OAMW','OBS'), @('AG','SRE'), @('AG','LOGIC'), @('LAW','SENT'), @('LAW','HEALTH'), @('LAW','COPILOT'),
  @('ACR','JOB')
)

# --- geometry -------------------------------------------------------------------------
$W = 1500; $H = 1100
$grpY = 130; $grpH = 940
$cellH = 82; $cellStep = 100; $firstTop = 168
function NodeTop($n) { $firstTop + ($n.i * $cellStep) }
function ColOf($n)   { $cols[$n.col] }
function Esc($s)     { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 $W $H' font-family='Segoe UI, Helvetica, Arial, sans-serif' role='img' aria-labelledby='architecture-title architecture-description'>")
[void]$sb.AppendLine("<title id='architecture-title'>Azure Monitor Lab architecture</title>")
[void]$sb.AppendLine("<desc id='architecture-description'>Workloads, telemetry collection, dashboards, and response. Azure Monitor Agent sends standalone VM OpenTelemetry metrics to the Azure Monitor workspace alongside classic Log Analytics monitoring. Application Insights and alerts feed Azure Copilot Observability Agent, which stores correlated issues in a dedicated Azure Monitor workspace. GitHub Copilot CLI consumes central monitoring context for guided investigations. Azure Container Registry supplies a digest-pinned image to the Container Apps Job used for approved lab operations.</desc>")
[void]$sb.AppendLine("<rect x='0' y='0' width='$W' height='$H' rx='18' fill='#F1F3F8'/>")
[void]$sb.AppendLine("<text x='$($W/2)' y='50' fill='#2D4770' font-size='32' font-weight='600' text-anchor='middle'>Azure Monitor Lab</text>")
[void]$sb.AppendLine("<text x='$($W/2)' y='77' fill='#52627A' font-size='14' text-anchor='middle'>rg-azure-monitor-lab · northeurope</text>")
[void]$sb.AppendLine("<text x='$($W/2)' y='98' fill='#52627A' font-size='12' text-anchor='middle'>Optional Foundry and agent stages use their documented supported regions</text>")
[void]$sb.AppendLine("<defs>")
[void]$sb.AppendLine("<linearGradient id='tier-accent' x1='0' y1='0' x2='1' y2='0'><stop offset='0' stop-color='#0F7774'/><stop offset='1' stop-color='#0079BA'/></linearGradient>")
[void]$sb.AppendLine("<filter id='card-shadow' x='-15%' y='-25%' width='130%' height='160%'><feDropShadow dx='0' dy='4' stdDeviation='5' flood-color='#203553' flood-opacity='0.13'/></filter>")
[void]$sb.AppendLine("<marker id='arrow' viewBox='0 0 10 10' refX='9' refY='5' markerWidth='7' markerHeight='7' orient='auto-start-reverse'><path d='M0,0 L10,5 L0,10 z' fill='#71859C'/></marker>")
[void]$sb.AppendLine("</defs>")
[void]$sb.AppendLine("<rect x='14' y='116' width='$($W-28)' height='$($H-130)' rx='20' fill='#FAFBFD' stroke='#FFFFFF' stroke-width='2'/>")

# group boxes
foreach ($key in $cols.Keys) {
  $c = $cols[$key]
  [void]$sb.AppendLine("<rect x='$($c.x)' y='$grpY' width='$($c.w)' height='$grpH' rx='22' fill='$($c.fill)'/>")
  [void]$sb.AppendLine("<rect x='$($c.x+14)' y='$($grpY-12)' width='$($c.w-28)' height='36' rx='18' fill='url(#tier-accent)'/>")
  [void]$sb.AppendLine("<text x='$($c.x + $c.w/2)' y='$($grpY+11)' fill='#FFFFFF' font-size='16' font-weight='600' text-anchor='middle'>$(Esc $c.title)</text>")
}

# edges first (under nodes)
function AnchorRight($n) { $c = ColOf $n; @(($c.x + $c.w - 12), ((NodeTop $n) + $cellH/2)) }
function AnchorLeft($n)  { $c = ColOf $n; @(($c.x + 12), ((NodeTop $n) + $cellH/2)) }
function AnchorTop($n)   { $c = ColOf $n; @(($c.x + $c.w/2), (NodeTop $n)) }
function AnchorBottom($n){ $c = ColOf $n; @(($c.x + $c.w/2), ((NodeTop $n) + $cellH)) }

$lineStyle = "stroke='#71859C' marker-end='url(#arrow)'"
foreach ($e in $edges) {
  $s = $nodes[$e[0]]; $t = $nodes[$e[1]]
  if ($s.col -eq $t.col) {
    $a = AnchorBottom $s; $b = AnchorTop $t
    [void]$sb.AppendLine("<path id='edge-$($e[0])-$($e[1])' d='M $($a[0]),$($a[1]) L $($b[0]),$($b[1])' fill='none' stroke-width='1.4' $lineStyle/>")
  } else {
    if ((ColOf $s).x -lt (ColOf $t).x) { $a = AnchorRight $s; $b = AnchorLeft $t }
    else { $a = AnchorLeft $s; $b = AnchorRight $t }
    $mx = ($a[0] + $b[0]) / 2
    [void]$sb.AppendLine("<path id='edge-$($e[0])-$($e[1])' d='M $($a[0]),$($a[1]) C $mx,$($a[1]) $mx,$($b[1]) $($b[0]),$($b[1])' fill='none' stroke-width='1.4' $lineStyle/>")
  }
}

# nodes
foreach ($id in $nodes.Keys) {
  $n = $nodes[$id]; $c = ColOf $n; $top = NodeTop $n
  [void]$sb.AppendLine("<g id='node-$id'>")
  [void]$sb.AppendLine("<rect x='$($c.x+12)' y='$top' width='$($c.w-24)' height='$cellH' rx='14' fill='#FFFFFF' filter='url(#card-shadow)'/>")
  $ic = $n.icons
  if ($ic.Count -eq 1) {
    [void]$sb.AppendLine("<image x='$($c.x+24)' y='$($top+19)' width='44' height='44' href='$($dataUri[$ic[0]])'/>")
    $lx = $c.x + 80
  } else {
    $ix = $c.x + 24
    foreach ($k in $ic) { [void]$sb.AppendLine("<image x='$ix' y='$($top+10)' width='30' height='30' href='$($dataUri[$k])'/>"); $ix += 38 }
    $lx = $c.x + 24
  }
  $lines = $n.lines
  if ($ic.Count -gt 1) {
    [void]$sb.AppendLine("<text x='$lx' y='$($top+57)' fill='#182B45' font-size='14' font-weight='600'>$(Esc $lines[0])</text>")
    if ($lines.Count -gt 1) {
      [void]$sb.AppendLine("<text x='$lx' y='$($top+73)' fill='#52627A' font-size='12'>$(Esc $lines[1])</text>")
    }
  } elseif ($lines.Count -eq 1) {
    [void]$sb.AppendLine("<text x='$lx' y='$($top+46)' fill='#182B45' font-size='14' font-weight='600'>$(Esc $lines[0])</text>")
  } else {
    [void]$sb.AppendLine("<text x='$lx' y='$($top+35)' fill='#182B45' font-size='14' font-weight='600'>$(Esc $lines[0])</text>")
    [void]$sb.AppendLine("<text x='$lx' y='$($top+55)' fill='#52627A' font-size='12'>$(Esc $lines[1])</text>")
  }
  [void]$sb.AppendLine('</g>')
}

[void]$sb.AppendLine('</svg>')

$outPath = Join-Path $repoRoot 'docs/architecture-overview-sre.svg'
[IO.File]::WriteAllText($outPath, $sb.ToString(), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote $outPath ($($sb.Length) bytes), $($iconPaths.Count) icons in $iconDir"
