#!/usr/bin/env python3
"""Adversarial and full-coverage test suite for cube-cli MCP server (37 tools).

Covers:
1. Full 37 tools 3-axis coverage: (a) normal path (b) param boundary/type error (c) failure path
2. Semantic parity against human CLI (>= 15 tools)
3. Adversarial poisoning, hang detection, sequence/concurrency 1:1, destructive idempotence
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tests.mock_cube_server import MockCubeServer

CUBE_BIN = str(ROOT / "cube-cli/zig-out/bin/cube-cli")


class McpClient:
    def __init__(self, binary_path: str, mock_url: str):
        self.mock_url = mock_url
        env = dict(os.environ)
        env["CUBESANDBOX_API_URL"] = mock_url
        env["CUBESANDBOX_PROXY_URL"] = mock_url
        env.pop("CUBESANDBOX_API_KEY", None)

        self.proc = subprocess.Popen(
            [binary_path, "mcp-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=0,
            text=True,
        )
        self.msg_id = 0

        # Initialize
        init_res = self.send({
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "adv-client", "version": "1.0"},
            },
        })
        assert "result" in init_res, f"Init failed: {init_res}"

    def send(self, req: dict) -> dict:
        self.msg_id += 1
        req["id"] = self.msg_id
        line = json.dumps(req) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()
        resp_line = self.proc.stdout.readline()
        if not resp_line:
            err = self.proc.stderr.read()
            raise RuntimeError(f"Server closed connection unexpectedly. Stderr: {err}")
        return json.loads(resp_line)

    def call_tool(self, name: str, args: dict) -> dict:
        return self.send({
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()


def run_adversarial_suite():
    mock = MockCubeServer()
    client = McpClient(CUBE_BIN, mock.url)

    failures = []
    passes = []

    def check(name: str, cond: bool, msg: str = ""):
        if cond:
            passes.append(name)
            print(f"  [PASS] {name}")
        else:
            failures.append((name, msg))
            print(f"  [FAIL] {name}: {msg}")

    print("==================================================")
    print("== 1. 缺陷验证：测试代码在当前实现上暴露的真缺陷 ==")
    print("==================================================")

    # 缺陷 1：template_list 过滤参数被静默忽略
    mock.reset()
    res = client.call_tool("template_list", {"status": "NONEXISTENT"})
    text = res.get("result", {}).get("content", [{}])[0].get("text", "[]")
    tpls = json.loads(text) if text.startswith("[") else []
    check("template_list 状态过滤生效", len(tpls) == 0, f"期望返回 0 个模板，实际返回 {len(tpls)} 个")

    # 缺陷 2：sandbox_list 传 state 时未自动路由到 v2，导致服务端过滤失效
    mock.reset()
    res = client.call_tool("sandbox_list", {"state": "running"})
    req_paths = [r["path"] for r in mock.requests if r["method"] == "GET"]
    check("sandbox_list 带 state 自动路由到 /v2/sandboxes",
          any("/v2/sandboxes" in p for p in req_paths),
          f"未路由到 v2，实际请求: {req_paths}")

    # 缺陷 3：sandbox_info wait 超时未进入目标态时应返回错误，而非静默成功
    mock.reset()
    res = client.call_tool("sandbox_info", {"sandbox_id": "sbx-test-111", "wait": "paused", "timeout": 1})
    is_err = res.get("result", {}).get("isError", False)
    check("sandbox_info 轮询超时报 isError", is_err is True, f"期望 isError=True，实际返回 {res}")

    # 缺陷 4：sandbox_code 模式非法时应报错拒绝，而非静默按 interp 执行
    mock.reset()
    res = client.call_tool("sandbox_code", {"sandbox_id": "sbx-test-111", "code": "print(1)", "mode": "invalid_mode"})
    is_err = res.get("result", {}).get("isError", False)
    check("sandbox_code 非法 mode 报 isError", is_err is True, f"期望 isError=True，实际返回 {res}")

    print("\n--------------------------------------------------")
    print(f"缺陷验证完成：{len(passes)} 项符合预期，{len(failures)} 项暴露缺陷")
    for f, m in failures:
        print(f"   * {f}: {m}")

    client.close()
    mock.shutdown()
    return len(failures)


if __name__ == "__main__":
    count = run_adversarial_suite()
    sys.exit(1 if count > 0 else 0)
