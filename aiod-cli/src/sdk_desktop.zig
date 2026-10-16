//! Core SDK —— 桌面与 GUI 操作域（/v2/computer/*）。
const std = @import("std");
const sdkmod = @import("sdk.zig");

const Sdk = sdkmod.Sdk;

/// GET /v2/computer/info
pub fn info(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/computer/info", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/computer/screenshot（返回原始 PNG 字节）
pub fn screenshot(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.requestRaw(.GET, "/v2/computer/screenshot", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/computer/cursor
pub fn cursor(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/computer/cursor", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/computer/clipboard
pub fn clipboard(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/computer/clipboard", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/computer/windows
pub fn windows(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/computer/windows", null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const A11ySpec = struct {
    scope: ?[]const u8 = null,
    max_depth: ?i64 = null,
    max_nodes: ?i64 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// GET /v2/computer/accessibility
pub fn a11y(self: *Sdk, spec: A11ySpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("/v2/computer/accessibility");
    var first = true;
    if (spec.scope) |v| {
        try w.print("?scope={s}", .{try sdkmod.qenc(self.arena, v)});
        first = false;
    }
    if (spec.max_depth) |v| {
        try w.print("{s}max_depth={d}", .{ if (first) "?" else "&", v });
        first = false;
    }
    if (spec.max_nodes) |v| {
        try w.print("{s}max_nodes={d}", .{ if (first) "?" else "&", v });
        first = false;
    }
    if (spec.role) |v| {
        try w.print("{s}role={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
        first = false;
    }
    if (spec.name) |v| {
        try w.print("{s}name={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
    }

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, w.buffered(), null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const A11yNodesSpec = struct {
    scope: ?[]const u8 = null,
    max_depth: ?i64 = null,
    max_nodes: ?i64 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    match: ?[]const u8 = null,
    states: ?[]const u8 = null,
    include_offscreen: ?bool = null,
    timeout_ms: ?i64 = null,
    limit: ?i64 = null,
    node_id: ?[]const u8 = null,
};

/// GET /v2/computer/accessibility/nodes
pub fn a11yNodes(self: *Sdk, spec: A11yNodesSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("/v2/computer/accessibility/nodes");
    var first = true;
    if (spec.scope) |v| {
        try w.print("?scope={s}", .{try sdkmod.qenc(self.arena, v)});
        first = false;
    }
    if (spec.max_depth) |v| {
        try w.print("{s}max_depth={d}", .{ if (first) "?" else "&", v });
        first = false;
    }
    if (spec.max_nodes) |v| {
        try w.print("{s}max_nodes={d}", .{ if (first) "?" else "&", v });
        first = false;
    }
    if (spec.role) |v| {
        try w.print("{s}role={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
        first = false;
    }
    if (spec.name) |v| {
        try w.print("{s}name={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
        first = false;
    }
    if (spec.match) |v| {
        try w.print("{s}match={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
        first = false;
    }
    if (spec.states) |v| {
        try w.print("{s}states={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
        first = false;
    }
    if (spec.include_offscreen) |v| {
        try w.print("{s}include_offscreen={s}", .{ if (first) "?" else "&", if (v) "true" else "false" });
        first = false;
    }
    if (spec.timeout_ms) |v| {
        try w.print("{s}timeout_ms={d}", .{ if (first) "?" else "&", v });
        first = false;
    }
    if (spec.limit) |v| {
        try w.print("{s}limit={d}", .{ if (first) "?" else "&", v });
        first = false;
    }
    if (spec.node_id) |v| {
        try w.print("{s}node_id={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, v) });
    }

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, w.buffered(), null, buf);
    return self.arena.dupe(u8, res.body);
}

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
    .{ .from = "mouse_down", .to = "MOUSE_DOWN" },  .{ .from = "mousedown", .to = "MOUSE_DOWN" },
    .{ .from = "mouse_up", .to = "MOUSE_UP" },      .{ .from = "mouseup", .to = "MOUSE_UP" },
    .{ .from = "right_click", .to = "RIGHT_CLICK" },.{ .from = "rightclick", .to = "RIGHT_CLICK" },
    .{ .from = "double_click", .to = "DOUBLE_CLICK" },.{ .from = "doubleclick", .to = "DOUBLE_CLICK" },
    .{ .from = "drag", .to = "DRAG_TO" },           .{ .from = "drag_to", .to = "DRAG_TO" },
    .{ .from = "drag_rel", .to = "DRAG_REL" },      .{ .from = "scroll", .to = "SCROLL" },
    .{ .from = "type", .to = "TYPING" },            .{ .from = "typing", .to = "TYPING" },
    .{ .from = "press", .to = "PRESS" },            .{ .from = "key", .to = "PRESS" },
    .{ .from = "key_down", .to = "KEY_DOWN" },      .{ .from = "keydown", .to = "KEY_DOWN" },
    .{ .from = "key_up", .to = "KEY_UP" },          .{ .from = "keyup", .to = "KEY_UP" },
    .{ .from = "hotkey", .to = "HOTKEY" },          .{ .from = "shortcut", .to = "HOTKEY" },
    .{ .from = "wait", .to = "WAIT" },              .{ .from = "sleep", .to = "WAIT" },
    .{ .from = "clipboard", .to = "SET_CLIPBOARD" },.{ .from = "set_clipboard", .to = "SET_CLIPBOARD" },
    .{ .from = "window_activate", .to = "WINDOW_ACTIVATE" },
    .{ .from = "window_minimize", .to = "WINDOW_MINIMIZE" },
    .{ .from = "node_focus", .to = "NODE_FOCUS" },
    .{ .from = "node_invoke", .to = "NODE_INVOKE" },
    .{ .from = "node_set_value", .to = "NODE_SET_VALUE" },
};

fn actionTypeOf(raw: []const u8) ?[]const u8 {
    for (action_aliases) |al| {
        if (std.ascii.eqlIgnoreCase(raw, al.from)) return al.to;
    }
    var up: [32]u8 = undefined;
    if (raw.len >= up.len) return null;
    for (raw, 0..) |ch, i| {
        up[i] = switch (ch) {
            'a'...'z' => ch - 32,
            '-', ' ' => '_',
            else => ch,
        };
    }
    for (action_variants) |v| {
        if (std.mem.eql(u8, up[0..raw.len], v)) return v;
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

pub fn normActionObj(arena: std.mem.Allocator, m: *std.json.ObjectMap) !void {
    if (m.get("action_type") != null) return;
    const av = m.get("action") orelse return;
    if (av != .string) return;
    const at = actionTypeOf(av.string) orelse return;
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

/// POST /v2/computer/actions
pub fn act(self: *Sdk, action_json: []const u8, screenshot_flag: bool) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, self.arena, action_json, .{}) catch return error.BadJson;
    if (parsed.value == .object) {
        try normActionObj(self.arena, &parsed.value.object);
    }
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, action_json.len * 2 + 1024));
    std.json.Stringify.value(parsed.value, .{}, &w) catch return error.BadJson;

    const path = if (screenshot_flag) "/v2/computer/actions?include_screenshot=true" else "/v2/computer/actions";
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/computer/actions/batch
pub fn actBatch(self: *Sdk, actions_json: []const u8, screenshot_flag: bool) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, self.arena, actions_json, .{}) catch return error.BadJson;
    if (parsed.value != .array) return error.BadJson;
    for (parsed.value.array.items) |*item| {
        if (item.* == .object) {
            try normActionObj(self.arena, &item.object);
        }
    }
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, actions_json.len * 2 + 1024));
    std.json.Stringify.value(parsed.value, .{}, &w) catch return error.BadJson;

    var bw = std.Io.Writer.fixed(try self.arena.alloc(u8, w.buffered().len + 128));
    try bw.print("{{\"actions\":{s},\"include_screenshot\":{s}}}", .{
        w.buffered(), if (screenshot_flag) "true" else "false",
    });

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/computer/actions/batch", bw.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

pub const RecordSpec = struct {
    action: ?[]const u8 = null,
    fps: ?i64 = null,
    crf: ?i64 = null,
    max_duration: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    save_path: ?[]const u8 = null,
};

/// POST /v2/computer/record
pub fn record(self: *Sdk, spec: RecordSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.print("{{\"action\":\"{s}\"", .{spec.action orelse "start"});
    if (spec.fps) |v| try w.print(",\"fps\":{d}", .{v});
    if (spec.crf) |v| try w.print(",\"crf\":{d}", .{v});
    if (spec.max_duration) |v| try w.print(",\"max_duration\":{d}", .{v});
    if (spec.width) |v| try w.print(",\"width\":{d}", .{v});
    if (spec.height) |v| try w.print(",\"height\":{d}", .{v});
    if (spec.save_path) |v| {
        try w.writeAll(",\"save_path\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/computer/record", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}
