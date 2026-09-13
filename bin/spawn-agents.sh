#!/bin/bash
# spawn-agents.sh — 複数の GitHub Issue を並行してエージェントに解かせる。
# 使い方: spawn-agents [オプション] <issue#> [issue#] ...
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
# shellcheck source=../lib/common.sh
. "$HARNESS_ROOT/lib/common.sh"

MAX_PARALLEL="${MAX_PARALLEL:-3}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

usage() {
  cat << EOF
使い方: spawn-agents [オプション] <issue番号> [issue番号...]

オプション:
  -m, --mode MODE      parallel(既定) | tmux | sequential
  -j, --jobs N         並行数の上限 (既定: ${MAX_PARALLEL})
  -p, --pr             完了後に PR を作成する
      --merge          --pr に加えて自動マージまで行う
      --admin          ブランチ保護を bypass して強制マージ (--merge と併用)
      --model MODEL    モデル (既定: ${CLAUDE_MODEL})
  -b, --base BRANCH    ベースブランチ (既定: リポジトリの既定ブランチ)
  -t, --timeout SEC    1エージェントの上限秒数 (既定: ${AGENT_TIMEOUT}、0で無制限)
  -f, --force          未マージ PR がある Issue も再実装する
  -d, --dry-run        実行計画だけ表示する
  -h, --help           このヘルプ

環境変数:
  CLAUDE_MODEL         モデル (既定 claude-opus-5)
  MAX_PARALLEL         並行数の上限 (既定 3)
  AGENT_TIMEOUT        1エージェントの上限秒数 (既定 3600、0で無制限)
  WORKTREES_BASE       worktree の置き場所 (既定 ~/worktrees)
  CLAUDE_HARNESS_DIR   ログの親ディレクトリ (既定 ~/.claude-harness)

worktree は \$WORKTREES_BASE/<リポジトリ名>-issue-<番号>/ に作られる。
リポジトリ名を含めるのは、別リポジトリの同じ番号の Issue と衝突させないため。

例:
  spawn-agents 42 51 67
  spawn-agents --model claude-sonnet-5 -j 5 --merge 1 2 3 4 5
  spawn-agents -j 1 99
EOF
}

MODE="parallel"
DRY_RUN=false
AUTO_PR=false
AUTO_MERGE=false
ADMIN_MERGE=false
FORCE=false
BASE_BRANCH=""
OPEN_PR_NUM=""
ISSUES=""

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)    MODE="${2:-}"; shift 2 ;;
    -j|--jobs)    MAX_PARALLEL="${2:-}"; shift 2 ;;
    -p|--pr)      AUTO_PR=true; shift ;;
    --merge)      AUTO_PR=true; AUTO_MERGE=true; shift ;;
    --admin)      ADMIN_MERGE=true; shift ;;
    --model)      CLAUDE_MODEL="${2:-}"; shift 2 ;;
    -b|--base)    BASE_BRANCH="${2:-}"; shift 2 ;;
    -t|--timeout) AGENT_TIMEOUT="${2:-}"; shift 2 ;;
    -f|--force)   FORCE=true; shift ;;
    -d|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    [0-9]*)       ISSUES="$ISSUES $1"; shift ;;
    *)            usage >&2; harness_die "不明なオプション: $1" ;;
  esac
done

