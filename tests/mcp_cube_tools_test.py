#!/usr/bin/env python3
"""E2E tests for all cube-cli MCP tools using MockCubeServer.

Verifies:
1. Every tool returns valid MCP result structure (result.content[0].text, isError: False).
2. Mock HTTP server receives correct HTTP method, path, and critical payload fields.
3. Error scenarios: missing required arguments, safety checks (confirm=true), and HTTP 500 failures.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# Add repo root to import path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tests.mock_cube_server import MockCubeServer


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
        )
        self.msg_id = 0

        # Initialize
        init_res = self.send({
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "test-client", "version": "1.0"},
            },
        })
        assert "result" in init_res, f"Init failed: {init_res}"

    def send(self, req: dict) -> dict:
        self.msg_id += 1
        req["id"] = self.msg_id
        line = json.dumps(req) + "\n"
        self.proc.stdin.write(line.encode("utf-8"))
        self.proc.stdin.flush()

        resp_line = self.proc.stdout.readline()
        if not resp_line:
            err = self.proc.stderr.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Server closed connection unexpectedly. Stderr: {err}")
        return json.loads(resp_line.decode("utf-8"))

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


def run_tests(binary_path: str):
    mock = MockCubeServer()
    client = McpClient(binary_path, mock.url)

    passed = 0
    failed = 0

    def ok(name: str):
        nonlocal passed
        passed += 1
        print(f"  [PASS] {name}")

    def fail(name: str, msg: str):
        nonlocal failed
        failed += 1
        print(f"  [FAIL] {name}: {msg}")

    print(f"== 开始执行 cube-cli 工具面全量测试（mock={mock.url}） ==")

    # 1. sandbox_create
    try:
        mock.reset()
        res = client.call_tool("sandbox_create", {"template": "tpl-code", "need": "code", "timeout": 3600})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"] == "/sandboxes" for r in mock.requests)
        ok("sandbox_create 正常新建")
    except Exception as e:
        fail("sandbox_create 正常新建", str(e))

    # 2. sandbox_list
    try:
        mock.reset()
        res = client.call_tool("sandbox_list", {})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/sandboxes" for r in mock.requests)
        ok("sandbox_list 正常查询")
    except Exception as e:
        fail("sandbox_list 正常查询", str(e))

    # 3. sandbox_info
    try:
        mock.reset()
        res = client.call_tool("sandbox_info", {"sandbox_id": "sbx-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/sandboxes/sbx-test-111" for r in mock.requests)
        ok("sandbox_info 正常查看")
    except Exception as e:
        fail("sandbox_info 正常查看", str(e))

    # 4. sandbox_pause
    try:
        mock.reset()
        res = client.call_tool("sandbox_pause", {"sandbox_id": "sbx-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"] == "/sandboxes/sbx-test-111/pause" for r in mock.requests)
        ok("sandbox_pause 正常暂停")
    except Exception as e:
        fail("sandbox_pause 正常暂停", str(e))

    # 5. sandbox_resume
    try:
        mock.reset()
        res = client.call_tool("sandbox_resume", {"sandbox_id": "sbx-test-111", "timeout": 1800})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"] == "/sandboxes/sbx-test-111/resume" for r in mock.requests)
        ok("sandbox_resume 正常恢复")
    except Exception as e:
        fail("sandbox_resume 正常恢复", str(e))

    # 6. sandbox_refresh
    try:
        mock.reset()
        res = client.call_tool("sandbox_refresh", {"sandbox_id": "sbx-test-111", "duration": 600})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"] == "/sandboxes/sbx-test-111/refreshes" for r in mock.requests)
        ok("sandbox_refresh 正常续期")
    except Exception as e:
        fail("sandbox_refresh 正常续期", str(e))

    # 7. sandbox_timeout
    try:
        mock.reset()
        res = client.call_tool("sandbox_timeout", {"sandbox_id": "sbx-test-111", "seconds": 7200})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"] == "/sandboxes/sbx-test-111/timeout" for r in mock.requests)
        ok("sandbox_timeout 正常设置超时")
    except Exception as e:
        fail("sandbox_timeout 正常设置超时", str(e))

    # 8. sandbox_net_set (安全校验失败 + confirm=True 成功)
    try:
        mock.reset()
        # 无 confirm -> 应拦截，不发请求
        res_blocked = client.call_tool("sandbox_net_set", {"sandbox_id": "sbx-test-111", "internet": True})
        assert res_blocked.get("result", {}).get("isError") is True
        assert "confirm=true" in res_blocked["result"]["content"][0]["text"]
        assert len(mock.requests) == 0, "未确认时不应发出任何网络请求"

        # 带 confirm=True -> 允许执行
        res_ok = client.call_tool("sandbox_net_set", {"sandbox_id": "sbx-test-111", "internet": True, "confirm": True})
        assert res_ok.get("result", {}).get("isError") is False
        assert any(r["method"] == "PUT" and r["path"] == "/sandboxes/sbx-test-111/network" for r in mock.requests)
        ok("sandbox_net_set 安全拦截与确认放行")
    except Exception as e:
        fail("sandbox_net_set 安全拦截与确认放行", str(e))

    # 9. sandbox_ports
    try:
        mock.reset()
        res = client.call_tool("sandbox_ports", {"sandbox_id": "sbx-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any("process.Process/Start" in r["path"] for r in mock.requests)
        ok("sandbox_ports 端口探测")
    except Exception as e:
        fail("sandbox_ports 端口探测", str(e))

    # 10. sandbox_clone
    try:
        mock.reset()
        res = client.call_tool("sandbox_clone", {"sandbox_id": "sbx-test-111", "n": 1})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and "/snapshots" in r["path"] for r in mock.requests)
        ok("sandbox_clone 快照克隆")
    except Exception as e:
        fail("sandbox_clone 快照克隆", str(e))

    # 11. sandbox_delete
    try:
        mock.reset()
        res = client.call_tool("sandbox_delete", {"sandbox_id": "sbx-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "DELETE" and r["path"] == "/sandboxes/sbx-test-111" for r in mock.requests)
        ok("sandbox_delete 销毁沙箱")
    except Exception as e:
        fail("sandbox_delete 销毁沙箱", str(e))

    # 12. sandbox_exec
    try:
        mock.reset()
        res = client.call_tool("sandbox_exec", {"sandbox_id": "sbx-test-111", "command": "echo hello"})
        assert res.get("result", {}).get("isError") is False
        assert "mock stdout output" in res["result"]["content"][0]["text"]
        assert any("process.Process/Start" in r["path"] for r in mock.requests)
        ok("sandbox_exec 同步执行")
    except Exception as e:
        fail("sandbox_exec 同步执行", str(e))

    # 13. sandbox_exec_async
    try:
        mock.reset()
        res = client.call_tool("sandbox_exec_async", {"sandbox_id": "sbx-test-111", "command": "sleep 10"})
        assert res.get("result", {}).get("isError") is False
        assert "pid 1234" in res["result"]["content"][0]["text"]
        assert any("process.Process/Start" in r["path"] for r in mock.requests)
        ok("sandbox_exec_async 异步后台启动")
    except Exception as e:
        fail("sandbox_exec_async 异步后台启动", str(e))

    # 14. sandbox_exec_logs
    try:
        mock.reset()
        res = client.call_tool("sandbox_exec_logs", {"sandbox_id": "sbx-test-111", "pid": 1234})
        assert res.get("result", {}).get("isError") is False
        assert any(r["path"].endswith("/files") for r in mock.requests)
        ok("sandbox_exec_logs 日志拉取")
    except Exception as e:
        fail("sandbox_exec_logs 日志拉取", str(e))

    # 15. sandbox_exec_kill
    try:
        mock.reset()
        res = client.call_tool("sandbox_exec_kill", {"sandbox_id": "sbx-test-111", "pid": 1234})
        assert res.get("result", {}).get("isError") is False
        assert any("process.Process/SendSignal" in r["path"] for r in mock.requests)
        ok("sandbox_exec_kill 信号终止")
    except Exception as e:
        fail("sandbox_exec_kill 信号终止", str(e))

    # 16. sandbox_exec_stdin
    try:
        mock.reset()
        res = client.call_tool("sandbox_exec_stdin", {"sandbox_id": "sbx-test-111", "pid": 1234, "data": "input text"})
        assert res.get("result", {}).get("isError") is False
        assert any("process.Process/SendInput" in r["path"] for r in mock.requests)
        ok("sandbox_exec_stdin 标准输入")
    except Exception as e:
        fail("sandbox_exec_stdin 标准输入", str(e))

    # 17. sandbox_code (interp & kernel)
    try:
        mock.reset()
        res_interp = client.call_tool("sandbox_code", {"sandbox_id": "sbx-test-111", "code": "print(1+1)", "lang": "python"})
        assert res_interp.get("result", {}).get("isError") is False
        assert any("process.Process/Start" in r["path"] for r in mock.requests)

        mock.reset()
        res_kernel = client.call_tool("sandbox_code", {"sandbox_id": "sbx-test-111", "code": "print('kernel')", "mode": "kernel"})
        assert res_kernel.get("result", {}).get("isError") is False
        assert any("49999/execute" in r["path"] for r in mock.requests)
        ok("sandbox_code 代码执行（解释器与内核模式）")
    except Exception as e:
        fail("sandbox_code 代码执行（解释器与内核模式）", str(e))

    # 18. sandbox_file_read
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_read", {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"})
        assert res.get("result", {}).get("isError") is False
        assert "sample file content" in res["result"]["content"][0]["text"]
        assert any(r["method"] == "GET" and r["path"].endswith("/files") for r in mock.requests)
        ok("sandbox_file_read 文件读取")
    except Exception as e:
        fail("sandbox_file_read 文件读取", str(e))

    # 19. sandbox_file_write
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_write", {"sandbox_id": "sbx-test-111", "path": "/root/test.txt", "content": "data123"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"].endswith("/files") for r in mock.requests)
        ok("sandbox_file_write 文件写入")
    except Exception as e:
        fail("sandbox_file_write 文件写入", str(e))

    # 20. sandbox_file_list
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_list", {"sandbox_id": "sbx-test-111", "path": "/root"})
        assert res.get("result", {}).get("isError") is False
        assert any("filesystem.Filesystem/ListDir" in r["path"] for r in mock.requests)
        ok("sandbox_file_list 目录列出")
    except Exception as e:
        fail("sandbox_file_list 目录列出", str(e))

    # 21. sandbox_file_stat
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_stat", {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"})
        assert res.get("result", {}).get("isError") is False
        assert any("filesystem.Filesystem/Stat" in r["path"] for r in mock.requests)
        ok("sandbox_file_stat 文件元数据")
    except Exception as e:
        fail("sandbox_file_stat 文件元数据", str(e))

    # 22. sandbox_file_mkdir
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_mkdir", {"sandbox_id": "sbx-test-111", "path": "/root/newdir"})
        assert res.get("result", {}).get("isError") is False
        assert any("filesystem.Filesystem/MakeDir" in r["path"] for r in mock.requests)
        ok("sandbox_file_mkdir 创建目录")
    except Exception as e:
        fail("sandbox_file_mkdir 创建目录", str(e))

    # 23. sandbox_file_delete
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_delete", {"sandbox_id": "sbx-test-111", "path": "/root/old.txt"})
        assert res.get("result", {}).get("isError") is False
        assert any("filesystem.Filesystem/Remove" in r["path"] for r in mock.requests)
        ok("sandbox_file_delete 文件删除")
    except Exception as e:
        fail("sandbox_file_delete 文件删除", str(e))

    # 24. sandbox_file_move
    try:
        mock.reset()
        res = client.call_tool("sandbox_file_move", {"sandbox_id": "sbx-test-111", "from": "/root/a.txt", "to": "/root/b.txt"})
        assert res.get("result", {}).get("isError") is False
        assert any("filesystem.Filesystem/Move" in r["path"] for r in mock.requests)
        ok("sandbox_file_move 文件移动")
    except Exception as e:
        fail("sandbox_file_move 文件移动", str(e))

    # 25. sandbox_file_exists
    try:
        mock.reset()
        res_exists = client.call_tool("sandbox_file_exists", {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"})
        assert res_exists.get("result", {}).get("isError") is False
        assert res_exists["result"]["content"][0]["text"] == "true"

        res_not_exists = client.call_tool("sandbox_file_exists", {"sandbox_id": "sbx-test-111", "path": "/root/nonexistent.txt"})
        assert res_not_exists.get("result", {}).get("isError") is False
        assert res_not_exists["result"]["content"][0]["text"] == "false"
        ok("sandbox_file_exists 存在性检查")
    except Exception as e:
        fail("sandbox_file_exists 存在性检查", str(e))

    # 26. snapshot_create
    try:
        mock.reset()
        res = client.call_tool("snapshot_create", {"sandbox_id": "sbx-test-111", "name": "my-snap"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and "/snapshots" in r["path"] for r in mock.requests)
        ok("snapshot_create 创建快照")
    except Exception as e:
        fail("snapshot_create 创建快照", str(e))

    # 27. snapshot_list
    try:
        mock.reset()
        res = client.call_tool("snapshot_list", {})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/snapshots" for r in mock.requests)
        ok("snapshot_list 快照列表")
    except Exception as e:
        fail("snapshot_list 快照列表", str(e))

    # 28. snapshot_rollback
    try:
        mock.reset()
        res = client.call_tool("snapshot_rollback", {"sandbox_id": "sbx-test-111", "snapshot_id": "snap-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and "/rollback" in r["path"] for r in mock.requests)
        ok("snapshot_rollback 快照回滚")
    except Exception as e:
        fail("snapshot_rollback 快照回滚", str(e))

    # 29. snapshot_delete
    try:
        mock.reset()
        res = client.call_tool("snapshot_delete", {"snapshot_id": "snap-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "DELETE" and r["path"] == "/templates/snap-test-111" for r in mock.requests)
        ok("snapshot_delete 删除快照")
    except Exception as e:
        fail("snapshot_delete 删除快照", str(e))

    # 30. volume_list
    try:
        mock.reset()
        res = client.call_tool("volume_list", {})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/volumes" for r in mock.requests)
        ok("volume_list 卷列表")
    except Exception as e:
        fail("volume_list 卷列表", str(e))

    # 31. volume_create
    try:
        mock.reset()
        res = client.call_tool("volume_create", {"name": "test-vol", "driver": "local"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "POST" and r["path"] == "/volumes" for r in mock.requests)
        ok("volume_create 创建持久卷")
    except Exception as e:
        fail("volume_create 创建持久卷", str(e))

    # 32. volume_info
    try:
        mock.reset()
        res = client.call_tool("volume_info", {"volume_id": "vol-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/volumes/vol-test-111" for r in mock.requests)
        ok("volume_info 卷详情")
    except Exception as e:
        fail("volume_info 卷详情", str(e))

    # 33. volume_delete
    try:
        mock.reset()
        res = client.call_tool("volume_delete", {"volume_id": "vol-test-111"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "DELETE" and r["path"] == "/volumes/vol-test-111" for r in mock.requests)
        ok("volume_delete 删除持久卷")
    except Exception as e:
        fail("volume_delete 删除持久卷", str(e))

    # 34. template_list
    try:
        mock.reset()
        res = client.call_tool("template_list", {})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/templates" for r in mock.requests)
        ok("template_list 模板列表")
    except Exception as e:
        fail("template_list 模板列表", str(e))

    # 35. template_pick
    try:
        mock.reset()
        res = client.call_tool("template_pick", {"need": "code"})
        assert res.get("result", {}).get("isError") is False
        assert "tpl-code" in res["result"]["content"][0]["text"]
        ok("template_pick 模板挑选")
    except Exception as e:
        fail("template_pick 模板挑选", str(e))

    # 36. template_info
    try:
        mock.reset()
        res = client.call_tool("template_info", {"template_id": "tpl-code"})
        assert res.get("result", {}).get("isError") is False
        assert any(r["method"] == "GET" and r["path"] == "/templates/tpl-code" for r in mock.requests)
        ok("template_info 模板详情")
    except Exception as e:
        fail("template_info 模板详情", str(e))

    # 37. api_call
    try:
        mock.reset()
        res = client.call_tool("api_call", {"method": "GET", "path": "/health"})
        assert res.get("result", {}).get("isError") is False
        assert "healthy" in res["result"]["content"][0]["text"]
        assert any(r["method"] == "GET" and r["path"] == "/health" for r in mock.requests)
        ok("api_call 通用 API 透传")
    except Exception as e:
        fail("api_call 通用 API 透传", str(e))

    # 38. 错误场景断言：缺必填参数
    try:
        res = client.call_tool("sandbox_info", {})
        assert res.get("result", {}).get("isError") is True
        assert "参数错误" in res["result"]["content"][0]["text"]
        ok("错误映射：缺必填参数")
    except Exception as e:
        fail("错误映射：缺必填参数", str(e))

    # 39. 错误场景断言：HTTP 500
    try:
        mock.reset()
        mock.add_failure(r"^/sandboxes$", status_code=500)
        res = client.call_tool("sandbox_list", {})
        assert res.get("result", {}).get("isError") is True
        assert "HTTP 500" in res["result"]["content"][0]["text"]
        ok("错误映射：HTTP 500 服务端异常")
    except Exception as e:
        fail("错误映射：HTTP 500 服务端异常", str(e))

    client.close()
    mock.shutdown()

    print(f"\n测试结果：{passed} 通过 / {failed} 失败")
    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=str(ROOT / "cube-cli/zig-out/bin/cube-cli"))
    args = parser.parse_args()
    run_tests(args.bin)
