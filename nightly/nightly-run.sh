#!/bin/bash
# nightly-run.sh — 夜間自律実行のオーケストレーター。
# launchd から呼ばれる。安全チェック → Issue収集 → spawn-agents → サマリー通知。
#
# 集計は spawn-agents が出す HARNESS_EVENT: マーカーを数える。
# 以前は "✅ PR作成" のような日本語のログ文言を grep していたため、
# 文言を1文字直すと黙って 0 件と報告される作りだった。
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

NIGHTLY_DIR="$HARNESS_DIR/nightly"
NIGHTLY_LOG_DIR="$NIGHTLY_DIR/logs"
CONFIG_FILE="$NIGHTLY_DIR/config.sh"
NOTIFY="$HARNESS_ROOT/lib/notify.sh"
mkdir -p "$NIGHTLY_LOG_DIR"

# launchd はログインシェルの環境を継承しない。SLACK_WEBHOOK_URL のような
# 秘密は plist に焼かず、このファイルに置く。
if [ -f "$HARNESS_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/env.sh"
fi

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RUN_LOG="$NIGHTLY_LOG_DIR/run-${TIMESTAMP}.log"
SUMMARY_FILE="$NIGHTLY_LOG_DIR/summary-${TIMESTAMP}.txt"

exec > >(tee -a "$RUN_LOG") 2>&1
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
# notify <本文> [priority] [URL]
notify() {
  [ -x "$NOTIFY" ] || return 0
  "$NOTIFY" -t "Nightly Harness" -p "${2:-default}" ${3:+-u "$3"} "$1" 2>/dev/null || true
}

log "================================="
log "🌙 Nightly Harness 実行開始"
log "================================="

# ---- 既定値 (config.sh で上書きされる) ----
REPOS=""                      # 空白区切りの owner/repo。配列でも書ける
LABEL_FILTER="automation"
MAX_ISSUES_PER_REPO=5
MAX_PARALLEL=2
MODEL="$CLAUDE_MODEL"
MIN_BATTERY=30
DRY_RUN=false
REPOS_DIR="${REPOS_DIR:-$HOME/repos}"

if [ -f "$CONFIG_FILE" ]; then
  log "📝 設定読み込み: $CONFIG_FILE"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
else
  log "⚠️  設定ファイルがありません: $CONFIG_FILE"
  log "    $HARNESS_ROOT/nightly/config.example.sh をコピーして編集してください"
  exit 2
fi

# config.sh は REPOS=( ... ) の配列でも REPOS="a b" の文字列でも書ける。
# bash 3.2 では空配列を "${REPOS[@]}" で展開すると set -u で落ちるため文字列に正規化する。
# shellcheck disable=SC2128
REPO_LIST=$(printf '%s ' ${REPOS[@]+"${REPOS[@]}"})
# shellcheck disable=SC2086
set -- $REPO_LIST
REPO_COUNT=$#

# ---- 安全チェック ----
log ""
log "🔒 安全チェック..."

if command -v pmset >/dev/null 2>&1; then
  battery=$(pmset -g batt 2>/dev/null | grep -o '[0-9]\+%' | head -1 | tr -d '%')
  on_ac=$(pmset -g batt 2>/dev/null | grep -c "AC Power")
  if [ -n "$battery" ] && [ "${on_ac:-0}" -eq 0 ] && [ "$battery" -lt "$MIN_BATTERY" ]; then
    log "❌ バッテリー残量 ${battery}% < ${MIN_BATTERY}%"
    notify "🔋 Nightly中止: バッテリー残量 ${battery}%"
    exit 2
  fi
fi
log "  ✅ 電源OK"

# ICMP を塞ぐネットワークがあるうえ、スリープ復帰直後は経路がまだ立っていない
# ことがある (2026-09-13 12:00 の実行が ping 失敗で中断した)。
# 実際に使う HTTPS で確かめ、数回リトライする。
net_ok=false
for attempt in 1 2 3; do
  if curl -sS -o /dev/null --max-time 10 https://api.github.com 2>/dev/null; then
    net_ok=true
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    log "  ⏳ api.github.com に到達できない (試行 ${attempt}/3)。10秒待って再試行"
    sleep 10
  fi
done
if ! $net_ok; then
  log "❌ ネット接続なし (api.github.com に到達できない)"
  notify "🌐 Nightly中止: ネット未接続"
  exit 3
fi
log "  ✅ ネット接続OK"

for cmd in gh spawn-agents claude jq git curl; do
  command -v "$cmd" >/dev/null 2>&1 || { log "❌ 必須コマンドなし: $cmd"; exit 4; }
done
log "  ✅ 必須コマンド揃っている"

if ! gh auth status >/dev/null 2>&1; then
  log "❌ gh 認証が切れています"
  notify "🔐 Nightly中止: gh認証切れ"
  exit 5
fi
log "  ✅ gh 認証OK"

if [ "$REPO_COUNT" -eq 0 ]; then
  log "❌ REPOS が未設定です ($CONFIG_FILE を編集してください)"
  exit 6
fi

# 直近3回が連続失敗なら手動確認まで止める
fail_count=0
for f in $(ls -t "$NIGHTLY_LOG_DIR"/run-*.log 2>/dev/null | head -4); do
  [ "$f" = "$RUN_LOG" ] && continue
  grep -q "^FINAL_STATUS=failed" "$f" 2>/dev/null && fail_count=$((fail_count + 1))
done
if [ "$fail_count" -ge 3 ]; then
  log "❌ 直近3回連続失敗。手動確認まで停止します"
  notify "🛑 Nightly停止: 3回連続失敗"
  exit 7
fi

# ---- Issue収集 ----
log ""
log "📋 対象Issue収集..."

TARGET_REPOS=""
TARGET_TOTAL=0
TMP_PLAN=$(mktemp)
trap 'rm -f "$TMP_PLAN"' EXIT

for repo in $REPO_LIST; do
  log "  リポジトリ: $repo"
  issues=$(gh issue list --repo "$repo" --state open \
    --label "$LABEL_FILTER" --limit "$MAX_ISSUES_PER_REPO" \
    --json number,title 2>/dev/null || echo "[]")

  count=$(printf '%s' "$issues" | jq 'length' 2>/dev/null || echo 0)
  log "    Open Issue数 (label=$LABEL_FILTER): $count"
  [ "$count" -gt 0 ] || continue

  printf '%s' "$issues" | jq -r '.[] | "      #\(.number): \(.title)"'
  nums=$(printf '%s' "$issues" | jq -r '[.[].number] | join(" ")')
  printf '%s\t%s\n' "$repo" "$nums" >> "$TMP_PLAN"
  TARGET_REPOS="$TARGET_REPOS $repo"
  TARGET_TOTAL=$((TARGET_TOTAL + count))
done

log ""
log "🎯 処理対象合計: $TARGET_TOTAL 件"
if [ "$TARGET_TOTAL" -eq 0 ]; then
  log "✨ 処理するIssueはありません。終了。"
  echo "FINAL_STATUS=no_work" >> "$RUN_LOG"
  exit 0
fi

# ---- 実行 ----
log ""
log "🚀 spawn-agents 実行..."

while IFS=$'\t' read -r repo nums; do
  [ -n "$repo" ] || continue
  log ""
  log "── $repo ──"

  local_path="$REPOS_DIR/$(basename "$repo")"
  if [ ! -d "$local_path/.git" ]; then
    log "  📥 clone: $repo → $local_path"
    mkdir -p "$REPOS_DIR"
    git clone "https://github.com/$repo.git" "$local_path" 2>&1 | tail -3
  else
    log "  🔄 最新化: $local_path"
    git -C "$local_path" fetch --all --prune 2>&1 | tail -3
    db=$(git -C "$local_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    git -C "$local_path" checkout "${db:-main}" 2>&1 | tail -1
    git -C "$local_path" pull --ff-only 2>&1 | tail -1
  fi

  log "  実行: spawn-agents --pr -j $MAX_PARALLEL --model $MODEL $nums"
  if $DRY_RUN; then
    log "  [DRY_RUN] 実行スキップ"
    continue
  fi

  (
    cd "$local_path" || exit 1
    # shellcheck disable=SC2086
    spawn-agents --pr -j "$MAX_PARALLEL" --model "$MODEL" $nums
  ) 2>&1 || log "  ⚠️  spawn-agents 終了コード非ゼロ"
done < "$TMP_PLAN"

# ---- サマリー ----
log ""
log "📊 サマリー作成..."

# tee で自分のログを読むため、grep -c の出力を整数に正規化する
count_event() {
  local n
  n=$(grep -c "^HARNESS_EVENT:$1 " "$RUN_LOG" 2>/dev/null | head -1 | tr -dc '0-9')
  echo "${n:-0}"
}

count_matching() {
  local n
  n=$(grep -c "$1" "$RUN_LOG" 2>/dev/null | head -1 | tr -dc '0-9')
  echo "${n:-0}"
}

done_count=$(count_event agent_done)
timeout_count=$(count_event agent_timeout)
pr_created=$(count_event pr_created)
merge_scheduled=$(count_event merge_scheduled)
merged=$(count_event merged)
failed=$(count_event failed)

# スキップは2種類ある。放っておけば進むもの (レビュー待ち・CI実行中) と、
# 人が見ないと永久に止まるもの (CI失敗・コンフリクト)。
# 同じ「スキップ」に丸めると、詰まっていることに誰も気づけない。
skipped_waiting=$(count_matching "^HARNESS_EVENT:skipped .*pr_state=waiting")
skipped_stuck=$(count_matching "^HARNESS_EVENT:skipped .*pr_state=stuck")
# 今回はじめて見つかった詰まり。既に印が付いているものは通知しない。
stuck_new=$(count_matching "^HARNESS_EVENT:skipped .*pr_state=stuck .*flagged=0")
stuck_list=$(grep "^HARNESS_EVENT:skipped .*pr_state=stuck" "$RUN_LOG" 2>/dev/null \
  | sed -E 's/.*issue=([0-9]+) pr=([0-9]+).*detail=([^ ]*).*/  #\1 → PR #\2 (\3)/' || true)
stuck_new_list=$(grep "^HARNESS_EVENT:skipped .*pr_state=stuck .*flagged=0" "$RUN_LOG" 2>/dev/null \
  | sed -E 's/.*issue=([0-9]+) pr=([0-9]+).*detail=([^ ]*).*/  #\1 → PR #\2 (\3)/' || true)

cat > "$SUMMARY_FILE" << EOF
🌙 Nightly Harness レポート ($(date '+%Y-%m-%d %H:%M'))

対象: ${REPO_COUNT} リポジトリ
処理: ${TARGET_TOTAL} Issue
  完了: ${done_count}
  タイムアウト: ${timeout_count}
  スキップ(レビュー待ち): ${skipped_waiting}
  詰まり(要対応): ${skipped_stuck}${stuck_new:+ (うち新規 ${stuck_new})}
  失敗: ${failed}
PR作成: ${pr_created}
マージ予約: ${merge_scheduled}
マージ完了: ${merged}
${stuck_list:+
🛑 人手が要る PR:
${stuck_list}
}
モデル: ${MODEL}
ログ: ${RUN_LOG}
EOF
cat "$SUMMARY_FILE"

# 通知は「人が動く必要があるとき」だけ鳴らす。
# 毎回鳴らすと見なくなり、肝心のときに気づけない。
notify_lines=""
[ "$stuck_new" -gt 0 ] && notify_lines="${notify_lines}🛑 詰まっている PR が ${stuck_new} 件
${stuck_new_list}
"
[ "$timeout_count" -gt 0 ] && notify_lines="${notify_lines}⏱️ タイムアウトしたエージェント ${timeout_count} 件
"
[ "$failed" -gt 0 ] && notify_lines="${notify_lines}❌ 失敗 ${failed} 件
"

if [ -n "$notify_lines" ]; then
  log ""
  log "📨 通知送信 (要対応あり)"
  prio="default"
  [ "$stuck_new" -gt 0 ] && prio="high"
  notify "$notify_lines
ログ: $RUN_LOG" "$prio"
else
  if [ "$skipped_stuck" -gt 0 ]; then
    log "📭 詰まりは ${skipped_stuck} 件あるが、いずれも通知済み。鳴らしません"
  else
    log "📭 要対応なし。通知はしません"
  fi
fi

# 1件も進まず失敗だけがある場合を failed とする。
# 既存PRによるスキップは失敗ではない。
if [ "$failed" -gt 0 ] && [ "$done_count" -eq 0 ] \
  && [ "$skipped_waiting" -eq 0 ] && [ "$skipped_stuck" -eq 0 ]; then
  echo "FINAL_STATUS=failed" >> "$RUN_LOG"
  log "❌ Nightly Harness 完了 (失敗のみ)"
  exit 1
fi
echo "FINAL_STATUS=success" >> "$RUN_LOG"
log "✅ Nightly Harness 完了"
exit 0
