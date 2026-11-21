#!/bin/bash
# Build (or re-provision) the e2e-base Tart image that scripts/vm/journeys.sh
# clones for every GUI journey run.
#
# /bin/bash on purpose: under Homebrew bash, `tart ip --resolver arp` (and
# `arp -an` itself) returns an empty table, so the guest IP never resolves.
#
# Runs on the mini host — the machine with tart and the T7 volume. Safe to
# re-run: an existing e2e-base is booted and re-provisioned in place.
#
# This script is the one place LAN access is fine: it is run by hand or from
# an agent shell (Terminal/SSH), where macOS allows Local Network. CI never
# runs it — journeys.sh reaches the guest over Tart's virtio channels only.
#
# What the image guarantees for guests:
#   - macOS 27 with the host's own Xcode (xcode-select points there, and
#     xcodebuild/swift versions are verified identical to the host's)
#   - auto-login to an Aqua session as admin (GUI tests need a window server)
#   - sleep / displaysleep / disksleep / screensaver / screen lock all off
#   - Remote Login on; admin password stays admin/admin; the mini user's
#     default SSH key (~/.ssh/id_rsa.pub) is in admin's authorized_keys
#
# Networking note: guests boot with --net-bridged=en0. NAT (the tart default)
# gets no DHCP lease on this host — bootpd serves nothing — while bridged
# pulls a LAN address that `tart ip --resolver arp` finds.
#
# Apple occasionally needs a GUI click (IPSW installs, license agreements).
# This path clones the published golden image, which needs none; if the base
# image is ever replaced by `tart create --from-ipsw`, finish its Setup
# Assistant once by hand before re-running this script.

set -euo pipefail

IMAGE="${E2E_IMAGE:-e2e-base}"
BASE="${E2E_BASE:-ghcr.io/cirruslabs/macos-golden-gate-base:latest}"
BRIDGE="${E2E_NET_BRIDGE:-en0}"
# Xcode plus swift build artifacts need far more than the base image's 50 GB
# disk; tart grows the APFS container into the added space on next boot.
DISK_GB="${E2E_DISK_GB:-120}"
GUEST_USER="admin"
GUEST_PASSWORD="admin"

TART="$(command -v tart || true)"
if [[ -z "$TART" && -x "$HOME/.local/bin/tart" ]]; then
    TART="$HOME/.local/bin/tart"
fi
if [[ -z "$TART" ]]; then
    echo "image.sh: tart not found on PATH or ~/.local/bin" >&2
    exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)

vm_exists() {
    # Capture first: `grep -q` exits early, tart takes SIGPIPE, and pipefail
    # would report the match as a failure.
    local json
    json="$("$TART" list --format json 2>/dev/null)" || return 1
    [[ "$json" == *"\"$IMAGE\""* ]]
}

vm_ip() {
    # Bridged guests land on the LAN; the arp resolver finds them once they
    # talk. --wait covers first-boot DHCP; the sweep covers an idle guest
    # whose ARP entry has already expired.
    local addr subnet="" ip=""
    addr="$(ipconfig getifaddr "$BRIDGE" 2>/dev/null || true)"
    if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        subnet="${addr%.*}"
    fi
    # First boot under load can take a while to DHCP; match journeys.sh's budget.
    for _ in $(seq 1 90); do
        ip="$("$TART" ip "$IMAGE" --resolver arp --wait 5 2>/dev/null || true)"
        [[ -n "$ip" ]] && break
        if [[ -n "$subnet" ]]; then
            seq 1 254 | xargs -P 64 -I{} ping -c 1 -t 1 "$subnet.{}" >/dev/null 2>&1 || true
        fi
        sleep 5
    done
    printf '%s' "$ip"
}

# Password auth for the one-time provisioning pass. askpass keeps the
# password out of the process table and off any tty.
askpass_ssh() {
    local dir
    dir="$(mktemp -d -t latch-image-askpass)"
    printf '#!/bin/sh\necho %s\n' "$GUEST_PASSWORD" >"$dir/askpass"
    chmod 700 "$dir/askpass"
    SSH_ASKPASS="$dir/askpass" SSH_ASKPASS_REQUIRE=force \
        DISPLAY="${DISPLAY:-none}" \
        ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password,keyboard-interactive \
            "$@"
    local status=$?
    rm -rf "$dir"
    return "$status"
}

provision() {
    local ip="$1"
    local pubkey
    pubkey="$(cat "$HOME/.ssh/id_rsa.pub")"
    askpass_ssh "$GUEST_USER@$ip" "bash -s" <<EOF
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '$pubkey' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
defaults -currentHost write com.apple.screensaver idleTime -int 0
defaults write com.apple.screensaver askForPassword -bool false
defaults write com.apple.screensaver askForPasswordDelay -int 0
echo '$GUEST_PASSWORD' | sudo -S pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1
echo PROVISION_OK
EOF
}

