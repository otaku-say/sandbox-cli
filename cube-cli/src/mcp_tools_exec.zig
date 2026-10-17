//! MCP 工具 —— 沙箱进程与代码执行域。
//!
//! 包括同步命令执行、后台异步命令执行、增量日志拉取、信号发送、输入写入与代码运行。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_exec = @import("sdk_exec.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tExec(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const cmd = a.str(srv.arena, "command") catch return srv.argError(a);
    const cwd = try a.strOpt(srv.arena, "cwd");
    const user = try a.strOpt(srv.arena, "user");
    const timeout_s: u64 = @intCast(@max(0, try a.intOr(srv.arena, "timeout", 0)));
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);

    const r = sdk_exec.sandboxExec(srv.sdk, sid, cmd, .{
        .cwd = cwd,
        .env_json = env_json,
        .user = user,
        .timeout_s = timeout_s,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };

    var w = std.Io.Writer.fixed(try srv.arena.alloc(u8, types.max_text_bytes));
    if (r.stdout.len > 0) try w.writeAll(r.stdout);
    if (r.stderr.len > 0) {
        if (w.buffered().len > 0 and w.buffered()[w.buffered().len - 1] != '\n') try w.writeAll("\n");
        try w.print("--- stderr ---\n{s}", .{r.stderr});
    }
    if (r.exit_code != 0) {
        if (w.buffered().len > 0 and w.buffered()[w.buffered().len - 1] != '\n') try w.writeAll("\n");
        try w.print("（exit {d}）", .{r.exit_code});
    }
    return ToolResult.ok(types.clampText(srv.arena, w.buffered()));
}

fn tExecAsync(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const cmd = a.str(srv.arena, "command") catch return srv.argError(a);
    const cwd = try a.strOpt(srv.arena, "cwd");
    const user = try a.strOpt(srv.arena, "user");
    const timeout_s: u64 = @intCast(@max(0, try a.intOr(srv.arena, "timeout", 0)));
    const no_stdin = a.boolOr(srv.arena, "no_stdin", false) catch return srv.argError(a);
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);

    const r = sdk_exec.sandboxExecAsync(srv.sdk, sid, cmd, .{
        .cwd = cwd,
        .env_json = env_json,
        .user = user,
        .timeout_s = timeout_s,
    }, no_stdin) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };

    const out = try std.fmt.allocPrint(srv.arena, "pid {d}\n  stdout {s}\n  stderr {s}", .{ r.pid, r.stdout_file, r.stderr_file });
    return ToolResult.ok(out);
}

fn tExecLogs(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const pid = a.intReq(srv.arena, "pid") catch return srv.argError(a);
    const off_out: u64 = @intCast(@max(0, try a.intOr(srv.arena, "offset", 0)));
    const off_err: u64 = @intCast(@max(0, try a.intOr(srv.arena, "stderr_offset", 0)));
    const limit: u64 = @intCast(@max(0, try a.intOr(srv.arena, "max", 0)));
    const user = try a.strOpt(srv.arena, "user");

    const r = sdk_exec.sandboxExecLogs(srv.sdk, sid, pid, user, off_out, off_err, limit) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        error.NoMeta => ToolResult.err("未找到该 pid 的执行记录"),
        else => ToolResult.err(@errorName(e)),
    };

    var w = std.Io.Writer.fixed(try srv.arena.alloc(u8, types.max_text_bytes));
    if (r.stdout.len > 0) try w.writeAll(r.stdout);
    if (r.stderr.len > 0) {
        if (w.buffered().len > 0 and w.buffered()[w.buffered().len - 1] != '\n') try w.writeAll("\n");
        try w.print("--- stderr ---\n{s}", .{r.stderr});
    }
    if (w.buffered().len > 0 and w.buffered()[w.buffered().len - 1] != '\n') try w.writeAll("\n");
    try w.print("[exec-logs] stdout 偏移 {d} B；stderr 偏移 {d} B；", .{ r.next_offset, r.next_stderr_offset });
    if (r.exit_code) |code| {
        try w.print("退出码 {d}", .{code});
    } else if (r.is_alive) {
        try w.writeAll("进程仍在运行");
    } else {
        try w.writeAll("进程已结束");
    }
    return ToolResult.ok(types.clampText(srv.arena, w.buffered()));
}

fn tExecKill(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const pid = a.intReq(srv.arena, "pid") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    const sig = try a.strOpt(srv.arena, "signal");

    sdk_exec.sandboxExecKill(srv.sdk, sid, pid, user, sig) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    if (srv.sdk.last_status == 404) {
        return ToolResult.ok(try std.fmt.allocPrint(srv.arena, "pid {d} 已不存在（可能已退出）", .{pid}));
    }
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "已向 pid {d} 发送信号 {s}", .{ pid, sig orelse "SIGNAL_SIGKILL" }) catch "信号已发送");
}

fn tExecStdin(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const pid = a.intReq(srv.arena, "pid") catch return srv.argError(a);
    const data = a.str(srv.arena, "data") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");

    sdk_exec.sandboxExecStdin(srv.sdk, sid, pid, user, data) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "已向 pid {d} 输入 {d} 字节", .{ pid, data.len }) catch "输入已发送");
}

