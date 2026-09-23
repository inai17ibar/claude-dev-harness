#!/bin/bash
# harness-review-data.sh — レビュー画面が必要とするものを JSON で出す。
#
# 使い方: harness-review-data.sh [owner/repo ...]
#   省略時は nightly の config.sh の REPOS を使う。
#   夜間ジョブが見ているのと同じ集合を既定にしないと、画面と実態がずれる。
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

REVIEW_LABEL="${REVIEW_LABEL:-review-findings}"
NEEDS_ATTENTION_LABEL="${NEEDS_ATTENTION_LABEL:-needs-attention}"

# 対象リポジトリの決め方 (上から順に採用)
#   1. 引数
#   2. $CLAUDE_HARNESS_DIR/repos.txt (1行1リポジトリ)。夜間ジョブを動かさない
#      マシンでもレビュー画面だけ使いたいので、独立した指定を持てるようにする
#   3. nightly の config.sh の REPOS。夜間ジョブが見ているのと同じ集合
#   4. カレントリポジトリの origin
repos=""
for a in "$@"; do
  case "$a" in
    --repos) REPOS_ONLY=1 ;;
    *) repos="$repos $a" ;;
  esac
done

if [ -z "$(printf '%s' "$repos" | tr -d ' ')" ] && [ -f "$HARNESS_DIR/repos.txt" ]; then
  repos=$(grep -vE '^\s*(#|$)' "$HARNESS_DIR/repos.txt" | tr '\n' ' ')
fi

if [ -z "$(printf '%s' "$repos" | tr -d ' ')" ]; then
  cfg="$HARNESS_DIR/nightly/config.sh"
  if [ -f "$cfg" ]; then
    REPOS=""
    # shellcheck disable=SC1090
    . "$cfg"
    # shellcheck disable=SC2128
    repos=$(printf '%s ' ${REPOS[@]+"${REPOS[@]}"})
  fi
fi

if [ -z "$(printf '%s' "$repos" | tr -d ' ')" ]; then
  repos=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||') || repos=""
fi

# --repos: 解決したリポジトリ一覧だけ出す。
# サーバーが「操作してよいリポジトリ」を検証するのに使う。
case "${REPOS_ONLY:-}" in
  1) printf '%s\n' $repos; exit 0 ;;
esac

now=$(date +%s)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '[]' > "$tmp/prs.json"
printf '[]' > "$tmp/backlog.json"

for repo in $repos; do
  # ---- エージェントの Open PR ----
  gh pr list -R "$repo" --state open --limit 50 \
    --json number,title,url,headRefName,labels,mergeable,statusCheckRollup,updatedAt,isDraft \
    2>/dev/null > "$tmp/raw.json" || printf '[]' > "$tmp/raw.json"

  jq --arg repo "$repo" --arg rl "$REVIEW_LABEL" --arg nl "$NEEDS_ATTENTION_LABEL" '
    def check_state:
      if (.__typename // "") == "CheckRun" then
        (if (.status // "") != "COMPLETED" then "PENDING" else (.conclusion // "NEUTRAL") end)
      else (.state // "PENDING") end;
    [ .[]
      | select((.headRefName // "") | startswith("agent/issue-"))
      | . as $pr
      | [ (.statusCheckRollup // [])[] | {n: (.name // .context // "check"), s: check_state} ] as $checks
      | ($checks | map(select(.s | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","ERROR")))) as $bad
      | ($checks | map(select(.s == "PENDING"))) as $pending
      | ([.labels[].name]) as $labels
      | {
          repo: $repo,
          number: .number,
          title: .title,
          url: .url,
          branch: .headRefName,
          issue: ((.headRefName | capture("^agent/issue-(?<n>[0-9]+)-") | .n | tonumber) // null),
          labels: $labels,
          updatedAt: .updatedAt,
          has_findings: ($labels | index($rl) != null),
          flagged: ($labels | index($nl) != null),
          checks: ($checks | map({name: .n, state: .s})),
          state: (
            if (.mergeable // "") == "CONFLICTING" then "conflict"
            elif ($bad | length) > 0 then "ci_failed"
            elif ($pending | length) > 0 then "ci_running"
            else "ready" end
          )
        }
    ]' "$tmp/raw.json" > "$tmp/repo_prs.json" 2>/dev/null || printf '[]' > "$tmp/repo_prs.json"

  jq -s 'add' "$tmp/prs.json" "$tmp/repo_prs.json" > "$tmp/prs.next" && mv "$tmp/prs.next" "$tmp/prs.json"

  # ---- idea バックログ ----
  gh issue list -R "$repo" --state open --label idea --limit 100 \
    --json number,title,body,createdAt,labels,url 2>/dev/null > "$tmp/raw_i.json" \
    || printf '[]' > "$tmp/raw_i.json"

  jq --arg repo "$repo" --argjson now "$now" '
    [ .[] | {
        repo: $repo,
        number: .number,
        title: .title,
        url: .url,
        age_days: ((($now - (.createdAt | fromdateiso8601)) / 86400) | floor),
        body_len: ((.body // "") | length),
        labels: [.labels[].name],
        promoted: ([.labels[].name] | index("automation") != null)
      } ]' "$tmp/raw_i.json" > "$tmp/repo_i.json" 2>/dev/null || printf '[]' > "$tmp/repo_i.json"

  jq -s 'add' "$tmp/backlog.json" "$tmp/repo_i.json" > "$tmp/b.next" && mv "$tmp/b.next" "$tmp/backlog.json"
done

# PR タイトルだけでは中身が分からない古い PR があるので、
# ブランチ名から辿った Issue のタイトルも添える。
jq -c '.[] | select(.issue != null) | {repo, number, issue}' "$tmp/prs.json" 2>/dev/null \
  | while IFS= read -r row; do
      r=$(printf '%s' "$row" | jq -r .repo)
      n=$(printf '%s' "$row" | jq -r .number)
      i=$(printf '%s' "$row" | jq -r .issue)
      gh issue view "$i" -R "$r" --json title -q '.title' \
        2>/dev/null > "$tmp/issuetitle_${n}.txt" || true
    done

# レビュー本文は PR ごとに1回だけ取りに行く (件数が多いと遅いので指摘ありだけ)
jq -c '.[] | select(.has_findings) | {repo, number}' "$tmp/prs.json" 2>/dev/null \
  | while IFS= read -r row; do
      r=$(printf '%s' "$row" | jq -r .repo)
      n=$(printf '%s' "$row" | jq -r .number)
      gh pr view "$n" -R "$r" --json comments \
        -q '[.comments[] | select(.body | startswith("## 🔍 自動レビュー"))] | last.body // ""' \
        2>/dev/null > "$tmp/review_${n}.txt" || true
    done

jq -n \
  --slurpfile prs "$tmp/prs.json" \
  --slurpfile backlog "$tmp/backlog.json" \
  --arg generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg repos "$repos" \
  '{generated: $generated, repos: ($repos | split(" ") | map(select(length > 0))),
    prs: $prs[0], backlog: $backlog[0]}' > "$tmp/out.json"

# レビュー本文を差し込む
python3 - "$tmp" << 'PY'
import json, os, sys
tmp = sys.argv[1]
with open(os.path.join(tmp, "out.json"), encoding="utf-8") as f:
    data = json.load(f)
for pr in data.get("prs", []):
    path = os.path.join(tmp, "review_%s.txt" % pr["number"])
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            pr["review"] = f.read().strip()
    path = os.path.join(tmp, "issuetitle_%s.txt" % pr["number"])
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            t = f.read().strip()
        if t:
            pr["issue_title"] = t
print(json.dumps(data, ensure_ascii=False))
PY
