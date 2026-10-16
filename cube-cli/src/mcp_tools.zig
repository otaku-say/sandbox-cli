//! MCP 工具注册表：把各域工具表拼成一张总表。
//! 新增域：写 `mcp_tools_<域>.zig`（导出 `pub const tools = [_]types.Tool{...}`），在此追加一行。
const types = @import("mcp_types.zig");
const lifecycle = @import("mcp_tools_lifecycle.zig");
const exec = @import("mcp_tools_exec.zig");
const files = @import("mcp_tools_files.zig");
const snapshot = @import("mcp_tools_snapshot.zig");
const volume = @import("mcp_tools_volume.zig");
const template = @import("mcp_tools_template.zig");
const raw = @import("mcp_tools_raw.zig");

comptime {
    @setEvalBranchQuota(100_000);
}

pub const tools = lifecycle.tools ++ exec.tools ++ files.tools ++ snapshot.tools ++ volume.tools ++ template.tools ++ raw.tools;
