//! 文件操作：cat / read / write / ls / tree / stat / mkdir / rm / mv / cp / edit / grep / search / get
//!
//! aiod v2 文件 API：
//!   GET  /v2/fs/read?path=          读文件（响应即内容）
//!   POST /v2/fs/write               {"path":...,"content":...}
//!   GET  /v2/fs/list?path=          列目录
//!   GET  /v2/fs/stat?path=
//!   GET  /v2/fs/tree?path=          整树（tar 原始字节）
//!   POST /v2/fs/mkdir | remove | move | copy | edit | grep
//!   GET  /v2/fs/search?path=&pattern=
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

fn fail(c: *Ctx, res: httpc.Response) !void {
    try c.out.print("HTTP {d}: {s}\n", .{ res.status, res.body });
    return error.HttpError;
}

fn queryPath(c: *Ctx, base_path: []const u8, path: []const u8, user: ?[]const u8) ![]const u8 {
    const enc = try urlEncode(c.arena, path);
    if (user) |u| {
        return std.fmt.allocPrint(c.arena, "{s}?path={s}&user={s}", .{ base_path, enc, try urlEncode(c.arena, u) });
    }
    return std.fmt.allocPrint(c.arena, "{s}?path={s}", .{ base_path, enc });
}

fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        n += if (safe) 1 else 3;
    }
    const out = try arena.alloc(u8, n);
    var i: usize = 0;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        if (safe) {
            out[i] = ch;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = hex[ch >> 4];
            out[i + 2] = hex[ch & 0x0F];
            i += 3;
        }
    }
    return out[0..i];
}

/// GET 类命令的通用流程
fn getJSON(c: *Ctx, path: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

/// POST 类命令的通用流程
fn postJSON(c: *Ctx, path: []const u8, body: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), body, buf);
    if (!res.ok()) return fail(c, res);
    try c.out.print("{s}\n", .{res.body});
}

fn cmdCat(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    // start_line/end_line：行级截取（end_line 不含尾行）
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 1024));
    try w.print("/v2/fs/read?path={s}", .{try urlEncode(c.arena, path)});
    if (a.get("user")) |u| try w.print("&user={s}", .{try urlEncode(c.arena, u)});
    if (a.get("start")) |v| try w.print("&start_line={s}", .{v});
    if (a.get("end")) |v| try w.print("&end_line={s}", .{v});
    const res = try httpc.get(c.client, try c.url(w.buffered()), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    // aiod 返回 {"success":true,"data":{"content":"..."}}，提取 content 原样输出
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch {
        try c.out.print("{s}", .{res.body});
        return;
    };
    if (dataString(parsed.value, "content")) |content| {
        try c.out.print("{s}", .{content});
    } else {
        try c.out.print("{s}\n", .{res.body});
    }
}

/// 取 data.<key> 的字符串值（aiod 统一响应包装）。
fn dataString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const d = v.object.get("data") orelse return null;
    if (d != .object) return null;
    const f = d.object.get(key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

fn cmdWrite(c: *Ctx, a: util.Args) !void {
    const local = a.at(0) orelse return error.MissingArg;
    const remote = a.at(1) orelse return error.MissingArg;

    var data: []const u8 = "";
    if (std.mem.eql(u8, local, "-")) {
        const buf = try c.arena.alloc(u8, BUF);
        var rbuf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().reader(c.io, &rbuf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = r.interface.readSliceShort(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        data = buf[0..total];
    } else {
        const dir = std.Io.Dir.cwd();
        data = dir.readFileAlloc(c.io, local, c.arena, .limited(BUF)) catch |e| return e;
    }

    // --append / --encoding / --leading-newline / --trailing-newline 透传
    const cap = util.jsonEscapedLen(remote) + util.jsonEscapedLen(data) + 256;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, cap));
    try w.print("{{\"path\":\"{s}\",\"content\":\"{s}\"", .{
        try util.jsonEscape(c.arena, remote), try util.jsonEscape(c.arena, data),
    });
    if (a.has("append")) try w.print(",\"append\":true", .{});
    if (a.get("encoding")) |v| try w.print(",\"encoding\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    if (a.has("leading-newline")) try w.print(",\"leading_newline\":true", .{});
    if (a.has("trailing-newline")) try w.print(",\"trailing_newline\":true", .{});
    try w.print("}}", .{});
    try postJSON(c, "/v2/fs/write", w.buffered());
}

/// Range 响应头解析：从 `bytes <start>-<end>/<total>` 取 total。
/// 找不到或格式不符时返回 0。
fn parseTotalFromContentRange(hdr: []const u8) u64 {
    // 形如 "bytes 0-1023/20971520" → 取最后一个斜杠后的数字
    const slash = std.mem.lastIndexOfScalar(u8, hdr, '/') orelse return 0;
    var v: u64 = 0;
    var any = false;
    for (hdr[slash + 1 ..]) |ch| {
        if (ch >= '0' and ch <= '9') {
            v = v * 10 + (ch - '0');
            any = true;
        } else break;
    }
    return if (any) v else 0;
}

/// 给请求加 Range 头：`bytes <from>-<to>`
fn rangeHeaders(c: *Ctx, from: u64, to: u64) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 4);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/octet-stream" };
    n += 1;
    hs[n] = .{ .name = "Range", .value = try std.fmt.allocPrint(c.arena, "bytes={d}-{d}", .{ from, to }) };
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
}

