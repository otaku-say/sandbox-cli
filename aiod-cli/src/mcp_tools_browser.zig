//! MCP 工具 —— 浏览器自动化域（/v2/browser/*）。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdkmod = @import("sdk.zig");
const sdk_browser = @import("sdk_browser.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tBrowserInfo(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_browser.info(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserNavigate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const url = a.strOpt("url");
    const history = a.strOpt("history");
    if (url == null and history == null) {
        return ToolResult.err("参数错误：需提供 url（网页地址）或 history（back/forward/reload）参数");
    }
    const body = sdk_browser.navigate(srv.sdk, .{
        .url = url,
        .history = history,
        .wait_until = a.strOpt("wait"),
        .timeout = a.intOpt(srv.arena, "timeout") catch return srv.argError(a),
        .tab_id = a.strOpt("tab"),
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserEvaluate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const expr = a.str(srv.arena, "expression") catch return srv.argError(a);
    const is_await = (a.boolOpt(srv.arena, "await") catch return srv.argError(a)) orelse false;
    const body = sdk_browser.evaluate(srv.sdk, expr, is_await) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserClick(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sel = a.strOpt("selector");
    const ref = a.strOpt("ref");
    if (sel == null and ref == null) {
        return ToolResult.err("参数错误：需提供 selector（CSS 选择器）或 ref（快照元素引用）参数之一");
    }
    const body = sdk_browser.click(srv.sdk, sel, ref, a.strOpt("tab")) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserFill(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sel = a.strOpt("selector");
    const ref = a.strOpt("ref");
    if (sel == null and ref == null) {
        return ToolResult.err("参数错误：需提供 selector（CSS 选择器）或 ref（快照元素引用）参数之一");
    }
    const val = a.strOpt("value") orelse "";
    const body = sdk_browser.fill(srv.sdk, sel, ref, val, a.strOpt("tab")) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserSnapshot(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const interactive = (a.boolOpt(srv.arena, "interactive") catch return srv.argError(a)) orelse false;
    const body = sdk_browser.snapshot(srv.sdk, interactive) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserTabs(srv: *Server, _: *argmod.Args) anyerror!ToolResult {
    const body = sdk_browser.tabs(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserScreenshot(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const full = (a.boolOpt(srv.arena, "full") catch return srv.argError(a)) orelse false;
    const quality = a.intOpt(srv.arena, "quality") catch return srv.argError(a);

    const bytes = sdk_browser.screenshot(srv.sdk, .{
        .full_page = full,
        .quality = quality,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };

    const max_img = 8 << 20; // 8 MiB limit
    var raw_bytes = bytes;
    var note: []const u8 = "";
    if (raw_bytes.len > max_img) {
        raw_bytes = raw_bytes[0..max_img];
        note = "（图片大小超过 8 MiB 已截断）";
    }
    const b64_len = std.base64.standard.Encoder.calcSize(raw_bytes.len);
    const b64 = try srv.arena.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(b64, raw_bytes);
    const summary = try std.fmt.allocPrint(srv.arena, "截图成功（PNG，{d} 字节）{s}", .{ bytes.len, note });
    return ToolResult.okImage(summary, b64);
}

fn tBrowserTabNew(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const url = a.strOpt("url");
    const body = sdk_browser.tabNew(srv.sdk, url) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserTabUse(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const tid = a.str(srv.arena, "tab_id") catch return srv.argError(a);
    const body = sdk_browser.tabUse(srv.sdk, tid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserTabClose(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const tid = a.str(srv.arena, "tab_id") catch return srv.argError(a);
    const body = sdk_browser.tabClose(srv.sdk, tid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserCookies(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const body = sdk_browser.cookies(srv.sdk, a.strOpt("url"), a.strOpt("domain")) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserCookieSet(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const c_val = a.jsonOpt("cookie") orelse return ToolResult.err("参数错误：需提供 cookie 对象或数组");
    const c_json = argmod.Args.jsonText(srv.arena, c_val) catch return srv.argError(a);
    var body_json: []const u8 = "";
    if (c_val == .array) {
        body_json = try std.fmt.allocPrint(srv.arena, "{{\"cookies\":{s}}}", .{c_json});
    } else if (c_val == .object) {
        if (c_val.object.get("cookies") != null) {
            body_json = c_json;
        } else {
            body_json = try std.fmt.allocPrint(srv.arena, "{{\"cookies\":[{s}]}}", .{c_json});
        }
    } else {
        return ToolResult.err("参数错误：cookie 需要是对象或数组");
    }
    const body = sdk_browser.cookieSet(srv.sdk, body_json) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserCookieDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const name = a.strOpt("name");
    const all = (a.boolOpt(srv.arena, "all") catch return srv.argError(a)) orelse false;
    const body = sdk_browser.cookieDelete(srv.sdk, name, all, a.strOpt("url"), a.strOpt("domain")) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserUpload(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const paths = (a.strArrayOpt(srv.arena, "paths") catch return srv.argError(a)) orelse return ToolResult.err("参数错误：paths 为必填参数");
    const body = sdk_browser.upload(srv.sdk, paths, a.strOpt("selector"), a.strOpt("ref"), a.strOpt("tab")) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserNetwork(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const limit = a.intOpt(srv.arena, "limit") catch return srv.argError(a);
    const clear = (a.boolOpt(srv.arena, "clear") catch return srv.argError(a)) orelse false;
    const body = sdk_browser.network(srv.sdk, limit, clear) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tBrowserConfig(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    var body_res: []const u8 = "";
    if (a.strOpt("resolution")) |v| {
        const xi = std.mem.indexOfScalar(u8, v, 'x') orelse
            std.mem.indexOfScalar(u8, v, 'X') orelse return ToolResult.err("参数错误：分辨率格式需为 WxH（如 1280x800）");
        const payload = try std.fmt.allocPrint(srv.arena, "{{\"resolution\":{{\"width\":{s},\"height\":{s}}}}}", .{ v[0..xi], v[xi + 1 ..] });
        body_res = try sdk_browser.configSet(srv.sdk, payload);
    } else if (a.jsonOpt("json")) |j| {
        const payload = try argmod.Args.jsonText(srv.arena, j);
        body_res = try sdk_browser.configSet(srv.sdk, payload);
    } else {
        body_res = try sdk_browser.configGet(srv.sdk);
    }
    return ToolResult.ok(types.clampText(srv.arena, body_res));
}

fn tBrowserCdp(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const method = a.str(srv.arena, "method") catch return srv.argError(a);
    var params_json: ?[]const u8 = null;
    if (a.jsonOpt("params")) |p| {
        params_json = argmod.Args.jsonText(srv.arena, p) catch return srv.argError(a);
    }
    const browser = (a.boolOpt(srv.arena, "browser") catch return srv.argError(a)) orelse false;
    const tab = a.strOpt("tab");
    const body = sdk_browser.cdp(srv.sdk, method, params_json, browser, tab) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError, error.ApiError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "browser_info",
        .description = "获取当前浏览器状态与信息（CDP 地址、运行状态等）。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tBrowserInfo,
    },
    .{
        .name = "browser_navigate",
        .description = "控制浏览器导航到指定 URL 或执行历史前进后退重载。",
        .schema =
        \\{"type":"object","properties":{"url":{"type":"string","description":"目标网址"},"history":{"type":"string","description":"历史导航动作：back|forward|reload"},"wait":{"type":"string","description":"等待事件：load|domcontentloaded|networkidle"},"timeout":{"type":"integer","description":"等待超时秒数"},"tab":{"type":"string","description":"目标标签页 ID"}},"required":[]}
        ,
        .handler = tBrowserNavigate,
    },
    .{
        .name = "browser_evaluate",
        .description = "在当前或指定浏览器页面上下文中执行 JavaScript 表达式求值。",
        .schema =
        \\{"type":"object","properties":{"expression":{"type":"string","description":"要执行的 JavaScript 表达式"},"await":{"type":"boolean","description":"是否等待 Promise 兑现"}},"required":["expression"]}
        ,
        .handler = tBrowserEvaluate,
    },
    .{
        .name = "browser_click",
        .description = "在当前页面点击指定的 DOM 元素（通过 CSS 选择器或快照引用 ref）。",
        .schema =
        \\{"type":"object","properties":{"selector":{"type":"string","description":"CSS 选择器"},"ref":{"type":"string","description":"无障碍树元素引用 ref"},"tab":{"type":"string","description":"目标标签页 ID"}},"required":[]}
        ,
        .handler = tBrowserClick,
    },
    .{
        .name = "browser_fill",
        .description = "在当前页面的输入框或表单元素中填入指定文本值。",
        .schema =
        \\{"type":"object","properties":{"selector":{"type":"string","description":"CSS 选择器"},"ref":{"type":"string","description":"无障碍树元素引用 ref"},"value":{"type":"string","description":"要填入的文本内容"},"tab":{"type":"string","description":"目标标签页 ID"}},"required":[]}
        ,
        .handler = tBrowserFill,
    },
    .{
        .name = "browser_snapshot",
        .description = "捕获当前页面的可交互无障碍 DOM 节点快照树（供模型定位元素）。",
        .schema =
        \\{"type":"object","properties":{"interactive":{"type":"boolean","description":"是否仅返回可交互元素"}},"required":[]}
        ,
        .handler = tBrowserSnapshot,
    },
    .{
        .name = "browser_tabs",
        .description = "列出当前浏览器开启的所有标签页及其标题与 URL。",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .handler = tBrowserTabs,
    },
    .{
        .name = "browser_screenshot",
        .description = "截取浏览器当前页面的视觉屏幕截图，返回 PNG 图片内容。",
        .schema =
        \\{"type":"object","properties":{"full":{"type":"boolean","description":"是否截取完整长图（整页滚动）"},"quality":{"type":"integer","description":"图片质量（0-100）"}},"required":[]}
        ,
        .handler = tBrowserScreenshot,
    },
    .{
        .name = "browser_tab_new",
        .description = "在浏览器中新建标签页，可直接导航到指定 URL。",
        .schema =
        \\{"type":"object","properties":{"url":{"type":"string","description":"初始导航网址"}},"required":[]}
        ,
        .handler = tBrowserTabNew,
    },
    .{
        .name = "browser_tab_use",
        .description = "切换到指定 ID 的浏览器标签页。",
        .schema =
        \\{"type":"object","properties":{"tab_id":{"type":"string","description":"目标标签页 ID"}},"required":["tab_id"]}
        ,
        .handler = tBrowserTabUse,
    },
    .{
        .name = "browser_tab_close",
        .description = "关闭指定 ID 的浏览器标签页。",
        .schema =
        \\{"type":"object","properties":{"tab_id":{"type":"string","description":"要关闭的标签页 ID"}},"required":["tab_id"]}
        ,
        .handler = tBrowserTabClose,
    },
    .{
        .name = "browser_cookies",
        .description = "获取当前页面的 Cookie 列表。",
        .schema =
        \\{"type":"object","properties":{"url":{"type":"string","description":"过滤的网址"},"domain":{"type":"string","description":"过滤的域名"}},"required":[]}
        ,
        .handler = tBrowserCookies,
    },
    .{
        .name = "browser_cookie_set",
        .description = "向浏览器中设置一条或多条 Cookie 数据。",
        .schema =
        \\{"type":"object","properties":{"cookie":{"type":"object","description":"Cookie 对象或列表"}},"required":["cookie"]}
        ,
        .handler = tBrowserCookieSet,
    },
    .{
        .name = "browser_cookie_delete",
        .description = "删除浏览器中的 Cookie（支持按名字或全部清空）。",
        .schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Cookie 名字"},"all":{"type":"boolean","description":"是否删除全部 Cookie"},"url":{"type":"string","description":"Cookie 所在 URL"},"domain":{"type":"string","description":"Cookie 所在域名"}},"required":[]}
        ,
        .handler = tBrowserCookieDelete,
    },
    .{
        .name = "browser_upload",
        .description = "将沙箱内的文件路径附加到网页的 <input type=file> 表单元素上。",
        .schema =
        \\{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"description":"沙箱内待上传文件绝对路径列表"},"selector":{"type":"string","description":"目标 input 元素的 CSS 选择器"},"ref":{"type":"string","description":"目标元素引用 ref"},"tab":{"type":"string","description":"目标标签页 ID"}},"required":["paths"]}
        ,
        .handler = tBrowserUpload,
    },
    .{
        .name = "browser_network",
        .description = "获取浏览器近期的网络请求日志与状态码。",
        .schema =
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"最多返回请求条数"},"clear":{"type":"boolean","description":"读取后是否清空历史记录"}},"required":[]}
        ,
        .handler = tBrowserNetwork,
    },
    .{
        .name = "browser_config",
        .description = "查看或配置浏览器分辨率及视口参数。",
        .schema =
        \\{"type":"object","properties":{"resolution":{"type":"string","description":"分辨率 WxH（如 1280x800）"},"json":{"type":"object","description":"完整配置 JSON 对象"}},"required":[]}
        ,
        .handler = tBrowserConfig,
    },
    .{
        .name = "browser_cdp",
        .description = "向浏览器直接发送 Chrome DevTools Protocol (CDP) 原始协议命令。",
        .schema =
        \\{"type":"object","properties":{"method":{"type":"string","description":"CDP 协议方法名（如 Page.captureScreenshot）"},"params":{"type":"object","description":"CDP 参数对象"},"browser":{"type":"boolean","description":"是否在 Browser 级别目标执行"},"tab":{"type":"string","description":"目标标签页 ID"}},"required":["method"]}
        ,
        .handler = tBrowserCdp,
    },
};
