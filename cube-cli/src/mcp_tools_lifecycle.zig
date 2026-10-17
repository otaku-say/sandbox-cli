//! MCP 工具 —— 沙箱生命周期与控制域。
//!
//! 包括沙箱创建、列表、详情、删除、暂停、恢复、续期、修改存活时间、网络安全配置、端口探测与克隆。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_lifecycle = @import("sdk_lifecycle.zig");
const envd = @import("envd.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tSandboxCreate(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const template = try a.strOpt(srv.arena, "template");
    const need = try a.strOpt(srv.arena, "need") orelse "code";
    const timeout = try a.intOpt(srv.arena, "timeout");
    const note = try a.strOpt(srv.arena, "note");
    const agent = try a.strOpt(srv.arena, "agent");
    const task = try a.strOpt(srv.arena, "task");
    const env_vars = a.objJsonText(srv.arena, "env") catch return srv.argError(a);
    const volumes = (try a.strArrayOpt(srv.arena, "volume")) orelse &.{};
    const lifecycle = try a.strOpt(srv.arena, "lifecycle");
    const auto_resume = try a.boolOpt(srv.arena, "auto_resume");
    const no_internet = try a.boolOpt(srv.arena, "no_internet");
    const distribution_scope = try a.strOpt(srv.arena, "distribution_scope");
    var mcp_json: ?[]const u8 = null;
    if (a.jsonOpt("mcp")) |m| {
        mcp_json = try argmod.Args.jsonText(srv.arena, m);
    }

    const body = sdk_lifecycle.sandboxCreate(srv.sdk, .{
        .template = template,
        .need = need,
        .timeout = timeout,
        .note = note,
        .agent = agent,
        .task = task,
        .env_vars = env_vars,
        .volumes = volumes,
        .lifecycle = lifecycle,
        .auto_resume = auto_resume,
        .no_internet = no_internet,
        .distribution_scope = distribution_scope,
        .mcp = mcp_json,
    }) catch |e| return switch (e) {
        error.TemplateUnavailable => ToolResult.err(try std.fmt.allocPrint(
            srv.arena,
            "没有满足 need={s} 的 READY 模板（可用 template 直接指定模板 ID，或先调 template_list 查看）",
            .{need},
        )),
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };

    // 结果组织：沙箱 ID + 可直接用于 aiod-cli 的网关基址（SANDBOX_BASE）+ 模板/状态。
    // CLI `new` 把这些打在 stderr 上；MCP 场景下 agent 必须能拿到，否则无法驱动数据面工具。
    const sid = envd.extractString(srv.arena, body.body, "sandboxID") orelse
        return ToolResult.ok(types.clampText(srv.arena, body.body));
    const state = envd.extractString(srv.arena, body.body, "state") orelse "";
    const base = sdk_lifecycle.sandboxBaseURL(srv.sdk, sid, body.template_id);

    var w = std.Io.Writer.fixed(try srv.arena.alloc(u8, 4096));
    try w.print("{{\"sandbox_id\":\"{s}\",\"template\":\"{s}\"", .{ sid, body.template_id });
    if (state.len > 0) try w.print(",\"state\":\"{s}\"", .{state});
    if (base.len > 0) {
        try w.print(",\"sandbox_base\":\"{s}\"", .{base});
    } else {
        try w.writeAll(",\"sandbox_base\":\"\",\"hint\":\"设置 CUBESANDBOX_PROXY_URL 后可得到 aiod 网关地址\"");
    }
    try w.writeAll("}");
    return ToolResult.ok(w.buffered());
}

