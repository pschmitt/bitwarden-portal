#!/usr/bin/env bash

usage() {
  echo "Usage: $0 -s BW_SERVER -c BW_API_CLIENT_ID -S BW_API_CLIENT_SECRET -e BW_EMAIL -m BW_MASTER_PASSWORD"
}

bw_login() {
  local device_identifier
  device_identifier=$(uuidgen)

  curl -fsSL "$BW_SERVER/identity/connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "grant_type=client_credentials" \
    --data "client_id=$BW_API_CLIENT_ID" \
    --data-urlencode "client_secret=$BW_API_CLIENT_SECRET" \
    --data "device_identifier=${device_identifier}" \
    --data "device_name=curl" \
    --data "device_type=fart" \
    --data "scope=api"
}

bw_hash_master_password() {
  # python3 bw.py hash \
  #   --email "$BW_EMAIL" \
  #   --password "$BW_MASTER_PASSWORD" \
  #   --kdf-iterations "$KDF_ITERATIONS"

  ./bw.py hash \
    --email "$BW_EMAIL" \
    --password "$BW_MASTER_PASSWORD" \
    --kdf-iterations "$KDF_ITERATIONS"
}

bw_purge_vault() {
  curl -fsSL -X POST "$BW_SERVER/api/ciphers/purge" \
    -H "Authorization: Bearer $BEARER_TOKEN" \
    --json "{\"masterPasswordHash\":\"$MASTER_PASSWORD_HASH\"}"
}

main() {
  while [[ -n $1 ]]
  do
    case "$1" in
      -h|--help|-\?)
        usage
        return 0
        ;;
      -s|--server)
        BW_SERVER="$2"
        shift 2
        ;;
      -c|--api-client-id|--client-id)
        BW_API_CLIENT_ID="$2"
        shift 2
        ;;
      -S|--api-client-secret|--client-secret)
        BW_API_CLIENT_SECRET="$2"
        shift 2
        ;;
      -e|--email)
        BW_EMAIL="$2"
        shift 2
        ;;
      -m|--master-password|--pass|--password)
        BW_MASTER_PASSWORD="$2"
        shift 2
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if [[ -z $BW_SERVER || -z $BW_API_CLIENT_ID || \
        -z $BW_API_CLIENT_SECRET || -z $BW_EMAIL || \
        -z $BW_MASTER_PASSWORD ]]
  then
    usage >&2
    return 2
  fi

  if ! BW_LOGIN_DATA=$(bw_login)
  then
    echo "Failed to log in to Bitwarden" >&2
    return 1
  fi

  IFS=$'\t' read -r KDF_ITERATIONS BEARER_TOKEN <<< "$(
    <<< "$BW_LOGIN_DATA" \
    jq -er '[ .KdfIterations, .access_token ] | @tsv'
  )"

  if ! MASTER_PASSWORD_HASH=$(bw_hash_master_password)
  then
    echo "Failed to hash master password" >&2
    return 1
  fi

  if ! bw_purge_vault
  then
    echo "Failed to purge vault" >&2
    return 1
  fi

  echo "✅ Vault purged successfully"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  cd "$(cd "$(dirname "$0")" >/dev/null 2>&1; pwd -P)" || exit 9

  main "$@"
fi
