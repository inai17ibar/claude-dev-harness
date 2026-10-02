#!/bin/bash
# weekly-audit.sh — 互換のための入口。中身は discover-run.sh に移った。
#
# 旧版は LLM に gh issue create を直接打たせていたため、ラベル・件数・重複判定が
# LLM 任せだった。discover-run.sh は LLM に JSON を返させ、起票はシェルが行う。
# 毎日差分だけを見て、全体監査は DISCOVER_FULL_INTERVAL_DAYS ごとに行う。
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/discover-run.sh" --full "$@"