fn tSandboxList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const md = (try a.strArrayOpt(srv.arena, "metadata")) orelse &.{};
    const state = try a.strOpt(srv.arena, "state");
    const limit = try a.strOpt(srv.arena, "limit");
    var v2 = try a.boolOr(srv.arena, "v2", false);
    if ((state != null or limit != null) and !v2) {
        v2 = true;
    }
    const q = sdk_lifecycle.ListQuery{
        .metadata = md,
        .state = state,
        .limit = limit,
        .v2 = v2,
    };
    const body = sdk_lifecycle.sandboxList(srv.sdk, q) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxInfo(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const wait_state = try a.strOpt(srv.arena, "wait");
    const timeout_raw = try a.intOr(srv.arena, "timeout", 120);
    const timeout_s: u64 = @intCast(@max(0, @min(timeout_raw, 120)));
    const body = sdk_lifecycle.sandboxInfo(srv.sdk, sid, .{ .wait_state = wait_state, .timeout_s = timeout_s }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        error.WaitTimeout => ToolResult.err(try std.fmt.allocPrint(srv.arena, "超时 {d}s：沙箱未进入 {s} 状态", .{ timeout_s, wait_state.? })),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxPause(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const wait = (a.boolOpt(srv.arena, "wait") catch return srv.argError(a)) orelse false;
    const timeout_s: u64 = @intCast(@max(0, a.intOr(srv.arena, "timeout", 60) catch return srv.argError(a)));

    sdk_lifecycle.sandboxPause(srv.sdk, sid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };

    if (wait) {
        // 与 CLI `pause --wait` 同语义：轮询到 paused，超时如实报错（不伪报成功）
        _ = sdk_lifecycle.sandboxInfo(srv.sdk, sid, .{ .wait_state = "paused", .timeout_s = timeout_s }) catch |e| return switch (e) {
            error.WaitTimeout => ToolResult.err(std.fmt.allocPrint(
                srv.arena, "超时 {d}s：沙箱未进入 paused 状态", .{timeout_s},
            ) catch "等待暂停超时"),
            error.MissingConfig, error.HttpError => srv.sdkError(),
            else => ToolResult.err(@errorName(e)),
        };
        return ToolResult.ok(std.fmt.allocPrint(srv.arena, "沙箱已暂停：{s}", .{sid}) catch "已暂停");
    }
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "暂停请求已发送：{s}（未等待状态；如需等待请传 wait=true）", .{sid}) catch "已暂停");
}

fn tSandboxResume(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    var timeout_s: ?u64 = null;
    if (try a.intOpt(srv.arena, "timeout")) |t| {
        if (t > 0) timeout_s = @intCast(t);
    }
    sdk_lifecycle.sandboxResume(srv.sdk, sid, timeout_s) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(std.fmt.allocPrint(srv.arena, "沙箱已恢复：{s}", .{sid}) catch "已恢复");
}

