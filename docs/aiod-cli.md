# aiod-cli 命令手册

> **本文档由 `scripts/gen-docs.py` 从编译产物自动生成，请勿手工编辑。**
> 权威命令面是 `<cli> help`（表在 `src/help.zig`）；文档随代码走，改命令先改 help。
> 重新生成：
>
> ```bash
> zig build -Doptimize=ReleaseFast          # 两个工具都编一遍
> python3 scripts/gen-docs.py --cube aiod-cli --aio aiod-cli
> ```

`aiod-cli` 是 **沙箱内 aiod v2 API 遥控** CLI：命令执行、文件传输、PTY 终端、
代码解释器、浏览器、文件监听、MCP、桌面 computer-use。

- 建沙箱 / 选模板 / 快照 / 卷 是另一个工具 [`cube-cli`](cube-cli.md)。
- 源码：[`aiod-cli/`](https://github.com/otaku-say/sandbox-cli/tree/main/aiod-cli)，命令表
  [`aiod-cli/src/help.zig`](https://github.com/otaku-say/sandbox-cli/blob/main/aiod-cli/src/help.zig)。

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
cd aiod-cli && zig build -Doptimize=ReleaseFast
# 交叉编译到 ARM（iSH / 手机 / aarch64 机器）
cd aiod-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
```

| 目标三元组 | 产物文件名 | 用在哪 |
|---|---|---|
| `aarch64-linux-musl` | `aiod-cli-aarch64-linux-musl` | iSH（iOS）、ARM 服务器 |
| `x86_64-linux-musl` | `aiod-cli-x86_64-linux-musl` | x86 服务器、桌面 Linux |

产物在 `aiod-cli/zig-out/bin/aiod-cli`，ReleaseFast + strip 后约 1.1 MB 静态单文件。

## 快速上手

```bash
export SANDBOX_BASE="https://<网关>/sandbox/<sandboxID>/8080"
aiod-cli health
aiod-cli sandbox-info
aiod-cli exec 'zig version'
aiod-cli write ./report.md /home/gem/report.md && aiod-cli cat /home/gem/report.md
ID=$(aiod-cli async 'pip install -q pandas'); aiod-cli log "$ID" --follow
```

## 通用约定

- 输出走 stdout，错误走 stderr 且**退出码非 0**。
- 取值型 flag 一律 `--key=value`；布尔开关直接写 `--flag`。
- 响应信封统一为 `{success, message, data, hint}`；非 2xx 或 `success=false` → `HTTP <码>: <message>（hint: …）`。
- 命令列表里标注「源码未实现」的选项确实**没有**接线，源码里也只有注释提到过，别照抄旧文档。

## 帮助怎么用

```bash
aiod-cli help              # 分组速查（58 行，常用命令）
aiod-cli help all          # 完整命令表，一条一行
aiod-cli help pty-ws       # 单命令详解（本文档对应小节）
aiod-cli pty-ws --help     # 同上，**只打印不执行**
aiod-cli pty-ws -h         # 同上
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
  - [`pty-info`](#ptyinfo) —— 看单个 PTY 会话详情
  - [`pty-rm`](#ptyrm) —— 删除 PTY 会话
  - [`pty-ws`](#ptyws) —— WebSocket 附着到 PTY 会话（非交互）
  - [`pty-ws-anon`](#ptywsanon) —— 匿名 WebShell 附着
- **代码**
  - [`code`](#code) —— 用内置代码解释器执行一段代码
  - [`code-info`](#codeinfo) —— 代码解释器信息（GET /v2/code/info）
  - [`code-sess-new`](#codesessnew) —— 新建代码会话
  - [`code-sess-ls`](#codesessls) —— 列出代码会话
  - [`code-sess-get`](#codesessget) —— 看单个代码会话详情
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
  - [`br-cookie-rm`](#brcookierm) —— 删 Cookie（DELETE /v2/browser/cookies）
  - [`br-upload`](#brupload) —— 往 <input type=file> 挂文件（沙箱内路径）
  - [`br-network`](#brnetwork) —— 抓网络请求列表
  - [`br-config`](#brconfig) —— 读/写浏览器配置（分辨率等）
  - [`br-cdp`](#brcdp) —— 直接发一条 CDP 命令
- **监听**
  - [`watch`](#watch) —— 创建文件监听器
  - [`watch-poll`](#watchpoll) —— 长轮询取监听事件
  - [`watch-events`](#watchevents) —— SSE 事件流（--max 收满退出）
  - [`watch-rm`](#watchrm) —— 删除监听器
  - [`watch-ls`](#watchls) —— 列出所有监听器
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
aiod-cli health —— aiod 网关健康检查
分组: 基础

用途:  GET /health，原样打印响应信封。
用法:  aiod-cli health
参数:  无。
示例:  aiod-cli health
       → {"status":"healthy","version":"0.9.2",...}
```

### sandbox-info

```text
aiod-cli sandbox-info —— 沙箱信息（GET /v2/sandbox）
分组: 基础

用途:  GET /v2/sandbox，拿沙箱画像（镜像、端口、平台版本等）。
用法:  aiod-cli sandbox-info
参数:  无。输出为服务端原始 JSON。
示例:  aiod-cli sandbox-info
```

### sandbox-packages

```text
aiod-cli sandbox-packages —— 沙箱内置包清单
分组: 基础

用途:  GET /v2/sandbox/packages?lang=<lang>，列出镜像里预装的语言运行时/包。
用法:  aiod-cli sandbox-packages [--lang=python|node]
参数:  --lang=   python（默认）/ node。
示例:  aiod-cli sandbox-packages
       aiod-cli sandbox-packages --lang=node
注意:  `data` 是纯文本，不是 JSON 数组。
```

### version

```text
aiod-cli version —— 版本 / 构建信息
分组: 基础

用途:  打印版本号、仓库地址与构建目标。
用法:  aiod-cli version        （等号写法：`aiod-cli --version`）
参数:  无。
示例:  aiod-cli version
```

### help

```text
aiod-cli help —— 帮助：速查表 / all 完整表 / <命令> 详情
分组: 基础

用途:  打印帮助，**永不触发任何真实操作**，也不需要 SANDBOX_BASE。
用法:  aiod-cli help              分组速查（常用命令）
       aiod-cli help all          完整命令表（一条一行）
       aiod-cli help <命令>       单命令详解
       aiod-cli --help / -h      等价于 `aiod-cli help`
       aiod-cli <命令> --help     等价于 `aiod-cli help <命令>`
       aiod-cli <命令> -h         同上
示例:  aiod-cli help pty-ws
       aiod-cli br-go --help
注意:  未知命令会打印「未知命令：xxx」并以非 0 退出。
```

## 执行

### exec

```text
aiod-cli exec —— 同步执行一条命令并打印输出
分组: 执行

用途:  POST /v2/commands（mode 缺省同步）。响应扁平，直接打印 stdout/stderr，
       非 0 退出码时补一行「（exit N）」。
用法:  aiod-cli exec <命令> [参数…] [--cwd=<目录>] [--shell=<壳>] [--user=<用户>]
                      [--session=<会话id>] [--env=K=V,K2=V2] [--timeout=<毫秒>]
                      [--hard-timeout=<秒>] [--args='["a","b"]'] [--max-output=<字节>]
       aiod-cli exec --id=<command_id> [--offset=<字节>] [--stderr-offset=<字节>]
                      [--wait] [--wait-timeout=<秒>]
参数:  <命令> [参数…]  位置参数用空格拼成一条命令（不用自己转义引号）。
       --cwd=        工作目录。
       --shell=      指定 shell（auto|bash|sh|powershell|cmd|none）。
       --user=       以指定用户执行。
       --session=    在已有命令会话里执行。
       --env=        环境变量，K=V 逗号分隔 → JSON 对象（同名后者覆盖）。
       --timeout=    毫秒；到点返回 status=running，进程还在跑（自己 kill）。
       --hard-timeout=  秒；到点服务端强杀（返回 timed_out）。
       --args=       JSON 数组；仅 shell=none 时合法（argv 形式运行）。
       --max-output= 截断输出上限。
       --id=         改成「按 id 回读」模式，不带位置参数。
       --offset= / --stderr-offset=   回读时的字节偏移（增量取输出）。
       --wait / --wait-timeout=      回读时服务端等待至多 N 秒直到有输出/终态。
示例:  aiod-cli exec 'echo hello'
       aiod-cli exec 'echo $A' --env=A=B,C=D
       aiod-cli exec 'zig build -Doptimize=ReleaseFast' --cwd=/root/repo --timeout=600000
       ID=$(aiod-cli async 'sleep 60'); aiod-cli exec --id=$ID --offset=0
注意:  非 2xx 或 success=false → 打印 HTTP <码>: <message>，退出码非 0。
```

### async

```text
aiod-cli async —— 异步派发一条命令，打印 command_id
分组: 执行

用途:  同 exec，但 mode=async，立即返回 command_id。
用法:  aiod-cli async <命令> [参数…] [--cwd=] [--shell=] [--user=] [--session=] [--env=K=V,K2=V2] [--timeout=] [--hard-timeout=] [--args=] [--max-output=]
参数:  同 exec（除 --id / --offset / --wait 系列）。
示例:  ID=$(aiod-cli async 'pip install pandas && python3 -c "print(1+1)"')
       aiod-cli log "$ID" --follow
       aiod-cli kill "$ID"
```

### log

```text
aiod-cli log —— 按 id 轮询/跟随输出
分组: 执行

用途:  GET /v2/commands/<id>，按 offset 增量读取 stdout/stderr。
用法:  aiod-cli log <command_id> [--follow]
参数:  --follow  循环直到状态变成 completed/failed/killed/exited（最多 600 轮 × 0.5s）。
示例:  aiod-cli log "$ID"
       aiod-cli log "$ID" --follow
注意:  终态为 completed 且 exit_code=-1 时通常是被 kill 了，别用退出码反推信号。
```

### kill

```text
aiod-cli kill —— 杀掉一条运行中的命令
分组: 执行

用途:  POST /v2/commands/<id>/kill。
用法:  aiod-cli kill <command_id> [--signal=<信号>]
参数:  --signal=   默认 SIGKILL。
示例:  aiod-cli kill "$ID"
       aiod-cli kill "$ID" --signal=SIGTERM
```

### stdin

```text
aiod-cli stdin —— 给运行中的命令喂 stdin
分组: 执行

用途:  POST /v2/commands/<id>/stdin。
用法:  aiod-cli stdin <command_id> <文本> [--enter]
参数:  --enter  自动补一个换行。
示例:  aiod-cli stdin "$ID" 'y' --enter
```

### sess-new

```text
aiod-cli sess-new —— 新建命令会话（固定 cwd）
分组: 执行

用途:  POST /v2/commands/sessions。
用法:  aiod-cli sess-new <会话id> [--cwd=<目录>] [--env=K=V,K2=V2] [--user=<用户>]
参数:  --cwd=   会话内固定的工作目录。
       --env=   会话级环境变量（K=V 逗号分隔 → JSON 对象，同名后者覆盖）。
       --user=  以指定用户跑会话命令。
示例:  aiod-cli sess-new work --cwd=/root/repo --env=FOO=bar
注意:  cwd 在创建时固定；会话内 `cd` 不跨调用保留。
```

### sess

```text
aiod-cli sess —— 在命令会话里执行
分组: 执行

用途:  POST /v2/commands，带 session=<会话id>。
用法:  aiod-cli sess <会话id> <命令> [参数…] [--timeout=<毫秒>]
参数:  --timeout=  毫秒。
示例:  aiod-cli sess work 'ls -la'
```

### sess-ls

```text
aiod-cli sess-ls —— 列出命令会话
分组: 执行

用途:  GET /v2/commands/sessions，输出原始 JSON。
用法:  aiod-cli sess-ls
参数:  无。
示例:  aiod-cli sess-ls
```

### sess-rm

```text
aiod-cli sess-rm —— 删除命令会话
分组: 执行

用途:  DELETE /v2/commands/sessions/<id>。
用法:  aiod-cli sess-rm <会话id>
参数:  <会话id>  位置参数，必填。
示例:  aiod-cli sess-rm work
```

## 文件

### cat

```text
aiod-cli cat —— 读沙箱内文件到标准输出
（同义词: read）
分组: 文件

用途:  GET /v2/fs/read?path=…，取 data.content 原样打到 stdout。
用法:  aiod-cli cat <远端路径> [--start=<行>] [--end=<行>] [--user=<用户>]
       （`aiod-cli read ...` 是同义词）
参数:  --user=   以指定用户身份读。
       --start= / --end=   行区间（0 起；end 不含尾行）。
示例:  aiod-cli cat /etc/hostname
       aiod-cli cat /tmp/data.csv --start=0 --end=10 > data.csv
```

### write

```text
aiod-cli write —— 把本地文件（或 stdin）写进沙箱
分组: 文件

用途:  POST /v2/fs/write，JSON 传 content（**按文本处理，非二进制安全**）。
用法:  aiod-cli write <本地文件|-> <远端路径> [--append] [--encoding=utf-8|base64|raw]
                      [--leading-newline] [--trailing-newline]
参数:  <本地文件|->  `-` 表示从 stdin 读（上限 4 MiB）。
       --append       追加到文件末尾而非覆盖。
       --encoding=    内容编码：utf-8（默认）/ base64 / raw。
       --leading-newline / --trailing-newline  写入前/后补一个换行。
示例:  aiod-cli write ./data.csv /home/gem/data.csv
       echo hi | aiod-cli write - /tmp/hi.txt --append
注意:  二进制文件请用 `put`（multipart）或 `fs-tree-put`（tar）。
```

### get

```text
aiod-cli get —— 下载沙箱内文件到本地（二进制安全）
分组: 文件

用途:  GET /v2/fs/download?path=…，响应体原样落本地。
用法:  aiod-cli get <远端路径> <本地文件> [--user=<用户>]
参数:  --user=   以指定用户身份读。
示例:  aiod-cli get /home/gem/out.tar.gz ./out.tar.gz
注意:  目标已存在直接覆盖。
```

### put

```text
aiod-cli put —— 上传本地文件到沙箱（二进制安全）
分组: 文件

用途:  multipart 上传到服务端 /tmp 再 move 到目标位置。
用法:  aiod-cli put <本地文件|-> <远端路径> [--overwrite]
参数:  --overwrite  目标已存在时覆盖（不加会失败）。
示例:  aiod-cli put ./app.tar.gz /home/gem/app.tar.gz
       aiod-cli put ./a.txt /tmp/a.txt --overwrite
       cat ./a.bin | aiod-cli put - /tmp/a.bin --overwrite
```

### fs-tree-put

```text
aiod-cli fs-tree-put —— 整棵目录树上传（tar）
分组: 文件

用途:  PUT /v2/fs/tree，body 为未压缩 tar。输入是 gzip（.tgz）会自动先在本地解压。
用法:  aiod-cli fs-tree-put <本地 tar|-> <远端目录> [--user=<用户>] [--json]
参数:  <本地 tar|->  `-` 表示从 stdin 读（上限 256 MiB）。
       --user=       以指定用户身份落盘。
       --json        只打印服务端 JSON，不打印人话摘要。
示例:  tar czf site.tgz site/ && aiod-cli fs-tree-put site.tgz /home/gem/
       gunzip -c site.tgz | aiod-cli fs-tree-put - /home/gem/site
注意:  服务端只收未压缩 tar；gzip 解压失败时按提示先本地 gunzip。
```

### ls

```text
aiod-cli ls —— 列目录
分组: 文件

用途:  GET /v2/fs/list?path=…，透传递归/隐藏/深度参数。
用法:  aiod-cli ls [远端路径] [--recursive] [--hidden] [--depth=<层>] [--user=<用户>]
参数:  [远端路径]  缺省为 /。
       --recursive  递归列出子目录。
       --hidden     显示隐藏文件（. 开头）。
       --depth=     最大深度（配合 --recursive）。
示例:  aiod-cli ls /home/gem
       aiod-cli ls /root/repo --recursive --depth=1
注意:  --depth <= 1 时输出与默认不同（服务端含嵌套条目）。
```

### stat

```text
aiod-cli stat —— 看文件/目录元信息
分组: 文件

用途:  GET /v2/fs/stat?path=…，输出原始 JSON。
用法:  aiod-cli stat <远端路径> [--follow-symlinks] [--user=<用户>]
参数:  --follow-symlinks  跟随符号链接取目标信息。
示例:  aiod-cli stat /tmp
```

### tree

```text
aiod-cli tree —— 递归列目录树
分组: 文件

用途:  GET /v2/fs/tree?path=…，服务端返回的是原始 tar（x-tar）字节流。
用法:  aiod-cli tree [远端路径] [--user=<用户>] [--tar | --out=<本地文件>]
参数:  [远端路径]  缺省为 /。
       --tar   原样输出 tar 字节（可管道给 tar tf -）。
       --out=  把 tar 存到本地文件。
示例:  aiod-cli tree /root/repo
       aiod-cli tree /root/repo --out=repo.tar && tar tf repo.tar | head
注意:  默认输出是**解析后的条目树**（缩进表示层级）；旧版直接刷二进制。
```

### mkdir

```text
aiod-cli mkdir —— 建目录
分组: 文件

用途:  POST /v2/fs/mkdir。
用法:  aiod-cli mkdir <远端路径> [--parents]
参数:  --parents  递归建父目录（mkdir -p）；目标已存在也算成功。
示例:  aiod-cli mkdir /tmp/out
       aiod-cli mkdir /tmp/a/b/c --parents
```

### rm

```text
aiod-cli rm —— 删除文件/目录
分组: 文件

用途:  POST /v2/fs/delete。
用法:  aiod-cli rm <远端路径> [--recursive]
参数:  --recursive  递归删除非空目录（服务端默认仅删文件/空目录）。
示例:  aiod-cli rm /tmp/out
       aiod-cli rm /tmp/out --recursive
```

### cp

```text
aiod-cli cp —— 复制
分组: 文件

用途:  POST /v2/fs/copy。
用法:  aiod-cli cp <源> <目标> [--overwrite]
参数:  --overwrite  目标已存在时覆盖。
示例:  aiod-cli cp /tmp/a.txt /tmp/b.txt
       aiod-cli cp /tmp/a.txt /tmp/b.txt --overwrite
```

### mv

```text
aiod-cli mv —— 移动/改名
分组: 文件

用途:  POST /v2/fs/move。
用法:  aiod-cli mv <源> <目标> [--overwrite]
参数:  --overwrite  目标已存在时覆盖。
示例:  aiod-cli mv /tmp/a.txt /tmp/b.txt
       aiod-cli mv /tmp/a.txt /tmp/b.txt --overwrite
```

### edit

```text
aiod-cli edit —— 按行改文件（替换 / 插入）
分组: 文件

用途:  POST /v2/fs/edit。
用法:  aiod-cli edit <远端路径> --old=<原串> --new=<新串>
                      [--replace-all | --replace-first | --replace-last]
       aiod-cli edit <远端路径> --insert=<行号> --text=<文本>
参数:  --old= --new=   str_replace 模式；--new 缺省为空串（等于删除该串）。
       --replace-all   多处匹配全部替换（replace_mode=ALL）。
       --replace-first 只替换第一处（replace_mode=FIRST）。
       --replace-last  只替换最后一处（replace_mode=LAST）。
       --insert= --text=  insert 模式，--insert 是行号。
示例:  aiod-cli edit /root/app.py --old='v1' --new='v2'
       aiod-cli edit /root/app.py --old='x' --new='y' --replace-all
       aiod-cli edit /root/app.py --insert=0 --text='import os'
注意:  多处匹配而不给 replace_mode 时服务端 400（必须显式三选一）。
```

### grep

```text
aiod-cli grep —— 在沙箱内按正则搜文件内容
分组: 文件

用途:  POST /v2/fs/grep（固定 recursive=true）。
用法:  aiod-cli grep <远端路径> <正则> [--fixed] [--ignore-case] [--multiline]
                      [--include=a,b] [--exclude=a,b] [--context=<行>]
                      [--max=<条>] [--offset=<条>] [--type=<类型>]
参数:  --fixed        按字面串搜（fixed_strings=true）。
       --ignore-case  忽略大小写（case_insensitive=true）。
       --include= / --exclude=   文件名通配数组（逗号分隔）。
       --context=     前后各 N 行上下文。
       --multiline    跨行匹配。
       --max= / --offset=        结果条数上限 / 偏移。
       --type=        文件类型过滤（如 py、rust）。
示例:  aiod-cli grep /root/repo 'fn main' --include='*.zig' --max=20
```

### search

```text
aiod-cli search —— 按路径/文件名 glob 搜
分组: 文件

用途:  GET /v2/fs/search?path=…&pattern=…
用法:  aiod-cli search <远端路径> <glob>
参数:  <远端路径> <glob>  两个位置参数，均必填。
示例:  aiod-cli search /root '*.zig'
注意:  搜的是**路径**，内容搜索用 `grep`。
```

## 终端 PTY

### pty-new

```text
aiod-cli pty-new —— 新建 PTY 会话
分组: 终端 PTY

用途:  POST /v2/pty/sessions。
用法:  aiod-cli pty-new <会话id> [--cwd=<目录>] [--user=<用户>] [--cols=<列>] [--rows=<行>]
                      [--retention=<时长>] [--no-change-timeout=<秒>]
参数:  --cwd=       初始工作目录。
       --user=      终端 shell 以哪个用户跑（会话期间固定）。
       --cols= --rows=  终端尺寸。
       --retention= 保留时长（透传给服务端）。
       --no-change-timeout=  空闲无变化超时（秒）。
示例:  aiod-cli pty-new t1 --cols=120 --rows=30
注意:  `--env` 服务端（0.9.2）明确未实现、会 400；请在会话里 export。
```

### pty

```text
aiod-cli pty —— 在 PTY 会话里执行命令
分组: 终端 PTY

用途:  POST /v2/pty/sessions/<id>/exec。输出合流在 data.output。
用法:  aiod-cli pty <会话id> <命令> [参数…] [--timeout=<毫秒>] [--async]
                      [--hard-timeout=<秒>] [--no-change-timeout=<秒>]
参数:  --timeout=  毫秒。
       --async     服务端不等结果，直接返回。
       --hard-timeout=      秒；到点强杀。
       --no-change-timeout= 空闲无变化超时（秒）。
示例:  aiod-cli pty t1 'tmux new -As work'
       aiod-cli pty t1 'ls -la' --timeout=30000
```

### pty-screen

```text
aiod-cli pty-screen —— 读 PTY 当前屏幕快照
分组: 终端 PTY

用途:  GET /v2/pty/sessions/<id>/screen。
用法:  aiod-cli pty-screen <会话id>
示例:  aiod-cli pty-screen t1
```

### pty-input

```text
aiod-cli pty-input —— 往 PTY 会话发输入
分组: 终端 PTY

用途:  POST /v2/pty/sessions/<id>/input。
用法:  aiod-cli pty-input <会话id> <文本> [--enter]
参数:  --enter  press_enter=true（补回车）。
示例:  aiod-cli pty-input t1 'echo hi' --enter
```

### pty-signal

```text
aiod-cli pty-signal —— 给 PTY 会话发信号
分组: 终端 PTY

用途:  POST /v2/pty/sessions/<id>/signal。
用法:  aiod-cli pty-signal <会话id> [信号] [--signal=<信号>]
参数:  [信号]  也可以写成位置参数；--signal= 优先。默认 SIGINT。
示例:  aiod-cli pty-signal t1 SIGTERM
注意:  实测发信号后会话往往直接终止。
```

### pty-resize

```text
aiod-cli pty-resize —— 调整 PTY 终端尺寸
分组: 终端 PTY

用途:  PATCH /v2/pty/sessions/<id>。
用法:  aiod-cli pty-resize <会话id> [--cols=<列>] [--rows=<行>] [--no-change-timeout=<秒>]
示例:  aiod-cli pty-resize t1 --cols=200 --rows=50
```

### pty-ls

```text
aiod-cli pty-ls —— 列出 PTY 会话
分组: 终端 PTY

用途:  GET /v2/pty/sessions，输出原始 JSON。
用法:  aiod-cli pty-ls
示例:  aiod-cli pty-ls
```

### pty-info

```text
aiod-cli pty-info —— 看单个 PTY 会话详情
分组: 终端 PTY

用途:  GET /v2/pty/sessions/<id>。
用法:  aiod-cli pty-info <会话id>
示例:  aiod-cli pty-info t1
```

### pty-rm

```text
aiod-cli pty-rm —— 删除 PTY 会话
分组: 终端 PTY

用途:  DELETE /v2/pty/sessions/<id>。
用法:  aiod-cli pty-rm <会话id>
示例:  aiod-cli pty-rm t1
```

### pty-ws

```text
aiod-cli pty-ws —— WebSocket 附着到 PTY 会话（非交互）
分组: 终端 PTY

用途:  ws(s)://…/v2/pty/sessions/<id>/ws?protocol=json 附着；读到 --max 条就退出。
       SANDBOX_BASE 为 https:// 时自动走 wss://（手写 TLS 1.3，无 openssl）。
用法:  aiod-cli pty-ws <会话id> [--send=<文本>] [--max=<条数>] [--raw] [--insecure|-k]
参数:  --send=   服务端 ready 之后自动发送这段文本。
       --max=    收满 N 条退出，默认 5。
       --raw     输出原始帧，不做加工。
       -k / --insecure
                 跳过证书主机名校验（仅 wss://；自签证书调试用）。
       --durable / --restore / --replay-bytes=<n>  重连参数（透传服务端）。
示例:  aiod-cli pty-ws t1 --send='echo attached' --max=6
注意:  wss 默认校验证书主机名（含 IP SAN）并做 CertificateVerify 验签；
       完整证书链验证暂未实现。同一会话一次只允许一个 WS 连接，异常断开后要
       换会话名或等服务端超时。
```

### pty-ws-anon

```text
aiod-cli pty-ws-anon —— 匿名 WebShell 附着
分组: 终端 PTY

用途:  ws(s)://…/v2/pty/ws?protocol=json，不绑定具体会话。
       SANDBOX_BASE 为 https:// 时自动走 wss://（手写 TLS 1.3）。
用法:  aiod-cli pty-ws-anon [--max=<条数>] [--send=<文本>] [--raw] [--insecure|-k]
参数:  同 pty-ws，但没有 <会话id> 位置参数。
示例:  aiod-cli pty-ws-anon --max=3
注意:  同 pty-ws。
```

## 代码

### code

```text
aiod-cli code —— 用内置代码解释器执行一段代码
分组: 代码

用途:  POST /v2/code/execute。
用法:  aiod-cli code <源码…> [--lang=python|javascript] [--session=<会话id>] [--timeout=<毫秒>]
参数:  --lang=     语言，默认 python。
       --session=  复用一个 code 会话（保留变量）。
       --timeout=  毫秒。
示例:  aiod-cli code 'print(sum(range(10)))'
       aiod-cli code 'console.log(1+1)' --lang=javascript
注意:  status=error 时信封 success=false 但 data 完整，CLI 会打印 traceback 并非 0 退出。
```

### code-info

```text
aiod-cli code-info —— 代码解释器信息（GET /v2/code/info）
分组: 代码

用途:  GET /v2/code/info。
用法:  aiod-cli code-info
参数:  无。
示例:  aiod-cli code-info
```

### code-sess-new

```text
aiod-cli code-sess-new —— 新建代码会话
分组: 代码

用途:  POST /v2/code/sessions。
用法:  aiod-cli code-sess-new [--lang=python|javascript]
参数:  --lang=   语言，默认 python。
示例:  aiod-cli code-sess-new --lang=python
```

### code-sess-ls

```text
aiod-cli code-sess-ls —— 列出代码会话
分组: 代码

用途:  GET /v2/code/sessions，输出原始 JSON。
用法:  aiod-cli code-sess-ls
示例:  aiod-cli code-sess-ls
```

### code-sess-get

```text
aiod-cli code-sess-get —— 看单个代码会话详情
分组: 代码

用途:  GET /v2/code/sessions/<id>。
用法:  aiod-cli code-sess-get <会话id>
示例:  aiod-cli code-sess-get cs_abc123
```

### code-sess-rm

```text
aiod-cli code-sess-rm —— 删除代码会话
分组: 代码

用途:  DELETE /v2/code/sessions/<id>。
用法:  aiod-cli code-sess-rm <会话id>
示例:  aiod-cli code-sess-rm cs_abc123
```

## 浏览器

### br-info

```text
aiod-cli br-info —— 浏览器信息（GET /v2/browser/info）
分组: 浏览器

用途:  GET /v2/browser/info。
用法:  aiod-cli br-info
参数:  无。
示例:  aiod-cli br-info
注意:  需要带 Chromium 的镜像（--need=browser / aio-daemon）。
```

### br-go

```text
aiod-cli br-go —— 导航到 URL
分组: 浏览器

用途:  POST /v2/browser/navigate。
用法:  aiod-cli br-go <url> [--wait=<等待策略>] [--timeout=<毫秒>] [--tab=<id>]
       aiod-cli br-go --history=back|forward|reload [--tab=<id>]
参数:  --wait=     wait_until 策略，如 load / networkidle（透传给服务端）。
       --timeout=  毫秒。
       --tab=      指定标签页（tab_id）；缺省当前活动页。
       --history=  历史操作 back/forward/reload（与 url 互斥）。
示例:  aiod-cli br-go https://example.com
       aiod-cli br-go --history=reload
```

### br-shot

```text
aiod-cli br-shot —— 截图到本地 PNG
分组: 浏览器

用途:  GET /v2/browser/screenshot，响应体是原始 PNG 字节，落本地文件。
用法:  aiod-cli br-shot <本地输出.png> [--full] [--quality=<n>]
参数:  --full      整页截图（full_page=true）。
       --quality=  JPEG 质量（仅在服务端走 jpeg 时有意义）。
示例:  aiod-cli br-shot shot.png
       aiod-cli br-shot shot.png --full
注意:  落盘后会校验是不是 PNG，末尾标「(PNG ✓)」或「(⚠ 非 PNG)」。
```

### br-eval

```text
aiod-cli br-eval —— 在页面里执行 JS 表达式
分组: 浏览器

用途:  POST /v2/browser/evaluate。
用法:  aiod-cli br-eval <JS 表达式…> [--await]
参数:  位置参数用空格拼成表达式；不需要引号。
       --await  等待返回的 Promise（await_promise=true）。
示例:  aiod-cli br-eval 'document.title'
       aiod-cli br-eval 'fetch("/api").then(r => r.text())' --await
```

### br-click

```text
aiod-cli br-click —— 点击元素
分组: 浏览器

用途:  POST /v2/browser/click。
用法:  aiod-cli br-click (--selector=<CSS> | --ref=<快照ref>) [--tab=<id>]
参数:  --selector= / --ref=  二选一：CSS 选择器 或 快照元素 ref。
       --tab=      指定标签页。
示例:  aiod-cli br-click --selector='#submit'
       aiod-cli br-snapshot --interactive   # 先拿 ref
       aiod-cli br-click --ref=e5
```

### br-fill

```text
aiod-cli br-fill —— 填输入框
分组: 浏览器

用途:  POST /v2/browser/fill。
用法:  aiod-cli br-fill (--selector=<CSS> | --ref=<快照ref>) [--value=<文本>] [--tab=<id>]
参数:  --selector= / --ref=  二选一。
       --value=     缺省为空串。
       --tab=       指定标签页。
示例:  aiod-cli br-fill --selector='input[name=q]' --value='zig lang'
```

### br-snapshot

```text
aiod-cli br-snapshot —— 抓页面可访问性快照
分组: 浏览器

用途:  POST /v2/browser/snapshot。
用法:  aiod-cli br-snapshot [--interactive]
参数:  --interactive  interactive_only=true，只要可交互节点。
示例:  aiod-cli br-snapshot
       aiod-cli br-snapshot --interactive
```

### br-tabs

```text
aiod-cli br-tabs —— 列出标签页
分组: 浏览器

用途:  GET /v2/browser/tabs。
用法:  aiod-cli br-tabs
示例:  aiod-cli br-tabs
```

### br-tab-new

```text
aiod-cli br-tab-new —— 新开标签页
分组: 浏览器

用途:  POST /v2/browser/tabs。
用法:  aiod-cli br-tab-new [--url=<url>]
参数:  --url=   不给就是空白页。
示例:  aiod-cli br-tab-new --url=https://example.com
```

### br-tab-use

```text
aiod-cli br-tab-use —— 切换当前标签页
分组: 浏览器

用途:  POST /v2/browser/tabs/<id>（空 body）。
用法:  aiod-cli br-tab-use <tabID>
参数:  <tabID>  位置参数，必填（id 从 `aiod-cli br-tabs` 取）。
示例:  aiod-cli br-tab-use 8f2c1a
```

### br-tab-close

```text
aiod-cli br-tab-close —— 关闭标签页
分组: 浏览器

用途:  DELETE /v2/browser/tabs/<id>。
用法:  aiod-cli br-tab-close <tabID>
参数:  <tabID>  位置参数，必填。
示例:  aiod-cli br-tab-close 8f2c1a
```

### br-cookies

```text
aiod-cli br-cookies —— 读 Cookie
分组: 浏览器

用途:  GET /v2/browser/cookies。
用法:  aiod-cli br-cookies [--url=<url>]
参数:  --url=   按 url 过滤。
示例:  aiod-cli br-cookies
       aiod-cli br-cookies --url=https://example.com
```

### br-cookie-set

```text
aiod-cli br-cookie-set —— 写 Cookie
分组: 浏览器

用途:  POST /v2/browser/cookies（发 {"cookies":[…]} 包装体）。
用法:  aiod-cli br-cookie-set --name=<名> --value=<值> [--url=<url>] [--domain=<域>]
参数:  --name=  必填；--value= 默认空串；--url= / --domain= 可选。
示例:  aiod-cli br-cookie-set --name=token --value=abc --domain=example.com
```

### br-cookie-rm

```text
aiod-cli br-cookie-rm —— 删 Cookie（DELETE /v2/browser/cookies）
分组: 浏览器

用途:  DELETE /v2/browser/cookies。
用法:  aiod-cli br-cookie-rm [--all | --name=<名>] [--url=<url>] [--domain=<域>]
参数:  --all 清全部；按名删时 CDP 要求同时给 --url 或 --domain。
示例:  aiod-cli br-cookie-rm --name=token --domain=example.com
       aiod-cli br-cookie-rm --all
```

### br-upload

```text
aiod-cli br-upload —— 往 <input type=file> 挂文件（沙箱内路径）
分组: 浏览器

用途:  POST /v2/browser/upload，把**沙箱内**文件挂给页面上传控件。
用法:  aiod-cli br-upload --paths=<沙箱内文件,…> [--selector=<css> | --ref=<快照ref>] [--tab=<id>]
参数:  --paths=   逗号分隔的沙箱内绝对路径（必填）。
       --selector=  目标 <input type=file> 的 CSS 选择器。
       --ref=       或者用快照元素 ref。
示例:  aiod-cli br-upload --paths=/tmp/a.png --selector='#file-input'
注意:  文件必须先存在于沙箱里（用 write / put 先放进去）。
```

### br-network

```text
aiod-cli br-network —— 抓网络请求列表
分组: 浏览器

用途:  GET /v2/browser/network/requests。
用法:  aiod-cli br-network [--limit=<条数>] [--clear]
参数:  --limit=  最多返回条数。
       --clear  取回后清空缓冲。
示例:  aiod-cli br-network
       aiod-cli br-network --limit=20 --clear
```

### br-config

```text
aiod-cli br-config —— 读/写浏览器配置（分辨率等）
分组: 浏览器

用途:  缺省 GET /v2/browser/config；--resolution= 或 --json= 时 POST。
用法:  aiod-cli br-config [--resolution=<宽>x<高> | --json=<JSON>]
参数:  --resolution=  设置视口，如 1280x800 → {"width":1280,"height":800}。
       --json=        要写入的配置 JSON（整体覆盖，不是单字段合并）。
示例:  aiod-cli br-config
       aiod-cli br-config --resolution=1280x800
```

### br-cdp

```text
aiod-cli br-cdp —— 直接发一条 CDP 命令
分组: 浏览器

用途:  POST /v2/browser/cdp，{"method":…,"params":…}。
用法:  aiod-cli br-cdp <CDP 方法> [--params=<JSON>] [--browser] [--tab=<id>]
参数:  <方法>        位置参数，必填，如 Page.navigate / Runtime.evaluate。
       --params=     CDP 参数 JSON，原样嵌入。
       --browser     走浏览器级会话（Browser.* / Target.*）。
       --tab=        指定标签页 target。
示例:  aiod-cli br-cdp 'Page.reload' --params='{"ignoreCache":true}'
       aiod-cli br-cdp 'Emulation.setDeviceMetricsOverride' \
              --params='{"width":1280,"height":800,"deviceScaleFactor":1,"mobile":false}'
示例:  aiod-cli br-cdp 'Browser.getVersion' --browser
```

## 监听

### watch

```text
aiod-cli watch —— 创建文件监听器
分组: 监听

用途:  POST /v2/watch，返回 watcher_id。
用法:  aiod-cli watch [远端路径] [--recursive] [--debounce=<毫秒>] [--exclude=a,b] [--include=a,b]
参数:  [远端路径]  缺省为 /。
       --recursive  递归监听子目录。
       --debounce=  防抖毫秒数。
       --exclude=   排除规则数组（逗号分隔）。
       --include=   只保留匹配 include_patterns 的路径（逗号分隔）。
示例:  aiod-cli watch /tmp/out --recursive --debounce=300
       W=$(aiod-cli watch /tmp/out --recursive | python3 -c 'import json,sys;print(json.load(sys.stdin)["watcher_id"])')
注意:  同一路径重复创建会**复用**已有监听器。
```

### watch-poll

```text
aiod-cli watch-poll —— 长轮询取监听事件
分组: 监听

用途:  GET /v2/watch/<id>/poll（服务端长轮询）。
用法:  aiod-cli watch-poll <watcher_id> [--cursor=<游标>] [--limit=<条数>] [--timeout=<秒>]
参数:  <watcher_id>  位置参数，必填。
       --cursor=     从上次返回的 cursor 继续（缺省 0）。
       --limit=      单次最多返回条数。
       --timeout=    最长等待秒数（长轮询）。
示例:  aiod-cli watch-poll "$W"
       aiod-cli watch-poll "$W" --cursor=5 --limit=10 --timeout=30
注意:  响应含 cursor/events/overflow；用返回的 cursor 作为下次 --cursor。
```

### watch-events

```text
aiod-cli watch-events —— SSE 事件流（--max 收满退出）
分组: 监听

用途:  GET /v2/watch/<id>/events，text/event-stream。
用法:  aiod-cli watch-events <watcher_id> [--max=<条数>] [--json]
参数:  --max=    收满 N 条退出；不给就一直挂着（Ctrl-C 退出）。
       --json    每条只打 data（原始 JSON），不加就打印可读格式。
示例:  aiod-cli watch-events "$W" --max=5
注意:  --max 计入**首条** watch_started，所以 --max=1 会立刻返回。
```

### watch-rm

```text
aiod-cli watch-rm —— 删除监听器
分组: 监听

用途:  DELETE /v2/watch/<id>。
用法:  aiod-cli watch-rm <watcher_id>
参数:  <watcher_id>  位置参数，必填。
示例:  aiod-cli watch-rm "$W"
注意:  删除前可用 `watch-ls` 列出现有监听器。
```

### watch-ls

```text
aiod-cli watch-ls —— 列出所有监听器
分组: 监听

用途:  GET /v2/watch，输出原始 JSON。
用法:  aiod-cli watch-ls
参数:  无。
示例:  aiod-cli watch-ls
```

## MCP

### mcp

```text
aiod-cli mcp —— MCP Hub JSON-RPC 透传
分组: MCP

用途:  POST /mcp，{"jsonrpc":"2.0","id":1,"method":…,"params":…}。
用法:  aiod-cli mcp <方法> [--params=<JSON>]
参数:  <方法>    initialize / tools/list / tools/call / ping 等。
       --params= JSON-RPC params，原样嵌入。
示例:  aiod-cli mcp initialize
       aiod-cli mcp tools/list
       aiod-cli mcp ping
       aiod-cli mcp tools/call --params='{"name":"browser_navigate","arguments":{"url":"https://example.com"}}'
注意:  tools/list 约 31 个工具；id 固定为 1。
```

## 桌面

### cmp-info

```text
aiod-cli cmp-info —— computer-use worker 信息
分组: 桌面

用途:  GET /v2/computer/info。
用法:  aiod-cli cmp-info
参数:  无。
示例:  aiod-cli cmp-info
注意:  只有 aio-computer 镜像可用；aio-daemon 上 /v2/computer/* 返回 503。
```

### cmp-shot

```text
aiod-cli cmp-shot —— 桌面截图到本地 PNG
分组: 桌面

用途:  GET /v2/computer/screenshot，原始 PNG 落本地。
用法:  aiod-cli cmp-shot [本地输出.png]
参数:  [本地输出.png]  缺省 screenshot.png。
示例:  aiod-cli cmp-shot desk.png
```

### cmp-cursor

```text
aiod-cli cmp-cursor —— 当前光标位置
分组: 桌面

用途:  GET /v2/computer/cursor。
用法:  aiod-cli cmp-cursor
示例:  aiod-cli cmp-cursor
```

### cmp-clipboard

```text
aiod-cli cmp-clipboard —— 读剪贴板
分组: 桌面

用途:  GET /v2/computer/clipboard。
用法:  aiod-cli cmp-clipboard
示例:  aiod-cli cmp-clipboard
注意:  **剪贴板为空时读会 503**：先 SET_CLIPBOARD（cmp-act）再读。
```

### cmp-windows

```text
aiod-cli cmp-windows —— 列出窗口
分组: 桌面

用途:  GET /v2/computer/windows。
用法:  aiod-cli cmp-windows
示例:  aiod-cli cmp-windows
```

### cmp-a11y

```text
aiod-cli cmp-a11y —— 可访问性树（应用级）
分组: 桌面

用途:  GET /v2/computer/accessibility。
用法:  aiod-cli cmp-a11y [--scope=<范围>] [--max-depth=<n>] [--max-nodes=<n>]
                        [--role=<角色>] [--name=<名字>]
参数:  --scope= --max-depth= --max-nodes= --role= --name=   按需过滤/裁剪。
示例:  aiod-cli cmp-a11y
       aiod-cli cmp-a11y --role=button --max-nodes=50
```

### cmp-a11y-nodes

```text
aiod-cli cmp-a11y-nodes —— 可访问性节点明细
分组: 桌面

用途:  GET /v2/computer/accessibility/nodes，支持比 cmp-a11y 更多的过滤。
用法:  aiod-cli cmp-a11y-nodes [--scope=] [--max-depth=] [--max-nodes=] [--role=] [--name=]
                             [--match=<串>] [--states=<状态>] [--include-offscreen]
                             [--timeout-ms=<毫秒>] [--limit=<n>] [--node-id=<id>]
示例:  aiod-cli cmp-a11y-nodes --role=button --limit=20
       aiod-cli cmp-a11y-nodes --match=Save --include-offscreen
```

### cmp-act

```text
aiod-cli cmp-act —— 执行一个桌面动作
分组: 桌面

用途:  POST /v2/computer/actions。动作体是 tagged union，CLI 会做归一（加法式补字段）。
用法:  aiod-cli cmp-act '<JSON 动作>' [--screenshot]
参数:  --screenshot  加 include_screenshot=true，顺带回一张图。
示例:  aiod-cli cmp-act '{"action_type":"CLICK","x":100,"y":200}'
       aiod-cli cmp-act '{"action_type":"SET_CLIPBOARD","text":"hi"}'
       aiod-cli cmp-act '{"action":"left_click","coordinate":[100,200]}' --screenshot
注意:  归一规则：①已有 action_type 原样透传 ②v1/OSWorld 风格动作名追加 action_type
       ③坐标类动作缺 x/y 而有 coordinate=[x,y] 时补上。绝不会删用户字段。
```

### cmp-act-batch

```text
aiod-cli cmp-act-batch —— 批量执行桌面动作
分组: 桌面

用途:  POST /v2/computer/actions/batch，包成 {"actions":[…],"include_screenshot":bool}。
用法:  aiod-cli cmp-act-batch '<JSON 动作数组>' [--screenshot]
参数:  --screenshot  结果里带回截图。
示例:  aiod-cli cmp-act-batch '[{"action_type":"CLICK","x":10,"y":10},{"action_type":"TYPE","text":"hi"}]'
注意:  必须传 JSON 数组；非数组会明确报错退出。
```

### cmp-record

```text
aiod-cli cmp-record —— 桌面录制（start / stop）
分组: 桌面

用途:  POST /v2/computer/record。
用法:  aiod-cli cmp-record [--action=start|stop] [--fps=<n>] [--crf=<n>]
                          [--max-duration=<秒>] [--width=<px>] [--height=<px>] [--save-path=<路径>]
参数:  --action=      start（默认）/ stop。
       --fps= --crf=  帧率 / 质量（crf 越小越清晰）。
       --max-duration= 最长录制秒数。
       --width= --height= --save-path=  分辨率与落盘路径。
示例:  aiod-cli cmp-record --action=start --fps=15
       aiod-cli cmp-record --action=stop --save-path=/tmp/screen.mp4
```

