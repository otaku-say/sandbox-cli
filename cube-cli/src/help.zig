//! help.zig —— cube-cli 的**权威命令面**：命令表 + 统一帮助输出。
//!
//! 设计约束：
//!   1. 命令表是唯一事实源，dispatch 的每个分支都在这里有条目；改命令先改这里。
//!   2. `<cmd> --help` / `<cmd> -h` / `help <cmd>` 三种写法等价，且**只打印不执行**
//!      （必须在 main 的 dispatch 之前拦截，`new --help` 绝不能真的建沙箱）。
//!   3. `help` 输出分组速查（≤60 行），`help all` 输出完整表，`help <cmd>` 输出单命令详情。
//!   4. 所有取值型 flag 一律 `--key=value` 等号写法；布尔开关直接写 `--flag`。
const std = @import("std");
const cfg = @import("cfg.zig");

pub const tool = "cube-cli";
pub const repo = "https://github.com/otaku-say/sandbox-cli";
pub const docs = "docs/cube-cli.md";

const groups = [_][]const u8{ "沙箱", "生命周期", "快照 / 卷", "模板", "文件", "诊断 / 其它" };

const Entry = struct {
    name: []const u8,
    alias: []const u8 = "",
    group: usize,
    brief: []const u8,
    detail: []const u8,
};

