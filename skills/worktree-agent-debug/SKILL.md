---
name: worktree-agent-debug
description: |
  Claude Dev Harness（spawn-agents / worktree / MCP stdio）で詰まったときのトラブルシュート。
  「claude native binary not installed」「arm64」「x64」「Rosetta」「cd: No such file」
  「stdout汚染」「console.log」「model not found」「404 not_found_error」「launchd」
  「CLAUDE_MODEL」「モデル名」などのキーワードが出たら必ず参照すること。
  harness が動かない・エージェントがクラッシュする・モデルエラーが出る場面で使う。
---

# Harness / Worktree Agent デバッグ

実際に踏んだ3つの問題と、その根本原因・診断・修復・予防策。
「エラーメッセージから推測する」のではなく「正常状態を診断するコマンド」から入ること。

---

## 問題1: `claude native binary not installed` — arm64/x64 混在

### 症状

```
Error: claude native binary not installed.
[@anthropic-ai/claude-code postinstall] Native package "@anthropic-ai/claude-code-darwin-arm64" not found.
  You are running x64 Node under Rosetta 2 on Apple Silicon.
```

`npm i -g @anthropic-ai/claude-code` で再インストールしても直らない。

### 診断コマンド（まずこれ）

```bash
uname -m                              # → arm64 のはず
node -e "console.log(process.arch)"  # → ここが x64 なら問題
file $(which zsh)                     # → x86_64 が含まれていたら原因確定
file $(which node)                    # → 同上
```

`uname -m` が arm64 なのに `node` が x64 → 連鎖の始まりが `/usr/local/bin/zsh`（x64）。

### 根本原因

**「Rosettaが動いていた」のではなく「ユーザー空間のzshバイナリがx64だった」。**

```
/usr/local/bin/zsh  (x64 ← 昔のIntel Homebrew残骸)
  └→ node (x64、nvmがx64 zshの下でインストール)
      └→ npm install → x64バイナリのみダウンロード
          └→ arm64バイナリが存在しないので postinstall 失敗
```

PATHで `/usr/local/bin` が `/bin` より先にあると、x64版 zsh が優先される。
macOSデフォルトの `/bin/zsh` は arm64 だが、それより前のPATHエントリが勝ってしまう。

### 修復手順

```bash
# 1. arm64シェルに切り替えて再インストール
arch -arm64 zsh -c "nvm install --lts && npm i -g @anthropic-ai/claude-code"

# 2. 確認
node -e "console.log(process.arch)"  # → arm64

# 3. claude が使えるか
claude --version
```

### 予防策

```bash
# ~/.zshrc の PATH 設定を確認
# /usr/local/bin より /opt/homebrew/bin (arm64 Homebrew) を優先させる
echo $PATH | tr ':' '\n' | head -10
```

`/usr/local/bin/zsh` が `arm64` になっているか、または PATH から除外されていれば再発しない。
Intel時代のHomebrewが `/usr/local/` に残存している場合、nodeやzshの古いx64版を消すか、PATHの順序を直す。

---

## 問題2: stdout汚染 — bash関数の返り値がログで汚れる

### 症状

```
/usr/local/bin/spawn-agents: line 148: cd: HEAD is now at f6ec98c chore: add ...: No such file or directory
```

`cd` の引数に git のログメッセージが混入している。

### 根本原因

bash の **コマンド置換 `$(...)`** は、関数内の **stdout に出たすべての文字列** をキャプチャする。

```bash
# この書き方は create_worktree のstdout全部を worktree_path に入れる
worktree_path=$(create_worktree "$issue")
```

`create_worktree` 内に以下が混在していると壊れる:

```bash
log "✅ Worktree作成: ..."   # log() が echo を使っていると → stdout → キャプチャされる
git worktree add ...          # git 自体も stdout に "Preparing worktree..." を出す
echo "$path"                  # ← 本来キャプチャされるべき値
```

結果、`worktree_path` の中身がこうなる:

```
[09:42:24] 既存worktreeを削除: /Users/.../issue-1
Preparing worktree (new branch 'agent/issue-1-...')
HEAD is now at f6ec98c chore: ...
/Users/.../worktrees/<リポジトリ名>-issue-1     ← 本来の値はここだけのはず
```

### 修復パターン

```bash
# ❌ 壊れる
log() { echo "[$(date +%H:%M:%S)] $*"; }
create_worktree() {
  log "作成中..."
  git worktree add "$path" -b "$branch"
  echo "$path"
}

# ✅ 正しい
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }   # 必ず >&2
create_worktree() {
  log "作成中..."
  git worktree add "$path" -b "$branch" >&2     # git の出力もstderrへ
  printf '%s' "$path"                            # 純粋な値のみstdoutへ
}
```

