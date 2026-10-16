//! MCP 工具 —— PTY 域（/v2/pty/sessions/*）。
//!
//! 提供虚拟终端会话的创建、列表、抓屏、执行、输入、信号、调整大小和删除。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_pty = @import("sdk_pty.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tPtyNew(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const body = sdk_pty.create(srv.sdk, .{
        .id = sid,
        .cwd = a.strOpt("cwd"),
        .cols = a.intOpt(srv.arena, "cols") catch return srv.argError(a),
        .rows = a.intOpt(srv.arena, "rows") catch return srv.argError(a),
        .retention = a.strOpt("retention"),
        .user = a.strOpt("user"),
        .no_change_timeout = a.intOpt(srv.arena, "no_change_timeout") catch return srv.argError(a),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tPtyList(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_pty.list(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tPtyScreen(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const body = sdk_pty.screen(srv.sdk, sid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tPtyExec(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const command = a.str(srv.arena, "command") catch return srv.argError(a);
    const timeout = a.intOpt(srv.arena, "timeout") catch return srv.argError(a);
    const body = sdk_pty.exec(srv.sdk, .{
        .id = sid,
        .command = command,
        .timeout = timeout,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tPtyInput(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const text = a.str(srv.arena, "text") catch return srv.argError(a);
    const enter = (a.boolOpt(srv.arena, "enter") catch return srv.argError(a)) orelse false;
    const body = sdk_pty.input(srv.sdk, sid, text, enter) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tPtyDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const body = sdk_pty.delete(srv.sdk, sid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const text = std.fmt.allocPrint(srv.arena, "deleted pty session {s}\n{s}", .{ sid, body }) catch "deleted";
    return ToolResult.ok(text);
}

fn tPtySignal(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const sig = a.strOpt("signal") orelse "SIGINT";
    const body = sdk_pty.signal(srv.sdk, sid, sig) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tPtyResize(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const cols = a.intOpt(srv.arena, "cols") catch return srv.argError(a);
    const rows = a.intOpt(srv.arena, "rows") catch return srv.argError(a);
    const body = sdk_pty.resize(srv.sdk, sid, cols, rows, null) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "pty_new",
        .description = "新建一个虚拟终端 PTY 会话。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"PTY 会话 ID"},"cwd":{"type":"string","description":"工作目录"},"user":{"type":"string","description":"执行用户"},"cols":{"type":"integer","description":"终端列数"},"rows":{"type":"integer","description":"终端行数"},"retention":{"type":"string","description":"保留策略"},"no_change_timeout":{"type":"integer","description":"无变更超时秒数"}},"required":["session_id"]}
        ,
        .handler = tPtyNew,
    },
    .{
        .name = "pty_list",
        .description = "列出沙箱内当前活动的所有 PTY 终端会话。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tPtyList,
    },
    .{
        .name = "pty_screen",
        .description = "抓取指定 PTY 会话当前的终端屏幕输出快照内容。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"目标 PTY 会话 ID"}},"required":["session_id"]}
        ,
        .handler = tPtyScreen,
    },
    .{
        .name = "pty_exec",
        .description = "在指定 PTY 终端会话内执行命令。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"PTY 会话 ID"},"command":{"type":"string","description":"要发送并执行的命令"},"timeout":{"type":"integer","description":"执行等待超时秒数"}},"required":["session_id","command"]}
        ,
        .handler = tPtyExec,
    },
    .{
        .name = "pty_input",
        .description = "向指定 PTY 会话的标准输入发送按键或文本输入。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"目标 PTY 会话 ID"},"text":{"type":"string","description":"输入的文本"},"enter":{"type":"boolean","description":"是否在末尾附带回车换行"}},"required":["session_id","text"]}
        ,
        .handler = tPtyInput,
    },
    .{
        .name = "pty_delete",
        .description = "关闭并销毁指定的 PTY 终端会话（具有破坏性）。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"要销毁的 PTY 会话 ID"}},"required":["session_id"]}
        ,
        .handler = tPtyDelete,
    },
    .{
        .name = "pty_signal",
        .description = "向 PTY 终端会话进程发送信号（如 SIGINT / SIGKILL / SIGTERM）。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"PTY 会话 ID"},"signal":{"type":"string","description":"信号名称，缺省为 SIGINT"}},"required":["session_id"]}
        ,
        .handler = tPtySignal,
    },
    .{
        .name = "pty_resize",
        .description = "调整 PTY 终端会话的窗口大小（行列数）。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"PTY 会话 ID"},"cols":{"type":"integer","description":"新列数"},"rows":{"type":"integer","description":"新行数"}},"required":["session_id"]}
        ,
        .handler = tPtyResize,
    },
};
