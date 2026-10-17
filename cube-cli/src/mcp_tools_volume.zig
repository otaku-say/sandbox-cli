//! MCP 工具 —— 持久卷域。
//!
//! 包括查询卷列表、创建卷、查看卷详情以及删除卷。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_volume = @import("sdk_volume.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tVolList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    _ = a;
    const body = sdk_volume.volumeList(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tVolCreate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    if (a.has("name") and try a.strOpt(srv.arena, "name") == null) {
        return ToolResult.err("参数错误：name 需要是字符串");
    }
    if (a.has("driver") and try a.strOpt(srv.arena, "driver") == null) {
        return ToolResult.err("参数错误：driver 需要是字符串");
    }
    const name = try a.strOpt(srv.arena, "name");
    const driver = try a.strOpt(srv.arena, "driver");
    const body = sdk_volume.volumeCreate(srv.sdk, name, driver) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tVolInfo(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const vid = a.str(srv.arena, "volume_id") catch return srv.argError(a);
    const body = sdk_volume.volumeInfo(srv.sdk, vid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tVolDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const vid = a.str(srv.arena, "volume_id") catch return srv.argError(a);
    sdk_volume.volumeDelete(srv.sdk, vid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "持久卷已删除：{s}", .{vid}) catch "已删除");
}

pub const tools = [_]Tool{
    .{
        .name = "volume_list",
        .description = "查询当前所有持久卷列表（volumeID 与名称）。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tVolList,
    },
    .{
        .name = "volume_create",
        .description = "新建持久卷，名字省略时由服务端生成。",
        .schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"卷名称（可选）"},"driver":{"type":"string","description":"底层存储驱动（如 cos / s3 / nfs 等）"}},"required":[]}
        ,
        .handler = tVolCreate,
    },
    .{
        .name = "volume_info",
        .description = "查看单个持久卷详情（名称、token、挂载信息）。",
        .schema =
        \\{"type":"object","properties":{"volume_id":{"type":"string","description":"持久卷 ID"}},"required":["volume_id"]}
        ,
        .handler = tVolInfo,
    },
    .{
        .name = "volume_delete",
        .description = "【破坏性】删除持久卷。若卷仍被沙箱挂载，服务端将返回冲突错误。",
        .schema =
        \\{"type":"object","properties":{"volume_id":{"type":"string","description":"持久卷 ID"}},"required":["volume_id"]}
        ,
        .handler = tVolDelete,
    },
};
