//! computer-use（桌面）命令：cmp-info / cmp-shot / cmp-cursor / cmp-clipboard /
//! cmp-windows / cmp-a11y / cmp-a11y-nodes / cmp-act / cmp-act-batch / cmp-record
//!
//! 路由（与沙箱内 aiod v2 对齐）：
//!   GET  /v2/computer/info | screenshot(原始 PNG) | cursor | clipboard | windows
//!   GET  /v2/computer/accessibility[...]  /  accessibility/nodes[...]
//!   POST /v2/computer/actions  /  actions/batch  /  record
//!
//! 需 aio-computer 镜像（aio-daemon 上统一 503，CLI 会报清晰错误）。
//!
//! 动作归一（对齐 Go 版语义，加法式、绝不删除用户字段）：
//!   ① 已有 action_type → 原样透传；
//!   ② 有可识别的 action 名（v1/OSWorld 风格）→ 追加 action_type；
//!   ③ 坐标类动作缺 x/y 而有 coordinate=[x,y] → 追加 x/y。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 16 << 20;

// ---------------- 基础 ----------------

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

fn getJSON(c: *Ctx, path: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

fn postJSON(c: *Ctx, path: []const u8, body: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        n += if (safe) 1 else 3;
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
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

// ---------------- 动作归一 ----------------

const action_variants = [_][]const u8{
    "MOVE_TO",      "MOVE_REL",         "CLICK",         "MOUSE_DOWN",     "MOUSE_UP",
    "RIGHT_CLICK",  "DOUBLE_CLICK",     "DRAG_TO",       "DRAG_REL",       "SCROLL",
    "TYPING",       "PRESS",            "KEY_DOWN",      "KEY_UP",         "HOTKEY",
    "WAIT",         "SET_CLIPBOARD",    "WINDOW_ACTIVATE", "WINDOW_MINIMIZE", "NODE_FOCUS",
    "NODE_INVOKE",  "NODE_SET_VALUE",
};

const Alias = struct { from: []const u8, to: []const u8 };
const action_aliases = [_]Alias{
    .{ .from = "move", .to = "MOVE_TO" },           .{ .from = "move_to", .to = "MOVE_TO" },
    .{ .from = "moveto", .to = "MOVE_TO" },         .{ .from = "mouse_move", .to = "MOVE_TO" },
    .{ .from = "move_rel", .to = "MOVE_REL" },      .{ .from = "moverel", .to = "MOVE_REL" },
    .{ .from = "click", .to = "CLICK" },            .{ .from = "left_click", .to = "CLICK" },
    .{ .from = "leftclick", .to = "CLICK" },        .{ .from = "right_click", .to = "RIGHT_CLICK" },
    .{ .from = "rightclick", .to = "RIGHT_CLICK" }, .{ .from = "double_click", .to = "DOUBLE_CLICK" },
    .{ .from = "doubleclick", .to = "DOUBLE_CLICK" }, .{ .from = "left_double", .to = "DOUBLE_CLICK" },
    .{ .from = "mouse_down", .to = "MOUSE_DOWN" },  .{ .from = "left_mouse_down", .to = "MOUSE_DOWN" },
    .{ .from = "mouse_up", .to = "MOUSE_UP" },      .{ .from = "left_mouse_up", .to = "MOUSE_UP" },
    .{ .from = "drag", .to = "DRAG_TO" },           .{ .from = "drag_to", .to = "DRAG_TO" },
    .{ .from = "dragto", .to = "DRAG_TO" },         .{ .from = "drag_rel", .to = "DRAG_REL" },
    .{ .from = "dragrel", .to = "DRAG_REL" },       .{ .from = "scroll", .to = "SCROLL" },
    .{ .from = "wheel", .to = "SCROLL" },           .{ .from = "type", .to = "TYPING" },
    .{ .from = "typing", .to = "TYPING" },          .{ .from = "write", .to = "TYPING" },
    .{ .from = "input_text", .to = "TYPING" },      .{ .from = "press", .to = "PRESS" },
    .{ .from = "key", .to = "PRESS" },              .{ .from = "key_down", .to = "KEY_DOWN" },
    .{ .from = "key_up", .to = "KEY_UP" },          .{ .from = "hotkey", .to = "HOTKEY" },
    .{ .from = "wait", .to = "WAIT" },              .{ .from = "sleep", .to = "WAIT" },
    .{ .from = "set_clipboard", .to = "SET_CLIPBOARD" }, .{ .from = "clipboard", .to = "SET_CLIPBOARD" },
    .{ .from = "window_activate", .to = "WINDOW_ACTIVATE" }, .{ .from = "activate_window", .to = "WINDOW_ACTIVATE" },
    .{ .from = "window_minimize", .to = "WINDOW_MINIMIZE" }, .{ .from = "minimize_window", .to = "WINDOW_MINIMIZE" },
    .{ .from = "node_focus", .to = "NODE_FOCUS" },  .{ .from = "node_invoke", .to = "NODE_INVOKE" },
    .{ .from = "node_set_value", .to = "NODE_SET_VALUE" },
};

/// 动作名 → v2 action_type（无法识别返回 null）。
fn actionTypeOf(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // 规范化：小写 + '-'/' ' → '_'
    const norm = arena.alloc(u8, name.len) catch return null;
    for (name, 0..) |ch, i| {
        norm[i] = switch (ch) {
            'A'...'Z' => ch + 32,
            '-', ' ' => '_',
            else => ch,
        };
    }
    for (action_aliases) |m| {
        if (std.mem.eql(u8, norm, m.from)) return m.to;
    }
    // 或已是大写枚举名
    const up = arena.alloc(u8, name.len) catch return null;
    for (name, 0..) |ch, i| {
        up[i] = switch (ch) {
            'a'...'z' => ch - 32,
            '-', ' ' => '_',
            else => ch,
        };
    }
    for (action_variants) |v| {
        if (std.mem.eql(u8, up, v)) return v;
    }
    return null;
}

fn posAction(at: []const u8) bool {
    const list = [_][]const u8{ "MOVE_TO", "CLICK", "RIGHT_CLICK", "DOUBLE_CLICK", "DRAG_TO" };
    for (list) |x| {
        if (std.mem.eql(u8, at, x)) return true;
    }
    return false;
}

/// 加法式归一化单个动作对象（就地修改 map）。
fn normActionObj(arena: std.mem.Allocator, m: *std.json.ObjectMap) !void {
    if (m.get("action_type") != null) return; // ① 原样透传
    const av = m.get("action") orelse return;
    if (av != .string) return;
    const at = actionTypeOf(arena, av.string) orelse return; // 识别不了 → 交给服务端报错
    try m.put(arena, "action_type", .{ .string = at });
    if (posAction(at)) {
        const has_x = m.get("x") != null;
        const has_y = m.get("y") != null;
        if (!has_x or !has_y) {
            if (m.get("coordinate")) |cv| {
                if (cv == .array and cv.array.items.len == 2) {
                    if (!has_x) try m.put(arena, "x", cv.array.items[0]);
                    if (!has_y) try m.put(arena, "y", cv.array.items[1]);
                }
            }
        }
    }
}

fn serialize(c: *Ctx, v: std.json.Value) ![]const u8 {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 1 << 20));
    try std.json.Stringify.value(v, .{}, &w);
    return w.buffered();
}

