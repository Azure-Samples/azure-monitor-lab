#!/usr/bin/env bash
# Invoked only by Azure VM Run Command with positional parameters.
set -euo pipefail
[[ $# == 8 ]] || { printf 'PIPELINE_DENIED:arguments\n'; exit 1; }
MODE=$1 SUBSCRIPTION_ID=$2 TENANT_ID=$3 RESOURCE_GROUP=$4
CLUSTER_NAME=$5 LOCATION=$6 VM_ID=$7 ARC_ALREADY_OWNED=$8
export PATH=/usr/local/bin:/usr/bin:/bin
export AZURE_CORE_ONLY_SHOW_ERRORS=true
export AZURE_CORE_COLLECT_TELEMETRY=no
umask 077

deny() { printf 'PIPELINE_DENIED:%s\n' "${1:-unspecified}"; exit 1; }
[[ ${MODE:-} == preflight || ${MODE:-} == install ]] || deny inputs
[[ ${SUBSCRIPTION_ID:-} =~ ^[0-9a-fA-F-]{36}$ &&
   ${TENANT_ID:-} =~ ^[0-9a-fA-F-]{36}$ &&
   ${RESOURCE_GROUP:-} =~ ^[a-zA-Z0-9_.()-]{1,90}$ &&
   ${CLUSTER_NAME:-} =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ &&
   ${LOCATION:-} =~ ^[a-z0-9]+$ &&
   ${VM_ID:-} =~ ^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft.Compute/virtualMachines/[a-zA-Z0-9_.-]+$ ]] || deny inputs
[[ $(id -u) == 0 && $(uname -m) == x86_64 && $(uname -s) == Linux ]] || deny host
source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || deny os
[[ $(getconf _NPROCESSORS_ONLN) -ge 4 ]] || deny cpu
[[ $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) -ge 8388608 ]] || deny memory
root_free_kib=$(df -Pk / | awk 'NR==2 {print $4}') || deny disk
[[ $root_free_kib =~ ^[0-9]+$ ]] || deny disk
for command in systemctl ss curl sha256sum apt-get gpg ip tar; do command -v "$command" >/dev/null 2>&1 || deny commands; done
systemctl is-active --quiet azuremonitoragent || deny ama
listeners=$(ss -lntH '( sport = :6514 or sport = :6443 or sport = :10250 or sport = :2379 or sport = :2380 )' 2>/dev/null) || deny ports
[[ -z $listeners ]] || {
  # A previously installed, owned K3s server may already use its own API listener.
  [[ -f /etc/rancher/k3s/azure-monitor-lab-owner &&
     $listeners == *:6443* &&
     $listeners != *:6514* &&
     $listeners != *:2379* && $listeners != *:2380* ]] || deny ports
}
owner=/etc/rancher/k3s/azure-monitor-lab-owner
[[ $ARC_ALREADY_OWNED == true || $ARC_ALREADY_OWNED == false ]] || deny ownership
[[ $ARC_ALREADY_OWNED == false || -e "$owner" ]] || deny ownership
if [[ -e "$owner" ]]; then
  [[ $(cat "$owner") == "$VM_ID|$CLUSTER_NAME" ]] || deny ownership
  [[ -f /usr/local/bin/k3s && -f /etc/systemd/system/k3s.service &&
     -f /etc/rancher/k3s/config.yaml ]] || deny k3s
  echo 'f03cad6610cf5b2903d8a9ac3d6716690e53dab461b09c07b0c913a262166abc  /usr/local/bin/k3s' | sha256sum -c - >/dev/null 2>&1 || deny checksum
  private_ip=$(awk -F '"' '/^advertise-address:/ {print $2}' /etc/rancher/k3s/config.yaml)
  [[ $private_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ &&
     $private_ip == "$(ip -4 route get 168.63.129.16 | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')" ]] || deny k3s
  grep -Fqx "ExecStart=/usr/local/bin/k3s server --flannel-backend host-gw --kubelet-arg=address=$private_ip --disable traefik --disable servicelb --write-kubeconfig-mode 600" /etc/systemd/system/k3s.service || deny k3s
  systemctl is-active --quiet k3s || deny k3s
  [[ $listeners == *"$private_ip:10250"* ]] || deny k3s
  min_free_kib=10485760
else
  [[ ! -e /usr/local/bin/k3s && ! -e /etc/rancher/k3s &&
     ! -e /etc/systemd/system/k3s.service ]] || deny k3s
  ! systemctl list-units --all --no-legend 'k3s*' | grep -q k3s || deny k3s
  min_free_kib=20971520
fi
[[ $root_free_kib -ge $min_free_kib ]] || deny disk
if [[ $MODE == preflight ]]; then
  printf 'PIPELINE_PREFLIGHT_OK\n'
  exit 0
fi

if ! command -v az >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || deny packages
  apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1 || deny packages
  install -d -m 755 /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    https://packages.microsoft.com/keys/microsoft.asc --output /etc/apt/keyrings/microsoft.asc >/dev/null 2>&1 || deny packages
  chmod 644 /etc/apt/keyrings/microsoft.asc
  printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.asc] https://packages.microsoft.com/repos/azure-cli/ jammy main\n' \
    > /etc/apt/sources.list.d/azure-cli.sources.list
  apt-get update -qq >/dev/null 2>&1 || deny packages
  apt-get install -y azure-cli >/dev/null 2>&1 || deny packages
