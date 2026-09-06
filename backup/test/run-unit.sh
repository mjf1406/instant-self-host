#!/usr/bin/env bash
# Host-side checks that do not need Docker or live Instant volumes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib.sh
. "${ROOT}/backup/lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

STATE_DIR="$(mktemp -d)"
DATA_DIR="${STATE_DIR}/data"
RESTORE_DIR="${STATE_DIR}/restore"
EXPORTS_DIR="${STATE_DIR}/exports"
export STATE_DIR DATA_DIR RESTORE_DIR EXPORTS_DIR
ensure_dirs

if ( require_env UNIT_TEST_MISSING_VAR ) 2>/dev/null; then
  fail "require_env should fail when a variable is missing"
fi
pass "require_env rejects a missing variable"

export RESTIC_PASSWORD=unit-pass
export R2_ACCESS_KEY_ID=unit-key
export R2_SECRET_ACCESS_KEY=unit-secret
export R2_ACCOUNT_ID=abc123
export R2_BUCKET=instant-self-host-backups
unset RESTIC_REPOSITORY || true
unset R2_ENDPOINT || true
configure_restic_env
[[ "$RESTIC_REPOSITORY" == "s3:https://abc123.r2.cloudflarestorage.com/instant-self-host-backups" ]] \
  || fail "unexpected repository URL: ${RESTIC_REPOSITORY}"
pass "configure_restic_env builds the default R2 URL"

if command -v flock >/dev/null 2>&1; then
  if ! acquire_backup_lock; then
    fail "first lock acquire should succeed"
  fi
  if (
    STATE_DIR="$STATE_DIR" \
    DATA_DIR="$DATA_DIR" \
    RESTORE_DIR="$RESTORE_DIR" \
    bash -c '. "'"${ROOT}/backup/lib.sh"'" && acquire_backup_lock'
  ); then
    fail "second lock acquire should fail while the first holder is alive"
  fi
  release_backup_lock
  pass "backup lock blocks overlapping jobs"
else
  echo "SKIP: flock is not available on this host; overlap locking is covered by backup/test/run-isolated.sh"
fi

write_state last-success "100"
[[ "$(read_state last-success)" == "100" ]] || fail "state round-trip failed"
pass "state files write and read"

if ( BACKUP_FRESHNESS_SECONDS=10 STATE_DIR="$STATE_DIR" bash "${ROOT}/backup/healthcheck.sh" ); then
  fail "healthcheck should fail for a stale last-success timestamp"
fi
pass "healthcheck fails when the last snapshot is stale"

write_state last-success "$(now_epoch)"
if ! ( BACKUP_FRESHNESS_SECONDS=28800 STATE_DIR="$STATE_DIR" bash "${ROOT}/backup/healthcheck.sh" ); then
  fail "healthcheck should pass when the last snapshot is fresh"
fi
pass "healthcheck passes when the last snapshot is fresh"

if command -v restic >/dev/null 2>&1; then
  if (
    RESTIC_PASSWORD=unit-pass \
    R2_ACCESS_KEY_ID=unit-key \
    R2_SECRET_ACCESS_KEY=unit-secret \
    R2_ACCOUNT_ID=abc123 \
    R2_BUCKET=instant-self-host-backups \
    RESTIC_INIT_CONFIRM=no \
    bash "${ROOT}/backup/init-repo.sh"
  ) 2>/dev/null; then
    fail "init-repo.sh should refuse without RESTIC_INIT_CONFIRM=yes when the repo is missing"
  fi
  pass "init-repo.sh refuses an unconfirmed init"
else
  echo "SKIP: restic is not installed on this host; init-repo refusal is covered by backup/test/run-isolated.sh"
fi

if (
  RESTIC_PASSWORD=unit-pass \
  R2_ACCESS_KEY_ID=unit-key \
  R2_SECRET_ACCESS_KEY=unit-secret \
  R2_ACCOUNT_ID=abc123 \
  R2_BUCKET=instant-self-host-backups \
  POSTGRES_PASSWORD=x \
  MINIO_ROOT_USER=x \
  MINIO_ROOT_PASSWORD=x \
  bash "${ROOT}/backup/restore.sh" live
) 2>/dev/null; then
  fail "restore.sh live should refuse without RESTORE_CONFIRM"
