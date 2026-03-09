# armbian-infra

Provisions Orange Pi 5 / 5 Plus boards from a blank SD card to a fully configured NVMe system running Armbian on btrfs. Three pipeline stages: **pull** (download image), **patch** (customize SD bootstrap), **base** (Ansible installs to NVMe).

---

## Prerequisites

**Controller machine (your laptop/workstation):**
- `ansible`, `openssl`, `ssh-keygen`, `curl`, `jq`, `gpg`, `xz`, `sha256sum`
- `sudo`, `losetup`, `mount` (for patching)
- `qemu-user-static` + `binfmt-support` (required if `PATCH_OVERLAY=tmpfs` or `PATCH_EXTRA_PKGS` is set — the default)

**Target board:**
- SD card with the patched image booted (board reachable over SSH)
- NVMe drive attached

---

## First-time setup (run once per controller)

```bash
./scripts/setup-gpg-key.sh       # fetch and commit Armbian GPG signing key
./scripts/gen-ssh-keypair.sh      # creates secrets/ssh/id_ed25519{,.pub}
./scripts/gen-password-hash.sh    # creates secrets/password.hash  (prompts interactively)
```

These three files are gitignored and stay on the controller. Every board provisioned from this directory will use the same keypair and password hash.

---

## Core workflow — provision one board

This is the full end-to-end for an Orange Pi 5. Run from the repo root unless noted.

### 1. Download and verify the Armbian image

```bash
./scripts/pull-image.sh --board orangepi5
```

Downloads the latest (or pinned) image to `images/orangepi5/`, verifies GPG + SHA256, writes `images/orangepi5/.pull-lock`.

### 2. Patch the image for bootstrap

```bash
./scripts/patch-image.sh --board orangepi5
```

Produces `images/patched/orangepi5.img.xz`. Applies: fixed hostname, admin user + SSH key, extra packages baked in, tmpfs overlay so the SD stays read-only on every boot.

### 3. Flash the SD card

```bash
xz -dc images/patched/orangepi5.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with your SD card device.

### 4. Boot the board, find its IP

Insert SD, power on. The board boots as `opi5-bootstrap`. Find its IP via your router/DHCP leases or a network scan, e.g.:

```bash
nmap -sn 10.42.0.0/24
```

### 5. Provision onto NVMe

```bash
cd base
ansible-playbook -i 10.42.0.X, \
  -u admin \
  --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml \
  --extra-vars sbcmodel=opi5
