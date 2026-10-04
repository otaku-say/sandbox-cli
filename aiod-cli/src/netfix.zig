//! netfix.zig —— 让 Zig 标准库的 DNS 解析容忍「不可达的 nameserver」。
//!
//! 现象
//!   某些环境的 /etc/resolv.conf 会把链路本地地址（fe80::/10）排在最前面，
//!   例如 iSH for iOS。musl libc 会自动跳过这类不可达的服务器，Zig 标准库的
//!   解析器不会：它拿第一个 nameserver 直接用，报文发不出去就整个查询以
//!   error.NameServerFailure 收场，而且每次都要空耗数秒超时。结果是内部网络
//!   完全正常的机器上，CLI 却连一个域名都解析不出来。
//!
//! 做法（纯 Zig，不依赖 libc）
//!   1. 读 /etc/resolv.conf，识别出指向 fe80::/10 的 nameserver 行；
//!   2. 把这些行剔除后写成一份临时副本 /tmp/.clidns-resolv.conf；
//!   3. 包装 std.Io，做两件事：
//!      a. dirOpenFile —— 把对 "/etc/resolv.conf" 的打开改写到副本；这样标准库
//!         公开的 HostName.ResolvConf.init(io) 读到的就是干净配置；
//!      b. netLookup —— 接管域名解析：/etc/hosts → localhost → DNS 查询，
//!         查询用的 nameserver 列表来自上面那份干净配置。
//!
//!   为什么必须同时接管 netLookup：Io.Threaded 的 netLookup 内部用的是**它自己
//!   的 io**（`t.io()`）而不是调用方传入的那个，单靠文件层改写会被绕过
//!   （strace 实测：它仍然打开真实文件）。
//!
//!   只有检测到「不可达 nameserver」时才安装 hook；正常环境完全不干预。
//!
//! 用法
//!   const io = netfix.install(gpa, threaded.io());

const std = @import("std");
const Io = std.Io;
const HostName = Io.net.HostName;
const IpAddress = Io.net.IpAddress;
const net = Io.net;

/// 过滤后的配置副本路径。内容只取决于 /etc/resolv.conf 与过滤规则，是确定性的。
const tmp_path = "/tmp/.clidns-resolv.conf";
const max_file_bytes = 1 << 20;

/// 原始（未包装）Io。CLI 进程只在启动时包装一次，单份全局状态足够。
var g_base: Io = undefined;
var g_vtable: Io.VTable = undefined;
var g_installed = false;
/// hook 被标准库实际调用的次数（可观测性 / 测试用）。
var g_hook_calls: u64 = 0;

/// 返回一个可用于网络请求的 Io。无法处理或无需处理时，原样返回 `base`。
pub fn install(gpa: std.mem.Allocator, base: Io) Io {
    return installFrom(gpa, base, "/etc/resolv.conf");
}

/// 与 `install` 相同，但可指定「配置文件来源路径」（测试用）。
pub fn installFrom(gpa: std.mem.Allocator, base: Io, src_path: []const u8) Io {
    if (g_installed) return base; // 幂等：重复调用不叠加包装

    const src = readAll(gpa, base, src_path) catch return base;
    defer gpa.free(src);

    const patched = (filterUnreachable(gpa, src) catch return base) orelse return base;
    defer gpa.free(patched);

    writeAll(base, tmp_path, patched) catch return base;

    g_base = base;
    g_vtable = base.vtable.*; // 复制整张 vtable，覆盖两个入口
    g_vtable.dirOpenFile = hookOpenFile;
    g_vtable.netLookup = hookNetLookup;
    g_installed = true;

    // 关键：`Io.userdata` 是底层实现的私有数据（原实现指向 Threaded 实例），
    // 包装层必须原样透传 —— 换成自己的结构体会让其余 vtable 函数解引用错位
    // （实测直接段错误）。本模块自身状态放在全局变量里。
    return .{ .userdata = base.userdata, .vtable = &g_vtable };
}

/// hook 被调用的次数：> 0 说明注入确实生效了。
pub fn hookCalls() u64 {
    return @atomicLoad(u64, &g_hook_calls, .monotonic);
}

/// 过滤后的副本路径（测试用）。
pub fn tmpPath() []const u8 {
    return tmp_path;
}

// ---------------------------------------------------------------- 过滤逻辑

