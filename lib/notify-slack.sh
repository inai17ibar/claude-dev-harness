#!/bin/bash
# notify-slack.sh — Slack通知ヘルパー (簡易メッセージ用)
# 使い方: notify-slack.sh "メッセージ"

MSG="${1:-(no message)}"

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "$MSG" >&2
  exit 0
fi

curl -s -X POST "$SLACK_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{\"text\": \"${MSG}\"}" >/dev/null 2>&1

exit $?
