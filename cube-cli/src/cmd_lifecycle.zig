//! 生命周期 / 快照 / 持久卷（全部走控制面 REST）
//!
//!   POST   /sandboxes/<id>/pause              暂停（挂起快照，0 成本）
//!   POST   /sandboxes/<id>/resume            恢复（body 可带 timeout）
//!   POST   /sandboxes/<id>/timeout           设置空闲超时
//!   POST   /sandboxes/<id>/refreshes         续期（新增时间窗）
//!   POST   /sandboxes/<id>/snapshots         打快照
//!   GET    /snapshots                        快照列表
//!   POST   /sandboxes/<id>/rollback          回滚到快照
//!   DELETE /templates/<snapshotID>           删除快照（官方刻意未开 /snapshots/{id} DELETE）
//!   GET/POST/DELETE /volumes                 持久卷
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

fn sidOf(a: util.Args) ![]const u8 {
    return a.at(0) orelse error.MissingArg;
}

fn post(c: *Ctx, path: []const u8, body: []const u8, msg: []const u8, arg: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    _ = try c.control(.POST, path, body, buf);
    try c.out.print("{s} {s}\n", .{ msg, arg });
}

/// pause <sid>
fn cmdPause(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/pause", .{sid});
    try post(c, path, "{}", "paused", sid);
}

/// resume <sid> [--timeout=秒]
fn cmdResume(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/resume", .{sid});
    var body: []const u8 = "{}";
    if (a.get("timeout")) |t| {
        body = try std.fmt.allocPrint(c.arena, "{{\"timeout\":{s}}}", .{t});
    }
    try post(c, path, body, "resumed", sid);
}

/// timeout <sid> <秒>   （-1 = 永不回收）
fn cmdTimeout(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const secs = a.at(1) orelse return error.MissingArg;
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/timeout", .{sid});
    const body = try std.fmt.allocPrint(c.arena, "{{\"timeout\":{s}}}", .{secs});
    try post(c, path, body, "timeout set", sid);
}

/// refresh <sid> <秒>   （续期：新增时间窗）
fn cmdRefresh(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const secs = a.at(1) orelse return error.MissingArg;
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/refreshes", .{sid});
    const body = try std.fmt.allocPrint(c.arena, "{{\"duration\":{s}}}", .{secs});
    try post(c, path, body, "refreshed", sid);
}

/// snap <sid> [--name=名称]
fn cmdSnap(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/snapshots", .{sid});
    var body: []const u8 = "{}";
    if (a.get("name")) |n| {
        body = try std.fmt.allocPrint(c.arena, "{{\"name\":\"{s}\"}}", .{try envd.jsonEscape(c.arena, n)});
    }
    const res = try c.control(.POST, path, body, buf);
    // 尽量提取 snapshotID
    if (envd.extractString(c.arena, res.body, "snapshotID")) |id| {
        try c.out.print("{s}\n", .{id});
    } else {
        try c.out.print("{s}\n", .{res.body});
    }
}

/// snap-ls [--sandbox=sid] [--limit=N]
fn cmdSnapLs(c: *Ctx, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, BUF);
    var path: []const u8 = "/snapshots";
    if (a.get("sandbox")) |s| {
        path = try std.fmt.allocPrint(c.arena, "/snapshots?sandboxID={s}", .{s});
    }
    const res = try c.control(.GET, path, null, buf);
    try c.out.print("{s}\n", .{res.body});
}

/// snap-rm <snapshotID>   —— 走模板删除接口
fn cmdSnapRm(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const path = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{id});
    _ = try c.control(.DELETE, path, null, buf);
    try c.out.print("snapshot removed {s}\n", .{id});
}

/// rollback <sid> <snapshotID>
fn cmdRollback(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const snap = a.at(1) orelse return error.MissingArg;
    const path = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/rollback", .{sid});
    const body = try std.fmt.allocPrint(c.arena, "{{\"snapshotID\":\"{s}\"}}", .{snap});
    try post(c, path, body, "rolled back", sid);
}

