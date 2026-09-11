#!/usr/bin/env bash
# Launch Notes, drive the catalog, tear down. Proof that the kernel
# CLI can run a real app. No YAML runner. No new kernel verbs.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
notes="${root}/examples/Notes"
latch="${notes}/latch.sh"
app="notes"
notes_pid=""
notes_log=""
step_label=""
catalog_json=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$notes_pid" ]]; then
        if kill -0 "$notes_pid" 2>/dev/null; then
            kill -TERM "$notes_pid" 2>/dev/null || true
            local deadline=$((SECONDS + 5))
            while kill -0 "$notes_pid" 2>/dev/null && ((SECONDS < deadline)); do
                sleep 0.1
            done
            if kill -0 "$notes_pid" 2>/dev/null; then
                kill -KILL "$notes_pid" 2>/dev/null || true
            fi
        fi
        wait "$notes_pid" 2>/dev/null || true
    fi
    if [[ -n "$notes_log" && -f "$notes_log" ]]; then
        rm -f "$notes_log"
    fi
    exit "$status"
}

trap cleanup EXIT INT TERM

fail() {
    echo "fail: ${step_label:-unknown}" >&2
    if [[ -n "${1-}" ]]; then
        echo "$1" >&2
    fi
    echo "==> doctor" >&2
    "$latch" doctor >&2 || true
    echo "==> catalog" >&2
    "$latch" catalog >&2 || true
    if [[ -n "$notes_log" && -f "$notes_log" ]]; then
        echo "==> notes log" >&2
        tail -n 80 "$notes_log" >&2 || true
    fi
    exit 1
}

step() {
    step_label="$1"
    shift
    echo "==> ${step_label}"
    "$@" || fail "command failed"
}

refresh_catalog() {
    catalog_json="$("$latch" catalog)" || fail "catalog failed"
}

has_id() {
    python3 -c '
import json, sys
items = json.loads(sys.argv[1])
sys.exit(0 if any(item.get("id") == sys.argv[2] for item in items) else 1)
' "$catalog_json" "$1"
}

expect_present() {
    local id="$1"
    if ! has_id "$id"; then
        fail "catalog missing ${id}"
    fi
}

expect_absent() {
    local id="$1"
    if has_id "$id"; then
        fail "catalog still has ${id}"
    fi
}

expect_parent() {
    local id="$1"
    local parent="$2"
    python3 -c '
import json, sys
items = json.loads(sys.argv[1])
wanted = sys.argv[2]
parent = sys.argv[3]
for item in items:
    if item.get("id") == wanted:
        actual = item.get("parent") or ""
        sys.exit(0 if actual == parent else 1)
sys.exit(1)
' "$catalog_json" "$id" "$parent" || fail "${id} parent is not ${parent}"
}

expect_unavailable() {
    local id="$1"
    local out
    local status=0
    out="$("$latch" ax press "$id" 2>&1)" || status=$?
    if [[ "$status" -eq 0 ]]; then
        fail "press ${id} succeeded (wanted unavailable)"
    fi
    if [[ "$out" != *unavailable* ]]; then
        fail "press ${id} failed without unavailable: ${out}"
    fi
    echo "unavailable: ${id}"
}

wait_gone() {
    local id="$1"
    local timeout="${2:-30}"
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        if ! "$latch" ax find "$id" >/dev/null 2>&1; then
            echo "ready: ${id} gone"
            return 0
        fi
        sleep 0.2
    done
    fail "timeout: ${id} still present"
}

check_screenshot() {
    local shot path
    shot="$("$latch" screenshot main)" || fail "screenshot failed"
    path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["path"])' "$shot")"
    if [[ ! -f "$path" ]]; then
        fail "screenshot file missing: ${path}"
    fi
    echo "screenshot: ${path}"
}

if [[ ! -f "$latch" ]]; then
    echo "error: Notes project CLI missing at ${latch}." >&2
    exit 1
fi

if "$latch" ping >/dev/null 2>&1; then
    echo "error: Notes already running; quit that copy and retry." >&2
    echo "  socket: ~/Library/Application Support/${app}-dev/latch.sock" >&2
    exit 1
fi

echo "==> build Notes"
swift build --package-path "$notes" --product Notes
bin_dir="$(swift build --package-path "$notes" --show-bin-path)"
bin="${bin_dir}/Notes"
if [[ ! -x "$bin" ]]; then
    echo "error: Notes binary missing at ${bin}." >&2
    exit 1
fi

notes_log="$(mktemp -t latch-notes-e2e.XXXXXX)"
echo "==> launch Notes"
"$bin" >"$notes_log" 2>&1 &
notes_pid=$!

cd "$notes"

step "wait boot" "$latch" wait boot --state ready
step "wait window" "$latch" wait window main
step "wait editor.title" "$latch" wait ax editor.title

step_label="boot catalog"
doctor_out="$("$latch" doctor)" || fail "doctor failed"
echo "$doctor_out"
if grep -q "next: empty catalog" <<<"$doctor_out"; then
    fail "doctor next is empty catalog"
fi
if ! grep -q "next: ok" <<<"$doctor_out"; then
    fail "doctor next is not ok"
fi

refresh_catalog
expect_present window.main
expect_present editor.title
expect_present editor.new
expect_present prefs.appearance.dark
expect_absent window.main-AppWindow-1
expect_absent sheet.compose
expect_absent composer.title
expect_absent composer.save
expect_absent composer.cancel
echo "ready: boot catalog"

step "set dark" "$latch" ax set prefs.appearance.dark true
step "wait dark" "$latch" wait ax prefs.appearance.dark --value true

step "press New" "$latch" ax press editor.new
step "wait composer.title" "$latch" wait ax composer.title

step_label="sheet catalog"
refresh_catalog
expect_present sheet.compose
expect_present composer.title
expect_present composer.save
expect_present composer.cancel
expect_parent composer.title sheet.compose
expect_parent composer.save sheet.compose
expect_parent composer.cancel sheet.compose
echo "ready: sheet catalog"

step "wait save disabled" "$latch" wait ax composer.save --disabled
step_label="disabled Save press"
expect_unavailable composer.save

step "set composer.title" "$latch" ax set composer.title Hello
step "wait save enabled" "$latch" wait ax composer.save --enabled
step "press Save" "$latch" ax press composer.save

step_label="dismiss composer"
wait_gone composer.save
step "wait editor.title Hello" "$latch" wait ax editor.title --value Hello

step "hide main" "$latch" window hide main
step "wait main hidden" "$latch" wait window main --hidden
step "show main" "$latch" window show main
step "wait main visible" "$latch" wait window main

step_label="screenshot"
check_screenshot

echo "ready: e2e"
