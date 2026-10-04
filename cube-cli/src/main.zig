//! cube-cli —— CubeSandbox 控制面 CLI（Zig）
//!
//! 约定：所有部署取值从环境变量读取，源码内不含任何真实主机名 / IP / 凭据。
//!   CUBESANDBOX_API_URL    控制面地址
//!   CUBESANDBOX_API_KEY    控制面 API Key
//!   CUBESANDBOX_PROXY_URL  数据面网关（拼沙箱内服务地址用）
const std = @import("std");
const cfg = @import("cfg.zig");
const httpc = @import("httpc.zig");
const connect = @import("connect.zig");
const envd = @import("envd.zig");

const BUF = 2 << 20;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    const argv_raw = init.args.vector;
    if (argv_raw.len < 2) {
        try usage(out);
        return;
    }
    const argv = try arena.alloc([]const u8, argv_raw.len);
    for (argv_raw, 0..) |a, i| argv[i] = std.mem.span(a);
    const cmd = argv[1];
    const args = argv[2..];

    var ctx: Ctx = .{
        .arena = arena,
        .client = &client,
        .out = out,
        .api = cfg.apiURL() orelse {
            try out.print("错误：缺少环境变量 CUBESANDBOX_API_URL\n", .{});
            return error.MissingConfig;
        },
        .key = cfg.apiKey(),
    };

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try out.print("cube-cli (zig) {s}\n", .{cfg.version});
        return;
    }
    if (eq(cmd, "help") or eq(cmd, "--help")) {
        try usage(out);
        return;
    }
    if (eq(cmd, "health")) {
        return cmdHealth(&ctx);
    }
    if (eq(cmd, "new")) {
        return cmdNew(&ctx, args);
    }
    if (eq(cmd, "ls")) {
        return cmdList(&ctx);
    }
    if (eq(cmd, "rm")) {
        return cmdRemove(&ctx, args);
    }
    if (eq(cmd, "exec")) {
        return cmdExec(&ctx, args);
    }

    try out.print("未知命令: {s}\n\n", .{cmd});
    try usage(out);
}

const Ctx = struct {
    arena: std.mem.Allocator,
    client: *std.http.Client,
    out: *std.Io.Writer,
    api: []const u8,
    key: ?[]const u8,
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn trimSlashRight(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and s[e - 1] == '/') e -= 1;
    return s[0..e];
}

fn usage(out: *std.Io.Writer) !void {
    try out.print(
        \\cube-cli (zig) {s} —— CubeSandbox 控制面 CLI
        \\
        \\用法:
        \\  cube-cli version                     版本
        \\  cube-cli health                      控制面健康检查
        \\  cube-cli new [--template=] [--need=] [--timeout=秒] [--note=名称]
        \\  cube-cli ls                          列出沙箱
        \\  cube-cli rm <sandboxID>              销毁沙箱
        \\  cube-cli exec <sandboxID> <命令...> [--cwd=] [--timeout=秒]
        \\
    , .{cfg.version});
    try out.print(
        \\环境变量（必填，仓库内不含任何部署信息）:
        \\  CUBESANDBOX_API_URL     控制面地址
        \\  CUBESANDBOX_API_KEY     控制面 API Key
        \\  CUBESANDBOX_PROXY_URL   数据面网关（exec 等沙箱内操作需要）
        \\
    , .{});
}

// ---------------- 控制面 HTTP ----------------

