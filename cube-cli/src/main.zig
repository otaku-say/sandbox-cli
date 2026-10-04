//! cube-cli —— CubeSandbox 控制面 CLI（Zig）
//!
//! 约定：所有部署取值从环境变量读取，源码内不含任何真实主机名 / IP / 凭据。
//!   CUBESANDBOX_API_URL    控制面地址
//!   CUBESANDBOX_API_KEY    控制面 API Key
//!   CUBESANDBOX_PROXY_URL  数据面网关（exec 等沙箱内操作需要）
const std = @import("std");
const cfg = @import("cfg.zig");
const httpc = @import("httpc.zig");
const ctxmod = @import("ctx.zig");
const envd = @import("envd.zig");
const util = @import("util.zig");
const cmd_template = @import("cmd_template.zig");
const cmd_ports = @import("cmd_ports.zig");
const cmd_files = @import("cmd_files.zig");
const cmd_lifecycle = @import("cmd_lifecycle.zig");

const Ctx = ctxmod.Ctx;
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

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try out.print("cube-cli (zig) {s}\n", .{cfg.version});
        return;
    }
    if (eq(cmd, "help") or eq(cmd, "--help")) {
        try usage(out);
        return;
    }

    var ctx: Ctx = .{
        .arena = arena,
        .client = &client,
        .out = out,
        .io = io,
        .api = cfg.apiURL() orelse {
            try out.print("错误：缺少环境变量 CUBESANDBOX_API_URL\n", .{});
            return error.MissingConfig;
        },
        .key = cfg.apiKey(),
    };

    if (eq(cmd, "health")) return cmdHealth(&ctx);
    if (eq(cmd, "new")) return cmdNew(&ctx, args);
    if (eq(cmd, "ls")) return cmdList(&ctx);
    if (eq(cmd, "rm")) return cmdRemove(&ctx, args);
    if (eq(cmd, "exec")) return cmdExec(&ctx, args);
    if (try cmd_template.dispatch(&ctx, cmd, args)) return;
    if (try cmd_ports.dispatch(&ctx, cmd, args)) return;
    if (try cmd_files.dispatch(&ctx, cmd, args)) return;
    if (try cmd_lifecycle.dispatch(&ctx, cmd, args)) return;

    try out.print("未知命令: {s}\n\n", .{cmd});
    try usage(out);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usage(out: *std.Io.Writer) !void {
    try out.print(
        \\cube-cli (zig) {s} —— CubeSandbox 控制面 CLI
        \\
        \\沙箱:
        \\  cube-cli new --template=<ID> [--timeout=秒] [--note=名称]
        \\  cube-cli ls                    列出沙箱
        \\  cube-cli rm <sandboxID>        销毁沙箱
        \\  cube-cli exec <sandboxID> <命令...> [--cwd=]
        \\
        \\模板:
        \\  cube-cli tpl-ls [--json]       模板列表（含网关端口推断）
        \\  cube-cli tpl-caps [--json]     模板画像：能力 + 端口 + 网关
        \\  cube-cli tpl-pick --need=browser,desktop
        \\
        \\其它:
        \\  cube-cli health | version | help
        \\
    , .{cfg.version});
    try out.print(
        \\环境变量（仓库内不含任何部署信息）:
        \\  CUBESANDBOX_API_URL / CUBESANDBOX_API_KEY / CUBESANDBOX_PROXY_URL
        \\
    , .{});
}

// ---------------- 命令 ----------------

fn cmdHealth(c: *Ctx) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.GET, "/health", null, buf);
    try c.out.print("{s}\n", .{res.body});
}

fn cmdNew(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    const tpl = a.get("template") orelse return error.MissingArg;

    var timeout_part: []const u8 = "";
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(i64, t, 10)) |n| {
            timeout_part = try std.fmt.allocPrint(c.arena, ",\"timeout\":{d}", .{n});
        } else |_| {}
    }
    var note_part: []const u8 = "";
    if (a.get("note")) |n| {
        const e = try envd.jsonEscape(c.arena, n);
        note_part = try std.fmt.allocPrint(c.arena, ",\"metadata\":{{\"note\":\"{s}\"}}", .{e});
    }
    const payload = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\"{s}{s}}}", .{ tpl, timeout_part, note_part });

    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.POST, "/sandboxes", payload, buf);
    const sid = envd.extractString(c.arena, res.body, "sandboxID") orelse {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    try c.out.print("{s}\n", .{sid});

    // 提示网关与端点（查模板详情拿端口，推断 aiod 网关）
    const detail_path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{tpl});
    const dres = c.control(.GET, detail_path, null, buf) catch return;
    const raw_ports = envd.extractString(c.arena, dres.body, "com.exposed_ports") orelse return;
    const ports = cmd_template.parsePorts(c.arena, raw_ports) catch return;
    const gw = cmd_template.guessGateway(ports, "");
    if (gw == 0) return;
    const proxy = cfg.proxyURL() orelse return;
    const base = try std.fmt.allocPrint(c.arena, "{s}/sandbox/{s}", .{ ctxmod.trimSlash(proxy), sid });
    try c.out.print("[sandbox] AIO 网关: {s}/{d}/   ← aio-cli 的 SANDBOX_BASE\n", .{ base, gw });
    try c.out.print("[sandbox] envd    : {s}/49983/\n", .{base});
}

fn cmdList(c: *Ctx) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.GET, "/sandboxes", null, buf);
    // 只摘要输出：ID / 模板 / 状态
    const Field = struct { sandboxID: []const u8 = "", templateID: []const u8 = "", state: []const u8 = "" };
    const parsed = std.json.parseFromSlice([]Field, c.arena, res.body, .{ .ignore_unknown_fields = true }) catch {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    try c.out.print("{s:<34} {s:<34} {s}\n", .{ "沙箱ID", "模板", "状态" });
    for (parsed.value) |s| {
        try c.out.print("{s:<34} {s:<34} {s}\n", .{ s.sandboxID, s.templateID, s.state });
    }
}

fn cmdRemove(c: *Ctx, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingArg;
    const sid = args[0];
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{sid});
    _ = try c.control(.DELETE, path, null, buf);
    try c.out.print("killed {s}\n", .{sid});
}

fn cmdExec(c: *Ctx, args: []const []const u8) !void {
    const a = try util.parse(c.arena, args);
    if (a.pos.len < 2) return error.MissingArg;
    const sid = a.pos[0];
    const command = a.joinFrom(1, " ");

    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const envd_base = try c.envdBase(sid);

    var timeout_ms: u64 = 60_000;
    if (a.get("timeout")) |t| {
        if (std.fmt.parseInt(u64, t, 10)) |n| timeout_ms = n * 1000 else |_| {}
    }

    const res = try envd.exec(c.arena, c.client, envd_base, token, null, command, a.get("cwd"), null, timeout_ms, buf);
    if (res.stdout.len > 0) try c.out.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) try c.out.print("{s}", .{res.stderr});
    if (res.exit_code != 0) try c.out.print("（exit {d}）\n", .{res.exit_code});
}
