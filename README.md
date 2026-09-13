# Claude Dev Harness

GitHub Issue を Claude Code のエージェントに並行で解かせるための、macOS 向けシェルハーネス。

Issue 番号を渡すと、リポジトリごとに独立した git worktree を切り、そこでエージェントを走らせ、
コミットから PR 作成・自動マージまで通します。同じタスクを N 回試して一番良い結果を選ぶ
`ccx-run`、実行状況を見るダッシュボード、Claude Code の hooks によるライフサイクル制御が付属します。

```bash
spawn-agents --pr 42 51 67     # 3つの Issue を並行で実装して PR を作る
ccx-run -n 3 "認証フローを設計して"  # 3案作らせて比較・採用
worktree-clean                 # マージ済みの worktree を片付ける
harness-dashboard              # http://localhost:8765 で状況を見る
```

## 動作要件

| | |
|---|---|
| OS | macOS (Linux でも CLI は動くが、通知まわりは macOS 前提) |
| シェル | **bash 3.2 で動きます**。macOS 標準の `/bin/bash` のままで構いません |
| 必須 | `git` `gh` `jq` `node` `python3` |
| 任意 | `tmux` (`-m tmux`)、`shellcheck` (開発時) |
| その他 | `claude` CLI が認証済みであること (`gh auth login` も) |

