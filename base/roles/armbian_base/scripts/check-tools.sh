#!/usr/bin/env bash
# scripts/check-tools.sh — verify required tools are available on the target
set -euo pipefail

missing=()
for cmd in btrfs mkfs.btrfs mkfs.ext4 rsync parted partprobe wipefs blkid sgdisk; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "MISSING: ${missing[*]}"
  exit 1
fi
echo "OK"
