//! Core SDK —— 快照域操作（控制面 REST）。
//!
//! 包含创建快照、查询快照列表、回滚到快照以及删除快照。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const envd = @import("envd.zig");
const jsonfmt = @import("jsonfmt.zig");
const sdk_lifecycle = @import("sdk_lifecycle.zig");

const Sdk = sdkmod.Sdk;

/// 创建快照（POST /sandboxes/<id>/snapshots）。
pub fn snapshotCreate(self: *Sdk, sid: []const u8, name: ?[]const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/snapshots", .{sid});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const body = if (name) |n|
        try std.fmt.allocPrint(self.arena, "{{\"name\":\"{s}\"}}", .{try envd.jsonEscape(self.arena, n)})
    else
        "{}";
    const res = try self.control(.POST, path, body, buf);
    return self.arena.dupe(u8, res.body);
}

pub const SnapListQuery = struct {
    sandbox_id: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    limit: ?u32 = null,
    next_token: ?[]const u8 = null,
};

pub const SnapListResult = struct {
    body: []const u8,
    next_token: ?[]const u8 = null,
};

/// 查询快照列表（GET /snapshots?...），带翻页 token。
pub fn snapshotListWithToken(self: *Sdk, q: SnapListQuery) !SnapListResult {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("/snapshots");
    var sep: u8 = '?';
    if (q.sandbox_id) |s| {
        try w.print("{c}sandboxID={s}", .{ sep, try jsonfmt.qenc(self.arena, s, false) });
        sep = '&';
    }
    if (q.backend) |b| {
        try w.print("{c}backend={s}", .{ sep, try jsonfmt.qenc(self.arena, b, false) });
        sep = '&';
    }
    if (q.limit) |l| {
        if (l > 0) {
            try w.print("{c}limit={d}", .{ sep, l });
            sep = '&';
        }
    }
    if (q.next_token) |nt| {
        if (nt.len > 0) {
            try w.print("{c}nextToken={s}", .{ sep, try jsonfmt.qenc(self.arena, nt, false) });
            sep = '&';
        }
    }
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.GET, w.buffered(), null, buf);
    const nt: ?[]const u8 = if (res.header("x-next-token")) |v| (if (v.len > 0) try self.arena.dupe(u8, v) else null) else null;
    return .{ .body = try self.arena.dupe(u8, res.body), .next_token = nt };
}

/// 查询快照列表（GET /snapshots?...）。返回响应体 JSON。
pub fn snapshotList(self: *Sdk, q: SnapListQuery) ![]const u8 {
    const r = try snapshotListWithToken(self, q);
    return r.body;
}

/// 回滚沙箱到指定快照（POST /sandboxes/<id>/rollback）。
pub fn snapshotRollback(self: *Sdk, sid: []const u8, snapshot_id: []const u8, wait: bool, timeout_s: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(self.arena, "/sandboxes/{s}/rollback", .{sid});
    const body = try std.fmt.allocPrint(self.arena, "{{\"snapshotID\":\"{s}\"}}", .{try envd.jsonEscape(self.arena, snapshot_id)});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.control(.POST, path, body, buf);
    const ret_body = try self.arena.dupe(u8, res.body);

    if (wait) {
        _ = try sdk_lifecycle.sandboxInfo(self, sid, .{ .wait_state = "running", .timeout_s = timeout_s });
    }

    return ret_body;
}

/// 删除快照（DELETE /templates/<snapshotID>）。
pub fn snapshotDelete(self: *Sdk, snapshot_id: []const u8) !void {
    const path = try std.fmt.allocPrint(self.arena, "/templates/{s}", .{snapshot_id});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    _ = try self.control(.DELETE, path, null, buf);
}
