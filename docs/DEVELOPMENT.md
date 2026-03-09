# Development Notes

Accumulated knowledge, gotchas, and architectural decisions. Written for the admin who built this but will forget the details after three months away.

---

## Bootstrap Phase (pull + patch)

### Image source

Images are resolved from `https://www.armbian.com/all-images.json` — a JSON catalog of every built image. This is more reliable than scraping the download page or using GitHub releases. The catalog is cached locally (`cache/all-images.json`) with a configurable TTL (`ARMBIAN_CATALOG_MAX_AGE`, default 3600s).

### Download method

Images are downloaded exclusively via `curl` with resume support (`-C -`). Torrent download via `aria2c` was evaluated and removed: Armbian torrents are very poorly seeded and `aria2c` fell back to HTTP on every single test run, making the extra dependency pointless. Downloads are intentionally serial (one board at a time) to avoid IP shadow-banning from `dl.armbian.com` — untested but good hygiene.

### Image resize before patching

Minimal Armbian images ship with very little free space on their rootfs partition — often under 200 MiB. Installing packages and regenerating the initramfs (~22 MiB for RK3588) exhausts this space mid-`apt` and causes `ENOSPC` during post-install triggers (symptom: `E: Write error - write (28: No space left on device)` / `E: IO Error saving source cache`).

The fix is `resize_image_for_patching()`, which runs **before** the image is ever mounted:

1. `truncate -s "+${PATCH_RESIZE_MB}M"` — extends the raw `.img` file (sparse, no actual disk write for the added zeros)
2. `parted resizepart N 100%` — grows the last partition entry in the GPT/MBR to fill the new space
3. `e2fsck -f -y` — required pre-condition before resize2fs will proceed
4. `resize2fs` — expands the ext4 filesystem to fill the enlarged partition

This works for both single-partition (`p1`) and dual-partition (`p1`+`p2`) Armbian image layouts — it always targets the last partition, which is always the rootfs. The resized (larger) `.img` recompresses back to roughly the same `.img.xz` size because the added space is zeroed and XZ compresses zeros to almost nothing. `PATCH_RESIZE_MB` defaults to `256` and can be set to `0` to skip the step entirely.

### QEMU chroot

Any package installation during the patch stage (overlay, `PATCH_EXTRA_PKGS`) requires `qemu-<arch>-static` on the host + `binfmt_misc` registered. This is because `mkinitramfs` hooks execute arm64 binaries, so a plain `dpkg --root` won't work.

The `overlayroot` package is **not installed on Armbian by default** — never expect it to be present. It must be explicitly installed via chroot.

`busybox-static` is also **required by `overlayroot`** — it provides the shell and mount utilities the initramfs hook uses to pivot the tmpfs overlay at boot. Without it, the overlay pivot fails silently and the system boots write-through instead of read-only. Whenever `PATCH_OVERLAY != false`, both `overlayroot` and `busybox-static` are installed together automatically as part of the overlay install step.

### /var/tmp bind mount

When mounting the image during patch via qemu chroot, `mkinitramfs` writes scratch files to `/var/tmp`. Even after the image resize above, this scratch space is bound to a host tmpdir to keep the working files entirely off the image partition: `CHROOT_TMPDIR=$(mktemp -d); mount --bind "$CHROOT_TMPDIR" "${root}/var/tmp"`. Both protections are complementary — the resize gives the installed packages permanent space; the `/var/tmp` bind mount keeps the mkinitramfs working tree off the partition entirely.

### Warning messages during chroot

The OS inside the chroot prints a warning about filesystem size on mount. This is normal — the image file hasn't been resized, so the kernel sees a small partition. If you get actual errors (not warnings), the `/var/tmp` bind mount is the fix. The warning persists because the `.img` size stays the same.

### EXTRA_PKGS

Added to support baking packages into the bootstrap image that Ansible needs on the target. The chroot triggers when `PATCH_EXTRA_PKGS` is non-empty OR `PATCH_OVERLAY != false`. Both share the same chroot setup/teardown. The apt update runs once, packages install in order (extra first, then overlay), apt clean runs once at the end.