/// 完整命令表。顺序即 `help all` 的输出顺序。
pub const table = [_]Entry{
    .{
        .name = "new",
        .group = 0,
        .brief = "建沙箱（默认 aio-code 镜像）",
        .detail =
        \\用途:  按能力（--need）或指定模板（--template）新建一个沙箱，并打印 AIO 网关地址
        \\       （也就是 aio-cli 的 SANDBOX_BASE）。
        \\用法:  cube-cli new [--need=code|browser|desktop] [--template=<模板ID>]
        \\                      [--timeout=<秒>] [--note=<名称>] [--agent=<谁>] [--task=<做什么>]
        \\参数:  --need=      需要的能力，默认 code。不带任何参数就是 aio-code 镜像（自带 Zig 工具链）
        \\                    browser / desktop 分别对应 aio-daemon / aio-computer 镜像。
        \\       --template=  直接指定模板 ID，优先于 --need。
        \\       --timeout=   空闲回收秒数；不传用平台默认。
        \\       --note=      显示名（ls 的"备注"列）。不给时按 "<agent> · <task>" 生成。
        \\       --agent=     谁开的；缺省读环境变量 CUBESANDBOX_AGENT_NAME，再缺省为 cube-cli。
        \\       --task=      做什么，进 metadata.task，admin WebUI 会渲染。
        \\示例:  cube-cli new --note=build --agent=ci --task="跑 Zig 构建"
        \\       cube-cli new --need=browser --timeout=1800
        \\注意:  `--need=` 是动态挑模板（能力覆盖 + 更薄者优先）；没有满足的 READY 模板会
        \\       报「没有满足 --need=... 的 READY 模板」并以非 0 退出。
        \\       `cube-cli new --help` 只打印本页，不会建沙箱。
        ,
    },
    .{
        .name = "ls",
        .group = 0,
        .brief = "列出沙箱（ID / 模板 / 状态 / 备注）",
        .detail =
        \\用途:  列出账号下所有沙箱。
        \\用法:  cube-cli ls
        \\参数:  无。
        \\示例:  cube-cli ls
        \\注意:  "备注"列取 metadata.note，没有则取 metadata.agent，再没有显示 "-"。
        ,
    },
    .{
        .name = "rm",
        .group = 0,
        .brief = "销毁沙箱",
        .detail =
        \\用途:  销毁一个沙箱（DELETE /sandboxes/<id>）。
        \\用法:  cube-cli rm <sandboxID>
        \\参数:  <sandboxID>  位置参数，必填。
        \\示例:  cube-cli rm 799fd44ef23e49eb8f4357807da32323
        \\注意:  不可恢复；正在跑的进程一并终止。ID 可从 `cube-cli ls` 取。
        ,
    },
    .{
        .name = "exec",
        .group = 0,
        .brief = "在沙箱内执行命令",
        .detail =
        \\用途:  走沙箱内 envd（49983）执行一条命令并打印 stdout/stderr/exit。
        \\用法:  cube-cli exec <sandboxID> <命令...> [--cwd=<目录>] [--env=NAME|KEY=VAL] [--timeout=<秒>]
        \\参数:  <sandboxID>  目标沙箱。
        \\       <命令...>    位置参数会原样用空格拼回一条命令（无需自己转义引号）。
        \\       --cwd=       工作目录。
        \\       --env=       K=V 直接给值；只给 NAME 则从**本机环境**读同名变量注入
        \\                    （敏感值不必出现在命令行 / 进程列表里）。
        \\       --timeout=   秒，默认 60。
        \\示例:  cube-cli exec $SID 'zig version'
        \\       cube-cli exec $SID 'python3 -c "print(1+1)"' --cwd=/tmp --timeout=300
        \\       cube-cli exec $SID 'printenv' --env=GITHUB_TOKEN
        \\注意:  需要 CUBESANDBOX_PROXY_URL（数据面网关）才有 envd 通道。
        ,
    },
    .{
        .name = "code",
        .group = 0,
        .brief = "用解释器在沙箱内跑一段代码",
        .detail =
        \\用途:  把一段源码交给解释器执行（内部等价于 exec python3 -c ...），不依赖 Jupyter 内核，
        \\       任何镜像都可用。
        \\用法:  cube-cli code <sandboxID> <代码...> [--lang=python|js|bash] [--timeout=<秒>] [--env=...]
        \\参数:  <代码...>    位置参数用空格拼接后整体交给解释器。
        \\       --lang=      python（默认）/ js（js、javascript、node、nodejs）/ bash（sh、shell）。
        \\       --timeout=   秒，默认 120。
        \\       --env=       同 exec。
        \\示例:  cube-cli code $SID 'print(sum(range(10)))'
        \\       cube-cli code $SID 'console.log(1+1)' --lang=js
        \\注意:  语言别名与非法语言：非法值会打印「不支持的语言: xxx」并以非 0 退出。
        ,
    },
    .{
        .name = "ports",
        .group = 0,
        .brief = "实测沙箱内实际监听的端口",
        .detail =
        \\用途:  在沙箱内读 /proc/net/tcp*，列出真实 LISTEN 端口、绑定地址、可否外部访问，
        \\       以及对应的网关访问 URL。
        \\用法:  cube-cli ports <sandboxID>
        \\参数:  <sandboxID>  位置参数，必填。
        \\示例:  cube-cli ports $SID
        \\注意:  模板声明的 exposedPorts 未必等于实际监听（创建时传了也可能被忽略），
        \\       真正决定可达性的是绑定地址：0.0.0.0 / :: 可连，127.0.0.1 / ::1 只有沙箱内部能连。
        ,
    },

    .{
        .name = "pause",
        .group = 1,
        .brief = "暂停沙箱（挂起快照，0 成本）",
        .detail =
        \\用途:  POST /sandboxes/<id>/pause，挂起成快照，磁盘态冻结、不计 CPU/内存。
        \\用法:  cube-cli pause <sandboxID>
        \\参数:  <sandboxID>  位置参数，必填。
        \\示例:  cube-cli pause $SID
        \\注意:  恢复用 `cube-cli resume <sandboxID>`。
        ,
    },
    .{
        .name = "resume",
        .group = 1,
        .brief = "恢复暂停的沙箱",
        .detail =
        \\用途:  POST /sandboxes/<id>/resume。
        \\用法:  cube-cli resume <sandboxID> [--timeout=<秒>]
        \\参数:  --timeout=   恢复后的新时间窗（秒）；不传则平台沿用原值。
        \\示例:  cube-cli resume $SID --timeout=1800
        ,
    },
    .{
        .name = "timeout",
        .group = 1,
        .brief = "设置空闲回收超时",
        .detail =
        \\用途:  POST /sandboxes/<id>/timeout，改空闲回收时间。
        \\用法:  cube-cli timeout <sandboxID> <秒>
        \\参数:  <秒>        位置参数，必填；-1 表示永不回收。
        \\示例:  cube-cli timeout $SID 7200
        \\       cube-cli timeout $SID -1
        ,
    },
    .{
        .name = "refresh",
        .group = 1,
        .brief = "续期：新增一个时间窗",
        .detail =
        \\用途:  POST /sandboxes/<id>/refreshes，**新增**一个时间窗（不是从现在起重算）。
        \\用法:  cube-cli refresh <sandboxID> <秒>
        \\参数:  <秒>        新增窗口长度，必填。
        \\示例:  cube-cli refresh $SID 3600
        \\注意:  长任务跑到一半时间要到了，用 refresh 续命，别去改 timeout。
        ,
    },
    .{
        .name = "net",
        .group = 1,
        .brief = "更新沙箱网络策略",
        .detail =
        \\用途:  PUT /sandboxes/<id>/network（204 即成功）。
        \\用法:  cube-cli net <sandboxID> [--no-internet|--internet] [--allow=域1,域2] [--deny=域1,域2]
        \\参数:  --no-internet   allowInternetAccess=false。
        \\       --internet      allowInternetAccess=true（与 --no-internet 互斥，别同时给）。
        \\       --allow=        逗号分隔的出站放行域 → allowOut。
        \\       --deny=         逗号分隔的出站拒绝域 → denyOut。
        \\示例:  cube-cli net $SID --no-internet
        \\       cube-cli net $SID --allow=github.com,registry.npmjs.org
        ,
    },

    .{
        .name = "snap",
        .group = 2,
        .brief = "给沙箱打快照",
        .detail =
        \\用途:  POST /sandboxes/<id>/snapshots，返回 snapshotID。
        \\用法:  cube-cli snap <sandboxID> [--name=<名称>]
        \\参数:  --name=  快照名。
        \\示例:  cube-cli snap $SID --name=before-refactor
        ,
    },
    .{
        .name = "snap-ls",
        .group = 2,
        .brief = "快照列表",
        .detail =
        \\用途:  GET /snapshots（可按沙箱过滤）。
        \\用法:  cube-cli snap-ls [--sandbox=<sandboxID>]
        \\参数:  --sandbox=  只看某个沙箱的快照。
        \\示例:  cube-cli snap-ls --sandbox=$SID
        \\注意:  源码注释里提到的 `--limit=` **当前未实现**（分页由服务端决定）；输出为原始 JSON。
        ,
    },
    .{
        .name = "snap-rm",
        .group = 2,
        .brief = "删除快照",
        .detail =
        \\用途:  删除一个快照。
        \\用法:  cube-cli snap-rm <snapshotID>
        \\参数:  <snapshotID>  位置参数，必填。
        \\示例:  cube-cli snap-rm snap_abc123
        \\注意:  官方没有开 /snapshots/{id} DELETE，这里走模板删除接口
        \\       DELETE /templates/<snapshotID>。
        ,
    },
    .{
        .name = "rollback",
        .group = 2,
        .brief = "回滚沙箱到某个快照",
        .detail =
        \\用途:  POST /sandboxes/<id>/rollback。
        \\用法:  cube-cli rollback <sandboxID> <snapshotID>
        \\参数:  两个位置参数，均必填。
        \\示例:  cube-cli rollback $SID snap_abc123
        ,
    },
    .{
        .name = "clone",
        .group = 2,
        .brief = "打快照并用它当模板批量克隆",
        .detail =
        \\用途:  先给沙箱打快照，再把快照当模板串行建 N 个新沙箱，最后删掉中间快照。
        \\用法:  cube-cli clone <sandboxID> [--n=<数量>]
        \\参数:  --n=   克隆个数，默认 1。
        \\示例:  cube-cli clone $SID --n=3
        \\注意:  简单串行实现，每个新沙箱的 metadata 为空（不带 agent/task/note）。
        ,
    },
    .{
        .name = "vol-ls",
        .group = 2,
        .brief = "列出持久卷",
        .detail =
        \\用途:  GET /volumes。
        \\用法:  cube-cli vol-ls
        \\参数:  无。输出为原始 JSON。
        \\示例:  cube-cli vol-ls
        ,
    },
    .{
        .name = "vol-new",
        .group = 2,
        .brief = "新建持久卷",
        .detail =
        \\用途:  POST /volumes。
        \\用法:  cube-cli vol-new <名字>
        \\参数:  <名字>  位置参数，必填。
        \\示例:  cube-cli vol-new cache-vol
        ,
    },
    .{
        .name = "vol-info",
        .group = 2,
        .brief = "查看持久卷详情",
        .detail =
        \\用途:  GET /volumes/<id>。
        \\用法:  cube-cli vol-info <卷ID>
        \\参数:  <卷ID>  位置参数，必填。
        \\示例:  cube-cli vol-info vol_abc123
        ,
    },
    .{
        .name = "vol-rm",
        .group = 2,
        .brief = "删除持久卷",
        .detail =
        \\用途:  DELETE /volumes/<id>。
        \\用法:  cube-cli vol-rm <卷ID>
        \\参数:  <卷ID>  位置参数，必填。
        \\示例:  cube-cli vol-rm vol_abc123
        ,
    },

    .{
        .name = "tpl-ls",
        .group = 3,
        .brief = "模板列表（含网关端口推断）",
        .detail =
        \\用途:  GET /templates，逐个模板取详情并推断网关端口。
        \\用法:  cube-cli tpl-ls [--json]
        \\参数:  --json  原样输出服务端 JSON（不做表格化，也跳过端口推断）。
        \\示例:  cube-cli tpl-ls
        \\       cube-cli tpl-ls --json | python3 -m json.tool
        ,
    },
    .{
        .name = "tpl-caps",
        .group = 3,
        .brief = "模板能力画像（能力 + 端口 + 网关）",
        .detail =
        \\用途:  列出模板的能力画像。默认静态推断（亚秒级）；--probe 会建临时沙箱打真实端点。
        \\用法:  cube-cli tpl-caps [<模板ID>] [--probe] [--prune] [--json]
        \\参数:  <模板ID>  位置参数。配合 --probe 时只探这一个；不带位置参数则探所有
        \\                 没有缓存的 READY 模板。
        \\       --probe    真机探测：建临时沙箱 → 等 envd → 打 /v2/browser|computer 端点 → 销毁。
        \\       --prune    清理 ~/.cube-cli-caps.json 里平台已不存在的模板条目。
        \\       --json     （预留）JSON 输出。
        \\示例:  cube-cli tpl-caps
        \\       cube-cli tpl-caps tpl-4850162aafbb41ad97516762 --probe
        \\注意:  --probe 每次都要建 + 毁一个沙箱（每个几十秒），不要放进 CI 循环里；
        \\       探测结果缓存到 ~/.cube-cli-caps.json，模板重建后自动失效。
        ,
    },
    .{
        .name = "tpl-pick",
        .group = 3,
        .brief = "按能力挑一个模板",
        .detail =
        \\用途:  按能力覆盖 + 更薄者优先选一个 READY 模板并打印模板 ID。`new --need` 用同一套逻辑。
        \\用法:  cube-cli tpl-pick [--need=<能力>[,<能力>...]]
        \\参数:  --need=   逗号分隔的能力，如 code / browser / desktop；默认只要求基线能力。
        \\示例:  cube-cli tpl-pick --need=browser,desktop
        \\       cube-cli tpl-pick
        \\注意:  没有满足的模板时打印「没有满足 --need=... 的 READY 模板」并非 0 退出。
        ,
    },
    .{
        .name = "tpl-info",
        .group = 3,
        .brief = "模板详情摘要",
        .detail =
        \\用途:  GET /templates/<id>，打印状态 / 镜像 / 创建时间 / 暴露端口 / 网关推断。
        \\用法:  cube-cli tpl-info <模板ID> [--json]
        \\参数:  --json  原样输出服务端 JSON。
        \\示例:  cube-cli tpl-info tpl-4850162aafbb41ad97516762
        ,
    },
    .{
        .name = "tpl-logs",
        .group = 3,
        .brief = "模板构建日志",
        .detail =
        \\用途:  GET /templates/<templateID>/builds/<buildID>/logs。
        \\用法:  cube-cli tpl-logs <模板ID> <buildID>
        \\参数:  两个位置参数，均必填。
        \\示例:  cube-cli tpl-logs tpl-4850162aafbb41ad97516762 bld_abc123
        ,
    },
    .{
        .name = "tpl-from-image",
        .group = 3,
        .brief = "从 OCI 镜像推导模板默认值",
        .detail =
        \\用途:  读镜像标签 io.cubesandbox.template.*（无端口标签时回退 Config.ExposedPorts），
        \\       推导出一份建模板请求体；可只打印、可输出 curl、可直接提交。
        \\用法:  cube-cli tpl-from-image <镜像引用> [--alias=<名>] [--cpu=<核>] [--memory=<MiB>]
        \\                       [--writable=<大小>] [--env=K=V,...] [--platform=linux/amd64]
        \\                       [--registry-user=<u>] [--registry-pass=<p>] [--json|--curl|--create]
        \\参数:  <镜像引用>      如 ghcr.io/org/img:tag（位置参数，必填）。
        \\       --json          只输出请求体 JSON。
        \\       --curl          输出可直接执行的 curl 命令。
        \\       --create        直接 POST 提交到平台（需要控制面环境变量）。
        \\       --platform=     目标平台，默认 linux/amd64（aarch64 镜像写 linux/arm64）。
        \\       --alias=        模板显示名；--cpu= / --memory= / --writable= / --env=K=V,.. 覆盖推导值。
        \\示例:  cube-cli tpl-from-image ghcr.io/otaku-say/cubesandbox-image/agent-infra/sandbox:aio-code
        \\       cube-cli tpl-from-image myreg.io/app:v1 --json --platform=linux/arm64
        \\       cube-cli tpl-from-image ghcr.io/org/img:latest --curl
        \\注意:  只需 registry 匿名读权限；私有镜像用 --registry-user/--registry-pass。
        \\       镜像没声明可写层大小时会按 12G 估计并给 ⚠️ 提示（--writable= 可覆盖）。
        ,
    },

    .{
        .name = "cat",
        .alias = "read",
        .group = 4,
        .brief = "读沙箱内文件到标准输出",
        .detail =
        \\用途:  GET /files?path=<p>，把文件内容原样打到 stdout。
        \\用法:  cube-cli cat <sandboxID> <远端路径> [--user=<用户>]
        \\       （`cube-cli read ...` 是同义词）
        \\参数:  --user=   以指定用户身份读（透传给 envd）。
        \\示例:  cube-cli cat $SID /etc/hostname
        \\       cube-cli cat $SID /tmp/data.csv > data.csv
        ,
    },
    .{
        .name = "write",
        .group = 4,
        .brief = "把本地文件（或 stdin）写进沙箱",
        .detail =
        \\用途:  POST /files?path=<p>，body 为内容。
        \\用法:  cube-cli write <sandboxID> <本地文件|-> <远端路径> [--user=<用户>]
        \\参数:  <本地文件|->  位置参数；`-` 表示从 stdin 读（上限 8 MiB）。
        \\示例:  cube-cli write $SID ./data.csv /home/gem/data.csv
        \\       echo hi | cube-cli write $SID - /tmp/hi.txt
        \\注意:  整体覆盖写，不支持追加；大文件（> 8 MiB）请用 aio-cli 的 put/fs-tree-put。
        ,
    },
    .{
        .name = "get",
        .group = 4,
        .brief = "把沙箱内文件下载到本地（二进制安全）",
        .detail =
        \\用途:  读远端文件并写到本地路径。
        \\用法:  cube-cli get <sandboxID> <远端路径> <本地文件> [--user=<用户>]
        \\参数:  --user=   以指定用户身份读。
        \\示例:  cube-cli get $SID /home/gem/out.tar.gz ./out.tar.gz
        \\注意:  目标已存在会直接覆盖。
        ,
    },
    .{
        .name = "ls-file",
        .group = 4,
        .brief = "列沙箱内目录",
        .detail =
        \\用途:  Filesystem.ListDir。
        \\用法:  cube-cli ls-file <sandboxID> [远端路径] [--user=<用户>]
        \\参数:  [远端路径]  位置参数，缺省为 /。
        \\示例:  cube-cli ls-file $SID /home/gem
        ,
    },
    .{
        .name = "stat",
        .group = 4,
        .brief = "看沙箱内文件/目录元信息",
        .detail =
        \\用途:  Filesystem.Stat，输出服务端原始 JSON。
        \\用法:  cube-cli stat <sandboxID> <远端路径> [--user=<用户>]
        \\示例:  cube-cli stat $SID /tmp
        ,
    },
    .{
        .name = "mkdir",
        .group = 4,
        .brief = "在沙箱内建目录",
        .detail =
        \\用途:  Filesystem.MakeDir。**不递归**。
        \\用法:  cube-cli mkdir <sandboxID> <远端路径> [--user=<用户>]
        \\示例:  cube-cli mkdir $SID /tmp/out
        \\注意:  父目录不存在会失败；递归创建请用 `cube-cli exec $SID 'mkdir -p ...'`。
        ,
    },
    .{
        .name = "rm-file",
        .group = 4,
        .brief = "删除沙箱内文件/目录",
        .detail =
        \\用途:  Filesystem.Remove。
        \\用法:  cube-cli rm-file <sandboxID> <远端路径> [--user=<用户>]
        \\示例:  cube-cli rm-file $SID /tmp/out
        \\注意:  非空目录能否删取决于服务端实现；需要递归时用 exec 跑 rm -rf。
        ,
    },
    .{
        .name = "mv",
        .group = 4,
        .brief = "移动/改名沙箱内文件",
        .detail =
        \\用途:  Filesystem.Move。
        \\用法:  cube-cli mv <sandboxID> <源> <目标> [--user=<用户>]
        \\示例:  cube-cli mv $SID /tmp/a.txt /tmp/b.txt
        ,
    },

    .{
        .name = "health",
        .group = 5,
        .brief = "控制面健康检查",
        .detail =
        \\用途:  GET /health，原样打印响应体。
        \\用法:  cube-cli health
        \\参数:  无。
        \\示例:  cube-cli health
        \\注意:  需要 CUBESANDBOX_API_URL。
        ,
    },
    .{
        .name = "version",
        .group = 5,
        .brief = "版本 / 构建信息",
        .detail =
        \\用途:  打印版本号、仓库地址与构建目标。
        \\用法:  cube-cli version        （等号写法：`cube-cli --version`）
        \\参数:  无。
        \\示例:  cube-cli version
        ,
    },
    .{
        .name = "help",
        .group = 5,
        .brief = "帮助：默认速查表 / all 完整表 / <命令> 详情",
        .detail =
        \\用途:  打印帮助，**永不触发任何真实操作**。
        \\用法:  cube-cli help              分组速查（常用命令）
        \\       cube-cli help all          完整命令表（一条一行）
        \\       cube-cli help <命令>       单命令详解（用法 / 参数 / 示例 / 注意）
        \\       cube-cli --help / -h      等价于 `cube-cli help`
        \\       cube-cli <命令> --help     等价于 `cube-cli help <命令>`
        \\       cube-cli <命令> -h         同上
        \\示例:  cube-cli help new
        \\       cube-cli tpl-caps --help
        \\注意:  未知命令会打印「未知命令：xxx」并以非 0 退出。
        ,
    },
    .{
        .name = "info",
        .group = 0,
        .brief = "沙箱详情（规格 / 元数据 / 卷挂载 / 截止时间）",
        .detail =
        \\用途:  查看单个沙箱完整状态：state、CPU/内存/磁盘、起止时间、metadata、volumeMounts、domain。
        \\用法:  cube-cli info <sandboxID> [--json] [--wait=<状态>] [--timeout=<秒>]
        \\参数:  --json 原样输出；--wait= 轮询到指定状态（如 running）；--timeout= 最大等待秒数。
        \\示例:  cube-cli info 6f1a... --json
        \\注意:  上游详情不含网络策略（改策略用 net 命令）。
        ,
    },
    .{
        .name = "connect",
        .group = 1,
        .brief = "连接/续期（官方推荐，替代 deprecated 的 resume）",
        .detail =
        \\用途:  把沙箱唤醒并保证「至少还剩 N 秒」（不会缩短已有的更长截止）。
        \\用法:  cube-cli connect <sandboxID> [--timeout=<秒>] [--json]
        \\参数:  --timeout= 剩余时间下限（秒）；缺省用平台默认。
        \\示例:  cube-cli connect 6f1a... --timeout=3600
        \\注意:  与 resume 语义不同：resume=「从现在起开 N 秒新窗口」；connect=「保证至少剩 N 秒」。
        ,
    },
    .{
        .name = "logs",
        .group = 5,
        .brief = "沙箱日志（启动 / 运行；排障首选）",
        .detail =
        \\用途:  读沙箱生命周期日志（建沙箱、启动 VM、恢复快照等）。
        \\用法:  cube-cli logs <sandboxID> [--tail=<N>] [--start=<游标>] [--limit=<N>] [--v2]
        \\                      [--cursor=<游标>] [--direction=forward|backward] [--level=info|warn|error] [--json]
        \\参数:  --tail= 只显示最后 N 行；--v2 走结构化日志接口（level/message/fields）。
        \\示例:  cube-cli logs 6f1a... --tail=50
        ,
    },
    .{
        .name = "raw",
        .group = 5,
        .brief = "任意控制面 API 透传（未覆盖端点的兜底）",
        .detail =
        \\用途:  直接对控制面发任意请求，复用同一套鉴权 / 解压 / 状态码处理；上游新端点无需等 CLI 更新。
        \\用法:  cube-cli raw <METHOD> <path> [--body=<JSON|@文件|->] [--query=k=v,…] [--header=k:v] [--json]
        \\参数:  --body= JSON 字符串、@文件名 或 - (stdin)；不带体时 GET/DELETE 无体、POST/PUT 发 {}。
        \\示例:  cube-cli raw GET /health
        \\       cube-cli raw POST /sandboxes --body='{"templateID":"tpl-..."}'
        \\注意:  非 2xx 打印状态码与响应体，并以非 0 退出。
        ,
    },
};