// ---------------- 命令 ----------------

/// cmp-shot <输出文件.png>：GET /v2/computer/screenshot（原始 PNG 字节）
fn cmdShot(c: *Ctx, a: util.Args) !void {
    const out_path = a.at(0) orelse "screenshot.png";
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url("/v2/computer/screenshot"), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    const f = try std.Io.Dir.cwd().createFile(c.io, out_path, .{});
    defer f.close(c.io);
    var wbuf: [8192]u8 = undefined;
    var w = f.writer(c.io, &wbuf);
    try w.interface.writeAll(res.body);
    try w.interface.flush();
    try c.out.print("saved {d} bytes -> {s}\n", .{ res.body.len, out_path });
}

/// cmp-a11y [--scope=][--max-depth=][--max-nodes=][--role=][--name=]
/// cmp-a11y-nodes [同上] [--match=][--states=][--include-offscreen=][--timeout-ms=][--limit=][--node-id=]
fn cmdA11y(c: *Ctx, a: util.Args, nodes: bool) !void {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 8 << 10));
    var first = true;
    const P = struct { k: []const u8, q: []const u8 };
    const common = [_]P{
        .{ .k = "scope", .q = "scope" },         .{ .k = "max-depth", .q = "max_depth" },
        .{ .k = "max-nodes", .q = "max_nodes" }, .{ .k = "role", .q = "role" },
        .{ .k = "name", .q = "name" },
    };
    const more = [_]P{
        .{ .k = "match", .q = "match" },
        .{ .k = "states", .q = "states" },
        .{ .k = "include-offscreen", .q = "include_offscreen" },
        .{ .k = "timeout-ms", .q = "timeout_ms" },
        .{ .k = "limit", .q = "limit" },
        .{ .k = "node-id", .q = "node_id" },
    };
    for (common) |p| {
        if (a.get(p.k)) |v| {
            try w.print("{s}{s}={s}", .{ if (first) "?" else "&", p.q, try urlEncode(c.arena, v) });
            first = false;
        }
    }
    if (nodes) {
        for (more) |p| {
            if (a.get(p.k)) |v| {
                try w.print("{s}{s}={s}", .{ if (first) "?" else "&", p.q, try urlEncode(c.arena, v) });
                first = false;
            }
        }
    }
    const base = if (nodes) "/v2/computer/accessibility/nodes" else "/v2/computer/accessibility";
    const path = try std.fmt.allocPrint(c.arena, "{s}{s}", .{ base, w.buffered() });
    try getJSON(c, path);
}

