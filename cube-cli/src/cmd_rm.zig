//! rm —— 销毁沙箱（DELETE /sandboxes/<id>），对生命周期互斥做重试。
//!
//! 上游事实：DELETE 可能返回 503 + `Retry-After: 2`（生命周期操作互斥，等 2 秒重试）；
//! 404 = 已经不存在（幂等成功）；408/409 同属瞬态/互斥，一并重试。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

/// 首次尝试之外最多重试 3 次。
const max_retries: u32 = 3;

pub const help =
    \\rm <sandboxID>
    \\  销毁沙箱。404 视为已删除（幂等，返回 0）；
    \\  503 + Retry-After / 409 / 408 按 Retry-After（缺省 2 秒）最多重试 3 次。
;

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "rm")) return false;
    try run(c, argv);
    return true;
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);
    const sid = a.at(0) orelse {
        try c.out.print("用法:\n{s}\n", .{help});
        return error.MissingArg;
    };
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}", .{sid});

    var attempt: u32 = 0;
    while (true) {
        const res = try c.controlRaw(.DELETE, path, null, &.{}, buf);
        if (res.ok()) {
            try c.out.print("killed {s}\n", .{sid});
            return;
        }
        if (res.status == 404) {
            try c.out.print("already gone {s}\n", .{sid});
            return;
        }
        const he = c.last_error;
        if (he.retryable() and attempt < max_retries) {
            const wait_s = he.retryAfter(2);
            std.debug.print("[rm] HTTP {d}（{d} 秒后重试，{d}/{d}）\n", .{ he.status, wait_s, attempt + 1, max_retries });
            if (wait_s > 0) try std.Io.sleep(c.io, .fromSeconds(@intCast(wait_s)), .awake);
            attempt += 1;
            continue;
        }
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
}