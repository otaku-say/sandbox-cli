#!/bin/sh
# tests/run_all.sh —— sandbox-cli 一键全量测试套件
#
# 步骤：
#   1. zig build 两个 CLI (Debug)
#   2. tests/help_smoke.sh 帮助体系冒烟测试
#   3. tests/mcp_protocol_test.py 协议 + 纯净性测试 (cube 与 aiod 各一次)
#   4. tests/mcp_cube_tools_test.py mock cube 工具套件（若文件不存在则打印 SKIP 并跳过）
#   5. tests/mcp_aiod_tools_test.py mock aiod 工具套件（若文件不存在则打印 SKIP 并跳过）
#
# 失败即非 0 退出；输出能一眼看出哪一步失败。

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CUBE="$ROOT/cube-cli/zig-out/bin/cube-cli"
AIO="$ROOT/aiod-cli/zig-out/bin/aiod-cli"

echo "=================================================="
echo "== [7/7] 大文本截断的 UTF-8 安全性 =="
echo "=================================================="
python3 "$ROOT/tests/mcp_big_output_test.py" --bin "$AIO"
echo "[PASS] mcp_big_output_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [1/7] 编译两个 CLI (Debug) =="
echo "=================================================="
(cd "$ROOT/cube-cli" && zig build)
(cd "$ROOT/aiod-cli" && zig build)
echo "[PASS] cube-cli & aiod-cli 编译成功"
echo ""

echo "=================================================="
echo "== [2/7] 帮助体系冒烟测试 (tests/help_smoke.sh) =="
echo "=================================================="
CUBE="$CUBE" AIO="$AIO" sh "$ROOT/tests/help_smoke.sh"
echo "[PASS] help_smoke.sh 全部通过"
echo ""

echo "=================================================="
echo "== [3/7] MCP 协议与纯净性测试 (tests/mcp_protocol_test.py) =="
echo "=================================================="
python3 "$ROOT/tests/mcp_protocol_test.py" --bin "$CUBE" --kind cube --tools-min 37
python3 "$ROOT/tests/mcp_protocol_test.py" --bin "$AIO" --kind aiod --tools-min 65
echo "[PASS] mcp_protocol_test.py (cube & aiod) 全部通过"
echo ""

echo "=================================================="
echo "== [4/7] mock cube 工具测试套件 =="
echo "=================================================="
if [ -f "$ROOT/tests/mcp_cube_tools_test.py" ]; then
    python3 "$ROOT/tests/mcp_cube_tools_test.py" --bin "$CUBE"
    echo "[PASS] mcp_cube_tools_test.py 全部通过"
else
    echo "[SKIP] tests/mcp_cube_tools_test.py 尚不存在，跳过"
fi
echo ""

echo "=================================================="
echo "== [5/7] mock aiod 工具测试套件 =="
echo "=================================================="
if [ -f "$ROOT/tests/mcp_aiod_tools_test.py" ]; then
    python3 "$ROOT/tests/mcp_aiod_tools_test.py" --bin "$AIO"
    echo "[PASS] mcp_aiod_tools_test.py 全部通过"
else
    echo "[SKIP] tests/mcp_aiod_tools_test.py 尚不存在，跳过"
fi
echo ""

echo "=================================================="
echo "== [6/7] 图片类工具结果边界（超限/非图片） =="
echo "=================================================="
python3 "$ROOT/tests/mcp_image_result_test.py" --bin "$AIO"
echo "[PASS] mcp_image_result_test.py 全部通过"
echo ""

echo "=================================================="
echo "== 全量测试完成：全部步骤成功通过！ =="
echo "=================================================="
