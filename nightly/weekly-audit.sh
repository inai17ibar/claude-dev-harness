#!/bin/bash
# weekly-audit.sh — リポジトリを監査して「改善の種」を idea Issue として自動起票する。
# 起票された idea Issue は人間が選別して automation ラベルを付けると、その晩の
# nightly-run.sh (spawn-agents) が実装する。このスクリプトは起票のみ行い、実装はしない。
#
# 週ごとに観点を1つに絞って深く見る (lib/audit.sh の AUDIT_DEFAULT_LENSES を順番に回す)。
# 監査は使い捨ての worktree で走らせ、起票前に失敗するテストで再現を確かめる。
# 再現できたものには repro ラベルを付け、そのテストを本文に載せる。
#
# 手動で観点を指定して走らせる:
#   AUDIT_LENS=security nightly/weekly-audit.sh
set -uo pipefail

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
# shellcheck source=../lib/audit.sh
. "$HARNESS_ROOT/lib/audit.sh"

HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"
AUDIT_DIR="$HARNESS_DIR/audit"
LOG_DIR="$AUDIT_DIR/logs"
WT_BASE="$AUDIT_DIR/worktrees"
mkdir -p "$LOG_DIR" "$WT_BASE"

# launchd 経由でも通知できるよう、環境ファイルがあれば読む
if [ -f "$HARNESS_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/env.sh"
fi

# ---- 設定 (すべて $HARNESS_DIR/audit/config.sh で上書きできる) ------------
AUDIT_REPOS=("inai17ibar/vlog-cockpit" "inai17ibar/stune")
MAX_NEW_ISSUES=5
# 回す観点 (空白区切り)。順番と中身は lib/audit.sh の audit_lens_brief を参照
AUDIT_LENSES="$AUDIT_DEFAULT_LENSES"
# true なら使い捨て worktree で失敗テストを書いて再現を確かめてから起票する
AUDIT_REPRO=true
# 重複チェックで見る「直近に閉じた Issue」の日数
AUDIT_DEDUP_DAYS=90
# 0 より大きいと、今回起票したもののうち repro かつ sev:high のものを
# この件数まで自動で automation に昇格させる。PR は review-gate を通るまで
# 自動マージされないので、最後の判断は人に残る。既定は人が選ぶ (0)。
AUDIT_AUTO_PROMOTE=0
if [ -f "$AUDIT_DIR/config.sh" ]; then
  # shellcheck disable=SC1091
  . "$AUDIT_DIR/config.sh"
fi
MODEL="${CLAUDE_MODEL:-claude-opus-5}"  # lib/common.sh と揃える

TS=$(date '+%Y%m%d_%H%M%S')
RUN_STARTED=$(audit_now_iso)
RUN_LOG="$LOG_DIR/audit-${TS}.log"
exec > >(tee -a "$RUN_LOG") 2>&1
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---- 観点を決める ------------------------------------------------------------
# shellcheck disable=SC2086  # 空白区切りの一覧を引数に展開する
LENS="${AUDIT_LENS:-$(audit_pick_lens "$(date '+%V')" $AUDIT_LENSES)}"
if ! LENS_BRIEF=$(audit_lens_brief "$LENS"); then
  log "❌ 未知の観点: '$LENS' (使えるもの: $AUDIT_DEFAULT_LENSES)"
  exit 1
fi

log "🔍 Weekly Audit 開始 (model=$MODEL, 観点=$LENS, max=${MAX_NEW_ISSUES}件/repo, repro=$AUDIT_REPRO, auto-promote=$AUDIT_AUTO_PROMOTE)"

for cmd in gh claude git; do
  command -v "$cmd" >/dev/null || { log "❌ 必須コマンドなし: $cmd"; exit 1; }
done
gh auth status >/dev/null 2>&1 || { log "❌ gh 認証切れ"; exit 1; }

# 途中で落ちても worktree を残さない
CURRENT_WT=""
CURRENT_SRC=""
cleanup_wt() {
  if [ -n "$CURRENT_WT" ] && [ -n "$CURRENT_SRC" ]; then
    git -C "$CURRENT_SRC" worktree remove --force "$CURRENT_WT" >/dev/null 2>&1 \
      || rm -rf "$CURRENT_WT"
    git -C "$CURRENT_SRC" worktree prune >/dev/null 2>&1
  fi
  CURRENT_WT=""
  CURRENT_SRC=""
}
trap cleanup_wt EXIT

ensure_labels() {
  local repo="$1"
  gh label create idea --repo "$repo" --color FBCA04 \
    --description "思いつき置き場。選別して automation を付けると夜間ジョブが実装する" >/dev/null 2>&1 || true
  gh label create repro --repo "$repo" --color 0E8A16 \
    --description "監査が失敗テストで再現を確認済み" >/dev/null 2>&1 || true
  gh label create "sev:high" --repo "$repo" --color B60205 \
    --description "データ消失・セキュリティ・主要機能が使えない" >/dev/null 2>&1 || true
  gh label create "sev:mid" --repo "$repo" --color E99695 \
    --description "誤った表示や動作。回避策あり" >/dev/null 2>&1 || true
  gh label create "sev:low" --repo "$repo" --color C2E0C6 \
    --description "体験の粗さ・保守性" >/dev/null 2>&1 || true
  gh label create "audit:$LENS" --repo "$repo" --color 5319E7 \
    --description "weekly-audit の観点: $LENS" >/dev/null 2>&1 || true
}

build_prompt() {
  local repo="$1" known="$2" repro_rules
  if [ "$AUDIT_REPRO" = "true" ]; then
    repro_rules=$(cat <<'EOF'
- カレントディレクトリは使い捨ての作業コピーで、終了後に破棄される。起票する前に、
  可能なら既存のテスト基盤で「問題があれば失敗するテスト」を書いて実行し、問題が
  実在することを確かめる。テストのための依存インストールはしてよい。
  - テストが失敗し、問題を再現できた → 本文の「再現テスト」にテストのファイルパス・
    コード全文・実行コマンド・失敗出力の要点を書き、ラベル repro を付ける
  - テストを書けない（テスト基盤の制約、実機が必要など）→ その理由を書き、repro は付けない
  - 書いたテストが通ってしまった（問題が実在しなかった）→ 起票しない
- コミット・push・PR作成は一切しない。作業コピーの変更は捨てられる前提で使う
EOF
)
  else
    repro_rules="- 実装・コード変更・コミットは一切しない。再現テストは書かず、本文に再現手順を書く"
  fi

  cat <<PROMPT
あなたは個人開発リポジトリの監査係です。カレントディレクトリのコードベースを調査し、
開発者とエージェントが後で拾える「改善の種」を GitHub Issue として起票してください。
今週は観点を1つに絞って深く調べます。広く浅く拾うより、この観点で見落とされてきたものを掘ってください。

${LENS_BRIEF}

ルール:
- 起票は最大 ${MAX_NEW_ISSUES} 件まで。数を埋めるための水増しはしない。価値が薄ければ0件でもよい
- 今週の観点に合うものを起票する。観点外でも、データ消失やセキュリティに関わる重大なもの
  (sev:high) を見つけた場合に限り、1件まで起票してよい
- コードを読んで、どの入力・操作で、どこを通って、何が起きるかを具体的に示せるものだけを起票する。
  推測や一般論は起票しない
- 次の既知の一覧（Open Issue、直近${AUDIT_DEDUP_DAYS}日に閉じた Issue、Open PR）と同じ原因・
  同じ箇所のものは起票しない。タイトルの表現が違っても原因が同じなら重複とみなす:
${known:-（既知のものなし）}
${repro_rules}
- 深刻度ラベルを1つだけ付ける:
  sev:high（データ消失・セキュリティ・主要機能が使えない）/
  sev:mid（誤った表示や動作。回避策あり）/ sev:low（体験の粗さ・保守性）
- 本文は、選別する人と、本文だけを仕様として読んで実装するエージェントの両方が読む。
  次の4つの見出しで書く:
  ## 現象        （どこで何が起きるか。ファイルパスと行番号を添える）
  ## なぜ問題か  （ユーザーから見て何が困るか。再現条件）
  ## 再現テスト  （上のルールに従う）
  ## 完了の判定  （何が満たされれば直ったと言えるか。再現テストが通ること、など）
- 起票コマンド（本文は mktemp で作った作業コピー外の一時ファイルに書いて渡す）:
  gh issue create --repo ${repo} --label idea --label "audit:${LENS}" --label <sev:high|sev:mid|sev:low> [--label repro] --title "<日本語1行>" --body-file <一時ファイル>
- 最後に起票した Issue の URL 一覧（0件なら「起票なし」）を出力して終了
PROMPT
}

SUMMARY=""

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

  ensure_labels "$repo"
  known=$(audit_known_titles "$repo" "$AUDIT_DEDUP_DAYS")
  log "  📋 重複チェック対象: $(printf '%s\n' "$known" | grep -c . || true) 件"

  # 監査する場所。再現テストを書くので、clone 本体ではなく使い捨ての worktree で走らせる
  # (clone 本体は nightly も使う。書きかけのテストを残すと翌晩の作業に混ざる)
  work_dir="$local_path"
  if [ "$AUDIT_REPRO" = "true" ]; then
    wt="$WT_BASE/$(basename "$repo")-$TS"
    if git -C "$local_path" worktree add --detach "$wt" HEAD >/dev/null 2>&1; then
      CURRENT_WT="$wt"
      CURRENT_SRC="$local_path"
      work_dir="$wt"
      # 依存のインストールを毎回やり直さないよう、clone 本体にあれば借りる
      if [ -d "$local_path/node_modules" ] && [ ! -e "$wt/node_modules" ]; then
        ln -s "$local_path/node_modules" "$wt/node_modules"
      fi
      log "  🧪 使い捨て worktree: $wt"
    else
      log "  ⚠️ worktree を作れないため、再現テストなしで監査する"
    fi
  fi

  repro_mode="$AUDIT_REPRO"
  [ "$work_dir" = "$local_path" ] && repro_mode=false
  prompt=$(AUDIT_REPRO="$repro_mode" build_prompt "$repo" "$known")

  (cd "$work_dir" && printf '%s\n' "$prompt" | claude -p --dangerously-skip-permissions --model "$MODEL") \
    || log "  ⚠️ claude 終了コード非ゼロ"

  cleanup_wt

  # 今回の起票を集計する
  created=$(gh issue list --repo "$repo" --state open --label idea --limit 100 \
    --search "created:>=$RUN_STARTED" --json number,labels \
    -q '.[] | "\(.number) \([.labels[].name] | join(","))"' 2>/dev/null || true)
  n_all=$(printf '%s\n' "$created" | grep -c . || true)
  n_repro=$(printf '%s\n' "$created" | grep -cE '(^| |,)repro(,|$)' || true)
  n_high=$(printf '%s\n' "$created" | grep -c 'sev:high' || true)

  promoted=""
  if [ "$AUDIT_AUTO_PROMOTE" -gt 0 ] 2>/dev/null; then
    for num in $(printf '%s\n' "$created" \
        | grep 'sev:high' | grep -E '(^| |,)repro(,|$)' | grep -v 'automation' \
        | head -n "$AUDIT_AUTO_PROMOTE" | cut -d' ' -f1); do
      if gh issue edit "$num" --repo "$repo" --add-label automation >/dev/null 2>&1; then
        promoted="$promoted #$num"
        log "  🚀 自動昇格: #$num → automation"
      fi
    done
  fi

  line="$(basename "$repo"): ${n_all}件 (再現済み ${n_repro} / sev:high ${n_high})"
  [ -n "$promoted" ] && line="$line 自動昇格:${promoted}"
  log "  📊 $line"
  SUMMARY="${SUMMARY}${line}
"
done

log "✅ Weekly Audit 完了 (観点=$LENS)"
NOTIFY="$HARNESS_ROOT/lib/notify.sh"
if [ -x "$NOTIFY" ]; then
  "$NOTIFY" -t "Weekly Audit ($LENS)" -p low "${SUMMARY}ログ: $RUN_LOG" || true
fi
