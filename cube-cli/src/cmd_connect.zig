//! connect —— 连接沙箱 / 续命（POST /sandboxes/<id>/connect，body {"timeout":N}）。
//!
//! 上游语义（已核实）：`timeout` 是"保证至少还剩 N 秒"——不会缩短已有的更长窗口；
//! 与 `resume`（从现在起开 N 秒新窗口）**不是一回事**，官方 Python SDK 已把 resume 标为
//! deprecated、推荐 connect。`timeout=0` 会被上游 400 拒绝，因此这里显式拒绝 0。
//! exec / code 内部本来就在用它拿 envdAccessToken，这里只是提升为公开命令。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

/// 不指定 --timeout 时的默认续命窗口（秒）。
const default_timeout: u64 = 600;

pub const help =
    \\connect <sandboxID> [--timeout=秒] [--json]
    \\  连接沙箱并保证它至少还剩 N 秒空闲（不会缩短已有的更长窗口）。
    \\  语义与 resume 不同（resume = 从现在起开新窗口）；官方推荐本接口而非 resume。
    \\  --timeout 必须是正整数（上游对 0 返回 400），默认 600 秒。
    \\  --json 原样输出接口 JSON（含 envdAccessToken）。
;

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "connect")) return false;
    try run(c, argv);
    return true;
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);
    const sid = a.at(0) orelse {
        try c.out.print("用法:\n{s}\n", .{help});
        return error.MissingArg;
    };
    var timeout_s: u64 = default_timeout;
    if (a.get("timeout")) |t| {
        timeout_s = std.fmt.parseInt(u64, std.mem.trim(u8, t, " \t"), 10) catch {
            try c.out.print("错误：--timeout 需要正整数秒（收到 {s}）\n", .{t});
            return error.BadArg;
        };
        if (timeout_s == 0) {
            try c.out.print("错误：--timeout 必须 > 0（上游对 timeout=0 返回 400）\n", .{});
            return error.BadArg;
        }
    }
    const body = try std.fmt.allocPrint(c.arena, "{{\"timeout\":{d}}}", .{timeout_s});
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/connect", .{sid});
    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.POST, path, body, buf);

    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    try c.out.print("connected {s}（保证剩余 ≥ {d}s）\n", .{ sid, timeout_s });
}