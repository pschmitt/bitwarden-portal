#!/usr/bin/env bash

set -euo pipefail

if [ -n "${DEBUG:-}" ]
then
  set -x
fi

MODE="${MODE:-default}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date "+%Y-%m-%d_%H-%M-%S")"
export BW_NOINTERACTIVE="true"

ENABLE_PRUNING="${ENABLE_PRUNING:-true}"
MIN_FILES="${MIN_FILES:-5}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
PUID="${PUID:-0}"
PGID="${PGID:-0}"

SOURCE_FOLDER="/app/backups/source"
DEST_FOLDER="/app/backups/dest"
TEMP_FOLDER="/tmp/bitwarden_unencrypted"
ATTACHMENTS_FOLDER="$TEMP_FOLDER/attachments"
RESTORE_EXTRACT_DIR="$TEMP_FOLDER/restore_extract"

SOURCE_EXPORT_FILENAME="bw_export_source_${TIMESTAMP}.json"
SOURCE_EXPORT_FILE_PATH="$TEMP_FOLDER/$SOURCE_EXPORT_FILENAME"
ENCRYPTED_SOURCE_OUTPUT_FILE_PATH="$SOURCE_FOLDER/${SOURCE_EXPORT_FILENAME}.enc"
SOURCE_TARBALL="$TEMP_FOLDER/bw_backup_source_${TIMESTAMP}.tar.gz"
DECRYPTED_SOURCE_TARBALL="$TEMP_FOLDER/bw_backup_source_${TIMESTAMP}_decrypted.tar.gz"
SOURCE_ATTACHMENTS_FOLDER="$ATTACHMENTS_FOLDER/source"

DEST_EXPORT_FILENAME="bw_export_dest_${TIMESTAMP}.json"
DEST_OUTPUT_FILE_PATH="$TEMP_FOLDER/$DEST_EXPORT_FILENAME"
ENCRYPTED_DEST_OUTPUT_FILE_PATH="$DEST_FOLDER/${DEST_EXPORT_FILENAME}.enc"

DECRYPTED_SOURCE_OUTPUT_FILE_PATH=""
RESTORE_ATTACHMENTS_FOLDER=""

COLOR_RESET=""
COLOR_INFO=""
COLOR_WARN=""
COLOR_ERROR=""
COLOR_OK=""

set_bw_env() {
  local label="$1"
  local appdata_dir
  appdata_dir="$TEMP_FOLDER/bw_cli_${label}"

  export BITWARDENCLI_APPDATA_DIR="$appdata_dir"
  export BW_CONFIG_DIR="$appdata_dir"
  export XDG_CONFIG_HOME="$appdata_dir"
  export HOME="$appdata_dir"
}

set_bw_session_env() {
  local session="$1"
  export BW_SESSION="$session"
  export BW_NOINTERACTIVE="true"
}

usage() {
  cat <<'EOF'
Usage: bitwarden-portal.sh [--mode default|backup|sync] [--help]

Modes:
  default  Backup source + destination and restore source data into destination (previous behavior).
  backup   Only create backups for source and destination vaults.
  sync     Synchronize source to destination without creating backups.
EOF
}

setup_colors() {
  if [ -t 1 ]
  then
    COLOR_RESET="\033[0m"
    COLOR_INFO="\033[34m"
    COLOR_WARN="\033[33m"
    COLOR_ERROR="\033[31m"
    COLOR_OK="\033[32m"
  fi
}

log_info() {
  printf "%b# %s%b\n" "$COLOR_INFO" "$1" "$COLOR_RESET" >&2
}

log_warn() {
  printf "%b! %s%b\n" "$COLOR_WARN" "$1" "$COLOR_RESET" >&2
}

log_error() {
  printf "%b✕ %s%b\n" "$COLOR_ERROR" "$1" "$COLOR_RESET" >&2
}

log_ok() {
  printf "%b✓ %s%b\n" "$COLOR_OK" "$1" "$COLOR_RESET" >&2
}

