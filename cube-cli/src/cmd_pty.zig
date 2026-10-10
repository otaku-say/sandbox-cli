//! pty-open / pty-write / pty-read / pty-close / pty-resize —— envd PTY 四件套（+resize）。
//!
//! 机制（2026-10-04 实测，envd 0.5.13）：
//!   - Start 带 "pty" 字段 = PTY 模式；断开响应流后进程继续运行（可再 Connect/SendInput）
//!   - Connect 只连**仍在运行**的 pid，且不重放断开期间的输出（envd 无缓冲）——
//!     直接用 Connect 做「读」会丢命令之间的输出
//!   - 因此 pty-open 用 /usr/bin/script(1) 把整个会话记录到文件（= 持久会话）：
//!       Start: /usr/bin/script -q -f -c "<shell> -i -l" /tmp/.cube-cli-pty/<tag>.log
//!     之后 pty-read 按字节偏移读该文件；pty-write 的输入（SendInput）与 shell 的
//!     回复都会落在文件里。日志与元信息在沙箱的 /tmp/.cube-cli-pty/ 下。
//!   - pty-write = SendInput(pty)；pty-close = SendSignal(SIGKILL)；pty-resize = Update
//!
//! 依赖镜像里有 /usr/bin/script（util-linux）。缺了会话会立即退出，pty-read 便读不到内容。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");
const cmd_proc = @import("cmd_proc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

pub const help_open =
    \\pty-open <sandboxID> [--rows=24] [--cols=80] [--shell=/bin/bash] [--cwd=] [--env=NAME|K=V] [--user=]
    \\  交互式 PTY 会话：用 script(1) 在 PTY 里跑 `<shell> -i -l` 并把整个会话记录到
    \\  /tmp/.cube-cli-pty/<tag>.log，打印 pid 后立即返回（会话常驻，断开不断）。
    \\  之后：pty-write 送输入 / pty-read 拉输出（按偏移增量）/ pty-close 结束。
;

pub const help_write =
    \\pty-write <sandboxID> <pid> <数据...>
    \\  向 PTY 会话送输入（SendInput pty）。数据是位置参数空格拼接；`-` = 从本机 stdin
    \\  读原始字节（可送控制字符）。--enter 额外补一个回车（\r）。
;

pub const help_read =
    \\pty-read <sandboxID> <pid> [--offset=N] [--limit=N] [--lines=N] [--follow] [--raw]
    \\  按字节偏移读 PTY 会话记录（默认从头读现有全部内容）。
    \\  --lines=N  只看最后 N 行（tail 语义，忽略 --offset）。
    \\  --follow   持续跟随到会话结束。--raw 保留 script(1) 的 "Script started on ..." 头。
    \\  输出为原始终端字节（含 ANSI 转义；重定向到文件时请自行过滤）。
;

pub const help_close =
    \\pty-close <sandboxID> <pid> [--sigterm]
    \\  结束 PTY 会话（默认 SIGKILL，--sigterm 用 SIGTERM）。会话记录文件保留。
;

pub const help_resize =
    \\pty-resize <sandboxID> <pid> --rows=N --cols=N
    \\  调整 PTY 窗口大小（envd process.Process/Update）。
;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "pty-open")) {
        try cmdPtyOpen(c, a);
        return true;
    }
    if (eq(cmd, "pty-write")) {
        try cmdPtyWrite(c, a);
        return true;
    }
    if (eq(cmd, "pty-read")) {
        try cmdPtyRead(c, a);
        return true;
    }
    if (eq(cmd, "pty-close")) {
        try cmdPtyClose(c, a);
        return true;
    }
    if (eq(cmd, "pty-resize")) {
        try cmdPtyResize(c, a);
        return true;
    }
    return false;
}

fn parsePid(c: *Ctx, s: []const u8) !i64 {
    return std.fmt.parseInt(i64, s, 10) catch {
        try c.out.print("pid 必须是数字：{s}\n", .{s});
        return error.BadArg;
    };
}

