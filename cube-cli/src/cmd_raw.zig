//! raw —— 控制面任意端点透传（P0 兜底：内置命令没覆盖的端点一律走它）。
//!
//! 鉴权 / 解压兜底 / 状态码处理与其它内置命令完全一致（都走 ctx.controlRaw）。
//!   GET    {api}<path>            无 body
//!   POST   {api}<path>            body = --body 或 {}
//!   DELETE /sandboxes/<id>       无 body
//!   POST   /sandboxes/<id>/connect  body {"timeout":N}
const std = @import("std");
const httpc = @import("httpc.zig");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const jsonfmt = @import("jsonfmt.zig");

const Ctx = ctxmod.Ctx;
const BUF = 2 << 20;

pub const help =
    \\raw <METHOD> <path> [--body=JSON|@文件|-] [--query=k=v,...] [--header=k:v] [--json]
    \\  任意方法 / 路径透传到控制面，鉴权与状态码处理和内置命令完全一致。
    \\  无 --body 时：GET/DELETE/HEAD 不带体，POST/PUT/PATCH 发 {}。
    \\  非 2xx 打印 "HTTP <状态>: <体>" 并以非 0 退出。
    \\  例：cube-cli raw GET /health
    \\      cube-cli raw GET '/sandboxes?metadata=agent=subagent-cube-p0'
    \\      cube-cli raw POST /sandboxes/<id>/refreshes --body='{"duration":300}'
    \\      cube-cli raw POST /sandboxes/<id>/snapshots --body=@- < snap.json
;

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "raw")) return false;
    try run(c, argv);
    return true;
}

fn parseMethod(s: []const u8) ?std.http.Method {
    var buf: [16]u8 = undefined;
    if (s.len == 0 or s.len > buf.len) return null;
    for (s, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return std.meta.stringToEnum(std.http.Method, buf[0..s.len]);
}

/// 查询串编码：key 全编码；value 保留 `=`（上游 metadata=k=v 过滤依赖它）与常见安全字符。
const qenc = jsonfmt.qenc;

fn appendQuery(c: *Ctx, path: []const u8, spec: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 16 << 10));
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, kv, '=') orelse {
            try c.out.print("错误：--query 需要 k=v 形式（收到 {s}）\n", .{kv});
            return error.BadArg;
        };
        if (count > 0) try w.writeAll("&");
        count += 1;
        try w.print("{s}={s}", .{ try qenc(c.arena, kv[0..i], false), try qenc(c.arena, kv[i + 1 ..], true) });
    }
    if (count == 0) return path;
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";
    return std.fmt.allocPrint(c.arena, "{s}{s}{s}", .{ path, sep, w.buffered() });
}

fn readBody(c: *Ctx, spec: []const u8) ![]const u8 {
    if (spec.len == 0) return "{}";
    if (spec[0] == '@') {
        const path = spec[1..];
        const data = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(64 << 20)) catch |e| {
            try c.out.print("错误：读取 {s} 失败（{s}）\n", .{ path, @errorName(e) });
            return error.ReadFailed;
        };
        return data;
    }
    if (std.mem.eql(u8, spec, "-")) {
        var rbuf: [64 << 10]u8 = undefined;
        var f = std.Io.File.stdin();
        var r = f.reader(c.io, &rbuf);
        const data = try c.arena.alloc(u8, 4 << 20);
        var w = std.Io.Writer.fixed(data);
        _ = r.interface.streamRemaining(&w) catch |e| {
            try c.out.print("错误：读取 stdin 失败（{s}）\n", .{@errorName(e)});
            return error.ReadFailed;
        };
        return w.buffered();
    }
    return spec;
}

pub fn run(c: *Ctx, argv: []const []const u8) !void {
    const a = try util.parse(c.arena, argv);
    if (a.pos.len < 2) {
        try c.out.print("用法:\n{s}\n", .{help});
        return error.MissingArg;
    }
    const method = parseMethod(a.pos[0]) orelse {
        try c.out.print("错误：不支持的 HTTP 方法: {s}\n", .{a.pos[0]});
        return error.BadMethod;
    };
    var path = a.pos[1];
    if (path.len == 0 or path[0] != '/') {
        path = try std.fmt.allocPrint(c.arena, "/{s}", .{path});
    }
    for (a.flags) |kv| {
        if (std.mem.eql(u8, kv[0], "query")) {
            path = try appendQuery(c, path, kv[1]);
        }
    }

    // 自定义头 --header=k:v
    var extra: std.ArrayList(std.http.Header) = .empty;
    for (a.flags) |kv| {
        if (!std.mem.eql(u8, kv[0], "header")) continue;
        const i = std.mem.indexOfScalar(u8, kv[1], ':') orelse {
            try c.out.print("错误：--header 需要 k:v 形式（收到 {s}）\n", .{kv[1]});
            return error.BadArg;
        };
        extra.append(c.arena, .{
            .name = std.mem.trim(u8, kv[1][0..i], " \t"),
            .value = std.mem.trim(u8, kv[1][i + 1 ..], " \t"),
        }) catch return error.OutOfMemory;
    }

    // body：显式优先；否则按方法决定（GET/DELETE/HEAD 无体，POST/PUT/PATCH 发 {}）
    var body: ?[]const u8 = null;
    if (a.get("body")) |b| {
        body = try readBody(c, b);
    } else if (method.requestHasBody()) {
        body = "{}";
    }

    const buf = try c.arena.alloc(u8, BUF);
    const res = try c.controlRaw(method, path, body, extra.items, buf);

    if (!res.ok()) {
        try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpError;
    }
    if (a.has("json")) {
        const v = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
            try c.out.print("{s}\n", .{res.body});
            return;
        };
        try c.out.print("{f}\n", .{std.json.fmt(v.value, .{ .whitespace = .indent_2 })});
        return;
    }
    if (res.body.len > 0) try c.out.print("{s}", .{res.body});
    if (res.body.len == 0 or res.body[res.body.len - 1] != '\n') try c.out.writeAll("\n");
}