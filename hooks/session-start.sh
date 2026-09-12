#!/bin/bash
# session-start.sh — SessionStart フック。
# 標準出力がそのままセッションのコンテキストとして読み込まれる。

set -uo pipefail

# シンボリックリンク (/usr/local/bin/*) 経由で呼ばれても実体の位置を求める。
# BASH_SOURCE はリンクのパスのままなので、そのまま dirname するとライブラリを見失う。
# macOS の readlink には -f が無いので自前でたどる。
_harness_self="${BASH_SOURCE[0]}"
while [ -L "$_harness_self" ]; do
  _harness_dir=$(cd -P "$(dirname "$_harness_self")" && pwd)
  _harness_self=$(readlink "$_harness_self")
  case "$_harness_self" in
    /*) ;;
    *) _harness_self="$_harness_dir/$_harness_self" ;;
  esac
done
HARNESS_ROOT=$(cd -P "$(dirname "$_harness_self")/.." && pwd)
# shellcheck source=../lib/hook-input.sh
. "$HARNESS_ROOT/lib/hook-input.sh"

harness_read_hook_input
CWD=$(harness_hook_field '.cwd')
[ -n "$CWD" ] || CWD=$(pwd)
cd "$CWD" 2>/dev/null || true

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

echo "=== セッション開始コンテキスト ==="
echo "時刻: $(date '+%Y-%m-%d %H:%M:%S')"
echo "ディレクトリ: $CWD"

if [ -n "$BRANCH" ]; then
  echo "ブランチ: $BRANCH"
  if git rev-parse --git-dir 2>/dev/null | grep -q "/worktrees/"; then
    echo "※ このセッションは git worktree 内で動作しています"
  fi

  ISSUE=$(printf '%s' "$BRANCH" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$ISSUE" ] && command -v gh >/dev/null 2>&1; then
    echo ""
    echo "=== 担当 Issue #${ISSUE} ==="
    gh issue view "$ISSUE" --json title,body \
      -q '"タイトル: " + .title + "\n本文:\n" + .body' 2>/dev/null \
      || echo "(gh で Issue を取得できませんでした)"
  fi
fi

[ -f "$CWD/CLAUDE.md" ] && { echo ""; echo "※ このプロジェクトには CLAUDE.md があります。参照してください。"; }

echo "=================================="
exit 0
