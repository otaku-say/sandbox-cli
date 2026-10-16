#!/usr/bin/env python3
"""MCP 协议 + stdout 纯净性套件（真实二进制、stdio 子进程、零第三方依赖）。

用法:
    python3 tests/mcp_protocol_test.py --bin <path> --kind cube|aiod [--tools-min N]

断言清单（每条独立计时，失败会明确指出场景）：
  1. 首行即 JSON-RPC 响应（无 banner/启动噪音）
  2. initialize 版本协商（已知版本原样回 / 未知版本回服务端最新）+ capabilities + serverInfo
  3. notifications/initialized 与未知通知：零 stdout 输出
  4. ping → {}
  5. tools/list：schema 全部可解析、type=object、含 properties/required、名字唯一、工具数下限
  6. 未知方法 → -32601；坏 JSON → -32700；顶层数组 → -32600；非对象 → -32600
  7. 未知工具 → -32602；缺必填参数 → result.isError=true
  8. id 保真：整数 / 字符串 / 大整数
  9. 缺配置时工具调用返回可读错误（isError=true，提示对应环境变量）
 10. **stdout 每一行都是合法 JSON-RPC**（核心纯净性断言）
 11. stdin EOF → 退出码 0
"""
import argparse
import json
import os
import select
import subprocess
import sys
import time

FAILURES = []
PASSED = 0
MY_ENV_KEYS = (
    "CUBESANDBOX_API_URL", "CUBESANDBOX_API_KEY", "CUBESANDBOX_PROXY_URL",
    "SANDBOX_BASE", "SANDBOX_KEY",
)


def ok(name):
    global PASSED
    PASSED += 1
    print(f"  ok   {name}")


def bad(name, detail):
    FAILURES.append((name, detail))
    print(f"  FAIL {name}: {detail}")


class Stdio:
    """stdio JSON-RPC 客户端：读行带超时与「纯 JSON 行」校验。"""

    def __init__(self, binary, kind, extra_env=None, extra_args=()):
        env = {k: v for k, v in os.environ.items() if k not in MY_ENV_KEYS}
        if extra_env:
            env.update(extra_env)
        self.p = subprocess.Popen(
            [binary, "mcp-server", *extra_args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, bufsize=0,
        )
        self.buf = b""
        self.lines = []
        self.kind = kind

    def send(self, text):
        if isinstance(text, (dict, list)):
            text = json.dumps(text, ensure_ascii=False)
        self.p.stdin.write(text.encode() + b"\n")
        self.p.stdin.flush()

    def read_line(self, timeout=15.0, require_json=True):
        deadline = time.time() + timeout
        while b"\n" not in self.buf:
            remain = deadline - time.time()
            if remain <= 0:
                raise TimeoutError("等待 stdout 行超时")
            r, _, _ = select.select([self.p.stdout], [], [], remain)
            if not r:
                raise TimeoutError("等待 stdout 行超时（select）")
            chunk = os.read(self.p.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError("stdout 已关闭")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        text = line.decode("utf-8", "replace")
        self.lines.append(text)
        if require_json:
            assert_json_line(text)
        return text

    def read_json(self, timeout=15.0):
        return json.loads(self.read_line(timeout=timeout))

    def expect_silence(self, seconds=1.2):
        """断言在窗口期内没有任何 stdout 输出（通知不得有响应）。"""
        end = time.time() + seconds
        while time.time() < end:
            remain = end - time.time()
            r, _, _ = select.select([self.p.stdout], [], [], remain)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if chunk:
                    self.buf += chunk
                    return False
        return b"\n" not in self.buf

    def stderr_text(self):
        r, _, _ = select.select([self.p.stderr], [], [], 0.5)
        if not r:
            return ""
        return os.read(self.p.stderr.fileno(), 65536).decode("utf-8", "replace")

    def close(self, timeout=10.0):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            return self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            return -1

    def kill(self):
        try:
            self.p.kill()
        except Exception:
            pass


def assert_json_line(text):
    """一行 stdout 必须是合法 JSON-RPC 消息（纯净性的硬约束）。"""
    assert text.startswith("{"), f"stdout 行不是 JSON 对象开头: {text[:120]!r}"
    msg = json.loads(text)  # 解析失败直接抛
    assert msg.get("jsonrpc") == "2.0", f"jsonrpc 字段不是 2.0: {text[:120]!r}"
    assert ("result" in msg) or ("error" in msg), f"既无 result 也无 error: {text[:120]!r}"
    assert "\n" not in json.dumps(msg), "消息体内含裸换行"


def case(name):
    def deco(fn):
        fn._case_name = name
        return fn
    return deco


# ---------------------------------------------------------------- 测试用例

@case("initialize / ping / tools-list 基本闭环")
def t_basic(c):
    c.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "proto-test", "version": "1.0"}}})
    r = c.read_json()
    assert r["id"] == 1, f"id 未回填: {r}"
    res = r["result"]
    assert res["protocolVersion"] == "2025-06-18", f"已知版本应原样回: {res}"
    assert res["capabilities"]["tools"] is not None, "capabilities.tools 缺失"
    assert res["serverInfo"]["name"], "serverInfo.name 缺失"
    assert res["serverInfo"]["version"], "serverInfo.version 缺失"

    # 未知版本 → 回服务端最新
    c.send({"jsonrpc": "2.0", "id": 2, "method": "initialize",
            "params": {"protocolVersion": "1999-01-01"}})
    r2 = c.read_json()
    assert r2["result"]["protocolVersion"] == "2025-06-18", f"未知版本应回最新: {r2['result']}"

    c.send({"jsonrpc": "2.0", "id": 3, "method": "ping"})
    assert c.read_json()["result"] == {}, "ping 应回空对象"


