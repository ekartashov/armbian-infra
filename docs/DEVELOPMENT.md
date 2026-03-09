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

Delegated entirely to Ansible. The `allocate-hostname.sh` script reads `base/inventory/hosts.ini`, finds the next available base-36 ID for the board model, and returns the hostname.

**Concurrency safety:** the script acquires an exclusive `flock(1)` lock on `${registry}.lock` before reading the registry, computing the next ID, and writing a tentative `allocating` entry. The lock is released only after the entry is written, so two concurrent invocations are guaranteed to see each other's in-progress allocation and will never produce duplicate hostnames.

**Tentative entries:** immediately after computing a hostname the script appends a line like `aa:bb:cc:dd:ee:ff  opi5-00  allocating` to the registry. The `10-register.yml` task later updates this line (matched by MAC address via `lineinfile` regexp) to `provisioned` status. If provisioning fails after allocation the `allocating` entry remains in the registry; on the next run the script treats `allocating` the same as `failed` — the board re-provisions with the same previously-allocated hostname so the slot is not wasted.

**Sequential provisioning:** `provision-base.yml` sets `serial: 1`, which ensures boards are provisioned one at a time even when multiple IPs are passed in the inventory string. This is the primary defence against shared-state races (hostname allocation, `/tmp` paths in `install-image.sh`, etc.). The `flock` locking is a second layer of protection. Do not remove `serial: 1` without auditing every shared-state concern first.

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

**The hash is per-project, not per-host or per-user.** One `secrets/password.hash` file is shared across every board provisioned from the same controller directory. All boards get the same admin password.

**`provision-base.yml` resolves the hash via a cascade (first match wins):**

1. `--extra-vars "admin_password_hash='$6$...'"` — explicit override, highest priority.
2. `secrets/password.hash` on the controller — auto-read if the file exists.
3. Interactive prompt during the playbook run — the entered password is SHA-512 hashed and **automatically saved to `secrets/password.hash`** so subsequent runs skip the prompt.

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

---

## Boot Troubleshooting

### System drops into initramfs after provisioning

If the board boots into an initramfs prompt with messages like:

```
mount: No such file or directory
mount: invalid option --
Target filesystem doesn't have requested /sbin/init.
run-init: opening console: No such file or directory
No init found. Try passing init= bootarg.
(initramfs) _
```

Several issues can compound to produce this. Check them in order:

**1. fstab root mount point is empty**

`/etc/fstab` in the installed system must have `/` as the mount point for the root btrfs subvolume. Verify:

```bash
grep ' btrfs ' /mnt/root/etc/fstab
```

Expected output includes a line with `UUID=...   /   btrfs   subvol=@,...`. If the mount point column is blank, the `fstab.j2` template has a bug — `regex_replace('/$', '') | default('/')` produces an empty string for `/` because Jinja2's `default()` only triggers on `undefined`, not on empty strings. The fix is `default('/', true)` (the `true` parameter makes it also trigger on empty/falsy values).

**2. btrfs module missing from initramfs**

The initramfs must include the `btrfs` kernel module to mount the root filesystem. Check:

```bash
lsinitramfs /mnt/root/boot/initrd.img-* | grep btrfs
```

If `btrfs.ko` is not listed, `btrfs` was not in `/etc/initramfs-tools/modules` when `update-initramfs` ran. Re-provision or manually add `btrfs` to that file and run `update-initramfs -u` in chroot.

**3. `/dev/console` missing in target root**

`run-init: opening console: No such file or directory` means the target's `/dev/console` character device does not exist. This can happen because rsync from the base image excludes `/dev/*`. Verify:

```bash
ls -la /mnt/root/dev/console /mnt/root/dev/null
```

If missing, recreate them:

```bash
mknod -m 622 /mnt/root/dev/console c 5 1
mknod -m 666 /mnt/root/dev/null    c 1 3
```

**4. initramfs generation failed silently**

If `update-initramfs` exits non-zero but is called with `|| true`, the playbook appears to succeed but the initramfs may be absent or stale. Always verify:

```bash
ls -lh /mnt/root/boot/initrd.img-*
```

If no file exists, the kernel cannot boot.

**5. SSH host keys not regenerated**

After the `rsync` copy from the base image, the target has the same SSH host keys as the source image. `09-finalize.yml` removes existing keys and runs `ssh-keygen -A` inside chroot to generate fresh unique keys per board. If this step is skipped or fails, sshd may refuse to start or every board will share identical host keys.


