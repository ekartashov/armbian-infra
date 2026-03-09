#!/usr/bin/env bash
# scripts/verify-armbianenv.sh — verify armbianEnv.txt is correctly configured for btrfs NVMe boot
# Usage: verify-armbianenv.sh <env_file> <board_mac>
set -euo pipefail

env_file="${1:?Usage: $0 <env_file> <board_mac>}"
board_mac="${2:?Usage: $0 <env_file> <board_mac>}"

errors=()
grep -q "rootfstype=btrfs"        "$env_file" || errors+=("rootfstype not set to btrfs")
grep -q "rootflags=subvol=@"      "$env_file" || errors+=("rootflags missing subvol=@")
grep -q "rootdev=UUID="           "$env_file" || errors+=("rootdev UUID not set")
grep -qF "ethaddr=${board_mac}"    "$env_file" || errors+=("ethaddr not fixed to ${board_mac}")

if [[ ${#errors[@]} -gt 0 ]]; then
  printf "VERIFY FAILED: %s\n" "${errors[@]}" >&2
  exit 1
fi
echo "OK: armbianEnv.txt verified"
