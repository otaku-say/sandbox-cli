//! ls —— 沙箱列表（v1 /v2 双通道 + metadata·state·limit 过滤）。
//!
//!   GET /sandboxes?metadata=<k=v>            v1（服务端硬编码 limit=200）
//!   GET /v2/sandboxes?metadata=&state=&limit=
//!
//! 注意：上游 v2 的 nextToken 是桩实现（接收即丢弃、也不返回 x-next-token），
//! 因此这里不做翻页；万一响应真带了 x-next-token，只在 stderr 提示，不假装能续拉。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const jsonfmt = @import("jsonfmt.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

pub const help =
    \\ls [--metadata=k=v] [--state=running|paused|...] [--limit=N] [--v2] [--json]
    \\  列出沙箱（ID / 模板 / 状态 / 备注；备注取 metadata.note，回落 metadata.agent）。
    \\  --metadata 可重复或逗号分隔（v1 服务端固定 limit=200；--limit 只对 --v2 生效）。
    \\  --state 只能走 v2（自动切换并提示）。
    \\  --json 原样输出接口 JSON。上游分页为桩实现，不提供翻页。
;

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "ls")) return false;
    try run(c, argv);
    return true;
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);

    var use_v2 = a.has("v2");
    if (a.get("state") != null and !use_v2) {
        use_v2 = true;
        std.debug.print("[ls] --state 只有 v2 支持，已自动切到 /v2/sandboxes\n", .{});
    }
    if (a.get("limit") != null and !use_v2 and a.get("metadata") == null) {
        // v1 的 limit 由服务端硬编码，显式给了 --limit 就走 v2
        use_v2 = true;
    }

    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 4096));
    var n: usize = 0;
    // metadata 过滤：可重复给 --metadata，也可逗号分隔
    for (a.flags) |kv| {
        if (!std.mem.eql(u8, kv[0], "metadata")) continue;
        var it = std.mem.tokenizeScalar(u8, kv[1], ',');
        while (it.next()) |kv2| {
            if (kv2.len == 0) continue;
            if (n > 0) try w.writeAll("&");
            n += 1;
            try w.print("metadata={s}", .{try jsonfmt.qenc(c.arena, kv2, true)});
        }
    }
    if (a.get("state")) |s| {
        if (n > 0) try w.writeAll("&");
        n += 1;
        try w.print("state={s}", .{try jsonfmt.qenc(c.arena, s, false)});
    }
    if (use_v2) {
        if (a.get("limit")) |l| {
            if (n > 0) try w.writeAll("&");
            n += 1;
            try w.print("limit={s}", .{l});
        }
    } else if (a.get("limit")) |l| {
        std.debug.print("[ls] 提示：v1 的 limit 由服务端固定为 200，--limit={s} 未生效\n", .{l});
    }

    const path = if (n > 0)
        try std.fmt.allocPrint(c.arena, "{s}?{s}", .{ if (use_v2) "/v2/sandboxes" else "/sandboxes", w.buffered() })
    else
        (if (use_v2) "/v2/sandboxes" else "/sandboxes");

    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.control(.GET, path, null, buf);

    if (res.header("x-next-token")) |t| {
        if (t.len > 0) std.debug.print("[ls] x-next-token={s}（上游分页为桩实现，未继续翻页）\n", .{t});
    }

    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }

    // v1 返回裸数组；v2 可能包一层 {"sandboxes":[...]} —— 两种都吃
    const v = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    var items: []const std.json.Value = &.{};
    switch (v.value) {
        .array => |arr| items = arr.items,
        .object => |o| {
            if (o.get("sandboxes")) |sv| {
                if (sv == .array) items = sv.array.items;
            }
        },
        else => {},
    }
    try c.out.print("{s:<34} {s:<34} {s:<10} {s}\n", .{ "沙箱ID", "模板", "状态", "备注" });
    for (items) |item| {
        const id = if (jsonfmt.objGet(item, "sandboxID")) |x| jsonfmt.valueStr(c.arena, x) catch "-" else "-";
        const tpl = if (jsonfmt.objGet(item, "templateID")) |x| jsonfmt.valueStr(c.arena, x) catch "-" else "-";
        const st = if (jsonfmt.objGet(item, "state")) |x| jsonfmt.valueStr(c.arena, x) catch "-" else "-";
        var label: []const u8 = "-";
        if (jsonfmt.objGet(item, "metadata")) |mv| {
            if (mv == .object) {
                if (mv.object.get("note")) |x| {
                    label = jsonfmt.valueStr(c.arena, x) catch "-";
                } else if (mv.object.get("agent")) |x| {
                    label = jsonfmt.valueStr(c.arena, x) catch "-";
                }
            }
        }
        try c.out.print("{s:<34} {s:<34} {s:<10} {s}\n", .{ id, tpl, st, label });
    }
    try c.out.print("共 {d} 个\n", .{items.len});
}