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

# ---- discover (課題・要件の自律発見) ----------------------------------------
# 毎日 6:40 に走り、見つけたものを idea Issue として起票する (実装はしない)。
# 種別 type:* と優先度 priority:* のラベルを付ける。詳しくは docs/discover.md
#
# 対象。未設定なら上の REPOS を使う
# DISCOVER_REPOS=( "inai17ibar/harness-test" )

# 毎日回すので軽いモデル。エイリアスなら世代交代で 404 にならない
DISCOVER_MODEL="sonnet"

# 1リポジトリ1回あたりの起票上限。選別する人の手が回る量にする
DISCOVER_MAX_ISSUES=3

# これより確度の低い提案は捨てる (high / medium / low)
DISCOVER_MIN_CONFIDENCE="medium"

# 全体監査の間隔 (日)。間の日は前回からの差分と新しい CI 失敗だけを見る。
# 何も変わっていなければ LLM を呼ばない
DISCOVER_FULL_INTERVAL_DAYS=7

# 未選別の idea (automation 無し) がこの件数以上なら LLM を呼ばない。
# 選別が追いついていないのに足しても読まれず、コストだけかかる
DISCOVER_BACKLOG_LIMIT=15

# 1リポジトリの上限秒数
DISCOVER_TIMEOUT=1200

# API キー課金で動かすときの1回あたり上限 (USD)。サブスクリプションなら空でよい
DISCOVER_MAX_BUDGET_USD=""

# true にすると「確度 high・規模 s の p0/p1 bug」にだけ automation も付け、
# 選別を待たずに夜間ジョブへ流す。誤検知がそのまま PR になるので、
# 起票の質を何週か見てから有効にすること
DISCOVER_AUTO_PROMOTE=false
