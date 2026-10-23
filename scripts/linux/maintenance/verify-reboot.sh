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

#==============================================================================
# KUBERNETES WORKLOAD RECOVERY
#==============================================================================

unavailable_workloads() {
  sudo -n k3s kubectl get deployments,statefulsets --all-namespaces --output json |
    jq -r '[.items[] | select((.status.readyReplicas // 0) < (.spec.replicas // 1)) | "\(.kind | ascii_downcase)/\(.metadata.name) \(.metadata.namespace)"] | join(";")'
}

if [[ "$host_name" == "k3s" ]]; then
  restarted=false
  pending=""
  for (( attempt = 1; attempt <= 54; attempt++ )); do
    pending=$(unavailable_workloads 2>/dev/null) || pending="api-unavailable"
    [[ -z "$pending" ]] && break
    if [[ "$restarted" == false && "$pending" != "api-unavailable" ]] && (( attempt >= 18 )); then
      IFS=';' read -r -a workloads <<< "$pending"
      for workload in "${workloads[@]}"; do
        read -r target namespace <<< "$workload"
        sudo -n k3s kubectl rollout restart "$target" --namespace "$namespace" >/dev/null || true
      done
      restarted=true
      printf 'reboot_workloads_restarted=%s\n' "$pending"
    fi
    sleep 10
  done
  [[ -z "$pending" ]] || fail "Workloads still unavailable after recovery: $pending"
fi

printf 'reboot_kernel=%s\n' "$(uname -r)"
printf 'reboot_verify=ready\n'
