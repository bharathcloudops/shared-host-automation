<!--
==============================================================================
SHARED HOST AUTOMATION
==============================================================================
-->

# Shared Host Automation

Versioned Linux automation scripts executed on OCI instances through the reusable OCI Run Command workflow. Consumers pin this repository to an immutable release tag and pass only validated arguments; no inbound SSH connection is required.

<!--
==============================================================================
AVAILABLE SCRIPTS
==============================================================================
-->

## Scripts

| Script | Purpose |
|---|---|
| `scripts/linux/cloudflare/bootstrap-cloudflared.sh` | Download a validated immutable release and invoke the connector installer within OCI's payload limit |
| `scripts/linux/cloudflare/install-cloudflared.sh` | Install the pinned connector, expose private metrics, and configure systemd |
| `scripts/linux/network/preflight.sh` | Validate host networking prerequisites |
| `scripts/linux/network/configure-secondary-ip.sh` | Configure a secondary private IP on a host |
| `scripts/linux/network/verify-secondary-ip.sh` | Verify secondary private IP configuration |
| `scripts/linux/monitoring/bootstrap-node-monitoring.sh` | Download an immutable release within the OCI Run Command payload limit |
| `scripts/linux/monitoring/manage-node-monitoring.sh` | Deploy, verify, inspect, or report private host and storage telemetry |
| `scripts/linux/backup/bootstrap-backups.sh` | Download an immutable release within the OCI Run Command payload limit |
| `scripts/linux/backup/manage-backups.sh` | Deploy, run, verify, check, restore-test, or report encrypted restic backups |
| `scripts/linux/oci/bootstrap-oracle-cloud-agent.sh` | Install and validate required Oracle Cloud Agent plugins |

<!--
==============================================================================
ENCRYPTED HOST BACKUPS
==============================================================================
-->

## Encrypted Host Backups

`manage-backups.sh` backs up host-resident application state with `restic` into the Terraform-managed OCI Object Storage backup bucket. Restic encrypts and deduplicates on the host, so the bucket only holds encrypted, incremental data and stays inside the Always Free allowance.

### Repository layout

| Folder in the backup bucket | Owner | Content |
|---|---|---|
| `wordpress/` | Helm CronJob in `platform-helm-charts` | Database dump, uploads, extensions, and webroot for every site |
| `backstage/` | This script | Verified `pg_dumpall` dump of every Backstage database, including the per-plugin `backstage_plugin_*` databases that hold the real data |
| `monitoring/` | This script | Grafana and Alertmanager state, excluding Prometheus time series |

Each folder is an independent restic repository with its own password.

### Naming

| Item | Convention |
|---|---|
| Vault secret | `bharathcloudops-<env>-<region>-host-backup` |
| Systemd units | `bharath-backup-<source>.service` and `.timer`, plus `bharath-backup-check.service` and `.timer` |
| Installed command | `/usr/local/sbin/bharath-backup` |
| Credential files | Root-only files under `/etc/bharathcloudops/backup/` |
| Snapshot tags | `source=<source>`, `env=prd`, `host=<host>` |
| Metrics | `bharath_backup_*{source="<source>"}` in `/var/lib/node-exporter/textfile/bharath_backup_<source>.prom` |

### Actions

| Action | Behaviour |
|---|---|
| `validate` | Check inputs without touching the host |
| `deploy` | Install the pinned restic release, write credential files, install timers, run every backup once, and verify |
| `backup` | Run every configured backup now |
| `check` | Run a partial restic integrity check on every repository |
| `verify` | Require a snapshot newer than 26 hours and an active timer for every source |
| `restore-test` | Restore the latest snapshot of every source into a temporary folder and validate its content |
| `status` | List the backup timers |

### Schedule and retention

| Source | Time | Retention |
|---|---|---|
| `backstage` | 02:35 plus up to 5 minutes | 7 daily, 4 weekly, 3 monthly |
| `monitoring` | 02:50 plus up to 5 minutes | 7 daily, 4 weekly, 3 monthly |
| Integrity check | Sunday 04:00 | Partial read of 5 percent of data |

The monitoring backup stops Grafana for the few seconds needed to copy its SQLite database consistently and always restarts it, including on failure.

### Safety

- The Backstage dump is written to a private temporary folder and accepted only when its final ten lines contain the PostgreSQL cluster completion line, so a truncated dump is never stored. PostgreSQL 17 appends restrict lines after the completion line, which the ten-line window allows for.
- A failed source prints `backup_failed=<source> stage=<stage>` and records `bharath_backup_last_status 0`, so the failing stage is visible in the pipeline output.
- The restic download is checked against a pinned SHA-256 value before installation.
- Passwords and keys are never placed in environment files, units, or logs.

<!--
==============================================================================
PRIVATE HOST MONITORING
==============================================================================
-->

## Private Host Monitoring

Release `v0.3.8` installs Prometheus Node Exporter `v1.12.1` as a native systemd service on AMD64 or ARM64 Ubuntu. The exporter listens on the host's declared private address at TCP `9100`; a persistent iptables chain accepts only the monitoring source address and drops every other connection to that listener.

