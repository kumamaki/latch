#!/usr/bin/env bash
# Prove the Release build carries no driving surface: no socket, AX,
# screenshot, token, or catalog-registry implementation in libLatch.a,
# and no DEBUG-only API in the Release swiftmodule. Debug is the
# positive control — the same checks must succeed there.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

impl='Latch\.(LatchServer|UnixSocketServer|LatchAX|LatchScreenshot|LatchToken|LatchPaths|LatchCatalogDump|LatchBootGatedOps|LatchSocketPhase)(\.| |$)'

impl_count() {
    nm "$1" | xcrun swift-demangle | grep -cE "$impl" || true
}

sock_string_count() {
    strings "$1" | grep -c "latch\.sock" || true
}

swift build
swift build -c release
debug_bin="$(swift build --show-bin-path)"
release_bin="$(swift build -c release --show-bin-path)"

debug_lib="${debug_bin}/libLatch.a"
release_lib="${release_bin}/libLatch.a"
for lib in "$debug_lib" "$release_lib"; do
    if [[ ! -f "$lib" ]]; then
        echo "audit: missing ${lib}" >&2
        exit 1
    fi
done

dbg_syms="$(impl_count "$debug_lib")"
rel_syms="$(impl_count "$release_lib")"
dbg_sock="$(sock_string_count "$debug_lib")"
rel_sock="$(sock_string_count "$release_lib")"
echo "impl symbols: debug=${dbg_syms} release=${rel_syms}"
echo "latch.sock strings: debug=${dbg_sock} release=${rel_sock}"

if [[ "$rel_syms" -ne 0 ]]; then
    echo "audit: Release libLatch.a carries driving-surface impl" >&2
    nm "$release_lib" | xcrun swift-demangle | grep -E "$impl" >&2 || true
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

target="arm64-apple-macosx15.0"
xcrun swiftc -typecheck -I "$release_bin" -target "$target" "$probe_dir/api.swift"
xcrun swiftc -typecheck -I "$debug_bin" -target "$target" "$probe_dir/api.swift"
xcrun swiftc -typecheck -I "$debug_bin" -target "$target" "$probe_dir/debug_only.swift"
if xcrun swiftc -typecheck -I "$release_bin" -target "$target" "$probe_dir/debug_only.swift" 2>/dev/null; then
    echo "audit: DEBUG-only API resolves against the Release swiftmodule" >&2
    exit 1
fi

echo "audit: api surface ok (always-on in both; DEBUG-only absent in Release)"
echo "ready: config audit"
