#!/usr/bin/env bash
# libs/boards.sh — board listing helpers
# Source after require.sh: source "$(dirname "$0")/../libs/boards.sh"

list_boards() {
  for f in "${DIR_CONFIG}"/boards/*.env; do
    [[ -f "$f" ]] && basename "$f" .env
  done
}

list_pulled_boards() {
  for f in "${DIR_IMAGES}"/*/.pull-lock; do
    [[ -f "$f" ]] || continue
    basename "$(dirname "$f")"
  done
}

list_patched_boards() {
  for f in "${DIR_PATCHED}"/*.patch-lock; do
    [[ -f "$f" ]] || continue
    basename "$f" .patch-lock
  done
}