pub fn isHelpArg(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-?") or
        std.mem.eql(u8, a, "help");
}

pub fn isHelpCmd(a: []const u8) bool {
    return std.mem.eql(u8, a, "help") or std.mem.eql(u8, a, "--help") or
        std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-?");
}

pub fn find(name: []const u8) ?*const Entry {
    for (&table) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
        if (e.alias.len > 0 and std.mem.eql(u8, e.alias, name)) return e;
    }
    return null;
}

/// 猜一个名字（用于「你是不是想找」提示）：返回前缀/包含匹配的第一个命令名。
fn suggest(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_n: usize = 4;
    for (&table) |*e| {
        var n: usize = 0;
        const a = e.name;
        const m = @min(name.len, a.len);
        while (n < m and name[n] == a[n]) n += 1;
        if (n >= 3 and n < best_n) {
            best_n = n;
            best = a;
        }
    }
    return best;
}

const banner =
    \\所有取值型 flag 一律用等号写法：--key=value（例：--need=code）；布尔开关直接写 --flag。
    \\
;

pub fn printVersion(out: *std.Io.Writer) !void {
    try out.print(
        \\{s} (zig) {s}
        \\仓库: {s}
        \\文档: {s}
        \\构建: Zig 0.17.0 · musl 静态单文件 · ReleaseFast + strip
        \\构建命令: cd cube-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
        \\产物名: aarch64 → cube-cli-aarch64-linux-musl ；x86_64 → cube-cli-x86_64-linux-musl
        \\
    , .{ tool, cfg.version, repo, docs });
}

