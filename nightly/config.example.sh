# shellcheck shell=bash
# shellcheck disable=SC2034  # nightly-run.sh に source されて使われる
# Nightly Harness 設定のサンプル。
#   cp nightly/config.example.sh ~/.claude-harness/nightly/config.sh
# して編集する。実際の設定はマシンごとに違うのでリポジトリには入れない。

# 対象リポジトリ (owner/repo)。配列でも空白区切り文字列でもよい。
REPOS=(
  # "inai17ibar/vlog-cockpit"
  # "inai17ibar/stune"
)

# このラベルが付いた Open Issue だけを対象にする
LABEL_FILTER="automation"

# 1リポジトリあたりの最大 Issue 数
MAX_ISSUES_PER_REPO=3

# 並行数。同時起動でエージェントが落ちるようなら 1 に下げる
MAX_PARALLEL=1

# モデル。省略すると $CLAUDE_MODEL (既定 claude-opus-5)
MODEL="claude-opus-5"

# ノート PC で電源未接続のときの最低バッテリー残量 (%)。Mac mini では実質無視される
MIN_BATTERY=30

# リポジトリを clone/更新する場所
REPOS_DIR="$HOME/repos"

# true なら spawn-agents を実際には呼ばない
DRY_RUN=false

# Slack 通知。plist には書かない。ここか $CLAUDE_HARNESS_DIR/env.sh に置く
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
