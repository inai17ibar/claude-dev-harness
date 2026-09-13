#!/bin/bash
# common.sh — 全スクリプト共通のユーティリティ。
#
# 制約: macOS 標準の /bin/bash は 3.2 なので、bash 4+ 専用の機能
# (wait -n, declare -A, ${var^^}, mapfile など) は使わない。
# Homebrew の bash 5 は /usr/local/bin にある x86_64 ビルドで、
# arm64 環境では別の問題を招くため依存しない (docs/troubleshooting.md 参照)。

# ---- 既定値 -------------------------------------------------------------
HARNESS_DIR="${CLAUDE_HARNESS_DIR:-$HOME/.claude-harness}"
WORKTREES_BASE="${WORKTREES_BASE:-$HOME/worktrees}"
# shellcheck disable=SC2034  # 読み込む側のスクリプトで使う
LOG_DIR="$HARNESS_DIR/logs"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-5}"
# 1 エージェントの上限秒数。0 で無制限。応答不能なエージェントが
# 並行枠を占有し続けるのを防ぐ。
AGENT_TIMEOUT="${AGENT_TIMEOUT:-3600}"

# ---- ログ ---------------------------------------------------------------
harness_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
harness_die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# ---- 依存チェック -------------------------------------------------------
harness_require() {
  local missing=""
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  [ -z "$missing" ] || harness_die "次のコマンドが必要です:$missing"
}

# ---- Git --------------------------------------------------------------
harness_require_git_repo() {
  git rev-parse --git-dir >/dev/null 2>&1 || harness_die "Gitリポジトリ内で実行してください"
}

# リポジトリの識別子。worktree ディレクトリ名の衝突回避に使う。
# worktree の中から呼んでも同じ値になるよう remote URL を優先する。
harness_repo_slug() {
  local url name
  url=$(git config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$url" ]; then
    name=$(basename "$url" .git)
  else
    name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo repo)")
  fi
  printf '%s' "$name" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-'
}

# 既定ブランチ。origin/HEAD が無いリポジトリでも動くようフォールバックする。
harness_default_branch() {
  local ref
  ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) && {
    printf '%s' "${ref#refs/remotes/origin/}"
    return 0
  }
  for ref in main master; do
    if git show-ref --verify --quiet "refs/heads/$ref"; then
      printf '%s' "$ref"
      return 0
    fi
  done
  git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'main'
}

# ---- 並行実行 -----------------------------------------------------------
# bash 3.2 には `wait -n` が無い。生きている PID を数え、上限を下回るまで
# 短い sleep を挟んでポーリングする。`wait -n` を || true で握り潰すと
# 3.2 ではビジーループになって CPU を焼くため、その形は使わない。
#
# 使い方: harness_throttle <上限> <pid...>
#   標準出力に「まだ生きている PID」を空白区切りで返す。
harness_throttle() {
  local limit=$1
  shift
  local alive pid
  while :; do
    alive=""
    for pid in "$@"; do
      if kill -0 "$pid" 2>/dev/null; then
        alive="$alive $pid"
      fi
    done
    # shellcheck disable=SC2086
    set -- $alive
    [ "$#" -lt "$limit" ] && break
    sleep 1
  done
  printf '%s' "${alive# }"
}

# ---- タイムアウト付き実行 ------------------------------------------------
# macOS には GNU coreutils の timeout が無いことが多い。
# gtimeout があれば使い、無ければポーリングで打ち切る。
# 応答不能になったエージェントを放置すると並行枠を食い潰すため必要。

# プロセスとその子孫を終わらせる。バックグラウンドジョブは
# スクリプト本体と同じプロセスグループなので、グループ kill は使えない。
harness_kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    harness_kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

# 使い方: harness_run_with_timeout <秒> <コマンド...>
#   打ち切った場合は 124 を返す (GNU timeout と同じ)
harness_run_with_timeout() {
  local secs=$1
  shift

  if [ -z "$secs" ] || [ "$secs" -le 0 ] 2>/dev/null; then
    "$@"
    return $?
  fi

  "$@" &
  local pid=$! waited=0 step=2
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      harness_kill_tree "$pid"
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep "$step"
    waited=$((waited + step))
  done
  wait "$pid"
}

# ---- 一時的な失敗のリトライ ----------------------------------------------
# GitHub の API は 502 や GraphQL の "Something went wrong" を返すことがある。
# 失敗して困る操作 (マージを止める、など) は数回試す。
#
# 使い方: harness_retry <試行回数> <待ち秒> <コマンド...>
#   最後の試行の標準エラーは握り潰さずに返す。
harness_retry() {
  local attempts=$1 delay=$2
  shift 2
  local i=1 out rc
  while :; do
    # if の中で実行すると、分岐が走らなかったときの $? は if 文自体の
    # 終了コード (=0) になり、元の失敗コードが失われる。
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
    if [ "$i" -ge "$attempts" ]; then
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
    i=$((i + 1))
    sleep "$delay"
  done
}
