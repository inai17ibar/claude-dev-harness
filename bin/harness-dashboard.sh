#!/bin/bash
# harness-dashboard.sh — メトリクス API と静的 Web を出す軽量 HTTP サーバー。
# 使い方: harness-dashboard [PORT]
set -uo pipefail

# シンボリックリンク (/usr/local/bin/*) 経由で呼ばれても実体の位置を求める。
# BASH_SOURCE はリンクのパスのままなので、そのまま dirname するとライブラリを見失う。
# macOS の readlink には -f が無いので自前でたどる。
_harness_self="${BASH_SOURCE[0]}"
while [ -L "$_harness_self" ]; do
  _harness_dir=$(cd -P "$(dirname "$_harness_self")" && pwd)
  _harness_self=$(readlink "$_harness_self")
  case "$_harness_self" in
    /*) ;;
    *) _harness_self="$_harness_dir/$_harness_self" ;;
  esac
done
HARNESS_ROOT=$(cd -P "$(dirname "$_harness_self")/.." && pwd)
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

cat > "$TMPDIR_SERVER/server.py" << 'PYEOF'
import http.server
import json
import os
import re
import socketserver
import subprocess
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8765"))
DASHBOARD_DIR = Path(os.environ["DASHBOARD_DIR"])
COLLECT_SCRIPT = os.environ["COLLECT_SCRIPT"]
REVIEW_SCRIPT = os.environ["REVIEW_SCRIPT"]
TOKEN = os.environ["UI_TOKEN"]
ALLOWED_REPOS = set(filter(None, os.environ.get("ALLOWED_REPOS", "").split()))

# 画面から実行してよい操作だけを並べる。ここに無いものは弾く。
# gh に渡す引数はこの表から組み立て、リクエストの文字列をそのまま
# コマンド行に流さない (番号は整数、リポジトリは許可リスト照合を通す)。
ACTIONS = {
    "approve": lambda repo, n: ["gh", "pr", "edit", str(n), "-R", repo,
                                "--remove-label", "review-findings"],
    "merge":   lambda repo, n: ["gh", "pr", "merge", str(n), "-R", repo,
                                "--merge", "--delete-branch"],
    "promote": lambda repo, n: ["gh", "issue", "edit", str(n), "-R", repo,
                                "--add-label", "automation"],
    "demote":  lambda repo, n: ["gh", "issue", "edit", str(n), "-R", repo,
                                "--remove-label", "automation"],
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(DASHBOARD_DIR), **kwargs)

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/metrics":
            params = parse_qs(parsed.query)
            repo = params.get("repo", [""])[0]
            cwd = params.get("cwd", [str(Path.home())])[0]
            args = [COLLECT_SCRIPT] + ([repo] if repo else [])
            run_cwd = cwd if Path(cwd).is_dir() else str(Path.home())
            try:
                r = subprocess.run(args, capture_output=True, text=True,
                                   timeout=20, cwd=run_cwd)
                if r.returncode == 0:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(r.stdout.encode())
                else:
                    self.send_error(500, "collect failed")
            except subprocess.TimeoutExpired:
                self.send_error(504, "collect timeout")
            return

        if parsed.path == "/api/review":
            try:
                r = subprocess.run([REVIEW_SCRIPT], capture_output=True,
                                   text=True, timeout=120)
                if r.returncode == 0 and r.stdout.strip():
                    self.send_response(200)
                    self.send_header("Content-Type",
                                     "application/json; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(r.stdout.encode())
                else:
                    self._json(500, {"error": (r.stderr or "no output")[-400:]})
            except subprocess.TimeoutExpired:
                self._json(504, {"error": "GitHub への問い合わせがタイムアウトしました"})
            return

        # レビュー画面はトークンを埋め込んで返す。localhost で開いている
        # 別ページから勝手に操作されないようにするため。
        if parsed.path in ("/review", "/review.html"):
            path = DASHBOARD_DIR / "review.html"
            if not path.exists():
                self.send_error(404, "review.html not found")
                return
            html = path.read_text(encoding="utf-8").replace("__UI_TOKEN__", TOKEN)
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        super().do_GET()

    def do_POST(self):
        if urlparse(self.path).path != "/api/action":
            self.send_error(404)
            return

        if self.headers.get("X-Harness-Token") != TOKEN:
            self._json(403, {"error": "トークンが一致しません。画面を開き直してください"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json(400, {"error": "リクエストを読めませんでした"})
            return

        action = req.get("action", "")
        repo = req.get("repo", "")
        number = req.get("number")

        if action not in ACTIONS:
            self._json(400, {"error": "不明な操作: %s" % action})
            return
        if not isinstance(repo, str) or not re.fullmatch(
                r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
            self._json(400, {"error": "リポジトリ名が不正です"})
            return
        if repo not in ALLOWED_REPOS:
            self._json(403, {"error": "対象外のリポジトリ: %s" % repo})
            return
        if not isinstance(number, int) or number <= 0:
            self._json(400, {"error": "番号が不正です"})
            return

        try:
            r = subprocess.run(ACTIONS[action](repo, number),
                               capture_output=True, text=True, timeout=90)
        except subprocess.TimeoutExpired:
            self._json(504, {"error": "gh がタイムアウトしました"})
            return

        if r.returncode == 0:
            self._json(200, {"ok": True, "output": (r.stdout or "").strip()[-400:]})
        else:
            self._json(500, {"ok": False,
                             "error": (r.stderr or r.stdout or "失敗").strip()[-400:]})


with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print("🚀 Harness Dashboard")
    print("   メトリクス : http://localhost:%d/" % PORT)
    print("   レビュー   : http://localhost:%d/review" % PORT)
    print("   停止: Ctrl+C")
    httpd.serve_forever()
PYEOF

# 静的ファイルはリポジトリ側を正として毎回配り直す
mkdir -p "$DASHBOARD_DIR"
cp "$HARNESS_ROOT/web/index.html" "$DASHBOARD_DIR/index.html" \
  || harness_die "$HARNESS_ROOT/web/index.html が見つかりません"
cp "$HARNESS_ROOT/web/review.html" "$DASHBOARD_DIR/review.html" \
  || harness_die "$HARNESS_ROOT/web/review.html が見つかりません"

COLLECT_SCRIPT="$(command -v harness-collect-metrics || echo "$HARNESS_ROOT/bin/harness-collect-metrics.sh")"
REVIEW_SCRIPT="$HARNESS_ROOT/bin/harness-review-data.sh"

# 画面から GitHub を操作できるので、同じ localhost の別ページから
# 勝手に叩かれないよう、起動ごとのトークンを要求する。
UI_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
ALLOWED_REPOS=$("$REVIEW_SCRIPT" --repos 2>/dev/null | tr '\n' ' ')
[ -n "$(printf '%s' "$ALLOWED_REPOS" | tr -d ' ')" ] \
  || harness_die "対象リポジトリを決められません。$HARNESS_DIR/repos.txt に1行1リポジトリで書いてください"

echo "   対象リポジトリ: $ALLOWED_REPOS"

PORT="$PORT" \
DASHBOARD_DIR="$DASHBOARD_DIR" \
COLLECT_SCRIPT="$COLLECT_SCRIPT" \
REVIEW_SCRIPT="$REVIEW_SCRIPT" \
UI_TOKEN="$UI_TOKEN" \
ALLOWED_REPOS="$ALLOWED_REPOS" \
  python3 "$TMPDIR_SERVER/server.py"
