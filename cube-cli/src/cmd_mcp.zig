//! cmd_mcp —— `cube-cli mcp-server`：把本 CLI 的能力以 MCP（stdio）暴露给 Agent。
//!
//! 人类通道（--help）走 CLI 输出；一旦进入服务模式，stdout 只属于 JSON-RPC 协议消息。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const sdkmod = @import("sdk.zig");
const mcp = @import("mcp_server.zig");

const Ctx = ctxmod.Ctx;

pub const help =
    \\mcp-server [--api-url=<URL>] [--key=<KEY>] [--proxy=<URL>] [--verbose]
    \\  以 MCP Server（stdio 传输）方式运行本 CLI：stdin 读 JSON-RPC 2.0 请求，
    \\  stdout 只写协议消息（绝对无 banner/日志），诊断一律走 stderr。
    \\  支持方法：initialize / notifications/initialized / ping / tools/list / tools/call。
    \\  配置默认取环境变量（CUBESANDBOX_API_URL / CUBESANDBOX_API_KEY / CUBESANDBOX_PROXY_URL），
    \\  可用上面的 flag 覆盖；缺配置不会退出，工具调用时返回可读错误。
    \\示例:  cube-cli mcp-server --verbose
    \\       MCP Client 配置：{"command":"cube-cli","args":["mcp-server"]}
;

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    if (!std.mem.eql(u8, cmd, "mcp-server")) return false;
    const a = try util.parse(c.arena, argv);
    const ov = sdkmod.Overrides{
        .api = a.get("api-url"),
        .key = a.get("key"),
        .proxy = a.get("proxy"),
    };
    const code = try mcp.run(std.heap.smp_allocator, c.io, c.client, ov, .{ .verbose = a.has("verbose") });
    if (code != 0) std.process.exit(code);
    return true;
}
