---
name: spawn-all
description: Open状態の全Issueを並行解決
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash
---

# Open Issueを全部処理

以下を実行:

```bash
ISSUES=$(gh issue list --state open --json number -q '.[].number' | tr '\n' ' ')
if [ -z "$ISSUES" ]; then
  echo "Open Issueはありません"
else
  spawn-agents --merge $ISSUES
fi
```

実行後、サマリーを報告してください。
