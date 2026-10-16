#!/usr/bin/env python3
"""aiod-cli MCP 工具全覆盖测试套件（真实 aiod-cli 二进制 + 本地 mock 服务端）。
对每个已实现的 MCP 工具进行调用测试，断言：
  (a) MCP 响应结构正确（JSON-RPC 2.0，content 格式规范）；
  (b) mock 收到对应的方法、路径与关键字段；
  (c) 异常场景（参数缺失、后端 HTTP 500、业务 success=false）正确映射到 isError: true。
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time

from mock_aiod_server import MockAiodServer

PASSED = 0
FAILED = 0
FAILURES = []


def ok(name):
    global PASSED
    PASSED += 1
    print(f"  [PASS] {name}")


def bad(name, detail):
    global FAILED
    FAILED += 1
    FAILURES.append((name, detail))
    print(f"  [FAIL] {name}: {detail}")


class McpClient:
    def __init__(self, binary, base_url):
        env = dict(os.environ)
        env["SANDBOX_BASE"] = base_url
        env.pop("SANDBOX_KEY", None)
        self.proc = subprocess.Popen(
            [binary, "mcp-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=0,
        )
        self.req_id = 0
        # 执行 initialize 握手
        init_res = self.call("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test-client", "version": "1.0.0"}
        })
        assert "result" in init_res, f"initialize failed: {init_res}"
        self.notify("notifications/initialized")

    def call(self, method, params=None):
        self.req_id += 1
        msg = {
            "jsonrpc": "2.0",
            "id": self.req_id,
            "method": method,
        }
        if params is not None:
            msg["params"] = params
        line = json.dumps(msg, ensure_ascii=False) + "\n"
        self.proc.stdin.write(line.encode("utf-8"))
        self.proc.stdin.flush()
        resp_line = self.proc.stdout.readline()
        if not resp_line:
            err = self.proc.stderr.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"MCP server died. Stderr: {err}")
        return json.loads(resp_line.decode("utf-8"))

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        line = json.dumps(msg, ensure_ascii=False) + "\n"
        self.proc.stdin.write(line.encode("utf-8"))
        self.proc.stdin.flush()

    def call_tool(self, tool_name, args):
        return self.call("tools/call", {"name": tool_name, "arguments": args})

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()


def run_tests(binary):
    mock = MockAiodServer()
    mock.start()
    print(f"Mock server running on {mock.base_url}")

    client = McpClient(binary, mock.base_url)

    # 1. 获取工具列表
    tools_res = client.call("tools/list")
    assert "result" in tools_res and "tools" in tools_res["result"]
    tool_names = {t["name"] for t in tools_res["result"]["tools"]}
    print(f"tools/list 返回 {len(tool_names)} 个工具")
    ok(f"tools/list 包含工具数量 = {len(tool_names)}")

    # 2. 逐工具测试表: (tool_name, arguments, expected_mock_method, expected_mock_path_prefix, check_body_fn)
    test_specs = [
        # --- Exec domain ---
        ("exec", {"command": "echo hello", "cwd": "/root", "timeout": 5000},
         "POST", "/v2/commands", lambda b: "echo hello" in b and "/root" in b),
        ("exec_async", {"command": "sleep 10"},
         "POST", "/v2/commands", lambda b: '"mode":"async"' in b),
        ("exec_logs", {"command_id": "cmd-test-1", "offset": 10, "wait": True},
         "GET", "/v2/commands/cmd-test-1", None),
        ("exec_kill", {"command_id": "cmd-test-1", "signal": "SIGTERM"},
         "POST", "/v2/commands/cmd-test-1/kill", lambda b: "SIGTERM" in b),
        ("exec_stdin", {"command_id": "cmd-test-1", "text": "hello\n", "enter": True},
         "POST", "/v2/commands/cmd-test-1/stdin", lambda b: "hello" in b),
        ("session_create", {"session_id": "sess-test-1", "cwd": "/app"},
         "POST", "/v2/commands/sessions", lambda b: "sess-test-1" in b),
        ("session_list", {},
         "GET", "/v2/commands/sessions", None),
        ("session_delete", {"session_id": "sess-test-1"},
         "DELETE", "/v2/commands/sessions/sess-test-1", None),
        ("exec_in_session", {"session_id": "sess-test-1", "command": "ls"},
         "POST", "/v2/commands", lambda b: "sess-test-1" in b and "ls" in b),

        # --- Files domain ---
        ("file_read", {"path": "/root/test.txt", "start": 0, "end": 10},
         "GET", "/v2/fs/read", None),
        ("file_write", {"path": "/root/test.txt", "content": "abc", "append": True},
         "POST", "/v2/fs/write", lambda b: "abc" in b and "/root/test.txt" in b),
        ("file_list", {"path": "/root"},
         "GET", "/v2/fs/list", None),
        ("file_stat", {"path": "/root/test.txt", "follow_symlinks": True},
         "GET", "/v2/fs/stat", None),
        ("file_tree", {"path": "/root"},
         "GET", "/v2/fs/tree", None),
        ("file_mkdir", {"path": "/root/newdir", "parents": True},
         "POST", "/v2/fs/mkdir", lambda b: "/root/newdir" in b),
        ("file_delete", {"path": "/root/newdir", "recursive": True},
         "POST", "/v2/fs/delete", lambda b: "/root/newdir" in b),
        ("file_copy", {"from": "/root/a", "to": "/root/b", "overwrite": True},
         "POST", "/v2/fs/copy", lambda b: "/root/a" in b and "/root/b" in b),
        ("file_move", {"from": "/root/a", "to": "/root/b", "overwrite": True},
         "POST", "/v2/fs/move", lambda b: "/root/a" in b and "/root/b" in b),
        ("file_edit", {"path": "/root/a.txt", "old": "x", "new": "y"},
         "POST", "/v2/fs/edit", lambda b: "str_replace" in b and "x" in b),
        ("file_grep", {"path": "/root", "pattern": "key", "ignore_case": True},
         "POST", "/v2/fs/grep", lambda b: "key" in b),
        ("file_search", {"path": "/root", "pattern": "*.py"},
         "GET", "/v2/fs/search", None),

        # --- PTY domain ---
        ("pty_new", {"session_id": "pty-test-1", "cols": 120, "rows": 40},
         "POST", "/v2/pty/sessions", lambda b: "pty-test-1" in b and "120" in b),
        ("pty_list", {},
         "GET", "/v2/pty/sessions", None),
        ("pty_screen", {"session_id": "pty-test-1"},
         "GET", "/v2/pty/sessions/pty-test-1/screen", None),
        ("pty_exec", {"session_id": "pty-test-1", "command": "whoami"},
         "POST", "/v2/pty/sessions/pty-test-1/exec", lambda b: "whoami" in b),
        ("pty_input", {"session_id": "pty-test-1", "text": "ls", "enter": True},
         "POST", "/v2/pty/sessions/pty-test-1/input", lambda b: "ls" in b and "true" in b),
        ("pty_delete", {"session_id": "pty-test-1"},
         "DELETE", "/v2/pty/sessions/pty-test-1", None),
        ("pty_signal", {"session_id": "pty-test-1", "signal": "SIGINT"},
         "POST", "/v2/pty/sessions/pty-test-1/signal", lambda b: "SIGINT" in b),
        ("pty_resize", {"session_id": "pty-test-1", "cols": 100, "rows": 30},
         "PATCH", "/v2/pty/sessions/pty-test-1", lambda b: "100" in b and "30" in b),

        # --- Misc domain ---
        ("sandbox_info", {},
         "GET", "/v2/sandbox", None),
        ("code_run", {"code": "print(1+1)", "lang": "python"},
         "POST", "/v2/code/execute", lambda b: "print(1+1)" in b),
        ("code_info", {},
         "GET", "/v2/code/info", None),
        ("watch_create", {"path": "/root", "recursive": True, "debounce": 200},
         "POST", "/v2/watch", lambda b: "200" in b),
        ("watch_poll", {"watcher_id": "watch-1", "cursor": "c-0"},
         "GET", "/v2/watch/watch-1/poll", None),
        ("watch_rm", {"watcher_id": "watch-1"},
         "DELETE", "/v2/watch/watch-1", None),
        ("watch_ls", {},
         "GET", "/v2/watch", None),
        ("mcp_hub", {"method": "tools/list", "params": {}},
         "POST", "/mcp", lambda b: "tools/list" in b),

        # --- Browser domain ---
        ("browser_info", {},
         "GET", "/v2/browser/info", None),
        ("browser_navigate", {"url": "https://example.com", "wait": "networkidle"},
         "POST", "/v2/browser/navigate", lambda b: "example.com" in b),
        ("browser_evaluate", {"expression": "window.location.href", "await": True},
         "POST", "/v2/browser/evaluate", lambda b: "window.location.href" in b),
        ("browser_click", {"selector": "button.submit"},
         "POST", "/v2/browser/click", lambda b: "button.submit" in b),
        ("browser_fill", {"selector": "input#username", "value": "alice"},
         "POST", "/v2/browser/fill", lambda b: "alice" in b),
        ("browser_snapshot", {"interactive": True},
         "POST", "/v2/browser/snapshot", lambda b: "interactive_only" in b),
        ("browser_tabs", {},
         "GET", "/v2/browser/tabs", None),
        ("browser_screenshot", {"full": True},
         "GET", "/v2/browser/screenshot", None),
        ("browser_tab_new", {"url": "https://example.com/new"},
         "POST", "/v2/browser/tabs", lambda b: "new" in b),
        ("browser_tab_use", {"tab_id": "tab-1"},
         "POST", "/v2/browser/tabs/tab-1", None),
        ("browser_tab_close", {"tab_id": "tab-1"},
         "DELETE", "/v2/browser/tabs/tab-1", None),
        ("browser_cookies", {"domain": "example.com"},
         "GET", "/v2/browser/cookies", None),
        ("browser_cookie_set", {"cookie": {"name": "uid", "value": "123"}},
         "POST", "/v2/browser/cookies", lambda b: "uid" in b and "123" in b),
        ("browser_cookie_delete", {"name": "uid"},
         "DELETE", "/v2/browser/cookies", None),
        ("browser_upload", {"paths": ["/tmp/file.png"], "selector": "input[type=file]"},
         "POST", "/v2/browser/upload", lambda b: "/tmp/file.png" in b),
        ("browser_network", {"limit": 20, "clear": True},
         "GET", "/v2/browser/network/requests", None),
        ("browser_config", {"resolution": "1920x1080"},
         "POST", "/v2/browser/config", lambda b: "1920" in b and "1080" in b),
        ("browser_cdp", {"method": "Page.reload", "params": {}},
         "POST", "/v2/browser/cdp", lambda b: "Page.reload" in b),

        # --- Desktop domain ---
        ("desktop_info", {},
         "GET", "/v2/computer/info", None),
        ("desktop_screenshot", {},
         "GET", "/v2/computer/screenshot", None),
        ("desktop_cursor", {},
         "GET", "/v2/computer/cursor", None),
        ("desktop_clipboard", {},
         "GET", "/v2/computer/clipboard", None),
        ("desktop_windows", {},
         "GET", "/v2/computer/windows", None),
        ("desktop_a11y", {"max_depth": 5},
         "GET", "/v2/computer/accessibility", None),
        ("desktop_a11y_nodes", {"role": "button"},
         "GET", "/v2/computer/accessibility/nodes", None),
        ("desktop_act", {"action": {"action": "click", "x": 100, "y": 200}, "screenshot": True},
         "POST", "/v2/computer/actions", lambda b: "CLICK" in b or "click" in b),
        ("desktop_act_batch", {"actions": [{"action": "move_to", "x": 50, "y": 60}], "screenshot": False},
         "POST", "/v2/computer/actions/batch", lambda b: "MOVE_TO" in b or "move_to" in b),
        ("desktop_record", {"action": "start", "fps": 30, "save_path": "/tmp/rec.mp4"},
         "POST", "/v2/computer/record", lambda b: "rec.mp4" in b),
    ]

    for name, args, exp_method, exp_path_prefix, check_body in test_specs:
        if name not in tool_names:
            bad(f"tool {name}", "工具未在 tools/list 声明")
            continue

        mock.clear_requests()
        res = client.call_tool(name, args)

        # 断言 1: MCP 返回格式正确且非错误
        if res.get("error"):
            bad(f"tool {name}", f"返回协议错误: {res['error']}")
            continue
        result = res.get("result", {})
        if result.get("isError") is True:
            content = result.get("content", [])
            err_text = content[0].get("text", "") if content else ""
            bad(f"tool {name}", f"isError=True: {err_text}")
            continue
        content = result.get("content", [])
        if not content:
            bad(f"tool {name}", "result.content 为空")
            continue

        # 特殊断言：如果是图片工具（browser_screenshot / desktop_screenshot），必须包含 image 类型 content
        if name in ("browser_screenshot", "desktop_screenshot"):
            has_image = any(c.get("type") == "image" and len(c.get("data", "")) > 0 for c in content)
            if not has_image:
                bad(f"tool {name}", "未能返回 image 类型 content")
                continue

        # 断言 2: mock 收到正确的请求
        reqs = mock.requests()
        if not reqs:
            bad(f"tool {name}", "mock 未收到任何请求")
            continue
        last_req = reqs[-1]
        if last_req["method"] != exp_method:
            bad(f"tool {name}", f"方法不匹配: 期望 {exp_method}, 收到 {last_req['method']}")
            continue
        if not last_req["path"].startswith(exp_path_prefix):
            bad(f"tool {name}", f"路径不匹配: 期望前缀 {exp_path_prefix}, 收到 {last_req['path']}")
            continue
        if check_body and not check_body(last_req["body"]):
            bad(f"tool {name}", f"请求体不匹配: {last_req['body']}")
            continue

        ok(f"tool {name} 正常调用")

    # 3. 异常场景测试
    # 场景 A: 缺失必填参数 -> isError=True，且提示 "参数错误"
    mock.clear_requests()
    res_arg_err = client.call_tool("exec", {})
    r_arg = res_arg_err.get("result", {})
    if r_arg.get("isError") is True and "参数错误" in r_arg.get("content", [{}])[0].get("text", ""):
        ok("异常场景 A: 缺失必填参数 -> isError=True 且提示参数错误")
    else:
        bad("异常场景 A", f"未正确处理缺参: {res_arg_err}")

    # 场景 B: 目标路径不存在或失败 -> HTTP 500 处理
    mock.clear_requests()
    res_500 = client.call_tool("exec", {"command": "fail_500=true"})
    r_500 = res_500.get("result", {})
    if r_500.get("isError") is True and "HTTP 500" in r_500.get("content", [{}])[0].get("text", ""):
        ok("异常场景 B: 服务端 HTTP 500 -> isError=True 且呈现 HTTP 500 现场")
    else:
        bad("异常场景 B", f"未正确呈现 500: {res_500}")

    # 场景 C: 业务错误 success=false -> isError=True 且提取 message
    mock.clear_requests()
    res_biz = client.call_tool("exec", {"command": "fail_api=true"})
    r_biz = res_biz.get("result", {})
    if r_biz.get("isError") is True and "模拟 API 业务错误" in r_biz.get("content", [{}])[0].get("text", ""):
        ok("异常场景 C: 业务信封 success:false -> isError=True 且正确提取业务错误 message")
    else:
        bad("异常场景 C", f"未正确提取业务错误: {res_biz}")

    client.close()
    mock.stop()

    print(f"\n==========================================")
    print(f"aiod-cli 工具套件测试结果: {PASSED} 通过 / {FAILED} 失败")
    print(f"==========================================")
    if FAILED > 0:
        for name, detail in FAILURES:
            print(f"  FAILED: {name} -> {detail}")
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default="aiod-cli/zig-out/bin/aiod-cli")
    args = parser.parse_args()
    run_tests(args.bin)
