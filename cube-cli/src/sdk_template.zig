//! Core SDK —— 模板域操作（控制面 REST）。
//!
//! 包含查询模板列表、按需求挑选模板（pick）以及查询模板详情。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const jsonfmt = @import("jsonfmt.zig");
const envd = @import("envd.zig");

const Sdk = sdkmod.Sdk;

pub fn filterTemplatesJson(arena: std.mem.Allocator, body: []const u8, itype: ?[]const u8, status: ?[]const u8) ![]const u8 {
    const v = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return body;
    if (v.value != .array) return body;
    var w = std.Io.Writer.fixed(try arena.alloc(u8, 8 << 20));
    try w.writeAll("[");
    var first = true;
    for (v.value.array.items) |it| {
        if (itype) |x| {
            if (!std.ascii.eqlIgnoreCase(tplFieldStr(it, "instanceType"), x)) continue;
        }
        if (status) |x| {
            if (!std.ascii.eqlIgnoreCase(tplFieldStr(it, "status"), x)) continue;
        }
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{f}", .{std.json.fmt(it, .{})});
    }
    try w.writeAll("]");
    return w.buffered();
}

fn tplFieldStr(v: std.json.Value, key: []const u8) []const u8 {
    const f = jsonfmt.objGet(v, key) orelse return "";
    if (f != .string) return "";
    return f.string;
}

/// 查询所有模板（GET /templates）。返回响应体 JSON。
pub fn templateList(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, "/templates", null, buf);
    return self.arena.dupe(u8, res.body);
}

/// 查询单个模板详情（GET /templates/<id>）。返回响应体 JSON。
/// 服务端模板别名解析：GET /templates/aliases/<name> → templateID。
/// 解析不到返回 null（调用方保持 CLI 的兜底：原样把值交给服务端）。
pub fn resolveAliasRef(self: *Sdk, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    const enc = jsonfmt.qenc(self.arena, name, false) catch return null;
    const path = std.fmt.allocPrint(self.arena, "/templates/aliases/{s}", .{enc}) catch return null;
    const buf = self.arena.alloc(u8, 1 << 20) catch return null;
    const res = self.controlRaw(.GET, path, null, &.{}, buf) catch return null;
    if (!res.ok()) return null;
    return envd.extractString(self.arena, res.body, "templateID");
}

pub fn templateInfo(self: *Sdk, tid: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/templates/{s}", .{tid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const PickResult = struct {
    id: []const u8,
    caps: []const u8,
    gw: u16,
};

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// 按所需能力挑出最佳模板（need: code / browser / desktop）。
pub fn templatePick(self: *Sdk, need: []const u8) !PickResult {
    const body = try templateList(self);
    const parsed = std.json.parseFromSlice(std.json.Value, self.arena, body, .{}) catch return error.BadJson;
    var items: []const std.json.Value = &.{};
    switch (parsed.value) {
        .array => |arr| items = arr.items,
        .object => |o| {
            if (o.get("templates")) |t| {
                if (t == .array) items = t.array.items;
            }
        },
        else => {},
    }

    var fallback_id: ?[]const u8 = null;
    var best_id: ?[]const u8 = null;
    var best_caps: []const u8 = "code";
    var best_gw: u16 = 8080;

    for (items) |it| {
        if (it != .object) continue;
        const tid = if (it.object.get("templateID")) |v| (if (v == .string) v.string else continue) else continue;
        const status = if (it.object.get("status")) |v| (if (v == .string) v.string else "") else "";
        if (!std.mem.eql(u8, status, "READY")) continue;

        if (fallback_id == null) fallback_id = tid;

        const img = if (it.object.get("imageInfo")) |v| (if (v == .string) v.string else "") else "";
        const is_browser = contains(img, "browser") or contains(img, "aio-daemon") or contains(img, "aiod");
        const is_desktop = contains(img, "desktop") or contains(img, "aio-computer");

        if (std.mem.eql(u8, need, "desktop")) {
            if (is_desktop) {
                best_id = tid;
                best_caps = "code,browser,desktop";
                best_gw = 8080;
                break;
            }
        } else if (std.mem.eql(u8, need, "browser")) {
            if (is_browser or is_desktop) {
                best_id = tid;
                best_caps = if (is_desktop) "code,browser,desktop" else "code,browser";
                best_gw = 8080;
                break;
            }
        } else {
            // need == "code" or default
            best_id = tid;
            best_caps = "code";
            best_gw = 8080;
            break;
        }
    }

    const final_id = best_id orelse fallback_id orelse return error.NotFound;
    return .{
        .id = final_id,
        .caps = best_caps,
        .gw = best_gw,
    };
}

// ---------------- 端口 / 网关推断（纯函数，从 cmd_template.zig 下沉） ----------------

pub const MAX_PORTS: usize = 64;

pub fn parsePorts(arena: std.mem.Allocator, s: []const u8) ![]u16 {
    const buf = try arena.alloc(u16, MAX_PORTS);
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, ":, ");
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        const v = std.fmt.parseInt(u16, tok, 10) catch continue;
        var dup = false;
        for (buf[0..n]) |x| {
            if (x == v) dup = true;
        }
        if (!dup) {
            buf[n] = v;
            n += 1;
        }
    }
    const out = buf[0..n];
    std.mem.sort(u16, out, {}, std.sort.asc(u16));
    return out;
}

pub fn hasPort(ports: []const u16, p: u16) bool {
    for (ports) |x| {
        if (x == p) return true;
    }
    return false;
}


pub fn guessGateway(ports: []const u16, image: []const u8) u16 {
    if (hasPort(ports, 9222) and hasPort(ports, 8080)) return 8080;
    if (hasPort(ports, 8080) and !hasPort(ports, 18091)) return 8080;
    if (hasPort(ports, 18091)) return 18091;
    if (hasPort(ports, 8080)) return 8080;
    if (contains(image, "aio-code")) return 18091;
    return 0;
}