Current default: `PATCH_EXTRA_PKGS="btrfs-progs rsync parted gdisk dosfstools btrbk"` — everything the Ansible base provisioning needs on the target. `btrbk` in particular must be present before Ansible runs because `08-btrbk.yml` checks for it via `dpkg -l` and skips the `apt-get install` step if already installed; without it baked in, the chroot `apt-get` during provisioning would need network access inside the staging chroot.

### Overlay mode

When `PATCH_OVERLAY="tmpfs"`, the initramfs pivots the rootfs read-only and overlays tmpfs on top. All writes land in RAM. The SD card state is preserved exactly as patched — every reboot starts from the same state. **This is the normal intended usage for this pipeline.** It is essential for Ansible provisioning: the bootstrap system is identical every time regardless of what happened in previous Ansible runs.

Can be disabled (`PATCH_OVERLAY="false"`) to skip the qemu dependency, speed up the build, and allow state persistence between reboots. Useful if the Ansible playbook needs to maintain state across runs (unlikely for base provisioning, but possible for future multi-step workflows). Note that disabling overlay also removes the `qemu-user-static` requirement, but then `PATCH_EXTRA_PKGS` cannot be used either.

---

## Board Identity Architecture

### All bootstrap images are identical

By design, there is no per-board identification at the bootstrap patch phase. All images for the same board model are built equal — same hostname (`opi5-bootstrap`), same user, same SSH keys. If multiple boards boot simultaneously, they either fight for the same IP (static) or get random DHCP assignments.

### MAC addresses on RK3588

Orange Pi 5 / 5 Plus use the Rockchip RK3588 SoC. The MAC address is **not hardware-burned** — it's stored in a "vendor storage area" on the boot media. U-Boot reads it on boot; if empty (all zeros), it generates a random one and saves it to vendor storage.

Additionally, Armbian's `armbian-firstrun` service randomizes the MAC in `armbianEnv.txt` (`ethaddr`) on first boot. In overlay mode, firstrun runs on every boot because its "already ran" flag is lost with the tmpfs reset.

Result: the bootstrap MAC is **random but stable within a single boot session**. It changes across reboots. This is fine — Ansible identifies the board by whatever MAC is active at provisioning time, and that MAC gets permanently fixed in `armbianEnv.txt` on the installed NVMe system (where firstrun is disabled).

### Hostname assignment

Delegated entirely to Ansible. The `allocate-hostname.sh` script reads `base/inventory/hosts.ini`, finds the next available base-36 ID for the board model, and returns the hostname. The registry is append-only — entries are written only after a fully successful install.

Base-36 encoding: `[0-9A-Z][0-9A-Z]` = 1296 unique hosts per model. Format: `opi5-00`, `opi5-01`, ..., `opi5-09`, `opi5-0A`, ..., `opi5-ZZ`.

### Second-run behavior

If a previously-provisioned MAC connects and the playbook runs again, `allocate-hostname.sh` exits with code 2 and prints the existing hostname on stdout.

**Current behavior:** `02-hostname.yml` treats any non-zero exit code as failure (`when: _hostname_result.rc != 0`), so a re-run against an already-provisioned board will **hard-fail** at the hostname step. This is safe — it prevents accidental re-provisioning — but the error message comes from stderr and may be confusing. A future improvement would be to handle exit code 2 explicitly as a graceful "already provisioned" abort rather than a failure.

Missing/offline boards that are already in the registry are ignored — we only look up the MAC of the host we're currently talking to.

---

## Base Phase (Ansible)

### Password hash — shared with the patch stage

`secrets/password.hash` is generated once by `scripts/gen-password-hash.sh` and is **shared between both pipeline stages**:

- **patch stage** (`patch-image.sh`) — sets the password for the bootstrap SD-card user.
- **base stage** (`provision-base.yml`) — sets the admin user password on the NVMe-installed system.

