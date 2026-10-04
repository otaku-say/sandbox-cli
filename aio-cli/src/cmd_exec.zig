//! 命令执行：exec / async / log / kill / stdin / sess*
//!
//! aiod v2 API 契约：
//!   POST /v2/commands            body {"command":...,"cwd","env","timeout","mode","shell","user","session"}
//!                                → 响应**扁平**：{command_id,status,stdout,stderr,exit_code,offset,...}
//!   GET  /v2/commands/<id>       → 响应**嵌套**：{"command":{...}}（按 offset 增量读）
//!   POST /v2/commands/<id>/kill  body {"signal":"SIGKILL"}
//!   POST /v2/commands/<id>/stdin body {"input":"..."}
//!   POST /v2/commands/sessions   body {"id":"..."}
//!   GET  /v2/commands/sessions
//!   DELETE /v2/commands/sessions/<id>
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 4 << 20;
const BODY = 64 << 10;

/// 兼容三种响应形状：
///   POST /v2/commands → {"success":true,"data":{command_id,status,stdout,...}}
///   GET  /v2/commands/<id> → {"data":{"command":{...}}} 或 {"command":{...}}
///   少数接口直接扁平返回
fn lookup(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    if (v.object.get(key)) |f| return f;
    const nests = [_][]const u8{ "data", "command" };
    for (nests) |n| {
        if (v.object.get(n)) |inner| {
            if (inner == .object) {
                if (inner.object.get(key)) |f| return f;
                // 再下一层：data.command.<key>
                if (inner.object.get("command")) |cmd| {
                    if (cmd == .object) {
                        if (cmd.object.get(key)) |f| return f;
                    }
                }
            }
        }
    }
    return null;
}

fn asStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = lookup(v, key) orelse return null;
    if (f == .string) return f.string;
    return null;
}

fn asInt(v: std.json.Value, key: []const u8) ?i64 {
    const f = lookup(v, key) orelse return null;
    if (f == .integer) return f.integer;
    return null;
}

fn printOut(c: *Ctx, out: ?[]const u8, err: ?[]const u8) !void {
    if (out) |s| {
        if (s.len > 0) try c.out.print("{s}", .{s});
    }
    if (err) |s| {
        if (s.len > 0) try c.out.print("{s}", .{s});
    }
}

/// 组装 POST /v2/commands 的 body。
fn runBody(c: *Ctx, a: util.Args, command: []const u8, mode: ?[]const u8) ![]const u8 {
    const buf = try c.arena.alloc(u8, BODY);
    var w = std.Io.Writer.fixed(buf);
    try w.print("{{\"command\":\"{s}\"", .{try util.jsonEscape(c.arena, command)});
    if (mode) |m| try w.print(",\"mode\":\"{s}\"", .{m});
    const opts = [_][]const u8{ "cwd", "shell", "user", "session" };
    for (opts) |k| {
        if (a.get(k)) |v| {
            try w.print(",\"{s}\":\"{s}\"", .{ k, try util.jsonEscape(c.arena, v) });
        }
    }
    if (a.get("timeout")) |v| try w.print(",\"timeout\":{s}", .{v});
    if (a.get("max-output")) |v| try w.print(",\"max_output_length\":{s}", .{v});
    try w.print("}}", .{});
    return w.buffered();
}

/// exec <命令> [--cwd=] [--env=] [--timeout=] —— 同步执行
/// exec --id=<command_id> [--offset=] [--stderr-offset=] —— 增量回读
fn cmdExecInner(c: *Ctx, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, BUF);

    // 模式一：按 id 回读
    if (a.get("id")) |id| {
        var qbuf: [256]u8 = undefined;
        var qn: usize = 0;
        if (a.get("offset")) |v| {
            const s = try std.fmt.bufPrint(qbuf[qn..], "offset={s}", .{v});
            qn += s.len;
        }
        if (a.get("stderr-offset")) |v| {
            const s = try std.fmt.bufPrint(qbuf[qn..], "{s}stderr_offset={s}", .{ if (qn > 0) "&" else "", v });
            qn += s.len;
        }
        const q: []const u8 = if (qn > 0) qbuf[0..qn] else "";
        const path = if (q.len > 0)
            try std.fmt.allocPrint(c.arena, "/v2/commands/{s}?{s}", .{ id, q })
        else
            try std.fmt.allocPrint(c.arena, "/v2/commands/{s}", .{id});
        const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
        if (!res.ok()) return errOut(c, res);
        try emit(c, res.body);
        return;
    }

    if (a.pos.len == 0) return error.MissingArg;
    const body = try runBody(c, a, a.joinFrom(0, " "), null);
    const res = try httpc.postJson(c.client, try c.url("/v2/commands"), try jsonAuth(c), body, buf);
    if (!res.ok()) return errOut(c, res);
    try emit(c, res.body);
}

fn emit(c: *Ctx, json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, json, .{}) catch {
        try c.out.print("{s}\n", .{json});
        return;
    };
    const v = parsed.value;
    try printOut(c, asStr(v, "stdout"), asStr(v, "stderr"));
    if (asInt(v, "exit_code")) |code| {
        if (code != 0) try c.out.print("（exit {d}）\n", .{code});
    }
}

fn errOut(c: *Ctx, res: httpc.Response) !void {
    try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
    return error.HttpError;
}

/// async <命令> [--cwd=] [--env=] [--user=] —— 打印 command_id
fn cmdAsync(c: *Ctx, a: util.Args) !void {
    if (a.pos.len == 0) return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const body = try runBody(c, a, a.joinFrom(0, " "), "async");
    const res = try httpc.postJson(c.client, try c.url("/v2/commands"), try jsonAuth(c), body, buf);
    if (!res.ok()) return errOut(c, res);
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}\n", .{res.body});
        return;
    };
    if (asStr(parsed.value, "command_id")) |id| {
        try c.out.print("{s}\n", .{id});
    } else {
        try c.out.print("{s}\n", .{res.body});
    }
}

