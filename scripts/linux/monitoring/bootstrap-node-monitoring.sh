#!/usr/bin/env bash

#==============================================================================
# VERSIONED NODE MONITORING BOOTSTRAP
#==============================================================================

set -euo pipefail

action="${1:-}"
automation_repository="${2:-}"
automation_ref="${3:-}"
shift 3 || true

if [[ ! "$action" =~ ^(validate|deploy|verify|status|report)$ ]] || \
  [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'A valid action, automation repository, and release are required.\n' >&2
  exit 1
fi

temporary_root=$(mktemp -d)
trap 'rm -rf "$temporary_root"' EXIT
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
  "https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz" \
  --output "$temporary_root/source.tar.gz"
mkdir "$temporary_root/source"
tar --extract --gzip --file "$temporary_root/source.tar.gz" \
  --directory "$temporary_root/source" --strip-components=1

bash "$temporary_root/source/scripts/linux/monitoring/manage-node-monitoring.sh" \
  "$action" "$@"