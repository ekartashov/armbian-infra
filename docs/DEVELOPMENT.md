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

**Current behavior:** `02-hostname.yml` detects exit code 2 and ends the play for that host gracefully using `ansible.builtin.meta: end_host`. A human-readable debug message is printed showing the existing hostname and how to force re-provisioning. The board is **not** re-provisioned and no error is raised — the playbook simply moves on to the next host.

To force re-provisioning of an already-provisioned board, remove or update its entry in `{{ registry_file }}` (typically `base/inventory/hosts.ini`) and re-run the playbook. A future improvement could add a `--extra-vars force_reprovision=true` flag to override this check without manual registry edits.

Missing/offline boards that are already in the registry are ignored — we only look up the MAC of the host we're currently talking to.

---

## Base Phase (Ansible)

### Gotcha: bash array syntax in inline Ansible shell tasks

**Never use bash array syntax in an inline `ansible.builtin.shell` block.** Ansible's Jinja2 templating engine processes the task body before handing it to the shell, and several bash constructs collide with Jinja2 syntax:

| Bash syntax | Jinja2 interpretation | Symptom |
|---|---|---|
| `arr=()` / `arr+=("x")` | unbalanced parentheses | task-load error: *missing=()* |
| `${#arr[@]}` | `{#` opens a Jinja2 comment | silently swallows the expression |
| `${arr[*]}` / `${arr[@]}` | `{` triggers variable interpolation | YAML/Jinja2 parse error at load time |

This is a **task-loading error**, meaning the playbook fails before it even runs a single task.

**Convention:** Extract any shell code that uses bash arrays, `${#...}`, or `${...[@]}` into a standalone script under `base/roles/armbian_base/scripts/` and call it via `ansible.builtin.script` instead:

```yaml
# ✗ Bad — Jinja2 parses ${#missing[@]} as a comment block
- name: Check tools
  ansible.builtin.shell: |
    missing=()
    for cmd in btrfs rsync; do
      command -v "$cmd" || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || exit 1
  args:
    executable: /bin/bash

# ✓ Good — complex bash lives in a script; no Jinja2 conflict
- name: Check tools
  ansible.builtin.script:
    cmd: "scripts/check-tools.sh btrfs rsync"
  changed_when: false
```

All scripts in `scripts/` accept their parameters as positional arguments (`"$@"`) so the Ansible task controls which tools/files/values are checked without hardcoding them in the script.

### Password hash — shared with the patch stage

`secrets/password.hash` is generated by `scripts/gen-password-hash.sh` and is **shared between both pipeline stages**:

- **patch stage** (`patch-image.sh`) — sets the password for the bootstrap SD-card user.
- **base stage** (`provision-base.yml`) — sets the admin user password on the NVMe-installed system.

The admin user on both the SD bootstrap image and the final NVMe system intentionally uses the same password hash.

**`gen-password-hash.sh` is flexible — it supports several calling modes:**

```bash
# One-time interactive setup (writes secrets/password.hash):
./scripts/gen-password-hash.sh

# Overwrite an existing file:
./scripts/gen-password-hash.sh --force

# Write to a custom path:
./scripts/gen-password-hash.sh --output /some/other/path

# Print hash to stdout (non-interactive, password from stdin):
echo "$password" | ./scripts/gen-password-hash.sh --stdout

# Generate and save to a custom path non-interactively:
echo "$password" | ./scripts/gen-password-hash.sh --output /path/to/hash
```

The Ansible playbook (`provision-base.yml`) calls `gen-password-hash.sh --stdout` when it needs to hash a prompted password inline — this keeps hashing logic in one canonical script rather than duplicating `openssl passwd` calls. The hash is passed to `create-user.sh` via **stdin** (not as a CLI argument) to prevent it from appearing in the process list (`/proc/*/cmdline`, `ps aux`). The calling Ansible task uses `no_log: true` for the same reason.

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

### Boot troubleshooting

If the board drops into an initramfs shell on first boot after provisioning, the following diagnostics apply.

#### Symptom: `mount: No such file or directory` / empty mount point in fstab

The Jinja2 `default()` filter **does not activate on empty strings** — it only triggers on undefined values. The fstab template uses `regex_replace('/$', '')` to strip trailing slashes from mount paths, which turns `/` into an empty string. Without the `true` parameter (`default('/', true)`), the root subvolume gets an empty mount point in `/etc/fstab` and the kernel cannot mount root.

From the initramfs shell, confirm with:

```
cat /etc/fstab        # look for a line with an empty second column
```

Always use `default('<fallback>', true)` when the preceding filter can produce an empty string.

#### Symptom: `run-init: opening console: No such file or directory`

`/dev/console` does not exist in the target root. The provisioning script creates it with `mknod` if absent. If this reoccurs, check that `09-finalize.yml` ran without errors and that the staging root `/dev` was not wiped before the `mknod` step.

#### Symptom: kernel panics with "no init found" / btrfs not recognised

The initramfs doesn't include the `btrfs` kernel module. `update-initramfs` normally detects the root filesystem type from `/etc/fstab`; if fstab was wrong (see above) or `update-initramfs` failed silently, the module is omitted.

`09-finalize.yml` now explicitly writes `btrfs` to `/etc/initramfs-tools/modules` before calling `update-initramfs`, and uses `update-initramfs -u -v` (without `|| true`) so any failure is fatal and visible.

#### General debug procedure from the initramfs shell

```sh
# List available block devices
ls /dev/nvme* /dev/sd* 2>/dev/null

# Try to mount root manually
mkdir /mnt/root
mount -t btrfs -o subvol=@ /dev/nvme0n1p2 /mnt/root

# Inspect fstab and init
cat /mnt/root/etc/fstab
ls /mnt/root/sbin/init /mnt/root/lib/systemd/systemd 2>/dev/null

# Check initramfs module list
cat /mnt/root/etc/initramfs-tools/modules
```

#### Boot readiness check

After unmounting the staging tree, `09-finalize.yml` re-mounts the root subvolume read-only and verifies:

- `/boot/initrd.img-*` exists
- `/boot/vmlinuz-*` or `/boot/Image` exists
- `/boot/armbianEnv.txt` exists
- `/etc/fstab` is non-empty
- `/sbin/init`, `/usr/sbin/init`, or `/lib/systemd/systemd` exists

The playbook fails loudly if any of these are missing, so boot problems are caught at provision time rather than at the board's first reboot.

---

## Dependencies

| Phase | Tool | Notes |
|-------|------|-------|
| pull | `curl`, `jq`, `sha256sum`, `gpg` | `curl` handles all downloads with resume support (`-C -`) |
| patch | `xz`, `sha256sum`, `file`, `sudo` | kernel-side: `losetup`, `mount`, `umount`, `mountpoint` |
| patch (chroot) | `qemu-<arch>-static` | required for any `PATCH_EXTRA_PKGS` or `PATCH_OVERLAY != false` |
| base (controller) | `ansible`, `openssl` or `mkpasswd` | `openssl passwd -6` for password hashing |
| base (target) | `btrfs-progs`, `rsync`, `parted`, `gdisk`, `dosfstools`, `btrbk` | baked into image via `PATCH_EXTRA_PKGS`; `dosfstools` needed for `mkfs.ext4` on the boot partition; `btrbk` required by `08-btrbk.yml` (checked via `dpkg -l` before attempting install) |
