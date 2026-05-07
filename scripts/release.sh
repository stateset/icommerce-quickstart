#!/usr/bin/env bash
# release.sh — automate the tag → GitHub release flow.
#
#   bash scripts/release.sh v0.2.0          # interactive: opens $EDITOR for notes
#   bash scripts/release.sh v0.2.0 --notes "Quick patch for X"  # one-shot
#
# What it does:
#   1. Verifies cwd is clean and on main, in sync with origin
#   2. Verifies CHANGELOG.md has the new version's entry (skip with --force)
#   3. Verifies the latest CI run on main is green (skip with --force)
#   4. Creates an annotated tag pointing at HEAD
#   5. Pushes the tag
#   6. Creates the GitHub release with the tag's notes
#
# Doesn't touch published packages — this repo doesn't publish to npm/PyPI.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; X=$'\033[0m'
else G= R= Y= D= B= X=; fi

ok()   { echo -e "  ${G}OK${X}    $*"; }
bad()  { echo -e "  ${R}FAIL${X}  $*"; }
warn() { echo -e "  ${Y}WARN${X}  $*"; }
info() { echo -e "  ${B}->${X}    $*"; }

# Args
TAG="${1:-}"
NOTES_INLINE=""
FORCE=0
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES_INLINE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) bad "unknown flag: $1"; exit 2 ;;
  esac
done

if [ -z "$TAG" ]; then
  cat <<EOF
${B}usage:${X} bash scripts/release.sh <vX.Y.Z> [--notes "..." | --force]

  <vX.Y.Z>     New tag, e.g. v0.2.0 (must start with 'v')
  --notes      Inline release notes (else opens \$EDITOR)
  --force      Skip CHANGELOG + CI green checks
EOF
  exit 2
fi

case "$TAG" in v*) ;; *) bad "tag must start with 'v', e.g. v0.2.0"; exit 2 ;; esac

echo -e "${B}stateset release ${TAG}${X}"

# 1. Clean working tree
if [ -n "$(git status --porcelain)" ]; then
  bad "working tree dirty:"; git status --short; exit 1
fi
ok "working tree clean"

# 2. On main
branch=$(git branch --show-current)
[ "$branch" = "main" ] || { bad "must be on 'main' (on '$branch')"; exit 1; }
ok "on main"

# 3. In sync with origin
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { bad "local main not in sync with origin/main"; exit 1; }
ok "in sync with origin/main"

# 4. Tag doesn't already exist
git rev-parse -q --verify "$TAG" >/dev/null 2>&1 && { bad "tag $TAG exists locally"; exit 1; }
git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "$TAG" && { bad "tag $TAG exists on origin"; exit 1; }
ok "tag $TAG is new"

# 5. CHANGELOG mention (unless --force)
if [ $FORCE -ne 1 ]; then
  ver="${TAG#v}"
  grep -qE "^## \[${ver}\]" CHANGELOG.md || { bad "CHANGELOG.md has no '## [${ver}]' section"; info "move [Unreleased] entries to a new ## [${ver}] section first"; exit 1; }
  ok "CHANGELOG.md has [${ver}] section"
fi

# 6. CI green on HEAD (unless --force)
if [ $FORCE -ne 1 ] && command -v gh >/dev/null; then
  conclusion=$(gh run list --repo stateset/icommerce-quickstart --branch main --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || echo "")
  case "$conclusion" in
    success) ok "CI green on main" ;;
    "")      warn "couldn't reach gh; skipping CI check" ;;
    *)       bad "latest CI on main: $conclusion (not releasing without --force)"; exit 1 ;;
  esac
elif [ $FORCE -ne 1 ]; then
  warn "gh not installed; skipping CI check"
fi

# Notes
if [ -n "$NOTES_INLINE" ]; then
  NOTES="$NOTES_INLINE"
else
  TMP=$(mktemp)
  cat > "$TMP" <<EOF
${TAG} - release

# Replace this with the user-visible release notes. Lines starting with #
# are stripped before posting.
#
# Suggested:
#   ## What is new
#   ## Fixes
#   ## Breaking
#   ## Verified
EOF
  ${EDITOR:-vi} "$TMP"
  NOTES=$(grep -v '^#' "$TMP")
  rm -f "$TMP"
  [ -n "${NOTES// /}" ] || { bad "release notes empty"; exit 1; }
fi

info "tagging $TAG"
git tag -a "$TAG" -m "$NOTES"

info "pushing tag"
git push origin "$TAG"

info "creating GitHub release"
gh release create "$TAG" --repo stateset/icommerce-quickstart --title "$TAG" --notes "$NOTES"

echo ""
ok "released ${TAG}"
ok "https://github.com/stateset/icommerce-quickstart/releases/tag/${TAG}"
