//! cmd_image.zig —— tpl-from-image：从 OCI 镜像 registry 读取「模板默认值」，生成/提交建模板请求。
//!
//! 读取顺序（对齐旧 Go 版语义）：
//!   1) 镜像标签 io.cubesandbox.template.*（JSON 汇总 io.cubesandbox.template.defaults + 单键覆盖）
//!   2) 无端口标签时回退 Config.ExposedPorts（Dockerfile EXPOSE），并按惯例补 49983 /health 探针
//!
//! 用法：
//!   cube-cli tpl-from-image <镜像>                        # 摘要 + 请求体
//!   cube-cli tpl-from-image <镜像> --json                 # 只输出请求体 JSON
//!   cube-cli tpl-from-image <镜像> --curl                 # 输出可直接执行的 curl
//!   cube-cli tpl-from-image <镜像> --create --alias=x     # 直接提交到平台
//!
//! 只需 registry 匿名读权限；私有镜像传 --registry-user/--registry-pass。
//! 选项：--platform=linux/amd64（默认） --alias= --cpu= --memory= --writable= --env=K=V,...
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const envd = @import("envd.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;

const manifest_accept = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json";

const ImageRef = struct { host: []const u8, repo: []const u8, reference: []const u8 };

const TplDefaults = struct {
    image: []const u8 = "",
    writableLayerSize: []const u8 = "",
    exposedPorts: []const u32 = &.{},
    probePort: u32 = 0,
    probePath: []const u8 = "",
    cpu: u32 = 0,
    memory: u32 = 0,
    env: []const []const u8 = &.{},
    name: []const u8 = "",
};

// ---------------- 基础工具 ----------------

fn getObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = getObj(v, key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// 拆分镜像引用：host / repo / reference。
fn splitImageRef(arena: std.mem.Allocator, ref_in: []const u8) !ImageRef {
    var ref = ref_in;
    if (std.mem.startsWith(u8, ref, "https://")) ref = ref["https://".len..];
    if (std.mem.startsWith(u8, ref, "http://")) ref = ref["http://".len..];

    var reference: []const u8 = "latest";
    if (std.mem.lastIndexOfScalar(u8, ref, '@')) |i| {
        reference = ref[i + 1 ..];
        ref = ref[0..i];
    } else if (std.mem.lastIndexOfScalar(u8, ref, ':')) |i| {
        if (std.mem.indexOfScalar(u8, ref[i..], '/') == null) {
            reference = ref[i + 1 ..];
            ref = ref[0..i];
        }
    }

    var host: []const u8 = "registry-1.docker.io";
    if (std.mem.indexOfScalar(u8, ref, '/')) |i| {
        const first = ref[0..i];
        if (std.mem.indexOfScalar(u8, first, '.') != null or
            std.mem.indexOfScalar(u8, first, ':') != null or
            std.mem.eql(u8, first, "localhost"))
        {
            host = first;
            ref = ref[i + 1 ..];
        }
    }
    if (std.mem.eql(u8, host, "docker.io")) host = "registry-1.docker.io";
    var repo = ref;
    if (std.mem.eql(u8, host, "registry-1.docker.io") and std.mem.indexOfScalar(u8, repo, '/') == null) {
        repo = try std.fmt.allocPrint(arena, "library/{s}", .{repo});
    }
    return .{ .host = host, .repo = repo, .reference = reference };
}

fn parsePortListU32(arena: std.mem.Allocator, s: []const u8) ![]const u32 {
    var buf = try arena.alloc(u32, 64);
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, ",: ");
    while (it.next()) |tok| {
        const v = std.fmt.parseInt(u32, trim(tok), 10) catch continue;
        if (v == 0 or v > 65535) continue;
        var dup = false;
        for (buf[0..n]) |x| {
            if (x == v) dup = true;
        }
        if (!dup and n < buf.len) {
            buf[n] = v;
            n += 1;
        }
    }
    const out = buf[0..n];
    std.mem.sort(u32, out, {}, std.sort.asc(u32));
    return out;
}

// ---------------- registry 访问（手动跟随重定向） ----------------

const RegRes = struct { status: u16, body: []const u8 };

/// GET（手动跟随最多 5 跳重定向；跳转后不再携带 Accept/Authorization）。
/// registry 的 blob 请求常 302 到 CDN，必须跟随。
fn regFetch(c: *Ctx, url_in: []const u8, accept: []const u8, auth_header: []const u8) !RegRes {
    var url = url_in;
    var hops: usize = 0;
    while (true) {
        const uri = std.Uri.parse(url) catch {
            try c.out.print("URL 解析失败: {s}\n", .{url});
            return error.Registry;
        };
        var hs: [2]std.http.Header = undefined;
        var hn: usize = 0;
        if (accept.len > 0 and hops == 0) {
            hs[hn] = .{ .name = "Accept", .value = accept };
            hn += 1;
        }
        if (auth_header.len > 0 and hops == 0) {
            hs[hn] = .{ .name = "Authorization", .value = auth_header };
            hn += 1;
        }
        var req = try std.http.Client.request(c.client, .GET, uri, .{ .extra_headers = hs[0..hn], .keep_alive = false });
        req.headers.accept_encoding = .omit;
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [32 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        const status: u16 = @intFromEnum(response.head.status);

        if (status >= 300 and status < 400) {
            var loc: []const u8 = "";
            var it = response.head.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "location")) {
                    loc = h.value;
                    break;
                }
            }
            if (loc.len == 0) {
                try c.out.print("registry 返回 {d} 但没有 Location 头\n", .{status});
                return error.Registry;
            }
            if (loc[0] == '/') {
                const se = std.mem.indexOf(u8, url, "://") orelse 0;
                const he = std.mem.indexOfScalarPos(u8, url, se + 3, '/') orelse url.len;
                loc = try std.fmt.allocPrint(c.arena, "{s}{s}", .{ url[0..he], loc });
            }
            url = try c.arena.dupe(u8, loc);
            hops += 1;
            if (hops > 5) {
                try c.out.print("重定向次数过多（>5）\n", .{});
                return error.Registry;
            }
            continue;
        }

        if (status == 204 or status == 304) {
            return .{ .status = status, .body = "" };
        }
        const body_buf = try c.arena.alloc(u8, 8 << 20);
        var tb: [4096]u8 = undefined;
        const r = response.reader(&tb);
        var got: usize = 0;
        var zero_streak: usize = 0;
        const want: ?u64 = response.head.content_length;
        while (got < body_buf.len) {
            if (want) |wl| {
                const wu: usize = std.math.cast(usize, wl) orelse std.math.maxInt(usize);
                if (got >= wu) break;
            }
            var iov = [1][]u8{body_buf[got..]};
            const n = r.readVec(&iov) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            if (n == 0) {
                zero_streak += 1;
                if (zero_streak >= 64) break;
                continue;
            }
            zero_streak = 0;
            got += n;
        }
        if (response.head.content_encoding != .identity) {
            const dec = try decompressBody(body_buf[0..got], response.head.content_encoding);
            return .{ .status = status, .body = dec };
        }
        return .{ .status = status, .body = body_buf[0..got] };
    }
}

