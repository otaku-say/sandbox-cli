//! Core SDK —— 沙箱内文件操作（走 envd 数据面）。
//!
//! 约定：纯操作与传输，不打印、不 exit、不依赖 CLI 上下文。
const std = @import("std");
const sdkmod = @import("sdk.zig");
const envd = @import("envd.zig");

const Sdk = sdkmod.Sdk;

fn jsonPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{try envd.jsonEscape(arena, path)});
}

/// 读文件内容（GET /files?path=...）。
pub fn fileRead(self: *Sdk, sid: []const u8, path: []const u8, user: ?[]const u8) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const res = try envd.readFile(self.arena, self.client, dp.base, dp.token, user, path, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
    return self.arena.dupe(u8, res.body);
}

/// 写文件内容（POST /files?path=...，原始 octet-stream）。
pub fn fileWrite(self: *Sdk, sid: []const u8, path: []const u8, content: []const u8, user: ?[]const u8) !void {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const res = try envd.writeFile(self.arena, self.client, dp.base, dp.token, user, path, content, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
}

/// 列目录（POST /filesystem.Filesystem/ListDir）。返回 JSON 响应体。
pub fn fileList(self: *Sdk, sid: []const u8, path: []const u8, user: ?[]const u8) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const body = try jsonPath(self.arena, path);
    const res = try envd.fsRPC(self.arena, self.client, dp.base, dp.token, user, "ListDir", body, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
    return self.arena.dupe(u8, res.body);
}

/// 获取文件/目录元信息（POST /filesystem.Filesystem/Stat）。返回 JSON 响应体。
pub fn fileStat(self: *Sdk, sid: []const u8, path: []const u8, user: ?[]const u8) ![]const u8 {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const body = try jsonPath(self.arena, path);
    const res = try envd.fsRPC(self.arena, self.client, dp.base, dp.token, user, "Stat", body, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
    return self.arena.dupe(u8, res.body);
}

/// 创建目录（POST /filesystem.Filesystem/MakeDir）。
pub fn fileMkdir(self: *Sdk, sid: []const u8, path: []const u8, user: ?[]const u8) !void {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const body = try jsonPath(self.arena, path);
    const res = try envd.fsRPC(self.arena, self.client, dp.base, dp.token, user, "MakeDir", body, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
}

/// 删除文件或目录（POST /filesystem.Filesystem/Remove）。
pub fn fileDelete(self: *Sdk, sid: []const u8, path: []const u8, user: ?[]const u8) !void {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const body = try jsonPath(self.arena, path);
    const res = try envd.fsRPC(self.arena, self.client, dp.base, dp.token, user, "Remove", body, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
}

/// 移动或重命名文件（POST /filesystem.Filesystem/Move）。
pub fn fileMove(self: *Sdk, sid: []const u8, source: []const u8, destination: []const u8, user: ?[]const u8) !void {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const body = try std.fmt.allocPrint(self.arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{
        try envd.jsonEscape(self.arena, source), try envd.jsonEscape(self.arena, destination),
    });
    const res = try envd.fsRPC(self.arena, self.client, dp.base, dp.token, user, "Move", body, buf);
    if (!res.ok()) {
        self.last_status = res.status;
        self.last_body = try self.arena.dupe(u8, res.body);
        return error.HttpError;
    }
}

/// 检查路径是否存在（走 Stat）。
pub fn fileExists(self: *Sdk, sid: []const u8, path: []const u8, user: ?[]const u8) !bool {
    const buf = try self.arena.alloc(u8, sdkmod.BUF);
    const dp = try self.dataPlane(sid, buf);
    const body = try jsonPath(self.arena, path);
    const res = try envd.fsRPC(self.arena, self.client, dp.base, dp.token, user, "Stat", body, buf);
    if (res.ok()) return true;
    if (res.status == 404 or std.mem.indexOf(u8, res.body, "not_found") != null) return false;
    self.last_status = res.status;
    self.last_body = try self.arena.dupe(u8, res.body);
    return error.HttpError;
}