/// pty-open：script(1) 记录会话 → 断开 → 打印 pid。
fn cmdPtyOpen(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);

    var rows: u64 = 24;
    var cols: u64 = 80;
    if (a.get("rows")) |r| rows = std.fmt.parseInt(u64, r, 10) catch 24;
    if (a.get("cols")) |r| cols = std.fmt.parseInt(u64, r, 10) catch 80;
    const shell = a.get("shell") orelse "/bin/bash";

    const tag = try cmd_proc.newTag(c);
    const log = try std.fmt.allocPrint(c.arena, "{s}/{s}.log", .{ cmd_proc.PTY_DIR, tag });

    const user_envs = try util.envsJson(c.arena, a.flags);
    const envs = if (user_envs.len > 0)
        try std.fmt.allocPrint(c.arena, "\"TERM\":\"xterm-256color\",\"LANG\":\"C.UTF-8\",\"LC_ALL\":\"C.UTF-8\",{s}", .{user_envs})
    else
        "\"TERM\":\"xterm-256color\",\"LANG\":\"C.UTF-8\",\"LC_ALL\":\"C.UTF-8\"";
    const cwd_part = if (a.get("cwd")) |wd|
        try std.fmt.allocPrint(c.arena, ",\"cwd\":\"{s}\"", .{try envd.jsonEscape(c.arena, wd)})
    else
        "";

    const shell_cmd = try std.fmt.allocPrint(c.arena, "{s} -i -l", .{shell});
    const payload = try std.fmt.allocPrint(
        c.arena,
        "{{\"process\":{{\"cmd\":\"/usr/bin/script\",\"args\":[\"-q\",\"-f\",\"-c\",\"{s}\",\"{s}\"],\"envs\":{{{s}}}{s}}},\"pty\":{{\"size\":{{\"rows\":{d},\"cols\":{d}}}}}}}",
        .{ try envd.jsonEscape(c.arena, shell_cmd), try envd.jsonEscape(c.arena, log), envs, cwd_part, rows, cols },
    );

    const res = try envd.startDetached(c.arena, c.client, base, token, a.get("user"), payload, buf);
    if (!res.ok()) {
        try c.out.print("pty 启动失败：HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    const pid: i64 = envd.extractInt(res.body, "pid") orelse {
        try c.out.print("pty 启动失败：未收到 pid\n", .{});
        return error.NoPid;
    };

    const meta = try std.fmt.allocPrint(
        c.arena,
        "{{\"pid\":{d},\"tag\":\"{s}\",\"log\":\"{s}\",\"shell\":\"{s}\"}}",
        .{ pid, tag, log, try envd.jsonEscape(c.arena, shell) },
    );
    cmd_proc.writeMeta(c, base, token, a.get("user"), cmd_proc.PTY_DIR, pid, meta, buf) catch {
        std.debug.print("[pty-open] 警告：会话元信息写入失败，pty-read 可能找不到日志\n", .{});
    };

    try c.out.print("pid {d}\n", .{pid});
    try c.out.print("  会话记录 {s}\n", .{log});
    try c.out.print("  输入 cube-cli pty-write {s} {d} <数据> ｜ 读 cube-cli pty-read {s} {d} --follow ｜ 结束 cube-cli pty-close {s} {d}\n", .{ sid, pid, sid, pid, sid, pid });
    try c.out.print("  提示：会话依赖镜像内的 /usr/bin/script；缺失时会话会立即退出。\n", .{});
}

/// pty-write：SendInput(pty)。
fn cmdPtyWrite(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = try parsePid(c, pid_s);
    if (a.pos.len < 3) {
        try c.out.print("用法：{s}\n", .{help_write});
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
        // 注意：不能直接别名 buf，后续 HTTP 会覆盖它（与 exec-stdin 同类问题）。
        data = try c.arena.dupe(u8, buf[0..total]);
    } else {
        data = a.joinFrom(2, " ");
    }
    if (a.has("enter")) {
        data = try std.fmt.allocPrint(c.arena, "{s}\r", .{data});
    }

    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);
    const res = try envd.sendInput(c.arena, c.client, base, token, a.get("user"), pid, "pty", data, buf);
    if (res.status == 404) {
        try c.out.print("pid {d} 已不存在（会话可能已结束）\n", .{pid});
        return;
    }
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    try c.out.print("sent {d} bytes -> pid {d}\n", .{ data.len, pid });
}

fn stripScriptHeader(data: []const u8) []const u8 {
    if (std.mem.startsWith(u8, data, "Script started on")) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |i| return data[i + 1 ..];
    }
    return data;
}

