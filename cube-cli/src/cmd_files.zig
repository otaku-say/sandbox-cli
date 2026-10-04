//! 文件操作：cat / read / write / ls / stat / mkdir / rm / mv
//!
//! 走 envd：
//!   GET  /files?path=<p>                    读文件（响应即内容）
//!   POST /files?path=<p>                    写文件（body 为内容）
//!   POST /filesystem.Filesystem/<Method>    列目录 / stat / 删除 / 移动 / 建目录（纯 JSON）
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");
const envd = @import("envd.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

const FileEntry = struct {
    name: []const u8 = "",
    type: []const u8 = "",
    path: []const u8 = "",
    size: []const u8 = "0", // 服务端以字符串返回
    permissions: []const u8 = "",
    owner: []const u8 = "",
    group: []const u8 = "",
    modifiedTime: []const u8 = "",
};

fn isDir(t: []const u8) bool {
    return std.mem.endsWith(u8, t, "DIRECTORY");
}

/// 准备 sid / token / envd 基址（各文件命令通用）。
const Target = struct { sid: []const u8, token: ?[]const u8, base: []const u8, buf: []u8 };

fn target(c: *Ctx, sid: []const u8) !Target {
    const buf = try c.arena.alloc(u8, BUF);
    const token = try c.connectToken(sid, buf);
    const base = try c.envdBase(sid);
    return .{ .sid = sid, .token = token, .base = base, .buf = buf };
}

fn jsonPath(c: *Ctx, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{try envd.jsonEscape(c.arena, path)});
}

fn fail(c: *Ctx, res: httpc.Response) !void {
    try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
    return error.HttpError;
}

/// cat <sid> <path>  —— 输出文件内容
fn cmdCat(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const path = a.at(1) orelse return error.MissingArg;
    const t = try target(c, sid);
    const res = try envd.readFile(c.arena, c.client, t.base, t.token, a.get("user"), path, t.buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}", .{res.body});
}

/// write <sid> <本地文件|-> <远端路径>  —— 从本地（或 stdin）写入远端
fn cmdWrite(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const local = a.at(1) orelse return error.MissingArg;
    const remote = a.at(2) orelse return error.MissingArg;

    var data: []const u8 = "";
    if (std.mem.eql(u8, local, "-")) {
        // 从 stdin 读到 EOF（上限 8 MiB）
        const buf = try c.arena.alloc(u8, BUF);
        var rbuf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().reader(c.io, &rbuf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = r.interface.readSliceShort(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        data = buf[0..total];
    } else {
        data = try readLocalFile(c.io, c.arena, local);
    }

    const t = try target(c, sid);
    const res = try envd.writeFile(c.arena, c.client, t.base, t.token, a.get("user"), remote, data, t.buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("wrote {d} bytes -> {s}\n", .{ data.len, remote });
}

fn readLocalFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, arena, .limited(BUF)) catch |e| return e;
}

/// ls <sid> <path>
fn cmdLs(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const path = a.at(1) orelse "/";
    const t = try target(c, sid);
    const body = try jsonPath(c, path);
    const res = try envd.fsRPC(c.arena, c.client, t.base, t.token, a.get("user"), "ListDir", body, t.buf);
    if (!res.ok()) return fail(c, res);

    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    const entries = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("entries")) |e| {
                if (e == .array) break :blk e.array.items;
            }
        }
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    try c.out.print("{s:<10} {s:<12} {s:<9} {s}\n", .{ "类型", "大小", "权限", "名称" });
    for (entries) |e| {
        if (e != .object) continue;
        const kind: []const u8 = if (e.object.get("type")) |t2| (if (t2 == .string and isDir(t2.string)) "dir" else "file") else "?";
        const size: []const u8 = if (e.object.get("size")) |s2| (if (s2 == .string) s2.string else "0") else "0";
        const perm: []const u8 = if (e.object.get("permissions")) |p| (if (p == .string) p.string else "") else "";
        const name: []const u8 = if (e.object.get("name")) |nm| (if (nm == .string) nm.string else "") else "";
        try c.out.print("{s:<10} {s:<12} {s:<9} {s}\n", .{ kind, size, perm, name });
    }
}

/// stat <sid> <path>
fn cmdStat(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const path = a.at(1) orelse return error.MissingArg;
    const t = try target(c, sid);
    const body = try jsonPath(c, path);
    const res = try envd.fsRPC(c.arena, c.client, t.base, t.token, a.get("user"), "Stat", body, t.buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

/// mkdir <sid> <path>
fn cmdMkdir(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const path = a.at(1) orelse return error.MissingArg;
    const t = try target(c, sid);
    const body = try jsonPath(c, path);
    const res = try envd.fsRPC(c.arena, c.client, t.base, t.token, a.get("user"), "MakeDir", body, t.buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("mkdir {s}\n", .{path});
}

/// rm <sid> <path>
fn cmdRm(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const path = a.at(1) orelse return error.MissingArg;
    const t = try target(c, sid);
    const body = try jsonPath(c, path);
    const res = try envd.fsRPC(c.arena, c.client, t.base, t.token, a.get("user"), "Remove", body, t.buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("rm {s}\n", .{path});
}

/// mv <sid> <源> <目标>
fn cmdMv(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const src = a.at(1) orelse return error.MissingArg;
    const dst = a.at(2) orelse return error.MissingArg;
    const t = try target(c, sid);
    const body = try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{
        try envd.jsonEscape(c.arena, src), try envd.jsonEscape(c.arena, dst),
    });
    const res = try envd.fsRPC(c.arena, c.client, t.base, t.token, a.get("user"), "Move", body, t.buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("mv {s} -> {s}\n", .{ src, dst });
}

/// get <sid> <远端路径> <本地文件>  —— 下载到本地（二进制安全）
fn cmdGet(c: *Ctx, a: util.Args) !void {
    const sid = a.at(0) orelse return error.MissingArg;
    const remote = a.at(1) orelse return error.MissingArg;
    const local = a.at(2) orelse return error.MissingArg;
    const t = try target(c, sid);
    const res = try envd.readFile(c.arena, c.client, t.base, t.token, a.get("user"), remote, t.buf);
    if (!res.ok()) return fail(c, res);
    const dir = std.Io.Dir.cwd();
    const f = try dir.createFile(c.io, local, .{});
    defer f.close(c.io);
    var wbuf: [8192]u8 = undefined;
    var w = f.writer(c.io, &wbuf);
    try w.interface.writeAll(res.body);
    try w.interface.flush();
    try c.out.print("saved {d} bytes -> {s}\n", .{ res.body.len, local });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "cat") or eq(cmd, "read")) {
        try cmdCat(c, a);
        return true;
    }
    if (eq(cmd, "get")) {
        try cmdGet(c, a);
        return true;
    }
    if (eq(cmd, "write")) {
        try cmdWrite(c, a);
        return true;
    }
    if (eq(cmd, "ls-file")) {
        try cmdLs(c, a);
        return true;
    }
    if (eq(cmd, "stat")) {
        try cmdStat(c, a);
        return true;
    }
    if (eq(cmd, "mkdir")) {
        try cmdMkdir(c, a);
        return true;
    }
    if (eq(cmd, "rm-file")) {
        try cmdRm(c, a);
        return true;
    }
    if (eq(cmd, "mv")) {
        try cmdMv(c, a);
        return true;
    }
    return false;
}