/// get <远端路径> <本地文件> [--user=] [--chunk=<字节>] [--no-range]
///
/// 默认 **Range 分块流式下载**：
///   1. `bytes=0-0` 探测（只读响应头，不写盘）→ 从 content-range 解析总长
///   2. 从 0 起按 --chunk 顺序逐段请求，每段经 streamToFile 直接写文件
///   3. 单段失败指数退避重试（最多 6 次）；全部写完 rename 落地，失败留 .part
///
/// 历史包袱：旧实现把整个响应收进 8 MiB buf，服务端返回更大时**静默截断**
/// （退出码 0、文件残缺）。现路径上文件内容只走 streamToFile。
fn cmdGet(c: *Ctx, a: util.Args) !void {
    const remote = a.at(0) orelse return error.MissingArg;
    const local = a.at(1) orelse return error.MissingArg;

    const no_range = a.has("no-range");
    const chunk: u64 = blk: {
        if (no_range) break :blk 0;
        const v = a.get("chunk") orelse break :blk 4 << 20; // 默认 4 MiB/段
        const parsed = std.fmt.parseInt(u64, v, 10) catch {
            try c.out.print("无效的 --chunk 值：{s}（应为字节数）\n", .{v});
            return error.InvalidChunk;
        };
        if (parsed < 1024) {
            try c.out.print("--chunk 过小：{d}（至少 1024 字节）\n", .{parsed});
            return error.InvalidChunk;
        }
        break :blk parsed;
    };

    const base_url = try c.url(try queryPath(c, "/v2/fs/download", remote, a.get("user")));
    const dir = std.Io.Dir.cwd();
    const part = try std.fmt.allocPrint(c.arena, "{s}.part", .{local});
    // 协议层缓冲（错误体、探测响应体）
    const buf = try c.arena.alloc(u8, 64 << 10);

    // ---------- 探测总长（bytes=0-0，不写盘） ----------
    var total: u64 = 0;
    var range_ok = !no_range;
    if (range_ok) {
        const probe = try rangeHeaders(c, 0, 0);
        const r = httpc.request(c.client, .GET, base_url, probe, null, buf) catch blk: {
            range_ok = false;
            break :blk null;
        };
        if (r) |resp| {
            switch (resp.status) {
                206 => {
                    total = parseTotalFromContentRange(resp.content_range);
                    if (total == 0) range_ok = false;
                },
                200, 416 => range_ok = false,
                else => {
                    try c.out.print("HTTP {d}: {s}\n", .{ resp.status, resp.body });
                    return error.HttpError;
                },
            }
        }
    }

    // 打开 .part（原子写：全部完成才 rename 成目标名）
    var f = try dir.createFile(c.io, part, .{ .truncate = true });
    defer f.close(c.io);

    if (!range_ok) {
        // ---------- 整段流式下载 ----------
        const headers = try auth(c);
        const st = try httpc.streamToFile(c.client, c.io, .GET, base_url, headers, null, f);
        if (st.status < 200 or st.status >= 300) {
            try c.out.print("HTTP {d}\n", .{st.status});
            return error.HttpError;
        }
        try dir.rename(part, dir, local, c.io);
        try c.out.print("saved {d} bytes -> {s}\n", .{ st.bytes, local });
        return;
    }

    // ---------- Range 分块下载 ----------
    try c.out.print("总长度 {d} 字节，按 {d} 字节分块下载\n", .{ total, chunk });
    var written: u64 = 0;
    var attempt: u32 = 0;
    const max_attempts: u32 = 6;

    while (written < total) {
        const want_end = @min(written + chunk - 1, total - 1);
        const hs = try rangeHeaders(c, written, want_end);
        const st = httpc.streamToFile(c.client, c.io, .GET, base_url, hs, null, f) catch |e| {
            attempt += 1;
            if (attempt >= max_attempts) {
                try c.out.print("第 {d} 段失败（{t}），已重试 {d} 次\n", .{ written / chunk, e, attempt });
                return e;
            }
            const secs: i64 = @intCast(@min(@as(u64, 1) << @intCast(@min(attempt, 5)), 32));
            try c.out.print("第 {d} 段失败，{d}s 后重试\n", .{ written / chunk, secs });
            std.Io.sleep(c.io, .fromSeconds(secs), .awake) catch {};
            continue;
        };
        if (st.status == 416) break; // 越界：按完成处理
        if (st.status != 206 and st.status != 200) {
            try c.out.print("HTTP {d}\n", .{st.status});
            return error.HttpError;
        }
        if (st.bytes == 0) {
            attempt += 1;
            if (attempt >= max_attempts) return error.ShortRead;
            std.Io.sleep(c.io, .fromSeconds(1), .awake) catch {};
            continue;
        }
        attempt = 0;
        written += st.bytes;
        try c.out.print("已下载 {d}/{d} 字节\n", .{ written, total });
    }

    if (written != total) {
        try c.out.print("下载不完整：期望 {d} 字节，实际 {d} 字节（.part 已保留，可续跑）\n", .{ total, written });
        return error.ShortRead;
    }
    try dir.rename(part, dir, local, c.io);
    try c.out.print("saved {d} bytes -> {s}\n", .{ written, local });
}

