//! health —— 平台健康检查（GET /health → {status, sandboxes}）。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const jsonfmt = @import("jsonfmt.zig");
const sdkmod = @import("sdk.zig");
const sdk_lifecycle = @import("sdk_lifecycle.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

pub const help =
    \\health [--json]
    \\  平台健康检查。默认打印 "状态: ok · 沙箱数: N"，--json 原样输出接口 JSON。
;

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "health")) return false;
    try run(c, argv);
    return true;
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);
    var s = sdkmod.Sdk.fromCtx(c);
    const body = sdk_lifecycle.systemHealth(&s) catch |e| {
        try s.printErr(c.out, e);
        return e;
    };
    if (a.has("json")) {
        try c.out.print("{s}\n", .{body});
        return;
    }
    const v = std.json.parseFromSlice(std.json.Value, c.arena, body, .{}) catch {
        try c.out.print("{s}\n", .{body});
        return;
    };
    const status = if (jsonfmt.objGet(v.value, "status")) |st| (jsonfmt.valueStr(c.arena, st) catch "-") else "-";
    const count_s = if (jsonfmt.objGet(v.value, "sandboxes")) |sb| blk: {
        const sv = sb;
        if (sv == .integer) {
            break :blk std.fmt.allocPrint(c.arena, "{d}", .{sv.integer}) catch "-";
        }
        if (sv == .array) {
            break :blk std.fmt.allocPrint(c.arena, "{d}", .{sv.array.items.len}) catch "-";
        }
        break :blk jsonfmt.valueStr(c.arena, sv) catch "-";
    } else "-";
    try c.out.print("状态: {s} · 沙箱数: {s}\n", .{ status, count_s });
}