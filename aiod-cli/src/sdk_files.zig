//! Core SDK —— 文件域（/v2/fs/*）。
//!
//! 包含文件读写、目录列表、stat、tar 树解析、目录创建、删除、移动、复制、查找、正则搜索等。
const std = @import("std");
const sdkmod = @import("sdk.zig");

const Sdk = sdkmod.Sdk;

pub const ReadSpec = struct {
    path: []const u8,
    start: ?i64 = null,
    end: ?i64 = null,
    user: ?[]const u8 = null,
};

/// GET /v2/fs/read?path=...&start=&end=&user=
pub fn readFile(self: *Sdk, spec: ReadSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, spec.path));
    if (spec.start) |v| try w.print("&start={d}", .{v});
    if (spec.end) |v| try w.print("&end={d}", .{v});
    if (spec.user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/read?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const WriteSpec = struct {
    path: []const u8,
    content: []const u8,
    append: bool = false,
    encoding: ?[]const u8 = null,
    leading_newline: bool = false,
    trailing_newline: bool = false,
    user: ?[]const u8 = null,
};

/// POST /v2/fs/write（文本写入）
pub fn writeFile(self: *Sdk, spec: WriteSpec) ![]const u8 {
    const cap = (spec.path.len + spec.content.len) * 2 + 512;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, cap));
    try w.writeAll("{\"path\":\"");
    try sdkmod.esc(&w, spec.path);
    try w.writeAll("\",\"content\":\"");
    try sdkmod.esc(&w, spec.content);
    try w.writeAll("\"");
    if (spec.append) try w.writeAll(",\"append\":true");
    if (spec.encoding) |e| {
        try w.writeAll(",\"encoding\":\"");
        try sdkmod.esc(&w, e);
        try w.writeAll("\"");
    }
    if (spec.leading_newline) try w.writeAll(",\"leading_newline\":true");
    if (spec.trailing_newline) try w.writeAll(",\"trailing_newline\":true");
    if (spec.user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/write", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

pub const ListSpec = struct {
    path: []const u8,
    user: ?[]const u8 = null,
    recursive: bool = false,
    show_hidden: bool = false,
    max_depth: ?i64 = null,
};

/// GET /v2/fs/list?path=...
pub fn list(self: *Sdk, spec: ListSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, spec.path));
    if (spec.user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    if (spec.recursive) try w.writeAll("&recursive=true");
    if (spec.show_hidden) try w.writeAll("&show_hidden=true");
    if (spec.max_depth) |d| try w.print("&max_depth={d}", .{d});

    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/list?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const StatSpec = struct {
    path: []const u8,
    user: ?[]const u8 = null,
    follow_symlinks: bool = false,
};

/// GET /v2/fs/stat?path=...
pub fn stat(self: *Sdk, spec: StatSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, spec.path));
    if (spec.user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    if (spec.follow_symlinks) try w.writeAll("&follow_symlinks=true");

    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/stat?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/fs/tree?path=...（返回原始 tar 字节）
pub fn treeRaw(self: *Sdk, p: ?[]const u8, user: ?[]const u8) ![]const u8 {
    const target = p orelse "/";
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, target));
    if (user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/tree?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.requestRaw(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

pub const TarEntry = struct { name: []const u8, is_dir: bool };

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

pub fn tarEntries(arena: std.mem.Allocator, data: []const u8) ![]TarEntry {
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

pub fn renderTreeText(arena: std.mem.Allocator, tar_data: []const u8) ![]const u8 {
    var entries = try tarEntries(arena, tar_data);
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const cur = entries[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, entries[j - 1].name, cur.name) == .gt) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = cur;
    }
    var w = std.Io.Writer.fixed(try arena.alloc(u8, tar_data.len * 2 + 4096));
    const pad = "                                        ";
    var prev: []const u8 = "";
    for (entries) |e| {
        var nm = e.name;
        if (std.mem.endsWith(u8, nm, "/")) nm = nm[0 .. nm.len - 1];
        if (std.mem.eql(u8, nm, prev)) continue;
        prev = nm;
        var depth: usize = 0;
        for (nm) |ch| {
            if (ch == '/') depth += 1;
        }
        const base = if (std.mem.lastIndexOfScalar(u8, nm, '/')) |k| nm[k + 1 ..] else nm;
        const width = @min(depth * 2, pad.len);
        try w.writeAll(pad[0..width]);
        try w.print("{s}{s}\n", .{ base, if (e.is_dir) "/" else "" });
    }
    return w.buffered();
}

/// 获取文本树（GET /v2/fs/tree 解析后的树结构）
pub fn treeText(self: *Sdk, p: ?[]const u8, user: ?[]const u8) ![]const u8 {
    const raw = try treeRaw(self, p, user);
    return renderTreeText(self.arena, raw);
}

/// POST /v2/fs/mkdir
pub fn mkdir(self: *Sdk, p: []const u8, parents: bool, user: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, p.len * 2 + 256));
    try w.writeAll("{\"path\":\"");
    try sdkmod.esc(&w, p);
    try w.writeAll("\"");
    if (parents) try w.writeAll(",\"parents\":true");
    if (user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/mkdir", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/fs/delete
pub fn deleteFile(self: *Sdk, p: []const u8, recursive: bool, user: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, p.len * 2 + 256));
    try w.writeAll("{\"path\":\"");
    try sdkmod.esc(&w, p);
    try w.writeAll("\"");
    if (recursive) try w.writeAll(",\"recursive\":true");
    if (user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/delete", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/fs/copy
pub fn copy(self: *Sdk, src: []const u8, dst: []const u8, overwrite: bool, user: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, (src.len + dst.len) * 2 + 256));
    try w.writeAll("{\"source\":\"");
    try sdkmod.esc(&w, src);
    try w.writeAll("\",\"destination\":\"");
    try sdkmod.esc(&w, dst);
    try w.writeAll("\"");
    if (overwrite) try w.writeAll(",\"overwrite\":true");
    if (user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/copy", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// POST /v2/fs/move
pub fn move(self: *Sdk, src: []const u8, dst: []const u8, overwrite: bool, user: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, (src.len + dst.len) * 2 + 256));
    try w.writeAll("{\"source\":\"");
    try sdkmod.esc(&w, src);
    try w.writeAll("\",\"destination\":\"");
    try sdkmod.esc(&w, dst);
    try w.writeAll("\"");
    if (overwrite) try w.writeAll(",\"overwrite\":true");
    if (user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/move", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

pub const EditSpec = struct {
    path: []const u8,
    old: ?[]const u8 = null,
    new: ?[]const u8 = null,
    replace_mode: ?[]const u8 = null,
    insert: ?i64 = null,
    text: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

/// POST /v2/fs/edit
pub fn edit(self: *Sdk, spec: EditSpec) ![]const u8 {
    const old_len: usize = if (spec.old) |o| o.len else 0;
    const new_len: usize = if (spec.new) |n| n.len else 0;
    const txt_len: usize = if (spec.text) |t| t.len else 0;
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, (spec.path.len + old_len + new_len + txt_len) * 2 + 1024));
    if (spec.old) |old| {
        try w.writeAll("{\"path\":\"");
        try sdkmod.esc(&w, spec.path);
        try w.writeAll("\",\"command\":\"str_replace\",\"old_str\":\"");
        try sdkmod.esc(&w, old);
        try w.writeAll("\",\"new_str\":\"");
        try sdkmod.esc(&w, spec.new orelse "");
        try w.writeAll("\"");
        if (spec.replace_mode) |m| {
            try w.writeAll(",\"replace_mode\":\"");
            try sdkmod.esc(&w, m);
            try w.writeAll("\"");
        }
    } else if (spec.insert) |line| {
        try w.writeAll("{\"path\":\"");
        try sdkmod.esc(&w, spec.path);
        try w.print("\",\"command\":\"insert\",\"insert_line\":{d},\"new_str\":\"", .{line});
        try sdkmod.esc(&w, spec.text orelse "");
        try w.writeAll("\"");
    } else {
        return error.BadArg;
    }
    if (spec.user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/edit", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

pub const GrepSpec = struct {
    path: []const u8,
    pattern: []const u8,
    fixed: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    context: ?i64 = null,
    max_matches: ?i64 = null,
    offset: ?i64 = null,
    type: ?[]const u8 = null,
    include: ?[]const []const u8 = null,
    exclude: ?[]const []const u8 = null,
    user: ?[]const u8 = null,
};

/// POST /v2/fs/grep
pub fn grep(self: *Sdk, spec: GrepSpec) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, (spec.path.len + spec.pattern.len) * 2 + 4096));
    try w.writeAll("{\"path\":\"");
    try sdkmod.esc(&w, spec.path);
    try w.writeAll("\",\"pattern\":\"");
    try sdkmod.esc(&w, spec.pattern);
    try w.writeAll("\",\"recursive\":true");
    if (spec.fixed) try w.writeAll(",\"fixed_strings\":true");
    if (spec.ignore_case) try w.writeAll(",\"case_insensitive\":true");
    if (spec.multiline) try w.writeAll(",\"multiline\":true");
    if (spec.context) |v| try w.print(",\"context_before\":{d},\"context_after\":{d}", .{ v, v });
    if (spec.max_matches) |v| try w.print(",\"max_results\":{d}", .{v});
    if (spec.offset) |v| try w.print(",\"offset\":{d}", .{v});
    if (spec.type) |v| {
        try w.writeAll(",\"type\":\"");
        try sdkmod.esc(&w, v);
        try w.writeAll("\"");
    }
    if (spec.include) |arr| {
        try w.writeAll(",\"include\":[");
        for (arr, 0..) |it, idx| {
            if (idx > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try sdkmod.esc(&w, it);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (spec.exclude) |arr| {
        try w.writeAll(",\"exclude\":[");
        for (arr, 0..) |it, idx| {
            if (idx > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try sdkmod.esc(&w, it);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (spec.user) |u| {
        try w.writeAll(",\"user\":\"");
        try sdkmod.esc(&w, u);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.POST, "/v2/fs/grep", w.buffered(), buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/fs/search?path=...&pattern=...
pub fn search(self: *Sdk, p: []const u8, pattern: []const u8, user: ?[]const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(try self.arena.alloc(u8, 4096));
    try w.writeAll("path=");
    try w.writeAll(try sdkmod.qenc(self.arena, p));
    try w.writeAll("&pattern=");
    try w.writeAll(try sdkmod.qenc(self.arena, pattern));
    if (user) |u| {
        try w.writeAll("&user=");
        try w.writeAll(try sdkmod.qenc(self.arena, u));
    }
    const path = try std.fmt.allocPrint(self.arena, "/v2/fs/search?{s}", .{w.buffered()});
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, path, null, buf);
    return self.arena.dupe(u8, res.body);
}

/// GET /v2/sandbox（沙箱画像）
pub fn sandboxInfo(self: *Sdk) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const res = try self.request(.GET, "/v2/sandbox", null, buf);
    return self.arena.dupe(u8, res.body);
}
