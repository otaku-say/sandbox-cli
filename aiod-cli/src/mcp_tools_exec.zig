//! MCP 工具 —— 命令执行与会话管理域（/v2/commands/*）。
//!
//! handler 只做三件事：读参数（mcp_args）→ 调 SDK → 组织结果文本。
//! 严格禁止：打印到 stdout、std.process.exit、内联重造 HTTP 请求。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_exec = @import("sdk_exec.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

/// 运行类响应的紧凑文本：command_id / status / exit_code + stdout/stderr。
pub fn renderRun(srv: *Server, body: []const u8) anyerror![]const u8 {
    const v = sdkmod.parse(srv.arena, body) orelse return body;
    const id = sdkmod.fieldStr(v, "command_id") orelse "";
    const status = sdkmod.fieldStr(v, "status") orelse "";
    const exit_code = sdkmod.fieldInt(v, "exit_code");
    const stdout = sdkmod.fieldStr(v, "stdout") orelse "";
    const stderr = sdkmod.fieldStr(v, "stderr") orelse "";
    var w = std.Io.Writer.fixed(try srv.arena.alloc(u8, stdout.len + stderr.len + 4096));
    try w.print("command_id={s} status={s}", .{ id, status });
    if (exit_code) |c| try w.print(" exit_code={d}", .{c});
    try w.writeAll("\n");
    if (stdout.len > 0) {
        try w.writeAll("--- stdout ---\n");
        try w.writeAll(stdout);
        if (stdout[stdout.len - 1] != '\n') try w.writeAll("\n");
    }
    if (stderr.len > 0) {
        try w.writeAll("--- stderr ---\n");
        try w.writeAll(stderr);
        if (stderr[stderr.len - 1] != '\n') try w.writeAll("\n");
    }
    if (stdout.len == 0 and stderr.len == 0) {
        return body;
    }
    return w.buffered();
}