log_section() {
  printf "%b########## %s ##########%b\n" "$COLOR_INFO" "$1" "$COLOR_RESET" >&2
}

parse_args() {
  while [ $# -gt 0 ]
  do
    case "$1" in
      --mode)
        MODE="$2"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

validate_mode() {
  case "$MODE" in
    default|backup|sync)
      ;;
    *)
      log_error "Invalid mode: $MODE"
      usage
      exit 1
      ;;
  esac
}

ensure_required_vars() {
  local missing=0
  for var in SOURCE_SERVER SOURCE_ACCOUNT SOURCE_PASSWORD SOURCE_CLIENT_ID SOURCE_CLIENT_SECRET DEST_SERVER DEST_ACCOUNT DEST_PASSWORD DEST_CLIENT_ID DEST_CLIENT_SECRET
  do
    if [ -z "${!var:-}" ]
    then
      log_error "Missing environment variable: $var"
      missing=1
    fi
  done

  if [ "$MODE" != "sync" ] && [ -z "${ENCRYPTION_PASSWORD:-}" ]
  then
    log_error "Missing environment variable: ENCRYPTION_PASSWORD"
    missing=1
  fi

  if [ "$missing" -eq 1 ]
  then
    exit 1
  fi
}

ensure_directories() {
  mkdir -p "$SOURCE_FOLDER"
  mkdir -p "$DEST_FOLDER"
  mkdir -p "$TEMP_FOLDER"
  mkdir -p "$ATTACHMENTS_FOLDER"
  mkdir -p "$RESTORE_EXTRACT_DIR"
}

