#!/usr/bin/env python3
"""CLI Command Parity Smoke Test for cube-cli.

Compares behavior between before-refactor and after-refactor binaries:
1. Normal execution with MockCubeServer (control plane + envd data plane).
2. Missing config: missing CUBESANDBOX_API_URL or missing CUBESANDBOX_PROXY_URL.
3. HTTP 500 failure injection.
4. Exit codes, stdout, and stderr must match byte-for-byte.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tests.mock_cube_server import MockCubeServer


def normalize_output(cmd_name: str, out: str) -> str:
    if "exec-async" in cmd_name and not ("no_env" in cmd_name or "no_proxy" in cmd_name):
        return re.sub(r"/tmp/\.cube-cli-exec/[0-9a-f]{12}\.(out|err)", r"/tmp/.cube-cli-exec/<RANDOM_TAG>.\1", out)
    return out


def run_tests(bin_before: str, bin_after: str) -> bool:
    mock = MockCubeServer()
    env_mock = {
        "CUBESANDBOX_API_URL": mock.url,
        "CUBESANDBOX_PROXY_URL": mock.url,
    }
    env_api_only = {
        "CUBESANDBOX_API_URL": mock.url,
    }

    test_cases = [
        # Group 1: Control plane
        ("pause", ["pause", "sbx-test-111"], env_mock, None),
        ("resume", ["resume", "sbx-test-111"], env_mock, None),
        ("resume_timeout", ["resume", "sbx-test-111", "--timeout=60"], env_mock, None),
        ("timeout", ["timeout", "sbx-test-111", "300"], env_mock, None),
        ("refresh", ["refresh", "sbx-test-111", "600"], env_mock, None),
        ("snap", ["snap", "sbx-test-111"], env_mock, None),
        ("snap_name", ["snap", "sbx-test-111", "--name=backup1"], env_mock, None),
        ("snap-ls", ["snap-ls"], env_mock, None),
        ("snap-ls_json", ["snap-ls", "--json"], env_mock, None),
        ("snap-rm", ["snap-rm", "snap-test-111"], env_mock, None),
        ("rollback", ["rollback", "sbx-test-111", "snap-test-111"], env_mock, None),
        ("rollback_json", ["rollback", "sbx-test-111", "snap-test-111", "--json"], env_mock, None),
        ("vol-ls", ["vol-ls"], env_mock, None),
        ("vol-ls_json", ["vol-ls", "--json"], env_mock, None),
        ("vol-new", ["vol-new", "my-new-vol"], env_mock, None),
        ("vol-new_json", ["vol-new", "my-new-vol", "--json"], env_mock, None),
        ("vol-info", ["vol-info", "vol-test-111"], env_mock, None),
        ("vol-info_json", ["vol-info", "vol-test-111", "--json"], env_mock, None),
        ("vol-rm", ["vol-rm", "vol-test-111"], env_mock, None),
        ("tpl-ls", ["tpl-ls"], env_mock, None),
        ("tpl-ls_json", ["tpl-ls", "--json"], env_mock, None),
        ("tpl-info", ["tpl-info", "tpl-code"], env_mock, None),
        ("tpl-info_json", ["tpl-info", "tpl-code", "--json"], env_mock, None),
        ("tpl-caps", ["tpl-caps"], env_mock, None),
        ("info", ["info", "sbx-test-111"], env_mock, None),
        ("info_json", ["info", "sbx-test-111", "--json"], env_mock, None),
        ("info_host", ["info", "sbx-test-111", "--host"], env_mock, None),
        ("info_mcp_url", ["info", "sbx-test-111", "--mcp-url"], env_mock, None),
        ("ls", ["ls"], env_mock, None),
        ("ls_json", ["ls", "--json"], env_mock, None),
        ("rm", ["rm", "sbx-test-111"], env_mock, None),
        ("health", ["health"], env_mock, None),
        ("health_json", ["health", "--json"], env_mock, None),

        # Group 1: Missing env
        ("pause_no_env", ["pause", "sbx-test-111"], {}, None),
        ("resume_no_env", ["resume", "sbx-test-111"], {}, None),
        ("timeout_no_env", ["timeout", "sbx-test-111", "60"], {}, None),
        ("refresh_no_env", ["refresh", "sbx-test-111", "60"], {}, None),
        ("snap_no_env", ["snap", "sbx-test-111"], {}, None),
        ("snap-ls_no_env", ["snap-ls"], {}, None),
        ("snap-rm_no_env", ["snap-rm", "snap-test-111"], {}, None),
        ("rollback_no_env", ["rollback", "sbx-test-111", "snap-test-111"], {}, None),
        ("vol-ls_no_env", ["vol-ls"], {}, None),
        ("vol-new_no_env", ["vol-new", "v1"], {}, None),
        ("vol-info_no_env", ["vol-info", "v1"], {}, None),
        ("vol-rm_no_env", ["vol-rm", "v1"], {}, None),
        ("tpl-ls_no_env", ["tpl-ls"], {}, None),
        ("tpl-info_no_env", ["tpl-info", "tpl-code"], {}, None),
        ("tpl-caps_no_env", ["tpl-caps"], {}, None),
        ("info_no_env", ["info", "sbx-test-111"], {}, None),
        ("ls_no_env", ["ls"], {}, None),
        ("rm_no_env", ["rm", "sbx-test-111"], {}, None),
        ("health_no_env", ["health"], {}, None),

        # Group 2: envd data plane
        ("cat", ["cat", "sbx-test-111", "/tmp/sample.txt"], env_mock, None),
        ("write_stdin", ["write", "sbx-test-111", "-", "/tmp/sample.txt"], env_mock, "sample write data\n"),
        ("ls-file", ["ls-file", "sbx-test-111", "/"], env_mock, None),
        ("stat", ["stat", "sbx-test-111", "/tmp/file1.txt"], env_mock, None),
        ("mkdir", ["mkdir", "sbx-test-111", "/tmp/mydir"], env_mock, None),
        ("rm-file", ["rm-file", "sbx-test-111", "/tmp/mydir"], env_mock, None),
        ("mv", ["mv", "sbx-test-111", "/tmp/src.txt", "/tmp/dst.txt"], env_mock, None),
        ("exists_true", ["exists", "sbx-test-111", "/tmp/file1.txt"], env_mock, None),
        ("exists_false", ["exists", "sbx-test-111", "/tmp/nonexistent.txt"], env_mock, None),
        ("exec-async", ["exec-async", "sbx-test-111", "echo", "hello"], env_mock, None),
        ("exec-async_timeout", ["exec-async", "sbx-test-111", "echo", "hello", "--timeout=10"], env_mock, None),
        ("exec-logs", ["exec-logs", "sbx-test-111", "1234"], env_mock, None),
        ("exec-kill", ["exec-kill", "sbx-test-111", "1234"], env_mock, None),
        ("exec-kill_sigterm", ["exec-kill", "sbx-test-111", "1234", "--sigterm"], env_mock, None),
        ("exec-stdin", ["exec-stdin", "sbx-test-111", "1234", "data_line"], env_mock, None),
        ("exec-stdin_piped", ["exec-stdin", "sbx-test-111", "1234", "-"], env_mock, "piped input data\n"),

        # Group 2: Missing CUBESANDBOX_PROXY_URL
        ("cat_no_proxy", ["cat", "sbx-test-111", "/tmp/f"], env_api_only, None),
        ("write_no_proxy", ["write", "sbx-test-111", "-", "/tmp/f"], env_api_only, "x"),
        ("ls-file_no_proxy", ["ls-file", "sbx-test-111", "/"], env_api_only, None),
        ("stat_no_proxy", ["stat", "sbx-test-111", "/tmp/f"], env_api_only, None),
        ("mkdir_no_proxy", ["mkdir", "sbx-test-111", "/tmp/d"], env_api_only, None),
        ("rm-file_no_proxy", ["rm-file", "sbx-test-111", "/tmp/f"], env_api_only, None),
        ("mv_no_proxy", ["mv", "sbx-test-111", "/tmp/a", "/tmp/b"], env_api_only, None),
        ("exists_no_proxy", ["exists", "sbx-test-111", "/tmp/f"], env_api_only, None),
        ("exec-async_no_proxy", ["exec-async", "sbx-test-111", "echo", "hi"], env_api_only, None),
        ("exec-logs_no_proxy", ["exec-logs", "sbx-test-111", "1234"], env_api_only, None),
        ("exec-kill_no_proxy", ["exec-kill", "sbx-test-111", "1234"], env_api_only, None),
        ("exec-stdin_no_proxy", ["exec-stdin", "sbx-test-111", "1234", "hi"], env_api_only, None),

        # Group 2: Missing both / no env
        ("cat_no_env", ["cat", "sbx-test-111", "/tmp/f"], {}, None),
        ("write_no_env", ["write", "sbx-test-111", "-", "/tmp/f"], {}, "x"),
        ("ls-file_no_env", ["ls-file", "sbx-test-111", "/"], {}, None),
        ("stat_no_env", ["stat", "sbx-test-111", "/tmp/f"], {}, None),
        ("mkdir_no_env", ["mkdir", "sbx-test-111", "/tmp/d"], {}, None),
        ("rm-file_no_env", ["rm-file", "sbx-test-111", "/tmp/f"], {}, None),
        ("mv_no_env", ["mv", "sbx-test-111", "/tmp/a", "/tmp/b"], {}, None),
        ("exists_no_env", ["exists", "sbx-test-111", "/tmp/f"], {}, None),
        ("exec-async_no_env", ["exec-async", "sbx-test-111", "echo", "hi"], {}, None),
        ("exec-logs_no_env", ["exec-logs", "sbx-test-111", "1234"], {}, None),
        ("exec-kill_no_env", ["exec-kill", "sbx-test-111", "1234"], {}, None),
        ("exec-stdin_no_env", ["exec-stdin", "sbx-test-111", "1234", "hi"], {}, None),
    ]

    all_passed = True
    passed_count = 0
    total_count = len(test_cases)

    for name, args, env, stdin_data in test_cases:
        inp = stdin_data.encode("utf-8") if stdin_data else b""
        p_before = subprocess.run([bin_before] + args, capture_output=True, env=env, input=inp)
        p_after = subprocess.run([bin_after] + args, capture_output=True, env=env, input=inp)

        out_b = p_before.stdout.decode("utf-8", errors="replace")
        out_a = p_after.stdout.decode("utf-8", errors="replace")
        err_b = p_before.stderr.decode("utf-8", errors="replace")
        err_a = p_after.stderr.decode("utf-8", errors="replace")
        rc_b = p_before.returncode
        rc_a = p_after.returncode

        # Fix verification: cat before refactor mistakenly omitted error text on MissingConfig
        if name == "cat_no_env":
            if out_a == "错误：缺少环境变量 CUBESANDBOX_API_URL\n" and rc_a == 1:
                print(f"  [PASS] {name}: correctly fixed MissingConfig output, rc={rc_a}")
                passed_count += 1
                continue
        if name == "cat_no_proxy":
            if out_a == "错误：缺少环境变量 CUBESANDBOX_PROXY_URL\n" and rc_a == 1:
                print(f"  [PASS] {name}: correctly fixed MissingConfig output, rc={rc_a}")
                passed_count += 1
                continue

        norm_b = normalize_output(name, out_b)
        norm_a = normalize_output(name, out_a)

        match_out = (norm_b == norm_a)
        match_err = (err_b == err_a)
        match_rc = (rc_b == rc_a)

        if match_out and match_rc and match_err:
            print(f"  [PASS] {name}: stdout byte-match, rc={rc_a}")
            passed_count += 1
        else:
            all_passed = False
            print(f"  [FAIL] {name}:")
            if not match_out:
                print(f"    stdout mismatch:\n      before: {repr(norm_b)}\n      after:  {repr(norm_a)}")
            if not match_rc:
                print(f"    rc mismatch: before={rc_b}, after={rc_a}")
            if not match_err:
                print(f"    stderr mismatch: before={repr(err_b)}, after={repr(err_a)}")

    # 4. HTTP 500 error injection parity
    mock.add_failure(".*", 500)
    http_500_cases = [
        ["health"],
        ["ls"],
        ["vol-ls"],
        ["tpl-ls"],
        ["pause", "sbx-test-111"],
        ["cat", "sbx-test-111", "/tmp/f"],
        ["ls-file", "sbx-test-111", "/"],
        ["stat", "sbx-test-111", "/tmp/f"],
        ["mkdir", "sbx-test-111", "/tmp/d"],
    ]
    for cmd in http_500_cases:
        total_count += 1
        p_b = subprocess.run([bin_before] + cmd, capture_output=True, env=env_mock)
        p_a = subprocess.run([bin_after] + cmd, capture_output=True, env=env_mock)
        if p_b.stdout == p_a.stdout and p_b.returncode == p_a.returncode and p_b.stderr == p_a.stderr:
            print(f"  [PASS] http_500_{cmd[0]}: HTTP 500 error stdout byte-match, rc={p_a.returncode}")
            passed_count += 1
        else:
            all_passed = False
            print(f"  [FAIL] http_500_{cmd[0]}: mismatch under 500")

    mock.shutdown()
    print(f"\n结果：{passed_count}/{total_count} 对拍通过")
    return all_passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check CLI command parity against pre-refactor binary")
    parser.add_argument("--before", default="/tmp/bin-before/cube-cli", help="Path to pre-refactor binary")
    parser.add_argument("--after", default="/tmp/ws-refactor/cube-cli/zig-out/bin/cube-cli", help="Path to post-refactor binary")

    args = parser.parse_args()

    if not Path(args.before).exists():
        print(f"[SKIP] 基线二进制不存在（{args.before}）：对拍需要改造前的 cube-cli，"
              f"可用 git worktree add /tmp/ws-before <ref> 并构建后传 --before")
        sys.exit(0)

    ok = run_tests(args.before, args.after)
    sys.exit(0 if ok else 1)
