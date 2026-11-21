#!/bin/bash
# Run LatchE2ETests inside a disposable Tart VM cloned from e2e-base.
#
# The guest never touches the LAN: the checkout enters through a virtiofs
# share (--dir), commands run through the Tart guest agent (tart exec), and
# traces leave through the same share. CI runners are launchd agents, which
# macOS denies Local Network access to without a prompt (Apple TN3179), so
# bridged networking and SSH would hang there — this lane uses neither.
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
#
# e2e-base must have the Tart guest agent — every non-vanilla Cirrus Labs
# image ships it. A guest without it never answers the readiness poll below,
# so the run fails loud instead of hanging.

set -euo pipefail

IMAGE="${E2E_IMAGE:-e2e-base}"
GUEST_USER="admin"
GUEST_DIR="latch"
SHARE="latch"
SHARE_PATH="/Volumes/My Shared Files/$SHARE"
GUEST_HOME="/Users/$GUEST_USER"
LOCK_DIR="${E2E_LOCK_DIR:-/Volumes/T7/tart-vms/e2e.lock}"

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

log() { echo "==> $*"; }

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

# tart exec takes argv, not a shell string — remote work goes through sh -c.
guest() { "$TART" exec "$VM" sh -c "$1"; }

acquire_lock
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- VM up ---------------------------------------------------------------

mkdir -p "$LOGDIR"
log "cloning $IMAGE -> $VM"
"$TART" clone "$IMAGE" "$VM"

log "booting $VM (--no-graphics, share $SHARE)"
nohup "$TART" run "$VM" --no-graphics --dir="$SHARE:$SRC" \
    >"$LOGDIR/tart-run.log" 2>&1 &

log "waiting for the guest agent"
agent_ready=""
for _ in $(seq 1 90); do
    if "$TART" exec "$VM" true 2>/dev/null; then
        agent_ready=1
        break
    fi
    sleep 5
done
if [[ -z "$agent_ready" ]]; then
    echo "journeys.sh: guest agent never came up ($LOGDIR/tart-run.log)" >&2
    exit 1
fi

# --- Source in, tests, traces out ----------------------------------------

log "copying checkout into the guest"
guest "mkdir -p $GUEST_HOME/$GUEST_DIR"
guest "rsync -a --delete \
    --exclude .git --exclude .build --exclude .latch-trace --exclude build \
    '$SHARE_PATH/' '$GUEST_HOME/$GUEST_DIR/'"

log "running LatchE2ETests in guest"
set +e
guest "cd $GUEST_HOME/$GUEST_DIR && swift test --no-parallel --filter LatchE2ETests $*" \
    2>&1 | tee "$LOGDIR/swift-test.log"
status=${PIPESTATUS[0]}
set -e

log "copying .latch-trace back through the share"
guest "if [ -d $GUEST_HOME/$GUEST_DIR/.latch-trace ]; then \
    mkdir -p '$SHARE_PATH/.latch-trace' && \
    rsync -a $GUEST_HOME/$GUEST_DIR/.latch-trace/ '$SHARE_PATH/.latch-trace/'; \
fi" || log "warning: trace sync failed (tests may have left none)"

exit "$status"
