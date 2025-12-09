#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")

#-------------------#
# Helper Functions  #
#-------------------#

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

    local input_file_name=$(echo "$input_file" | sed 's/\/app\///g')
    local output_file_name=$(echo "$output_file" | sed 's/\/app\///g')

    echo "# Encrypting file: $input_file_name."

    openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$password" -in "$input_file" -out "$output_file"

    if [ $? -ne 0 ]; then
        echo "✕ Error: Failed to encrypt file $input_file."
        exit 1
    fi

    echo "# Encryption successful: $output_file_name."
}

decrypt_file() {
    local input_file="$1"
    local output_file="$2"
    local password="$3"

    local input_file_name=$(echo "$input_file" | sed 's/\/app\///g')
    local output_file_name=$(echo "$output_file" | sed 's/\/app\///g')

    echo "# Decrypting file: $input_file_name."

    openssl enc -aes-256-cbc -d -pbkdf2 -pass pass:"$password" -in "$input_file" -out "$output_file"

    if [ $? -ne 0 ]; then
        echo "✕ Error: Failed to decrypt file $input_file."
        exit 1
    fi

    echo "# Decryption successful: $output_file_name."
}

export_attachments() {
    local session="$1"
    local items_json="$2"
    local dest_folder="$3"

    local items_with_attachments
    items_with_attachments=$(jq -c '.items[] | select(.attachments != null and (.attachments | length) > 0)' "$items_json")

    if [ -z "$items_with_attachments" ]; then
        return 0
    fi

    local total_items
    total_items=$(wc -l <<< "$items_with_attachments")

    echo "# Exporting attachments from $total_items items..."

    # Create all directories first
    while IFS= read -r item_data; do
        local item_id
        item_id=$(jq -r '.id' <<< "$item_data")
        mkdir -p "$dest_folder/$item_id"
    done <<< "$items_with_attachments"

    # Build list of attachments to download with item_id, att_id, att_name
    local download_list
    download_list=$(mktemp)

    while IFS= read -r item_data; do
        local item_id
        item_id=$(jq -r '.id' <<< "$item_data")

        jq -r --arg item_id "$item_id" '.attachments[] | "\($item_id)\t\(.id)\t\(.fileName)"' <<< "$item_data"
    done <<< "$items_with_attachments" > "$download_list"

    # Download attachments in parallel
    cat "$download_list" | xargs -P 200 -I {} bash -c '
        IFS=$'"'"'\t'"'"' read -r item_id att_id att_name <<< "{}"
        att_dest="'"$dest_folder"'/$item_id/$att_name"
        if [ ! -e "$att_dest" ]; then
            bw --session "'"$session"'" get attachment "$att_id" --itemid "$item_id" --output "$att_dest" --raw 2>/dev/null
        fi
    '

    rm -f "$download_list"
}

