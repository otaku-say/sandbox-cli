//! exec-async / exec-logs / exec-kill / exec-stdin —— envd 进程 API 的异步执行族，
//! 外加 code --mode=kernel 的代码解释器通道。
//!
//! 与 SDK 的关系（2026-10-04 实测，envd 0.5.13）：
//!   SDK 的 Commands.run 只是同步执行；envd 本体支持「Start 后断开连接、进程继续跑」
//!   （List / Connect / SendSignal / SendInput 均可对运行中 pid 操作）。
//!   本组命令把该能力整理成 CLI 原语，并用**输出落盘**弥补 envd 无缓冲的问题：
//!     exec-async 的包装脚本把 stdout/stderr 重定向到 /tmp/.cube-cli-exec/<tag>.{out,err}，
//!     退出码写 <tag>.exit → exec-logs 因此可以按字节偏移增量拉取（--offset/--limit/--follow）。
//!
//! 端点在 envd（49983）的 process.Process 服务：
//!   POST /process.Process/Start      启动（异步：读到 start 事件里的 pid 即断开）
//!   POST /process.Process/List       运行中进程列表
//!   POST /process.Process/SendSignal "SIGNAL_SIGKILL" / "SIGNAL_SIGTERM"
//!   POST /process.Process/SendInput  输入（stdin / pty）
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");
const httpc = @import("httpc.zig");
const cfg = @import("cfg.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

/// exec-async 的会话目录（日志 + pid→元信息映射都在这里）。
pub const EXEC_DIR = "/tmp/.cube-cli-exec";
/// pty-open 的会话目录。
pub const PTY_DIR = "/tmp/.cube-cli-pty";

pub const help_async =
    \\exec-async <sandboxID> <命令...> [--cwd=] [--env=NAME|K=V] [--user=] [--timeout=秒] [--no-stdin]
    \\  在沙箱内**后台**启动一条命令：读到 envd 的 start 事件后立即断开，打印 pid 后返回；
    \\  进程继续运行，stdout/stderr 落盘（/tmp/.cube-cli-exec/<tag>.{out,err}），退出码写 .exit。
    \\  默认保持 stdin 打开（配合 exec-stdin 送输入）；--no-stdin 立即 EOF。
    \\  --timeout= 用 `timeout -k 5 <秒>` 包一层（到点自动杀）。
    \\  拉日志：cube-cli exec-logs <sid> <pid> --follow ｜ 结束：cube-cli exec-kill <sid> <pid>
;

pub const help_logs =
    \\exec-logs <sandboxID> <pid> [--mode=stdout|stderr|both] [--offset=N] [--limit=N] [--follow]
    \\  增量拉取 exec-async 进程的输出（按字节偏移；默认从头读当前已有内容）。
    \\  --offset=N  从第 N 字节开始；--limit=N 本次最多读 N 字节；--follow 持续跟随到进程结束。
    \\  --mode      选择流（both = 先 stdout 后 stderr 分段拼接，无跨流严格时序）。
    \\  进程结束后打印退出码（exit 文件）。
;

pub const help_kill =
    \\exec-kill <sandboxID> <pid> [--sigterm]
    \\  给异步进程发信号（默认 SIGKILL，--sigterm 用 SIGTERM）。进程不存在时提示已退出（幂等）。
;

pub const help_stdin =
    \\exec-stdin <sandboxID> <pid> <数据...>
    \\  给异步进程送 stdin（数据为位置参数空格拼接；`-` 表示从本机 stdin 读原始字节）。
    \\  需要进程以 stdin 打开启动（exec-async 默认如此，--no-stdin 启动的会报 not enabled）。
;

/// exec-async 的进程元信息（/tmp/.cube-cli-exec/<pid>.meta）。
pub const SessMeta = struct {
    pid: i64 = 0,
    tag: []const u8 = "",
    out: []const u8 = "",
    err: []const u8 = "",
    exit: []const u8 = "",
    log: []const u8 = "",
    shell: []const u8 = "",
    cmd: []const u8 = "",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 12 位十六进制随机 tag（std.Io.random）。
pub fn newTag(c: *Ctx) ![]const u8 {
    var rb: [6]u8 = undefined;
    std.Io.random(c.io, &rb);
    const hex = "0123456789abcdef";
    const out = try c.arena.alloc(u8, 12);
    for (rb, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

/// 读会话元信息；不存在/解析失败返回 error。
pub fn loadMeta(c: *Ctx, base: []const u8, token: ?[]const u8, user: ?[]const u8, dir: []const u8, pid: i64, buf: []u8) !SessMeta {
    const path = try std.fmt.allocPrint(c.arena, "{s}/{d}.meta", .{ dir, pid });
    const res = try envd.readFile(c.arena, c.client, base, token, user, path, buf);
    if (!res.ok()) return error.NoMeta;
    const parsed = std.json.parseFromSlice(SessMeta, c.arena, res.body, .{ .ignore_unknown_fields = true }) catch return error.BadMeta;
    return parsed.value;
}

/// 写会话元信息（目录可能刚创建，失败时补一次 mkdir 再写）。
pub fn writeMeta(c: *Ctx, base: []const u8, token: ?[]const u8, user: ?[]const u8, dir: []const u8, pid: i64, json: []const u8, buf: []u8) !void {
    const path = try std.fmt.allocPrint(c.arena, "{s}/{d}.meta", .{ dir, pid });
    var res = try envd.writeFile(c.arena, c.client, base, token, user, path, json, buf);
    if (!res.ok()) {
        const mk = try std.fmt.allocPrint(c.arena, "mkdir -p {s}", .{dir});
        _ = envd.exec(c.arena, c.client, base, token, user, mk, null, null, 0, buf) catch {};
        res = try envd.writeFile(c.arena, c.client, base, token, user, path, json, buf);
    }
    if (!res.ok()) return error.MetaFailed;
}

/// 进程是否仍在运行（List 里能否找到该 pid）。
pub fn pidAlive(c: *Ctx, base: []const u8, token: ?[]const u8, user: ?[]const u8, pid: i64, buf: []u8) bool {
    const res = envd.listProcs(c.arena, c.client, base, token, user, buf) catch return false;
    if (!res.ok()) return false;
    const pat = std.fmt.allocPrint(c.arena, "\"pid\":{d}", .{pid}) catch return false;
    return std.mem.indexOf(u8, res.body, pat) != null;
}

/// 增量读取的返回：data = 本次新增内容；next = 读完后应使用的偏移。
pub const Delta = struct { data: []const u8 = "", next: u64 = 0 };

/// 按字节偏移读远端文件（Range 优先，服务端忽略时本地切片）。
/// 文件不存在（404）返回空增量（还在创建中）。
pub fn readDelta(c: *Ctx, base: []const u8, token: ?[]const u8, user: ?[]const u8, path: []const u8, off: u64, limit: u64, buf: []u8) !Delta {
    const res = try envd.readFileRange(c.arena, c.client, base, token, user, path, off, buf);
    if (res.status == 404) return .{ .data = "", .next = off };
    // 416 = 偏移已到文件末尾（无新增内容），不是错误：返回空增量，
    // follow 循环靠 pidAlive/readExit 收尾（见 issue #2）。
    if (res.status == 416) return .{ .data = "", .next = off };
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    var data: []const u8 = res.body;
    if (res.status != 206) {
        if (off >= data.len) {
            data = "";
        } else {
            data = data[off..];
        }
    }
    if (limit > 0 and data.len > limit) data = data[0..limit];
    return .{ .data = data, .next = off + @as(u64, @intCast(data.len)) };
}

/// 读退出码文件（不存在返回 null）。
pub fn readExit(c: *Ctx, base: []const u8, token: ?[]const u8, user: ?[]const u8, path: []const u8, buf: []u8) ?i64 {
    const res = envd.readFile(c.arena, c.client, base, token, user, path, buf) catch return null;
    if (!res.ok() or res.body.len == 0) return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, res.body, " \r\n\t"), 10) catch null;
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "exec-async")) {
        try cmdExecAsync(c, a);
        return true;
    }
    if (eq(cmd, "exec-logs")) {
        try cmdExecLogs(c, a);
        return true;
    }
    if (eq(cmd, "exec-kill")) {
        try cmdExecKill(c, a);
        return true;
    }
    if (eq(cmd, "exec-stdin")) {
        try cmdExecStdin(c, a);
        return true;
    }
    return false;
}

