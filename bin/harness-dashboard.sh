#!/bin/bash
# harness-dashboard.sh — メトリクス API と静的 Web を出す軽量 HTTP サーバー。
# 使い方: harness-dashboard [PORT]
set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HARNESS_ROOT/lib/common.sh"

PORT="${1:-${HARNESS_DASHBOARD_PORT:-8765}}"
DASHBOARD_DIR="${HARNESS_DASHBOARD_DIR:-$HARNESS_DIR/dashboard}"

# Pythonがあるか
harness_require python3

# 一時的なPythonサーバースクリプトを書き出して起動
TMPDIR_SERVER=$(mktemp -d)
cleanup_tmp() { rm -rf "$TMPDIR_SERVER"; }
trap cleanup_tmp EXIT

cat > "$TMPDIR_SERVER/server.py" << PYEOF
import http.server
import socketserver
import json
import subprocess
import os
import sys
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8765"))
DASHBOARD_DIR = Path(os.environ["DASHBOARD_DIR"])
COLLECT_SCRIPT = os.environ["COLLECT_SCRIPT"]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(DASHBOARD_DIR), **kwargs)

    def log_message(self, format, *args):
        pass  # quieten

    def do_GET(self):
        parsed = urlparse(self.path)
        
        # API: /api/metrics
        if parsed.path == "/api/metrics":
            params = parse_qs(parsed.query)
            repo = params.get("repo", [""])[0]
            cwd = params.get("cwd", [str(Path.home())])[0]
            
            try:
                args = [COLLECT_SCRIPT]
                if repo:
                    args.append(repo)
                
                # cwdが存在し、Gitリポジトリなら、そこで実行
                run_cwd = cwd if Path(cwd).is_dir() else str(Path.home())
                
                result = subprocess.run(
                    args,
                    capture_output=True,
                    text=True,
                    timeout=15,
                    cwd=run_cwd
                )
                if result.returncode == 0:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    self.wfile.write(result.stdout.encode())
                else:
                    self.send_error(500, f"collect failed: {result.stderr}")
            except subprocess.TimeoutExpired:
                self.send_error(504, "collect timeout")
            except Exception as e:
                self.send_error(500, str(e))
            return
        
        # 静的ファイル
        super().do_GET()

with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"🚀 Harness Dashboard: http://localhost:{PORT}")
    print(f"   メトリクスAPI: http://localhost:{PORT}/api/metrics")
    print(f"   停止: Ctrl+C")
    httpd.serve_forever()
PYEOF

# 静的ファイルはリポジトリ側を正として毎回配り直す
mkdir -p "$DASHBOARD_DIR"
cp "$HARNESS_ROOT/web/index.html" "$DASHBOARD_DIR/index.html" \
  || harness_die "$HARNESS_ROOT/web/index.html が見つかりません"

COLLECT_SCRIPT="$(command -v harness-collect-metrics || echo "$HARNESS_ROOT/bin/harness-collect-metrics.sh")"

PORT="$PORT" \
DASHBOARD_DIR="$DASHBOARD_DIR" \
COLLECT_SCRIPT="$COLLECT_SCRIPT" \
  python3 "$TMPDIR_SERVER/server.py"
