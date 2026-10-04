//! 配置：环境变量读取（仅 CUBESANDBOX_* 新命名（旧名已移除））
const std = @import("std");

/// 读环境变量（走 libc，因此构建必须 -lc）。
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

/// 控制面地址（必填）：CUBESANDBOX_API_URL
pub fn apiURL() ?[]const u8 {
    return getenv("CUBESANDBOX_API_URL");
}

/// 控制面 API Key（可空：本部署可能不启用鉴权）。
pub fn apiKey() ?[]const u8 {
    return getenv("CUBESANDBOX_API_KEY");
}

/// 数据面网关地址（拼沙箱访问 URL 用）。
pub fn proxyURL() ?[]const u8 {
    return getenv("CUBESANDBOX_PROXY_URL");
}

pub const version = "0.2.0";
