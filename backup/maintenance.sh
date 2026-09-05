#!/usr/bin/env bash
# Apply restic retention and the weekly data-sample check.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

should_run_weekly() {
  local last last_day today weekday

  last="$(read_state last-maintenance || true)"
  today="$(utc_date)"
  weekday="$(utc_weekday)"

  if [[ "$weekday" == "$MAINTENANCE_WEEKDAY" && "$last" != "$today" ]]; then
    return 0
  fi
  if [[ -z "$last" ]]; then
    return 0
  fi

  last_day="$(date -u -d "${last} 00:00:00" +%s 2>/dev/null || true)"
  if [[ -n "$last_day" ]]; then
    if (( $(now_epoch) - last_day >= 8 * 24 * 60 * 60 )); then
      return 0
    fi
  fi
  return 1
}

apply_retention() {
  log "applying restic retention: keep-within=${RESTIC_KEEP_WITHIN} weekly=${RESTIC_KEEP_WEEKLY} monthly=${RESTIC_KEEP_MONTHLY}"
  restic_cmd forget \
    --keep-within "$RESTIC_KEEP_WITHIN" \
    --keep-weekly "$RESTIC_KEEP_WEEKLY" \
    --keep-monthly "$RESTIC_KEEP_MONTHLY" \
    --prune
}

check_data_sample() {
  log "running weekly restic data sample check (${RESTIC_CHECK_READ_DATA_SUBSET})"
  restic_cmd check --read-data-subset="$RESTIC_CHECK_READ_DATA_SUBSET"
}

main() {
  require_cmd restic
  validate_backup_env

  if ! restic_repo_exists; then
    die "restic repository does not exist; refusing maintenance"
  fi

  if ! should_run_weekly; then
    log "weekly maintenance not due"
    return 0
  fi

  apply_retention
  check_data_sample
  write_state last-maintenance "$(utc_date)"
  log "weekly maintenance completed"
}

main "$@"