# shellcheck disable=SC2086
set -- $ISSUES
[ $# -gt 0 ] || { usage >&2; harness_die "Issue 番号を1つ以上指定してください"; }
ISSUE_LIST="$*"

harness_require git gh jq claude
harness_require_git_repo

REPO_SLUG=$(harness_repo_slug)
[ -n "$BASE_BRANCH" ] || BASE_BRANCH=$(harness_default_branch)
mkdir -p "$LOG_DIR" "$WORKTREES_BASE"

harness_log "リポジトリ: $REPO_SLUG  ベース: $BASE_BRANCH  モデル: ${CLAUDE_MODEL}"
harness_log "並行上限: ${MAX_PARALLEL}  タイムアウト: ${AGENT_TIMEOUT}s"

# ---- Issue ごとの処理 ----------------------------------------------------

# 未マージの PR が既にある Issue は作業済みとみなす。--force で上書きできる。
#
# 判定はブランチ名 (agent/issue-<番号>-<timestamp>) の前方一致で行う。
# `gh pr list --search "linked:issue-<番号>"` は使わない。`linked:issue` は
# 「Issue に紐づく PR かどうか」の真偽値修飾子で、番号は付けられない。
# 番号付きで渡すと単なる全文検索に落ちて無関係な PR まで拾い、
# エージェント PR が1つでも開いていれば全 Issue がスキップされる。

# stdin の PR 一覧 JSON から、この Issue のエージェント PR 番号を返す。
# ネットワークに触らないのでテストできる。
pr_number_for_issue() {
  jq -r --arg prefix "agent/issue-$1-" \
    '[ .[] | select((.headRefName // "") | startswith($prefix)) ] | .[0].number // empty' \
    2>/dev/null
}

has_open_pr() {
  local issue=$1 num
  num=$(gh pr list --state open --limit 200 --json number,headRefName 2>/dev/null \
    | pr_number_for_issue "$issue")
  [ -n "$num" ] || return 1
  OPEN_PR_NUM="$num"
  return 0
}

fetch_issue() {
  local issue=$1
  gh issue view "$issue" --json number,title,body 2>/dev/null \
    || printf '{"number":%s,"title":"Issue #%s","body":""}' "$issue" "$issue"
}

worktree_path_for() { printf '%s/%s-issue-%s' "$WORKTREES_BASE" "$REPO_SLUG" "$1"; }

# 機械可読イベント。nightly-run.sh などの集計はこれを数える。
# 日本語のログ文言を grep させると、文言を直した瞬間に集計が 0 になる。
emit() {  # emit <種別> <key=value...>
  printf 'HARNESS_EVENT:%s %s\n' "$1" "${*:2}"
}

create_worktree() {
  local issue=$1
  local branch="agent/issue-${issue}-${TIMESTAMP}"
  local path err
  path=$(worktree_path_for "$issue")

  if [ -d "$path" ]; then
    harness_log "既存 worktree を削除: $path"
    git worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
  fi
  git worktree prune >/dev/null 2>&1 || true

  # ベースブランチ起点で切る。origin/<base> があればそちらを優先する。
  local start="$BASE_BRANCH"
  git rev-parse --verify --quiet "origin/$BASE_BRANCH" >/dev/null 2>&1 && start="origin/$BASE_BRANCH"

  if ! err=$(git worktree add "$path" -b "$branch" "$start" 2>&1); then
    harness_log "❌ worktree 作成失敗 (#$issue): ${err%%$'\n'*}"
    return 1
  fi
  printf '%s' "$path"
}

build_prompt() {
  local issue_json=$1 issue_num title body
  issue_num=$(printf '%s' "$issue_json" | jq -r .number)
  title=$(printf '%s' "$issue_json" | jq -r .title)
  body=$(printf '%s' "$issue_json" | jq -r .body)

  cat << EOF
あなたは GitHub Issue を解決する自律エージェントです。

## Issue #${issue_num}: ${title}

${body}

## 必須タスク
以下を必ず順番に実行してください。途中で止まらないこと。

1. CLAUDE.md があれば読む
2. テストファイルを読んで仕様を理解する
3. テストが通るように実装する
4. テストを実行して全部 pass することを確認する
5. 必ず \`git add -A && git commit -m "fix: resolve issue #${issue_num} - ${title}"\` を実行する
6. 最後に "COMPLETED: Issue #${issue_num}" と出力する

## 制約
- コミットせずに終わらないこと
- 質問せずに進めること。権限はすべて承認済みです
- 既存のテストを壊さないこと
EOF
}

create_pr() {
  local issue=$1 worktree=$2
  local branch pr_url pr_num merge_out

  branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1

  if [ "$(git -C "$worktree" rev-list --count "$branch" "^$BASE_BRANCH" 2>/dev/null || echo 0)" = "0" ]; then
    harness_log "⚠️  Issue #${issue}: コミットが無いので PR 作成をスキップ"
    return 1
  fi

  if ! git -C "$worktree" push -u origin "$branch" >/dev/null 2>&1; then
    harness_log "❌ Issue #${issue}: push 失敗"
    emit failed "issue=$issue" "stage=push"
    return 1
  fi

  if ! pr_url=$(gh pr create --head "$branch" \
      --title "fix: resolve issue #${issue}" \
      --body "Closes #${issue}

🤖 Generated by Claude Dev Harness" 2>&1); then
    harness_log "❌ Issue #${issue}: PR 作成失敗: ${pr_url%%$'\n'*}"
    emit failed "issue=$issue" "stage=pr_create"
    return 1
  fi
  harness_log "✅ Issue #${issue}: PR 作成 ${pr_url##*$'\n'}"
  emit pr_created "issue=$issue" "url=${pr_url##*$'\n'}"

  $AUTO_MERGE || return 0

  pr_num=$(printf '%s' "$pr_url" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1)
  [ -n "$pr_num" ] || { harness_log "⚠️  Issue #${issue}: PR 番号を取れず自動マージをスキップ"; return 1; }

  if $ADMIN_MERGE; then
    if merge_out=$(gh pr merge "$pr_num" --merge --admin 2>&1); then
      harness_log "✅ Issue #${issue}: 管理者マージ完了"
      emit merged "issue=$issue" "pr=$pr_num" "mode=admin"
      git -C "$worktree" push origin --delete "$branch" >/dev/null 2>&1 \
        && harness_log "   リモートブランチ削除: $branch" || true
    else
      harness_log "⚠️  Issue #${issue}: 管理者マージ失敗: ${merge_out%%$'\n'*}"
    fi
    return 0
  fi

  # まず --auto (CI 通過後に自動マージ) を試し、使えなければ即マージにフォールバックする。
  # 以前は `merge_out=$(...)` の失敗が set -e でサブシェルごと落としており、
  # このフォールバックには到達していなかった。
  if merge_out=$(gh pr merge "$pr_num" --merge --delete-branch --auto 2>&1); then
    harness_log "✅ Issue #${issue}: 自動マージを予約 (CI 待ち)"
    emit merge_scheduled "issue=$issue" "pr=$pr_num"
  elif printf '%s' "$merge_out" | grep -qE "clean status|Protected branch rules not configured|not enabled"; then
    harness_log "ℹ️  Issue #${issue}: --auto が使えないので即マージを試行"
    if gh pr merge "$pr_num" --merge --delete-branch >/dev/null 2>&1; then
      harness_log "✅ Issue #${issue}: 即マージ完了"
      emit merged "issue=$issue" "pr=$pr_num" "mode=immediate"
    else
      harness_log "⚠️  Issue #${issue}: 即マージも失敗 (手動で: gh pr merge $pr_num)"
    fi
  else
    harness_log "⚠️  Issue #${issue}: マージ予約失敗: ${merge_out%%$'\n'*}"
  fi
}

# エージェント本体。harness_run_with_timeout から呼べるよう関数に切り出す。
run_agent() {
  local worktree=$1 prompt_file=$2 log_file=$3
  (
    cd "$worktree" || exit 1
    claude -p --dangerously-skip-permissions --model "${CLAUDE_MODEL}" \
      < "$prompt_file" 2>&1 | tee "$log_file"
  )
}

run_one() {
  local issue=$1 issue_json title worktree log_file prompt_file rc

  if ! $FORCE && has_open_pr "$issue"; then
    harness_log "⏭️  Issue #${issue}: 未マージの PR #${OPEN_PR_NUM} があるためスキップ (--force で上書き)"
    emit skipped "issue=$issue" "pr=$OPEN_PR_NUM" "reason=open_pr"
    return 0
  fi

  issue_json=$(fetch_issue "$issue")
  title=$(printf '%s' "$issue_json" | jq -r .title)
  harness_log "▶️  Issue #${issue} 開始: ${title}"

  worktree=$(create_worktree "$issue") || return 1
  [ -d "$worktree" ] || { harness_log "❌ Issue #${issue}: worktree がありません"; return 1; }

  log_file="${LOG_DIR}/issue-${issue}-${TIMESTAMP}.log"
  prompt_file="${LOG_DIR}/prompt-issue-${issue}-${TIMESTAMP}.txt"
  build_prompt "$issue_json" > "$prompt_file"

  harness_run_with_timeout "${AGENT_TIMEOUT}" \
    run_agent "$worktree" "$prompt_file" "$log_file"
  rc=$?

  if [ "$rc" = "124" ]; then
    harness_log "⏱️  Issue #${issue}: ${AGENT_TIMEOUT}s でタイムアウト、打ち切りました"
    printf 'AGENT_TIMEOUT:%s\n' "$issue" >> "$log_file"
    emit agent_timeout "issue=$issue"
  else
    printf 'AGENT_DONE:%s\n' "$issue" >> "$log_file"
    harness_log "✅ Issue #${issue} エージェント完了"
    emit agent_done "issue=$issue"
  fi

  # タイムアウトしていても、途中までのコミットがあれば PR にする価値がある
  $AUTO_PR && create_pr "$issue" "$worktree"
  return 0
}

run_parallel() {
  harness_log "🚀 $# 件の Issue を ${MAX_PARALLEL} 並行で処理"

  if $DRY_RUN; then
    local i
    for i in "$@"; do
      printf 'DRY RUN: Issue #%s → %s (branch agent/issue-%s-%s)\n' \
        "$i" "$(worktree_path_for "$i")" "$i" "$TIMESTAMP"
    done
    return 0
  fi

  local pids="" issue
  for issue in "$@"; do
    # shellcheck disable=SC2086
    pids=$(harness_throttle "${MAX_PARALLEL}" $pids)
    run_one "$issue" &
    pids="$pids $!"
  done

  harness_log "⏳ 起動済みジョブの完了を待機中..."
  # shellcheck disable=SC2086
  set -- $pids
  for pid in "$@"; do wait "$pid" 2>/dev/null || true; done

  printf '\n=========================================\n'
  printf '📊 結果サマリー\n'
  printf '  処理: %s 件 / モデル: %s\n' "$#" "${CLAUDE_MODEL}"
  printf '  ログ: %s\n' "$LOG_DIR"
  printf '=========================================\n'
}

run_tmux() {
  harness_require tmux
  local session="claude-agents-${TIMESTAMP}"
  tmux new-session -d -s "$session" -x 220 -y 50

  local first=true issue issue_json worktree log_file prompt_file
  for issue in "$@"; do
    issue_json=$(fetch_issue "$issue")
    worktree=$(create_worktree "$issue") || continue
    log_file="${LOG_DIR}/issue-${issue}-${TIMESTAMP}.log"
    prompt_file="${LOG_DIR}/prompt-issue-${issue}-${TIMESTAMP}.txt"
    build_prompt "$issue_json" > "$prompt_file"

    if $first; then
      tmux rename-window -t "$session:0" "issue-${issue}"
      first=false
    else
      tmux new-window -t "$session" -n "issue-${issue}"
    fi

    # プロンプトはファイル経由で渡す。コマンド行に埋め込むと
    # Issue 本文のクォートやバッククォートで壊れる。
    tmux send-keys -t "$session:issue-${issue}" \
      "cd $(printf '%q' "$worktree") && claude -p --dangerously-skip-permissions --model $(printf '%q' "${CLAUDE_MODEL}") < $(printf '%q' "$prompt_file") 2>&1 | tee $(printf '%q' "$log_file"); echo; echo '[Enter で閉じる]'; read" Enter
  done

  harness_log "✅ tmux セッション起動: $session"
  tmux attach -t "$session"
}

# shellcheck disable=SC2086
set -- $ISSUE_LIST
case "$MODE" in
  parallel)   run_parallel "$@" ;;
  sequential) MAX_PARALLEL=1; run_parallel "$@" ;;
  tmux)       run_tmux "$@" ;;
  *)          harness_die "不明なモード: $MODE" ;;
esac