/// 取最后 n 行（保留行尾换行）。
fn tailLines(data: []const u8, n: u64) []const u8 {
    var count: u64 = 0;
    var i: usize = data.len;
    while (i > 0) {
        i -= 1;
        if (data[i] == '\n') {
            count += 1;
            if (count > n) return data[i + 1 ..];
        }
    }
    return data;
}

/// pty-read：读会话记录（增量）。
fn cmdPtyRead(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = try parsePid(c, pid_s);

    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);

    const meta = cmd_proc.loadMeta(c, base, token, a.get("user"), cmd_proc.PTY_DIR, pid, buf) catch {
        try c.out.print("未找到 pid {d} 的 PTY 会话记录（不是 pty-open 启动的？）\n", .{pid});
        return error.NoMeta;
    };

    const keep_header = a.has("raw");
    const follow = a.has("follow");
    const lines_n: u64 = if (a.get("lines")) |n| (std.fmt.parseInt(u64, n, 10) catch 0) else 0;
    var off: u64 = if (a.get("offset")) |o| (std.fmt.parseInt(u64, o, 10) catch 0) else 0;
    const limit: u64 = if (a.get("limit")) |l| (std.fmt.parseInt(u64, l, 10) catch 0) else 0;

    // tail 模式：一次读全量取末 N 行
    if (lines_n > 0 and !follow) {
        const d = try cmd_proc.readDelta(c, base, token, a.get("user"), meta.log, 0, 0, buf);
        var content = d.data;
        if (!keep_header) content = stripScriptHeader(content);
        try c.out.print("{s}", .{tailLines(content, lines_n)});
        return;
    }

    while (true) {
        const d = try cmd_proc.readDelta(c, base, token, a.get("user"), meta.log, off, limit, buf);
        if (d.data.len > 0) {
            var content = d.data;
            if (off == 0 and !keep_header) content = stripScriptHeader(content);
            try c.out.print("{s}", .{content});
            off = d.next;
        }
        if (!follow) break;
        if (!cmd_proc.pidAlive(c, base, token, a.get("user"), pid, buf)) {
            const d2 = try cmd_proc.readDelta(c, base, token, a.get("user"), meta.log, off, limit, buf);
            if (d2.data.len > 0) {
                try c.out.print("{s}", .{d2.data});
                off = d2.next;
            }
            try c.out.print("\n[pty-read] 会话已结束；日志 {s}（偏移 {d} B）\n", .{ meta.log, off });
            return;
        }
        try std.Io.sleep(c.io, .fromMilliseconds(700), .awake);
    }
    try c.out.print("\n[pty-read] 日志 {s}；已到偏移 {d} B（下次 --offset={d} 继续）\n", .{ meta.log, off, off });
}

/// pty-close：SIGKILL（--sigterm 可选）。
fn cmdPtyClose(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = try parsePid(c, pid_s);
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);
    const sig: []const u8 = if (a.has("sigterm")) "SIGNAL_SIGTERM" else "SIGNAL_SIGKILL";
    const res = try envd.sendSignal(c.arena, c.client, base, token, a.get("user"), pid, sig, buf);
    if (res.status == 404) {
        try c.out.print("pid {d} 已不存在（会话可能已结束）\n", .{pid});
        return;
    }
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    try c.out.print("closed pty pid {d}（{s}）\n", .{ pid, sig });
}

/// pty-resize：Update(pty.size)。
fn cmdPtyResize(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const pid_s = a.at(1) orelse return error.MissingArg;
    const pid = try parsePid(c, pid_s);
    const rows: u64 = if (a.get("rows")) |r| (std.fmt.parseInt(u64, r, 10) catch 24) else 24;
    const cols: u64 = if (a.get("cols")) |r| (std.fmt.parseInt(u64, r, 10) catch 80) else 80;
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);
    const res = try envd.updatePty(c.arena, c.client, base, token, a.get("user"), pid, rows, cols, buf);
    if (res.status == 404) {
        try c.out.print("pid {d} 已不存在（会话可能已结束）\n", .{pid});
        return;
    }
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    try c.out.print("resized pid {d} -> {d}x{d}\n", .{ pid, rows, cols });
}