/// log <command_id> —— 轮询增量读取（--follow 时循环）
fn cmdLog(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const follow = a.has("follow");
    const buf = try c.arena.alloc(u8, BUF);

    var offset: i64 = 0;
    var stderr_offset: i64 = 0;
    var rounds: usize = 0;
    while (true) {
        const path = try std.fmt.allocPrint(c.arena, "/v2/commands/{s}?offset={d}&stderr_offset={d}", .{ id, offset, stderr_offset });
        const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
        if (!res.ok()) return errOut(c, res);

        const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
            try c.out.print("{s}\n", .{res.body});
            return;
        };
        const v = parsed.value;
        try printOut(c, asStr(v, "stdout"), asStr(v, "stderr"));
        if (asInt(v, "offset")) |o| offset = o;
        if (asInt(v, "stderr_offset")) |o| stderr_offset = o;

        const status = asStr(v, "status") orelse "";
        const done = std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed") or
            std.mem.eql(u8, status, "killed") or std.mem.eql(u8, status, "exited");
        if (done or !follow or rounds > 600) break;
        rounds += 1;
        std.Io.sleep(c.io, .fromMilliseconds(500), .awake) catch {};
    }
}

/// kill <command_id> [--signal=]
fn cmdKill(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    const sig = a.get("signal") orelse "SIGKILL";
    const buf = try c.arena.alloc(u8, BUF);
    const body = try std.fmt.allocPrint(c.arena, "{{\"signal\":\"{s}\"}}", .{sig});
    const path = try std.fmt.allocPrint(c.arena, "/v2/commands/{s}/kill", .{id});
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return errOut(c, res);
    try c.out.print("killed {s}\n", .{id});
}

/// stdin <command_id> <文本> [--enter]
fn cmdStdin(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    var text = a.at(1) orelse "";
    if (a.has("enter")) {
        text = try std.fmt.allocPrint(c.arena, "{s}\n", .{text});
    }
    const buf = try c.arena.alloc(u8, BUF);
    const body = try std.fmt.allocPrint(c.arena, "{{\"input\":\"{s}\"}}", .{try util.jsonEscape(c.arena, text)});
    const path = try std.fmt.allocPrint(c.arena, "/v2/commands/{s}/stdin", .{id});
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return errOut(c, res);
    try c.out.print("ok\n", .{});
}

/// sess-new / sess / sess-ls / sess-rm
fn cmdSess(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    const buf = try c.arena.alloc(u8, BUF);
    if (std.mem.eql(u8, cmd, "sess-new")) {
        const id = a.at(0) orelse return error.MissingArg;
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, BODY));
        try w.print("{{\"id\":\"{s}\"", .{try util.jsonEscape(c.arena, id)});
        if (a.get("cwd")) |v| try w.print(",\"cwd\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
        try w.print("}}", .{});
        const res = try httpc.postJson(c.client, try c.url("/v2/commands/sessions"), try jsonAuth(c), w.buffered(), buf);
        if (!res.ok()) return errOut(c, res);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    if (std.mem.eql(u8, cmd, "sess-ls")) {
        const res = try httpc.get(c.client, try c.url("/v2/commands/sessions"), try auth(c), buf);
        if (!res.ok()) return errOut(c, res);
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    if (std.mem.eql(u8, cmd, "sess-rm")) {
        const id = a.at(0) orelse return error.MissingArg;
        const path = try std.fmt.allocPrint(c.arena, "/v2/commands/sessions/{s}", .{id});
        const res = try httpc.del(c.client, try c.url(path), try auth(c), buf);
        if (!res.ok()) return errOut(c, res);
        try c.out.print("removed {s}\n", .{id});
        return;
    }
    // sess <session_id> <命令>... —— 在会话里执行
    if (std.mem.eql(u8, cmd, "sess")) {
        const id = a.at(0) orelse return error.MissingArg;
        if (a.pos.len < 2) return error.MissingArg;
        var cmd_txt: []const u8 = a.pos[1];
        for (a.pos[2..]) |p| cmd_txt = try std.fmt.allocPrint(c.arena, "{s} {s}", .{ cmd_txt, p });
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, BODY));
        try w.print("{{\"command\":\"{s}\",\"session\":\"{s}\"", .{ try util.jsonEscape(c.arena, cmd_txt), try util.jsonEscape(c.arena, id) });
        if (a.get("timeout")) |v| try w.print(",\"timeout\":{s}", .{v});
        try w.print("}}", .{});
        const res = try httpc.postJson(c.client, try c.url("/v2/commands"), try jsonAuth(c), w.buffered(), buf);
        if (!res.ok()) return errOut(c, res);
        try emit(c, res.body);
    }
}

// ---------------- 鉴权头 ----------------

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
    if (eq(cmd, "exec")) {
        try cmdExecInner(c, a);
        return true;
    }
    if (eq(cmd, "async")) {
        try cmdAsync(c, a);
        return true;
    }
    if (eq(cmd, "log")) {
        try cmdLog(c, a);
        return true;
    }
    if (eq(cmd, "kill")) {
        try cmdKill(c, a);
        return true;
    }
    if (eq(cmd, "stdin")) {
        try cmdStdin(c, a);
        return true;
    }
    if (eq(cmd, "sess") or eq(cmd, "sess-new") or eq(cmd, "sess-ls") or eq(cmd, "sess-rm")) {
        try cmdSess(c, cmd, a);
        return true;
    }
    return false;
}
