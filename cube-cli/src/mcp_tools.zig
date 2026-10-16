//! MCP 工具注册表：把各域工具表拼成一张总表。
//! 新增域：写 `mcp_tools_<域>.zig`（导出 `pub const tools = [_]types.Tool{...}`），在此追加一行。
const types = @import("mcp_types.zig");
const lifecycle = @import("mcp_tools_lifecycle.zig");

pub const tools = lifecycle.tools;
