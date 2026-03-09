#!/usr/bin/env bash
# scripts/patch-image.sh — patch a pulled Armbian image for headless SSH bootstrap
#
# Usage:
#   ./scripts/patch-image.sh <board>          # e.g., orangepi5
#   ./scripts/patch-image.sh --all
#   ./scripts/patch-image.sh <board> --force   # overwrite existing patched image
#
# Runs as your normal user. Uses sudo internally for losetup/mount operations
# only — all output files (images, locks, secrets) remain user-owned.
#
# Prerequisites:
#   - Base image pulled (run pull-image.sh first)
#   - sudo access (for losetup/mount)
#   - secrets/password.hash + secrets/ssh/id_ed25519.pub (generated interactively if missing)

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"
source "$(dirname "$0")/../libs/boards.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────

FORCE=false
ALL_BOARDS=false
BOARDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=true; shift ;;
    --all)    ALL_BOARDS=true; shift ;;
    --help|-h)
      echo "Usage: $0 <board> [--force]"
      echo "       $0 --all [--force]"
      echo ""
      echo "Boards with pulled images (available for patching):"
      list_pulled_boards | sed 's/^/  /'
      exit 0
      ;;
    -*) log_fatal "unknown flag: $1 (try --help)" ;;
    *)  BOARDS+=("$1"); shift ;;
  esac
done

# Replace the check after argument parsing