fn cmdMkdir(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const body = if (a.has("parents"))
        try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\",\"parents\":true}}", .{try util.jsonEscape(c.arena, path)})
    else
        try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{try util.jsonEscape(c.arena, path)});
    try postJSON(c, "/v2/fs/mkdir", body);
}

fn cmdRm(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    // --recursive → recursive=true（否则非空目录服务端 500）
    const body = if (a.has("recursive"))
        try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\",\"recursive\":true}}", .{try util.jsonEscape(c.arena, path)})
    else
        try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{try util.jsonEscape(c.arena, path)});
    try postJSON(c, "/v2/fs/delete", body);
}

fn copyMove(c: *Ctx, cmd: []const u8, a: util.Args) !void {
    const src = a.at(0) orelse return error.MissingArg;
    const dst = a.at(1) orelse return error.MissingArg;
    const route: []const u8 = if (std.mem.eql(u8, cmd, "mv")) "/v2/fs/move" else "/v2/fs/copy";
    const b = if (a.has("overwrite"))
        try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\",\"overwrite\":true}}", .{
            try util.jsonEscape(c.arena, src), try util.jsonEscape(c.arena, dst),
        })
    else
        try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, src), try util.jsonEscape(c.arena, dst),
        });
    try postJSON(c, route, b);
}

fn cmdEdit(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    // replace_mode（大写枚举）：多处匹配时必须显式给出才会成功
    const replace_mode: ?[]const u8 = if (a.has("replace-all"))
        "ALL"
    else if (a.has("replace-first"))
        "FIRST"
    else if (a.has("replace-last"))
        "LAST"
    else
        null;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    if (a.get("old")) |old| {
        try w.print("{{\"path\":\"{s}\",\"command\":\"str_replace\",\"old_str\":\"{s}\",\"new_str\":\"{s}\"", .{
            try util.jsonEscape(c.arena, path), try util.jsonEscape(c.arena, old),
            try util.jsonEscape(c.arena, a.get("new") orelse ""),
        });
        if (replace_mode) |m| try w.print(",\"replace_mode\":\"{s}\"", .{m});
        try w.print("}}", .{});
    } else if (a.get("insert")) |line| {
        try w.print("{{\"path\":\"{s}\",\"command\":\"insert\",\"insert_line\":{s},\"new_str\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, path), line, try util.jsonEscape(c.arena, a.get("text") orelse ""),
        });
    } else return error.MissingArg;
    try postJSON(c, "/v2/fs/edit", w.buffered());
}

