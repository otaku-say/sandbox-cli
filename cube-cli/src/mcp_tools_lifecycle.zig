//! MCP 工具 —— 沙箱生命周期域（**样例实现**：其余域的写法照此扩展）。
//!
//! handler 只做三件事：读参数（mcp_args）→ 调 SDK → 组织结果文本。
//! 严格禁止：打印到 stdout、std.process.exit、内联重造 HTTP 请求。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_lifecycle = @import("sdk_lifecycle.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tSandboxList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const md = try a.strArrayOpt(srv.arena, "metadata") orelse &.{};
    const q = sdk_lifecycle.ListQuery{
        .metadata = md,
        .state = a.strOpt("state"),
        .limit = a.strOpt("limit"),
        .v2 = try a.boolOr(srv.arena, "v2", false),
    };
    const body = sdk_lifecycle.sandboxList(srv.sdk, q) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxInfo(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const wait_state = a.strOpt("wait");
    const timeout_s: u64 = @intCast(@max(0, a.intOr(srv.arena, "timeout", 120) catch 120));
    const body = sdk_lifecycle.sandboxInfo(srv.sdk, sid, .{ .wait_state = wait_state, .timeout_s = timeout_s }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxPause(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    sdk_lifecycle.sandboxPause(srv.sdk, sid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(try std.fmt.allocPrint(srv.arena, "{{\"sandbox_id\":\"{s}\",\"state\":\"pause_requested\"}}", .{sid}));
}

fn tSandboxDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const r = sdk_lifecycle.sandboxDelete(srv.sdk, sid, true) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const verb: []const u8 = switch (r) {
        .deleted => "deleted",
        .already_gone => "already_gone",
    };
    return ToolResult.ok(try std.fmt.allocPrint(srv.arena, "{{\"sandbox_id\":\"{s}\",\"result\":\"{s}\"}}", .{ sid, verb }));
}

pub const tools = [_]Tool{
    .{
        .name = "sandbox_list",
        .description = "列出账号下所有 CubeSandbox（ID/模板/状态/备注）。可按 state 过滤（自动走 v2 接口）。",
        .schema =
        \\{"type":"object","properties":{"state":{"type":"string","description":"按状态过滤，如 running / paused"},"metadata":{"type":"array","items":{"type":"string"},"description":"metadata 过滤，形如 k=v"},"limit":{"type":"string","description":"条数上限（仅 v2 生效）"},"v2":{"type":"boolean","description":"强制走 /v2/sandboxes"}},"required":[]}
        ,
        .handler = tSandboxList,
    },
    .{
        .name = "sandbox_info",
        .description = "查看单个沙箱详情（状态/规格/元数据/卷挂载/截止时间）。可用 wait 轮询到指定状态。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"wait":{"type":"string","description":"轮询到该状态后返回，如 running"},"timeout":{"type":"integer","description":"wait 的上限秒数，默认 120"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxInfo,
    },
    .{
        .name = "sandbox_pause",
        .description = "暂停沙箱（挂起快照，0 成本）。恢复用 sandbox_resume（待实现）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxPause,
    },
    .{
        .name = "sandbox_delete",
        .description = "【破坏性·不可逆】销毁沙箱。404 视为已删除；503/409 自动按 Retry-After 重试最多 3 次。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxDelete,
    },
};