/// 逐行检查配置，丢弃指向链路本地地址的 nameserver 行。
/// 没有任何可丢弃的行时返回 null（调用方据此跳过包装）。
fn filterUnreachable(gpa: std.mem.Allocator, src: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (isUnreachableNameserver(line)) {
            changed = true;
            continue;
        }
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }

    if (!changed) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// 该行是否为「不可达的 nameserver」声明。
fn isUnreachableNameserver(line: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = it.next() orelse return false;
    if (!std.mem.eql(u8, keyword, "nameserver")) return false;
    const addr_text = it.next() orelse return false;
    return isLinkLocalV6(addr_text);
}

/// 是否为 IPv6 链路本地地址（fe80::/10）。去掉 `%zone` 后缀（RFC 4007）后
/// 比较前三个十六进制字符：fe80…febf。没有作用域的链路本地地址无法作为
/// nameserver 使用（libc 同样会跳过）。
fn isLinkLocalV6(text: []const u8) bool {
    const bare = if (std.mem.indexOfScalar(u8, text, '%')) |i| text[0..i] else text;
    if (bare.len < 4) return false;
    if (std.mem.indexOfScalar(u8, bare, ':') == null) return false; // 不是 IPv6
    const a = std.ascii.toLower(bare[0]);
    const b = std.ascii.toLower(bare[1]);
    const c = std.ascii.toLower(bare[2]);
    return a == 'f' and b == 'e' and c >= '8' and c <= 'b';
}

// ------------------------------------------------------------ vtable 挂钩

/// 把对 "/etc/resolv.conf" 的打开改写到过滤后的副本。
fn hookOpenFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.OpenFileOptions,
) Io.File.OpenError!Io.File {
    _ = userdata; // 必须忽略：调用底层实现时要传它自己的 userdata
    const path = if (std.mem.eql(u8, sub_path, "/etc/resolv.conf")) tmp_path else sub_path;
    return g_base.vtable.dirOpenFile(g_base.userdata, dir, path, options);
}

/// 接管域名解析。
fn hookNetLookup(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    _ = userdata;
    _ = @atomicRmw(u64, &g_hook_calls, .Add, 1, .monotonic);
    return resolve(g_base, host_name, resolved, options);
}

// ---------------------------------------------------------------- 解析流程

fn resolve(
    io: Io,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    // RFC 6761 §6.3.3：localhost 及其子域直接给出回环地址
    if (isLocalhost(host_name.bytes)) return localhostResult(io, resolved, options);

    // /etc/hosts 优先（标准库同样如此）
    if (hostsLookup(io, host_name, resolved, options) catch |err| switch (err) {
        error.UnknownHostName => false,
        else => |e| return e,
    }) return;

    return dnsLookup(io, host_name, resolved, options);
}

fn isLocalhost(name: []const u8) bool {
    const base = if (std.mem.endsWith(u8, name, ".")) "localhost." else "localhost";
    if (!std.mem.endsWith(u8, name, base)) return false;
    return name.len == base.len or name[name.len - base.len - 1] == '.';
}

fn localhostResult(
    io: Io,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    defer resolved.close(io);
    if (options.family != .ip4) try put(io, resolved, .{ .address = .{ .ip6 = .loopback(options.port) } });
    if (options.family != .ip6) try put(io, resolved, .{ .address = .{ .ip4 = .loopback(options.port) } });
    if (options.canonical_name_buffer) |buf| {
        @memcpy(buf[0.."localhost".len], "localhost");
        try put(io, resolved, .{ .canonical_name = .{ .bytes = buf[0.."localhost".len] } });
    }
}