/// 兜底解压（gzip/zlib）：服务器无视"未请求压缩"仍返回压缩体时使用。
/// 压缩数据在 raw 中，解压结果复制回 raw 起始处（输出比输入大，借临时分配）。
fn decompressBody(raw: []u8, ce: std.http.ContentEncoding) ![]u8 {
    const container: std.compress.flate.Container = switch (ce) {
        .gzip => .gzip,
        .deflate => .zlib,
        else => return error.UnsupportedCompressionMethod,
    };
    const gpa = std.heap.smp_allocator;
    const cap = @min(64 << 20, @max(raw.len * 32, 1 << 20));
    const tmp = try gpa.alloc(u8, cap);
    defer gpa.free(tmp);
    var in: std.Io.Reader = .fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&in, container, &window);
    // 用 streamRemaining 驱动解压（内部正确处理"暂无输出"的 0 字节读，直到 EOF）
    var w = std.Io.Writer.fixed(tmp);
    _ = d.reader.streamRemaining(&w) catch |e| switch (e) {
        error.WriteFailed => {}, // 输出超过 cap：截断
        else => return e,
    };
    const out_n = @min(w.buffered().len, raw.len);
    @memcpy(raw[0..out_n], tmp[0..out_n]);
    return raw[0..out_n];
}