```

The trailing comma after the IP is required (it makes it an inline inventory).

Ansible will:
- Assign a unique hostname from the MAC↔hostname registry (`inventory/hosts.ini`)
- Partition the NVMe (512 MiB ext4 boot + btrfs root)
- Create btrfs subvolumes: `/`, `home`, `snapshots`, `varlog`, `srv`
- Install Armbian (streams local image from controller if available, otherwise downloads)
- Create the admin user, deploy SSH key, disable firstrun, regenerate host keys
- Configure btrbk with hourly snapshots
- Take a `root.golden` snapshot for rollback
- Register the board in `inventory/hosts.ini`

### 6. Remove SD card, reboot

```bash
ssh admin@10.42.0.X "sudo reboot"
```

The board boots from NVMe as its assigned hostname (e.g. `opi5-00`).

```bash
ssh -i secrets/ssh/id_ed25519 admin@opi5-00
```

---

## Orange Pi 5 Plus

Identical workflow — replace `orangepi5` with `orangepi5-plus` in pull/patch, and `opi5` with `opi5p` in `--extra-vars`:

```bash
./scripts/pull-image.sh  --board orangepi5-plus
./scripts/patch-image.sh --board orangepi5-plus
# flash, boot ...
ansible-playbook ... --extra-vars sbcmodel=opi5p
```

---

## Ansible variables reference

Set any of these via `--extra-vars key=value` or edit `base/inventory/group_vars/all.yml` for permanent defaults.

| Variable | Default | Notes |
|---|---|---|
| `sbcmodel` | `opi5` | `opi5` or `opi5p` |
| `install_method` | `pull` | `pull` = fresh image (local-first then download); `copy` = rsync live SD |
| `admin_user` | `admin` | Username created on the NVMe system |
| `admin_password_hash` | *(auto)* | See [Password management](#password-management) |
| `admin_ssh_pubkey` | *(auto)* | Reads `secrets/ssh/id_ed25519.pub` if not set |
| `enable_btrbk` | `true` | Install and enable hourly btrbk snapshot timer |
| `enable_golden_snapshot` | `true` | Take a `root.golden` btrfs snapshot after install |
| `enable_hdmi_dummy_plug` | `false` | Add `video=` arg to `armbianEnv.txt` |
| `hdmi_resolution` | `1920x1080M-32@60D` | Used when dummy plug is enabled |
| `nvme_device` | `/dev/nvme0n1` | Target block device |
| `boot_partition_size_mb` | `512` | Size of ext4 `/boot` partition |
| `btrfs_mount_options` | `compress=zstd:1,noatime,ssd` | Applied to all btrfs mounts |

---

## Patch stage variables reference

Set in `config/defaults.env` (shared) or `config/boards/<board>.env` (per-board).

| Variable | Default | Notes |
|---|---|---|
| `PATCH_USER` | `admin` | Bootstrap OS username |
| `PATCH_ROOT_MODE` | `locked` | `locked` = root has no password; `password` = uses `secrets/password.hash` |
| `PATCH_OVERLAY` | `tmpfs` | `tmpfs` = SD stays read-only, every boot is identical (recommended); `false` = persistent writes |
| `PATCH_RESIZE_MB` | `256` | MiB added to image rootfs before patching — prevents ENOSPC during apt/mkinitramfs |
| `PATCH_EXTRA_PKGS` | `btrfs-progs rsync parted gdisk dosfstools btrbk` | Baked into SD via chroot apt. Requires `qemu-user-static`. |
| `PATCH_XZ_LEVEL` | `6` | Recompression level for patched image output |
| `ARMBIAN_VERSION` | *(empty)* | Pin a specific version; empty = latest |
| `ARMBIAN_DISTRO` | `trixie` | Debian codename |
| `ARMBIAN_BRANCH` | `current` | `current`, `edge`, or `vendor` |
| `ARMBIAN_VARIANT` | `minimal` | `minimal`, `server`, or `desktop` |

---

## Password management

`secrets/password.hash` is a single SHA-512 hash shared by all boards provisioned from this controller. It is used by both the patch stage (SD bootstrap user) and the base stage (NVMe admin user).

**Resolution order — first match wins:**

1. `--extra-vars adminpasswordhash='$6$...'` — per-run override, does not touch the file
2. `secrets/password.hash` — auto-read on every run
3. Interactive prompt — hashes what you type, saves to `secrets/password.hash`

**Regenerate the stored hash:**
```bash
./scripts/gen-password-hash.sh --force
```

**Per-run override without touching `secrets/password.hash`:**
```bash
hash=$(echo 'mypassword' | ./scripts/gen-password-hash.sh --stdout)
ansible-playbook ... --extra-vars "sbcmodel=opi5 adminpasswordhash=${hash}"
```
> Use `"..."` with `${hash}` pre-expanded — never paste a raw `$6$...` hash inside single quotes directly after `--extra-vars`, the `$` signs will be mis-interpreted by the shell.

---

## SSH keys

| Key | Location | Scope | Managed by |
|---|---|---|---|
| Operator key (client) | `secrets/ssh/id_ed25519` | Goes into `authorized_keys` on every board | `gen-ssh-keypair.sh` |
| SSH host keys (server identity) | `/etc/ssh/ssh_host_*` on each board | Per-board, unique | Regenerated in Phase 7 of provisioning |

The operator private key never leaves the controller (`secrets/` is gitignored). If you need to rotate the operator key, regenerate with `./scripts/gen-ssh-keypair.sh --force` and re-provision affected boards.

---

## Hostname assignment

Hostnames are automatically assigned from the board's MAC address and stored in `base/inventory/hosts.ini`. The format is `opi5-00` through `opi5-ZZ` (base-36, 1296 slots per model).

- If a board is already in the registry, provisioning skips it (prints the existing hostname, no error).
- To re-provision an existing board, remove or update its line in `base/inventory/hosts.ini` and re-run.
- Concurrent provisioning is safe — the allocator uses `flock` and `serial: 1` is set in the playbook.

---

## Common operations

**Provision multiple boards one at a time:**
```bash
# Pass multiple IPs — serial: 1 ensures they run sequentially
cd base
ansible-playbook -i "10.42.0.5,10.42.0.6,10.42.0.7," \
  -u admin --private-key ../secrets/ssh/id_ed25519 \
  playbooks/provision-base.yml --extra-vars sbcmodel=opi5
