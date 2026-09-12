#!/bin/bash
# setup.sh — Claude Dev Harness のインストール / 更新 / アンインストール。
#
# 冪等。何度実行しても同じ状態になる。
#   - ~/.claude/settings.json は **マージ** する。既存の model / plugins / theme は残す
#   - ~/.zshrc の環境変数はマーカーで囲んだブロックを置換する。追記して増殖させない
#   - hooks と CLI はこのリポジトリを直接指す。git pull すればそのまま反映される
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
HARNESS_ROOT=$(cd -P "$(dirname "$_harness_self")" && pwd)
# shellcheck source=lib/common.sh
. "$HARNESS_ROOT/lib/common.sh"

CLAUDE_DIR="$HOME/.claude"
SKILL_DIR="$CLAUDE_DIR/skills"
SETTINGS="$CLAUDE_DIR/settings.json"
ZSHRC="$HOME/.zshrc"
BIN_DIR=""
MARKER_BEGIN="# >>> claude-dev-harness >>>"
MARKER_END="# <<< claude-dev-harness <<<"
OURS_RE="claude-dev-harness|\\.claude-harness/hooks"

DRY_RUN=false
UNINSTALL=false
SKIP_ZSHRC=false

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)   DRY_RUN=true; shift ;;
    --uninstall)    UNINSTALL=true; shift ;;
    --skip-zshrc)   SKIP_ZSHRC=true; shift ;;
    -h|--help)
      cat << EOF
使い方: ./setup.sh [オプション]
  -n, --dry-run     何をするか表示するだけ
      --uninstall   シンボリックリンク・hooks 設定・zshrc ブロックを外す
                    (ログや worktree は消さない)
      --skip-zshrc  ~/.zshrc を触らない
EOF
      exit 0 ;;
    *) harness_die "不明なオプション: $1" ;;
  esac
done

