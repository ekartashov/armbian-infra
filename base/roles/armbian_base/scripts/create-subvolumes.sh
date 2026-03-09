#!/usr/bin/env bash
# scripts/create-subvolumes.sh — create btrfs subvolumes and mount staging tree
set -euo pipefail

device="" boot_device="" staging="" toplevel="" mount_options="" subvolumes_json=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)        device="$2"; shift 2 ;;
    --boot-device)   boot_device="$2"; shift 2 ;;
    --staging)       staging="$2"; shift 2 ;;
    --toplevel)      toplevel="$2"; shift 2 ;;
    --mount-options) mount_options="$2"; shift 2 ;;
    --subvolumes)    subvolumes_json="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Mount top-level subvolume ────────────────────────────────────────────────
mkdir -p "$toplevel"
if ! mountpoint -q "$toplevel" 2>/dev/null; then
  mount -o subvolid=5,noatime,ssd "$device" "$toplevel"
fi

# ── Create subvolumes ───────────────────────────────────────────────────────
# Parse JSON array: [{"name":"@","mount":"/"},{"name":"@home","mount":"/home"},...]
# Use python3 since it's always on Debian/Ubuntu
mapfile -t sv_names < <(echo "$subvolumes_json" | python3 -c "
import sys, json
for sv in json.load(sys.stdin):
    print(sv['name'])
")

mapfile -t sv_mounts < <(echo "$subvolumes_json" | python3 -c "
import sys, json
for sv in json.load(sys.stdin):
    print(sv['mount'])
")

for name in "${sv_names[@]}"; do
  sv_path="${toplevel}/${name}"
  if btrfs subvolume show "$sv_path" >/dev/null 2>&1; then
    echo "subvolume ${name} already exists"
  else
    btrfs subvolume create "$sv_path"
    echo "created subvolume ${name}"
  fi
done

# ── Mount staging tree ──────────────────────────────────────────────────────
# Mount @ first (root), then the rest in mount-path depth order
mkdir -p "$staging"

# Mount root subvolume
if ! mountpoint -q "$staging" 2>/dev/null; then
  mount -o "subvol=@,${mount_options}" "$device" "$staging"
fi

# Mount remaining subvolumes
for i in "${!sv_names[@]}"; do
  name="${sv_names[$i]}"
  mnt="${sv_mounts[$i]}"
  [[ "$mnt" == "/" ]] && continue  # already mounted

  target="${staging}${mnt}"
  mkdir -p "$target"
  if ! mountpoint -q "$target" 2>/dev/null; then
    mount -o "subvol=${name},${mount_options}" "$device" "$target"
  fi
done

# Mount top-level for btrbk at staging path too
mkdir -p "${staging}${toplevel##$staging}"
target_toplevel="${staging}/mnt/btrfs-root"
mkdir -p "$target_toplevel"

# Mount boot partition
mkdir -p "${staging}/boot"
if ! mountpoint -q "${staging}/boot" 2>/dev/null; then
  mount "$boot_device" "${staging}/boot"
fi

echo "staging tree mounted at ${staging}"
