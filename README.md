# Armbian Infra

Bootstraps and provisions Orange Pi 5 / 5 Plus boards onto NVMe with btrfs via a two-phase pipeline: **pull + patch** (SD bootstrap image), **base** (Ansible NVMe provisioning).

---

## Directory layout

```
armbian-infra/
  config/
    defaults.env                  # shared pull+patch defaults
    boards/
      orangepi5.env
      orangepi5-plus.env
  keys/
    armbian-release.asc           # Armbian GPG signing key (committed)
  libs/
    require.sh                    # shared logging, require(), load_config()
    boards.sh                     # list_boards(), list_pulled_boards(), etc.
  scripts/
    setup-gpg-key.sh              # one-time: fetch and commit Armbian GPG key
    pull-image.sh                 # download + verify Armbian images
    patch-image.sh                # patch images for bootstrap
    clean.sh                      # remove generated artifacts
    gen-password-hash.sh          # generate secrets/password.hash
    gen-ssh-keypair.sh            # generate secrets/ssh/id_ed25519
  templates/
    sshd_config                   # deployed to patched image + NVMe target
  base/                           # Ansible: provisions bootstrap → NVMe
    ansible.cfg
    inventory/
      hosts.ini                   # MAC→hostname registry (append-only)
      group_vars/
        all.yml
    playbooks/
      provision-base.yml
    roles/
      armbian_base/
        defaults/main.yml
        tasks/                    # 01-preflight through 10-register
        scripts/                  # bash scripts called by tasks
        templates/                # fstab.j2, btrbk.conf.j2, etc.
        handlers/main.yml
  docs/
    DEVELOPMENT.md                # gotchas, architecture decisions, knowledge base
  secrets/                        # gitignored
  cache/                          # gitignored
  images/
    orangepi5/
    orangepi5-plus/
    patched/
```

---

## Pipeline stages

### 1 · pull

Downloads, verifies, and version-pins Armbian images.

```bash
./scripts/pull-image.sh [--board <board>] [--all] [--refresh]
```

Boards: `orangepi5`, `orangepi5-plus`. Resolves from `https://www.armbian.com/all-images.json`. Saves a `.pull-lock` alongside the image with the pinned version, SHA256, and download URL.

### 2 · patch

Patches the pulled image for bootstrap use: sets hostname, user, SSH key, installs extra packages, and configures tmpfs overlay.

```bash
./scripts/patch-image.sh [--board <board>] [--all]
```

Produces `images/patched/<board>.img.xz` + `.patch-lock`.

### 3 · provision-base (Ansible)

Provisions a booted bootstrap board (SD card, overlay mode, SSH-accessible) onto NVMe with:

- GPT partition table: ext4 `/boot` + btrfs root
- Flat btrfs subvolume layout: `@`, `@home`, `@snapshots`, `@var_log`, `@srv`
- Unique hostname from MAC→hostname registry (`base/inventory/hosts.ini`)
- Admin user with pre-hashed password, SSH key, passwordless sudo
- Armbian firstrun disabled, SSH host keys regenerated
- btrbk snapshot infrastructure with systemd timer
- Golden image snapshot for rollback

Image source optimisation: if the controller already has the base image from the pull stage, it streams the local file instead of re-downloading.

```bash
cd base
ansible-playbook -i "10.42.0.5," -u admin \
  --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml \
  --extra-vars "sbc_model=opi5"
```

---

## Quick start

```bash
# 1. One-time setup
./scripts/setup-gpg-key.sh
./scripts/gen-ssh-keypair.sh
./scripts/gen-password-hash.sh   # used by BOTH the patch stage and Ansible base stage

# 2. Pull + patch the bootstrap image
./scripts/pull-image.sh --board orangepi5
./scripts/patch-image.sh --board orangepi5

# 3. Flash images/patched/orangepi5.img.xz to SD, boot board, find its IP

# 4. Provision onto NVMe
cd base
ansible-playbook -i "10.42.0.X," -u admin \
  --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml \
  --extra-vars "sbc_model=opi5"

# 5. Remove SD card, reboot — board boots from NVMe
```

---

## Configuration

### Pull parameters (`config/defaults.env` — pull section)

| Variable | Default | Notes |
|---|---|---|
| `ARMBIAN_DISTRO` | `trixie` | Debian codename |
| `ARMBIAN_BRANCH` | `current` | `current` \| `edge` \| `vendor` |
| `ARMBIAN_VARIANT` | `minimal` | `minimal` \| `server` \| `desktop` |
| `ARMBIAN_VERSION` | _(empty)_ | Pin a specific version; empty = latest |
| `ARMBIAN_CATALOG_MAX_AGE` | `3600` | Catalog cache TTL in seconds |

### Patch parameters (`config/defaults.env` — patch section)

| Variable | Default | Notes |
|---|---|---|
| `PATCH_USER` | `admin` | Bootstrap OS username |
| `PATCH_ROOT_MODE` | `locked` | `locked` \| `password` — whether root has a usable password |
| `PATCH_XZ_LEVEL` | `6` | XZ recompression level (6 = Armbian default) |
| `PATCH_OVERLAY` | `tmpfs` | **Normal usage.** Configures a tmpfs overlay on boot so the SD card stays read-only — every reboot starts from the exact same patched state. This is essential for idempotent Ansible provisioning runs. Set to `false` only if you need write-persistent state across reboots (unusual). Requires `qemu-user-static` on the host. |
| `PATCH_RESIZE_MB` | `256` | Extra MiB added to the rootfs partition before patching. Prevents `ENOSPC` during `apt`/`mkinitramfs`. Set to `0` to skip resize. |
| `PATCH_EXTRA_PKGS` | `btrfs-progs rsync parted gdisk dosfstools btrbk` | Packages baked into the image via chroot `apt`. Everything Ansible needs pre-installed on the target. Requires `qemu-user-static`. |

### Ansible parameters (`base/inventory/group_vars/all.yml`)

| Variable | Default | Notes |
|---|---|---|
| `install_method` | `pull` | `pull` = fresh image (local-first); `copy` = clone live system |
| `sbc_model` | `opi5` | `opi5` or `opi5p` — determines hostname prefix |
| `enable_hdmi_dummyplug` | `false` | Adds `video=` to `armbianEnv.txt` `extraargs` |
| `enable_btrbk` | `true` | Install and configure btrbk snapshot timer |
| `admin_user` | `admin` | Username on the installed system |
| `admin_password_hash` | _(auto)_ | Reads `secrets/password.hash` or prompts |

See `base/inventory/group_vars/all.yml` for the full list.

---

## Dependencies

| Phase | Tool | Notes |
|---|---|---|
| pull | `curl`, `jq`, `sha256sum`, `gpg` | `curl` handles all downloads with resume support (`-C -`) |
| patch | `xz`, `sha256sum`, `file`, `sudo` | kernel-side: `losetup`, `mount`, `umount`, `mountpoint` |
| patch (chroot) | `qemu-<arch>-static` | required for any `PATCH_EXTRA_PKGS` or `PATCH_OVERLAY != false` |
| base (controller) | `ansible`, `openssl` or `mkpasswd` | `openssl passwd -6` for password hashing |
| base (target) | `btrfs-progs`, `rsync`, `parted`, `gdisk`, `dosfstools`, `btrbk` | baked into image via `PATCH_EXTRA_PKGS`; `btrbk` is also required by subsequent Ansible stages (`08-btrbk.yml`) |