/// 取匿名/基本认证 token（公开镜像）；失败返回空串（继续无 token 尝试）。
fn fetchToken(c: *Ctx, ir: ImageRef, user: []const u8, pass: []const u8) []const u8 {
    var tok_host: []const u8 = ir.host;
    var service: []const u8 = ir.host;
    if (std.mem.eql(u8, ir.host, "registry-1.docker.io")) {
        tok_host = "auth.docker.io";
        service = "registry.docker.io";
    }
    const url = std.fmt.allocPrint(c.arena, "https://{s}/token?service={s}&scope=repository:{s}:pull", .{ tok_host, service, ir.repo }) catch return "";

    var auth: []const u8 = "";
    if (user.len > 0) {
        const raw = std.fmt.allocPrint(c.arena, "{s}:{s}", .{ user, pass }) catch return "";
        const enc = std.base64.standard.Encoder;
        const out = c.arena.alloc(u8, enc.calcSize(raw.len)) catch return "";
        _ = enc.encode(out, raw);
        auth = std.fmt.allocPrint(c.arena, "Basic {s}", .{out}) catch return "";
    }
    const res = regFetch(c, url, "", auth) catch return "";
    if (res.status < 200 or res.status >= 300) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch return "";
    if (parsed.value == .object) {
        if (parsed.value.object.get("token")) |t| {
            if (t == .string) return t.string;
        }
        if (parsed.value.object.get("access_token")) |t| {
            if (t == .string) return t.string;
        }
    }
    return "";
}

/// 拉 manifest（多架构时按 platform 选子 manifest）→ 返回 config digest。
fn fetchConfigDigest(c: *Ctx, ir: ImageRef, token: []const u8, platform: []const u8) ![]const u8 {
    const Man = struct {
        manifests: []const struct {
            digest: []const u8 = "",
            platform: struct { os: []const u8 = "", architecture: []const u8 = "" } = .{},
        } = &.{},
        config: struct { digest: []const u8 = "" } = .{},
    };
    const auth = if (token.len > 0) try std.fmt.allocPrint(c.arena, "Bearer {s}", .{token}) else "";

    const url = try std.fmt.allocPrint(c.arena, "https://{s}/v2/{s}/manifests/{s}", .{ ir.host, ir.repo, ir.reference });
    const res = try regFetch(c, url, manifest_accept, auth);
    if (res.status < 200 or res.status >= 300) {
        try c.out.print("读取 manifest 失败: HTTP {d}: {s}\n", .{ res.status, firstLine(res.body) });
        return error.Registry;
    }
    const parsed = std.json.parseFromSlice(Man, c.arena, res.body, .{ .ignore_unknown_fields = true }) catch |e| {
        try c.out.print("解析 manifest 失败: {t}\n", .{e});
        return error.Registry;
    };
    var cfg_digest: []const u8 = parsed.value.config.digest;
    if (parsed.value.manifests.len > 0) {
        var want_os: []const u8 = "linux";
        var want_arch: []const u8 = "amd64";
        if (std.mem.indexOfScalar(u8, platform, '/')) |i| {
            want_os = platform[0..i];
            want_arch = platform[i + 1 ..];
        }
        cfg_digest = "";
        for (parsed.value.manifests) |m| {
            if (std.mem.eql(u8, m.platform.os, want_os) and std.mem.eql(u8, m.platform.architecture, want_arch)) {
                const sub_url = try std.fmt.allocPrint(c.arena, "https://{s}/v2/{s}/manifests/{s}", .{ ir.host, ir.repo, m.digest });
                const sub_res = regFetch(c, sub_url, manifest_accept, auth) catch continue;
                if (sub_res.status < 200 or sub_res.status >= 300) continue;
                const sub = std.json.parseFromSlice(Man, c.arena, sub_res.body, .{ .ignore_unknown_fields = true }) catch continue;
                cfg_digest = sub.value.config.digest;
                break;
            }
        }
        if (cfg_digest.len == 0) {
            try c.out.print("镜像没有 {s} 架构\n", .{platform});
            return error.Registry;
        }
    }
    if (cfg_digest.len == 0) {
        try c.out.print("manifest 里没有 config（{s}）\n", .{ir.reference});
        return error.Registry;
    }
    return cfg_digest;
}