fn tSandboxRefresh(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    var duration_s: ?u64 = null;
    if (try a.intOpt(srv.arena, "duration")) |d| {
        if (d > 0) duration_s = @intCast(d);
    }
    const body = sdk_lifecycle.sandboxRefresh(srv.sdk, sid, duration_s) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxTimeout(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const seconds = a.intReq(srv.arena, "seconds") catch return srv.argError(a);
    if (seconds <= 0) {
        return ToolResult.err("参数错误：seconds 必须为正整数");
    }
    const body = sdk_lifecycle.sandboxSetTimeout(srv.sdk, sid, @intCast(seconds)) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxNetSet(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const internet = try a.boolOpt(srv.arena, "internet");
    const confirm = try a.boolOr(srv.arena, "confirm", false);

    // 安全检查：PUT 全量替换，缺 allowInternetAccess 会静默恢复公网访问；必须加 confirm=true 确认
    if ((internet == null or internet.? == true) and !confirm) {
        return ToolResult.err("PUT 全量替换，缺 allowInternetAccess 会静默恢复公网访问；确认请加 confirm=true");
    }

    const allow = (try a.strArrayOpt(srv.arena, "allow")) orelse &.{};
    const deny = (try a.strArrayOpt(srv.arena, "deny")) orelse &.{};

    const body = sdk_lifecycle.sandboxSetNet(srv.sdk, sid, .{
        .internet = internet,
        .allow = allow,
        .deny = deny,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxPorts(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const body = sdk_lifecycle.sandboxPorts(srv.sdk, sid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxClone(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const n_raw = try a.intOr(srv.arena, "n", 1);
    const n: usize = @intCast(@max(1, n_raw));
    const timeout = try a.intOpt(srv.arena, "timeout");
    const note = try a.strOpt(srv.arena, "note");
    const keep_snapshot = try a.boolOr(srv.arena, "keep_snapshot", false);

    const body = sdk_lifecycle.sandboxClone(srv.sdk, sid, .{
        .n = n,
        .timeout = timeout,
        .note = note,
        .keep_snapshot = keep_snapshot,
    }) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tSandboxDelete(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const sid = a.str(srv.arena, "sandbox_id") catch return srv.argError(a);
    const res = sdk_lifecycle.sandboxDelete(srv.sdk, sid, true) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return switch (res) {
        .deleted => ToolResult.ok(std.fmt.allocPrint(srv.arena, "沙箱已销毁：{s}", .{sid}) catch "已销毁"),
        .already_gone => ToolResult.ok(std.fmt.allocPrint(srv.arena, "沙箱已不存在（幂等成功）：{s}", .{sid}) catch "已不存在"),
    };
}

pub const tools = [_]Tool{
    .{
        .name = "sandbox_create",
        .description = "新建沙箱实例。支持按能力动态挑选模板（need: code/browser/desktop）或显式指定 template。",
        .schema =
        \\{"type":"object","properties":{"template":{"type":"string","description":"模板 ID 或服务端别名（本地 imageInfo 匹配请用 need / template_pick）"},"need":{"type":"string","description":"所需能力等级（默认 code；可选 browser/desktop）"},"timeout":{"type":"integer","description":"沙箱超时存活秒数"},"note":{"type":"string","description":"沙箱备注/名称"},"agent":{"type":"string","description":"创建者/Agent 名称标识"},"task":{"type":"string","description":"关联的任务描述"},"env":{"type":"object","description":"环境变量注入键值对"},"volume":{"type":"array","items":{"type":"string"},"description":"持久卷挂载数组（卷名[:挂载路径]）"},"lifecycle":{"type":"string","description":"超时行为（kill 或 pause）"},"auto_resume":{"type":"boolean","description":"是否开启访问时自动唤醒"},"no_internet":{"type":"boolean","description":"是否禁止访问公网"},"distribution_scope":{"type":"string","description":"调度节点范围（逗号分隔）"},"mcp":{"type":"object","description":"MCP 服务端配置对象"}},"required":[]}
        ,
        .handler = tSandboxCreate,
    },
    .{
        .name = "sandbox_list",
        .description = "列出当前用户的沙箱。支持按 metadata/state 过滤；支持 v1 与 v2。",
        .schema =
        \\{"type":"object","properties":{"metadata":{"type":"array","items":{"type":"string"},"description":"按 metadata 过滤，元素为 key=value 形式"},"state":{"type":"string","description":"按状态过滤，如 running/paused"},"limit":{"type":"string","description":"条数上限（仅 v2 生效）"},"v2":{"type":"boolean","description":"强制走 /v2/sandboxes"}},"required":[]}
        ,
        .handler = tSandboxList,
    },
    .{
        .name = "sandbox_info",
        .description = "查看单个沙箱详情（状态/规格/元数据/卷挂载/截止时间）。可用 wait 轮询到指定状态。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"wait":{"type":"string","description":"轮询到该状态后返回，如 running"},"timeout":{"type":"integer","description":"wait 的上限秒数，默认 120"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxInfo,
    },
    .{
        .name = "sandbox_pause",
        .description = "暂停沙箱（挂起快照，0 成本）。恢复用 sandbox_resume。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"wait":{"type":"boolean","description":"是否等待沙箱真正进入 paused（默认 false）"},"timeout":{"type":"integer","description":"wait 的上限秒数，默认 60"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxPause,
    },
    .{
        .name = "sandbox_resume",
        .description = "唤醒处于暂停（paused）状态的沙箱，可重设超时时间。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"timeout":{"type":"integer","description":"唤醒后的存活秒数"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxResume,
    },
    .{
        .name = "sandbox_refresh",
        .description = "续期沙箱（增加存活时长窗口）。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"duration":{"type":"integer","description":"增加的续期秒数"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxRefresh,
    },
    .{
        .name = "sandbox_timeout",
        .description = "直接修改沙箱的剩余存活秒数。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"seconds":{"type":"integer","description":"剩余存活秒数"}},"required":["sandbox_id","seconds"]}
        ,
        .handler = tSandboxTimeout,
    },
    .{
        .name = "sandbox_net_set",
        .description = "【全量替换】修改沙箱的网络出网策略（出站白名单/黑名单/公网访问开关）。缺省或放宽公网时需带 confirm=true。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"},"internet":{"type":"boolean","description":"是否允许访问公网"},"allow":{"type":"array","items":{"type":"string"},"description":"出站白名单域名列表"},"deny":{"type":"array","items":{"type":"string"},"description":"出站黑名单域名列表"},"confirm":{"type":"boolean","description":"放宽或缺省公网访问时的安全确认开关"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxNetSet,
    },
    .{
        .name = "sandbox_ports",
        .description = "实测探测沙箱内部当前正在监听的 TCP 端口列表及外部网关访问地址。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxPorts,
    },
    .{
        .name = "sandbox_clone",
        .description = "以指定沙箱为蓝本，先打快照再批量克隆出 n 个全新的独立沙箱。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"源沙箱 ID"},"n":{"type":"integer","description":"克隆数量（默认 1）"},"timeout":{"type":"integer","description":"克隆沙箱超时秒数"},"note":{"type":"string","description":"克隆沙箱备注"},"keep_snapshot":{"type":"boolean","description":"是否保留中间快照，默认 false"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxClone,
    },
    .{
        .name = "sandbox_delete",
        .description = "【破坏性·不可逆】销毁沙箱。404 视为已删除；503/409 自动按 Retry-After 重试最多 3 次。",
        .schema =
        \\{"type":"object","properties":{"sandbox_id":{"type":"string","description":"沙箱 ID"}},"required":["sandbox_id"]}
        ,
        .handler = tSandboxDelete,
    },
};