/// 输出 JSON 字符串数组字段："key":["a","b"]（逗号分隔输入）。
fn writeStrArray(w: *std.Io.Writer, c: *Ctx, key: []const u8, spec: []const u8) !void {
    try w.print(",\"{s}\":[", .{key});
    var it = std.mem.splitScalar(u8, spec, ',');
    var first = true;
    while (it.next()) |p| {
        if (p.len == 0) continue;
        if (!first) try w.print(",", .{});
        try w.print("\"{s}\"", .{try util.jsonEscape(c.arena, p)});
        first = false;
    }
    try w.print("]", .{});
}

fn cmdGrep(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const pattern = a.at(1) orelse return error.MissingArg;
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    try w.print("{{\"path\":\"{s}\",\"pattern\":\"{s}\",\"recursive\":true", .{
        try util.jsonEscape(c.arena, path), try util.jsonEscape(c.arena, pattern),
    });
    if (a.has("fixed")) try w.print(",\"fixed_strings\":true", .{});
    if (a.has("ignore-case")) try w.print(",\"case_insensitive\":true", .{});
    if (a.has("multiline")) try w.print(",\"multiline\":true", .{});
    if (a.get("context")) |v| try w.print(",\"context_before\":{s},\"context_after\":{s}", .{ v, v });
    if (a.get("max")) |v| try w.print(",\"max_results\":{s}", .{v});
    if (a.get("offset")) |v| try w.print(",\"offset\":{s}", .{v});
    if (a.get("type")) |v| try w.print(",\"type\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    if (a.get("include")) |v| try writeStrArray(&w, c, "include", v);
    if (a.get("exclude")) |v| try writeStrArray(&w, c, "exclude", v);
    try w.print("}}", .{});
    try postJSON(c, "/v2/fs/grep", w.buffered());
}

fn cmdSearch(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse return error.MissingArg;
    const pattern = a.at(1) orelse return error.MissingArg;
    const q = try std.fmt.allocPrint(c.arena, "/v2/fs/search?path={s}&pattern={s}", .{
        try urlEncode(c.arena, path), try urlEncode(c.arena, pattern),
    });
    try getJSON(c, q);
}

/// put <本地文件|-> <远端路径>：multipart 上传到服务端 /tmp 再移动到目标（二进制安全）。
/// 单引号 shell 转义（POSIX）：内部单引号用 '\'' 断开。
fn shellQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try arena.alloc(u8, s.len * 4 + 8));
    try w.writeAll("'");
    for (s) |ch| {
        if (ch == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(ch);
        }
    }
    try w.writeAll("'");
    return w.buffered();
}

/// 取响应 JSON 里的退出码（兼容顶层 / data / data.command 三种嵌套）。
fn jsonExitCode(v: std.json.Value) ?i64 {
    if (v != .object) return null;
    if (v.object.get("exit_code")) |f| {
        if (f == .integer) return f.integer;
    }
    const nests = [_][]const u8{ "data", "command" };
    for (nests) |n| {
        if (v.object.get(n)) |inner| {
            if (inner == .object) {
                if (inner.object.get("exit_code")) |f| {
                    if (f == .integer) return f.integer;
                }
                if (inner.object.get("command")) |cmd| {
                    if (cmd == .object) {
                        if (cmd.object.get("exit_code")) |f| {
                            if (f == .integer) return f.integer;
                        }
                    }
                }
            }
        }
    }
    return null;
}

/// 在沙箱内同步执行一条 shell 命令，返回退出码（null = 请求本身失败）。
fn execShellCode(c: *Ctx, command: []const u8) !?i64 {
    const buf = try c.arena.alloc(u8, BUF);
    const body = try std.fmt.allocPrint(c.arena, "{{\"command\":\"{s}\"}}", .{try util.jsonEscape(c.arena, command)});
    const res = try httpc.postJson(c.client, try c.url("/v2/commands"), try jsonAuth(c), body, buf);
    if (!res.ok()) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch return null;
    return jsonExitCode(parsed.value);
}

