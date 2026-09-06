#!/usr/bin/env bash
# Restore an InstantDB snapshot into isolated targets or, with confirmation, live data.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

LIVE_CONFIRM_PHRASE="I_UNDERSTAND_THIS_REPLACES_LIVE_DATA"

usage() {
  cat <<EOF
Restore InstantDB data from the restic repository on R2.

Usage:
  restore.sh list
  restore.sh drill
  restore.sh live

Environment:
  RESTORE_SNAPSHOT          Snapshot ID or latest (default: latest)
  RESTORE_TARGET_DB         Destination database name
  RESTORE_TARGET_BUCKET     Destination MinIO bucket
  RESTORE_CONFIG_DIR        Destination directory for the config archive
  RESTORE_CLEANUP           Set to yes to remove drill targets after success
  RESTORE_CONFIRM           Required for live restore: ${LIVE_CONFIRM_PHRASE}

drill creates uniquely named temporary targets and never writes the live
database, live bucket, or live server config.

live replaces the named live targets. Stop the Instant server first.
EOF
}

snapshot_id() {
  printf '%s' "${RESTORE_SNAPSHOT:-latest}"
}

restore_work_dir() {
  printf '%s/%s' "$RESTORE_DIR" "$(date -u +%Y%m%dT%H%M%SZ)-$$"
}

list_snapshots() {
  validate_backup_env
  if ! restic_repo_exists; then
    die "restic repository does not exist at ${RESTIC_REPOSITORY}"
  fi
  restic_cmd snapshots
}

extract_snapshot() {
  local dest="$1"

  mkdir -p "$dest"
  log "restoring snapshot $(snapshot_id) to ${dest}"
  if [[ "$(snapshot_id)" == "latest" ]]; then
    restic_cmd restore latest --target "$dest"
  else
    restic_cmd restore "$(snapshot_id)" --target "$dest"
  fi
}

validate_restored_set() {
  local root="$1"
  local dump archive

  dump="${root}/postgres/${POSTGRES_DB}.dump"
  archive="${root}/server-config/config.tar.gz"
  [[ -f "$dump" ]] || die "restored snapshot is missing ${dump}"
  [[ -f "$archive" ]] || die "restored snapshot is missing ${archive}"
  [[ -d "${root}/minio" ]] || die "restored snapshot is missing ${root}/minio"
  log "restored snapshot contains dump, uploads, and server config"
}

restore_database() {
  local dump="$1"
  local target_db="$2"

  export_pg_password
  log "creating database ${target_db}"
  createdb \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    "$target_db"
  log "restoring dump into ${target_db}"
  pg_restore \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    -d "$target_db" \
    --no-owner \
    --no-acl \
    --no-password \
    "$dump"
}

verify_database() {
  local target_db="$1"
  local table_count

  export_pg_password
  psql \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    -d "$target_db" \
    -v ON_ERROR_STOP=1 \
    -c "SELECT 1" \
    >/dev/null
  table_count="$(
    psql \
      -h "$POSTGRES_HOST" \
      -U "$POSTGRES_USER" \
      -d "$target_db" \
      -tAc "SELECT count(*) FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema')"
  )"
  if [[ -z "$table_count" ]]; then
    die "could not count tables in ${target_db}"
  fi
  log "database ${target_db} opened with ${table_count} user tables"
}

drop_database() {
  local target_db="$1"

  export_pg_password
  log "dropping drill database ${target_db}"
  dropdb \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    --if-exists \
    "$target_db"
}

restore_uploads() {
  local source_dir="$1"
  local target_bucket="$2"

  configure_mc_local
  log "creating bucket ${target_bucket}"
  mc mb --ignore-existing "local/${target_bucket}"
  log "mirroring restored uploads into ${target_bucket}"
  mc mirror --overwrite --remove "$source_dir" "local/${target_bucket}"
}

compare_uploads() {
  local source_dir="$1"
  local target_bucket="$2"
  local source_count dest_count

  configure_mc_local
  source_count="$(find "$source_dir" -type f | wc -l | tr -d ' ')"
  dest_count="$(mc ls --recursive "local/${target_bucket}" | wc -l | tr -d ' ')"
  log "upload object counts: restored=${source_count} destination=${dest_count}"
  if [[ "$source_count" != "$dest_count" ]]; then
    die "restored upload count does not match destination bucket ${target_bucket}"
  fi
}

remove_bucket() {
  local target_bucket="$1"

  configure_mc_local
  log "removing drill bucket ${target_bucket}"
  mc rb --force "local/${target_bucket}" || true
}

extract_config() {
  local archive="$1"
  local dest="$2"

  mkdir -p "$dest"
  log "extracting server config to ${dest}"
  tar -C "$dest" -xzf "$archive"
  find "$dest" -type f | sed -n '1,20p' || true
}

