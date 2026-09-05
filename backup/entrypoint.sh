#!/usr/bin/env bash
# Validate backup settings, run one job, then keep the UTC scheduler running.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

BACKUP_CRON="${BACKUP_CRON:-0 */6 * * *}"

write_crontab() {
  printf '%s /usr/local/bin/backup.sh\n' "$BACKUP_CRON" > /etc/backup.crontab
}

main() {
  if [[ $# -gt 0 ]]; then
    exec "$@"
  fi

  require_cmd supercronic backup.sh
  validate_backup_env
  ensure_dirs
  write_runtime_env /etc/backup.env
  write_crontab

  if ! restic_repo_exists; then
    log "restic repository is not initialized at ${RESTIC_REPOSITORY}"
    log "Create the dedicated R2 bucket, then run: docker compose --profile backup-init run --rm -e RESTIC_INIT_CONFIRM=yes backup-init"
  else
    if ! /usr/local/bin/backup.sh; then
      log "startup backup failed; the scheduler will retry on ${BACKUP_CRON} UTC"
    fi
  fi

  log "starting UTC schedule: ${BACKUP_CRON}"
  exec supercronic -passthrough-logs /etc/backup.crontab
}

main "$@"
