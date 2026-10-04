//! 浏览器：br-go / br-shot / br-eval / br-click / br-fill / br-snapshot /
//!         br-tabs / br-tab-new / br-tab-use / br-tab-close / br-cookies /
//!         br-cookie-set / br-network / br-info / br-config / br-cdp
//!
//! aiod v2 浏览器 API：
//!   POST /v2/browser/navigate     {"url","wait_until","timeout"}
//!   GET  /v2/browser/screenshot   query（返回 PNG 原始字节）
//!   POST /v2/browser/evaluate     {"expression","tab_id"}
//!   POST /v2/browser/click        {"selector"}
//!   POST /v2/browser/fill         {"selector","value"}
//!   POST /v2/browser/snapshot     {"interactive"}
//!   GET/POST /v2/browser/tabs ...
//!   /v2/browser/{cookies,network/requests,info,config,cdp}
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 32 << 20; // 截图可能很大

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

/// br-go <url> [--wait=load|domcontentloaded|networkidle] [--timeout=秒]
fn cmdGo(c: *Ctx, a: util.Args) !void {
    const url = a.at(0) orelse return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 32 << 10));
    try w.print("{{\"url\":\"{s}\"", .{try util.jsonEscape(c.arena, url)});
    if (a.get("wait")) |v| try w.print(",\"wait_until\":\"{s}\"", .{v});
    if (a.get("timeout")) |v| try w.print(",\"timeout\":{s}", .{v});
    try w.print("}}", .{});
    try postJ(c, "/v2/browser/navigate", w.buffered());
}

/// br-shot <输出文件.png> [--full] [--quality=0-100]
fn cmdShot(c: *Ctx, a: util.Args) !void {
    const out_path = a.at(0) orelse return error.MissingArg;
    var q: []const u8 = "format=png";
    if (a.has("full")) q = "format=png&full_page=true";
    if (a.get("quality")) |v| {
        q = try std.fmt.allocPrint(c.arena, "{s}&quality={s}", .{ q, v });
    }
    const path = try std.fmt.allocPrint(c.arena, "/v2/browser/screenshot?{s}", .{q});
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    // 校验 PNG 魔术数（避免把错误页写盘）
    const is_png = res.body.len >= 8 and std.mem.eql(u8, res.body[0..8], "\x89PNG\r\n\x1a\n");
    const dir = std.Io.Dir.cwd();
    const f = try dir.createFile(c.io, out_path, .{});
    defer f.close(c.io);
    var wbuf: [8192]u8 = undefined;
    var w = f.writer(c.io, &wbuf);
    try w.interface.writeAll(res.body);
    try w.interface.flush();
    try c.out.print("saved {d} bytes -> {s}{s}\n", .{ res.body.len, out_path, if (is_png) " (PNG ✓)" else " (⚠ 非 PNG)" });
}

/// br-eval <表达式> [--await]
fn cmdEval(c: *Ctx, a: util.Args) !void {
    const expr = a.joinFrom(0, " ");
    if (expr.len == 0) return error.MissingArg;
    const body = try std.fmt.allocPrint(c.arena, "{{\"expression\":\"{s}\"}}", .{try util.jsonEscape(c.arena, expr)});
    try postJ(c, "/v2/browser/evaluate", body);
}

/// br-click --selector=<css>  |  br-fill --selector= --value=
fn cmdClickFill(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    const sel = a.get("selector") orelse return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 32 << 10));
    if (std.mem.eql(u8, cmd, "br-click")) {
        try w.print("{{\"selector\":\"{s}\"}}", .{try util.jsonEscape(c.arena, sel)});
        try postJ(c, "/v2/browser/click", w.buffered());
    } else {
        const val = a.get("value") orelse "";
        try w.print("{{\"selector\":\"{s}\",\"value\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, sel), try util.jsonEscape(c.arena, val),
        });
        try postJ(c, "/v2/browser/fill", w.buffered());
    }
}

/// br-snapshot [--interactive]
fn cmdSnapshot(c: *Ctx, a: util.Args) !void {
    const body = if (a.has("interactive")) "{\"interactive\":true}" else "{}";
    try postJ(c, "/v2/browser/snapshot", body);
}

