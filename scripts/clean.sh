#!/usr/bin/env bash
# scripts/clean.sh — remove generated artifacts from the build pipeline
#
# Usage:
#   ./scripts/clean.sh [--cache] [--images] [--patched] [--secrets] [--locks] [--all] [--dry-run]
#
# Targets (additive flags):
#   --cache    cache/all-images.json (catalog; auto-expires anyway)
#   --images   images/<board>/Armbian_*.img.xz{,.sha,.asc}  (downloaded raw images)
#   --patched  images/patched/*.img.xz  +  *.img  (pipeline outputs)
#   --secrets  secrets/  (generated password hash + SSH keypair)
#   --locks    images/*/.pull-lock  +  images/patched/*.patch-lock
#              !! version pins — only wipe when you want a full reset !!
#
# Shorthands:
#   --all      --cache --images --patched --secrets  (keeps locks)
#   --all --locks                                    (nuclear: full clean slate)
#
# Examples:
#   ./scripts/clean.sh --cache                   # just expire the catalog
#   ./scripts/clean.sh --patched                 # re-patch without re-downloading
#   ./scripts/clean.sh --all                     # clean everything, keep version pins
#   ./scripts/clean.sh --all --locks             # full reset
#   ./scripts/clean.sh --all --dry-run           # preview what would be removed

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────

do_cache=false
do_images=false
do_patched=false
do_secrets=false
do_locks=false
dry_run=false

if [[ $# -eq 0 ]]; then
  cat >&2 <<EOF
${_BOLD}Usage:${_RESET} $(basename "$0") [--cache] [--images] [--patched] [--secrets] [--locks] [--all] [--dry-run]

Targets:
  --cache    Catalog cache (cache/all-images.json)
  --images   Downloaded raw Armbian images + sidecar files
  --patched  Patched output images (images/patched/*.img.xz / *.img)
  --secrets  Generated secrets (password hash, SSH keypair)
  --locks    Version pins (.pull-lock, .patch-lock)  ← destructive!
  --all      Shorthand for --cache --images --patched --secrets
  --dry-run  Print what would be removed without deleting anything
EOF
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --cache)    do_cache=true ;;
    --images)   do_images=true ;;
    --patched)  do_patched=true ;;
    --secrets)  do_secrets=true ;;
    --locks)    do_locks=true ;;
    --all)      do_cache=true; do_images=true; do_patched=true; do_secrets=true ;;
    --dry-run)  dry_run=true ;;
    *) log_fatal "unknown argument: $arg" ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

removed=0

_rm() {
  # Usage: _rm <glob-or-path> [<description>]
  local target="$1"
  local desc="${2:-$target}"

  # Expand glob safely
  local -a matches=()
  while IFS= read -r -d '' f; do
    matches+=("$f")
  done < <(find . -path "./$target" -print0 2>/dev/null || true)

  if [[ ${#matches[@]} -eq 0 ]]; then
    log_info "nothing to remove: ${_BOLD}${desc}${_RESET}"
    return
  fi

  for f in "${matches[@]}"; do
    if "$dry_run"; then
      log_warn "[dry-run] would remove: ${_BOLD}${f}${_RESET}"
    else
      rm -rf -- "$f"
      log_ok "removed: ${_BOLD}${f}${_RESET}"
    fi
    (( removed++ )) || true
  done
}

_rm_glob() {
  # Usage: _rm_glob <dir> <glob-pattern>
  local dir="$1"
  local pattern="$2"

  [[ -d "$dir" ]] || return 0

  local -a matches=()
  while IFS= read -r -d '' f; do
    matches+=("$f")
  done < <(find "$dir" -maxdepth 1 -name "$pattern" -print0 2>/dev/null || true)

  if [[ ${#matches[@]} -eq 0 ]]; then
    log_info "nothing matching ${_BOLD}${pattern}${_RESET} in ${dir}"
    return
  fi

  for f in "${matches[@]}"; do
    if "$dry_run"; then
      log_warn "[dry-run] would remove: ${_BOLD}${f}${_RESET}"
    else
      rm -f -- "$f"
      log_ok "removed: ${_BOLD}${f}${_RESET}"
    fi
    (( removed++ )) || true
  done
}

# ── Clean targets ────────────────────────────────────────────────────────────

cd "$PROJECT_ROOT"

"$dry_run" && log_warn "dry-run mode — nothing will be deleted"

# -- cache -------------------------------------------------------------------
if "$do_cache"; then
  log_info "cleaning catalog cache…"
  _rm "cache/all-images.json" "catalog cache"
  # Remove dir too if empty
  if [[ -d cache ]] && [[ -z "$(ls -A cache 2>/dev/null)" ]]; then
    "$dry_run" || rmdir cache
  fi
fi

# -- downloaded raw images ---------------------------------------------------
if "$do_images"; then
  log_info "cleaning downloaded raw images…"
  for board_dir in "${DIR_IMAGES}"/*/; do
    [[ -d "$board_dir" ]] || continue
    [[ "$(basename "$board_dir")" == "patched" ]] && continue
    _rm_glob "$board_dir" "Armbian_*.img.xz"
    _rm_glob "$board_dir" "Armbian_*.img.xz.sha"
    _rm_glob "$board_dir" "Armbian_*.img.xz.asc"
  done
fi

# -- patched outputs ---------------------------------------------------------
if "$do_patched"; then
  log_info "cleaning patched outputs…"
  _rm_glob "${DIR_PATCHED}" "*.img.xz"
  _rm_glob "${DIR_PATCHED}" "*.img"
fi

# -- secrets -----------------------------------------------------------------
if "$do_secrets"; then
  log_info "cleaning generated secrets…"
  _rm_glob "${DIR_SECRETS}"       "password.hash"
  _rm_glob "${DIR_SECRETS}/ssh"   "id_*"          # private key
  _rm_glob "${DIR_SECRETS}/ssh"   "*.pub"          # public key
  # Remove the now-empty ssh/ subdirectory
  if [[ -d "${DIR_SECRETS}/ssh" ]] && [[ -z "$(ls -A "${DIR_SECRETS}/ssh" 2>/dev/null)" ]]; then
    if "$dry_run"; then
      log_warn "[dry-run] would remove: ${_BOLD}${DIR_SECRETS}/ssh${_RESET}"
    else
      rmdir "${DIR_SECRETS}/ssh"
      log_ok "removed: ${_BOLD}${DIR_SECRETS}/ssh${_RESET}"
    fi
  fi
fi

# -- lock files (version pins) -----------------------------------------------
if "$do_locks"; then
  log_warn "removing version lock files — you will re-resolve versions on next pull/patch"
  for board_dir in "${DIR_IMAGES}"/*/; do
    [[ -d "$board_dir" ]] || continue
    [[ "$(basename "$board_dir")" == "patched" ]] && continue
    _rm_glob "$board_dir" ".pull-lock"
  done
  _rm_glob "${DIR_PATCHED}" "*.patch-lock"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo >&2
if "$dry_run"; then
  log_warn "dry-run complete — ${_BOLD}${removed}${_RESET} item(s) would be removed"
elif [[ $removed -eq 0 ]]; then
  log_info "nothing to clean"
else
  log_ok "done — ${_BOLD}${removed}${_RESET} item(s) removed"
fi
