#!/bin/bash
# harness-collect-metrics.sh — ログと GitHub から現状を集めて JSON で出す。
# 使い方: harness-collect-metrics [owner/repo]
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

REPO_FLAG=""
[ -n "${1:-}" ] && REPO_FLAG="--repo $1"

# ファイルの更新時刻(epoch)とサイズ。BSD stat と GNU stat の両方に対応する。
file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0; }
file_size()  { stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null || echo 0; }
epoch_to_iso() { date -r "$1" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                 || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ""; }

total_runs=0
success_runs=0
failed_runs=0

if [ -d "$LOG_DIR" ]; then
  while IFS= read -r log_file; do
    [ -f "$log_file" ] || continue
    total_runs=$((total_runs + 1))
    if grep -q "AGENT_DONE:" "$log_file" 2>/dev/null; then
      success_runs=$((success_runs + 1))
    else
      failed_runs=$((failed_runs + 1))
    fi
  done < <(find "$LOG_DIR" -name "issue-*.log" -type f 2>/dev/null | head -200)
fi

sessions_today=0
sessions_total=0
if [ -f "$LOG_DIR/sessions.log" ]; then
  sessions_total=$(wc -l < "$LOG_DIR/sessions.log" | tr -d ' ')
  sessions_today=$(grep -c "^\[$(date '+%Y-%m-%d')" "$LOG_DIR/sessions.log" 2>/dev/null | tr -d ' ')
fi

auto_commits_total=0
if [ -f "$LOG_DIR/auto-commit.log" ]; then
  auto_commits_total=$(wc -l < "$LOG_DIR/auto-commit.log" | tr -d ' ')
fi

active_worktrees=0
if [ -d "${WORKTREES_BASE:-$HOME/worktrees}" ]; then
  active_worktrees=$(find "${WORKTREES_BASE:-$HOME/worktrees}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
fi

open_issues=0
open_prs=0
merged_today=0
repo_name="(no repo)"
if git rev-parse --git-dir >/dev/null 2>&1; then
  repo_name=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||' || echo "(no remote)")
  # shellcheck disable=SC2086  # REPO_FLAG は "--repo x" として分割させたい
  open_issues=$(gh issue list --state open --limit 200 --json number $REPO_FLAG 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  # shellcheck disable=SC2086
  open_prs=$(gh pr list --state open --limit 200 --json number $REPO_FLAG 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  today_start=$(date -u '+%Y-%m-%dT00:00:00Z')
  # shellcheck disable=SC2086
  merged_today=$(gh pr list --state merged --limit 100 --json mergedAt $REPO_FLAG 2>/dev/null | \
    jq "[.[] | select(.mergedAt >= \"$today_start\")] | length" 2>/dev/null || echo 0)
fi

recent_array="[]"
if [ -d "$LOG_DIR" ]; then
  tmpfile=$(mktemp)
  find "$LOG_DIR" -name "issue-*.log" -type f 2>/dev/null | \
    while IFS= read -r f; do printf '%s %s\n' "$(file_mtime "$f")" "$f"; done | \
    sort -rn | head -10 | while read -r mtime path; do
      issue=$(basename "$path" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1)
      status="failed"
      grep -q "AGENT_DONE:" "$path" 2>/dev/null && status="success"
      size=$(file_size "$path")
      ts=$(epoch_to_iso "$mtime")
      printf '{"issue":%s,"status":"%s","size":%s,"timestamp":"%s"}\n' \
        "${issue:-0}" "$status" "$size" "$ts"
    done > "$tmpfile"
  recent_array=$(jq -s . "$tmpfile" 2>/dev/null || echo "[]")
  rm -f "$tmpfile"
fi

by_issue_array="[]"
if [ -d "$LOG_DIR" ]; then
  tmpfile=$(mktemp)
  find "$LOG_DIR" -name "issue-*.log" -type f 2>/dev/null | \
    sed -E 's/.*issue-([0-9]+)-.*/\1/' | sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "{\"issue\":%s,\"attempts\":%s}\n", $2, $1}' > "$tmpfile"
  by_issue_array=$(jq -s . "$tmpfile" 2>/dev/null || echo "[]")
  rm -f "$tmpfile"
fi

success_rate=0
if [ "$total_runs" -gt 0 ]; then
  success_rate=$(awk "BEGIN { printf \"%.1f\", $success_runs * 100 / $total_runs }")
fi

cat << JSON
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "repo": "$repo_name",
  "summary": {
    "total_runs": $total_runs,
    "success_runs": $success_runs,
    "failed_runs": $failed_runs,
    "success_rate": $success_rate,
    "sessions_total": $sessions_total,
    "sessions_today": $sessions_today,
    "auto_commits_total": $auto_commits_total,
    "active_worktrees": $active_worktrees,
    "open_issues": $open_issues,
    "open_prs": $open_prs,
    "merged_today": $merged_today
  },
  "recent_runs": $recent_array,
  "top_issues": $by_issue_array
}
JSON