fi
pass "restore.sh live refuses without confirmation"

if (
  RESTIC_PASSWORD=unit-pass \
  R2_ACCESS_KEY_ID=unit-key \
  R2_SECRET_ACCESS_KEY=unit-secret \
  R2_ACCOUNT_ID=abc123 \
  R2_BUCKET=instant-self-host-backups \
  POSTGRES_PASSWORD=x \
  MINIO_ROOT_USER=x \
  MINIO_ROOT_PASSWORD=x \
  bash "${ROOT}/backup/app-backup.sh"
) 2>/dev/null; then
  fail "app-backup.sh should refuse without INSTANT_PLATFORM_TOKEN"
fi
pass "app-backup.sh refuses without a platform token"

[[ -d "${DATA_DIR}/minio-app-backups" ]] || fail "ensure_dirs should create minio-app-backups"
[[ -d "$EXPORTS_DIR" ]] || fail "ensure_dirs should create the exports directory"
pass "ensure_dirs creates the app-backups staging directory"

# Source function definitions without running the script's main flow.
# shellcheck source=../app-backup.sh
. "${ROOT}/backup/app-backup.sh"

http_json() {
  case "$1 $2" in
    "GET /dash")
      HTTP_STATUS=200
      HTTP_BODY='{"apps":[{"id":"app-b"},{"id":"app-a"}],"orgs":[{"id":"org-1"}]}'
      ;;
    "GET /dash/orgs/org-1")
      HTTP_STATUS=200
      HTTP_BODY='{"apps":[{"id":"app-c"},{"id":"app-a"}]}'
      ;;
    *)
      HTTP_STATUS=404
      HTTP_BODY='{"message":"not found"}'
      ;;
  esac
  HTTP_RETRY_AFTER=""
}

unset APP_BACKUP_APP_IDS || true
if command -v jq >/dev/null 2>&1; then
  discovered="$(list_app_ids)"
  [[ "$discovered" == $'app-a\napp-b\napp-c' ]] \
    || fail "unexpected dashboard app discovery result: ${discovered}"
  pass "app discovery includes personal and organization apps once"
else
  echo "SKIP: jq is not available on this host; app discovery is covered by the image build"
fi

http_json() {
  if [[ "$1 $2" == "POST /dash/apps/denied-app/backups" ]]; then
    HTTP_STATUS=403
    HTTP_BODY='{"message":"forbidden"}'
  else
    HTTP_STATUS=200
    HTTP_BODY='{"jobs":[]}'
  fi
  HTTP_RETRY_AFTER=""
}

if start_error="$(start_or_attach_job denied-app 2>&1)"; then
  fail "start_or_attach_job should fail when POST is denied"
fi
[[ "$start_error" == *"HTTP 403"* && "$start_error" == *"forbidden"* ]] \
  || fail "start failure should preserve the POST response: ${start_error}"
pass "app backup start failures remain visible"

post_calls=0
http_json() {
  post_calls=$((post_calls + 1))
  if [[ "$post_calls" -eq 1 ]]; then
    HTTP_STATUS=429
    HTTP_BODY='{"message":"try later"}'
    HTTP_RETRY_AFTER=7
  else
    HTTP_STATUS=200
    HTTP_BODY='{"job":{"id":"retried-job"}}'
    HTTP_RETRY_AFTER=""
  fi
}
sleep() {
  [[ "$1" == "7" ]] || fail "retry should honor Retry-After, got $1"
}
APP_BACKUP_RATE_LIMIT_MAX_RETRIES=1
retried_job="$(start_or_attach_job retry-app)"
[[ "$retried_job" == "retried-job" ]] \
  || fail "rate-limited backup did not retry successfully: ${retried_job}"
pass "app backups retry rate limits using Retry-After"

