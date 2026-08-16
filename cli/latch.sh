#!/usr/bin/env bash
# Latch CLI. Talks to latch.sock with the same newline-JSON one-shot
# envelope as the Swift server. Wait lives here (poll query*) so the
# server never pins a Task past its 10s recv budget.

set -euo pipefail

app=""
app_from_flag=""
app_source=""
slug_file=""
data_dir=""
socket_path=""
token_path=""

usage() {
    cat >&2 <<'EOF'
latch [--app slug] <command> [args]

Resolve the socket from, first hit wins:
  --app, LATCH_APP, then cwd-to-root .latch.json ({"app":"<slug>"}).

  ~/Library/Application Support/<app>-dev/latch.sock

Commands:
  ping
  doctor
  ids
  query boot
  query windows
  window show <name>
  window hide <name>
  wait boot --state <state> [--timeout 30]
  wait window <name> [--hidden] [--timeout 30]
  wait ax <id> [--value <string>] [--enabled|--disabled] [--timeout 30]
  ax dump [--labeled] [window]
  ax find <id>
  ax press <id> [action]
  ax set <id> <value>
  catalog [window]
  screenshot <window>
EOF
    exit 64
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

parse_latch_json() {
    local file="$1"
    local parsed
    parsed="$(
        python3 - "$file" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except json.JSONDecodeError as error:
    print(f"error: {path} is not valid JSON: {error}", file=sys.stderr)
    sys.exit(1)
except OSError as error:
    print(f"error: cannot read {path}: {error}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print(f"error: {path} must be a JSON object with an app key.", file=sys.stderr)
    sys.exit(1)
app = data.get("app")
if not isinstance(app, str) or not app.strip():
    print(f"error: {path} is missing a non-empty app string.", file=sys.stderr)
    sys.exit(1)
print(app.strip())
PY
    )"
    app="$parsed"
    app_source=".latch.json"
    slug_file="$file"
}

find_latch_json() {
    local dir="$PWD"
    while true; do
        local candidate="$dir/.latch.json"
        if [[ -f "$candidate" ]]; then
            parse_latch_json "$candidate"
            return
        fi
        local parent
        parent="$(dirname "$dir")"
        if [[ "$parent" == "$dir" ]]; then
            break
        fi
        dir="$parent"
    done
    echo "error: pass --app <slug>, set LATCH_APP, or add .latch.json with {\"app\":\"<slug>\"}." >&2
    exit 1
}

resolve_slug() {
    if [[ -n "$app_from_flag" ]]; then
        app="$app_from_flag"
        app_source="--app"
    elif [[ -n "${LATCH_APP-}" ]]; then
        app="$LATCH_APP"
        app_source="LATCH_APP"
    else
        find_latch_json
    fi
}

resolve_paths() {
    resolve_slug
    data_dir="${HOME}/Library/Application Support/${app}-dev"
    socket_path="${data_dir}/latch.sock"
    token_path="${data_dir}/latch.token"
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

labeled_dump() {
    local window="${1-}"
    if [[ -n "$window" ]]; then
        round_trip axDump "$(printf '{"window":%s,"labeled":true}' "$(json_escape "$window")")"
    else
        round_trip axDump '{"labeled":true}'
    fi
}

flatten_catalog() {
    python3 - "$1" <<'PY'
import json, sys

def walk(node, out):
    if not isinstance(node, dict):
        return
    ident = node.get("id")
    if ident:
        item = {
            "id": ident,
            "role": node.get("role"),
            "enabled": node.get("enabled"),
            "actions": node.get("actions") or [],
        }
        for key in ("title", "value", "window", "kind", "choices", "description"):
            val = node.get(key)
            if val not in (None, [], ""):
                item[key] = val
        out.append(item)
    for child in node.get("children") or []:
        walk(child, out)

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
items = []
walk((envelope.get("data") or {}).get("root") or {}, items)
items.sort(key=lambda node: node["id"])
print(json.dumps(items, indent=2))
PY
}

print_ids() {
    python3 - "$1" <<'PY'
import json, sys

def walk(node, out):
    if not isinstance(node, dict):
        return
    ident = node.get("id")
    if ident:
        title = node.get("title")
        role = node.get("role") or ""
        surface = title if title not in (None, "") else role
        out.append((ident, surface))
    for child in node.get("children") or []:
        walk(child, out)

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
items = []
walk((envelope.get("data") or {}).get("root") or {}, items)
items.sort(key=lambda row: row[0])
print("| Id | Surface |")
print("|---|---|")
for ident, surface in items:
    surface = str(surface).replace("|", "\\|")
    print(f"| `{ident}` | {surface} |")
PY
}

doctor() {
    local token_exists="false"
    local token_mode="missing"
    if [[ -f "$token_path" ]]; then
        token_exists="true"
        token_mode="$(stat -f '0%Lp' "$token_path")"
    fi

    local socket_listening="false"
    if [[ -S "$socket_path" ]]; then
        socket_listening="true"
    fi

    local ping_status="failed"
    local ping_code=""
    local boot="unknown"
    local windows=0
    local catalog=0

    if [[ "$token_exists" == "true" && "$socket_listening" == "true" ]]; then
        local response=""
        if response="$(round_trip ping 2>/dev/null)"; then
            local parsed
            parsed="$(
                python3 - "$response" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    envelope = json.loads(raw)
except json.JSONDecodeError:
    print("unparseable\tunknown\t0\t0\tprotocol")
    sys.exit(0)
if not envelope.get("ok"):
    err = envelope.get("error") or {}
    print(f"failed\tunknown\t0\t0\t{err.get('code', 'error')}")
    sys.exit(0)
data = envelope.get("data") or {}
boot = data.get("boot") or "unknown"
windows = data.get("windows") if isinstance(data.get("windows"), int) else 0
catalog = data.get("catalog") if isinstance(data.get("catalog"), int) else 0
print(f"ok\t{boot}\t{windows}\t{catalog}\t")
PY
            )"
            IFS=$'\t' read -r ping_status boot windows catalog ping_code <<<"$parsed"
        fi
    fi

    local next="ok"
    if [[ "$token_exists" != "true" ]]; then
        next="token missing"
    elif [[ "$socket_listening" != "true" ]]; then
        next="socket down"
    elif [[ "$ping_status" != "ok" ]]; then
        if [[ "$ping_code" == "unauthenticated" ]]; then
            next="token missing"
        else
            next="socket down"
        fi
    elif [[ "$boot" == "starting" ]]; then
        next="still starting"
    elif [[ "$boot" == "failed" ]]; then
        next="boot failed"
    elif [[ "$catalog" -eq 0 ]]; then
        next="empty catalog"
    fi

    echo "slug: ${app}"
    echo "slug_from: ${app_source}"
    if [[ -n "$slug_file" ]]; then
        echo "slug_file: ${slug_file}"
    fi
    echo "token: ${token_path}"
    echo "token_exists: ${token_exists}"
    echo "token_mode: ${token_mode}"
    echo "socket: ${socket_path}"
    echo "socket_listening: ${socket_listening}"
    echo "ping: ${ping_status}"
    echo "boot: ${boot}"
    echo "windows: ${windows}"
    echo "catalog: ${catalog}"
    echo "next: ${next}"

    if [[ "$ping_status" == "ok" && "$boot" != "failed" ]]; then
        exit 0
    fi
    exit 1
}

wait_until() {
    local timeout="$1"
    local label="$2"
    shift 2
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
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
    local check_value="$2"
    local want_value="$3"
    local enabled_flag="$4"
    socket_ready || return 1
    local response
    response="$(round_trip axFind "$(printf '{"id":%s}' "$(json_escape "$identifier")")")"
    python3 - "$response" "$check_value" "$want_value" "$enabled_flag" <<'PY'
import json, sys
envelope = json.loads(sys.argv[1])
if not envelope.get("ok"):
    sys.exit(1)
node = (envelope.get("data") or {}).get("node") or {}
check_value = sys.argv[2] == "1"
want_value = sys.argv[3]
enabled_flag = sys.argv[4]
if check_value and node.get("value") != want_value:
    sys.exit(1)
if enabled_flag == "1" and node.get("enabled") is not True:
    sys.exit(1)
if enabled_flag == "0" and node.get("enabled") is not False:
    sys.exit(1)
sys.exit(0)
PY
}

[[ $# -gt 0 ]] || usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || usage
            app_from_flag="$2"
            shift 2
            ;;
        --help | -h)
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
    doctor) doctor ;;
    ids)
        print_ids "$(labeled_dump)"
        ;;
    query)
        kind="${1-}"
        shift || true
        case "$kind" in
            boot) query queryBoot ;;
            windows) query queryWindows ;;
            *) usage ;;
        esac
        ;;
    window)
        action="${1-}"
        name="${2-}"
        [[ -n "$name" && ("$action" == "show" || "$action" == "hide") ]] || usage
        if [[ "$action" == "show" ]]; then
            query windowShow "$(printf '{"window":%s}' "$(json_escape "$name")")"
        else
            query windowHide "$(printf '{"window":%s}' "$(json_escape "$name")")"
        fi
        ;;
    wait)
        kind="${1-}"
        shift || true
        timeout=30
        state=""
        hidden=0
        check_value=0
        want_value=""
        enabled_flag=""
        leftover=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --timeout)
                    [[ $# -ge 2 ]] || usage
                    timeout="$2"
                    shift 2
                    ;;
                --state)
                    [[ $# -ge 2 ]] || usage
                    state="$2"
                    shift 2
                    ;;
                --hidden) hidden=1; shift ;;
                --visible) hidden=0; shift ;;
                --value)
                    [[ $# -ge 2 ]] || usage
                    check_value=1
                    want_value="$2"
                    shift 2
                    ;;
                --enabled)
                    if [[ "$enabled_flag" == "0" ]]; then
                        echo "error: --enabled and --disabled cannot be combined." >&2
                        exit 1
                    fi
                    enabled_flag=1
                    shift
                    ;;
                --disabled)
                    if [[ "$enabled_flag" == "1" ]]; then
                        echo "error: --enabled and --disabled cannot be combined." >&2
                        exit 1
                    fi
                    enabled_flag=0
                    shift
                    ;;
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
                label="ax ${1}"
                if [[ "$check_value" == 1 ]]; then
                    label="${label} value=${want_value}"
                fi
                if [[ "$enabled_flag" == 1 ]]; then
                    label="${label} enabled"
                elif [[ "$enabled_flag" == 0 ]]; then
                    label="${label} disabled"
                fi
                wait_until "$timeout" "$label" ax_ready "$1" "$check_value" "$want_value" "$enabled_flag"
                ;;
            *) usage ;;
        esac
        ;;
    ax)
        verb="${1-}"
        shift || true
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
    catalog)
        flatten_catalog "$(labeled_dump "${1-}")"
        ;;
    screenshot)
        [[ $# -ge 1 ]] || usage
        query screenshot "$(printf '{"window":%s}' "$(json_escape "$1")")"
        ;;
    *) usage ;;
esac
