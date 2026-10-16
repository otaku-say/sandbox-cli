//! MCP 门面共享类型：Server / Tool / ToolResult / 协议常量。
//! 只依赖 Core SDK 层与参数层，不依赖终端上下文。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const argmod = @import("mcp_args.zig");

/// 服务端在 initialize 中声明的协议版本（第一个为最新）。
pub const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };
pub const server_name = "cube-cli";

/// 单条工具结果的文本上限（超过则截断并标注）。
pub const max_text_bytes: usize = 4 << 20;

pub const ToolResult = struct {
    text: []const u8 = "",
    /// 可选图片内容（PNG base64）；与 text 同时返回时按 text + image 两块组织。
    image_png_b64: ?[]const u8 = null,
    is_error: bool = false,

    pub fn ok(text: []const u8) ToolResult {
        return .{ .text = text };
    }

    pub fn okImage(text: []const u8, b64: []const u8) ToolResult {
        return .{ .text = text, .image_png_b64 = b64 };
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
    const kept = std.fmt.allocPrint(arena, "{s}\n（输出已截断，共 {d} 字节）", .{ text[0..max_text_bytes], text.len }) catch text[0..max_text_bytes];
    return kept;
}
