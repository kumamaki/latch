#!/usr/bin/env bash
# Orchestrates a Latch tagged release.
#
# Latch is a SwiftPM library. The version is the git tag, not Package.swift.
# Agents run this without --confirm (dry-run). Users run `just ship`.
#
# What it does:
#   1. Validates preconditions (on main, clean tree, not behind origin).
#   2. Validates the requested X.Y.Z version (semver-shaped, not already
#      taken locally or on the remote, strictly newer than the latest v* tag).
#   3. Runs `just check`.
#   4. Shows the plan (commits, pin replacements, changelog heading,
#      and any unprefixed X.Y.Z twin of the new tag).
#   5. With --confirm, stamps CHANGELOG + pins, commits, pushes main,
#      deletes an unprefixed X.Y.Z twin, tags vX.Y.Z, pushes the tag,
#      and creates a GitHub Release from the stamped changelog section.
#
# Dry-run leaves the tree clean. Confirm reads /dev/tty so agent shells
# fail closed.
#
# Usage:
#   scripts/release.sh --version 0.1.0
#   scripts/release.sh --version 0.1.0 --confirm
#
# Flags:
#   --version X.Y.Z   required, semver-shaped (no leading "v", no pre-release)
#   --confirm         prompt on /dev/tty, then mutate (default: dry-run)
#   --remote NAME     git remote (default: origin)

set -euo pipefail