fn tExec(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const command = a.str(srv.arena, "command") catch return srv.argError(a);
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);
    const body = sdk_exec.run(srv.sdk, .{
        .command = command,
        .cwd = a.strOpt("cwd"),
        .shell = a.strOpt("shell"),
        .user = a.strOpt("user"),
        .session = a.strOpt("session"),
        .env_json = env_json,
        .timeout_ms = a.intOpt(srv.arena, "timeout") catch return srv.argError(a),
        .hard_timeout_s = a.intOpt(srv.arena, "hard_timeout") catch return srv.argError(a),
        .max_output = a.intOpt(srv.arena, "max_output") catch return srv.argError(a),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const rendered = renderRun(srv, body) catch body;
    return ToolResult.ok(types.clampText(srv.arena, rendered));
}

fn tExecAsync(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const command = a.str(srv.arena, "command") catch return srv.argError(a);
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);
    const body = sdk_exec.run(srv.sdk, .{
        .command = command,
        .cwd = a.strOpt("cwd"),
        .shell = a.strOpt("shell"),
        .user = a.strOpt("user"),
        .session = a.strOpt("session"),
        .env_json = env_json,
        .hard_timeout_s = a.intOpt(srv.arena, "hard_timeout") catch return srv.argError(a),
        .max_output = a.intOpt(srv.arena, "max_output") catch return srv.argError(a),
        .mode = "async",
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    if (sdkmod.parse(srv.arena, body)) |v| {
        if (sdkmod.fieldStr(v, "command_id")) |id| {
            return ToolResult.ok(std.fmt.allocPrint(srv.arena, "command_id={s}\n{s}", .{ id, body }) catch body);
        }
    }
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tExecLogs(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const cid = a.str(srv.arena, "command_id") catch return srv.argError(a);
    const wait = (a.boolOpt(srv.arena, "wait") catch return srv.argError(a)) orelse false;
    const body = sdk_exec.logs(srv.sdk, .{
        .command_id = cid,
        .offset = a.intOpt(srv.arena, "offset") catch return srv.argError(a),
        .stderr_offset = a.intOpt(srv.arena, "stderr_offset") catch return srv.argError(a),
        .wait = wait,
        .wait_timeout = a.intOpt(srv.arena, "wait_timeout") catch return srv.argError(a),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const rendered = renderRun(srv, body) catch body;
    return ToolResult.ok(types.clampText(srv.arena, rendered));
}

fn tExecKill(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const cid = a.str(srv.arena, "command_id") catch return srv.argError(a);
    const sig = a.strOpt("signal");
    const body = sdk_exec.kill(srv.sdk, cid, sig) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const text = std.fmt.allocPrint(srv.arena, "killed {s}\n{s}", .{ cid, body }) catch "killed";
    return ToolResult.ok(text);
}

fn tExecStdin(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const cid = a.str(srv.arena, "command_id") catch return srv.argError(a);
    const text = a.str(srv.arena, "text") catch return srv.argError(a);
    const enter = (a.boolOpt(srv.arena, "enter") catch return srv.argError(a)) orelse false;
    const body = sdk_exec.stdin(srv.sdk, cid, text, enter) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(if (body.len > 0) body else "ok");
}

fn tSessionCreate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);
    const body = sdk_exec.sessionCreate(srv.sdk, sid, a.strOpt("cwd"), a.strOpt("user"), env_json) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSessionList(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_exec.sessionList(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSessionDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const body = sdk_exec.sessionDelete(srv.sdk, sid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const text = std.fmt.allocPrint(srv.arena, "removed {s}\n{s}", .{ sid, body }) catch "removed";
    return ToolResult.ok(text);
}

fn tExecInSession(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "session_id") catch return srv.argError(a);
    const command = a.str(srv.arena, "command") catch return srv.argError(a);
    const timeout = a.intOpt(srv.arena, "timeout") catch return srv.argError(a);
    const body = sdk_exec.run(srv.sdk, .{
        .command = command,
        .session = sid,
        .timeout_ms = timeout,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    const rendered = renderRun(srv, body) catch body;
    return ToolResult.ok(types.clampText(srv.arena, rendered));
}

pub const tools = [_]Tool{
    .{
        .name = "exec",
        .description = "在沙箱内同步执行一条命令并返回 stdout/stderr/exit_code（非 0 退出码不代表调用失败）。",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"要执行的命令（shell 语义）"},"cwd":{"type":"string","description":"工作目录"},"shell":{"type":"string","description":"shell：auto|bash|sh|powershell|cmd|none"},"user":{"type":"string","description":"以哪个用户执行"},"session":{"type":"string","description":"在指定命令会话里执行"},"env":{"type":"object","description":"环境变量对象，值必须是字符串"},"timeout":{"type":"integer","description":"毫秒；到点返回 status=running（进程仍在跑）"},"hard_timeout":{"type":"integer","description":"秒；到点服务端强杀"},"max_output":{"type":"integer","description":"输出字节上限"}},"required":["command"]}
        ,
        .handler = tExec,
    },
    .{
        .name = "exec_async",
        .description = "在沙箱内异步后台执行一条命令，立即返回 command_id 供后续查询日志或等待。",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"要执行的命令"},"cwd":{"type":"string","description":"工作目录"},"shell":{"type":"string","description":"shell 类型"},"user":{"type":"string","description":"执行用户"},"session":{"type":"string","description":"命令会话 ID"},"env":{"type":"object","description":"环境变量对象"},"hard_timeout":{"type":"integer","description":"秒；到点强杀"},"max_output":{"type":"integer","description":"输出字节上限"}},"required":["command"]}
        ,
        .handler = tExecAsync,
    },
    .{
        .name = "exec_logs",
        .description = "按 command_id 读取已执行或正在运行命令的增量日志与状态；可指定 wait 等待完成。",
        .schema =
        \\{"type":"object","properties":{"command_id":{"type":"string","description":"命令 ID"},"offset":{"type":"integer","description":"stdout 起始字节偏移"},"stderr_offset":{"type":"integer","description":"stderr 起始字节偏移"},"wait":{"type":"boolean","description":"是否阻塞等待命令完成"},"wait_timeout":{"type":"integer","description":"等待超时秒数"}},"required":["command_id"]}
        ,
        .handler = tExecLogs,
    },
    .{
        .name = "exec_kill",
        .description = "强杀或向沙箱内正在运行的命令发送信号（具有破坏性）。",
        .schema =
        \\{"type":"object","properties":{"command_id":{"type":"string","description":"命令 ID"},"signal":{"type":"string","description":"发送的信号，默认 SIGKILL"}},"required":["command_id"]}
        ,
        .handler = tExecKill,
    },
    .{
        .name = "exec_stdin",
        .description = "向正在运行的异步命令的标准输入 stdin 写入数据。",
        .schema =
        \\{"type":"object","properties":{"command_id":{"type":"string","description":"命令 ID"},"text":{"type":"string","description":"要写入的文本内容"},"enter":{"type":"boolean","description":"是否在末尾自动追加换行"}},"required":["command_id","text"]}
        ,
        .handler = tExecStdin,
    },
    .{
        .name = "session_create",
        .description = "在沙箱内创建一个持久化环境的命令会话（保持当前工作目录与环境变量）。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"会话 ID"},"cwd":{"type":"string","description":"会话默认工作目录"},"user":{"type":"string","description":"会话默认用户"},"env":{"type":"object","description":"会话预置环境变量"}},"required":["session_id"]}
        ,
        .handler = tSessionCreate,
    },
    .{
        .name = "session_list",
        .description = "列出沙箱内当前存在的所有命令会话。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tSessionList,
    },
    .{
        .name = "session_delete",
        .description = "删除指定的命令会话及其持久化状态（具有破坏性）。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"要删除的会话 ID"}},"required":["session_id"]}
        ,
        .handler = tSessionDelete,
    },
    .{
        .name = "exec_in_session",
        .description = "在指定的持久化命令会话中执行命令并返回输出。",
        .schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"目标命令会话 ID"},"command":{"type":"string","description":"要执行的命令"},"timeout":{"type":"integer","description":"超时毫秒数"}},"required":["session_id","command"]}
        ,
        .handler = tExecInSession,
    },
};
