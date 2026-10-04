//! aiod-cli —— 沙箱内 aiod v2 API 遥控 CLI
//!
//! 约定：所有部署相关取值通过环境变量传入（SANDBOX_BASE / SANDBOX_KEY），
//! 仓库内不含任何主机名、IP 或凭据。
const std = @import("std");
const netfix = @import("netfix.zig");
const cfg = @import("cfg.zig");
const ctxmod = @import("ctx.zig");
const httpc = @import("httpc.zig");
const util = @import("util.zig");

const cmd_exec = @import("cmd_exec.zig");
const cmd_files = @import("cmd_files.zig");
const cmd_pty = @import("cmd_pty.zig");
const cmd_browser = @import("cmd_browser.zig");
const cmd_misc = @import("cmd_misc.zig");
const cmd_cmp = @import("cmd_cmp.zig");
const help = @import("help.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = netfix.install(gpa, threaded.io());

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    const raw = init.args.vector;
    if (raw.len < 2) {
        try help.printTop(out);
        return;
    }
    const argv = try arena.alloc([]const u8, raw.len);
    for (raw, 0..) |a, i| argv[i] = std.mem.span(a);

    const cmd = argv[1];
    const rest = argv[2..];

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try help.printVersion(out);
        return;
    }

    // ---- 帮助体系（必须在 SANDBOX_BASE 检查与 dispatch 之前：帮助不需要环境变量，
    //      且 `<cmd> --help` 绝不能触发真实操作）----
    if (help.isHelpCmd(cmd)) {
        if (rest.len == 0) {
            try help.printTop(out);
            return;
        }
        const topic = rest[0];
        if (eq(topic, "all")) {
            try help.printAll(out);
            return;
        }
        if (help.find(topic)) |e| {
            try help.printOne(out, e);
            return;
        }
        try help.printUnknown(out, topic);
        exitWith(out, 1);
    }
    // `<cmd> --help` / `<cmd> -h` / `<cmd> help`
    for (rest) |a| {
        if (!help.isHelpArg(a)) continue;
        if (help.find(cmd)) |e| {
            try help.printOne(out, e);
            return;
        }
        try help.printUnknown(out, cmd);
        exitWith(out, 1);
    }

    // 未知命令优先报错：不该先抱怨缺环境变量
    if (!help.known(cmd)) {
        try help.printUnknown(out, cmd);
        exitWith(out, 1);
    }

    const base = cfg.sandboxBase() orelse {
        try out.print("错误：缺少环境变量 SANDBOX_BASE（沙箱内 aiod 网关地址）\n", .{});
        try out.print("两种写法都合法：\n", .{});
        try out.print("  带端口的完整网关: https://<网关>/sandbox/<sandboxID>/8080\n", .{});
        try out.print("  沙箱内自测        : http://127.0.0.1:8080\n", .{});
        try out.print("值可用 `cube-cli new` 输出的 [sandbox] AIO 网关那行；末尾多余的 / 会自动去掉。\n", .{});
        try out.print("（`aiod-cli help` 不需要这个变量。）\n", .{});
        exitWith(out, 1);
    };

    var ctx: ctxmod.Ctx = .{
        .io = io,
        .client = &client,
        .arena = arena,
        .out = out,
        .base = trimSlashRight(base),
        .key = cfg.sandboxKey(),
    };

    if (eq(cmd, "health")) {
        try cmdHealth(&ctx);
        return;
    }

    if (try cmd_exec.dispatch(&ctx, cmd, rest)) return;
    if (try cmd_files.dispatch(&ctx, cmd, rest)) return;
    if (try cmd_pty.dispatch(&ctx, cmd, rest)) return;
    if (try cmd_browser.dispatch(&ctx, cmd, rest)) return;
    if (try cmd_misc.dispatch(&ctx, cmd, rest)) return;
    if (try cmd_cmp.dispatch(&ctx, cmd, rest)) return;

    try help.printUnknown(out, cmd);
    exitWith(out, 1);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 打印完立即以指定码退出（process.exit 不跑 defer，所以先 flush）。
fn exitWith(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

/// 去掉末尾的 '/'（0.17 没有 std.mem.trimRight，手写更稳）。
fn trimSlashRight(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and s[e - 1] == '/') e -= 1;
    return s[0..e];
}

fn cmdHealth(c: *ctxmod.Ctx) !void {
    const url = try c.url("/health");
    const buf = try c.arena.alloc(u8, util.BUF);
    var storage: [2]std.http.Header = undefined;
    const res = try httpc.get(c.client, url, util.authHeaders(c, &storage), buf);
    try util.printOrFail(c, res);
}
