#!/bin/bash
# hook-input.sh — Claude Code のフック入力を読むためのヘルパー。
#
# Claude Code はフックに JSON を **標準入力** で渡す:
#
#   {"session_id":"...","transcript_path":"...","cwd":"...",
#    "hook_event_name":"PreToolUse","tool_name":"Bash",
#    "tool_input":{"command":"ls -la"}}
#
# 以前このハーネスは CLAUDE_TOOL_INPUT_COMMAND / CLAUDE_TOOL_INPUT_FILE_PATH /
# CLAUDE_SESSION_ID という環境変数を読んでいたが、そんな変数は渡ってこない。
# その結果 safety-guard も post-write も何もせず素通りしていた (2026-09-12 に発覚)。

HOOK_INPUT=""

# 標準入力を一度だけ読む。端末から直接叩いたときにぶら下がらないよう -t 0 を見る。
harness_read_hook_input() {
  if [ -t 0 ]; then
    HOOK_INPUT=""
  else
    HOOK_INPUT=$(cat 2>/dev/null || true)
  fi
}

# JSON から値を取り出す。jq を優先し、無ければ python3 にフォールバックする。
# 使い方: harness_hook_field '.tool_input.command'
harness_hook_field() {
  local filter="$1"
  [ -n "$HOOK_INPUT" ] || return 0

  # HARNESS_FORCE_PYTHON=1 で python3 経路を強制できる (テスト用)
  if [ "${HARNESS_FORCE_PYTHON:-0}" != "1" ] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$HOOK_INPUT" | jq -r "$filter // empty" 2>/dev/null
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    # .a.b 形式の単純なパスだけ対応すれば足りる
    printf '%s' "$HOOK_INPUT" | HARNESS_FILTER="$filter" python3 -c '
import json, os, sys
path = [p for p in os.environ["HARNESS_FILTER"].lstrip(".").split(".") if p]
try:
    cur = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in path:
    if not isinstance(cur, dict) or key not in cur:
        sys.exit(0)
    cur = cur[key]
if cur is not None:
    sys.stdout.write(cur if isinstance(cur, str) else json.dumps(cur))
' 2>/dev/null
    return 0
  fi

  return 0
}
