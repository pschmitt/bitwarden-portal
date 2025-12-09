#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: master_password_hash.sh --email EMAIL --password PASSWORD [--kdf-iterations N] [--local]

Derives the Bitwarden master password auth hash using PBKDF2 (SHA-256) via OpenSSL.
Options:
  -e, --email             Account email (leading/trailing whitespace is trimmed)
  -p, --password          Master password
  --kdf-iterations N      PBKDF2 iterations for the master key (default: 600000)
  --local                 Apply the local hash variant (2 iterations instead of 1)
  -h, --help              Show this help
EOF
}

require_openssl_pbkdf2() {
  if ! openssl list -kdf-algorithms 2>/dev/null | grep -q "PBKDF2"
  then
    echo "OpenSSL PBKDF2 support is required (openssl kdf PBKDF2 unavailable)." >&2
    exit 1
  fi
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

derive_master_key() {
  local trimmed_email
  trimmed_email="$(printf '%s' "$EMAIL" | trim)"

  openssl kdf -binary \
    -keylen 32 \
    -kdfopt digest:SHA256 \
    -kdfopt "pass:$PASSWORD" \
    -kdfopt "salt:$trimmed_email" \
    -kdfopt "iter:$KDF_ITERATIONS" \
    PBKDF2 | xxd -p -c 256 | tr -d '\n'
}

compute_master_password_hash() {
  local master_key_hex final_iters
  master_key_hex="$(derive_master_key)"

  if [[ -z "$master_key_hex" ]]
  then
    echo "Failed to derive master key." >&2
    return 1
  fi

  final_iters=1
  if [[ "$LOCAL_VARIANT" -eq 1 ]]
  then
    final_iters=2
  fi

  openssl kdf -binary \
    -keylen 32 \
    -kdfopt digest:SHA256 \
    -kdfopt "hexpass:$master_key_hex" \
    -kdfopt "salt:$PASSWORD" \
    -kdfopt "iter:$final_iters" \
    PBKDF2 | openssl base64 -A
}

main() {
  EMAIL=""
  PASSWORD=""
  KDF_ITERATIONS=600000
  LOCAL_VARIANT=0

  while [[ $# -gt 0 ]]
  do
    case "$1" in
      -e|--email)
        EMAIL="${2-}"
        shift 2
        ;;
      -p|--password)
        PASSWORD="${2-}"
        shift 2
        ;;
      --kdf-iterations)
        KDF_ITERATIONS="${2-}"
        shift 2
        ;;
      --local)
        LOCAL_VARIANT=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  if [[ -z "${EMAIL// }" || -z "$PASSWORD" ]]
  then
    echo "Email and password are required." >&2
    usage
    return 1
  fi

  if ! [[ "$KDF_ITERATIONS" =~ ^[0-9]+$ ]]
  then
    echo "Iterations must be a positive integer." >&2
    return 1
  fi

  require_openssl_pbkdf2

  if ! compute_master_password_hash
  then
    return 1
  fi

  printf '\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
