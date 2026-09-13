#!/bin/bash
# install.sh — nightly / weekly-audit を launchd に登録する (macOS 専用)。
#
# 常時稼働マシン (Mac mini など) でだけ実行する。ノート PC で入れると
# 蓋を閉じている間に走らず、起きた瞬間にまとめて走る。
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

AGENTS_DIR="$HOME/Library/LaunchAgents"
JOBS="nightly weekly-audit"
DRY_RUN=false
UNINSTALL=false

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    --uninstall)  UNINSTALL=true; shift ;;
    -h|--help)
      cat << EOF
使い方: launchd/install.sh [オプション]
  -n, --dry-run   生成する plist を表示するだけ
      --uninstall ジョブを停止して plist を削除する

登録されるジョブ:
  com.harness.nightly        2:00 と 8〜22時の偶数時。automation ラベルの Issue を実装
  com.harness.weekly-audit   土 7:00。idea ラベルの Issue を起票するだけ

設定は \$CLAUDE_HARNESS_DIR/nightly/config.sh (サンプル: nightly/config.example.sh)。
モデルや SLACK_WEBHOOK_URL は plist に焼かず、config.sh か
\$CLAUDE_HARNESS_DIR/env.sh に書く。plist に埋めると、生成したときの
シェルの値が固定化して後から追えなくなる。
EOF
      exit 0 ;;
    *) harness_die "不明なオプション: $1" ;;
  esac
done

[ "$(uname)" = "Darwin" ] || harness_die "macOS 専用です"

label_for() { printf 'com.harness.%s' "$1"; }

if $UNINSTALL; then
  echo "🧹 launchd ジョブを削除します"
  for job in $JOBS; do
    label=$(label_for "$job")
    plist="$AGENTS_DIR/${label}.plist"
    if [ -f "$plist" ]; then
      $DRY_RUN || launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
        || launchctl unload "$plist" 2>/dev/null || true
      $DRY_RUN || rm -f "$plist"
      echo "  - $label を削除"
    else
      echo "  - $label は未登録"
    fi
  done
  echo "✅ 完了"
  exit 0
fi

# CLI が PATH にあるか (launchd はログインシェルの PATH を継承しない)
BIN_DIR=""
for d in /usr/local/bin "$HOME/.local/bin"; do
  [ -x "$d/spawn-agents" ] && { BIN_DIR="$d"; break; }
done
[ -n "$BIN_DIR" ] || harness_die "spawn-agents が見つかりません。先に ./setup.sh を実行してください"

CONFIG_FILE="$HARNESS_DIR/nightly/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  if $DRY_RUN; then
    echo "📝 [dry-run] 設定ファイルが無いのでサンプルを置きます: $CONFIG_FILE"
  else
    echo "📝 設定ファイルがないのでサンプルを置きます: $CONFIG_FILE"
  fi
  $DRY_RUN || {
    mkdir -p "$HARNESS_DIR/nightly"
    cp "$HARNESS_ROOT/nightly/config.example.sh" "$CONFIG_FILE"
  }
  echo "   REPOS を編集してから再実行してください"
fi

mkdir -p "$AGENTS_DIR" "$HARNESS_DIR/nightly" "$HARNESS_DIR/audit"

for job in $JOBS; do
  label=$(label_for "$job")
  template="$HARNESS_ROOT/launchd/${label}.plist.template"
  plist="$AGENTS_DIR/${label}.plist"
  [ -f "$template" ] || { echo "  ⚠️  テンプレートなし: $template"; continue; }

  rendered=$(sed \
    -e "s|__HARNESS_ROOT__|$HARNESS_ROOT|g" \
    -e "s|__HARNESS_DIR__|$HARNESS_DIR|g" \
    -e "s|__WORKTREES_BASE__|$WORKTREES_BASE|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__BIN_DIR__|$BIN_DIR|g" \
    "$template")

  if $DRY_RUN; then
    echo "── $label ──"
    printf '%s\n' "$rendered"
    continue
  fi

  # 既存があれば止めてから置き換える
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
    || launchctl unload "$plist" 2>/dev/null || true

  printf '%s\n' "$rendered" > "$plist"
  plutil -lint "$plist" >/dev/null || harness_die "$plist の生成に失敗しました"

  if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null \
    || launchctl load "$plist" 2>/dev/null; then
    echo "  ✅ $label を登録"
  else
    echo "  ⚠️  $label の登録に失敗 (手動: launchctl bootstrap gui/$(id -u) $plist)"
  fi
done

$DRY_RUN && exit 0

echo ""
echo "登録状況:"
launchctl list | grep -E "com\.harness\." || echo "  (見つかりません)"
echo ""
echo "手動実行して確かめる:"
echo "  launchctl kickstart -p gui/$(id -u)/com.harness.nightly"
echo "  tail -f $HARNESS_DIR/nightly/launchd-stdout.log"