@case("通知不得产生任何输出")
def t_notifications(c):
    c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert c.expect_silence(), "notifications/initialized 不应有任何输出"
    c.send({"jsonrpc": "2.0", "method": "notifications/whatever"})
    assert c.expect_silence(), "未知通知不应有任何输出"
    c.send({"jsonrpc": "2.0", "method": "totally/unknown"})
    assert c.expect_silence(), "无 id 的未知方法不应有输出"


@case("tools/list schema 完整性")
def t_tools_list(c, tools_min):
    c.send({"jsonrpc": "2.0", "id": 10, "method": "tools/list"})
    r = c.read_json()
    tools = r["result"]["tools"]
    assert len(tools) >= tools_min, f"工具数 {len(tools)} < 期望下限 {tools_min}"
    names = set()
    for t in tools:
        assert t["name"] and isinstance(t["name"], str), f"工具名非法: {t}"
        assert t["name"] not in names, f"工具名重复: {t['name']}"
        names.add(t["name"])
        assert t.get("description"), f"{t['name']} 缺 description"
        sch = t.get("inputSchema")
        assert isinstance(sch, dict), f"{t['name']} 缺 inputSchema"
        assert sch.get("type") == "object", f"{t['name']} inputSchema.type != object"
        assert isinstance(sch.get("properties"), dict), f"{t['name']} 缺 properties"
        assert isinstance(sch.get("required"), list), f"{t['name']} 缺 required"
        for k in sch["required"]:
            assert k in sch["properties"], f"{t['name']} required 的 {k} 不在 properties"
    return tools


@case("协议级错误码")
def t_errors(c):
    c.send({"jsonrpc": "2.0", "id": 20, "method": "no/such/method"})
    r = c.read_json()
    assert r["error"]["code"] == -32601, f"未知方法应为 -32601: {r}"

    c.send("{ this is not json }")
    r = c.read_json()
    assert r["error"]["code"] == -32700 and r["id"] is None, f"坏 JSON 应 -32700 + id null: {r}"

    c.send([{"jsonrpc": "2.0", "id": 21, "method": "ping"}])
    r = c.read_json()
    assert r["error"]["code"] == -32600, f"批处理应 -32600: {r}"

    c.send("42")
    r = c.read_json()
    assert r["error"]["code"] == -32600, f"非对象应为 -32600: {r}"

    c.send({"jsonrpc": "1.0", "id": 22, "method": "ping"})
    r = c.read_json()
    assert r["error"]["code"] == -32600, f"jsonrpc 非 2.0 应 -32600: {r}"

    c.send({"jsonrpc": "2.0", "id": 23, "method": "tools/call",
            "params": {"name": "no_such_tool_xyz", "arguments": {}}})
    r = c.read_json()
    assert r["error"]["code"] == -32602, f"未知工具应 -32602: {r}"

    c.send({"jsonrpc": "2.0", "id": 24, "method": "tools/call",
            "params": {"arguments": {}}})
    r = c.read_json()
    assert r["error"]["code"] == -32602, f"缺 name 应 -32602: {r}"


@case("缺必填参数 → isError 结果（让模型自纠正）")
def t_missing_arg(c, tools):
    target = None
    for t in tools:
        if t["inputSchema"]["required"]:
            target = t
            break
    if target is None:
        raise AssertionError("没有带必填参数的工具，无法测试")
    c.send({"jsonrpc": "2.0", "id": 30, "method": "tools/call",
            "params": {"name": target["name"], "arguments": {}}})
    r = c.read_json()
    res = r["result"]
    assert res["isError"] is True, f"{target['name']} 缺参数应 isError: {res}"
    assert res["content"][0]["type"] == "text"
    assert "参数错误" in res["content"][0]["text"], f"错误文案应含“参数错误”: {res}"


