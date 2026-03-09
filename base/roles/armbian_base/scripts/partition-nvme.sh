#!/usr/bin/env bash
# scripts/partition-nvme.sh — partition NVMe for armbian-base
# --check: exit 0 if already correctly partitioned, 1 if not
# --apply: wipe and repartition

set -euo pipefail

mode="" device="" boot_size_mb=512
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)     mode="check"; shift ;;
    --apply)     mode="apply"; shift ;;
    --device)    device="$2"; shift 2 ;;
    --boot-size) boot_size_mb="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$mode" ]]   || { echo "error: --check or --apply required" >&2; exit 1; }
[[ -n "$device" ]] || { echo "error: --device required" >&2; exit 1; }
[[ -b "$device" ]] || { echo "error: ${device} is not a block device" >&2; exit 1; }

p1="${device}p1"
p2="${device}p2"

# ── Check mode ──────────────────────────────────────────────────────────────

if [[ "$mode" == "check" ]]; then
  # Verify: GPT table, two partitions, p1=ext4, p2=btrfs
  if [[ ! -b "$p1" ]] || [[ ! -b "$p2" ]]; then
    echo "partitions missing"
    exit 1
  fi
  t1=$(blkid -o value -s TYPE "$p1" 2>/dev/null || echo "")
  t2=$(blkid -o value -s TYPE "$p2" 2>/dev/null || echo "")
  if [[ "$t1" == "ext4" ]] && [[ "$t2" == "btrfs" ]]; then
    echo "STATE=already_done"
    exit 0
  fi
  echo "filesystem types wrong: p1=${t1} p2=${t2}"
  exit 1
fi

# ── Apply mode ──────────────────────────────────────────────────────────────

echo "wiping ${device}..."
wipefs -af "$device"
# sgdisk for GPT — offset at 16 MiB (sector 32768) for Rockchip convention
sgdisk --zap-all "$device" 2>/dev/null || true

# Partition 1: boot (ext4), starting at 32768 sectors (16 MiB)
# Partition 2: root (btrfs), rest of disk
sgdisk \
  -n 1:32768:+${boot_size_mb}M -t 1:8300 -c 1:"boot" \
  -n 2:0:0                     -t 2:8300 -c 2:"root" \
  "$device"

partprobe "$device"
sleep 1

# Verify partitions appeared
[[ -b "$p1" ]] || { echo "error: ${p1} not found after partitioning" >&2; exit 1; }
[[ -b "$p2" ]] || { echo "error: ${p2} not found after partitioning" >&2; exit 1; }

echo "partitioned: ${p1} (boot ${boot_size_mb}M) + ${p2} (root)"
