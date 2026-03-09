#!/usr/bin/env bash
# scripts/install-image.sh — decompress and rsync a fresh Armbian image to staging
set -euo pipefail

image="" staging=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)   image="$2"; shift 2 ;;
    --staging) staging="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$image" ]]   || { echo "error: --image required" >&2; exit 1; }
[[ -n "$staging" ]] || { echo "error: --staging required" >&2; exit 1; }
[[ -f "$image" ]]   || { echo "error: image not found: ${image}" >&2; exit 1; }

raw_img="/tmp/armbian-base.img"
loop_mount="/tmp/armbian-source"
cleanup() {
  umount "$loop_mount" 2>/dev/null || true
  [[ -n "${loopdev:-}" ]] && losetup -d "$loopdev" 2>/dev/null || true
  rmdir "$loop_mount" 2>/dev/null || true
}
trap cleanup EXIT

# ── Decompress ──────────────────────────────────────────────────────────────
echo "decompressing image..."
xzcat "$image" > "$raw_img"

# ── Loop-mount ──────────────────────────────────────────────────────────────
loopdev=$(losetup --find --show --partscan "$raw_img")

# Detect rootfs partition (p2 for dual-partition images, p1 for single)
rootfs_part=""
if [[ -b "${loopdev}p2" ]]; then
  rootfs_part="${loopdev}p2"
elif [[ -b "${loopdev}p1" ]]; then
  rootfs_part="${loopdev}p1"
else
  partprobe "$loopdev" 2>/dev/null || true
  sleep 1
  if [[ -b "${loopdev}p2" ]]; then
    rootfs_part="${loopdev}p2"
  elif [[ -b "${loopdev}p1" ]]; then
    rootfs_part="${loopdev}p1"
  else
    echo "error: no partitions found on loop device" >&2
    exit 1
  fi
fi

mkdir -p "$loop_mount"
mount -o ro "$rootfs_part" "$loop_mount"
echo "mounted source rootfs from ${rootfs_part}"

# ── Rsync to staging ───────────────────────────────────────────────────────
echo "rsync rootfs to staging..."
rsync -aAXH --info=progress2 \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
  --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' \
  --exclude='/media/*' --exclude='/lost+found' \
  "${loop_mount}/" "${staging}/"

# Copy /boot contents separately (they go to the ext4 partition)
if [[ -d "${loop_mount}/boot" ]]; then
  echo "rsync /boot to staging..."
  rsync -aAXH "${loop_mount}/boot/" "${staging}/boot/"
fi

echo "image installed to ${staging}"
