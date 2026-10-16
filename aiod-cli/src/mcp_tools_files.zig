//! MCP 工具 —— 文件域（/v2/fs/*）。
//!
//! 提供读写、列表、状态、文本树、创建、删除、复制、移动、编辑、正则检索与文件名搜索。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_files = @import("sdk_files.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

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
    if (sdkmod.parse(srv.arena, body)) |v| {
        if (sdkmod.fieldStr(v, "content")) |c| return ToolResult.ok(types.clampText(srv.arena, c));
    }
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileWrite(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const content = a.str(srv.arena, "content") catch return srv.argError(a);
    const append = (a.boolOpt(srv.arena, "append") catch return srv.argError(a)) orelse false;
    const leading_newline = (a.boolOpt(srv.arena, "leading_newline") catch return srv.argError(a)) orelse false;
    const trailing_newline = (a.boolOpt(srv.arena, "trailing_newline") catch return srv.argError(a)) orelse false;
    const body = sdk_files.writeFile(srv.sdk, .{
        .path = path,
        .content = content,
        .append = append,
        .encoding = a.strOpt("encoding"),
        .leading_newline = leading_newline,
        .trailing_newline = trailing_newline,
        .user = a.strOpt("user"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const body = sdk_files.list(srv.sdk, .{
        .path = path,
        .user = a.strOpt("user"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileStat(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const follow = (a.boolOpt(srv.arena, "follow_symlinks") catch return srv.argError(a)) orelse false;
    const body = sdk_files.stat(srv.sdk, .{
        .path = path,
        .user = a.strOpt("user"),
        .follow_symlinks = follow,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileTree(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.strOpt("path");
    const user = a.strOpt("user");
    const body = sdk_files.treeText(srv.sdk, path, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileMkdir(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const parents = (a.boolOpt(srv.arena, "parents") catch return srv.argError(a)) orelse true;
    const user = a.strOpt("user");
    const body = sdk_files.mkdir(srv.sdk, path, parents, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const recursive = (a.boolOpt(srv.arena, "recursive") catch return srv.argError(a)) orelse true;
    const user = a.strOpt("user");
    const body = sdk_files.deleteFile(srv.sdk, path, recursive, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileCopy(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const src = a.str(srv.arena, "from") catch return srv.argError(a);
    const dst = a.str(srv.arena, "to") catch return srv.argError(a);
    const overwrite = (a.boolOpt(srv.arena, "overwrite") catch return srv.argError(a)) orelse false;
    const user = a.strOpt("user");
    const body = sdk_files.copy(srv.sdk, src, dst, overwrite, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileMove(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const src = a.str(srv.arena, "from") catch return srv.argError(a);
    const dst = a.str(srv.arena, "to") catch return srv.argError(a);
    const overwrite = (a.boolOpt(srv.arena, "overwrite") catch return srv.argError(a)) orelse false;
    const user = a.strOpt("user");
    const body = sdk_files.move(srv.sdk, src, dst, overwrite, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileEdit(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const old = a.strOpt("old");
    const new = a.strOpt("new");
    const mode = a.strOpt("replace_mode");
    const insert = a.intOpt(srv.arena, "insert") catch return srv.argError(a);
    const text = a.strOpt("text");
    const user = a.strOpt("user");

    if (old == null and insert == null) {
        return ToolResult.err("参数错误：需提供 old（字符串替换）或 insert（行号插入）参数");
    }

    const body = sdk_files.edit(srv.sdk, .{
        .path = path,
        .old = old,
        .new = new,
        .replace_mode = mode,
        .insert = insert,
        .text = text,
        .user = user,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileGrep(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const pattern = a.str(srv.arena, "pattern") catch return srv.argError(a);
    const fixed = (a.boolOpt(srv.arena, "fixed") catch return srv.argError(a)) orelse false;
    const ignore_case = (a.boolOpt(srv.arena, "ignore_case") catch return srv.argError(a)) orelse false;
    const multiline = (a.boolOpt(srv.arena, "multiline") catch return srv.argError(a)) orelse false;
    const max_matches = a.intOpt(srv.arena, "max_matches") catch return srv.argError(a);
    const user = a.strOpt("user");

    const body = sdk_files.grep(srv.sdk, .{
        .path = path,
        .pattern = pattern,
        .fixed = fixed,
        .ignore_case = ignore_case,
        .multiline = multiline,
        .max_matches = max_matches,
        .user = user,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tFileSearch(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const path = a.str(srv.arena, "path") catch return srv.argError(a);
    const pattern = a.str(srv.arena, "pattern") catch return srv.argError(a);
    const user = a.strOpt("user");

    const body = sdk_files.search(srv.sdk, path, pattern, user) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "file_read",
        .description = "读沙箱内文件内容（文本语义，GET /v2/fs/read）。可用 start/end 取行区间。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"沙箱内绝对路径"},"start":{"type":"integer","description":"起始行（0 起）"},"end":{"type":"integer","description":"结束行（不含）"},"user":{"type":"string","description":"以指定用户读"}},"required":["path"]}
        ,
        .handler = tFileRead,
    },
    .{
        .name = "file_write",
        .description = "向沙箱内写入文件内容（覆盖或追加）。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"沙箱内绝对路径"},"content":{"type":"string","description":"文件内容"},"append":{"type":"boolean","description":"是否为追加写入"},"encoding":{"type":"string","description":"内容编码"},"leading_newline":{"type":"boolean","description":"写入前追加换行"},"trailing_newline":{"type":"boolean","description":"写入后追加换行"}},"required":["path","content"]}
        ,
        .handler = tFileWrite,
    },
    .{
        .name = "file_list",
        .description = "列出沙箱内指定目录下的文件和子目录列表。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"目录绝对路径"},"user":{"type":"string","description":"执行用户"}},"required":["path"]}
        ,
        .handler = tFileList,
    },
    .{
        .name = "file_stat",
        .description = "获取沙箱内指定文件或目录的元数据（大小、修改时间、权限等）。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"文件或目录绝对路径"},"user":{"type":"string","description":"执行用户"},"follow_symlinks":{"type":"boolean","description":"是否追踪符号链接"}},"required":["path"]}
        ,
        .handler = tFileStat,
    },
    .{
        .name = "file_tree",
        .description = "以文本树形结构列出沙箱内指定路径的文件与目录层级树。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"根路径，缺省为 /"},"user":{"type":"string","description":"执行用户"}},"required":[]}
        ,
        .handler = tFileTree,
    },
    .{
        .name = "file_mkdir",
        .description = "在沙箱内创建新目录（默认创建父目录）。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"要创建的目录路径"},"parents":{"type":"boolean","description":"是否递归创建父目录"},"user":{"type":"string","description":"执行用户"}},"required":["path"]}
        ,
        .handler = tFileMkdir,
    },
    .{
        .name = "file_delete",
        .description = "删除沙箱内的文件或目录（具有破坏性）。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"要删除的文件或目录路径"},"recursive":{"type":"boolean","description":"非空目录是否递归删除"},"user":{"type":"string","description":"执行用户"}},"required":["path"]}
        ,
        .handler = tFileDelete,
    },
    .{
        .name = "file_copy",
        .description = "在沙箱内复制文件或目录到指定目标路径。",
        .schema =
        \\{"type":"object","properties":{"from":{"type":"string","description":"源路径"},"to":{"type":"string","description":"目标路径"},"overwrite":{"type":"boolean","description":"是否覆盖已存在目标"},"user":{"type":"string","description":"执行用户"}},"required":["from","to"]}
        ,
        .handler = tFileCopy,
    },
    .{
        .name = "file_move",
        .description = "在沙箱内移动或重命名文件/目录。",
        .schema =
        \\{"type":"object","properties":{"from":{"type":"string","description":"源路径"},"to":{"type":"string","description":"目标路径"},"overwrite":{"type":"boolean","description":"是否覆盖已存在目标"},"user":{"type":"string","description":"执行用户"}},"required":["from","to"]}
        ,
        .handler = tFileMove,
    },
    .{
        .name = "file_edit",
        .description = "精确编辑沙箱内文件内容（支持字符串替换或按行插入）。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"文件绝对路径"},"old":{"type":"string","description":"待替换的原字符串"},"new":{"type":"string","description":"替换后的新字符串"},"replace_mode":{"type":"string","description":"匹配模式：ALL|FIRST|LAST"},"insert":{"type":"integer","description":"插入起始行号"},"text":{"type":"string","description":"插入文本"},"user":{"type":"string","description":"执行用户"}},"required":["path"]}
        ,
        .handler = tFileEdit,
    },
    .{
        .name = "file_grep",
        .description = "在沙箱指定路径的文件或目录中搜索匹配的内容。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"搜索起始路径"},"pattern":{"type":"string","description":"搜索关键词或正则模式"},"fixed":{"type":"boolean","description":"是否按字面量精确匹配"},"ignore_case":{"type":"boolean","description":"是否忽略大小写"},"multiline":{"type":"boolean","description":"是否启用多行模式"},"max_matches":{"type":"integer","description":"最大返回结果数"},"user":{"type":"string","description":"执行用户"}},"required":["path","pattern"]}
        ,
        .handler = tFileGrep,
    },
    .{
        .name = "file_search",
        .description = "按文件名模式在沙箱文件系统中搜索文件路径。",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"搜索起始路径"},"pattern":{"type":"string","description":"文件名匹配模式（如 *.py）"},"user":{"type":"string","description":"执行用户"}},"required":["path","pattern"]}
        ,
        .handler = tFileSearch,
    },
};
