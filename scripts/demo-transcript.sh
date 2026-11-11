#!/usr/bin/env bash
# Writes a Journey's transcript.txt into README.md between the demo markers.
# usage: demo-transcript.sh <trace-dir>
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1/transcript.txt" ]]; then
  echo "usage: demo-transcript.sh <trace-dir containing transcript.txt>" >&2
  exit 2
fi

readme="$(cd "$(dirname "$0")/.." && pwd)/README.md"
fence="$(printf '\140\140\140')"
block="$(printf '%stext\n%s\n%s' "$fence" "$(cat "$1/transcript.txt")" "$fence")"
updated="$(BLOCK="$block" awk '
  /<!-- demo:start -->/ { print; print ENVIRON["BLOCK"]; skip = 1; next }
  /<!-- demo:end -->/ { skip = 0 }
  !skip { print }
' "$readme")"
printf '%s\n' "$updated" >"$readme"
