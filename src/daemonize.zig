const std = @import("std");
const lib_posix = @import("sys.zig").posix;
const Cfg = @import("cfg.zig");
const socket = @import("socket.zig");
const ipc = @import("ipc.zig");
const assert = std.debug.assert;
const log = @import("log.zig");
const cross = @import("cross");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const Cmd = struct {
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
};

pub fn createCmdZ(def_shell: []const u8, is_task_mode: bool, command: ?[]const []const u8) !Cmd {
    const gpa = std.heap.c_allocator;

    if (command) |cmd_args| {
        if (cmd_args.len > 0) {
            const argv = try gpa.allocSentinel(?[*:0]const u8, cmd_args.len, null);
            for (cmd_args, 0..) |arg, i| {
                const s = try gpa.dupeSentinel(u8, arg, 0);
                argv[i] = s.ptr;
            }
            return .{
                .file = argv[0].?,
                .argv_ptr = argv.ptr,
            };
        }
    }

    const shell: [:0]const u8 = if (is_task_mode and !is_windows)
        "bash"
    else
        try gpa.dupeSentinel(u8, def_shell, 0);

    if (is_windows) {
        // Windows shells have no login-shell convention to signal through argv[0]
        const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = shell.ptr;
        return .{ .file = shell, .argv_ptr = argv.ptr };
    }

    // Use "-shellname" as argv[0] to signal login shell (traditional method)
    const login_shell = try std.fmt.allocPrintSentinel(
        gpa,
        "-{s}",
        .{std.fs.path.basename(shell)},
        0,
    );
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = login_shell.ptr;

    return .{
        .file = shell,
        .argv_ptr = argv.ptr,
    };
}

/// Runs in the forked child. Either execs or returns an error (caller
/// must exit on error -- returning would fall through to parent code).
fn exec(sesh_name: []const u8, cmd: Cmd) !noreturn {
    const gpa = std.heap.c_allocator;

    // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
    // exec. Restore the default so the shell and its children behave
    // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
    const dfl: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.DFL },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);

    const session_env = try std.fmt.allocPrintSentinel(
        gpa,
        "ZMX_SESSION={s}",
        .{sesh_name},
        0,
    );
    _ = cross.putenv(session_env.ptr);

    if (cross.getenv("TERM")) |term_env| {
        if (std.mem.eql(u8, std.mem.span(term_env), "dumb")) {
            _ = cross.putenv(@constCast("TERM=xterm-256color"));
        }
    } else {
        _ = cross.putenv(@constCast("TERM=xterm-256color"));
    }

    // the shell inherits the first attach client's environment, and a nested `zmx attach` run from
    // it must not opt in on the outer terminal's behalf or learn its nonce
    _ = cross.unsetenv("ZMX_MANAGED");
    _ = cross.unsetenv("ZMX_MANAGED_CLAIM");
    // the record is the daemon's to write; a nested session must not write its own exit into it
    _ = cross.unsetenv("ZMX_EXIT_FILE");
    _ = cross.unsetenv("ZMX_HOLD_UNTIL_ATTACH");

    const err = lib_posix.execvpeZ(cmd.file, cmd.argv_ptr, std.c.environ);
    std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd.file, @errorName(err) });
    lib_posix.exit(1);
}

/// awaitRelease parks the forked child until the daemon writes one byte to the gate. The gate closing
/// without it (a kill, or the daemon gone) ends the child before the command runs.
fn awaitRelease(gate: [2]lib_posix.fd_t) void {
    // the child's copy of the write end would keep the gate open after the daemon is gone
    lib_posix.close(gate[1]);
    var byte: [1]u8 = undefined;
    const n = lib_posix.read(gate[0], &byte) catch 0;
    if (n != 1) lib_posix.exit(1);
    lib_posix.close(gate[0]);
}

pub const PtyInfo = struct {
    master_fd: c_int = undefined,
    pid: c_int = undefined,
    /// the write end of a held child's gate, -1 when the child runs at once
    hold_fd: c_int = -1,
};

