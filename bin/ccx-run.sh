#!/bin/bash
# ccx-run.sh — 同じタスクを N 回並行実行して、いちばん良い結果を選ぶ。
# 使い方: ccx-run [オプション] "タスク説明"
set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HARNESS_ROOT/lib/common.sh"

CCX_LOG_DIR="$LOG_DIR/ccx"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

usage() {
  cat << EOF
使い方: ccx-run [オプション] "タスク説明"

オプション:
  -n, --trials N     実行回数 (既定: explore=3, exact=1)
  -t, --type TYPE    exact (一意解) | explore (既定、複数解あり)
  -b, --base BRANCH  ベースブランチ (既定: 現在のブランチ)
      --test CMD     採用判定に使うテストコマンド
      --model MODEL  モデル (既定: $CLAUDE_MODEL)
      --pick N       対話せず Trial N を採用する
      --auto-pick    対話せずテストに通った最初の Trial を採用する (--test 必須)
      --keep-all     不採用の worktree を消さない
  -h, --help         このヘルプ

例:
  ccx-run -t exact --test "npm test" "Issue #42 を修正して"
  ccx-run -n 3 "UserService をリファクタして"
  ccx-run -n 5 --test "npm test" --auto-pick "フレーキーなテストを直して"
EOF
}

TRIALS=3
TRIALS_SET=false
TASK_TYPE="explore"
BASE_BRANCH=""
TEST_CMD=""
PICK=""
AUTO_PICK=false
KEEP_ALL=false
TASK=""

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--trials) TRIALS="${2:-}"; TRIALS_SET=true; shift 2 ;;
    -t|--type)   TASK_TYPE="${2:-}"; shift 2 ;;
    -b|--base)   BASE_BRANCH="${2:-}"; shift 2 ;;
    --test)      TEST_CMD="${2:-}"; shift 2 ;;
    --model)     CLAUDE_MODEL="${2:-}"; shift 2 ;;
    --pick)      PICK="${2:-}"; shift 2 ;;
    --auto-pick) AUTO_PICK=true; shift ;;
    --keep-all)  KEEP_ALL=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           TASK="$1"; shift ;;
  esac
done

[ -n "$TASK" ] || { usage >&2; harness_die "タスク説明を指定してください"; }
$AUTO_PICK && [ -z "$TEST_CMD" ] && harness_die "--auto-pick には --test が必要です"
[ "$TASK_TYPE" = "exact" ] && ! $TRIALS_SET && TRIALS=1

harness_require git claude
harness_require_git_repo

REPO_SLUG=$(harness_repo_slug)
[ -n "$BASE_BRANCH" ] || BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
mkdir -p "$CCX_LOG_DIR" "$WORKTREES_BASE"

echo "🔀 ccx-run: ${TRIALS} 回並行実行"
echo "   モデル: $CLAUDE_MODEL"
echo "   種別: $TASK_TYPE | ベース: $BASE_BRANCH"
echo "   タスク: $(printf '%.80s' "$TASK")"
echo ""

worktree_for() { printf '%s/%s-ccx-%s-%s' "$WORKTREES_BASE" "$REPO_SLUG" "$1" "$TIMESTAMP"; }

pids=""
i=1
while [ "$i" -le "$TRIALS" ]; do
  branch="ccx/trial-${i}-${TIMESTAMP}"
  wt=$(worktree_for "$i")
  log_file="${CCX_LOG_DIR}/trial-${i}-${TIMESTAMP}.log"
  prompt_file="${CCX_LOG_DIR}/prompt-${i}-${TIMESTAMP}.txt"

  if ! err=$(git worktree add "$wt" -b "$branch" "$BASE_BRANCH" 2>&1); then
    harness_log "❌ Trial $i の worktree 作成に失敗: ${err%%$'\n'*}"
    i=$((i + 1))
    continue
  fi

  {
    printf '%s\n\n' "$TASK"
    printf '## 完了条件\n'
    printf -- '- 変更を必ずコミットすること: git add -A && git commit -m "ccx trial %s"\n' "$i"
    [ -n "$TEST_CMD" ] && printf -- '- テストを通すこと: %s\n' "$TEST_CMD"
    printf -- '- 最後に "CCX_DONE:%s" と出力すること\n' "$i"
    printf -- '- 権限は承認済みです。質問せずに進めてください\n'
  } > "$prompt_file"

  (
    cd "$wt" || exit 1
    claude -p --dangerously-skip-permissions --model "$CLAUDE_MODEL" \
      < "$prompt_file" 2>&1 | tee "$log_file"
  ) &
  pids="$pids $!"
  echo "   Trial $i 起動 (PID $!, branch: $branch)"
  i=$((i + 1))
