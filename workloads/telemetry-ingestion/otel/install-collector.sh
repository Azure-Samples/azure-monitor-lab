#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
umask 077

deny() { printf 'OTLP_COLLECTOR_DENIED\n'; exit 1; }
[[ $# == 4 ]] || deny
mode=$1
vm_id=$2
endpoint=$3
configuration=$4
[[ $mode == preflight || $mode == install ]] || deny
[[ $vm_id =~ ^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft.Compute/virtualMachines/[a-zA-Z0-9_.-]+$ ]] || deny
[[ $endpoint =~ ^https://[a-zA-Z0-9.-]+\.ingest\.monitor\.azure\.com/datacollectionRules/dcr-[a-zA-Z0-9-]+/streams/Microsoft-OTLP-Logs/otlp/v1/logs$ ]] || deny
[[ $configuration =~ ^[a-zA-Z0-9_-]+$ ]] || deny
[[ $(id -u) == 0 && $(uname -m) == x86_64 && $(uname -s) == Linux ]] || deny
source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || deny
for command in systemctl ss curl sha256sum tar base64; do command -v "$command" >/dev/null 2>&1 || deny; done
systemctl is-active --quiet azuremonitoragent || deny
owner=/etc/otelcol-contrib/azure-monitor-lab-owner
if [[ -e "$owner" ]]; then
  [[ $(cat "$owner") == "$vm_id" ]] || deny
  [[ -f /etc/otelcol-contrib/config.yaml && -f /etc/systemd/system/azure-monitor-lab-otelcol.service ]] || deny
  [[ -x /usr/local/bin/otelcol-contrib ]] || deny
  [[ $(/usr/local/bin/otelcol-contrib --version) == *0.148.0* ]] || deny
else
  [[ ! -e /etc/otelcol-contrib && ! -e /etc/systemd/system/azure-monitor-lab-otelcol.service ]] || deny
  ! command -v otelcol-contrib >/dev/null 2>&1 || deny
fi
if [[ $(ss -lntH '( sport = :4318 )' 2>/dev/null) ]]; then
  [[ -e "$owner" ]] && systemctl is-active --quiet azure-monitor-lab-otelcol || deny
  [[ $(ss -lntH '( sport = :4318 )') == *127.0.0.1:4318* ]] || deny
fi
[[ $mode == install ]] || { printf 'OTLP_COLLECTOR_PREFLIGHT_OK\n'; exit 0; }

if [[ ! -e "$owner" ]]; then
  archive=/root/.otelcol-contrib-azure-monitor-download
  [[ ! -e "$archive" ]] || deny
  trap 'rm -f "$archive"' EXIT
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --max-time 180 \
    --output "$archive" \
    'https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.148.0/otelcol-contrib_0.148.0_linux_amd64.tar.gz' >/dev/null 2>&1 || deny
  echo "224be33baa9eb534838e3d742d5327eff6a6bb60cdf4a16daf9c4e70d438fe00  $archive" |
    sha256sum -c - >/dev/null 2>&1 || deny
  tar -xzf "$archive" -O otelcol-contrib > /usr/local/bin/otelcol-contrib || deny
  chmod 755 /usr/local/bin/otelcol-contrib
  [[ $(/usr/local/bin/otelcol-contrib --version) == *0.148.0* ]] || deny
  rm -f "$archive"
  trap - EXIT
  install -d -m 700 /etc/otelcol-contrib
  printf '%s\n' "$vm_id" > "$owner"
fi

encoded=${configuration//-/+}
encoded=${encoded//_/\/}
while (( ${#encoded} % 4 )); do encoded+='='; done
printf '%s' "$encoded" | base64 --decode > /etc/otelcol-contrib/config.yaml || deny
printf 'AZURE_MONITOR_OTLP_LOGS_ENDPOINT=%s\n' "$endpoint" > /etc/otelcol-contrib/endpoint.env
export AZURE_MONITOR_OTLP_LOGS_ENDPOINT=$endpoint
chmod 600 /etc/otelcol-contrib/config.yaml /etc/otelcol-contrib/endpoint.env
cat > /etc/systemd/system/azure-monitor-lab-otelcol.service <<'UNIT'
[Unit]
Description=Azure Monitor lab native OTLP logs Collector
After=network-online.target
Wants=network-online.target
[Service]
Type=exec
EnvironmentFile=/etc/otelcol-contrib/endpoint.env
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/otelcol-contrib/config.yaml
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
/usr/local/bin/otelcol-contrib validate --config /etc/otelcol-contrib/config.yaml >/dev/null 2>&1 || deny
systemctl daemon-reload
systemctl enable --now azure-monitor-lab-otelcol >/dev/null 2>&1 || deny
systemctl restart azure-monitor-lab-otelcol >/dev/null 2>&1 || deny
systemctl is-active --quiet azure-monitor-lab-otelcol || deny
systemctl is-active --quiet azuremonitoragent || deny
printf 'OTLP_COLLECTOR_INSTALL_OK\n'
