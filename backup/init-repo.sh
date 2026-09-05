#!/usr/bin/env bash
# Create the restic repository on R2 only after an explicit confirmation.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "$0")" && pwd)/lib.sh"
fi
. "$LIB_SH"

usage() {
  cat <<'EOF'
Initialize the restic repository on Cloudflare R2.

This command refuses to run unless RESTIC_INIT_CONFIRM=yes.
Check the account ID, endpoint, bucket, and prefix before you confirm.
A mistyped destination can create an empty repository in the wrong place.

Usage:
  RESTIC_INIT_CONFIRM=yes init-repo.sh
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd restic
  validate_backup_env

  if restic_repo_exists; then
    log "restic repository already exists at ${RESTIC_REPOSITORY}"
    restic_cmd snapshots --latest 1
    exit 0
  fi

  if [[ "${RESTIC_INIT_CONFIRM:-}" != "yes" ]]; then
    die "refusing to initialize a new restic repository at ${RESTIC_REPOSITORY}. Set RESTIC_INIT_CONFIRM=yes after you have checked the bucket and endpoint."
  fi

  log "initializing restic repository at ${RESTIC_REPOSITORY}"
  restic_cmd init
  restic_cmd cat config >/dev/null
  log "repository initialized"
}

main "$@"
