#!/usr/bin/env python3
"""scripts/gen-docs.py —— 从**已编译的二进制**生成 docs/*.md。

为什么从二进制生成：docs 要与实际能跑的命令面逐字一致。手写文档必然漂移，
而 `<cmd> --help` 的内容就是 src/help.zig 里的命令表，编译后即事实。

用法（在仓库根目录执行，两个二进制都要先 zig build 好）：
    python3 scripts/gen-docs.py \
        --cube cube-cli/zig-out/bin/cube-cli \
        --aio  aiod-cli/zig-out/bin/aiod-cli
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ALL_RE = re.compile(r"^【(.+?)】\s*$")
ROW_RE = re.compile(r"^  (\S+)\s\s+(.*)$")
ENTRY_RE = re.compile(r"^(\S+) (\S+) —— (.*)$")


def run(binary, *args):
    p = subprocess.run([binary, *args], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{binary} {' '.join(args)} 退出码 {p.returncode}\n{p.stderr}")
    return p.stdout


def parse_table(binary):
    """`help all` → [(分组, 命令名, 别名, 一句话)]"""
    out = []
    group = None
    for line in run(binary, "help", "all").splitlines():
        m = ALL_RE.match(line)
        if m:
            group = m.group(1)
            continue
        m = ROW_RE.match(line)
        if m and group:
            names = m.group(1).split("|")
            out.append((group, names[0], names[1] if len(names) > 1 else "", m.group(2).strip()))
    return out


def slug(name):
    return name.replace("-", "").replace("|", "")


def build_doc(binary, title, intro_md, table, extra_head_md):
    lines = [
        f"# {title}",
        "",
        "> **本文档由 `scripts/gen-docs.py` 从编译产物自动生成，请勿手工编辑。**",
        "> 权威命令面是 `<cli> help`（表在 `src/help.zig`）；文档随代码走，改命令先改 help。",
        "> 重新生成：",
        ">",
        "> ```bash",
        "> zig build -Doptimize=ReleaseFast          # 两个工具都编一遍",
        f"> python3 scripts/gen-docs.py --cube {Path(binary).name} --aio aiod-cli",
        "> ```",
        "",
        intro_md,
        "",
    ]
    lines += extra_head_md
    lines += ["", "## 命令索引", ""]
    cur = None
    for group, name, alias, brief in table:
        if group != cur:
            cur = group
            lines.append(f"- **{group}**")
        a = f"（同义词 `{alias}`）" if alias else ""
        lines.append(f"  - [`{name}`](#{slug(name)}) —— {brief}{a}")
    lines.append("")

    cur = None
    for group, name, alias, brief in table:
        if group != cur:
            cur = group
            lines.append(f"## {group}")
            lines.append("")
        lines.append(f"### {name}")
        lines.append("")
        detail = run(binary, "help", name)
        lines.append("```text")
        lines.append(detail.rstrip("\n"))
        lines.append("```")
        lines.append("")
        if "示例:" not in detail:
            sys.exit(f"{binary} help {name} 缺少可复制运行的示例")
    return "\n".join(lines) + "\n"


CUBE_INTRO = """`cube-cli` 是 **CubeSandbox 控制面** CLI：建/查/销毁沙箱、选模板、打快照与回滚、
持久卷、以及沙箱内文件操作（envd 通道）。

