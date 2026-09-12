#!/bin/bash
# safety-guard.sh — PreToolUse(Bash) フック。破壊的なコマンドを実行前に止める。
#
# 入力は標準入力の JSON (.tool_input.command)。
# 終了コード 2 = ブロック。stderr の内容が Claude にフィードバックされる。
#
# 設計方針:
#   - 誤爆しないこと。`rm -rf /tmp/build` や `rm -rf node_modules` を止めてしまうと
#     ガードごと外されて意味がなくなる。パターンは必ず対象を最後まで見て判定する。
#   - 追加・除外はユーザーが設定ファイルで足せるようにする。
#       $CLAUDE_HARNESS_DIR/safety-block.txt  … 1行1 ERE。追加でブロックする
#       $CLAUDE_HARNESS_DIR/safety-allow.txt  … 1行1 ERE。合致したら常に許可する

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
# shellcheck source=../lib/hook-input.sh
. "$HARNESS_ROOT/lib/hook-input.sh"

HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"

harness_read_hook_input
CMD=$(harness_hook_field '.tool_input.command')
[ -n "$CMD" ] || exit 0

matches() { printf '%s' "$CMD" | grep -qE "$1"; }
matches_fixed() { printf '%s' "$CMD" | grep -qF "$1"; }

block() {
  printf '🚫 Safety Guard: %s\n' "$1" >&2
  printf '   コマンド: %s\n' "$CMD" >&2
  printf '   意図した操作なら、対象を明示するか手元で実行してください。\n' >&2
  exit 2
}

# ---- ユーザー定義の許可リスト (最優先) ----------------------------------
if [ -f "$HARNESS_DIR/safety-allow.txt" ]; then
  while IFS= read -r pattern; do
    case "$pattern" in ''|'#'*) continue ;; esac
    matches "$pattern" && exit 0
  done < "$HARNESS_DIR/safety-allow.txt"
fi

# ---- ルート/ホーム全体の削除 --------------------------------------------
# rm のフラグを読み飛ばし、削除対象が / ~ $HOME そのもの (または /*) のときだけ止める。
# `rm -rf /tmp/x` `rm -rf ~/worktrees/x` は対象が続くのでここには当たらない。
RM_ALL='rm[[:space:]]+(-[^[:space:]]+[[:space:]]+)*["'"'"']?(/|~|\$HOME|\$\{HOME\})["'"'"']?(/?\*)?[[:space:]]*($|[;&|])'
matches "$RM_ALL" && block "ルートまたはホームディレクトリ全体の削除"

# ---- ディスクの直接書き込み ---------------------------------------------
matches 'dd[[:space:]]+if=/dev/(zero|random|urandom)[^;&|]*of=/dev/' \
  && block "ブロックデバイスへの dd 書き込み"
matches '>[[:space:]]*/dev/(sd[a-z]|disk[0-9]|nvme[0-9])' \
  && block "ブロックデバイスへのリダイレクト"
matches 'mkfs(\.[a-z0-9]+)?[[:space:]]' && block "ファイルシステムの作成 (mkfs)"

# ---- fork bomb -----------------------------------------------------------
matches_fixed ':(){ :|:& };:' && block "fork bomb"
matches ':\(\)[[:space:]]*\{[[:space:]]*:\|:&' && block "fork bomb"

# ---- 外部スクリプトの直接実行 -------------------------------------------
matches '(curl|wget)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh([[:space:]]|$)' \
  && block "ダウンロードしたスクリプトのパイプ実行"

# ---- 既定ブランチへの破壊的操作 -----------------------------------------
# --force-with-lease は安全側なので通す。
if matches 'git[[:space:]]+push' \
  && matches '(--force([[:space:]]|$)|[[:space:]]-f([[:space:]]|$))' \
  && matches '(^|[[:space:]:/])(main|master)([[:space:]]|:|$)'; then
  block "既定ブランチへの force push (--force-with-lease を使ってください)"
fi
matches 'git[[:space:]]+branch[[:space:]]+-[dD][[:space:]]+(main|master)([[:space:]]|$)' \
  && block "既定ブランチの削除"
matches 'git[[:space:]]+push[^;&|]*--delete[[:space:]]+(main|master)([[:space:]]|$)' \
  && block "リモートの既定ブランチの削除"

# ---- 権限の一括変更 ------------------------------------------------------
matches 'chmod[[:space:]]+(-[^[:space:]]+[[:space:]]+)*777[[:space:]]+/[[:space:]]*($|[;&|])' \
  && block "ルート全体の chmod 777"

# ---- 破壊的な SQL --------------------------------------------------------
matches 'DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)[[:space:]]' \
  && block "破壊的な SQL (DROP)"
matches 'TRUNCATE[[:space:]]+TABLE[[:space:]]' && block "破壊的な SQL (TRUNCATE)"

# ---- ユーザー定義の追加ブロック -----------------------------------------
if [ -f "$HARNESS_DIR/safety-block.txt" ]; then
  while IFS= read -r pattern; do
    case "$pattern" in ''|'#'*) continue ;; esac
    matches "$pattern" && block "ユーザー定義パターンに合致: $pattern"
  done < "$HARNESS_DIR/safety-block.txt"
fi

exit 0
