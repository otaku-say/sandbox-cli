//! logs —— 沙箱日志（默认 v1，--v2 走 v2 结构化日志，--follow 用 v2 cursor 轮询）。
//!
//!   GET /sandboxes/<id>/logs?start=&limit=      → {logs:[{line,timestamp}], logEntries:[{level,message,timestamp,fields}]}
//!   GET /v2/sandboxes/<id>/logs?cursor=&limit=&direction= → 结构化 level/message/fields
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const jsonfmt = @import("jsonfmt.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

pub const help =
    \\logs <sandboxID> [--tail=N] [--start=时间] [--limit=N] [--v2] [--cursor=游标]
    \\      [--direction=forward|backward] [--level=info|warn|error] [--follow] [--timeout=秒] [--json]
    \\  沙箱日志。默认走 v1；--v2 走 v2 结构化日志并支持 --level 过滤。
    \\  --tail=N 等价于 --limit=N（取末尾 N 条）；--follow 用 v2 的 cursor+direction 轮询。
    \\  --json 原样输出接口 JSON；--timeout 只对 --follow 生效（默认不限，Ctrl-C 退出）。
;

const Entry = struct {
    level: ?[]const u8 = null,
    message: ?[]const u8 = null,
    line: ?[]const u8 = null,
    timestamp: ?[]const u8 = null,
    fields: ?std.json.Value = null,
};

const LogsResp = struct {
    logs: ?[]Entry = null,
    logEntries: ?[]Entry = null,
    nextCursor: ?[]const u8 = null,
};

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "logs")) return false;
    try run(c, argv);
    return true;
}

fn levelMatch(level: ?[]const u8, want: ?[]const u8) bool {
    const w = want orelse return true;
    const l = level orelse return false;
    return std.ascii.eqlIgnoreCase(l, w);
}

fn printEntry(c: *Ctx, e: Entry, as_json: bool) !void {
    if (as_json) return;
    const lv = e.level orelse "-";
    const ts = e.timestamp orelse "-";
    const msg = e.message orelse e.line orelse "";
    try c.out.print("[{s}] {s} {s}", .{ lv, ts, msg });
    if (e.fields) |f| {
        if (f != .null) {
            const s = jsonfmt.valueStr(c.arena, f) catch "";
            if (s.len > 0 and !std.mem.eql(u8, s, "-")) try c.out.print("  {s}", .{s});
        }
    }
    try c.out.writeAll("\n");
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);
    const sid = a.at(0) orelse {
        try c.out.print("用法:\n{s}\n", .{help});
        return error.MissingArg;
    };
    const want_level = a.get("level");
    const as_json = a.has("json");
    const limit_n: ?u64 = blk: {
        if (a.get("tail")) |v| break :blk std.fmt.parseInt(u64, v, 10) catch null;
        if (a.get("limit")) |v| break :blk std.fmt.parseInt(u64, v, 10) catch null;
        break :blk null;
    };
    const follow = a.has("follow");
    const use_v2 = a.has("v2") or follow;

    var cursor: ?[]const u8 = a.get("cursor");
    const direction = a.get("direction") orelse (if (a.has("cursor")) "backward" else "forward");

    if (!use_v2) {
        var path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/logs", .{sid});
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 512));
        var n: usize = 0;
        if (a.get("start")) |s| {
            try w.print("start={s}", .{s});
            n += 1;
        }
        if (limit_n) |l| {
            if (n > 0) try w.writeAll("&");
            try w.print("limit={d}", .{l});
            n += 1;
        }
        if (n > 0) path = try std.fmt.allocPrint(c.arena, "{s}?{s}", .{ path, w.buffered() });

        const buf = try c.arena.alloc(u8, BUF);
        const res = try c.control(.GET, path, null, buf);
        if (as_json) {
            try c.out.print("{s}\n", .{res.body});
            return;
        }
        const parsed = std.json.parseFromSlice(LogsResp, c.arena, res.body, .{ .ignore_unknown_fields = true }) catch {
            try c.out.print("{s}\n", .{res.body});
            return;
        };
        var printed: usize = 0;
        if (parsed.value.logs) |ls| {
            for (ls) |e| {
                // v1 纯文本行没有 level；指定 --level 时无法判定，跳过
                if (want_level != null) continue;
                try printEntry(c, e, false);
                printed += 1;
            }
        }
        if (parsed.value.logEntries) |es| {
            for (es) |e| {
                if (!levelMatch(e.level, want_level)) continue;
                try printEntry(c, e, false);
                printed += 1;
            }
        }
        if (printed == 0 and parsed.value.logs == null and parsed.value.logEntries == null) {
            try c.out.print("{s}\n", .{res.body});
        }
        return;
    }

    // v2（含 --follow）
    var deadline_s: u64 = 0; // 0 = 不限
    if (a.get("timeout")) |t| deadline_s = std.fmt.parseInt(u64, t, 10) catch 0;
    const buf = try c.arena.alloc(u8, BUF);
    var waited: u64 = 0;
    while (true) {
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 512));
        if (cursor) |cu| try w.print("cursor={s}", .{try jsonfmt.qenc(c.arena, cu, false)});
        if (limit_n) |l| {
            if (w.buffered().len > 0) try w.writeAll("&");
            try w.print("limit={d}", .{l});
        }
        if (w.buffered().len > 0) try w.writeAll("&");
        try w.print("direction={s}", .{direction});
        const path = try std.fmt.allocPrint(c.arena, "/v2/sandboxes/{s}/logs?{s}", .{ sid, w.buffered() });
        const res = try c.control(.GET, path, null, buf);
        if (as_json) try c.out.print("{s}\n", .{res.body});

        const parsed = std.json.parseFromSlice(LogsResp, c.arena, res.body, .{ .ignore_unknown_fields = true }) catch {
            try c.out.print("{s}\n", .{res.body});
            return;
        };
        const entries = parsed.value.logEntries orelse parsed.value.logs orelse &[_]Entry{};
        for (entries) |e| {
            if (!levelMatch(e.level, want_level)) continue;
            try printEntry(c, e, as_json);
        }
        if (parsed.value.nextCursor) |cu| cursor = cu;

        if (!follow) return;
        if (deadline_s > 0 and waited >= deadline_s) {
            std.debug.print("[logs] --timeout {d}s 到，停止跟随\n", .{deadline_s});
            return;
        }
        try c.out.flush();
        try std.Io.sleep(c.io, .fromSeconds(2), .awake);
        waited += 2;
    }
}