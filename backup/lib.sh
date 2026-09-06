#!/usr/bin/env bash
# Shared helpers for InstantDB backup and restore tooling.

set -euo pipefail

STATE_DIR="${STATE_DIR:-/staging/state}"
DATA_DIR="${DATA_DIR:-/staging/data}"
RESTORE_DIR="${RESTORE_DIR:-/staging/restore}"
SERVER_CONFIG_DIR="${SERVER_CONFIG_DIR:-/app/resources/config}"
lock_file() {
  printf '%s' "${LOCK_FILE:-${STATE_DIR}/backup.lock}"
}

POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-instant}"
POSTGRES_DB="${POSTGRES_DB:-instant}"
S3_ENDPOINT="${S3_ENDPOINT:-http://minio:9000}"
S3_BUCKET="${S3_BUCKET:-instant-bucket}"
S3_APP_BACKUPS_BUCKET="${S3_APP_BACKUPS_BUCKET:-instant-app-backups}"
INSTANT_SERVER_URL="${INSTANT_SERVER_URL:-http://server:8888}"
APP_BACKUP_CRON="${APP_BACKUP_CRON:-0 2 * * *}"
APP_BACKUP_JOB_TIMEOUT_SECONDS="${APP_BACKUP_JOB_TIMEOUT_SECONDS:-1800}"
APP_BACKUP_POLL_SECONDS="${APP_BACKUP_POLL_SECONDS:-5}"
R2_REGION="${R2_REGION:-auto}"
R2_BUCKET="${R2_BUCKET:-instant-self-host-backups}"
BACKUP_FRESHNESS_SECONDS="${BACKUP_FRESHNESS_SECONDS:-28800}"
BACKUP_MAX_RUNTIME_SECONDS="${BACKUP_MAX_RUNTIME_SECONDS:-7200}"
BACKUP_MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-1024}"
RESTIC_KEEP_WITHIN="${RESTIC_KEEP_WITHIN:-7d}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-5}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
RESTIC_CHECK_READ_DATA_SUBSET="${RESTIC_CHECK_READ_DATA_SUBSET:-5%}"
MAINTENANCE_WEEKDAY="${MAINTENANCE_WEEKDAY:-0}"
TZ="${TZ:-UTC}"

export TZ
export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/mc-config}"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local name
  for name in "$@"; do
    command -v "$name" >/dev/null 2>&1 || die "required command not found: $name"
  done
}

env_present() {
  local name="$1"
  [[ -n "${!name:-}" ]]
}

require_env() {
  local name
  for name in "$@"; do
    env_present "$name" || die "missing required environment variable: $name"
  done
}

ensure_dirs() {
  mkdir -p \
    "$STATE_DIR" \
    "$DATA_DIR/postgres" \
    "$DATA_DIR/minio" \
    "$DATA_DIR/minio-app-backups" \
    "$DATA_DIR/server-config" \
    "$RESTORE_DIR" \
    "$MC_CONFIG_DIR"
}

write_state() {
  local name="$1"
  local value="$2"
  local tmp

  ensure_dirs
  tmp="$(mktemp "${STATE_DIR}/${name}.XXXXXX")"
  printf '%s\n' "$value" >"$tmp"
  mv -f "$tmp" "${STATE_DIR}/${name}"
}

read_state() {
  local name="$1"
  local file="${STATE_DIR}/${name}"

  if [[ -f "$file" ]]; then
    tr -d '\r\n' <"$file"
  fi
}

now_epoch() {
  date -u +%s
}

utc_weekday() {
  date -u +%w
}

utc_date() {
  date -u +%Y-%m-%d
}

configure_restic_env() {
  require_env RESTIC_PASSWORD R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY

  if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
    require_env R2_BUCKET
    local endpoint
    if [[ -n "${R2_ENDPOINT:-}" ]]; then
      endpoint="${R2_ENDPOINT%/}"
    else
      require_env R2_ACCOUNT_ID
      endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    fi

    if [[ -n "${RESTIC_REPOSITORY_PREFIX:-}" ]]; then
      RESTIC_REPOSITORY="s3:${endpoint}/${R2_BUCKET}/${RESTIC_REPOSITORY_PREFIX}"
    else
      RESTIC_REPOSITORY="s3:${endpoint}/${R2_BUCKET}"
    fi
  fi

  export RESTIC_REPOSITORY
  export RESTIC_PASSWORD
  export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION="${R2_REGION}"
}

