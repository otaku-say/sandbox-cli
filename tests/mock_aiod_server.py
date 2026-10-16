#!/usr/bin/env python3
"""本地 HTTP mock 服务端（aiod-cli 数据面）：模拟 /v2/* 与 /mcp。
支持记录所有接收到的请求（method, path, body）以供测试用例进行断言验证。
"""
import io
import json
import os
import sys
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08"
    b"\x06\x00\x00\x00\x1f\x15c4\x00\x00\x00\rIDATx\x9cc\xf8\xff\xff?\x00\x05"
    b"\xfe\x02\xfe\xdc\xccY\xe7\x00\x00\x00\x00IEND\xaeB`\x82"
)


def make_tar():
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tar:
        data = b"print('hello')\n"
        ti = tarfile.TarInfo(name="app/main.py")
        ti.size = len(data)
        tar.addfile(ti, io.BytesIO(data))
    return bio.getvalue()


TAR_BYTES = make_tar()


class MockAiodHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _read_body(self):
        n = int(self.headers.get("content-length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _reply_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _reply_bytes(self, status, content_type, data):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, method, body):
        self.server.requests_log.append({
            "method": method,
            "path": self.path,
            "headers": dict(self.headers),
            "body": body.decode("utf-8", errors="replace") if body else "",
        })

    def do_GET(self):
        self._record("GET", b"")
        path = self.path

        req_path = path.split("?")[0]

        if "fail_500=true" in path or "/fail_500" in path:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"Internal Error")
            return

        if "fail_api=true" in path:
            self._reply_json(200, {"success": False, "message": "模拟 API 业务错误"})
            return

        if path.startswith("/v2/commands/"):
            # GET /v2/commands/<id>
            self._reply_json(200, {
                "success": True,
                "data": {
                    "command_id": "cmd-test-1",
                    "status": "completed",
                    "exit_code": 0,
                    "stdout": "mock logs stdout\n",
                    "stderr": "",
                    "offset": 17,
                }
            })
            return

        if path.startswith("/v2/commands/sessions"):
            self._reply_json(200, {
                "success": True,
                "data": [{"id": "sess-default", "cwd": "/root"}]
            })
            return

        if path.startswith("/v2/fs/read"):
            self._reply_json(200, {
                "success": True,
                "data": {"content": "file content line 1\nfile content line 2\n"}
            })
            return

        if path.startswith("/v2/fs/list"):
            self._reply_json(200, {
                "success": True,
                "data": [
                    {"name": "main.py", "type": "file", "size": 15},
                    {"name": "src", "type": "dir", "size": 4096}
                ]
            })
            return

        if path.startswith("/v2/fs/stat"):
            self._reply_json(200, {
                "success": True,
                "data": {"size": 1024, "mode": 33188, "is_dir": False}
            })
            return

        if path.startswith("/v2/fs/tree"):
            self._reply_bytes(200, "application/x-tar", TAR_BYTES)
            return

        if path.startswith("/v2/fs/search"):
            self._reply_json(200, {
                "success": True,
                "data": ["/workspace/main.py", "/workspace/test.py"]
            })
            return

        if path == "/v2/pty/sessions":
            self._reply_json(200, {
                "success": True,
                "data": [{"id": "pty-test-1", "cwd": "/root"}]
            })
            return

        if path.startswith("/v2/pty/sessions/") and req_path.endswith("/screen"):
            self._reply_json(200, {
                "success": True,
                "data": {"screen": "root@sandbox:~# ls\napp  src\n"}
            })
            return

        if path.startswith("/v2/pty/sessions/"):
            self._reply_json(200, {
                "success": True,
                "data": {"id": "pty-test-1", "cols": 80, "rows": 24}
            })
            return

        if path == "/v2/code/info":
            self._reply_json(200, {
                "success": True,
                "data": {"languages": ["python", "javascript"], "default": "python"}
            })
            return

        if path.startswith("/v2/watch/") and req_path.endswith("/poll"):
            self._reply_json(200, {
                "success": True,
                "data": {
                    "events": [{"path": "/root/test.txt", "action": "modify"}],
                    "cursor": "c-123"
                }
            })
            return

        if path == "/v2/watch":
            self._reply_json(200, {
                "success": True,
                "data": [{"watcher_id": "watch-1", "path": "/root"}]
            })
            return

        if path == "/v2/sandbox":
            self._reply_json(200, {
                "success": True,
                "data": {"id": "b11df6e8", "status": "running", "image": "cube-aio:v1"}
            })
            return

        if path == "/v2/browser/info":
            self._reply_json(200, {
                "success": True,
                "data": {"running": True, "cdp_url": "ws://127.0.0.1:9222/devtools"}
            })
            return

        if path == "/v2/browser/tabs":
            self._reply_json(200, {
                "success": True,
                "data": [{"id": "tab-1", "title": "Example Domain", "url": "https://example.com"}]
            })
            return

        if path.startswith("/v2/browser/screenshot"):
            self._reply_bytes(200, "image/png", TINY_PNG)
            return

        if path.startswith("/v2/browser/cookies"):
            self._reply_json(200, {
                "success": True,
                "data": [{"name": "session", "value": "xyz123", "domain": "example.com"}]
            })
            return

        if path.startswith("/v2/browser/network/requests"):
            self._reply_json(200, {
                "success": True,
                "data": [{"url": "https://example.com/style.css", "status": 200}]
            })
            return

        if path == "/v2/browser/config":
            self._reply_json(200, {
                "success": True,
                "data": {"resolution": {"width": 1280, "height": 800}}
            })
            return

        if path == "/v2/computer/info":
            self._reply_json(200, {
                "success": True,
                "data": {"width": 1920, "height": 1080, "os": "linux"}
            })
            return

        if path == "/v2/computer/screenshot":
            self._reply_bytes(200, "image/png", TINY_PNG)
            return

        if path == "/v2/computer/cursor":
            self._reply_json(200, {
                "success": True,
                "data": {"x": 250, "y": 300}
            })
            return

        if path == "/v2/computer/clipboard":
            self._reply_json(200, {
                "success": True,
                "data": {"text": "mock clipboard data"}
            })
            return

        if path == "/v2/computer/windows":
            self._reply_json(200, {
                "success": True,
                "data": [{"id": 1, "title": "Chrome", "x": 0, "y": 0, "w": 1000, "h": 700}]
            })
            return

        if path.startswith("/v2/computer/accessibility/nodes"):
            self._reply_json(200, {
                "success": True,
                "data": [{"id": "node-1", "role": "button", "name": "Submit"}]
            })
            return

        if path.startswith("/v2/computer/accessibility"):
            self._reply_json(200, {
                "success": True,
                "data": {"role": "root", "name": "Desktop", "children": []}
            })
            return

        self._reply_json(404, {"success": False, "message": f"Not Found: {path}"})

    def do_POST(self):
        body = self._read_body()
        self._record("POST", body)
        path = self.path
        body_str = body.decode("utf-8", errors="replace") if body else ""

        if "fail_500=true" in path or "/fail_500" in path or "fail_500=true" in body_str:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"Internal Error")
            return

        if "fail_api=true" in path or "fail_api=true" in body_str:
            self._reply_json(200, {"success": False, "message": "模拟 API 业务错误"})
            return

        if path == "/v2/commands":
            try:
                b = json.loads(body)
                mode = b.get("mode")
            except Exception:
                mode = None
            if mode == "async":
                self._reply_json(200, {
                    "success": True,
                    "data": {
                        "command_id": "cmd-async-999",
                        "status": "running"
                    }
                })
            else:
                self._reply_json(200, {
                    "success": True,
                    "data": {
                        "command_id": "cmd-sync-111",
                        "status": "completed",
                        "exit_code": 0,
                        "stdout": "sync output\n",
                        "stderr": ""
                    }
                })
            return

        if path.startswith("/v2/commands/") and path.endswith("/kill"):
            self._reply_json(200, {"success": True, "data": {"killed": True}})
            return

        if path.startswith("/v2/commands/") and path.endswith("/stdin"):
            self._reply_json(200, {"success": True, "data": {"accepted": True}})
            return

        if path == "/v2/commands/sessions":
            self._reply_json(200, {
                "success": True,
                "data": {"id": "sess-new-1"}
            })
            return

        if path == "/v2/fs/write":
            self._reply_json(200, {"success": True, "data": {"bytes_written": 100}})
            return

        if path == "/v2/fs/mkdir":
            self._reply_json(200, {"success": True, "data": {"created": True}})
            return

        if path == "/v2/fs/delete":
            self._reply_json(200, {"success": True, "data": {"deleted": True}})
            return

        if path == "/v2/fs/copy":
            self._reply_json(200, {"success": True, "data": {"copied": True}})
            return

        if path == "/v2/fs/move":
            self._reply_json(200, {"success": True, "data": {"moved": True}})
            return

        if path == "/v2/fs/edit":
            self._reply_json(200, {"success": True, "data": {"edited": True}})
            return

        if path == "/v2/fs/grep":
            self._reply_json(200, {
                "success": True,
                "data": {"matches": [{"path": "/root/test.txt", "line": 1, "text": "matched text"}]}
            })
            return

        if path == "/v2/pty/sessions":
            self._reply_json(200, {
                "success": True,
                "data": {"id": "pty-new-1"}
            })
            return

        if path.startswith("/v2/pty/sessions/") and path.endswith("/exec"):
            self._reply_json(200, {
                "success": True,
                "data": {"output": "pty exec output\n", "exit_code": 0}
            })
            return

        if path.startswith("/v2/pty/sessions/") and path.endswith("/input"):
            self._reply_json(200, {"success": True, "data": {"accepted": True}})
            return

        if path.startswith("/v2/pty/sessions/") and path.endswith("/signal"):
            self._reply_json(200, {"success": True, "data": {"signaled": True}})
            return

        if path == "/v2/code/execute":
            self._reply_json(200, {
                "success": True,
                "data": {"result": "42", "stdout": "42\n"}
            })
            return

        if path == "/v2/watch":
            self._reply_json(200, {
                "success": True,
                "data": {"watcher_id": "watch-created-1"}
            })
            return

        if path == "/mcp":
            try:
                req = json.loads(body)
                rid = req.get("id", 1)
            except Exception:
                rid = 1
            self._reply_json(200, {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"status": "ok", "mock_mcp": True}
            })
            return

        if path == "/v2/browser/navigate":
            self._reply_json(200, {
                "success": True,
                "data": {"status": "navigated"}
            })
            return

        if path == "/v2/browser/evaluate":
            self._reply_json(200, {
                "success": True,
                "data": {"result": "evaluated value"}
            })
            return

        if path == "/v2/browser/click":
            self._reply_json(200, {"success": True, "data": {"clicked": True}})
            return

        if path == "/v2/browser/fill":
            self._reply_json(200, {"success": True, "data": {"filled": True}})
            return

        if path == "/v2/browser/snapshot":
            self._reply_json(200, {
                "success": True,
                "data": {"nodes": [{"role": "button", "ref": "e1"}]}
            })
            return

        if path == "/v2/browser/tabs":
            self._reply_json(200, {
                "success": True,
                "data": {"tab_id": "tab-new-1"}
            })
            return

        if path.startswith("/v2/browser/tabs/"):
            self._reply_json(200, {"success": True, "data": {"active": True}})
            return

        if path == "/v2/browser/cookies":
            self._reply_json(200, {"success": True, "data": {"set": True}})
            return

        if path == "/v2/browser/upload":
            self._reply_json(200, {"success": True, "data": {"uploaded": True}})
            return

        if path == "/v2/browser/config":
            self._reply_json(200, {"success": True, "data": {"updated": True}})
            return

        if path == "/v2/browser/cdp":
            self._reply_json(200, {
                "success": True,
                "data": {"result": {"cdp_ran": True}}
            })
            return

        if path.startswith("/v2/computer/actions/batch"):
            self._reply_json(200, {"success": True, "data": {"batch_completed": True}})
            return

        if path.startswith("/v2/computer/actions"):
            self._reply_json(200, {"success": True, "data": {"act_completed": True}})
            return

        if path == "/v2/computer/record":
            self._reply_json(200, {"success": True, "data": {"recording": True}})
            return

        self._reply_json(404, {"success": False, "message": f"Not Found: {path}"})

    def do_DELETE(self):
        self._record("DELETE", b"")
        path = self.path

        if "fail_500=true" in path or "/fail_500" in path:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"Internal Error")
            return

        if "fail_api=true" in path:
            self._reply_json(200, {"success": False, "message": "模拟 API 业务错误"})
            return

        if path.startswith("/v2/commands/sessions/"):
            self._reply_json(200, {"success": True, "data": {"deleted": True}})
            return

        if path.startswith("/v2/pty/sessions/"):
            self._reply_json(200, {"success": True, "data": {"deleted": True}})
            return

        if path.startswith("/v2/watch/"):
            self._reply_json(200, {"success": True, "data": {"deleted": True}})
            return

        if path.startswith("/v2/browser/tabs/"):
            self._reply_json(200, {"success": True, "data": {"closed": True}})
            return

        if path.startswith("/v2/browser/cookies"):
            self._reply_json(200, {"success": True, "data": {"cleared": True}})
            return

        self._reply_json(404, {"success": False, "message": f"Not Found: {path}"})

    def do_PATCH(self):
        body = self._read_body()
        self._record("PATCH", body)
        path = self.path

        if path.startswith("/v2/pty/sessions/"):
            self._reply_json(200, {"success": True, "data": {"resized": True}})
            return

        self._reply_json(404, {"success": False, "message": f"Not Found: {path}"})


class MockAiodServer:
    def __init__(self, host="127.0.0.1", port=0):
        self.server = ThreadingHTTPServer((host, port), MockAiodHandler)
        self.server.requests_log = []
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.port}"

    def requests(self):
        return self.server.requests_log

    def clear_requests(self):
        self.server.requests_log.clear()


if __name__ == "__main__":
    srv = MockAiodServer()
    srv.start()
    print(f"Mock server listening on {srv.base_url}")
    try:
        while True:
            import time
            time.sleep(1)
    except KeyboardInterrupt:
        srv.stop()