> bash 4+ 専用の機能 (`wait -n`, 連想配列, `mapfile`) は使っていません。
> Homebrew の bash を入れる必要はありません。むしろ `/usr/local/bin` に x86_64 版が
> 残っている環境では [トラブルシュート](#トラブルシュート) の問題を踏みます。

## インストール

```bash
git clone https://github.com/inai17ibar/claude-dev-harness.git ~/src/claude-dev-harness
cd ~/src/claude-dev-harness
./setup.sh
source ~/.zshrc
```

`setup.sh` は冪等です。更新したいときは `git pull && ./setup.sh` で構いません。

やること:

1. `~/.claude-harness/` にログ・状態のディレクトリを作る
2. `bin/*.sh` を `/usr/local/bin`（無ければ `~/.local/bin`）にシンボリックリンク
3. `~/.claude/settings.json` に hooks を**マージ**する（既存の設定は残す）
4. `skills/` を `~/.claude/skills/` に配置
5. `~/.zshrc` の環境変数ブロックを更新する

```bash
./setup.sh --dry-run     # 何をするか見るだけ
./setup.sh --skip-zshrc  # ~/.zshrc を触らない
./setup.sh --uninstall   # リンク・hooks 設定・zshrc ブロックを外す（ログは残す）
```

hooks と CLI は**このリポジトリを直接指します**。コピーではないので、`git pull` すれば
そのまま反映されます。

## コマンド

### spawn-agents — 複数 Issue を並行で解く

```bash
spawn-agents 42 51 67                          # 並行で実装（PR は作らない）
spawn-agents --pr 42 51 67                     # PR 作成まで
spawn-agents --merge 42 51 67                  # PR + 自動マージ（CI 通過後）
spawn-agents --model claude-sonnet-5 -j 5 --pr 1 2 3 4 5
spawn-agents -m tmux 42 51                     # tmux で各エージェントのログを見ながら
spawn-agents --dry-run 42 51                   # 実行計画だけ
```

| オプション | 説明 |
|---|---|
| `-m, --mode` | `parallel`(既定) / `tmux` / `sequential` |
| `-j, --jobs N` | 並行数の上限（既定 3）。Issue が多くてもこの数ずつバッチ実行 |
| `-p, --pr` | 完了後に PR を作る |
| `--merge` | `--pr` + 自動マージ。`--auto` が使えなければ即マージにフォールバック |
| `--admin` | ブランチ保護を bypass して強制マージ |
| `--model` | モデル（既定 `claude-opus-5`） |
| `-b, --base` | ベースブランチ（既定はリポジトリの既定ブランチ） |
| `-t, --timeout` | 1エージェントの上限秒数（既定 3600、`0` で無制限） |
| `-f, --force` | 未マージ PR がある Issue も再実装する |
| `-d, --dry-run` | 実行計画だけ表示 |

**worktree の置き場所**は `$WORKTREES_BASE/<リポジトリ名>-issue-<番号>/` です。
リポジトリ名を含めるのは、別リポジトリの同じ番号の Issue と衝突させないため。
ブランチは `agent/issue-<番号>-<timestamp>`。

**既に未マージの PR がある Issue はスキップ**します（`--force` で上書き）。
launchd などで定期的に回したときに、同じ Issue を何度も実装し直さないためです。

**タイムアウト**した場合もそこまでのコミットがあれば PR を作ります。ログ末尾には
`AGENT_DONE:<番号>` または `AGENT_TIMEOUT:<番号>` が入ります（ダッシュボードの成功判定に使用）。

### ccx-run — N 回実行してベストを選ぶ

```bash
ccx-run -n 3 "UserService をリファクタして"
ccx-run -t exact --test "npm test" "Issue #42 を修正して"
ccx-run -n 5 --test "npm test" --auto-pick "フレーキーなテストを直して"
```

`explore`（既定, 3回）と `exact`（1回）の2種類。`--test` を渡すと各試行でテストを走らせて
結果を並べます。`--pick N` / `--auto-pick` で対話なしに採用でき、採用した試行は
現在のブランチに cherry-pick されます。

### worktree-clean — 後片付け

```bash
worktree-clean --dry-run    # 削除対象を見るだけ
worktree-clean              # マージ済みブランチと worktree を削除
worktree-clean --all-repos  # 他リポジトリの残骸も対象にする
```

`$WORKTREES_BASE` は全リポジトリで共有されるため、**既定では自分のリポジトリ名で始まる
ディレクトリしか触りません**。`--all-repos` を付けても、他のリポジトリに現役登録されている
worktree はスキップします。

### nightly / weekly-audit — 常時稼働マシンでの自律運用

常時起動しているマシン (Mac mini など) に launchd で登録すると、`automation` ラベルの付いた
Issue を自動で実装し PR を作ります。ノート PC には入れないでください
(蓋を閉じている間は走らず、起きた瞬間にまとめて走ります)。

```bash
cp nightly/config.example.sh ~/.claude-harness/nightly/config.sh
vi ~/.claude-harness/nightly/config.sh   # REPOS を書く
./launchd/install.sh --dry-run           # 生成される plist を確認
./launchd/install.sh
```

| ジョブ | スケジュール | 動作 |
|---|---|---|
| `com.harness.nightly` | 2:00 と 8〜22時の偶数時 | `automation` ラベルの Issue を `spawn-agents --pr` で実装 |
| `com.harness.weekly-audit` | 土 7:00 | コードベースを監査して `idea` ラベルの Issue を起票するだけ (実装はしない) |

想定している回し方は「`idea` で溜める → 人間が選んで `automation` を付ける → 夜間に実装されて
PR が立つ → 朝レビューしてマージ」です。

集計は `spawn-agents` が出す `HARNESS_EVENT:` マーカーを数えます。ログの日本語文言を
grep する作りだと、文言を1文字直した瞬間に黙って 0 件と報告されるためです。

```
HARNESS_EVENT:agent_done issue=42
HARNESS_EVENT:skipped issue=35 pr=42 reason=open_pr
HARNESS_EVENT:pr_created issue=42 url=https://github.com/...
HARNESS_EVENT:merge_scheduled issue=42 pr=48
```

`SLACK_WEBHOOK_URL` などの秘密は plist に焼かず、`~/.claude-harness/env.sh` か
nightly の `config.sh` に置きます (plist に埋めると生成時のシェルの値が固定化します)。

```bash
launchctl kickstart -p gui/$(id -u)/com.harness.nightly   # 手動で1回走らせる
tail -f ~/.claude-harness/nightly/launchd-stdout.log
./launchd/install.sh --uninstall                          # 解除
```

### harness-dashboard / harness-collect-metrics — 観測

```bash
harness-dashboard              # http://localhost:8765
harness-collect-metrics | jq . # JSON で取得
harness-collect-metrics | jq .summary.success_rate
```

## Hooks

`setup.sh` が `~/.claude/settings.json` に登録します。

| hook | タイミング | 動作 |
|---|---|---|
| `post-write.sh` | Write/Edit の後 | Prettier / ESLint / ruff / gofmt / rustfmt / shfmt。**プロジェクトに入っているものだけ**使う（`npx --no-install`） |
| `safety-guard.sh` | Bash 実行前 | 破壊的コマンドをブロック（終了コード 2） |
| `on-stop.sh` | セッション終了時 | 自動コミット → ログ → Slack / macOS 通知 |
| `auto-commit.sh` | 同上（on-stop から） | `agent/issue-*` `ccx/trial-*` ブランチの未コミット変更を拾う |
| `session-start.sh` | セッション開始時 | ブランチ・担当 Issue 本文をコンテキストに注入 |

フック入力は **標準入力の JSON** から読みます（`.tool_input.command` など）。
`CLAUDE_TOOL_INPUT_*` のような環境変数は渡ってこないので、そこを読んでいる実装は
黙って何もしません。

### safety-guard のカスタマイズ

`rm -rf /tmp/build` や `rm -rf node_modules` のような正当なコマンドを止めないよう、
パターンは削除対象を最後まで見て判定します。`tests/run-tests.sh` に
「止めるべき」「通すべき」の両方のケースを置いてあります。

追加・除外はファイルで足せます（1行1正規表現、`#` でコメント）。

```bash
~/.claude-harness/safety-allow.txt   # 合致したら常に許可（最優先）
~/.claude-harness/safety-block.txt   # 追加でブロック
```

## 環境変数

`setup.sh` が `~/.zshrc` に `# >>> claude-dev-harness >>>` で囲んだブロックとして書きます。
手で足さないでください（同じ export が何度も積まれる事故が起きます）。

| 変数 | 既定 | 説明 |
|---|---|---|
| `CLAUDE_MODEL` | `claude-opus-5` | `spawn-agents` / `ccx-run` の既定モデル |
| `MAX_PARALLEL` | `3` | 並行数の上限 |
| `AGENT_TIMEOUT` | `3600` | 1エージェントの上限秒数。`0` で無制限 |
| `WORKTREES_BASE` | `~/worktrees` | worktree の置き場 |
| `CLAUDE_HARNESS_DIR` | `~/.claude-harness` | ログ・状態の置き場 |
| `SLACK_WEBHOOK_URL` | （未設定） | 設定したときだけ Slack に通知する |

## ディレクトリ構成

```
claude-dev-harness/          # このリポジトリ = 唯一の正
  bin/                       # CLI 本体（/usr/local/bin から symlink）
  lib/common.sh              # 共通ユーティリティ（bash 3.2 互換）
  lib/hook-input.sh          # フックの stdin JSON を読む
  hooks/                     # Claude Code の hooks
  skills/                    # ~/.claude/skills へ配置されるスキル
  nightly/                   # 常時稼働マシン用のオーケストレーター
  launchd/                   # plist テンプレートと登録スクリプト
  web/index.html             # ダッシュボード
  tests/run-tests.sh         # 依存なしの自己テスト
  setup.sh

~/.claude-harness/           # 実行時の状態（git 管理外）
  logs/                      # issue-*.log, ccx/, sessions.log, auto-commit.log
  dashboard/                 # web/ から配られる静的ファイル
  nightly/config.sh          # nightly の設定 (マシンごとに違うので git 管理外)
  env.sh                     # launchd 用の秘密 (任意)
  safety-allow.txt           # 任意
  safety-block.txt           # 任意

~/worktrees/                 # $WORKTREES_BASE
  <repo>-issue-<N>/
  <repo>-ccx-<N>-<timestamp>/
```

## 開発

```bash
tests/run-tests.sh                    # 全部
tests/run-tests.sh safety-guard       # 名前で絞る
shellcheck -x -S warning setup.sh lib/*.sh hooks/*.sh bin/*.sh tests/*.sh
```

CI は ubuntu（shellcheck + テスト + `setup.sh --dry-run`）と
macOS（`/bin/bash` = 3.2 でテスト）の2本です。

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `model not found` / 404 | `CLAUDE_MODEL` が古い | `~/.zshrc` のブロックを `setup.sh` で更新。現行は `claude-opus-5` |
| `claude native binary not installed` | Rosetta 下の x64 Node | arm64 のシェルから入り直す。`/usr/local/bin/zsh` が x64 だと踏む |
| 1件処理したら残りが打ち切られる | bash 3.2 + `set -u` の空配列展開 | 本ハーネスは配列を避けているので発生しません。旧版から移行してください |
| `-j` を付けると CPU を焼く | bash 3.2 に `wait -n` が無く、`\|\| true` で握り潰すとビジーループになる | 同上。`harness_throttle` はポーリング + `sleep` |
| 自動マージが効かない | `gh pr merge --auto` は保護ブランチ設定が要る | `--merge` は失敗時に即マージへフォールバックします。それも不可なら `--admin` |
| 全 Issue がスキップされる | `gh pr list --search "linked:issue-N"` は番号を付けると全文検索に落ち、無関係な PR まで拾う | 判定はブランチ名 `agent/issue-N-` の前方一致で行う。`tests/run-tests.sh open-pr` |
| nightly の集計が常に 0 | ログの日本語文言を grep していた | `HARNESS_EVENT:` マーカーを数える |
| safety-guard が何も止めない | 環境変数からコマンドを読もうとしている旧版 | `setup.sh` で hooks を入れ直す。`tests/run-tests.sh safety-guard` で確認 |
| Slack 通知が来ない | `SLACK_WEBHOOK_URL` がプレースホルダのまま | 未設定なら送信自体をスキップします。実 URL を入れてください |

## ライセンス

MIT
