//! HTTP 核心：所有请求走 std.http.Client。
//!
//! 约定：响应体写入调用方提供的 buf（建议 ≥ 2 MiB）；需要更大响应时显式传入更大缓冲。
const std = @import("std");

pub const Headers = []const std.http.Header;
pub const Method = std.http.Method;

pub const Response = struct {
    status: u16,
    body: []const u8,
    /// 响应头副本（响应体读完、连接复用之后依然有效；见 captureHeaders）。
    headers: Headers = &.{},

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// 取响应头（大小写不敏感）。
    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// 取响应头并按整数解析（如 Retry-After）。
    pub fn headerInt(self: Response, name: []const u8) ?i64 {
        const v = self.header(name) orelse return null;
        return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t"), 10) catch null;
    }
};

/// 复制并解析响应头。
///
/// std.http 的 Response.Head 不保留解析后的头表，只留原始字节 `.bytes`；
/// 而这些字节指向连接读缓冲，一旦开始读 body 就被覆盖 —— 所以必须先复制一份。
/// 复制品由 smp_allocator 持有，进程生命周期内一直有效（CLI 是短进程，不回收）。
fn captureHeaders(head_bytes: []const u8) Headers {
    const gpa = std.heap.smp_allocator;
    const copy = gpa.dupe(u8, head_bytes) catch return &.{};
    var list: std.ArrayList(std.http.Header) = .empty;
    defer list.deinit(gpa);
    var it = std.mem.splitSequence(u8, copy, "\r\n");
    _ = it.first(); // 状态行
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..i], " \t");
        const value = std.mem.trim(u8, line[i + 1 ..], " \t");
        if (name.len == 0) continue;
        list.append(gpa, .{ .name = name, .value = value }) catch return &.{};
    }
    return list.toOwnedSlice(gpa) catch &.{};
}

pub fn request(
    client: *std.http.Client,
    method: Method,
    url: []const u8,
    headers: Headers,
    payload: ?[]const u8,
    buf: []u8,
) !Response {
    return requestStopAt(client, method, url, headers, payload, buf, null);
}

/// 与 request 相同，但响应体读到**第一次出现 needle** 即停止（不等待 EOF）。
///
/// 用于「启动后立即分离」：envd 的 Start 流会一直开到进程结束，
/// 而我们只想读到首个 `"pid"` 就断开（进程会在沙箱里继续跑）。
pub fn requestStopAt(
    client: *std.http.Client,
    method: Method,
    url: []const u8,
    headers: Headers,
    payload: ?[]const u8,
    buf: []u8,
    needle: ?[]const u8,
) !Response {
    // 低层流程（不用 fetch）：fetch 对 PUT+204 这类"无 body 响应"会在
    // streamRemaining 里等待永远不会到来的 EOF（连接 keep-alive 不关），实测挂死。
    // 这里改用 request → send → receiveHead → 手动读 body，并对 204/304 特判。
    const uri = try std.Uri.parse(url);
    var req = try std.http.Client.request(client, method, uri, .{
        .extra_headers = headers,
        .keep_alive = false,
    });
    req.headers.accept_encoding = .omit; // 不发送 Accept-Encoding（避免压缩；如服务器仍压缩则下方兜底解压）
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(p);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var response = try req.receiveHead(&.{});
    const status: u16 = @intFromEnum(response.head.status);
    // 先抓住响应头（body 一旦开始读，head.bytes 指向的缓冲就被覆盖）
    const resp_headers = captureHeaders(response.head.bytes);
    // 204/304/HEAD 无 body：直接返回（绝不读流）
    if (status == 204 or status == 304 or method == .HEAD) {
        return .{ .status = status, .body = "", .headers = resp_headers };
    }

    var tb: [4096]u8 = undefined;
    const r = response.reader(&tb);
    var got: usize = 0;
    var zero_streak: usize = 0;
    const want: ?u64 = response.head.content_length;
    while (got < buf.len) {
        if (want) |wl| {
            const wu: usize = std.math.cast(usize, wl) orelse std.math.maxInt(usize);
            if (got >= wu) break;
        }
        var iov = [1][]u8{buf[got..]};
        const n = r.readVec(&iov) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) {
            // 0 字节不代表 EOF；连读 3 次空转即放弃（防御无 content-length 的异常流）
            zero_streak += 1;
            if (zero_streak >= 64) break;
            continue;
        }
        zero_streak = 0;
        got += n;
        if (needle) |nd| {
            if (std.mem.indexOf(u8, buf[0..got], nd) != null) break;
        }
    }
    // 兜底：服务器无视"未请求压缩"仍返回压缩体时手动解压
    if (response.head.content_encoding != .identity) {
        const dec = try decompressBody(buf[0..got], response.head.content_encoding);
        return .{ .status = status, .body = dec, .headers = resp_headers };
    }
    return .{ .status = status, .body = buf[0..got], .headers = resp_headers };
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

pub fn get(client: *std.http.Client, url: []const u8, headers: Headers, buf: []u8) !Response {
    return request(client, .GET, url, headers, null, buf);
}

pub fn del(client: *std.http.Client, url: []const u8, headers: Headers, buf: []u8) !Response {
    return request(client, .DELETE, url, headers, null, buf);
}

/// POST JSON：headers 需含 Content-Type: application/json
pub fn postJson(client: *std.http.Client, url: []const u8, headers: Headers, json: []const u8, buf: []u8) !Response {
    return request(client, .POST, url, headers, json, buf);
}

/// PATCH JSON（上游 PATCH /templates/{id} 直接 501，这里只保证协议层能发出去）。
pub fn patchJson(client: *std.http.Client, url: []const u8, headers: Headers, json: []const u8, buf: []u8) !Response {
    return request(client, .PATCH, url, headers, json, buf);
}

pub const json_ct = std.http.Header{ .name = "Content-Type", .value = "application/json" };
