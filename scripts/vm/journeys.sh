#!/bin/bash
# Run LatchE2ETests inside a disposable Tart VM cloned from e2e-base.
#
# /bin/bash on purpose: under Homebrew bash, `tart ip --resolver arp` (and
# `arp -an` itself) returns an empty table, so the guest IP never resolves.
#
# GUI journeys warp the pointer and post real events, so they never run on a
# desk — this script runs them on the mini host inside a VM that is always
# destroyed afterwards. Pulli's e2e lane shares the same lock path.
#
# Usage: scripts/vm/journeys.sh [extra swift-test args]
#   e.g. scripts/vm/journeys.sh --filter DragJourneyTests/dragJourney
# Extra args are appended to `swift test --no-parallel --filter LatchE2ETests`.
#
# Exit code is the guest test run's.

set -euo pipefail

IMAGE="${E2E_IMAGE:-e2e-base}"
BRIDGE="${E2E_NET_BRIDGE:-en0}"
GUEST_USER="admin"
LOCK_DIR="${E2E_LOCK_DIR:-/Volumes/T7/tart-vms/e2e.lock}"
GUEST_DIR="latch"

SRC="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
VM="latch-journeys-$STAMP"
# Per-run logs live with the traces they belong to, synced back with them.
LOGDIR="$SRC/.latch-trace/vm-$STAMP"

TART="$(command -v tart || true)"
if [[ -z "$TART" && -x "$HOME/.local/bin/tart" ]]; then
    TART="$HOME/.local/bin/tart"
fi
if [[ -z "$TART" ]]; then
    echo "journeys.sh: tart not found on PATH or ~/.local/bin" >&2
    exit 1
fi

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
RSYNC_SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

log() { echo "==> $*"; }

# `tart ip --resolver arp` sees a bridged guest only after the guest has
# talked enough to land in the host ARP table — an idle guest looks absent.
# Ping the bridge's /24 so the guest's reply refreshes the entry.
warm_arp() {
    local addr subnet
    addr="$(ipconfig getifaddr "$BRIDGE" 2>/dev/null || true)"
    [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    subnet="${addr%.*}"
    seq 1 254 | xargs -P 64 -I{} ping -c 1 -t 1 "$subnet.{}" >/dev/null 2>&1 || true
}

# shellcheck disable=SC2329 # invoked via trap
release_lock() {
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
    log "waiting for $LOCK_DIR"
    while true; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            # Write via rename so a contender never reads a half-written pid.
            echo $$ >"$LOCK_DIR/.pid.$$"
            mv "$LOCK_DIR/.pid.$$" "$LOCK_DIR/pid"
            return 0
        fi
        local pid
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
            log "reclaiming stale lock (pid $pid is gone)"
            find "$LOCK_DIR" -name '.pid.*' -delete 2>/dev/null || true
            rm -f "$LOCK_DIR/pid"
            rmdir "$LOCK_DIR" 2>/dev/null || true
            continue
        fi
        if [[ -z "$pid" ]]; then
            # mkdir and pid-write are not atomic; give the holder a moment
            # before treating an empty lock as abandoned.
            sleep 2
            pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                log "reclaiming lock with no live pid"
                find "$LOCK_DIR" -name '.pid.*' -delete 2>/dev/null || true
                rmdir "$LOCK_DIR" 2>/dev/null || true
                continue
            fi
        fi
        sleep 5
    done
}

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
    "$TART" stop "$VM" >/dev/null 2>&1 || true
    "$TART" delete "$VM" >/dev/null 2>&1 || true
    release_lock
}

acquire_lock
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- VM up ---------------------------------------------------------------

mkdir -p "$LOGDIR"
log "cloning $IMAGE -> $VM"
"$TART" clone "$IMAGE" "$VM"

log "booting $VM (--net-bridged=$BRIDGE --no-graphics)"
nohup "$TART" run "$VM" --net-bridged="$BRIDGE" --no-graphics \
    >"$LOGDIR/tart-run.log" 2>&1 &

log "waiting for guest IP"
ip=""
for _ in $(seq 1 90); do
    ip="$("$TART" ip "$VM" --resolver arp --wait 5 2>/dev/null || true)"
    [[ -n "$ip" ]] && break
    warm_arp
    sleep 5
done
if [[ -z "$ip" ]]; then
    echo "journeys.sh: no guest IP ($LOGDIR/tart-run.log)" >&2
    exit 1
fi
log "guest at $ip — waiting for SSH"

for _ in $(seq 1 60); do
    if $SSH "$GUEST_USER@$ip" true 2>/dev/null; then
        break
    fi
    sleep 5
done
if ! $SSH "$GUEST_USER@$ip" true 2>/dev/null; then
    echo "journeys.sh: SSH never came up on $ip" >&2
    exit 1
fi

# --- Source in, tests, traces out ----------------------------------------

log "syncing checkout to guest:$GUEST_DIR"
rsync -az --delete \
    --exclude .git --exclude .build --exclude .latch-trace --exclude build \
    -e "$RSYNC_SSH" \
    "$SRC/" "$GUEST_USER@$ip:$GUEST_DIR/"

log "running LatchE2ETests in guest"
set +e
$SSH "$GUEST_USER@$ip" \
    "cd ~/$GUEST_DIR && swift test --no-parallel --filter LatchE2ETests $*" \
    2>&1 | tee "$LOGDIR/swift-test.log"
status=${PIPESTATUS[0]}
set -e

log "syncing .latch-trace back"
mkdir -p "$SRC/.latch-trace"
rsync -az -e "$RSYNC_SSH" \
    "$GUEST_USER@$ip:$GUEST_DIR/.latch-trace/" "$SRC/.latch-trace/" \
    || log "warning: trace sync failed (tests may have left none)"

exit "$status"