@case("id 保真（整数 / 字符串 / 大整数）")
def t_id_fidelity(c):
    for i, ident in enumerate([7, "abc-123", 9007199254740993, "中文-id"]):
        c.send({"jsonrpc": "2.0", "id": ident, "method": "ping"})
        r = c.read_json()
        assert r["id"] == ident, f"id 未保真: 期望 {ident!r}，得到 {r['id']!r}"


@case("缺配置时工具调用给出可读错误")
def t_missing_config(c, tools, kind):
    no_req = [t for t in tools if not t["inputSchema"]["required"]]
    if not no_req:
        raise AssertionError("没有无必填参数的工具")
    calls = []
    for t in no_req[:6]:
        props = t["inputSchema"]["properties"]
        # 尽量填一些明显无害的默认值，目标是走到“缺配置”分支
        args = {}
        if "sandbox_id" in props:
            args["sandbox_id"] = "sbx-not-configured"
        calls.append((t["name"], args))
    want = "CUBESANDBOX_API_URL" if kind == "cube" else "SANDBOX_BASE"
    hit = False
    for name, args in calls:
        c.send({"jsonrpc": "2.0", "id": 40, "method": "tools/call",
                "params": {"name": name, "arguments": args}})
        r = c.read_json()
        res = r.get("result")
        if not res:
            continue
        text = res["content"][0]["text"]
        if res["isError"] and want in text:
            hit = True
            break
    assert hit, f"未在缺配置场景看到对 {want} 的提示"


@case("stdout 全量纯净性（含多轮真实调用）")
def t_purity(c, tools):
    # 做一轮带输出的操作，然后检查累计的每一行
    for i in range(3):
        c.send({"jsonrpc": "2.0", "id": 50 + i, "method": "tools/list"})
        c.read_json()
    n = len(c.lines)
    for line in c.lines:
        assert_json_line(line)
    # 长文本参数（含中文/引号/换行）经 JSON 编码后仍须单行
    payload = "行1\n行2\t\"引号\"\\反斜杠 " + "字" * 500
    c.send({"jsonrpc": "2.0", "id": 60, "method": "tools/call",
            "params": {"name": tools[0]["name"], "arguments": {"content": payload}}})
    c.read_json()
    for line in c.lines[n:]:
        assert_json_line(line)


@case("EOF 干净退出（退出码 0）")
def t_eof(c):
    code = c.close()
    assert code == 0, f"EOF 后退出码应为 0，实际 {code}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--kind", required=True, choices=["cube", "aiod"])
    ap.add_argument("--tools-min", type=int, default=1)
    args = ap.parse_args()

    if not os.path.exists(args.bin):
        print(f"二进制不存在: {args.bin}", file=sys.stderr)
        return 2

    print(f"== {args.kind}: {args.bin} ==")
    c = Stdio(args.bin, args.kind)
    tools = None
    try:
        # 首行即协议响应：发 initialize 前先确认没有启动噪音
        c.send({"jsonrpc": "2.0", "id": 0, "method": "ping"})
        first = c.read_line()  # 非 JSON 会在这里断言失败
        assert json.loads(first)["id"] == 0, "首个 stdout 行不是我们对 ping 的响应（存在启动噪音）"
        ok("首行即协议响应（无 banner）")

        t_basic(c)
        ok("initialize/版本协商/ping")
        t_notifications(c)
        ok("通知零输出")
        tools = t_tools_list(c, args.tools_min)
        ok(f"tools/list schema 完整（{len(tools)} 个工具）")
        t_errors(c)
        ok("协议错误码")
        t_missing_arg(c, tools)
        ok("缺参 → isError")
        t_id_fidelity(c)
        ok("id 保真")
        t_missing_config(c, tools, args.kind)
        ok("缺配置可读错误")
        t_purity(c, tools)
        ok("stdout 纯净性")
        t_eof(c)
        ok("EOF 退出码 0")
    except Exception as e:  # noqa: BLE001
        bad("未捕获异常", f"{type(e).__name__}: {e}")
        c.kill()
    finally:
        try:
            c.kill()
        except Exception:
            pass

    print(f"-- 通过 {PASSED} 组，失败 {len(FAILURES)} 组 --")
    for name, detail in FAILURES:
        print(f"   ! {name}: {detail}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
