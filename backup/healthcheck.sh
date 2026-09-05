#!/usr/bin/env bash
# Report whether the latest backup is still fresh enough.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

running_status=0
backup_is_running || running_status=$?
if [[ "$running_status" -eq 0 ]]; then
  exit 0
fi
if [[ "$running_status" -eq 2 ]]; then
  log "backup exceeded BACKUP_MAX_RUNTIME_SECONDS=${BACKUP_MAX_RUNTIME_SECONDS}"
  exit 1
fi

last_success="$(read_state last-success || true)"
if [[ -z "$last_success" ]]; then
  exit 1
fi

now="$(now_epoch)"
if (( now - last_success <= BACKUP_FRESHNESS_SECONDS )); then
  exit 0
fi

exit 1
