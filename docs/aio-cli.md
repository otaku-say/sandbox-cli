# aio-cli 命令手册

> **本文档由 `scripts/gen-docs.py` 从编译产物自动生成，请勿手工编辑。**
> 权威命令面是 `<cli> help`（表在 `src/help.zig`）；文档随代码走，改命令先改 help。
> 重新生成：
>
> ```bash
> zig build -Doptimize=ReleaseFast          # 两个工具都编一遍
> python3 scripts/gen-docs.py --cube aio-cli --aio aio-cli
> ```

`aio-cli` 是 **沙箱内 aiod v2 API 遥控** CLI：命令执行、文件传输、PTY 终端、
代码解释器、浏览器、文件监听、MCP、桌面 computer-use。

- 建沙箱 / 选模板 / 快照 / 卷 是另一个工具 [`cube-cli`](cube-cli.md)。
- 源码：[`aio-cli/`](https://github.com/otaku-say/sandbox-cli/tree/main/aio-cli)，命令表
  [`aio-cli/src/help.zig`](https://github.com/otaku-say/sandbox-cli/blob/main/aio-cli/src/help.zig)。

## 环境变量

仓库内**不含任何主机名 / IP / 凭据**。只有 `SANDBOX_BASE` / `SANDBOX_KEY` 两个变量。

| 变量 | 必填 | 用途 |
|---|---|---|
| `SANDBOX_BASE` | 是（`help` 除外） | aiod 网关地址。缺失时打印两种合法写法并以退出码 1 结束。 |
| `SANDBOX_KEY` | 否 | 鉴权 Key。非空时同时附 `Authorization: Bearer <key>` 与 `X-API-Key: <key>`。 |

### `SANDBOX_BASE` 的两种写法

```bash
# ① 带端口的完整网关（从本机 / 任何地方遥控沙箱）
export SANDBOX_BASE="https://<网关>/sandbox/<sandboxID>/8080"

# ② 沙箱内自测：直接打回环
export SANDBOX_BASE="http://127.0.0.1:8080"
```

值来自 `cube-cli new` 打印的 `[sandbox] AIO 网关:` 那行。**末尾多余的 `/` 会被自动去掉**，所以带不带尾斜杠都行。端口也不总是 8080（轻量镜像是 18091），以 `cube-cli ports` 实测为准。

## 构建与产物名

需要 Zig **0.17.0**。两种目标都要能编过：

```bash
# 本机架构
cd aio-cli && zig build -Doptimize=ReleaseFast
# 交叉编译到 ARM（iSH / 手机 / aarch64 机器）
cd aio-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
```

| 目标三元组 | 产物文件名 | 用在哪 |
|---|---|---|
| `aarch64-linux-musl` | `aio-cli-aarch64-linux-musl` | iSH（iOS）、ARM 服务器 |
| `x86_64-linux-musl` | `aio-cli-x86_64-linux-musl` | x86 服务器、桌面 Linux |

产物在 `aio-cli/zig-out/bin/aio-cli`，ReleaseFast + strip 后约 1.1 MB 静态单文件。

## 快速上手

```bash
export SANDBOX_BASE="https://<网关>/sandbox/<sandboxID>/8080"
aio-cli health
aio-cli sandbox-info
aio-cli exec 'zig version'
aio-cli write ./report.md /home/gem/report.md && aio-cli cat /home/gem/report.md
ID=$(aio-cli async 'pip install -q pandas'); aio-cli log "$ID" --follow
```

## 通用约定

- 输出走 stdout，错误走 stderr 且**退出码非 0**。
- 取值型 flag 一律 `--key=value`；布尔开关直接写 `--flag`。
- 响应信封统一为 `{success, message, data, hint}`；非 2xx 或 `success=false` → `HTTP <码>: <message>（hint: …）`。
- 命令列表里标注「源码未实现」的选项确实**没有**接线，源码里也只有注释提到过，别照抄旧文档。

## 帮助怎么用

```bash
aio-cli help              # 分组速查（58 行，常用命令）
aio-cli help all          # 完整命令表，一条一行
aio-cli help pty-ws       # 单命令详解（本文档对应小节）
aio-cli pty-ws --help     # 同上，**只打印不执行**
aio-cli pty-ws -h         # 同上
```

`help` 系列**不需要** `SANDBOX_BASE`。未知命令会打印「未知命令：xxx」并以退出码 1 结束。

## 命令索引

- **基础**
  - [`health`](#health) —— aiod 网关健康检查
  - [`sandbox-info`](#sandboxinfo) —— 沙箱信息（GET /v2/sandbox）
  - [`sandbox-packages`](#sandboxpackages) —— 沙箱内置包清单
  - [`version`](#version) —— 版本 / 构建信息
  - [`help`](#help) —— 帮助：速查表 / all 完整表 / <命令> 详情
- **执行**
  - [`exec`](#exec) —— 同步执行一条命令并打印输出
  - [`async`](#async) —— 异步派发一条命令，打印 command_id
  - [`log`](#log) —— 按 id 轮询/跟随输出
  - [`kill`](#kill) —— 杀掉一条运行中的命令
  - [`stdin`](#stdin) —— 给运行中的命令喂 stdin
  - [`sess-new`](#sessnew) —— 新建命令会话（固定 cwd）
  - [`sess`](#sess) —— 在命令会话里执行
  - [`sess-ls`](#sessls) —— 列出命令会话
  - [`sess-rm`](#sessrm) —— 删除命令会话
- **文件**
  - [`cat`](#cat) —— 读沙箱内文件到标准输出（同义词 `read`）
  - [`write`](#write) —— 把本地文件（或 stdin）写进沙箱
  - [`get`](#get) —— 下载沙箱内文件到本地（二进制安全）
  - [`put`](#put) —— 上传本地文件到沙箱（二进制安全）
  - [`fs-tree-put`](#fstreeput) —— 整棵目录树上传（tar）
  - [`ls`](#ls) —— 列目录
  - [`stat`](#stat) —— 看文件/目录元信息
  - [`tree`](#tree) —— 递归列目录树
  - [`mkdir`](#mkdir) —— 建目录
  - [`rm`](#rm) —— 删除文件/目录
  - [`cp`](#cp) —— 复制
  - [`mv`](#mv) —— 移动/改名
  - [`edit`](#edit) —— 按行改文件（替换 / 插入）
  - [`grep`](#grep) —— 在沙箱内按正则搜文件内容
  - [`search`](#search) —— 按路径/文件名 glob 搜
- **终端 PTY**
  - [`pty-new`](#ptynew) —— 新建 PTY 会话
  - [`pty`](#pty) —— 在 PTY 会话里执行命令
  - [`pty-screen`](#ptyscreen) —— 读 PTY 当前屏幕快照
  - [`pty-input`](#ptyinput) —— 往 PTY 会话发输入
  - [`pty-signal`](#ptysignal) —— 给 PTY 会话发信号
  - [`pty-resize`](#ptyresize) —— 调整 PTY 终端尺寸
  - [`pty-ls`](#ptyls) —— 列出 PTY 会话
  - [`pty-rm`](#ptyrm) —— 删除 PTY 会话
  - [`pty-ws`](#ptyws) —— WebSocket 附着到 PTY 会话（非交互）
  - [`pty-ws-anon`](#ptywsanon) —— 匿名 WebShell 附着
- **代码**
  - [`code`](#code) —— 用内置代码解释器执行一段代码
  - [`code-info`](#codeinfo) —— 代码解释器信息（GET /v2/code/info）
  - [`code-sess-new`](#codesessnew) —— 新建代码会话
  - [`code-sess-ls`](#codesessls) —— 列出代码会话
  - [`code-sess-rm`](#codesessrm) —— 删除代码会话
- **浏览器**
  - [`br-info`](#brinfo) —— 浏览器信息（GET /v2/browser/info）
  - [`br-go`](#brgo) —— 导航到 URL
  - [`br-shot`](#brshot) —— 截图到本地 PNG
  - [`br-eval`](#breval) —— 在页面里执行 JS 表达式
  - [`br-click`](#brclick) —— 点击元素
  - [`br-fill`](#brfill) —— 填输入框
  - [`br-snapshot`](#brsnapshot) —— 抓页面可访问性快照
  - [`br-tabs`](#brtabs) —— 列出标签页
  - [`br-tab-new`](#brtabnew) —— 新开标签页
  - [`br-tab-use`](#brtabuse) —— 切换当前标签页
  - [`br-tab-close`](#brtabclose) —— 关闭标签页
  - [`br-cookies`](#brcookies) —— 读 Cookie
  - [`br-cookie-set`](#brcookieset) —— 写 Cookie
  - [`br-network`](#brnetwork) —— 抓网络请求列表
  - [`br-config`](#brconfig) —— 读/写浏览器配置（分辨率等）
  - [`br-cdp`](#brcdp) —— 直接发一条 CDP 命令
- **监听**
  - [`watch`](#watch) —— 创建文件监听器
  - [`watch-poll`](#watchpoll) —— 长轮询取监听事件
  - [`watch-events`](#watchevents) —— SSE 事件流（--max 收满退出）
  - [`watch-rm`](#watchrm) —— 删除监听器
- **MCP**
  - [`mcp`](#mcp) —— MCP Hub JSON-RPC 透传
- **桌面**
  - [`cmp-info`](#cmpinfo) —— computer-use worker 信息
  - [`cmp-shot`](#cmpshot) —— 桌面截图到本地 PNG
  - [`cmp-cursor`](#cmpcursor) —— 当前光标位置
  - [`cmp-clipboard`](#cmpclipboard) —— 读剪贴板
  - [`cmp-windows`](#cmpwindows) —— 列出窗口
  - [`cmp-a11y`](#cmpa11y) —— 可访问性树（应用级）
  - [`cmp-a11y-nodes`](#cmpa11ynodes) —— 可访问性节点明细
  - [`cmp-act`](#cmpact) —— 执行一个桌面动作
  - [`cmp-act-batch`](#cmpactbatch) —— 批量执行桌面动作
  - [`cmp-record`](#cmprecord) —— 桌面录制（start / stop）

## 基础

### health

```text
aio-cli health —— aiod 网关健康检查
分组: 基础

用途:  GET /health，原样打印响应信封。
用法:  aio-cli health
参数:  无。
示例:  aio-cli health
       → {"status":"healthy","version":"0.9.2",...}
```

### sandbox-info

```text
aio-cli sandbox-info —— 沙箱信息（GET /v2/sandbox）
分组: 基础

用途:  GET /v2/sandbox，拿沙箱画像（镜像、端口、平台版本等）。
用法:  aio-cli sandbox-info
参数:  无。输出为服务端原始 JSON。
示例:  aio-cli sandbox-info
```

### sandbox-packages

```text
aio-cli sandbox-packages —— 沙箱内置包清单
分组: 基础

用途:  GET /v2/sandbox/packages?lang=<lang>，列出镜像里预装的语言运行时/包。
用法:  aio-cli sandbox-packages [--lang=python|node]
参数:  --lang=   python（默认）/ node。
示例:  aio-cli sandbox-packages
       aio-cli sandbox-packages --lang=node
注意:  `data` 是纯文本，不是 JSON 数组。
```

### version

```text
aio-cli version —— 版本 / 构建信息
分组: 基础

用途:  打印版本号、仓库地址与构建目标。
用法:  aio-cli version        （等号写法：`aio-cli --version`）
参数:  无。
示例:  aio-cli version
```

### help

```text
aio-cli help —— 帮助：速查表 / all 完整表 / <命令> 详情
分组: 基础

用途:  打印帮助，**永不触发任何真实操作**，也不需要 SANDBOX_BASE。
用法:  aio-cli help              分组速查（常用命令）
       aio-cli help all          完整命令表（一条一行）
       aio-cli help <命令>       单命令详解
       aio-cli --help / -h      等价于 `aio-cli help`
       aio-cli <命令> --help     等价于 `aio-cli help <命令>`
       aio-cli <命令> -h         同上
示例:  aio-cli help pty-ws
       aio-cli br-go --help
注意:  未知命令会打印「未知命令：xxx」并以非 0 退出。
```

## 执行

### exec

```text
aio-cli exec —— 同步执行一条命令并打印输出
分组: 执行

用途:  POST /v2/commands（mode 缺省同步）。响应扁平，直接打印 stdout/stderr，
       非 0 退出码时补一行「（exit N）」。
用法:  aio-cli exec <命令> [参数…] [--cwd=<目录>] [--shell=<壳>] [--user=<用户>]
                      [--session=<会话id>] [--timeout=<毫秒>] [--max-output=<字节>]
       aio-cli exec --id=<command_id> [--offset=<字节>] [--stderr-offset=<字节>]
参数:  <命令> [参数…]  位置参数用空格拼成一条命令（不用自己转义引号）。
       --cwd=        工作目录。
       --shell=      指定 shell。
       --user=       以指定用户执行。
       --session=    在已有命令会话里执行。
       --timeout=    毫秒；到点返回 status=running，进程还在跑（自己 kill）。
       --max-output= 截断输出上限。
       --id=         改成「按 id 回读」模式，不带位置参数。
       --offset= / --stderr-offset=   回读时的字节偏移（增量取输出）。
示例:  aio-cli exec 'echo hello'
       aio-cli exec 'zig build -Doptimize=ReleaseFast' --cwd=/root/repo --timeout=600000
       aio-cli exec 'python3 -c "import sys;print(sys.version)"'
       ID=$(aio-cli async 'sleep 60'); aio-cli exec --id=$ID --offset=0
注意:  源码注释里出现过 `--env=`、`--wait`、`--wait-timeout`，**当前并未实现**。
       非 2xx 或 success=false → 打印 HTTP <码>: <message>，退出码非 0。
```

### async

```text
aio-cli async —— 异步派发一条命令，打印 command_id
分组: 执行

用途:  同 exec，但 mode=async，立即返回 command_id。
用法:  aio-cli async <命令> [参数…] [--cwd=] [--shell=] [--user=] [--session=] [--timeout=] [--max-output=]
参数:  同 exec（除 --id / --offset 系列）。
示例:  ID=$(aio-cli async 'pip install pandas && python3 -c "print(1+1)"')
       aio-cli log "$ID" --follow
       aio-cli kill "$ID"
```

### log

```text
aio-cli log —— 按 id 轮询/跟随输出
分组: 执行

用途:  GET /v2/commands/<id>，按 offset 增量读取 stdout/stderr。
用法:  aio-cli log <command_id> [--follow]
参数:  --follow  循环直到状态变成 completed/failed/killed/exited（最多 600 轮 × 0.5s）。
示例:  aio-cli log "$ID"
       aio-cli log "$ID" --follow
注意:  终态为 completed 且 exit_code=-1 时通常是被 kill 了，别用退出码反推信号。
```

### kill

```text
aio-cli kill —— 杀掉一条运行中的命令
分组: 执行

用途:  POST /v2/commands/<id>/kill。
用法:  aio-cli kill <command_id> [--signal=<信号>]
参数:  --signal=   默认 SIGKILL。
示例:  aio-cli kill "$ID"
       aio-cli kill "$ID" --signal=SIGTERM
```

### stdin

```text
aio-cli stdin —— 给运行中的命令喂 stdin
分组: 执行

用途:  POST /v2/commands/<id>/stdin。
用法:  aio-cli stdin <command_id> <文本> [--enter]
参数:  --enter  自动补一个换行。
示例:  aio-cli stdin "$ID" 'y' --enter
```

### sess-new

```text
aio-cli sess-new —— 新建命令会话（固定 cwd）
分组: 执行

用途:  POST /v2/commands/sessions。
用法:  aio-cli sess-new <会话id> [--cwd=<目录>]
参数:  --cwd=   会话内固定的工作目录。
示例:  aio-cli sess-new work --cwd=/root/repo
注意:  cwd 在创建时固定；会话内 `cd` 不跨调用保留。
```

### sess

```text
aio-cli sess —— 在命令会话里执行
分组: 执行

用途:  POST /v2/commands，带 session=<会话id>。
用法:  aio-cli sess <会话id> <命令> [参数…] [--timeout=<毫秒>]
参数:  --timeout=  毫秒。
示例:  aio-cli sess work 'ls -la'
```

### sess-ls

```text
aio-cli sess-ls —— 列出命令会话
分组: 执行

用途:  GET /v2/commands/sessions，输出原始 JSON。
用法:  aio-cli sess-ls
参数:  无。
示例:  aio-cli sess-ls
```

### sess-rm

```text
aio-cli sess-rm —— 删除命令会话
分组: 执行

用途:  DELETE /v2/commands/sessions/<id>。
用法:  aio-cli sess-rm <会话id>
参数:  <会话id>  位置参数，必填。
示例:  aio-cli sess-rm work
```

## 文件

### cat

```text
aio-cli cat —— 读沙箱内文件到标准输出
（同义词: read）
分组: 文件

用途:  GET /v2/fs/read?path=…，取 data.content 原样打到 stdout。
用法:  aio-cli cat <远端路径> [--user=<用户>]
       （`aio-cli read ...` 是同义词）
参数:  --user=   以指定用户身份读。
示例:  aio-cli cat /etc/hostname
       aio-cli cat /tmp/data.csv > data.csv
```

### write

```text
aio-cli write —— 把本地文件（或 stdin）写进沙箱
分组: 文件

用途:  POST /v2/fs/write，JSON 传 content（**按文本处理，非二进制安全**）。
用法:  aio-cli write <本地文件|-> <远端路径>
参数:  <本地文件|->  `-` 表示从 stdin 读（上限 4 MiB）。
示例:  aio-cli write ./data.csv /home/gem/data.csv
       echo hi | aio-cli write - /tmp/hi.txt
注意:  二进制文件请用 `put`（multipart）或 `fs-tree-put`（tar）。
```

### get

```text
aio-cli get —— 下载沙箱内文件到本地（二进制安全）
分组: 文件

用途:  GET /v2/fs/download?path=…，响应体原样落本地。
用法:  aio-cli get <远端路径> <本地文件> [--user=<用户>]
参数:  --user=   以指定用户身份读。
示例:  aio-cli get /home/gem/out.tar.gz ./out.tar.gz
注意:  目标已存在直接覆盖。
```

### put

```text
aio-cli put —— 上传本地文件到沙箱（二进制安全）
分组: 文件

用途:  multipart 上传到服务端 /tmp 再 move 到目标位置。
用法:  aio-cli put <本地文件|-> <远端路径> [--overwrite]
参数:  --overwrite  目标已存在时覆盖（不加会失败）。
示例:  aio-cli put ./app.tar.gz /home/gem/app.tar.gz
       aio-cli put ./a.txt /tmp/a.txt --overwrite
       cat ./a.bin | aio-cli put - /tmp/a.bin --overwrite
```

### fs-tree-put

```text
aio-cli fs-tree-put —— 整棵目录树上传（tar）
分组: 文件

用途:  PUT /v2/fs/tree，body 为未压缩 tar。输入是 gzip（.tgz）会自动先在本地解压。
用法:  aio-cli fs-tree-put <本地 tar|-> <远端目录> [--user=<用户>] [--json]
参数:  <本地 tar|->  `-` 表示从 stdin 读（上限 256 MiB）。
       --user=       以指定用户身份落盘。
       --json        只打印服务端 JSON，不打印人话摘要。
示例:  tar czf site.tgz site/ && aio-cli fs-tree-put site.tgz /home/gem/
       gunzip -c site.tgz | aio-cli fs-tree-put - /home/gem/site
注意:  服务端只收未压缩 tar；gzip 解压失败时按提示先本地 gunzip。
```

### ls

```text
aio-cli ls —— 列目录
分组: 文件

用途:  GET /v2/fs/list?path=…。
用法:  aio-cli ls [远端路径] [--user=<用户>]
参数:  [远端路径]  缺省为 /。
示例:  aio-cli ls /home/gem
注意:  不递归（要树看 `aio-cli tree`）。
```

### stat

```text
aio-cli stat —— 看文件/目录元信息
分组: 文件

用途:  GET /v2/fs/stat?path=…，输出原始 JSON。
用法:  aio-cli stat <远端路径> [--user=<用户>]
示例:  aio-cli stat /tmp
```

### tree

```text
aio-cli tree —— 递归列目录树
分组: 文件

用途:  GET /v2/fs/tree?path=…，递归展开。
用法:  aio-cli tree [远端路径] [--user=<用户>]
参数:  [远端路径]  缺省为 /。
示例:  aio-cli tree /root/repo
注意:  没有 `--depth=` / `--hidden=` 选项（源码未实现），深度由服务端决定。
```

### mkdir

```text
aio-cli mkdir —— 建目录
分组: 文件

用途:  POST /v2/fs/mkdir。**不递归**。
用法:  aio-cli mkdir <远端路径>
示例:  aio-cli mkdir /tmp/out
注意:  父目录不存在会失败；递归用 `aio-cli exec 'mkdir -p ...'`。
```

### rm

```text
aio-cli rm —— 删除文件/目录
分组: 文件

用途:  POST /v2/fs/delete。**不递归**。
用法:  aio-cli rm <远端路径>
示例:  aio-cli rm /tmp/out
注意:  非空目录删不掉；整树删除用 `aio-cli exec 'rm -rf ...'`。
```

### cp

```text
aio-cli cp —— 复制
分组: 文件

用途:  POST /v2/fs/copy。
用法:  aio-cli cp <源> <目标>
示例:  aio-cli cp /tmp/a.txt /tmp/b.txt
注意:  目标已存在时不会自动覆盖（需要先 rm）。
```

### mv

```text
aio-cli mv —— 移动/改名
分组: 文件

用途:  POST /v2/fs/move。
用法:  aio-cli mv <源> <目标>
示例:  aio-cli mv /tmp/a.txt /tmp/b.txt
注意:  同名目标已存在时会失败。
```

### edit

```text
aio-cli edit —— 按行改文件（替换 / 插入）
分组: 文件

用途:  POST /v2/fs/edit。
用法:  aio-cli edit <远端路径> --old=<原串> --new=<新串>
       aio-cli edit <远端路径> --insert=<行号> --text=<文本>
参数:  --old= --new=   str_replace 模式；--new 缺省为空串（等于删除该串）。
       --insert= --text=  insert 模式，--insert 是行号。
示例:  aio-cli edit /root/app.py --old='v1' --new='v2'
       aio-cli edit /root/app.py --insert=0 --text='import os'
注意:  没有 `--replace-all` 选项（源码未实现）。
```

### grep

```text
aio-cli grep —— 在沙箱内按正则搜文件内容
分组: 文件

用途:  POST /v2/fs/grep，固定 recursive=true。
用法:  aio-cli grep <远端路径> <正则>
参数:  <远端路径> <正则>  两个位置参数，均必填。
示例:  aio-cli grep /root/repo 'fn main'
注意:  没有 --fixed / --ignore-case / --include / --max 选项（源码未实现）。
```

### search

```text
aio-cli search —— 按路径/文件名 glob 搜
分组: 文件

用途:  GET /v2/fs/search?path=…&pattern=…
用法:  aio-cli search <远端路径> <glob>
参数:  <远端路径> <glob>  两个位置参数，均必填。
示例:  aio-cli search /root '*.zig'
注意:  搜的是**路径**，内容搜索用 `grep`。
```

## 终端 PTY

### pty-new

```text
aio-cli pty-new —— 新建 PTY 会话
分组: 终端 PTY

用途:  POST /v2/pty/sessions。
用法:  aio-cli pty-new <会话id> [--cwd=<目录>] [--cols=<列>] [--rows=<行>] [--retention=<时长>]
参数:  --cwd=       初始工作目录。
       --cols= --rows=  终端尺寸。
       --retention= 保留时长（透传给服务端）。
示例:  aio-cli pty-new t1 --cols=120 --rows=30
```

### pty

```text
aio-cli pty —— 在 PTY 会话里执行命令
分组: 终端 PTY

用途:  POST /v2/pty/sessions/<id>/exec。输出合流在 data.output。
用法:  aio-cli pty <会话id> <命令> [参数…] [--timeout=<毫秒>] [--async]
参数:  --timeout=  毫秒。
       --async     服务端不等结果，直接返回。
示例:  aio-cli pty t1 'tmux new -As work'
       aio-cli pty t1 'ls -la' --timeout=30000
```

### pty-screen

```text
aio-cli pty-screen —— 读 PTY 当前屏幕快照
分组: 终端 PTY

用途:  GET /v2/pty/sessions/<id>/screen。
用法:  aio-cli pty-screen <会话id>
示例:  aio-cli pty-screen t1
```

### pty-input

```text
aio-cli pty-input —— 往 PTY 会话发输入
分组: 终端 PTY

用途:  POST /v2/pty/sessions/<id>/input。
用法:  aio-cli pty-input <会话id> <文本> [--enter]
参数:  --enter  press_enter=true（补回车）。
示例:  aio-cli pty-input t1 'echo hi' --enter
```

### pty-signal

```text
aio-cli pty-signal —— 给 PTY 会话发信号
分组: 终端 PTY

用途:  POST /v2/pty/sessions/<id>/signal。
用法:  aio-cli pty-signal <会话id> [信号] [--signal=<信号>]
参数:  [信号]  也可以写成位置参数；--signal= 优先。默认 SIGINT。
示例:  aio-cli pty-signal t1 SIGTERM
注意:  实测发信号后会话往往直接终止。
```

### pty-resize

```text
aio-cli pty-resize —— 调整 PTY 终端尺寸
分组: 终端 PTY

用途:  PATCH /v2/pty/sessions/<id>。
用法:  aio-cli pty-resize <会话id> [--cols=<列>] [--rows=<行>]
示例:  aio-cli pty-resize t1 --cols=200 --rows=50
```

### pty-ls

```text
aio-cli pty-ls —— 列出 PTY 会话
分组: 终端 PTY

用途:  GET /v2/pty/sessions，输出原始 JSON。
用法:  aio-cli pty-ls
示例:  aio-cli pty-ls
```

### pty-rm

```text
aio-cli pty-rm —— 删除 PTY 会话
分组: 终端 PTY

用途:  DELETE /v2/pty/sessions/<id>。
用法:  aio-cli pty-rm <会话id>
示例:  aio-cli pty-rm t1
```

### pty-ws

```text
aio-cli pty-ws —— WebSocket 附着到 PTY 会话（非交互）
分组: 终端 PTY

用途:  ws://…/v2/pty/sessions/<id>/ws?protocol=json 附着；读到 --max 条就退出。
用法:  aio-cli pty-ws <会话id> [--send=<文本>] [--max=<条数>] [--raw]
参数:  --send=   服务端 ready 之后自动发送这段文本。
       --max=    收满 N 条退出，默认 5。
       --raw     输出原始帧，不做加工。
示例:  aio-cli pty-ws t1 --send='echo attached' --max=6
注意:  只支持 ws://（Zig 0.17 标准库缺 TLS/进程能力）；SANDBOX_BASE 是 https 时会给出
       「把二进制搬进沙箱、用 SANDBOX_BASE=http://127.0.0.1:8080」的替代方案。
       同一会话一次只允许一个 WS 连接，异常断开后要换会话名或等服务端超时。
```

### pty-ws-anon

```text
aio-cli pty-ws-anon —— 匿名 WebShell 附着
分组: 终端 PTY

用途:  ws://…/v2/pty/ws?protocol=json，不绑定具体会话。
用法:  aio-cli pty-ws-anon [--max=<条数>] [--send=<文本>] [--raw]
参数:  同 pty-ws，但没有 <会话id> 位置参数。
示例:  aio-cli pty-ws-anon --max=3
注意:  同 pty-ws，仅支持 ws://。
```

## 代码

### code

```text
aio-cli code —— 用内置代码解释器执行一段代码
分组: 代码

用途:  POST /v2/code/execute。
用法:  aio-cli code <源码…> [--lang=python|javascript] [--session=<会话id>] [--timeout=<毫秒>]
参数:  --lang=     语言，默认 python。
       --session=  复用一个 code 会话（保留变量）。
       --timeout=  毫秒。
示例:  aio-cli code 'print(sum(range(10)))'
       aio-cli code 'console.log(1+1)' --lang=javascript
注意:  status=error 时信封 success=false 但 data 完整，CLI 会打印 traceback 并非 0 退出。
```

### code-info

```text
aio-cli code-info —— 代码解释器信息（GET /v2/code/info）
分组: 代码

用途:  GET /v2/code/info。
用法:  aio-cli code-info
参数:  无。
示例:  aio-cli code-info
```

### code-sess-new

```text
aio-cli code-sess-new —— 新建代码会话
分组: 代码

用途:  POST /v2/code/sessions。
用法:  aio-cli code-sess-new [--lang=python|javascript]
参数:  --lang=   语言，默认 python。
示例:  aio-cli code-sess-new --lang=python
```

### code-sess-ls

```text
aio-cli code-sess-ls —— 列出代码会话
分组: 代码

用途:  GET /v2/code/sessions，输出原始 JSON。
用法:  aio-cli code-sess-ls
示例:  aio-cli code-sess-ls
```

### code-sess-rm

```text
aio-cli code-sess-rm —— 删除代码会话
分组: 代码

用途:  DELETE /v2/code/sessions/<id>。
用法:  aio-cli code-sess-rm <会话id>
示例:  aio-cli code-sess-rm cs_abc123
```

## 浏览器

### br-info

```text
aio-cli br-info —— 浏览器信息（GET /v2/browser/info）
分组: 浏览器

用途:  GET /v2/browser/info。
用法:  aio-cli br-info
参数:  无。
示例:  aio-cli br-info
注意:  需要带 Chromium 的镜像（--need=browser / aio-daemon）。
```

### br-go

```text
aio-cli br-go —— 导航到 URL
分组: 浏览器

用途:  POST /v2/browser/navigate。
用法:  aio-cli br-go <url> [--wait=<等待策略>] [--timeout=<毫秒>]
参数:  --wait=     wait_until 策略，如 load / networkidle（透传给服务端）。
       --timeout=  毫秒。
示例:  aio-cli br-go https://example.com
       aio-cli br-go https://example.com --wait=networkidle --timeout=30000
```

### br-shot

```text
aio-cli br-shot —— 截图到本地 PNG
分组: 浏览器

用途:  GET /v2/browser/screenshot，响应体是原始 PNG 字节，落本地文件。
用法:  aio-cli br-shot <本地输出.png> [--full] [--quality=<n>]
参数:  --full      整页截图（full_page=true）。
       --quality=  JPEG 质量（仅在服务端走 jpeg 时有意义）。
示例:  aio-cli br-shot shot.png
       aio-cli br-shot shot.png --full
注意:  落盘后会校验是不是 PNG，末尾标「(PNG ✓)」或「(⚠ 非 PNG)」。
```

### br-eval

```text
aio-cli br-eval —— 在页面里执行 JS 表达式
分组: 浏览器

用途:  POST /v2/browser/evaluate。
用法:  aio-cli br-eval <JS 表达式…>
参数:  位置参数用空格拼成表达式；不需要引号。
示例:  aio-cli br-eval 'document.title'
       aio-cli br-eval 'Array.from(document.querySelectorAll("a")).length'
注意:  源码注释提到 `--await`，**当前未实现**（Promise 结果不会自动等待）。
```

### br-click

```text
aio-cli br-click —— 点击元素
分组: 浏览器

用途:  POST /v2/browser/click。
用法:  aio-cli br-click --selector=<CSS>
参数:  --selector=  必填，CSS 选择器。
示例:  aio-cli br-click --selector='#submit'
注意:  没有 `--ref=` 选项（源码未实现），只能按 CSS 选择器点。
```

### br-fill

```text
aio-cli br-fill —— 填输入框
分组: 浏览器

用途:  POST /v2/browser/fill。
用法:  aio-cli br-fill --selector=<CSS> [--value=<文本>]
参数:  --selector=  必填。
       --value=     缺省为空串。
示例:  aio-cli br-fill --selector='input[name=q]' --value='zig lang'
```

### br-snapshot

```text
aio-cli br-snapshot —— 抓页面可访问性快照
分组: 浏览器

用途:  POST /v2/browser/snapshot。
用法:  aio-cli br-snapshot [--interactive]
参数:  --interactive  interactive=true，只要可交互节点。
示例:  aio-cli br-snapshot
       aio-cli br-snapshot --interactive
```

### br-tabs

```text
aio-cli br-tabs —— 列出标签页
分组: 浏览器

用途:  GET /v2/browser/tabs。
用法:  aio-cli br-tabs
示例:  aio-cli br-tabs
```

### br-tab-new

```text
aio-cli br-tab-new —— 新开标签页
分组: 浏览器

用途:  POST /v2/browser/tabs。
用法:  aio-cli br-tab-new [--url=<url>]
参数:  --url=   不给就是空白页。
示例:  aio-cli br-tab-new --url=https://example.com
```

### br-tab-use

```text
aio-cli br-tab-use —— 切换当前标签页
分组: 浏览器

用途:  POST /v2/browser/tabs/<id>（空 body）。
用法:  aio-cli br-tab-use <tabID>
参数:  <tabID>  位置参数，必填（id 从 `aio-cli br-tabs` 取）。
示例:  aio-cli br-tab-use 8f2c1a
```

### br-tab-close

```text
aio-cli br-tab-close —— 关闭标签页
分组: 浏览器

用途:  DELETE /v2/browser/tabs/<id>。
用法:  aio-cli br-tab-close <tabID>
参数:  <tabID>  位置参数，必填。
示例:  aio-cli br-tab-close 8f2c1a
```

### br-cookies

```text
aio-cli br-cookies —— 读 Cookie
分组: 浏览器

用途:  GET /v2/browser/cookies。
用法:  aio-cli br-cookies [--url=<url>]
参数:  --url=   按 url 过滤。
示例:  aio-cli br-cookies
       aio-cli br-cookies --url=https://example.com
```

### br-cookie-set

```text
aio-cli br-cookie-set —— 写 Cookie
分组: 浏览器

用途:  POST /v2/browser/cookies。
用法:  aio-cli br-cookie-set --name=<名> --value=<值> [--url=<url>] [--domain=<域>]
参数:  --name=  必填；--value= 默认空串；--url= / --domain= 可选。
示例:  aio-cli br-cookie-set --name=token --value=abc --domain=example.com
```

### br-network

```text
aio-cli br-network —— 抓网络请求列表
分组: 浏览器

用途:  GET /v2/browser/network/requests。
用法:  aio-cli br-network
参数:  无（没有 --limit= / --clear 选项，源码未实现）。
示例:  aio-cli br-network
```

### br-config

```text
aio-cli br-config —— 读/写浏览器配置（分辨率等）
分组: 浏览器

用途:  不带 --json 时 GET /v2/browser/config；带 --json 时 POST 整份配置。
用法:  aio-cli br-config
       aio-cli br-config --json='{"resolution":"1280x800"}'
参数:  --json=   要写入的配置 JSON（整体覆盖，不是单字段合并）。
示例:  aio-cli br-config
       aio-cli br-config --json='{"resolution":"1920x1080"}'
注意:  没有 `--resolution=WxH` 简写（源码未实现），只能整份 JSON 传。
```

### br-cdp

```text
aio-cli br-cdp —— 直接发一条 CDP 命令
分组: 浏览器

用途:  POST /v2/browser/cdp，{"method":…,"params":…}。
用法:  aio-cli br-cdp <CDP 方法> [--params=<JSON>]
参数:  <方法>        位置参数，必填，如 Page.navigate / Runtime.evaluate。
       --params=     CDP 参数 JSON，原样嵌入。
示例:  aio-cli br-cdp 'Page.reload' --params='{"ignoreCache":true}'
       aio-cli br-cdp 'Emulation.setDeviceMetricsOverride' \
              --params='{"width":1280,"height":800,"deviceScaleFactor":1,"mobile":false}'
注意:  没有 `--browser` 选项（源码未实现），默认就是当前浏览器 target。
```

## 监听

### watch

```text
aio-cli watch —— 创建文件监听器
分组: 监听

用途:  POST /v2/watch，返回 watcher_id。
用法:  aio-cli watch [远端路径] [--recursive] [--debounce=<毫秒>]
参数:  [远端路径]  缺省为 /。
       --recursive  递归监听子目录。
       --debounce=  防抖毫秒数。
示例:  aio-cli watch /tmp/out --recursive --debounce=300
       W=$(aio-cli watch /tmp/out --recursive | python3 -c 'import json,sys;print(json.load(sys.stdin)["watcher_id"])')
注意:  同一路径重复创建会**复用**已有监听器。
```

### watch-poll

```text
aio-cli watch-poll —— 长轮询取监听事件
分组: 监听

用途:  GET /v2/watch/<id>（服务端长轮询）。
用法:  aio-cli watch-poll <watcher_id>
参数:  <watcher_id>  位置参数，必填。
示例:  aio-cli watch-poll "$W"
注意:  没有 `--cursor=` / `--timeout=` / `--limit=` 选项（源码未实现）。
```

### watch-events

```text
aio-cli watch-events —— SSE 事件流（--max 收满退出）
分组: 监听

用途:  GET /v2/watch/<id>/events，text/event-stream。
用法:  aio-cli watch-events <watcher_id> [--max=<条数>] [--json]
参数:  --max=    收满 N 条退出；不给就一直挂着（Ctrl-C 退出）。
       --json    每条只打 data（原始 JSON），不加就打印可读格式。
示例:  aio-cli watch-events "$W" --max=5
注意:  --max 计入**首条** watch_started，所以 --max=1 会立刻返回。
```

### watch-rm

```text
aio-cli watch-rm —— 删除监听器
分组: 监听

用途:  DELETE /v2/watch/<id>。
用法:  aio-cli watch-rm <watcher_id>
参数:  <watcher_id>  位置参数，必填。
示例:  aio-cli watch-rm "$W"
注意:  没有 `watch-ls` 命令（源码未实现），ID 要自己留好。
```

## MCP

### mcp

```text
aio-cli mcp —— MCP Hub JSON-RPC 透传
分组: MCP

用途:  POST /mcp，{"jsonrpc":"2.0","id":1,"method":…,"params":…}。
用法:  aio-cli mcp <方法> [--params=<JSON>]
参数:  <方法>    initialize / tools/list / tools/call / ping 等。
       --params= JSON-RPC params，原样嵌入。
示例:  aio-cli mcp initialize
       aio-cli mcp tools/list
       aio-cli mcp ping
       aio-cli mcp tools/call --params='{"name":"browser_navigate","arguments":{"url":"https://example.com"}}'
注意:  tools/list 约 31 个工具；id 固定为 1。
```

## 桌面

### cmp-info

```text
aio-cli cmp-info —— computer-use worker 信息
分组: 桌面

用途:  GET /v2/computer/info。
用法:  aio-cli cmp-info
参数:  无。
示例:  aio-cli cmp-info
注意:  只有 aio-computer 镜像可用；aio-daemon 上 /v2/computer/* 返回 503。
```

### cmp-shot

```text
aio-cli cmp-shot —— 桌面截图到本地 PNG
分组: 桌面

用途:  GET /v2/computer/screenshot，原始 PNG 落本地。
用法:  aio-cli cmp-shot [本地输出.png]
参数:  [本地输出.png]  缺省 screenshot.png。
示例:  aio-cli cmp-shot desk.png
```

### cmp-cursor

```text
aio-cli cmp-cursor —— 当前光标位置
分组: 桌面

用途:  GET /v2/computer/cursor。
用法:  aio-cli cmp-cursor
示例:  aio-cli cmp-cursor
```

### cmp-clipboard

```text
aio-cli cmp-clipboard —— 读剪贴板
分组: 桌面

用途:  GET /v2/computer/clipboard。
用法:  aio-cli cmp-clipboard
示例:  aio-cli cmp-clipboard
注意:  **剪贴板为空时读会 503**：先 SET_CLIPBOARD（cmp-act）再读。
```

### cmp-windows

```text
aio-cli cmp-windows —— 列出窗口
分组: 桌面

用途:  GET /v2/computer/windows。
用法:  aio-cli cmp-windows
示例:  aio-cli cmp-windows
```

### cmp-a11y

```text
aio-cli cmp-a11y —— 可访问性树（应用级）
分组: 桌面

用途:  GET /v2/computer/accessibility。
用法:  aio-cli cmp-a11y [--scope=<范围>] [--max-depth=<n>] [--max-nodes=<n>]
                        [--role=<角色>] [--name=<名字>]
参数:  --scope= --max-depth= --max-nodes= --role= --name=   按需过滤/裁剪。
示例:  aio-cli cmp-a11y
       aio-cli cmp-a11y --role=button --max-nodes=50
```

### cmp-a11y-nodes

```text
aio-cli cmp-a11y-nodes —— 可访问性节点明细
分组: 桌面

用途:  GET /v2/computer/accessibility/nodes，支持比 cmp-a11y 更多的过滤。
用法:  aio-cli cmp-a11y-nodes [--scope=] [--max-depth=] [--max-nodes=] [--role=] [--name=]
                             [--match=<串>] [--states=<状态>] [--include-offscreen]
                             [--timeout-ms=<毫秒>] [--limit=<n>] [--node-id=<id>]
示例:  aio-cli cmp-a11y-nodes --role=button --limit=20
       aio-cli cmp-a11y-nodes --match=Save --include-offscreen
```

### cmp-act

```text
aio-cli cmp-act —— 执行一个桌面动作
分组: 桌面

用途:  POST /v2/computer/actions。动作体是 tagged union，CLI 会做归一（加法式补字段）。
用法:  aio-cli cmp-act '<JSON 动作>' [--screenshot]
参数:  --screenshot  加 include_screenshot=true，顺带回一张图。
示例:  aio-cli cmp-act '{"action_type":"CLICK","x":100,"y":200}'
       aio-cli cmp-act '{"action_type":"SET_CLIPBOARD","text":"hi"}'
       aio-cli cmp-act '{"action":"left_click","coordinate":[100,200]}' --screenshot
注意:  归一规则：①已有 action_type 原样透传 ②v1/OSWorld 风格动作名追加 action_type
       ③坐标类动作缺 x/y 而有 coordinate=[x,y] 时补上。绝不会删用户字段。
```

### cmp-act-batch

```text
aio-cli cmp-act-batch —— 批量执行桌面动作
分组: 桌面

用途:  POST /v2/computer/actions/batch，包成 {"actions":[…],"include_screenshot":bool}。
用法:  aio-cli cmp-act-batch '<JSON 动作数组>' [--screenshot]
参数:  --screenshot  结果里带回截图。
示例:  aio-cli cmp-act-batch '[{"action_type":"CLICK","x":10,"y":10},{"action_type":"TYPE","text":"hi"}]'
注意:  必须传 JSON 数组；非数组会明确报错退出。
```

### cmp-record

```text
aio-cli cmp-record —— 桌面录制（start / stop）
分组: 桌面

用途:  POST /v2/computer/record。
用法:  aio-cli cmp-record [--action=start|stop] [--fps=<n>] [--crf=<n>]
                          [--max-duration=<秒>] [--width=<px>] [--height=<px>] [--save-path=<路径>]
参数:  --action=      start（默认）/ stop。
       --fps= --crf=  帧率 / 质量（crf 越小越清晰）。
       --max-duration= 最长录制秒数。
       --width= --height= --save-path=  分辨率与落盘路径。
示例:  aio-cli cmp-record --action=start --fps=15
       aio-cli cmp-record --action=stop --save-path=/tmp/screen.mp4
```

