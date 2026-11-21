# Latch task runner.
#
# Ship is USER-only (pushes main + tag, creates a GitHub Release).
# Agents: use `just release` / `just check` — never `just ship`.

set shell := ["bash", "-uc", "-o", "pipefail"]

default:
    @just --list

# Unit tests only — desk-safe: no GUI journeys, no windows on screen.
# The E2E journeys drive real apps and run in a VM: `just test-journeys`.
test:
    swift test --no-parallel --skip LatchE2ETests

# GUI journeys in a disposable Tart VM on the mini — never on this desk.
# On the mini it runs this checkout; elsewhere it syncs the tree to
# server.local:~/Work/latch-e2e first. Extra args reach `swift test`,
# e.g. `just test-journeys --filter DragJourneyTests/dragSessionJourney`.
test-journeys *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -x "$HOME/.local/bin/tart" ]] || command -v tart >/dev/null 2>&1; then
        # /bin/bash: Homebrew bash hides the ARP table from `tart ip`.
        exec /bin/bash scripts/vm/journeys.sh "$@"
    fi
    remote="server.local"
    rsync -az --delete \
        --exclude .git --exclude .build --exclude .latch-trace --exclude build \
        ./ "$remote:Work/latch-e2e/"
    cmd='cd ~/Work/latch-e2e && exec /bin/bash scripts/vm/journeys.sh'
    for arg in "$@"; do printf -v q ' %q' "$arg"; cmd+="$q"; done
    exec ssh "$remote" "$cmd"

# Lint Swift sources and the CLI / release / check scripts.
lint:
    swift format lint --strict --recursive Sources Tests examples Package.swift
    shellcheck cli/latch.sh examples/Notes/latch.sh scripts/release.sh scripts/audit-config.sh scripts/smoke-consumer.sh scripts/demo-transcript.sh scripts/vm/image.sh scripts/vm/journeys.sh

# Assert Release carries no driving-surface impl or API.
audit-config:
    bash scripts/audit-config.sh

# Build and run a scratch consumer package against this checkout.
smoke-consumer:
    bash scripts/smoke-consumer.sh

# Unit tests, lint, and config audits. The full pre-ship gate — desk-safe.
check:
    just test
    just lint
    just audit-config
    just smoke-consumer

# Run the Gallery demo journey (drives a GUI app) and write its transcript into the README.
demo-transcript:
    swift test --filter GalleryJourneyTests/demoJourney
    bash scripts/demo-transcript.sh "$(ls -d .latch-trace/gallery-demo-* | tail -1)"

# Print the CLI usage.
cli-help:
    bash cli/latch.sh --help

# Build and launch an example app (GUI, Debug): notes or gallery.
demo name="notes":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{name}}" in
      notes) swift run --package-path examples/Notes Notes ;;
      gallery) swift run Gallery ;;
      *) echo "usage: just demo [notes|gallery]" >&2; exit 2 ;;
    esac

# Next X.Y.Z from the latest v* tag (fallback v0.0.0). Unprefixed tags do not count.
[private]
next-version kind:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{kind}}" in
      major|minor|patch) ;;
      *) echo "usage: just release|ship <major|minor|patch>" >&2; exit 2 ;;
    esac
    git fetch origin main --tags --quiet
    latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged HEAD --sort=-version:refname \
      | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
    latest="${latest:-v0.0.0}"
    IFS=. read -r major minor patch <<< "${latest#v}"
    case "{{kind}}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
    esac
    echo "${latest} ${major}.${minor}.${patch}"

# Agent-safe dry-run: checks + print the release plan. Does not write or push.
release kind:
    #!/usr/bin/env bash
    set -euo pipefail
    bump="$(just next-version "{{kind}}")"
    read -r latest next <<<"$bump"
    echo "==> bumping {{kind}}: ${latest} → v${next}"
    echo
    ./scripts/release.sh --version "${next}"

# USER-ONLY: stamp, push main+tag, GitHub Release. Agents: use just release.
ship kind:
    #!/usr/bin/env bash
    set -euo pipefail
    bump="$(just next-version "{{kind}}")"
    read -r latest next <<<"$bump"
    echo "==> bumping {{kind}}: ${latest} → v${next}"
    echo
    ./scripts/release.sh --version "${next}" --confirm
