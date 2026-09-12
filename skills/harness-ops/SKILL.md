---
name: harness-ops
description: >
  Claude Dev Harness の運用スキル。複数Issueの並行解決、worktree管理、
  PR作成、ccx-runでのN回実行、Hooksの設定など、ハーネスのCLIツールを
  どう使うかを定義する。「issueを並行で」「worktreeを掃除」
  「複数案を試したい」「PR作って」がトリガー。
allowed-tools: Bash, Read
---

# Claude Dev Harness 運用ガイド

このリポジトリは Claude Dev Harness で開発されている。
以下の CLI ツールが `/usr/local/bin/` にインストール済み。
実体は `~/src/claude-dev-harness/bin/` へのシンボリックリンクなので、
`git pull && ./setup.sh` で更新できる。

## コマンド一覧

### spawn-agents — 複数Issueの並行解決

```bash
# 基本: Opus で並行解決
spawn-agents 42 51 67

# PR作成まで自動化
spawn-agents --pr 42 51 67

# PR作成 + 自動マージ (CI通過後)
spawn-agents --merge 42 51 67

# Sonnetで高速バッチ (5並行)
spawn-agents --model claude-sonnet-5 -j 5 --pr 1 2 3 4 5

# tmuxで並行ログ確認
spawn-agents -m tmux 42 51 67

# DRY RUN
spawn-agents --dry-run 42 51

# 未マージPRがあるIssueも強制的に再実装
spawn-agents --force 42

# タイムアウトを15分にする (既定は3600秒、0で無制限)
spawn-agents -t 900 42
```

各Issueに対して `~/worktrees/<リポジトリ名>-issue-<番号>/` に独立worktreeが作られ、
未マージの既存PRがあるIssueは再実装せずスキップされる（`--force` で上書き）。
ブランチ `agent/issue-<番号>-<timestamp>` でエージェントが実装する。

タイムアウトしたエージェントも、そこまでのコミットがあればPRを作る。
ログ末尾の `AGENT_DONE:<番号>` / `AGENT_TIMEOUT:<番号>` で成否を判別できる。

### ccx-run — N回実行してベスト選択

```bash
# 探索的: 3回実行して比較
ccx-run -n 3 "認証フローを実装"

# 一意解 (exact): 1回実行
ccx-run -t exact --test "npm test" "Issue #42を修正"

# テスト通過を条件にする
ccx-run --test "pytest" -n 3 "UserServiceをリファクタ"

# 違うモデルで試す
ccx-run --model claude-sonnet-5 -n 5 "デザイン案を出して"
```

### worktree-clean — 後片付け

```bash
# マージ済みworktreeとブランチを削除
worktree-clean

# 削除対象だけ確認
worktree-clean --dry-run

# 他リポジトリの残骸も対象にする (現役の worktree はスキップされる)
worktree-clean --all-repos
```

`$WORKTREES_BASE` は全リポジトリ共有なので、既定では自分のリポジトリ名で始まる
ディレクトリしか触らない。他リポジトリの作業中 worktree を巻き添えで消さないため。

## Hooks (自動で動作)

| Hook | タイミング | 動作 |
|---|---|---|
| `post-write.sh` | ファイル書き込み後 | Prettier/ruff/gofmt 自動実行 |
| `auto-commit.sh` | Stop時 | agent/issue-* ブランチで未コミット変更を自動コミット |
| `on-stop.sh` | Stop時 | Slack + macOS通知 |
| `session-start.sh` | セッション開始時 | Issue本文をコンテキスト注入 |
| `safety-guard.sh` | Bash実行前 | rm -rf / などをブロック。`~/.claude-harness/safety-{allow,block}.txt` で調整可 |

## 環境変数

```bash
CLAUDE_MODEL          # デフォルトモデル (claude-opus-5)
AGENT_TIMEOUT         # 1エージェントの上限秒数 (既定3600。応答不能時に打ち切り)
MAX_PARALLEL          # 並行数上限 (現運用は1=逐次。並行起動でエージェントが即死した実績あり)
WORKTREES_BASE        # worktree保存先 (~/worktrees)
CLAUDE_HARNESS_DIR    # ハーネスルート (~/.claude-harness)
SLACK_WEBHOOK_URL     # Slack通知先 (任意)
```

## ユーザの典型的なフロー（2026-09現在の運用）

1. 思いつきを `idea` ラベルでIssue化（/idea スキル、または土曜7:00の週次監査ジョブが自動起票）
2. やるものに `automation` ラベルを付ける（=発注。GitHubアプリから10秒）
3. Mac miniの launchd ジョブが 2:00 と 8〜22時の偶数時に `spawn-agents --pr` で実装しPR作成
   （自動マージはリポジトリ設定で不許可のため --pr 運用。PR本文の Closes #N でマージ時にIssueも閉じる）
4. 朝（または次の偶数時以降）PRをレビューして1クリックでマージ
5. `worktree-clean` で後片付け（任意）

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `claude native binary not installed` | Rosetta下のx64 Node | `/bin/zsh` でarm64シェルから入り直す |
| `error: unknown option '--headless'` | 古いCLI | `npm i -g @anthropic-ai/claude-code` |
| `model not found` | モデル名古い | `CLAUDE_MODEL` を更新 |
| `No commits between master and ...` | エージェントがコミットしていない | auto-commit hookを確認、または手動 `git -C <worktree> add -A && commit` |
| Issueの実装が出来ていない | プロンプトで止まった | ログ確認: `~/.claude-harness/logs/issue-*.log` |
| 1件処理後に残りIssueが打ち切られる | bash 3.2 + set -u の空配列展開エラー | 現行版は配列を使わないので発生しない。旧 `~/claude-harness` が残っていれば移行する |
| `-j` を付けるとCPUを焼く | bash 3.2 に `wait -n` が無い | 現行版は `harness_throttle` のポーリングで対処済み |
| safety-guard が何も止めない | 環境変数からコマンドを読む旧版 | `setup.sh` で入れ直す。`tests/run-tests.sh safety-guard` で確認 |
| エージェントが応答不能のまま並行枠を占有 | タイムアウト未設定 | `AGENT_TIMEOUT`（既定3600秒）。`-t 0` で無制限 |

## 関連スキル

- `tdd-ai-parallel` — テスト駆動の並列開発フロー
