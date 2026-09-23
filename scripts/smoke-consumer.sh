#!/usr/bin/env bash
# Prove a clean external consumer resolves Latch as a path dependency
# and that the driving surface follows the consumer's build config:
# debug populates the catalog and binds the socket; release stays
# inert — empty snapshot, notFound press, no socket file.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="latchsmoke"
work="$(mktemp -d -t latch-smoke)"

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    rm -rf "$work"
    rm -rf "${HOME}/Library/Application Support/${app}-dev"
    exit "$status"
}
trap cleanup EXIT INT TERM

fail() {
    echo "fail: $1" >&2
    exit 1
}

expect() {
    grep -q "^$1$" <<<"$2" || fail "expected '$1' in consumer output"
}

mkdir -p "$work/Sources/probe"
cat >"$work/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "latch-consumer",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "Latch", path: "$root")],
    targets: [
        .executableTarget(
            name: "probe",
            dependencies: [.product(name: "Latch", package: "Latch")]
        )
    ],
    swiftLanguageModes: [.v6]
)
EOF

cat >"$work/Sources/probe/main.swift" <<'SWIFT'
import Foundation
import Latch

@main
struct Probe {
    static func main() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/latchsmoke-dev")
        try? FileManager.default.removeItem(at: dir)

        await MainActor.run {
            Latch.start(app: "latchsmoke")
            let binding = LatchCatalog.Binding()
            binding.publish(
                id: "smoke.button",
                role: "button",
                press: { _ in }
            )
            print("snapshot=\(Latch.snapshot().count)")
            do {
                try Latch.press(id: "smoke.button")
                print("press=ok")
            } catch {
                print("press=error")
            }
            do {
                try Latch.dismiss()
                print("dismiss=ok")
            } catch {
                print("dismiss=error")
            }
            _ = binding
        }
        try? await Task.sleep(for: .milliseconds(800))
        let sock = dir.appendingPathComponent("latch.sock")
        print("socket=\(FileManager.default.fileExists(atPath: sock.path))")
        try? FileManager.default.removeItem(at: dir)
    }
}
SWIFT

echo "==> build consumer (debug)"
(cd "$work" && swift build)
echo "==> run consumer (debug)"
debug_out="$("$work/.build/debug/probe")"
echo "$debug_out"
expect "snapshot=1" "$debug_out"
expect "press=ok" "$debug_out"
expect "dismiss=error" "$debug_out"
expect "socket=true" "$debug_out"
echo "ready: debug drives"

echo "==> build consumer (release)"
(cd "$work" && swift build -c release)
echo "==> run consumer (release)"
release_out="$("$work/.build/release/probe")"
echo "$release_out"
expect "snapshot=0" "$release_out"
expect "press=error" "$release_out"
expect "dismiss=error" "$release_out"
expect "socket=false" "$release_out"
echo "ready: release inert"

echo "ready: consumer smoke"