/// spawnPty runs forkpty() and executes the shell or shell command the user
/// provides. With `hold`, the child waits before exec until the daemon releases it through
/// `PtyInfo.hold_fd`.
///
/// This is the second fork in the double-fork technique explained in the
/// daemonize() comment.
pub fn spawnPty(sesh_name: []const u8, cmd: Cmd, size: ipc.Resize, hold: bool) !PtyInfo {
    if (is_windows) return win.spawnConsole(sesh_name, cmd, size, hold);
    var ws: cross.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    const gate: ?[2]lib_posix.fd_t = if (hold) try lib_posix.pipe2(.{ .CLOEXEC = true }) else null;
    var master_fd: c_int = undefined;
    const pid = cross.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) {
        if (gate) |g| {
            lib_posix.close(g[0]);
            lib_posix.close(g[1]);
        }
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        if (gate) |g| awaitRelease(g);
        // In the forked child, ANY error must exit rather than propagate:
        // a returned error falls through to the parent code path below,
        // running a second daemon on the same socket (or worse, hitting
        // errdefers that delete the parent's socket file).
        exec(sesh_name, cmd) catch |err| {
            std.log.err("child setup failed: {s}", .{@errorName(err)});
            lib_posix.exit(1);
        };
        unreachable; // exec() either execs or exits, never returns ok
    }
    // master pid code path
    std.log.info("pty spawned session={s} pid={d} held={}", .{ sesh_name, pid, hold });
    if (gate) |g| lib_posix.close(g[0]);

    // make pty non-blocking
    const flags = try lib_posix.fcntl(master_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(master_fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);

    return .{
        .master_fd = master_fd,
        .pid = pid,
        .hold_fd = if (gate) |g| g[1] else -1,
    };
}

/// Detach is what the parent learns of the child's setsid through the acknowledgement pipe.
const Detach = enum { detached, gone, unknown };

/// awaitDetach waits for the child's acknowledgement byte. A parent that leads its terminal's
/// session would SIGHUP a child still in its group by exiting, so it must not exit before the
/// child's setsid. EOF without the byte means the child died first; a timeout says nothing.
fn awaitDetach(fd: i32, timeout_ms: i32) Detach {
    var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const ready = lib_posix.poll(&fds, timeout_ms) catch return .unknown;
    if (ready == 0) return .unknown;
    var byte: [1]u8 = undefined;
    const n = lib_posix.read(fd, &byte) catch return .unknown;
    return if (n == 1) .detached else .gone;
}

/// daemonize is the first fork in a double-fork technique to create a
/// completely disconnected session (container of process groups).
///
/// When launching a daemon, you normally set the child process of the fork to
/// be the session leader via setsid() which creates a new session that removes
/// the current controlling terminal. This is important because we don't want a
/// controlling terminal for our daemon or else it could receive signals to
/// shutdown when the controlling terminal closes.
///
/// However, if the first fork's child process is also the daemon process, then
/// it's technically possible for the daemon to open a terminal device (e.g.
/// open("/dev/console", O_RDWR)) and then it would acquire a controlling
/// terminal! A controlling terminal would expose the daemon to
/// terminal-generated signals (e.g. SIGINT) or SIGHUP from terminal disconnect
/// which could kill the daemon.
///
/// The first fork produces a child guaranteed not to be a group leader, so
/// setsid() will succeed.  By forking a second time, the grandchild process
/// (the daemon) is not the session leader. Per POSIX, only a process that is
/// the session leader can acquire a controlling terminal.
///
/// Apparently this is "a bit paranoid" and on Linux it is arguable since a
/// session leader only acquires a controlling terminal under
/// implementation-defined conditions. But the double-fork is the portable way
/// to guarantee the daemon can never acquire one, regardless of how a given
/// POSIX implementation behaves. So we baked it into zmx.
///
/// PID=42  SID=10  PGID=10  ← original (PG leader, has tty)
///     │
///     │  fork #1
///     ├──────────┐
///     │ exit     │ PID=55  SID=10  PGID=10  (not a PG leader)
///     ✝          │
///                │ setsid()
///                ▼
///               PID=55  SID=55  PGID=55  (session leader, no tty)
///                 │
///                 │  fork #2
///                 ├──────────┐
///                 │ exit     │ PID=73  SID=55  PGID=55
///                 ✝          │ PID≠SID → can't get a tty
///                            ▼
///                          DAEMON ✓
pub fn daemonize(sesh_name: []const u8, cmd: Cmd, keep_fds_open: []i32, hold: bool) !PtyInfo {
    if (is_windows) return win.daemonize(sesh_name, cmd, hold);
    const ack = try lib_posix.pipe2(.{ .CLOEXEC = true });
    // creates the daemon
    const pid = try lib_posix.fork();
    assert(pid != -1);

    if (pid > 0) { // parent (client)
        lib_posix.close(ack[1]);
        const detach = awaitDetach(ack[0], 1000);
        lib_posix.close(ack[0]);
        // a slow child may still detach and serve, so only a child known dead fails the create
        if (detach == .gone) return error.DaemonExited;
        // cannot use a passed-in io or alloc after a fork so we create what we need
        // after the fork()
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch unreachable;
        return error.IsClientProc;
    }

    assert(pid == 0); // child (daemon's parent in double-fork)
    lib_posix.close(ack[0]);
    // becomes the session leader and detaches process from its controlling terminal
    _ = try lib_posix.setsid();
    _ = lib_posix.write(ack[1], "d") catch {};
    lib_posix.close(ack[1]);

    // Fetch terminal size before redirecting stdio FDs to /dev/null.
    const term_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);

    // Redirect stdin/stdout/stderr to /dev/null. The daemon
    // communicates via its unix socket, not stdio. Without
    // this, any pipe on FDs 0-2 (e.g. from bats' `run`
    // keyword) stays open for the daemon's lifetime, causing
    // the caller to hang waiting for EOF.
    {
        const devnull = lib_posix.open(
            "/dev/null",
            .{ .ACCMODE = .RDWR },
            0,
        ) catch |err| {
            std.log.warn("failed to open /dev/null: {s}", .{@errorName(err)});
            return err;
        };
        inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |fd| {
            _ = lib_posix.dup2(devnull, fd) catch |err| {
                std.log.warn("dup2 /dev/null -> {d}: {s}", .{ fd, @errorName(err) });
                return err;
            };
        }
        var found = false;
        for (keep_fds_open) |fd| {
            if (devnull == fd) found = true;
        }
        if (devnull > 2 and !found) lib_posix.close(devnull);
    }

    // Close file descriptors inherited from the parent that the
    // daemon doesn't need. This prevents test harnesses (like
    // bats) from hanging: they wait for their internal FDs (3+)
    // to close before exiting.
    //
    // Skip any fds that the caller wants to keep open, e.g. server_sock_fd
    // (needed for IPC) and dir.fd (needed to delete the socket file on
    // shutdown).
    {
        var fd: i32 = 3;
        while (fd < 64) : (fd += 1) {
            var found = false;
            for (keep_fds_open) |kfd| {
                if (fd == kfd) found = true;
            }
            if (!found) _ = std.c.close(fd);
        }
    }

    return spawnPty(sesh_name, cmd, term_size, hold);
}

