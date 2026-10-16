//! Core SDK 层（cube-cli）——纯操作与传输，**不打印、不 exit、不依赖终端/协议上下文**。
//!
//! CLI 门面（`cmd_*.zig`）与 MCP 门面（`mcp_tools*.zig`）共用这一层：
//!   · 控制面：Bearer/X-API-Key 鉴权 + 401/403 回退（同既有行为）
//!   · 数据面：envd（进程 / 文件 / PTY）——直接调用 `envd.zig`
//! 失败现场保留在 `last_status` / `last_body`，由调用方决定如何呈现（打印 / MCP 错误文本）。
const std = @import("std");
const httpc = @import("httpc.zig");
const cfg = @import("cfg.zig");
const envd = @import("envd.zig");

pub const BUF = 8 << 20; // 与 aiod 对齐；工具层仍按 4 MiB 截断长文本

/// 启动期配置覆盖（MCP flag 优先于环境变量）。
pub const Overrides = struct {
    api: ?[]const u8 = null,
    key: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
};

pub const Sdk = struct {
    arena: std.mem.Allocator,
    client: *std.http.Client,
    io: std.Io,
    /// 控制面基址（末尾无 /）
    api: []const u8 = "",
    /// 控制面 API Key（可空：本部署可能不启用鉴权）
    key: ?[]const u8 = null,
    /// 数据面网关（末尾无 /）
    proxy: []const u8 = "",

    /// 最近一次失败现场（0 = 无）
    last_status: u16 = 0,
    last_body: []const u8 = "",
    /// 响应体是否撑满调用方缓冲（= 很可能被截断，调用方应据此提示或改用分页/区间）
    last_truncated: bool = false,
    last_config_error: bool = false,
    missing_config_name: ?[]const u8 = null,

    pub fn init(arena: std.mem.Allocator, client: *std.http.Client, io: std.Io, ov: Overrides) Sdk {
        return .{
            .arena = arena,
            .client = client,
            .io = io,
            .api = trimSlash(ov.api orelse (cfg.apiURL() orelse "")),
            .key = ov.key orelse cfg.apiKey(),
            .proxy = trimSlash(ov.proxy orelse (cfg.proxyURL() orelse "")),
        };
    }

    pub fn fromCtx(c: anytype) Sdk {
        return init(c.arena, c.client, c.io, .{ .api = c.api, .key = c.key, .proxy = cfg.proxyURL() });
    }

    /// 控制面请求；非 2xx 返回 error.HttpError（**不打印**，现场见 last_*）。
    pub fn control(self: *Sdk, method: httpc.Method, path: []const u8, payload: ?[]const u8, buf: []u8) !httpc.Response {
        const res = try self.controlRaw(method, path, payload, &.{}, buf);
        if (!res.ok()) return error.HttpError;
        return res;
    }

    /// 任意方法/路径的控制面请求（非 2xx 不报错，原样返回）。
    /// 鉴权：`Authorization: Bearer <key>` + `X-API-Key: <key>`；401/403 时回退只带 X-API-Key 重试一次。
    pub fn controlRaw(
        self: *Sdk,
        method: httpc.Method,
        path: []const u8,
        payload: ?[]const u8,
        extra: httpc.Headers,
        buf: []u8,
    ) !httpc.Response {
        if (self.api.len == 0) {
            self.last_config_error = true;
            self.missing_config_name = "CUBESANDBOX_API_URL";
            self.last_status = 0;
            self.last_body = "";
            return error.MissingConfig;
        }
        self.last_config_error = false;
        self.missing_config_name = null;
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.api, path });

        var hs: [16]std.http.Header = undefined;
        var n: usize = 0;
        hs[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        if (payload != null) {
            hs[n] = httpc.json_ct;
            n += 1;
        }
        var has_bearer = false;
        if (self.key) |k| {
            hs[n] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.arena, "Bearer {s}", .{k}) };
            n += 1;
            has_bearer = true;
            hs[n] = .{ .name = "X-API-Key", .value = k };
            n += 1;
        }
        for (extra) |h| {
            if (n >= hs.len) break;
            hs[n] = h;
            n += 1;
        }

        var res = try httpc.request(self.client, method, url, hs[0..n], payload, buf);

        if (has_bearer and (res.status == 401 or res.status == 403)) {
            var hs2: [16]std.http.Header = undefined;
            var n2: usize = 0;
            hs2[n2] = hs[0];
            n2 += 1;
            if (payload != null) {
                hs2[n2] = httpc.json_ct;
                n2 += 1;
            }
            hs2[n2] = .{ .name = "X-API-Key", .value = self.key.? };
            n2 += 1;
            for (extra) |h| {
                if (n2 >= hs2.len) break;
                hs2[n2] = h;
                n2 += 1;
            }
            res = try httpc.request(self.client, method, url, hs2[0..n2], payload, buf);
        }

        self.last_truncated = buf.len > 0 and res.body.len >= buf.len;
        if (res.ok()) {
            self.last_status = 0;
            self.last_body = "";
        } else {
            // body 指向可复用读缓冲，必须复制
            self.last_status = res.status;
            self.last_body = self.arena.dupe(u8, res.body) catch "";
        }
        return res;
    }

    /// 失败 → 给模型看的一句话（缺配置 / HTTP 现场）。
    pub fn failText(self: *const Sdk) []const u8 {
        if (self.missing_config_name) |name| {
            return std.fmt.allocPrint(self.arena, "错误：缺少环境变量 {s}", .{name}) catch "错误：缺少环境变量";
        }
        if (self.last_config_error or (self.last_status == 0 and self.api.len == 0)) {
            return "错误：缺少环境变量 CUBESANDBOX_API_URL";
        }
        if (self.last_status != 0) {
            return std.fmt.allocPrint(self.arena, "HTTP {d}: {s}", .{ self.last_status, self.last_body }) catch "HTTP 请求失败";
        }
        return self.last_body;
    }

    pub fn printErr(self: *const Sdk, out: *std.Io.Writer, err: anyerror) !void {
        if (err == error.MissingConfig) {
            try out.print("{s}\n", .{self.failText()});
        } else if (err == error.HttpError) {
            try out.print("HTTP {d}: {s}\n", .{ self.last_status, self.last_body });
        }
    }

    /// 数据面网关是否可用。
    pub fn hasProxy(self: *const Sdk) bool {
        return self.proxy.len > 0;
    }

    /// 沙箱内 envd 基址（走数据面路径风格路由）。
    pub fn envdBase(self: *Sdk, sid: []const u8) ![]const u8 {
        if (self.proxy.len == 0) {
            self.last_config_error = true;
            self.missing_config_name = "CUBESANDBOX_PROXY_URL";
            return error.MissingConfig;
        }
        return std.fmt.allocPrint(self.arena, "{s}/sandbox/{s}/49983", .{ self.proxy, sid });
    }

    /// connect 沙箱，拿 envdAccessToken（可空）。
    pub fn connectToken(self: *Sdk, sid: []const u8, buf: []u8) !?[]const u8 {
        const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/connect", .{sid});
        const res = try self.control(.POST, path, "{}", buf);
        return envd.extractString(self.arena, res.body, "envdAccessToken");
    }

    /// 数据面基址 + token 一把取（失败时 last_* 已有现场）。
    pub fn dataPlane(self: *Sdk, sid: []const u8, buf: []u8) !struct { base: []const u8, token: ?[]const u8 } {
        if (self.api.len == 0) {
            self.last_config_error = true;
            self.missing_config_name = "CUBESANDBOX_API_URL";
            return error.MissingConfig;
        }
        if (self.proxy.len == 0) {
            self.last_config_error = true;
            self.missing_config_name = "CUBESANDBOX_PROXY_URL";
            return error.MissingConfig;
        }
        const token = try self.connectToken(sid, buf);
        const base = try self.envdBase(sid);
        return .{ .base = base, .token = token };
    }
};

pub fn trimSlash(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and s[e - 1] == '/') e -= 1;
    return s[0..e];
}

