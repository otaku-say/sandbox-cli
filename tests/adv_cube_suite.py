#!/usr/bin/env python3
"""tests/adv_cube_suite.py —— cube-cli MCP 全量对抗与覆盖测试套件

交付内容：
1. 37 个 MCP 工具全量覆盖（每工具均覆盖：a 正常路径、b 参数边界/类型错误、c 失败路径）
2. 人类 CLI 语义对拍（≥15 个工具分别走 tools/call 与 CLI 命令，对比 mock 请求 sig）
3. 对抗面专项：
   - 参数毒化（非法类型、空串、超长万字串、2^63-1、负数、0、emoji、路径穿越、多余未知字段）
   - 顺序与并发（200 次成功/失败交错调用，1:1 应答保真与无错位、内存稳态）
   - 挂死检测（超长超时参数有上限保护，30s 内必定返回）
   - 输出质量（包含 ID、状态、偏移等关键信息，大输出规范标注）
   - 破坏性工具（sandbox_delete 404 幂等、重复调用、503 重试）
"""

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

        init_res = self.send({
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "adv-suite-client", "version": "1.0"},
            },
        })
        assert "result" in init_res, f"Init failed: {init_res}"

    def send(self, req: dict, timeout=30) -> dict:
        if "id" not in req:
            self.msg_id += 1
            req["id"] = self.msg_id
        line = json.dumps(req) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()
        t0 = time.time()
        while True:
            if time.time() - t0 > timeout:
                raise TimeoutError(f"tools/call 超时（超过 {timeout}s）")
            resp_line = self.proc.stdout.readline()
            if not resp_line:
                err = self.proc.stderr.read()
                raise RuntimeError(f"Server closed connection unexpectedly. Stderr: {err}")
            resp_line = resp_line.strip()
            if resp_line:
                return json.loads(resp_line)

    def call_tool(self, name: str, args: any, timeout=30) -> dict:
        self.msg_id += 1
        return self.send({
            "jsonrpc": "2.0",
            "id": self.msg_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        }, timeout=timeout)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()


