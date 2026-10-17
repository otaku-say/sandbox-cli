//! MCP 工具 —— 模板域。
//!
//! 包括列出模板、挑选模板以及查询模板详情。
const std = @import("std");
const types = @import("mcp_types.zig");
const argmod = @import("mcp_args.zig");
const sdk_template = @import("sdk_template.zig");

const Server = types.Server;
const Tool = types.Tool;
const ToolResult = types.ToolResult;

fn tTplList(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    if (a.has("instance_type") and try a.strOpt(srv.arena, "instance_type") == null) {
        return ToolResult.err("参数错误：instance_type 需要是字符串");
    }
    if (a.has("status") and try a.strOpt(srv.arena, "status") == null) {
        return ToolResult.err("参数错误：status 需要是字符串");
    }
    const itype = try a.strOpt(srv.arena, "instance_type");
    const status = try a.strOpt(srv.arena, "status");
    var body = sdk_template.templateList(srv.sdk) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    if (itype != null or status != null) {
        body = try sdk_template.filterTemplatesJson(srv.arena, body, itype, status);
    }
    return ToolResult.ok(types.clampText(srv.arena, body));
}

fn tTplPick(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    if (a.has("need") and try a.strOpt(srv.arena, "need") == null) {
        return ToolResult.err("参数错误：need 需要是字符串");
    }
    const need = try a.strOpt(srv.arena, "need") orelse "code";
    const res = sdk_template.templatePick(srv.sdk, need) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        error.NotFound => ToolResult.err("没有满足条件的 READY 模板"),
        else => ToolResult.err(@errorName(e)),
    };
    const out = try std.fmt.allocPrint(srv.arena, "{s}\nneed={s}  能力={s}  网关={d}", .{ res.id, need, res.caps, res.gw });
    return ToolResult.ok(out);
}

fn tTplInfo(srv: *Server, a: *argmod.Args) anyerror!ToolResult {
    const tid = a.str(srv.arena, "template_id") catch return srv.argError(a);
    const body = sdk_template.templateInfo(srv.sdk, tid) catch |e| return switch (e) {
        error.MissingConfig, error.HttpError => srv.sdkError(),
        else => ToolResult.err(@errorName(e)),
    };
    return ToolResult.ok(types.clampText(srv.arena, body));
}

pub const tools = [_]Tool{
    .{
        .name = "template_list",
        .description = "查询当前平台支持的所有环境模板列表（ID、状态、镜像等）。",
        .schema =
        \\{"type":"object","properties":{"instance_type":{"type":"string","description":"按实例类型过滤"},"status":{"type":"string","description":"按模板状态过滤（如 READY）"}},"required":[]}
        ,
        .handler = tTplList,
    },
    .{
        .name = "template_pick",
        .description = "按所需能力（code/browser/desktop）动态挑选可用的最佳 READY 模板。",
        .schema =
        \\{"type":"object","properties":{"need":{"type":"string","description":"所需能力等级：code（默认）、browser 或 desktop"}},"required":[]}
        ,
        .handler = tTplPick,
    },
    .{
        .name = "template_info",
        .description = "查询指定模板的详细配置（暴露端口、镜像、创建时间等）。",
        .schema =
        \\{"type":"object","properties":{"template_id":{"type":"string","description":"模板 ID"}},"required":["template_id"]}
        ,
        .handler = tTplInfo,
    },
};
