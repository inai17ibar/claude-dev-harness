# shellcheck shell=bash
# discover.sh — 自律発見ジョブ (nightly/discover-run.sh) の判断ロジック。
#
# ネットワークにも claude にも触らない関数だけを置く。発見の質を左右する
# 「何を起票してよいか」「いつ LLM を呼ぶか」はここで決まるので、
# tests/run-tests.sh で fixture を当てて固定する。
#
# 制約: bash 3.2 互換 (lib/common.sh と同じ)。

# ---- ラベル ---------------------------------------------------------------
# 名前|色|説明。種別と優先度は「1 Issue に各1つ」を前提にしている。
# 増やすときは prompt の定義 (discover_prompt_rules) と backlog.sh の並び順も揃える。
discover_label_specs() {
  cat << 'EOF'
idea|FBCA04|思いつき置き場。選別して automation を付けると夜間ジョブが実装する
source:discover|5319E7|自律発見ジョブ (discover) が起票した
type:bug|D73A4A|不具合。いまの挙動が仕様・テスト・README に反している
type:feature|A2EEEF|新しい要件・機能
type:improvement|0E8A16|既存機能の改善 (UX・性能・保守性・エラー処理)
type:test|BFD4F2|テストの欠落・不足
type:docs|0075CA|ドキュメントの誤り・欠落
priority:p0|B60205|最優先。データ消失・セキュリティ・主要機能が使えない
priority:p1|D93F0B|高。主要機能の誤動作。回避策はあるが利用者が困る
priority:p2|FBCA04|中。小さな不具合や改善。手が空いたら
priority:p3|C2E0C6|低。あると良い
EOF
}

# 発見した1件に付けるラベル (カンマ区切り)
# 使い方: discover_labels_for <type> <priority>
discover_labels_for() {
  printf 'idea,source:discover,type:%s,priority:%s' "$1" "$2"
}

