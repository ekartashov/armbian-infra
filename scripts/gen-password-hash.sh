#!/usr/bin/env bash
# scripts/gen-password-hash.sh — generate SHA-512 password hash for /etc/shadow
#
# Usage (interactive — prompts for password with confirmation):
#   ./scripts/gen-password-hash.sh                        # writes secrets/password.hash
#   ./scripts/gen-password-hash.sh --force                # overwrite existing file
#   ./scripts/gen-password-hash.sh --output /other/path  # write to custom path
#   ./scripts/gen-password-hash.sh --stdout               # print hash to stdout, no file
#
# Usage (non-interactive — reads password from stdin, no confirmation prompt):
#   echo "$pass"     | ./scripts/gen-password-hash.sh --stdout
#   echo "$pass"     | ./scripts/gen-password-hash.sh --output /path/to/hash
#   echo "$pass"     | ./scripts/gen-password-hash.sh           # writes default file
#
# The generated hash is shared by BOTH pipeline stages:
#   - patch stage  (patch-image.sh)           — sets the bootstrap SD-card user password
#   - base stage   (Ansible provision-base)   — sets the admin user password on NVMe
#
# Uses openssl passwd -6. Alternatively: mkpasswd -m sha-512 (whois pkg).

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"

require openssl

# ── Argument parsing ──────────────────────────────────────────────────────────

output_file="${DIR_SECRETS}/password.hash"
to_stdout=false
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdout)     to_stdout=true; shift ;;
    --output|-o)  output_file="$2"; shift 2 ;;
    --force|-f)   force=true; shift ;;
    *) log_fatal "unknown argument: $1 (valid options: --stdout, --output/-o <path>, --force/-f)" ;;
  esac
done

# ── Check for existing file ───────────────────────────────────────────────────

if [[ "$to_stdout" == false && -f "$output_file" && "$force" == false ]]; then
  log_info "hash already exists at ${output_file}"
  log_info "use --force to regenerate, or --stdout to print to stdout"
  exit 0
fi

# ── Read password ─────────────────────────────────────────────────────────────

if [[ -t 0 ]]; then
  # Interactive terminal: prompt with confirmation
  read -rsp "Password: " pass; echo >&2
  read -rsp "Confirm:  " confirm; echo >&2
  [[ "$pass" == "$confirm" ]] || log_fatal "passwords don't match"
  [[ -n "$pass" ]]            || log_fatal "password cannot be empty"
else
  # Non-interactive (stdin piped): read single line, no confirmation
  IFS= read -r pass
  [[ -n "$pass" ]] || log_fatal "password cannot be empty (received from stdin)"
fi

# ── Generate hash ─────────────────────────────────────────────────────────────

hash=$(printf '%s' "$pass" | openssl passwd -6 -stdin)

# ── Output ────────────────────────────────────────────────────────────────────

if [[ "$to_stdout" == true ]]; then
  printf '%s\n' "$hash"
else
  mkdir -p "$(dirname "$output_file")"
  printf '%s\n' "$hash" > "$output_file"
  chmod 600 "$output_file"
  log_ok "hash written to ${output_file}"
fi
