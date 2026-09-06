#!/usr/bin/env bash
# Export one Instant app from an R2 restic snapshot as a restore ZIP.

set -euo pipefail

# shellcheck source=lib.sh
LIB_SH="/usr/local/lib/backup/lib.sh"
if [[ ! -f "$LIB_SH" ]]; then
  LIB_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi
. "$LIB_SH"

EXPORT_APP_ID=""
EXPORT_SNAPSHOT="latest"
EXPORT_BACKUP_PREFIX=""
EXPORT_OUTPUT=""
EXPORT_FORCE="no"
EXPORT_WORK_DIR=""

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
ZSTD_MAGIC='28b52ffd'

usage() {
  cat <<'EOF'
Export one Instant app from an encrypted restic snapshot on R2.

The command is read-only. It needs R2 credentials and RESTIC_PASSWORD. It
does not need a running Instant stack, Postgres, or MinIO.

Usage:
  export-app-backup.sh list
  export-app-backup.sh --app APP_ID [--snapshot SNAPSHOT_ID|latest]
                       [--backup-prefix PREFIX] [--output PATH] [--force]

Options:
  list                   Show restic snapshots in the R2 repository
  --app APP_ID           App UUID to export
  --snapshot ID          restic snapshot ID or latest (default: latest)
  --backup-prefix PREFIX Dashboard backup directory under the app, usually
                         the backup UUID. Default: newest backupAt
  --output PATH          ZIP file, or a directory for the default name
  --force                Replace an existing ZIP

The ZIP is written under /staging/exports by default. Copy it out, restore it
from the dashboard, then delete it. The archive contains production data.
EOF
}

is_uuid() {
  [[ "$1" =~ $UUID_RE ]]
}

is_zstd_file() {
  local hex

  [[ -f "$1" ]] || return 1
  hex="$(od -An -tx1 -N4 "$1" | tr -d ' \n')"
  [[ "$hex" == "$ZSTD_MAGIC" ]]
}

decode_zstd_or_copy() {
  local src="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")"
  if is_zstd_file "$src"; then
    zstd -dq -c "$src" >"$dest"
  else
    cp "$src" "$dest"
  fi
}

