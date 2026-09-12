---
name: tdd-ai-parallel
description: >
  テスト駆動AI並列開発ワークフロー。テストファイルが既にあって実装を書きたい時、
  または複数のIssueを並行で解決したい時に使う。Issueの実装、テスト通過、PR作成までを
  spawn-agentsコマンドで一気通貫で進める。「新機能を実装」「Issue を解決」
  「並列で開発」「TDDで実装」「複数機能を同時に開発」がトリガー。
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# テスト駆動AI並列開発

## 原則

「AIに明確なゴール判定（テスト）を与える」のが核心。テストが仕様書になる。
人間は設計とレビュー、AIは実装、ゴール判定はテスト。

## いつ使うか

- 既にテストファイルがあって実装を書く時
- 複数のIssueを並行で解決したい時
- リファクタや新機能で複数案を試したい時 (ccx-run併用)

## ワークフロー

### 単一機能の TDD

1. `git checkout -b feature/<機能名>`
2. テストファイルを書く (なければユーザに「先にテストを書きますか?」と聞く)
3. テストが失敗することを確認する: `npm test` / `pytest` / `cargo test`
4. 実装を書く
5. テストが通ることを確認
6. lint・型チェック: `npm run lint` / `ruff check` / `cargo clippy`
7. `git add -A && git commit -m "feat: <機能名>"`

### 複数Issueの並行解決

ハーネスの `spawn-agents` コマンドを使う:

```bash
# Issue #42, #51, #67 を並行で解決して PR まで作成
spawn-agents --merge 42 51 67

# Sonnetで高速バッチ (Opusレート制限回避)
spawn-agents --model claude-sonnet-5 -j 5 --merge 1 2 3 4 5

# tmuxで並行ログ確認
spawn-agents -m tmux 42 51 67
```

各Issueは `~/worktrees/<リポジトリ名>-issue-<番号>/` に独立した worktree が切られ、
ブランチは `agent/issue-<番号>-<timestamp>` で作成される。

### 探索的タスク (ccx-run)

設計案・リファクタなど「複数解がありうる」タスクは ccx-run でN回試して採用:

```bash
# Opusで3回試して比較
ccx-run -n 3 "認証フローを設計して実装して"

# テスト通過を採用条件にする
ccx-run --test "npm test" -n 3 "UserServiceをリファクタ"
```

## 並列度の判断

| 状況 | 並列OK | 並列NG |
|---|---|---|
| 異なるファイルを触る | ✅ | |
| 同じファイルを別関数で触る | ✅ (慎重に) | |
| 同じ関数を触る |  | ❌ 直列化 |
| DBスキーマ変更 |  | ❌ 直列化 |
| 共有型定義の変更 |  | ❌ 事前合意 |

## 良いテストの条件

- 入出力が型と値で明確に定義されている
- モックで外部依存を切る (DB, API, ファイルシステム)
- 正常系・異常系・境界値・エッジケースを網羅
- `npm test` 1コマンドで実行できる

詳細なテストパターン例は `references/test-templates.md` 参照。

## エージェントへの実装指示テンプレート

spawn-agents は自動で良いプロンプトを組み立てるが、手動で claude を呼ぶ場合は:

```
<テストファイルパス> の全テストが pass するまで実装してください。

テスト実行: <テスト実行コマンド>
既存テストも壊さないこと。
完了したら git add -A && git commit -m "fix: ..." を必ず実行してください。
最後に "COMPLETED" と出力してください。
```

## トラブルシュート

| 症状 | 対処 |
|---|---|
| エージェントが質問してくる | `--dangerously-skip-permissions` 付与 |
| 実装してもコミットしない | プロンプトに「必ずコミット」明記、Stop hookで auto-commit |
| テスト通っても品質低い | テスト要件に lint・型チェック追加 |
| 並行でコンフリクト | 共有ファイルの変更タスクは直列化 |
| Opusでレート制限 | `-j 2` で並行数を下げる、または `--model claude-sonnet-5` |

## ハーネスとの統合

このスキルは Claude Dev Harness と連携する:
- `spawn-agents` — 並行Issue解決
- `ccx-run` — N回実行→ベスト選択
- `worktree-clean` — マージ済みクリーンアップ
- Hooks: 自動コミット (`auto-commit.sh`), 通知 (`on-stop.sh`), lint (`post-write.sh`)