/// 分块上传大文件：切成 8 MiB 段逐段 multipart 上传，再在沙箱内 `cat` 拼接。
///
/// 为什么需要：单连接连续上传大文件会撞网关/代理的传输上限
/// （实测 70 MiB 成功、200 MiB 在中途 error.WriteFailed）。分块把每段的
/// 连接负载压到 8 MiB，规避该上限；拼接在沙箱侧完成，客户端不占额外内存。
fn putChunkedUpload(c: *Ctx, local: []const u8, remote: []const u8, file_size: u64, hs: httpc.Headers, boundary: []const u8, buf: []u8) !void {
    const CHUNK: u64 = 8 << 20;
    const nchunks: u64 = (file_size + CHUNK - 1) / CHUNK;
    const token = std.hash.Wyhash.hash(0, local);
    const parts = try c.arena.alloc([]const u8, @intCast(nchunks));

    var i: u64 = 0;
    while (i < nchunks) : (i += 1) {
        const offset = i * CHUNK;
        const len = @min(CHUNK, file_size - offset);
        const part_name = try std.fmt.allocPrint(c.arena, ".aiod-put-{x}-{d}", .{ token, i });
        const res = httpc.uploadFileMultipartRange(c.client, c.io, try c.url("/v2/fs/upload"), hs, boundary, "file", part_name, local, offset, len, buf) catch |e| {
            try c.out.print("段 {d}/{d} 上传失败: {t}\n", .{ i + 1, nchunks, e });
            return e;
        };
        if (!res.ok()) return fail(c, res);
        const tmp = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch break :blk null;
            break :blk dataString(parsed.value, "file_path");
        } orelse {
            try c.out.print("段 {d} 响应缺少 file_path: {s}\n", .{ i, res.body });
            return error.NoFilePath;
        };
        parts[@intCast(i)] = try c.arena.dupe(u8, tmp);
    }
    try c.out.print("已上传 {d} 段，开始拼接…\n", .{nchunks});

    const cmd = blk: {
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 256 << 10));
        try w.writeAll("cat");
        for (parts) |p| try w.print(" {s}", .{try shellQuote(c.arena, p)});
        try w.print(" > {s}", .{try shellQuote(c.arena, remote)});
        try w.writeAll(" && rm -f");
        for (parts) |p| try w.print(" {s}", .{try shellQuote(c.arena, p)});
        break :blk w.buffered();
    };
    const code = try execShellCode(c, cmd);
    if (code == null or code.? != 0) {
        try c.out.print("拼接失败（exit={?d}）；临时分片保留在沙箱 /tmp 便于排查\n", .{code});
        return error.ConcatFailed;
    }
    try c.out.print("已上传 {s} -> {s}（{d} 字节，分 {d} 段）\n", .{ local, remote, file_size, nchunks });
}

