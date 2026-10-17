#!/usr/bin/env python3
"""主控补充的边界回归（反空跑：这些用例在改动前的二进制上必须失败）。

覆盖：
  1. sandbox_create 的 template 支持**服务端别名解析**（别名 → templateID 再建沙箱）
  2. sandbox_pause 的 `wait` 生效：等不到 paused 必须**如实报超时**（不许伪报成功）
  3. sandbox_pause `wait` 且真的 paused → 成功
  4. 可选字符串参数类型不符 → 参数错误（不再静默忽略）
  5. aiod file_grep 透传 include/context/offset/type

用法: python3 tests/mcp_cube_edge_test.py --cube <bin> --aio <bin>
（用改动前的二进制跑应出现 FAIL —— 可用 `--expect-pre-change` 让脚本反转断言以自证灵敏度）
"""
import argparse
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
STATE = {"sandbox_state": "running", "pause_seen": 0}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _body(self):
        n = int(self.headers.get("content-length") or 0)
        return self.rfile.read(n).decode("utf-8", "replace") if n else ""

    def _json(self, obj, status=200):
        # 与真实控制面一致：Go encoding/json 默认输出紧凑 JSON（无空格）
        b = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        LOG.append(("GET", self.path, ""))
        if self.path.startswith("/templates/aliases/"):
            if "spaced-alias" in self.path:
                # 故意返回**带空格/缩进**的 JSON：验证取值不依赖对端排版
                b = json.dumps({"templateID": "tpl-real-spaced"}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
                return
            self._json({"templateID": "tpl-real-1"})
            return
        if self.path.startswith("/sandboxes/") and self.path.count("/") == 2:
            self._json({"sandboxID": "sbx-1", "state": STATE["sandbox_state"]})
            return
        if self.path.startswith("/sandboxes"):
            self._json([{"sandboxID": "sbx-1", "templateID": "tpl-real-1", "state": "running"}])
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        body = self._body()
        LOG.append(("POST", self.path, body))
        if self.path == "/sandboxes":
            self._json({"sandboxID": "sbx-1", "status": "running"})
            return
        if self.path.endswith("/pause"):
            STATE["pause_seen"] += 1
            if STATE["sandbox_state"] == "pause_then_running":
                STATE["sandbox_state"] = "running"  # 等不到 paused
            elif STATE["sandbox_state"] == "pause_then_paused":
                STATE["sandbox_state"] = "paused"
            self._json({})
            return
        if self.path == "/v2/fs/grep":
            self._json({"success": True, "data": {"matches": []}})
            return
        self._json({})

    def do_PUT(self):
        self._body()
        self._json({})


def start_mock():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


class Mcp:
    def __init__(self, binary, env):
        self.p = subprocess.Popen([binary, "mcp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=env, bufsize=0)
        self.n = 0
        self.call("initialize", {"protocolVersion": "2025-06-18"})

    def call(self, method, params):
        self.n += 1
        req = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            req["params"] = params
        self.p.stdin.write((json.dumps(req) + "\n").encode()); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def tool(self, name, args):
        r = self.call("tools/call", {"name": name, "arguments": args})
        res = r.get("result")
        if res is None:
            return {"is_error": True, "text": str(r.get("error"))}
        return {"is_error": res.get("isError", False),
                "text": "".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")}

    def close(self):
        try:
            self.p.kill()
        except Exception:
            pass


FAILS = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS.append(name)
        print(f"  FAIL {name}: {detail}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cube", required=True)
    ap.add_argument("--aio", required=True)
    ap.add_argument("--expect-pre-change", action="store_true",
                    help="用改动前二进制跑时加此开关：断言反转，用于自证这些用例真的能抓到旧行为")
    args = ap.parse_args()
    pre = args.expect_pre_change

    srv, port = start_mock()
    base = f"http://127.0.0.1:{port}"
    env = {k: v for k, v in os.environ.items() if not k.startswith("CUBESANDBOX_") and not k.startswith("SANDBOX_")}
    env["CUBESANDBOX_API_URL"] = base
    env["CUBESANDBOX_PROXY_URL"] = base
    aio_env = dict(env); aio_env["SANDBOX_BASE"] = base

    cube = Mcp(args.cube, env)

    # 1) 别名解析
    LOG.clear()
    r = cube.tool("sandbox_create", {"template": "my-alias"})
    alias_q = any(m == "GET" and p.startswith("/templates/aliases/") for m, p, _ in LOG)
    body = next((b for m, p, b in LOG if m == "POST" and p == "/sandboxes"), "")
    resolved = '"templateID":"tpl-real-1"' in body.replace(" ", "")
    check("别名解析：查询了别名接口" + ("（预期旧版不做）" if pre else ""), alias_q != pre, f"LOG={LOG[:3]}")
    check("别名解析：建沙箱用的是解析后的 templateID" + ("（预期旧版用原始别名）" if pre else ""),
          resolved != pre, f"body={body[:120]}")

    # 1b) 别名响应带空白/缩进也要能解析（不依赖对端排版）
    LOG.clear()
    r = cube.tool("sandbox_create", {"template": "spaced-alias"})
    body = next((b for m, p, b in LOG if m == "POST" and p == "/sandboxes"), "")
    spaced_ok = '"templateID":"tpl-real-spaced"' in body.replace(" ", "")
    check("带空格的别名响应也能解析" + ("（预期旧版取不到值）" if pre else ""), spaced_ok != pre, f"body={body[:120]}")

    # 2) pause wait：等不到 → 如实超时
    STATE["sandbox_state"] = "pause_then_running"
    r = cube.tool("sandbox_pause", {"sandbox_id": "sbx-1", "wait": True, "timeout": 1})
    timed_out = r["is_error"] and ("超时" in r["text"])
    check("pause wait：等不到 paused 时报超时" + ("（预期旧版伪报成功）" if pre else ""),
          timed_out != pre, f"r={r}")

    # 3) pause wait：真的 paused → 成功
    STATE["sandbox_state"] = "pause_then_paused"
    r = cube.tool("sandbox_pause", {"sandbox_id": "sbx-1", "wait": True, "timeout": 10})
    ok3 = (not r["is_error"]) and "已暂停" in r["text"]
    check("pause wait：真的 paused 时成功", ok3, f"r={r}")

    # 4) 可选字符串参数类型不符 → 参数错误（不再静默忽略）
    r = cube.tool("sandbox_info", {"sandbox_id": "sbx-1", "wait": 123})
    strict = r["is_error"] and "参数错误" in r["text"]
    check("可选字符串类型错误 → 参数错误" + ("（预期旧版静默忽略）" if pre else ""), strict != pre, f"r={r}")
    cube.close()

    aio = Mcp(args.aio, aio_env)
    LOG.clear()
    r = aio.tool("file_grep", {"path": "/tmp", "pattern": "x", "include": ["*.zig"], "context": 2,
                               "offset": 5, "type": "zig"})
    grep_body = next((b for m, p, b in LOG if p == "/v2/fs/grep"), "")
    has_all = all(k in grep_body for k in ('"include":["*.zig"]', '"context_before":2', '"offset":5', '"type":"zig"'))
    check("file_grep 透传 include/context/offset/type" + ("（预期旧版缺字段）" if pre else ""),
          has_all != pre, f"body={grep_body[:160]}")

    r = aio.tool("file_read", {"path": "/etc/hosts", "user": 123})
    strict2 = r["is_error"] and "参数错误" in r["text"]
    check("aiod 可选字符串类型错误 → 参数错误" + ("（预期旧版静默忽略）" if pre else ""), strict2 != pre, f"r={r}")
    aio.close()
    srv.shutdown()

    print(f"-- 边界回归：{len(FAILS)} 项不符预期 --")
    if FAILS and not pre:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
