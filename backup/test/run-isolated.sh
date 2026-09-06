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

log "testing dashboard app discovery"
"${COMPOSE[@]}" run --rm --no-deps --entrypoint bash backup -c '
  . /usr/local/bin/app-backup.sh
  http_json() {
    case "$1 $2" in
      "GET /dash")
        HTTP_STATUS=200
        HTTP_BODY="{\"apps\":[{\"id\":\"app-b\"},{\"id\":\"app-a\"}],\"orgs\":[{\"id\":\"org-1\"}]}"
        ;;
      "GET /dash/orgs/org-1")
        HTTP_STATUS=200
        HTTP_BODY="{\"apps\":[{\"id\":\"app-c\"},{\"id\":\"app-a\"}]}"
        ;;
      *)
        HTTP_STATUS=404
        HTTP_BODY="{\"message\":\"not found\"}"
        ;;
    esac
    HTTP_RETRY_AFTER=""
  }
  actual="$(list_app_ids)"
  test "$actual" = "$(printf "app-a\napp-b\napp-c")"
'

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

log "seeding a zstd dashboard backup and storage blob"
"${COMPOSE[@]}" run --rm --no-deps --entrypoint bash backup -c '
  set -euo pipefail
  . /usr/local/lib/backup/lib.sh
  configure_mc_local
  APP_ID=11111111-1111-4111-8111-111111111111
  BACKUP_ID=33333333-3333-4333-8333-333333333333
  LOCATION_ID=44444444-4444-4444-8444-444444444444
  tmp="$(mktemp -d)"
  cat >"${tmp}/config.json" <<EOF
{"schema":{"entities":{"todos":{}}},"counts":{"\$files":1,"todos":1},"title":"export-fixture","appId":"${APP_ID}","backupAt":"2026-09-06T00:00:00Z"}
EOF
  cat >"${tmp}/todos.jsonl" <<EOF
{"entity":{"id":"66666666-6666-4666-8666-666666666666","name":"exported"},"createdAt":1772604198270}
EOF
  cat >"${tmp}/files.jsonl" <<EOF
{"entity":{"id":"55555555-5555-4555-8555-555555555555","path":"probe.txt","size":12,"location-id":"${LOCATION_ID}","content-type":"text/plain"},"createdAt":1772604198270}
EOF
  zstd -q -f -o "${tmp}/config.json.zst" "${tmp}/config.json"
  zstd -q -f -o "${tmp}/todos.jsonl.zst" "${tmp}/todos.jsonl"
  zstd -q -f -o "${tmp}/files.jsonl.zst" "${tmp}/files.jsonl"
  mc cp "${tmp}/config.json.zst" "local/instant-app-backups/${APP_ID}/${BACKUP_ID}/config.json" >/dev/null
  mc cp "${tmp}/todos.jsonl.zst" "local/instant-app-backups/${APP_ID}/${BACKUP_ID}/entities/todos.jsonl" >/dev/null
  mc cp "${tmp}/files.jsonl.zst" "local/instant-app-backups/${APP_ID}/${BACKUP_ID}/entities/\$files.jsonl" >/dev/null
  printf "hello-export" | mc pipe "local/instant-bucket/${APP_ID}/7/${LOCATION_ID}"
  rm -rf "$tmp"
'

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

log "rendering standalone recovery compose"
docker compose \
  --env-file "${ROOT}/backup/recovery.env.example" \
  -f "${ROOT}/backup/recovery-compose.yml" \
  config \
  >/dev/null

log "listing snapshots without Postgres or MinIO credentials"
"${COMPOSE[@]}" --profile recovery run --rm recover list | tee /tmp/instant-recovery-list.log
grep -q "instant-self-host" /tmp/instant-recovery-list.log \
  || grep -q snapshot /tmp/instant-recovery-list.log

log "exporting one app onto the host bind mount"
rm -rf "${ROOT}/backup/test/exports"
mkdir -p "${ROOT}/backup/test/exports"
"${COMPOSE[@]}" --profile recovery run --rm recover \
  --app 11111111-1111-4111-8111-111111111111 \
  --snapshot latest

log "verifying Instant restore ZIP on the host bind mount"
zip_name=11111111-1111-4111-8111-111111111111-33333333-3333-4333-8333-333333333333.zip
test -f "${ROOT}/backup/test/exports/${zip_name}"
"${COMPOSE[@]}" --profile recovery run --rm --entrypoint bash recover -c '
  set -euo pipefail
  zip=/staging/exports/11111111-1111-4111-8111-111111111111-33333333-3333-4333-8333-333333333333.zip
  test -f "$zip"
  mapfile -t entries < <(unzip -Z -1 "$zip")
  test "${entries[0]}" = "config.json"
  test "${entries[1]}" = "entities/\$files.jsonl"
  test "${entries[2]}" = "entities/todos.jsonl"
  test "${entries[3]}" = "files/44444444-4444-4444-8444-444444444444"
  test "${#entries[@]}" -eq 4
  for entry in "${entries[@]}"; do
    case "$entry" in
      */) exit 1 ;;
    esac
  done
  tmp="$(mktemp -d)"
  unzip -q -d "$tmp" "$zip"
  jq -e ".schema.entities.todos != null" "${tmp}/config.json" >/dev/null
  test "$(cat "${tmp}/files/44444444-4444-4444-8444-444444444444")" = "hello-export"
  rm -rf "$tmp"
'
rm -rf "${ROOT}/backup/test/exports"

log "isolated backup and restore drill passed"