/// exec-async <sid> <cmd...>
fn cmdExecAsync(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const cmdtext = a.joinFrom(1, " ");
    if (cmdtext.len == 0) {
        try c.out.print("用法：{s}\n", .{help_async});
        return error.MissingArg;
    }

    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);

    const tag = try newTag(c);
    const out = try std.fmt.allocPrint(c.arena, "{s}/{s}.out", .{ EXEC_DIR, tag });
    const err = try std.fmt.allocPrint(c.arena, "{s}/{s}.err", .{ EXEC_DIR, tag });
    const ex = try std.fmt.allocPrint(c.arena, "{s}/{s}.exit", .{ EXEC_DIR, tag });

    // 包装：输出落盘 + 退出码落盘 → exec-logs 可增量拉取
    var inner: []const u8 = cmdtext;
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(u64, t, 10)) |secs| {
            if (secs > 0) {
                inner = try std.fmt.allocPrint(c.arena, "timeout -k 5 {d} bash -c {s}", .{ secs, try util.shellQuote(c.arena, cmdtext) });
            }
        } else |_| {}
    }
    const wrapper = try std.fmt.allocPrint(
        c.arena,
        "mkdir -p {s} 2>/dev/null; {{ {s} ; }} > {s} 2> {s}; echo $? > {s}",
        .{ EXEC_DIR, inner, out, err, ex },
    );

    const envs = try util.envsJson(c.arena, a.flags);
    const cwd_part = if (a.get("cwd")) |wd|
        try std.fmt.allocPrint(c.arena, ",\"cwd\":\"{s}\"", .{try envd.jsonEscape(c.arena, wd)})
    else
        "";
    const stdin_flag: []const u8 = if (a.has("no-stdin")) "false" else "true";
    const payload = try std.fmt.allocPrint(
        c.arena,
        "{{\"process\":{{\"cmd\":\"/bin/bash\",\"args\":[\"-l\",\"-c\",\"{s}\"],\"envs\":{{{s}}}{s}}},\"stdin\":{s}}}",
        .{ try envd.jsonEscape(c.arena, wrapper), envs, cwd_part, stdin_flag },
    );

    const res = try envd.startDetached(c.arena, c.client, base, token, a.get("user"), payload, buf);
    if (!res.ok()) {
        try c.out.print("启动失败：HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    const pid32 = envd.extractInt(res.body, "pid") orelse {
        try c.out.print("启动失败：未收到 pid（{s}）\n", .{res.body});
        return error.NoPid;
    };
    const pid: i64 = pid32;

    const meta = try std.fmt.allocPrint(
        c.arena,
        "{{\"pid\":{d},\"tag\":\"{s}\",\"out\":\"{s}\",\"err\":\"{s}\",\"exit\":\"{s}\",\"cmd\":\"{s}\"}}",
        .{ pid, tag, out, err, ex, try envd.jsonEscape(c.arena, cmdtext) },
    );
    writeMeta(c, base, token, a.get("user"), EXEC_DIR, pid, meta, buf) catch {
        std.debug.print("[exec-async] 警告：会话元信息写入失败，exec-logs 可能找不到日志\n", .{});
    };

    try c.out.print("pid {d}\n", .{pid});
    try c.out.print("  stdout {s}\n", .{out});
    try c.out.print("  stderr {s}\n", .{err});
    try c.out.print("  拉日志 cube-cli exec-logs {s} {d} --follow ｜ 输入 cube-cli exec-stdin {s} {d} <数据> ｜ 结束 cube-cli exec-kill {s} {d}\n", .{ sid, pid, sid, pid, sid, pid });
}