fn cmdPut(c: *Ctx, a: util.Args) !void {
    const local = a.at(0) orelse return error.MissingArg;
    const remote = a.at(1) orelse return error.MissingArg;

    var fname: []const u8 = local;
    if (std.mem.lastIndexOfScalar(u8, local, '/')) |i| fname = local[i + 1 ..];
    if (std.mem.eql(u8, fname, "-")) fname = "stdin.bin";

    // 预检查：目标已存在时自动加 --overwrite，避免 move 失败导致临时文件残留
    var need_overwrite = a.has("overwrite");
    if (!need_overwrite) {
        var stat_w = std.Io.Writer.fixed(try c.arena.alloc(u8, 1024));
        try stat_w.print("/v2/fs/stat?path={s}", .{try urlEncode(c.arena, remote)});
        if (a.get("user")) |u| try stat_w.print("&user={s}", .{try urlEncode(c.arena, u)});
        const stat_buf = try c.arena.alloc(u8, BUF);
        const stat_res = httpc.get(c.client, try c.url(stat_w.buffered()), try auth(c), stat_buf) catch null;
        if (stat_res) |sr| {
            if (sr.ok()) {
                std.debug.print("目标已存在，自动启用 --overwrite\n", .{});
                need_overwrite = true;
            }
        }
    }

    const boundary = "ZigAioCliBoundary7f3a9c";
    const ct = try std.fmt.allocPrint(c.arena, "multipart/form-data; boundary={s}", .{boundary});
    const hs = try c.arena.alloc(std.http.Header, 3);
    var hn: usize = 0;
    hs[hn] = .{ .name = "Accept", .value = "application/json" };
    hn += 1;
    hs[hn] = .{ .name = "Content-Type", .value = ct };
    hn += 1;
    if (c.key) |k| {
        hs[hn] = .{ .name = "X-API-KEY", .value = k };
        hn += 1;
    }

    const buf = try c.arena.alloc(u8, BUF);
    var uploaded: u64 = 0;
    var res: httpc.Response = undefined;

    if (std.mem.eql(u8, local, "-")) {
        // stdin：无长度信息，仍需整体读入（保持 64 MiB 上限）
        const data = blk: {
            const b = try c.arena.alloc(u8, 64 << 20);
            var rbuf: [8192]u8 = undefined;
            var r = std.Io.File.stdin().reader(c.io, &rbuf);
            var total: usize = 0;
            while (total < b.len) {
                const n = r.interface.readSliceShort(b[total..]) catch break;
                if (n == 0) break;
                total += n;
            }
            break :blk b[0..total];
        };
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, data.len + 4096));
        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n", .{fname});
        try w.print("Content-Type: application/octet-stream\r\n\r\n", .{});
        try w.writeAll(data);
        try w.print("\r\n--{s}--\r\n", .{boundary});
        res = try httpc.request(c.client, .POST, try c.url("/v2/fs/upload"), hs[0..hn], w.buffered(), buf);
        uploaded = data.len;
    } else {
        // 文件：按大小选路径 —— 小文件流式单请求；大文件分块（规避单连接中断）
        var probe_f = std.Io.Dir.cwd().openFile(c.io, local, .{}) catch |e| {
            try c.out.print("读取本地文件 {s} 失败: {t}\n", .{ local, e });
            return e;
        };
        const st = probe_f.stat(c.io) catch |e| {
            probe_f.close(c.io);
            try c.out.print("读取本地文件 {s} 失败: {t}\n", .{ local, e });
            return e;
        };
        probe_f.close(c.io);

        const CHUNK_THRESHOLD: u64 = 32 << 20; // >32 MiB 走分块
        if (st.size > CHUNK_THRESHOLD) {
            try putChunkedUpload(c, local, remote, st.size, hs[0..hn], boundary, buf);
            return; // 分块路径已在沙箱内完成拼接落地
        }
        res = httpc.uploadFileMultipartRange(c.client, c.io, try c.url("/v2/fs/upload"), hs[0..hn], boundary, "file", fname, local, 0, st.size, buf) catch |e| {
            try c.out.print("上传 {s} 失败: {t}\n", .{ local, e });
            return e;
        };
        uploaded = st.size;
    }
    if (!res.ok()) return fail(c, res);
    const tmp = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch break :blk null;
        break :blk dataString(parsed.value, "file_path");
    } orelse {
        try c.out.print("上传响应缺少 file_path: {s}\n", .{res.body});
        return error.NoFilePath;
    };

    const mv = if (need_overwrite)
        try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\",\"overwrite\":true}}", .{
            try util.jsonEscape(c.arena, tmp), try util.jsonEscape(c.arena, remote),
        })
    else
        try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, tmp), try util.jsonEscape(c.arena, remote),
        });
    const buf2 = try c.arena.alloc(u8, BUF);
    const mres = try httpc.postJson(c.client, try c.url("/v2/fs/move"), try jsonAuth(c), mv, buf2);
    if (!mres.ok()) {
        // move 失败时清理临时文件，避免残留
        const cleanup = try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, tmp),
        });
        const buf3 = try c.arena.alloc(u8, BUF);
        _ = httpc.postJson(c.client, try c.url("/v2/fs/delete"), try jsonAuth(c), cleanup, buf3) catch {};
        return fail(c, mres);
    }
    try c.out.print("已上传 {s} -> {s}（{d} 字节）\n", .{ local, remote, uploaded });
}