replace_live_database() {
  local dump="$1"
  local target_db="$2"

  export_pg_password
  log "replacing live database ${target_db}"
  psql \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    --set=target_db="$target_db" \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'target_db' AND pid <> pg_backend_pid();"
  dropdb \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    --if-exists \
    --force \
    "$target_db"
  restore_database "$dump" "$target_db"
}

run_drill() {
  local work root dump archive target_db target_bucket config_dir

  validate_backup_env
  require_cmd restic mc pg_restore createdb dropdb psql tar find
  if ! restic_repo_exists; then
    die "restic repository does not exist at ${RESTIC_REPOSITORY}"
  fi

  target_db="${RESTORE_TARGET_DB:-instant_restore_$(date -u +%Y%m%d%H%M%S)}"
  target_bucket="${RESTORE_TARGET_BUCKET:-instant-restore-$(date -u +%Y%m%d%H%M%S)}"
  work="$(restore_work_dir)"
  config_dir="${RESTORE_CONFIG_DIR:-${work}/server-config-extracted}"

  if [[ "$target_db" == "$POSTGRES_DB" ]]; then
    die "drill refuses to use the live database name ${POSTGRES_DB}"
  fi
  if [[ "$target_bucket" == "$S3_BUCKET" ]]; then
    die "drill refuses to use the live bucket name ${S3_BUCKET}"
  fi
  if [[ "$config_dir" == "$SERVER_CONFIG_DIR" ]]; then
    die "drill refuses to write the live server config directory"
  fi

  extract_snapshot "$work"
  root="$(restored_data_root "$work")"
  validate_restored_set "$root"
  dump="${root}/postgres/${POSTGRES_DB}.dump"
  archive="${root}/server-config/config.tar.gz"

  restore_database "$dump" "$target_db"
  verify_database "$target_db"
  restore_uploads "${root}/minio" "$target_bucket"
  compare_uploads "${root}/minio" "$target_bucket"
  extract_config "$archive" "$config_dir"

  log "DRILL OK snapshot=$(snapshot_id) db=${target_db} bucket=${target_bucket} config=${config_dir}"

  if [[ "${RESTORE_CLEANUP:-}" == "yes" ]]; then
    drop_database "$target_db"
    remove_bucket "$target_bucket"
    rm -rf "$work"
    log "removed temporary drill targets"
  else
    log "left drill targets in place; set RESTORE_CLEANUP=yes to remove them after a successful drill"
  fi
}

run_live() {
  local work root dump archive target_db target_bucket config_dir

  [[ "${RESTORE_CONFIRM:-}" == "$LIVE_CONFIRM_PHRASE" ]] || \
    die "live restore refused. Set RESTORE_CONFIRM=${LIVE_CONFIRM_PHRASE}"

  target_db="${RESTORE_TARGET_DB:-}"
  target_bucket="${RESTORE_TARGET_BUCKET:-}"
  config_dir="${RESTORE_CONFIG_DIR:-$SERVER_CONFIG_DIR}"
  [[ -n "$target_db" ]] || die "live restore requires RESTORE_TARGET_DB"
  [[ -n "$target_bucket" ]] || die "live restore requires RESTORE_TARGET_BUCKET"
  [[ "$target_db" == "$POSTGRES_DB" ]] || die "RESTORE_TARGET_DB must match POSTGRES_DB (${POSTGRES_DB})"
  [[ "$target_bucket" == "$S3_BUCKET" ]] || die "RESTORE_TARGET_BUCKET must match S3_BUCKET (${S3_BUCKET})"
  [[ "$config_dir" == "$SERVER_CONFIG_DIR" ]] || die "live restore writes only ${SERVER_CONFIG_DIR}"

  validate_backup_env
  require_cmd restic mc pg_restore createdb dropdb psql tar
  if ! restic_repo_exists; then
    die "restic repository does not exist at ${RESTIC_REPOSITORY}"
  fi

  work="$(restore_work_dir)"
  extract_snapshot "$work"
  root="$(restored_data_root "$work")"
  validate_restored_set "$root"
  dump="${root}/postgres/${POSTGRES_DB}.dump"
  archive="${root}/server-config/config.tar.gz"

  replace_live_database "$dump" "$target_db"
  verify_database "$target_db"
  restore_uploads "${root}/minio" "$target_bucket"
  compare_uploads "${root}/minio" "$target_bucket"
  extract_config "$archive" "$config_dir"
  rm -rf "$work"
  log "LIVE RESTORE OK snapshot=$(snapshot_id) db=${target_db} bucket=${target_bucket}"
}

main() {
  case "${1:-}" in
    list)
      list_snapshots
      ;;
    drill)
      run_drill
      ;;
    live)
      run_live
      ;;
    -h|--help|"")
      usage
      [[ -n "${1:-}" ]] || exit 1
      ;;
    *)
      die "unknown restore command: $1"
      ;;
  esac
}

main "$@"
