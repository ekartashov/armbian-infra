#!/usr/bin/env bash
# scripts/gen-ssh-keypair.sh — generate Ed25519 keypair for bootstrap access
# Output: secrets/ssh/id_ed25519{,.pub}

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"

require ssh-keygen

KEYDIR="${DIR_SECRETS}/ssh"
mkdir -p "$KEYDIR"

if [[ -f "$KEYDIR/id_ed25519" ]]; then
  log_info "keypair already exists:"
  ssh-keygen -l -f "$KEYDIR/id_ed25519.pub"
  exit 0
fi

ssh-keygen -t ed25519 -f "$KEYDIR/id_ed25519" -N "" -C "armbian-bootstrap"
chmod 600 "$KEYDIR/id_ed25519"
log_ok "keypair generated at ${KEYDIR}/"