**鉄則**: `$(...)` でキャプチャされる関数は、返り値の `echo`/`printf` 以外を全て `>&2` に逃がす。

### MCPサーバーでの同じ罠

MCP stdio サーバーは stdout が JSON-RPC の通信路。`console.log` を1つでも書くとプロトコルが壊れて `Unexpected token` でクラッシュする。

```typescript
// ❌ プロトコル破壊
console.log("debug:", value);

// ✅ 常にstderr
const log = (...args: unknown[]) => console.error("[server]", ...args);
```

同じ「stdout は通信路、ログは stderr」という原則が bash と MCP で共通している。

### 診断方法

`$()` の中身が壊れていると疑ったら一時的に展開して確認:

```bash
# $() を直接 echo で展開して中身を見る
echo "---START---"
create_worktree "$issue"
echo "---END---"
```

複数行が出てきたら stdout 汚染が確定。

---

## 問題3: `model not found` — モデル名変更 / launchd 環境変数

### 症状

```
API Error: 404 {"type":"error","error":{"type":"not_found_error","message":"model: claude-opus-4-20250514"}}
```

silent フォールバックはない。必ず 404 が返る（これはありがたい仕様）。

### 設定の散在場所（4箇所すべて更新が必要）

> 3. と 4. は Mac mini 側の常設ジョブの設定。MBP には存在しない。
> 1. は `setup.sh` が管理するブロック（`# >>> claude-dev-harness >>>`）を直す。

```bash
# 1. 対話シェル用
grep "CLAUDE_MODEL" ~/.zshrc

# 2. spawn-agentsのフォールバック値
grep "CLAUDE_MODEL:-" /usr/local/bin/spawn-agents

# 3. launchd plist（シェルの環境変数を継承しないので独立設定が必要）
plutil -p ~/Library/LaunchAgents/com.harness.nightly.plist | grep -A1 CLAUDE_MODEL

# 4. nightly config（launchd経由実行時はこれが優先）
grep "^MODEL=" ~/.claude-harness/nightly/config.sh
```

優先順位（高い順）:

```
config.sh の MODEL=              ← nightly実行時はここが最優先
  ↓ なければ
plist の EnvironmentVariables   ← launchd起動ジョブはここを見る
  ↓ なければ
~/.zshrc の export CLAUDE_MODEL ← 対話実行時
  ↓ なければ
spawn-agents 内のデフォルト値
```

**見落としやすい罠**: `~/.zshrc` だけ直しても launchd ジョブには反映されない。launchd は起動時の環境を固定するので、plist を更新して `launchctl unload && launchctl load` しないと反映されない。

### 一括確認コマンド

```bash
echo "=== 全CLAUDE_MODEL設定 ==="
echo "zshrc:        $(grep 'CLAUDE_MODEL' ~/.zshrc | grep -v '^#' | head -1)"
echo "spawn-agents: $(grep 'CLAUDE_MODEL:-' /usr/local/bin/spawn-agents | head -1)"
echo "plist:        $(plutil -p ~/Library/LaunchAgents/com.harness.nightly.plist 2>/dev/null | grep -A1 CLAUDE_MODEL | tail -1)"
echo "config.sh:    $(grep '^MODEL=' ~/.claude-harness/nightly/config.sh 2>/dev/null | head -1)"
echo "現在のシェル:  $CLAUDE_MODEL"
```

### 修復手順

```bash
# 1. 新しいモデル名を確認（Claude Codeのデフォルトを参考に）
claude --version

# 2. 全4箇所を更新
NEW_MODEL="claude-sonnet-4-6"   # 例

sed -i '' "s/CLAUDE_MODEL=.*/CLAUDE_MODEL=$NEW_MODEL/" ~/.zshrc
# spawn-agents は管理者権限が必要なら sudo
# plist は plutil または手動編集
# config.sh は直接編集

# 3. launchdジョブを再読み込み
launchctl unload ~/Library/LaunchAgents/com.harness.nightly.plist
launchctl load   ~/Library/LaunchAgents/com.harness.nightly.plist
```

---

## 共通の診断フロー

harness が動かないときは以下の順で確認する:

```bash
# Step 1: Nodeのアーキ確認
node -e "console.log(process.arch)"   # arm64 でなければ問題1へ

# Step 2: モデル名の一致確認（上記の一括確認コマンド）

# Step 3: worktreeの状態確認
git worktree list

# Step 4: 最新ログを確認
ls -lt ~/.claude-harness/logs/*.log | head -5
tail -50 ~/.claude-harness/logs/$(ls -t ~/.claude-harness/logs/*.log | head -1)
```

stdout汚染は Step 4 のログを見て「cdの引数にパス以外が混入している」で気づく。