```

**Re-use a locally cached image (skip download):**
If `images/orangepi5/.pull-lock` exists and the version matches, the playbook streams the image from the controller automatically — no action needed.

**Rebuild the patched image (e.g. after changing PATCH_EXTRA_PKGS):**
```bash
./scripts/patch-image.sh --board orangepi5 --force
```

**Roll back a board to its golden snapshot:**
```bash
ssh admin@opi5-00
sudo btrfs subvolume snapshot /mnt/btrfs-root/snapshots/root.golden /mnt/btrfs-root/@
# update /boot/armbianEnv.txt rootflags to point to the new subvol, then reboot
```

**Check what images are available locally:**
```bash
./scripts/clean.sh --dry-run --all    # preview what exists / would be removed
```

**Wipe all generated secrets and start fresh:**
```bash
./scripts/clean.sh --secrets          # removes password.hash and SSH keypair
./scripts/gen-ssh-keypair.sh
./scripts/gen-password-hash.sh
```

**Wipe everything (nuclear reset):**
```bash
./scripts/clean.sh --all
```

---

## Directory layout

```
armbian-infra/
├── config/
│   ├── defaults.env          # shared pull + patch config
│   └── boards/
│       ├── orangepi5.env     # board-specific overrides
│       └── orangepi5-plus.env
├── scripts/                  # pull-image, patch-image, gen-*, clean, setup-gpg-key
├── templates/
│   └── sshdconfig            # deployed to both patched SD and NVMe target
├── libs/                     # shared bash: require.sh, boards.sh
├── base/                     # Ansible tree
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.ini         # MAC↔hostname registry (append-only, commit this)
│   │   └── group_vars/all.yml
│   ├── playbooks/
│   │   └── provision-base.yml
│   └── roles/armbian/base/
│       ├── defaults/main.yml
│       ├── tasks/            # 01-preflight through 10-register
│       ├── scripts/          # bash helpers called by tasks
│       └── templates/        # fstab.j2, btrbk.conf.j2, etc.
├── docs/
│   └── DEVELOPMENT.md        # architecture decisions and gotchas
├── secrets/                  # ← gitignored, stays on controller
│   ├── password.hash
│   └── ssh/id_ed25519{,.pub}
├── images/                   # ← gitignored
│   ├── orangepi5/            # downloaded raw images + .pull-lock
│   ├── orangepi5-plus/
│   └── patched/              # output of patch-image.sh + .patch-lock
└── cache/                    # ← gitignored (catalog JSON)
```

---

## Troubleshooting

**Board not reachable after flashing SD:**
Verify the SD image flashed cleanly. The bootstrap hostname is `opi5-bootstrap` (or `opi5plus-bootstrap`). Check DHCP leases. SSH uses port 22, key auth only — password login is disabled.

**`qemu-user-static` errors during patch:**
Install `qemu-user-static` and `binfmt-support` on the controller, then restart `systemd-binfmt`: `sudo systemctl restart systemd-binfmt`.

**Ansible fails mid-run — board already in registry as `allocating`:**
Re-run the playbook unchanged. The allocator treats `allocating` entries as recoverable and re-uses the same hostname slot.

**NVMe not found:**
Confirm the drive is attached and `nvme_device` in `group_vars/all.yml` matches the actual device path (`/dev/nvme0n1` is the default).

**`VERIFY FAILED` in Phase 9 (armbianEnv.txt check):**
The `configure-boot.sh` script detected a missing required key. Check that `rootfstype=btrfs`, `rootflags=subvol=...`, `rootdev=UUID=...`, and `ethaddr=<mac>` are all present in `/boot/armbianEnv.txt` on the staging root.
