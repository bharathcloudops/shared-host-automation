#!/usr/bin/env bash

#==============================================================================
# PRIVATE RESTIC BACKUPS TO OCI OBJECT STORAGE
#==============================================================================

set -euo pipefail

action="${1:-validate}"
restic_version=0.19.1
restic_sha256_arm64=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465
restic_sha256_amd64=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
configuration_directory=/etc/bharathcloudops/backup
textfile_directory=/var/lib/node-exporter/textfile
restic_binary=/usr/local/bin/restic
installed_script=/usr/local/sbin/bharath-backup
cache_directory=/var/cache/bharath-backup
unit_directory=/etc/systemd/system
retention_daily=7
retention_weekly=4
retention_monthly=3
maximum_age_seconds=93600
stage_directory=""
grafana_stopped=false

#==============================================================================
# FAILURE AND PRIVILEGE HANDLING
#==============================================================================

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-1}"
}

#==============================================================================
# INPUT LOADING AND VALIDATION
#==============================================================================

case "$action" in
  backup-source)
    source_name="${2:-}"
    host_name=""
    sources_json="[]"
    secret_json=""
    ;;
  validate|deploy|backup|check|verify|restore-test|status)
    host_name="${2:-}"
    sources_json="${3:-[]}"
    secret_json="${4:-}"
    ;;
  *)
    fail 'Unsupported backup action.' 10
    ;;
esac

if [[ -z "$host_name" && -f "$configuration_directory/host-name" ]]; then
  host_name=$(<"$configuration_directory/host-name")
  sources_json=$(<"$configuration_directory/sources.json")
fi

if [[ ! "$host_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || \
  ! jq -e 'type == "array" and length > 0 and all(.[]; . == "backstage" or . == "monitoring")' <<< "$sources_json" >/dev/null; then
  fail 'A valid host name and a list of backup sources are required.' 10
fi

if [[ "$action" == "backup-source" ]] && \
  ! jq -e --arg source "$source_name" 'index($source) != null' <<< "$sources_json" >/dev/null; then
  fail 'The backup source is not configured on this host.' 10
fi

if [[ "$action" == "validate" ]]; then
  printf 'backup_validation=ready\n'
  exit 0
fi

if (( EUID != 0 )); then
  exec sudo -n bash "$0" "$@"
fi

mapfile -t sources < <(jq -r '.[]' <<< "$sources_json")

#==============================================================================
# HOST PREREQUISITES
#==============================================================================

for required_command in curl date docker install jq sha256sum systemctl tar; do
  command -v "$required_command" >/dev/null 2>&1 || fail "Required command is unavailable: $required_command" 20
done

install -d -m 0700 "$cache_directory"

#==============================================================================
# RESTIC INSTALLATION WITH PINNED CHECKSUMS
#==============================================================================

install_restic() {
  local architecture
  local expected
  local temporary_root

  if [[ -x "$restic_binary" ]] && "$restic_binary" version | grep -Fq "restic $restic_version "; then
    return 0
  fi
  case "$(uname -m)" in
    aarch64) architecture=arm64; expected="$restic_sha256_arm64" ;;
    x86_64) architecture=amd64; expected="$restic_sha256_amd64" ;;
    *) fail 'Unsupported host architecture.' 20 ;;
  esac
  if ! command -v bzip2 >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install --yes --no-install-recommends bzip2 >/dev/null
  fi
  temporary_root=$(mktemp -d)
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "https://github.com/restic/restic/releases/download/v$restic_version/restic_${restic_version}_linux_${architecture}.bz2" \
    --output "$temporary_root/restic.bz2"
  if [[ "$(sha256sum "$temporary_root/restic.bz2" | awk '{print $1}')" != "$expected" ]]; then
    rm -rf "$temporary_root"
    fail 'The restic download failed checksum verification.' 30
  fi
  bzip2 --decompress --stdout "$temporary_root/restic.bz2" > "$temporary_root/restic"
  install -m 0755 "$temporary_root/restic" "$restic_binary"
  rm -rf "$temporary_root"
}

#==============================================================================
# ROOT-ONLY CREDENTIAL FILES
#==============================================================================

write_secret_file() {
  install -m 0600 /dev/null "$configuration_directory/$1"
  printf '%s' "$2" > "$configuration_directory/$1"
}