fn controlHeaders(c: *Ctx, storage: *[2]std.http.Header) httpc.Headers {
    var n: usize = 0;
    storage[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (c.key) |k| {
        storage[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return storage[0..n];
}

fn controlJsonHeaders(c: *Ctx, storage: *[3]std.http.Header) httpc.Headers {
    var n: usize = 0;
    storage[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    storage[n] = httpc.json_ct;
    n += 1;
    if (c.key) |k| {
        storage[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return storage[0..n];
}

/// 发控制面请求，把响应体放到 buf；非 2xx 时打印并报错。
fn control(c: *Ctx, method: httpc.Method, path: []const u8, payload: ?[]const u8, buf: []u8) !httpc.Response {
    const url = try std.fmt.allocPrint(c.arena, "{s}{s}", .{ trimSlashRight(c.api), path });
    var hs: [3]std.http.Header = undefined;
    const headers = if (payload == null) controlHeaders(c, hs[0..2]) else controlJsonHeaders(c, hs[0..3]);
    const res = try httpc.request(c.client, method, url, headers, payload, buf);
    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    return res;
}

// ---------------- 命令 ----------------

fn cmdHealth(c: *Ctx) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try control(c, .GET, "/health", null, buf);
    try c.out.print("{s}\n", .{res.body});
}

fn cmdNew(c: *Ctx, args: []const []const u8) !void {
    // 解析 --template= / --timeout= / --note=
    var template: ?[]const u8 = null;
    var timeout_s: i64 = 0;
    var note: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--template=")) template = a["--template=".len..];
        if (std.mem.startsWith(u8, a, "--timeout=")) timeout_s = std.fmt.parseInt(i64, a["--timeout=".len..], 10) catch 0;
        if (std.mem.startsWith(u8, a, "--note=")) note = a["--note=".len..];
    }
    const tpl = template orelse return error.MissingArg;

    var timeout_part: []const u8 = "";
    if (timeout_s > 0) {
        timeout_part = try std.fmt.allocPrint(c.arena, ",\"timeout\":{d}", .{timeout_s});
    }
    var note_part: []const u8 = "";
    if (note) |n| {
        const e = try envd.jsonEscape(c.arena, n);
        note_part = try std.fmt.allocPrint(c.arena, ",\"metadata\":{{\"note\":\"{s}\"}}", .{e});
    }
    const payload = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\"{s}{s}}}", .{ tpl, timeout_part, note_part });

    const buf = try c.arena.alloc(u8, BUF);
    const res = try control(c, .POST, "/sandboxes", payload, buf);
    // 响应含 sandboxID 与 envdAccessToken
    const sid = extractB64Field(c.arena, res.body, "sandboxID") orelse {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    try c.out.print("{s}\n", .{sid});
}

fn cmdList(c: *Ctx) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try control(c, .GET, "/sandboxes", null, buf);
    try c.out.print("{s}\n", .{res.body});
}

fn cmdRemove(c: *Ctx, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingArg;
    const sid = args[0];
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{sid});
    _ = try control(c, .DELETE, path, null, buf);
    try c.out.print("killed {s}\n", .{sid});
}

fn cmdExec(c: *Ctx, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingArg;
    const sid = args[0];
    var command: []const u8 = args[1];
    for (args[2..]) |a| {
        command = try std.fmt.allocPrint(c.arena, "{s} {s}", .{ command, a });
    }

    var cwd: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--cwd=")) cwd = a["--cwd=".len..];
    }

    // ① connect 拿凭证
    const buf = try c.arena.alloc(u8, BUF);
    const conn_path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/connect", .{sid});
    const conn = try control(c, .POST, conn_path, "{}", buf);
    const token = extractB64Field(c.arena, conn.body, "envdAccessToken");

    // ② envd 地址（数据面路径风格）
    const proxy = cfg.proxyURL() orelse {
        try c.out.print("错误：缺少环境变量 CUBESANDBOX_PROXY_URL\n", .{});
        return error.MissingConfig;
    };
    const envd_base = try std.fmt.allocPrint(c.arena, "{s}/sandbox/{s}/49983", .{ trimSlashRight(proxy), sid });

    // ③ 执行
    const res = try envd.exec(c.arena, c.client, envd_base, token, null, command, cwd, null, 60_000, buf);
    if (res.stdout.len > 0) try c.out.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) try c.out.print("{s}", .{res.stderr});
    if (res.exit_code != 0) {
        try c.out.print("（exit {d}）\n", .{res.exit_code});
    }
}

/// 从 JSON 片段里取字符串字段的原始值。
fn extractB64Field(arena: std.mem.Allocator, payload: []const u8, field: []const u8) ?[]const u8 {
    const pat = std.fmt.allocPrint(arena, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, payload, pat) orelse return null;
    const s0 = start + pat.len;
    const end = std.mem.indexOfPos(u8, payload, s0, "\"") orelse return null;
    return payload[s0..end];
}
