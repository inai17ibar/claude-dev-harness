#!/bin/bash
# post-write.sh — PostToolUse(Write|Edit|MultiEdit) フック。書いたファイルを整形する。
#
# 対象ファイルは標準入力の JSON (.tool_input.file_path) から取る。
# 以前は CLAUDE_TOOL_INPUT_FILE_PATH という存在しない環境変数を見ていたため
# 何も整形していなかった。
#
# フォーマッタは **プロジェクトに入っているものだけ** を使う。
# `npx prettier` は未インストールだとネットワークから取りに行ってしまうので
# --no-install を付け、無ければ黙って諦める。

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

harness_read_hook_input
FILE=$(harness_hook_field '.tool_input.file_path')
[ -n "$FILE" ] || exit 0
[ -f "$FILE" ] || exit 0

# node_modules や .git の中は触らない
case "$FILE" in
  */node_modules/*|*/.git/*|*/dist/*|*/build/*|*/.next/*) exit 0 ;;
esac

run_npx() {  # $1 = パッケージ名, 以降 = 引数
  command -v npx >/dev/null 2>&1 || return 0
  npx --no-install "$@" >/dev/null 2>&1 || true
}

case "${FILE##*.}" in
  ts|tsx|mts|cts)
    run_npx prettier --write "$FILE"
    run_npx eslint --fix "$FILE"
    ;;
  js|jsx|mjs|cjs)
    run_npx prettier --write "$FILE"
    run_npx eslint --fix "$FILE"
    ;;
  json|css|scss|md|yml|yaml|html)
    run_npx prettier --write "$FILE"
    ;;
  py)
    if command -v ruff >/dev/null 2>&1; then
      ruff check --fix "$FILE" >/dev/null 2>&1 || true
      ruff format "$FILE" >/dev/null 2>&1 || true
    elif command -v black >/dev/null 2>&1; then
      black -q "$FILE" >/dev/null 2>&1 || true
    fi
    ;;
  rs)
    command -v rustfmt >/dev/null 2>&1 && { rustfmt "$FILE" >/dev/null 2>&1 || true; }
    ;;
  go)
    command -v gofmt >/dev/null 2>&1 && { gofmt -w "$FILE" >/dev/null 2>&1 || true; }
    ;;
  sh|bash)
    command -v shfmt >/dev/null 2>&1 && { shfmt -w "$FILE" >/dev/null 2>&1 || true; }
    ;;
esac

exit 0