# ---- LLM 出力の検証 --------------------------------------------------------
# LLM の出力は「提案」でしかない。起票してよいものだけをここで通す。
#
# 使い方: discover_normalize <最大件数> <最低確度 high|medium|low>  < raw.json
#   入力は {"findings":[...]} か [...] のどちらでもよい。
#   出力は正規化済みの JSON 配列 (優先度 → 確度の順)。
#
# 落とすもの:
#   - 種別・優先度が定義外、タイトルか現象が空
#   - 確度が最低確度より低い
#   - 根拠 (ファイルパス) の無い bug。「たぶんバグ」は起票しない
# 直すもの:
#   - 確度 high でない p0 は p1 に下げる。p0 は通知が鳴るので誤報の代償が大きい
discover_normalize() {
  jq -c --argjson max "${1:-3}" --arg minc "${2:-medium}" '
    def s: if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end;
    def lc: s | ascii_downcase;
    def rank_p: {"p0":0,"p1":1,"p2":2,"p3":3}[.] // 9;
    def rank_c: {"high":0,"medium":1,"low":2}[.] // 9;

    (if type == "array" then .
     elif type == "object" then (.findings // [])
     else [] end)
    | map(select(type == "object"))
    | map({
        title:      (.title | s | .[0:80]),
        type:       (.type | lc),
        priority:   (.priority | lc),
        confidence: ((.confidence | lc) as $c | if $c == "" then "medium" else $c end),
        size:       ((.size | lc) as $z | if ($z == "s" or $z == "m" or $z == "l") then $z else "m" end),
        problem:    (.problem | s),
        why:        (.why | s),
        done_when:  (.done_when | s),
        evidence:   ([(.evidence // [])[]? | s | select(length > 0)] | .[0:5]),
        key:        (.key | lc | gsub("[^a-z0-9]+"; "-") | gsub("^-|-$"; "") | .[0:40])
      })
    | map(select(
        .title != "" and .problem != ""
        and (.type | IN("bug","feature","improvement","test","docs"))
        and (.priority | rank_p) < 9
        and (.confidence | rank_c) < 9
        and ((.confidence | rank_c) <= ($minc | rank_c))
        and (.type != "bug" or (.evidence | length) > 0)
      ))
    | map(if .priority == "p0" and .confidence != "high" then .priority = "p1" else . end)
    | sort_by([(.priority | rank_p), (.confidence | rank_c)])
    | .[0:$max]
  '
}

# claude -p --output-format json の出力から findings を取り出す。
# --json-schema が効いていれば .structured_output に入る。効かない版の CLI や
# スキーマを無視されたときのため、.result の本文から JSON を拾う経路も残す。
#
# 使い方: discover_extract_output < claude-output.json
discover_extract_output() {
  jq -c '
    if (.structured_output | type) == "object" then .structured_output
    elif (.result | type) == "string" then
      (.result | (try fromjson catch null)
        // (try (capture("(?s)(?<j>\\{.*\\})").j | fromjson) catch null)
        // {"findings": []})
    else {"findings": []} end
  '
}

# ---- 重複判定 --------------------------------------------------------------
# 同じ指摘を毎回起票しないための指紋。LLM がタイトルを言い換えても、
# 種別・キー・最初の根拠ファイルが同じなら同じ指摘とみなす。
# 行番号はコードが動くとずれるので落とす。
#
# 使い方: discover_fingerprint <type> <key> <最初の根拠>
discover_fingerprint() {
  local path=${3%%:*}
  printf '%s|%s|%s' "$1" "$2" "$path" | git hash-object --stdin | cut -c1-12
}

# Issue 本文に埋めた指紋を集める。入力は gh issue list --json body の配列。
discover_existing_fps() {
  jq -r '.[] | (.body // "") | scan("harness-discover fp=([0-9a-f]+)") | .[0]'
}

# ---- 本文 -----------------------------------------------------------------
# idea-triage が「流せる本文」として求める3節 (現象 / なぜ問題か / 完了の判定)
# と同じ形で書く。nightly のエージェントは本文だけを仕様として読むので、
# 起票した時点でそのまま automation を付けられる状態にしておく。
#
# 使い方: discover_render_body <fp> <mode> < finding.json
discover_render_body() {
  jq -r --arg fp "$1" --arg mode "$2" '
    "## 現象\n" + .problem + "\n\n"
    + "## なぜ問題か\n" + (if .why == "" then "(未記入)" else .why end) + "\n\n"
    + "## 完了の判定\n" + (if .done_when == "" then "(未記入。流す前に書くこと)" else .done_when end) + "\n\n"
    + "## 根拠\n"
    + (if (.evidence | length) == 0 then "(なし)"
       else (.evidence | map("- `" + . + "`") | join("\n")) end)
    + "\n\n---\n"
    + "<sub>🔍 discover (" + $mode + ") が起票 · 種別 " + .type + " · 優先度 " + .priority
    + " · 確度 " + .confidence + " · 規模 " + .size + "</sub>\n"
    + "<!-- harness-discover fp=" + $fp + " -->"
  '
}

# ---- いつ LLM を呼ぶか -----------------------------------------------------
# コストの大半は LLM 呼び出しなので、呼ぶかどうかを先に決める。
#
# 使い方: discover_decide_mode <now> <last_full> <last_sha> <head_sha> <full間隔(日)> <force_full> <新しい信号の数>
#   出力: full / incremental / skip
#     full        … 初回、--full、または前回の全体監査から間隔が空いた
#     incremental … 前回から HEAD が進んだか、新しい CI 失敗がある
#     skip        … 何も変わっていない。LLM を呼ばない
discover_decide_mode() {
  local now=$1 last_full=$2 last_sha=$3 head=$4 interval_days=$5 force=$6 signals=$7
  if [ "$force" = "true" ] || [ -z "$last_full" ] || [ -z "$last_sha" ]; then
    echo full
    return
  fi
  if [ $((now - last_full)) -ge $((interval_days * 86400)) ]; then
    echo full
    return
  fi
  if [ "$head" != "$last_sha" ] || [ "${signals:-0}" -gt 0 ]; then
    echo incremental
    return
  fi
  echo skip
}

# ---- 状態ファイル -----------------------------------------------------------
# key=value の素朴な形式。source すると中身次第で任意のコードが走るので、
# grep で読む。
#
# 使い方: discover_state_get <file> <key>
discover_state_get() {
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# 使い方: discover_state_put <file> <key> <value>
discover_state_put() {
  local file=$1 key=$2 val=$3 tmp
  tmp=$(mktemp)
  [ -f "$file" ] && grep -v "^$key=" "$file" > "$tmp" 2>/dev/null
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$file"
}