pub fn printTop(out: *std.Io.Writer) !void {
    try out.print(
        \\{s} (zig) {s} —— CubeSandbox 控制面 CLI（建沙箱 / 选模板 / 快照 / 卷 / 沙箱内文件）
        \\仓库 {s} ｜ 逐条文档 {s}
        \\
        \\用法: {s} <命令> [位置参数…] [--key=value]
        \\
    , .{ tool, cfg.version, repo, docs, tool });
    try out.writeAll(banner);
    try out.print(
        \\本帮助即**权威命令面**：命令表在 src/help.zig，与 docs/cube-cli.md 同步更新、随代码走。
        \\
        \\【沙箱】
        \\  new      建沙箱（默认 aio-code 镜像）  --need= --template= --timeout= --note= --agent= --task=
        \\  ls       列出沙箱（ID / 模板 / 状态 / 备注）
        \\  info     沙箱详情（规格/元数据/卷/截止时间）  --json --wait=
        \\  rm       销毁沙箱 <sandboxID>
        \\  exec     在沙箱内执行命令            --cwd= --env= --timeout=
        \\  code     用解释器跑一段代码            --lang=python|js|bash --timeout= --env=
        \\  ports    实测沙箱内实际监听的端口
        \\
        \\【生命周期】
        \\  pause    暂停（挂起快照，0 成本）
        \\  resume   恢复                        --timeout=秒
        \\  timeout/refresh  设空闲超时 / 续期   <sid> <秒>（-1 = 永不回收）
        \\  net      改网络策略                  --no-internet --allow=域,域 --deny=域,域
        \\  connect  连接/续期（官方推荐，替代 resume）  --timeout=
        \\
        \\【快照 / 卷】
        \\  snap      打快照 <sid>                --name=
        \\  snap-ls   快照列表                    --sandbox=<sid>
        \\  snap-rm   删快照 <snapshotID>
        \\  rollback  回滚到快照 <sid> <snapshotID>
        \\  clone     快照当模板批量克隆 <sid>     --n=数量
        \\  vol-ls / vol-new <名字> / vol-info <卷ID> / vol-rm <卷ID>   持久卷
        \\
        \\【模板】
        \\  tpl-ls           模板列表               --json
        \\  tpl-caps         模板能力画像           --probe --prune --json
        \\  tpl-pick         按能力选模板           --need=browser,desktop
        \\  tpl-info         模板详情               --json
        \\  tpl-logs         构建日志 <模板ID> <buildID>
        \\  tpl-from-image   从 OCI 镜像推导模板默认值  --json --curl --create --platform= …
        \\
        \\【文件】（<sid> 之后的操作都走沙箱内 envd）
        \\  cat|read  读文件      <sid> <路径>              --user=
        \\  write     写本地文件   <sid> <本地|-> <远端>     --user=
        \\  get       下载到本地   <sid> <远端> <本地>       --user=
        \\  ls-file   列目录      <sid> [路径]              --user=
        \\  stat / mkdir / rm-file / mv   <sid> <路径…>      --user=
        \\
        \\【诊断 / 其它】
        \\  health   控制面健康检查
        \\  logs / raw   沙箱日志 / 任意 API 透传   <sid> --tail=N ｜ <METHOD> <path>
        \\  version  版本 / 仓库地址 / 构建信息
        \\  help [命令|all]   帮助；all = 完整命令表
        \\
        \\单命令帮助（三种写法等价，**只打印不执行**）：
        \\  {s} help new   ｜   {s} new --help   ｜   {s} new -h
        \\
        \\环境变量（仓库内不含任何部署信息）:
        \\  CUBESANDBOX_API_URL    控制面地址（必填）
        \\  CUBESANDBOX_API_KEY    控制面 API Key（本部署可不设）
        \\  CUBESANDBOX_PROXY_URL  数据面网关（exec / 文件 / ports 需要）
        \\  CUBESANDBOX_AGENT_NAME  默认写入新沙箱 metadata.agent 的名字
        \\
    , .{ tool, tool, tool });
}

