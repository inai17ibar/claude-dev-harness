# discover — 課題と要件の自律発見

リポジトリを定期的に調べ、まだ Issue になっていない「課題」と「新しい要件」を見つけて、
種別・優先度のラベル付きで `idea` Issue に起票する仕組み。**実装はしない。**
旧 `weekly-audit` を置き換える。

```
                 ┌──────────── discover (毎日 6:40) ────────────┐
 コード / CI ──▶ │ 収集 ─▶ 判定 ─▶ 分析 (LLM) ─▶ 検証 ─▶ 起票 │ ──▶ idea Issue
                 │ shell   shell   読み取り専用    shell   shell │     type:* priority:*
                 └──────────────────────────────────────────────┘
                                                                      │
             朝: idea-triage / レビュー画面で選ぶ ─▶ automation ─▶ nightly が実装 ─▶ PR
```

## 方針

### 1. LLM は「提案」だけ。起票はシェルが決める

旧 weekly-audit は LLM に `gh issue create` を直接打たせていた。これだと
ラベルの付け方・件数・重複判定がすべて LLM の気分次第になり、守りたい規則を
プロンプトでお願いするしかない。

discover では LLM に `--json-schema` で構造化された提案を返させ、
シェルが次を**決定的に**行う (`lib/discover.sh`):

| 規則 | 理由 |
|---|---|
| 種別・優先度が定義外なら捨てる | ラベルが増殖すると絞り込みに使えなくなる |
| 確度が `DISCOVER_MIN_CONFIDENCE` 未満なら捨てる | 誤検知の起票は、本物の指摘を埋もれさせる |
| 根拠 (path:line) の無い bug は捨てる | 「たぶんバグ」は確かめる手間を人に押し付けるだけ |
| 確度 high でない p0 は p1 に下げる | p0 は通知が鳴る。誤報の代償が大きい |
| 指紋が既存 Issue (open/closed) と一致したら捨てる | 言い換えによる再起票を防ぐ |
| 起票は `DISCOVER_MAX_ISSUES` 件まで (重複除去の**後**で数える) | 選別する人の手が回る量に抑える |

LLM に許すツールは `Read, Grep, Glob, git log/diff/show, ls` だけ。
終わったあと作業ツリーが変わっていれば `git stash` に退避する。

### 2. ラベル体系

1 Issue に「種別1つ + 優先度1つ」を付ける。ラベルは初回起票時に自動で作られる。

| ラベル | 意味 |
|---|---|
| `type:bug` | いまの挙動が仕様・テスト・README に反している (根拠必須) |
| `type:feature` | 新しい要件。プロダクトの文脈が裏付けるものだけ |
| `type:improvement` | 既存機能の改善 (エラー処理・性能・UX・保守性) |
| `type:test` | テストの欠落・境界条件の抜け |
| `type:docs` | ドキュメントの誤り・欠落 |
| `priority:p0` | データ消失・セキュリティ・主要機能が使えない。**通知が鳴る** |
| `priority:p1` | 主要機能の誤動作。回避策はあるが困る |
| `priority:p2` | 小さな不具合や改善 |
| `priority:p3` | あると良い |
| `source:discover` | discover が起票した (精度の振り返り用) |
| `idea` | 既存のインボックス。ここに入るので既存の選別フローにそのまま乗る |

`automation` は**付けない** (既定)。発注するかどうかは人が決める。
`DISCOVER_AUTO_PROMOTE=true` のときだけ、「確度 high・規模 s の p0/p1 bug」に限って
automation も付けて夜間ジョブへ直行させる。

選別側も優先度で並ぶ:
`skills/idea-triage/scripts/backlog.sh` と `harness-dashboard /review` は p0 → p3 の順に表示する。

### 3. 本文はそのまま流せる形で書く

nightly のエージェントは Issue 本文だけを仕様として読む。discover は
idea-triage が求める3節 (**現象 / なぜ問題か / 完了の判定**) + 根拠で本文を書くので、
選んだらそのまま `automation` を付けられる。

### 4. 何を見るか (収集)

