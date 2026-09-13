#!/bin/bash
# on-stop.sh — Stop フック。
#   1. 未コミット変更の自動コミット (agent/ccx ブランチのみ)
#   2. セッションログ
#   3. Slack / macOS 通知
#
# session_id と cwd は標準入力の JSON から取る。
# 以前は CLAUDE_SESSION_ID を読んでいたため、ログが全行 session=unknown になっていた。

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

HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"
LOG_DIR="$HARNESS_DIR/logs"
mkdir -p "$LOG_DIR"

harness_read_hook_input
SESSION_ID=$(harness_hook_field '.session_id')
CWD=$(harness_hook_field '.cwd')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
[ -n "$CWD" ] || CWD=$(pwd)

BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-branch")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 1. 自動コミット
if [ -x "$HARNESS_ROOT/hooks/auto-commit.sh" ]; then
  HARNESS_HOOK_CWD="$CWD" "$HARNESS_ROOT/hooks/auto-commit.sh" || true
fi

# 2. ログ
printf '[%s] STOP session=%s branch=%s cwd=%s\n' \
  "$TIMESTAMP" "$SESSION_ID" "$BRANCH" "$CWD" >> "$LOG_DIR/sessions.log"

ISSUE=$(printf '%s' "$BRANCH" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)

# 通知は既定で鳴らさない。
#
# 以前はセッションが終わるたびに Slack へ投げていた。ログを見ると累計900件超で、
# その量になると誰も見なくなり、肝心のとき (CI が落ちた・詰まった) に気づけない。
# 「人が動く必要があるとき」に鳴らす役目は nightly 側に寄せてある。
#
# セッション終了ごとの通知が欲しい場合は HARNESS_NOTIFY_ON_STOP=1 を設定する。
if [ "${HARNESS_NOTIFY_ON_STOP:-0}" = "1" ] && [ -x "$HARNESS_ROOT/lib/notify.sh" ]; then
  "$HARNESS_ROOT/lib/notify.sh" -t "Claude Code 完了" -p low \
    "ブランチ: ${BRANCH}${ISSUE:+ (Issue #${ISSUE})}" >/dev/null 2>&1 || true
fi

# macOS のローカル通知は、自律実行のブランチのときだけ。
# 対話セッションでは自分で見ているので鳴らす意味がない。
case "$BRANCH" in
  agent/issue-*|ccx/trial-*)
    if [ "$(uname)" = "Darwin" ]; then
      osascript -e "display notification \"完了: ${BRANCH}\" with title \"Claude Dev Harness\"" \
        >/dev/null 2>&1 || true
    fi
    ;;
esac

exit 0
