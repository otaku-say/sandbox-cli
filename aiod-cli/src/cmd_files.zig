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

fn cmdGet(c: *Ctx, a: util.Args) !void {
    const remote = a.at(0) orelse return error.MissingArg;
    const local = a.at(1) orelse return error.MissingArg;
    const buf = try c.arena.alloc(u8, BUF);
    const q = try queryPath(c, "/v2/fs/download", remote, a.get("user"));
    const res = try httpc.get(c.client, try c.url(q), try auth(c), buf);
    if (!res.ok()) return fail(c, res);
    const dir = std.Io.Dir.cwd();
    const f = try dir.createFile(c.io, local, .{});
    defer f.close(c.io);
    var wbuf: [8192]u8 = undefined;
    var w = f.writer(c.io, &wbuf);
    try w.interface.writeAll(res.body);
    try w.interface.flush();
    try c.out.print("saved {d} bytes -> {s}\n", .{ res.body.len, local });
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
fn cmdPut(c: *Ctx, a: util.Args) !void {
    const local = a.at(0) orelse return error.MissingArg;
    const remote = a.at(1) orelse return error.MissingArg;

    var data: []const u8 = undefined;
    if (std.mem.eql(u8, local, "-")) {
        const buf = try c.arena.alloc(u8, 64 << 20);
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
        data = std.Io.Dir.cwd().readFileAlloc(c.io, local, c.arena, .limited(64 << 20)) catch |e| {
            try c.out.print("读取本地文件 {s} 失败: {t}\n", .{ local, e });
            return e;
        };
    }

    var fname: []const u8 = local;
    if (std.mem.lastIndexOfScalar(u8, local, '/')) |i| fname = local[i + 1 ..];
    if (std.mem.eql(u8, fname, "-")) fname = "stdin.bin";

    const boundary = "ZigAioCliBoundary7f3a9c";
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, data.len + 4096));
    try w.print("--{s}\r\n", .{boundary});
    try w.print("Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n", .{fname});
    try w.print("Content-Type: application/octet-stream\r\n\r\n", .{});
    try w.writeAll(data);
    try w.print("\r\n--{s}--\r\n", .{boundary});

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
    const res = try httpc.request(c.client, .POST, try c.url("/v2/fs/upload"), hs[0..hn], w.buffered(), buf);
    if (!res.ok()) return fail(c, res);
    const tmp = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, c.arena, res.body, .{}) catch break :blk null;
        break :blk dataString(parsed.value, "file_path");
    } orelse {
        try c.out.print("上传响应缺少 file_path: {s}\n", .{res.body});
        return error.NoFilePath;
    };

    const mv = if (a.has("overwrite"))
        try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\",\"overwrite\":true}}", .{
            try util.jsonEscape(c.arena, tmp), try util.jsonEscape(c.arena, remote),
        })
    else
        try std.fmt.allocPrint(c.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{
            try util.jsonEscape(c.arena, tmp), try util.jsonEscape(c.arena, remote),
        });
    const buf2 = try c.arena.alloc(u8, BUF);
    const mres = try httpc.postJson(c.client, try c.url("/v2/fs/move"), try jsonAuth(c), mv, buf2);
    if (!mres.ok()) return fail(c, mres);
    try c.out.print("已上传 {s} -> {s}（{d} 字节）\n", .{ local, remote, data.len });
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
