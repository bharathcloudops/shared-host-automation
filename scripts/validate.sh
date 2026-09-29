#!/usr/bin/env bash

#==============================================================================
# SHARED HOST AUTOMATION VALIDATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REPOSITORY PATHS
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap_script="$repository_root/scripts/linux/cloudflare/bootstrap-cloudflared.sh"
installer_script="$repository_root/scripts/linux/cloudflare/install-cloudflared.sh"

#==============================================================================
# REQUIRED FILES
#==============================================================================

for required_file in "$bootstrap_script" "$installer_script"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'Missing required file: %s\n' "$required_file" >&2
    exit 1
  fi
done

#==============================================================================
# OCI BOOTSTRAP PAYLOAD VALIDATION
#==============================================================================

sample_arguments=$(jq -cn '[
  "bharathadigopula/shared-host-automation",
  "v0.3.4",
  "10.10.10.125",
  "10.10.10.34",
  ("A" * 255)
]')
argument_line=$(jq -r '[.[] | @sh] | "set -- " + join(" ")' <<< "$sample_arguments")
rendered_size=$(printf '%s\n%s' "$argument_line" "$(cat "$bootstrap_script")" | wc -c | tr -d ' ')
if (( rendered_size > 4096 )); then
  printf 'Rendered cloudflared bootstrap exceeds the OCI 4096-byte inline limit.\n' >&2
  exit 1
fi

#==============================================================================
# CLOUDFLARED SECRET HANDLING VALIDATION
#==============================================================================

if ! grep -Fq -- '--token-file /etc/cloudflared/tunnel.token' "$installer_script" || \
  grep -Fq -- "--token \${TUNNEL_TOKEN}" "$installer_script" || \
  ! grep -Fq 'cloudflared.sha256' "$installer_script" || \
  ! grep -Fq "printf 'cloudflare_tunnel=unchanged" "$installer_script"; then
  printf 'Cloudflared must use its root-only token file.\n' >&2
  exit 1
fi

if ! grep -Fq 'cmp --silent "$temporary_file" "$netplan_file"' "$repository_root/scripts/linux/network/configure-secondary-ip.sh" || \
  ! grep -Fq 'configuration=unchanged' "$repository_root/scripts/linux/network/configure-secondary-ip.sh" || \
  ! grep -Fq 'oracle_cloud_agent=unchanged' "$repository_root/scripts/linux/oci/bootstrap-oracle-cloud-agent.sh"; then
  printf 'Host networking and OCI agent configuration must skip unchanged healthy state.\n' >&2
  exit 1
fi

#==============================================================================
# PRIVATE METRICS FIREWALL VALIDATION
#==============================================================================

if ! grep -Fq 'iptables -A CLOUDFLARED_METRICS' "$installer_script" || \
  ! grep -Fq 'cloudflared-metrics-firewall.service' "$installer_script"; then
  printf 'Cloudflared metrics must use a source-restricted firewall rule.\n' >&2
  exit 1
fi

#==============================================================================
# VALIDATION RESULT
#==============================================================================

printf 'host_automation_validation=ready\n'