/// br-tabs / br-tab-new [--url=] / br-tab-use <id> / br-tab-close <id>
fn cmdTabs(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    if (std.mem.eql(u8, cmd, "br-tabs")) {
        try getJ(c, "/v2/browser/tabs");
        return;
    }
    if (std.mem.eql(u8, cmd, "br-tab-new")) {
        var body: []const u8 = "{}";
        if (a.get("url")) |u| {
            body = try std.fmt.allocPrint(c.arena, "{{\"url\":\"{s}\"}}", .{try util.jsonEscape(c.arena, u)});
        }
        try postJ(c, "/v2/browser/tabs", body);
        return;
    }
    const id = a.at(0) orelse return error.MissingArg;
    const path = try std.fmt.allocPrint(c.arena, "/v2/browser/tabs/{s}", .{id});
    if (std.mem.eql(u8, cmd, "br-tab-use")) {
        const buf = try c.arena.alloc(u8, BUF);
        const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), "{}", buf);
        if (!res.ok()) return fail(c, res);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    if (std.mem.eql(u8, cmd, "br-tab-close")) {
        const buf = try c.arena.alloc(u8, BUF);
        const res = try httpc.del(c.client, try c.url(path), try auth(c), buf);
        if (!res.ok()) return fail(c, res);
        try c.out.print("{s}\n", .{res.body});
    }
}

/// br-cookies [--url=] / br-cookie-set --name= --value=
fn cmdCookies(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    if (std.mem.eql(u8, cmd, "br-cookies")) {
        var path: []const u8 = "/v2/browser/cookies";
        if (a.get("url")) |u| {
            path = try std.fmt.allocPrint(c.arena, "/v2/browser/cookies?url={s}", .{u});
        }
        try getJ(c, path);
        return;
    }
    const name = a.get("name") orelse return error.MissingArg;
    const value = a.get("value") orelse "";
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 16 << 10));
    try w.print("{{\"name\":\"{s}\",\"value\":\"{s}\"", .{
        try util.jsonEscape(c.arena, name), try util.jsonEscape(c.arena, value),
    });
    if (a.get("url")) |u| try w.print(",\"url\":\"{s}\"", .{try util.jsonEscape(c.arena, u)});
    if (a.get("domain")) |d| try w.print(",\"domain\":\"{s}\"", .{try util.jsonEscape(c.arena, d)});
    try w.print("}}", .{});
    try postJ(c, "/v2/browser/cookies", w.buffered());
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "br-go")) {
        try cmdGo(c, a);
        return true;
    }
    if (eq(cmd, "br-shot")) {
        try cmdShot(c, a);
        return true;
    }
    if (eq(cmd, "br-eval")) {
        try cmdEval(c, a);
        return true;
    }
    if (eq(cmd, "br-click") or eq(cmd, "br-fill")) {
        try cmdClickFill(c, cmd, a);
        return true;
    }
    if (eq(cmd, "br-snapshot")) {
        try cmdSnapshot(c, a);
        return true;
    }
    if (eq(cmd, "br-tabs") or eq(cmd, "br-tab-new") or eq(cmd, "br-tab-use") or eq(cmd, "br-tab-close")) {
        try cmdTabs(c, cmd, a);
        return true;
    }
    if (eq(cmd, "br-cookies") or eq(cmd, "br-cookie-set")) {
        try cmdCookies(c, cmd, a);
        return true;
    }
    if (eq(cmd, "br-network")) {
        try getJ(c, "/v2/browser/network/requests");
        return true;
    }
    if (eq(cmd, "br-info")) {
        try getJ(c, "/v2/browser/info");
        return true;
    }
    if (eq(cmd, "br-config")) {
        if (a.get("json")) |j| {
            try postJ(c, "/v2/browser/config", j);
        } else {
            try getJ(c, "/v2/browser/config");
        }
        return true;
    }
    if (eq(cmd, "br-cdp")) {
        const method = a.at(0) orelse return error.MissingArg;
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 32 << 10));
        try w.print("{{\"method\":\"{s}\"", .{try util.jsonEscape(c.arena, method)});
        if (a.get("params")) |p| try w.print(",\"params\":{s}", .{p});
        try w.print("}}", .{});
        try postJ(c, "/v2/browser/cdp", w.buffered());
        return true;
    }
    return false;
}