| 信号 | 取り方 | 用途 |
|---|---|---|
| 前回からの差分 | `git log/diff last_sha..HEAD` | 差分監査の範囲。変更が生んだ問題・やり残しを探す |
| 差分で増えた TODO/FIXME | `git diff -U0` | 本人が書き残した課題 |
| 既定ブランチで新しく落ちた CI | `gh run list --status failure` + `--log-failed` の末尾 | 推測ではなく事実としての bug |
| プロダクトの文脈 | `.github/discover.md` (無ければ README) | **新しい要件**を出すための目標・やらないこと |
| 既存 Issue | open 全件のタイトル | 重複を返させない |
| 却下された Issue | closed かつ `NOT_PLANNED` | 一度断った提案を二度と出させない |

「新しい要件」はコードだけを見ても出てこない。対象リポジトリに
`.github/discover.md` を置き、プロダクトの目標・利用者・やらないことを書いておくと
feature の提案がその範囲に収まる (例: harness-test の `.github/discover.md`)。

## コスト設計

コストのほぼすべては LLM 呼び出し。**呼ぶかどうかを先に、無料で決める。**

| 段 | 仕組み | 効果 |
|---|---|---|
| 変化なし | HEAD が前回と同じで新しい CI 失敗も無ければ LLM を呼ばない | 動いていないリポジトリは 0 円 |
| 差分監査 | 平日は前回からの差分だけを見せる。全体監査は `DISCOVER_FULL_INTERVAL_DAYS` (7日) ごと | 読むトークンが変更量に比例する |
| 選別待ち | 未選別の idea が `DISCOVER_BACKLOG_LIMIT` (15) 以上なら LLM を呼ばない。状態は進めず差分は持ち越す | 読まれない起票にお金を払わない |
| 軽いモデル | 既定 `sonnet` (エイリアス) | 実装より軽い「読んで判断」の仕事 |
| 上限 | `DISCOVER_TIMEOUT` (秒) と、API 課金なら `DISCOVER_MAX_BUDGET_USD` | 暴走しても1回の上限が決まっている |
| 可視化 | `HARNESS_EVENT:discover_cost usd=...` をログに残す | 1回あたりの実費を後から集計できる |

定期実行にする理由はコストだけでなく**選別のリズム**でもある。毎朝 6:40 に起票され、
人が朝に選び、nightly (8〜22時の偶数時) が実装する。起票が選別を追い越さないよう、
上の「選別待ち」で自然にブレーキがかかる。

### なぜ GitHub Actions ではなく launchd か

| | launchd (採用) | GitHub Actions の cron |
|---|---|---|
| 課金 | 常時稼働機の Claude サブスクリプション内 | API キーなら従量課金 |
| 既存資産 | nightly と同じ機械・同じ clone・同じ通知 | 別に組み直し |
| 弱点 | 機械が落ちていると走らない | — |

既に Mac mini で nightly を回している前提なので、同じ機械に載せるのが一番安い。
Actions に移すなら `discover-run.sh` はそのまま動く (gh / claude / jq / git があればよい)。

## 運用

```bash
nightly/discover-run.sh --dry-run                 # 起票せずに何が出るか見る (LLM は呼ぶ)
nightly/discover-run.sh --repo owner/repo --full  # 1リポジトリを全体監査
launchctl kickstart -p gui/$(id -u)/com.harness.discover
tail -f ~/.claude-harness/discover/launchd-stdout.log
```

状態は `~/.claude-harness/discover/state/<owner>_<repo>` (`last_sha` / `last_run` / `last_full`)。
消すと次回は全体監査になる。

### 精度の振り返り

`source:discover` で絞ると、discover の起票がその後どうなったかが見える。

```bash
gh issue list -R owner/repo --label source:discover --state closed \
  --json stateReason -q 'group_by(.stateReason) | map({(.[0].stateReason): length}) | add'
```

`NOT_PLANNED` が多ければ確度の下限を `high` に上げるか、`.github/discover.md` の
「やらないこと」を足す。却下された Issue は次回以降のプロンプトに渡るので、
**閉じるときは "not planned" で閉じる**と同じ提案が戻ってこない。

## イベント

| イベント | 意味 |
|---|---|
| `discover_filed repo= type= priority= url=` | 起票した |
| `discover_dup repo= fp=` | 既存と重複したので見送った |
| `discover_skipped repo= reason=no_change\|backlog_full` | LLM を呼ばなかった |
| `discover_cost repo= usd= mode=` | 1回の実費 |
| `discover_error repo= reason=` | 失敗 (通知が鳴る) |
