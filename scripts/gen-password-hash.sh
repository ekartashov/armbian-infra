#!/usr/bin/env bash
# scripts/gen-password-hash.sh — generate SHA-512 hash for /etc/shadow
# Output: secrets/password.hash
#
# This hash is shared by BOTH pipeline stages:
#   - patch stage  (patch-image.sh)           — sets the bootstrap SD-card user password
#   - base stage   (Ansible provision-base)   — sets the admin user password on NVMe
# Run this script once before either stage. Both stages read the same file.
#
# Uses openssl passwd -6. Alternatively: mkpasswd -m sha-512 (whois pkg).

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"

require openssl

HASHFILE="${DIR_SECRETS}/password.hash"
mkdir -p "$DIR_SECRETS"

if [[ -f "$HASHFILE" ]]; then
  log_info "hash already exists at ${HASHFILE}"
  log_info "delete it first to regenerate"
  exit 0
fi

read -rsp "Password: " pass; echo >&2
read -rsp "Confirm:  " confirm; echo >&2

if [[ "$pass" != "$confirm" ]]; then
  log_fatal "passwords don't match"
fi

if [[ -z "$pass" ]]; then
  log_fatal "password cannot be empty"
fi

echo "$pass" | openssl passwd -6 -stdin > "$HASHFILE"
chmod 600 "$HASHFILE"
log_ok "hash written to ${HASHFILE}"
