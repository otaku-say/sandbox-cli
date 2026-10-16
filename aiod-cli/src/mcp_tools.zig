//! MCP 工具注册表（aiod-cli）：各域工具表拼接。
//! 新增域：写 `mcp_tools_<域>.zig`（导出 `pub const tools = [_]types.Tool{...}`），在此追加一行。
const types = @import("mcp_types.zig");
const exec_ = @import("mcp_tools_exec.zig");
const files_ = @import("mcp_tools_files.zig");
const pty_ = @import("mcp_tools_pty.zig");
const misc_ = @import("mcp_tools_misc.zig");
const browser_ = @import("mcp_tools_browser.zig");
const desktop_ = @import("mcp_tools_desktop.zig");

pub const tools = exec_.tools ++ files_.tools ++ pty_.tools ++ misc_.tools ++ browser_.tools ++ desktop_.tools;