/// exec-logs <sid> <pid> [--mode=stdout|stderr|both] [--offset=] [--limit=] [--follow]
fn cmdExecLogs(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = std.fmt.parseInt(i64, pid_s, 10) catch {
        try c.out.print("pid 必须是数字：{s}\n", .{pid_s});
        return error.BadArg;
    };

    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);

    const meta = loadMeta(c, base, token, a.get("user"), EXEC_DIR, pid, buf) catch {
        try c.out.print("未找到 pid {d} 的执行记录（不是 exec-async 启动的？）\n", .{pid});
        return error.NoMeta;
    };

    const mode = a.get("mode") orelse "both";
    var off_out: u64 = if (a.get("offset")) |o| (std.fmt.parseInt(u64, o, 10) catch 0) else 0;
    var off_err: u64 = off_out;
    const limit: u64 = if (a.get("limit")) |l| (std.fmt.parseInt(u64, l, 10) catch 0) else 0;
    const follow = a.has("follow");

    var last_exit: ?i64 = null;
    while (true) {
        var fresh = false;
        if (!eq(mode, "stderr")) {
            const d = try readDelta(c, base, token, a.get("user"), meta.out, off_out, limit, buf);
            if (d.data.len > 0) {
                try c.out.print("{s}", .{d.data});
                off_out = d.next;
                fresh = true;
            }
        }
        if (!eq(mode, "stdout")) {
            const d = try readDelta(c, base, token, a.get("user"), meta.err, off_err, limit, buf);
            if (d.data.len > 0) {
                try c.out.print("\n--- stderr ---\n{s}", .{d.data});
                off_err = d.next;
                fresh = true;
            }
        }
        if (readExit(c, base, token, a.get("user"), meta.exit, buf)) |code| last_exit = code;

        if (!follow) break;
        if (last_exit != null and !fresh) break;
        if (!fresh and !pidAlive(c, base, token, a.get("user"), pid, buf)) break;
        try std.Io.sleep(c.io, .fromMilliseconds(700), .awake);
    }

    try c.out.print("\n[exec-logs] stdout 偏移 {d} B；stderr 偏移 {d} B；", .{ off_out, off_err });
    if (last_exit) |code| {
        try c.out.print("退出码 {d}\n", .{code});
    } else if (pidAlive(c, base, token, a.get("user"), pid, buf)) {
        try c.out.print("进程仍在运行（--follow 可继续跟随）\n", .{});
    } else {
        try c.out.print("进程已结束（无退出码落盘：可能被信号杀死）\n", .{});
    }
}

