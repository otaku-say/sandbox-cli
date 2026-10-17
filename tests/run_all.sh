#!/bin/sh
# tests/run_all.sh —— sandbox-cli 一键全量测试套件
#
# 步骤：
#   1. zig build 两个 CLI (Debug)
#   2. tests/help_smoke.sh 帮助体系冒烟测试
#   3. tests/mcp_protocol_test.py 协议 + 纯净性测试 (cube 与 aiod 各一次)
#   4. tests/mcp_cube_tools_test.py mock cube 工具套件（若文件不存在则打印 SKIP 并跳过）
#   5. tests/mcp_aiod_tools_test.py mock aiod 工具套件（若文件不存在则打印 SKIP 并跳过）
#   6. tests/mcp_image_result_test.py 图片类工具结果边界
#   7. tests/mcp_big_output_test.py 大文本截断的 UTF-8 安全性
#   8. tests/cmd_parity_smoke.py CLI 对拍（改造前后逐字节一致；缺基线则 SKIP）
#   9. tests/mcp_mem_stability_test.py MCP Server 内存增长稳定性回归测试 (cube 与 aiod 各一次)
#
# 失败即非 0 退出；输出能一眼看出哪一步失败。

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CUBE="$ROOT/cube-cli/zig-out/bin/cube-cli"
AIO="$ROOT/aiod-cli/zig-out/bin/aiod-cli"

echo "=================================================="
echo "== [1/10] 编译两个 CLI (Debug) =="
echo "=================================================="
(cd "$ROOT/cube-cli" && zig build)
(cd "$ROOT/aiod-cli" && zig build)
echo "[PASS] cube-cli & aiod-cli 编译成功"
echo ""

echo "=================================================="
echo "== [2/10] 帮助体系冒烟测试 (tests/help_smoke.sh) =="
echo "=================================================="
CUBE="$CUBE" AIO="$AIO" sh "$ROOT/tests/help_smoke.sh"
echo "[PASS] help_smoke.sh 全部通过"
echo ""

echo "=================================================="
echo "== [3/10] MCP 协议与纯净性测试 (tests/mcp_protocol_test.py) =="
echo "=================================================="
python3 "$ROOT/tests/mcp_protocol_test.py" --bin "$CUBE" --kind cube --tools-min 37
python3 "$ROOT/tests/mcp_protocol_test.py" --bin "$AIO" --kind aiod --tools-min 65
echo "[PASS] mcp_protocol_test.py (cube & aiod) 全部通过"
echo ""

echo "=================================================="
echo "== [4/10] mock cube 工具测试套件 =="
echo "=================================================="
if [ -f "$ROOT/tests/mcp_cube_tools_test.py" ]; then
    python3 "$ROOT/tests/mcp_cube_tools_test.py" --bin "$CUBE"
    echo "[PASS] mcp_cube_tools_test.py 全部通过"
else
    echo "[SKIP] tests/mcp_cube_tools_test.py 尚不存在，跳过"
fi
echo ""

echo "=================================================="
echo "== [5/10] mock aiod 工具测试套件 =="
echo "=================================================="
if [ -f "$ROOT/tests/mcp_aiod_tools_test.py" ]; then
    python3 "$ROOT/tests/mcp_aiod_tools_test.py" --bin "$AIO"
    echo "[PASS] mcp_aiod_tools_test.py 全部通过"
else
    echo "[SKIP] tests/mcp_aiod_tools_test.py 尚不存在，跳过"
fi
echo ""

echo "=================================================="
echo "== [6/10] 图片类工具结果边界（超限/非图片） =="
echo "=================================================="
python3 "$ROOT/tests/mcp_image_result_test.py" --bin "$AIO"
echo "[PASS] mcp_image_result_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [7/10] 大文本截断的 UTF-8 安全性 =="
echo "=================================================="
python3 "$ROOT/tests/mcp_big_output_test.py" --bin "$AIO"
echo "[PASS] mcp_big_output_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [8/10] CLI 对拍（改造前后逐字节一致；缺基线则 SKIP） =="
echo "=================================================="
python3 "$ROOT/tests/cmd_parity_smoke.py" --before "${PARITY_BEFORE:-/tmp/bin-before/cube-cli}" --after "$CUBE"
echo "[PASS] cmd_parity_smoke.py 处理完成"
echo ""

echo "=================================================="
echo "== [9/10] MCP Server 内存稳定性回归 (tests/mcp_mem_stability_test.py) =="
echo "=================================================="
python3 "$ROOT/tests/mcp_mem_stability_test.py" --bin "$CUBE" --kind cube --iters "${MEM_ITERS:-3000}"
python3 "$ROOT/tests/mcp_mem_stability_test.py" --bin "$AIO" --kind aiod --iters "${MEM_ITERS:-3000}"
echo "[PASS] mcp_mem_stability_test.py (cube & aiod) 全部通过"
echo ""

echo "=================================================="
echo "== [10/10] 对抗测试套件（mock 侧：全工具覆盖 + 缺陷探针 + 边界） =="
echo "=================================================="
python3 "$ROOT/tests/adv_cube_suite.py"
python3 "$ROOT/tests/adv_cube_defect_probe.py"
python3 "$ROOT/tests/adv_aiod_suite.py"
python3 "$ROOT/tests/adv_aiod_coverage.py"
python3 "$ROOT/tests/mcp_cube_edge_test.py" --cube "$CUBE" --aio "$AIO"
echo "[PASS] 对抗测试套件全部通过"
echo ""

echo "=================================================="
echo "== 全量测试完成：全部步骤成功通过！ =="
echo "=================================================="
