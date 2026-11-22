//! The POSIX layer for the target: posix.zig, or on Windows its counterpart over sockets and ConPTY.
const builtin = @import("builtin");

pub const posix = if (builtin.os.tag == .windows) @import("win/posix.zig") else @import("posix.zig");

const std = @import("std");

/// File permissions from a POSIX mode; Windows files take the default access of their directory.
pub fn permissions(mode: u32) std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(@intCast(mode));
}

/// Moves `file` to its end and returns that offset, in one call so a concurrent writer cannot slip between.
pub fn seekEnd(file: std.Io.File) ?u64 {
    if (builtin.os.tag == .windows) {
        var pos: i64 = 0;
        if (SetFilePointerEx(file.handle, 0, &pos, 2) == 0) return null;
        return @intCast(pos);
    }
    const cross = @import("cross");
    const pos = cross.lseek(file.handle, 0, cross.SEEK_END);
    return if (pos == -1) null else @intCast(pos);
}
extern "kernel32" fn SetFilePointerEx(h: *anyopaque, dist: i64, new: ?*i64, method: u32) callconv(.winapi) i32;

pub const HOST_NAME_MAX = if (builtin.os.tag == .windows) 256 else std.posix.HOST_NAME_MAX;

/// This machine's host name, as OSC 7 and `zmx list` compare it.
pub fn gethostname(buf: *[HOST_NAME_MAX]u8) ![]u8 {
    if (builtin.os.tag != .windows) return std.posix.gethostname(buf);
    var n: u32 = buf.len;
    // ComputerNameDnsHostname
    if (GetComputerNameExA(1, buf, &n) == 0) return error.Unexpected;
    return buf[0..n];
}
extern "kernel32" fn GetComputerNameExA(kind: i32, buf: [*]u8, n: *u32) callconv(.winapi) i32;

pub fn getpid() i32 {
    return if (builtin.os.tag == .windows) posix.getpid() else std.c.getpid();
}

/// A connected pair of stream sockets in `fds`, returning 0 or -1 as socketpair(2) does.
pub fn socketpair(fds: *[2]i32) c_int {
    if (builtin.os.tag == .windows) {
        fds.* = posix.pipe2(.{}) catch return -1;
        return 0;
    }
    return std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, fds);
}