/// fs-tree-put <本地 tar|-> <远端目录>：PUT /v2/fs/tree（只收未压缩 tar；gzip 自动先解压）。
fn cmdFsTreePut(c: *Ctx, a: util.Args) !void {
    const src = a.at(0) orelse return error.MissingArg;
    const remote = a.at(1) orelse return error.MissingArg;

    var raw: []const u8 = undefined;
    if (std.mem.eql(u8, src, "-")) {
        const buf = try c.arena.alloc(u8, 256 << 20);
        var rbuf: [8192]u8 = undefined;
        var r = std.Io.File.stdin().reader(c.io, &rbuf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = r.interface.readSliceShort(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        raw = buf[0..total];
    } else {
        raw = std.Io.Dir.cwd().readFileAlloc(c.io, src, c.arena, .limited(256 << 20)) catch |e| {
            try c.out.print("读取本地文件 {s} 失败: {t}\n", .{ src, e });
            return e;
        };
    }

    var payload = raw;
    if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) {
        payload = gunzip(c.arena, raw) catch |e| {
            try c.out.print("gzip 解压失败（{t}）\n提示：可先在本地解压：gunzip -c x.tgz | aiod-cli fs-tree-put - <远端目录>\n", .{e});
            return e;
        };
        std.debug.print("提示: 输入为 gzip，已在本地解压为原始 tar 再上传\n", .{});
    }

    const q = try queryPath(c, "/v2/fs/tree", remote, a.get("user"));
    const hs = try c.arena.alloc(std.http.Header, 3);
    var hn: usize = 0;
    hs[hn] = .{ .name = "Accept", .value = "application/json" };
    hn += 1;
    hs[hn] = .{ .name = "Content-Type", .value = "application/x-tar" };
    hn += 1;
    if (c.key) |k| {
        hs[hn] = .{ .name = "X-API-KEY", .value = k };
        hn += 1;
    }

    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.request(c.client, .PUT, try c.url(q), hs[0..hn], payload, buf);
    if (!res.ok()) return fail(c, res);
    if (a.has("json")) {
        try c.out.print("{s}\n", .{res.body});
        return;
    }
    try c.out.print("整树已上传 -> {s}\n{s}\n", .{ remote, res.body });
}

fn gunzip(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var in: std.Io.Reader = .fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&in, .gzip, &window);
    return try d.reader.readAllocShort(arena, 128 << 20);
}

// ---------------- tree（GET /v2/fs/tree 返回原始 tar，这里解析成条目树） ----------------

const TarEntry = struct { name: []const u8, is_dir: bool };

/// 读 ustar 八进制字段。
fn tarOctal(block: []const u8, off: usize, len: usize) u64 {
    var v: u64 = 0;
    var i = off;
    const end = off + len;
    while (i < end and (block[i] == ' ' or block[i] == 0)) i += 1;
    while (i < end) : (i += 1) {
        const ch = block[i];
        if (ch < '0' or ch > '7') break;
        v = v * 8 + (ch - '0');
    }
    return v;
}

/// 从 tar 字节流提取条目（跳过 pax/长名扩展头；数据区按 512 对齐跳过）。
fn tarEntries(arena: std.mem.Allocator, data: []const u8) ![]TarEntry {
    const maxn = data.len / 512 + 1;
    const out = try arena.alloc(TarEntry, maxn);
    var n: usize = 0;
    var pos: usize = 0;
    while (pos + 512 <= data.len) {
        const h = data[pos .. pos + 512];
        var allzero = true;
        for (h) |b| {
            if (b != 0) {
                allzero = false;
                break;
            }
        }
        if (allzero) break;
        var name: []const u8 = h[0..100];
        if (std.mem.indexOfScalar(u8, name, 0)) |z| name = name[0..z];
        var prefix: []const u8 = h[345..500];
        if (std.mem.indexOfScalar(u8, prefix, 0)) |z| prefix = prefix[0..z];
        const size = tarOctal(h, 124, 12);
        const tf = h[156];
        const is_dir = tf == '5' or std.mem.endsWith(u8, name, "/");
        // x/g = pax 扩展头，L/K = GNU 长名：跳过其数据，不当条目
        if (tf != 'x' and tf != 'g' and tf != 'L' and tf != 'K' and name.len > 0) {
            if (prefix.len > 0) {
                out[n] = .{ .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name }), .is_dir = is_dir };
            } else {
                out[n] = .{ .name = name, .is_dir = is_dir };
            }
            n += 1;
        }
        pos += 512 + ((size + 511) / 512) * 512;
    }
    return out[0..n];
}

