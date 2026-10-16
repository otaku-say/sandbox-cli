#!/usr/bin/env python3
"""Local mock HTTP server for CubeSandbox control plane and envd data plane.

Supports both import as a test fixture and standalone execution.
"""

import base64
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def connect_stream(events: list[dict]) -> bytes:
    """Encode events as Connect protocol framed stream."""
    buf = bytearray()
    for ev in events:
        payload = json.dumps(ev, separators=(',', ':')).encode("utf-8")
        buf.append(0)
        buf.extend(len(payload).to_bytes(4, "big"))
        buf.extend(payload)
    # End of stream envelope (flag = 2)
    end_payload = b"{}"
    buf.append(2)
    buf.extend(len(end_payload).to_bytes(4, "big"))
    buf.extend(end_payload)
    return bytes(buf)


class MockHandler(BaseHTTPRequestHandler):
    server: "MockCubeServerInternal"

    def log_message(self, *args):
        pass

    def _read_body(self) -> str:
        length = int(self.headers.get("content-length") or 0)
        if length > 0:
            return self.rfile.read(length).decode("utf-8", errors="replace")
        return ""

    def _record_and_dispatch(self, method: str):
        body = self._read_body()
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        rec = {
            "method": method,
            "path": path,
            "raw_path": self.path,
            "query": query,
            "body": body,
            "headers": dict(self.headers),
        }
        self.server.recorded_requests.append(rec)

        for fail_pattern, status_code in self.server.failure_routes:
            if re.search(fail_pattern, self.path):
                self._send_json(status_code, {"error": "simulated failure", "code": status_code})
                return

        self._route(method, path, query, body)

    def do_GET(self):
        self._record_and_dispatch("GET")

    def do_POST(self):
        self._record_and_dispatch("POST")

    def do_PUT(self):
        self._record_and_dispatch("PUT")

    def do_DELETE(self):
        self._record_and_dispatch("DELETE")

    def _send_json(self, status: int, data: any, headers: dict = None):
        # Use separators=(',', ':') so Zig extractString/extractInt can match without spaces
        content = json.dumps(data, separators=(',', ':')).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(content)))
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(content)

    def _send_text(self, status: int, text: str, content_type: str = "text/plain"):
        content = text.encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _send_bytes(self, status: int, content: bytes, content_type: str):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _route(self, method: str, path: str, query: dict, body: str):
        # 1. Envd data plane endpoints: /sandbox/<sid>/49983/...
        if "/49983/" in path or path.endswith("/49983"):
            self._route_envd(method, path, query, body)
            return

        # 2. Kernel execute endpoint: /sandbox/<sid>/49999/execute
        if "/49999/execute" in path:
            self._send_text(200, '{"type":"stdout","text":"hello from kernel\\n"}\n', "application/x-ndjson")
            return

        # 3. Control plane endpoints
        if path == "/sandboxes" or path == "/v2/sandboxes":
            if method == "GET":
                self._send_json(200, [
                    {
                        "sandboxID": "sbx-test-111",
                        "templateID": "tpl-code",
                        "state": "running",
                        "metadata": {"note": "test-box", "agent": "test"},
                    }
                ])
                return
            elif method == "POST":
                self._send_json(200, {"sandboxID": "sbx-created-222", "status": "running"})
                return

        if re.match(r"^/sandboxes/[^/]+/connect$", path):
            self._send_json(200, {"envdAccessToken": "mock-token-abc"})
            return

        if re.match(r"^/sandboxes/[^/]+/pause$", path):
            self._send_json(200, {"status": "paused"})
            return

        if re.match(r"^/sandboxes/[^/]+/resume$", path):
            self._send_json(200, {"status": "running"})
            return

        if re.match(r"^/sandboxes/[^/]+/refreshes$", path):
            self._send_json(200, {"refreshed": True, "duration": 300})
            return

        if re.match(r"^/sandboxes/[^/]+/timeout$", path):
            self._send_json(200, {"timeout": 3600})
            return

        if re.match(r"^/sandboxes/[^/]+/network$", path):
            self._send_json(200, {"allowInternetAccess": True})
            return

        if re.match(r"^/sandboxes/[^/]+/snapshots$", path):
            self._send_json(200, {"snapshotID": "snap-new-333"})
            return

        if re.match(r"^/sandboxes/[^/]+/rollback$", path):
            self._send_json(200, {"operationID": "op-rb-1", "status": "running"})
            return

        if re.match(r"^/sandboxes/[^/]+$", path):
            if method == "GET":
                self._send_json(200, {
                    "sandboxID": "sbx-test-111",
                    "templateID": "tpl-code",
                    "state": "running",
                    "metadata": {"note": "test-box"},
                })
                return
            elif method == "DELETE":
                self._send_json(200, {"status": "deleted"})
                return

        if path == "/snapshots":
            self._send_json(200, [
                {
                    "snapshotID": "snap-test-111",
                    "status": "READY",
                    "originSandboxID": "sbx-test-111",
                }
            ])
            return

        if path == "/volumes":
            if method == "GET":
                self._send_json(200, [
                    {"volumeID": "vol-test-111", "name": "my-vol", "driver": "local"}
                ])
                return
            elif method == "POST":
                self._send_json(200, {"volumeID": "vol-created-222", "name": "new-vol"})
                return

        if re.match(r"^/volumes/[^/]+$", path):
            if method == "GET":
                self._send_json(200, {
                    "volumeID": "vol-test-111",
                    "name": "my-vol",
                    "token": "tok-vol-secret",
                })
                return
            elif method == "DELETE":
                self._send_json(200, {"status": "deleted"})
                return

        if path == "/templates":
            self._send_json(200, [
                {
                    "templateID": "tpl-code",
                    "status": "READY",
                    "imageInfo": "aio-code:latest",
                },
                {
                    "templateID": "tpl-browser",
                    "status": "READY",
                    "imageInfo": "aio-browser:latest",
                },
                {
                    "templateID": "tpl-desktop",
                    "status": "READY",
                    "imageInfo": "aio-computer:latest",
                },
            ])
            return

        if re.match(r"^/templates/[^/]+$", path):
            if method == "GET":
                self._send_json(200, {
                    "templateID": "tpl-code",
                    "status": "READY",
                    "imageInfo": "aio-code:latest",
                    "com.exposed_ports": "8080/tcp,49983/tcp",
                })
                return
            elif method == "DELETE":
                self._send_json(200, {"status": "deleted"})
                return

        if path == "/health":
            self._send_json(200, {"status": "healthy"})
            return

        self._send_json(404, {"error": "not found", "path": path})

    def _route_envd(self, method: str, path: str, query: dict, body: str):
        if path.endswith("/files"):
            if method == "GET":
                qpath = query.get("path", [""])[0]
                if "nonexistent" in qpath:
                    self._send_text(404, "file not found")
                elif qpath.endswith(".meta"):
                    meta = {
                        "pid": 1234,
                        "tag": "mocktag",
                        "out": "/tmp/.cube-cli-exec/mocktag.out",
                        "err": "/tmp/.cube-cli-exec/mocktag.err",
                        "exit": "/tmp/.cube-cli-exec/mocktag.exit",
                        "cmd": "echo test",
                    }
                    self._send_json(200, meta)
                elif qpath.endswith(".out"):
                    self._send_text(200, "hello stdout from async process\n")
                elif qpath.endswith(".err"):
                    self._send_text(200, "")
                elif qpath.endswith(".exit"):
                    self._send_text(200, "0\n")
                else:
                    self._send_text(200, "sample file content from mock")
                return
            elif method == "POST":
                self._send_text(200, "ok")
                return

        if "process.Process/Start" in path:
            # Check if this is ports probe
            if "proc/net/tcp" in body:
                tcp_mock = (
                    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
                    "   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n"
                    "   1: 0100007F:C33F 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0\n"
                )
                b64 = base64.b64encode(tcp_mock.encode("utf-8")).decode("utf-8")
                events = [
                    {"pid": 1234},
                    {"stdout": b64},
                    {"exitCode": 0},
                ]
                self._send_bytes(200, connect_stream(events), "application/connect+json")
                return

            out_b64 = base64.b64encode(b"mock stdout output\n").decode("utf-8")
            events = [
                {"pid": 1234},
                {"stdout": out_b64},
                {"exitCode": 0},
            ]
            self._send_bytes(200, connect_stream(events), "application/connect+json")
            return

        if "process.Process/List" in path:
            self._send_json(200, {"processes": [{"pid": 1234, "cmd": "mock"}]})
            return

        if "process.Process/SendSignal" in path:
            self._send_json(200, {})
            return

        if "process.Process/SendInput" in path:
            self._send_json(200, {})
            return

        if "filesystem.Filesystem/ListDir" in path:
            self._send_json(200, {
                "entries": [
                    {"name": "file1.txt", "type": "FILE", "size": "100", "permissions": "-rw-r--r--"},
                    {"name": "subdir", "type": "DIRECTORY", "size": "4096", "permissions": "drwxr-xr-x"},
                ]
            })
            return

        if "filesystem.Filesystem/Stat" in path:
            if "nonexistent" in body:
                self._send_json(404, {"error": "not_found"})
            else:
                self._send_json(200, {
                    "name": "file1.txt",
                    "type": "FILE",
                    "size": "100",
                    "permissions": "-rw-r--r--",
                })
            return

        if "filesystem.Filesystem/MakeDir" in path:
            self._send_json(200, {})
            return

        if "filesystem.Filesystem/Remove" in path:
            self._send_json(200, {})
            return

        if "filesystem.Filesystem/Move" in path:
            self._send_json(200, {})
            return

        self._send_json(404, {"error": "envd endpoint not found", "path": path})


class MockCubeServerInternal(ThreadingHTTPServer):
    recorded_requests: list
    failure_routes: list

    def __init__(self, addr, handler_cls):
        super().__init__(addr, handler_cls)
        self.recorded_requests = []
        self.failure_routes = []


class MockCubeServer:
    def __init__(self, host="127.0.0.1", port=0):
        self.server = MockCubeServerInternal((host, port), MockHandler)
        self.port = self.server.server_address[1]
        self.url = f"http://{host}:{self.port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def requests(self):
        return self.server.recorded_requests

    def add_failure(self, pattern: str, status_code: int = 500):
        self.server.failure_routes.append((pattern, status_code))

    def clear_failures(self):
        self.server.failure_routes.clear()

    def reset(self):
        self.server.recorded_requests.clear()
        self.server.failure_routes.clear()

    def shutdown(self):
        self.server.shutdown()
        self.server.server_close()


if __name__ == "__main__":
    srv = MockCubeServer("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0)
    print(f"MockCubeServer listening on {srv.url}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        srv.shutdown()
