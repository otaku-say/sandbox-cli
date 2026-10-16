//! cmd_mcp —— `aiod-cli mcp-server`：把本 CLI 的能力以 MCP（stdio）暴露给 Agent。
//!
//! 人类通道（--help）走 CLI 输出；一旦进入服务模式，stdout 只属于 JSON-RPC 协议消息。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const sdkmod = @import("sdk.zig");
const mcp = @import("mcp_server.zig");

const Ctx = ctxmod.Ctx;

pub const help =
    \\mcp-server [--base=<URL>] [--key=<KEY>] [--verbose]
    \\  以 MCP Server（stdio 传输）方式运行本 CLI：stdin 读 JSON-RPC 2.0 请求，
    \\  stdout 只写协议消息（绝对无 banner/日志），诊断一律走 stderr。
    \\  支持方法：initialize / notifications/initialized / ping / tools/list / tools/call。
    \\  配置默认取环境变量（SANDBOX_BASE / SANDBOX_KEY），可用上面的 flag 覆盖；
    \\  缺配置不会退出，工具调用时返回可读错误。
    \\示例:  aiod-cli mcp-server --verbose
    \\       MCP Client 配置：{"command":"aiod-cli","args":["mcp-server"],
    \\                        "env":{"SANDBOX_BASE":"https://<网关>/sandbox/<沙箱ID>/8080"}}
;

/// 服务入口（返回退出码）。**在 SANDBOX_BASE 检查之前调用**：
/// 缺配置也要能启动，只有工具调用时才报错——否则 MCP Client 直接失联。
pub fn run(arena: std.mem.Allocator, io: std.Io, client: *std.http.Client, argv: []const []const u8) !u8 {
    const a = try util.parse(arena, argv);
    const ov = sdkmod.Overrides{
        .base = a.get("base"),
        .key = a.get("key"),
    };
    return mcp.run(std.heap.smp_allocator, io, client, ov, .{ .verbose = a.has("verbose") });
}

/// 常规分发位置（保持与其它命令对称；当前 main 在 base 检查前提前放行）。
pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "mcp-server")) return false;
    const code = try run(c.arena, c.io, c.client, argv);
    if (code != 0) std.process.exit(code);
    return true;
}
