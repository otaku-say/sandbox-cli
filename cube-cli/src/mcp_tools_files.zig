//! MCP 工具 —— 沙箱文件操作域。
//!
//! 提供读、写、列出、状态、建目录、删除、移动和存在性判断等文件原语。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_files = @import("sdk_files.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tFileRead(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    const content = sdk_files.fileRead(srv.sdk, sid, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, content));
}

fn tFileWrite(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const content = a.str(srv.arena, "content") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    sdk_files.fileWrite(srv.sdk, sid, path, content, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "成功写入 {s}（{d} 字节）", .{ path, content.len }) catch "写入成功");
}

fn tFileList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    const body = sdk_files.fileList(srv.sdk, sid, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileStat(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    const body = sdk_files.fileStat(srv.sdk, sid, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileMkdir(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    sdk_files.fileMkdir(srv.sdk, sid, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "目录已创建：{s}", .{path}) catch "目录已创建");
}

fn tFileDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    sdk_files.fileDelete(srv.sdk, sid, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "文件/目录已删除：{s}", .{path}) catch "已删除");
}

fn tFileMove(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const from = a.str(srv.arena, "from") catch return srv.argError(a);
    const to = a.str(srv.arena, "to") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    sdk_files.fileMove(srv.sdk, sid, from, to, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "已移动：{s} -> {s}", .{ from, to }) catch "已移动");
}

fn tFileExists(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const user = try a.strOpt(srv.arena, "user");
    const exists = sdk_files.fileExists(srv.sdk, sid, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(if (exists) "true" else "false");
}

pub const tools = [_]Tool{
    .{
        .name = "sandbox_file_read",
        .description = "读取沙箱内指定路径的文件内容。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"沙箱内的文件绝对路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path"]}
        ,
        .handler = tFileRead,
    },
    .{
        .name = "sandbox_file_write",
        .description = "向沙箱内指定路径写入文件内容（覆盖写入）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"沙箱内的文件绝对路径"},"content":{"type":"string","description":"要写入的文本内容"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path","content"]}
        ,
        .handler = tFileWrite,
    },
    .{
        .name = "sandbox_file_list",
        .description = "列出沙箱内指定目录的文件和子目录信息（返回 JSON 数组）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"沙箱内的目录路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path"]}
        ,
        .handler = tFileList,
    },
    .{
        .name = "sandbox_file_stat",
        .description = "获取沙箱内指定文件或目录的元数据（大小/权限/修改时间等）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"沙箱内的文件或目录路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path"]}
        ,
        .handler = tFileStat,
    },
    .{
        .name = "sandbox_file_mkdir",
        .description = "在沙箱内递归创建目录。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"要创建的目录路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path"]}
        ,
        .handler = tFileMkdir,
    },
    .{
        .name = "sandbox_file_delete",
        .description = "【破坏性】删除沙箱内的文件或目录。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"要删除的文件或目录路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path"]}
        ,
        .handler = tFileDelete,
    },
    .{
        .name = "sandbox_file_move",
        .description = "在沙箱内移动或重命名文件/目录。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"from":{"type":"string","description":"源路径"},"to":{"type":"string","description":"目标路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","from","to"]}
        ,
        .handler = tFileMove,
    },
    .{
        .name = "sandbox_file_exists",
        .description = "检查沙箱内指定路径是否存在（返回 true 或 false）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"path":{"type":"string","description":"文件或目录路径"},"user":{"type":"string","description":"切换用户执行（默认当前）"}},"required":["sandbox_id","path"]}
        ,
        .handler = tFileExists,
    },
};
