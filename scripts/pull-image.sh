#!/usr/bin/env bash
# scripts/pull-image.sh — Download and verify an Armbian image
#
# Usage:
#   ./scripts/pull-image.sh <board>              # e.g., orangepi5
#   ./scripts/pull-image.sh <board> --refresh     # ignore lock, pull latest
#   ./scripts/pull-image.sh --all                 # pull for all boards in config/boards/
#   ./scripts/pull-image.sh --all --refresh
#
# Configuration is loaded from config/defaults.env + config/boards/<board>.env
# After a successful pull, a .pull-lock file is written to images/<board>/
# that freezes the resolved version until --refresh is used or the lock
# is deleted.

set -euo pipefail
source "$(dirname "$0")/../libs/require.sh"

# ── Constants ────────────────────────────────────────────────────────────────

CATALOG_URL="https://www.armbian.com/all-images.json"
CATALOG_CACHE="${DIR_CACHE}/all-images.json"
GPG_KEY="${DIR_KEYS}/armbian-release.asc"
EXPECTED_KEY_FP="DF00FAF1C577104B50BF1D0093D6889F9F0E78D5"

# ── Argument parsing (before dep checks so --help always works) ──────────────

REFRESH=false
ALL_BOARDS=false
BOARDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh) REFRESH=true; shift ;;
    --all)     ALL_BOARDS=true; shift ;;
    --help|-h)
      echo "Usage: $0 <board> [--refresh]"
      echo "       $0 --all [--refresh]"
      echo ""
      echo "Boards available in config/boards/:"
      for f in "${DIR_CONFIG}"/boards/*.env; do
        basename "$f" .env
      done
      exit 0
      ;;
    -*)
      log_fatal "unknown flag: $1 (try --help)"
      ;;
    *)
      BOARDS+=("$1"); shift
      ;;
  esac
done

if [[ "$ALL_BOARDS" == "true" ]]; then
  for f in "${DIR_CONFIG}"/boards/*.env; do
    BOARDS+=("$(basename "$f" .env)")
  done
fi

if [[ ${#BOARDS[@]} -eq 0 ]]; then
  log_fatal "no board specified (try: $0 orangepi5  or  $0 --all)"
fi

# ── Dependencies ─────────────────────────────────────────────────────────────

require curl jq sha256sum gpg

# ── GPG key check ────────────────────────────────────────────────────────────

if [[ ! -f "$GPG_KEY" ]]; then
  log_fatal "GPG key not found at ${GPG_KEY}\n       Run: ./scripts/setup-gpg-key.sh"
fi

# ── Catalog fetch with caching ───────────────────────────────────────────────

fetch_catalog() {
  local max_age="${ARMBIAN_CATALOG_MAX_AGE:-3600}"
  local now
  now=$(date +%s)

  mkdir -p "$DIR_CACHE"

  if [[ -f "$CATALOG_CACHE" ]]; then
    local mtime
    # GNU stat vs BSD stat
    mtime=$(stat -c %Y "$CATALOG_CACHE" 2>/dev/null) \
      || mtime=$(stat -f %m "$CATALOG_CACHE" 2>/dev/null) \
      || mtime=0

    if (( now - mtime < max_age )); then
      log_info "using cached catalog (age: $(( now - mtime ))s, max: ${max_age}s)"
      return 0
    fi
  fi

  log_info "fetching image catalog from armbian.com ..."
  if ! curl -fsSL --retry 3 --retry-delay 5 -o "${CATALOG_CACHE}.tmp" "$CATALOG_URL"; then
    # If fetch fails but we have a stale cache, use it with a warning
    if [[ -f "$CATALOG_CACHE" ]]; then
      log_warn "catalog fetch failed — using stale cache"
      return 0
    fi
    log_fatal "cannot fetch catalog from ${CATALOG_URL} (check network)"
  fi

  # Validate it's actual JSON with an assets array
  if ! jq -e '.assets | length > 0' "${CATALOG_CACHE}.tmp" >/dev/null 2>&1; then
    rm -f "${CATALOG_CACHE}.tmp"
    log_fatal "fetched catalog is invalid (missing .assets array). Schema may have changed."
  fi

  mv "${CATALOG_CACHE}.tmp" "$CATALOG_CACHE"
  log_ok "catalog cached ($(jq '.assets | length' "$CATALOG_CACHE") images)"
}

# ── Variant normalization ────────────────────────────────────────────────────

normalize_variant() {
  local v="$1"
  case "$v" in
    minimal|xfce|gnome|cinnamon) echo "$v" ;;
    server|cli|"")               echo ""    ;;
    *) log_fatal "unknown variant: ${v} (valid: minimal, server, xfce, gnome, cinnamon)" ;;
  esac
}

# ── Image resolution from catalog ────────────────────────────────────────────

# resolve_image outputs a single JSON object for the matching image,
# or exits with an error.
resolve_image() {
  local slug="$1" distro="$2" branch="$3" variant="$4" version="${5:-}"

  local filter
  filter=$(jq -n \
    --arg slug    "$slug" \
    --arg distro  "$distro" \
    --arg branch  "$branch" \
    --arg variant "$variant" \
    --arg version "$version" \
    '{slug: $slug, distro: $distro, branch: $branch, variant: $variant, version: $version}')

  local results
  results=$(jq --argjson f "$filter" '
    [.assets[] | select(
      .board_slug == $f.slug and
      .distro     == $f.distro and
      .branch     == $f.branch and
      .variant    == $f.variant and
      (if $f.version != "" then .armbian_version == $f.version else true end)
    )]
  ' "$CATALOG_CACHE")

  local count
  count=$(echo "$results" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    log_error "no image found matching:"
    log_error "  board_slug = ${slug}"
    log_error "  distro     = ${distro}"
    log_error "  branch     = ${branch}"
    log_error "  variant    = ${variant} $([ -n "$version" ] && echo "(version = ${version})")"
    log_error ""
    log_error "this combination may not exist, may have been removed, or the"
    log_error "catalog may be stale. try --refresh or check:"
    log_error "  https://www.armbian.com/download/"
    echo "" >&2
    # Show what IS available for this board to help debug
    local available
    available=$(jq --arg slug "$slug" '
      [.assets[] | select(.board_slug == $slug)
        | {distro, branch, variant, armbian_version}]
        | unique | sort_by(.distro, .branch)
    ' "$CATALOG_CACHE")
    if [[ "$(echo "$available" | jq 'length')" -gt 0 ]]; then
      log_info "available images for ${slug}:"
      echo "$available" | jq -r '.[] |
        "         \(.distro) / \(.branch) / \(if .variant == "" then "server" else .variant end) (v\(.armbian_version))"'
    fi
    return 1
  fi

  # If multiple matches (shouldn't happen, but could during releases),
  # pick the highest version
  if [[ "$count" -gt 1 ]]; then
    log_warn "found ${count} matching images, selecting highest version"
  fi

  echo "$results" | jq 'sort_by(.armbian_version) | reverse | .[0]'
}

# ── Download with resume ─────────────────────────────────────────────────────

download_file() {
  local url="$1" dest="$2" desc="$3"
  log_info "downloading ${desc} ..."

  local curl_opts=(
    -fSL
    --retry 3
    --retry-delay 5
    -o "$dest"
  )

  # Resume support for the image (large file)
  if [[ -f "$dest" ]]; then
    curl_opts+=(-C -)
    log_info "  resuming partial download"
  fi

  if ! curl "${curl_opts[@]}" "$url"; then
    rm -f "$dest"
    log_fatal "download failed: ${url}"
  fi
}

# ── Verification helpers ─────────────────────────────────────────────────────

verify_sha256() {
  local image_path="$1" sha_path="$2"
  log_info "verifying SHA256 ..."

  local expected_hash
  expected_hash=$(awk '{print $1}' "$sha_path")

  local actual_hash
  actual_hash=$(sha256sum "$image_path" | awk '{print $1}')

  if [[ "$expected_hash" != "$actual_hash" ]]; then
    log_error "SHA256 mismatch:"
    log_error "  expected: ${expected_hash}"
    log_error "  actual:   ${actual_hash}"
    return 1
  fi

  log_ok "SHA256 verified"
}

verify_gpg() {
  local image_path="$1" asc_path="$2"
  log_info "verifying GPG signature ..."

  local tmp_gnupg
  tmp_gnupg=$(mktemp -d)
  local old_gnupghome="${GNUPGHOME:-}"
  export GNUPGHOME="$tmp_gnupg"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_gnupg}'; GNUPGHOME='${old_gnupghome}'" RETURN

  gpg --quiet --import "$GPG_KEY" 2>/dev/null

  local gpg_output
  if gpg_output=$(gpg --status-fd 1 --verify "$asc_path" "$image_path" 2>&1); then
    if echo "$gpg_output" | grep -q "$EXPECTED_KEY_FP"; then
      log_ok "GPG signature verified (key: ${EXPECTED_KEY_FP: -16})"
      return 0
    fi
    local actual_key
    actual_key=$(echo "$gpg_output" | grep -oP 'key [A-F0-9]+' | head -1)
    log_error "image signed by unexpected key: ${actual_key:-unknown}"
    log_error "expected key fingerprint: ${EXPECTED_KEY_FP}"
    log_error ""
    log_error "Armbian may have rotated their signing key."
    log_error "Verify the new key manually and update keys/armbian-release.asc"
    log_error "Re-run ./scripts/setup-gpg-key.sh"
    return 1
  else
    if echo "$gpg_output" | grep -q "NO_PUBKEY\|no public key"; then
      local signing_key
      signing_key=$(echo "$gpg_output" | grep -oP 'key [A-F0-9]+' | head -1)
      log_error "image signed by unknown key: ${signing_key:-unknown}"
      log_error "expected fingerprint: ${EXPECTED_KEY_FP}"
      log_error ""
      log_error "Armbian may have rotated their signing key."
      log_error "Verify manually and re-run ./scripts/setup-gpg-key.sh"
    elif echo "$gpg_output" | grep -qi "BAD signature"; then
      log_error "BAD GPG SIGNATURE — image may have been tampered with!"
      log_error "Do NOT use this image."
    else
      log_error "GPG verification failed with unexpected output"
      echo "$gpg_output" >&2
    fi
    return 1
  fi
}

# ── Pull a single board ───────────────────────────────────────────────────────

pull_board() {
  local board="$1"

  log_info "═══ ${_BOLD}${board}${_RESET} ═══════════════════════════════════════════"

  load_config "$board"

  local variant
  variant=$(normalize_variant "${ARMBIAN_VARIANT:-}")

  local board_dir="${DIR_IMAGES}/${ARMBIAN_BOARD_SLUG}"
  mkdir -p "$board_dir"

  # ── Check existing lock ──────────────────────────────────────────────────

  if [[ "$REFRESH" == "false" ]] && read_lock "$board_dir"; then
    local locked_img="${board_dir}/${ARMBIAN_LOCKED_FILENAME}"
    if [[ -f "$locked_img" ]]; then
      log_info "already downloaded (v${ARMBIAN_LOCKED_VERSION}): ${ARMBIAN_LOCKED_FILENAME}"
      log_info "use --refresh to re-resolve"
      echo "" >&2
      return 0
    fi
    log_warn "lock exists but image file missing — re-downloading locked version"
  fi

  # ── Resolve image from catalog ────────────────────────────────────────────

  # If a lock exists (file was missing), re-pin to the locked version to avoid
  # silently upgrading to whatever the catalog currently shows.
  local pinned_version="${ARMBIAN_VERSION:-}"
  if [[ "$REFRESH" == "false" ]] && read_lock "$board_dir" 2>/dev/null; then
    pinned_version="${ARMBIAN_LOCKED_VERSION:-$pinned_version}"
  fi

  local image_json
  image_json=$(resolve_image \
    "$ARMBIAN_BOARD_SLUG" \
    "$ARMBIAN_DISTRO" \
    "$ARMBIAN_BRANCH" \
    "$variant" \
    "$pinned_version") || return 1

  # ── Extract image metadata ────────────────────────────────────────────────

  local filename armbian_version kernel_version
  local file_url file_url_sha file_url_asc
  local file_size size_mb

  file_url=$(        echo "$image_json" | jq -r '.file_url')
  file_url_sha=$(    echo "$image_json" | jq -r '.file_url_sha')
  file_url_asc=$(    echo "$image_json" | jq -r '.file_url_asc')
  file_size=$(       echo "$image_json" | jq -r '.file_size')
  armbian_version=$( echo "$image_json" | jq -r '.armbian_version')
  kernel_version=$(  echo "$image_json" | jq -r '.kernel_version')
  filename=$(        basename "$file_url")
  size_mb=$(( file_size / 1048576 ))

  local image_path="${board_dir}/${filename}"
  local sha_path="${image_path}.sha"
  local asc_path="${image_path}.asc"

  # ── Download sidecar files ───────────────────────────────────────────────

  download_file "$file_url_sha" "$sha_path" "SHA256 checksum"

  # Validate sha file has expected format
  if ! grep -qP '^[a-f0-9]{64}\s+' "$sha_path" 2>/dev/null; then
    log_fatal "SHA file has unexpected format: $(head -1 "$sha_path")"
  fi

  download_file "$file_url_asc" "$asc_path" "GPG signature"

  # ── Download image ───────────────────────────────────────────────────────

  download_file "$file_url" "$image_path" "image (${size_mb} MB)"

  # ── Verify SHA256 ────────────────────────────────────────────────────────

  if ! verify_sha256 "$image_path" "$sha_path"; then
    log_warn "SHA256 failed — retrying download from scratch"
    rm -f "$image_path"
    download_file "$file_url" "$image_path" "image (retry)"

    if ! verify_sha256 "$image_path" "$sha_path"; then
      rm -f "$image_path"
      log_fatal "SHA256 verification failed after retry — aborting"
    fi
  fi

  # ── Verify GPG ───────────────────────────────────────────────────────────

  # GPG .asc verifies the .img.xz directly (not the sha file)
  if ! verify_gpg "$image_path" "$asc_path"; then
    rm -f "$image_path"
    log_fatal "GPG verification failed — image removed, aborting"
  fi

  # ── Write lock ───────────────────────────────────────────────────────────

  local sha256
  sha256=$(awk '{print $1}' "$sha_path")

  write_lock "$board_dir" \
    "ARMBIAN_LOCKED_VERSION=\"${armbian_version}\"" \
    "ARMBIAN_LOCKED_KERNEL=\"${kernel_version}\"" \
    "ARMBIAN_LOCKED_SHA256=\"${sha256}\"" \
    "ARMBIAN_LOCKED_FILE_URL=\"${file_url}\"" \
    "ARMBIAN_LOCKED_FILENAME=\"${filename}\"" \
    "ARMBIAN_LOCKED_BOARD_SLUG=\"${ARMBIAN_BOARD_SLUG}\"" \
    "ARMBIAN_LOCKED_DISTRO=\"${ARMBIAN_DISTRO}\"" \
    "ARMBIAN_LOCKED_BRANCH=\"${ARMBIAN_BRANCH}\"" \
    "ARMBIAN_LOCKED_VARIANT=\"${ARMBIAN_VARIANT}\""

  log_ok "${_BOLD}${filename}${_RESET} — downloaded and verified"
  echo "" >&2
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  log_info "armbian image pull"
  echo "" >&2

  # Fetch catalog once for all boards
  fetch_catalog

  local failed=()

  for board in "${BOARDS[@]}"; do
    if ! pull_board "$board"; then
      failed+=("$board")
      log_error "failed to pull image for ${board}"
      echo "" >&2
    fi
  done

  # Summary
  echo "" >&2
  if [[ ${#failed[@]} -eq 0 ]]; then
    log_ok "all boards done (${#BOARDS[@]}/${#BOARDS[@]})"
  else
    log_error "${#failed[@]}/${#BOARDS[@]} boards failed: ${failed[*]}"
    exit 1
  fi
}

main