/// 读 /etc/hosts。返回 true 表示命中；未命中时返回 error.UnknownHostName。
fn hostsLookup(
    io: Io,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!bool {
    const file = Io.Dir.openFileAbsolute(io, "/etc/hosts", .{}) catch return false;
    defer file.close(io);

    var line_buf: [512]u8 = undefined;
    var file_reader = file.reader(io, &line_buf);
    const reader = &file_reader.interface;

    var addresses: usize = 0;
    var canonical: ?HostName = null;
    var pending: [64]IpAddress = undefined;

    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch {};
                continue;
            },
            error.ReadFailed => return error.DetectingNetworkConfigurationFailed,
            error.EndOfStream => break,
        };
        reader.toss(@min(1, reader.bufferedLen()));
        var split = std.mem.splitScalar(u8, line, '#');
        const body = split.first();
        var it = std.mem.tokenizeAny(u8, body, " \t\r");
        const ip_text = it.next() orelse continue;
        var first_name: ?[]const u8 = null;
        while (it.next()) |name_text| {
            if (std.ascii.eqlIgnoreCase(name_text, host_name.bytes)) {
                if (first_name == null) first_name = name_text;
                break;
            }
        } else continue;

        const addr = IpAddress.parse(ip_text, options.port) catch continue;
        if (options.family) |f| {
            if (std.meta.activeTag(addr) != f) continue;
        }
        if (addresses >= pending.len) continue;
        pending[addresses] = addr;
        addresses += 1;

        if (canonical == null) {
            if (options.canonical_name_buffer) |buf| {
                if (HostName.init(first_name.?)) |n| {
                    if (n.bytes.len <= buf.len) {
                        @memcpy(buf[0..n.bytes.len], n.bytes);
                        canonical = .{ .bytes = buf[0..n.bytes.len] };
                    }
                } else |_| {}
            }
        }
    }

    if (addresses == 0) return error.UnknownHostName;

    defer resolved.close(io);
    for (pending[0..addresses]) |addr| try put(io, resolved, .{ .address = addr });
    if (options.canonical_name_buffer != null) {
        try put(io, resolved, .{ .canonical_name = canonical orelse host_name });
    }
    return true;
}

/// 用（已经过滤过的）resolv.conf 做 DNS 查询。
fn dnsLookup(
    io: Io,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    defer resolved.close(io);

    // 这里读到的就是过滤后的副本（hookOpenFile 已把 /etc/resolv.conf 改写过去）
    const rc = HostName.ResolvConf.init(io) catch return error.ResolvConfParseFailed;
    const nameservers = rc.nameservers();
    if (nameservers.len == 0) return error.NameServerFailure;

    // 规范化查询名：去掉末尾点；按 ndots 规则决定是否追加 search 域
    var canon = host_name.bytes;
    if (std.mem.endsWith(u8, canon, ".")) canon.len -= 1;
    if (std.mem.endsWith(u8, canon, ".")) return error.UnknownHostName;

    var name_buf: [HostName.max_len]u8 = undefined;
    const dots = std.mem.countScalar(u8, canon, '.');
    const use_search = dots < rc.ndots and rc.search_len != 0;

    var search_it = std.mem.tokenizeAny(u8, rc.search_buffer[0..rc.search_len], " \t");
    const first_name: []const u8 = if (use_search) blk: {
        const token = search_it.next() orelse canon;
        @memcpy(name_buf[0..canon.len], canon);
        name_buf[canon.len] = '.';
        @memcpy(name_buf[canon.len + 1 ..][0..token.len], token);
        break :blk name_buf[0 .. canon.len + 1 + token.len];
    } else canon;

    var addresses_len: usize = 0;
    var canonical: ?HostName = null;
    try queryOnce(io, &rc, first_name, options, resolved, &addresses_len, &canonical);
    if (addresses_len == 0 and use_search) {
        // search 域未命中，回退到原始名字
        try queryOnce(io, &rc, canon, options, resolved, &addresses_len, &canonical);
    }

    if (options.canonical_name_buffer != null) {
        try put(io, resolved, .{ .canonical_name = canonical orelse .{ .bytes = canon } });
    }
    if (addresses_len == 0) return error.NoAddressReturned;
}

