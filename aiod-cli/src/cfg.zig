//! 配置与环境变量。
//!
//! 约定：本仓库不出现任何真实主机名 / IP / 凭据，全部由环境变量注入。
const std = @import("std");

pub const version = "0.2.0";

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

/// 沙箱内 aiod 网关地址，形如 https://<gateway-host>/sandbox/<sandboxID>/<port>
pub fn sandboxBase() ?[]const u8 {
    return getenv("SANDBOX_BASE");
}

/// aiod 鉴权 Key（可选）。
pub fn sandboxKey() ?[]const u8 {
    return getenv("SANDBOX_KEY");
}

/// 默认单次请求超时（秒），可由 --timeout 覆盖。
pub const default_timeout_s: u32 = 60;
