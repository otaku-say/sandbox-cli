//! MCP 工具 —— 沙箱快照域。
//!
//! 包括创建快照、列出快照、回滚到快照以及删除快照。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_snapshot = @import("sdk_snapshot.zig");
const envd = @import("envd.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tSnapCreate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const name = try a.strOpt(srv.arena, "name");
    const body = sdk_snapshot.snapshotCreate(srv.sdk, sid, name) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    if (envd.extractString(srv.arena, body, "snapshotID")) |id| {
        return ToolResult.ok(id);
    }
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSnapList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = try a.strOpt(srv.arena, "sandbox_id");
    const backend = try a.strOpt(srv.arena, "backend");
    const next_token = try a.strOpt(srv.arena, "next");
    var limit: ?u32 = null;
    if (try a.intOpt(srv.arena, "limit")) |l| {
        if (l > 0) limit = @intCast(l);
    }

    const body = sdk_snapshot.snapshotList(srv.sdk, .{
        .sandbox_id = sid,
        .backend = backend,
        .limit = limit,
        .next_token = next_token,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSnapRollback(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const snap = a.str(srv.arena, "snapshot_id") catch return srv.argError(a);
    const wait = a.boolOr(srv.arena, "wait", false) catch return srv.argError(a);
    const timeout_raw = try a.intOr(srv.arena, "timeout", 60);
    const timeout_s: u64 = @intCast(@max(0, @min(timeout_raw, 120)));

    const body = sdk_snapshot.snapshotRollback(srv.sdk, sid, snap, wait, timeout_s) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        error.WaitTimeout => ToolResult.err(try std.fmt.allocPrint(srv.arena, "超时 {d}s：沙箱未恢复到 running 状态", .{timeout_s})),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSnapDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const snap = a.str(srv.arena, "snapshot_id") catch return srv.argError(a);
    sdk_snapshot.snapshotDelete(srv.sdk, snap) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "快照已删除：{s}", .{snap}) catch "已删除");
}

pub const tools = [_]Tool{
    .{
        .name = "snapshot_create",
        .description = "对指定沙箱打快照，记录当前磁盘与内存状态，返回 snapshotID。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"name":{"type":"string","description":"快照别名或备注"}},"required":["sandbox_id"]}
        ,
        .handler = tSnapCreate,
    },
    .{
        .name = "snapshot_list",
        .description = "查询快照列表（可按来源沙箱、后端存储过滤）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"按来源沙箱 ID 过滤"},"backend":{"type":"string","description":"按后端类型过滤（xfs/s3 等）"},"limit":{"type":"integer","description":"单页条数上限"},"next":{"type":"string","description":"翻页 token"}},"required":[]}
        ,
        .handler = tSnapList,
    },
    .{
        .name = "snapshot_rollback",
        .description = "【破坏性】将沙箱回滚到指定快照的状态（沙箱内未保存的变更将丢失）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"snapshot_id":{"type":"string","description":"快照 ID"},"wait":{"type":"boolean","description":"是否等待沙箱恢复到 running 状态，默认 false"},"timeout":{"type":"integer","description":"等待超时的秒数，默认 60"}},"required":["sandbox_id","snapshot_id"]}
        ,
        .handler = tSnapRollback,
    },
    .{
        .name = "snapshot_delete",
        .description = "【破坏性】删除指定快照。",
        .schema =
        \\{"type":"object","properties":{"snapshot_id":{"type":"string","description":"快照 ID"}},"required":["snapshot_id"]}
        ,
        .handler = tSnapDelete,
    },
};
