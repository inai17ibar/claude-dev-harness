#!/bin/bash
# discover-run.sh — リポジトリから課題・新しい要件を自律的に見つけ、
# 種別・優先度ラベル付きの idea Issue として起票する。実装はしない。
#
#   収集 (シェル, 無料) → 判定 (LLM を呼ぶか) → 分析 (LLM, 読み取り専用) → 起票 (シェル)
#
# LLM には gh を触らせない。LLM は JSON で「提案」を返すだけで、ラベルの付与・
# 重複判定・件数の上限はこのスクリプトが決める。旧 weekly-audit は LLM に
# gh issue create を直接打たせていたため、ラベルも件数も LLM 任せだった。
#
# 設計の背景は docs/discover.md。
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
# shellcheck source=../lib/common.sh
. "$HARNESS_ROOT/lib/common.sh"
# shellcheck source=../lib/discover.sh
. "$HARNESS_ROOT/lib/discover.sh"

usage() {
  cat << EOF
使い方: discover-run.sh [オプション]

  リポジトリを調べて課題・新しい要件を見つけ、idea Issue として起票する。
  種別 (type:*) と優先度 (priority:*) のラベルを付ける。実装はしない。

  -r, --repo OWNER/REPO  対象を指定する (複数可)。省略時は config.sh の
                         DISCOVER_REPOS → REPOS
      --full             前回からの差分ではなく全体を監査する
  -n, --dry-run          LLM は呼ぶが、起票・ラベル作成・状態更新はしない
  -h, --help             このヘルプ

設定: \$CLAUDE_HARNESS_DIR/nightly/config.sh の DISCOVER_* (nightly/config.example.sh)
EOF
}

FORCE_FULL=false
DRY_RUN=false
CLI_REPOS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--repo) [ $# -ge 2 ] || harness_die "$1 にはリポジトリが要ります"; CLI_REPOS="$CLI_REPOS $2"; shift 2 ;;
    --full) FORCE_FULL=true; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) harness_die "不明なオプション: $1" ;;
  esac
done

DISCOVER_DIR="$HARNESS_DIR/discover"
STATE_DIR="$DISCOVER_DIR/state"
DISCOVER_LOG_DIR="$DISCOVER_DIR/logs"
mkdir -p "$STATE_DIR" "$DISCOVER_LOG_DIR"
NOTIFY="$HARNESS_ROOT/lib/notify.sh"
SCHEMA_FILE="$HARNESS_ROOT/nightly/discover-schema.json"

