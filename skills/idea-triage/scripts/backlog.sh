#!/bin/bash
# backlog.sh — idea ラベルの Issue を、選別に必要な情報だけ付けて一覧にする。
#
# 使い方: backlog.sh <owner/repo> [owner/repo ...]
#
# 出している情報と、それが選別に効く理由:
#   経過日数  … 古いものは前提が変わっている可能性がある。大きな移行や
#               リファクタを挟んでいれば、内容が今も成り立つか疑ってかかる
#   本文字数  … nightly のエージェントは Issue 本文だけを仕様として読む。
#               本文が薄いものをそのまま automation にすると、
#               エージェントは手がかりなしで実装することになる
#   フラグ    … 未マージの PR が既にあるものは nightly がスキップするので、
#               ラベルを付けても動かない
set -uo pipefail

[ $# -gt 0 ] || { echo "使い方: backlog.sh <owner/repo> [owner/repo ...]" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh が必要です" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq が必要です" >&2; exit 1; }

now=$(date +%s)

for repo in "$@"; do
  issues=$(gh issue list -R "$repo" --state open --label idea --limit 100 \
    --json number,title,body,createdAt,labels 2>/dev/null) || {
    echo "⚠️  $repo の Issue を取得できませんでした" >&2
    continue
  }

  count=$(printf '%s' "$issues" | jq 'length')
  printf '\n── %s (idea: %s件) ──\n' "$repo" "$count"
  [ "$count" -gt 0 ] || { echo "  (なし)"; continue; }

  # 未マージのエージェント PR がある Issue 番号を集める
  prs=$(gh pr list -R "$repo" --state open --limit 100 --json headRefName 2>/dev/null || echo '[]')
  busy=$(printf '%s' "$prs" | jq -r '[.[] | (.headRefName // "")
    | capture("^agent/issue-(?<n>[0-9]+)-") | .n] | join(" ")')

  printf '%s' "$issues" | jq -r --argjson now "$now" '
    .[] | [
      .number,
      (($now - (.createdAt | fromdateiso8601)) / 86400 | floor),
      (.body // "" | length),
      ([.labels[].name] | join(",")),
      .title
    ] | @tsv' | while IFS=$'\t' read -r num age blen labels title; do
      flags=""
      case " $busy " in *" $num "*) flags="${flags}PR中 " ;; esac
      [ "$blen" -lt 120 ] && flags="${flags}本文薄 "
      [ "$age" -gt 30 ] && flags="${flags}古い "
      case ",$labels," in *,automation,*) flags="${flags}選別済 " ;; esac
      printf '  #%-4s %3sd  %5s字  %-14s %s\n' \
        "$num" "$age" "$blen" "${flags:-—}" "$title"
    done
done

printf '\n凡例: PR中=未マージPRあり(nightlyはスキップ) / 本文薄=実装の手がかりが不足 / 古い=30日超 / 選別済=automation付き\n'
