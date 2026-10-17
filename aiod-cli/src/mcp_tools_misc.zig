//! MCP 工具 —— 杂项域（代码执行、文件监听、MCP Hub、沙箱画像）。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_misc = @import("sdk_misc.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tCodeRun(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const code = a.str(srv.arena, "code") catch return srv.argError(a);
    const body = sdk_misc.codeRun(srv.sdk, .{
        .code = code,
        .language = try a.strOpt(srv.arena, "lang"),
        .session_id = try a.strOpt(srv.arena, "session"),
        .timeout = a.intOpt(srv.arena, "timeout") catch return srv.argError(a),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tCodeInfo(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_misc.codeInfo(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tWatchCreate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = try a.strOpt(srv.arena, "path");
    const recursive = (a.boolOpt(srv.arena, "recursive") catch return srv.argError(a)) orelse false;
    const debounce = a.intOpt(srv.arena, "debounce") catch return srv.argError(a);
    const exclude = a.strArrayOpt(srv.arena, "exclude") catch return srv.argError(a);
    const include = a.strArrayOpt(srv.arena, "include") catch return srv.argError(a);

    const body = sdk_misc.watchCreate(srv.sdk, .{
        .path = path,
        .recursive = recursive,
        .debounce = debounce,
        .exclude = exclude,
        .include_patterns = include,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tWatchPoll(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const wid = a.str(srv.arena, "watcher_id") catch return srv.argError(a);
    const cursor = try a.strOpt(srv.arena, "cursor");
    const limit = (a.intOpt(srv.arena, "limit") catch return srv.argError(a)) orelse 100;
    const timeout = (a.intOpt(srv.arena, "timeout") catch return srv.argError(a)) orelse 30;

    const body = sdk_misc.watchPoll(srv.sdk, wid, cursor, limit, timeout) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tWatchRm(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const wid = a.str(srv.arena, "watcher_id") catch return srv.argError(a);
    const body = sdk_misc.watchRm(srv.sdk, wid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tWatchLs(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_misc.watchLs(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tMcpHub(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const method = a.str(srv.arena, "method") catch return srv.argError(a);
    var params_json: ?[]const u8 = null;
    if (a.jsonOpt("params")) |p| {
        params_json = argmod.Args.jsonText(srv.arena, p) catch return srv.argError(a);
    }
    const body = sdk_misc.mcpHub(srv.sdk, method, params_json) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxInfo(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_misc.sandboxInfo(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "sandbox_info",
        .description = "获取当前 CubeSandbox 沙箱画像与基础信息（镜像、平台版本、配置等）。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tSandboxInfo,
    },
    .{
        .name = "code_run",
        .description = "在沙箱内运行一段 Python 或 JavaScript 代码片段。",
        .schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"要执行的代码源码"},"lang":{"type":"string","description":"编程语言：python|javascript，缺省为 python"},"session":{"type":"string","description":"可选的有状态代码会话 ID"},"timeout":{"type":"integer","description":"执行超时秒数"}},"required":["code"]}
        ,
        .handler = tCodeRun,
    },
    .{
        .name = "code_info",
        .description = "查询沙箱内代码运行环境的元数据（支持语言、运行时版本等）。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tCodeInfo,
    },
    .{
        .name = "watch_create",
        .description = "在沙箱文件系统指定路径创建变更监听器（inotify/fsnotify）。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"监听目录或文件路径，缺省为 /"},"recursive":{"type":"boolean","description":"是否递归监听子目录"},"debounce":{"type":"integer","description":"防抖毫秒数"},"exclude":{"type":"array","items":{"type":"string"},"description":"排除文件模式列表"},"include":{"type":"array","items":{"type":"string"},"description":"包含文件模式列表"}},"required":[]}
        ,
        .handler = tWatchCreate,
    },
    .{
        .name = "watch_poll",
        .description = "长轮询拉取指定监听器累积的文件变更事件列表。",
        .schema =
        \\{"type":"object","properties":{"watcher_id":{"type":"string","description":"监听器 ID"},"cursor":{"type":"string","description":"起始事件游标"},"limit":{"type":"integer","description":"单次最多返回事件数"},"timeout":{"type":"integer","description":"长轮询等待超时秒数"}},"required":["watcher_id"]}
        ,
        .handler = tWatchPoll,
    },
    .{
        .name = "watch_rm",
        .description = "移除并停止指定的文件系统监听器。",
        .schema =
        \\{"type":"object","properties":{"watcher_id":{"type":"string","description":"要销毁的监听器 ID"}},"required":["watcher_id"]}
        ,
        .handler = tWatchRm,
    },
    .{
        .name = "watch_ls",
        .description = "列出当前沙箱内所有活跃的文件系统监听器。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tWatchLs,
    },
    .{
        .name = "mcp_hub",
        .description = "调用沙箱内运行的内置 MCP Hub 服务端方法（反向代理调用）。",
        .schema =
        \\{"type":"object","properties":{"method":{"type":"string","description":"JSON-RPC 方法名（如 initialize / tools/list / tools/call）"},"params":{"type":"object","description":"可选方法参数对象"}},"required":["method"]}
        ,
        .handler = tMcpHub,
    },
};