if (
  unset POSTGRES_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD RESTIC_REPOSITORY R2_ENDPOINT
  RESTIC_PASSWORD=unit-pass \
  R2_ACCESS_KEY_ID=unit-key \
  R2_SECRET_ACCESS_KEY=unit-secret \
  R2_ACCOUNT_ID=abc123 \
  R2_BUCKET=instant-self-host-backups \
  bash -c '. "'"${ROOT}/backup/lib.sh"'" && validate_recovery_env'
); then
  pass "recovery env does not require Postgres or MinIO"
else
  fail "validate_recovery_env should succeed without live-stack credentials"
fi

if list_error="$(
  unset POSTGRES_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD
  RESTIC_PASSWORD=unit-pass \
  R2_ACCESS_KEY_ID=unit-key \
  R2_SECRET_ACCESS_KEY=unit-secret \
  R2_ACCOUNT_ID=abc123 \
  R2_BUCKET=instant-self-host-backups \
  bash "${ROOT}/backup/export-app-backup.sh" list 2>&1
)"; then
  fail "export list should fail without restic or a repository, not succeed"
fi
[[ "$list_error" != *"POSTGRES_PASSWORD"* && "$list_error" != *"MINIO_ROOT_"* ]] \
  || fail "export list should not require live-stack credentials: ${list_error}"
pass "export list does not require Postgres or MinIO"

# Source exporter helpers without running the restic path.
# shellcheck source=../export-app-backup.sh
. "${ROOT}/backup/export-app-backup.sh"

if ( parse_export_args ) 2>/dev/null; then
  fail "parse_export_args should require --app"
fi
pass "export refuses a missing --app"

if ( parse_export_args --app not-a-uuid ) 2>/dev/null; then
  fail "parse_export_args should reject an invalid app id"
fi
pass "export refuses an invalid app id"

EXPORT_APP_ID="11111111-1111-4111-8111-111111111111"
EXPORT_BACKUP_PREFIX=""
EXPORT_FORCE="no"
EXPORT_WORK_DIR="$(mktemp -d "${STATE_DIR}/export-XXXXXX")"
app_root="${EXPORT_WORK_DIR}/minio-app-backups/${EXPORT_APP_ID}"
uploads_root="${EXPORT_WORK_DIR}/minio/${EXPORT_APP_ID}"
old_backup="${app_root}/22222222-2222-4222-8222-222222222222"
new_backup="${app_root}/33333333-3333-4333-8333-333333333333"
mkdir -p "${old_backup}/entities" "${new_backup}/entities" "${uploads_root}/7"
cat >"${old_backup}/config.json" <<'EOF'
{"schema":{"entities":{}},"backupAt":"2020-01-01T00:00:00Z","title":"old"}
EOF
cat >"${new_backup}/config.json" <<'EOF'
{"schema":{"entities":{"todos":{}}},"backupAt":"2026-09-06T00:00:00Z","title":"new"}
EOF
cat >"${new_backup}/entities/todos.jsonl" <<'EOF'
{"entity":{"id":"66666666-6666-4666-8666-666666666666","name":"exported"},"createdAt":1772604198270}
EOF
cat >"${new_backup}/entities/\$files.jsonl" <<'EOF'
{"entity":{"id":"55555555-5555-4555-8555-555555555555","path":"probe.txt","size":12,"location-id":"44444444-4444-4444-8444-444444444444","content-type":"text/plain"},"createdAt":1772604198270}
EOF
printf 'hello-export' >"${uploads_root}/7/44444444-4444-4444-8444-444444444444"

if command -v jq >/dev/null 2>&1; then
  selected="$(select_backup_dir "$app_root")"
  [[ "$selected" == "$new_backup" ]] \
    || fail "select_backup_dir should pick the newest backupAt: ${selected}"
  pass "export selects the newest dashboard backup"

  selected="$(select_backup_dir "$app_root" "22222222-2222-4222-8222-222222222222")"
  [[ "$selected" == "$old_backup" ]] \
    || fail "select_backup_dir should honor --backup-prefix: ${selected}"
  pass "export honors an explicit backup prefix"
