#!/usr/bin/env bash
# install-hooks.sh — wire git pre-commit hook to lint Solidity + JS locally.
#
# Two CI failures in this repo's history were "forge fmt --check" wanting
# different formatting than my local forge (iter-8, iter-19). The fix each
# time was running `forge fmt` locally before pushing — but it's easy to
# forget. This hook makes it automatic.
#
#   bash scripts/install-hooks.sh
#
# Skip the hook for one commit: `git commit --no-verify`.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOOK="$ROOT/.git/hooks/pre-commit"
mkdir -p "$ROOT/.git/hooks"

cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# pre-commit: forge fmt --check + node --check on touched files.
# Bypass with `git commit --no-verify`.

set -e

if [ -t 1 ]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; X=$'\033[0m'
else R= G= Y= X=; fi

# Solidity files staged?
sol_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.sol$' || true)
if [ -n "$sol_files" ]; then
  if ! command -v forge >/dev/null; then
    echo "${Y}!${X} forge not on PATH; skipping fmt-check (will fail in CI)"
  else
    echo "  forge fmt --check on staged .sol files…"
    cd "$(git rev-parse --show-toplevel)/contracts"
    if ! forge fmt --check >/dev/null 2>&1; then
      echo "${R}✗ forge fmt --check failed${X}"
      echo "  fix locally with: cd contracts && forge fmt"
      echo "  bypass: git commit --no-verify"
      exit 1
    fi
    echo "${G}✓${X} forge fmt clean"
    cd - >/dev/null
  fi
fi

# JS files staged?
js_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(mjs|js)$' || true)
if [ -n "$js_files" ]; then
  echo "  node --check on staged .mjs/.js files…"
  for f in $js_files; do
    if ! node --check "$f" >/dev/null 2>&1; then
      echo "${R}✗ node --check failed: $f${X}"
      exit 1
    fi
  done
  echo "${G}✓${X} node syntax clean"
fi

# Bash files staged?
sh_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.sh$' || true)
if [ -n "$sh_files" ]; then
  echo "  bash -n on staged .sh files…"
  for f in $sh_files; do
    if ! bash -n "$f" >/dev/null 2>&1; then
      echo "${R}✗ bash -n failed: $f${X}"
      exit 1
    fi
  done
  echo "${G}✓${X} bash syntax clean"
fi
EOF

chmod +x "$HOOK"
echo "✓ pre-commit hook installed at $HOOK"
echo "  bypass per-commit:  git commit --no-verify"
echo "  uninstall:          rm $HOOK"
