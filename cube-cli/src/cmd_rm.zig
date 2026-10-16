//! rm —— 销毁沙箱（DELETE /sandboxes/<id>），对生命周期互斥做重试。
//!
//! 上游事实：DELETE 可能返回 503 + `Retry-After: 2`（生命周期操作互斥，等 2 秒重试）；
//! 404 = 已经不存在（幂等成功）；408/409 同属瞬态/互斥，一并重试。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const sdkmod = @import("sdk.zig");
const sdk_lifecycle = @import("sdk_lifecycle.zig");

const Ctx = ctxmod.Ctx;

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
    var s = sdkmod.Sdk.fromCtx(c);
    const res = sdk_lifecycle.sandboxDelete(&s, sid, true) catch |e| {
        try s.printErr(c.out, e);
        return e;
    };
    switch (res) {
        .deleted => try c.out.print("killed {s}\n", .{sid}),
        .already_gone => try c.out.print("already gone {s}\n", .{sid}),
    }
}