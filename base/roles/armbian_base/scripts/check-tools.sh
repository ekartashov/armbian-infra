#!/usr/bin/env bash
# scripts/check-tools.sh — verify required tools are available on the target
# Usage: check-tools.sh <cmd1> <cmd2> ...
set -euo pipefail

missing=()
for cmd in "$@"; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "MISSING: ${missing[*]}" >&2
  exit 1
fi
echo "OK"