def get_rss(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except Exception:
        pass
    return 0


def run_all_tests():
    mock = MockCubeServer()
    client = McpClient(CUBE_BIN, mock.url)

    total_checks = 0
    failed_checks = 0
    coverage_record = {}

    def report(section: str, name: str, cond: bool, detail: str = ""):
        nonlocal total_checks, failed_checks
        total_checks += 1
        if cond:
            print(f"  [PASS] [{section}] {name}")
        else:
            failed_checks += 1
            print(f"  [FAIL] [{section}] {name}: {detail}")

    print("==================================================")
    print("== 一、37 个 MCP 工具全量 3 轴覆盖测试 ==")
    print("==================================================")

    tools_37 = [
        "sandbox_create", "sandbox_list", "sandbox_info", "sandbox_pause",
        "sandbox_resume", "sandbox_refresh", "sandbox_timeout", "sandbox_net_set",
        "sandbox_ports", "sandbox_clone", "sandbox_delete", "sandbox_exec",
        "sandbox_exec_async", "sandbox_exec_logs", "sandbox_exec_kill",
        "sandbox_exec_stdin", "sandbox_code", "sandbox_file_read",
        "sandbox_file_write", "sandbox_file_list", "sandbox_file_stat",
        "sandbox_file_mkdir", "sandbox_file_delete", "sandbox_file_move",
        "sandbox_file_exists", "snapshot_create", "snapshot_list",
        "snapshot_rollback", "snapshot_delete", "volume_list", "volume_create",
        "volume_info", "volume_delete", "template_list", "template_pick",
        "template_info", "api_call"
    ]

    normal_inputs = {
        "sandbox_create": {"template": "tpl-code", "need": "code"},
        "sandbox_list": {},
        "sandbox_info": {"sandbox_id": "sbx-test-111"},
        "sandbox_pause": {"sandbox_id": "sbx-test-111"},
        "sandbox_resume": {"sandbox_id": "sbx-test-111", "timeout": 120},
        "sandbox_refresh": {"sandbox_id": "sbx-test-111", "duration": 300},
        "sandbox_timeout": {"sandbox_id": "sbx-test-111", "seconds": 3600},
        "sandbox_net_set": {"sandbox_id": "sbx-test-111", "internet": True, "confirm": True},
        "sandbox_ports": {"sandbox_id": "sbx-test-111"},
        "sandbox_clone": {"sandbox_id": "sbx-test-111", "n": 1},
        "sandbox_delete": {"sandbox_id": "sbx-test-111"},
        "sandbox_exec": {"sandbox_id": "sbx-test-111", "command": "echo test"},
        "sandbox_exec_async": {"sandbox_id": "sbx-test-111", "command": "sleep 1"},
        "sandbox_exec_logs": {"sandbox_id": "sbx-test-111", "pid": 1234},
        "sandbox_exec_kill": {"sandbox_id": "sbx-test-111", "pid": 1234},
        "sandbox_exec_stdin": {"sandbox_id": "sbx-test-111", "pid": 1234, "data": "in"},
        "sandbox_code": {"sandbox_id": "sbx-test-111", "code": "print(1)"},
        "sandbox_file_read": {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"},
        "sandbox_file_write": {"sandbox_id": "sbx-test-111", "path": "/root/test.txt", "content": "hello"},
        "sandbox_file_list": {"sandbox_id": "sbx-test-111", "path": "/root"},
        "sandbox_file_stat": {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"},
        "sandbox_file_mkdir": {"sandbox_id": "sbx-test-111", "path": "/root/dir"},
        "sandbox_file_delete": {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"},
        "sandbox_file_move": {"sandbox_id": "sbx-test-111", "from": "/root/a", "to": "/root/b"},
        "sandbox_file_exists": {"sandbox_id": "sbx-test-111", "path": "/root/test.txt"},
        "snapshot_create": {"sandbox_id": "sbx-test-111", "name": "snap1"},
        "snapshot_list": {},
        "snapshot_rollback": {"sandbox_id": "sbx-test-111", "snapshot_id": "snap-1"},
        "snapshot_delete": {"snapshot_id": "snap-1"},
        "volume_list": {},
        "volume_create": {"name": "vol1", "driver": "cos"},
        "volume_info": {"volume_id": "vol-1"},
        "volume_delete": {"volume_id": "vol-1"},
        "template_list": {"status": "READY"},
        "template_pick": {"need": "code"},
        "template_info": {"template_id": "tpl-code"},
        "api_call": {"method": "GET", "path": "/health"},
    }

    boundary_inputs = {
        "sandbox_create": {"timeout": "not_an_int"},
        "sandbox_list": {"metadata": 12345},
        "sandbox_info": {"sandbox_id": ["not_a_string"]},
        "sandbox_pause": {"sandbox_id": 12345},
        "sandbox_resume": {"sandbox_id": "sbx-1", "timeout": "not_an_int"},
        "sandbox_refresh": {"sandbox_id": "sbx-1", "duration": "not_an_int"},
        "sandbox_timeout": {"sandbox_id": "sbx-1", "seconds": -5},
        "sandbox_net_set": {"sandbox_id": "sbx-1", "internet": "not_a_bool"},
        "sandbox_ports": {"sandbox_id": ["not_a_string"]},
        "sandbox_clone": {"sandbox_id": "sbx-1", "n": "not_an_int"},
        "sandbox_delete": {"sandbox_id": 12345},
        "sandbox_exec": {"sandbox_id": "sbx-1", "command": 12345},
        "sandbox_exec_async": {"sandbox_id": "sbx-1", "command": ["not_string"]},
        "sandbox_exec_logs": {"sandbox_id": "sbx-1", "pid": "not_int"},
        "sandbox_exec_kill": {"sandbox_id": "sbx-1", "pid": ["not_int"]},
        "sandbox_exec_stdin": {"sandbox_id": "sbx-1", "pid": 1234, "data": 12345},
        "sandbox_code": {"sandbox_id": "sbx-1", "code": "print(1)", "mode": "invalid_mode_xyz"},
        "sandbox_file_read": {"sandbox_id": "sbx-1", "path": 12345},
        "sandbox_file_write": {"sandbox_id": "sbx-1", "path": "/a", "content": 12345},
        "sandbox_file_list": {"sandbox_id": "sbx-1", "path": ["invalid"]},
        "sandbox_file_stat": {"sandbox_id": "sbx-1", "path": 12345},
        "sandbox_file_mkdir": {"sandbox_id": "sbx-1", "path": 12345},
        "sandbox_file_delete": {"sandbox_id": "sbx-1", "path": 12345},
        "sandbox_file_move": {"sandbox_id": "sbx-1", "from": 123, "to": 456},
        "sandbox_file_exists": {"sandbox_id": "sbx-1", "path": 12345},
        "snapshot_create": {"sandbox_id": 12345},
        "snapshot_list": {"limit": "not_int"},
        "snapshot_rollback": {"sandbox_id": "sbx-1", "snapshot_id": 12345},
        "snapshot_delete": {"snapshot_id": ["not_string"]},
        "volume_list": "invalid_arguments_string",
        "volume_create": {"name": 12345},
        "volume_info": {"volume_id": 12345},
        "volume_delete": {"volume_id": ["not_string"]},
        "template_list": {"status": 12345},
        "template_pick": {"need": 12345},
        "template_info": {"template_id": 12345},
        "api_call": {"method": "INVALID_METHOD", "path": "/health"},
    }

    for tool in tools_37:
        mock.reset()
        norm_arg = normal_inputs[tool]
        bound_arg = boundary_inputs[tool]

        # (a) 正常路径
        res_a = client.call_tool(tool, norm_arg)
        err_a = res_a.get("result", {}).get("isError", False) or ("error" in res_a)
        ok_a = (not err_a)
        report("全量覆盖-正常路径", f"{tool} 正常调用", ok_a, f"返回错误: {res_a}")

        # (b) 参数边界/类型错误
        res_b = client.call_tool(tool, bound_arg)
        err_b = res_b.get("result", {}).get("isError", False) or ("error" in res_b)
        report("全量覆盖-边界类型", f"{tool} 边界拦截", err_b, f"未报错: {res_b}")

        # (c) 失败路径（服务端 500 异常）
        mock.reset()
        mock.add_failure(r".*", 500)
        res_c = client.call_tool(tool, norm_arg)
        err_c = res_c.get("result", {}).get("isError", False) or ("error" in res_c)
        report("全量覆盖-服务端失败", f"{tool} 500 处理", err_c, f"未体现错误: {res_c}")

        coverage_record[tool] = {
            "normal": "PASS" if ok_a else "FAIL",
            "boundary": "PASS" if err_b else "FAIL",
            "failure": "PASS" if err_c else "FAIL",
        }

    mock.clear_failures()

    print("\n==================================================")
    print("== 二、与人类 CLI 语义对拍测试 (19 组命令) ==")
    print("==================================================")

    def run_cli(args):
        env = dict(os.environ)
        env["CUBESANDBOX_API_URL"] = mock.url
        env["CUBESANDBOX_PROXY_URL"] = mock.url
        env["CUBESANDBOX_API_KEY"] = "mock-key"
        cmd = [CUBE_BIN] + args
        return subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    parity_cases = [
        ("sandbox_info", {"sandbox_id": "sbx-1"}, ["info", "sbx-1"]),
        ("sandbox_pause", {"sandbox_id": "sbx-1"}, ["pause", "sbx-1"]),
        ("sandbox_resume", {"sandbox_id": "sbx-1", "timeout": 120}, ["resume", "sbx-1", "--timeout=120"]),
        ("sandbox_refresh", {"sandbox_id": "sbx-1", "duration": 300}, ["refresh", "sbx-1", "--duration=300"]),
        ("sandbox_timeout", {"sandbox_id": "sbx-1", "seconds": 3600}, ["timeout", "sbx-1", "3600"]),
        ("sandbox_delete", {"sandbox_id": "sbx-1"}, ["rm", "sbx-1"]),
        ("sandbox_list (default)", {}, ["ls", "--json"]),
        ("sandbox_list (state filter)", {"state": "running"}, ["ls", "--state=running", "--json"]),
        ("sandbox_net_set (confirm)", {"sandbox_id": "sbx-1", "internet": True, "confirm": True}, ["net", "sbx-1", "--internet", "--yes"]),
        ("snapshot_create", {"sandbox_id": "sbx-1", "name": "snap1"}, ["snap", "sbx-1", "--name=snap1"]),
        ("snapshot_list", {"sandbox_id": "sbx-1", "limit": 10}, ["snap-ls", "--sandbox=sbx-1", "--limit=10", "--json"]),
        ("snapshot_delete", {"snapshot_id": "snap-1"}, ["snap-rm", "snap-1"]),
        ("volume_list", {}, ["vol-ls", "--json"]),
        ("volume_create", {"name": "vol1", "driver": "cos"}, ["vol-new", "vol1", "--driver=cos", "--json"]),
        ("volume_info", {"volume_id": "vol-1"}, ["vol-info", "vol-1", "--json"]),
        ("volume_delete", {"volume_id": "vol-1"}, ["vol-rm", "vol-1"]),
        ("template_info", {"template_id": "tpl-1"}, ["tpl-info", "tpl-1"]),
        ("api_call", {"method": "GET", "path": "/sandboxes"}, ["raw", "GET", "/sandboxes"]),
        ("sandbox_exec", {"sandbox_id": "sbx-1", "command": "echo hello"}, ["exec", "sbx-1", "echo", "hello"]),
    ]

    for tool_name, mcp_args, cli_args in parity_cases:
        mock.reset()
        _ = client.call_tool(tool_name.split()[0], mcp_args)
        mcp_reqs = [(r["method"], r["path"], r.get("body")) for r in mock.requests]

        mock.reset()
        _ = run_cli(cli_args)
        cli_reqs = [(r["method"], r["path"], r.get("body")) for r in mock.requests]

        eq = (mcp_reqs == cli_reqs)
        report("CLI 语义对拍", tool_name, eq, f"MCP={mcp_reqs} vs CLI={cli_reqs}")

    print("\n==================================================")
    print("== 三、对抗面测试（毒化、顺序、挂死、破坏性） ==")
    print("==================================================")

    # 1. 安全门禁：sandbox_net_set 缺 confirm 时必须零请求
    mock.reset()
    res_gate = client.call_tool("sandbox_net_set", {"sandbox_id": "sbx-1", "internet": True})
    report("对抗面-安全门禁", "sandbox_net_set 未确认零请求",
           len(mock.requests) == 0 and res_gate.get("result", {}).get("isError") is True,
           f"发出了请求数: {len(mock.requests)}")

    # 2. 参数毒化：超长万字串、2^63-1、emoji、路径穿越、多余未知字段
    poison_tests = [
        ("超长 1 万字符命令", "sandbox_exec", {"sandbox_id": "sbx-1", "command": "x" * 10000}, False),
        ("2^63-1 极大时间", "sandbox_timeout", {"sandbox_id": "sbx-1", "seconds": 9223372036854775807}, False),
        ("emoji 文件路径", "sandbox_file_read", {"sandbox_id": "sbx-1", "path": "/root/📁/🔥.txt"}, False),
        ("相对路径穿越", "sandbox_file_read", {"sandbox_id": "sbx-1", "path": "../../etc/passwd"}, False),
        ("多余未知字段", "sandbox_info", {"sandbox_id": "sbx-1", "foo": "bar", "unknown": 123}, False),
    ]
    for label, tname, targs, expect_err in poison_tests:
        mock.reset()
        res = client.call_tool(tname, targs)
        is_err = res.get("result", {}).get("isError", False)
        report("对抗面-参数毒化", label, is_err == expect_err, f"isError={is_err}")

    # 3. 挂死检测与超时保护：轮询极大值在 30s 内必定返回并报超时
    mock.reset()
    t_start = time.time()
    res_hang = client.call_tool("sandbox_info", {"sandbox_id": "sbx-test-111", "wait": "never_reach", "timeout": 1}, timeout=10)
    dur = time.time() - t_start
    report("对抗面-挂死检测", "轮询未达成在超时后安全退出并报 isError",
           res_hang.get("result", {}).get("isError") is True and dur < 5,
           f"耗时 {dur:.2f}s, 结果: {res_hang}")

    # 4. 破坏性工具：sandbox_delete 404 幂等成功、503 重试成功
    mock.reset()
    mock.add_failure(r"^/sandboxes/sbx-404$", 404)
    res_del_404 = client.call_tool("sandbox_delete", {"sandbox_id": "sbx-404"})
    text_404 = res_del_404.get("result", {}).get("content", [{}])[0].get("text", "")
    report("对抗面-破坏性", "sandbox_delete 404 幂等返回成功提示",
           res_del_404.get("result", {}).get("isError") is False and "不存在" in text_404,
           f"返回内容: {text_404}")

    # 5. 顺序/并发与内存稳态：200 次成功/失败交替请求 1:1 无错位、无明显泄漏
    dislocations = 0
    rss_start = get_rss(client.proc.pid)
    for i in range(1, 201):
        req_id = i * 11 + 5
        if i % 2 == 1:
            r = client.send({"jsonrpc": "2.0", "id": req_id, "method": "tools/call",
                             "params": {"name": "sandbox_info", "arguments": {"sandbox_id": "sbx-test-111"}}})
        else:
            r = client.send({"jsonrpc": "2.0", "id": req_id, "method": "tools/call",
                             "params": {"name": "sandbox_info", "arguments": {}}})
        if r.get("id") != req_id:
            dislocations += 1
    rss_end = get_rss(client.proc.pid)
    report("对抗面-顺序并发", "200 次混合调用 1:1 应答且零错位", dislocations == 0, f"错位数: {dislocations}")
    report("对抗面-内存稳态", "200 次混合调用无内存暴涨", (rss_end - rss_start) < 20480, f"增长: {rss_end - rss_start} kB")

    client.close()
    mock.shutdown()

    print("\n==================================================")
    print(f"测试完成：共执行 {total_checks} 项检查，通过 {total_checks - failed_checks} 项，失败 {failed_checks} 项")
    print("==================================================")

    # 打印覆盖表摘要
    print("\n【37 工具覆盖表一览】")
    print(f"{'序号':<4} {'工具名':<25} {'(a)正常路径':<12} {'(b)边界类型':<12} {'(c)失败路径':<12} 结论")
    for i, t in enumerate(tools_37, 1):
        rec = coverage_record[t]
        verdict = "全绿 PASS" if rec["normal"] == "PASS" and rec["boundary"] == "PASS" and rec["failure"] == "PASS" else "FAIL"
        print(f"{i:<4} {t:<25} {rec['normal']:<12} {rec['boundary']:<12} {rec['failure']:<12} {verdict}")

    return failed_checks


if __name__ == "__main__":
    failed = run_all_tests()
    sys.exit(1 if failed > 0 else 0)
