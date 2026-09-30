#!/usr/bin/env bash

#==============================================================================
# PRIVATE NODE AND STORAGE MONITORING
#==============================================================================

set -euo pipefail

action="${1:-validate}"
metrics_address="${2:-}"
metrics_source_address="${3:-}"
host_name="${4:-}"
storage_paths_json="${5:-[] }"
node_exporter_version=1.12.1
textfile_directory=/var/lib/node-exporter/textfile
configuration_directory=/etc/bharathcloudops

#==============================================================================
# INPUT VALIDATION
#==============================================================================

validate_ipv4() {
  local address="$1"
  local octet
  local -a octets

  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

if [[ ! "$action" =~ ^(validate|deploy|verify|status|report)$ ]] || \
  ! validate_ipv4 "$metrics_address" || \
  ! validate_ipv4 "$metrics_source_address" || \
  [[ ! "$host_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || \
  ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and startswith("/") and (contains("\n") | not))' <<< "$storage_paths_json" >/dev/null; then
  printf 'Valid action, private addresses, host name, and absolute storage paths are required.\n' >&2
  exit 10
fi

if [[ "$action" == "validate" ]]; then
  printf 'node_monitoring_validation=ready\n'
  exit 0
fi

for required_command in curl install iptables jq sha256sum sudo systemctl tar; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$required_command" >&2
    exit 20
  fi
done

if ! sudo -n true; then
  printf 'The automation user does not have non-interactive sudo access.\n' >&2
  exit 30
fi

#==============================================================================
# STATUS AND VERIFICATION
#==============================================================================

verify_monitoring() {
  sudo -n systemctl is-active --quiet node-exporter.service
  sudo -n systemctl is-active --quiet node-storage-metrics.timer
  curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --retry-max-time 30 \
    "http://${metrics_address}:9100/metrics" |
    grep -F 'node_cpu_seconds_total' >/dev/null
  sudo -n iptables -C NODE_EXPORTER_METRICS -p tcp -s "${metrics_source_address}/32" \
    -d "${metrics_address}/32" --dport 9100 -j ACCEPT
  printf 'node_monitoring=ready\n'
}

show_status() {
  printf 'host=%s\n' "$host_name"
  printf 'node_exporter_state=%s\n' "$(sudo -n systemctl is-active node-exporter.service 2>/dev/null || true)"
  printf 'storage_collector_state=%s\n' "$(sudo -n systemctl is-active node-storage-metrics.timer 2>/dev/null || true)"
  printf 'failed_systemd_units=%s\n' "$(sudo -n systemctl --failed --no-legend | wc -l | tr -d ' ')"
  printf 'node_monitoring_status=ready\n'
}

report_health() {
  show_status
  printf '\nFILESYSTEMS\n'
  df --human-readable --print-type
  printf '\nMEMORY\n'
  free --human
  printf '\nLOAD_AND_UPTIME\n'
  uptime
  printf '\nMANAGED_STORAGE\n'
  while IFS= read -r managed_path; do
    if sudo -n test -e "$managed_path"; then
      printf '\nPATH %s\n' "$managed_path"
      sudo -n du --summarize --human-readable --one-file-system -- "$managed_path" 2>/dev/null || true
      sudo -n find "$managed_path" -xdev -type f -printf '%s\t%p\n' 2>/dev/null |
        sort --numeric-sort --reverse | head -n 20 || true
    else
      printf '\nPATH %s MISSING\n' "$managed_path"
    fi
  done < <(jq -r '.[]' <<< "$storage_paths_json")
  if command -v docker >/dev/null 2>&1; then
    printf '\nDOCKER_STORAGE\n'
    sudo -n docker system df --verbose 2>/dev/null || true
  fi
  printf 'node_monitoring_report=ready\n'
}

case "$action" in
  verify)
    verify_monitoring
    exit 0
    ;;
  status)
    show_status
    exit 0
    ;;
  report)
    report_health
    exit 0
    ;;
esac

#==============================================================================
# PINNED NODE EXPORTER INSTALLATION
#==============================================================================

case "$(uname -m)" in
  x86_64|amd64)
    archive_architecture=amd64
    expected_sha256=b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63
    ;;
  aarch64|arm64)
    archive_architecture=arm64
    expected_sha256=ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7
    ;;
  *)
    printf 'Unsupported host architecture: %s\n' "$(uname -m)" >&2
    exit 40
    ;;
esac

installed_version=$(node_exporter --version 2>&1 | awk '/node_exporter, version/ { print $3 }' || true)
if [[ "$installed_version" != "$node_exporter_version" ]]; then
  temporary_directory=$(mktemp -d)
  trap 'rm -rf "$temporary_directory"' EXIT
  archive_name="node_exporter-${node_exporter_version}.linux-${archive_architecture}.tar.gz"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/${archive_name}" \
    --output "$temporary_directory/$archive_name"
  printf '%s  %s\n' "$expected_sha256" "$temporary_directory/$archive_name" |
    sha256sum --check --status
  tar --extract --gzip --file "$temporary_directory/$archive_name" --directory "$temporary_directory"
  sudo -n install -o root -g root -m 0755 \
    "$temporary_directory/node_exporter-${node_exporter_version}.linux-${archive_architecture}/node_exporter" \
    /usr/local/bin/node_exporter
fi

#==============================================================================
# STORAGE METRICS COLLECTOR
#==============================================================================