parse_export_args() {
  EXPORT_APP_ID=""
  EXPORT_SNAPSHOT="latest"
  EXPORT_BACKUP_PREFIX=""
  EXPORT_OUTPUT=""
  EXPORT_FORCE="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        [[ $# -ge 2 ]] || die "missing value for --app"
        EXPORT_APP_ID="$2"
        shift 2
        ;;
      --snapshot)
        [[ $# -ge 2 ]] || die "missing value for --snapshot"
        EXPORT_SNAPSHOT="$2"
        shift 2
        ;;
      --backup-prefix)
        [[ $# -ge 2 ]] || die "missing value for --backup-prefix"
        EXPORT_BACKUP_PREFIX="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die "missing value for --output"
        EXPORT_OUTPUT="$2"
        shift 2
        ;;
      --force)
        EXPORT_FORCE="yes"
        shift
        ;;
      -h|--help)
        usage
        return 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$EXPORT_APP_ID" ]] || die "missing required --app APP_ID"
  is_uuid "$EXPORT_APP_ID" || die "invalid app id: ${EXPORT_APP_ID}"
  [[ -n "$EXPORT_SNAPSHOT" ]] || die "snapshot must not be empty"
  if [[ -n "$EXPORT_BACKUP_PREFIX" ]]; then
    if [[ "$EXPORT_BACKUP_PREFIX" == /* || "$EXPORT_BACKUP_PREFIX" == *..* ]]; then
      die "invalid --backup-prefix: ${EXPORT_BACKUP_PREFIX}"
    fi
  fi
}

backup_at_sort_key() {
  local value="$1"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%020d' "$value"
  else
    printf '%s' "$value"
  fi
}

read_backup_at() {
  local config="$1"

  jq -r 'if .backupAt == null then empty else .backupAt | tostring end' "$config"
}

select_backup_dir() {
  local app_root="$1"
  local prefix="${2:-}"
  local config candidate decoded at key best="" best_key=""

  [[ -d "$app_root" ]] || die "snapshot has no dashboard backups for app ${EXPORT_APP_ID}"

  if [[ -n "$prefix" ]]; then
    candidate="${app_root}/${prefix}"
    [[ -f "${candidate}/config.json" ]] \
      || die "backup prefix ${prefix} was not found for app ${EXPORT_APP_ID}"
    printf '%s' "$candidate"
    return
  fi

  decoded="$(mktemp)"
  while IFS= read -r config; do
    [[ -n "$config" ]] || continue
    decode_zstd_or_copy "$config" "$decoded"
    at="$(read_backup_at "$decoded" || true)"
    candidate="$(dirname "$config")"
    if [[ -n "$at" ]]; then
      key="$(backup_at_sort_key "$at")"
    else
      key="$(basename "$candidate")"
    fi
    if [[ -z "$best" || "$key" > "$best_key" ]]; then
      best="$candidate"
      best_key="$key"
    fi
  done < <(find "$app_root" -mindepth 2 -maxdepth 2 -type f -name config.json | LC_ALL=C sort)
  rm -f "$decoded"

  [[ -n "$best" ]] || die "no config.json found for app ${EXPORT_APP_ID}"
  printf '%s' "$best"
}

decode_backup_dir() {
  local src="$1"
  local dest="$2"
  local file base

  [[ -f "${src}/config.json" ]] || die "selected backup is missing config.json"
  mkdir -p "${dest}/entities"
  decode_zstd_or_copy "${src}/config.json" "${dest}/config.json"
  jq -e 'type == "object" and (.schema | type == "object")' "${dest}/config.json" >/dev/null \
    || die "decoded config.json is missing a schema object"

  if [[ -d "${src}/entities" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      base="$(basename "$file")"
      decode_zstd_or_copy "$file" "${dest}/entities/${base}"
    done < <(find "${src}/entities" -maxdepth 1 -type f -name '*.jsonl' | LC_ALL=C sort)
  fi
}

extract_location_ids() {
  local files_jsonl="$1"

  [[ -f "$files_jsonl" ]] || return 0
  jq -r '
    if type != "object" then
      error("each $files.jsonl line must be a JSON object")
    elif (.entity | type) != "object" then
      error("$files.jsonl is missing an entity object")
    elif (.entity["location-id"] | type) != "string" or .entity["location-id"] == "" then
      error("$files.jsonl is missing entity.location-id")
    else
      .entity["location-id"]
    end
  ' "$files_jsonl"
}

locate_upload_blob() {
  local uploads_root="$1"
  local location_id="$2"
  local matches=()

  if [[ ! -d "$uploads_root" ]]; then
    die "missing storage blob for location-id ${location_id}"
  fi

  while IFS= read -r -d '' file; do
    matches+=("$file")
  done < <(find "$uploads_root" -type f -name "$location_id" -print0)

  if [[ ${#matches[@]} -eq 0 ]]; then
    die "missing storage blob for location-id ${location_id}"
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    die "ambiguous storage blob for location-id ${location_id}"
  fi
  printf '%s' "${matches[0]}"
}

collect_storage_files() {
  local decoded="$1"
  local uploads_root="$2"
  local files_jsonl="${decoded}/entities/\$files.jsonl"
  local location_id blob dest

  if [[ ! -f "$files_jsonl" ]]; then
    return 0
  fi

  mkdir -p "${decoded}/files"
  while IFS= read -r location_id; do
    [[ -n "$location_id" ]] || continue
    blob="$(locate_upload_blob "$uploads_root" "$location_id")"
    dest="${decoded}/files/${location_id}"
    if [[ -e "$dest" ]]; then
      die "duplicate location-id in \$files.jsonl: ${location_id}"
    fi
    cp "$blob" "$dest"
  done < <(extract_location_ids "$files_jsonl")
}

write_restore_zip() {
  local assembled="$1"
  local output="$2"
  local tmp
  local -a entities=() files=()

  [[ -f "${assembled}/config.json" ]] || die "assembled export is missing config.json"
  mkdir -p "$(dirname "$output")"
  tmp="${output}.tmp.$$"
  rm -f "$tmp"

  if [[ -d "${assembled}/entities" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      entities+=("${file#./}")
    done < <(cd "$assembled" && find entities -maxdepth 1 -type f -name '*.jsonl' | LC_ALL=C sort)
  fi
  if [[ -d "${assembled}/files" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      files+=("${file#./}")
    done < <(cd "$assembled" && find files -maxdepth 1 -type f | LC_ALL=C sort)
  fi

  (
    cd "$assembled"
    zip -X -D -q "$tmp" config.json
    if [[ ${#entities[@]} -gt 0 ]]; then
      zip -X -D -q "$tmp" "${entities[@]}"
    fi
    if [[ ${#files[@]} -gt 0 ]]; then
      zip -X -D -q "$tmp" "${files[@]}"
    fi
  )
  mv -f "$tmp" "$output"
}

default_export_name() {
  local backup_id="$1"

  printf '%s-%s.zip' "$EXPORT_APP_ID" "$backup_id"
}

resolve_output_path() {
  local backup_id="$1"
  local name

  name="$(default_export_name "$backup_id")"
  if [[ -z "$EXPORT_OUTPUT" ]]; then
    printf '%s/%s' "$EXPORTS_DIR" "$name"
    return
  fi
  if [[ -d "$EXPORT_OUTPUT" || "$EXPORT_OUTPUT" == */ ]]; then
    printf '%s/%s' "${EXPORT_OUTPUT%/}" "$name"
    return
  fi
  printf '%s' "$EXPORT_OUTPUT"
}

