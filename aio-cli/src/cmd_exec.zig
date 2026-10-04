//! 命令执行：exec / async / log / kill / stdin / sess / sess-*
//!
//! 待实现：dispatch 命中本模块负责的命令时执行并返回 true，否则返回 false。
const std = @import("std");
const util = @import("util.zig");
const Ctx = util.Ctx;

pub fn dispatch(c: *Ctx, cmd: []const u8, args: []const []const u8) !bool {
    _ = c;
    _ = cmd;
    _ = args;
    return false;
}