/// 一轮查询：向所有 nameserver 依次尝试 A / AAAA。
fn queryOnce(
    io: Io,
    rc: *const HostName.ResolvConf,
    lookup_name: []const u8,
    options: HostName.LookupOptions,
    resolved: *Io.Queue(HostName.LookupResult),
    addresses_len: *usize,
    canonical: *?HostName,
) HostName.LookupError!void {
    // 构造待发查询：调用方没限定地址族时，A 与 AAAA 都要问
    const family_records: [2]struct { af: IpAddress.Family, rr: HostName.DnsRecord } = .{
        .{ .af = .ip6, .rr = .A },
        .{ .af = .ip4, .rr = .AAAA },
    };
    var query_bufs: [2][280]u8 = undefined;
    var queries: [2][]const u8 = undefined;
    var nq: usize = 0;
    for (family_records) |fr| {
        if (options.family != fr.af) {
            var entropy: [2]u8 = undefined;
            Io.random(io, &entropy);
            const len = writeResolutionQuery(&query_bufs[nq], lookup_name, fr.rr, entropy);
            queries[nq] = query_bufs[nq][0..len];
            nq += 1;
        }
    }
    if (nq == 0) return;

    // nameserver 可能同时有 v4/v6：有 v6 时开双栈套接字，v4 目标映射成 v4-mapped
    var mapped: [HostName.ResolvConf.max_nameservers]IpAddress = undefined;
    var any_ip6 = false;
    for (rc.nameservers(), mapped[0..rc.nameservers_len]) |*ns, *m| {
        m.* = .{ .ip6 = .fromAny(ns.*) };
        any_ip6 = any_ip6 or ns.* == .ip6;
    }

    var v4_buf: [HostName.ResolvConf.max_nameservers]IpAddress = undefined;
    var socket: net.Socket = undefined;
    var targets: []const IpAddress = rc.nameservers();
    if (any_ip6) {
        const any6: IpAddress = .{ .ip6 = .unspecified(0) };
        if (any6.bind(io, .{ .ip6_only = false, .mode = .dgram })) |s| {
            socket = s;
            targets = mapped[0..rc.nameservers_len];
        } else |_| {
            const any4: IpAddress = .{ .ip4 = .unspecified(0) };
            socket = try any4.bind(io, .{ .mode = .dgram });
            targets = ip4ToBuf(rc.nameservers(), &v4_buf);
        }
    } else {
        const any4: IpAddress = .{ .ip4 = .unspecified(0) };
        socket = try any4.bind(io, .{ .mode = .dgram });
    }
    defer socket.close(io);

    const clock: Io.Clock = .boot;
    const timeout_secs: u32 = if (rc.timeout_seconds == 0) 5 else rc.timeout_seconds;

    var answers_buf: [2 * 512]u8 = undefined;
    var answers: [2][]u8 = undefined;
    var got: [2]bool = .{ false, false };
    var answer_off: usize = 0;

    for (targets) |*ns| {
        var all_got = true;
        for (got[0..nq]) |g| {
            if (!g) all_got = false;
        }
        if (all_got) break;

        for (queries[0..nq]) |q| {
            const deadline = clock.now(io).addDuration(.fromSeconds(timeout_secs));
            socket.sendTimeout(io, ns, q, .{ .deadline = .{ .raw = deadline, .clock = clock } }) catch continue;
        }

        var waits: usize = 0;
        while (waits < nq) : (waits += 1) {
            const deadline = clock.now(io).addDuration(.fromSeconds(timeout_secs));
            const msg = socket.receiveTimeout(io, answers_buf[answer_off..], .{
                .deadline = .{ .raw = deadline, .clock = clock },
            }) catch break;
            const reply = msg.data;
            if (reply.len < 4) continue;

            const qi = for (queries[0..nq], 0..) |q, i| {
                if (reply[0] == q[0] and reply[1] == q[1]) break i;
            } else continue;
            if (got[qi]) continue;

            switch (reply[3] & 15) {
                0, 3 => { // NOERROR / NXDOMAIN 都是有效应答
                    answers[qi] = reply;
                    got[qi] = true;
                    answer_off += reply.len;
                },
                else => continue,
            }
        }
    }

    for (answers[0..nq], got[0..nq]) |answer, ok| {
        if (!ok) continue;
        var it = HostName.DnsResponse.init(answer) catch continue;
        while (it.next() catch continue) |record| switch (record.rr) {
            .A => {
                const data = record.packet[record.data_off..][0..record.data_len];
                if (data.len != 4) return error.InvalidDnsARecord;
                try put(io, resolved, .{ .address = .{ .ip4 = .{
                    .bytes = data[0..4].*,
                    .port = options.port,
                } } });
                addresses_len.* += 1;
            },
            .AAAA => {
                const data = record.packet[record.data_off..][0..record.data_len];
                if (data.len != 16) return error.InvalidDnsAAAARecord;
                try put(io, resolved, .{ .address = .{ .ip6 = .{
                    .port = options.port,
                    .bytes = data[0..16].*,
                } } });
                addresses_len.* += 1;
            },
            .CNAME => {
                if (options.canonical_name_buffer) |buf| {
                    const expanded = HostName.expand(record.packet, record.data_off, buf) catch
                        return error.InvalidDnsCnameRecord;
                    canonical.* = expanded[1];
                }
            },
            _ => continue,
        };
    }
}

