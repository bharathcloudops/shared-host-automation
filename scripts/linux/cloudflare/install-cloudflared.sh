#!/usr/bin/env bash

#==============================================================================
# CLOUDFLARE TUNNEL CONNECTOR
#==============================================================================

set -euo pipefail

metrics_address="${1:-}"
metrics_source_address="${2:-}"
tunnel_token="${3:-}"
cloudflared_version="2026.8.2"

#==============================================================================
# METRICS NETWORK VALIDATION
#==============================================================================

for address in "$metrics_address" "$metrics_source_address"; do
  if [[ ! "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf 'A valid private metrics IPv4 address is required.\n' >&2
    exit 10
  fi

  IFS=. read -r first_octet second_octet third_octet fourth_octet <<< "$address"
  for octet in "$first_octet" "$second_octet" "$third_octet" "$fourth_octet"; do
    if (( 10#$octet > 255 )); then
      printf 'Invalid metrics IPv4 address: %s\n' "$address" >&2
      exit 10
    fi
  done
done

if [[ ! "$tunnel_token" =~ ^[A-Za-z0-9._=-]{100,}$ ]]; then
  printf 'A valid Cloudflare tunnel token is required.\n' >&2
  exit 10
fi

for required_command in curl dpkg install iptables sha256sum sudo systemctl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$required_command" >&2
    exit 20
  fi
done

if ! sudo -n true; then
  printf 'The automation user does not have non-interactive sudo access.\n' >&2
  exit 30
fi

deployment_fingerprint=$(printf '%s\0' "$cloudflared_version" "$metrics_address" "$metrics_source_address" "$tunnel_token" | sha256sum | awk '{print $1}')
fingerprint_file=/var/lib/bharathcloudops/cloudflared.sha256
installed_version=$(cloudflared --version 2>/dev/null | awk '{ print $3 }' || true)
if [[ "$installed_version" == "$cloudflared_version" ]] && \
  [[ "$(sudo -n cat "$fingerprint_file" 2>/dev/null || true)" == "$deployment_fingerprint" ]] && \
  sudo -n systemctl is-active --quiet cloudflared.service && \
  curl --fail --silent --show-error "http://${metrics_address}:8880/metrics" >/dev/null && \
  sudo -n iptables -C CLOUDFLARED_METRICS -p tcp -s "${metrics_source_address}/32" -d "${metrics_address}/32" --dport 8880 -j ACCEPT; then
  printf 'cloudflare_tunnel=unchanged\n'
  printf 'cloudflared_metrics=ready\n'
  printf 'cloudflare_tunnel=ready\n'
  exit 0
fi

#==============================================================================
# PRIVATE METRICS FIREWALL FILES
#==============================================================================

firewall_script=$(mktemp)
firewall_unit=$(mktemp)
trap 'rm -f "$firewall_script" "$firewall_unit"' EXIT

cat > "$firewall_script" <<FIREWALL
#!/usr/bin/env bash

#==============================================================================
# CLOUDFLARED METRICS FIREWALL
#==============================================================================

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

iptables -N CLOUDFLARED_METRICS 2>/dev/null || true
iptables -F CLOUDFLARED_METRICS
iptables -A CLOUDFLARED_METRICS -p tcp -s ${metrics_source_address}/32 -d ${metrics_address}/32 --dport 8880 -j ACCEPT
iptables -C INPUT -j CLOUDFLARED_METRICS 2>/dev/null || iptables -I INPUT 1 -j CLOUDFLARED_METRICS
FIREWALL

cat > "$firewall_unit" <<UNIT
[Unit]
Description=Cloudflared metrics firewall
After=network-online.target
Before=cloudflared.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudflared-metrics-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

chmod 755 "$firewall_script"
sudo -n install -o root -g root -m 755 "$firewall_script" /usr/local/sbin/cloudflared-metrics-firewall
sudo -n install -o root -g root -m 644 "$firewall_unit" /etc/systemd/system/cloudflared-metrics-firewall.service

#==============================================================================
# PINNED PACKAGE INSTALLATION
#==============================================================================

case "$(dpkg --print-architecture)" in
  amd64)
    package_architecture="amd64"
    expected_sha256="c805c7c8102190c04dfc16e3b4cc4acc9007d5b19b3afbcd608ea6fed7645a43"
    ;;
  arm64)
    package_architecture="arm64"
    expected_sha256="096739c69f62cace40b144f0e6c81e61333f3d320ce07a265c7b17b5e925731c"
    ;;
  *)
    printf 'Unsupported package architecture.\n' >&2
    exit 40
    ;;
esac

installed_version=$(cloudflared --version 2>/dev/null | awk '{ print $3 }' || true)
if [[ "$installed_version" != "$cloudflared_version" ]]; then
  package_file=$(mktemp --suffix=.deb)
  trap 'rm -f "$package_file"' EXIT
  package_url="https://github.com/cloudflare/cloudflared/releases/download/${cloudflared_version}/cloudflared-linux-${package_architecture}.deb"
  curl --fail --location --silent --show-error "$package_url" --output "$package_file"
  printf '%s  %s\n' "$expected_sha256" "$package_file" | sha256sum --check --status
  sudo -n dpkg --install "$package_file"
  rm -f "$package_file"
  trap - EXIT
fi

installed_version=$(cloudflared --version | awk '{ print $3 }')
if [[ "$installed_version" != "$cloudflared_version" ]]; then
  printf 'Installed cloudflared version %s does not match required version %s.\n' "$installed_version" "$cloudflared_version" >&2
  exit 45
fi

#==============================================================================
# SYSTEMD SERVICE
#==============================================================================

token_file=$(mktemp)
unit_file=$(mktemp)
trap 'rm -f "$firewall_script" "$firewall_unit" "$token_file" "$unit_file"' EXIT

printf '%s\n' "$tunnel_token" > "$token_file"
chmod 600 "$token_file"

cat > "$unit_file" <<UNIT
[Unit]
Description=Cloudflare Tunnel
After=network-online.target cloudflared-metrics-firewall.service
Requires=cloudflared-metrics-firewall.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --metrics ${metrics_address}:8880 run --token-file /etc/cloudflared/tunnel.token
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

sudo -n install -d -o root -g root -m 700 /etc/cloudflared
sudo -n install -o root -g root -m 600 "$token_file" /etc/cloudflared/tunnel.token
sudo -n install -o root -g root -m 644 "$unit_file" /etc/systemd/system/cloudflared.service
sudo -n rm -f /etc/cloudflared/tunnel.env
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now cloudflared-metrics-firewall.service
sudo -n systemctl enable cloudflared.service
sudo -n systemctl restart cloudflared.service

for attempt in {1..30}; do
  if sudo -n systemctl is-active --quiet cloudflared.service; then
    sleep 5
    if sudo -n systemctl is-active --quiet cloudflared.service; then
      break
    fi
  fi

  if (( attempt == 30 )); then
    sudo -n systemctl status cloudflared.service --no-pager >&2
    exit 50
  fi

  sleep 2
done

curl --fail --silent --show-error "http://${metrics_address}:8880/metrics" >/dev/null
sudo -n iptables -C CLOUDFLARED_METRICS -p tcp -s "${metrics_source_address}/32" -d "${metrics_address}/32" --dport 8880 -j ACCEPT
printf 'cloudflared_firewall=managed\n'

#==============================================================================
# PRIVATE METRICS NETWORK STATUS
#==============================================================================

printf 'cloudflared_interface=%s\n' "$(ip -o -4 address show | awk -v address="$metrics_address" '$4 == address "/32" { print $2 ":" $4 }')"
printf 'cloudflared_listener=%s\n' "$(ss -H -lnt "sport = :8880" | awk 'NR == 1 { print $4 }')"
printf 'cloudflared_return_route=%s\n' "$(ip -4 route get "$metrics_source_address" | head -n 1)"
if command -v iptables >/dev/null 2>&1; then
  printf 'cloudflared_iptables_policy=%s\n' "$(sudo -n iptables -S INPUT | head -n 1)"
  printf 'cloudflared_iptables_rejects=%s\n' "$(sudo -n iptables -S INPUT | grep -Ec -- '-j (DROP|REJECT)' || true)"
else
  printf 'cloudflared_iptables_policy=unavailable\ncloudflared_iptables_rejects=unavailable\n'
fi
if command -v nft >/dev/null 2>&1; then
  printf 'cloudflared_nft_rejects=%s\n' "$(sudo -n nft list ruleset 2>/dev/null | grep -Ec '(^|[[:space:]])(drop|reject)([[:space:]]|$)' || true)"
else
  printf 'cloudflared_nft_rejects=unavailable\n'
fi
printf 'cloudflared_version=%s\n' "$installed_version"
sudo -n install -d -o root -g root -m 700 /var/lib/bharathcloudops
printf '%s\n' "$deployment_fingerprint" | sudo -n tee "$fingerprint_file" >/dev/null
sudo -n chmod 0600 "$fingerprint_file"
printf 'cloudflared_metrics=ready\n'
printf 'cloudflare_tunnel=ready\n'