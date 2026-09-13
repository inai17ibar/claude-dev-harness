#!/bin/bash
# weekly-audit.sh — リポジトリを監査して「改善の種」を idea Issue として自動起票する。
# 起票された idea Issue は人間が選別して automation ラベルを付けると、その晩の
# nightly-run.sh (spawn-agents) が実装する。このスクリプトは起票のみ行い、実装はしない。
set -uo pipefail

HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"
AUDIT_DIR="$HARNESS_DIR/audit"
LOG_DIR="$AUDIT_DIR/logs"
mkdir -p "$LOG_DIR"

# launchd 経由でも Slack 通知できるよう、環境ファイルがあれば読む
if [ -f "$HARNESS_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/env.sh"
fi

# 監査対象。$HARNESS_DIR/audit/config.sh があればそちらで上書きできる
AUDIT_REPOS=("inai17ibar/vlog-cockpit" "inai17ibar/stune")
if [ -f "$HARNESS_DIR/audit/config.sh" ]; then
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/audit/config.sh"
fi
MAX_NEW_ISSUES=5
MODEL="${CLAUDE_MODEL:-claude-opus-5}"  # lib/common.sh と揃える

TS=$(date '+%Y%m%d_%H%M%S')
RUN_LOG="$LOG_DIR/audit-${TS}.log"
exec > >(tee -a "$RUN_LOG") 2>&1
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "🔍 Weekly Audit 開始 (model=$MODEL, max=${MAX_NEW_ISSUES}件/repo)"

for cmd in gh claude git; do
  command -v "$cmd" >/dev/null || { log "❌ 必須コマンドなし: $cmd"; exit 1; }
done
gh auth status >/dev/null 2>&1 || { log "❌ gh 認証切れ"; exit 1; }

for repo in "${AUDIT_REPOS[@]}"; do
  log "── $repo ──"
  local_path="$HOME/repos/$(basename "$repo")"
  if [ ! -d "$local_path/.git" ]; then
    log "  📥 clone: $repo → $local_path"
    mkdir -p "$HOME/repos"
    git clone "https://github.com/$repo.git" "$local_path" 2>&1 | tail -2
  else
    log "  🔄 最新化: $local_path"
    git -C "$local_path" fetch --all --prune >/dev/null 2>&1
    db=$(git -C "$local_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    git -C "$local_path" checkout "${db:-main}" >/dev/null 2>&1
    git -C "$local_path" pull --ff-only >/dev/null 2>&1
  fi

  gh label create idea --repo "$repo" --color FBCA04 \
    --description "思いつき置き場。選別して automation を付けると夜間ジョブが実装する" 2>/dev/null || true

  existing=$(gh issue list --repo "$repo" --state open --limit 100 --json title -q '.[].title')

  prompt=$(cat <<PROMPT
あなたは個人開発リポジトリの監査係です。カレントディレクトリのコードベースを調査し、開発者が後で拾える「改善の種」をGitHub Issueとして起票してください。

探すもの（優先順）:
1. コード中の TODO / FIXME / HACK コメントで、Issue化する価値があるもの
2. README や UI 文言が約束しているのに未実装・中途半端な機能
3. 明らかな小バグ・エラーハンドリング漏れ（確信が持てるものだけ）
4. テストが全く無い重要モジュール

ルール:
- 起票は最大 ${MAX_NEW_ISSUES} 件まで。数を埋めるための水増しはしない。価値が薄ければ0件でもよい
- 1件のIssueは、エージェントが本文だけを読んで自律実装できる粒度・具体性にする
- 以下の既存Open Issueと重複・近接するものは起票しない:
${existing:-（既存Issueなし）}
- 起票コマンド: gh issue create --repo ${repo} --label idea --title "<日本語1行>" --body "<根拠のファイルパスと理由を2〜4行>"
- 実装・コード変更・コミットは一切しない。起票のみ
- 最後に起票したIssueのURL一覧（0件なら「起票なし」）を出力して終了
PROMPT
)
  (cd "$local_path" && echo "$prompt" | claude -p --dangerously-skip-permissions --model "$MODEL") \
    || log "  ⚠️ claude 終了コード非ゼロ"
done

log "✅ Weekly Audit 完了"
NOTIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/notify-slack.sh"
if [ -x "$NOTIFY" ]; then
  "$NOTIFY" "🔍 Weekly Audit 完了。ログ: $RUN_LOG" || true
fi
