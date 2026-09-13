#!/bin/bash
# notify.sh — 通知の送り先をまとめる。設定されているものにだけ送り、
# 何も設定されていなければ標準エラーに出して終わる。
#
# 環境変数:
#   NTFY_TOPIC         ntfy のトピック名。これだけで送れる (アカウント不要)
#   NTFY_SERVER        既定 https://ntfy.sh
#   SLACK_WEBHOOK_URL  Slack Incoming Webhook
#
# 使い方:
#   notify.sh "本文"
#   notify.sh -t "タイトル" -p high -u "https://github.com/..." "本文"
#
# launchd から呼ばれる経路では ~/.claude-harness/env.sh に置く。
# ログインシェルの環境は継承されない。
set -uo pipefail

HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"
[ -f "$HARNESS_DIR/env.sh" ] && . "$HARNESS_DIR/env.sh"

TITLE="Claude Dev Harness"
PRIORITY="default"
CLICK_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--title)    TITLE="${2:-}"; shift 2 ;;
    -p|--priority) PRIORITY="${2:-}"; shift 2 ;;
    -u|--url)      CLICK_URL="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) break ;;
  esac
done

MSG="${1:-}"
[ -n "$MSG" ] || { echo "notify.sh: 本文がありません" >&2; exit 1; }

sent=false

# ---- ntfy ----------------------------------------------------------------
if [ -n "${NTFY_TOPIC:-}" ]; then
  server="${NTFY_SERVER:-https://ntfy.sh}"
  # shellcheck disable=SC2086
  if curl -s --max-time 10 \
      -H "Title: $TITLE" \
      -H "Priority: $PRIORITY" \
      ${CLICK_URL:+-H "Click: $CLICK_URL"} \
      -d "$MSG" \
      "$server/$NTFY_TOPIC" >/dev/null 2>&1; then
    sent=true
  fi
fi

# ---- Slack ---------------------------------------------------------------
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  payload=$(printf '%s' "$MSG" | python3 -c '
import json, sys, os
text = sys.stdin.read()
title = os.environ.get("HARNESS_NOTIFY_TITLE", "")
print(json.dumps({"text": (title + "\n" if title else "") + text}))
' 2>/dev/null) || payload=""
  if [ -n "$payload" ]; then
    HARNESS_NOTIFY_TITLE="$TITLE" \
    curl -s --max-time 10 -X POST "$SLACK_WEBHOOK_URL" \
      -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 && sent=true
  fi
fi

# ---- どこにも送れなければ手元に出す ---------------------------------------
$sent || printf '[notify] %s: %s\n' "$TITLE" "$MSG" >&2
exit 0