fn readUntil(fd: c_int, want: []const u8, buf: []u8, wait_ms: i32) ![]const u8 {
    var len: usize = 0;
    var waited: i32 = 0;
    while (waited < wait_ms) : (waited += 20) {
        if (std.mem.indexOf(u8, buf[0..len], want) != null) break;
        var pfd = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        if ((lib_posix.poll(&pfd, 20) catch 0) == 0) continue;
        const n = lib_posix.read(fd, buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

test "a held child runs its command only once released, without the hold variable" {
    if (is_windows) return error.SkipZigTest; // forkpty and /bin/sh; conpty.zig tests the Windows gate
    _ = cross.putenv(@constCast("ZMX_HOLD_UNTIL_ATTACH=5"));
    defer _ = cross.unsetenv("ZMX_HOLD_UNTIL_ATTACH");
    const cmd = try createCmdZ("/bin/sh", false, &.{ "/bin/sh", "-c", "printf 'ran:%s' \"${ZMX_HOLD_UNTIL_ATTACH-unset}\"" });
    const info = try spawnPty("hold-test", cmd, .{ .rows = 24, .cols = 80 }, true);
    defer lib_posix.close(info.master_fd);
    try std.testing.expect(info.hold_fd >= 0);
    const fd_flags = try lib_posix.fcntl(info.hold_fd, lib_posix.F.GETFD, 0);
    try std.testing.expect(fd_flags & std.posix.FD_CLOEXEC != 0);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try readUntil(info.master_fd, "ran:", &buf, 300));

    _ = try lib_posix.write(info.hold_fd, "1");
    lib_posix.close(info.hold_fd);
    const out = try readUntil(info.master_fd, "ran:unset", &buf, 3000);
    try std.testing.expect(std.mem.indexOf(u8, out, "ran:unset") != null);
    _ = lib_posix.waitpid(info.pid, 0);
}

test "a held child whose gate closes without release exits before its command" {
    if (is_windows) return error.SkipZigTest; // forkpty and /bin/sh; conpty.zig tests the Windows gate
    const cmd = try createCmdZ("/bin/sh", false, &.{ "/bin/sh", "-c", "printf ran" });
    const info = try spawnPty("hold-test", cmd, .{ .rows = 24, .cols = 80 }, true);
    defer lib_posix.close(info.master_fd);
    lib_posix.close(info.hold_fd);
    const status = lib_posix.waitpid(info.pid, 0).status;
    try std.testing.expect(std.posix.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 1), std.posix.W.EXITSTATUS(status));
    var buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try readUntil(info.master_fd, "ran", &buf, 200), "ran") == null);
}

