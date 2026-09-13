#!/bin/bash
# worktree-clean.sh — マージ済みの worktree とブランチを片付ける。
# 使い方: worktree-clean [--dry-run] [--all-repos]
#
# 安全性について:
#   $WORKTREES_BASE は全リポジトリで共有される。旧版は「現在のリポジトリの
#   `git worktree list` に無いディレクトリ」を無条件に rm -rf していたため、
#   別リポジトリの作業中 worktree を巻き添えで消す事故が起きうる状態だった。
#   このため既定では自分のリポジトリ名で始まるディレクトリしか触らない。
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

DRY_RUN=false
ALL_REPOS=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --all-repos) ALL_REPOS=true; shift ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) harness_die "不明なオプション: $1" ;;
  esac
done

harness_require_git_repo
REPO_SLUG=$(harness_repo_slug)
DEFAULT_BRANCH=$(harness_default_branch)

echo "🧹 worktree クリーンアップ"
echo "  リポジトリ: $REPO_SLUG"
echo "  ベースブランチ: $DEFAULT_BRANCH"
echo "  worktree 置き場: $WORKTREES_BASE"
$DRY_RUN   && echo "  [DRY RUN — 実際には削除しません]"
$ALL_REPOS && echo "  [--all-repos — 他リポジトリの残骸も対象にします]"
echo ""

# ---- 1. マージ済みブランチとその worktree ------------------------------
# git branch --merged の行頭マーカー:
#   "* " 現在のブランチ / "+ " 他の worktree でチェックアウト中 / "  " それ以外
# "+" を剥がし忘れると、worktree を持つブランチ === まさに掃除したいものが
# 全部対象から外れる。
merged_agent_branches() {
  sed 's/^[*+] //; s/^  //' | grep -E '^(agent/|ccx/)' || true
}

echo "▼ マージ済みの agent/ccx ブランチ"
merged=$(git branch --merged "$DEFAULT_BRANCH" 2>/dev/null | merged_agent_branches)

if [ -z "$merged" ]; then
  echo "  (なし)"
else
  printf '%s\n' "$merged" | while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    wt=$(git worktree list --porcelain \
      | awk -v b="refs/heads/$branch" '/^worktree /{p=$2} $0=="branch "b{print p}' || true)
    echo "  - $branch${wt:+  (worktree: $wt)}"
    $DRY_RUN && continue
    [ -n "$wt" ] && git worktree remove --force "$wt" >/dev/null 2>&1
    git branch -d "$branch" >/dev/null 2>&1 || git branch -D "$branch" >/dev/null 2>&1 || true
  done
fi

# ---- 2. 登録が外れた worktree ディレクトリ -----------------------------
echo ""
echo "▼ 登録の外れた worktree ディレクトリ"
[ -d "$WORKTREES_BASE" ] || { echo "  ($WORKTREES_BASE がありません)"; exit 0; }

# このリポジトリの git ディレクトリ。worktree の所属判定に使う。
own_common_dir=$(cd "$(git rev-parse --show-toplevel)" && git rev-parse --git-common-dir 2>/dev/null)
case "$own_common_dir" in
  /*) ;;
  *)  own_common_dir="$(cd "$(git rev-parse --show-toplevel)" && cd "$own_common_dir" && pwd)" ;;
esac

found=0
shown=0
for dir in "$WORKTREES_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  name=$(basename "$dir")

  # 既定では自分のリポジトリの worktree だけを対象にする
  if ! $ALL_REPOS; then
    case "$name" in
      "$REPO_SLUG"-*) ;;
      *) continue ;;
    esac
  fi

  # まだこのリポジトリに登録されている worktree なら触らない
  if git worktree list --porcelain | grep -qx "worktree $dir"; then
    continue
  fi

  # 他リポジトリに登録されている worktree なら触らない
  if [ -e "$dir/.git" ]; then
    other=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || true)
    if [ -n "$other" ]; then
      case "$other" in
        /*) ;;
        *)  other="$(cd "$dir" && cd "$other" && pwd 2>/dev/null || true)" ;;
      esac
      if [ -n "$other" ] && [ "$other" != "$own_common_dir" ]; then
        shown=$((shown + 1))
        echo "  - $name  … 別リポジトリの worktree のためスキップ"
        continue
      fi
    fi
  fi

  found=$((found + 1))
  shown=$((shown + 1))
  echo "  - $dir"
  $DRY_RUN && continue
  rm -rf "$dir" && echo "      → 削除しました"
done
[ "$shown" -eq 0 ] && echo "  (なし)"

$DRY_RUN || git worktree prune

echo ""
echo "✅ 完了"
git worktree list
