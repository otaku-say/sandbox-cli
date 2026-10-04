//! help.zig —— aio-cli 的**权威命令面**：命令表 + 统一帮助输出。
//!
//! 设计约束与 cube-cli 一致：
//!   1. 命令表是唯一事实源，覆盖 main/cmd_* 全部 dispatch 分支；改命令先改这里。
//!   2. `<cmd> --help` / `<cmd> -h` / `help <cmd>` 等价，且**只打印不执行**
//!      （必须在 main 的 dispatch 之前拦截，否则 `exec --help` 会真的执行 `--help` 这个命令）。
//!   3. `help` 分组速查（≤60 行）｜ `help all` 完整表 ｜ `help <cmd>` 单命令详情。
//!   4. 取值型 flag 一律 `--key=value`；布尔开关直接写 `--flag`。
const std = @import("std");
const cfg = @import("cfg.zig");

pub const tool = "aio-cli";
pub const repo = "https://github.com/otaku-say/sandbox-cli";
pub const docs = "docs/aio-cli.md";

const groups = [_][]const u8{ "基础", "执行", "文件", "终端 PTY", "代码", "浏览器", "监听", "MCP", "桌面" };

const Entry = struct {
    name: []const u8,
    alias: []const u8 = "",
    group: usize,
    brief: []const u8,
    detail: []const u8,
};