- 数据面遥控（执行 / PTY / 浏览器 / 桌面）是另一个工具 [`aiod-cli`](aiod-cli.md)。
- 源码：[`cube-cli/`](https://github.com/otaku-say/sandbox-cli/tree/main/cube-cli)，命令表
  [`cube-cli/src/help.zig`](https://github.com/otaku-say/sandbox-cli/blob/main/cube-cli/src/help.zig)。"""

CUBE_HEAD = [
    "## 环境变量",
    "",
    "仓库内**不含任何主机名 / IP / 凭据**，全部从环境变量读取。只有 `CUBESANDBOX_*` 这四个"
    "（旧命名 `CUBE_API_URL` / `CUBE_API_KEY` / `CBS_PROXY_BASE` 已彻底移除，不再兼容）。",
    "",
    "| 变量 | 必填 | 用途 |",
    "|---|---|---|",
    "| `CUBESANDBOX_API_URL` | 是 | 控制面地址。缺失时任何控制面命令报「错误：缺少环境变量 CUBESANDBOX_API_URL」。 |",
    "| `CUBESANDBOX_API_KEY` | 否 | 控制面 API Key（`X-API-KEY` 头）。本部署未启用鉴权时可省略。 |",
    "| `CUBESANDBOX_PROXY_URL` | exec/文件/ports 必填 | 数据面网关。缺失时报「错误：缺少环境变量 CUBESANDBOX_PROXY_URL」。 |",
    "| `CUBESANDBOX_AGENT_NAME` | 否 | `new` 写入 `metadata.agent` 的默认名字，不设则记 `cube-cli`。 |",
    "",
    "## 构建与产物名",
    "",
    "需要 Zig **0.17.0**。两种目标都要能编过：",
    "",
    "```bash",
    "# 本机架构",
    "cd cube-cli && zig build -Doptimize=ReleaseFast",
    "# 交叉编译到 ARM（iSH / 手机 / aarch64 机器）",
    "cd cube-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl",
    "```",
    "",
    "| 目标三元组 | 产物文件名 | 用在哪 |",
    "|---|---|---|",
    "| `aarch64-linux-musl` | `cube-cli-aarch64-linux-musl` | iSH（iOS）、ARM 服务器 |",
    "| `x86_64-linux-musl` | `cube-cli-x86_64-linux-musl` | x86 服务器、桌面 Linux |",
    "",
    "产物在 `cube-cli/zig-out/bin/cube-cli`，ReleaseFast + strip 后约 1.2 MB 静态单文件。",
    "",
    "## 拿到沙箱后交给 aiod-cli",
    "",
    "`cube-cli new` 输出的 `[sandbox] AIO 网关:` 那行**就是** `aiod-cli` 的 `SANDBOX_BASE`：",
    "",
    "```bash",
    "SID=$(cube-cli new --note=demo)",
    "# 输出里：[sandbox] AIO 网关: https://<网关>/sandbox/<sandboxID>/8080/   ← aiod-cli 的 SANDBOX_BASE",
    "export SANDBOX_BASE=\"https://<网关>/sandbox/$SID/8080\"   # 末尾的 / 无所谓",
    "aiod-cli health",
    "```",
    "",
    "若把二进制搬进沙箱内部执行，`SANDBOX_BASE` 写回环地址即可：`SANDBOX_BASE=http://127.0.0.1:8080`"
    "（此时不再经过网关；这也是 `pty-ws` 唯一支持的形态，因为它只能走 `ws://`）。",
    "",
    "## 帮助怎么用",
    "",
    "```bash",
    "cube-cli help              # 分组速查（58 行，常用命令）",
    "cube-cli help all          # 完整命令表，一条一行",
    "cube-cli help new          # 单命令详解（本文档对应小节）",
    "cube-cli new --help        # 同上，**只打印不建沙箱**",
    "cube-cli new -h            # 同上",
    "```",
    "",
    "未知命令会打印「未知命令：xxx」并以退出码 1 结束。所有取值型 flag 一律写"
    "**`--key=value`** 等号形式；布尔开关直接写 `--flag`（不要写 `--flag=true`）。",
]

AIO_INTRO = """`aiod-cli` 是 **沙箱内 aiod v2 API 遥控** CLI：命令执行、文件传输、PTY 终端、
代码解释器、浏览器、文件监听、MCP、桌面 computer-use。

- 建沙箱 / 选模板 / 快照 / 卷 是另一个工具 [`cube-cli`](cube-cli.md)。
- 源码：[`aiod-cli/`](https://github.com/otaku-say/sandbox-cli/tree/main/aiod-cli)，命令表
  [`aiod-cli/src/help.zig`](https://github.com/otaku-say/sandbox-cli/blob/main/aiod-cli/src/help.zig)。"""

AIO_HEAD = [
    "## 环境变量",
    "",
    "仓库内**不含任何主机名 / IP / 凭据**。只有 `SANDBOX_BASE` / `SANDBOX_KEY` 两个变量。",
    "",
    "| 变量 | 必填 | 用途 |",
    "|---|---|---|",
    "| `SANDBOX_BASE` | 是（`help` 除外） | aiod 网关地址。缺失时打印两种合法写法并以退出码 1 结束。 |",
    "| `SANDBOX_KEY` | 否 | 鉴权 Key。非空时同时附 `Authorization: Bearer <key>` 与 `X-API-Key: <key>`。 |",
    "",
    "### `SANDBOX_BASE` 的两种写法",
    "",
    "```bash",
    "# ① 带端口的完整网关（从本机 / 任何地方遥控沙箱）",
    "export SANDBOX_BASE=\"https://<网关>/sandbox/<sandboxID>/8080\"",
    "",
    "# ② 沙箱内自测：直接打回环",
    "export SANDBOX_BASE=\"http://127.0.0.1:8080\"",
    "```",
    "",
    "值来自 `cube-cli new` 打印的 `[sandbox] AIO 网关:` 那行。**末尾多余的 `/` 会被自动去掉**，"
    "所以带不带尾斜杠都行。端口也不总是 8080（轻量镜像是 18091），以 `cube-cli ports` 实测为准。",
    "",
    "## 构建与产物名",
    "",
    "需要 Zig **0.17.0**。两种目标都要能编过：",
    "",
    "```bash",
    "# 本机架构",
    "cd aiod-cli && zig build -Doptimize=ReleaseFast",
    "# 交叉编译到 ARM（iSH / 手机 / aarch64 机器）",
    "cd aiod-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl",
    "```",
    "",
    "| 目标三元组 | 产物文件名 | 用在哪 |",
    "|---|---|---|",
    "| `aarch64-linux-musl` | `aiod-cli-aarch64-linux-musl` | iSH（iOS）、ARM 服务器 |",
    "| `x86_64-linux-musl` | `aiod-cli-x86_64-linux-musl` | x86 服务器、桌面 Linux |",
    "",
    "产物在 `aiod-cli/zig-out/bin/aiod-cli`，ReleaseFast + strip 后约 1.1 MB 静态单文件。",
    "",
    "## 快速上手",
    "",
    "```bash",
    "export SANDBOX_BASE=\"https://<网关>/sandbox/<sandboxID>/8080\"",
    "aiod-cli health",
    "aiod-cli sandbox-info",
    "aiod-cli exec 'zig version'",
    "aiod-cli write ./report.md /home/gem/report.md && aiod-cli cat /home/gem/report.md",
    "ID=$(aiod-cli async 'pip install -q pandas'); aiod-cli log \"$ID\" --follow",
    "```",
    "",
    "## 通用约定",
    "",
    "- 输出走 stdout，错误走 stderr 且**退出码非 0**。",
    "- 取值型 flag 一律 `--key=value`；布尔开关直接写 `--flag`。",
    "- 响应信封统一为 `{success, message, data, hint}`；非 2xx 或 `success=false` → "
    "`HTTP <码>: <message>（hint: …）`。",
    "- 命令列表里标注「源码未实现」的选项确实**没有**接线，源码里也只有注释提到过，别照抄旧文档。",
    "",
    "## 帮助怎么用",
    "",
    "```bash",
    "aiod-cli help              # 分组速查（58 行，常用命令）",
    "aiod-cli help all          # 完整命令表，一条一行",
    "aiod-cli help pty-ws       # 单命令详解（本文档对应小节）",
    "aiod-cli pty-ws --help     # 同上，**只打印不执行**",
    "aiod-cli pty-ws -h         # 同上",
    "```",
    "",
    "`help` 系列**不需要** `SANDBOX_BASE`。未知命令会打印「未知命令：xxx」并以退出码 1 结束。",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cube", required=True)
    ap.add_argument("--aio", required=True)
    ap.add_argument("--out", default="docs")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    cube = build_doc(args.cube, "cube-cli 命令手册", CUBE_INTRO,
                     parse_table(args.cube), CUBE_HEAD)
    (out / "cube-cli.md").write_text(cube, encoding="utf-8")
    print(f"wrote {out/'cube-cli.md'}  {len(cube.splitlines())} 行")

    aio = build_doc(args.aio, "aiod-cli 命令手册", AIO_INTRO,
                    parse_table(args.aio), AIO_HEAD)
    (out / "aiod-cli.md").write_text(aio, encoding="utf-8")
    print(f"wrote {out/'aiod-cli.md'}  {len(aio.splitlines())} 行")


if __name__ == "__main__":
    main()