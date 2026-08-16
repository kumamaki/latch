#!/usr/bin/env bash
# Latch CLI. Talks to latch.sock with the same newline-JSON one-shot
# envelope as the Swift server. Wait lives here (poll query*) so the
# server never pins a Task past its 10s recv budget.

set -euo pipefail

app="${LATCH_APP-}"
data_dir=""
socket_path=""
token_path=""

usage() {
    cat >&2 <<'EOF'
latch [--app slug] <command> [args]

Resolve the socket from --app / LATCH_APP:
  ~/Library/Application Support/<app>-dev/latch.sock

Commands:
  ping
  query boot
  query windows
  window show <name>
  window hide <name>
  wait boot --state <state> [--timeout 30]
  wait window <name> [--hidden] [--timeout 30]
  wait ax <id> [--timeout 30]
  ax dump [--labeled] [window]
  ax find <id>
  ax press <id> [action]
  ax set <id> <value>
  screenshot <window>
EOF
    exit 64
}

resolve_paths() {
    if [[ -z "$app" ]]; then
        echo "error: pass --app <slug> or set LATCH_APP." >&2
        exit 1
    fi
    data_dir="${HOME}/Library/Application Support/${app}-dev"
    socket_path="${data_dir}/latch.sock"
    token_path="${data_dir}/latch.token"
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

read_token() {
    if [[ ! -f "$token_path" ]]; then
        echo "error: Latch token missing at ${token_path}. Is the Debug app running?" >&2
        exit 1
    fi
    tr -d '[:space:]' <"$token_path"
}

round_trip() {
    local command="$1"
    local args_json="${2-}"
    local token
    token="$(read_token)"
    if [[ ! -S "$socket_path" ]]; then
        echo "error: Latch socket is not listening at ${socket_path}. Start the Debug app." >&2
        exit 1
    fi
    local payload
    if [[ -n "$args_json" ]]; then
        payload=$(printf '{"token":%s,"command":%s,"args":%s}' \
            "$(json_escape "$token")" "$(json_escape "$command")" "$args_json")
    else
        payload=$(printf '{"token":%s,"command":%s}' \
            "$(json_escape "$token")" "$(json_escape "$command")")
    fi
    printf '%s\n' "$payload" | nc -U "$socket_path"
}

print_or_fail() {
    local response="$1"
    python3 - "$response" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    envelope = json.loads(raw)
except json.JSONDecodeError:
    print(f"protocol: unparseable response: {raw}", file=sys.stderr)
    sys.exit(1)
if not envelope.get("ok"):
    err = envelope.get("error") or {}
    print(f"{err.get('code', 'error')}: {err.get('message', 'unknown error')}", file=sys.stderr)
    sys.exit(1)
data = envelope.get("data")
if data not in (None, {}, []):
    print(json.dumps(data, indent=2))
PY
}

query() {
    local command="$1"
    local args_json="${2-}"
    local response
    response="$(round_trip "$command" "$args_json")"
    print_or_fail "$response"
}

wait_until() {
    local timeout="$1"
    local label="$2"
    shift 2
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if "$@"; then
            echo "ready: ${label}"
            exit 0
        fi
        sleep 0.2
    done
    echo "timeout: ${label}" >&2
    exit 1
}

socket_ready() {
    [[ -S "$socket_path" && -f "$token_path" ]]
}

boot_ready() {
    local wanted="$1"
    socket_ready || return 1
    local response
    response="$(round_trip queryBoot)"
    python3 - "$response" "$wanted" <<'PY'
import json, sys
envelope = json.loads(sys.argv[1])
if not envelope.get("ok"):
    sys.exit(1)
sys.exit(0 if envelope["data"].get("state") == sys.argv[2] else 1)
PY
}

window_ready() {
    local name="$1"
    local want_visible="$2"
    socket_ready || return 1
    local response
    response="$(round_trip queryWindows)"
    python3 - "$response" "$name" "$want_visible" <<'PY'
import json, sys
envelope = json.loads(sys.argv[1])
name = sys.argv[2]
want = sys.argv[3] == "1"
if not envelope.get("ok"):
    sys.exit(1)
for item in envelope["data"].get("items", []):
    if item.get("name") == name:
        sys.exit(0 if bool(item.get("visible")) == want else 1)
sys.exit(1)
PY
}

ax_ready() {
    local identifier="$1"
    socket_ready || return 1
    local response
    response="$(round_trip axFind "$(printf '{"id":%s}' "$(json_escape "$identifier")")")"
    python3 - "$response" <<'PY'
import json, sys
envelope = json.loads(sys.argv[1])
sys.exit(0 if envelope.get("ok") else 1)
PY
}

[[ $# -gt 0 ]] || usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            app="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "error: unknown flag $1" >&2
            usage
            ;;
        *)
            break
            ;;
    esac
done

resolve_paths
[[ $# -gt 0 ]] || usage
command="$1"
shift

case "$command" in
    ping) query ping ;;
    query)
        kind="${1-}"; shift || true
        case "$kind" in
            boot) query queryBoot ;;
            windows) query queryWindows ;;
            *) usage ;;
        esac
        ;;
    window)
        action="${1-}"; name="${2-}"
        [[ -n "$name" && ( "$action" == "show" || "$action" == "hide" ) ]] || usage
        if [[ "$action" == "show" ]]; then
            query windowShow "$(printf '{"window":%s}' "$(json_escape "$name")")"
        else
            query windowHide "$(printf '{"window":%s}' "$(json_escape "$name")")"
        fi
        ;;
    wait)
        kind="${1-}"; shift || true
        timeout=30
        state=""
        hidden=0
        leftover=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --timeout) timeout="$2"; shift 2 ;;
                --state) state="$2"; shift 2 ;;
                --hidden) hidden=1; shift ;;
                --visible) hidden=0; shift ;;
                *) leftover+=("$1"); shift ;;
            esac
        done
        set -- "${leftover[@]+"${leftover[@]}"}"
        case "$kind" in
            boot)
                [[ -n "$state" ]] || usage
                wait_until "$timeout" "boot ${state}" boot_ready "$state"
                ;;
            window)
                [[ $# -ge 1 ]] || usage
                label="window ${1} $([ "$hidden" = 1 ] && echo hidden || echo visible)"
                wait_until "$timeout" "$label" window_ready "$1" "$([ "$hidden" = 1 ] && echo 0 || echo 1)"
                ;;
            ax)
                [[ $# -ge 1 ]] || usage
                wait_until "$timeout" "ax ${1}" ax_ready "$1"
                ;;
            *) usage ;;
        esac
        ;;
    ax)
        verb="${1-}"; shift || true
        case "$verb" in
            dump)
                labeled=false
                window=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --labeled) labeled=true; shift ;;
                        *) window="$1"; shift ;;
                    esac
                done
                if [[ -n "$window" ]]; then
                    query axDump "$(printf '{"window":%s,"labeled":%s}' "$(json_escape "$window")" "$labeled")"
                elif [[ "$labeled" == true ]]; then
                    query axDump '{"labeled":true}'
                else
                    query axDump
                fi
                ;;
            find)
                [[ $# -ge 1 ]] || usage
                query axFind "$(printf '{"id":%s}' "$(json_escape "$1")")"
                ;;
            press)
                [[ $# -ge 1 ]] || usage
                if [[ $# -ge 2 ]]; then
                    query axPress "$(printf '{"id":%s,"action":%s}' "$(json_escape "$1")" "$(json_escape "$2")")"
                else
                    query axPress "$(printf '{"id":%s}' "$(json_escape "$1")")"
                fi
                ;;
            set)
                [[ $# -ge 2 ]] || usage
                query axSet "$(printf '{"id":%s,"value":%s}' "$(json_escape "$1")" "$(json_escape "$2")")"
                ;;
            *) usage ;;
        esac
        ;;
    screenshot)
        [[ $# -ge 1 ]] || usage
        query screenshot "$(printf '{"window":%s}' "$(json_escape "$1")")"
        ;;
    *) usage ;;
esac
