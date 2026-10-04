//! 文件操作：cat / read / write / ls / tree / stat / mkdir / rm / mv / cp / edit / grep / search / get
//!
//! aiod v2 文件 API：
//!   GET  /v2/fs/read?path=          读文件（响应即内容）
//!   POST /v2/fs/write               {"path":...,"content":...}
//!   GET  /v2/fs/list?path=          列目录
//!   GET  /v2/fs/stat?path=
//!   GET  /v2/fs/tree?path=          整树（tar 原始字节）
//!   POST /v2/fs/mkdir | remove | move | copy | edit | grep
//!   GET  /v2/fs/search?path=&pattern=
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

fn fail(c: *Ctx, res: httpc.Response) !void {
    try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
    return error.HttpError;
}

fn queryPath(c: *Ctx, base_path: []const u8, path: []const u8, user: ?[]const u8) ![]const u8 {
    const enc = try urlEncode(c.arena, path);
    if (user) |u| {
        return std.fmt.allocPrint(c.arena, "{s}?path={s}&user={s}", .{ base_path, enc, try urlEncode(c.arena, u) });
    }
    return std.fmt.allocPrint(c.arena, "{s}?path={s}", .{ base_path, enc });
}

fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        n += if (safe) 1 else 3;
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        if (safe) {
            out[i] = ch;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = hex[ch >> 4];
            out[i + 2] = hex[ch & 0x0F];
            i += 3;
        }
    }
    return out[0..i];
}

/// GET 类命令的通用流程
fn getJSON(c: *Ctx, path: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

/// POST 类命令的通用流程
fn postJSON(c: *Ctx, path: []const u8, body: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

fn cmdCat(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const q = try queryPath(c, "/v2/fs/read", path, a.get("user"));
    const res = try httpc.get(c.client, try c.url(q), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    // aiod 返回 {"success":true,"data":{"content":"..."}}，提取 content 原样输出
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}", .{res.body});
        return;
    };
    if (dataString(parsed.value, "content")) |content| {
        try c.out.print("{s}", .{content});
    } else {
        try c.out.print("{s}\n", .{res.body});
    }
}

/// 取 data.<key> 的字符串值（aiod 统一响应包装）。
fn dataString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const d = v.object.get("data") orelse return null;
    if (d != .object) return null;
    const f = d.object.get(key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

fn cmdWrite(c: *Ctx, a: util.Args) !void {
    const local = a.at(0) orelse return error.MissingArg;
    const remote = a.at(1) orelse return error.MissingArg;

    var data: []const u8 = "";
    if (std.mem.eql(u8, local, "-")) {
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
        const dir = std.Io.Dir.cwd();
        data = dir.readFileAlloc(c.io, local, c.arena, .limited(BUF)) catch |e| return e;
    }

    const body = try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{
        try util.jsonEscape(c.arena, remote), try util.jsonEscape(c.arena, data),
    });
    try postJSON(c, "/v2/fs/write", body);
}

fn cmdGet(c: *Ctx, a: util.Args) !void {
    const remote = a.at(0) orelse return error.MissingArg;
    const local = a.at(1) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const q = try queryPath(c, "/v2/fs/download", remote, a.get("user"));
    const res = try httpc.get(c.client, try c.url(q), try auth(c), buf);
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

fn cmdMkdir(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const body = try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{try util.jsonEscape(c.arena, path)});
    try postJSON(c, "/v2/fs/mkdir", body);
}

fn cmdRm(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const body = try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{try util.jsonEscape(c.arena, path)});
    try postJSON(c, "/v2/fs/delete", body);
}

fn copyMove(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    const src = a.at(0) orelse return error.MissingArg;
    const dst = a.at(1) orelse return error.MissingArg;
    const route: []const u8 = if (std.mem.eql(u8, cmd, "mv")) "/v2/fs/move" else "/v2/fs/copy";
    const b = try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{
        try util.jsonEscape(c.arena, src), try util.jsonEscape(c.arena, dst),
    });
    try postJSON(c, route, b);
}

fn cmdEdit(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    if (a.get("old")) |old| {
        try w.print("{{\"path\":\"{s}\",\"command\":\"str_replace\",\"old_str\":\"{s}\",\"new_str\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, path), try util.jsonEscape(c.arena, old),
            try util.jsonEscape(c.arena, a.get("new") orelse ""),
        });
    } else if (a.get("insert")) |line| {
        try w.print("{{\"path\":\"{s}\",\"command\":\"insert\",\"insert_line\":{s},\"new_str\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, path), line, try util.jsonEscape(c.arena, a.get("text") orelse ""),
        });
    } else return error.MissingArg;
    try postJSON(c, "/v2/fs/edit", w.buffered());
}

fn cmdGrep(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const pattern = a.at(1) orelse return error.MissingArg;
    const body = try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\",\"pattern\":\"{s}\",\"recursive\":true}}", .{
        try util.jsonEscape(c.arena, path), try util.jsonEscape(c.arena, pattern),
    });
    try postJSON(c, "/v2/fs/grep", body);
}

fn cmdSearch(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const pattern = a.at(1) orelse return error.MissingArg;
    const q = try std.fmt.allocPrint(c.arena, "/v2/fs/search?path={s}&pattern={s}", .{
        try urlEncode(c.arena, path), try urlEncode(c.arena, pattern),
    });
    try getJSON(c, q);
}

// ---------------- 鉴权 ----------------

fn auth(c: *Ctx) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 2);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
}

fn jsonAuth(c: *Ctx) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 3);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    hs[n] = httpc.json_ct;
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
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
    if (eq(cmd, "write")) {
        try cmdWrite(c, a);
        return true;
    }
    if (eq(cmd, "get")) {
        try cmdGet(c, a);
        return true;
    }
    if (eq(cmd, "ls")) {
        const path = a.at(0) orelse "/";
        try getJSON(c, try queryPath(c, "/v2/fs/list", path, a.get("user")));
        return true;
    }
    if (eq(cmd, "stat")) {
        const path = a.at(0) orelse return error.MissingArg;
        try getJSON(c, try queryPath(c, "/v2/fs/stat", path, a.get("user")));
        return true;
    }
    if (eq(cmd, "tree")) {
        const path = a.at(0) orelse "/";
        try getJSON(c, try queryPath(c, "/v2/fs/tree", path, a.get("user")));
        return true;
    }
    if (eq(cmd, "mkdir")) {
        try cmdMkdir(c, a);
        return true;
    }
    if (eq(cmd, "rm")) {
        try cmdRm(c, a);
        return true;
    }
    if (eq(cmd, "mv") or eq(cmd, "cp")) {
        try copyMove(c, cmd, a);
        return true;
    }
    if (eq(cmd, "edit")) {
        try cmdEdit(c, a);
        return true;
    }
    if (eq(cmd, "grep")) {
        try cmdGrep(c, a);
        return true;
    }
    if (eq(cmd, "search")) {
        try cmdSearch(c, a);
        return true;
    }
    return false;
}
