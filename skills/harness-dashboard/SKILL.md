---
name: harness-dashboard
description: >
  Claude Dev Harness の観測ダッシュボード操作。エージェント実行状況、
  Issue/PR数、成功率、最近の実行ログを確認する。
  「ダッシュボード開いて」「ハーネスの状況見せて」「処理状況確認」
  「成功率は？」「最近の実行ログ」「Issueの処理待ち」がトリガー。
allowed-tools: Bash
---

# Harness Dashboard

## ダッシュボードの起動

```bash
harness-dashboard           # http://localhost:8765 で起動
harness-dashboard 9000      # ポート指定
```

ブラウザで自動的に開かない場合は、`open http://localhost:8765` で開く。

## コマンドラインでメトリクス取得

JSON形式で現状を取得:

```bash
# 現在のリポジトリ
harness-collect-metrics

# 別リポジトリ指定
harness-collect-metrics inai17ibar/harness-test

# 整形して表示
harness-collect-metrics | jq .

# サマリーだけ
harness-collect-metrics | jq .summary

# 成功率だけ
harness-collect-metrics | jq .summary.success_rate
```

## 取得できるメトリクス

| フィールド | 説明 |
|---|---|
| `summary.total_runs` | エージェント総実行数 |
| `summary.success_runs` | 成功した実行 (AGENT_DONE出力あり) |
| `summary.failed_runs` | 失敗した実行 |
| `summary.success_rate` | 成功率 (%) |
| `summary.sessions_today` | 本日のClaudeセッション数 |
| `summary.sessions_total` | 累計セッション数 |
| `summary.auto_commits_total` | auto-commit hook発動回数 |
| `summary.active_worktrees` | 現在の worktree 数 |
| `summary.open_issues` | リポジトリのOpen Issue |
| `summary.open_prs` | リポジトリのOpen PR |
| `summary.merged_today` | 本日マージされたPR数 |
| `recent_runs` | 最近の実行10件 |
| `top_issues` | 試行回数の多いIssue上位10件 |

## データソース

- `~/.claude-harness/logs/issue-*.log` — 各エージェント実行ログ
- `~/.claude-harness/logs/sessions.log` — Stop hookのセッション記録
- `~/.claude-harness/logs/auto-commit.log` — 自動コミット履歴
- `~/worktrees/` — アクティブworktree
- `gh issue list`, `gh pr list` — GitHubの現状

## ユーザの典型的な質問への応答

「成功率はどう?」→ `harness-collect-metrics | jq '.summary | {success_rate, total_runs}'`

「Open Issueは何件?」→ `harness-collect-metrics | jq '.summary.open_issues'`

「今日マージされたPRは?」→ `harness-collect-metrics | jq '.summary.merged_today'`

「最近の実行を5件見せて」→ `harness-collect-metrics | jq '.recent_runs[:5]'`

「失敗が多いIssueは?」→ `harness-collect-metrics | jq '.top_issues'`

「ダッシュボード開いて」→ `harness-dashboard &` してから `open http://localhost:8765`
