//! PTY 终端：pty-new / pty-ls / pty / pty-screen / pty-input / pty-signal / pty-resize / pty-rm
//!
//! aiod v2：
//!   POST   /v2/pty/sessions                {"id","cwd","cols","rows","retention"}
//!   GET    /v2/pty/sessions
//!   POST   /v2/pty/sessions/<id>/exec      {"command","timeout","async"} → data.output（合流）
//!   GET    /v2/pty/sessions/<id>/screen
//!   POST   /v2/pty/sessions/<id>/input     {"input","press_enter"}
//!   POST   /v2/pty/sessions/<id>/signal    {"signal"}
//!   PATCH  /v2/pty/sessions/<id>           {"cols","rows"}
//!   DELETE /v2/pty/sessions/<id>
//!
//! 注（Go 版实测备注）：--timeout 到点会返回 status=running（命令仍在跑），
//! 此时再 exec 会被拒（Session already has a running command），可用 pty-screen 看进度；
//! signal 会把会话进程终止（会话随后从列表消失）。
//!
//! pty-ws（WebSocket 附着）需要手写 WS 客户端，当前版本未实现。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

/// 打印错误响应并返回错误（返回 anyerror 以便在任意返回类型的函数里直接 return）。
fn fail(c: *Ctx, res: httpc.Response) anyerror {
    c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body }) catch {};
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

fn out(c: *Ctx, res: httpc.Response) !void {
    try c.out.print("{s}\n", .{res.body});
}

/// pty-new <会话id> [--cwd=] [--cols=] [--rows=] [--retention=]
fn cmdNew(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 16 << 10));
    try w.print("{{\"id\":\"{s}\"", .{try util.jsonEscape(c.arena, id)});
    if (a.get("cwd")) |v| try w.print(",\"cwd\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    if (a.get("cols")) |v| try w.print(",\"cols\":{s}", .{v});
    if (a.get("rows")) |v| try w.print(",\"rows\":{s}", .{v});
    if (a.get("retention")) |v| try w.print(",\"retention\":\"{s}\"", .{v});
    try w.print("}}", .{});
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.postJson(c.client, try c.url("/v2/pty/sessions"), try jsonAuth(c), w.buffered(), buf);
    if (!res.ok()) return fail(c, res);
    try out(c, res);
}

/// pty <会话id> <命令...> [--timeout=] [--async]
fn cmdExec(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    if (a.pos.len < 2) return error.MissingArg;
    var cmd_txt: []const u8 = a.pos[1];
    for (a.pos[2..]) |p| cmd_txt = try std.fmt.allocPrint(c.arena, "{s} {s}", .{ cmd_txt, p });

    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    try w.print("{{\"command\":\"{s}\"", .{try util.jsonEscape(c.arena, cmd_txt)});
    if (a.get("timeout")) |v| try w.print(",\"timeout\":{s}", .{v});
    if (a.has("async")) try w.print(",\"async\":true", .{});
    try w.print("}}", .{});

    const path = try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/exec", .{id});
    const buf = try c.arena.alloc(u8, BUF);
    // exec 可能等满 timeout，HTTP 侧给足余量
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), w.buffered(), buf);
    if (!res.ok()) return fail(c, res);
    try out(c, res);
}

fn cmdGet(c: *Ctx, path: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    try out(c, res);
}

fn cmdSend(c: *Ctx, path: []const u8, body: []const u8, method: httpc.Method) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.request(c.client, method, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return fail(c, res);
    try out(c, res);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "pty-new")) {
        try cmdNew(c, a);
        return true;
    }
    if (eq(cmd, "pty-ls")) {
        try cmdGet(c, "/v2/pty/sessions");
        return true;
    }
    if (eq(cmd, "pty")) {
        try cmdExec(c, a);
        return true;
    }
    if (eq(cmd, "pty-screen")) {
        const id = a.at(0) orelse return error.MissingArg;
        try cmdGet(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/screen", .{id}));
        return true;
    }
    if (eq(cmd, "pty-input")) {
        const id = a.at(0) orelse return error.MissingArg;
        const text = a.at(1) orelse "";
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
        try w.print("{{\"input\":\"{s}\",\"press_enter\":{s}}}", .{
            try util.jsonEscape(c.arena, text),
            if (a.has("enter")) "true" else "false",
        });
        try cmdSend(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/input", .{id}), w.buffered(), .POST);
        return true;
    }
    if (eq(cmd, "pty-signal")) {
        const id = a.at(0) orelse return error.MissingArg;
        const sig = a.get("signal") orelse (a.at(1) orelse "SIGINT");
        const body = try std.fmt.allocPrint(c.arena, "{{\"signal\":\"{s}\"}}", .{sig});
        try cmdSend(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/signal", .{id}), body, .POST);
        return true;
    }
    if (eq(cmd, "pty-resize")) {
        const id = a.at(0) orelse return error.MissingArg;
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 4096));
        try w.print("{{", .{});
        var first = true;
        if (a.get("cols")) |v| {
            try w.print("\"cols\":{s}", .{v});
            first = false;
        }
        if (a.get("rows")) |v| {
            if (!first) try w.print(",", .{});
            try w.print("\"rows\":{s}", .{v});
        }
        try w.print("}}", .{});
        try cmdSend(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}", .{id}), w.buffered(), .PATCH);
        return true;
    }
    if (eq(cmd, "pty-rm")) {
        const id = a.at(0) orelse return error.MissingArg;
        const buf = try c.arena.alloc(u8, BUF);
        const res = try httpc.del(c.client, try c.url(try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}", .{id})), try auth(c), buf);
        if (!res.ok()) return fail(c, res);
        try out(c, res);
        return true;
    }
    if (eq(cmd, "pty-ws") or eq(cmd, "pty-ws-anon")) {
        try c.out.print("pty-ws 需要 WebSocket 客户端，当前版本尚未实现（REST 部分已可用）\n", .{});
        return true;
    }
    return false;
}