restore_attachments() {
    local session="$1"
    local attachments_folder="$2"

    if [ ! -d "$attachments_folder" ] || [ -z "$(ls -A "$attachments_folder" 2>/dev/null)" ]; then
        return 0
    fi

    local total_items
    total_items=$(find "$attachments_folder" -mindepth 1 -maxdepth 1 -type d | wc -l)

    if [ "$total_items" -eq 0 ]; then
        return 0
    fi

    echo "# Restoring attachments for $total_items items..."

    # Build list of attachments to upload: item_id, att_file_path
    local upload_list
    upload_list=$(mktemp)

    for item_dir in "$attachments_folder"/*; do
        if [ ! -d "$item_dir" ]; then
            continue
        fi

        local item_id
        item_id=$(basename "$item_dir")

        for att_file in "$item_dir"/*; do
            if [ -f "$att_file" ]; then
                echo "$item_id"$'\t'"$att_file" >> "$upload_list"
            fi
        done
    done

    # Upload attachments in parallel
    cat "$upload_list" | xargs --verbose -P 10 -I {} bash -c '
        IFS=$'"'"'\t'"'"' read -r item_id att_file <<< "{}"
        bw --session "'"$session"'" create attachment --file "$att_file" --itemid "$item_id" 2>/dev/null
    '

    rm -f "$upload_list"
}

purge_folder() {
    local folder_path="$1"
    local max_files="$2"
    local retention_days="$3"

    local folder_name=$(echo "$folder_path" | sed 's/\/app\///g')

    if [ "$ENABLE_PRUNING" == "false" ]; then
        echo "# Pruning disabled, skipping..."
        return
    elif [ "$ENABLE_PRUNING" != "true" ]; then
        echo "The var ENABLE_PRUNING is invalid (only 'true' or 'false' is accepted): $ENABLE_PRUNING"
        exit 1
    fi

    echo "# Purging files in folder: $folder_name."

    # Find all files in the folder sorted by modification time (oldest first)
    all_files=$(find "$folder_path" -type f -printf "%T@ %p\n" | sort -n)

    # Find files older than the retention period
    old_files=$(find "$folder_path" -type f -mtime +"$retention_days")

    # Find files newer than the retention period
    recent_files=$(find "$folder_path" -type f -mtime -"$retention_days")

    # Check if there are no files in the folder
    if [ -z "$all_files" ]; then
        echo "# No files found in the folder: $folder_path. Nothing to purge."
        return
    fi

    # Case 1: If there are recent files, delete only the files older than retention_days
    if [ -n "$recent_files" ]; then
        if [ -n "$old_files" ]; then
            echo "# Found files modified within the last $retention_days days. Deleting only older files..."
            find "$folder_path" -type f -mtime +"$retention_days" -exec rm -f {} +
        else
            echo "# No files older than $retention_days days to delete. Nothing to purge."
        fi
    else
        # Case 2: If all files are older than retention_days, keep only the most recent max_files files
        echo "# All files are older than $retention_days days. Keeping the most recent $max_files files..."
        echo "$all_files" | head -n -"$max_files" | awk '{print $2}' | xargs -I{} rm -f "{}"
    fi

    echo "# Purge completed for $folder_name."
}

cleanup_unencrypted() {
    echo "# Cleaning up all unencrypted backup files from temporary folder ($TEMP_FOLDER)..."
    rm -f "$TEMP_FOLDER"/*.json
    rm -rf "$ATTACHMENTS_FOLDER"
}

# Set traps to ensure cleanup is performed on exit or error
trap cleanup_unencrypted SIGINT SIGTERM EXIT


#------#
# INIT #
#------#

# Create folder if not exists
SOURCE_FOLDER="/app/backups/source"
DEST_FOLDER="/app/backups/dest"

mkdir -p "$SOURCE_FOLDER"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to create folder /backups/source."
    exit 1
fi

mkdir -p "$DEST_FOLDER"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to create folder /backups/dest."
    exit 1
fi

# Create temporary folder for unencrypted files
TEMP_FOLDER="/tmp/bitwarden_unencrypted"
mkdir -p "$TEMP_FOLDER"
if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to create temporary folder $TEMP_FOLDER."
    exit 1
fi

# Create temporary folder for attachments
ATTACHMENTS_FOLDER="$TEMP_FOLDER/attachments"
mkdir -p "$ATTACHMENTS_FOLDER"
if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to create attachments folder $ATTACHMENTS_FOLDER."
    exit 1
fi

# Clean up any existing unencrypted backup files from TEMP_FOLDER
echo "# Cleaning up any existing unencrypted backup files..."
rm -f "$TEMP_FOLDER"/*.json
rm -rf "$ATTACHMENTS_FOLDER"/*

echo "########## Start of Backup process ##########"

echo "# Fixing permissions on backups folder..."
fix_permissions "$PUID" "$PGID" "/app/backups"

sleep 1


#--------#
# BACKUP #
#--------#

echo "# Start Time: $(date)"

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_source_"
SOURCE_NEW_FILENAME="$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json"
# Unencrypted file stored in temporary folder
SOURCE_OUTPUT_FILE_PATH="$TEMP_FOLDER/$SOURCE_NEW_FILENAME"
# Encrypted file stored in source backup folder
ENCRYPTED_SOURCE_OUTPUT_FILE_PATH="$SOURCE_FOLDER/$SOURCE_NEW_FILENAME.enc"


#--------------#
# SOURCE PURGE #
#--------------#

purge_folder "$SOURCE_FOLDER" "$MIN_FILES" "$RETENTION_DAYS"
sleep 1


#--------------#
# SOURCE LOGIN #
#--------------#

# Lets make sure we're logged out before we start
echo "# Logging out from Bitwarden..."
bw logout >/dev/null

export BW_CLIENTID=${SOURCE_CLIENT_ID}
export BW_CLIENTSECRET=${SOURCE_CLIENT_SECRET}

# Login to our Server
echo "# Logging into Source server..."
bw config server "$SOURCE_SERVER"

bw login "$SOURCE_ACCOUNT" --apikey --raw

if [ $? -ne 0 ]; then
    printf "\n"
    echo "✕ Error: Failed to log in to source server with account ${SOURCE_ACCOUNT} at ${SOURCE_SERVER}."
    exit 1
fi

printf '\n'

# By using an API Key, we need to unlock the vault to get a sessionID
echo "# Unlocking the vault..."
SOURCE_SESSION=$(bw unlock "$SOURCE_PASSWORD" --raw)

if [ -z "$SOURCE_SESSION" ]; then
    echo "✕ Error: No source session retrieved. Check your source credentials and try again."
    exit 1
fi

# Synchronizing the vault
echo "# Synchronizing the vault..."
bw sync --session "$SOURCE_SESSION"
printf '\n'


#---------------#
# SOURCE EXPORT #
#---------------#

echo "# Exporting all items..."
bw --session "$SOURCE_SESSION" export --raw --format json > "$SOURCE_OUTPUT_FILE_PATH"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to export data."
    exit 1
fi

fix_permissions "$PUID" "$PGID" "$SOURCE_OUTPUT_FILE_PATH"

# Export list of items with attachment metadata
SOURCE_ITEMS_LIST="$TEMP_FOLDER/bw_items_source_$TIMESTAMP.json"
echo "# Exporting item list (for attachment metadata)..."
bw --session "$SOURCE_SESSION" list items > "$SOURCE_ITEMS_LIST"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to list items."
    exit 1
fi

# Wrap items list in export format for export_attachments function
SOURCE_ITEMS_WRAPPED="$TEMP_FOLDER/bw_items_wrapped_$TIMESTAMP.json"
jq '{items: .}' "$SOURCE_ITEMS_LIST" > "$SOURCE_ITEMS_WRAPPED"

# Export attachments
SOURCE_ATTACHMENTS_FOLDER="$ATTACHMENTS_FOLDER/source"
mkdir -p "$SOURCE_ATTACHMENTS_FOLDER"
export_attachments "$SOURCE_SESSION" "$SOURCE_ITEMS_WRAPPED" "$SOURCE_ATTACHMENTS_FOLDER"

#-----------------------#
# SOURCE EXPORT ENCRYPT #
#-----------------------#

# Create tarball with export and attachments
SOURCE_TARBALL="$TEMP_FOLDER/bw_backup_source_$TIMESTAMP.tar.gz"
echo "# Creating backup tarball with attachments..."
tar -czf "$SOURCE_TARBALL" -C "$TEMP_FOLDER" "$(basename "$SOURCE_OUTPUT_FILE_PATH")" -C "$ATTACHMENTS_FOLDER" source 2>/dev/null || tar -czf "$SOURCE_TARBALL" -C "$TEMP_FOLDER" "$(basename "$SOURCE_OUTPUT_FILE_PATH")"

# Encrypt the tarball
encrypt_file "$SOURCE_TARBALL" "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
fix_permissions "$PUID" "$PGID" "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH"

# Remove the unencrypted files
echo "# Removed unencrypted files."
rm -f "$SOURCE_OUTPUT_FILE_PATH" "$SOURCE_ITEMS_LIST" "$SOURCE_ITEMS_WRAPPED" "$SOURCE_TARBALL"
rm -rf "$SOURCE_ATTACHMENTS_FOLDER"

sleep 1

#---------------#
# SOURCE LOGOUT #
#---------------#
echo "# Locking the vault..."
bw lock
echo ""

# Logout
echo "# Logging out from Bitwarden..."
bw logout >/dev/null

unset BW_CLIENTID
unset BW_CLIENTSECRET

echo "########## End of Backup process ##########"

sleep 1


#---------#
# RESTORE #
#---------#

# Restoring process
echo "########## Start of Restore process ##########"

# We want to remove items later, so we set a base filename now
DEST_EXPORT_OUTPUT_BASE="bw_export_dest_"
DEST_NEW_FILENAME="$DEST_EXPORT_OUTPUT_BASE$TIMESTAMP.json"
# Unencrypted file stored in temporary folder
DEST_OUTPUT_FILE_PATH="$TEMP_FOLDER/$DEST_NEW_FILENAME"
# Encrypted file stored in destination backup folder
ENCRYPTED_DEST_OUTPUT_FILE_PATH="$DEST_FOLDER/$DEST_NEW_FILENAME.enc"


#------------#
# DEST PURGE #
#------------#

purge_folder "$DEST_FOLDER" "$MIN_FILES" "$RETENTION_DAYS"
sleep 1

#------------#
# DEST LOGIN #
#------------#

export BW_CLIENTID=${DEST_CLIENT_ID}
export BW_CLIENTSECRET=${DEST_CLIENT_SECRET}

# Login to our Server
echo "# Logging into Dest server..."
bw config server "$DEST_SERVER"

bw login "$DEST_ACCOUNT" --apikey --raw

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to log in to destination server with account ${DEST_ACCOUNT} at ${DEST_SERVER}."
    exit 1
fi

printf '\n'

# By using an API Key, we need to unlock the vault to get a sessionID
echo "# Unlocking the vault..."
DEST_SESSION=$(bw unlock "$DEST_PASSWORD" --raw)

if [ -z "$DEST_SESSION" ]; then
    echo "✕ Error: No destination session retrieved. Check your destination credentials and try again."
    exit 1
fi

# Synchronizing the vault
echo "# Synchronizing the vault..."
bw sync --session "$DEST_SESSION"
printf '\n'


#-------------#
# DEST EXPORT #
#-------------#

# Export what's currently in the vault, so we can remove it
echo "# Exporting current items from destination vault..."
bw --session "$DEST_SESSION" export --raw --format json > "$DEST_OUTPUT_FILE_PATH"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to export data."
    exit 1
fi

fix_permissions "$PUID" "$PGID" "$DEST_OUTPUT_FILE_PATH"

#---------------------#
# DEST EXPORT ENCRYPT #
#---------------------#

# Encrypt the exported file
echo "# Encrypting exported file..."
encrypt_file "$DEST_OUTPUT_FILE_PATH" "$ENCRYPTED_DEST_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
fix_permissions "$PUID" "$PGID" "$ENCRYPTED_DEST_OUTPUT_FILE_PATH"

sleep 1

#-----------------#
# DEST REMOVE OLD #
#-----------------#

echo "# Purging destination vault via bw-purge-vault.sh..."
if ! bash "$SCRIPT_DIR/bw-purge-vault.sh" \
  --server "$DEST_SERVER" \
  --api-client-id "$DEST_CLIENT_ID" \
  --api-client-secret "$DEST_CLIENT_SECRET" \
  --email "$DEST_ACCOUNT" \
  --master-password "$DEST_PASSWORD"
then
  echo "✕ Error: Failed to purge destination vault." >&2
  exit 1
fi

# Remove the unencrypted file
echo "# Removed unencrypted file"
rm -f "$DEST_OUTPUT_FILE_PATH"

sleep 1

#---------------------------#
# DEST IMPORT SOURCE BACKUP #
#---------------------------#

# Restoring from source backup (encrypted)
DEST_LATEST_BACKUP="$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH"
# Decrypted tarball stored in temporary folder
DECRYPTED_SOURCE_TARBALL="$TEMP_FOLDER/bw_backup_source_$TIMESTAMP.tar.gz"

# Decrypt the latest backup
echo "# Decrypting the latest backup..."
decrypt_file "$DEST_LATEST_BACKUP" "$DECRYPTED_SOURCE_TARBALL" "$ENCRYPTION_PASSWORD"
fix_permissions "$PUID" "$PGID" "$DECRYPTED_SOURCE_TARBALL"

# Extract the tarball
echo "# Extracting backup tarball..."
RESTORE_EXTRACT_DIR="$TEMP_FOLDER/restore_extract"
mkdir -p "$RESTORE_EXTRACT_DIR"
tar -xzf "$DECRYPTED_SOURCE_TARBALL" -C "$RESTORE_EXTRACT_DIR"

# Find the JSON export file
DECRYPTED_SOURCE_OUTPUT_FILE_PATH=$(find "$RESTORE_EXTRACT_DIR" -name "bw_export_source_*.json" | head -n 1)

if [ -z "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH" ] || [ ! -f "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH" ]; then
    echo "✕ Error: Could not find JSON export in backup."
    exit 1
fi

# Import the decrypted backup
echo "# Importing the decrypted backup: $DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
bw --session "$DEST_SESSION" --raw import bitwardenjson "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to import data."
    exit 1
fi

echo "# Decrypted backup imported."

# Restore attachments if they exist
RESTORE_ATTACHMENTS_FOLDER="$RESTORE_EXTRACT_DIR/source"
if [ -d "$RESTORE_ATTACHMENTS_FOLDER" ]; then
    restore_attachments "$DEST_SESSION" "$RESTORE_ATTACHMENTS_FOLDER"
fi

# Remove the decrypted files
rm -f "$DECRYPTED_SOURCE_TARBALL"
rm -rf "$RESTORE_EXTRACT_DIR"
echo "# Cleanup completed."


#-------------#
# DEST LOGOUT #
#-------------#

echo "# Locking the vault and logout from destination server..."
bw lock > /dev/null

bw logout > /dev/null

echo "########## End of Restore Process ##########"

unset BW_CLIENTID
unset BW_CLIENTSECRET