cleanup_unencrypted() {
  log_info "Cleaning up temporary files..."
  rm -f "$TEMP_FOLDER"/*.json
  rm -f "$TEMP_FOLDER"/*.tar.gz
  rm -rf "$ATTACHMENTS_FOLDER"
  rm -rf "$RESTORE_EXTRACT_DIR"
}

fix_permissions() {
  local puid="$1"
  local pgid="$2"
  local folder="$3"
  chown -R "$puid:$pgid" "$folder"
}

encrypt_file() {
  local input_file="$1"
  local output_file="$2"
  local password="$3"

  local input_file_name="${input_file#/app/}"
  local output_file_name="${output_file#/app/}"

  log_info "Encrypting file: $input_file_name"

  if ! openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:$password" -in "$input_file" -out "$output_file"
  then
    log_error "Failed to encrypt file $input_file."
    exit 1
  fi

  log_ok "Encryption successful: $output_file_name"
}

decrypt_file() {
  local input_file="$1"
  local output_file="$2"
  local password="$3"

  local input_file_name="${input_file#/app/}"
  local output_file_name="${output_file#/app/}"

  log_info "Decrypting file: $input_file_name"

  if ! openssl enc -aes-256-cbc -d -pbkdf2 -pass "pass:$password" -in "$input_file" -out "$output_file"
  then
    log_error "Failed to decrypt file $input_file."
    exit 1
  fi

  log_ok "Decryption successful: $output_file_name"
}

export_attachments() {
  local session="$1"
  local items_json="$2"
  local dest_folder="$3"

  local items_with_attachments
  items_with_attachments=$(jq -c '.items[] | select(.attachments != null and (.attachments | length) > 0)' "$items_json")

  if [ -z "$items_with_attachments" ]
  then
    return 0
  fi

  local total_items
  total_items=$(wc -l <<< "$items_with_attachments")

  log_info "Exporting attachments from $total_items items..."

  while IFS= read -r item_data
  do
    local item_id
    item_id=$(jq -r '.id' <<< "$item_data")
    mkdir -p "$dest_folder/$item_id"
  done <<< "$items_with_attachments"

  local download_list
  download_list=$(mktemp)

  while IFS= read -r item_data
  do
    local item_id
    item_id=$(jq -r '.id' <<< "$item_data")
    jq -r --arg item_id "$item_id" '.attachments[] | "\($item_id)\t\(.id)\t\(.fileName)"' <<< "$item_data"
  done <<< "$items_with_attachments" > "$download_list"

  while IFS=$'\t' read -r item_id att_id att_name
  do
    local att_dest="$dest_folder/$item_id/$att_name"
    if [ ! -e "$att_dest" ]
    then
      if ! BW_SESSION="$session" BW_NOINTERACTIVE="true" bw --session "$session" get attachment "$att_id" --itemid "$item_id" --output "$att_dest" --raw
      then
        echo "Failed to download attachment $att_name for item $item_id" >&2
      fi
    fi
  done < "$download_list"

  rm -f "$download_list"
}

restore_attachments() {
  local label="$1"
  local session="$2"
  local attachments_folder="$3"
  local mapping_file="$4"

  set_bw_env "$label"
  set_bw_session_env "$session"

  if [ ! -d "$attachments_folder" ] || [ -z "$(ls -A "$attachments_folder")" ]
  then
    return 0
  fi

  local total_items
  total_items=$(find "$attachments_folder" -mindepth 1 -maxdepth 1 -type d | wc -l)

  if [ "$total_items" -eq 0 ]
  then
    return 0
  fi

  log_info "Restoring attachments for $total_items items..."

  declare -A id_map
  if [ -n "$mapping_file" ] && [ -f "$mapping_file" ]
  then
    while IFS=$'\t' read -r src_id dst_id
    do
      id_map["$src_id"]="$dst_id"
    done < "$mapping_file"
  fi

  local upload_list
  upload_list=$(mktemp)

  for item_dir in "$attachments_folder"/*
  do
    if [ ! -d "$item_dir" ]
    then
      continue
    fi

    local source_item_id
    source_item_id=$(basename "$item_dir")
    local dest_item_id="$source_item_id"

    if [ -n "$mapping_file" ]
    then
      if [ -n "${id_map[$source_item_id]:-}" ]
      then
        dest_item_id="${id_map[$source_item_id]}"
      else
        log_warn "Could not find destination item for source item $source_item_id. Skipping attachments."
        continue
      fi
    fi

    for att_file in "$item_dir"/*
    do
      if [ -f "$att_file" ]
      then
        printf "%s\t%s\n" "$dest_item_id" "$att_file" >> "$upload_list"
      fi
    done
  done

  while IFS=$'\t' read -r item_id att_file
  do
    BW_SESSION="$session" BW_NOINTERACTIVE="true" bw --session "$session" create attachment --file "$att_file" --itemid "$item_id"
  done < "$upload_list"

  rm -f "$upload_list"
}

purge_folder() {
  local folder_path="$1"
  local max_files="$2"
  local retention_days="$3"

  local folder_name="${folder_path#/app/}"

  if [ "$ENABLE_PRUNING" = "false" ]
  then
    log_info "Pruning disabled, skipping for $folder_name."
    return
  elif [ "$ENABLE_PRUNING" != "true" ]
  then
    log_error "ENABLE_PRUNING must be 'true' or 'false': $ENABLE_PRUNING"
    exit 1
  fi

  log_info "Purging files in folder: $folder_name"

  local all_files
  all_files=$(find "$folder_path" -type f -printf "%T@ %p\n" | sort -n)

  local old_files
  old_files=$(find "$folder_path" -type f -mtime +"$retention_days")

  local recent_files
  recent_files=$(find "$folder_path" -type f -mtime -"$retention_days")

  if [ -z "$all_files" ]
  then
    log_info "No files found in folder: $folder_path. Nothing to purge."
    return
  fi

  if [ -n "$recent_files" ]
  then
    if [ -n "$old_files" ]
    then
      log_info "Deleting files older than $retention_days days..."
      find "$folder_path" -type f -mtime +"$retention_days" -exec rm -f {} +
    else
      log_info "No files older than $retention_days days to delete."
    fi
  else
    log_info "All files are older than $retention_days days. Keeping the most recent $max_files files..."
    echo "$all_files" | head -n -"$max_files" | awk '{print $2}' | xargs -I{} rm -f "{}"
  fi

  log_ok "Purge completed for $folder_name."
}

bw_login() {
  local label="$1"
  local server="$2"
  local account="$3"
  local client_id="$4"
  local client_secret="$5"
  local password="$6"
  set_bw_env "$label"
  bw logout >&2 || true

  export BW_CLIENTID="$client_id"
  export BW_CLIENTSECRET="$client_secret"

  log_info "Configuring $label server: $server"
  bw config server "$server" >&2

  log_info "Logging into $label..."
  if ! bw login "$account" --apikey --raw >/tmp/bw_login_output 2>&1
  then
    cat /tmp/bw_login_output >&2 || true
    log_error "Failed to log in to $label server with account $account at $server."
    exit 1
  fi
  rm -f /tmp/bw_login_output

  log_info "Unlocking the $label vault..."
  local session
  session=$(bw unlock "$password" --raw | awk 'NF {last=$0} END {print last}' | tr -d '\r')

  if [ -z "$session" ]
  then
    log_error "No $label session retrieved. Check your credentials."
    exit 1
  fi

  log_info "Synchronizing the $label vault..."
  BW_SESSION="$session" BW_NOINTERACTIVE="true" bw sync --session "$session" >&2

  local session_var
  session_var="$(printf "%s_SESSION" "$(echo "$label" | tr '[:lower:]' '[:upper:]')" )"
  export "$session_var=$session"
  export BW_SESSION="$session"
}

bw_logout() {
  log_info "Locking and logging out..."
  bw lock >&2 || true
  bw logout >&2 || true
  unset BW_CLIENTID
  unset BW_CLIENTSECRET
  unset BW_SESSION
  unset BITWARDENCLI_APPDATA_DIR
  unset BW_CONFIG_DIR
  unset XDG_CONFIG_HOME
  unset HOME
}

export_items_with_attachments() {
  local label="$1"
  local session="$2"
  local export_path="$3"
  local attachments_dir="$4"

  set_bw_env "$label"
  set_bw_session_env "$session"

  log_info "Exporting all items..."
  bw --session "$session" export --raw --format json > "$export_path"
  fix_permissions "$PUID" "$PGID" "$export_path"

  local items_list
  items_list=$(mktemp "$TEMP_FOLDER/items_list_XXXX.json")
  local items_wrapped
  items_wrapped=$(mktemp "$TEMP_FOLDER/items_wrapped_XXXX.json")

  log_info "Exporting item list (for attachment metadata)..."
  bw --session "$session" list items > "$items_list"
  jq '{items: .}' "$items_list" > "$items_wrapped"

  mkdir -p "$attachments_dir"
  export_attachments "$session" "$items_wrapped" "$attachments_dir"

  rm -f "$items_list" "$items_wrapped"
}

create_backup_tarball() {
  local export_file="$1"
  local attachments_dir="$2"
  local tarball="$3"

  log_info "Creating backup tarball..."

  if [ -d "$attachments_dir" ] && [ -n "$(find "$attachments_dir" -mindepth 1 -maxdepth 1 | head -n 1)" ]
  then
    tar -czf "$tarball" -C "$TEMP_FOLDER" "$(basename "$export_file")" -C "$ATTACHMENTS_FOLDER" "$(basename "$attachments_dir")"
  else
    tar -czf "$tarball" -C "$TEMP_FOLDER" "$(basename "$export_file")"
  fi
}

backup_source() {
  log_section "Start of Backup process"
  log_info "Fixing permissions on backups folder..."
  fix_permissions "$PUID" "$PGID" "/app/backups"

  purge_folder "$SOURCE_FOLDER" "$MIN_FILES" "$RETENTION_DAYS"

  bw_login "source" "$SOURCE_SERVER" "$SOURCE_ACCOUNT" "$SOURCE_CLIENT_ID" "$SOURCE_CLIENT_SECRET" "$SOURCE_PASSWORD"
  local source_session="$BW_SESSION"

  export_items_with_attachments "source" "$source_session" "$SOURCE_EXPORT_FILE_PATH" "$SOURCE_ATTACHMENTS_FOLDER"
  create_backup_tarball "$SOURCE_EXPORT_FILE_PATH" "$SOURCE_ATTACHMENTS_FOLDER" "$SOURCE_TARBALL"
  encrypt_file "$SOURCE_TARBALL" "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
  fix_permissions "$PUID" "$PGID" "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH"

  log_info "Cleaning source unencrypted export and tarball."
  rm -f "$SOURCE_EXPORT_FILE_PATH" "$SOURCE_TARBALL"
  rm -rf "$SOURCE_ATTACHMENTS_FOLDER"

  bw_logout
  log_section "End of Backup process"
}

backup_destination_vault() {
  local dest_session="$1"
  set_bw_env "destination"
  set_bw_session_env "$dest_session"

  purge_folder "$DEST_FOLDER" "$MIN_FILES" "$RETENTION_DAYS"

  log_info "Exporting current items from destination vault..."
  bw --session "$dest_session" export --raw --format json > "$DEST_OUTPUT_FILE_PATH"
  fix_permissions "$PUID" "$PGID" "$DEST_OUTPUT_FILE_PATH"

  log_info "Encrypting exported destination file..."
  encrypt_file "$DEST_OUTPUT_FILE_PATH" "$ENCRYPTED_DEST_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
  fix_permissions "$PUID" "$PGID" "$ENCRYPTED_DEST_OUTPUT_FILE_PATH"

  log_info "Removing unencrypted destination export."
  rm -f "$DEST_OUTPUT_FILE_PATH"
}

purge_destination_vault() {
  log_info "Purging destination vault via bw.py..."
  if ! python3 "$SCRIPT_DIR/bw.py" purge \
    --server "$DEST_SERVER" \
    --api-client-id "$DEST_CLIENT_ID" \
    --api-client-secret "$DEST_CLIENT_SECRET" \
    --email "$DEST_ACCOUNT" \
    --master-password "$DEST_PASSWORD"
  then
    log_error "Failed to purge destination vault."
    exit 1
  fi
}

decrypt_backup_payload() {
  log_info "Decrypting the latest backup..."
  decrypt_file "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH" "$DECRYPTED_SOURCE_TARBALL" "$ENCRYPTION_PASSWORD"
  fix_permissions "$PUID" "$PGID" "$DECRYPTED_SOURCE_TARBALL"

  log_info "Extracting backup tarball..."
  mkdir -p "$RESTORE_EXTRACT_DIR"
  tar -xzf "$DECRYPTED_SOURCE_TARBALL" -C "$RESTORE_EXTRACT_DIR"

  DECRYPTED_SOURCE_OUTPUT_FILE_PATH=$(find "$RESTORE_EXTRACT_DIR" -name "bw_export_source_*.json" | head -n 1)
  RESTORE_ATTACHMENTS_FOLDER="$RESTORE_EXTRACT_DIR/source"

  if [ -z "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH" ] || [ ! -f "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH" ]
  then
    log_error "Could not find JSON export in backup."
    exit 1
  fi
}

import_backup_to_destination() {
  local dest_session="$1"

  set_bw_env "destination"
  set_bw_session_env "$dest_session"

  log_info "Importing the decrypted backup: $DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
  if ! bw --session "$dest_session" --raw import bitwardenjson "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
  then
    log_error "Failed to import data."
    exit 1
  fi

  if [ -d "$RESTORE_ATTACHMENTS_FOLDER" ]
  then
    local dest_items_after_import
    dest_items_after_import=$(mktemp "$TEMP_FOLDER/dest_items_after_import_XXXX.json")
    local id_mapping_file
    id_mapping_file=$(mktemp "$TEMP_FOLDER/id_mapping_XXXX.tsv")

    log_info "Exporting destination items to map IDs..."
    bw --session "$dest_session" list items > "$dest_items_after_import"

    log_info "Generating item ID mapping..."
    python3 "$SCRIPT_DIR/bw.py" match "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH" "$dest_items_after_import" > "$id_mapping_file"

    restore_attachments "destination" "$dest_session" "$RESTORE_ATTACHMENTS_FOLDER" "$id_mapping_file"
    rm -f "$dest_items_after_import" "$id_mapping_file"
  fi

  rm -f "$DECRYPTED_SOURCE_TARBALL"
  rm -rf "$RESTORE_EXTRACT_DIR"
  log_ok "Destination import complete."
}

run_default_mode() {
  backup_source

  log_section "Start of Restore process"
  bw_login "destination" "$DEST_SERVER" "$DEST_ACCOUNT" "$DEST_CLIENT_ID" "$DEST_CLIENT_SECRET" "$DEST_PASSWORD"
  local dest_session="$BW_SESSION"

  backup_destination_vault "$dest_session"
  purge_destination_vault
  decrypt_backup_payload
  import_backup_to_destination "$dest_session"

  bw_logout
  log_section "End of Restore Process"
}

run_backup_mode() {
  backup_source
  bw_login "destination" "$DEST_SERVER" "$DEST_ACCOUNT" "$DEST_CLIENT_ID" "$DEST_CLIENT_SECRET" "$DEST_PASSWORD"
  local dest_session="$BW_SESSION"
  backup_destination_vault "$dest_session"
  bw_logout
  log_ok "Backup mode complete."
}

run_sync_mode() {
  log_section "Start of Sync process"
  log_info "Fixing permissions on backups folder..."
  fix_permissions "$PUID" "$PGID" "/app/backups"

  bw_login "source" "$SOURCE_SERVER" "$SOURCE_ACCOUNT" "$SOURCE_CLIENT_ID" "$SOURCE_CLIENT_SECRET" "$SOURCE_PASSWORD"
  local source_session="$BW_SESSION"
  export_items_with_attachments "source" "$source_session" "$SOURCE_EXPORT_FILE_PATH" "$SOURCE_ATTACHMENTS_FOLDER"
  bw_logout

  bw_login "destination" "$DEST_SERVER" "$DEST_ACCOUNT" "$DEST_CLIENT_ID" "$DEST_CLIENT_SECRET" "$DEST_PASSWORD"
  local dest_session="$BW_SESSION"
  purge_destination_vault
  set_bw_env "destination"
  set_bw_session_env "$dest_session"

  log_info "Importing source export into destination..."
  if ! bw --session "$dest_session" --raw import bitwardenjson "$SOURCE_EXPORT_FILE_PATH"
  then
    log_error "Failed to import data."
    exit 1
  fi

  if [ -d "$SOURCE_ATTACHMENTS_FOLDER" ]
  then
    local dest_items_after_import
    dest_items_after_import=$(mktemp "$TEMP_FOLDER/dest_items_after_import_XXXX.json")
    local id_mapping_file
    id_mapping_file=$(mktemp "$TEMP_FOLDER/id_mapping_XXXX.tsv")

    log_info "Exporting destination items to map IDs..."
    BW_SESSION="$dest_session" BW_NOINTERACTIVE="true" bw --session "$dest_session" list items > "$dest_items_after_import"

    log_info "Generating item ID mapping..."
    python3 "$SCRIPT_DIR/bw.py" match "$SOURCE_EXPORT_FILE_PATH" "$dest_items_after_import" > "$id_mapping_file"

    restore_attachments "destination" "$dest_session" "$SOURCE_ATTACHMENTS_FOLDER" "$id_mapping_file"
    rm -f "$dest_items_after_import" "$id_mapping_file"
  fi

  bw_logout
  log_section "End of Sync process"
}

main() {
  setup_colors
  parse_args "$@"
  validate_mode
  ensure_required_vars
  ensure_directories

  trap cleanup_unencrypted SIGINT SIGTERM EXIT

log_info "Cleaning up any existing unencrypted backup files..."
rm -f "$TEMP_FOLDER"/*.json
find "$ATTACHMENTS_FOLDER" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

case "$MODE" in
  default)
    run_default_mode
    ;;
  backup)
    run_backup_mode
    ;;
  sync)
    run_sync_mode
    ;;
esac
}

main "$@"
