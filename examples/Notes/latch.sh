#!/usr/bin/env bash
# Drive the live Debug app. Kernel client lives in the Latch checkout.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
client="$root/cli/latch.sh"
if [[ ! -f "$client" ]]; then
    echo "error: Latch kernel client missing at ${client}." >&2
    exit 1
fi
cd "$here"
exec bash "$client" "$@"