validate_backup_env() {
  require_env \
    POSTGRES_PASSWORD \
    MINIO_ROOT_USER \
    MINIO_ROOT_PASSWORD \
    RESTIC_PASSWORD \
    R2_ACCESS_KEY_ID \
    R2_SECRET_ACCESS_KEY

  if [[ -z "${RESTIC_REPOSITORY:-}" && -z "${R2_ENDPOINT:-}" ]]; then
    require_env R2_ACCOUNT_ID R2_BUCKET
  elif [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
    require_env R2_BUCKET
  fi

  configure_restic_env
}

restic_cmd() {
  restic --retry-lock 10m -o s3.bucket-lookup=auto "$@"
}

restic_repo_exists() {
  configure_restic_env
  restic_cmd cat config >/dev/null 2>&1
}

configure_mc_local() {
  require_env MINIO_ROOT_USER MINIO_ROOT_PASSWORD
  mkdir -p "$MC_CONFIG_DIR"
  mc alias set local "$S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
}

dump_path() {
  printf '%s/postgres/%s.dump' "$DATA_DIR" "$POSTGRES_DB"
}

config_archive_path() {
  printf '%s/server-config/config.tar.gz' "$DATA_DIR"
}

pg_conn_args() {
  printf -- '-h %s -U %s' "$POSTGRES_HOST" "$POSTGRES_USER"
}

export_pg_password() {
  require_env POSTGRES_PASSWORD
  export PGPASSWORD="$POSTGRES_PASSWORD"
}

acquire_backup_lock() {
  ensure_dirs
  exec 9>"$(lock_file)"
  if ! flock -n 9; then
    return 1
  fi
  write_state backup.pid "$$"
  write_state backup.started "$(now_epoch)"
  return 0
}

release_backup_lock() {
  rm -f "${STATE_DIR}/backup.pid" "${STATE_DIR}/backup.started"
  if [[ -e /dev/fd/9 ]]; then
    flock -u 9 || true
  fi
}

backup_is_running() {
  local pid started now

  pid="$(read_state backup.pid || true)"
  started="$(read_state backup.started || true)"
  if [[ -z "$pid" || -z "$started" ]]; then
    return 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  now="$(now_epoch)"
  if (( now - started > BACKUP_MAX_RUNTIME_SECONDS )); then
    return 2
  fi
  return 0
}

check_staging_space() {
  local avail_kb used_kb need_kb min_kb

  avail_kb="$(df -Pk /staging | awk 'NR==2 {print $4}')"
  used_kb="$(du -sk "$DATA_DIR" 2>/dev/null | awk '{print $1}')"
  min_kb=$((BACKUP_MIN_FREE_MB * 1024))
  need_kb=$((used_kb / 5 + min_kb))

  if [[ -z "$avail_kb" ]]; then
    die "could not determine free space on /staging"
  fi
  if (( avail_kb < need_kb )); then
    die "not enough free space on /staging: available ${avail_kb} KB, need at least ${need_kb} KB"
  fi
  log "staging space ok: available ${avail_kb} KB, required ${need_kb} KB"
}

write_runtime_env() {
  local dest="${1:-/etc/backup.env}"
  local key
  local keys=(
    TZ
    STATE_DIR
    DATA_DIR
    RESTORE_DIR
    SERVER_CONFIG_DIR
    POSTGRES_HOST
    POSTGRES_USER
    POSTGRES_PASSWORD
    POSTGRES_DB
    MINIO_ROOT_USER
    MINIO_ROOT_PASSWORD
    S3_ENDPOINT
    S3_BUCKET
    S3_APP_BACKUPS_BUCKET
    INSTANT_SERVER_URL
    INSTANT_PLATFORM_TOKEN
    APP_BACKUP_CRON
    APP_BACKUP_APP_IDS
    APP_BACKUP_JOB_TIMEOUT_SECONDS
    APP_BACKUP_POLL_SECONDS
    R2_ACCOUNT_ID
    R2_BUCKET
    R2_ENDPOINT
    R2_ACCESS_KEY_ID
    R2_SECRET_ACCESS_KEY
    R2_REGION
    RESTIC_PASSWORD
    RESTIC_REPOSITORY
    RESTIC_REPOSITORY_PREFIX
    BACKUP_CRON
    BACKUP_FRESHNESS_SECONDS
    BACKUP_MAX_RUNTIME_SECONDS
    BACKUP_MIN_FREE_MB
    RESTIC_KEEP_WITHIN
    RESTIC_KEEP_WEEKLY
    RESTIC_KEEP_MONTHLY
    RESTIC_CHECK_READ_DATA_SUBSET
    MAINTENANCE_WEEKDAY
  )

  : >"$dest"
  chmod 0600 "$dest"
  for key in "${keys[@]}"; do
    if [[ -n "${!key+x}" && -n "${!key}" ]]; then
      printf 'export %s=%q\n' "$key" "${!key}" >>"$dest"
    fi
  done
}
