//! Core SDK —— 浏览器自动化域（/v2/browser/*）。
const std = @import("std");
const sdkmod = @import("sdk.zig");

const Sdk = sdkmod.Sdk;

/// GET /v2/browser/info
pub fn info(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/browser/info", null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const NavigateSpec = struct {
    url: ?[]const u8 = null,
    history: ?[]const u8 = null,
    wait_until: ?[]const u8 = null,
    timeout: ?i64 = null,
    tab_id: ?[]const u8 = null,
};

/// POST /v2/browser/navigate
pub fn navigate(self: *Sdk, spec: NavigateSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 32 << 10));
    try w.writeAll("{");
    var first = true;
    if (spec.history) |h| {
        try w.writeAll("\"history\":\"");
        try sdkmod.esc(&w, h);
        try w.writeAll("\"");
        first = false;
    } else if (spec.url) |u| {
        try w.writeAll("\"url\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
        first = false;
    }
    if (spec.wait_until) |v| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"wait_until\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
        first = false;
    }
    if (spec.timeout) |v| {
        if (!first) try w.writeAll(",");
        try w.print("\"timeout\":{d}", .{v});
        first = false;
    }
    if (spec.tab_id) |v| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"tab_id\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/navigate", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/evaluate
pub fn evaluate(self: *Sdk, expression: []const u8, is_await: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, expression.len * 2 + 256));
    try w.writeAll("{\"expression\":\"");
    try sdkmod.esc(&w, expression);
    try w.writeAll("\"");
    if (is_await) try w.writeAll(",\"await\":true");
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/evaluate", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/click
pub fn click(self: *Sdk, selector: ?[]const u8, ref: ?[]const u8, tab_id: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 2048));
    try w.writeAll("{");
    var first = true;
    if (selector) |s| {
        try w.writeAll("\"selector\":\"");
        try sdkmod.esc(&w, s);
        try w.writeAll("\"");
        first = false;
    }
    if (ref) |r| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"ref\":\"");
        try sdkmod.esc(&w, r);
        try w.writeAll("\"");
        first = false;
    }
    if (tab_id) |t| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"tab_id\":\"");
        try sdkmod.esc(&w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/click", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/fill
pub fn fill(self: *Sdk, selector: ?[]const u8, ref: ?[]const u8, value: []const u8, tab_id: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, value.len * 2 + 2048));
    try w.writeAll("{");
    var first = true;
    if (selector) |s| {
        try w.writeAll("\"selector\":\"");
        try sdkmod.esc(&w, s);
        try w.writeAll("\"");
        first = false;
    }
    if (ref) |r| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"ref\":\"");
        try sdkmod.esc(&w, r);
        try w.writeAll("\"");
        first = false;
    }
    if (!first) try w.writeAll(",");
    try w.writeAll("\"value\":\"");
    try sdkmod.esc(&w, value);
    try w.writeAll("\"");
    if (tab_id) |t| {
        try w.writeAll(",\"tab_id\":\"");
        try sdkmod.esc(&w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/fill", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/snapshot
pub fn snapshot(self: *Sdk, interactive_only: bool) ![]const u8 {
    const body: []const u8 = if (interactive_only) "{\"interactive_only\":true}" else "{}";
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/snapshot", body, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/browser/tabs
pub fn tabs(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/browser/tabs", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/tabs
pub fn tabNew(self: *Sdk, url: ?[]const u8) ![]const u8 {
    const body: []const u8 = if (url) |u|
        try std.fmt.allocPrint(self.arena, "{{\"url\":\"{s}\"}}", .{try sdkmod.qenc(self.arena, u)})
    else
        "{}";
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/tabs", body, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/tabs/<id>
pub fn tabUse(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/browser/tabs/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, path, "{}", buf);
    return self.arena.dupe(u8, res.body);
}

/// DELETE /v2/browser/tabs/<id>
pub fn tabClose(self: *Sdk, id: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/v2/browser/tabs/{s}", .{id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.DELETE, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const ScreenshotSpec = struct {
    full_page: bool = false,
    quality: ?i64 = null,
};

/// GET /v2/browser/screenshot（返回原始 PNG 字节）
pub fn screenshot(self: *Sdk, spec: ScreenshotSpec) ![]const u8 {
    var qbuf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&qbuf);
    try w.writeAll("format=png");
    if (spec.full_page) try w.writeAll("&full_page=true");
    if (spec.quality) |q| try w.print("&quality={d}", .{q});

    const path = try std.fmt.allocPrint(self.arena, "/v2/browser/screenshot?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.requestRaw(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/browser/cookies
pub fn cookies(self: *Sdk, url: ?[]const u8, domain: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 1024));
    try w.writeAll("/v2/browser/cookies");
    var first = true;
    if (url) |u| {
        try w.print("?url={s}", .{try sdkmod.qenc(self.arena, u)});
        first = false;
    }
    if (domain) |d| {
        try w.print("{s}domain={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, d) });
    }
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, w.buffered(), null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/cookies
pub fn cookieSet(self: *Sdk, body: []const u8) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/cookies", body, buf);
    return self.arena.dupe(u8, res.body);
}

/// DELETE /v2/browser/cookies
pub fn cookieDelete(self: *Sdk, name: ?[]const u8, all: bool, url: ?[]const u8, domain: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 1024));
    try w.writeAll("/v2/browser/cookies");
    var first = true;
    if (all) {
        try w.writeAll("?all=true");
        first = false;
    }
    if (name) |n| {
        try w.print("{s}name={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, n) });
        first = false;
    }
    if (url) |u| {
        try w.print("{s}url={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, u) });
        first = false;
    }
    if (domain) |d| {
        try w.print("{s}domain={s}", .{ if (first) "?" else "&", try sdkmod.qenc(self.arena, d) });
    }
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.DELETE, w.buffered(), null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/upload
pub fn upload(self: *Sdk, paths: []const []const u8, selector: ?[]const u8, ref: ?[]const u8, tab_id: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 64 << 10));
    try w.writeAll("{\"paths\":[");
    for (paths, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\"");
        try sdkmod.esc(&w, p);
        try w.writeAll("\"");
    }
    try w.writeAll("]");
    if (selector) |s| {
        try w.writeAll(",\"selector\":\"");
        try sdkmod.esc(&w, s);
        try w.writeAll("\"");
    }
    if (ref) |r| {
        try w.writeAll(",\"ref\":\"");
        try sdkmod.esc(&w, r);
        try w.writeAll("\"");
    }
    if (tab_id) |t| {
        try w.writeAll(",\"tab_id\":\"");
        try sdkmod.esc(&w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/upload", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/browser/network/requests
pub fn network(self: *Sdk, limit: ?i64, clear: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 256));
    try w.writeAll("/v2/browser/network/requests");
    var first = true;
    if (limit) |l| {
        try w.print("?limit={d}", .{l});
        first = false;
    }
    if (clear) {
        try w.print("{s}clear=true", .{if (first) "?" else "&"});
    }
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, w.buffered(), null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/browser/config
pub fn configGet(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/browser/config", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/config
pub fn configSet(self: *Sdk, body: []const u8) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/config", body, buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/browser/cdp
pub fn cdp(self: *Sdk, method: []const u8, params_json: ?[]const u8, is_browser: bool, tab_id: ?[]const u8) ![]const u8 {
    const plen: usize = if (params_json) |p| p.len else 0;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, plen + 2048));
    try w.writeAll("{\"method\":\"");
    try sdkmod.esc(&w, method);
    try w.writeAll("\"");
    if (params_json) |p| try w.print(",\"params\":{s}", .{p});
    if (is_browser) try w.writeAll(",\"browser\":true");
    if (tab_id) |t| {
        try w.writeAll(",\"tab_id\":\"");
        try sdkmod.esc(&w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("}");

    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/browser/cdp", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}