/// tree [远端路径] [--user=] [--tar | --out=<本地文件>]
/// 默认把服务端返回的 tar 解析成条目树打印；--tar 输出原始字节；--out= 存成本地 tar。
fn cmdTree(c: *Ctx, a: util.Args) !void {
    const path = a.at(0) orelse "/";
    const buf = try c.arena.alloc(u8, BUF);
    const q = try queryPath(c, "/v2/fs/tree", path, a.get("user"));
    const res = try httpc.get(c.client, try c.url(q), try auth(c), buf);
    if (!res.ok()) return fail(c, res);

    if (a.has("tar")) {
        try c.out.writeAll(res.body); // 原始 tar 字节，不加修饰
        return;
    }
    if (a.get("out")) |out_path| {
        const f = try std.Io.Dir.cwd().createFile(c.io, out_path, .{});
        defer f.close(c.io);
        var wbuf: [8192]u8 = undefined;
        var fw = f.writer(c.io, &wbuf);
        try fw.interface.writeAll(res.body);
        try fw.interface.flush();
        try c.out.print("saved {d} bytes -> {s}\n", .{ res.body.len, out_path });
        return;
    }

    var entries = try tarEntries(c.arena, res.body);
    // 插入排序（按路径名）
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const cur = entries[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, entries[j - 1].name, cur.name) == .gt) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = cur;
    }
    const pad = "                                        "; // 40 空格
    var prev: []const u8 = "";
    for (entries) |e| {
        var nm = e.name;
        if (std.mem.endsWith(u8, nm, "/")) nm = nm[0 .. nm.len - 1];
        if (std.mem.eql(u8, nm, prev)) continue; // 同路径去重
        prev = nm;
        var depth: usize = 0;
        for (nm) |ch| {
            if (ch == '/') depth += 1;
        }
        const base = if (std.mem.lastIndexOfScalar(u8, nm, '/')) |k| nm[k + 1 ..] else nm;
        const width = @min(depth * 2, pad.len);
        try c.out.writeAll(pad[0..width]);
        try c.out.print("{s}{s}\n", .{ base, if (e.is_dir) "/" else "" });
    }
}

// ---------------- 鉴权 ----------------

fn auth(c: *Ctx) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 2);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
}

fn jsonAuth(c: *Ctx) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 3);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    hs[n] = httpc.json_ct;
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "cat") or eq(cmd, "read")) {
        try cmdCat(c, a);
        return true;
    }
    if (eq(cmd, "write")) {
        try cmdWrite(c, a);
        return true;
    }
    if (eq(cmd, "get")) {
        try cmdGet(c, a);
        return true;
    }
    if (eq(cmd, "put")) {
        try cmdPut(c, a);
        return true;
    }
    if (eq(cmd, "fs-tree-put")) {
        try cmdFsTreePut(c, a);
        return true;
    }
    if (eq(cmd, "ls")) {
        const path = a.at(0) orelse "/";
        // 透传 recursive / show_hidden / max_depth（旧版静默忽略）
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 1024));
        try w.print("/v2/fs/list?path={s}", .{try urlEncode(c.arena, path)});
        if (a.get("user")) |u| try w.print("&user={s}", .{try urlEncode(c.arena, u)});
        if (a.has("recursive")) try w.print("&recursive=true", .{});
        if (a.has("hidden")) try w.print("&show_hidden=true", .{});
        if (a.get("depth")) |d| try w.print("&max_depth={s}", .{d});
        try getJSON(c, w.buffered());
        return true;
    }
    if (eq(cmd, "stat")) {
        const path = a.at(0) orelse return error.MissingArg;
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 1024));
        try w.print("/v2/fs/stat?path={s}", .{try urlEncode(c.arena, path)});
        if (a.get("user")) |u| try w.print("&user={s}", .{try urlEncode(c.arena, u)});
        if (a.has("follow-symlinks")) try w.print("&follow_symlinks=true", .{});
        try getJSON(c, w.buffered());
        return true;
    }
    // tree：解析 tar 输出版
    if (eq(cmd, "tree")) {
        try cmdTree(c, a);
        return true;
    }
    if (eq(cmd, "mkdir")) {
        try cmdMkdir(c, a);
        return true;
    }
    if (eq(cmd, "rm")) {
        try cmdRm(c, a);
        return true;
    }
    if (eq(cmd, "mv") or eq(cmd, "cp")) {
        try copyMove(c, cmd, a);
        return true;
    }
    if (eq(cmd, "edit")) {
        try cmdEdit(c, a);
        return true;
    }
    if (eq(cmd, "grep")) {
        try cmdGrep(c, a);
        return true;
    }
    if (eq(cmd, "search")) {
        try cmdSearch(c, a);
        return true;
    }
    return false;
}