fn fetchConfigBlob(c: *Ctx, ir: ImageRef, digest: []const u8, token: []const u8) !std.json.Value {
    const auth = if (token.len > 0) try std.fmt.allocPrint(c.arena, "Bearer {s}", .{token}) else "";
    const url = try std.fmt.allocPrint(c.arena, "https://{s}/v2/{s}/blobs/{s}", .{ ir.host, ir.repo, digest });
    const res = try regFetch(c, url, "", auth);
    if (res.status < 200 or res.status >= 300) {
        try c.out.print("读取镜像 config 失败: HTTP {d}: {s}\n", .{ res.status, firstLine(res.body) });
        return error.Registry;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch |e| {
        try c.out.print("解析镜像 config 失败: {t}\n", .{e});
        return error.Registry;
    };
    return parsed.value;
}

// ---------------- 默认值合成 ----------------

const Synth = struct { d: TplDefaults, warnings: [][]const u8 };

fn defaultsFromImage(c: *Ctx, ref: []const u8, cfg: std.json.Value, a: util.Args) !Synth {
    var d = TplDefaults{ .image = ref };
    var warns_buf: [8][]const u8 = undefined;
    var nw: usize = 0;

    var labels: ?std.json.Value = null;
    var exposed: ?std.json.Value = null;
    if (getObj(cfg, "config")) |cc| {
        labels = getObj(cc, "Labels");
        exposed = getObj(cc, "ExposedPorts");
    }

    // ① 标签 JSON 汇总
    if (labels) |lv| {
        if (lv == .object) {
            if (lv.object.get("io.cubesandbox.template.defaults")) |dv| {
                if (dv == .string) {
                    if (std.json.parseFromSlice(TplDefaults, c.arena, dv.string, .{ .ignore_unknown_fields = true })) |parsed| {
                        const pd = parsed.value;
                        if (pd.image.len > 0) d.image = pd.image;
                        if (pd.writableLayerSize.len > 0) d.writableLayerSize = pd.writableLayerSize;
                        if (pd.exposedPorts.len > 0) d.exposedPorts = pd.exposedPorts;
                        if (pd.probePort > 0) d.probePort = pd.probePort;
                        if (pd.probePath.len > 0) d.probePath = pd.probePath;
                        if (pd.cpu > 0) d.cpu = pd.cpu;
                        if (pd.memory > 0) d.memory = pd.memory;
                        if (pd.env.len > 0) d.env = pd.env;
                        if (pd.name.len > 0) d.name = pd.name;
                    } else |_| {
                        warns_buf[nw] = "io.cubesandbox.template.defaults 不是合法 JSON，已忽略";
                        nw += 1;
                    }
                }
            }
            // ② 单键覆盖
            if (getStr(lv, "io.cubesandbox.template.exposed-ports")) |s| {
                d.exposedPorts = try parsePortListU32(c.arena, s);
            }
            if (getStr(lv, "io.cubesandbox.template.probe-port")) |s| {
                d.probePort = std.fmt.parseInt(u32, trim(s), 10) catch d.probePort;
            }
            if (getStr(lv, "io.cubesandbox.template.probe-path")) |s| d.probePath = trim(s);
            if (getStr(lv, "io.cubesandbox.template.writable-layer-size")) |s| d.writableLayerSize = trim(s);
            if (getStr(lv, "io.cubesandbox.template.cpu")) |s| d.cpu = std.fmt.parseInt(u32, trim(s), 10) catch d.cpu;
            if (getStr(lv, "io.cubesandbox.template.memory")) |s| d.memory = std.fmt.parseInt(u32, trim(s), 10) catch d.memory;
            if (getStr(lv, "io.cubesandbox.template.alias")) |s| d.name = trim(s);
        }
    }

    // ③ 无端口标签时用 EXPOSE 兜底
    if (d.exposedPorts.len == 0) {
        if (exposed) |ev| {
            if (ev == .object and ev.object.count() > 0) {
                const buf = try c.arena.alloc(u32, 64);
                var pn: usize = 0;
                var it = ev.object.iterator();
                while (it.next()) |e| {
                    var key = e.key_ptr.*;
                    if (std.mem.indexOfScalar(u8, key, '/')) |i| key = key[0..i];
                    const v = std.fmt.parseInt(u32, trim(key), 10) catch continue;
                    var dup = false;
                    for (buf[0..pn]) |x| {
                        if (x == v) dup = true;
                    }
                    if (!dup and pn < buf.len) {
                        buf[pn] = v;
                        pn += 1;
                    }
                }
                const out = buf[0..pn];
                std.mem.sort(u32, out, {}, std.sort.asc(u32));
                d.exposedPorts = out;
                if (pn > 0) {
                    warns_buf[nw] = "端口取自镜像 EXPOSE（无 io.cubesandbox.template 标签）";
                    nw += 1;
                }
                for (d.exposedPorts) |pp| {
                    if (pp == 49983 and d.probePort == 0) {
                        d.probePort = 49983;
                        d.probePath = "/health";
                        warns_buf[nw] = "探针按惯例取 envd 49983 /health";
                        nw += 1;
                        break;
                    }
                }
            }
        }
    }

    // ④ 命令行覆盖
    if (a.get("alias")) |v| d.name = v;
    if (a.get("writable")) |v| d.writableLayerSize = v;
    if (a.get("cpu")) |v| d.cpu = std.fmt.parseInt(u32, v, 10) catch d.cpu;
    if (a.get("memory")) |v| d.memory = std.fmt.parseInt(u32, v, 10) catch d.memory;
    if (a.get("env")) |v| {
        var ev_buf = try c.arena.alloc([]const u8, 32);
        var en: usize = 0;
        var it = std.mem.tokenizeScalar(u8, v, ',');
        while (it.next()) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=') != null and en < ev_buf.len) {
                ev_buf[en] = trim(tok);
                en += 1;
            }
        }
        d.env = ev_buf[0..en];
    }
    if (d.writableLayerSize.len == 0) {
        d.writableLayerSize = "12G";
        warns_buf[nw] = "镜像未声明可写层大小，暂按 12G 估计（--writable= 可覆盖）";
        nw += 1;
    }

    return .{ .d = d, .warnings = warns_buf[0..nw] };
}