/// cmp-act '<JSON 动作>' [--screenshot]
fn cmdAct(c: *Ctx, a: util.Args) !void {
    const raw = a.joinFrom(0, " ");
    if (raw.len == 0) return error.MissingArg;
    var parsed = std.json.parseFromSlice(std.json.Value, c.arena, raw, .{}) catch |e| {
        try c.out.print("动作不是合法 JSON: {t}\n", .{e});
        return error.BadJson;
    };
    if (parsed.value == .object) {
        const m = &parsed.value.object;
        try normActionObj(c.arena, m);
    }
    const body = try serialize(c, parsed.value);
    const q = if (a.has("screenshot")) "?include_screenshot=true" else "";
    const path = try std.fmt.allocPrint(c.arena, "/v2/computer/actions{s}", .{q});
    try postJSON(c, path, body);
}

/// cmp-act-batch '<JSON 动作数组>' [--screenshot]
fn cmdActBatch(c: *Ctx, a: util.Args) !void {
    const raw = a.joinFrom(0, " ");
    if (raw.len == 0) return error.MissingArg;
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, raw, .{}) catch |e| {
        try c.out.print("动作数组不是合法 JSON: {t}\n", .{e});
        return error.BadJson;
    };
    if (parsed.value != .array) {
        try c.out.print("参数应为 JSON 数组，例如 '[{{\"action\":\"click\",\"x\":1,\"y\":2}}]'\n", .{});
        return error.BadJson;
    }
    for (parsed.value.array.items) |*item| {
        if (item.* != .object) continue;
        const m = &item.object;
        try normActionObj(c.arena, m);
    }
    // 包装为 {"actions":[...],"include_screenshot":bool}
    const arr = try serialize(c, parsed.value);
    const body = try std.fmt.allocPrint(c.arena, "{{\"actions\":{s},\"include_screenshot\":{s}}}", .{
        arr, if (a.has("screenshot")) "true" else "false",
    });
    try postJSON(c, "/v2/computer/actions/batch", body);
}

/// cmp-record [--action=start|stop] [--fps=] [--crf=] [--max-duration=] [--width=] [--height=] [--save-path=]
fn cmdRecord(c: *Ctx, a: util.Args) !void {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 16 << 10));
    try w.print("{{\"action\":\"{s}\"", .{a.get("action") orelse "start"});
    if (a.get("fps")) |v| try w.print(",\"fps\":{s}", .{v});
    if (a.get("crf")) |v| try w.print(",\"crf\":{s}", .{v});
    if (a.get("max-duration")) |v| try w.print(",\"max_duration\":{s}", .{v});
    if (a.get("width")) |v| try w.print(",\"width\":{s}", .{v});
    if (a.get("height")) |v| try w.print(",\"height\":{s}", .{v});
    if (a.get("save-path")) |v| {
        try w.print(",\"save_path\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    }
    try w.print("}}", .{});
    try postJSON(c, "/v2/computer/record", w.buffered());
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "cmp-info")) {
        try getJSON(c, "/v2/computer/info");
        return true;
    }
    if (eq(cmd, "cmp-shot")) {
        try cmdShot(c, a);
        return true;
    }
    if (eq(cmd, "cmp-cursor")) {
        try getJSON(c, "/v2/computer/cursor");
        return true;
    }
    if (eq(cmd, "cmp-clipboard")) {
        try getJSON(c, "/v2/computer/clipboard");
        return true;
    }
    if (eq(cmd, "cmp-windows")) {
        try getJSON(c, "/v2/computer/windows");
        return true;
    }
    if (eq(cmd, "cmp-a11y")) {
        try cmdA11y(c, a, false);
        return true;
    }
    if (eq(cmd, "cmp-a11y-nodes")) {
        try cmdA11y(c, a, true);
        return true;
    }
    if (eq(cmd, "cmp-act")) {
        try cmdAct(c, a);
        return true;
    }
    if (eq(cmd, "cmp-act-batch")) {
        try cmdActBatch(c, a);
        return true;
    }
    if (eq(cmd, "cmp-record")) {
        try cmdRecord(c, a);
        return true;
    }
    return false;
}
