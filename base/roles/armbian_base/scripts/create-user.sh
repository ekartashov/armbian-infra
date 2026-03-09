#!/usr/bin/env bash
# scripts/create-user.sh — create admin user on the staged system
set -euo pipefail

staging="" user="" hash="" shell="/bin/bash" groups="sudo" pubkey=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging) staging="$2"; shift 2 ;;
    --user)    user="$2"; shift 2 ;;
    --shell)   shell="$2"; shift 2 ;;
    --groups)  groups="$2"; shift 2 ;;
    --pubkey)  pubkey="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read password hash from stdin to avoid exposing it in the process list
read -r hash

[[ -n "$staging" ]] || { echo "error: --staging required" >&2; exit 1; }
[[ -n "$user" ]]    || { echo "error: --user required" >&2; exit 1; }
[[ -n "$hash" ]]    || { echo "error: password hash required (pass via stdin)" >&2; exit 1; }

uid=1000
gid=1000
days_since_epoch=$(( $(date +%s) / 86400 ))

# ── Remove default users at UID 1000 ───────────────────────────────────────
# Fresh Armbian images may have a pre-created user
existing_user=$(awk -F: -v uid="$uid" '$3 == uid {print $1}' "${staging}/etc/passwd" 2>/dev/null || true)
if [[ -n "$existing_user" && "$existing_user" != "$user" ]]; then
  echo "removing default user: ${existing_user}"
  sed -i "/^${existing_user}:/d" "${staging}/etc/passwd"
  sed -i "/^${existing_user}:/d" "${staging}/etc/shadow"
  sed -i "/^${existing_user}:/d" "${staging}/etc/group"
  sed -i "s/,${existing_user}//" "${staging}/etc/group"
  sed -i "s/:${existing_user}$/:/" "${staging}/etc/group"
  rm -rf "${staging}/home/${existing_user}"
fi

# ── Create user ─────────────────────────────────────────────────────────────
if grep -q "^${user}:" "${staging}/etc/passwd" 2>/dev/null; then
  echo "user ${user} already exists — updating"
  sed -i "s|^${user}:[^:]*:|${user}:x:|" "${staging}/etc/passwd"
  sed -i "s|^${user}:[^:]*:|${user}:${hash}:|" "${staging}/etc/shadow"
else
  echo "${user}:x:${uid}:${gid}:Admin User:/home/${user}:${shell}" >> "${staging}/etc/passwd"
  echo "${user}:${hash}:${days_since_epoch}:0:99999:7:::" >> "${staging}/etc/shadow"
  # Create primary group if needed
  if ! grep -q "^${user}:" "${staging}/etc/group" 2>/dev/null; then
    echo "${user}:x:${gid}:" >> "${staging}/etc/group"
  fi
fi

# Add to supplementary groups
IFS=',' read -ra grp_list <<< "$groups"
for grp in "${grp_list[@]}"; do
  if grep -q "^${grp}:" "${staging}/etc/group"; then
    # Check if already a member
    if ! grep -q "^${grp}:.*:.*${user}" "${staging}/etc/group"; then
      if grep -q "^${grp}:[^:]*:[^:]*:$" "${staging}/etc/group"; then
        sed -i "s/^${grp}:\([^:]*\):\([^:]*\):$/\0${user}/" "${staging}/etc/group"
      else
        sed -i "s/^${grp}:\([^:]*\):\([^:]*\):\(.*\)/\0,${user}/" "${staging}/etc/group"
      fi
    fi
  fi
done

# ── Home directory ──────────────────────────────────────────────────────────
home="${staging}/home/${user}"
mkdir -p "$home"

if [[ -d "${staging}/etc/skel" ]]; then
  cp -a "${staging}/etc/skel/." "$home/" 2>/dev/null || true
fi

# ── SSH key ─────────────────────────────────────────────────────────────────
mkdir -p "$home/.ssh"
chmod 700 "$home/.ssh"

if [[ -n "$pubkey" ]]; then
  echo "$pubkey" > "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  echo "SSH pubkey deployed"
fi

chown -R "${uid}:${gid}" "$home"
chmod 700 "$home"

# ── Lock root ───────────────────────────────────────────────────────────────
sed -i 's|^root:[^:]*:|root:!:|' "${staging}/etc/shadow"

echo "user ${user} created (uid=${uid})"