fn tCode(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const code = a.str(srv.arena, "code") catch return srv.argError(a);
    const mode = try a.strOpt(srv.arena, "mode") orelse "interp";
    const lang = try a.strOpt(srv.arena, "lang") orelse "python";
    const timeout_s: u64 = @intCast(@max(0, try a.intOr(srv.arena, "timeout", 0)));
    const user = try a.strOpt(srv.arena, "user");
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);

    const r = sdk_exec.sandboxCode(srv.sdk, sid, code, .{
        .mode = mode,
        .lang = lang,
        .timeout_s = timeout_s,
        .env_json = env_json,
        .user = user,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        error.BadMode => ToolResult.err("不支持的执行模式（支持 interp / kernel）"),
        error.BadLang => ToolResult.err("不支持的编程语言（支持 python / js / bash）"),
        else => ToolResult.err(@errorName(e)),
    };

    var w = std.Io.Writer.fixed(try srv.arena.alloc(u8, types.max_text_bytes));
    if (r.stdout.len > 0) try w.writeAll(r.stdout);
    if (r.stderr.len > 0) {
        if (w.buffered().len > 0 and w.buffered()[w.buffered().len - 1] != '\n') try w.writeAll("\n");
        try w.print("--- stderr ---\n{s}", .{r.stderr});
    }
    if (r.exit_code != 0) {
        if (w.buffered().len > 0 and w.buffered()[w.buffered().len - 1] != '\n') try w.writeAll("\n");
        try w.print("（exit {d}）", .{r.exit_code});
    }
    return ToolResult.ok(types.clampText(srv.arena, w.buffered()));
}

pub const tools = [_]Tool{
    .{
        .name = "sandbox_exec",
        .description = "在沙箱内同步执行命令，等待执行完成并返回 stdout/stderr 及退出状态。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"command":{"type":"string","description":"要执行的完整命令"},"cwd":{"type":"string","description":"工作目录"},"env":{"type":"object","description":"环境变量键值对"},"user":{"type":"string","description":"执行用户"},"timeout":{"type":"integer","description":"执行超时秒数"}},"required":["sandbox_id","command"]}
        ,
        .handler = tExec,
    },
    .{
        .name = "sandbox_exec_async",
        .description = "在沙箱内后台异步启动命令，立即返回 pid 与输出落盘路径。后续用 sandbox_exec_logs 拉取日志。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"command":{"type":"string","description":"要启动的完整命令"},"cwd":{"type":"string","description":"工作目录"},"env":{"type":"object","description":"环境变量键值对"},"user":{"type":"string","description":"执行用户"},"timeout":{"type":"integer","description":"执行超时秒数"},"no_stdin":{"type":"boolean","description":"是否关闭 stdin（默认保持打开）"}},"required":["sandbox_id","command"]}
        ,
        .handler = tExecAsync,
    },
    .{
        .name = "sandbox_exec_logs",
        .description = "增量拉取异步命令的 stdout/stderr 日志与退出码（按字节偏移增量拉取，不支持持续 follow）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"pid":{"type":"integer","description":"异步进程的 pid"},"offset":{"type":"integer","description":"stdout 起始字节偏移量，默认 0"},"stderr_offset":{"type":"integer","description":"stderr 起始字节偏移量，默认 0"},"max":{"type":"integer","description":"最大拉取字节数"},"user":{"type":"string","description":"执行用户"}},"required":["sandbox_id","pid"]}
        ,
        .handler = tExecLogs,
    },
    .{
        .name = "sandbox_exec_kill",
        .description = "【破坏性】向沙箱内的异步进程发送终止信号（默认 SIGKILL）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"pid":{"type":"integer","description":"进程 pid"},"signal":{"type":"string","description":"信号名称（SIGNAL_SIGKILL 或 SIGNAL_SIGTERM）"},"user":{"type":"string","description":"执行用户"}},"required":["sandbox_id","pid"]}
        ,
        .handler = tExecKill,
    },
    .{
        .name = "sandbox_exec_stdin",
        .description = "向沙箱内正在运行的异步命令发送标准输入数据。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"pid":{"type":"integer","description":"目标进程 pid"},"data":{"type":"string","description":"要送入的文本或数据"},"user":{"type":"string","description":"执行用户"}},"required":["sandbox_id","pid","data"]}
        ,
        .handler = tExecStdin,
    },
    .{
        .name = "sandbox_code",
        .description = "在沙箱内运行一段代码（支持 python/js/bash；默认 interp 解释器模式，或 kernel 内核模式）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"code":{"type":"string","description":"待执行的代码文本"},"mode":{"type":"string","description":"执行模式：interp（默认）或 kernel"},"lang":{"type":"string","description":"编程语言：python（默认）、js 或 bash"},"timeout":{"type":"integer","description":"超时秒数"},"env":{"type":"object","description":"环境变量键值对"},"user":{"type":"string","description":"执行用户"}},"required":["sandbox_id","code"]}
        ,
        .handler = tCode,
    },
};
