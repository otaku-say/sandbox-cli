# cube-cli 命令手册

> **本文档由 `scripts/gen-docs.py` 从编译产物自动生成，请勿手工编辑。**
> 权威命令面是 `<cli> help`（表在 `src/help.zig`）；文档随代码走，改命令先改 help。
> 重新生成：
>
> ```bash
> zig build -Doptimize=ReleaseFast          # 两个工具都编一遍
> python3 scripts/gen-docs.py --cube cube-cli --aio aio-cli
> ```

`cube-cli` 是 **CubeSandbox 控制面** CLI：建/查/销毁沙箱、选模板、打快照与回滚、
持久卷、以及沙箱内文件操作（envd 通道）。

- 数据面遥控（执行 / PTY / 浏览器 / 桌面）是另一个工具 [`aio-cli`](aio-cli.md)。
- 源码：[`cube-cli/`](https://github.com/otaku-say/sandbox-cli/tree/main/cube-cli)，命令表
  [`cube-cli/src/help.zig`](https://github.com/otaku-say/sandbox-cli/blob/main/cube-cli/src/help.zig)。

## 环境变量

仓库内**不含任何主机名 / IP / 凭据**，全部从环境变量读取。只有 `CUBESANDBOX_*` 这四个（旧命名 `CUBE_API_URL` / `CUBE_API_KEY` / `CBS_PROXY_BASE` 已彻底移除，不再兼容）。

| 变量 | 必填 | 用途 |
|---|---|---|
| `CUBESANDBOX_API_URL` | 是 | 控制面地址。缺失时任何控制面命令报「错误：缺少环境变量 CUBESANDBOX_API_URL」。 |
| `CUBESANDBOX_API_KEY` | 否 | 控制面 API Key（`X-API-KEY` 头）。本部署未启用鉴权时可省略。 |
| `CUBESANDBOX_PROXY_URL` | exec/文件/ports 必填 | 数据面网关。缺失时报「错误：缺少环境变量 CUBESANDBOX_PROXY_URL」。 |
| `CUBESANDBOX_AGENT_NAME` | 否 | `new` 写入 `metadata.agent` 的默认名字，不设则记 `cube-cli`。 |

## 构建与产物名

需要 Zig **0.17.0**。两种目标都要能编过：

```bash
# 本机架构
cd cube-cli && zig build -Doptimize=ReleaseFast
# 交叉编译到 ARM（iSH / 手机 / aarch64 机器）
cd cube-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
```

| 目标三元组 | 产物文件名 | 用在哪 |
|---|---|---|
| `aarch64-linux-musl` | `cube-cli-aarch64-linux-musl` | iSH（iOS）、ARM 服务器 |
| `x86_64-linux-musl` | `cube-cli-x86_64-linux-musl` | x86 服务器、桌面 Linux |

产物在 `cube-cli/zig-out/bin/cube-cli`，ReleaseFast + strip 后约 1.2 MB 静态单文件。

## 拿到沙箱后交给 aio-cli

`cube-cli new` 输出的 `[sandbox] AIO 网关:` 那行**就是** `aio-cli` 的 `SANDBOX_BASE`：

```bash
SID=$(cube-cli new --note=demo)
# 输出里：[sandbox] AIO 网关: https://<网关>/sandbox/<sandboxID>/8080/   ← aio-cli 的 SANDBOX_BASE
export SANDBOX_BASE="https://<网关>/sandbox/$SID/8080"   # 末尾的 / 无所谓
aio-cli health
```

若把二进制搬进沙箱内部执行，`SANDBOX_BASE` 写回环地址即可：`SANDBOX_BASE=http://127.0.0.1:8080`（此时不再经过网关；这也是 `pty-ws` 唯一支持的形态，因为它只能走 `ws://`）。

## 帮助怎么用

```bash
cube-cli help              # 分组速查（58 行，常用命令）
cube-cli help all          # 完整命令表，一条一行
cube-cli help new          # 单命令详解（本文档对应小节）
cube-cli new --help        # 同上，**只打印不建沙箱**
cube-cli new -h            # 同上
```

未知命令会打印「未知命令：xxx」并以退出码 1 结束。所有取值型 flag 一律写**`--key=value`** 等号形式；布尔开关直接写 `--flag`（不要写 `--flag=true`）。

## 命令索引

- **沙箱**
  - [`new`](#new) —— 建沙箱（默认 aio-code 镜像）
  - [`ls`](#ls) —— 列出沙箱（ID / 模板 / 状态 / 备注）
  - [`rm`](#rm) —— 销毁沙箱
  - [`exec`](#exec) —— 在沙箱内执行命令
  - [`code`](#code) —— 用解释器在沙箱内跑一段代码
  - [`ports`](#ports) —— 实测沙箱内实际监听的端口
  - [`info`](#info) —— 沙箱详情（规格 / 元数据 / 卷挂载 / 截止时间）
- **生命周期**
  - [`pause`](#pause) —— 暂停沙箱（挂起快照，0 成本）
  - [`resume`](#resume) —— 恢复暂停的沙箱
  - [`timeout`](#timeout) —— 设置空闲回收超时
  - [`refresh`](#refresh) —— 续期：新增一个时间窗
  - [`net`](#net) —— 更新沙箱网络策略
  - [`connect`](#connect) —— 连接/续期（官方推荐，替代 deprecated 的 resume）
- **快照 / 卷**
  - [`snap`](#snap) —— 给沙箱打快照
  - [`snap-ls`](#snapls) —— 快照列表
  - [`snap-rm`](#snaprm) —— 删除快照
  - [`rollback`](#rollback) —— 回滚沙箱到某个快照
  - [`clone`](#clone) —— 打快照并用它当模板批量克隆
  - [`vol-ls`](#volls) —— 列出持久卷
  - [`vol-new`](#volnew) —— 新建持久卷
  - [`vol-info`](#volinfo) —— 查看持久卷详情
  - [`vol-rm`](#volrm) —— 删除持久卷
- **模板**
  - [`tpl-ls`](#tplls) —— 模板列表（含网关端口推断）
  - [`tpl-caps`](#tplcaps) —— 模板能力画像（能力 + 端口 + 网关）
  - [`tpl-pick`](#tplpick) —— 按能力挑一个模板
  - [`tpl-info`](#tplinfo) —— 模板详情摘要
  - [`tpl-logs`](#tpllogs) —— 模板构建日志
  - [`tpl-from-image`](#tplfromimage) —— 从 OCI 镜像推导模板默认值
- **文件**
  - [`cat`](#cat) —— 读沙箱内文件到标准输出（同义词 `read`）
  - [`write`](#write) —— 把本地文件（或 stdin）写进沙箱
  - [`get`](#get) —— 把沙箱内文件下载到本地（二进制安全）
  - [`ls-file`](#lsfile) —— 列沙箱内目录
  - [`stat`](#stat) —— 看沙箱内文件/目录元信息
  - [`mkdir`](#mkdir) —— 在沙箱内建目录
  - [`rm-file`](#rmfile) —— 删除沙箱内文件/目录
  - [`mv`](#mv) —— 移动/改名沙箱内文件
- **诊断 / 其它**
  - [`health`](#health) —— 控制面健康检查
  - [`version`](#version) —— 版本 / 构建信息
  - [`help`](#help) —— 帮助：默认速查表 / all 完整表 / <命令> 详情
  - [`logs`](#logs) —— 沙箱日志（启动 / 运行；排障首选）
  - [`raw`](#raw) —— 任意控制面 API 透传（未覆盖端点的兜底）

## 沙箱

### new

```text
cube-cli new —— 建沙箱（默认 aio-code 镜像）
分组: 沙箱

用途:  按能力（--need）或指定模板（--template）新建一个沙箱，并打印 AIO 网关地址
       （也就是 aio-cli 的 SANDBOX_BASE）。
用法:  cube-cli new [--need=code|browser|desktop] [--template=<模板ID>]
                      [--timeout=<秒>] [--note=<名称>] [--agent=<谁>] [--task=<做什么>]
参数:  --need=      需要的能力，默认 code。不带任何参数就是 aio-code 镜像（自带 Zig 工具链）
                    browser / desktop 分别对应 aio-daemon / aio-computer 镜像。
       --template=  直接指定模板 ID，优先于 --need。
       --timeout=   空闲回收秒数；不传用平台默认。
       --note=      显示名（ls 的"备注"列）。不给时按 "<agent> · <task>" 生成。
       --agent=     谁开的；缺省读环境变量 CUBESANDBOX_AGENT_NAME，再缺省为 cube-cli。
       --task=      做什么，进 metadata.task，admin WebUI 会渲染。
示例:  cube-cli new --note=build --agent=ci --task="跑 Zig 构建"
       cube-cli new --need=browser --timeout=1800
注意:  `--need=` 是动态挑模板（能力覆盖 + 更薄者优先）；没有满足的 READY 模板会
       报「没有满足 --need=... 的 READY 模板」并以非 0 退出。
       `cube-cli new --help` 只打印本页，不会建沙箱。
```

### ls

```text
cube-cli ls —— 列出沙箱（ID / 模板 / 状态 / 备注）
分组: 沙箱

用途:  列出账号下所有沙箱。
用法:  cube-cli ls
参数:  无。
示例:  cube-cli ls
注意:  "备注"列取 metadata.note，没有则取 metadata.agent，再没有显示 "-"。
```

### rm

```text
cube-cli rm —— 销毁沙箱
分组: 沙箱

用途:  销毁一个沙箱（DELETE /sandboxes/<id>）。
用法:  cube-cli rm <sandboxID>
参数:  <sandboxID>  位置参数，必填。
示例:  cube-cli rm 799fd44ef23e49eb8f4357807da32323
注意:  不可恢复；正在跑的进程一并终止。ID 可从 `cube-cli ls` 取。
```

### exec

```text
cube-cli exec —— 在沙箱内执行命令
分组: 沙箱

用途:  走沙箱内 envd（49983）执行一条命令并打印 stdout/stderr/exit。
用法:  cube-cli exec <sandboxID> <命令...> [--cwd=<目录>] [--env=NAME|KEY=VAL] [--timeout=<秒>]
参数:  <sandboxID>  目标沙箱。
       <命令...>    位置参数会原样用空格拼回一条命令（无需自己转义引号）。
       --cwd=       工作目录。
       --env=       K=V 直接给值；只给 NAME 则从**本机环境**读同名变量注入
                    （敏感值不必出现在命令行 / 进程列表里）。
       --timeout=   秒，默认 60。
示例:  cube-cli exec $SID 'zig version'
       cube-cli exec $SID 'python3 -c "print(1+1)"' --cwd=/tmp --timeout=300
       cube-cli exec $SID 'printenv' --env=GITHUB_TOKEN
注意:  需要 CUBESANDBOX_PROXY_URL（数据面网关）才有 envd 通道。
```

### code

```text
cube-cli code —— 用解释器在沙箱内跑一段代码
分组: 沙箱

用途:  把一段源码交给解释器执行（内部等价于 exec python3 -c ...），不依赖 Jupyter 内核，
       任何镜像都可用。
用法:  cube-cli code <sandboxID> <代码...> [--lang=python|js|bash] [--timeout=<秒>] [--env=...]
参数:  <代码...>    位置参数用空格拼接后整体交给解释器。
       --lang=      python（默认）/ js（js、javascript、node、nodejs）/ bash（sh、shell）。
       --timeout=   秒，默认 120。
       --env=       同 exec。
示例:  cube-cli code $SID 'print(sum(range(10)))'
       cube-cli code $SID 'console.log(1+1)' --lang=js
注意:  语言别名与非法语言：非法值会打印「不支持的语言: xxx」并以非 0 退出。
```

### ports

```text
cube-cli ports —— 实测沙箱内实际监听的端口
分组: 沙箱

用途:  在沙箱内读 /proc/net/tcp*，列出真实 LISTEN 端口、绑定地址、可否外部访问，
       以及对应的网关访问 URL。
用法:  cube-cli ports <sandboxID>
参数:  <sandboxID>  位置参数，必填。
示例:  cube-cli ports $SID
注意:  模板声明的 exposedPorts 未必等于实际监听（创建时传了也可能被忽略），
       真正决定可达性的是绑定地址：0.0.0.0 / :: 可连，127.0.0.1 / ::1 只有沙箱内部能连。
```

### info

```text
cube-cli info —— 沙箱详情（规格 / 元数据 / 卷挂载 / 截止时间）
分组: 沙箱

用途:  查看单个沙箱完整状态：state、CPU/内存/磁盘、起止时间、metadata、volumeMounts、domain。
用法:  cube-cli info <sandboxID> [--json] [--wait=<状态>] [--timeout=<秒>]
参数:  --json 原样输出；--wait= 轮询到指定状态（如 running）；--timeout= 最大等待秒数。
示例:  cube-cli info 6f1a... --json
注意:  上游详情不含网络策略（改策略用 net 命令）。
```

## 生命周期

### pause

```text
cube-cli pause —— 暂停沙箱（挂起快照，0 成本）
分组: 生命周期

用途:  POST /sandboxes/<id>/pause，挂起成快照，磁盘态冻结、不计 CPU/内存。
用法:  cube-cli pause <sandboxID>
参数:  <sandboxID>  位置参数，必填。
示例:  cube-cli pause $SID
注意:  恢复用 `cube-cli resume <sandboxID>`。
```

### resume

```text
cube-cli resume —— 恢复暂停的沙箱
分组: 生命周期

用途:  POST /sandboxes/<id>/resume。
用法:  cube-cli resume <sandboxID> [--timeout=<秒>]
参数:  --timeout=   恢复后的新时间窗（秒）；不传则平台沿用原值。
示例:  cube-cli resume $SID --timeout=1800
```

### timeout

```text
cube-cli timeout —— 设置空闲回收超时
分组: 生命周期

用途:  POST /sandboxes/<id>/timeout，改空闲回收时间。
用法:  cube-cli timeout <sandboxID> <秒>
参数:  <秒>        位置参数，必填；-1 表示永不回收。
示例:  cube-cli timeout $SID 7200
       cube-cli timeout $SID -1
```

### refresh

```text
cube-cli refresh —— 续期：新增一个时间窗
分组: 生命周期

用途:  POST /sandboxes/<id>/refreshes，**新增**一个时间窗（不是从现在起重算）。
用法:  cube-cli refresh <sandboxID> <秒>
参数:  <秒>        新增窗口长度，必填。
示例:  cube-cli refresh $SID 3600
注意:  长任务跑到一半时间要到了，用 refresh 续命，别去改 timeout。
```

### net

```text
cube-cli net —— 更新沙箱网络策略
分组: 生命周期

用途:  PUT /sandboxes/<id>/network（204 即成功）。
用法:  cube-cli net <sandboxID> [--no-internet|--internet] [--allow=域1,域2] [--deny=域1,域2]
参数:  --no-internet   allowInternetAccess=false。
       --internet      allowInternetAccess=true（与 --no-internet 互斥，别同时给）。
       --allow=        逗号分隔的出站放行域 → allowOut。
       --deny=         逗号分隔的出站拒绝域 → denyOut。
示例:  cube-cli net $SID --no-internet
       cube-cli net $SID --allow=github.com,registry.npmjs.org
```

### connect

```text
cube-cli connect —— 连接/续期（官方推荐，替代 deprecated 的 resume）
分组: 生命周期

用途:  把沙箱唤醒并保证「至少还剩 N 秒」（不会缩短已有的更长截止）。
用法:  cube-cli connect <sandboxID> [--timeout=<秒>] [--json]
参数:  --timeout= 剩余时间下限（秒）；缺省用平台默认。
示例:  cube-cli connect 6f1a... --timeout=3600
注意:  与 resume 语义不同：resume=「从现在起开 N 秒新窗口」；connect=「保证至少剩 N 秒」。
```

## 快照 / 卷

### snap

```text
cube-cli snap —— 给沙箱打快照
分组: 快照 / 卷

用途:  POST /sandboxes/<id>/snapshots，返回 snapshotID。
用法:  cube-cli snap <sandboxID> [--name=<名称>]
参数:  --name=  快照名。
示例:  cube-cli snap $SID --name=before-refactor
```

### snap-ls

```text
cube-cli snap-ls —— 快照列表
分组: 快照 / 卷

用途:  GET /snapshots（可按沙箱过滤）。
用法:  cube-cli snap-ls [--sandbox=<sandboxID>]
参数:  --sandbox=  只看某个沙箱的快照。
示例:  cube-cli snap-ls --sandbox=$SID
注意:  源码注释里提到的 `--limit=` **当前未实现**（分页由服务端决定）；输出为原始 JSON。
```

### snap-rm

```text
cube-cli snap-rm —— 删除快照
分组: 快照 / 卷

用途:  删除一个快照。
用法:  cube-cli snap-rm <snapshotID>
参数:  <snapshotID>  位置参数，必填。
示例:  cube-cli snap-rm snap_abc123
注意:  官方没有开 /snapshots/{id} DELETE，这里走模板删除接口
       DELETE /templates/<snapshotID>。
```

### rollback

```text
cube-cli rollback —— 回滚沙箱到某个快照
分组: 快照 / 卷

用途:  POST /sandboxes/<id>/rollback。
用法:  cube-cli rollback <sandboxID> <snapshotID>
参数:  两个位置参数，均必填。
示例:  cube-cli rollback $SID snap_abc123
```

### clone

```text
cube-cli clone —— 打快照并用它当模板批量克隆
分组: 快照 / 卷

用途:  先给沙箱打快照，再把快照当模板串行建 N 个新沙箱，最后删掉中间快照。
用法:  cube-cli clone <sandboxID> [--n=<数量>]
参数:  --n=   克隆个数，默认 1。
示例:  cube-cli clone $SID --n=3
注意:  简单串行实现，每个新沙箱的 metadata 为空（不带 agent/task/note）。
```

### vol-ls

```text
cube-cli vol-ls —— 列出持久卷
分组: 快照 / 卷

用途:  GET /volumes。
用法:  cube-cli vol-ls
参数:  无。输出为原始 JSON。
示例:  cube-cli vol-ls
```

### vol-new

```text
cube-cli vol-new —— 新建持久卷
分组: 快照 / 卷

用途:  POST /volumes。
用法:  cube-cli vol-new <名字>
参数:  <名字>  位置参数，必填。
示例:  cube-cli vol-new cache-vol
```

### vol-info

```text
cube-cli vol-info —— 查看持久卷详情
分组: 快照 / 卷

用途:  GET /volumes/<id>。
用法:  cube-cli vol-info <卷ID>
参数:  <卷ID>  位置参数，必填。
示例:  cube-cli vol-info vol_abc123
```

### vol-rm

```text
cube-cli vol-rm —— 删除持久卷
分组: 快照 / 卷

用途:  DELETE /volumes/<id>。
用法:  cube-cli vol-rm <卷ID>
参数:  <卷ID>  位置参数，必填。
示例:  cube-cli vol-rm vol_abc123
```

## 模板

### tpl-ls

```text
cube-cli tpl-ls —— 模板列表（含网关端口推断）
分组: 模板

用途:  GET /templates，逐个模板取详情并推断网关端口。
用法:  cube-cli tpl-ls [--json]
参数:  --json  原样输出服务端 JSON（不做表格化，也跳过端口推断）。
示例:  cube-cli tpl-ls
       cube-cli tpl-ls --json | python3 -m json.tool
```

### tpl-caps

```text
cube-cli tpl-caps —— 模板能力画像（能力 + 端口 + 网关）
分组: 模板

用途:  列出模板的能力画像。默认静态推断（亚秒级）；--probe 会建临时沙箱打真实端点。
用法:  cube-cli tpl-caps [<模板ID>] [--probe] [--prune] [--json]
参数:  <模板ID>  位置参数。配合 --probe 时只探这一个；不带位置参数则探所有
                 没有缓存的 READY 模板。
       --probe    真机探测：建临时沙箱 → 等 envd → 打 /v2/browser|computer 端点 → 销毁。
       --prune    清理 ~/.cube-cli-caps.json 里平台已不存在的模板条目。
       --json     （预留）JSON 输出。
示例:  cube-cli tpl-caps
       cube-cli tpl-caps tpl-4850162aafbb41ad97516762 --probe
注意:  --probe 每次都要建 + 毁一个沙箱（每个几十秒），不要放进 CI 循环里；
       探测结果缓存到 ~/.cube-cli-caps.json，模板重建后自动失效。
```

### tpl-pick

```text
cube-cli tpl-pick —— 按能力挑一个模板
分组: 模板

用途:  按能力覆盖 + 更薄者优先选一个 READY 模板并打印模板 ID。`new --need` 用同一套逻辑。
用法:  cube-cli tpl-pick [--need=<能力>[,<能力>...]]
参数:  --need=   逗号分隔的能力，如 code / browser / desktop；默认只要求基线能力。
示例:  cube-cli tpl-pick --need=browser,desktop
       cube-cli tpl-pick
注意:  没有满足的模板时打印「没有满足 --need=... 的 READY 模板」并非 0 退出。
```

### tpl-info

```text
cube-cli tpl-info —— 模板详情摘要
分组: 模板

用途:  GET /templates/<id>，打印状态 / 镜像 / 创建时间 / 暴露端口 / 网关推断。
用法:  cube-cli tpl-info <模板ID> [--json]
参数:  --json  原样输出服务端 JSON。
示例:  cube-cli tpl-info tpl-4850162aafbb41ad97516762
```

### tpl-logs

```text
cube-cli tpl-logs —— 模板构建日志
分组: 模板

用途:  GET /templates/<templateID>/builds/<buildID>/logs。
用法:  cube-cli tpl-logs <模板ID> <buildID>
参数:  两个位置参数，均必填。
示例:  cube-cli tpl-logs tpl-4850162aafbb41ad97516762 bld_abc123
```

### tpl-from-image

```text
cube-cli tpl-from-image —— 从 OCI 镜像推导模板默认值
分组: 模板

用途:  读镜像标签 io.cubesandbox.template.*（无端口标签时回退 Config.ExposedPorts），
       推导出一份建模板请求体；可只打印、可输出 curl、可直接提交。
用法:  cube-cli tpl-from-image <镜像引用> [--alias=<名>] [--cpu=<核>] [--memory=<MiB>]
                       [--writable=<大小>] [--env=K=V,...] [--platform=linux/amd64]
                       [--registry-user=<u>] [--registry-pass=<p>] [--json|--curl|--create]
参数:  <镜像引用>      如 ghcr.io/org/img:tag（位置参数，必填）。
       --json          只输出请求体 JSON。
       --curl          输出可直接执行的 curl 命令。
       --create        直接 POST 提交到平台（需要控制面环境变量）。
       --platform=     目标平台，默认 linux/amd64（aarch64 镜像写 linux/arm64）。
       --alias=        模板显示名；--cpu= / --memory= / --writable= / --env=K=V,.. 覆盖推导值。
示例:  cube-cli tpl-from-image ghcr.io/otaku-say/cubesandbox-image/agent-infra/sandbox:aio-code
       cube-cli tpl-from-image myreg.io/app:v1 --json --platform=linux/arm64
       cube-cli tpl-from-image ghcr.io/org/img:latest --curl
注意:  只需 registry 匿名读权限；私有镜像用 --registry-user/--registry-pass。
       镜像没声明可写层大小时会按 12G 估计并给 ⚠️ 提示（--writable= 可覆盖）。
```

## 文件

### cat

```text
cube-cli cat —— 读沙箱内文件到标准输出
（同义词: read）
分组: 文件

用途:  GET /files?path=<p>，把文件内容原样打到 stdout。
用法:  cube-cli cat <sandboxID> <远端路径> [--user=<用户>]
       （`cube-cli read ...` 是同义词）
参数:  --user=   以指定用户身份读（透传给 envd）。
示例:  cube-cli cat $SID /etc/hostname
       cube-cli cat $SID /tmp/data.csv > data.csv
```

### write

```text
cube-cli write —— 把本地文件（或 stdin）写进沙箱
分组: 文件

用途:  POST /files?path=<p>，body 为内容。
用法:  cube-cli write <sandboxID> <本地文件|-> <远端路径> [--user=<用户>]
参数:  <本地文件|->  位置参数；`-` 表示从 stdin 读（上限 8 MiB）。
示例:  cube-cli write $SID ./data.csv /home/gem/data.csv
       echo hi | cube-cli write $SID - /tmp/hi.txt
注意:  整体覆盖写，不支持追加；大文件（> 8 MiB）请用 aio-cli 的 put/fs-tree-put。
```

### get

```text
cube-cli get —— 把沙箱内文件下载到本地（二进制安全）
分组: 文件

用途:  读远端文件并写到本地路径。
用法:  cube-cli get <sandboxID> <远端路径> <本地文件> [--user=<用户>]
参数:  --user=   以指定用户身份读。
示例:  cube-cli get $SID /home/gem/out.tar.gz ./out.tar.gz
注意:  目标已存在会直接覆盖。
```

### ls-file

```text
cube-cli ls-file —— 列沙箱内目录
分组: 文件

用途:  Filesystem.ListDir。
用法:  cube-cli ls-file <sandboxID> [远端路径] [--user=<用户>]
参数:  [远端路径]  位置参数，缺省为 /。
示例:  cube-cli ls-file $SID /home/gem
```

### stat

```text
cube-cli stat —— 看沙箱内文件/目录元信息
分组: 文件

用途:  Filesystem.Stat，输出服务端原始 JSON。
用法:  cube-cli stat <sandboxID> <远端路径> [--user=<用户>]
示例:  cube-cli stat $SID /tmp
```

### mkdir

```text
cube-cli mkdir —— 在沙箱内建目录
分组: 文件

用途:  Filesystem.MakeDir。**不递归**。
用法:  cube-cli mkdir <sandboxID> <远端路径> [--user=<用户>]
示例:  cube-cli mkdir $SID /tmp/out
注意:  父目录不存在会失败；递归创建请用 `cube-cli exec $SID 'mkdir -p ...'`。
```

### rm-file

```text
cube-cli rm-file —— 删除沙箱内文件/目录
分组: 文件

用途:  Filesystem.Remove。
用法:  cube-cli rm-file <sandboxID> <远端路径> [--user=<用户>]
示例:  cube-cli rm-file $SID /tmp/out
注意:  非空目录能否删取决于服务端实现；需要递归时用 exec 跑 rm -rf。
```

### mv

```text
cube-cli mv —— 移动/改名沙箱内文件
分组: 文件

用途:  Filesystem.Move。
用法:  cube-cli mv <sandboxID> <源> <目标> [--user=<用户>]
示例:  cube-cli mv $SID /tmp/a.txt /tmp/b.txt
```

## 诊断 / 其它

### health

```text
cube-cli health —— 控制面健康检查
分组: 诊断 / 其它

用途:  GET /health，原样打印响应体。
用法:  cube-cli health
参数:  无。
示例:  cube-cli health
注意:  需要 CUBESANDBOX_API_URL。
```

### version

```text
cube-cli version —— 版本 / 构建信息
分组: 诊断 / 其它

用途:  打印版本号、仓库地址与构建目标。
用法:  cube-cli version        （等号写法：`cube-cli --version`）
参数:  无。
示例:  cube-cli version
```

### help

```text
cube-cli help —— 帮助：默认速查表 / all 完整表 / <命令> 详情
分组: 诊断 / 其它

用途:  打印帮助，**永不触发任何真实操作**。
用法:  cube-cli help              分组速查（常用命令）
       cube-cli help all          完整命令表（一条一行）
       cube-cli help <命令>       单命令详解（用法 / 参数 / 示例 / 注意）
       cube-cli --help / -h      等价于 `cube-cli help`
       cube-cli <命令> --help     等价于 `cube-cli help <命令>`
       cube-cli <命令> -h         同上
示例:  cube-cli help new
       cube-cli tpl-caps --help
注意:  未知命令会打印「未知命令：xxx」并以非 0 退出。
```

### logs

```text
cube-cli logs —— 沙箱日志（启动 / 运行；排障首选）
分组: 诊断 / 其它

用途:  读沙箱生命周期日志（建沙箱、启动 VM、恢复快照等）。
用法:  cube-cli logs <sandboxID> [--tail=<N>] [--start=<游标>] [--limit=<N>] [--v2]
                      [--cursor=<游标>] [--direction=forward|backward] [--level=info|warn|error] [--json]
参数:  --tail= 只显示最后 N 行；--v2 走结构化日志接口（level/message/fields）。
示例:  cube-cli logs 6f1a... --tail=50
```

### raw

```text
cube-cli raw —— 任意控制面 API 透传（未覆盖端点的兜底）
分组: 诊断 / 其它

用途:  直接对控制面发任意请求，复用同一套鉴权 / 解压 / 状态码处理；上游新端点无需等 CLI 更新。
用法:  cube-cli raw <METHOD> <path> [--body=<JSON|@文件|->] [--query=k=v,…] [--header=k:v] [--json]
参数:  --body= JSON 字符串、@文件名 或 - (stdin)；不带体时 GET/DELETE 无体、POST/PUT 发 {}。
示例:  cube-cli raw GET /health
       cube-cli raw POST /sandboxes --body='{"templateID":"tpl-..."}'
注意:  非 2xx 打印状态码与响应体，并以非 0 退出。
```

