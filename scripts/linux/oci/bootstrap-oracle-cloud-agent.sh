#!/usr/bin/env bash

#==============================================================================
# ORACLE CLOUD AGENT BOOTSTRAP
#==============================================================================

set -euo pipefail

#==============================================================================
# BOOTSTRAP REQUIREMENTS
#==============================================================================

minimum_agent_version="${1:-1.61.0}"
agent_snap="oracle-cloud-agent"
sudoers_file="/etc/sudoers.d/101-oracle-cloud-agent-run-command"

for required_command in awk dpkg id mktemp snap sudo visudo; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$required_command" >&2
    exit 10
  fi
done

if ! sudo -n true; then
  printf 'The bootstrap user does not have non-interactive sudo access.\n' >&2
  exit 20
fi

if [[ ! "$minimum_agent_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Minimum agent version must use semantic version format.\n' >&2
  exit 30
fi

#==============================================================================
# AGENT INSTALLATION
#==============================================================================

if snap list "$agent_snap" >/dev/null 2>&1; then
  installed_agent_version=$(snap list "$agent_snap" | awk 'NR == 2 { print $2 }')
  normalized_agent_version=$(awk -F- '{ print $1 }' <<< "$installed_agent_version")
  if dpkg --compare-versions "$normalized_agent_version" ge "$minimum_agent_version" && \
    id ocarun >/dev/null 2>&1 && \
    [[ "$(sudo cat "$sudoers_file" 2>/dev/null || true)" == 'ocarun ALL=(ALL) NOPASSWD: ALL' ]]; then
    printf 'oracle_cloud_agent=unchanged\n'
    printf 'oracle_cloud_agent_version=%s\n' "$installed_agent_version"
    printf 'oracle_cloud_agent=ready\n'
    printf 'run_command_sudo=ready\n'
    exit 0
  fi
  if ! dpkg --compare-versions "$normalized_agent_version" ge "$minimum_agent_version"; then
    sudo snap refresh "$agent_snap" --channel=latest/stable
  fi
else
  sudo snap install "$agent_snap" --classic --channel=latest/stable
fi

installed_agent_version=$(snap list "$agent_snap" | awk 'NR == 2 { print $2 }')
normalized_agent_version=$(awk -F- '{ print $1 }' <<< "$installed_agent_version")

if ! dpkg --compare-versions "$normalized_agent_version" ge "$minimum_agent_version"; then
  printf 'Oracle Cloud Agent %s is older than required version %s.\n' "$installed_agent_version" "$minimum_agent_version" >&2
  exit 40
fi

sudo snap restart "$agent_snap"

for attempt in {1..30}; do
  if id ocarun >/dev/null 2>&1; then
    break
  fi

  if (( attempt == 30 )); then
    printf 'The ocarun service account was not created after the agent restart.\n' >&2
    exit 50
  fi

  sleep 2
done

#==============================================================================
# RUN COMMAND PRIVILEGE POLICY
#==============================================================================

temporary_sudoers=$(mktemp)
trap 'rm -f "$temporary_sudoers"' EXIT
printf 'ocarun ALL=(ALL) NOPASSWD: ALL\n' > "$temporary_sudoers"
visudo -cf "$temporary_sudoers"
sudo install -o root -g root -m 0440 "$temporary_sudoers" "$sudoers_file"
sudo visudo -cf "$sudoers_file"
sudo snap restart "$agent_snap"

#==============================================================================
# BOOTSTRAP VERIFICATION
#==============================================================================

snap services "$agent_snap"
printf 'oracle_cloud_agent_version=%s\n' "$installed_agent_version"
printf 'oracle_cloud_agent=ready\n'
printf 'run_command_sudo=ready\n'