fn buildBody(c: *Ctx, d: TplDefaults) ![]const u8 {
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    try w.print("{{\"image\":\"{s}\"", .{try envd.jsonEscape(c.arena, d.image)});
    if (d.writableLayerSize.len > 0) {
        try w.print(",\"writableLayerSize\":\"{s}\"", .{try envd.jsonEscape(c.arena, d.writableLayerSize)});
    }
    if (d.exposedPorts.len > 0) {
        try w.writeAll(",\"exposedPorts\":[");
        for (d.exposedPorts, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{d}", .{p});
        }
        try w.writeAll("]");
    }
    if (d.probePort > 0) try w.print(",\"probePort\":{d}", .{d.probePort});
    if (d.probePath.len > 0) try w.print(",\"probePath\":\"{s}\"", .{try envd.jsonEscape(c.arena, d.probePath)});
    if (d.cpu > 0) try w.print(",\"cpu\":{d}", .{d.cpu});
    if (d.memory > 0) try w.print(",\"memory\":{d}", .{d.memory});
    if (d.env.len > 0) {
        try w.writeAll(",\"env\":[");
        for (d.env, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{try envd.jsonEscape(c.arena, e)});
        }
        try w.writeAll("]");
    }
    if (d.name.len > 0) try w.print(",\"name\":\"{s}\"", .{try envd.jsonEscape(c.arena, d.name)});
    try w.writeAll("}");
    return w.buffered();
}

