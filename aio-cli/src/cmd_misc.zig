//! 代码解释器 / 监听 / MCP / 沙箱信息
//!
//!   POST /v2/code/execute        {"code","language","session_id"}
//!   GET  /v2/code/info
//!   GET/POST/DELETE /v2/code/sessions[/<id>]
//!   GET  /v2/sandbox | /v2/sandbox/packages?lang=
//!   POST /v2/watch               {"path","recursive","debounce"}
//!   GET  /v2/watch/<id>          （poll 事件）
//!   DELETE /v2/watch/<id>
//!   POST /mcp                    （JSON-RPC）
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

fn getJ(c: *Ctx, path: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

fn postJ(c: *Ctx, path: []const u8, body: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

/// code <源码> [--lang=python|javascript] [--session=]
fn cmdCode(c: *Ctx, a: util.Args) !void {
    const src = a.joinFrom(0, " ");
    if (src.len == 0) return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 256 << 10));
    try w.print("{{\"code\":\"{s}\"", .{try util.jsonEscape(c.arena, src)});
    try w.print(",\"language\":\"{s}\"", .{a.get("lang") orelse "python"});
    if (a.get("session")) |s| try w.print(",\"session_id\":\"{s}\"", .{try util.jsonEscape(c.arena, s)});
    if (a.get("timeout")) |t| try w.print(",\"timeout\":{s}", .{t});
    try w.print("}}", .{});
    try postJ(c, "/v2/code/execute", w.buffered());
}

/// code-sess-new [--lang=] / code-sess-ls / code-sess-rm <id>
fn cmdCodeSess(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    if (std.mem.eql(u8, cmd, "code-info")) {
        try getJ(c, "/v2/code/info");
        return;
    }
    if (std.mem.eql(u8, cmd, "code-sess-ls")) {
        try getJ(c, "/v2/code/sessions");
        return;
    }
    if (std.mem.eql(u8, cmd, "code-sess-new")) {
        const body = try std.fmt.allocPrint(c.arena, "{{\"language\":\"{s}\"}}", .{a.get("lang") orelse "python"});
        try postJ(c, "/v2/code/sessions", body);
        return;
    }
    if (std.mem.eql(u8, cmd, "code-sess-rm")) {
        const id = a.at(0) orelse return error.MissingArg;
        const path = try std.fmt.allocPrint(c.arena, "/v2/code/sessions/{s}", .{id});
        const buf = try c.arena.alloc(u8, BUF);
        const res = try httpc.del(c.client, try c.url(path), try auth(c), buf);
        if (!res.ok()) return fail(c, res);
        try c.out.print("{s}\n", .{res.body});
    }
}

/// watch <path> [--recursive] [--debounce=毫秒] / watch-poll <id> / watch-rm <id>
fn cmdWatch(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    if (std.mem.eql(u8, cmd, "watch")) {
        const path = a.at(0) orelse "/";
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 16 << 10));
        try w.print("{{\"path\":\"{s}\"", .{try util.jsonEscape(c.arena, path)});
        if (a.has("recursive")) try w.print(",\"recursive\":true", .{});
        if (a.get("debounce")) |d| try w.print(",\"debounce\":{s}", .{d});
        try w.print("}}", .{});
        try postJ(c, "/v2/watch", w.buffered());
        return;
    }
    const id = a.at(0) orelse return error.MissingArg;
    const path = try std.fmt.allocPrint(c.arena, "/v2/watch/{s}", .{id});
    if (std.mem.eql(u8, cmd, "watch-poll")) {
        try getJ(c, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "watch-rm")) {
        const buf = try c.arena.alloc(u8, BUF);
        const res = try httpc.del(c.client, try c.url(path), try auth(c), buf);
        if (!res.ok()) return fail(c, res);
        try c.out.print("{s}\n", .{res.body});
    }
}

/// mcp <initialize|tools/list|tools/call|ping> [--params=JSON]
fn cmdMcp(c: *Ctx, a: util.Args) !void {
    const method = a.at(0) orelse return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\"", .{try util.jsonEscape(c.arena, method)});
    if (a.get("params")) |p| try w.print(",\"params\":{s}", .{p});
    try w.print("}}", .{});
    try postJ(c, "/mcp", w.buffered());
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "code")) {
        try cmdCode(c, a);
        return true;
    }
    if (eq(cmd, "code-info") or eq(cmd, "code-sess-ls") or eq(cmd, "code-sess-new") or eq(cmd, "code-sess-rm")) {
        try cmdCodeSess(c, cmd, a);
        return true;
    }
    if (eq(cmd, "watch") or eq(cmd, "watch-poll") or eq(cmd, "watch-rm")) {
        try cmdWatch(c, cmd, a);
        return true;
    }
    if (eq(cmd, "mcp")) {
        try cmdMcp(c, a);
        return true;
    }
    if (eq(cmd, "sandbox-info")) {
        try getJ(c, "/v2/sandbox");
        return true;
    }
    if (eq(cmd, "sandbox-packages")) {
        const path = try std.fmt.allocPrint(c.arena, "/v2/sandbox/packages?lang={s}", .{a.get("lang") orelse "python"});
        try getJ(c, path);
        return true;
    }
    return false;
}