/// clone <sid> [-n=数量]  —— 快照作模板批量克隆（简单串行实现）
fn cmdClone(c: *Ctx, a: util.Args) !void {
    const sid = try sidOf(a);
    const buf = try c.arena.alloc(u8, BUF);
    var n: usize = 1;
    if (a.get("n")) |v| {
        n = std.fmt.parseInt(usize, v, 10) catch 1;
    }
    // ① 打快照
    const spath = try std.fmt.allocPrint(c.arena, "/sandboxes/{s}/snapshots", .{sid});
    const sres = try c.control(.POST, spath, "{}", buf);
    const snap = envd.extractString(c.arena, sres.body, "snapshotID") orelse {
        try c.out.print("快照创建失败: {s}\n", .{sres.body});
        return error.SnapshotFailed;
    };
    // ② 用快照当模板建 n 个
    for (0..n) |i| {
        const body = try std.fmt.allocPrint(c.arena, "{{\"templateID\":\"{s}\"}}", .{snap});
        const res = try c.control(.POST, "/sandboxes", body, buf);
        if (envd.extractString(c.arena, res.body, "sandboxID")) |newid| {
            try c.out.print("{s}\n", .{newid});
        }
        _ = i;
    }
    // ③ 清理快照
    const dpath = try std.fmt.allocPrint(c.arena, "/templates/{s}", .{snap});
    _ = c.control(.DELETE, dpath, null, buf) catch {};
}

/// vol-ls / vol-new <名字> / vol-rm <卷ID>
fn cmdVol(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, BUF);
    if (std.mem.eql(u8, cmd, "vol-ls")) {
        const res = try c.control(.GET, "/volumes", null, buf);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    if (std.mem.eql(u8, cmd, "vol-new")) {
        const name = a.at(0) orelse return error.MissingArg;
        const body = try std.fmt.allocPrint(c.arena, "{{\"name\":\"{s}\"}}", .{try envd.jsonEscape(c.arena, name)});
        const res = try c.control(.POST, "/volumes", body, buf);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    if (std.mem.eql(u8, cmd, "vol-info")) {
        const id = a.at(0) orelse return error.MissingArg;
        const path = try std.fmt.allocPrint(c.arena, "/volumes/{s}", .{id});
        const res = try c.control(.GET, path, null, buf);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    if (std.mem.eql(u8, cmd, "vol-rm")) {
        const id = a.at(0) orelse return error.MissingArg;
        const path = try std.fmt.allocPrint(c.arena, "/volumes/{s}", .{id});
        _ = try c.control(.DELETE, path, null, buf);
        try c.out.print("volume removed {s}\n", .{id});
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "pause")) {
        try cmdPause(c, a);
        return true;
    }
    if (eq(cmd, "resume")) {
        try cmdResume(c, a);
        return true;
    }
    if (eq(cmd, "timeout")) {
        try cmdTimeout(c, a);
        return true;
    }
    if (eq(cmd, "refresh")) {
        try cmdRefresh(c, a);
        return true;
    }
    if (eq(cmd, "snap")) {
        try cmdSnap(c, a);
        return true;
    }
    if (eq(cmd, "snap-ls")) {
        try cmdSnapLs(c, a);
        return true;
    }
    if (eq(cmd, "snap-rm")) {
        try cmdSnapRm(c, a);
        return true;
    }
    if (eq(cmd, "rollback")) {
        try cmdRollback(c, a);
        return true;
    }
    if (eq(cmd, "clone")) {
        try cmdClone(c, a);
        return true;
    }
    if (eq(cmd, "vol-ls") or eq(cmd, "vol-new") or eq(cmd, "vol-info") or eq(cmd, "vol-rm")) {
        try cmdVol(c, cmd, a);
        return true;
    }
    return false;
}