# The guest builds with the same Xcode the host does: CLT's toolchain lacks
# the macro plugins (@Test, #expect, @Observable, ...) and would drift on the
# next update.
# The .app is a few GB over the LAN; xcode-select, license, and first-launch
# component install run as root, then the guest must report the host's exact
# xcodebuild and swift versions or the image is rejected.
install_xcode() {
    local ip="$1"
    local developer host_xcode host_xcodebuild host_swift
    developer="$(xcode-select -p)"
    host_xcode="${developer%/Contents/Developer}"
    if [[ "$host_xcode" != *.app ]]; then
        echo "image.sh: xcode-select -p is '$developer' — expected .../Xcode.app/Contents/Developer" >&2
        return 1
    fi
    host_xcodebuild="$(xcodebuild -version)"
    host_swift="$(swift --version)"

    echo "==> copying $host_xcode to the guest"
    rsync -a --timeout=300 "$host_xcode" "$GUEST_USER@$ip:/Applications/"
    # $GUEST_PASSWORD must expand here, on the client.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" \
        "echo $GUEST_PASSWORD | sudo -S /bin/sh -c 'xcode-select -s $host_xcode/Contents/Developer && xcodebuild -license accept && xcodebuild -runFirstLaunch'"

    local guest_xcodebuild guest_swift
    guest_xcodebuild="$(ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" 'xcodebuild -version')"
    guest_swift="$(ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" 'swift --version')"
    if [[ "$guest_xcodebuild" != "$host_xcodebuild" || "$guest_swift" != "$host_swift" ]]; then
        echo "image.sh: guest toolchain does not match the host" >&2
        echo "  host  xcodebuild: $host_xcodebuild" >&2
        echo "  guest xcodebuild: $guest_xcodebuild" >&2
        echo "  host  swift:      $host_swift" >&2
        echo "  guest swift:      $guest_swift" >&2
        return 1
    fi
}

echo "==> image: $IMAGE (base: $BASE, bridge: $BRIDGE)"

if ! vm_exists; then
    echo "==> cloning $BASE"
    "$TART" clone "$BASE" "$IMAGE"
else
    echo "==> $IMAGE exists — re-provisioning"
fi

"$TART" stop "$IMAGE" >/dev/null 2>&1 || true
"$TART" set "$IMAGE" --disk-size "$DISK_GB"
nohup "$TART" run "$IMAGE" --net-bridged="$BRIDGE" --no-graphics \
    >"$HOME/tart-$IMAGE.log" 2>&1 &
trap '"$TART" stop "$IMAGE" >/dev/null 2>&1 || true' EXIT

echo "==> waiting for guest IP"
ip="$(vm_ip || true)"
if [[ -z "$ip" ]]; then
    echo "image.sh: no guest IP — is the VM booting? ($HOME/tart-$IMAGE.log)" >&2
    exit 1
fi
echo "==> guest at $ip — waiting for SSH"

ready=""
for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" true 2>/dev/null; then
        ready=1
        break
    fi
    # Key auth only works after provisioning; accept password too while the
    # image is still being built for the first time.
    if askpass_ssh "$GUEST_USER@$ip" true 2>/dev/null; then
        ready=1
        break
    fi
    sleep 5
done
if [[ -z "$ready" ]]; then
    echo "image.sh: SSH never came up on $ip" >&2
    exit 1
fi

echo "==> provisioning guest"
provision "$ip"
install_xcode "$ip"

# Prove the path journeys.sh will use: key auth, no password, and the macro
# probe compiles. Plain swiftc adds neither the platform frameworks nor the
# toolchain's testing plugin dir — SwiftPM supplies both at build time — so
# the probe passes them explicitly, exactly as `swift test` would resolve them.
if ! ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" 'swift --version | head -1'; then
    echo "image.sh: key auth to $ip failed after provisioning" >&2
    exit 1
fi
ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" 'cat > /tmp/latch-macro-probe.swift' <<'EOF'
import SwiftUI
import Testing

struct V: View {
    @State private var x = 0
    var body: some View { Text("\(x)") }
}

@Test func probe() { #expect(true) }
EOF
DEV_DIR="$(xcode-select -p)"
# $DEV_DIR expands here, on the client — the guest's developer dir is the
# same path because install_xcode copied the .app to /Applications.
# shellcheck disable=SC2029
probe_cmd="cd /tmp && swiftc -typecheck \
    -F $DEV_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks \
    -plugin-path $DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing \
    latch-macro-probe.swift && rm -f latch-macro-probe.swift"
# shellcheck disable=SC2029
if ! ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "$probe_cmd"; then
    echo "image.sh: macro probe failed — the Xcode install is incomplete" >&2
    exit 1
fi

"$TART" stop "$IMAGE"
trap - EXIT
echo "==> $IMAGE ready (stopped, cloneable)"
