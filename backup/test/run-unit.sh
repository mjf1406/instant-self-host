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
export STATE_DIR DATA_DIR RESTORE_DIR
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

rm -rf "$STATE_DIR"
echo "unit checks passed"
