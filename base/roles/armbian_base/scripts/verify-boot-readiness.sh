#!/usr/bin/env bash
# scripts/verify-boot-readiness.sh — verify an installed system has all required boot files
# Usage: verify-boot-readiness.sh --root-uuid <uuid> [--mount-options <opts>]
set -euo pipefail

root_uuid="" 
mount_options="noatime,ssd"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-uuid)      root_uuid="$2";      shift 2 ;;
    --mount-options)  mount_options="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$root_uuid" ]] || { echo "error: --root-uuid is required" >&2; exit 1; }

tmp_check=$(mktemp -d)
cleanup_check() {
  umount "$tmp_check" 2>/dev/null || true
  rmdir  "$tmp_check" 2>/dev/null || true
}
trap cleanup_check EXIT

# Mount root subvolume read-only for verification
mount -o "subvol=@,ro,${mount_options}" \
  /dev/disk/by-uuid/"${root_uuid}" "$tmp_check" \
  || mount -o "subvol=@,ro" \
       /dev/disk/by-uuid/"${root_uuid}" "$tmp_check"

errors=""

ls "$tmp_check"/boot/initrd.img-* >/dev/null 2>&1 \
  || errors="${errors}  - no initrd.img-* found in /boot\n"

{ ls "$tmp_check"/boot/vmlinuz-* >/dev/null 2>&1 \
    || ls "$tmp_check"/boot/Image  >/dev/null 2>&1; } \
  || errors="${errors}  - no kernel image (vmlinuz-* or Image) found in /boot\n"

[[ -f "$tmp_check/boot/armbianEnv.txt" ]] \
  || errors="${errors}  - /boot/armbianEnv.txt missing\n"

[[ -s "$tmp_check/etc/fstab" ]] \
  || errors="${errors}  - /etc/fstab is missing or empty\n"

{ [[ -f "$tmp_check/sbin/init" ]] \
    || [[ -f "$tmp_check/usr/sbin/init" ]] \
    || [[ -f "$tmp_check/lib/systemd/systemd" ]]; } \
  || errors="${errors}  - no init found (/sbin/init, /usr/sbin/init, or /lib/systemd/systemd)\n"

if [[ -n "$errors" ]]; then
  echo "Boot readiness check FAILED:" >&2
  printf "%b" "$errors" >&2
  exit 1
fi
echo "Boot readiness check passed"