/// 把列表中的 IPv4 项筛进调用方提供的缓冲（保持顺序）。
fn ip4ToBuf(
    list: []const IpAddress,
    buf: *[HostName.ResolvConf.max_nameservers]IpAddress,
) []const IpAddress {
    var n: usize = 0;
    for (list) |a| {
        if (a == .ip4) {
            buf[n] = a;
            n += 1;
        }
    }
    return buf[0..n];
}

/// 构造一条 DNS 查询报文（移植自 musl / 标准库实现）。
fn writeResolutionQuery(q: *[280]u8, dname: []const u8, ty: HostName.DnsRecord, entropy: [2]u8) usize {
    var name = dname;
    if (std.mem.endsWith(u8, name, ".")) name.len -= 1;
    std.debug.assert(name.len <= 253);
    const n = 17 + name.len + @intFromBool(name.len != 0);

    q[0..2].* = entropy;
    @memset(q[2..n], 0);
    q[2] = 1; // recursion desired
    q[5] = 1; // QDCOUNT = 1
    @memcpy(q[13..][0..name.len], name);
    var i: usize = 13;
    var j: usize = undefined;
    while (q[i] != 0) : (i = j + 1) {
        j = i;
        while (q[j] != 0 and q[j] != '.') : (j += 1) {}
        if (j - i - 1 > 62) unreachable;
        q[i - 1] = @intCast(j - i);
    }
    q[i + 1] = @backingInt(ty);
    q[i + 3] = 1; // IN
    return n;
}

/// 入队；把「队列被提前关闭」按契约视为不可达（标准库同样这么处理）。
fn put(io: Io, q: *Io.Queue(HostName.LookupResult), item: HostName.LookupResult) HostName.LookupError!void {
    q.putOne(io, item) catch |e| switch (e) {
        error.Closed => unreachable, // 本函数返回前，调用方不得 close
        error.Canceled => return error.Canceled,
    };
}

// ------------------------------------------------------------- 文件读写

fn readAll(gpa: std.mem.Allocator, io: Io, abs_path: []const u8) ![]u8 {
    const f = try Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    var buf: [8 * 1024]u8 = undefined;
    var r = f.reader(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(max_file_bytes));
}

fn writeAll(io: Io, abs_path: []const u8, data: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(io, abs_path, .{});
    defer f.close(io);
    var buf: [4 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

// ------------------------------------------------------------------ 测试

test "isLinkLocalV6" {
    try std.testing.expect(isLinkLocalV6("fe80::1"));
    try std.testing.expect(isLinkLocalV6("FE80::d023:ceff:fea8:c173"));
    try std.testing.expect(isLinkLocalV6("febf::1%en0"));
    try std.testing.expect(!isLinkLocalV6("fd10:10:10:1::1"));
    try std.testing.expect(!isLinkLocalV6("240e:309:10be:3e11::1"));
    try std.testing.expect(!isLinkLocalV6("223.5.5.5"));
    try std.testing.expect(!isLinkLocalV6("fec0::1")); // site-local，非链路本地
}

test "filterUnreachable" {
    const gpa = std.testing.allocator;
    const src = "search lan\nnameserver fe80::1\nnameserver 223.5.5.5\n";
    const out = (try filterUnreachable(gpa, src)).?;
    defer gpa.free(out);
    try std.testing.expectEqualStrings("search lan\nnameserver 223.5.5.5\n", out);

    // 无需改动时返回 null
    try std.testing.expectEqual(@as(?[]u8, null), try filterUnreachable(gpa, "nameserver 223.5.5.5\n"));
    try std.testing.expectEqual(@as(?[]u8, null), try filterUnreachable(gpa, ""));
}

test "isLocalhost" {
    try std.testing.expect(isLocalhost("localhost"));
    try std.testing.expect(isLocalhost("localhost."));
    try std.testing.expect(isLocalhost("foo.localhost"));
    try std.testing.expect(!isLocalhost("notlocalhost"));
    try std.testing.expect(!isLocalhost("example.com"));
}
