"""Runs every code block of each SDK's README exactly as written.

    python3 testing/run_readme_examples.py [python node go ruby php dart] [--gateway live|1110] [--live]

Default: against testing/mock_api.py (offline). ``--live``: against https://api.toneperfect.app with
$TONEPERFECT_API_KEY, which must be a test key (tp_test_...: fixed example results, nothing scored or charged).
Live calls go through a local proxy that lets one request reach the API every 4 seconds.

Each block runs in a fresh directory that holds hello.ogg (the sample the READMEs use) and a way to import the SDK
from this checkout instead of a registry: PYTHONPATH for Python, node_modules/toneperfect for Node.js, -I for Ruby,
vendor/autoload.php for PHP, a replace directive for Go and a path dependency for Dart. Code is not edited.
A block passes when it exits 0. Shell blocks (install commands) are not run.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "testing"))
import mock_api  # noqa: E402

TAGS = {"python": ("python",), "node": ("js", "javascript"), "go": ("go",), "ruby": ("ruby",), "php": ("php",), "dart": ("dart",)}
GO_MODULE = "github.com/vm542/toneperfect-sdk/go"
LIVE = "https://api.toneperfect.app"


def blocks(language):
    text = open(os.path.join(ROOT, language, "README.md"), encoding="utf-8").read()
    pattern = r"```(" + "|".join(TAGS[language]) + r")\n(.*?)```"
    return [code for _, code in re.findall(pattern, text, flags=re.S)]


def throttle_proxy(upstream, interval=4.0):
    lock, last = threading.Lock(), [0.0]

    class Proxy(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def forward(self):
            if not self.path.startswith("/v1/"):
                self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) or None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection", "accept-encoding")}
            with lock:
                wait = last[0] + interval - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                last[0] = time.monotonic()
            request = urllib.request.Request(upstream + self.path, data=body, method=self.command, headers=headers)
            try:
                response = urllib.request.urlopen(request, timeout=90)
                status, rh, data = response.status, response.headers, response.read()
            except urllib.error.HTTPError as error:
                status, rh, data = error.code, error.headers, error.read()
            self.send_response(status)
            for k, v in rh.items():
                if k.lower() not in ("transfer-encoding", "content-length", "connection", "content-encoding"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = forward

    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


def run_block(language, code, env, index):
    work = tempfile.mkdtemp(prefix=f"tp-readme-{language}-{index}-")
    shutil.copy(os.path.join(ROOT, "testing", "fixtures", "hello.ogg"), os.path.join(work, "hello.ogg"))
    sdk = os.path.join(ROOT, language)
    env = dict(env)
    if language == "python":
        path = os.path.join(work, "example.py"); open(path, "w", encoding="utf-8").write(code)
        env["PYTHONPATH"] = os.path.join(sdk, "src")
        cmd = [sys.executable, path]
    elif language == "node":
        os.makedirs(os.path.join(work, "node_modules"))
        os.symlink(sdk, os.path.join(work, "node_modules", "toneperfect"))
        path = os.path.join(work, "example.mjs" if re.search(r"^\s*import ", code, re.M) else "example.cjs")
        open(path, "w", encoding="utf-8").write(code)
        cmd = ["node", path]
    elif language == "ruby":
        path = os.path.join(work, "example.rb"); open(path, "w", encoding="utf-8").write(code)
        cmd = ["ruby", "-I", os.path.join(sdk, "lib"), path]
    elif language == "php":
        os.makedirs(os.path.join(work, "vendor"))
        open(os.path.join(work, "vendor", "autoload.php"), "w").write(f"<?php\nrequire {json.dumps(os.path.join(sdk, 'src', 'TonePerfect.php'))};\n")
        path = os.path.join(work, "example.php"); open(path, "w", encoding="utf-8").write(code)
        cmd = ["php", path]
    elif language == "go":
        open(os.path.join(work, "go.mod"), "w").write(f"module example\n\ngo 1.21\n\nrequire {GO_MODULE} v0.0.0\n\nreplace {GO_MODULE} => {sdk}\n")
        open(os.path.join(work, "main.go"), "w", encoding="utf-8").write(code)
        cmd = ["go", "run", "."]
        env.setdefault("GOFLAGS", "-mod=mod")
    elif language == "dart":
        os.makedirs(os.path.join(work, "bin"))
        open(os.path.join(work, "pubspec.yaml"), "w").write(f"name: example\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  toneperfect:\n    path: {sdk}\n")
        open(os.path.join(work, "bin", "main.dart"), "w", encoding="utf-8").write(code)
        got = subprocess.run(["dart", "pub", "get"], cwd=work, capture_output=True, text=True, env=env)
        if got.returncode:
            return got.returncode, got.stdout + got.stderr
        cmd = ["dart", "run", "bin/main.dart"]
    result = subprocess.run(cmd, cwd=work, capture_output=True, text=True, env=env, timeout=300)
    return result.returncode, (result.stdout + result.stderr).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("languages", nargs="*", default=list(TAGS))
    parser.add_argument("--gateway", choices=["live", "1110"], default="live")
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    env = dict(os.environ)
    if args.live:
        key = env.get("TONEPERFECT_API_KEY", "")
        if not key.startswith("tp_test_"):
            sys.exit("--live needs TONEPERFECT_API_KEY set to a test key (tp_test_...)")
        env["TONEPERFECT_BASE_URL"] = throttle_proxy(LIVE)
        target = "live API (one request / 4 s)"
    else:
        _, url = mock_api.serve(0, args.gateway)
        env["TONEPERFECT_BASE_URL"], env["TONEPERFECT_API_KEY"] = url, "tp_test_mock"
        target = f"mock ({args.gateway} gateway)"
    failures = 0
    for language in args.languages:
        found = blocks(language)
        if not found:
            print(f"FAIL {language}: README has no runnable block"); failures += 1; continue
        for i, code in enumerate(found, 1):
            status, output = run_block(language, code, env, i)
            first = code.strip().splitlines()[0][:70]
            print(f"{'ok  ' if status == 0 else 'FAIL'} {language} block {i}/{len(found)} ({first})")
            if status:
                failures += 1
                print("     " + output.replace("\n", "\n     ")[:3000])
    print(f"{target}: {'all README blocks ran' if not failures else f'{failures} failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