VERSION=""
DO_CONFIRM=0
REMOTE="origin"
CHANGELOG="CHANGELOG.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version requires X.Y.Z}"; shift 2 ;;
    --confirm) DO_CONFIRM=1; shift ;;
    --remote) REMOTE="${2:?--remote requires a name}"; shift 2 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) echo "release.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "release.sh: --version X.Y.Z is required" >&2
  exit 2
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release.sh: '$VERSION' is not X.Y.Z-shaped (pre-release tags aren't supported)" >&2
  exit 2
fi

TAG="v$VERSION"
UNPREFIXED_TAG="$VERSION"
IFS=. read -r MAJOR MINOR _ <<< "$VERSION"
STATUS="${MAJOR}.${MINOR}."

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

changelog_has_version() {
  awk -v ver="$1" '
    $0 == "## " ver { found = 1; exit }
    index($0, "## " ver " — ") == 1 { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$CHANGELOG"
}

extract_section() {
  local heading="$1"
  local dest="$2"
  awk -v heading="$heading" '
    $0 == heading { grab = 1; next }
    grab && /^## / { exit }
    grab { lines[++n] = $0 }
    END {
      start = 1
      end = n
      while (start <= end && lines[start] ~ /^$/) start++
      while (end >= start && lines[end] ~ /^$/) end--
      for (i = start; i <= end; i++) print lines[i]
    }
  ' "$CHANGELOG" >"$dest"
}

replace_pin() {
  local file="$1"
  awk -v ver="$VERSION" '
    {
      if ($0 ~ /\.package\(url: "https:\/\/github.com\/kumamaki\/latch", from: "[0-9]+\.[0-9]+\.[0-9]+"\)/) {
        sub(/from: "[0-9]+\.[0-9]+\.[0-9]+"/, "from: \"" ver "\"")
        count++
      }
      print
    }
    END {
      if (count != 1) {
        print "release.sh: pin rewrite expected 1 match, found " count + 0 > "/dev/stderr"
        exit 1
      }
    }
  ' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

# --- Preconditions --------------------------------------------------------

HEAD_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
if [[ "$HEAD_BRANCH" != "main" ]]; then
  echo "release.sh: must be on 'main' (currently on '$HEAD_BRANCH')" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "release.sh: working tree is dirty — commit or stash first" >&2
  git status --short >&2
  exit 1
fi

git fetch "$REMOTE" main --tags --quiet

REMOTE_HEAD="$(git rev-parse "$REMOTE/main" 2>/dev/null || echo "")"
if [[ -z "$REMOTE_HEAD" ]]; then
  echo "release.sh: '$REMOTE/main' not found — is the remote configured?" >&2
  exit 1
fi

BEHIND="$(git rev-list --count HEAD.."$REMOTE/main")"
if [[ "$BEHIND" -gt 0 ]]; then
  echo "release.sh: local main is behind $REMOTE/main by $BEHIND commit(s) — pull first" >&2
  exit 1
fi
AHEAD="$(git rev-list --count "$REMOTE/main"..HEAD)"

if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "release.sh: tag '$TAG' already exists locally" >&2
  exit 1
fi
if git ls-remote --tags --exit-code "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "release.sh: tag '$TAG' already exists on $REMOTE" >&2
  exit 1
fi

LAST_TAG="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged HEAD --sort=-version:refname \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
if [[ -n "$LAST_TAG" ]]; then
  PREV="${LAST_TAG#v}"
  HIGHER="$(printf '%s\n%s\n' "$PREV" "$VERSION" | sort -V | tail -1)"
  if [[ "$HIGHER" != "$VERSION" || "$PREV" == "$VERSION" ]]; then
    echo "release.sh: '$VERSION' is not strictly newer than last tag '$LAST_TAG'" >&2
    exit 1
  fi
fi

DELETE_LOCAL_UNPREFIXED=0
DELETE_REMOTE_UNPREFIXED=0
if git rev-parse -q --verify "refs/tags/$UNPREFIXED_TAG" >/dev/null; then
  DELETE_LOCAL_UNPREFIXED=1
fi
if git ls-remote --tags --exit-code "$REMOTE" "refs/tags/$UNPREFIXED_TAG" >/dev/null 2>&1; then
  DELETE_REMOTE_UNPREFIXED=1
fi

if ! grep -qx '## Unreleased' "$CHANGELOG"; then
  echo "release.sh: $CHANGELOG has no '## Unreleased' section" >&2
  exit 1
fi
if changelog_has_version "$VERSION"; then
  echo "release.sh: $CHANGELOG already has a '$VERSION' heading" >&2
  exit 1
fi

PIN_FILES=(README.md docs/agent-setup.md)
PIN_PATTERN='\.package\(url: "https://github.com/kumamaki/latch", from: "[0-9]+\.[0-9]+\.[0-9]+"\)'
for pin_file in "${PIN_FILES[@]}"; do
  pin_count="$(grep -cE "$PIN_PATTERN" "$pin_file" || true)"
  if [[ "$pin_count" -ne 1 ]]; then
    echo "release.sh: expected exactly one SwiftPM pin in <$pin_file>, found <$pin_count>" >&2
    exit 1
  fi
done

STATUS_COUNT="$(grep -cE '^Status: [0-9]+\.[0-9]+\.' README.md || true)"
if [[ "$STATUS_COUNT" -ne 1 ]]; then
  echo "release.sh: expected exactly one 'Status: X.Y.' line in README.md, found <$STATUS_COUNT>" >&2
  exit 1
fi

NOTES_FILE="$(mktemp)"
TAG_MSG_FILE="$(mktemp)"
cleanup() { rm -f "$NOTES_FILE" "$TAG_MSG_FILE"; }
trap cleanup EXIT

extract_section "## Unreleased" "$NOTES_FILE"
if [[ ! -s "$NOTES_FILE" ]]; then
  echo "release.sh: Unreleased is empty — nothing to ship" >&2
  exit 1
fi

if [[ "$DO_CONFIRM" -eq 1 ]] && ! command -v gh >/dev/null 2>&1; then
  echo "release.sh: --confirm requires the 'gh' CLI" >&2
  exit 1
fi

# --- Checks ---------------------------------------------------------------

echo "→ just check"
just check

# --- Plan -----------------------------------------------------------------

{
  echo "Latch $VERSION"
  echo
  if [[ -n "$LAST_TAG" ]]; then
    echo "Changes since $LAST_TAG:"
    git --no-pager log --pretty='- %s' "$LAST_TAG"..HEAD
  elif [[ "$DELETE_LOCAL_UNPREFIXED" -eq 1 || "$DELETE_REMOTE_UNPREFIXED" -eq 1 ]]; then
    echo "Replaces unprefixed tag $UNPREFIXED_TAG."
    git --no-pager log --pretty='- %s'
  else
    echo "First release."
    git --no-pager log --pretty='- %s'
  fi
  echo "- chore: release $TAG"
} >"$TAG_MSG_FILE"

echo
echo "Release plan"
echo "  version : $VERSION"
echo "  tag     : $TAG"
echo "  remote  : $REMOTE"
echo "  prev tag: ${LAST_TAG:-<none>}"
echo "  ahead   : $AHEAD commit(s)"
echo "  status  : Status: $STATUS"
if [[ "$DELETE_LOCAL_UNPREFIXED" -eq 1 || "$DELETE_REMOTE_UNPREFIXED" -eq 1 ]]; then
  echo "  delete  : $UNPREFIXED_TAG (local=$DELETE_LOCAL_UNPREFIXED remote=$DELETE_REMOTE_UNPREFIXED)"
fi
echo
echo "Will stamp:"
echo "  CHANGELOG.md  ## Unreleased  →  ## $VERSION — $(date +%Y-%m-%d)"
for pin_file in "${PIN_FILES[@]}"; do
  current_pin="$(grep -E "$PIN_PATTERN" "$pin_file")"
  echo "  $pin_file  $current_pin  →  from: \"$VERSION\""
done
echo "  README.md  Status: X.Y.  →  Status: $STATUS"
echo
echo "Tag annotation:"
sed 's/^/  /' "$TAG_MSG_FILE"
echo
echo "GitHub Release notes:"
sed 's/^/  /' "$NOTES_FILE"
echo

if [[ "$DO_CONFIRM" -ne 1 ]]; then
  echo "Dry-run only. Tree is clean."
  echo "Re-run with --confirm (or just ship) to stamp, push, tag, and release."
  exit 0
fi

read -r -p "Stamp, push $REMOTE/main, tag $TAG, and create the GitHub Release? [y/N] " reply </dev/tty
case "$reply" in
  y|Y|yes|YES) ;;
  *) echo "release.sh: aborted" >&2; exit 1 ;;
esac

# --- Execute --------------------------------------------------------------

TODAY="$(date +%Y-%m-%d)"

awk -v ver="$VERSION" -v today="$TODAY" '
  $0 == "## Unreleased" && !done {
    print "## Unreleased"
    print ""
    print "## " ver " — " today
    done = 1
    next
  }
  { print }
' "$CHANGELOG" >"$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"

for pin_file in "${PIN_FILES[@]}"; do
  replace_pin "$pin_file"
done

awk -v status="$STATUS" '
  {
    if ($0 ~ /^Status: [0-9]+\.[0-9]+\./) {
      sub(/^Status: [0-9]+\.[0-9]+\./, "Status: " status)
      count++
    }
    print
  }
  END {
    if (count != 1) {
      print "release.sh: status rewrite expected 1 match, found " count + 0 > "/dev/stderr"
      exit 1
    }
  }
' README.md >README.md.tmp
mv README.md.tmp README.md

echo "Committing version stamp..."
git add CHANGELOG.md README.md docs/agent-setup.md
git commit -m "chore: release $TAG"

if [[ "$AHEAD" -gt 0 || "$(git rev-parse HEAD)" != "$REMOTE_HEAD" ]]; then
  echo "Pushing to $REMOTE/main..."
  git push "$REMOTE" main
fi

if [[ "$DELETE_LOCAL_UNPREFIXED" -eq 1 ]]; then
  echo "Deleting local tag <$UNPREFIXED_TAG>..."
  git tag -d "$UNPREFIXED_TAG"
fi
if [[ "$DELETE_REMOTE_UNPREFIXED" -eq 1 ]]; then
  echo "Deleting $REMOTE tag <$UNPREFIXED_TAG>..."
  git push "$REMOTE" ":refs/tags/$UNPREFIXED_TAG"
fi

TAG_TARGET="$(git rev-parse HEAD)"
echo "Creating annotated tag $TAG at $TAG_TARGET..."
git tag -a "$TAG" -F "$TAG_MSG_FILE" "$TAG_TARGET"

echo "Pushing $TAG to $REMOTE..."
git push "$REMOTE" "$TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release.sh: GitHub Release '$TAG' already exists" >&2
  exit 1
fi

echo "Waiting for GitHub to see <$TAG>..."
seen=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if git ls-remote --tags --exit-code "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
    if gh api "repos/{owner}/{repo}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
      seen=1
      break
    fi
  fi
  sleep 1
done
if [[ "$seen" -ne 1 ]]; then
  echo "release.sh: GitHub never saw tag <$TAG>" >&2
  exit 1
fi

extract_section "## $VERSION — $TODAY" "$NOTES_FILE"
if [[ ! -s "$NOTES_FILE" ]]; then
  echo "release.sh: stamped changelog section for <$VERSION> is empty" >&2
  exit 1
fi

echo "Creating GitHub Release <$TAG>..."
gh release create "$TAG" --verify-tag --title "$TAG" --notes-file "$NOTES_FILE"

echo
echo "=== ship complete ==="
echo "  tag     $TAG"
echo "  release https://github.com/kumamaki/latch/releases/tag/$TAG"
