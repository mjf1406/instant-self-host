#!/usr/bin/env bash
# Create one Instant dashboard backup per app, then upload the result to R2.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

INSTANT_SERVER_URL="${INSTANT_SERVER_URL:-http://server:8888}"
INSTANT_SERVER_URL="${INSTANT_SERVER_URL%/}"
APP_BACKUP_JOB_TIMEOUT_SECONDS="${APP_BACKUP_JOB_TIMEOUT_SECONDS:-1800}"
APP_BACKUP_POLL_SECONDS="${APP_BACKUP_POLL_SECONDS:-5}"

HTTP_STATUS=""
HTTP_BODY=""

usage() {
  cat <<'EOF'
Create one Instant dashboard backup for each app, wait for the jobs to
finish, then run backup.sh so the new snapshots go to R2.

Usage:
  app-backup.sh

Requires INSTANT_PLATFORM_TOKEN. Leave APP_BACKUP_APP_IDS empty to include
every non-deleted app, or set it to a comma-separated list of app IDs.
EOF
}

json_string_field() {
  local key="$1"
  local json="${2:-$HTTP_BODY}"

  printf '%s' "$json" \
    | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    | head -1
}

http_json() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local tmp

  tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    HTTP_STATUS="$(
      curl -sS -o "$tmp" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer ${INSTANT_PLATFORM_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data "$body" \
        "${INSTANT_SERVER_URL}${path}"
    )" || HTTP_STATUS="000"
  else
    HTTP_STATUS="$(
      curl -sS -o "$tmp" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer ${INSTANT_PLATFORM_TOKEN}" \
        -H "Accept: application/json" \
        "${INSTANT_SERVER_URL}${path}"
    )" || HTTP_STATUS="000"
  fi
  HTTP_BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

list_app_ids() {
  local raw

  if [[ -n "${APP_BACKUP_APP_IDS:-}" ]]; then
    printf '%s' "$APP_BACKUP_APP_IDS" \
      | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'
    return
  fi

  export_pg_password
  raw="$(
    psql \
      -h "$POSTGRES_HOST" \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      -tAc "SELECT id FROM apps WHERE deletion_marked_at IS NULL ORDER BY id"
  )"
  printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d'
}

start_or_attach_job() {
  local app_id="$1"
  local job_id

  http_json POST "/dash/apps/${app_id}/backups" '{"description":"Scheduled snapshot"}'
  if [[ "$HTTP_STATUS" == "429" ]]; then
    log "rate limited for app ${app_id}; skipping"
    return 1
  fi
  if [[ "$HTTP_STATUS" == "200" ]]; then
    job_id="$(json_string_field id)"
    if [[ -z "$job_id" ]]; then
      log "app ${app_id} returned no job id: ${HTTP_BODY}"
      return 1
    fi
    printf '%s' "$job_id"
    return 0
  fi

  http_json GET "/dash/apps/${app_id}/backup-jobs"
  job_id="$(json_string_field id)"
  if [[ -n "$job_id" ]]; then
    log "app ${app_id} already has job ${job_id}"
    printf '%s' "$job_id"
    return 0
  fi

  log "could not start backup for app ${app_id}: HTTP ${HTTP_STATUS} ${HTTP_BODY}"
  return 1
}

poll_job() {
  local app_id="$1"
  local job_id="$2"
  local started now status

  started="$(now_epoch)"
  while true; do
    http_json GET "/dash/apps/${app_id}/backup-jobs/${job_id}"
    if [[ "$HTTP_STATUS" != "200" ]]; then
      log "app ${app_id} job ${job_id} poll failed: HTTP ${HTTP_STATUS} ${HTTP_BODY}"
      return 1
    fi

    status="$(json_string_field job_status)"
    case "$status" in
      completed)
        log "app ${app_id} backup ${job_id} completed"
        return 0
        ;;
      errored|cancelled)
        log "app ${app_id} backup ${job_id} ended with status ${status}"
        return 1
        ;;
    esac

    now="$(now_epoch)"
    if (( now - started > APP_BACKUP_JOB_TIMEOUT_SECONDS )); then
      log "app ${app_id} backup ${job_id} timed out after ${APP_BACKUP_JOB_TIMEOUT_SECONDS}s"
      return 1
    fi
    sleep "$APP_BACKUP_POLL_SECONDS"
  done
}

backup_app() {
  local app_id="$1"
  local job_id

  log "starting dashboard backup for app ${app_id}"
  if ! job_id="$(start_or_attach_job "$app_id")"; then
    return 1
  fi
  log "waiting for app ${app_id} job ${job_id}"
  poll_job "$app_id" "$job_id"
}

main() {
  local app_id failed=0 count=0

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_env INSTANT_PLATFORM_TOKEN
  require_cmd curl psql
  require_env POSTGRES_PASSWORD
  validate_backup_env
  ensure_dirs

  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    count=$((count + 1))
    if ! backup_app "$app_id"; then
      failed=$((failed + 1))
    fi
  done < <(list_app_ids)

  if [[ "$count" -eq 0 ]]; then
    log "no apps to back up"
  else
    log "finished dashboard backups: ${count} apps, ${failed} failed"
  fi

  /usr/local/bin/backup.sh
  if [[ "$failed" -gt 0 ]]; then
    die "${failed} dashboard backup(s) failed before the off-site upload"
  fi
}

main "$@"
