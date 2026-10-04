#!/bin/sh
# tests/help_smoke.sh —— 两个 CLI 帮助体系的冒烟测试（可重复执行，不依赖网络）
#
# 覆盖：
#   1. help / help all / help <cmd> / <cmd> --help / <cmd> -h 五种入口都能打印
#   2. **new --help 绝不建沙箱**（前后 cube-cli ls 对比沙箱数量）
#   3. 未知命令 → "未知命令：xxx" + 非 0 退出
#   4. aio-cli 缺 SANDBOX_BASE 时的报错是否清晰；help 不需要该变量
#   5. 顶层 help 行数 ≤ 60
#
# 用法：
#   CUBE=/path/to/cube-cli AIO=/path/to/aio-cli tests/help_smoke.sh
#   # 或者直接进各自 zig-out/bin 目录跑（默认从 ../../ 找）
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CUBE=${CUBE:-$ROOT/cube-cli/zig-out/bin/cube-cli}
AIO=${AIO:-$ROOT/aio-cli/zig-out/bin/aio-cli}
[ -x "$CUBE" ] || { echo "找不到 cube-cli: $CUBE"; exit 1; }
[ -x "$AIO" ] || { echo "找不到 aio-cli: $AIO"; exit 1; }

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# check <名称> <期望退出码> <命令…>
check() {
    name=$1; want=$2; shift 2
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$name (exit $rc)"
    else bad "$name (exit $rc，期望 $want)"; printf '%s\n' "$out" | sed 's/^/        /' | head -5; fi
    printf '%s' "$out"
}

echo "== 1. 顶层 help =="
CUBE_LINES=$("$CUBE" help | wc -l | tr -d ' ')
AIO_LINES=$("$AIO" help | wc -l | tr -d ' ')
if [ "$CUBE_LINES" -le 60 ]; then ok "cube-cli help = $CUBE_LINES 行 (≤60)"
else bad "cube-cli help = $CUBE_LINES 行 (>60)"; fi
if [ "$AIO_LINES" -le 60 ]; then ok "aio-cli help = $AIO_LINES 行 (≤60)"
else bad "aio-cli help = $AIO_LINES 行 (>60)"; fi
"$CUBE" --help  >/dev/null 2>&1; check "cube-cli --help"        0 "$CUBE" --help >/dev/null
"$CUBE"          >/dev/null 2>&1; check "cube-cli（无参数）"     0 "$CUBE"          >/dev/null
"$AIO" --help  >/dev/null 2>&1; check "aio-cli --help"         0 "$AIO" --help >/dev/null
"$AIO" -h      >/dev/null 2>&1; check "aio-cli -h"             0 "$AIO" -h     >/dev/null
"$AIO"          >/dev/null 2>&1; check "aio-cli（无参数）"      0 "$AIO"          >/dev/null

echo "== 2. help all =="
check "cube-cli help all" 0 "$CUBE" help all >/dev/null
check "aio-cli help all"  0 "$AIO"  help all >/dev/null

echo "== 3. help <命令> / <命令> --help / <命令> -h 三种写法等价 =="
for c in new exec tpl-caps vol-new; do
    a=$("$CUBE" help "$c" 2>&1)
    b=$("$CUBE" "$c" --help 2>&1)
    d=$("$CUBE" "$c" -h 2>&1)
    if [ "$a" = "$b" ] && [ "$b" = "$d" ] && [ -n "$a" ]; then
        ok "cube-cli $c：三种写法输出完全一致"
    else
        bad "cube-cli $c：三种写法输出不一致"
    fi
done
for c in exec pty-ws br-cookie-set cmp-a11y; do
    a=$("$AIO" help "$c" 2>&1)
    b=$("$AIO" "$c" --help 2>&1)
    d=$("$AIO" "$c" -h 2>&1)
    if [ "$a" = "$b" ] && [ "$b" = "$d" ] && [ -n "$a" ]; then
        ok "aio-cli $c：三种写法输出完全一致"
    else
        bad "aio-cli $c：三种写法输出不一致"
    fi
done

