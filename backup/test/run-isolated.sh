#!/usr/bin/env bash
# Isolated backup and restore drill against disposable Postgres, MinIO, and an R2 stand-in.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE=(docker compose -f "${ROOT}/backup/test/isolated-compose.yml" --project-name instant-backup-isolated)
cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

log "building backup image"
"${COMPOSE[@]}" build backup

log "refusing unconfirmed repository init"
if "${COMPOSE[@]}" run --rm --no-deps --entrypoint /usr/local/bin/init-repo.sh backup >/tmp/instant-init-refuse.log 2>&1; then
  cat /tmp/instant-init-refuse.log
  echo "init-repo.sh should refuse without RESTIC_INIT_CONFIRM=yes" >&2
  exit 1
fi
grep -q "refusing to initialize" /tmp/instant-init-refuse.log

log "starting disposable stack"
"${COMPOSE[@]}" up -d postgres minio r2
"${COMPOSE[@]}" up --no-build createbuckets

log "initializing repository"
"${COMPOSE[@]}" --profile backup-init run --rm --no-deps backup-init

log "running first backup"
"${COMPOSE[@]}" run --rm --no-deps --entrypoint /usr/local/bin/backup.sh backup

log "refusing live restore without confirmation"
if "${COMPOSE[@]}" --profile restore run --rm --no-deps \
  -e RESTORE_TARGET_DB=instant \
  -e RESTORE_TARGET_BUCKET=instant-bucket \
  restore live >/tmp/instant-live-refuse.log 2>&1; then
  cat /tmp/instant-live-refuse.log
  echo "restore.sh live should refuse without RESTORE_CONFIRM" >&2
  exit 1
fi
grep -q "live restore refused" /tmp/instant-live-refuse.log

log "running isolated restore drill"
"${COMPOSE[@]}" --profile restore run --rm --no-deps restore drill

log "isolated backup and restore drill passed"