done

echo ""
echo "⏳ 並行実行の完了を待機中..."
# shellcheck disable=SC2086
set -- $pids
for pid in "$@"; do wait "$pid" 2>/dev/null || true; done

echo ""
echo "========================================="
echo "📋 実行結果"
echo "========================================="

passed_trial=""
i=1
while [ "$i" -le "$TRIALS" ]; do
  wt=$(worktree_for "$i")
  echo ""
  echo "━━━ Trial $i ━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Worktree : $wt"
  echo "  ログ     : ${CCX_LOG_DIR}/trial-${i}-${TIMESTAMP}.log"

  if [ -d "$wt" ]; then
    changed=$(git -C "$wt" diff --name-only "$BASE_BRANCH" 2>/dev/null | wc -l | tr -d ' ')
    echo "  変更ファイル数: $changed"
    git -C "$wt" diff --stat "$BASE_BRANCH" 2>/dev/null | head -5 | sed 's/^/    /'
    commits=$(git -C "$wt" rev-list --count "$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)
    [ "$commits" -gt 0 ] && echo "  コミット: ✅ ($commits 件)" || echo "  コミット: ❌"

    if [ -n "$TEST_CMD" ]; then
      if (cd "$wt" && eval "$TEST_CMD") >/dev/null 2>&1; then
        echo "  テスト: ✅ PASS"
        [ -z "$passed_trial" ] && passed_trial="$i"
      else
        echo "  テスト: ❌ FAIL"
      fi
    fi
  else
    echo "  (worktree がありません)"
  fi
  i=$((i + 1))
done

# ---- 採用 ---------------------------------------------------------------
choice=""
if [ -n "$PICK" ]; then
  choice="$PICK"
elif $AUTO_PICK; then
  choice="$passed_trial"
  echo ""
  if [ -n "$choice" ]; then
    echo "🤖 --auto-pick: テストに通った Trial $choice を採用します"
  else
    echo "🤖 --auto-pick: テストに通った Trial がありません"
  fi
else
  echo ""
  echo "========================================="
  printf '採用する Trial を選んでください (1-%s, s=スキップ): ' "$TRIALS"
  read -r choice
fi

if printf '%s' "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "$TRIALS" ]; then
  selected_wt=$(worktree_for "$choice")
  selected_commit=$(git -C "$selected_wt" rev-parse HEAD 2>/dev/null || true)
  echo ""
  echo "✅ Trial $choice を採用 (commit: $(printf '%.8s' "${selected_commit:-?}"))"

  if [ -n "$selected_commit" ]; then
    do_pick=false
    if [ -n "$PICK" ] || $AUTO_PICK; then
      do_pick=true
    else
      printf '現在のブランチ (%s) に cherry-pick しますか? (y/N): ' "$BASE_BRANCH"
      read -r ans
      printf '%s' "$ans" | grep -qE '^[Yy]$' && do_pick=true
    fi
    if $do_pick; then
      if git cherry-pick "$selected_commit"; then
        echo "✅ cherry-pick 完了"
      else
        echo "⚠️  cherry-pick 失敗 — 手動で: git cherry-pick $selected_commit"
      fi
    fi
  fi
else
  choice=""
fi

# ---- 後片付け -----------------------------------------------------------
if ! $KEEP_ALL; then
  cleanup=true
  if [ -z "$PICK" ] && ! $AUTO_PICK; then
    printf '\n不採用の worktree を削除しますか? (Y/n): '
    read -r ans
    printf '%s' "$ans" | grep -qE '^[Nn]$' && cleanup=false
  fi
  if $cleanup; then
    i=1
    while [ "$i" -le "$TRIALS" ]; do
      if [ "$i" != "${choice:-}" ]; then
        wt=$(worktree_for "$i")
        br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        git worktree remove --force "$wt" >/dev/null 2>&1 || true
        [ -n "$br" ] && git branch -D "$br" >/dev/null 2>&1 || true
      fi
      i=$((i + 1))
    done
    echo "✅ クリーンアップ完了"
  fi
fi

echo ""
echo "🎉 ccx-run 完了"