// ---------------- 命令入口 ----------------

fn cmdTplFromImage(c: *Ctx, a: util.Args) !void {
    const ref = a.at(0) orelse {
        try c.out.print("用法: tpl-from-image <镜像引用> [--alias=] [--cpu=] [--memory=] [--writable=] [--env=K=V,..] [--json|--curl|--create] [--platform=linux/amd64]\n", .{});
        return error.MissingArg;
    };
    const user = a.get("registry-user") orelse "";
    const pass = a.get("registry-pass") orelse "";
    const platform = a.get("platform") orelse "linux/amd64";

    const ir = try splitImageRef(c.arena, ref);
    const token = fetchToken(c, ir, user, pass);
    const digest = try fetchConfigDigest(c, ir, token, platform);
    const blob = try fetchConfigBlob(c, ir, digest, token);
    const synth = try defaultsFromImage(c, ref, blob, a);
    const d = synth.d;

    const body = try buildBody(c, d);

    if (a.has("json")) {
        try c.out.print("{s}\n", .{body});
        return;
    }
    if (a.has("curl")) {
        try c.out.print("curl -sS -X POST \"$CUBESANDBOX_API_URL/templates\" \\\n  -H \"X-API-KEY: $CUBESANDBOX_API_KEY\" -H \"Content-Type: application/json\" \\\n  -d '{s}'\n", .{body});
        return;
    }

    // 人类可读摘要
    const arch = getStr(blob, "architecture") orelse "?";
    const os_name = getStr(blob, "os") orelse "?";
    try c.out.print("镜像: {s}\n", .{ref});
    try c.out.print("  架构: {s}/{s}\n", .{ os_name, arch });
    try c.out.print("  暴露端口: ", .{});
    for (d.exposedPorts, 0..) |p, i| {
        if (i > 0) try c.out.print(",", .{});
        try c.out.print("{d}", .{p});
    }
    try c.out.print("\n", .{});
    try c.out.print("  就绪探针: {d} {s}\n", .{ d.probePort, d.probePath });
    try c.out.print("  可写层: {s}   CPU: {d}  内存: {d}MiB  别名: {s}\n", .{ d.writableLayerSize, d.cpu, d.memory, d.name });
    for (synth.warnings) |wk| {
        std.debug.print("⚠️  {s}\n", .{wk});
    }
    try c.out.print("\n建模板请求体（可直接粘进 WebUI 或 --json 管道使用）:\n{s}\n", .{body});

    if (a.has("create")) {
        const buf = try c.arena.alloc(u8, 2 << 20);
        const res = try c.control(.POST, "/templates", body, buf);
        try c.out.print("已提交: {s}\n", .{firstLine(res.body)});
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "tpl-from-image")) {
        try cmdTplFromImage(c, a);
        return true;
    }
    return false;
}
