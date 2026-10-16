#!/usr/bin/env python3
"""图片类工具的结果组织边界测试（主控补充）。

断言：
  1) 正常 PNG → 返回 image content（mimeType=image/png）
  2) 超过 8 MiB → **不返回图片**，回文本说明（截断二进制=坏图，客户端必然渲染失败）
  3) 非 PNG/JPEG 魔数 → **不返回图片**，回文本说明
用法: python3 tests/mcp_image_result_test.py --bin aiod-cli/zig-out/bin/aiod-cli
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_aiod_server as M  # noqa: E402

FAILS = []


def ok(msg):
    print(f"  ok   {msg}")


def bad(msg):
    FAILS.append(msg)
    print(f"  FAIL {msg}")


def run_screenshot(binary, payload):
    M.TINY_PNG = payload
    srv = M.MockAiodServer()
    srv.start()
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("CUBESANDBOX_") and not k.startswith("SANDBOX_")}
    env["SANDBOX_BASE"] = srv.base_url
    p = subprocess.Popen([binary, "mcp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env, bufsize=0)
    try:
        p.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n')
        p.stdin.flush()
        p.stdout.readline()
        p.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_screenshot","arguments":{}}}\n')
        p.stdin.flush()
        msg = json.loads(p.stdout.readline())
        return msg["result"]
    finally:
        p.kill()
        srv.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    args = ap.parse_args()

    real_png = bytes.fromhex("89504e470d0a1a0a") + b"\x00" * 64

    # 1) 正常 PNG
    res = run_screenshot(args.bin, real_png)
    kinds = [c["type"] for c in res["content"]]
    if "image" in kinds and any(c.get("mimeType") == "image/png" for c in res["content"]):
        ok("正常 PNG → 返回 image content（image/png）")
    else:
        bad(f"正常 PNG 未返回图片：{kinds}")

    # 2) 超限（9 MiB）
    res = run_screenshot(args.bin, real_png + b"\x00" * (9 << 20))
    kinds = [c["type"] for c in res["content"]]
    text = "".join(c.get("text", "") for c in res["content"] if c["type"] == "text")
    if "image" not in kinds and ("超过" in text or "上限" in text):
        ok("超限图片 → 不返回图片，回文本说明")
    else:
        bad(f"超限图片处理错误：kinds={kinds} text={text[:120]!r}")

    # 3) 非图片内容
    res = run_screenshot(args.bin, b"this is definitely not an image")
    kinds = [c["type"] for c in res["content"]]
    text = "".join(c.get("text", "") for c in res["content"] if c["type"] == "text")
    if "image" not in kinds and "魔数" in text:
        ok("非图片内容 → 不返回图片，回文本说明")
    else:
        bad(f"非图片处理错误：kinds={kinds} text={text[:120]!r}")

    print(f"-- 图片边界测试：失败 {len(FAILS)} 项 --")
    for f in FAILS:
        print(f"   ! {f}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
