#!/usr/bin/env bash
# scripts/allocate-hostname.sh — allocate a hostname from the MAC registry
# Called on the Ansible controller (delegate_to: localhost).
#
# Usage: allocate-hostname.sh --mac AA:BB:CC:DD:EE:FF --model opi5 --registry path/to/hosts.ini
# Stdout (last line): the allocated hostname (e.g., opi5-00)
# Exit 0: success (hostname on stdout)
# Exit 1: error (message on stderr)
# Exit 2: MAC already provisioned (hostname on stdout, message on stderr)
#
# Concurrency: uses flock(1) on "${registry}.lock" for mutual exclusion.
# A tentative "allocating" entry is written to the registry before the lock
# is released, so concurrent invocations see each other's in-progress allocation.
# If provisioning fails after allocation, the "allocating" entry is treated the
# same as "failed" on the next run — the board re-provisions with the same hostname.

set -euo pipefail

mac="" model="" registry=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac)      mac="$2"; shift 2 ;;
    --model)    model="$2"; shift 2 ;;
    --registry) registry="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$mac" ]]      || { echo "error: --mac required" >&2; exit 1; }
[[ -n "$model" ]]    || { echo "error: --model required" >&2; exit 1; }
[[ -n "$registry" ]] || { echo "error: --registry required" >&2; exit 1; }

mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')

# ── Base-36 helpers ──────────────────────────────────────────────────────────

# Chars: 0-9 A-Z (uppercase in hostnames)
B36_CHARS="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

int_to_b36() {
  local n=$1
  local hi=$(( n / 36 ))
  local lo=$(( n % 36 ))
  echo "${B36_CHARS:$hi:1}${B36_CHARS:$lo:1}"
}

b36_to_int() {
  local s=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  local hi lo
  hi=$(expr index "$B36_CHARS" "${s:0:1}" 2>/dev/null) || hi=0
  lo=$(expr index "$B36_CHARS" "${s:1:1}" 2>/dev/null) || lo=0
  echo $(( (hi - 1) * 36 + (lo - 1) ))
}

# ── Check registry (with exclusive lock) ────────────────────────────────────

touch "$registry"

# Acquire exclusive lock on the registry file for the entire read-compute-write
# section.  This prevents two concurrent provisioning runs from computing the
# same next ID and colliding on a hostname.
# The .lock file persists after the script exits — this is intentional and
# harmless (it is listed in .gitignore).  The kernel lock is released when fd 9
# is closed (either explicitly below or automatically on script exit).
exec 9>"${registry}.lock" \
  || { echo "error: cannot open lock file ${registry}.lock — check directory permissions" >&2; exit 1; }
# Ensure fd 9 is closed (and lock released) on any exit path.
trap 'exec 9>&-' EXIT
flock -x 9

# Look for existing entry for this MAC (inside lock — authoritative read)
existing=$(grep -i "^${mac}" "$registry" 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  existing_hostname=$(echo "$existing" | awk '{print $2}')
  existing_status=$(echo "$existing" | awk '{print $3}')
  if [[ "$existing_status" == "provisioned" ]]; then
    echo "MAC ${mac} already provisioned as ${existing_hostname}" >&2
    echo "$existing_hostname"
    exit 2
  fi
  # Status is "failed" or "allocating" — allow re-provision with same hostname.
  # "allocating" means a previous run allocated the hostname but did not finish
  # provisioning; reuse the same hostname so the slot is not wasted.
  echo "MAC ${mac} previously ${existing_status} as ${existing_hostname} — re-provisioning" >&2
  echo "$existing_hostname"
  exit 0
fi

# ── Allocate next ID ────────────────────────────────────────────────────────
# "allocating" entries are counted alongside "provisioned" entries — they
# already occupy their hostname slot.

max_id=-1
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// /}" ]] && continue
  hostname=$(echo "$line" | awk '{print $2}')
  # Match our model prefix
  if [[ "$hostname" == ${model}-* ]]; then
    suffix="${hostname#${model}-}"
    if [[ ${#suffix} -eq 2 ]]; then
      id=$(b36_to_int "$suffix")
      (( id > max_id )) && max_id=$id
    fi
  fi
done < "$registry"

next_id=$(( max_id + 1 ))
if (( next_id >= 1296 )); then
  echo "error: hostname space exhausted for model ${model} (max 1296)" >&2
  exit 1
fi

next_suffix=$(int_to_b36 $next_id)
hostname="${model}-${next_suffix}"

# Write a tentative entry BEFORE releasing the lock.  Any concurrent
# allocate-hostname.sh invocation will see this entry and skip the slot.
echo "${mac}  ${hostname}  allocating" >> "$registry"

# Release lock
exec 9>&-

echo "$hostname"