collector_script=$(mktemp)
collector_service=$(mktemp)
collector_timer=$(mktemp)
exporter_service=$(mktemp)
firewall_script=$(mktemp)
firewall_service=$(mktemp)
trap 'rm -f "$collector_script" "$collector_service" "$collector_timer" "$exporter_service" "$firewall_script" "$firewall_service"' EXIT

cat > "$collector_script" <<'COLLECTOR'
#!/usr/bin/env bash

#==============================================================================
# MANAGED STORAGE METRICS COLLECTOR
#==============================================================================

set -euo pipefail

configuration=/etc/bharathcloudops/node-monitoring.json
output_directory=/var/lib/node-exporter/textfile
temporary_output=$(mktemp "$output_directory/storage.prom.XXXXXX")
trap 'rm -f "$temporary_output"' EXIT
host_name=$(jq -r '.host' "$configuration")

escape_label() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

while IFS= read -r managed_path; do
  escaped_path=$(printf '%s' "$managed_path" | escape_label)
  if [[ -e "$managed_path" ]]; then
    path_bytes=$(du --bytes --summarize --one-file-system -- "$managed_path" 2>/dev/null | awk '{print $1}' || printf 0)
    file_count=$(find "$managed_path" -xdev -type f -printf . 2>/dev/null | wc -c | tr -d ' ')
    printf 'bharath_managed_path_available{host="%s",path="%s"} 1\n' "$host_name" "$escaped_path"
    printf 'bharath_managed_path_bytes{host="%s",path="%s"} %s\n' "$host_name" "$escaped_path" "${path_bytes:-0}"
    printf 'bharath_managed_path_files{host="%s",path="%s"} %s\n' "$host_name" "$escaped_path" "$file_count"
  else
    printf 'bharath_managed_path_available{host="%s",path="%s"} 0\n' "$host_name" "$escaped_path"
  fi
done < <(jq -r '.storage_paths[]' "$configuration") > "$temporary_output"

chmod 0644 "$temporary_output"
mv "$temporary_output" "$output_directory/storage.prom"
trap - EXIT
COLLECTOR

cat > "$collector_service" <<'UNIT'
[Unit]
Description=Collect managed storage metrics
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/collect-node-storage-metrics
UNIT

cat > "$collector_timer" <<'UNIT'
[Unit]
Description=Collect managed storage metrics every fifteen minutes

[Timer]
OnBootSec=2m
OnUnitActiveSec=15m
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat > "$exporter_service" <<UNIT
[Unit]
Description=Prometheus Node Exporter
After=network-online.target node-exporter-metrics-firewall.service
Requires=node-exporter-metrics-firewall.service
Wants=network-online.target

[Service]
Type=simple
User=prometheus-node-exporter
Group=prometheus-node-exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${metrics_address}:9100 --collector.systemd --collector.textfile.directory=${textfile_directory}
Restart=always
RestartSec=5s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

cat > "$firewall_script" <<FIREWALL
#!/usr/bin/env bash

#==============================================================================
# NODE EXPORTER PRIVATE FIREWALL
#==============================================================================

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
iptables -N NODE_EXPORTER_METRICS 2>/dev/null || true
iptables -F NODE_EXPORTER_METRICS
iptables -A NODE_EXPORTER_METRICS -p tcp -s ${metrics_source_address}/32 -d ${metrics_address}/32 --dport 9100 -j ACCEPT
iptables -A NODE_EXPORTER_METRICS -p tcp -s ${metrics_address}/32 -d ${metrics_address}/32 --dport 9100 -j ACCEPT
iptables -A NODE_EXPORTER_METRICS -p tcp -d ${metrics_address}/32 --dport 9100 -j DROP
iptables -C INPUT -j NODE_EXPORTER_METRICS 2>/dev/null || iptables -I INPUT 1 -j NODE_EXPORTER_METRICS
FIREWALL

cat > "$firewall_service" <<'UNIT'
[Unit]
Description=Node Exporter metrics firewall
After=network-online.target
Before=node-exporter.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/node-exporter-metrics-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo -n id prometheus-node-exporter >/dev/null 2>&1 || \
  sudo -n useradd --system --no-create-home --shell /usr/sbin/nologin prometheus-node-exporter
sudo -n install -d -o root -g root -m 0755 "$configuration_directory"
printf '{"host":"%s","storage_paths":%s}\n' "$host_name" "$storage_paths_json" |
  sudo -n tee "$configuration_directory/node-monitoring.json" >/dev/null
sudo -n chmod 0644 "$configuration_directory/node-monitoring.json"
sudo -n install -d -o prometheus-node-exporter -g prometheus-node-exporter -m 0755 "$textfile_directory"
sudo -n install -o root -g root -m 0755 "$collector_script" /usr/local/sbin/collect-node-storage-metrics
sudo -n install -o root -g root -m 0755 "$firewall_script" /usr/local/sbin/node-exporter-metrics-firewall
sudo -n install -o root -g root -m 0644 "$collector_service" /etc/systemd/system/node-storage-metrics.service
sudo -n install -o root -g root -m 0644 "$collector_timer" /etc/systemd/system/node-storage-metrics.timer
sudo -n install -o root -g root -m 0644 "$exporter_service" /etc/systemd/system/node-exporter.service
sudo -n install -o root -g root -m 0644 "$firewall_service" /etc/systemd/system/node-exporter-metrics-firewall.service
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now node-exporter-metrics-firewall.service
sudo -n systemctl enable --now node-storage-metrics.timer
sudo -n systemctl start --no-block node-storage-metrics.service
sudo -n systemctl enable node-exporter.service
sudo -n systemctl restart node-exporter.service

verify_monitoring
printf 'node_monitoring_deploy=ready\n'