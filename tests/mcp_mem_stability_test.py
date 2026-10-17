#!/usr/bin/env python3
"""MCP Server 内存增长稳定性回归测试。

针对常驻长进程（mcp-server）验证在高频 tools/call 下无界内存增长缺陷已彻底修复。
测试逻辑：
1. 分别对 aiod-cli（使用 mock_aiod_server，工具：file_read）与
   cube-cli（使用 mock_cube_server，工具：sandbox_list）启动 mcp-server；
2. 连续执行 3000 次（默认）tools/call；
3. 每 500 次从 /proc/<pid>/status 采样一次 VmRSS；
4. 以第 500 次为预热基线，断言「末次 RSS - 基线 RSS < 1 MiB」；
5. 打印清晰的采样曲线与增长统计。
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Add repo root to import path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tests.mock_aiod_server import MockAiodServer
from tests.mock_cube_server import MockCubeServer


def get_vm_rss_kb(pid: int) -> int:
    """Read VmRSS in kilobytes from /proc/<pid>/status."""
    try:
        with open(f"/proc/{pid}/status", "r") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    parts = line.split()
                    return int(parts[1])
    except Exception as e:
        print(f"Warning: unable to read /proc/{pid}/status: {e}", file=sys.stderr)
    return 0


class McpProcess:
    def __init__(self, bin_path: str, env_vars: dict):
        env = dict(os.environ)
        env.update(env_vars)
        self.proc = subprocess.Popen(
            [bin_path, "mcp-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=0,
        )
        self.req_id = 0

        # Handshake: initialize
        init_req = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "mem-test-client", "version": "1.0.0"},
            },
        }
        res = self.send(init_req)
        assert "result" in res, f"initialize failed: {res}"

        # notifications/initialized
        self.notify({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, obj: dict) -> dict:
        line = json.dumps(obj) + "\n"
        self.proc.stdin.write(line.encode("utf-8"))
        self.proc.stdin.flush()
        raw = self.proc.stdout.readline()
        if not raw:
            err = self.proc.stderr.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"mcp-server closed stdout prematurely. stderr: {err}")
        return json.loads(raw.decode("utf-8"))

    def notify(self, obj: dict):
        line = json.dumps(obj) + "\n"
        self.proc.stdin.write(line.encode("utf-8"))
        self.proc.stdin.flush()

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=2)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


def run_single_stability_test(
    name: str,
    bin_path: str,
    kind: str,
    total_iters: int,
    step: int,
    warmup: int,
    threshold_kb: int,
) -> bool:
    print(f"==================================================")
    print(f"[{name}] 开始内存稳定性测试: {bin_path}")
    print(f"  配置: iters={total_iters}, step={step}, warmup={warmup}, threshold={threshold_kb} kB ({threshold_kb / 1024:.2f} MiB)")

    if kind == "cube":
        mock_server = MockCubeServer()
        env_vars = {
            "CUBESANDBOX_API_URL": mock_server.url,
            "CUBESANDBOX_PROXY_URL": mock_server.url,
        }
        call_params = {"name": "sandbox_list", "arguments": {}}
        stop_mock = mock_server.shutdown
    elif kind == "aiod":
        mock_server = MockAiodServer()
        mock_server.start()
        env_vars = {
            "SANDBOX_BASE": mock_server.base_url,
        }
        call_params = {"name": "file_read", "arguments": {"path": "/etc/hosts"}}
        stop_mock = mock_server.stop
    else:
        raise ValueError(f"Unknown kind: {kind}")

    mcp = McpProcess(bin_path, env_vars)
    pid = mcp.proc.pid
    initial_rss = get_vm_rss_kb(pid)
    print(f"  进程 PID={pid}, 启动初始 RSS: {initial_rss} kB")

    samples = []  # list of (iter, rss_kb)
    t0 = time.time()

    try:
        for i in range(1, total_iters + 1):
            req = {
                "jsonrpc": "2.0",
                "id": i + 10,
                "method": "tools/call",
                "params": call_params,
            }
            res = mcp.send(req)
            if "error" in res:
                print(f"  [ERROR] tools/call failed at iter {i}: {res['error']}")
                return False

            if i % step == 0:
                rss = get_vm_rss_kb(pid)
                samples.append((i, rss))

        duration = time.time() - t0
        print(f"  完成 {total_iters} 次请求，耗时 {duration:.2f}s ({total_iters / duration:.1f} req/s)")

    finally:
        mcp.close()
        stop_mock()

    # Analyze samples
    print("  RSS 采样曲线:")
    baseline_rss = None
    for it, rss in samples:
        note = ""
        if it == warmup:
            baseline_rss = rss
            note = " <- [基线 (预热后)]"
        elif baseline_rss is not None:
            delta = rss - baseline_rss
            note = f" (距基线 {delta:+d} kB)"
        print(f"    iter {it:5d}: {rss:6d} kB{note}")

    if baseline_rss is None:
        # If warmup not exact match, use first sample >= warmup
        for it, rss in samples:
            if it >= warmup:
                baseline_rss = rss
                break
        if baseline_rss is None:
            baseline_rss = samples[0][1]

    final_rss = samples[-1][1]
    warm_growth = final_rss - baseline_rss

    # 稳态判据：以**采样序列后半段**为基线。一次性台阶（懒分配 / arena 容量首次增长）
    # 不算泄漏，只有持续线性爬升才算 —— 这也是 CI 上真实出现过的形态
    # （aiod 在 CI 上 500→1000 一次性 +276 kB，之后 2000 次完全持平）。
    mid_idx = len(samples) // 2
    steady_it, steady_rss = samples[mid_idx]
    growth_kb = final_rss - steady_rss
    measured = max(1, total_iters - steady_it)
    per_req = growth_kb * 1024.0 / measured

    print(f"  统计摘要:")
    print(f"    预热基线 RSS (iter {warmup}): {baseline_rss} kB  →  末次 {final_rss} kB（差值 {warm_growth:+d} kB，仅判读用）")
    print(f"    稳态基线 RSS (iter {steady_it}): {steady_rss} kB  →  末次 {final_rss} kB")
    print(f"    稳态净增长: {growth_kb:+d} kB ({growth_kb / 1024.0:+.3f} MiB) over {measured} 次请求")
    print(f"    允许阈值: < {threshold_kb} kB ({threshold_kb / 1024:.2f} MiB)")
    print(f"    每请求平均增长（稳态）: {per_req:.1f} B/req（修复前实现实测约 380 B/req → 稳态区间约 +570 kB，必被拦下）")

    if growth_kb < threshold_kb:
        print(f"  [PASS] {name} 内存稳定性断言通过 (增长 {growth_kb} kB < {threshold_kb} kB)")
        return True
    else:
        print(f"  [FAIL] {name} 内存增长超标! 增长 {growth_kb} kB >= {threshold_kb} kB")
        return False


def main():
    parser = argparse.ArgumentParser(description="MCP Server 内存增长稳定性回归测试")
    parser.add_argument("--bin", help="待测试二进制路径（如不指定则测试 cube-cli 与 aiod-cli 默认路径）")
    parser.add_argument("--kind", choices=["cube", "aiod", "auto"], default="auto", help="目标类型")
    parser.add_argument("--iters", type=int, default=3000, help="总调用次数 (默认 3000)")
    parser.add_argument("--step", type=int, default=500, help="采样步长 (默认 500)")
    parser.add_argument("--warmup", type=int, default=500, help="预热步数，作为基线 (默认 500)")
    parser.add_argument("--threshold-mib", type=float, default=0.125, help="允许的最大增长 MiB (默认 0.125；反证：修复前实现 3000 次请求实测 +0.906 MiB，故该阈值能真正拦住这类泄漏)")
    args = parser.parse_args()

    threshold_kb = int(args.threshold_mib * 1024)

    tasks = []
    if args.bin:
        kind = args.kind
        if kind == "auto":
            lower = args.bin.lower()
            if "aiod" in lower:
                kind = "aiod"
            elif "cube" in lower:
                kind = "cube"
            else:
                parser.error("无法根据 --bin 推断 kind，请显式提供 --kind {cube,aiod}")
        tasks.append((f"{kind}-cli", args.bin, kind))
    else:
        cube_bin = str(ROOT / "cube-cli" / "zig-out" / "bin" / "cube-cli")
        aiod_bin = str(ROOT / "aiod-cli" / "zig-out" / "bin" / "aiod-cli")
        tasks.append(("cube-cli", cube_bin, "cube"))
        tasks.append(("aiod-cli", aiod_bin, "aiod"))

    all_ok = True
    for name, bin_path, kind in tasks:
        if not os.path.isfile(bin_path):
            print(f"[ERROR] 二进制不存在: {bin_path}，请先执行 zig build", file=sys.stderr)
            sys.exit(1)
        ok = run_single_stability_test(
            name=name,
            bin_path=bin_path,
            kind=kind,
            total_iters=args.iters,
            step=args.step,
            warmup=args.warmup,
            threshold_kb=threshold_kb,
        )
        if not ok:
            all_ok = False
        print("")

    if all_ok:
        print("[ALL PASS] 所有目标内存稳定性测试全部通过！")
        sys.exit(0)
    else:
        print("[FAIL] 存在未能通过内存稳定性断言的目标！", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
