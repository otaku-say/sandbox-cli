//! MCP 工具 —— 任意控制面 API 透传（api_call）。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_raw = @import("sdk_raw.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tApiCall(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const method = a.str(srv.arena, "method") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const body = try a.strOpt(srv.arena, "body");
    const query = try a.objOpt(srv.arena, "query");

    const res = sdk_raw.apiCall(srv.sdk, method, path, body, query) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        error.BadMethod => ToolResult.err("不支持的 HTTP 方法"),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, res));
}

pub const tools = [_]Tool{
    .{
        .name = "api_call",
        .description = "向控制面任意 API 端点发送 HTTP 请求（GET/POST/PUT/DELETE 等），支持透传查询参数与请求体。",
        .schema =
        \\{"type":"object","properties":{"method":{"type":"string","description":"HTTP 方法（GET / POST / PUT / DELETE 等）"},"path":{"type":"string","description":"API 路径，如 /sandboxes 或 /health"},"body":{"type":"string","description":"请求体 JSON 字符串（POST / PUT 等使用）"},"query":{"type":"object","description":"URL 查询参数键值对"}},"required":["method","path"]}
        ,
        .handler = tApiCall,
    },
};
