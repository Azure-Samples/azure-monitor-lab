<#
.SYNOPSIS
  Creates, inspects, or removes temporary AKS workloads that move the demo SLIs.

.DESCRIPTION
  Degrade creates two isolated deployments in the demo namespace:
  - sli-unavailable creates Pending pods with an intentionally invalid image.
  - sli-slow-start creates pods whose init container waits longer than the
    30-second pod-start latency threshold.

  Status lists the test deployments and pods. Restore removes only those two
  deployments. The script does not modify the hello-frontend deployment.

.PARAMETER SubscriptionId
  Expected Azure subscription ID. Must match the active account after pinning.

.PARAMETER ResourceGroup
  Resource group containing the target AKS cluster.

.PARAMETER Mode
  Degrade, Status, or Restore. Defaults to Degrade.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [ValidateSet('Degrade', 'Status', 'Restore')]
  [string] $Mode = 'Degrade',
  [string] $Namespace = 'demo'
)

$ErrorActionPreference = 'Stop'
function Write-Step($Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Assert-NativeCommandSucceeded($Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

Write-Step "Pinning Azure subscription"
az account set --subscription $SubscriptionId | Out-Null
Assert-NativeCommandSucceeded 'Setting the Azure subscription'
$activeSubscriptionId = az account show --query id -o tsv
Assert-NativeCommandSucceeded 'Reading the active Azure subscription'
if ($activeSubscriptionId -ne $SubscriptionId) {
  throw "BLOCKED: active subscription '$activeSubscriptionId' does not match expected subscription '$SubscriptionId'."
}

Write-Step "Connecting to AKS in '$ResourceGroup'"
$aksClusters = @(az aks list -g $ResourceGroup -o json | ConvertFrom-Json)
Assert-NativeCommandSucceeded 'Finding the AKS cluster'
if ($aksClusters.Count -ne 1) {
  throw "Expected exactly one AKS cluster in '$ResourceGroup', found $($aksClusters.Count)."
}
$aks = $aksClusters[0]
if ($aks.powerState.code -ne 'Running') {
  throw "AKS cluster '$($aks.name)' is '$($aks.powerState.code)'. Start it before running the SLI demo."
}
az aks get-credentials -g $ResourceGroup -n $aks.name --overwrite-existing --output none
Assert-NativeCommandSucceeded "Connecting kubectl to '$($aks.name)'"
kubectl get namespace $Namespace --output name | Out-Null
Assert-NativeCommandSucceeded "Finding namespace '$Namespace'"

$testDeployments = @('sli-unavailable', 'sli-slow-start')

if ($Mode -eq 'Restore') {
  Write-Step "Removing SLI test deployments"
  kubectl delete deployment $testDeployments -n $Namespace --ignore-not-found
  Assert-NativeCommandSucceeded 'Removing the SLI test deployments'
  Write-Host "`nSLI test workloads removed. Source metrics should recover after the next evaluation windows." -ForegroundColor Green
  return
}

if ($Mode -eq 'Status') {
  Write-Step "Showing SLI test workloads"
  kubectl get deployment,pod -n $Namespace -l 'amlab-scenario=sli-degradation' -o wide
  Assert-NativeCommandSucceeded 'Showing the SLI test workloads'
  return
}

Write-Step "Replacing reversible SLI degradation workloads"
kubectl delete deployment $testDeployments -n $Namespace --ignore-not-found --wait=true
Assert-NativeCommandSucceeded 'Removing previous SLI degradation workloads'

$manifest = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sli-unavailable
  namespace: demo
  labels:
    amlab-scenario: sli-degradation
spec:
  replicas: 5
  selector:
    matchLabels:
      app: sli-unavailable
  template:
    metadata:
      labels:
        app: sli-unavailable
        amlab-scenario: sli-degradation
    spec:
      containers:
      - name: unavailable
        image: mcr.microsoft.com/azuredocs/aks-helloworld:does-not-exist
        resources:
          requests:
            cpu: 5m
            memory: 8Mi
          limits:
            cpu: 20m
            memory: 32Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sli-slow-start
  namespace: demo
  labels:
    amlab-scenario: sli-degradation
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sli-slow-start
  template:
    metadata:
      labels:
        app: sli-slow-start
        amlab-scenario: sli-degradation
    spec:
      initContainers:
      - name: startup-delay
        image: busybox:1.36
        command: ["sh", "-c", "sleep 45"]
        resources:
          requests:
            cpu: 5m
            memory: 8Mi
          limits:
            cpu: 20m
            memory: 32Mi
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh", "-c", "sleep 3600"]
        resources:
          requests:
            cpu: 5m
            memory: 8Mi
          limits:
            cpu: 20m
            memory: 32Mi
'@

$renderedManifest = $manifest.Replace('namespace: demo', "namespace: $Namespace")
$manifestPath = Join-Path ($env:TEMP ?? [IO.Path]::GetTempPath()) "amlab-sli-demo-$([guid]::NewGuid().ToString('N')).yaml"
try {
  $renderedManifest | Set-Content -Path $manifestPath -Encoding utf8
  kubectl apply -f $manifestPath
  Assert-NativeCommandSucceeded 'Applying the SLI degradation workloads'
} finally {
  Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
}

Write-Step "Waiting for the slow-start deployment"
kubectl rollout status deployment/sli-slow-start -n $Namespace --timeout=3m
Assert-NativeCommandSucceeded 'Waiting for the slow-start deployment'

Write-Step "Current SLI test workload status"
kubectl get deployment,pod -n $Namespace -l 'amlab-scenario=sli-degradation' -o wide
Assert-NativeCommandSucceeded 'Showing the SLI test workloads'

Write-Host @"

The availability test pods intentionally remain Pending. The slow-start pods
started after a 45-second init delay. Allow one or two 5-minute source windows
and the SLI processing delay before evaluating Compliance and Burn Rate.

Restore with:
  ./scripts/demo-slis.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -Mode Restore
"@ -ForegroundColor Yellow