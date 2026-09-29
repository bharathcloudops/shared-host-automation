#!/usr/bin/env bash

#==============================================================================
# PERSISTENT SECONDARY IPV4 CONFIGURATION
#==============================================================================

set -euo pipefail

#==============================================================================
# INPUT VALIDATION
#==============================================================================

secondary_private_ip="${1:-}"

if [[ ! "$secondary_private_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf 'A valid IPv4 secondary address is required.\n' >&2
  exit 1
fi

IFS=. read -r first_octet second_octet third_octet fourth_octet <<< "$secondary_private_ip"
for octet in "$first_octet" "$second_octet" "$third_octet" "$fourth_octet"; do
  if (( 10#$octet > 255 )); then
    printf 'A valid IPv4 secondary address is required.\n' >&2
    exit 1
  fi
done

#==============================================================================
# PRIVILEGE VALIDATION
#==============================================================================

if ! sudo -n true; then
  printf 'The automation user does not have non-interactive sudo access.\n' >&2
  exit 20
fi

#==============================================================================
# NETPLAN CONFIGURATION
#==============================================================================

sudo -n bash -s -- "$secondary_private_ip" <<'ROOT_SCRIPT'
set -euo pipefail

secondary_private_ip="$1"
interface_name=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
netplan_file="/etc/netplan/90-shared-secondary-ip.yaml"
backup_file="${netplan_file}.previous"

if [[ -z "$interface_name" ]]; then
  printf 'Unable to determine the default network interface.\n' >&2
  exit 1
fi

if [[ -f "$netplan_file" ]]; then
  cp --preserve=mode,ownership,timestamps "$netplan_file" "$backup_file"
fi

temporary_file=$(mktemp)
trap 'rm -f "$temporary_file"' EXIT

printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      addresses:\n        - %s/32\n' \
  "$interface_name" "$secondary_private_ip" > "$temporary_file"
chmod 600 "$temporary_file"
if [[ -f "$netplan_file" ]] && cmp --silent "$temporary_file" "$netplan_file" && \
  ip -4 address show dev "$interface_name" | grep -Fq "inet ${secondary_private_ip}/32"; then
  printf 'secondary_ip=%s\ninterface=%s\nconfiguration=unchanged\nconfiguration=ready\n' "$secondary_private_ip" "$interface_name"
  exit 0
fi

install -o root -g root -m 600 "$temporary_file" "$netplan_file"

if ! netplan generate; then
  if [[ -f "$backup_file" ]]; then
    mv "$backup_file" "$netplan_file"
  else
    rm -f "$netplan_file"
  fi
  netplan generate
  exit 1
fi

rm -f "$backup_file"
netplan apply
ip -4 address show dev "$interface_name" | grep -F "inet ${secondary_private_ip}/32"
printf 'secondary_ip=%s\ninterface=%s\nconfiguration=ready\n' "$secondary_private_ip" "$interface_name"
ROOT_SCRIPT