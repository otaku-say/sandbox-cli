//! Core SDK —— 沙箱生命周期域操作（控制面 REST）。
//!
//! 约定：所有函数返回**数据**（响应体 / 结构化结果），不打印、不 exit。
//! CLI 命令与 MCP 工具都从这里取能力。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const httpc = @import("httpc.zig");
const jsonfmt = @import("jsonfmt.zig");

const Sdk = sdkmod.Sdk;

// ---------------- ls ----------------

pub const ListQuery = struct {
    metadata: []const []const u8 = &.{},
    state: ?[]const u8 = null,
    limit: ?[]const u8 = null,
    v2: bool = false,
};

/// GET /sandboxes（v1）或 /v2/sandboxes（v2）。返回响应体（调用方决定渲染方式）。
pub fn sandboxList(self: *Sdk, q: ListQuery) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    var n: usize = 0;
    for (q.metadata) |kv| {
        if (kv.len == 0) continue;
        if (n > 0) try w.writeAll("&");
        n += 1;
        try w.print("metadata={s}", .{try jsonfmt.qenc(self.arena, kv, true)});
    }
    if (q.state) |s| {
        if (n > 0) try w.writeAll("&");
        n += 1;
        try w.print("state={s}", .{try jsonfmt.qenc(self.arena, s, false)});
    }
    if (q.v2) {
        if (q.limit) |l| {
            if (n > 0) try w.writeAll("&");
            n += 1;
            try w.print("limit={s}", .{l});
        }
    }
    const base = if (q.v2) "/v2/sandboxes" else "/sandboxes";
    const path = if (n > 0)
        try std.fmt.allocPrint(self.arena, "{s}?{s}", .{ base, w.buffered() })
    else
        base;
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

// ---------------- info ----------------

pub const InfoOptions = struct {
    /// 轮询到指定状态（如 running）；null = 不轮询。
    wait_state: ?[]const u8 = null,
    timeout_s: u64 = 120,
};

/// GET /sandboxes/<id>；可轮询到目标状态。返回最终响应体。
pub fn sandboxInfo(self: *Sdk, sid: []const u8, opt: InfoOptions) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    var res = try self.control(.GET, path, null, buf);
    if (opt.wait_state) |target| {
        // 不用墙钟（避免 Io/时间 API 差异）：按秒轮询，最多 timeout_s 次。
        var i: u64 = 0;
        while (i < opt.timeout_s) : (i += 1) {
            if (stateOf(res.body)) |s| {
                if (std.mem.eql(u8, s, target)) break;
            }
            try std.Io.sleep(self.io, .fromSeconds(1), .awake);
            res = try self.control(.GET, path, null, buf);
        }
    }
    return self.arena.dupe(u8, res.body);
}

fn stateOf(body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("state") orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---------------- pause / resume / refresh / timeout ----------------

pub fn sandboxPause(self: *Sdk, sid: []const u8) !void {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/pause", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    _ = try self.control(.POST, path, "{}", buf);
}

pub fn sandboxResume(self: *Sdk, sid: []const u8, timeout_s: ?u64) !void {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/resume", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = if (timeout_s) |t|
        try std.fmt.allocPrint(self.arena, "{{\"timeout\":{d}}}", .{t})
    else
        "{}";
    _ = try self.control(.POST, path, body, buf);
}

pub fn sandboxRefresh(self: *Sdk, sid: []const u8, duration_s: ?u64) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/refreshes", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = if (duration_s) |d|
        try std.fmt.allocPrint(self.arena, "{{\"duration\":{d}}}", .{d})
    else
        "{}";
    const res = try self.control(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

pub fn sandboxSetTimeout(self: *Sdk, sid: []const u8, seconds: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/timeout", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = try std.fmt.allocPrint(self.arena, "{{\"timeout\":{d}}}", .{seconds});
    const res = try self.control(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

/// PUT /sandboxes/<id>/network
pub const NetSpec = struct {
    internet: ?bool = null,
    allow: ?[]const u8 = null,
    deny: ?[]const u8 = null,
};

pub fn sandboxSetNet(self: *Sdk, sid: []const u8, spec: NetSpec) !void {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/network", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 64 << 10));
    try w.writeAll("{");
    var comma = false;
    if (spec.internet) |v| {
        try w.print("\"allowInternetAccess\":{s}", .{if (v) "true" else "false"});
        comma = true;
    }
    if (spec.allow) |a| {
        if (comma) try w.writeAll(",");
        try w.print("\"allowOut\":\"{s}\"", .{try jsonfmt_qenc(self.arena, a)});
        comma = true;
    }
    if (spec.deny) |d| {
        if (comma) try w.writeAll(",");
        try w.print("\"denyOut\":\"{s}\"", .{try jsonfmt_qenc(self.arena, d)});
        comma = true;
    }
    try w.writeAll("}");
    _ = try self.control(.PUT, path, w.buffered(), buf);
}

fn jsonfmt_qenc(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return jsonfmt.qenc(arena, s, false);
}

// ---------------- rm（带生命周期互斥重试） ----------------

pub const DeleteResult = enum { deleted, already_gone };

/// DELETE /sandboxes/<id>：404 幂等成功；503/409/408 按 Retry-After 最多重试 3 次。
/// 重试等待会阻塞调用方（CLI 与 MCP 都接受这一点，语义与既有 rm 一致）。
pub fn sandboxDelete(self: *Sdk, sid: []const u8, allow_retry: bool) !DeleteResult {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    var attempt: u32 = 0;
    while (true) {
        const res = try self.controlRaw(.DELETE, path, null, &.{}, buf);
        if (res.ok()) return .deleted;
        if (res.status == 404) return .already_gone;
        const status = res.status;
        const body = try self.arena.dupe(u8, res.body);
        if (allow_retry and (status == 503 or status == 409 or status == 408) and attempt < 3) {
            var wait_s: u64 = 2;
            if (res.header("Retry-After")) |v| {
                wait_s = @min(std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch 2, 30);
            }
            attempt += 1;
            if (wait_s > 0) try std.Io.sleep(self.io, .fromSeconds(@intCast(wait_s)), .awake);
            continue;
        }
        self.last_status = status;
        self.last_body = body;
        return error.HttpError;
    }
}