The admin user on both the SD bootstrap image and the final NVMe system intentionally uses the same password hash. Run `gen-password-hash.sh` once before either stage.

The hash is passed to `create-user.sh` via **stdin** (not as a CLI argument) to prevent it from appearing in the process list (`/proc/*/cmdline`, `ps aux`). The calling Ansible task uses `no_log: true` for the same reason.

### Phase 5: Image source optimization

When `install_method=pull`, the playbook first checks if the controller already has the base image from the bootstrap build stage (`images/<board>/.pull-lock` + the actual `.img.xz` file). If it exists and the version matches (or no version is pinned), the image is streamed from the controller to the target via Ansible's `copy` module — no re-download needed. Falls back to direct download on the target using the URL from `.pull-lock`.

### Btrfs on OPi5/5+

`armbian-install` with btrfs is **broken** on Orange Pi 5 and 5 Plus. Multiple forum reports from 2023 through April 2025. U-Boot on RK3588 cannot reliably read btrfs. The solution is a separate ext4 `/boot` partition (512 MiB) with btrfs for the rest. We bypass `armbian-install` entirely and do everything manually: partition, format, subvolume create, rsync, configure boot.

### armbianEnv.txt

The `extraargs` line is space-delimited. **No quotes around values** — U-Boot silently ignores quoted `extraargs` content (confirmed via DietPi issue #5292). The `rootflags=subvol=@` line is critical for btrfs — without it, the kernel mounts the top-level subvolume (ID 5) instead of `@`.

### Btrfs subvolume layout

Flat layout with @-prefix (Ubuntu convention). All subvolumes are direct children of the top-level subvolume (ID 5). `@var_lib` was considered but kept inside `@` — separating it causes dpkg database inconsistency on root rollback.

### btrbk vs custom scripts

btrbk handles the retention policy engine (hourly/daily/weekly cleanup). Writing this from scratch in bash is the #1 source of bugs in custom snapshot scripts. btrbk is layout-independent, supports incremental send/receive for future backup targets, and is in the Debian repos.

btrbk does NOT do restores. Restore procedure: mount top-level, rename `@` → `@.broken`, snapshot the desired `@snapshots/root.YYYYMMDD` → `@`, reboot.

### NVMe partition alignment

Rockchip RK3588 boot ROM uses the first 16 MiB of SD/eMMC for bootloader stages. For NVMe booting via SPI flash, the NVMe doesn't contain the bootloader — U-Boot lives on SPI. The 16 MiB offset (sector 32768) on NVMe is technically unnecessary but harmless and consistent with Armbian conventions.

### Armbian firstrun service

`armbian-firstrun.service` does: SSH key regeneration, MAC randomization in armbianEnv.txt, UUID generation, board-specific hardware workarounds, hostname detection from device tree. On the installed NVMe system, we disable it entirely because we handle all of these ourselves. We also set `OPENSSHD_REGENERATE_HOST_KEYS=false` in `/etc/default/armbian-firstrun` as a belt-and-suspenders measure.

---

## Dependencies

| Phase | Tool | Notes |
|-------|------|-------|
| pull | `curl`, `jq`, `sha256sum`, `gpg` | `curl` handles all downloads with resume support (`-C -`) |
| patch | `xz`, `sha256sum`, `file`, `sudo` | kernel-side: `losetup`, `mount`, `umount`, `mountpoint` |
| patch (chroot) | `qemu-<arch>-static` | required for any `PATCH_EXTRA_PKGS` or `PATCH_OVERLAY != false` |
| base (controller) | `ansible`, `openssl` or `mkpasswd` | `openssl passwd -6` for password hashing |
| base (target) | `btrfs-progs`, `rsync`, `parted`, `gdisk`, `dosfstools`, `btrbk` | baked into image via `PATCH_EXTRA_PKGS`; `dosfstools` needed for `mkfs.ext4` on the boot partition; `btrbk` required by `08-btrbk.yml` (checked via `dpkg -l` before attempting install) |
