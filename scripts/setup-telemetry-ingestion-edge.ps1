[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $HostName,
  [Parameter(Mandatory)] [string] $SshUser,
  [switch] $OptIn,
  [ValidateRange(20, 65535)] [int] $MinFreeGiB = 20
)
$ErrorActionPreference = 'Stop'
if ($HostName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -or
    $SshUser -notmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,63}$') {
  throw 'Invalid SSH hostname or user.'
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw 'ssh is required for read-only host assessment.' }

# The remote script performs no writes, package installs, Arc registration, or service restarts.
$probe = @'
set -eu
printf 'os='; uname -s
printf 'arch='; uname -m
printf 'distro='; ( . /etc/os-release; printf '%s\n' "$ID:$VERSION_ID" )
printf 'cpu='; getconf _NPROCESSORS_ONLN
printf 'mem_kib='; awk '/^MemAvailable:/ {print $2}' /proc/meminfo
printf 'root_free_kib='; df -Pk / | awk 'NR==2 {print $4}'
printf 'systemd='; if command -v systemctl >/dev/null 2>&1; then echo yes; else echo no; fi
printf 'ama='; if command -v systemctl >/dev/null 2>&1; then systemctl is-active azuremonitoragent 2>/dev/null || :; else echo unknown; fi
printf 'k3s='; if command -v k3s >/dev/null 2>&1; then echo present; else echo absent; fi
printf 'arc='; if command -v azcmagent >/dev/null 2>&1; then echo present; else echo absent; fi
printf 'dns='; if getent hosts management.azure.com >/dev/null 2>&1; then echo ok; else echo unavailable; fi
printf 'https='; if command -v curl >/dev/null 2>&1 && test "$(curl -sSI -o /dev/null -w '%{http_code}' --max-time 8 https://management.azure.com/)" != 000; then echo ok; else echo unavailable; fi
printf 'port_6514='; if command -v ss >/dev/null 2>&1 && ss -lnt | grep -Eq '[:.]6514[[:space:]]'; then echo busy; else echo free_or_unknown; fi
printf 'port_4317='; if command -v ss >/dev/null 2>&1 && ss -lnt | grep -Eq '[:.]4317[[:space:]]'; then echo busy; else echo free_or_unknown; fi
'@
$lines = @($probe | & ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$SshUser@$HostName" 'sh -s')
if ($LASTEXITCODE -ne 0) { throw "Read-only SSH assessment failed ($LASTEXITCODE)." }
$result = @{}
foreach ($line in $lines) {
  if ($line -match '^([a-z0-9_]+)=(.*)$') { $result[$Matches[1]] = $Matches[2] }
}
$required = @('os','arch','distro','cpu','mem_kib','root_free_kib','systemd','ama','k3s','arc','dns','https','port_6514','port_4317')
foreach ($key in $required) { if (-not $result.ContainsKey($key)) { throw "Missing host assessment field $key." } }
$capacity = $result.os -eq 'Linux' -and $result.arch -in @('x86_64','aarch64') -and
  $result.systemd -eq 'yes' -and [int]$result.cpu -ge 4 -and
  [long]$result.mem_kib -ge (8 * 1024 * 1024) -and
  [long]$result.root_free_kib -ge ($MinFreeGiB * 1024 * 1024)
$network = $result.dns -eq 'ok' -and $result.https -eq 'ok'
[pscustomobject]@{
  Host = $HostName
  AssessmentOnly = $true
  Linux = $result.os
  Distribution = $result.distro
  Architecture = $result.arch
  CPUs = $result.cpu
  AvailableMemoryKiB = $result.mem_kib
  FreeRootKiB = $result.root_free_kib
  AMA = $result.ama
  K3s = $result.k3s
  ArcAgent = $result.arc
  Dns = $result.dns
  Https = $result.https
  Listener6514 = $result.port_6514
  Listener4317 = $result.port_4317
  CapacityPass = $capacity
  NetworkPass = $network
  OptedIn = [bool]$OptIn
}
if (-not $capacity -or -not $network) { throw 'Host capacity/network gate failed. No changes were made.' }
if ($OptIn) {
  Write-Warning 'Opt-in acknowledged for planning ONLY. No installation, Arc connection, extension deployment, DCR deployment, or VM modification was performed.'
  Write-Warning 'Confirm distro-specific K3s prerequisites, actual DCE egress, Arc/Kubernetes/cert-manager support, AMA health, isolation and change approval manually before any separate deployment.'
} else {
  Write-Warning 'Default is assessment only; K3s and Arc enrollment require a separately approved manual action.'
}
