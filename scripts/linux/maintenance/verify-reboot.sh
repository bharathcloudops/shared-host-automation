#!/usr/bin/env bash

#==============================================================================
# POST-REBOOT HOST VERIFICATION
#==============================================================================

set -euo pipefail

host_name="${1:-}"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

case "$host_name" in
  platform) required_services=(docker) ;;
  k3s) required_services=(docker k3s) ;;
  web-01) required_services=(cloudflared) ;;
  *) fail 'A known host name is required.' ;;
esac

#==============================================================================
# REBOOT AND KERNEL STATE
#==============================================================================

uptime_seconds=$(cut -d. -f1 /proc/uptime)
newest_kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -n 1)
system_state=$(systemctl is-system-running 2>/dev/null || true)

(( uptime_seconds < 1800 )) || fail "The host has not rebooted recently (uptime ${uptime_seconds}s)."
[[ "$(uname -r)" == "$newest_kernel" ]] || fail "Running kernel $(uname -r) is not the newest installed kernel $newest_kernel."
[[ ! -f /var/run/reboot-required ]] || fail 'A reboot is still required after rebooting.'
[[ "$system_state" =~ ^(running|degraded)$ ]] || fail "System state is $system_state."

#==============================================================================
# REQUIRED SERVICES
#==============================================================================

for service in "${required_services[@]}"; do
  systemctl is-active --quiet "$service" || fail "Required service $service is not active."
done

printf 'reboot_kernel=%s\n' "$(uname -r)"
printf 'reboot_verify=ready\n'
