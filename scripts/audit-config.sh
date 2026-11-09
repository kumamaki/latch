#!/usr/bin/env bash
# Prove the Release build carries no driving surface: no socket, AX,
# screenshot, token, or catalog-registry implementation in libLatch.a,
# and no DEBUG-only API in the Release swiftmodule. Debug is the
# positive control — the same checks must succeed there.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

impl='Latch\.(LatchServer|UnixSocketServer|LatchAX|LatchScreenshot|LatchToken|LatchPaths|LatchCatalogDump|LatchBootGatedOps|LatchSocketPhase|LatchValueHistory|LatchHistoryReply)(\.| |$)'

impl_count() {
    nm "$@" | xcrun swift-demangle | grep -cE "$impl" || true
}

sock_string_count() {
    strings "$@" | grep -c "latch\.sock" || true
}

swift build --product Latch
swift build -c release --product Latch
debug_bin="$(swift build --show-bin-path)"
release_bin="$(swift build -c release --show-bin-path)"

# The toolchain decides whether a library product leaves a libLatch.a or
# only the module's object files, so audit whichever it produced.
latch_artifacts() {
    local archive="$1/libLatch.a"
    if [[ -f "$archive" ]]; then
        echo "$archive"
        return
    fi
    local objects
    objects="$(find "$1" -path '*Latch.build/*.o' -not -path '*LatchE2E*' | sort)"
    if [[ -z "$objects" ]]; then
        echo "audit: no Latch archive or objects under ${1}" >&2
        find "$1" -maxdepth 3 -iname '*Latch*' >&2
        exit 1
    fi
    echo "$objects"
}

# Where the swiftmodule lands (the bin path or its Modules/) also varies.
module_dir() {
    local module
    module="$(find "$1" -name Latch.swiftmodule -not -path '*LatchE2E*' | head -1)"
    if [[ -z "$module" ]]; then
        echo "audit: no Latch.swiftmodule under ${1}" >&2
        exit 1
    fi
    dirname "$module"
}

# macOS bash 3.2 has no mapfile.
debug_libs=()
while IFS= read -r artifact; do debug_libs+=("$artifact"); done < <(latch_artifacts "$debug_bin")
release_libs=()
while IFS= read -r artifact; do release_libs+=("$artifact"); done < <(latch_artifacts "$release_bin")

dbg_syms="$(impl_count "${debug_libs[@]}")"
rel_syms="$(impl_count "${release_libs[@]}")"
dbg_sock="$(sock_string_count "${debug_libs[@]}")"
rel_sock="$(sock_string_count "${release_libs[@]}")"
echo "impl symbols: debug=${dbg_syms} release=${rel_syms}"
echo "latch.sock strings: debug=${dbg_sock} release=${rel_sock}"

if [[ "$rel_syms" -ne 0 ]]; then
    echo "audit: Release libLatch.a carries driving-surface impl" >&2
    nm "${release_libs[@]}" | xcrun swift-demangle | grep -E "$impl" >&2 || true
    exit 1
fi
if [[ "$rel_sock" -ne 0 ]]; then
    echo "audit: Release libLatch.a embeds latch.sock strings" >&2
    exit 1
fi
if [[ "$dbg_syms" -eq 0 || "$dbg_sock" -eq 0 ]]; then
    echo "audit: Debug build lost the driving surface — control failed" >&2
    exit 1
fi

probe_dir="$(mktemp -d -t latch-audit)"
trap 'rm -rf "$probe_dir"' EXIT

cat >"$probe_dir/api.swift" <<'SWIFT'
import Latch
import SwiftUI

// Surface every adopter relies on. Must compile in both configs.
func labeled(_ v: some View) -> some View {
    v.latch("audit.button", press: {}).latchWindow("main")
}
@MainActor
func calls() {
    Latch.start(app: "audit")
    Latch.stop()
    _ = Latch.snapshot()
    _ = try? Latch.find(id: "audit.missing")
    _ = Latch.updates()
    let _: (any LatchOpsProviding)? = nil
    _ = LatchCatalog.formatBool(true)
}
SWIFT

cat >"$probe_dir/debug_only.swift" <<'SWIFT'
import Latch

// DEBUG-only public surface. Must resolve in Debug, fail in Release.
let _ = LatchPaths.self
let _ = LatchToken.self
let _ = LatchDefaultOps.self
let _ = LatchServer.self
SWIFT

debug_modules="$(module_dir "$debug_bin")"
release_modules="$(module_dir "$release_bin")"
target="arm64-apple-macosx15.0"
xcrun swiftc -typecheck -I "$release_modules" -target "$target" "$probe_dir/api.swift"
xcrun swiftc -typecheck -I "$debug_modules" -target "$target" "$probe_dir/api.swift"
xcrun swiftc -typecheck -I "$debug_modules" -target "$target" "$probe_dir/debug_only.swift"
if xcrun swiftc -typecheck -I "$release_modules" -target "$target" "$probe_dir/debug_only.swift" 2>/dev/null; then
    echo "audit: DEBUG-only API resolves against the Release swiftmodule" >&2
    exit 1
fi

echo "audit: api surface ok (always-on in both; DEBUG-only absent in Release)"
echo "ready: config audit"
