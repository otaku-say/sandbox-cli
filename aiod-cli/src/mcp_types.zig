//! MCP 门面共享类型：Server / Tool / ToolResult / 协议常量。
//! 只依赖 Core SDK 层与参数层，不依赖终端上下文。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const argmod = @import("mcp_args.zig");

/// 服务端在 initialize 中声明的协议版本（第一个为最新）。
pub const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };
pub const server_name = "aiod-cli";

/// 单条工具结果的文本上限（超过则截断并标注）。
pub const max_text_bytes: usize = 4 << 20;

pub const ToolResult = struct {
    text: []const u8 = "",
    /// 可选图片内容（base64）；与 text 同时返回时按 text + image 两块组织。
    image_b64: ?[]const u8 = null,
    /// 图片 MIME（仅 image_b64 非空时有意义）
    image_mime: []const u8 = "image/png",
    is_error: bool = false,

    pub fn ok(text: []const u8) ToolResult {
        return .{ .text = text };
    }

    pub fn okImage(text: []const u8, b64: []const u8) ToolResult {
        return .{ .text = text, .image_b64 = b64 };
    }

    pub fn okImageMime(text: []const u8, b64: []const u8, mime: []const u8) ToolResult {
        return .{ .text = text, .image_b64 = b64, .image_mime = mime };
    }

    pub fn err(text: []const u8) ToolResult {
        return .{ .text = text, .is_error = true };
    }
};

pub const Server = struct {
    /// 每消息 arena：循环每处理一条消息重置。
    arena: std.mem.Allocator,
    sdk: *sdkmod.Sdk,
    verbose: bool = false,

    /// 诊断输出（永远走 stderr；stdout 只属于协议消息）。
    pub fn log(self: *Server, comptime fmt: []const u8, args: anytype) void {
        if (!self.verbose) return;
        std.debug.print("[mcp] " ++ fmt ++ "\n", args);
    }

    /// 参数校验失败 → 统一错误结果（让模型看到并自纠正）。
    pub fn argError(self: *Server, a: *argmod.Args) ToolResult {
        const m = if (a.msg.len > 0) a.msg else "参数不合法";
        return ToolResult.err(std.fmt.allocPrint(self.arena, "参数错误：{s}", .{m}) catch "参数错误");
    }

    /// SDK 操作失败 → 把 last_* 现场转成人话。
    pub fn sdkError(self: *Server) ToolResult {
        return ToolResult.err(self.sdk.failText());
    }
};

pub const Handler = *const fn (srv: *Server, a: *argmod.Args) anyerror!ToolResult;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// 完整 inputSchema（JSON object，含 type/properties/required）。
    schema: []const u8,
    handler: Handler,
};

/// 截断保护：超过上限的文本截断并标注实际长度。
pub fn clampText(arena: std.mem.Allocator, text: []const u8) []const u8 {
    if (text.len <= max_text_bytes) return text;
    // 截断必须回退到 UTF-8 字符边界：否则 stdout 会出现非法 UTF-8 字节序列，
    // 严格按行解码的客户端会直接报错（协议纯净性的底线）。
    const cut = utf8Boundary(text, max_text_bytes);
    const kept = std.fmt.allocPrint(arena, "{s}\n（输出已截断，共 {d} 字节）", .{ text[0..cut], text.len }) catch text[0..cut];
    return kept;
}

/// 把「允许截断的位置」回退到 UTF-8 字符起始处（不劈开多字节字符）。
pub fn utf8Boundary(s: []const u8, n: usize) usize {
    var e = @min(n, s.len);
    while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1;
    return e;
}


/// 统一的图片结果组织：**只有真图片且不超限**才作为 image content 返回。
/// 截断二进制会产生客户端必然渲染失败的坏图，所以超限/非图片一律回文本并说明。
/// PNG/JPEG 魔数识别 + 8 MiB 上限。
pub fn imageResult(srv: *Server, bytes: []const u8, what: []const u8) anyerror!ToolResult {
    const max_img: usize = 8 << 20;
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    const is_png = bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &png_magic);
    const is_jpg = bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF;

    if (bytes.len > max_img) {
        return ToolResult.ok(try std.fmt.allocPrint(
            srv.arena,
            "{s}成功，但图片 {d} 字节超过 {d} 字节上限，未作为图片返回；可缩小页面/视口或减少截图范围后重试",
            .{ what, bytes.len, max_img },
        ));
    }
    if (!is_png and !is_jpg) {
        return ToolResult.ok(try std.fmt.allocPrint(
            srv.arena,
            "{s}返回 {d} 字节，但不是 PNG/JPEG（魔数不匹配），未作为图片返回；原始内容请用文件类工具获取",
            .{ what, bytes.len },
        ));
    }
    const b64_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const b64 = try srv.arena.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(b64, bytes);
    return ToolResult.okImageMime(
        try std.fmt.allocPrint(srv.arena, "{s}成功（{s}，{d} 字节）", .{ what, if (is_png) "PNG" else "JPEG", bytes.len }),
        b64,
        if (is_png) "image/png" else "image/jpeg",
    );
}