refuse_overwrite() {
  local output="$1"

  if [[ -e "$output" && "$EXPORT_FORCE" != "yes" ]]; then
    die "refusing to overwrite existing ZIP ${output}. Pass --force to replace it."
  fi
}

require_recovery_repo() {
  validate_recovery_env
  if ! restic_repo_exists; then
    die "restic repository does not exist at ${RESTIC_REPOSITORY}"
  fi
}

list_snapshots() {
  require_recovery_repo
  restic_cmd snapshots
}

restore_app_prefixes() {
  local dest="$1"
  local snapshot="$2"

  mkdir -p "$dest"
  log "restoring app ${EXPORT_APP_ID} from snapshot ${snapshot}"
  restic_cmd restore "$snapshot" --target "$dest" \
    --include "${DATA_DIR}/minio-app-backups/${EXPORT_APP_ID}" \
    --include "${DATA_DIR}/minio/${EXPORT_APP_ID}"
}

cleanup_export_work() {
  if [[ -n "${EXPORT_WORK_DIR:-}" && -d "$EXPORT_WORK_DIR" ]]; then
    rm -rf "$EXPORT_WORK_DIR"
  fi
}

export_app_from_trees() {
  local app_backups_root="$1"
  local uploads_root="$2"
  local output="$3"
  local selected decoded backup_id

  selected="$(select_backup_dir "$app_backups_root" "$EXPORT_BACKUP_PREFIX")"
  backup_id="$(basename "$selected")"
  if [[ -z "$output" ]]; then
    output="$(resolve_output_path "$backup_id")"
  fi
  refuse_overwrite "$output"

  decoded="${EXPORT_WORK_DIR:-$(mktemp -d)}/decoded"
  mkdir -p "$decoded"
  log "using dashboard backup ${backup_id}"
  decode_backup_dir "$selected" "$decoded"
  collect_storage_files "$decoded" "$uploads_root"
  write_restore_zip "$decoded" "$output"
  EXPORT_ZIP_PATH="$output"
  log "wrote Instant restore ZIP ${output}"
}

main() {
  local root app_backups uploads

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ "${1:-}" == "list" ]]; then
    require_cmd restic
    list_snapshots
    return
  fi

  parse_export_args "$@"
  require_cmd restic zstd zip jq find od
  require_recovery_repo
  ensure_dirs

  EXPORT_WORK_DIR="$(mktemp -d "${RESTORE_DIR}/export-XXXXXX")"
  trap cleanup_export_work EXIT

  restore_app_prefixes "$EXPORT_WORK_DIR" "$EXPORT_SNAPSHOT"
  root="$(restored_data_root "$EXPORT_WORK_DIR")"
  app_backups="${root}/minio-app-backups/${EXPORT_APP_ID}"
  uploads="${root}/minio/${EXPORT_APP_ID}"
  export_app_from_trees "$app_backups" "$uploads" ""
  log "export complete: ${EXPORT_ZIP_PATH}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
