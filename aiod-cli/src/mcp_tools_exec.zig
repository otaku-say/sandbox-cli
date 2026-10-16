//! MCP 工具 —— 执行 / 基础域（**样例实现**：其余域照此扩展）。
//!
//! handler 只做三件事：读参数（mcp_args）→ 调 SDK → 组织结果文本。
//! 严格禁止：打印到 stdout、std.process.exit、内联重造 HTTP 请求。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_exec = @import("sdk_exec.zig");
const sdk_files = @import("sdk_files.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

/// 运行类响应的紧凑文本：command_id / status / exit_code + stdout/stderr。
fn renderRun(srv: *Server, body: []const u8) anyerror![]const u8 {
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
        // 没解析出输出（例如异步派发）→ 原样回响应体，别丢信息
        return body;
    }
    return w.buffered();
}

fn tExec(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const command = a.str(srv.arena, "command") catch return srv.argError(a);
    const env_json = a.objJsonText(srv.arena, "env") catch return srv.argError(a);
    const spec = sdk_exec.RunSpec{
        .command = command,
        .cwd = a.strOpt("cwd"),
        .shell = a.strOpt("shell"),
        .user = a.strOpt("user"),
        .session = a.strOpt("session"),
        .env_json = env_json,
        .timeout_ms = a.intOpt(srv.arena, "timeout") catch return srv.argError(a),
        .hard_timeout_s = a.intOpt(srv.arena, "hard_timeout") catch return srv.argError(a),
        .max_output = a.intOpt(srv.arena, "max_output") catch return srv.argError(a),
    };
    const body = sdk_exec.run(srv.sdk, spec) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, try renderRun(srv, body)));
}

fn tSandboxInfo(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    _ = a;
    const body = sdk_files.sandboxInfo(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileRead(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const body = sdk_files.readFile(srv.sdk, .{
        .path = path,
        .start = a.intOpt(srv.arena, "start") catch return srv.argError(a),
        .end = a.intOpt(srv.arena, "end") catch return srv.argError(a),
        .user = a.strOpt("user"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    // 取 data.content；拿不到就回原始响应体
    if (sdkmod.parse(srv.arena, body)) |v| {
        if (sdkmod.fieldStr(v, "content")) |c| return ToolResult.ok(types.clampText(srv.arena, c));
    }
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "sandbox_info",
        .description = "沙箱画像（镜像/端口/平台版本等，GET /v2/sandbox）。无参数。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tSandboxInfo,
    },
    .{
        .name = "exec",
        .description = "在沙箱内同步执行一条命令并返回 stdout/stderr/exit_code（非 0 退出码不代表调用失败）。",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"要执行的命令（shell 语义）"},"cwd":{"type":"string","description":"工作目录"},"shell":{"type":"string","description":"shell：auto|bash|sh|powershell|cmd|none"},"user":{"type":"string","description":"以哪个用户执行"},"session":{"type":"string","description":"在指定命令会话里执行"},"env":{"type":"object","description":"环境变量对象，值必须是字符串"},"timeout":{"type":"integer","description":"毫秒；到点返回 status=running（进程仍在跑）"},"hard_timeout":{"type":"integer","description":"秒；到点服务端强杀"},"max_output":{"type":"integer","description":"输出字节上限"}},"required":["command"]}
        ,
        .handler = tExec,
    },
    .{
        .name = "file_read",
        .description = "读沙箱内文件内容（文本语义，GET /v2/fs/read）。可用 start/end 取行区间。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"沙箱内绝对路径"},"start":{"type":"integer","description":"起始行（0 起）"},"end":{"type":"integer","description":"结束行（不含）"},"user":{"type":"string","description":"以指定用户读"}},"required":["path"]}
        ,
        .handler = tFileRead,
    },
};