else
  echo "SKIP: jq is not available on this host; backup selection is covered by the image build"
fi

if command -v jq >/dev/null 2>&1; then
  missing_decoded="${EXPORT_WORK_DIR}/missing"
  mkdir -p "${missing_decoded}/entities"
  printf '%s\n' '{"schema":{"entities":{}}}' >"${missing_decoded}/config.json"
  cp "${new_backup}/entities/\$files.jsonl" "${missing_decoded}/entities/\$files.jsonl"
  if ( collect_storage_files "$missing_decoded" "${EXPORT_WORK_DIR}/minio/missing-app" ) 2>/dev/null; then
    fail "collect_storage_files should fail when a blob is missing"
  fi
  pass "export fails when a required storage blob is missing"

  mkdir -p "${uploads_root}/9"
  cp "${uploads_root}/7/44444444-4444-4444-8444-444444444444" \
    "${uploads_root}/9/44444444-4444-4444-8444-444444444444"
  ambiguous_decoded="${EXPORT_WORK_DIR}/ambiguous"
  mkdir -p "${ambiguous_decoded}/entities"
  printf '%s\n' '{"schema":{"entities":{}}}' >"${ambiguous_decoded}/config.json"
  cp "${new_backup}/entities/\$files.jsonl" "${ambiguous_decoded}/entities/\$files.jsonl"
  if ( collect_storage_files "$ambiguous_decoded" "$uploads_root" ) 2>/dev/null; then
    fail "collect_storage_files should fail when a blob is ambiguous"
  fi
  pass "export fails when a storage blob is ambiguous"
  rm -f "${uploads_root}/9/44444444-4444-4444-8444-444444444444"
else
  echo "SKIP: jq is not available on this host; missing-file checks are covered by the image build"
fi

if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  EXPORT_OUTPUT="${EXPORT_WORK_DIR}/out"
  mkdir -p "$EXPORT_OUTPUT"
  export_app_from_trees "$app_root" "$uploads_root" ""
  zip_path="$EXPORT_ZIP_PATH"
  [[ -f "$zip_path" ]] || fail "export_app_from_trees did not write a ZIP"
  mapfile -t zip_entries < <(unzip -Z -1 "$zip_path")
  expected_entries=(
    "config.json"
    'entities/$files.jsonl'
    "entities/todos.jsonl"
    "files/44444444-4444-4444-8444-444444444444"
  )
  [[ "${#zip_entries[@]}" -eq "${#expected_entries[@]}" ]] \
    || fail "unexpected ZIP entry count: ${zip_entries[*]}"
  for i in "${!expected_entries[@]}"; do
    [[ "${zip_entries[$i]}" == "${expected_entries[$i]}" ]] \
      || fail "ZIP entry ${i} was ${zip_entries[$i]}, expected ${expected_entries[$i]}"
  done
  for entry in "${zip_entries[@]}"; do
    [[ "$entry" != */ ]] || fail "ZIP should not contain directory entries: ${entry}"
  done
  extracted="${EXPORT_WORK_DIR}/unzipped"
  mkdir -p "$extracted"
  unzip -q -d "$extracted" "$zip_path"
  jq -e '.schema.entities.todos != null' "${extracted}/config.json" >/dev/null \
    || fail "exported config.json was not readable JSON with a schema"
  [[ "$(cat "${extracted}/files/44444444-4444-4444-8444-444444444444")" == "hello-export" ]] \
    || fail "exported file bytes did not match the storage blob"
  pass "export ZIP has Instant restore order and raw file bytes"

  if ( EXPORT_FORCE=no export_app_from_trees "$app_root" "$uploads_root" "$zip_path" ) 2>/dev/null; then
    fail "export should refuse to overwrite an existing ZIP"
  fi
  pass "export refuses to overwrite an existing ZIP"
else
  echo "SKIP: zip/unzip/jq are not available on this host; ZIP order is covered by backup/test/run-isolated.sh"
fi

rm -rf "$STATE_DIR"
echo "unit checks passed"
