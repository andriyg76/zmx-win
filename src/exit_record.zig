const std = @import("std");
const lib_posix = @import("sys.zig").posix;

/// Marks that the session's shell exited by writing `exited` to `ZMX_EXIT_FILE`,
/// through a sibling that is renamed into place so a reader never sees a partial
/// record. With no `ZMX_EXIT_FILE` it does nothing. It reaps nothing: the
/// daemon's ordinary teardown still ends the shell's process group and waits.
pub fn write() void {
    const path = lib_posix.getenv("ZMX_EXIT_FILE") orelse return;
    if (path.len == 0) return;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.mem.printSentinel(&tmp_buf, "{s}.tmp", .{path}, 0) catch return;
    const fd = lib_posix.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600) catch {
        std.log.warn("cannot open exit record path={s}", .{tmp});
        return;
    };
    _ = lib_posix.write(fd, "exited\n") catch {};
    lib_posix.close(fd);
    if (std.c.rename(tmp.ptr, path.ptr) != 0) std.log.warn("cannot publish exit record path={s}", .{path});
}