if [[ "$ALL_BOARDS" == "true" ]]; then
  mapfile -t BOARDS < <(list_pulled_boards)
  if [[ ${#BOARDS[@]} -eq 0 ]]; then
    log_fatal "no pulled images found in ${DIR_IMAGES} — run ./scripts/pull-image.sh --all first"
  fi
fi

if [[ ${#BOARDS[@]} -eq 0 ]]; then
  log_fatal "no board specified (try: $0 orangepi5  or  $0 --all)"
fi

# ── Dependencies ─────────────────────────────────────────────────────────────

# Tools in user PATH
require xz sed sha256sum sudo

if [[ $EUID -eq 0 ]]; then
  log_fatal "do not run as root — the script uses sudo internally for mount operations only"
fi

if ! sudo -v 2>/dev/null; then
  log_fatal "sudo access required (for losetup/mount)"
fi

# Tools in /sbin (not in user PATH on Debian, but accessible via sudo)
_sbin_missing=()
for _cmd in losetup mount umount mountpoint parted e2fsck resize2fs sgdisk; do
  sudo which "$_cmd" >/dev/null 2>&1 || _sbin_missing+=("$_cmd")
done
if [[ ${#_sbin_missing[@]} -gt 0 ]]; then
  log_fatal "missing commands (via sudo): ${_BOLD}${_sbin_missing[*]}${_RESET}"
fi

# ── Secrets provisioning ─────────────────────────────────────────────────────

ensure_password_hash() {
  local hashfile="${DIR_SECRETS}/password.hash"
  if [[ -f "$hashfile" ]]; then
    return 0
  fi

  log_warn "no password hash found at ${hashfile}"
  log_info "generating one now for the '${PATCH_USER}' user..."

  require openssl
  mkdir -p "$DIR_SECRETS"

  read -rsp "  Password for '${PATCH_USER}': " pass; echo >&2
  read -rsp "  Confirm: " confirm; echo >&2

  [[ "$pass" == "$confirm" ]] || log_fatal "passwords don't match"
  [[ -n "$pass" ]]            || log_fatal "password cannot be empty"

  echo "$pass" | openssl passwd -6 -stdin > "$hashfile"
  chmod 600 "$hashfile"
  log_ok "hash written to ${hashfile}"
}

ensure_ssh_keypair() {
  local pubkey="${DIR_SECRETS}/ssh/id_ed25519.pub"
  if [[ -f "$pubkey" ]]; then
    return 0
  fi

  log_warn "no SSH keypair found at ${DIR_SECRETS}/ssh/"
  log_info "generating Ed25519 keypair..."

  require ssh-keygen
  mkdir -p "${DIR_SECRETS}/ssh"

  ssh-keygen -t ed25519 -f "${DIR_SECRETS}/ssh/id_ed25519" -N "" -C "armbian-bootstrap"
  chmod 600 "${DIR_SECRETS}/ssh/id_ed25519"
  log_ok "keypair generated"
}

# ── Image resize (before mount) ───────────────────────────────────────────────

# Minimal Armbian images ship with very little free space on the rootfs
# partition — often under 200 MiB. Installing packages + regenerating the
# initramfs (~22 MiB) pushes the partition over the edge and causes ENOSPC
# during apt post-install triggers. The fix is to extend the raw .img file
# and resize the last partition + its filesystem before we ever mount it.
# This runs entirely on the host (loopdev, parted, e2fsck, resize2fs) without
# entering the chroot.
resize_image_for_patching() {
  local img="$1"
  local extra_mb="${PATCH_RESIZE_MB:-256}"

  if [[ "$extra_mb" -eq 0 ]]; then
    log_info "PATCH_RESIZE_MB=0 — skipping image resize"
    return 0
  fi

  log_info "expanding image by ${extra_mb} MiB for package installation headroom ..."

  truncate -s "+${extra_mb}M" "$img"

  local tmp_loop
  tmp_loop=$(sudo losetup --find --show --partscan "$img")

  # After truncating a GPT image the backup GPT header is stranded at the
  # old end-of-disk. parted refuses to resizepart until it is moved.
  # sgdisk -e (--move-second-header) relocates it to the actual new end.
  sudo sgdisk -e "$tmp_loop" >/dev/null 2>&1

  local last_part_num
  last_part_num=$(sudo parted -sm "$tmp_loop" print 2>/dev/null \
    | awk -F: 'NR>2 { n=$1+0; if (n>max) max=n } END { print max }')

  if [[ -z "$last_part_num" || "$last_part_num" -lt 1 ]]; then
    sudo losetup -d "$tmp_loop"
    log_fatal "could not determine last partition number in ${img}"
  fi

  local last_part="${tmp_loop}p${last_part_num}"

  sudo parted -s "$tmp_loop" resizepart "$last_part_num" 100%
  sudo partprobe "$tmp_loop"
  sleep 1

  sudo e2fsck -f -y "$last_part" >/dev/null 2>&1 || true
  sudo resize2fs "$last_part" >/dev/null 2>&1

  sudo losetup -d "$tmp_loop"
  log_ok "image partition expanded (+${extra_mb} MiB)"
}

# ── Mount / unmount helpers (sudo only here) ─────────────────────────────────

LOOPDEV=""
MOUNTPOINT=""
CHROOT_ACTIVE=false
CHROOT_ARCH=""
CHROOT_TMPDIR=""

cleanup_mount() {
  # Tear down chroot bind mounts first so umount -R sees clean submounts
  if "$CHROOT_ACTIVE"; then
    _chroot_umount_binds 2>/dev/null || true
  fi
  if [[ -n "$MOUNTPOINT" ]] && sudo mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
    sudo umount -R "$MOUNTPOINT" 2>/dev/null || true
  fi
  if [[ -n "$LOOPDEV" ]]; then
    sudo losetup -d "$LOOPDEV" 2>/dev/null || true
  fi
  if [[ -n "$MOUNTPOINT" ]]; then
    sudo rmdir "$MOUNTPOINT" 2>/dev/null || true
  fi
}

mount_image() {
  local img="$1"
  MOUNTPOINT=$(mktemp -d /tmp/armbian-patch.XXXXXX)
  trap cleanup_mount EXIT

  LOOPDEV=$(sudo losetup --find --show --partscan "$img")

  # Detect partition layout
  local rootfs_part=""
  if [[ -b "${LOOPDEV}p2" ]]; then
    rootfs_part="${LOOPDEV}p2"
  elif [[ -b "${LOOPDEV}p1" ]]; then
    rootfs_part="${LOOPDEV}p1"
  else
    sudo partprobe "$LOOPDEV" 2>/dev/null || true
    sleep 1
    if [[ -b "${LOOPDEV}p2" ]]; then
      rootfs_part="${LOOPDEV}p2"
    elif [[ -b "${LOOPDEV}p1" ]]; then
      rootfs_part="${LOOPDEV}p1"
    else
      log_fatal "no partitions found on ${LOOPDEV}"
    fi
  fi

  sudo mount "$rootfs_part" "$MOUNTPOINT"
  log_ok "mounted rootfs (${rootfs_part}) at ${MOUNTPOINT}"
}

umount_image() {
  sudo umount "$MOUNTPOINT"
  sudo losetup -d "$LOOPDEV"
  sudo rmdir "$MOUNTPOINT"
  LOOPDEV=""
  MOUNTPOINT=""
  trap - EXIT
  log_ok "unmounted and detached"
}

# ── QEMU chroot helpers ───────────────────────────────────────────────────────

# Internal: unmount bind mounts and remove qemu binary.
# Called from both teardown_chroot and cleanup_mount (error path).
_chroot_umount_binds() {
  local root="$MOUNTPOINT"
  # Unmount in reverse order of mounting
  for mp in etc/resolv.conf var/tmp run dev/pts dev/shm dev sys proc; do
    if sudo mountpoint -q "${root}/${mp}" 2>/dev/null; then
      sudo umount "${root}/${mp}" 2>/dev/null || true
    fi
  done
  if [[ -n "$CHROOT_ARCH" ]]; then
    sudo rm -f "${root}/usr/bin/qemu-${CHROOT_ARCH}-static"
  fi
  # Remove policy-rc.d if we left it (e.g. failed mid-install)
  sudo rm -f "${root}/usr/sbin/policy-rc.d"
  # Remove host tmpdir used for mkinitramfs working space
  if [[ -n "$CHROOT_TMPDIR" ]]; then
    rm -rf "$CHROOT_TMPDIR"
    CHROOT_TMPDIR=""
  fi
  CHROOT_ACTIVE=false
}

detect_image_arch() {
  local root="$1"
  local target_bin=""
  for candidate in "${root}/bin/bash" "${root}/usr/bin/bash" "${root}/bin/ls" "${root}/bin/sh"; do
    [[ -f "$candidate" ]] && { target_bin="$candidate"; break; }
  done
  [[ -z "$target_bin" ]] && log_fatal "cannot detect image arch — no known binary found in rootfs"

  local file_out
  file_out=$(file -b "$target_bin" 2>/dev/null)

  if echo "$file_out" | grep -qiE "aarch64|ARM aarch64"; then
    echo "aarch64"
  elif echo "$file_out" | grep -qiE "ARM.*EABI|armv7|armhf"; then
    echo "arm"
  elif echo "$file_out" | grep -qiE "RISC-V.*64"; then
    echo "riscv64"
  else
    log_fatal "unrecognised image architecture: ${file_out}"
  fi
}

check_chroot_deps() {
  local arch="$1"
  local qemu_bin="qemu-${arch}-static"

  command -v "$qemu_bin" >/dev/null 2>&1 \
    || log_fatal "${qemu_bin} not found — install qemu-user-static on your host system"

  [[ -d /proc/sys/fs/binfmt_misc ]] \
    || log_fatal "binfmt_misc not mounted\n       sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc"

  [[ -f "/proc/sys/fs/binfmt_misc/qemu-${arch}" ]] \
    || log_fatal "binfmt_misc entry missing for ${arch} — reinstall qemu-user-static on your host system and restart systemd-binfmt"

  log_ok "host qemu-user-static: ${qemu_bin}"
}

setup_chroot() {
  local root="$MOUNTPOINT"
  local arch="$1"

  log_info "setting up chroot (${arch}) ..."

  # Static qemu binary — kernel uses it via binfmt_misc to exec arm64 ELFs
  sudo cp "$(command -v "qemu-${arch}-static")" "${root}/usr/bin/qemu-${arch}-static"

  # Prevent init scripts from starting services during package install
  echo '#!/bin/sh' | sudo tee "${root}/usr/sbin/policy-rc.d" > /dev/null
  echo 'exit 101'  | sudo tee -a "${root}/usr/sbin/policy-rc.d" > /dev/null
  sudo chmod +x "${root}/usr/sbin/policy-rc.d"

  # Bind mounts (order matters — proc before sys, dev before dev/pts)
  sudo mount --bind /proc            "${root}/proc"
  sudo mount --bind /sys             "${root}/sys"
  sudo mount --bind /dev             "${root}/dev"
  sudo mount --bind /dev/pts         "${root}/dev/pts"
  sudo mount --bind /dev/shm         "${root}/dev/shm"
  sudo mount --bind /run             "${root}/run"
  # mkinitramfs writes its working tree to /var/tmp inside the image.
  # The rootfs partition has very little free space, so bind a host tmpdir
  # there to give it room without touching the image partition at all.
  CHROOT_TMPDIR=$(mktemp -d)
  sudo mount --bind "$CHROOT_TMPDIR" "${root}/var/tmp"
  # Use host resolv.conf so apt can reach the network
  sudo mount --bind /etc/resolv.conf "${root}/etc/resolv.conf"

  CHROOT_ARCH="$arch"
  CHROOT_ACTIVE=true
  log_ok "chroot environment ready"
}

teardown_chroot() {
  log_info "tearing down chroot environment ..."
  _chroot_umount_binds
  log_ok "chroot environment cleaned up"
}

# Wrapper: run a command inside the arm chroot with a clean environment
run_chroot() {
  sudo chroot "$MOUNTPOINT" \
    /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    "$@"
}

# Install extra packages and/or overlayroot inside a QEMU chroot.
# Triggers when PATCH_EXTRA_PKGS is non-empty OR PATCH_OVERLAY != false.
# Both share a single chroot session: one apt-get update, installs, one clean.
apply_chroot_packages() {
  local root="$MOUNTPOINT"
  local extra_pkgs="${PATCH_EXTRA_PKGS:-}"
  local overlay_mode="${PATCH_OVERLAY:-false}"

  local need_overlay=false
  [[ "$overlay_mode" != "false" ]] && need_overlay=true

  # Nothing to do — skip chroot entirely
  if [[ -z "$extra_pkgs" ]] && ! $need_overlay; then
    return 0
  fi

  log_info "setting up chroot for package installation ..."

  local arch
  arch=$(detect_image_arch "$root")
  check_chroot_deps "$arch"

  setup_chroot "$arch"

  # Write overlayroot.conf BEFORE installing the package.
  # The overlayroot initramfs hook copies /etc/overlayroot.conf into the
  # initramfs only if the file exists when update-initramfs runs (triggered
  # by the overlayroot postinst). Writing it after teardown_chroot is too
  # late — the conf is absent during initramfs build and the overlay never
  # activates at boot, causing persistent write-through behaviour.
  if $need_overlay; then
    echo "overlayroot=\"${overlay_mode}\"" \
      | sudo tee "${root}/etc/overlayroot.conf" > /dev/null
    log_ok "overlayroot.conf pre-written (${overlay_mode})"
  fi

  run_chroot apt-get update -qq

  if [[ -n "$extra_pkgs" ]]; then
    log_info "installing extra packages: ${extra_pkgs}"
    # shellcheck disable=SC2086
    run_chroot apt-get install -y --no-install-recommends $extra_pkgs
    log_ok "extra packages installed"
  fi

  if $need_overlay; then
    log_info "installing overlayroot + busybox-static (mode: ${overlay_mode}) ..."
    # --force-confold: dpkg finds our pre-written overlayroot.conf differs
    # from the package default (overlayroot="") and prompts even under
    # DEBIAN_FRONTEND=noninteractive when stdin is a tty. This flag silently
    # keeps our version without prompting.
    # busybox-static is required by overlayroot — it provides the shell and
    # mount tools used by the initramfs hook to set up the tmpfs overlay at
    # boot. Without it the overlay pivot fails silently and the system boots
    # write-through instead of read-only.
    run_chroot apt-get install -y \
      -o Dpkg::Options::="--force-confold" \
      --no-install-recommends overlayroot busybox-static
    log_ok "overlayroot + busybox-static installed"
  fi

  run_chroot apt-get clean

  teardown_chroot
}

# ── Patch operations (sudo for in-mountpoint writes) ─────────────────────────

apply_patches() {
  local root="$MOUNTPOINT"
  local user="$PATCH_USER"
  local hostname="$PATCH_HOSTNAME"
  local uid=1000
  local gid=1000
  local password_hash
  password_hash=$(<"${DIR_SECRETS}/password.hash")
  local pubkey
  pubkey=$(<"${DIR_SECRETS}/ssh/id_ed25519.pub")
  local days_since_epoch=$(( $(date +%s) / 86400 ))

  # ── 1. Suppress first-login wizard ───────────────────────────────────────
  sudo rm -f "${root}/root/.not_logged_in_yet"
  log_ok "removed first-login wizard trigger"

  # ── 2. Lock root account ─────────────────────────────────────────────────
  if [[ "${PATCH_ROOT_MODE}" == "locked" ]]; then
    sudo sed -i 's|^root:[^:]*:|root:!:|' "${root}/etc/shadow"
    log_ok "root account locked"
  elif [[ "${PATCH_ROOT_MODE}" == "password" ]]; then
    local root_hash
    if [[ -f "${DIR_SECRETS}/password-root.hash" ]]; then
      root_hash=$(<"${DIR_SECRETS}/password-root.hash")
    else
      root_hash="$password_hash"
    fi
    sudo sed -i "s|^root:[^:]*:|root:${root_hash}:|" "${root}/etc/shadow"
    log_ok "root password set"
  fi

  # ── 3. Verify UID 1000 is free ──────────────────────────────────────────
  if grep -q "^[^:]*:[^:]*:${uid}:" "${root}/etc/passwd"; then
    log_fatal "UID ${uid} already taken in /etc/passwd — image may have been patched already"
  fi

  # ── 4. Create user ──────────────────────────────────────────────────────
  echo "${user}:x:${uid}:${gid}:Bootstrap User:/home/${user}:/bin/bash" \
    | sudo tee -a "${root}/etc/passwd" > /dev/null

  echo "${user}:${password_hash}:${days_since_epoch}:0:99999:7:::" \
    | sudo tee -a "${root}/etc/shadow" > /dev/null

  echo "${user}:x:${gid}:" \
    | sudo tee -a "${root}/etc/group" > /dev/null

  # Add to sudo group
  if grep -q "^sudo:[^:]*:[^:]*:$" "${root}/etc/group"; then
    sudo sed -i "s/^sudo:\([^:]*\):\([^:]*\):$/sudo:\1:\2:${user}/" "${root}/etc/group"
  elif grep -q "^sudo:" "${root}/etc/group"; then
    sudo sed -i "s/^sudo:\([^:]*\):\([^:]*\):\(.*\)/sudo:\1:\2:\3,${user}/" "${root}/etc/group"
  else
    log_warn "sudo group not found in /etc/group"
  fi

  log_ok "user '${user}' created (uid=${uid})"

  # ── 5. Home directory + skel + SSH key ──────────────────────────────────
  local home="${root}/home/${user}"
  sudo mkdir -p "$home"

  if [[ -d "${root}/etc/skel" ]]; then
    sudo cp -a "${root}/etc/skel/." "$home/"
  fi

  sudo install -d -m 700 -o "${uid}" -g "${gid}" "$home/.ssh"
  echo "$pubkey" | sudo tee "$home/.ssh/authorized_keys" > /dev/null
  sudo chmod 600 "$home/.ssh/authorized_keys"

  sudo chown -R "${uid}:${gid}" "$home"
  sudo chmod 700 "$home"

  log_ok "home directory created with SSH key"

  # ── 6. sshd_config ─────────────────────────────────────────────────────
  sudo cp "${DIR_TEMPLATES}/sshd_config" "${root}/etc/ssh/sshd_config"
  sudo chmod 644 "${root}/etc/ssh/sshd_config"
  log_ok "sshd_config deployed (key-only, no root login)"

  # ── 7. Enable SSH service ──────────────────────────────────────────────
  sudo mkdir -p "${root}/etc/systemd/system/multi-user.target.wants"

  if [[ -f "${root}/lib/systemd/system/ssh.service" ]]; then
    sudo ln -sf /lib/systemd/system/ssh.service \
      "${root}/etc/systemd/system/multi-user.target.wants/ssh.service"
    log_ok "enabled ssh.service"
  elif [[ -f "${root}/lib/systemd/system/sshd.service" ]]; then
    sudo ln -sf /lib/systemd/system/sshd.service \
      "${root}/etc/systemd/system/multi-user.target.wants/sshd.service"
    log_ok "enabled sshd.service"
  else
    log_warn "SSH service unit not found — verify manually after first boot"
  fi

  sudo rm -f "${root}/etc/systemd/system/sockets.target.wants/ssh.socket" 2>/dev/null || true

  # ── 8. Hostname ────────────────────────────────────────────────────────
  echo "$hostname" | sudo tee "${root}/etc/hostname" > /dev/null

  if grep -q "127.0.1.1" "${root}/etc/hosts"; then
    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t${hostname}/" "${root}/etc/hosts"
  else
    printf "127.0.1.1\t%s\n" "${hostname}" | sudo tee -a "${root}/etc/hosts" > /dev/null
  fi
  log_ok "hostname set to '${hostname}'"

  # ── 9. Reset machine-id (regenerates uniquely per board on boot) ───────
  sudo truncate -s 0 "${root}/etc/machine-id"
  sudo rm -f "${root}/var/lib/dbus/machine-id" 2>/dev/null || true
  log_ok "machine-id reset"

  # ── 10. Passwordless sudo for bootstrap user ───────────────────────────
  sudo mkdir -p "${root}/etc/sudoers.d"
  echo "${user} ALL=(ALL) NOPASSWD: ALL" | sudo tee "${root}/etc/sudoers.d/90-bootstrap" > /dev/null
  sudo chmod 440 "${root}/etc/sudoers.d/90-bootstrap"
  log_ok "passwordless sudo configured"
}

# ── Patch a single board ─────────────────────────────────────────────────────

patch_board() {
  local board="$1"

  log_info "═══ ${_BOLD}${board}${_RESET} ═══════════════════════════════════════════"

  load_config "$board"

  local board_dir="${DIR_IMAGES}/${ARMBIAN_BOARD_SLUG}"
  if ! read_lock "$board_dir"; then
    log_error "no .pull-lock for ${board} — run pull-image.sh first"
    return 1
  fi

  local base_file="${board_dir}/${ARMBIAN_LOCKED_FILENAME}"
  if [[ ! -f "$base_file" ]]; then
    log_error "base image not found: ${base_file}"
    log_error "run: ./scripts/pull-image.sh ${board}"
    return 1
  fi

  mkdir -p "$DIR_PATCHED"
  local patched_xz="${DIR_PATCHED}/${ARMBIAN_BOARD_SLUG}.img.xz"
  local patched_lock="${DIR_PATCHED}/${ARMBIAN_BOARD_SLUG}.patch-lock"

  if [[ -f "$patched_xz" && "$FORCE" == "false" ]]; then
    log_info "patched image exists: ${patched_xz}"
    log_info "use --force to rebuild"
    return 0
  fi

  [[ -n "${PATCH_HOSTNAME:-}" ]] || log_fatal "PATCH_HOSTNAME not set in board config"
  [[ -f "${DIR_TEMPLATES}/sshd_config" ]] || log_fatal "templates/sshd_config not found"

  # ── Decompress (user-owned output) ───────────────────────────────────────

  local working_img="${DIR_PATCHED}/${ARMBIAN_BOARD_SLUG}.img"
  rm -f "$working_img" "$patched_xz"

  log_info "decompressing base image ..."
  xz -dkc "$base_file" > "$working_img"
  log_ok "decompressed ($(du -sh "$working_img" | cut -f1))"

  # ── Resize image partition for package installation headroom ─────────────
  # Minimal Armbian images ship with almost no free space on the rootfs.
  # Installing packages + regenerating initramfs (~22 MiB) causes ENOSPC
  # without this step. resize_image_for_patching expands the raw .img file
  # and uses parted + resize2fs to grow the last partition and its filesystem
  # before we mount anything.
  resize_image_for_patching "$working_img"

  # ── Mount + patch + unmount (sudo for privileged ops) ────────────────────

  mount_image "$working_img"
  apply_patches
  apply_chroot_packages
  umount_image

  # ── Recompress (user-owned output) ───────────────────────────────────────

  log_info "recompressing (xz -${PATCH_XZ_LEVEL} -T0) ..."
  xz "-${PATCH_XZ_LEVEL}" -T0 "$working_img"
  log_ok "compressed: ${patched_xz} ($(du -sh "$patched_xz" | cut -f1))"

  # ── Write patch-lock (user-owned) ────────────────────────────────────────

  local patched_sha
  patched_sha=$(sha256sum "$patched_xz" | awk '{print $1}')

  cat > "$patched_lock" << EOF
# .patch-lock (auto-generated by patch-image.sh — do not edit)
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
PATCH_BASE_IMAGE="${ARMBIAN_LOCKED_FILENAME}"
PATCH_BASE_SHA256="${ARMBIAN_LOCKED_SHA256}"
PATCH_BOARD="${ARMBIAN_BOARD_SLUG}"
PATCH_HOSTNAME="${PATCH_HOSTNAME}"
PATCH_USER="${PATCH_USER}"
PATCH_ROOT_MODE="${PATCH_ROOT_MODE}"
PATCH_OVERLAY="${PATCH_OVERLAY:-false}"
PATCH_EXTRA_PKGS="${PATCH_EXTRA_PKGS:-}"
PATCH_RESIZE_MB="${PATCH_RESIZE_MB:-256}"
PATCH_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PATCH_SHA256="${patched_sha}"
EOF

  log_ok "${_BOLD}${ARMBIAN_BOARD_SLUG}.img.xz${_RESET} — patched and ready to flash"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  log_info "armbian image patch"
  echo ""

  # shellcheck source=/dev/null
  source "${DIR_CONFIG}/defaults.env"

  ensure_password_hash
  ensure_ssh_keypair

  local failed=()

  for board in "${BOARDS[@]}"; do
    if ! patch_board "$board"; then
      failed+=("$board")
      log_error "failed to patch ${board}"
      echo ""
    fi
  done

  echo ""
  if [[ ${#failed[@]} -eq 0 ]]; then
    log_ok "all boards patched (${#BOARDS[@]}/${#BOARDS[@]})"
    echo ""
    log_info "flash:  xzcat images/patched/<board>.img.xz | sudo dd of=/dev/sdX bs=4M status=progress oflag=sync"
  else
    log_error "${#failed[@]}/${#BOARDS[@]} failed: ${failed[*]}"
    exit 1
  fi
}

main
