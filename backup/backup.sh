#!/usr/bin/env bash
# Create one encrypted InstantDB snapshot and upload it to Cloudflare R2.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

on_exit() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    write_state last-failure "$(now_epoch)" || true
  fi
  release_backup_lock
}

usage() {
  cat <<'EOF'
Create one InstantDB backup and send it to the restic repository on R2.

Usage:
  backup.sh

The repository must already exist. This script never initializes a new one.
EOF
}

mirror_uploads() {
  log "mirroring MinIO bucket ${S3_BUCKET} to staging"
  configure_mc_local
  mc mirror --overwrite --remove "local/${S3_BUCKET}" "$DATA_DIR/minio"
}

dump_postgres() {
  local dest tmp

  dest="$(dump_path)"
  tmp="${dest}.tmp"
  rm -f "$tmp"
  export_pg_password
  log "dumping PostgreSQL database ${POSTGRES_DB}"
  pg_dump \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -Fc \
    --no-password \
    -f "$tmp"
  mv -f "$tmp" "$dest"
  log "wrote ${dest}"
}

archive_server_config() {
  local dest tmp

  dest="$(config_archive_path)"
  tmp="${dest}.tmp"
  rm -f "$tmp"
  if [[ ! -d "$SERVER_CONFIG_DIR" ]]; then
    die "server config directory not found: ${SERVER_CONFIG_DIR}"
  fi
  log "archiving server config from ${SERVER_CONFIG_DIR}"
  tar -C "$SERVER_CONFIG_DIR" -czf "$tmp" .
  mv -f "$tmp" "$dest"
  log "wrote ${dest}"
}

upload_snapshot() {
  log "uploading restic snapshot to ${RESTIC_REPOSITORY}"
  restic_cmd backup \
    --tag instant \
    --host instant-self-host \
    "$DATA_DIR"
}

verify_metadata() {
  log "running restic metadata check"
  restic_cmd check
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd restic mc pg_dump tar flock df du
  validate_backup_env
  ensure_dirs

  if ! restic_repo_exists; then
    die "restic repository does not exist at ${RESTIC_REPOSITORY}. Run the backup-init service with RESTIC_INIT_CONFIRM=yes after you have checked the bucket and endpoint."
  fi

  if ! acquire_backup_lock; then
    log "another backup is already running; skipping this run"
    exit 0
  fi
  trap on_exit EXIT

  check_staging_space
  mirror_uploads
  dump_postgres
  archive_server_config
  upload_snapshot
  verify_metadata

  write_state last-success "$(now_epoch)"
  write_state last-snapshot-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "backup completed"

  /usr/local/bin/maintenance.sh
}

main "$@"