fi
az extension show --name connectedk8s --only-show-errors --output none >/dev/null 2>&1 ||
  az extension add --name connectedk8s --yes --only-show-errors --output none >/dev/null 2>&1 || deny connectedk8s
if ! command -v helm >/dev/null 2>&1; then
  archive=/root/.helm-azure-monitor-download
  [[ ! -e "$archive" ]] || deny helm
  trap 'rm -f "$archive"' EXIT
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --max-time 180 --output "$archive" \
    'https://get.helm.sh/helm-v3.17.3-linux-amd64.tar.gz' >/dev/null 2>&1 || deny helm
  echo "ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd  $archive" |
    sha256sum -c - >/dev/null 2>&1 || deny helm
  tar -xzf "$archive" -O linux-amd64/helm > /usr/local/bin/helm || deny helm
  chmod 755 /usr/local/bin/helm
  rm -f "$archive"
  trap - EXIT
fi
[[ $(helm version --short 2>/dev/null) == v3.* ]] || deny helm

if [[ ! -e "$owner" ]]; then
  # The version and SHA256 are fixed independently of the download response.
  binary=/root/.k3s-azure-monitor-download
  [[ ! -e "$binary" ]] || deny k3s-download
  trap 'rm -f "$binary"' EXIT
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --max-time 180 --output "$binary" \
    'https://github.com/k3s-io/k3s/releases/download/v1.33.3%2Bk3s1/k3s' >/dev/null 2>&1 || deny k3s-download
  echo "f03cad6610cf5b2903d8a9ac3d6716690e53dab461b09c07b0c913a262166abc  $binary" |
    sha256sum -c - >/dev/null 2>&1 || deny k3s-download
  private_ip=$(ip -4 route get 168.63.129.16 | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
  [[ $private_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || deny k3s-network
  install -d -m 700 /etc/rancher/k3s
  install -m 755 "$binary" /usr/local/bin/k3s
  printf 'bind-address: "%s"\nadvertise-address: "%s"\n' "$private_ip" "$private_ip" > /etc/rancher/k3s/config.yaml
  printf '%s|%s\n' "$VM_ID" "$CLUSTER_NAME" > "$owner"
  cat > /etc/systemd/system/k3s.service <<UNIT
[Unit]
Description=Azure Monitor lab single-node K3s
After=network-online.target
Wants=network-online.target
[Service]
Type=exec
ExecStart=/usr/local/bin/k3s server --flannel-backend host-gw --kubelet-arg=address=$private_ip --disable traefik --disable servicelb --write-kubeconfig-mode 600
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now k3s >/dev/null 2>&1 || deny k3s-service
fi
systemctl is-active --quiet k3s || deny k3s-service
[[ -f /etc/rancher/k3s/k3s.yaml ]] || deny k3s-config
private_ip=$(awk -F '"' '/^advertise-address:/ {print $2}' /etc/rancher/k3s/config.yaml)
[[ $private_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || deny k3s-config
if grep -q 'server: https://127.0.0.1:6443' /etc/rancher/k3s/k3s.yaml; then
  sed -i "s#server: https://127.0.0.1:6443#server: https://${private_ip}:6443#" /etc/rancher/k3s/k3s.yaml
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for attempt in {1..30}; do
  if /usr/local/bin/k3s kubectl get --raw=/readyz >/dev/null 2>&1; then break; fi
  sleep 2
done
/usr/local/bin/k3s kubectl get --raw=/readyz >/dev/null 2>&1 || deny k3s-ready
systemctl is-active --quiet azuremonitoragent || deny ama
az login --identity --allow-no-subscriptions --output none >/dev/null 2>&1 || deny identity-login
account=$(az account show --subscription "$SUBSCRIPTION_ID" --query tenantId -o tsv 2>/dev/null) || deny identity-account
[[ ${account,,} == ${TENANT_ID,,} ]] || deny identity-tenant
if [[ ${ARC_ALREADY_OWNED:-false} == true ]]; then
  # Never reconnect an existing resource; the orchestrator verifies its owner and status.
  printf 'PIPELINE_INSTALL_OK\n'
  exit 0
fi
az connectedk8s connect --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" --subscription "$SUBSCRIPTION_ID" --kube-config "$KUBECONFIG" \
  --tags "monitor-lab-edge-vm=$VM_ID" --output none >/dev/null 2>&1 || deny arc-connect
printf 'PIPELINE_INSTALL_OK\n'