echo "== 4. 未知命令（非 0 退出 + 提示） =="
o=$("$CUBE" frobnicate 2>&1); rc=$?
case "$o" in *"未知命令"*) ok "cube-cli 未知命令有提示" ;; *) bad "cube-cli 未知命令无提示" ;; esac
[ "$rc" -ne 0 ] && ok "cube-cli 未知命令退出码 $rc" || bad "cube-cli 未知命令退出码为 0"
o=$("$AIO" frobnicate 2>&1); rc=$?
case "$o" in *"未知命令"*) ok "aio-cli 未知命令有提示" ;; *) bad "aio-cli 未知命令无提示" ;; esac
[ "$rc" -ne 0 ] && ok "aio-cli 未知命令退出码 $rc" || bad "aio-cli 未知命令退出码为 0"
o=$("$CUBE" help frobnicate 2>&1); rc=$?
case "$o" in *"未知命令"*) ok "cube-cli help <未知> 有提示" ;; *) bad "cube-cli help <未知> 无提示" ;; esac
[ "$rc" -ne 0 ] && ok "cube-cli help <未知> 退出码 $rc" || bad "cube-cli help <未知> 退出码为 0"

echo "== 5. new --help 绝不建沙箱 =="
BEFORE=$("$CUBE" ls 2>/dev/null | tail -n +2 | grep -c . || true)
"$CUBE" new --help  >/dev/null 2>&1; rc1=$?
"$CUBE" new -h      >/dev/null 2>&1; rc2=$?
"$CUBE" help new    >/dev/null 2>&1; rc3=$?
AFTER=$("$CUBE" ls 2>/dev/null | tail -n +2 | grep -c . || true)
printf '  沙箱数：执行前 %s → 执行后 %s\n' "$BEFORE" "$AFTER"
if [ "$BEFORE" = "$AFTER" ]; then ok "new --help / -h / help new 都没有新建沙箱"
else bad "沙箱数变了（$BEFORE → $AFTER），help 触发了真实操作！"; fi
for r in "$rc1" "$rc2" "$rc3"; do
    [ "$r" -eq 0 ] || bad "new --help 系列退出码应为 0，实际 $r"
done
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 0 ] && ok "new --help 系列退出码均为 0"
# 离线兜底：new --help 的输出里不能出现任何 32 位十六进制沙箱 ID
NEWHELP=$("$CUBE" new --help 2>&1)
if printf '%s' "$NEWHELP" | grep -Eq '[0-9a-f]{32}'; then
    bad "new --help 输出里出现了疑似沙箱 ID，说明它真的建了沙箱"
else
    ok "new --help 输出里没有任何沙箱 ID"
fi
if printf '%s' "$NEWHELP" | grep -q '^\[sandbox\] AIO 网关:'; then
    bad "new --help 打印了网关信息（只有真建沙箱才会打）"
else
    ok "new --help 没有打印真建沙箱才有的 [sandbox] AIO 网关 行"
fi

echo "== 6. aio-cli 缺 SANDBOX_BASE 的报错 =="
o=$(env -u SANDBOX_BASE "$AIO" exec 'echo hi' 2>&1); rc=$?
case "$o" in *SANDBOX_BASE*) ok "报错点明了 SANDBOX_BASE" ;; *) bad "报错没提 SANDBOX_BASE"; printf '%s\n' "$o" | sed 's/^/        /' ;; esac
case "$o" in *"127.0.0.1:8080"*|*"sandbox/"*"sandboxID"*) ok "报错给出了 SANDBOX_BASE 的两种写法" ;; *) bad "报错没给两种写法示例" ;; esac
[ "$rc" -ne 0 ] && ok "缺变量时退出码 $rc" || bad "缺变量时退出码为 0"
o=$(env -u SANDBOX_BASE "$AIO" help 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -n "$o" ] && ok "help 不需要 SANDBOX_BASE" || bad "help 在缺 SANDBOX_BASE 时失败"
o=$(env -u SANDBOX_BASE "$AIO" exec --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -n "$o" ] && ok "exec --help 不需要 SANDBOX_BASE" || bad "exec --help 在缺 SANDBOX_BASE 时失败"

echo "== 7. version 带仓库与构建信息 =="
"$CUBE" version 2>&1 | grep -q 'github.com/otaku-say/sandbox-cli' \
    && ok "cube-cli version 含仓库地址" || bad "cube-cli version 缺仓库地址"
"$AIO"  version 2>&1 | grep -q 'github.com/otaku-say/sandbox-cli' \
    && ok "aio-cli version 含仓库地址" || bad "aio-cli version 缺仓库地址"
"$CUBE" version 2>&1 | grep -q 'Zig 0.17.0' \
    && ok "cube-cli version 含构建信息" || bad "cube-cli version 缺构建信息"

echo
echo "结果：$PASS 通过 / $FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1