write_credentials() {
  if ! jq -e '
    type == "object" and
    (.RESTIC_REPOSITORY_BASE | strings | test("^s3:https://[A-Za-z0-9.-]+/[A-Za-z0-9._-]+$")) and
    (.AWS_ACCESS_KEY_ID | strings | length > 0) and
    (.AWS_SECRET_ACCESS_KEY | strings | length > 0) and
    (.AWS_DEFAULT_REGION | strings | test("^[a-z0-9-]+$")) and
    (.RESTIC_PASSWORD_BACKSTAGE | strings | length >= 24) and
    (.RESTIC_PASSWORD_MONITORING | strings | length >= 24)
  ' <<< "$secret_json" >/dev/null; then
    fail 'The backup credential bundle is missing or invalid.' 40
  fi
  install -d -m 0700 "$configuration_directory"
  write_secret_file repository-base "$(jq -r .RESTIC_REPOSITORY_BASE <<< "$secret_json")"
  write_secret_file aws-access-key-id "$(jq -r .AWS_ACCESS_KEY_ID <<< "$secret_json")"
  write_secret_file aws-secret-access-key "$(jq -r .AWS_SECRET_ACCESS_KEY <<< "$secret_json")"
  write_secret_file aws-region "$(jq -r .AWS_DEFAULT_REGION <<< "$secret_json")"
  write_secret_file password-backstage "$(jq -r .RESTIC_PASSWORD_BACKSTAGE <<< "$secret_json")"
  write_secret_file password-monitoring "$(jq -r .RESTIC_PASSWORD_MONITORING <<< "$secret_json")"
  printf '%s' "$host_name" > "$configuration_directory/host-name"
  printf '%s' "$sources_json" > "$configuration_directory/sources.json"
  chmod 0600 "$configuration_directory/host-name" "$configuration_directory/sources.json"
}

#==============================================================================
# RESTIC REPOSITORY ACCESS
#==============================================================================

restic_for() {
  local repository_name="$1"
  shift
  RESTIC_REPOSITORY="$(<"$configuration_directory/repository-base")/$repository_name" \
  RESTIC_PASSWORD_FILE="$configuration_directory/password-$repository_name" \
  AWS_ACCESS_KEY_ID="$(<"$configuration_directory/aws-access-key-id")" \
  AWS_SECRET_ACCESS_KEY="$(<"$configuration_directory/aws-secret-access-key")" \
  AWS_DEFAULT_REGION="$(<"$configuration_directory/aws-region")" \
  RESTIC_CACHE_DIR="$cache_directory" \
  "$restic_binary" "$@"
}

initialise_repository() {
  restic_for "$1" cat config >/dev/null 2>&1 || restic_for "$1" init >/dev/null
}

#==============================================================================
# BACKUP METRICS FOR THE NODE EXPORTER TEXTFILE COLLECTOR
#==============================================================================

previous_metric() {
  sed -n "s/^$2{source=\"$1\"} //p" "$textfile_directory/bharath_backup_$1.prom" 2>/dev/null | head -n 1
}

write_metrics() {
  local name="$1"
  local status="$2"
  local duration="$3"
  local size="$4"
  local repository_size="$5"
  local file="$textfile_directory/bharath_backup_$name.prom"
  local last_success

  if [[ "$status" == 1 ]]; then
    last_success=$(date +%s)
  else
    last_success=$(previous_metric "$name" bharath_backup_last_success_timestamp_seconds)
    size=$(previous_metric "$name" bharath_backup_last_size_bytes)
    repository_size=$(previous_metric "$name" bharath_backup_repository_size_bytes)
  fi
  install -d -m 0755 "$textfile_directory"
  {
    printf '# TYPE bharath_backup_last_success_timestamp_seconds gauge\n'
    printf 'bharath_backup_last_success_timestamp_seconds{source="%s"} %s\n' "$name" "${last_success:-0}"
    printf '# TYPE bharath_backup_last_status gauge\n'
    printf 'bharath_backup_last_status{source="%s"} %s\n' "$name" "$status"
    printf '# TYPE bharath_backup_last_duration_seconds gauge\n'
    printf 'bharath_backup_last_duration_seconds{source="%s"} %s\n' "$name" "$duration"
    printf '# TYPE bharath_backup_last_size_bytes gauge\n'
    printf 'bharath_backup_last_size_bytes{source="%s"} %s\n' "$name" "${size:-0}"
    printf '# TYPE bharath_backup_repository_size_bytes gauge\n'
    printf 'bharath_backup_repository_size_bytes{source="%s"} %s\n' "$name" "${repository_size:-0}"
  } > "$file.partial"
  chmod 0644 "$file.partial"
  mv "$file.partial" "$file"
}

