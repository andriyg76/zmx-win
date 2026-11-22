//! Implements win/cshim.h, which c.h includes on Windows in place of termios.h and pty.h.
const std = @import("std");
const builtin = @import("builtin");
const cross = @import("cross");
const api = @import("api.zig");
const posix = @import("posix.zig");
const stdio = @import("stdio.zig");
const conpty = @import("conpty.zig");

comptime {
    if (builtin.os.tag == .windows) {
        @export(&ioctl, .{ .name = "ioctl" });
        @export(&tcgetattr, .{ .name = "tcgetattr" });
        @export(&tcsetattr, .{ .name = "tcsetattr" });
        @export(&tcflush, .{ .name = "tcflush" });
        @export(&cfmakeraw, .{ .name = "cfmakeraw" });
        @export(&setenv, .{ .name = "setenv" });
        @export(&unsetenv, .{ .name = "unsetenv" });
    }
}

fn stdHandleOf(fd: c_int) ?api.DWORD {
    const e = posix.entry(fd) orelse return null;
    return switch (e.kind) {
        .stdin => api.STD_INPUT_HANDLE,
        .stdout => api.STD_OUTPUT_HANDLE,
        .stderr => api.STD_ERROR_HANDLE,
        else => null,
    };
}

fn ioctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) callconv(.c) c_int {
    switch (request) {
        cross.TIOCGWINSZ => {
            const ws: *cross.struct_winsize = @ptrCast(@alignCast(arg orelse return -1));
            const rc = if (stdHandleOf(fd)) |which| stdio.windowSize(which) else conpty.size(fd);
            const s = rc orelse return -1;
            ws.* = .{ .ws_row = s[0], .ws_col = s[1], .ws_xpixel = 0, .ws_ypixel = 0 };
            return 0;
        },
        cross.TIOCSWINSZ => {
            const ws: *const cross.struct_winsize = @ptrCast(@alignCast(arg orelse return -1));
            return if (conpty.resize(fd, ws.ws_row, ws.ws_col)) 0 else -1;
        },
        cross.TIOCOUTQ => {
            // what stdout's bridge holds that the console has not taken; other writes complete before returning
            const q: *c_int = @ptrCast(@alignCast(arg orelse return -1));
            q.* = if (stdHandleOf(fd) == api.STD_OUTPUT_HANDLE) @intCast(@min(stdio.outputQueued(), std.math.maxInt(c_int))) else 0;
            return 0;
        },
        cross.FIONREAD => {
            const q: *c_int = @ptrCast(@alignCast(arg orelse return -1));
            const e = posix.entry(fd) orelse return -1;
            if (e.kind != .socket) return -1;
            var n: u32 = 0;
            if (api.ioctlsocket(e.sock, api.FIONREAD, &n) != 0) return -1;
            q.* = @intCast(n);
            return 0;
        },
        // a pseudo console has no foreground process group to read
        else => return -1,
    }
}

fn tcgetattr(fd: c_int, t: *cross.struct_termios) callconv(.c) c_int {
    if (stdHandleOf(fd) != api.STD_INPUT_HANDLE) return -1;
    const m = stdio.getModes() orelse return -1;
    t.* = std.mem.zeroes(cross.struct_termios);
    t.zmx_in_mode = m.in;
    t.zmx_out_mode = m.out;
    t.zmx_in_cp = m.in_cp;
    t.zmx_out_cp = m.out_cp;
    return 0;
}

fn tcsetattr(fd: c_int, action: c_int, t: *const cross.struct_termios) callconv(.c) c_int {
    if (stdHandleOf(fd) != api.STD_INPUT_HANDLE) return -1;
    if (action == cross.TCSAFLUSH) stdio.flushInput();
    const m: stdio.Modes = .{ .in = t.zmx_in_mode, .out = t.zmx_out_mode, .in_cp = t.zmx_in_cp, .out_cp = t.zmx_out_cp };
    stdio.setModes(if (t.zmx_raw != 0) stdio.rawModes(m) else m);
    return 0;
}

fn tcflush(fd: c_int, queue: c_int) callconv(.c) c_int {
    const which = stdHandleOf(fd);
    if (queue != cross.TCOFLUSH and which == api.STD_INPUT_HANDLE) stdio.flushInput();
    if (queue != cross.TCIFLUSH and which == api.STD_OUTPUT_HANDLE) stdio.flushOutput();
    return 0;
}

fn cfmakeraw(t: *cross.struct_termios) callconv(.c) void {
    t.zmx_raw = 1;
}

fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int {
    if (overwrite == 0 and std.c.getenv(name) != null) return 0;
    return _putenv_s(name, value);
}

fn unsetenv(name: [*:0]const u8) callconv(.c) c_int {
    // an empty value removes the variable
    return _putenv_s(name, "");
}

extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