pub fn printAll(out: *std.Io.Writer) !void {
    try out.print(
        \\{s} (zig) {s} —— 完整命令表（一条一行；仓库 {s} ｜ 文档 {s}）
        \\
        \\用法: {s} <命令> [位置参数…] [--key=value]
        \\
    , .{ tool, cfg.version, repo, docs, tool });
    try out.writeAll(banner);
    for (groups, 0..) |g, gi| {
        try out.print("\n【{s}】\n", .{g});
        for (&table) |*e| {
            if (e.group != gi) continue;
            const nm = if (e.alias.len > 0)
                try std.fmt.allocPrint(std.heap.smp_allocator, "{s}|{s}", .{ e.name, e.alias })
            else
                e.name;
            try out.print("  {s:<22} {s}\n", .{ nm, e.brief });
        }
    }
    try out.print(
        \\
        \\单命令详情: {s} help <命令> ｜ {s} <命令> --help ｜ {s} <命令> -h
        \\共 {d} 条命令。
        \\
    , .{ tool, tool, tool, table.len });
}

pub fn printOne(out: *std.Io.Writer, e: *const Entry) !void {
    try out.print("{s} {s} —— {s}\n", .{ tool, e.name, e.brief });
    if (e.alias.len > 0) try out.print("（同义词: {s}）\n", .{e.alias});
    try out.print("分组: {s}\n\n", .{groups[e.group]});
    try out.writeAll(e.detail);
    try out.writeAll("\n");
}

pub fn printUnknown(out: *std.Io.Writer, name: []const u8) !void {
    try out.print("未知命令：{s}\n", .{name});
    if (suggest(name)) |s| try out.print("你是不是想找 `{s}`？\n", .{s});
    try out.print("用 `{s} help` 看完整命令表，`{s} help {s}` 看单条命令详解。\n", .{ tool, tool, name });
}