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

// ---------------- pty-ws（WebSocket 附着） ----------------

const ws = @import("ws.zig");

const BaseInfo = struct {
    host: []const u8,
    port: u16,
    path_prefix: []const u8,
    tls: bool,
};

/// 解析 SANDBOX_BASE（http(s)://host[:port][/path]）。
fn parseBase(base: []const u8) !BaseInfo {
    const sep = std.mem.indexOf(u8, base, "://") orelse return error.BadBase;
    const scheme = base[0..sep];
    const rest = base[sep + 3 ..];
    const tls = std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss");
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path_prefix = if (slash < rest.len) rest[slash..] else "";
    var host = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
        // 注意 IPv6 字面量的 [::1]:8080 形式
        if (ci > 0 and authority[ci - 1] != ']') {
            host = authority[0..ci];
            port = std.fmt.parseInt(u16, authority[ci + 1 ..], 10) catch port;
        }
    }
    // 去掉 IPv6 的方括号
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    return .{ .host = host, .port = port, .path_prefix = path_prefix, .tls = tls };
}

/// pty-ws <会话id> [--send=文本] [--max=条数]
fn cmdPtyWs(c: *Ctx, anon: bool, a: util.Args) !void {
    if (!anon) {
        _ = a.at(0) orelse return error.MissingArg;
    }

    const info = parseBase(c.base) catch {
        try c.out.print("无法解析 SANDBOX_BASE: {s}\n", .{c.base});
        return error.BadBase;
    };
    if (info.tls) {
        try c.out.print("wss:// 暂不可用。原因：Zig 0.17.0 的 std.crypto.tls 在握手后写入会卡死，\n", .{});
        try c.out.print("且 std.posix / std.process.Child 的进程 API 已精简，无法改用 openssl 隧道。\n\n", .{});
        try c.out.print("替代路径（在沙箱内直连本地回环，效果相同）：\n", .{});
        try c.out.print("  cube-cli write <sid> <aio-cli-x86_64> /root/aio-cli\n", .{});
        try c.out.print("  cube-cli exec <sid> 'chmod +x /root/aio-cli; SANDBOX_BASE=http://127.0.0.1:8080 /root/aio-cli pty-ws <会话id> --send=\"...\"'\n\n", .{});
        try c.out.print("（x86_64 版二进制可从本项目 Release 下载）\n", .{});
        return error.Unsupported;
    }

    const ws_path = if (anon)
        try std.fmt.allocPrint(c.arena, "{s}/v2/pty/ws?protocol=json", .{info.path_prefix})
    else
        try std.fmt.allocPrint(c.arena, "{s}/v2/pty/sessions/{s}/ws?protocol=json", .{ info.path_prefix, a.at(0).? });

    const host_header = try std.fmt.allocPrint(c.arena, "{s}:{d}", .{ info.host, info.port });

    var conn = ws.dial(c.io, info.host, info.port, ws_path, host_header) catch |e| {
        try c.out.print("WebSocket 连接失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[ws] connected, path={s}\n", .{ws_path});

    // 发送时机：等服务端发出 ready 之后再发，否则会被直接断开
    var pending_send: ?[]const u8 = a.get("send");

    var max_msgs: usize = 5;
    if (a.get("max")) |v| {
        max_msgs = std.fmt.parseInt(usize, v, 10) catch 5;
    }

    var got: usize = 0;
    while (got < max_msgs) {
        const frame = conn.readFrame() catch |e| {
            if (e == error.ConnectionClosed) break;
            try c.out.print("读取帧失败: {t}\n", .{e});
            break;
        };
        switch (frame.opcode) {
            ws.OP_CLOSE => break,
            ws.OP_PING => try conn.sendFrame(ws.OP_PONG, frame.payload),
            ws.OP_TEXT => {
                if (a.has("raw")) {
                    try c.out.print("[TEXT {d}] {s}\n", .{ frame.payload.len, frame.payload });
                } else if (std.json.parseFromSlice(std.json.Value, c.arena, frame.payload, .{})) |parsed| {
                    // 有 data 就输出（自动反转义）；否则输出 [type] 便于观察握手阶段
                    var printed = false;
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("data")) |d| {
                            if (d == .string) {
                                try c.out.print("{s}", .{d.string});
                                printed = true;
                            }
                        }
                        if (!printed) {
                            if (parsed.value.object.get("type")) |t| {
                                if (t == .string) {
                                    try c.out.print("[{s}]\n", .{t.string});
                                    printed = true;
                                }
                            }
                        }
                    }
                    if (!printed) try c.out.print("[{s}]\n", .{frame.payload});
                } else |_| {
                    try c.out.print("[{s}]\n", .{frame.payload});
                }
                try c.out.flush();
                got += 1;
                if (pending_send != null and std.mem.indexOf(u8, frame.payload, "\"ready\"") != null) {
                    const line = try std.fmt.allocPrint(c.arena, "{{\"type\":\"input\",\"data\":\"{s}\"}}", .{try util.jsonEscape(c.arena, pending_send.?)});
                    conn.sendText(line) catch |e| {
                        try c.out.print("发送失败: {t}\n", .{e});
                        return e;
                    };
                    pending_send = null;
                }
            },
            ws.OP_BINARY => {
                try c.out.print("{s}", .{frame.payload});
                try c.out.flush();
                got += 1;
            },
            else => {},
        }
    }
    try c.out.print("\n", .{});

    // 礼貌关闭：发 close 帧再断开。否则服务端会保留半开连接，
    // 导致"下一次附着无响应"（这正是之前 --send 时序问题的真因）。
    conn.sendFrame(ws.OP_CLOSE, "") catch {};
    conn.close();
}

/// 从 {"type":...,"data":"..."} 里取 data（不依赖完整 JSON 解析）。
fn extractJSONData(arena: std.mem.Allocator, payload: []const u8) ?[]const u8 {
    _ = arena;
    const pat = "\"data\":\"";
    const start = std.mem.indexOf(u8, payload, pat) orelse return null;
    const s0 = start + pat.len;
    var i = s0;
    while (i < payload.len) : (i += 1) {
        if (payload[i] == '\\') {
            i += 1;
            continue;
        }
        if (payload[i] == '"') break;
    }
    if (i >= payload.len) return null;
    return payload[s0..i];
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
        try cmdPtyWs(c, eq(cmd, "pty-ws-anon"), a);
        return true;
    }
    return false;
}
