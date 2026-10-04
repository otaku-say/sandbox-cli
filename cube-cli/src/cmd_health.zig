//! health —— 平台健康检查（GET /health → {status, sandboxes}）。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const jsonfmt = @import("jsonfmt.zig");

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
    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.GET, "/health", null, buf);
    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    const v = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    const status = if (jsonfmt.objGet(v.value, "status")) |s| (jsonfmt.valueStr(c.arena, s) catch "-") else "-";
    const count_s = if (jsonfmt.objGet(v.value, "sandboxes")) |s| blk: {
        const sv = s;
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