#==============================================================================
# SOURCE SNAPSHOTS
#==============================================================================

monitoring_compose() {
  docker compose --project-directory /opt/monitoring-stack/current --file /opt/monitoring-stack/current/compose.yaml "$@"
}

backstage_compose() {
  docker compose --project-directory /opt/backstage-platform/current --file /opt/backstage-platform/current/compose.yaml "$@"
}

cleanup_backup() {
  if [[ "$grafana_stopped" == true ]]; then
    monitoring_compose start grafana >/dev/null 2>&1 || true
    grafana_stopped=false
  fi
  if [[ -n "$stage_directory" ]]; then
    rm -rf "$stage_directory"
    stage_directory=""
  fi
}

snapshot_backstage() {
  local dump="$stage_directory/backstage.sql"

  if ! backstage_compose exec -T postgres pg_dumpall --username backstage > "$dump"; then
    printf 'backup_failed=backstage stage=pg_dumpall\n' >&2
    return 1
  fi
  if [[ ! -s "$dump" ]] || ! tail -n 10 "$dump" | grep -Fq 'PostgreSQL database cluster dump complete'; then
    printf 'backup_failed=backstage stage=incomplete_dump\n' >&2
    return 1
  fi
  if ! snapshot_summary=$(restic_for backstage backup --json --stdin --stdin-filename backstage.sql \
    --tag source=backstage --tag env=prd --tag "host=$host_name" < "$dump" | jq -c 'select(.message_type == "summary")'); then
    printf 'backup_failed=backstage stage=restic_backup\n' >&2
    return 1
  fi
}

snapshot_monitoring() {
  local grafana_path
  local alertmanager_path

  if ! grafana_path=$(docker volume inspect monitoring-stack_grafana-data --format '{{ .Mountpoint }}') || \
    ! alertmanager_path=$(docker volume inspect monitoring-stack_alertmanager-data --format '{{ .Mountpoint }}'); then
    printf 'backup_failed=monitoring stage=volume_lookup\n' >&2
    return 1
  fi
  if ! monitoring_compose stop grafana >/dev/null; then
    printf 'backup_failed=monitoring stage=grafana_stop\n' >&2
    return 1
  fi
  grafana_stopped=true
  if ! snapshot_summary=$(restic_for monitoring backup --json "$grafana_path" "$alertmanager_path" \
    --tag source=monitoring --tag env=prd --tag "host=$host_name" | jq -c 'select(.message_type == "summary")'); then
    printf 'backup_failed=monitoring stage=restic_backup\n' >&2
    return 1
  fi
  if ! monitoring_compose start grafana >/dev/null; then
    printf 'backup_failed=monitoring stage=grafana_start\n' >&2
    return 1
  fi
  grafana_stopped=false
}

backup_source() {
  local name="$1"
  local started
  local size
  local repository_size

  started=$(date +%s)
  snapshot_summary=""
  install -d -m 0700 "$cache_directory"
  stage_directory=$(mktemp -d /var/backups/.bharath-backup.XXXXXX)
  trap cleanup_backup EXIT
  if ! initialise_repository "$name"; then
    printf 'backup_failed=%s stage=repository_init\n' "$name" >&2
  elif "snapshot_$name" && \
    restic_for "$name" forget --prune --tag "source=$name" \
      --keep-daily "$retention_daily" --keep-weekly "$retention_weekly" --keep-monthly "$retention_monthly" >/dev/null; then
    size=$(jq -r '.total_bytes_processed // 0' <<< "$snapshot_summary")
    repository_size=$(restic_for "$name" stats --mode raw-data --json | jq -r '.total_size // 0')
    cleanup_backup
    trap - EXIT
    write_metrics "$name" 1 "$(( $(date +%s) - started ))" "$size" "$repository_size"
    return 0
  fi
  cleanup_backup
  trap - EXIT
  write_metrics "$name" 0 "$(( $(date +%s) - started ))" 0 0
  return 1
}