/// exec-kill <sid> <pid> [--sigterm]
fn cmdExecKill(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = std.fmt.parseInt(i64, pid_s, 10) catch {
        try c.out.print("pid 必须是数字：{s}\n", .{pid_s});
        return error.BadArg;
    };
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);
    const sig: []const u8 = if (a.has("sigterm")) "SIGNAL_SIGTERM" else "SIGNAL_SIGKILL";
    const res = try envd.sendSignal(c.arena, c.client, base, token, a.get("user"), pid, sig, buf);
    if (res.status == 404) {
        try c.out.print("pid {d} 已不存在（可能已退出）\n", .{pid});
        return;
    }
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    try c.out.print("killed pid {d}（{s}）\n", .{ pid, sig });
}

/// exec-stdin <sid> <pid> <数据...|->
fn cmdExecStdin(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = std.fmt.parseInt(i64, pid_s, 10) catch {
        try c.out.print("pid 必须是数字：{s}\n", .{pid_s});
        return error.BadArg;
    };
    if (a.pos.len < 3) {
        try c.out.print("用法：{s}\n", .{help_stdin});
        return error.MissingArg;
    }

    const buf = try c.arena.alloc(u8, BUF);
    var data: []const u8 = "";
    if (eq(a.pos[2], "-")) {
        var rbuf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().reader(c.io, &rbuf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = r.interface.readSliceShort(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        // 注意：不能直接 data = buf[0..total]（别名），后续 connectToken/sendInput
        // 会把 HTTP 响应写进同一块 buf 头部，管道数据发送前就被掉包（见 issue #3）。
        data = try c.arena.dupe(u8, buf[0..total]);
    } else {
        data = a.joinFrom(2, " ");
    }

    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);
    const res = try envd.sendInput(c.arena, c.client, base, token, a.get("user"), pid, "stdin", data, buf);
    if (!res.ok()) {
        if (res.status == 404) {
            try c.out.print("pid {d} 已不存在（可能已退出）\n", .{pid});
            return;
        }
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        try c.out.print("提示：进程需以 stdin 打开启动（exec-async 默认打开；--no-stdin 的会拒绝输入）。\n", .{});
        return error.HttpError;
    }
    try c.out.print("sent {d} bytes -> pid {d}\n", .{ data.len, pid });
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

/// code --mode=kernel：POST <proxy>/sandbox/<sid>/49999/execute（E2B 代码解释器协议）。
///
/// 请求体 {code, language, env_vars}；响应是 ndjson，事件类型：
///   stdout / stderr / result / error / number_of_executions
/// result 里除 text 外还可能是 html/svg/png/jpeg/pdf/latex/json/javascript/chart。
pub fn kernelRun(c: *Ctx, sid: []const u8, code: []const u8, lang: ?[]const u8, envs_json: []const u8, timeout_ms: u64) !void {
    _ = timeout_ms; // 读超时依赖服务端；事件流在解释器返回后自然结束
    const proxy = cfg.proxyURL() orelse {
        try c.out.print("错误：缺少环境变量 CUBESANDBOX_PROXY_URL\n", .{});
        return error.MissingConfig;
    };
    const url = try std.fmt.allocPrint(c.arena, "{s}/sandbox/{s}/49999/execute", .{ ctxmod.trimSlash(proxy), sid });
    const envs_part: []const u8 = if (envs_json.len > 0)
        try std.fmt.allocPrint(c.arena, "{{{s}}}", .{envs_json})
    else
        "null";
    const lang_part: []const u8 = if (lang) |l|
        try std.fmt.allocPrint(c.arena, "\"{s}\"", .{try envd.jsonEscape(c.arena, l)})
    else
        "null";
    const body = try std.fmt.allocPrint(
        c.arena,
        "{{\"code\":\"{s}\",\"language\":{s},\"env_vars\":{s}}}",
        .{ try envd.jsonEscape(c.arena, code), lang_part, envs_part },
    );

    const buf = try c.arena.alloc(u8, BUF);
    var hs: [2]std.http.Header = undefined;
    hs[0] = .{ .name = "Content-Type", .value = "application/json" };
    hs[1] = .{ .name = "Accept", .value = "application/x-ndjson" };
    const res = try httpc.request(c.client, .POST, url, hs[0..2], body, buf);
    if (!res.ok()) {
        try c.out.print("内核模式失败：HTTP {d}（端口 49999）\n", .{res.status});
        try c.out.print("  说明：SDK 的 kernel 通道 = 沙箱端口 49999（E2B 代码解释器 /execute）。\n", .{});
        try c.out.print("  本部署 CF 路径路由本身可达（实测：临时监听 49999 → /sandbox/<sid>/49999/ 返回 200），\n", .{});
        try c.out.print("  但当前 aio-* 镜像未内置该服务（只听 8080 / 49983）→ /execute 502。\n", .{});
        try c.out.print("  需要镜像内置解释器服务；普通执行请用 --mode=interp（默认）或 exec。\n", .{});
        return error.HttpError;
    }

    var any = false;
    var lines = std.mem.splitScalar(u8, res.body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, c.arena, line, .{}) catch continue;
        const v = parsed.value;
        const ty = getStr(v, "type") orelse continue;
        any = true;
        if (eq(ty, "stdout")) {
            if (getStr(v, "text")) |tx| try c.out.print("{s}", .{tx});
        } else if (eq(ty, "stderr")) {
            if (getStr(v, "text")) |tx| std.debug.print("{s}", .{tx});
        } else if (eq(ty, "result")) {
            var printed_text = false;
            if (getStr(v, "text")) |tx| {
                if (tx.len > 0) {
                    try c.out.print("{s}\n", .{tx});
                    printed_text = true;
                }
            }
            var noted = false;
            const known = [_][]const u8{ "html", "markdown", "svg", "png", "jpeg", "pdf", "latex", "json", "javascript", "chart", "data" };
            for (known) |k| {
                const fv = v.object.get(k) orelse continue;
                const sz: usize = switch (fv) {
                    .string => |ss| ss.len,
                    .object => |o| o.count(),
                    .array => |arr| arr.items.len,
                    else => 0,
                };
                if (sz == 0) continue;
                if (!noted) {
                    try c.out.print("[结果", .{});
                    noted = true;
                }
                try c.out.print(" {s}({d})", .{ k, sz });
            }
            if (noted) try c.out.print("；非文本格式未展开]\n", .{});
            if (!noted and !printed_text) try c.out.print("[结果：空]\n", .{});
        } else if (eq(ty, "error")) {
            const name = getStr(v, "name") orelse "Error";
            const value = getStr(v, "value") orelse "";
            const tb = getStr(v, "traceback") orelse "";
            std.debug.print("代码执行错误：{s}: {s}\n", .{ name, value });
            if (tb.len > 0) std.debug.print("{s}\n", .{tb});
            c.out.flush() catch {};
            std.process.exit(1);
        }
        // number_of_executions 等其它事件忽略
    }
    if (!any) {
        try c.out.print("（端口 49999 有响应但无事件：请确认它是 E2B 代码解释器）\n", .{});
    }
}
