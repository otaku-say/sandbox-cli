# aio-cli

沙箱内 **aiod v2 API** 遥控 CLI（Zig 实现）。

## 环境变量

| 变量 | 说明 |
|---|---|
| `SANDBOX_BASE` | 沙箱内 aiod 网关地址，形如 `https://<gateway-host>/sandbox/<sandboxID>/8080`（必填） |
| `SANDBOX_KEY` | 鉴权 Key（可选） |

## 代码结构

| 文件 | 职责 |
|---|---|
| `src/main.zig` | 入口、命令分发、`health` / `version` |
| `src/cfg.zig` | 环境变量 |
| `src/ctx.zig` | `Ctx`：io / client / arena / out / base / key |
| `src/httpc.zig` | HTTP 核心：`request` / `get` / `postJson` / `del` |
| `src/util.zig` | 参数解析 `Args`、鉴权头、输出辅助 |
| `src/cmd_exec.zig` | 命令执行：exec / async / log / kill / stdin / sess* |
| `src/cmd_files.zig` | 文件：cat / read / write / put / get / ls / tree / mkdir / rm / mv / cp / edit / grep / search / stat |
| `src/cmd_pty.zig` | 终端：pty / pty-new / pty-input / pty-screen / pty-signal / pty-resize / pty-ls / pty-rm / pty-ws |
| `src/cmd_browser.zig` | 浏览器 br-* 与 computer-use cmp-* |
| `src/cmd_misc.zig` | code / code-* / watch / watch-* / mcp / sandbox-info / sandbox-packages |

## 开发约定（**重要**）

每个 `cmd_*.zig` 只导出一个入口：

```zig
pub fn dispatch(c: *Ctx, cmd: []const u8, args: []const []const u8) !bool {
    if (std.mem.eql(u8, cmd, "xxx")) { try doXxx(c, args); return true; }
    return false;
}
```

- 命中本模块负责的命令 → 执行并返回 `true`；不命中 → 返回 `false`
- **不要修改 `main.zig`**：模块已按固定顺序注册，只需改自己负责的文件

典型用法：

```zig
const argv = try util.parse(c.arena, args);
const path = argv.at(0) orelse return error.MissingArg;
const timeout = argv.get("timeout");

const url = try c.url("/v2/commands");
const buf = try c.arena.alloc(u8, util.BUF);
var storage: [3]std.http.Header = undefined;
const res = try httpc.postJson(c.client, url, util.jsonHeaders(c, &storage), body, buf);
try util.printOrFail(c, res);
```

## Zig 0.17 API 要点（与网上/模型记忆里的旧示例**完全不同**）

| 旧写法（≤0.14） | 0.17 正确写法 |
|---|---|
| `std.io.Writer.fixed` | `std.Io.Writer.fixed` |
| `client.fetch(.{...})` 无 io | `client` 构造时**必须注入** `.io` |
| `fn main() !void` | `pub fn main(init: std.process.Init.Minimal) !void` |
| `std.process.argsAlloc` | `init.args.vector`（`[]const [*:0]const u8`，`std.mem.span` 转 slice） |
| `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator` / `std.heap.smp_allocator` |
| `std.io.fixedBufferStream` | 无（用 `std.Io.Writer.fixed` 或手写） |
| `std.mem.trimRight` | 无（手写） |
| `std.posix.getenv` | `std.c.getenv`（构建需 `link_libc`） |

HTTP 客户端初始化（`main.zig` 已做，模块内直接用 `c.client`）：

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
const io = threaded.io();
var client: std.http.Client = .{ .allocator = gpa, .io = io };
```

## 构建

```bash
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
```

需要 Zig **0.17.0**。