run() {
  if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

# ---- インストール先の bin を決める --------------------------------------
pick_bin_dir() {
  local d
  for d in /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$d" ] && [ -w "$d" ]; then BIN_DIR="$d"; return 0; fi
  done
  BIN_DIR="$HOME/.local/bin"
  run mkdir -p "$BIN_DIR"
}

CLI_NAMES="spawn-agents ccx-run worktree-clean harness-collect-metrics harness-dashboard"

# ---- アンインストール ---------------------------------------------------
if $UNINSTALL; then
  echo "🧹 Claude Dev Harness をアンインストールします"
  pick_bin_dir
  for name in $CLI_NAMES; do
    target="$BIN_DIR/$name"
    if [ -L "$target" ] && readlink "$target" | grep -q "claude-dev-harness"; then
      run rm -f "$target"
      echo "  - $target を削除"
    fi
  done
  if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    if jq --arg re "$OURS_RE" '
      .hooks = ((.hooks // {}) | with_entries(
        .value = (.value
          | map(.hooks = ((.hooks // []) | map(select(((.command // "") | test($re)) | not))))
          | map(select((.hooks | length) > 0)))))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    ' "$SETTINGS" > "$tmp" 2>/dev/null; then
      run cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
      run mv "$tmp" "$SETTINGS"
      echo "  - settings.json から hooks を除去"
    else
      rm -f "$tmp"
    fi
  fi
  if [ -f "$ZSHRC" ] && grep -qF "$MARKER_BEGIN" "$ZSHRC"; then
    run cp "$ZSHRC" "$ZSHRC.backup.$(date +%Y%m%d_%H%M%S)"
    if ! $DRY_RUN; then
      awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b {skip=1} skip==0 {print} $0 == e {skip=0}' "$ZSHRC" > "$ZSHRC.tmp" \
        && mv "$ZSHRC.tmp" "$ZSHRC"
    fi
    echo "  - ~/.zshrc のブロックを削除"
  fi
  echo "✅ アンインストール完了"
  exit 0
fi

# ---- 依存チェック -------------------------------------------------------
echo "🚀 Claude Dev Harness セットアップ"
echo "   ソース: $HARNESS_ROOT"
echo ""
echo "📦 依存チェック"
missing=""
for cmd in git gh jq node python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
  else
    echo "  ❌ $cmd"
    missing="$missing $cmd"
  fi
done
for cmd in tmux claude shellcheck; do
  command -v "$cmd" >/dev/null 2>&1 && echo "  ✅ $cmd (任意)" || echo "  ⚠️  $cmd が無い (任意)"
done
[ -z "$missing" ] || harness_die "必須コマンドが足りません:$missing  →  brew install$missing"

# ---- ランタイムディレクトリ ---------------------------------------------
echo ""
echo "📁 ランタイムディレクトリ: $HARNESS_DIR"
run mkdir -p "$HARNESS_DIR/logs/ccx" "$HARNESS_DIR/dashboard" "$WORKTREES_BASE"

# ---- CLI のリンク -------------------------------------------------------
echo ""
pick_bin_dir
echo "🔗 CLI を $BIN_DIR にリンク"
for name in $CLI_NAMES; do
  src="$HARNESS_ROOT/bin/${name}.sh"
  [ -f "$src" ] || { echo "  ⚠️  $src が無いのでスキップ"; continue; }
  run chmod +x "$src"
  run ln -sfn "$src" "$BIN_DIR/$name"
  echo "  ✅ $name → ${src#"$HARNESS_ROOT"/}"
done

# ---- hooks ---------------------------------------------------------------
echo ""
echo "🪝 hooks を $SETTINGS に登録 (既存設定は保持)"
run chmod +x "$HARNESS_ROOT"/hooks/*.sh

NEW_HOOKS=$(cat << JSON
{
  "PostToolUse": [
    {"matcher":"Write|Edit|MultiEdit",
     "hooks":[{"type":"command","command":"$HARNESS_ROOT/hooks/post-write.sh","timeout":30}]}
  ],
  "PreToolUse": [
    {"matcher":"Bash",
     "hooks":[{"type":"command","command":"$HARNESS_ROOT/hooks/safety-guard.sh","timeout":10}]}
  ],
  "Stop": [
    {"hooks":[{"type":"command","command":"$HARNESS_ROOT/hooks/on-stop.sh","timeout":20}]}
  ],
  "SessionStart": [
    {"hooks":[{"type":"command","command":"$HARNESS_ROOT/hooks/session-start.sh","timeout":15}]}
  ]
}
JSON
)

# 既存の settings.json を土台にする。無ければ空オブジェクトから始める。
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null \
    || harness_die "$SETTINGS が壊れています。直してから再実行してください"
  SETTINGS_SRC="$SETTINGS"
else
  run mkdir -p "$CLAUDE_DIR"
  SETTINGS_SRC=$(mktemp)
  printf '{}\n' > "$SETTINGS_SRC"
  trap 'rm -f "$SETTINGS_SRC"' EXIT
fi

merged=$(jq --argjson nh "$NEW_HOOKS" --arg re "$OURS_RE" '
  # 自分が過去に入れた hook だけ取り除いてから入れ直す。他人の hook は残す。
  .hooks = ((.hooks // {}) | with_entries(
    .value = (.value
      | map(.hooks = ((.hooks // []) | map(select(((.command // "") | test($re)) | not))))
      | map(select((.hooks | length) > 0)))))
  | .hooks = (reduce ($nh | to_entries[]) as $e (.hooks; .[$e.key] = ((.[$e.key] // []) + $e.value)))
' "$SETTINGS_SRC") || harness_die "settings.json のマージに失敗しました"

if $DRY_RUN; then
  echo "  [dry-run] hooks をマージ (4 イベント)"
else
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
  printf '%s\n' "$merged" > "$SETTINGS"
  echo "  ✅ PostToolUse / PreToolUse / Stop / SessionStart を登録"
  echo "     バックアップ: $SETTINGS.backup.*"
fi

# ---- skills --------------------------------------------------------------
echo ""
echo "📚 スキルを $SKILL_DIR に配置"
run mkdir -p "$SKILL_DIR"
for skill_path in "$HARNESS_ROOT"/skills/*/; do
  [ -d "$skill_path" ] || continue
  name=$(basename "$skill_path")
  run rm -rf "$SKILL_DIR/$name"
  run cp -R "$skill_path" "$SKILL_DIR/$name"
  echo "  ✅ $name"
done

# ---- ~/.zshrc ------------------------------------------------------------
if $SKIP_ZSHRC; then
  echo ""
  echo "⏭️  --skip-zshrc のため ~/.zshrc は触りません"
else
  echo ""
  echo "🔑 ~/.zshrc の環境変数ブロックを更新"
  BLOCK=$(cat << ZBLOCK
$MARKER_BEGIN
# このブロックは setup.sh が管理します。手で増やさないでください。
export CLAUDE_HARNESS_DIR="\$HOME/.claude-harness"   # ログ・状態の置き場
export WORKTREES_BASE="\$HOME/worktrees"             # worktree の置き場
export CLAUDE_MODEL="claude-opus-5"                  # spawn-agents / ccx-run の既定モデル
# 並行数の上限。エージェントが同時起動で落ちるようなら 1〜2 に下げる。
export MAX_PARALLEL=3
export AGENT_TIMEOUT=3600                            # 1エージェントの上限秒数 (0で無制限)
# Slack 通知を使うなら実際の Webhook URL を入れてコメントを外す。
# 未設定なら on-stop.sh は Slack への送信をスキップします。
# export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
$MARKER_END
ZBLOCK
)
  if $DRY_RUN; then
    echo "  [dry-run] ブロックを置換/追記"
  else
    touch "$ZSHRC"
    cp "$ZSHRC" "$ZSHRC.backup.$(date +%Y%m%d_%H%M%S)"
    if grep -qF "$MARKER_BEGIN" "$ZSHRC"; then
      awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" -v blk="$BLOCK" '
        $0 == b {skip=1; print blk; next}
        $0 == e {skip=0; next}
        skip==0 {print}' "$ZSHRC" > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
      echo "  ✅ 既存ブロックを置換"
    else
      printf '\n%s\n' "$BLOCK" >> "$ZSHRC"
      echo "  ✅ ブロックを追記"
    fi
    echo "     バックアップ: $ZSHRC.backup.*"
  fi
fi

echo ""
echo "========================================="
echo "✅ セットアップ完了"
echo ""
echo "次のステップ:"
echo "  1. source ~/.zshrc"
echo "  2. Claude Code を再起動して hooks を読み込ませる"
echo "  3. Git リポジトリで: spawn-agents --dry-run <issue番号>"
echo ""
echo "確認:"
echo "  tests/run-tests.sh        # 自己テスト"
echo "  harness-collect-metrics   # 稼働メトリクス"
echo "========================================="
