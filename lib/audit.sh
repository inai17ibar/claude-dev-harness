# shellcheck shell=bash
# audit.sh — weekly-audit.sh が使う関数。テストから直接呼べるよう、副作用のない
# ものはここに置く。/bin/bash 3.2 で動くこと (declare -A や mapfile は使わない)。

# 既定の観点。週ごとに1つずつ順番に回す。
# 同じ観点で毎週見ると、同じ種類の Issue ばかりが出て、見ていない観点は永久に
# 見ないままになる (sTune では 34 件中セキュリティが 0 件だった)。
# shellcheck disable=SC2034  # weekly-audit.sh とテストが読む
AUDIT_DEFAULT_LENSES="data-integrity error-surfacing security scale promises tests"

# audit_pick_lens <週番号> <観点...>
# 週番号から観点を1つ選ぶ。週番号は date +%V の "08" のような0埋めを受け付ける
# (そのまま算術に渡すと 8 進数として解釈されて落ちる)。
audit_pick_lens() {
  local week="$1"
  shift
  [ $# -gt 0 ] || return 1
  case "$week" in
    ''|*[!0-9]*) return 1 ;;
  esac
  week=$((10#$week))
  local idx=$((week % $#))
  shift "$idx"
  printf '%s\n' "$1"
}

# audit_lens_brief <観点>
# 観点ごとに「何を探すか」をプロンプトに差し込む文章で返す。知らない観点は失敗。
audit_lens_brief() {
  case "$1" in
    data-integrity) cat <<'EOF'
【今週の観点: データ消失・整合性】
ユーザーのデータ（DB・設定ファイル・ユーザーのファイル・外部デバイス上のファイル）が
消える、壊れる、食い違う経路を探す。
- 削除・上書き・再スキャン・同期・移行の処理で、前提が崩れたとき（ドライブ未接続、
  読み取れないフォルダ、同名ファイル、空のDB）に何が起きるか
- 書き込みの途中で失敗したときの後始末（書きかけのファイル、半端な状態のDB）
- 確認なしで実行される破壊的な操作
EOF
      ;;
    error-surfacing) cat <<'EOF'
【今週の観点: 失敗の握りつぶし】
失敗したのにユーザーには成功に見える、または何も起きないように見える経路を探す。
- 戻り値の null / false / 例外が無視され「成功」と報告される箇所
- 部分的な成功を全体の成功として扱う箇所
- エラーがコンソールやログにしか出ず、画面に出ない箇所
- catch して黙って既定値にフォールバックし、次の保存で元データを失う箇所
EOF
      ;;
    security) cat <<'EOF'
【今週の観点: セキュリティ・信頼境界】
信頼できない入力が、権限のある処理に届く経路を探す。
- Electron: preload / contextBridge が公開しているAPIの範囲、カスタムプロトコルの
  パス検証、外部URLや新規ウィンドウを開く処理、webPreferences の設定
- 子プロセス・シェルに渡す引数の組み立て（ファイル名・ボリューム名・曲名など
  外部由来の文字列）
- パストラバーサル、権限外のファイル読み書き
- 依存パッケージやランタイムのサポート切れ・既知の脆弱性
実際に悪用できる経路を具体的に示せるものだけを起票する。一般論の注意喚起は起票しない。
EOF
      ;;
    scale) cat <<'EOF'
【今週の観点: 規模・性能】
データが今の100倍になったとき（曲数・ファイル数・Issue数など）に破綻する箇所を探す。
- 全件をメモリに載せる、全件をプロセス間で送る、全件を毎回再計算する処理
- UIスレッド・メインプロセスを止める同期I/O
- 件数に比例して子プロセスやタイマーを起動する処理
- 進捗が出ず固まって見える長時間処理
どの規模で、何が、どのくらい遅く／重くなるかを根拠つきで書く。
EOF
      ;;
    promises) cat <<'EOF'
【今週の観点: 約束と実装のずれ】
README・UI文言・型定義・IPC/APIが約束しているのに、実装されていない、または
途中で配線が切れている機能を探す。
- 下位層（DB・IPC・API）まで実装済みなのに、UIから使えない機能
- ボタンや案内文があるのに、到達しない・動かない分岐
- TODO / FIXME / HACK コメントのうち、ユーザーに影響が出ているもの
EOF
      ;;
    tests) cat <<'EOF'
【今週の観点: テストの穴】
壊れても気づけない場所を探す。
- テストが1本も無い重要モジュール（データを書き換える処理を優先）
- 書かれているのにCIで実行されていないテスト
- テスト基盤の制約で、そもそもテストが書けない領域
「テストが無い」だけでなく、その箇所で過去に起きた／起きうる不具合を根拠に書く。
EOF
      ;;
    *) return 1 ;;
  esac
}

# audit_date_days_ago <日数>
# N日前の日付を YYYY-MM-DD で返す。BSD date (macOS) と GNU date の両方に対応。
audit_date_days_ago() {
  local days="$1"
  date -u -v-"${days}"d '+%Y-%m-%d' 2>/dev/null \
    || date -u -d "${days} days ago" '+%Y-%m-%d'
}

# audit_now_iso
# gh の検索クエリ (created:>=...) に渡せる UTC 時刻。
audit_now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# audit_known_titles <owner/repo> [日数]
# 重複チェックに使う既知のタイトル一覧を返す。
# 開いている Issue だけを見ていると、直近に直して閉じたものや、PR が出ている
# 最中のものを再起票してしまう。そこで次の3つをまとめて返す。
#   - Open な Issue
#   - 直近 N 日 (既定 90) に閉じた Issue
#   - Open な PR
audit_known_titles() {
  local repo="$1" days="${2:-90}" since
  since=$(audit_date_days_ago "$days")
  {
    gh issue list --repo "$repo" --state open --limit 200 \
      --json number,title -q '.[] | "#\(.number) \(.title)"' 2>/dev/null
    gh issue list --repo "$repo" --state closed --limit 200 \
      --search "closed:>=$since" \
      --json number,title -q '.[] | "#\(.number) [closed] \(.title)"' 2>/dev/null
    gh pr list --repo "$repo" --state open --limit 100 \
      --json number,title -q '.[] | "PR#\(.number) \(.title)"' 2>/dev/null
  } | sort -u
}
