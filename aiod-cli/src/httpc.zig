//! HTTP 核心：所有请求走 std.http.Client。
//!
//! 约定：JSON 类响应写入调用方提供的 buf（建议 ≥ 2 MiB）。
//! **二进制/大响应不要走这里**：request 是「收进 buf」语义，buf 满即停，
//! 超出部分静默丢弃（这正是历史上 aiod-cli get 8 MiB 截断的根源）。
//! 需要流式落盘的场景用 streamToFile（get 命令在用）。
const std = @import("std");

pub const Headers = []const std.http.Header;
pub const Method = std.http.Method;

pub const Response = struct {
    status: u16,
    body: []const u8,
    /// `content-range` 响应头原文（Range 分块下载用；无则为空串）
    content_range: []const u8 = "",

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub fn request(
    client: *std.http.Client,
    method: Method,
    url: []const u8,
    headers: Headers,
    payload: ?[]const u8,
    buf: []u8,
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
    // 204/304 无 body：直接返回（绝不读流）
    if (status == 204 or status == 304) {
        return .{ .status = status, .body = "", .content_range = "" };
    }

    // content-range 原文（小写头名；std.http 已规范化）。
    // 注意：h.value 指向连接读缓冲，req.deinit 后即释放，不能直接存进 Response
    // （调用方在请求返回后才读它，悬垂指针 = 网关链路稳定段错误，见 issue #1）。
    // 复制到 smp_allocator（短进程不回收；与 cube-cli captureHeaders 同策略）。
    var cr: []const u8 = "";
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-range")) {
            cr = std.heap.smp_allocator.dupe(u8, h.value) catch "";
            break;
        }
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
    }
    // 兜底：服务器无视"未请求压缩"仍返回压缩体时手动解压
    if (response.head.content_encoding != .identity) {
        const dec = try decompressBody(buf[0..got], response.head.content_encoding);
        return .{ .status = status, .body = dec, .content_range = cr };
    }
    return .{ .status = status, .body = buf[0..got], .content_range = cr };
}

/// 流式下载：把响应体直接写进文件，不经固定缓冲（大文件唯一正确姿势）。
/// 返回实际写入字节数；status 非 2xx 时同样返回（由调用方决定是否中断）。
pub const StreamResult = struct { status: u16, bytes: u64 };

/// 流式落盘：把响应体直接写进已打开的文件，不经固定缓冲（大文件唯一正确姿势）。
/// 返回状态码与实际写入字节数；文件位置由调用方维护（本函数只追加）。
pub fn streamToFile(
    client: *std.http.Client,
    io: std.Io,
    method: Method,
    url: []const u8,
    headers: Headers,
    payload: ?[]const u8,
    f: std.Io.File,
) !StreamResult {
    const uri = try std.Uri.parse(url);
    var req = try std.http.Client.request(client, method, uri, .{
        .extra_headers = headers,
        .keep_alive = false,
    });
    req.headers.accept_encoding = .omit;
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
    if (status == 204 or status == 304) return .{ .status = status, .bytes = 0 };

    var tb: [4096]u8 = undefined;
    var rbuf: [64 << 10]u8 = undefined;
    const r = response.reader(&rbuf);
    var wbuf: [64 << 10]u8 = undefined;
    // 必须用 streaming 写：positional 模式每次新 writer 都从 offset 0 覆盖，
    // 会导致分块下载时「后一段覆盖前一段」。streaming 走 fd 当前位置，可累加。
    var fw = f.writerStreaming(io, &wbuf);
    var total: u64 = 0;
    var zero_streak: usize = 0;
    while (true) {
        var iov = [1][]u8{&tb};
        const n = r.readVec(&iov) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) {
            // 0 字节不代表 EOF；连续空转若干次才放弃（与 request 同策略）
            zero_streak += 1;
            if (zero_streak >= 64) break;
            continue;
        }
        zero_streak = 0;
        try fw.interface.writeAll(tb[0..n]);
        total += n;
    }
    try fw.interface.flush();
    return .{ .status = status, .bytes = total };
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

/// 流式 multipart 上传（支持文件范围）：把 [offset, offset+length) 的内容
/// 「边读边发」，不整体进内存 → 单段大小无客户端上限。
///
/// 历史包袱：旧 put 用 readFileAlloc(.limited(64 MiB)) 把整个文件读进内存，
/// 超过 64 MiB 直接 error.StreamTooLong；再大（~200 MiB）单连接传输还会
/// WriteFailed —— 这就是「大文件必须分块」的两个根因。
///
/// headers 需已含 `Content-Type: multipart/form-data; boundary=<boundary>`。
pub fn uploadFileMultipartRange(
    client: *std.http.Client,
    io: std.Io,
    url: []const u8,
    headers: Headers,
    boundary: []const u8,
    field_name: []const u8,
    filename: []const u8,
    file_path: []const u8,
    offset: u64,
    length: u64,
    buf: []u8,
) !Response {
    const uri = try std.Uri.parse(url);

    var head_buf: [1024]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, field_name, filename });
    var foot_buf: [128]u8 = undefined;
    const foot = try std.fmt.bufPrint(&foot_buf, "\r\n--{s}--\r\n", .{boundary});
    const total_len: u64 = head.len + length + foot.len;

    var req = try std.http.Client.request(client, .POST, uri, .{
        .extra_headers = headers,
        .keep_alive = false,
    });
    req.headers.accept_encoding = .omit;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = total_len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(head);

    const f = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer f.close(io);
    var chunk: [64 << 10]u8 = undefined;
    var pos: u64 = offset;
    var remaining: u64 = length;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, chunk.len));
        var iov = [1][]u8{chunk[0..want]};
        const n = f.readPositional(io, &iov, pos) catch break;
        if (n == 0) break;
        try body.writer.writeAll(chunk[0..n]);
        pos += n;
        remaining -= n;
    }
    if (remaining != 0) {
        return error.FileChangedDuringUpload;
    }
    try body.writer.writeAll(foot);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    const status: u16 = @intFromEnum(response.head.status);
    if (status == 204 or status == 304) return .{ .status = status, .body = "" };

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
            zero_streak += 1;
            if (zero_streak >= 64) break;
            continue;
        }
        zero_streak = 0;
        got += n;
    }
    return .{ .status = status, .body = buf[0..got] };
}

/// 兼容旧签名：整文件上传。
pub fn uploadFileMultipart(
    client: *std.http.Client,
    io: std.Io,
    url: []const u8,
    headers: Headers,
    boundary: []const u8,
    field_name: []const u8,
    filename: []const u8,
    file_path: []const u8,
    file_size: u64,
    buf: []u8,
) !Response {
    return uploadFileMultipartRange(client, io, url, headers, boundary, field_name, filename, file_path, 0, file_size, buf);
}

/// POST JSON：headers 需含 Content-Type: application/json
pub fn postJson(client: *std.http.Client, url: []const u8, headers: Headers, json: []const u8, buf: []u8) !Response {
    return request(client, .POST, url, headers, json, buf);
}

pub const json_ct = std.http.Header{ .name = "Content-Type", .value = "application/json" };