if [ -f "$HARNESS_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/env.sh"
fi

# ---- 既定値 (config.sh で上書きされる) ----
REPOS=""
DISCOVER_REPOS=""
# 発見は「読んで判断する」仕事で、実装ほどの力は要らない。毎日回すので軽いモデルを既定にする。
# エイリアスにしておくと、モデル ID の世代交代で 404 になる事故を避けられる。
DISCOVER_MODEL="sonnet"
DISCOVER_MAX_ISSUES=3            # 1リポジトリ1回あたりの起票上限
DISCOVER_MIN_CONFIDENCE="medium" # これより確度の低い提案は捨てる
DISCOVER_FULL_INTERVAL_DAYS=7    # 全体監査の間隔。間は差分だけ見る
DISCOVER_BACKLOG_LIMIT=15        # 未選別の idea がこれ以上あれば LLM を呼ばない
DISCOVER_TIMEOUT=1200            # 1リポジトリの上限秒数
DISCOVER_MAX_BUDGET_USD=""       # API 課金のときの1回あたり上限。空なら付けない
DISCOVER_AUTO_PROMOTE=false      # true: 確度高・規模 s の p0/p1 bug に automation も付ける
REPOS_DIR="${REPOS_DIR:-$HOME/repos}"

CONFIG_FILE="$HARNESS_DIR/nightly/config.sh"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi
# 旧 weekly-audit の設定 (AUDIT_REPOS) も読む
AUDIT_REPOS=""
if [ -f "$HARNESS_DIR/audit/config.sh" ]; then
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/audit/config.sh"
fi

# 配列でも文字列でも書けるよう正規化する (nightly-run.sh と同じ理由)
# shellcheck disable=SC2128
REPO_LIST=$(printf '%s ' ${DISCOVER_REPOS[@]+"${DISCOVER_REPOS[@]}"})
# shellcheck disable=SC2128
[ -n "${REPO_LIST// /}" ] || REPO_LIST=$(printf '%s ' ${REPOS[@]+"${REPOS[@]}"})
# shellcheck disable=SC2128
[ -n "${REPO_LIST// /}" ] || REPO_LIST=$(printf '%s ' ${AUDIT_REPOS[@]+"${AUDIT_REPOS[@]}"})
[ -n "${CLI_REPOS// /}" ] && REPO_LIST="$CLI_REPOS"

TS=$(date '+%Y%m%d_%H%M%S')
RUN_LOG="$DISCOVER_LOG_DIR/run-${TS}.log"
exec > >(tee -a "$RUN_LOG") 2>&1
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
# nightly と同じ HARNESS_EVENT 形式。集計は文言ではなくこのマーカーで行う
emit() { local kind=$1; shift; echo "HARNESS_EVENT:$kind $*"; }
notify() {
  [ -x "$NOTIFY" ] || return 0
  "$NOTIFY" -t "Discover" -p "${2:-default}" "$1" 2>/dev/null || true
}

log "🔍 Discover 開始 (model=${DISCOVER_MODEL}, max=${DISCOVER_MAX_ISSUES}件/repo, dry_run=${DRY_RUN})"

for cmd in gh claude git jq; do
  command -v "$cmd" >/dev/null 2>&1 || { log "❌ 必須コマンドなし: $cmd"; exit 4; }
done
gh auth status >/dev/null 2>&1 || { log "❌ gh 認証切れ"; notify "🔐 Discover中止: gh認証切れ"; exit 5; }
[ -n "${REPO_LIST// /}" ] || { log "❌ 対象リポジトリがありません ($CONFIG_FILE の REPOS か --repo)"; exit 6; }

NOW=$(date +%s)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ensure_labels() {
  local repo=$1 name color desc
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    gh label create "$name" -R "$repo" --color "$color" --description "$desc" >/dev/null 2>&1 || true
  done << EOF
$(discover_label_specs)
EOF
}

sync_repo() {
  local repo=$1 path=$2 db
  if [ ! -d "$path/.git" ]; then
    log "  📥 clone: $repo → $path" >&2
    mkdir -p "$(dirname "$path")"
    git clone -q "https://github.com/$repo.git" "$path" || return 1
  else
    git -C "$path" fetch -q --all --prune || return 1
  fi
  db=$(git -C "$path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  db=${db:-main}
  git -C "$path" checkout -q "$db" 2>/dev/null || return 1
  git -C "$path" merge -q --ff-only "origin/$db" 2>/dev/null || return 1
  printf '%s' "$db"
}

# プロダクトの文脈。「新しい要件」は README だけからは出しにくいので、
# リポジトリ側に目標・やらないことを書いたファイルがあれば最優先で渡す。
product_context() {
  local path=$1 f
  for f in .github/discover.md DISCOVER.md docs/discover.md; do
    if [ -f "$path/$f" ]; then
      printf '### %s\n' "$f"
      head -c 6000 "$path/$f"
      return 0
    fi
  done
  if [ -f "$path/README.md" ]; then
    printf '### README.md (discover.md が無いので代わりに)\n'
    head -c 4000 "$path/README.md"
  fi
}

run_claude() {
  # バックグラウンド実行 (harness_run_with_timeout) では stdin が /dev/null になるので、
  # 関数の中でリダイレクトする
  local budget_args=""
  [ -n "$DISCOVER_MAX_BUDGET_USD" ] && budget_args="--max-budget-usd $DISCOVER_MAX_BUDGET_USD"
  # 読むためのツールだけを許す。-p では許可されていないツールは自動で拒否される
  # shellcheck disable=SC2086
  claude -p --model "$DISCOVER_MODEL" --output-format json \
    --json-schema "$(cat "$SCHEMA_FILE")" \
    --allowedTools "Read,Grep,Glob,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(ls:*)" \
    --disallowedTools "Write,Edit,NotebookEdit,WebFetch,WebSearch" \
    $budget_args < "$1" > "$2"
}

filed_total=0
p0_lines=""
error_repos=""

for repo in $REPO_LIST; do
  log ""
  log "── $repo ──"
  safe=$(printf '%s' "$repo" | tr '/' '_')
  state="$STATE_DIR/$safe"
  rdir="$WORK/$safe"
  mkdir -p "$rdir"
  local_path="$REPOS_DIR/$(basename "$repo")"

  if ! db=$(sync_repo "$repo" "$local_path"); then
    log "  ❌ リポジトリを最新化できませんでした"
    emit discover_error "repo=$repo" "reason=sync"
    error_repos="$error_repos $repo"
    continue
  fi
  head_sha=$(git -C "$local_path" rev-parse HEAD)
  last_sha=$(discover_state_get "$state" last_sha)
  last_full=$(discover_state_get "$state" last_full)
  last_run=$(discover_state_get "$state" last_run)
  # 前回の SHA が履歴から消えていれば (force push など) 全体監査に倒す
  if [ -n "$last_sha" ] && ! git -C "$local_path" cat-file -e "${last_sha}^{commit}" 2>/dev/null; then
    last_sha=""
  fi

  # ---- 収集: 前回以降に既定ブランチで落ちた CI ----
  gh run list -R "$repo" --branch "$db" --status failure --limit 10 \
    --json databaseId,workflowName,displayTitle,createdAt,url,headSha > "$rdir/runs.json" 2>/dev/null \
    || echo '[]' > "$rdir/runs.json"
  jq -c --argjson since "${last_run:-0}" \
    '[.[] | select((.createdAt | fromdateiso8601) > $since)] | .[0:3]' \
    "$rdir/runs.json" > "$rdir/new_runs.json" 2>/dev/null || echo '[]' > "$rdir/new_runs.json"
  signals=$(jq 'length' "$rdir/new_runs.json")

  mode=$(discover_decide_mode "$NOW" "$last_full" "$last_sha" "$head_sha" \
    "$DISCOVER_FULL_INTERVAL_DAYS" "$FORCE_FULL" "$signals")
  log "  mode=$mode (HEAD=${head_sha:0:7} 前回=${last_sha:0:7} 新しいCI失敗=${signals})"

  if [ "$mode" = "skip" ]; then
    log "  💤 前回から変化なし。LLM は呼びません"
    emit discover_skipped "repo=$repo" "reason=no_change"
    $DRY_RUN || discover_state_put "$state" last_run "$NOW"
    continue
  fi

  # ---- 収集: 既存 Issue (重複と、却下済みの再提案を防ぐ) ----
  gh issue list -R "$repo" --state open --limit 200 \
    --json number,title,labels,body > "$rdir/open.json" 2>/dev/null || echo '[]' > "$rdir/open.json"
  gh issue list -R "$repo" --state closed --limit 100 \
    --json number,title,stateReason,closedAt,body > "$rdir/closed.json" 2>/dev/null || echo '[]' > "$rdir/closed.json"

  # 選別が追いついていないのに足しても読まれない。LLM 代を払う前に止める。
  # 状態は進めないので、変化は次回に持ち越される
  backlog=$(jq '[.[] | [.labels[].name] | select(index("idea") != null and index("automation") == null)] | length' "$rdir/open.json")
  if [ "$backlog" -ge "$DISCOVER_BACKLOG_LIMIT" ]; then
    log "  📥 未選別の idea が ${backlog} 件 (上限 ${DISCOVER_BACKLOG_LIMIT})。先に選別してください。LLM は呼びません"
    emit discover_skipped "repo=$repo" "reason=backlog_full" "backlog=$backlog"
    continue
  fi

  # ---- プロンプト ----
  # ヒアドキュメントの中に括弧入りの $(...) を書くと bash 3.2 が誤パースすることがあるので、
  # 埋め込む値は先に変数へ出しておく
  ctx=$(product_context "$local_path")
  open_list=$(jq -r '.[] | "- #\(.number) \(.title)"' "$rdir/open.json" | head -150)
  rejected_list=$(jq -r '.[] | select(.stateReason == "NOT_PLANNED") | "- #\(.number) \(.title)"' "$rdir/closed.json" | head -50)
  commits="" diffstat="" todos=""
  if [ "$mode" = "incremental" ]; then
    commits=$(git -C "$local_path" log --oneline --no-merges "${last_sha}..HEAD" 2>/dev/null | head -30)
    diffstat=$(git -C "$local_path" diff --stat "${last_sha}..HEAD" 2>/dev/null | tail -40)
    todos=$(git -C "$local_path" diff -U0 "${last_sha}..HEAD" 2>/dev/null | grep -E '^\+.*(TODO|FIXME|HACK)' | head -20)
  fi
  {
    cat << EOF
あなたはこのリポジトリ (${repo}) の品質と成長に責任を持つ監査係です。
カレントディレクトリのコードを調べ、開発者がまだ Issue にしていない「課題」と「新しい要件」を見つけてください。
コードの変更・コミット・Issue 作成はしません。見つけたものを JSON で返すだけです。

## プロダクトの文脈
${ctx}

EOF
    if [ "$mode" = "full" ]; then
      cat << 'EOF'
## 今回の範囲: 全体監査
コードベース全体を見てください。ただし広く浅くではなく、利用者への影響が大きいところから見ること。
EOF
    else
      cat << EOF
## 今回の範囲: 前回 (${last_sha:0:7}) からの差分
まず次の変更を見て、それが新たに生んだ問題・やり残し・波及先を探してください。
変更ファイルの周辺コードは自由に読んでかまいません。差分と無関係な古い問題は今回は探さなくてよい。

### コミット
${commits}

### 変更ファイル
${diffstat}

### 差分で増えた TODO / FIXME / HACK
${todos:-(なし)}
EOF
    fi

    if [ "$signals" -gt 0 ]; then
      echo ""
      echo "## 既定ブランチ (${db}) で新しく落ちた CI"
      echo "ここは推測ではなく事実です。原因をコードから特定できたら bug として返してください。"
      jq -r '.[] | "\(.databaseId)\t\(.workflowName) — \(.displayTitle) (\(.headSha[0:7]))"' "$rdir/new_runs.json" \
        | head -2 | while IFS=$'\t' read -r id title; do
            echo ""
            echo "### $title"
            echo '```'
            gh run view "$id" -R "$repo" --log-failed 2>/dev/null | tail -60 | cut -c1-300
            echo '```'
          done
    fi

    cat << EOF

## 既に Issue になっているもの (重複して返さない)
${open_list:-(なし)}

## 却下されたもの (同じ趣旨を二度と返さない)
${rejected_list:-(なし)}

## 種別 (type)
- bug: いまの挙動が仕様・テスト・README・常識に反する。根拠の path:line が必須。再現条件が言えないものは返さない
- feature: 新しい要件。プロダクトの文脈が裏付けるものだけ。「あったら便利」の思いつきは返さない
- improvement: 既存機能の改善 (エラー処理の漏れ、性能、UX、保守性)
- test: 重要なのにテストが無い・境界条件が抜けている
- docs: README 等の誤り・欠落 (書いてある使い方が実際と違う、など)

## 優先度 (priority)
- p0: データ消失・セキュリティ・主要機能が使えない。確度 high のときだけ
- p1: 主要機能の誤動作。回避策はあるが利用者が困る
- p2: 小さな不具合や改善
- p3: あると良い

## ルール
- 返すのは最大 ${DISCOVER_MAX_ISSUES} 件。数を埋めるための水増しはしない。価値が薄ければ 0 件でよい
- 1件は、別のエージェントが本文だけを読んで実装できる粒度・具体性にする (problem / why / done_when を埋める)
- done_when は検証できる形で書く。テストで判定できるならテスト名や入力と期待値を書く
- key は同じ指摘なら毎回同じになる英小文字の識別子 (例: divide-by-zero)
- 確信が持てないものは confidence を下げる。確度の低い提案は捨てられる
- 起票しなかったが人に伝えたいことは notes に1〜2行で
EOF
  } > "$rdir/prompt.txt"

  # ---- 分析 ----
  before_status=$(git -C "$local_path" status --porcelain)
  log "  🤖 claude 実行中 (timeout=${DISCOVER_TIMEOUT}s)"
  (cd "$local_path" && harness_run_with_timeout "$DISCOVER_TIMEOUT" run_claude "$rdir/prompt.txt" "$rdir/out.json")
  rc=$?

  # 読むだけのはずだが、変わっていたら消さずに退避する (レビュアーと同じ扱い)
  if [ "$(git -C "$local_path" status --porcelain)" != "$before_status" ]; then
    log "  ⚠️ 監査中に作業ツリーが変わりました。git stash に退避します"
    git -C "$local_path" stash push -q -u -m "discover: unexpected changes $TS" || true
  fi

  if [ "$rc" -ne 0 ] || ! jq -e . "$rdir/out.json" >/dev/null 2>&1; then
    log "  ❌ claude が失敗しました (rc=$rc)"
    head -c 500 "$rdir/out.json" 2>/dev/null
    emit discover_error "repo=$repo" "reason=claude" "rc=$rc"
    error_repos="$error_repos $repo"
    continue
  fi
  if [ "$(jq -r '.is_error // false' "$rdir/out.json")" = "true" ]; then
    log "  ❌ claude がエラーを返しました: $(jq -r '.result // .subtype // ""' "$rdir/out.json" | head -c 300)"
    emit discover_error "repo=$repo" "reason=claude_error"
    error_repos="$error_repos $repo"
    continue
  fi
  cost=$(jq -r '.total_cost_usd // empty' "$rdir/out.json")
  [ -n "$cost" ] && emit discover_cost "repo=$repo" "usd=$cost" "mode=$mode"

  discover_extract_output < "$rdir/out.json" > "$rdir/raw.json"
  notes=$(jq -r '.notes // empty' "$rdir/raw.json")
  [ -n "$notes" ] && log "  📝 notes: $notes"
  # 上限は「起票した件数」に掛ける。ここで絞ると、重複で見送るものが枠を食い、
  # 新しい指摘が押し出される
  discover_normalize 50 "$DISCOVER_MIN_CONFIDENCE" < "$rdir/raw.json" > "$rdir/findings.json"
  raw_n=$(jq '(.findings // []) | length' "$rdir/raw.json")
  kept_n=$(jq 'length' "$rdir/findings.json")
  log "  提案 ${raw_n} 件 → 検証を通過 ${kept_n} 件"

  # ---- 起票 ----
  # open も closed も含めて、既に起票した指紋は再起票しない
  jq -s 'add' "$rdir/open.json" "$rdir/closed.json" | discover_existing_fps > "$rdir/fps.txt"
  $DRY_RUN || [ "$kept_n" -eq 0 ] || ensure_labels "$repo"

  i=0
  filed_repo=0
  while [ "$i" -lt "$kept_n" ] && [ "$filed_repo" -lt "$DISCOVER_MAX_ISSUES" ]; do
    jq -c ".[$i]" "$rdir/findings.json" > "$rdir/f.json"
    i=$((i + 1))
    title=$(jq -r .title "$rdir/f.json")
    type=$(jq -r .type "$rdir/f.json")
    prio=$(jq -r .priority "$rdir/f.json")
    key=$(jq -r 'if .key == "" then .title else .key end' "$rdir/f.json")
    ev=$(jq -r '.evidence[0] // ""' "$rdir/f.json")
    fp=$(discover_fingerprint "$type" "$key" "$ev")

    if grep -qx "$fp" "$rdir/fps.txt" \
      || jq -e --arg t "$title" 'any(.[]; .title == $t)' "$rdir/open.json" >/dev/null; then
      log "  ↩︎  重複のため見送り: [$type/$prio] $title"
      emit discover_dup "repo=$repo" "fp=$fp"
      continue
    fi
    echo "$fp" >> "$rdir/fps.txt"
    filed_repo=$((filed_repo + 1))

    labels=$(discover_labels_for "$type" "$prio")
    if [ "$DISCOVER_AUTO_PROMOTE" = "true" ] \
      && jq -e '.type == "bug" and .confidence == "high" and .size == "s" and (.priority == "p0" or .priority == "p1")' \
        "$rdir/f.json" >/dev/null; then
      labels="$labels,automation"
    fi
    discover_render_body "$fp" "$mode" < "$rdir/f.json" > "$rdir/body.md"

    if $DRY_RUN; then
      log "  [DRY_RUN] 起票予定: [$labels] $title"
      sed 's/^/      /' "$rdir/body.md"
      continue
    fi
    if url=$(harness_retry 3 5 gh issue create -R "$repo" --title "$title" \
        --body-file "$rdir/body.md" --label "$labels"); then
      log "  ✅ 起票: [$type/$prio] $title → $url"
      emit discover_filed "repo=$repo" "type=$type" "priority=$prio" "url=$url"
      filed_total=$((filed_total + 1))
      [ "$prio" = "p0" ] && p0_lines="${p0_lines}  ${title}
  ${url}
"
    else
      log "  ❌ 起票に失敗: $title ($url)"
      emit discover_error "repo=$repo" "reason=issue_create"
    fi
  done

  if ! $DRY_RUN; then
    discover_state_put "$state" last_sha "$head_sha"
    discover_state_put "$state" last_run "$NOW"
    [ "$mode" = "full" ] && discover_state_put "$state" last_full "$NOW"
  fi
done

log ""
log "✅ Discover 完了: 起票 ${filed_total} 件${error_repos:+ / 失敗:${error_repos}}"

# 通知は人が動く必要があるときだけ。p0 の発見と、ジョブ自体の失敗。
if [ -n "$p0_lines" ]; then
  notify "🚨 p0 を発見しました
${p0_lines}" high
fi
if [ -n "$error_repos" ]; then
  notify "⚠️ Discover が失敗したリポジトリ:${error_repos}
ログ: $RUN_LOG"
  exit 1
fi
exit 0
