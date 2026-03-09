#!/usr/bin/env bash
# scripts/setup-gpg-key.sh — Fetch and pin Armbian's GPG signing key
#
# Run this once during initial project setup. The exported key is committed
# to keys/armbian-release.asc so pull-image.sh has no runtime keyserver
# dependency.
#
# Usage: ./scripts/setup-gpg-key.sh

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"

require gpg curl

# Armbian's image signing key
EXPECTED_FINGERPRINT="DF00FAF1C577104B50BF1D0093D6889F9F0E78D5"
KEYSERVER="hkp://keyserver.ubuntu.com"
OUTPUT="${DIR_KEYS}/armbian-release.asc"

log_info "fetching Armbian signing key: ${EXPECTED_FINGERPRINT}"

# Use a temporary keyring to avoid polluting user's keyring
TMPGNUPG=$(mktemp -d)
trap 'rm -rf "$TMPGNUPG"' EXIT
export GNUPGHOME="$TMPGNUPG"

# Fetch from keyserver
if ! gpg --keyserver "$KEYSERVER" --recv-key "$EXPECTED_FINGERPRINT" 2>&1; then
  log_warn "keyserver ${KEYSERVER} failed, trying direct IP fallback"
  # Ubuntu keyserver sometimes has IPv6 issues; try direct
  gpg --keyserver "hkp://162.213.33.9" --recv-key "$EXPECTED_FINGERPRINT" \
    || log_fatal "could not fetch key from any keyserver"
fi

# Verify we got the right key
IMPORTED_FP=$(gpg --with-colons --fingerprint "$EXPECTED_FINGERPRINT" 2>/dev/null \
  | awk -F: '/^fpr:/ { print $10; exit }')

if [[ "$IMPORTED_FP" != "$EXPECTED_FINGERPRINT" ]]; then
  log_fatal "fingerprint mismatch! expected ${EXPECTED_FINGERPRINT}, got ${IMPORTED_FP}"
fi

# Export armored public key
gpg --export --armor "$EXPECTED_FINGERPRINT" > "$OUTPUT"

log_ok "key exported to ${OUTPUT}"
log_info "fingerprint: ${IMPORTED_FP}"
log_info "commit this file to your repository"

# Show key details for human verification
echo "" >&2
gpg --fingerprint "$EXPECTED_FINGERPRINT"
