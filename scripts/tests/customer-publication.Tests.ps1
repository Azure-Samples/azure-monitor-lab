$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$fixture = Join-Path $repo ('.artifacts\customer-publication-check-' + [guid]::NewGuid().ToString('N'))
try {
  $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts'), (Join-Path $fixture 'publish\wwwroot') -Force
  $helper = Join-Path $fixture 'scripts\prepare-webapp-package.ps1'
  Copy-Item (Join-Path $repo 'scripts\prepare-webapp-package.ps1') $helper
  @'
param($ResourceGroup,$SubscriptionId,$TenantId,$WebAppName,$CustomerWebAppName,$CentralLawName,$OutputPath,$SreModelEndpoint,$SreModelDeployment)
@{LabConsole=@{Sre=@{AgentName=''}}} | ConvertTo-Json -Depth 4 | Set-Content $OutputPath
'@ | Set-Content (Join-Path $fixture 'scripts\write-webapp-console-config.ps1')
  $publish = Join-Path $fixture 'publish'
  'offline fixture' | Set-Content (Join-Path $publish 'AmlabHello.dll')
  'offline page' | Set-Content (Join-Path $publish 'wwwroot\index.html')
  '{"libraries":{"CustomerOrders/1.0.0":{"type":"project"}}}' | Set-Content (Join-Path $publish 'AmlabHello.deps.json')
  $parameters = @{PublishDirectory=$publish;ResourceGroup='test-rg';SubscriptionId='test-sub';TenantId='test-tenant'}
  $failed = $false
  try { & $helper @parameters } catch { $failed = $_.Exception.Message -match 'CustomerOrders.dll' }
  if (-not $failed -or (Test-Path (Join-Path $publish 'lab-console.json'))) { throw 'Missing referenced runtime assembly must fail before package configuration.' }
  'offline dependency' | Set-Content (Join-Path $publish 'CustomerOrders.dll')
  & $helper @parameters
  $archive = Join-Path $fixture 'publish.zip'
  Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $archive
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    if (-not ($zip.Entries.FullName -contains 'CustomerOrders.dll')) { throw 'Publication ZIP lost the referenced customer assembly.' }
  } finally { $zip.Dispose() }
  [xml] $project = Get-Content (Join-Path $repo 'workloads\webapp\AmlabHello.csproj') -Raw
  $reference = @($project.Project.ItemGroup.ProjectReference | Where-Object Include -like '*CustomerOrders.csproj').Include
  if (-not $reference -or -not (Test-Path (Join-Path $repo "workloads\webapp\$reference"))) { throw 'Original repository publication must resolve the customer project reference.' }
  foreach ($script in @('deploy-webapp.ps1','post-deploy.ps1','trigger-code-optimization.ps1')) {
    $source = Get-Content (Join-Path $repo "scripts\$script") -Raw
    if ($source -notmatch 'dotnet publish' -or $source -notmatch 'AmlabHello.csproj') { throw "Publication path changed unexpectedly: $script" }
  }
  Write-Output 'PASS: original customer ProjectReference resolves; missing published CustomerOrders.dll fails closed; complete referenced assembly survives package preparation and ZIP (offline, no Azure).'
} finally {
  if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