**6. `rootflags=subvol=@` silently ignored — kernel mounts btrfs top level**

`boot.scr` builds `bootargs` from:
```
root=${rootdev} rootfstype=${rootfstype} ... ${extraargs} ${extraboardargs}
```
The variable `${rootflags}` is **never read**. A standalone `rootflags=subvol=@`
line in `armbianEnv.txt` is therefore silently ignored. The kernel mounts btrfs
subvolume ID 5 (the top level) instead of `@`. Because `${toplevelmount}/@/dev`
does not contain device nodes, the `/dev` move in the initramfs fails and
`run-init` cannot find `/sbin/init`, producing the full error cascade.

**Fix:** embed `rootflags=subvol=@` inside `extraargs=`. `configure-boot.sh` now
does this automatically. To verify manually:

```bash
grep '^extraargs=' /mnt/target/boot/armbianEnv.txt
# must contain: rootflags=subvol=@
```

**Root cause in code:** `configure-boot.sh` was missing the closing `}` of the
`set_env()` function, so all `set_env` calls below it were inside the function
body and never ran at the top level. The extraargs injection block — added later
to work around the boot.scr limitation — was also inside the function for the
same reason.

---

## Running the Ansible Playbook Partially

Ansible doesn't have named "stages" or "steps" as a built-in concept — but
there are several ways to run only part of a playbook.

### Preview all task names

Before running anything, see every task name in order:

```bash
cd base/
ansible-playbook -i "10.42.0.5," -u admin \
  --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml \
  --extra-vars "sbc_model=opi5" \
  --list-tasks
```

### Resume from a specific task

`--start-at-task` skips everything before the named task and resumes from there:

```bash
ansible-playbook -i "10.42.0.5," -u admin \
  --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml \
  --extra-vars "sbc_model=opi5" \
  --start-at-task "Configure armbianEnv.txt"
```

> **Heads-up:** tasks that set variables (e.g. "Parse UUIDs") are also skipped
> if they come before the resume point. Pass missing values via `--extra-vars`:
>
> ```bash
> --extra-vars "sbc_model=opi5 root_uuid=<uuid> boot_uuid=<uuid> target_hostname=opi5-01"
> ```
>
> Run `--list-tasks` first and check which `set_fact` tasks precede your entry
> point.

### Common partial-run scenarios

| Goal | `--start-at-task` value |
|------|------------------------|
| Re-run boot config only | `"Configure armbianEnv.txt"` |
| Re-run from install onward | `"Deploy image to target filesystem"` |
| Re-run initramfs rebuild only | `"Update initramfs (ensure btrfs modules are included)"` |
| Re-run verify + snapshot + unmount | `"Verify armbianEnv.txt configuration"` |

### Interactive step-by-step

Ansible pauses before each task and asks `y` (run it), `n` (skip it), or `c`
(run all remaining without pausing):

```bash
ansible-playbook ... --step
```

### Dry run (check mode)

Shows what *would* change without touching anything. Useful to verify
`--extra-vars` are resolved correctly before a real run. Note: `shell` and
`script` tasks that read actual system state may report incorrect results in
check mode since nothing has actually been changed yet.

```bash
ansible-playbook ... --check
```

### Target a single board when inventory has many

```bash
ansible-playbook -i inventory/hosts.ini -u admin \
  --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml \
  --extra-vars "sbc_model=opi5" \
  --limit "10.42.0.5"
```

---

| Phase | Tool | Notes |
|-------|------|-------|
| pull | `curl`, `jq`, `sha256sum`, `gpg` | `curl` handles all downloads with resume support (`-C -`) |
| patch | `xz`, `sha256sum`, `file`, `sudo` | kernel-side: `losetup`, `mount`, `umount`, `mountpoint` |
| patch (chroot) | `qemu-<arch>-static` | required for any `PATCH_EXTRA_PKGS` or `PATCH_OVERLAY != false` |
| base (controller) | `ansible`, `openssl` or `mkpasswd` | `openssl passwd -6` for password hashing |
| base (target) | `btrfs-progs`, `rsync`, `parted`, `gdisk`, `dosfstools`, `btrbk` | baked into image via `PATCH_EXTRA_PKGS`; `dosfstools` needed for `mkfs.ext4` on the boot partition; `btrbk` required by `08-btrbk.yml` (checked via `dpkg -l` before attempting install) |