pub const table = [_]Entry{
    // ---------------- 基础 ----------------
    .{
        .name = "health",
        .group = 0,
        .brief = "aiod 网关健康检查",
        .detail =
        \\用途:  GET /health，原样打印响应信封。
        \\用法:  aio-cli health
        \\参数:  无。
        \\示例:  aio-cli health
        \\       → {"status":"healthy","version":"0.9.2",...}
        ,
    },
    .{
        .name = "sandbox-info",
        .group = 0,
        .brief = "沙箱信息（GET /v2/sandbox）",
        .detail =
        \\用途:  GET /v2/sandbox，拿沙箱画像（镜像、端口、平台版本等）。
        \\用法:  aio-cli sandbox-info
        \\参数:  无。输出为服务端原始 JSON。
        \\示例:  aio-cli sandbox-info
        ,
    },
    .{
        .name = "sandbox-packages",
        .group = 0,
        .brief = "沙箱内置包清单",
        .detail =
        \\用途:  GET /v2/sandbox/packages?lang=<lang>，列出镜像里预装的语言运行时/包。
        \\用法:  aio-cli sandbox-packages [--lang=python|node]
        \\参数:  --lang=   python（默认）/ node。
        \\示例:  aio-cli sandbox-packages
        \\       aio-cli sandbox-packages --lang=node
        \\注意:  `data` 是纯文本，不是 JSON 数组。
        ,
    },
    .{
        .name = "version",
        .group = 0,
        .brief = "版本 / 构建信息",
        .detail =
        \\用途:  打印版本号、仓库地址与构建目标。
        \\用法:  aio-cli version        （等号写法：`aio-cli --version`）
        \\参数:  无。
        \\示例:  aio-cli version
        ,
    },
    .{
        .name = "help",
        .group = 0,
        .brief = "帮助：速查表 / all 完整表 / <命令> 详情",
        .detail =
        \\用途:  打印帮助，**永不触发任何真实操作**，也不需要 SANDBOX_BASE。
        \\用法:  aio-cli help              分组速查（常用命令）
        \\       aio-cli help all          完整命令表（一条一行）
        \\       aio-cli help <命令>       单命令详解
        \\       aio-cli --help / -h      等价于 `aio-cli help`
        \\       aio-cli <命令> --help     等价于 `aio-cli help <命令>`
        \\       aio-cli <命令> -h         同上
        \\示例:  aio-cli help pty-ws
        \\       aio-cli br-go --help
        \\注意:  未知命令会打印「未知命令：xxx」并以非 0 退出。
        ,
    },

    // ---------------- 执行 ----------------
    .{
        .name = "exec",
        .group = 1,
        .brief = "同步执行一条命令并打印输出",
        .detail =
        \\用途:  POST /v2/commands（mode 缺省同步）。响应扁平，直接打印 stdout/stderr，
        \\       非 0 退出码时补一行「（exit N）」。
        \\用法:  aio-cli exec <命令> [参数…] [--cwd=<目录>] [--shell=<壳>] [--user=<用户>]
        \\                      [--session=<会话id>] [--env=K=V,K2=V2] [--timeout=<毫秒>]
        \\                      [--hard-timeout=<秒>] [--args='["a","b"]'] [--max-output=<字节>]
        \\       aio-cli exec --id=<command_id> [--offset=<字节>] [--stderr-offset=<字节>]
        \\                      [--wait] [--wait-timeout=<秒>]
        \\参数:  <命令> [参数…]  位置参数用空格拼成一条命令（不用自己转义引号）。
        \\       --cwd=        工作目录。
        \\       --shell=      指定 shell（auto|bash|sh|powershell|cmd|none）。
        \\       --user=       以指定用户执行。
        \\       --session=    在已有命令会话里执行。
        \\       --env=        环境变量，K=V 逗号分隔 → JSON 对象（同名后者覆盖）。
        \\       --timeout=    毫秒；到点返回 status=running，进程还在跑（自己 kill）。
        \\       --hard-timeout=  秒；到点服务端强杀（返回 timed_out）。
        \\       --args=       JSON 数组；仅 shell=none 时合法（argv 形式运行）。
        \\       --max-output= 截断输出上限。
        \\       --id=         改成「按 id 回读」模式，不带位置参数。
        \\       --offset= / --stderr-offset=   回读时的字节偏移（增量取输出）。
        \\       --wait / --wait-timeout=      回读时服务端等待至多 N 秒直到有输出/终态。
        \\示例:  aio-cli exec 'echo hello'
        \\       aio-cli exec 'echo $A' --env=A=B,C=D
        \\       aio-cli exec 'zig build -Doptimize=ReleaseFast' --cwd=/root/repo --timeout=600000
        \\       ID=$(aio-cli async 'sleep 60'); aio-cli exec --id=$ID --offset=0
        \\注意:  非 2xx 或 success=false → 打印 HTTP <码>: <message>，退出码非 0。
        ,
    },
    .{
        .name = "async",
        .group = 1,
        .brief = "异步派发一条命令，打印 command_id",
        .detail =
        \\用途:  同 exec，但 mode=async，立即返回 command_id。
        \\用法:  aio-cli async <命令> [参数…] [--cwd=] [--shell=] [--user=] [--session=] [--env=K=V,K2=V2] [--timeout=] [--hard-timeout=] [--args=] [--max-output=]
        \\参数:  同 exec（除 --id / --offset / --wait 系列）。
        \\示例:  ID=$(aio-cli async 'pip install pandas && python3 -c "print(1+1)"')
        \\       aio-cli log "$ID" --follow
        \\       aio-cli kill "$ID"
        ,
    },
    .{
        .name = "log",
        .group = 1,
        .brief = "按 id 轮询/跟随输出",
        .detail =
        \\用途:  GET /v2/commands/<id>，按 offset 增量读取 stdout/stderr。
        \\用法:  aio-cli log <command_id> [--follow]
        \\参数:  --follow  循环直到状态变成 completed/failed/killed/exited（最多 600 轮 × 0.5s）。
        \\示例:  aio-cli log "$ID"
        \\       aio-cli log "$ID" --follow
        \\注意:  终态为 completed 且 exit_code=-1 时通常是被 kill 了，别用退出码反推信号。
        ,
    },
    .{
        .name = "kill",
        .group = 1,
        .brief = "杀掉一条运行中的命令",
        .detail =
        \\用途:  POST /v2/commands/<id>/kill。
        \\用法:  aio-cli kill <command_id> [--signal=<信号>]
        \\参数:  --signal=   默认 SIGKILL。
        \\示例:  aio-cli kill "$ID"
        \\       aio-cli kill "$ID" --signal=SIGTERM
        ,
    },
    .{
        .name = "stdin",
        .group = 1,
        .brief = "给运行中的命令喂 stdin",
        .detail =
        \\用途:  POST /v2/commands/<id>/stdin。
        \\用法:  aio-cli stdin <command_id> <文本> [--enter]
        \\参数:  --enter  自动补一个换行。
        \\示例:  aio-cli stdin "$ID" 'y' --enter
        ,
    },
    .{
        .name = "sess-new",
        .group = 1,
        .brief = "新建命令会话（固定 cwd）",
        .detail =
        \\用途:  POST /v2/commands/sessions。
        \\用法:  aio-cli sess-new <会话id> [--cwd=<目录>] [--env=K=V,K2=V2] [--user=<用户>]
        \\参数:  --cwd=   会话内固定的工作目录。
        \\       --env=   会话级环境变量（K=V 逗号分隔 → JSON 对象，同名后者覆盖）。
        \\       --user=  以指定用户跑会话命令。
        \\示例:  aio-cli sess-new work --cwd=/root/repo --env=FOO=bar
        \\注意:  cwd 在创建时固定；会话内 `cd` 不跨调用保留。
        ,
    },
    .{
        .name = "sess",
        .group = 1,
        .brief = "在命令会话里执行",
        .detail =
        \\用途:  POST /v2/commands，带 session=<会话id>。
        \\用法:  aio-cli sess <会话id> <命令> [参数…] [--timeout=<毫秒>]
        \\参数:  --timeout=  毫秒。
        \\示例:  aio-cli sess work 'ls -la'
        ,
    },
    .{
        .name = "sess-ls",
        .group = 1,
        .brief = "列出命令会话",
        .detail =
        \\用途:  GET /v2/commands/sessions，输出原始 JSON。
        \\用法:  aio-cli sess-ls
        \\参数:  无。
        \\示例:  aio-cli sess-ls
        ,
    },
    .{
        .name = "sess-rm",
        .group = 1,
        .brief = "删除命令会话",
        .detail =
        \\用途:  DELETE /v2/commands/sessions/<id>。
        \\用法:  aio-cli sess-rm <会话id>
        \\参数:  <会话id>  位置参数，必填。
        \\示例:  aio-cli sess-rm work
        ,
    },

    // ---------------- 文件 ----------------
    .{
        .name = "cat",
        .alias = "read",
        .group = 2,
        .brief = "读沙箱内文件到标准输出",
        .detail =
        \\用途:  GET /v2/fs/read?path=…，取 data.content 原样打到 stdout。
        \\用法:  aio-cli cat <远端路径> [--start=<行>] [--end=<行>] [--user=<用户>]
        \\       （`aio-cli read ...` 是同义词）
        \\参数:  --user=   以指定用户身份读。
        \\       --start= / --end=   行区间（0 起；end 不含尾行）。
        \\示例:  aio-cli cat /etc/hostname
        \\       aio-cli cat /tmp/data.csv --start=0 --end=10 > data.csv
        ,
    },
    .{
        .name = "write",
        .group = 2,
        .brief = "把本地文件（或 stdin）写进沙箱",
        .detail =
        \\用途:  POST /v2/fs/write，JSON 传 content（**按文本处理，非二进制安全**）。
        \\用法:  aio-cli write <本地文件|-> <远端路径> [--append] [--encoding=utf-8|base64|raw]
        \\                      [--leading-newline] [--trailing-newline]
        \\参数:  <本地文件|->  `-` 表示从 stdin 读（上限 4 MiB）。
        \\       --append       追加到文件末尾而非覆盖。
        \\       --encoding=    内容编码：utf-8（默认）/ base64 / raw。
        \\       --leading-newline / --trailing-newline  写入前/后补一个换行。
        \\示例:  aio-cli write ./data.csv /home/gem/data.csv
        \\       echo hi | aio-cli write - /tmp/hi.txt --append
        \\注意:  二进制文件请用 `put`（multipart）或 `fs-tree-put`（tar）。
        ,
    },
    .{
        .name = "get",
        .group = 2,
        .brief = "下载沙箱内文件到本地（二进制安全）",
        .detail =
        \\用途:  GET /v2/fs/download?path=…，响应体原样落本地。
        \\用法:  aio-cli get <远端路径> <本地文件> [--user=<用户>]
        \\参数:  --user=   以指定用户身份读。
        \\示例:  aio-cli get /home/gem/out.tar.gz ./out.tar.gz
        \\注意:  目标已存在直接覆盖。
        ,
    },
    .{
        .name = "put",
        .group = 2,
        .brief = "上传本地文件到沙箱（二进制安全）",
        .detail =
        \\用途:  multipart 上传到服务端 /tmp 再 move 到目标位置。
        \\用法:  aio-cli put <本地文件|-> <远端路径> [--overwrite]
        \\参数:  --overwrite  目标已存在时覆盖（不加会失败）。
        \\示例:  aio-cli put ./app.tar.gz /home/gem/app.tar.gz
        \\       aio-cli put ./a.txt /tmp/a.txt --overwrite
        \\       cat ./a.bin | aio-cli put - /tmp/a.bin --overwrite
        ,
    },
    .{
        .name = "fs-tree-put",
        .group = 2,
        .brief = "整棵目录树上传（tar）",
        .detail =
        \\用途:  PUT /v2/fs/tree，body 为未压缩 tar。输入是 gzip（.tgz）会自动先在本地解压。
        \\用法:  aio-cli fs-tree-put <本地 tar|-> <远端目录> [--user=<用户>] [--json]
        \\参数:  <本地 tar|->  `-` 表示从 stdin 读（上限 256 MiB）。
        \\       --user=       以指定用户身份落盘。
        \\       --json        只打印服务端 JSON，不打印人话摘要。
        \\示例:  tar czf site.tgz site/ && aio-cli fs-tree-put site.tgz /home/gem/
        \\       gunzip -c site.tgz | aio-cli fs-tree-put - /home/gem/site
        \\注意:  服务端只收未压缩 tar；gzip 解压失败时按提示先本地 gunzip。
        ,
    },
    .{
        .name = "ls",
        .group = 2,
        .brief = "列目录",
        .detail =
        \\用途:  GET /v2/fs/list?path=…，透传递归/隐藏/深度参数。
        \\用法:  aio-cli ls [远端路径] [--recursive] [--hidden] [--depth=<层>] [--user=<用户>]
        \\参数:  [远端路径]  缺省为 /。
        \\       --recursive  递归列出子目录。
        \\       --hidden     显示隐藏文件（. 开头）。
        \\       --depth=     最大深度（配合 --recursive）。
        \\示例:  aio-cli ls /home/gem
        \\       aio-cli ls /root/repo --recursive --depth=1
        \\注意:  --depth <= 1 时输出与默认不同（服务端含嵌套条目）。
        ,
    },
    .{
        .name = "stat",
        .group = 2,
        .brief = "看文件/目录元信息",
        .detail =
        \\用途:  GET /v2/fs/stat?path=…，输出原始 JSON。
        \\用法:  aio-cli stat <远端路径> [--follow-symlinks] [--user=<用户>]
        \\参数:  --follow-symlinks  跟随符号链接取目标信息。
        \\示例:  aio-cli stat /tmp
        ,
    },
    .{
        .name = "tree",
        .group = 2,
        .brief = "递归列目录树",
        .detail =
        \\用途:  GET /v2/fs/tree?path=…，服务端返回的是原始 tar（x-tar）字节流。
        \\用法:  aio-cli tree [远端路径] [--user=<用户>] [--tar | --out=<本地文件>]
        \\参数:  [远端路径]  缺省为 /。
        \\       --tar   原样输出 tar 字节（可管道给 tar tf -）。
        \\       --out=  把 tar 存到本地文件。
        \\示例:  aio-cli tree /root/repo
        \\       aio-cli tree /root/repo --out=repo.tar && tar tf repo.tar | head
        \\注意:  默认输出是**解析后的条目树**（缩进表示层级）；旧版直接刷二进制。
        ,
    },
    .{
        .name = "mkdir",
        .group = 2,
        .brief = "建目录",
        .detail =
        \\用途:  POST /v2/fs/mkdir。
        \\用法:  aio-cli mkdir <远端路径> [--parents]
        \\参数:  --parents  递归建父目录（mkdir -p）；目标已存在也算成功。
        \\示例:  aio-cli mkdir /tmp/out
        \\       aio-cli mkdir /tmp/a/b/c --parents
        ,
    },
    .{
        .name = "rm",
        .group = 2,
        .brief = "删除文件/目录",
        .detail =
        \\用途:  POST /v2/fs/delete。
        \\用法:  aio-cli rm <远端路径> [--recursive]
        \\参数:  --recursive  递归删除非空目录（服务端默认仅删文件/空目录）。
        \\示例:  aio-cli rm /tmp/out
        \\       aio-cli rm /tmp/out --recursive
        ,
    },
    .{
        .name = "cp",
        .group = 2,
        .brief = "复制",
        .detail =
        \\用途:  POST /v2/fs/copy。
        \\用法:  aio-cli cp <源> <目标> [--overwrite]
        \\参数:  --overwrite  目标已存在时覆盖。
        \\示例:  aio-cli cp /tmp/a.txt /tmp/b.txt
        \\       aio-cli cp /tmp/a.txt /tmp/b.txt --overwrite
        ,
    },
    .{
        .name = "mv",
        .group = 2,
        .brief = "移动/改名",
        .detail =
        \\用途:  POST /v2/fs/move。
        \\用法:  aio-cli mv <源> <目标> [--overwrite]
        \\参数:  --overwrite  目标已存在时覆盖。
        \\示例:  aio-cli mv /tmp/a.txt /tmp/b.txt
        \\       aio-cli mv /tmp/a.txt /tmp/b.txt --overwrite
        ,
    },
    .{
        .name = "edit",
        .group = 2,
        .brief = "按行改文件（替换 / 插入）",
        .detail =
        \\用途:  POST /v2/fs/edit。
        \\用法:  aio-cli edit <远端路径> --old=<原串> --new=<新串>
        \\                      [--replace-all | --replace-first | --replace-last]
        \\       aio-cli edit <远端路径> --insert=<行号> --text=<文本>
        \\参数:  --old= --new=   str_replace 模式；--new 缺省为空串（等于删除该串）。
        \\       --replace-all   多处匹配全部替换（replace_mode=ALL）。
        \\       --replace-first 只替换第一处（replace_mode=FIRST）。
        \\       --replace-last  只替换最后一处（replace_mode=LAST）。
        \\       --insert= --text=  insert 模式，--insert 是行号。
        \\示例:  aio-cli edit /root/app.py --old='v1' --new='v2'
        \\       aio-cli edit /root/app.py --old='x' --new='y' --replace-all
        \\       aio-cli edit /root/app.py --insert=0 --text='import os'
        \\注意:  多处匹配而不给 replace_mode 时服务端 400（必须显式三选一）。
        ,
    },
    .{
        .name = "grep",
        .group = 2,
        .brief = "在沙箱内按正则搜文件内容",
        .detail =
        \\用途:  POST /v2/fs/grep（固定 recursive=true）。
        \\用法:  aio-cli grep <远端路径> <正则> [--fixed] [--ignore-case] [--multiline]
        \\                      [--include=a,b] [--exclude=a,b] [--context=<行>]
        \\                      [--max=<条>] [--offset=<条>] [--type=<类型>]
        \\参数:  --fixed        按字面串搜（fixed_strings=true）。
        \\       --ignore-case  忽略大小写（case_insensitive=true）。
        \\       --include= / --exclude=   文件名通配数组（逗号分隔）。
        \\       --context=     前后各 N 行上下文。
        \\       --multiline    跨行匹配。
        \\       --max= / --offset=        结果条数上限 / 偏移。
        \\       --type=        文件类型过滤（如 py、rust）。
        \\示例:  aio-cli grep /root/repo 'fn main' --include='*.zig' --max=20
        ,
    },
    .{
        .name = "search",
        .group = 2,
        .brief = "按路径/文件名 glob 搜",
        .detail =
        \\用途:  GET /v2/fs/search?path=…&pattern=…
        \\用法:  aio-cli search <远端路径> <glob>
        \\参数:  <远端路径> <glob>  两个位置参数，均必填。
        \\示例:  aio-cli search /root '*.zig'
        \\注意:  搜的是**路径**，内容搜索用 `grep`。
        ,
    },

    // ---------------- 终端 PTY ----------------
    .{
        .name = "pty-new",
        .group = 3,
        .brief = "新建 PTY 会话",
        .detail =
        \\用途:  POST /v2/pty/sessions。
        \\用法:  aio-cli pty-new <会话id> [--cwd=<目录>] [--user=<用户>] [--cols=<列>] [--rows=<行>]
        \\                      [--retention=<时长>] [--no-change-timeout=<秒>]
        \\参数:  --cwd=       初始工作目录。
        \\       --user=      终端 shell 以哪个用户跑（会话期间固定）。
        \\       --cols= --rows=  终端尺寸。
        \\       --retention= 保留时长（透传给服务端）。
        \\       --no-change-timeout=  空闲无变化超时（秒）。
        \\示例:  aio-cli pty-new t1 --cols=120 --rows=30
        \\注意:  `--env` 服务端（0.9.2）明确未实现、会 400；请在会话里 export。
        ,
    },
    .{
        .name = "pty",
        .group = 3,
        .brief = "在 PTY 会话里执行命令",
        .detail =
        \\用途:  POST /v2/pty/sessions/<id>/exec。输出合流在 data.output。
        \\用法:  aio-cli pty <会话id> <命令> [参数…] [--timeout=<毫秒>] [--async]
        \\                      [--hard-timeout=<秒>] [--no-change-timeout=<秒>]
        \\参数:  --timeout=  毫秒。
        \\       --async     服务端不等结果，直接返回。
        \\       --hard-timeout=      秒；到点强杀。
        \\       --no-change-timeout= 空闲无变化超时（秒）。
        \\示例:  aio-cli pty t1 'tmux new -As work'
        \\       aio-cli pty t1 'ls -la' --timeout=30000
        ,
    },
    .{
        .name = "pty-screen",
        .group = 3,
        .brief = "读 PTY 当前屏幕快照",
        .detail =
        \\用途:  GET /v2/pty/sessions/<id>/screen。
        \\用法:  aio-cli pty-screen <会话id>
        \\示例:  aio-cli pty-screen t1
        ,
    },
    .{
        .name = "pty-input",
        .group = 3,
        .brief = "往 PTY 会话发输入",
        .detail =
        \\用途:  POST /v2/pty/sessions/<id>/input。
        \\用法:  aio-cli pty-input <会话id> <文本> [--enter]
        \\参数:  --enter  press_enter=true（补回车）。
        \\示例:  aio-cli pty-input t1 'echo hi' --enter
        ,
    },
    .{
        .name = "pty-signal",
        .group = 3,
        .brief = "给 PTY 会话发信号",
        .detail =
        \\用途:  POST /v2/pty/sessions/<id>/signal。
        \\用法:  aio-cli pty-signal <会话id> [信号] [--signal=<信号>]
        \\参数:  [信号]  也可以写成位置参数；--signal= 优先。默认 SIGINT。
        \\示例:  aio-cli pty-signal t1 SIGTERM
        \\注意:  实测发信号后会话往往直接终止。
        ,
    },
    .{
        .name = "pty-resize",
        .group = 3,
        .brief = "调整 PTY 终端尺寸",
        .detail =
        \\用途:  PATCH /v2/pty/sessions/<id>。
        \\用法:  aio-cli pty-resize <会话id> [--cols=<列>] [--rows=<行>] [--no-change-timeout=<秒>]
        \\示例:  aio-cli pty-resize t1 --cols=200 --rows=50
        ,
    },
    .{
        .name = "pty-ls",
        .group = 3,
        .brief = "列出 PTY 会话",
        .detail =
        \\用途:  GET /v2/pty/sessions，输出原始 JSON。
        \\用法:  aio-cli pty-ls
        \\示例:  aio-cli pty-ls
        ,
    },
    .{
        .name = "pty-info",
        .group = 3,
        .brief = "看单个 PTY 会话详情",
        .detail =
        \\用途:  GET /v2/pty/sessions/<id>。
        \\用法:  aio-cli pty-info <会话id>
        \\示例:  aio-cli pty-info t1
        ,
    },
    .{
        .name = "pty-rm",
        .group = 3,
        .brief = "删除 PTY 会话",
        .detail =
        \\用途:  DELETE /v2/pty/sessions/<id>。
        \\用法:  aio-cli pty-rm <会话id>
        \\示例:  aio-cli pty-rm t1
        ,
    },
    .{
        .name = "pty-ws",
        .group = 3,
        .brief = "WebSocket 附着到 PTY 会话（非交互）",
        .detail =
        \\用途:  ws://…/v2/pty/sessions/<id>/ws?protocol=json 附着；读到 --max 条就退出。
        \\用法:  aio-cli pty-ws <会话id> [--send=<文本>] [--max=<条数>] [--raw]
        \\参数:  --send=   服务端 ready 之后自动发送这段文本。
        \\       --max=    收满 N 条退出，默认 5。
        \\       --raw     输出原始帧，不做加工。
        \\       --durable / --restore / --replay-bytes=<n>  重连参数（透传服务端）。
        \\示例:  aio-cli pty-ws t1 --send='echo attached' --max=6
        \\注意:  只支持 ws://（Zig 0.17 标准库缺 TLS/进程能力）；SANDBOX_BASE 是 https 时会给出
        \\       「把二进制搬进沙箱、用 SANDBOX_BASE=http://127.0.0.1:8080」的替代方案。
        \\       同一会话一次只允许一个 WS 连接，异常断开后要换会话名或等服务端超时。
        ,
    },
    .{
        .name = "pty-ws-anon",
        .group = 3,
        .brief = "匿名 WebShell 附着",
        .detail =
        \\用途:  ws://…/v2/pty/ws?protocol=json，不绑定具体会话。
        \\用法:  aio-cli pty-ws-anon [--max=<条数>] [--send=<文本>] [--raw]
        \\参数:  同 pty-ws，但没有 <会话id> 位置参数。
        \\示例:  aio-cli pty-ws-anon --max=3
        \\注意:  同 pty-ws，仅支持 ws://。
        ,
    },

    // ---------------- 代码 ----------------
    .{
        .name = "code",
        .group = 4,
        .brief = "用内置代码解释器执行一段代码",
        .detail =
        \\用途:  POST /v2/code/execute。
        \\用法:  aio-cli code <源码…> [--lang=python|javascript] [--session=<会话id>] [--timeout=<毫秒>]
        \\参数:  --lang=     语言，默认 python。
        \\       --session=  复用一个 code 会话（保留变量）。
        \\       --timeout=  毫秒。
        \\示例:  aio-cli code 'print(sum(range(10)))'
        \\       aio-cli code 'console.log(1+1)' --lang=javascript
        \\注意:  status=error 时信封 success=false 但 data 完整，CLI 会打印 traceback 并非 0 退出。
        ,
    },
    .{
        .name = "code-info",
        .group = 4,
        .brief = "代码解释器信息（GET /v2/code/info）",
        .detail =
        \\用途:  GET /v2/code/info。
        \\用法:  aio-cli code-info
        \\参数:  无。
        \\示例:  aio-cli code-info
        ,
    },
    .{
        .name = "code-sess-new",
        .group = 4,
        .brief = "新建代码会话",
        .detail =
        \\用途:  POST /v2/code/sessions。
        \\用法:  aio-cli code-sess-new [--lang=python|javascript]
        \\参数:  --lang=   语言，默认 python。
        \\示例:  aio-cli code-sess-new --lang=python
        ,
    },
    .{
        .name = "code-sess-ls",
        .group = 4,
        .brief = "列出代码会话",
        .detail =
        \\用途:  GET /v2/code/sessions，输出原始 JSON。
        \\用法:  aio-cli code-sess-ls
        \\示例:  aio-cli code-sess-ls
        ,
    },
    .{
        .name = "code-sess-get",
        .group = 4,
        .brief = "看单个代码会话详情",
        .detail =
        \\用途:  GET /v2/code/sessions/<id>。
        \\用法:  aio-cli code-sess-get <会话id>
        \\示例:  aio-cli code-sess-get cs_abc123
        ,
    },
    .{
        .name = "code-sess-rm",
        .group = 4,
        .brief = "删除代码会话",
        .detail =
        \\用途:  DELETE /v2/code/sessions/<id>。
        \\用法:  aio-cli code-sess-rm <会话id>
        \\示例:  aio-cli code-sess-rm cs_abc123
        ,
    },// ---------------- 浏览器 ----------------
    .{
        .name = "br-info",
        .group = 5,
        .brief = "浏览器信息（GET /v2/browser/info）",
        .detail =
        \\用途:  GET /v2/browser/info。
        \\用法:  aio-cli br-info
        \\参数:  无。
        \\示例:  aio-cli br-info
        \\注意:  需要带 Chromium 的镜像（--need=browser / aio-daemon）。
        ,
    },
    .{
        .name = "br-go",
        .group = 5,
        .brief = "导航到 URL",
        .detail =
        \\用途:  POST /v2/browser/navigate。
        \\用法:  aio-cli br-go <url> [--wait=<等待策略>] [--timeout=<毫秒>] [--tab=<id>]
        \\       aio-cli br-go --history=back|forward|reload [--tab=<id>]
        \\参数:  --wait=     wait_until 策略，如 load / networkidle（透传给服务端）。
        \\       --timeout=  毫秒。
        \\       --tab=      指定标签页（tab_id）；缺省当前活动页。
        \\       --history=  历史操作 back/forward/reload（与 url 互斥）。
        \\示例:  aio-cli br-go https://example.com
        \\       aio-cli br-go --history=reload
        ,
    },
    .{
        .name = "br-shot",
        .group = 5,
        .brief = "截图到本地 PNG",
        .detail =
        \\用途:  GET /v2/browser/screenshot，响应体是原始 PNG 字节，落本地文件。
        \\用法:  aio-cli br-shot <本地输出.png> [--full] [--quality=<n>]
        \\参数:  --full      整页截图（full_page=true）。
        \\       --quality=  JPEG 质量（仅在服务端走 jpeg 时有意义）。
        \\示例:  aio-cli br-shot shot.png
        \\       aio-cli br-shot shot.png --full
        \\注意:  落盘后会校验是不是 PNG，末尾标「(PNG ✓)」或「(⚠ 非 PNG)」。
        ,
    },
    .{
        .name = "br-eval",
        .group = 5,
        .brief = "在页面里执行 JS 表达式",
        .detail =
        \\用途:  POST /v2/browser/evaluate。
        \\用法:  aio-cli br-eval <JS 表达式…> [--await]
        \\参数:  位置参数用空格拼成表达式；不需要引号。
        \\       --await  等待返回的 Promise（await_promise=true）。
        \\示例:  aio-cli br-eval 'document.title'
        \\       aio-cli br-eval 'fetch("/api").then(r => r.text())' --await
        ,
    },
    .{
        .name = "br-click",
        .group = 5,
        .brief = "点击元素",
        .detail =
        \\用途:  POST /v2/browser/click。
        \\用法:  aio-cli br-click (--selector=<CSS> | --ref=<快照ref>) [--tab=<id>]
        \\参数:  --selector= / --ref=  二选一：CSS 选择器 或 快照元素 ref。
        \\       --tab=      指定标签页。
        \\示例:  aio-cli br-click --selector='#submit'
        \\       aio-cli br-snapshot --interactive   # 先拿 ref
        \\       aio-cli br-click --ref=e5
        ,
    },
    .{
        .name = "br-fill",
        .group = 5,
        .brief = "填输入框",
        .detail =
        \\用途:  POST /v2/browser/fill。
        \\用法:  aio-cli br-fill (--selector=<CSS> | --ref=<快照ref>) [--value=<文本>] [--tab=<id>]
        \\参数:  --selector= / --ref=  二选一。
        \\       --value=     缺省为空串。
        \\       --tab=       指定标签页。
        \\示例:  aio-cli br-fill --selector='input[name=q]' --value='zig lang'
        ,
    },
    .{
        .name = "br-snapshot",
        .group = 5,
        .brief = "抓页面可访问性快照",
        .detail =
        \\用途:  POST /v2/browser/snapshot。
        \\用法:  aio-cli br-snapshot [--interactive]
        \\参数:  --interactive  interactive_only=true，只要可交互节点。
        \\示例:  aio-cli br-snapshot
        \\       aio-cli br-snapshot --interactive
        ,
    },
    .{
        .name = "br-tabs",
        .group = 5,
        .brief = "列出标签页",
        .detail =
        \\用途:  GET /v2/browser/tabs。
        \\用法:  aio-cli br-tabs
        \\示例:  aio-cli br-tabs
        ,
    },
    .{
        .name = "br-tab-new",
        .group = 5,
        .brief = "新开标签页",
        .detail =
        \\用途:  POST /v2/browser/tabs。
        \\用法:  aio-cli br-tab-new [--url=<url>]
        \\参数:  --url=   不给就是空白页。
        \\示例:  aio-cli br-tab-new --url=https://example.com
        ,
    },
    .{
        .name = "br-tab-use",
        .group = 5,
        .brief = "切换当前标签页",
        .detail =
        \\用途:  POST /v2/browser/tabs/<id>（空 body）。
        \\用法:  aio-cli br-tab-use <tabID>
        \\参数:  <tabID>  位置参数，必填（id 从 `aio-cli br-tabs` 取）。
        \\示例:  aio-cli br-tab-use 8f2c1a
        ,
    },
    .{
        .name = "br-tab-close",
        .group = 5,
        .brief = "关闭标签页",
        .detail =
        \\用途:  DELETE /v2/browser/tabs/<id>。
        \\用法:  aio-cli br-tab-close <tabID>
        \\参数:  <tabID>  位置参数，必填。
        \\示例:  aio-cli br-tab-close 8f2c1a
        ,
    },
    .{
        .name = "br-cookies",
        .group = 5,
        .brief = "读 Cookie",
        .detail =
        \\用途:  GET /v2/browser/cookies。
        \\用法:  aio-cli br-cookies [--url=<url>]
        \\参数:  --url=   按 url 过滤。
        \\示例:  aio-cli br-cookies
        \\       aio-cli br-cookies --url=https://example.com
        ,
    },
    .{
        .name = "br-cookie-set",
        .group = 5,
        .brief = "写 Cookie",
        .detail =
        \\用途:  POST /v2/browser/cookies（发 {"cookies":[…]} 包装体）。
        \\用法:  aio-cli br-cookie-set --name=<名> --value=<值> [--url=<url>] [--domain=<域>]
        \\参数:  --name=  必填；--value= 默认空串；--url= / --domain= 可选。
        \\示例:  aio-cli br-cookie-set --name=token --value=abc --domain=example.com
        ,
    },
    .{
        .name = "br-cookie-rm",
        .group = 5,
        .brief = "删 Cookie（DELETE /v2/browser/cookies）",
        .detail =
        \\用途:  DELETE /v2/browser/cookies。
        \\用法:  aio-cli br-cookie-rm [--all | --name=<名>] [--url=<url>] [--domain=<域>]
        \\参数:  --all 清全部；按名删时 CDP 要求同时给 --url 或 --domain。
        \\示例:  aio-cli br-cookie-rm --name=token --domain=example.com
        \\       aio-cli br-cookie-rm --all
        ,
    },
    .{
        .name = "br-upload",
        .group = 5,
        .brief = "往 <input type=file> 挂文件（沙箱内路径）",
        .detail =
        \\用途:  POST /v2/browser/upload，把**沙箱内**文件挂给页面上传控件。
        \\用法:  aio-cli br-upload --paths=<沙箱内文件,…> [--selector=<css> | --ref=<快照ref>] [--tab=<id>]
        \\参数:  --paths=   逗号分隔的沙箱内绝对路径（必填）。
        \\       --selector=  目标 <input type=file> 的 CSS 选择器。
        \\       --ref=       或者用快照元素 ref。
        \\示例:  aio-cli br-upload --paths=/tmp/a.png --selector='#file-input'
        \\注意:  文件必须先存在于沙箱里（用 write / put 先放进去）。
        ,
    },
    .{
        .name = "br-network",
        .group = 5,
        .brief = "抓网络请求列表",
        .detail =
        \\用途:  GET /v2/browser/network/requests。
        \\用法:  aio-cli br-network [--limit=<条数>] [--clear]
        \\参数:  --limit=  最多返回条数。
        \\       --clear  取回后清空缓冲。
        \\示例:  aio-cli br-network
        \\       aio-cli br-network --limit=20 --clear
        ,
    },
    .{
        .name = "br-config",
        .group = 5,
        .brief = "读/写浏览器配置（分辨率等）",
        .detail =
        \\用途:  缺省 GET /v2/browser/config；--resolution= 或 --json= 时 POST。
        \\用法:  aio-cli br-config [--resolution=<宽>x<高> | --json=<JSON>]
        \\参数:  --resolution=  设置视口，如 1280x800 → {"width":1280,"height":800}。
        \\       --json=        要写入的配置 JSON（整体覆盖，不是单字段合并）。
        \\示例:  aio-cli br-config
        \\       aio-cli br-config --resolution=1280x800
        ,
    },
    .{
        .name = "br-cdp",
        .group = 5,
        .brief = "直接发一条 CDP 命令",
        .detail =
        \\用途:  POST /v2/browser/cdp，{"method":…,"params":…}。
        \\用法:  aio-cli br-cdp <CDP 方法> [--params=<JSON>] [--browser] [--tab=<id>]
        \\参数:  <方法>        位置参数，必填，如 Page.navigate / Runtime.evaluate。
        \\       --params=     CDP 参数 JSON，原样嵌入。
        \\       --browser     走浏览器级会话（Browser.* / Target.*）。
        \\       --tab=        指定标签页 target。
        \\示例:  aio-cli br-cdp 'Page.reload' --params='{"ignoreCache":true}'
        \\       aio-cli br-cdp 'Emulation.setDeviceMetricsOverride' \
        \\              --params='{"width":1280,"height":800,"deviceScaleFactor":1,"mobile":false}'
        \\示例:  aio-cli br-cdp 'Browser.getVersion' --browser
        ,
    },

    // ---------------- 监听 ----------------
    .{
        .name = "watch",
        .group = 6,
        .brief = "创建文件监听器",
        .detail =
        \\用途:  POST /v2/watch，返回 watcher_id。
        \\用法:  aio-cli watch [远端路径] [--recursive] [--debounce=<毫秒>] [--exclude=a,b] [--include=a,b]
        \\参数:  [远端路径]  缺省为 /。
        \\       --recursive  递归监听子目录。
        \\       --debounce=  防抖毫秒数。
        \\       --exclude=   排除规则数组（逗号分隔）。
        \\       --include=   只保留匹配 include_patterns 的路径（逗号分隔）。
        \\示例:  aio-cli watch /tmp/out --recursive --debounce=300
        \\       W=$(aio-cli watch /tmp/out --recursive | python3 -c 'import json,sys;print(json.load(sys.stdin)["watcher_id"])')
        \\注意:  同一路径重复创建会**复用**已有监听器。
        ,
    },
    .{
        .name = "watch-poll",
        .group = 6,
        .brief = "长轮询取监听事件",
        .detail =
        \\用途:  GET /v2/watch/<id>/poll（服务端长轮询）。
        \\用法:  aio-cli watch-poll <watcher_id> [--cursor=<游标>] [--limit=<条数>] [--timeout=<秒>]
        \\参数:  <watcher_id>  位置参数，必填。
        \\       --cursor=     从上次返回的 cursor 继续（缺省 0）。
        \\       --limit=      单次最多返回条数。
        \\       --timeout=    最长等待秒数（长轮询）。
        \\示例:  aio-cli watch-poll "$W"
        \\       aio-cli watch-poll "$W" --cursor=5 --limit=10 --timeout=30
        \\注意:  响应含 cursor/events/overflow；用返回的 cursor 作为下次 --cursor。
        ,
    },
    .{
        .name = "watch-events",
        .group = 6,
        .brief = "SSE 事件流（--max 收满退出）",
        .detail =
        \\用途:  GET /v2/watch/<id>/events，text/event-stream。
        \\用法:  aio-cli watch-events <watcher_id> [--max=<条数>] [--json]
        \\参数:  --max=    收满 N 条退出；不给就一直挂着（Ctrl-C 退出）。
        \\       --json    每条只打 data（原始 JSON），不加就打印可读格式。
        \\示例:  aio-cli watch-events "$W" --max=5
        \\注意:  --max 计入**首条** watch_started，所以 --max=1 会立刻返回。
        ,
    },
    .{
        .name = "watch-rm",
        .group = 6,
        .brief = "删除监听器",
        .detail =
        \\用途:  DELETE /v2/watch/<id>。
        \\用法:  aio-cli watch-rm <watcher_id>
        \\参数:  <watcher_id>  位置参数，必填。
        \\示例:  aio-cli watch-rm "$W"
        \\注意:  删除前可用 `watch-ls` 列出现有监听器。
        ,
    },
    .{
        .name = "watch-ls",
        .group = 6,
        .brief = "列出所有监听器",
        .detail =
        \\用途:  GET /v2/watch，输出原始 JSON。
        \\用法:  aio-cli watch-ls
        \\参数:  无。
        \\示例:  aio-cli watch-ls
        ,
    },

    // ---------------- MCP ----------------
    .{
        .name = "mcp",
        .group = 7,
        .brief = "MCP Hub JSON-RPC 透传",
        .detail =
        \\用途:  POST /mcp，{"jsonrpc":"2.0","id":1,"method":…,"params":…}。
        \\用法:  aio-cli mcp <方法> [--params=<JSON>]
        \\参数:  <方法>    initialize / tools/list / tools/call / ping 等。
        \\       --params= JSON-RPC params，原样嵌入。
        \\示例:  aio-cli mcp initialize
        \\       aio-cli mcp tools/list
        \\       aio-cli mcp ping
        \\       aio-cli mcp tools/call --params='{"name":"browser_navigate","arguments":{"url":"https://example.com"}}'
        \\注意:  tools/list 约 31 个工具；id 固定为 1。
        ,
    },

    // ---------------- 桌面 computer-use ----------------
    .{
        .name = "cmp-info",
        .group = 8,
        .brief = "computer-use worker 信息",
        .detail =
        \\用途:  GET /v2/computer/info。
        \\用法:  aio-cli cmp-info
        \\参数:  无。
        \\示例:  aio-cli cmp-info
        \\注意:  只有 aio-computer 镜像可用；aio-daemon 上 /v2/computer/* 返回 503。
        ,
    },
    .{
        .name = "cmp-shot",
        .group = 8,
        .brief = "桌面截图到本地 PNG",
        .detail =
        \\用途:  GET /v2/computer/screenshot，原始 PNG 落本地。
        \\用法:  aio-cli cmp-shot [本地输出.png]
        \\参数:  [本地输出.png]  缺省 screenshot.png。
        \\示例:  aio-cli cmp-shot desk.png
        ,
    },
    .{
        .name = "cmp-cursor",
        .group = 8,
        .brief = "当前光标位置",
        .detail =
        \\用途:  GET /v2/computer/cursor。
        \\用法:  aio-cli cmp-cursor
        \\示例:  aio-cli cmp-cursor
        ,
    },
    .{
        .name = "cmp-clipboard",
        .group = 8,
        .brief = "读剪贴板",
        .detail =
        \\用途:  GET /v2/computer/clipboard。
        \\用法:  aio-cli cmp-clipboard
        \\示例:  aio-cli cmp-clipboard
        \\注意:  **剪贴板为空时读会 503**：先 SET_CLIPBOARD（cmp-act）再读。
        ,
    },
    .{
        .name = "cmp-windows",
        .group = 8,
        .brief = "列出窗口",
        .detail =
        \\用途:  GET /v2/computer/windows。
        \\用法:  aio-cli cmp-windows
        \\示例:  aio-cli cmp-windows
        ,
    },
    .{
        .name = "cmp-a11y",
        .group = 8,
        .brief = "可访问性树（应用级）",
        .detail =
        \\用途:  GET /v2/computer/accessibility。
        \\用法:  aio-cli cmp-a11y [--scope=<范围>] [--max-depth=<n>] [--max-nodes=<n>]
        \\                        [--role=<角色>] [--name=<名字>]
        \\参数:  --scope= --max-depth= --max-nodes= --role= --name=   按需过滤/裁剪。
        \\示例:  aio-cli cmp-a11y
        \\       aio-cli cmp-a11y --role=button --max-nodes=50
        ,
    },
    .{
        .name = "cmp-a11y-nodes",
        .group = 8,
        .brief = "可访问性节点明细",
        .detail =
        \\用途:  GET /v2/computer/accessibility/nodes，支持比 cmp-a11y 更多的过滤。
        \\用法:  aio-cli cmp-a11y-nodes [--scope=] [--max-depth=] [--max-nodes=] [--role=] [--name=]
        \\                             [--match=<串>] [--states=<状态>] [--include-offscreen]
        \\                             [--timeout-ms=<毫秒>] [--limit=<n>] [--node-id=<id>]
        \\示例:  aio-cli cmp-a11y-nodes --role=button --limit=20
        \\       aio-cli cmp-a11y-nodes --match=Save --include-offscreen
        ,
    },
    .{
        .name = "cmp-act",
        .group = 8,
        .brief = "执行一个桌面动作",
        .detail =
        \\用途:  POST /v2/computer/actions。动作体是 tagged union，CLI 会做归一（加法式补字段）。
        \\用法:  aio-cli cmp-act '<JSON 动作>' [--screenshot]
        \\参数:  --screenshot  加 include_screenshot=true，顺带回一张图。
        \\示例:  aio-cli cmp-act '{"action_type":"CLICK","x":100,"y":200}'
        \\       aio-cli cmp-act '{"action_type":"SET_CLIPBOARD","text":"hi"}'
        \\       aio-cli cmp-act '{"action":"left_click","coordinate":[100,200]}' --screenshot
        \\注意:  归一规则：①已有 action_type 原样透传 ②v1/OSWorld 风格动作名追加 action_type
        \\       ③坐标类动作缺 x/y 而有 coordinate=[x,y] 时补上。绝不会删用户字段。
        ,
    },
    .{
        .name = "cmp-act-batch",
        .group = 8,
        .brief = "批量执行桌面动作",
        .detail =
        \\用途:  POST /v2/computer/actions/batch，包成 {"actions":[…],"include_screenshot":bool}。
        \\用法:  aio-cli cmp-act-batch '<JSON 动作数组>' [--screenshot]
        \\参数:  --screenshot  结果里带回截图。
        \\示例:  aio-cli cmp-act-batch '[{"action_type":"CLICK","x":10,"y":10},{"action_type":"TYPE","text":"hi"}]'
        \\注意:  必须传 JSON 数组；非数组会明确报错退出。
        ,
    },
    .{
        .name = "cmp-record",
        .group = 8,
        .brief = "桌面录制（start / stop）",
        .detail =
        \\用途:  POST /v2/computer/record。
        \\用法:  aio-cli cmp-record [--action=start|stop] [--fps=<n>] [--crf=<n>]
        \\                          [--max-duration=<秒>] [--width=<px>] [--height=<px>] [--save-path=<路径>]
        \\参数:  --action=      start（默认）/ stop。
        \\       --fps= --crf=  帧率 / 质量（crf 越小越清晰）。
        \\       --max-duration= 最长录制秒数。
        \\       --width= --height= --save-path=  分辨率与落盘路径。
        \\示例:  aio-cli cmp-record --action=start --fps=15
        \\       aio-cli cmp-record --action=stop --save-path=/tmp/screen.mp4
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

/// 命令名是否已知（在读 SANDBOX_BASE 之前就能判定，用于"未知命令"优先报错）。
pub fn known(name: []const u8) bool {
    if (eqStr(name, "health")) return true;
    return find(name) != null;
}

fn eqStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 猜一个名字（用于「你是不是想找」提示）：返回公共前缀最长的候选。
fn suggest(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_n: usize = 4;
    for (&table) |*e| {
        const a = e.name;
        const m = @min(name.len, a.len);
        var n: usize = 0;
        while (n < m and name[n] == a[n]) n += 1;
        if (n >= 3 and n < best_n) {
            best_n = n;
            best = a;
        }
    }
    return best;
}

const banner =
    \\所有取值型 flag 一律用等号写法：--key=value（例：--lang=python）；布尔开关直接写 --flag。
    \\
;

pub fn printVersion(out: *std.Io.Writer) !void {
    try out.print(
        \\{s} (zig) {s}
        \\仓库: {s}
        \\文档: {s}
        \\构建: Zig 0.17.0 · musl 静态单文件 · ReleaseFast + strip
        \\构建命令: cd aio-cli && zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
        \\产物名: aarch64 → aio-cli-aarch64-linux-musl ；x86_64 → aio-cli-x86_64-linux-musl
        \\数据面: SANDBOX_BASE（必填，可用 https 网关或沙箱内 http://127.0.0.1:8080）
        \\
    , .{ tool, cfg.version, repo, docs });
}

pub fn printTop(out: *std.Io.Writer) !void {
    try out.print(
        \\{s} (zig) {s} —— 沙箱内 aiod v2 API 遥控（执行 / 文件 / PTY / 代码 / 浏览器 / 监听 / 桌面）
        \\仓库 {s} ｜ 逐条文档 {s}
        \\
        \\用法: {s} <命令> [位置参数…] [--key=value]
        \\
    , .{ tool, cfg.version, repo, docs, tool });
    try out.writeAll(banner);
    try out.print(
        \\本帮助即**权威命令面**：命令表在 src/help.zig，与 docs/aio-cli.md 同步更新、随代码走。
        \\
        \\【基础】
        \\  health / sandbox-info / sandbox-packages [--lang=]   version / help [命令|all]
        \\
        \\【执行】
        \\  exec <命令…> [--cwd= --shell= --user= --session= --env= --timeout= --max-output=]
        \\  exec --id=<id> [--offset= --stderr-offset= --wait --wait-timeout=]   async <命令…>   log <id> [--follow]
        \\  kill <id> [--signal=]   stdin <id> <文本> [--enter]
        \\  sess-new <id> [--cwd= --env=] / sess <id> <命令…> [--timeout=] / sess-ls / sess-rm <id>
        \\
        \\【文件】
        \\  cat|read <路径> [--start= --end= --user=]  write <本地|-> <远端> [--append]  get <远端> <本地>
        \\  put <本地|-> <远端> [--overwrite]    fs-tree-put <tar|-> <目录> [--user= --json]
        \\  ls [路径] [--recursive --hidden --depth=] / tree [路径] [--tar|--out=] / stat / mkdir / rm [--recursive]
        \\  cp|mv <源> <目标> [--overwrite]   edit <路径> (--old= --new= [--replace-all|-first|-last] | --insert= --text=)
        \\  grep <路径> <正则> [--fixed --ignore-case --include= --exclude= --context= --max=]   search <路径> <glob>
        \\
        \\【终端 PTY】
        \\  pty-new <id> [--cwd= --user= --cols= --rows=]   pty <id> <命令…> [--timeout= --hard-timeout= --async]
        \\  pty-screen <id>   pty-input <id> <文本> [--enter]   pty-signal <id> [信号]
        \\  pty-resize <id> [--cols= --rows=]   pty-ls   pty-info <id>   pty-rm <id>
        \\  pty-ws <id> [--send= --max= --raw]      pty-ws-anon [--max=]
        \\
        \\【代码解释器】
        \\  code <源码…> [--lang= --session= --timeout=]   code-info
        \\  code-sess-new [--lang=] / code-sess-ls / code-sess-get <id> / code-sess-rm <id>
        \\【浏览器】（需 aio-daemon / aio-browser 镜像）
        \\  br-info / br-tabs / br-network / br-snapshot [--interactive] / br-cookies [--url=]
        \\  br-go <url> [--wait= --timeout= --tab= | --history=]    br-shot <out.png> [--full --quality=]
        \\  br-eval <表达式> [--await]   br-click|br-fill (--selector=|--ref=) [--value=]   br-config [--json=JSON]
        \\  br-tab-new [--url=] / br-tab-use <id> / br-tab-close <id>
        \\  br-cookie-set --name= --value= [--url= --domain=]   br-cookie-rm [--all|--name= --url= --domain=]
        \\  br-upload --paths=<沙箱内文件,…> [--selector=|--ref=]   br-cdp <方法> [--params=JSON]
        \\
        \\【监听 / MCP】
        \\  watch [路径] [--recursive --debounce=]   watch-poll <id> [--cursor= --limit= --timeout=]   watch-ls / watch-rm <id>
        \\  watch-events <id> [--max= --json]
        \\  mcp <initialize|tools/list|tools/call|ping> [--params=JSON]
        \\
        \\【桌面】（需 aio-computer 镜像，否则 503）
        \\  cmp-info / cmp-shot [out.png] / cmp-cursor / cmp-clipboard / cmp-windows
        \\  cmp-a11y [--scope= --max-depth= --max-nodes= --role= --name=]
        \\  cmp-a11y-nodes [同上 + --match= --states= --include-offscreen --limit= --node-id=]
        \\  cmp-act '<JSON>' [--screenshot]   cmp-act-batch '<JSON 数组>' [--screenshot]
        \\  cmp-record [--action= --fps= --crf= --max-duration= --width= --height= --save-path=]
        \\
        \\单命令帮助（三种写法等价，**只打印不执行**）：
        \\  {s} help exec   ｜   {s} exec --help   ｜   {s} exec -h
        \\
        \\环境变量（仓库内不含任何部署信息）:
        \\  SANDBOX_BASE   aiod 网关地址（必填）。带端口的完整网关 https://<gw>/sandbox/<sandboxID>/8080
        \\                 沙箱内自测 http://127.0.0.1:8080 ；末尾多余的 / 会自动去掉
        \\  SANDBOX_KEY    鉴权 Key（可选，非空时附 Authorization: Bearer + X-API-Key）
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
            try out.print("  {s:<20} {s}\n", .{ nm, e.brief });
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