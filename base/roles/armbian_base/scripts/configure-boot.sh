#!/usr/bin/env bash
# scripts/configure-boot.sh — configure /boot/armbianEnv.txt for btrfs root
set -euo pipefail

staging="" root_uuid="" mac="" hdmi="false" hdmi_res="" hdmi_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging)          staging="$2"; shift 2 ;;
    --root-uuid)        root_uuid="$2"; shift 2 ;;
    --mac)              mac="$2"; shift 2 ;;
    --hdmi)             hdmi="$2"; shift 2 ;;
    --hdmi-resolution)  hdmi_res="$2"; shift 2 ;;
    --hdmi-output)      hdmi_out="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

env_file="${staging}/boot/armbianEnv.txt"
[[ -f "$env_file" ]] || { echo "error: ${env_file} not found" >&2; exit 1; }

# ── Helper: set a key=value line (replace if exists, append if not) ─────────
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

# ── Root filesystem settings ────────────────────────────────────────────────
set_env "rootdev" "UUID=${root_uuid}"
set_env "rootfstype" "btrfs"
set_env "rootflags" "subvol=@"

# ── Fixed MAC address ──────────────────────────────────────────────────────
if [[ -n "$mac" ]]; then
  set_env "ethaddr" "$mac"
fi

# ── extraargs: HDMI dummy plug ─────────────────────────────────────────────
if [[ "$hdmi" == "true" ]] || [[ "$hdmi" == "True" ]]; then
  video_arg="video=${hdmi_out}:${hdmi_res}"
  if grep -q "^extraargs=" "$env_file"; then
    current=$(grep "^extraargs=" "$env_file" | sed 's/^extraargs=//')
    # Remove any existing video= parameter
    current=$(echo "$current" | sed 's/video=[^ ]*//' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    if [[ -n "$current" ]]; then
      set_env "extraargs" "${current} ${video_arg}"
    else
      set_env "extraargs" "${video_arg}"
    fi
  else
    set_env "extraargs" "${video_arg}"
  fi
else
  # Remove video= from extraargs if present but HDMI disabled
  if grep -q "^extraargs=" "$env_file"; then
    current=$(grep "^extraargs=" "$env_file" | sed 's/^extraargs=//')
    cleaned=$(echo "$current" | sed 's/video=[^ ]*//' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    if [[ -n "$cleaned" ]]; then
      set_env "extraargs" "$cleaned"
    else
      sed -i '/^extraargs=$/d' "$env_file"
    fi
  fi
fi

echo "armbianEnv.txt configured:"
cat "$env_file"
