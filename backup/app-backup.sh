#!/usr/bin/env bash
# Create one Instant dashboard backup per app, then upload the result to R2.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi
. "$LIB_SH"

INSTANT_SERVER_URL="${INSTANT_SERVER_URL:-http://server:8888}"
INSTANT_SERVER_URL="${INSTANT_SERVER_URL%/}"
APP_BACKUP_JOB_TIMEOUT_SECONDS="${APP_BACKUP_JOB_TIMEOUT_SECONDS:-1800}"
APP_BACKUP_POLL_SECONDS="${APP_BACKUP_POLL_SECONDS:-5}"
APP_BACKUP_RATE_LIMIT_MAX_RETRIES="${APP_BACKUP_RATE_LIMIT_MAX_RETRIES:-5}"
APP_BACKUP_RATE_LIMIT_FALLBACK_SECONDS="${APP_BACKUP_RATE_LIMIT_FALLBACK_SECONDS:-300}"

HTTP_STATUS=""
HTTP_BODY=""
HTTP_RETRY_AFTER=""

usage() {
  cat <<'EOF'
Create one Instant dashboard backup for each app, wait for the jobs to
finish, then run backup.sh so the new snapshots go to R2.

Usage:
  app-backup.sh

Requires INSTANT_PLATFORM_TOKEN. Leave APP_BACKUP_APP_IDS empty to discover
every app visible to that account, or set it to a comma-separated list of app
IDs.
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
  local headers tmp

  tmp="$(mktemp)"
  headers="$(mktemp)"
  if [[ -n "$body" ]]; then
    HTTP_STATUS="$(
      curl -sS -D "$headers" -o "$tmp" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer ${INSTANT_PLATFORM_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data "$body" \
        "${INSTANT_SERVER_URL}${path}"
    )" || HTTP_STATUS="000"
  else
    HTTP_STATUS="$(
      curl -sS -D "$headers" -o "$tmp" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer ${INSTANT_PLATFORM_TOKEN}" \
        -H "Accept: application/json" \
        "${INSTANT_SERVER_URL}${path}"
    )" || HTTP_STATUS="000"
  fi
  HTTP_BODY="$(cat "$tmp")"
  HTTP_RETRY_AFTER="$(
    sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$headers" \
      | tr -d '\r' \
      | tail -1
  )"
  rm -f "$tmp" "$headers"
}

list_app_ids() {
  local dash_body org_body org_id

  if [[ -n "${APP_BACKUP_APP_IDS:-}" ]]; then
    printf '%s' "$APP_BACKUP_APP_IDS" \
      | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'
    return
  fi

  http_json GET "/dash"
  if [[ "$HTTP_STATUS" != "200" ]]; then
    log "could not discover dashboard apps: HTTP ${HTTP_STATUS} ${HTTP_BODY}" >&2
    return 1
  fi
  dash_body="$HTTP_BODY"

  {
    printf '%s' "$dash_body" | jq -r '.apps[]?.id'

    while IFS= read -r org_id; do
      [[ -n "$org_id" ]] || continue
      http_json GET "/dash/orgs/${org_id}"
      if [[ "$HTTP_STATUS" != "200" ]]; then
        log "could not discover apps for organization ${org_id}: HTTP ${HTTP_STATUS} ${HTTP_BODY}" >&2
        return 1
      fi
      org_body="$HTTP_BODY"
      printf '%s' "$org_body" | jq -r '.apps[]?.id'
    done < <(printf '%s' "$dash_body" | jq -r '.orgs[]?.id')
  } | sed '/^[[:space:]]*$/d' | sort -u
}

start_or_attach_job() {
  local app_id="$1"
  local attempt=0 job_id post_body post_status retry_after

  while true; do
    http_json POST "/dash/apps/${app_id}/backups" '{"description":"Scheduled snapshot"}'
    if [[ "$HTTP_STATUS" != "429" ]]; then
      break
    fi

    if (( attempt >= APP_BACKUP_RATE_LIMIT_MAX_RETRIES )); then
      log "rate limited for app ${app_id} after ${attempt} retries: ${HTTP_BODY}" >&2
      return 1
    fi

    retry_after="$HTTP_RETRY_AFTER"
    if [[ ! "$retry_after" =~ ^[1-9][0-9]*$ ]]; then
      retry_after="$APP_BACKUP_RATE_LIMIT_FALLBACK_SECONDS"
    fi
    attempt=$((attempt + 1))
    log "rate limited for app ${app_id}; retrying in ${retry_after}s (${attempt}/${APP_BACKUP_RATE_LIMIT_MAX_RETRIES})" >&2
    sleep "$retry_after"
  done

  if [[ "$HTTP_STATUS" == "200" ]]; then
    job_id="$(json_string_field id)"
    if [[ -z "$job_id" ]]; then
      log "app ${app_id} returned no job id: ${HTTP_BODY}" >&2
      return 1
    fi
    printf '%s' "$job_id"
    return 0
  fi

  post_status="$HTTP_STATUS"
  post_body="$HTTP_BODY"
  http_json GET "/dash/apps/${app_id}/backup-jobs"
  job_id="$(json_string_field id)"
  if [[ -n "$job_id" ]]; then
    log "app ${app_id} already has job ${job_id}" >&2
    printf '%s' "$job_id"
    return 0
  fi

  log "could not start backup for app ${app_id}: HTTP ${post_status} ${post_body}" >&2
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
  local app_id app_ids failed=0 count=0

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_env INSTANT_PLATFORM_TOKEN
  require_cmd curl jq
  require_env POSTGRES_PASSWORD
  validate_backup_env
  ensure_dirs

  if ! app_ids="$(list_app_ids)"; then
    die "dashboard app discovery failed"
  fi

  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    count=$((count + 1))
    if ! backup_app "$app_id"; then
      failed=$((failed + 1))
    fi
  done <<<"$app_ids"

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
