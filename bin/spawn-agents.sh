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
      --no-review      PR 作成後の自動レビューを行わない
      --review-model M レビューに使うモデル (既定: 実装と同じ)
  -d, --dry-run        実行計画だけ表示する
  -h, --help           このヘルプ

環境変数:
  CLAUDE_MODEL         モデル (既定 claude-opus-5)
  MAX_PARALLEL         並行数の上限 (既定 3)
  AGENT_TIMEOUT        1エージェントの上限秒数 (既定 3600、0で無制限)
  HARNESS_REVIEW_MODEL レビューに使うモデル (既定: 実装と同じ)
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
DO_REVIEW=true
REVIEW_MODEL="${HARNESS_REVIEW_MODEL:-}"
BASE_BRANCH=""
OPEN_PR_NUM=""
OPEN_PR_STATE=""
OPEN_PR_DETAIL=""
OPEN_PR_FLAGGED=""
NEEDS_ATTENTION_LABEL="${NEEDS_ATTENTION_LABEL:-needs-attention}"
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
    --no-review)  DO_REVIEW=false; shift ;;
    --review-model) REVIEW_MODEL="${2:-}"; shift 2 ;;
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

# stdin の PR 一覧 JSON から、この Issue のエージェント PR を探し
#   <番号> <TAB> <waiting|stuck> <TAB> <詳細>
# を返す。ネットワークに触らないのでテストできる。
#
# waiting = 人間待ち (CI 実行中 / レビュー待ち)。放っておけば進む
# stuck   = 機械では進めない (CI 失敗 / コンフリクト)。人間が見ないと永久に止まる
#
# この区別が無いと、壊れた PR とレビュー待ちの PR がサマリー上で同じ
# 「スキップ」に見え、詰まっていることに誰も気づけない。
pr_info_for_issue() {
  jq -r --arg prefix "agent/issue-$1-" --arg flag "$NEEDS_ATTENTION_LABEL" '
    def check_state:
      if (.__typename // "") == "CheckRun" then
        (if (.status // "") != "COMPLETED" then "PENDING" else (.conclusion // "NEUTRAL") end)
      else
        (.state // "PENDING")
      end;
    def check_name: (.name // .context // "check");
    [ .[] | select((.headRefName // "") | startswith($prefix)) ] | .[0] // empty
    | . as $pr
    | [ (.statusCheckRollup // [])[] | {n: check_name, s: check_state} ] as $checks
    | ($checks | map(select(.s | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","ERROR")))) as $bad
    | ($checks | map(select(.s == "PENDING"))) as $pending
    | ([ (.labels // [])[].name ] | index($flag) != null) as $flagged
    | (if ($pr.mergeable // "") == "CONFLICTING" then
         ["stuck", "conflict"]
       elif ($bad | length) > 0 then
         ["stuck", "ci_failed:" + ($bad | map(.n) | join(","))]
       elif ($pending | length) > 0 then
         ["waiting", "ci_running"]
       else
         ["waiting", "review"]
       end) as $st
    | [$pr.number, $st[0], $st[1], (if $flagged then "1" else "0" end)]
    | @tsv' 2>/dev/null
}

has_open_pr() {
  local issue=$1 info
  info=$(gh pr list --state open --limit 200 \
    --json number,headRefName,mergeable,statusCheckRollup,labels 2>/dev/null \
    | pr_info_for_issue "$issue")
  [ -n "$info" ] || return 1
  OPEN_PR_NUM=$(printf '%s' "$info" | cut -f1)
  OPEN_PR_STATE=$(printf '%s' "$info" | cut -f2)
  OPEN_PR_DETAIL=$(printf '%s' "$info" | cut -f3)
  OPEN_PR_FLAGGED=$(printf '%s' "$info" | cut -f4)
  return 0
}

# 閉じた PR に残った印を落とす。
#
# 詰まりが直って CI が緑になると auto-merge がそのままマージするので、
# open PR を見て回る clear_needs_attention は走らない。印を残したままだと
# label:needs-attention の検索が信用できなくなる。1実行につき1回だけ掃く。
sweep_stale_attention_labels() {
  local nums
  nums=$(gh pr list --state closed --limit 30 --label "$NEEDS_ATTENTION_LABEL" \
    --json number -q '.[].number' 2>/dev/null) || return 0
  [ -n "$nums" ] || return 0
  local n
  for n in $nums; do
    gh pr edit "$n" --remove-label "$NEEDS_ATTENTION_LABEL" >/dev/null 2>&1 \
      && harness_log "🏷️  閉じた PR #${n} から ${NEEDS_ATTENTION_LABEL} を外しました" || true
  done
}

# 詰まった PR に印を付ける。
#
# ラベルは通知であると同時に「もう知らせた」という記録でもある。
# nightly は1日9回走るので、これが無いと同じ PR に毎回コメントが積まれる。
# ラベルが既に付いていれば何もしない。
mark_needs_attention() {
  local pr=$1 detail=$2 issue=$3

  gh label create "$NEEDS_ATTENTION_LABEL" --color D93F0B \
    --description "エージェントのPRが自力で進めない状態。人手が要る" >/dev/null 2>&1 || true

  if ! gh pr edit "$pr" --add-label "$NEEDS_ATTENTION_LABEL" >/dev/null 2>&1; then
    harness_log "   ⚠️  PR #${pr} にラベルを付けられませんでした"
    return 1
  fi

  local reason
  case "$detail" in
    conflict)     reason="ベースブランチとコンフリクトしています。" ;;
    ci_failed:*)  reason="CI が失敗しています (${detail#ci_failed:})。" ;;
    *)            reason="自力で進めない状態です ($detail)。" ;;
  esac

  gh pr comment "$pr" --body "🛑 このPRは自力で進めません。${reason}

Harness はこの状態を検出すると Issue #${issue} をスキップし続けます。
直すか、このPRを閉じて Issue を作り直してください。
（対応後は \`${NEEDS_ATTENTION_LABEL}\` ラベルが自動で外れます）" >/dev/null 2>&1 || true

  harness_log "   🏷️  PR #${pr} に ${NEEDS_ATTENTION_LABEL} を付けました"
  return 0
}

# 直ったら印を外す
clear_needs_attention() {
  local pr=$1
  gh pr edit "$pr" --remove-label "$NEEDS_ATTENTION_LABEL" >/dev/null 2>&1 \
    && harness_log "   🏷️  PR #${pr} の ${NEEDS_ATTENTION_LABEL} を外しました" || true
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

  pr_num=$(printf '%s' "$pr_url" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1)

  # レビューは CI と並行に走らせる。マージ判断はブロックしない。
  if $DO_REVIEW && [ -n "$pr_num" ]; then
    review_pr "$issue" "$worktree" "$pr_num" || true
  fi

  $AUTO_MERGE || return 0

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

# PR を作ったあとに自動レビューを走らせ、指摘を PR にコメントする。
# CI とは別物。CI は「動くか」を見るが、これは「この直し方でよいか」を見る。
# マージはブロックしない (人が読んで判断する材料を置くだけ)。
#
# レビュアーは worktree の中で動かす。差分だけ渡すより周辺のコードを
# 読めたほうが精度が上がるため。ただし読むだけのはずなので、
# 終わったあとに worktree が変わっていないことを必ず確かめる。
review_pr() {
  local issue=$1 worktree=$2 pr_num=$3
  local model="${REVIEW_MODEL:-$CLAUDE_MODEL}"
  local prompt_file="${LOG_DIR}/review-prompt-${issue}-${TIMESTAMP}.txt"
  local out_file="${LOG_DIR}/review-${issue}-${TIMESTAMP}.md"
  local diff_file="${LOG_DIR}/review-diff-${issue}-${TIMESTAMP}.diff"

  git -C "$worktree" diff "$BASE_BRANCH"...HEAD > "$diff_file" 2>/dev/null || true
  if [ ! -s "$diff_file" ]; then
    harness_log "   ℹ️  Issue #${issue}: 差分が無いのでレビューをスキップ"
    return 0
  fi

  local lines
  lines=$(wc -l < "$diff_file" | tr -d ' ')
  local truncated=""
  if [ "$lines" -gt 2000 ]; then
    head -2000 "$diff_file" > "${diff_file}.head" && mv "${diff_file}.head" "$diff_file"
    truncated="（差分が大きいため先頭2000行のみ）"
  fi

  {
    cat << 'PROMPT'
このリポジトリで、あるエージェントが Issue を解決する変更を書きました。
その変更をレビューしてください。

## 出し方

1行目に必ず次のどちらかを書いてください。

  REVIEW: 指摘なし
  REVIEW: 要確認 <件数>件

2行目以降に、指摘があれば箇条書きで書いてください。1件につき
「どのファイルの何が、なぜ問題か」を1〜2行で。修正案は不要です。

## 見るところ

- 仕様と実装のズレ。テストは通るが Issue の意図を満たしていない、など
- 境界条件の取りこぼし（0・負数・空・null・オーバーフロー）
- 既存コードの規約や書き方から外れているところ
- 明らかに危ないもの（認可の抜け、秘密の直書き、注入の余地）

## 見なくてよいところ

- 好みの問題、命名の細かい趣味
- フォーマッタが直すような整形
- テストが通っているかどうか（CI が別に見ています）

指摘が思いつかなければ、無理に絞り出さず「指摘なし」と書いてください。
水増しされた指摘は、本物の指摘を見えなくします。

## 制約

**読むだけです。ファイルを一切変更しないでください。**
コミットもしないでください。

## 変更内容
PROMPT
    printf '%s\n\n```diff\n' "$truncated"
    cat "$diff_file"
    printf '```\n'
  } > "$prompt_file"

  harness_log "   🔍 Issue #${issue}: レビュー中 (model=$model)"
  if ! harness_run_with_timeout 900 \
      review_agent "$worktree" "$prompt_file" "$out_file"; then
    harness_log "   ⚠️  Issue #${issue}: レビューが完了しませんでした"
    return 1
  fi

  # 読むだけのはずなので、変わっていたら戻す
  if ! git -C "$worktree" diff --quiet 2>/dev/null \
    || [ -n "$(git -C "$worktree" ls-files --others --exclude-standard)" ]; then
    harness_log "   ⚠️  Issue #${issue}: レビューがファイルを変更したので元に戻します"
    git -C "$worktree" checkout -- . >/dev/null 2>&1 || true
    git -C "$worktree" clean -fd >/dev/null 2>&1 || true
  fi

  [ -s "$out_file" ] || { harness_log "   ⚠️  Issue #${issue}: レビュー結果が空です"; return 1; }

  local headline findings
  headline=$(head -1 "$out_file")
  case "$headline" in
    *指摘なし*) findings=0 ;;
    *要確認*)   findings=$(printf '%s' "$headline" | grep -oE '[0-9]+' | head -1) ;;
    *)          findings="?" ;;
  esac

  gh pr comment "$pr_num" --body "## 🔍 自動レビュー

$(cat "$out_file")

<sub>Claude Dev Harness が PR 作成時に自動で実行しました（model: \`${model}\`）。
CI とは別物で、マージはブロックしません。見当違いの指摘は無視してください。</sub>" >/dev/null 2>&1 \
    && harness_log "   ✅ Issue #${issue}: レビューを PR #${pr_num} にコメント (${findings})" \
    || harness_log "   ⚠️  Issue #${issue}: レビューのコメント投稿に失敗"

  emit reviewed "issue=$issue" "pr=$pr_num" "findings=${findings:-0}"
  return 0
}

# harness_run_with_timeout から呼べるよう関数にする
review_agent() {
  local worktree=$1 prompt_file=$2 out_file=$3
  (
    cd "$worktree" || exit 1
    claude -p --dangerously-skip-permissions --model "${REVIEW_MODEL:-$CLAUDE_MODEL}" \
      < "$prompt_file" > "$out_file" 2>/dev/null
  )
}

run_one() {
  local issue=$1 issue_json title worktree log_file prompt_file rc

  if ! $FORCE && has_open_pr "$issue"; then
    if [ "$OPEN_PR_STATE" = "stuck" ]; then
      harness_log "🛑 Issue #${issue}: PR #${OPEN_PR_NUM} が詰まっています (${OPEN_PR_DETAIL})。人手が要ります"
      [ "$OPEN_PR_FLAGGED" = "1" ] || mark_needs_attention "$OPEN_PR_NUM" "$OPEN_PR_DETAIL" "$issue"
    else
      harness_log "⏭️  Issue #${issue}: 未マージの PR #${OPEN_PR_NUM} があるためスキップ (${OPEN_PR_DETAIL})"
      [ "$OPEN_PR_FLAGGED" = "1" ] && clear_needs_attention "$OPEN_PR_NUM"
    fi
    # flagged は「この実行より前から印が付いていたか」。
    # 通知はこれが 0 のとき (=新しく見つかったとき) だけ鳴らす。
    # 毎回鳴らすと、直すまでの間ずっと同じ通知が届いて見なくなる。
    emit skipped "issue=$issue" "pr=$OPEN_PR_NUM" "reason=open_pr" \
      "pr_state=$OPEN_PR_STATE" "detail=$OPEN_PR_DETAIL" "flagged=$OPEN_PR_FLAGGED"
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
  # $@ は後段の wait ループで PID 一覧に置き換えるので、件数はここで控える
  local total=$#
  harness_log "🚀 ${total} 件の Issue を ${MAX_PARALLEL} 並行で処理"

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
  printf '  処理: %s 件 / モデル: %s\n' "$total" "${CLAUDE_MODEL}"
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

$DRY_RUN || sweep_stale_attention_labels

case "$MODE" in
  parallel)   run_parallel "$@" ;;
  sequential) MAX_PARALLEL=1; run_parallel "$@" ;;
  tmux)       run_tmux "$@" ;;
  *)          harness_die "不明なモード: $MODE" ;;
esac