#==============================================================================
# SYSTEMD UNITS AND TIMERS
#==============================================================================

backup_time_for() {
  case "$1" in
    backstage) printf '02:35:00' ;;
    monitoring) printf '02:50:00' ;;
  esac
}

install_units() {
  local name

  install -m 0755 "$0" "$installed_script"
  for name in "${sources[@]}"; do
    cat > "$unit_directory/bharath-backup-$name.service" <<UNIT
[Unit]
Description=Back up $name to OCI Object Storage
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$installed_script backup-source $name
TimeoutStartSec=1800
Nice=10
IOSchedulingClass=idle
UNIT
    cat > "$unit_directory/bharath-backup-$name.timer" <<UNIT
[Unit]
Description=Daily $name backup to OCI Object Storage

[Timer]
OnCalendar=*-*-* $(backup_time_for "$name")
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  done
  cat > "$unit_directory/bharath-backup-check.service" <<UNIT
[Unit]
Description=Check backup repository integrity
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$installed_script check
TimeoutStartSec=3600
Nice=10
IOSchedulingClass=idle
UNIT
  cat > "$unit_directory/bharath-backup-check.timer" <<UNIT
[Unit]
Description=Weekly backup repository integrity check

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  for name in "${sources[@]}"; do
    systemctl enable --now "bharath-backup-$name.timer" >/dev/null 2>&1
  done
  systemctl enable --now bharath-backup-check.timer >/dev/null 2>&1
}

#==============================================================================
# LIFECYCLE ACTIONS
#==============================================================================

run_all_backups() {
  local name
  local exit_code=0

  for name in "${sources[@]}"; do
    backup_source "$name" || exit_code=1
  done
  return "$exit_code"
}

verify_backups() {
  local name
  local latest
  local age

  for name in "${sources[@]}"; do
    latest=$(restic_for "$name" snapshots --latest 1 --json | jq -r '.[0].time // empty')
    [[ -n "$latest" ]] || fail "No snapshot exists for $name." 50
    age=$(( $(date +%s) - $(date -d "$latest" +%s) ))
    (( age < maximum_age_seconds )) || fail "The latest $name snapshot is older than 26 hours." 50
    systemctl is-active --quiet "bharath-backup-$name.timer" || fail "The $name backup timer is not active." 50
  done
}

restore_test() {
  local name
  local target
  local database

  for name in "${sources[@]}"; do
    target=$(mktemp -d /var/backups/.bharath-restore.XXXXXX)
    if ! restic_for "$name" restore latest --target "$target" >/dev/null; then
      rm -rf "$target"
      fail "The $name snapshot could not be restored." 60
    fi
    case "$name" in
      backstage)
        if [[ ! -s "$target/backstage.sql" ]] || ! grep -Fq 'PostgreSQL database cluster dump' "$target/backstage.sql"; then
          rm -rf "$target"
          fail 'The restored Backstage dump is invalid.' 60
        fi
        ;;
      monitoring)
        database=$(find "$target" -name grafana.db -size +0 | head -n 1)
        if [[ -z "$database" || "$(head -c 15 "$database")" != "SQLite format 3" ]]; then
          rm -rf "$target"
          fail 'The restored Grafana database is invalid.' 60
        fi
        ;;
    esac
    rm -rf "$target"
  done
}

case "$action" in
  deploy)
    install_restic
    write_credentials
    install_units
    run_all_backups || fail 'The initial backup run failed.' 70
    verify_backups
    printf 'backup_deploy=ready\n'
    ;;
  backup-source)
    install_restic
    backup_source "$source_name"
    ;;
  backup)
    run_all_backups || fail 'One or more backups failed.' 70
    printf 'backup_run=ready\n'
    ;;
  check)
    for name in "${sources[@]}"; do
      restic_for "$name" check --read-data-subset=5% >/dev/null || fail "The $name repository check failed." 80
    done
    printf 'backup_check=ready\n'
    ;;
  verify)
    verify_backups
    printf 'backup_verify=ready\n'
    ;;
  restore-test)
    restore_test
    printf 'backup_restore_test=ready\n'
    ;;
  status)
    systemctl list-timers 'bharath-backup-*' --no-pager 2>&1 | head -n 8
    printf 'backup_status=ready\n'
    ;;
esac
