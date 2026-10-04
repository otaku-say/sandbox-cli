//! cube-cli —— CubeSandbox 控制面 CLI（Zig）
//!
//! 设计约定：
//!   - 所有部署相关取值（控制面地址、API Key、数据面网关）**一律从环境变量读取**，
//!     源码与仓库内不出现任何真实主机名、IP 或凭据。
//!   - 输出走 stdout（供脚本消费），诊断信息走 stderr。
const std = @import("std");
const cfg = @import("cfg.zig");
const httpc = @import("httpc.zig");

const BUF_SIZE = 1 << 21; // 2 MiB 响应缓冲

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
    const out = &stdout_w.interface; // 取 Io.Writer 接口视图
    defer out.flush() catch {};

    const argv = init.args.vector;
    if (argv.len < 2) {
        try usage(out);
        return;
    }

    const cmd = std.mem.span(argv[1]);

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try out.print("cube-cli (zig) {s}\n", .{cfg.version});
    } else if (eq(cmd, "help") or eq(cmd, "--help")) {
        try usage(out);
    } else if (eq(cmd, "health")) {
        try cmdHealth(arena, &client, out);
    } else if (eq(cmd, "tpl-ls")) {
        try cmdTplLs(arena, &client, out);
    } else {
        try out.print("未知命令: {s}\n\n", .{cmd});
        try usage(out);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usage(out: *std.Io.Writer) !void {
    try out.print(
        \\cube-cli (zig) {s} —— CubeSandbox 控制面 CLI
        \\
        \\用法:
        \\  cube-cli version     版本
        \\  cube-cli health      控制面健康检查
        \\  cube-cli tpl-ls      列出模板
        \\
    , .{cfg.version});
    try out.print(
        \\环境变量（必填，仓库内不含任何部署信息）:
        \\  CUBESANDBOX_API_URL    控制面地址
        \\  CUBESANDBOX_API_KEY    控制面 API Key（如部署未启用鉴权可省略）
        \\  CUBESANDBOX_PROXY_URL  数据面网关（拼沙箱访问 URL 用）
        \\
    , .{});
}

/// 组装鉴权头。存储由调用方提供，保证生命周期覆盖请求。
fn authHeaders(storage: *[1]std.http.Header) httpc.Headers {
    if (cfg.apiKey()) |k| {
        storage[0] = .{ .name = "X-API-KEY", .value = k };
        return storage[0..1];
    }
    return &.{};
}

fn apiBase(out: *std.Io.Writer) ![]const u8 {
    return cfg.apiURL() orelse {
        try out.print("错误：缺少环境变量 CUBESANDBOX_API_URL\n", .{});
        return error.MissingConfig;
    };
}

fn cmdHealth(arena: std.mem.Allocator, client: *std.http.Client, out: *std.Io.Writer) !void {
    const api = try apiBase(out);
    const url = try std.fmt.allocPrint(arena, "{s}/health", .{api});
    const buf = try arena.alloc(u8, BUF_SIZE);

    var storage: [1]std.http.Header = undefined;
    const res = try httpc.get(client, url, authHeaders(&storage), buf);
    if (res.status != 200) {
        try out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    try out.print("{s}\n", .{res.body});
}

const Tpl = struct {
    templateID: []const u8 = "",
    status: []const u8 = "",
    createdAt: []const u8 = "",
    imageInfo: []const u8 = "",
    aliases: []const []const u8 = &.{},
};

fn cmdTplLs(arena: std.mem.Allocator, client: *std.http.Client, out: *std.Io.Writer) !void {
    const api = try apiBase(out);
    const url = try std.fmt.allocPrint(arena, "{s}/templates", .{api});
    const buf = try arena.alloc(u8, BUF_SIZE);

    var storage: [1]std.http.Header = undefined;
    const res = try httpc.get(client, url, authHeaders(&storage), buf);
    if (res.status != 200) {
        try out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }

    const parsed = std.json.parseFromSlice([]Tpl, arena, res.body, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        std.debug.print("JSON 解析失败: {t}\n", .{e});
        return e;
    };

    try out.print("{s:<34} {s:<8} {s}\n", .{ "模板ID", "状态", "镜像" });
    for (parsed.value) |t| {
        try out.print("{s:<34} {s:<8} {s}\n", .{ t.templateID, t.status, basename(t.imageInfo) });
    }
}

fn basename(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}
