//! MCP 工具 —— 桌面与 GUI 操作域（/v2/computer/*）。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_desktop = @import("sdk_desktop.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tDesktopInfo(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.info(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopScreenshot(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const bytes = sdk_desktop.screenshot(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };

    if (srv.sdk.last_truncated) {
        return ToolResult.ok(try std.fmt.allocPrint(
            srv.arena,
            "桌面截图响应达到 {d} 字节读取上限（可能被截断），未作为图片返回；请降低分辨率后重试",
            .{sdkmod.BUF},
        ));
    }
    return types.imageResult(srv, bytes, "桌面截图");
}

fn tDesktopCursor(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.cursor(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopClipboard(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.clipboard(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopWindows(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.windows(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopA11y(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.a11y(srv.sdk, .{
        .scope = a.strOpt("scope"),
        .max_depth = a.intOpt(srv.arena, "max_depth") catch return srv.argError(a),
        .max_nodes = a.intOpt(srv.arena, "max_nodes") catch return srv.argError(a),
        .role = a.strOpt("role"),
        .name = a.strOpt("name"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopA11yNodes(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.a11yNodes(srv.sdk, .{
        .scope = a.strOpt("scope"),
        .max_depth = a.intOpt(srv.arena, "max_depth") catch return srv.argError(a),
        .max_nodes = a.intOpt(srv.arena, "max_nodes") catch return srv.argError(a),
        .role = a.strOpt("role"),
        .name = a.strOpt("name"),
        .match = a.strOpt("match"),
        .states = a.strOpt("states"),
        .include_offscreen = a.boolOpt(srv.arena, "include_offscreen") catch return srv.argError(a),
        .timeout_ms = a.intOpt(srv.arena, "timeout_ms") catch return srv.argError(a),
        .limit = a.intOpt(srv.arena, "limit") catch return srv.argError(a),
        .node_id = a.strOpt("node_id"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopAct(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const act_val = a.jsonOpt("action") orelse return ToolResult.err("参数错误：action 为必填参数");
    const act_json = argmod.Args.jsonText(srv.arena, act_val) catch return srv.argError(a);
    const screenshot_flag = (a.boolOpt(srv.arena, "screenshot") catch return srv.argError(a)) orelse false;

    const body = sdk_desktop.act(srv.sdk, act_json, screenshot_flag) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopActBatch(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const acts_val = a.jsonOpt("actions") orelse return ToolResult.err("参数错误：actions 为必填参数（动作数组）");
    const acts_json = argmod.Args.jsonText(srv.arena, acts_val) catch return srv.argError(a);
    const screenshot_flag = (a.boolOpt(srv.arena, "screenshot") catch return srv.argError(a)) orelse false;

    const body = sdk_desktop.actBatch(srv.sdk, acts_json, screenshot_flag) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tDesktopRecord(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const body = sdk_desktop.record(srv.sdk, .{
        .action = a.strOpt("action"),
        .fps = a.intOpt(srv.arena, "fps") catch return srv.argError(a),
        .crf = a.intOpt(srv.arena, "crf") catch return srv.argError(a),
        .max_duration = a.intOpt(srv.arena, "max_duration") catch return srv.argError(a),
        .width = a.intOpt(srv.arena, "width") catch return srv.argError(a),
        .height = a.intOpt(srv.arena, "height") catch return srv.argError(a),
        .save_path = a.strOpt("save_path"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "desktop_info",
        .description = "获取当前桌面 GUI 视窗环境信息（分辨率、显示器配置等）。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tDesktopInfo,
    },
    .{
        .name = "desktop_screenshot",
        .description = "截取桌面完整屏幕图像，返回 PNG 图片内容。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tDesktopScreenshot,
    },
    .{
        .name = "desktop_cursor",
        .description = "获取当前鼠标指针所在的屏幕坐标位置。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tDesktopCursor,
    },
    .{
        .name = "desktop_clipboard",
        .description = "读取当前桌面剪贴板中的文本内容。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tDesktopClipboard,
    },
    .{
        .name = "desktop_windows",
        .description = "列出当前桌面打开的所有应用窗口及其位置和尺寸。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tDesktopWindows,
    },
    .{
        .name = "desktop_a11y",
        .description = "获取桌面无障碍 Accessibility UI 元素树。",
        .schema =
        \\{"type":"object","properties":{"scope":{"type":"string","description":"搜索范围"},"max_depth":{"type":"integer","description":"遍历最大深度"},"max_nodes":{"type":"integer","description":"最大返回节点数"},"role":{"type":"string","description":"按角色过滤"},"name":{"type":"string","description":"按名称过滤"}},"required":[]}
        ,
        .handler = tDesktopA11y,
    },
    .{
        .name = "desktop_a11y_nodes",
        .description = "精确查询桌面无障碍节点列表，支持多条件复合匹配。",
        .schema =
        \\{"type":"object","properties":{"scope":{"type":"string","description":"搜索范围"},"max_depth":{"type":"integer","description":"遍历最大深度"},"max_nodes":{"type":"integer","description":"最大返回节点数"},"role":{"type":"string","description":"按角色过滤"},"name":{"type":"string","description":"按名称过滤"},"match":{"type":"string","description":"匹配规则"},"states":{"type":"string","description":"状态过滤"},"include_offscreen":{"type":"boolean","description":"是否包含离屏元素"},"timeout_ms":{"type":"integer","description":"查询超时毫秒数"},"limit":{"type":"integer","description":"返回上限"},"node_id":{"type":"string","description":"特定节点 ID"}},"required":[]}
        ,
        .handler = tDesktopA11yNodes,
    },
    .{
        .name = "desktop_act",
        .description = "向桌面发送单个鼠标/键盘操作事件（如 click、move_to、typing、press、hotkey 等）。",
        .schema =
        \\{"type":"object","properties":{"action":{"type":"object","description":"动作规范对象，如 {\"action\":\"click\",\"x\":100,\"y\":200}"},"screenshot":{"type":"boolean","description":"执行后是否在响应中附带最新截图"}},"required":["action"]}
        ,
        .handler = tDesktopAct,
    },
    .{
        .name = "desktop_act_batch",
        .description = "批量有序执行一组桌面键鼠操作动作。",
        .schema =
        \\{"type":"object","properties":{"actions":{"type":"array","items":{"type":"object"},"description":"动作规范对象列表"},"screenshot":{"type":"boolean","description":"执行完成后是否返回最终截图"}},"required":["actions"]}
        ,
        .handler = tDesktopActBatch,
    },
    .{
        .name = "desktop_record",
        .description = "录制桌面屏幕视频（开始或停止录屏）。",
        .schema =
        \\{"type":"object","properties":{"action":{"type":"string","description":"动作：start|stop"},"fps":{"type":"integer","description":"帧率"},"crf":{"type":"integer","description":"质量 CRF"},"max_duration":{"type":"integer","description":"最大录制秒数"},"width":{"type":"integer","description":"视频宽度"},"height":{"type":"integer","description":"视频高度"},"save_path":{"type":"string","description":"录像文件保存路径"}},"required":[]}
        ,
        .handler = tDesktopRecord,
    },
};
