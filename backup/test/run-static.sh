#!/usr/bin/env bash
# Static checks for backup scripts and the rendered Compose stack.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS=(
  "${ROOT}/backup/lib.sh"
  "${ROOT}/backup/entrypoint.sh"
  "${ROOT}/backup/backup.sh"
  "${ROOT}/backup/app-backup.sh"
  "${ROOT}/backup/export-app-backup.sh"
  "${ROOT}/backup/maintenance.sh"
  "${ROOT}/backup/healthcheck.sh"
  "${ROOT}/backup/restore.sh"
  "${ROOT}/backup/init-repo.sh"
  "${ROOT}/backup/test/run-isolated.sh"
  "${ROOT}/backup/test/run-static.sh"
  "${ROOT}/backup/test/run-unit.sh"
)

for script in "${SCRIPTS[@]}"; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${SCRIPTS[@]}"
else
  echo "shellcheck not installed; bash -n passed"
fi

if command -v docker >/dev/null 2>&1; then
  docker compose \
    --env-file "${ROOT}/.env.example" \
    -f "${ROOT}/docker-compose.yml" \
    config \
    >/dev/null
  docker compose \
    --env-file "${ROOT}/backup/recovery.env.example" \
    -f "${ROOT}/backup/recovery-compose.yml" \
    config \
    >/dev/null
else
  echo "docker not installed; skipped compose config render"
fi

echo "static checks passed"