The compact bootstrap accepts the action, immutable repository/ref, metrics address, monitoring source address, host name, and a JSON array of managed storage paths. Supported actions are:

| Action | Mutation | Result |
|---|---|---|
| `validate` | No | Validates arguments and the release contract |
| `deploy` | Yes | Installs the pinned binary, firewall, collector, timer, and service |
| `verify` | No | Verifies the service, timer, metrics endpoint, and firewall rule |
| `status` | No | Reports exporter, timer, and failed-systemd-unit state |
| `report` | No | Reports filesystems, RAM, load, managed paths, twenty largest files per path, and Docker storage |

Node Exporter supplies CPU, RAM, swap, load, filesystem, inode, disk I/O, network, uptime, and systemd metrics. Deployment uses a bounded readiness retry while the exporter binds and starts the initial managed-path scan asynchronously so large filesystems cannot exhaust OCI Run Command output retrieval; `node-storage-metrics.timer` then runs every fifteen minutes and adds these low-cardinality metrics for each declared path:

| Metric | Meaning |
|---|---|
| `bharath_managed_path_available` | Whether the configured path exists |
| `bharath_managed_path_bytes` | Bytes stored below the configured path on its filesystem |
| `bharath_managed_path_files` | Number of files below the configured path |

Filenames are deliberately excluded from Prometheus labels. The `report` action records detailed filenames in the access-controlled OCI Run Command artifact retained by GitHub Actions for seven days.

```shell
bash scripts/linux/monitoring/bootstrap-node-monitoring.sh \
	deploy \
	bharathcloudops/shared-host-automation \
	v0.3.8 \
	10.10.10.125 \
	10.10.10.34 \
	web-01 \
	'["/etc/cloudflared","/var/log"]'
```

<!--
==============================================================================
CLOUDFLARE TUNNEL CONNECTOR
==============================================================================
-->

## Cloudflare Tunnel Connector

Release `v0.3.4` uses the compact bootstrap as the OCI Run Command entry point. It accepts the immutable repository, release, private metrics address, monitoring source address, and Vault-injected Cloudflare Tunnel token in that order.

```shell
bash scripts/linux/cloudflare/bootstrap-cloudflared.sh \
	bharathadigopula/shared-host-automation \
	v0.3.4 \
	10.10.10.125 \
	10.10.10.34 \
	"$TUNNEL_TOKEN"
```

The production workflow does not place the token in repository configuration. It retrieves the current token from OCI Vault, masks it in GitHub Actions, and appends it as a shell-quoted Run Command argument. The bootstrap downloads the matching tagged source and invokes `install-cloudflared.sh` with the metrics address, monitoring source address, and token.

<!--
==============================================================================
CONNECTOR REQUIREMENTS
==============================================================================
-->

### Requirements

- Debian package management with `dpkg`
- `curl`, `install`, `sha256sum`, `sudo`, and `systemctl`
- Non-interactive sudo access
- `amd64` or `arm64` architecture
- A private IPv4 address on which Prometheus can reach port `8880`
- A remotely managed Cloudflare Tunnel token containing at least 100 supported characters

<!--
==============================================================================
CONNECTOR BEHAVIOUR
==============================================================================
-->

### Behaviour

The script:

1. Selects the package and pinned SHA-256 checksum for the host architecture.
2. Downloads and installs `cloudflared 2026.8.2` when the installed version differs.
3. Writes the token to root-owned `/etc/cloudflared/tunnel.token` with mode `0600`.
4. Starts cloudflared with `--token-file` so the credential is not present in process arguments.
5. Exposes connector metrics only on `<private-address>:8880`.
6. Installs a systemd-managed iptables chain that allows only the configured monitoring source address to reach TCP port `8880`.
7. Installs `/etc/systemd/system/cloudflared.service` with automatic restart enabled.
8. Enables and restarts the service, then confirms both service stability and metrics availability.

Successful output includes:

```text
cloudflared_version=2026.8.2
cloudflared_metrics=ready
cloudflare_tunnel=ready
```

The systemd service uses `--no-autoupdate`; upgrading the connector requires a reviewed script change and a new immutable repository release.

<!--
==============================================================================
REPOSITORY VALIDATION
==============================================================================
-->

## Validation

GitHub Actions validates shell syntax, OCI payload sizes, immutable download checksums, secret handling, firewall rules, and both management contracts without mutating hosts.

```shell
SEARCH_PATH=scripts bash ../github-pipeline-templates/scripts/validation/validate-shell.sh
bash scripts/validate.sh
```

Each rendered bootstrap and its arguments must remain within OCI Run Command's 4,096-byte inline command limit. The repository validator uses the maximum supported 255-character Cloudflare secret and asserts that both metrics listeners use source-restricted firewall rules.

<!--
==============================================================================
RELEASE POLICY
==============================================================================
-->

## Release Policy

- Consumers reference semantic version tags, never `main`.
- Tags are immutable and must not be moved or deleted.
- Script changes require shell validation before release.
- Secrets must be injected at runtime and must not be committed, printed, or included in workflow artifacts.
