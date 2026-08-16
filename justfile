# Latch task runner.
#
# Ship is USER-only (pushes main + tag, creates a GitHub Release).
# Agents: use `just release` / `just check` — never `just ship`.

set shell := ["bash", "-uc", "-o", "pipefail"]

default:
    @just --list

# Type-check and run unit tests.
test:
    swift test

# Lint Swift sources and the CLI / release scripts.
lint:
    swift format lint --strict --recursive Sources Tests examples Package.swift
    shellcheck cli/latch.sh scripts/release.sh

# Tests plus lint. The full pre-ship gate.
check:
    just test
    just lint

# Print the CLI usage.
cli-help:
    bash cli/latch.sh --help

# Build and launch the Notes demo (GUI, Debug).
demo:
    swift run --package-path examples/Notes Notes

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
