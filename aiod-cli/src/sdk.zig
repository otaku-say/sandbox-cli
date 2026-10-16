//! Core SDK 层（aiod-cli）——纯操作与传输，**不打印、不 exit、不依赖终端/协议上下文**。
//!
//! CLI 门面（`cmd_*.zig`）与 MCP 门面（`mcp_tools*.zig`）共用这一层。
//! 失败现场保留在 `last_status` / `last_body` / `last_message`，由调用方决定呈现方式。
const std = @import("std");
const httpc = @import("httpc.zig");
const cfg = @import("cfg.zig");

/// 常规 JSON 响应的缓冲上限。
pub const BUF = 8 << 20;

/// 启动期配置覆盖（MCP flag 优先于环境变量）。
pub const Overrides = struct {
    base: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

pub const Sdk = struct {
    arena: std.mem.Allocator,
    client: *std.http.Client,
    io: std.Io,
    /// aiod 网关基址（末尾无 /），形如 https://<host>/sandbox/<id>/8080
    base: []const u8 = "",
    key: ?[]const u8 = null,

    last_status: u16 = 0,
    last_body: []const u8 = "",
    last_message: []const u8 = "",
    last_config_error: bool = false,

    pub fn init(arena: std.mem.Allocator, client: *std.http.Client, io: std.Io, ov: Overrides) Sdk {
        return .{
            .arena = arena,
            .client = client,
            .io = io,
            .base = trimSlash(ov.base orelse (cfg.sandboxBase() orelse "")),
            .key = ov.key orelse cfg.sandboxKey(),
        };
    }

    pub fn url(self: *Sdk, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.base, path });
    }

    pub fn urlFmt(self: *Sdk, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const p = try std.fmt.allocPrint(self.arena, fmt, args);
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.base, p });
    }

    /// 常规 JSON 请求：非 2xx 或信封 success=false 都返回错误（**不打印**）。
    pub fn request(self: *Sdk, method: httpc.Method, path: []const u8, payload: ?[]const u8, buf: []u8) !httpc.Response {
        const res = try self.requestRaw(method, path, payload, buf);
        if (envelopeMessage(res.body)) |m| {
            self.last_message = self.arena.dupe(u8, m) catch m;
            return error.ApiError;
        }
        return res;
    }

    /// 不做信封判定的请求（二进制/非 JSON 响应，如 /v2/fs/download、/v2/fs/tree）。
    pub fn requestRaw(self: *Sdk, method: httpc.Method, path: []const u8, payload: ?[]const u8, buf: []u8) !httpc.Response {
        if (self.base.len == 0) {
            self.last_config_error = true;
            self.last_status = 0;
            self.last_body = "";
            self.last_message = "";
            return error.MissingConfig;
        }
        self.last_config_error = false;
        self.last_status = 0;
        self.last_body = "";
        self.last_message = "";

        const u = try self.url(path);
        var hs: [3]std.http.Header = undefined;
        var n: usize = 0;
        hs[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        if (payload != null) {
            hs[n] = httpc.json_ct;
            n += 1;
        }
        if (self.key) |k| {
            hs[n] = .{ .name = "X-API-KEY", .value = k };
            n += 1;
        }
        const res = try httpc.request(self.client, method, u, hs[0..n], payload, buf);
        if (!res.ok()) {
            self.last_status = res.status;
            self.last_body = self.arena.dupe(u8, res.body) catch "";
            return error.HttpError;
        }
        return res;
    }

    /// 失败 → 给模型看的一句话。
    pub fn failText(self: *const Sdk) []const u8 {
        if (self.last_config_error or self.base.len == 0) {
            return "缺少环境变量 SANDBOX_BASE（沙箱内 aiod 网关地址），无法执行数据面操作";
        }
        if (self.last_message.len > 0) {
            return std.fmt.allocPrint(self.arena, "接口返回失败：{s}", .{self.last_message}) catch self.last_message;
        }
        if (self.last_status != 0) {
            return std.fmt.allocPrint(self.arena, "HTTP {d}: {s}", .{ self.last_status, self.last_body }) catch "HTTP 请求失败";
        }
        return self.last_body;
    }
};

pub fn trimSlash(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and s[e - 1] == '/') e -= 1;
    return s[0..e];
}

// ---------------- 响应解析辅助（工具层组织结果文本用） ----------------

/// 解析响应体；失败返回 null（非 JSON 响应属正常情况）。
pub fn parse(arena: std.mem.Allocator, body: []const u8) ?std.json.Value {
    const p = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return null;
    return p.value;
}

/// 信封失败（HTTP 200 + success=false）时取 message；无则 null。
pub fn envelopeMessage(body: []const u8) ?[]const u8 {
    const p = std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, body, .{}) catch return null;
    defer p.deinit();
    if (p.value != .object) return null;
    const s = p.value.object.get("success") orelse return null;
    if (s != .bool or s.bool) return null;
    if (p.value.object.get("message")) |m| {
        if (m == .string) return m.string;
    }
    if (p.value.object.get("error")) |e| {
        if (e == .string) return e.string;
    }
    return "success=false";
}

/// 取字段：先扁平，再 `data.<key>`，再 `data.command.<key>`（aiod 响应形状不统一）。
pub fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    if (v.object.get(key)) |f| return f;
    const nests = [_][]const u8{ "data", "command" };
    for (nests) |n| {
        if (v.object.get(n)) |inner| {
            if (inner == .object) {
                if (inner.object.get(key)) |f| return f;
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

pub fn fieldStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

pub fn fieldInt(v: std.json.Value, key: []const u8) ?i64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

/// 查询串百分号编码（与 cube-cli 的 jsonfmt.qenc 同语义）。
pub fn qenc(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| n += if (safeChar(ch)) @as(usize, 1) else 3;
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        if (safeChar(ch)) {
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

/// JSON 字符串转义（不含外层引号）：控制字符 \uXXXX，UTF-8 原样通过。
/// SDK 层自备一份，避免 Core 层反向依赖 MCP 层。
pub fn esc(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    var b: [6]u8 = undefined;
                    const t = try std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c});
                    try w.writeAll(t);
                } else {
                    try w.writeAll(&[_]u8{c});
                }
            },
        }
    }
}

fn safeChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
}