test "a child spawned without a hold has no gate" {
    if (is_windows) return error.SkipZigTest; // forkpty and /bin/sh; conpty.zig tests the Windows gate
    const cmd = try createCmdZ("/bin/sh", false, &.{ "/bin/sh", "-c", "printf ran" });
    const info = try spawnPty("hold-test", cmd, .{ .rows = 24, .cols = 80 }, false);
    defer lib_posix.close(info.master_fd);
    try std.testing.expectEqual(@as(c_int, -1), info.hold_fd);
    var buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try readUntil(info.master_fd, "ran", &buf, 3000), "ran") != null);
    _ = lib_posix.waitpid(info.pid, 0);
}

/// Windows has no fork, so a client starts the daemon as `zmx __daemon`, a fresh process given the session,
/// the size and the command the fork would have carried over, and waits until its socket answers.
pub const win = struct {
    const api = @import("win/api.zig");
    const conpty = @import("win/conpty.zig");

    pub const Child = struct { rows: u16, cols: u16 };
    /// set in the `zmx __daemon` process, which runs the daemon itself
    pub var child: ?Child = null;
    /// whether the client is starting a `zmx run` task session, carried to the daemon
    pub var task_mode = false;

    /// The exit code of a `zmx __daemon` that lost the race for its session's socket.
    pub const exit_address_in_use: u8 = 3;

    /// A client hands `hold` to `zmx __daemon` as its HOLD argument, the ZMX_HOLD_UNTIL_ATTACH seconds it was
    /// created with, since that daemon is a new process rather than a fork carrying the client's state over.
    pub fn daemonize(sesh_name: []const u8, cmd: Cmd, hold: bool) !PtyInfo {
        if (child) |c| return spawnConsole(sesh_name, cmd, .{ .rows = c.rows, .cols = c.cols }, hold);
        try startDaemon(sesh_name, cmd, hold);
        return error.IsClientProc;
    }

    fn startDaemon(sesh_name: []const u8, cmd: Cmd, hold: bool) !void {
        const gpa = std.heap.c_allocator;
        const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);

        var exe_buf: [1024]u16 = undefined;
        const exe_len = api.GetModuleFileNameW(null, &exe_buf, exe_buf.len);
        if (exe_len == 0 or exe_len >= exe_buf.len) return error.NoExePath;
        const exe = try std.unicode.wtf16LeToWtf8Alloc(gpa, exe_buf[0..exe_len]);
        defer gpa.free(exe);

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        var rows_buf: [8]u8 = undefined;
        var cols_buf: [8]u8 = undefined;
        try args.appendSlice(gpa, &.{
            exe,
            "__daemon",
            sesh_name,
            try std.fmt.bufPrint(&rows_buf, "{d}", .{size.rows}),
            try std.fmt.bufPrint(&cols_buf, "{d}", .{size.cols}),
            if (task_mode) "task" else "session",
            // hold is only requested by a detached create, which validated ZMX_HOLD_UNTIL_ATTACH already
            if (hold) std.mem.span(cross.getenv("ZMX_HOLD_UNTIL_ATTACH") orelse return error.NoHoldSeconds) else "0",
            "--",
        });
        var i: usize = 0;
        while (cmd.argv_ptr[i]) |arg| : (i += 1) try args.append(gpa, std.mem.span(arg));

        const cmdline = try conpty.commandLine(gpa, args.items);
        defer gpa.free(cmdline);

        var si: api.STARTUPINFOW = .{ .cb = @sizeOf(api.STARTUPINFOW) };
        // the daemon keeps none of the client's stdio, so a pipe on it reaches EOF when the client exits
        si.dwFlags = api.STARTF_USESTDHANDLES;
        si.hStdInput = api.INVALID_HANDLE_VALUE;
        si.hStdOutput = api.INVALID_HANDLE_VALUE;
        si.hStdError = api.INVALID_HANDLE_VALUE;
        var pi: api.PROCESS_INFORMATION = undefined;
        const base = api.DETACHED_PROCESS | api.CREATE_NEW_PROCESS_GROUP | api.CREATE_NO_WINDOW;
        // leave the client's job when it allows that, so closing the client's terminal does not end the daemon
        if (api.CreateProcessW(null, cmdline.ptr, null, null, 0, base | api.CREATE_BREAKAWAY_FROM_JOB, null, null, &si, &pi) == 0) {
            const first = api.GetLastError();
            if (api.CreateProcessW(null, cmdline.ptr, null, null, 0, base, null, null, &si, &pi) == 0) {
                std.log.err("starting daemon failed err={d} breakaway_err={d}", .{ api.GetLastError(), first });
                return error.DaemonSpawnFailed;
            }
            std.log.warn("daemon started inside the client's job err={d}", .{first});
        }
        _ = api.CloseHandle(pi.hThread);
        defer _ = api.CloseHandle(pi.hProcess);
        std.log.info("daemon process started session={s} pid={d}", .{ sesh_name, pi.dwProcessId });

        const socket_path = try socket.getSocketPath(gpa, (try Cfg.socketDir(gpa)), sesh_name);
        defer gpa.free(socket_path);
        const deadline = api.GetTickCount64() + 10_000;
        while (api.GetTickCount64() < deadline) {
            if (socket.sessionConnect(socket_path)) |fd| {
                lib_posix.close(fd);
                return;
            } else |_| {}
            if (api.WaitForSingleObject(pi.hProcess, 20) == api.WAIT_OBJECT_0) {
                var code: u32 = 0;
                _ = api.GetExitCodeProcess(pi.hProcess, &code);
                std.log.info("daemon process exited before its socket answered code={d}", .{code});
                if (code == exit_address_in_use) return error.AddressInUse;
                // a daemon that found the session running already left it to this client
                if (code == 0) return;
                return error.DaemonSpawnFailed;
            }
        }
        return error.DaemonStartTimeout;
    }

    pub fn spawnConsole(sesh_name: []const u8, cmd: Cmd, size: ipc.Resize, hold: bool) !PtyInfo {
        const gpa = std.heap.c_allocator;
        const session_env = try std.fmt.allocPrintSentinel(gpa, "ZMX_SESSION={s}", .{sesh_name}, 0);
        _ = cross.putenv(session_env.ptr);
        if (cross.getenv("TERM")) |term_env| {
            if (std.mem.eql(u8, std.mem.span(term_env), "dumb")) _ = cross.putenv(@constCast("TERM=xterm-256color"));
        } else {
            _ = cross.putenv(@constCast("TERM=xterm-256color"));
        }
        _ = cross.unsetenv("ZMX_MANAGED");
        _ = cross.unsetenv("ZMX_MANAGED_CLAIM");
        _ = cross.unsetenv("ZMX_EXIT_FILE");
        _ = cross.unsetenv("ZMX_HOLD_UNTIL_ATTACH");

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var i: usize = 0;
        while (cmd.argv_ptr[i]) |arg| : (i += 1) try argv.append(gpa, std.mem.span(arg));
        const spawned = try conpty.spawn(argv.items, size.rows, size.cols, hold);
        std.log.info("pty spawned session={s} pid={d} held={}", .{ sesh_name, spawned.pid, hold });
        return .{ .master_fd = spawned.fd, .pid = spawned.pid, .hold_fd = spawned.hold_fd };
    }
};

test "awaitDetach reads the acknowledgement, a child gone before it, and silence" {
    // Windows starts the daemon as `zmx __daemon` and waits for its socket, with no fork to acknowledge
    if (is_windows) return error.SkipZigTest;
    const written = try lib_posix.pipe2(.{ .CLOEXEC = true });
    _ = try lib_posix.write(written[1], "d");
    lib_posix.close(written[1]);
    try std.testing.expectEqual(Detach.detached, awaitDetach(written[0], 1000));
    lib_posix.close(written[0]);

    const closed = try lib_posix.pipe2(.{ .CLOEXEC = true });
    lib_posix.close(closed[1]);
    try std.testing.expectEqual(Detach.gone, awaitDetach(closed[0], 1000));
    lib_posix.close(closed[0]);

    const silent = try lib_posix.pipe2(.{ .CLOEXEC = true });
    try std.testing.expectEqual(Detach.unknown, awaitDetach(silent[0], 10));
    lib_posix.close(silent[0]);
    lib_posix.close(silent[1]);
}
