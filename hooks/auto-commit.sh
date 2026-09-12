#!/bin/bash
# auto-commit.sh — エージェントが commit し忘れたまま止まったときの保険。
# agent/issue-* と ccx/trial-* ブランチでのみ動く。
#
# 対象ディレクトリは HARNESS_HOOK_CWD (on-stop.sh が渡す) → pwd の順で決める。

set -uo pipefail

HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"
TARGET="${HARNESS_HOOK_CWD:-$(pwd)}"

cd "$TARGET" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$BRANCH" in
  agent/issue-*|ccx/trial-*) ;;
  *) exit 0 ;;
esac

# 変更が無ければ何もしない
if git diff --quiet 2>/dev/null \
  && git diff --cached --quiet 2>/dev/null \
  && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  exit 0
fi

ISSUE=$(printf '%s' "$BRANCH" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
if [ -n "$ISSUE" ]; then
  MSG="fix: resolve issue #${ISSUE}

🤖 Auto-committed by Claude Dev Harness
Branch: ${BRANCH}"
else
  MSG="chore: auto-commit by Claude Dev Harness

Branch: ${BRANCH}"
fi

git add -A >/dev/null 2>&1 || exit 0
if git commit -m "$MSG" >/dev/null 2>&1; then
  mkdir -p "$HARNESS_DIR/logs"
  printf '[%s] auto-commit branch=%s issue=%s cwd=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$BRANCH" "${ISSUE:-none}" "$TARGET" \
    >> "$HARNESS_DIR/logs/auto-commit.log"
fi

exit 0
