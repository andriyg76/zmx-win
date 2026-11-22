const std = @import("std");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const cross = @import("cross");
const socket = @import("socket.zig");
const label = @import("label.zig");
const role = @import("role.zig");
const lib_posix = @import("sys.zig").posix;
const exit_record = @import("exit_record.zig");
const Cfg = @import("cfg.zig");
const signal = @import("signal.zig");
const assert = std.debug.assert;
const daemonize = @import("daemonize.zig");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const ghostty_vt = terminal.ghostty_vt;

/// How long a client whose session ended may spend writing its last output and the terminal reset, from
/// the moment the daemon hangs up, closes or resets the connection.
const CLOSE_BUDGET_MS: i64 = 2000;
/// The end of that deadline the output leaves to the reset, on a stdout that is a terminal.
const RESET_SHARE_MS: i64 = 200;

fn resetShare(stdout_fd: i32) i64 {
    const tty = if (builtin.os.tag == .windows) lib_posix.isatty(stdout_fd) else std.c.isatty(stdout_fd) == 1;
    return if (tty) RESET_SHARE_MS else 0;
}

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
pub fn clientLoop(connection: ipc.Connection, env_str: []const u8, session_path: []const u8) !ClientResult {
    return clientLoopOn(connection, env_str, session_path, lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO);
}

/// A daemon whose session ended unlinks its socket before it closes its clients, so a hangup with the socket
/// still in place is a detach or a crash, after which the client returns as upstream does.
fn sessionGone(session_path: []const u8) bool {
    const path = lib_posix.toPosixPath(session_path) catch return false;
    return std.c.access(&path, 0) != 0;
}

/// Whether a hangup ends the session rather than detaching; the first one that does arms the close deadline.
fn sessionEnding(close_deadline: *?i64, session_path: []const u8) bool {
    if (close_deadline.* != null) return true;
    if (!sessionGone(session_path)) return false;
    close_deadline.* = role.nowMs() + CLOSE_BUDGET_MS;
    return true;
}

fn clientLoopOn(connection: ipc.Connection, env_str: []const u8, session_path: []const u8, stdin_fd: i32, stdout_fd: i32) !ClientResult {
    const client_sock_fd = connection.fd;
    std.log.info("client loop fd={d}", .{client_sock_fd});
    const gpa: std.mem.Allocator = blk: {
        if (builtin.mode == .debug) {
            const GPA = std.heap.DebugAllocator(.{});
            const Static = struct {
                var gpa: GPA = .{};
            };
            break :blk Static.gpa.allocator();
        }
        break :blk std.heap.c_allocator;
    };
    defer lib_posix.close(client_sock_fd);

    try signal.openSignalPipe();
    defer signal.closeSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.WINCH));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.HUP));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.INT));

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try lib_posix.fcntl(client_sock_fd, lib_posix.F.GETFL, 0);
    sock_flags |= lib_posix.O_NONBLOCK;
    _ = try lib_posix.fcntl(client_sock_fd, lib_posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer sock_write_buf.deinit(gpa);

    if (env_str.len > 0) {
        try connection.wire.append(gpa, &sock_write_buf, .EnvSet, env_str);
    }

    var relay: ?role.Relay = if (role.nonceFromEnv()) |nonce| role.Relay.init(nonce) else null;
    defer if (relay) |*r| r.deinit();
    if (relay) |r| {
        const flags = ipc.ManageFlags{ .claim = role.claimFromEnv() };
        try connection.wire.append(gpa, &sock_write_buf, .Manage, std.mem.asBytes(&flags));
        // an older daemon ignores the tag, so a reclaim there leaves the lead where it is
        var id_buf: role.IdentityBuf = undefined;
        try connection.wire.append(gpa, &sock_write_buf, .Identity, role.identity(&id_buf, r.nonce, role.reclaimFromEnv()));
    }

    // Send init message with terminal size (buffered)
    const size = ipc.getTerminalSize(stdout_fd);
    try connection.wire.append(gpa, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 4);
    defer poll_fds.deinit(gpa);

    var read_buf = try ipc.SocketBuffer.init(gpa);
    defer read_buf.deinit();
    read_buf.wire = connection.wire;

    var stdout_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer stdout_buf.deinit(gpa);

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const reset_share = resetShare(stdout_fd);
    const stdin_orig_flags = try lib_posix.fcntl(stdin_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags | lib_posix.O_NONBLOCK);
    defer _ = lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags) catch {};

    const detach_key_disabled = util.isDetachKeyDisabled();

    var close_deadline: ?i64 = null;
    var sock_eof = false;

    while (true) {
        const stdout_behind = stdout_buf.items.len > 0;
        if (close_deadline) |deadline| {
            if (sock_eof and !stdout_behind) {
                return ClientResult{ .kind = .detach, .session_name = null, .close_deadline_ms = deadline };
            }
            if (role.nowMs() >= deadline - reset_share) {
                std.log.info("session output cut at the close deadline unwritten={d} eof={}", .{ stdout_buf.items.len, sock_eof });
                return ClientResult{ .kind = .detach, .session_name = null, .close_deadline_ms = deadline };
            }
        }
        const closing = close_deadline != null;

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = if (closing) -1 else stdin_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = lib_posix.POLL.IN;
        if (!closing and sock_write_buf.items.len > 0) {
            sock_events |= lib_posix.POLL.OUT;
        }
        // after the hangup the socket is read only while stdout keeps up, so the rest waits in the daemon;
        // poll reports a hangup whatever the events, so it is left out meanwhile
        const poll_sock = !closing or (!sock_eof and !stdout_behind);
        try poll_fds.append(gpa, .{
            .fd = if (poll_sock) client_sock_fd else -1,
            .events = sock_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = if (closing) -1 else signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        if (stdout_buf.items.len > 0) {
            try poll_fds.append(gpa, .{
                .fd = stdout_fd,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        var poll_timeout: i32 = if (relay) |*r| r.pollTimeout(role.nowMs()) else -1;
        if (close_deadline) |deadline| {
            const left: i32 = @intCast(std.math.clamp(deadline - reset_share - role.nowMs(), 0, CLOSE_BUDGET_MS));
            if (poll_timeout < 0 or left < poll_timeout) poll_timeout = left;
        }
        // after the hangup a signal ends the poll, so its timeout is recomputed from the deadline
        _ = if (closing) try lib_posix.pollOrInterrupted(poll_fds.items, poll_timeout) else try lib_posix.poll(poll_fds.items, poll_timeout);
        if (relay) |*r| try r.expire(gpa, &stdout_buf, role.nowMs());

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            try signal.drainSignalPipe();
            const next_size = ipc.getTerminalSize(stdout_fd);
            try connection.wire.append(
                gpa,
                &sock_write_buf,
                .Resize,
                std.mem.asBytes(&next_size),
            );
        }

        // Handle stdin -> socket (Input)
        const inp_flags = (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL);
        if (poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (!detach_key_disabled and util.isCtrlBackslash(buf[0..n])) {
                        std.log.info("detach key detected", .{});
                        try connection.wire.append(gpa, &sock_write_buf, .Detach, "");
                    } else {
                        try connection.wire.append(gpa, &sock_write_buf, .Input, buf[0..n]);
                    }
                } else {
                    std.log.info("eof stdin", .{});
                    // EOF on stdin
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
            }
        }

        // Handle socket read (incoming Output messages from daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.IN != 0) {
            const n: usize = read_buf.read(client_sock_fd) catch |err| blk: {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    if (!sessionEnding(&close_deadline, session_path)) return ClientResult{ .kind = .detach, .session_name = null };
                    break :blk 0;
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("server closed connection", .{});
                if (!sessionEnding(&close_deadline, session_path)) return ClientResult{ .kind = .detach, .session_name = null };
                sock_eof = true;
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Output => {
                        if (relay) |*r| {
                            try r.forward(gpa, &stdout_buf, msg.payload);
                        } else if (msg.payload.len > 0) {
                            try stdout_buf.appendSlice(gpa, msg.payload);
                        }
                    },
                    .Role => if (relay) |*r| {
                        if (msg.payload.len == @sizeOf(ipc.RoleChange)) {
                            const change = std.mem.bytesToValue(ipc.RoleChange, msg.payload);
                            try r.roleChanged(gpa, &stdout_buf, change, role.nowMs());
                        }
                    },
                    .Resize => {
                        // daemon is asking for the client's window size usually in response
                        // to this client being set as leader.
                        const next_size = ipc.getTerminalSize(stdout_fd);
                        try connection.wire.append(
                            gpa,
                            &sock_write_buf,
                            .Resize,
                            std.mem.asBytes(&next_size),
                        );
                    },
                    .Switch => {
                        std.log.info("switch session", .{});
                        // Payload format: "session_name\ncwd" from the daemon
                        const newline_idx = std.mem.indexOfScalar(u8, msg.payload, '\n') orelse {
                            // No cwd provided (backward compat or old daemon)
                            return ClientResult{ .kind = .switch_session, .session_name = try gpa.dupe(u8, msg.payload) };
                        };
                        return ClientResult{
                            .kind = .switch_session,
                            .session_name = try gpa.dupe(u8, msg.payload[0..newline_idx]),
                            .cwd = if (newline_idx + 1 < msg.payload.len) try gpa.dupe(u8, msg.payload[newline_idx + 1 ..]) else null,
                        };
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n: usize = lib_posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        std.log.info("connection reset or broken pipe", .{});
                        if (!sessionEnding(&close_deadline, session_path)) return ClientResult{ .kind = .detach, .session_name = null };
                        // the daemon is gone; what it sent before that is still read to EOF
                        sock_write_buf.clearRetainingCapacity();
                        break :blk 0;
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(gpa, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0) {
            const n = lib_posix.write(stdout_fd, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(gpa, 0, n, &[_]u8{});
            }
        }

        if (poll_fds.items[1].revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
            if (close_deadline == null) std.log.info("poll hup|err|nval", .{});
            if (!sessionEnding(&close_deadline, session_path)) return ClientResult{ .kind = .detach, .session_name = null };
        }
    }
}

fn ttyOutputQueued(fd: i32) usize {
    var queued: c_int = 0;
    if (cross.ioctl(fd, cross.TIOCOUTQ, &queued) != 0) return 0;
    return @intCast(@max(queued, 0));
}

fn takenBy(fd: i32, deadline_ms: i64, comptime queued: fn (i32) usize) bool {
    while (true) : (sleepMs(5)) {
        if (queued(fd) == 0) return true;
        if (role.nowMs() >= deadline_ms) return false;
    }
}

fn sleepMs(ms: u64) void {
    if (builtin.os.tag == .windows) return lib_posix.sleepMs(ms);
    const ts = std.c.timespec{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

pub const TerminalExit = union(enum) {
    detached,
    ended: i64,
    interrupted,
};

/// How an attach client leaves its terminal `t`: after a detach (no deadline) as upstream does. After a
/// session end the terminal gets until the reset's share of the deadline to take the output and the reset
/// the rest; what it has not taken by then is flushed, since TCSAFLUSH and, on macOS, the exit's close of
/// the tty wait for it. `t` restores termios with TCSAFLUSH when the output was taken.
pub fn leaveTerminal(t: anytype, exit: TerminalExit) void {
    const d = switch (exit) {
        .detached => {
            t.restoreTermios(true);
            t.writeReset(null);
            return;
        },
        .interrupted => {
            // A supervisor can signal an attach client and stop reading its PTY.
            // TCSAFLUSH would wait for the supervisor while it waits for us.
            const deadline = role.nowMs() + 100;
            t.flushOutput();
            t.restoreTermios(false);
            t.writeReset(deadline);
            if (!t.outputTakenBy(deadline)) t.flushOutput();
            return;
        },
        .ended => |deadline| deadline,
    };
    const taken = t.outputTakenBy(d - resetShare(t.out_fd));
    if (!taken) t.flushOutput();
    t.restoreTermios(taken);
    t.writeReset(d);
    if (!t.outputTakenBy(d)) t.flushOutput();
}

/// The attach client's own terminal, for leaveTerminal; `in_fd` is null when stdin is no terminal.
pub const Tty = struct {
    out_fd: i32,
    in_fd: ?i32,
    orig: *const cross.termios,
    reset: []const u8,

    /// Waits until the terminal has taken what was written to it, or the deadline passes, and says which.
    /// A stdout that is no terminal counts as taken.
    pub fn outputTakenBy(self: Tty, deadline_ms: i64) bool {
        return takenBy(self.out_fd, deadline_ms, ttyOutputQueued);
    }
    pub fn flushOutput(self: Tty) void {
        _ = cross.tcflush(self.out_fd, cross.TCOFLUSH);
    }
    pub fn restoreTermios(self: Tty, flushing: bool) void {
        const fd = self.in_fd orelse return;
        if (flushing) {
            _ = cross.tcsetattr(fd, cross.TCSAFLUSH, self.orig);
        } else {
            _ = cross.tcflush(fd, cross.TCIFLUSH);
            _ = cross.tcsetattr(fd, cross.TCSANOW, self.orig);
        }
    }
    pub fn writeReset(self: Tty, deadline_ms: ?i64) void {
        if (deadline_ms) |d| writeBy(self.out_fd, self.reset, d) else _ = lib_posix.write(self.out_fd, self.reset) catch {};
    }
};

/// Writes `bytes` to `fd`, nonblocking, giving up at `deadline_ms`.
pub fn writeBy(fd: i32, bytes: []const u8, deadline_ms: i64) void {
    const flags = lib_posix.fcntl(fd, lib_posix.F.GETFL, 0) catch return;
    _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK) catch return;
    defer _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags) catch {};
    var rest = bytes;
    while (rest.len > 0) {
        const n = lib_posix.write(fd, rest) catch |err| {
            if (err != error.WouldBlock) return;
            const left = deadline_ms - role.nowMs();
            if (left <= 0) return;
            var pfd = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.OUT, .revents = 0 }};
            _ = lib_posix.pollOrInterrupted(&pfd, @intCast(@min(left, CLOSE_BUDGET_MS))) catch return;
            continue;
        };
        rest = rest[n..];
    }
}

fn initTerminal(gpa: std.mem.Allocator, io: std.Io, size: ipc.Resize, cfg: *const Cfg) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(io, gpa, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_lines = cfg.max_scrollback_lines,
        .max_scrollback_bytes = null, // Let the line limit control scrollback.
    });
}

/// How long a daemon whose shell exited may spend delivering the output its clients have not read yet,
/// one deadline shared by all of them. A kill or SIGTERM ends it at once.
const EXIT_DRAIN_MS: i64 = 2000;

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, gpa: std.mem.Allocator, io: std.Io, server_sock_fd: lib_posix.socket_t, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });

    try signal.openSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 8);
    defer poll_fds.deinit(gpa);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try initTerminal(gpa, io, init_size, daemon.cfg);
    defer term.deinit(gpa);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    // Carries the tail of the previous PTY read so the task-exit marker
    // search below can see across a read() boundary. Sized to comfortably
    // hold "ZMX_TASK_COMPLETED:" (19 bytes) plus a u8 exit code and CRLF.
    var marker_carry: [32]u8 = undefined;
    var marker_carry_len: usize = 0;

    var had_terminal_client = daemon.hasTerminalClient();

    // set when the shell exits: the loop then only delivers what clients have not read, until none is left
    // or the deadline passes, and still serves them, so a kill ends it at once
    var drain_deadline: ?i64 = null;

    daemon_loop: while (daemon.running) {
        if (drain_deadline) |deadline| {
            if (!daemon.hasUnsentOutput()) break :daemon_loop;
            if (role.nowMs() >= deadline) {
                std.log.info("exit drain deadline passed with output unsent", .{});
                break :daemon_loop;
            }
        }
        const draining = drain_deadline != null;

        // If the program asked for focus reports (DECSET 1004), send focus-out
        // when the last attached client leaves and focus-in when one returns,
        // as a terminal would when its window loses/gains focus.
        const has_terminal_client = daemon.hasTerminalClient();
        if (has_terminal_client != had_terminal_client and term.modes.get(.focus_event)) {
            daemon.queuePtyInput(gpa, if (has_terminal_client) "\x1b[I" else "\x1b[O");
        }
        had_terminal_client = has_terminal_client;

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = server_sock_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        var pty_events: i16 = lib_posix.POLL.IN;
        if (daemon.pty_write_buf.items.len > 0) {
            pty_events |= lib_posix.POLL.OUT;
        }
        // the PTY of an exited shell reports a hangup on every poll
        try poll_fds.append(gpa, .{
            .fd = if (draining) -1 else pty_fd,
            .events = pty_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        for (daemon.clients.items) |client| {
            var events: i16 = lib_posix.POLL.IN;
            if (client.has_pending_output) {
                events |= lib_posix.POLL.OUT;
            }
            try poll_fds.append(gpa, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        const poll_timeout: i32 = if (drain_deadline) |deadline|
            @intCast(std.math.clamp(deadline - role.nowMs(), 0, EXIT_DRAIN_MS))
        else
            -1;
        _ = try lib_posix.poll(poll_fds.items, poll_timeout);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe() catch {};
            std.log.info(
                "SIGTERM received, shutting down gracefully session={s}",
                .{daemon.session_name},
            );
            break :daemon_loop;
        }

        if (poll_fds.items[0].revents & (lib_posix.POLL.ERR | lib_posix.POLL.HUP | lib_posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & lib_posix.POLL.IN != 0) {
            const client_fd = try lib_posix.accept(
                server_sock_fd,
                null,
                null,
                lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
            );
            const client = try gpa.create(Client);
            client.* = Client{
                .alloc = gpa,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(gpa),
                .write_buf = undefined,
            };
            // 64KB initial capacity lets ~15 broadcast cycles (N_TTY_BUF_SIZE reads
            // * header) accumulate before the first ArrayList growth. The write
            // buffer is userspace-only: it drains via POLLOUT to the client socket,
            // which has no corresponding kernel-imposed per-write limit.
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 65536);
            try daemon.clients.append(gpa, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY. Buffer is sized to N_TTY_BUF_SIZE (4096): the hard
            // kernel limit for the N_TTY line discipline. A larger buffer doesn't
            // help: each read() from a PTY master returns at most 4096 bytes
            // regardless of the userspace buffer size.
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    // what clients have not read yet is delivered, bounded, before shutdown frees it
                    daemon.child_exited = true;
                    drain_deadline = role.nowMs() + EXIT_DRAIN_MS;
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    vt_stream.nextSlice(buf[0..n]);
                    daemon.setPwd(&term);
                    daemon.has_pty_output = true;
                    daemon.screen_revision +%= 1;

                    // In run mode, scan output for exit code marker. The marker
                    // can straddle two PTY reads (more likely under a throttled
                    // scheduler, e.g. containers), so prepend the tail carried
                    // over from the previous read before searching.
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        var scan_buf: [marker_carry.len + buf.len]u8 = undefined;
                        @memcpy(scan_buf[0..marker_carry_len], marker_carry[0..marker_carry_len]);
                        @memcpy(scan_buf[marker_carry_len..][0..n], buf[0..n]);
                        const scan_len = marker_carry_len + n;

                        if (try util.findTaskExitMarker(scan_buf[0..scan_len], daemon.task_id)) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

                            std.log.info("task completed exit_code={d}", .{exit_code});

                            // Notify connected clients
                            for (daemon.clients.items) |c| {
                                ipc.appendMessage(gpa, &c.write_buf, .TaskComplete, &[_]u8{exit_code}) catch {};
                                c.has_pending_output = true;
                            }
                        }

                        marker_carry_len = @min(marker_carry.len, scan_len);
                        @memcpy(
                            marker_carry[0..marker_carry_len],
                            scan_buf[scan_len - marker_carry_len .. scan_len],
                        );
                    }

                    daemon.relayPtyOutput(gpa, buf[0..n]);
                }
            }
        }

        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            while (daemon.pty_write_buf.items.len > 0) {
                const n = lib_posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.warn("pty write failed: {s}", .{@errorName(err)});
                        daemon.pty_write_buf.clearRetainingCapacity();
                    }
                    break;
                };
                if (n == 0) break;
                daemon.pty_write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
            }
        }

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, sig_pipe, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 3
        const num_polled_clients = poll_fds.items.len - 3;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 3].revents;

            if (revents & lib_posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    // the shell is gone: no new attach, input or command, only a detach, a kill or Info
                    if (draining) switch (msg.header.tag) {
                        .Detach, .DetachAll, .Kill, .Info => {},
                        else => continue,
                    };
                    switch (msg.header.tag) {
                        .Input => try daemon.handleInput(gpa, client, msg.payload),
                        .Send => daemon.handleSend(gpa, msg.payload),
                        .Output => try daemon.handleOutput(gpa, msg.payload, &term, &vt_stream),
                        .Init => try daemon.handleInit(gpa, client, pty_fd, &term, msg.payload),
                        .Switch => try daemon.handleSwitch(gpa, msg.payload),
                        .Resize => try daemon.handleResize(gpa, client, pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(gpa, client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll(gpa);
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => try daemon.handleInfo(gpa, client, &term),
                        .LabelGet => try daemon.handleLabelGet(gpa, client),
                        .LabelSet => try daemon.handleLabelSet(gpa, client, msg.payload),
                        .LabelClear => try daemon.handleLabelClear(gpa, client),
                        .EnvGet => try daemon.handleEnvGet(gpa, client),
                        .EnvSet => try daemon.handleEnvSet(gpa, client, msg.payload),
                        .History => try daemon.handleHistory(gpa, client, &term, msg.payload),
                        .Capture => try daemon.handleCapture(gpa, client, &term, msg.payload),
                        .Run => try daemon.handleRun(gpa, io, client, msg.payload),
                        .Manage => daemon.handleManage(client, msg.payload),
                        .Identity => try daemon.handleIdentity(gpa, client, msg.payload),
                        .Type => try daemon.handleType(gpa, client, &term, msg.payload),
                        .Screen => try daemon.handleScreen(gpa, client, &term, msg.payload),
                        .Ack, .TaskComplete, .LabelData, .EnvData, .Role, .Unsupported => {},
                        .Write => try daemon.handleWrite(gpa, client, msg.payload),
                        _ => {
                            std.log.warn(
                                "ignoring unknown IPC tag={d}",
                                .{@backingInt(msg.header.tag)},
                            );
                            ipc.appendMessage(gpa, &client.write_buf, .Unsupported, "") catch {};
                            client.has_pending_output = true;
                        },
                    }
                }
            }

            if (revents & lib_posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = lib_posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) client.consumeWritten(gpa, n);

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                // A client that writes and exits (`zmx send`, `zmx run -d`) is
                // reported HUP with part of its message still unread: a pass
                // reads at most 4 KiB. Closing now drops the rest. Leave it to
                // the next pass, which reads on until EOF closes the client.
                if (revents & lib_posix.POLL.IN != 0 and
                    revents & (lib_posix.POLL.ERR | lib_posix.POLL.NVAL) == 0) continue;
                const last = daemon.closeClient(gpa, client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

const ClientResult = struct {
    kind: enum {
        detach,
        switch_session,
    },
    session_name: ?[]const u8,
    cwd: ?[]const u8 = null,
    /// set when the session ended; leaveTerminal takes it
    close_deadline_ms: ?i64 = null,
};

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    is_terminal: bool = false, // sent .Init (a `zmx attach`), not a run/send/tail client
    /// sent .Manage: leads only by claiming, never by typing, and is told its role
    managed: bool = false,
    claim_on_init: bool = false,
    /// the client's ZMX_MANAGED token, from Identity
    token: ?[]u8 = null,
    /// the token of an earlier attach whose lead this client takes back, from Identity
    reclaim_from: ?[]u8 = null,
    told_role: ?ipc.Role = null,
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),
    /// before Init: the bytes of the frame at the head of write_buf that a short write left unsent
    head_left: usize = 0,
    env_str: ?[]u8 = null,

    pub fn deinit(self: *Client, gpa: std.mem.Allocator) void {
        lib_posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
        if (self.env_str) |s| gpa.free(s);
        if (self.token) |s| gpa.free(s);
        if (self.reclaim_from) |s| gpa.free(s);
    }

    /// Drop `n` written bytes from write_buf. Before Init it also follows how much of the frame now at
    /// the head is unsent, so the first Init's clear can keep a frame the client is partway through.
    fn consumeWritten(self: *Client, gpa: std.mem.Allocator, n: usize) void {
        if (!self.is_terminal) {
            var rest = n;
            var off: usize = @min(rest, self.head_left);
            self.head_left -= off;
            rest -= off;
            while (rest > 0) {
                const header = std.mem.bytesToValue(ipc.Header, self.write_buf.items[off..][0..@sizeOf(ipc.Header)]);
                const frame = @sizeOf(ipc.Header) + header.len;
                if (rest < frame) {
                    self.head_left = frame - rest;
                    break;
                }
                rest -= frame;
                off += frame;
            }
        }
        self.write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
    }

    fn setEnv(self: *Client, gpa: std.mem.Allocator, env_str: []const u8) !void {
        if (self.env_str) |s| gpa.free(s);
        self.env_str = if (env_str.len > 0) try gpa.dupe(u8, env_str) else null;
    }
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
pub const Daemon = struct {
    cfg: *Cfg,
    session_name: []const u8,
    socket_path: []const u8,
    // === opt ===
    pty_write_buf: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    labels: std.StringHashMapUnmanaged([]u8) = .empty,
    // This control which client is the leader.  The leader controls terminal state and
    // cols/rows of session.
    leader_client_fd: ?i32 = null,
    /// bumped on every leadership change, carried in each RoleChange
    leader_generation: u32 = 0,
    /// the leader took a vacant session without claiming and has not typed, pasted or clicked since,
    /// so a client taking back a lead it lost with its link may have it
    leader_idle: bool = false,
    /// bumped on every pty read, resize and injected output, carried in each ScreenHeader
    screen_revision: u64 = 0,
    running: bool = true,
    /// set when the pty reached EOF because the shell exited, as opposed to a kill
    child_exited: bool = false,
    pid: i32 = undefined,
    command: ?[]const []const u8 = null,
    /// The session's working directory in OSC 7 form, `file://<host><path>`.
    /// Kept as a URI rather than a path so `zmx list` shows the host, which is
    /// what tells you a session is inside SSH. Points into `cwd_buf` once set,
    /// so a Daemon must not be copied by value after that.
    cwd: []const u8 = "",
    /// The same directory as a path that can be opened: percent-decoding
    /// applied, scheme and host stripped. Empty when the cwd is on another
    /// host, since then it names no directory here and nothing should chdir
    /// into it. Points into `cwd_path_buf`.
    cwd_path: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    has_pty_output: bool = false,
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_id: [4]u8 = undefined,
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    pty_fd: i32 = -1, // set by daemonLoop so handleRun can probe the foreground process
    shell: []const u8 = "/bin/sh",
    quiet: bool = false,

    /// Create a Daemon. Caller is responsible for freeing all variables passed
    /// into the init fn.
    pub fn init(io: std.Io, cfg: *Cfg, sesh_name: []const u8, socket_path: []const u8) Daemon {
        return .{
            .cfg = cfg,
            .session_name = sesh_name,
            .socket_path = socket_path,
            .created_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        };
    }

    pub fn deinit(self: *Daemon, gpa: std.mem.Allocator) void {
        self.clients.deinit(gpa);
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.deinit(gpa);
        self.pty_write_buf.deinit(gpa);
    }

    pub fn shutdown(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("shutting down daemon session={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit(gpa);
            gpa.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    /// Resize the daemon's terminal with prompt_redraw disabled. On resize the
    /// terminal would clear prompt lines expecting the shell to redraw them,
    /// but the shell's redraw goes to the PTY (forwarded to clients), not to
    /// this terminal, so the clearing only corrupts our snapshot state.
    fn resizeTerm(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal, cols: u16, rows: u16) !void {
        const saved = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved;
        try term.resize(gpa, .{ .cols = cols, .rows = rows });
    }

    /// True while a client that sent .Init (a real `zmx attach`) is connected.
    fn hasTerminalClient(self: *const Daemon) bool {
        for (self.clients.items) |c| {
            if (c.is_terminal) return true;
        }
        return false;
    }

    /// True while any client has output queued that it has not been sent.
    fn hasUnsentOutput(self: *const Daemon) bool {
        for (self.clients.items) |c| {
            if (c.write_buf.items.len > 0) return true;
        }
        return false;
    }

    pub fn closeClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        // leader is disconnected, remove ref and let another client claim leader on input
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info(
                "unsetting leader session={s} fd={d}",
                .{ self.session_name, client.socket_fd },
            );
            self.leader_client_fd = null;
            self.leader_generation +%= 1;
        }
        client.deinit(gpa);
        gpa.destroy(client);
        _ = self.clients.orderedRemove(i);
        self.notifyRoles(gpa);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown(gpa);
            return true;
        }
        return false;
    }

    /// ensureSession will either create or re-use the daemon used for a session.
    /// It will spin up a unix socket, double-fork the process (so it survives
    /// the terminal dying), and automatically attach the client to the ipc unix
    /// socket.
    ///
    /// The return bool value indicates if the current process is the daemon
    /// or the client since they have different behaviors post-fork.
    ///
    /// E.g. If it's the client process then we need to connect to the unix socket
    /// and run the clientLoop.  If it's the daemon then we need to bail since
    /// the daemonLoop is created inside this fn and when it returns that means
    /// the daemon stopped and needs to exit.
    pub fn ensureSession(self: *Daemon, io: std.Io) !bool {
        const sesh_name = self.session_name;
        std.log.info("ensure session session={s}", .{sesh_name});
        var dir = try std.Io.Dir.openDirAbsolute(io, self.cfg.socket_dir, .{});
        defer dir.close(io);

        const exists = try socket.sessionExists(io, dir, sesh_name);
        // if daemon is gone then we flip this to true
        var should_create = !exists;

        if (exists) {
            if (ipc.connectSession(self.socket_path)) |fd| {
                lib_posix.close(fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session={s}",
                        .{sesh_name},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(io, dir, sesh_name);
                    should_create = true;
                },
                // Connect failed for an unusual reason. The check is only to
                // decide create-vs-attach; the socket file exists, so proceed
                // to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "connect failed ({s}), proceeding to attach session={s}",
                        .{ @errorName(err), sesh_name },
                    );
                },
            }
        }

        if (!should_create) {
            return false;
        }

        return self.run(io, dir, sesh_name);
    }

    fn run(self: *Daemon, io: std.Io, dir: std.Io.Dir, sesh_name: []const u8) !bool {
        std.log.info("creating session={s}", .{sesh_name});
        // a Windows client starts the daemon as its own process, which creates the socket itself
        const win_client = builtin.os.tag == .windows and daemonize.win.child == null;
        if (win_client) daemonize.win.task_mode = self.is_task_mode;
        const server_sock_fd: lib_posix.socket_t = if (win_client) -1 else try socket.createSocket(self.socket_path);
        const log_fd = if (builtin.os.tag == .windows) -1 else if (log.log_system.file) |f| f.handle else -1;

        var keep_fds_open = [_]i32{ server_sock_fd, if (builtin.os.tag == .windows) -1 else dir.handle, log_fd };
        const cmd = try daemonize.createCmdZ(self.shell, self.is_task_mode, self.command);

        // `cwd_path` is the decoded path, and is empty when the cwd is on
        // another host: OSC 7 crosses SSH boundaries, so a session that ssh'd
        // elsewhere reports a directory that does not exist on this machine.
        std.log.info("checking pwd={s} path={s}", .{ self.cwd, self.cwd_path });
        if (self.cwd_path.len > 0) {
            const pwd_dir = std.Io.Dir.openDirAbsolute(io, self.cwd_path, .{}) catch |err| blk: {
                std.log.warn("failed to open dir={s} err={s}", .{ self.cwd_path, @errorName(err) });
                break :blk null;
            };
            if (pwd_dir) |pdir| {
                defer std.Io.Dir.close(pdir, io);
                std.log.info("set directory dir={s}", .{self.cwd_path});
                try std.process.setCurrentDir(io, pdir);
            }
        }

        const pty_info = daemonize.daemonize(
            sesh_name,
            cmd,
            &keep_fds_open,
        ) catch |err| {
            switch (err) {
                error.IsClientProc => {
                    // send a msg to the client that the session was created.
                    if (!self.quiet) {
                        var w_buf: [2048]u8 = undefined;
                        var w = std.Io.File.stdout().writer(io, &w_buf);
                        try w.interface.print("session \"{s}\" created\n", .{sesh_name});
                        try w.interface.flush();
                    }
                    lib_posix.close(server_sock_fd);
                    return false;
                },
                else => {
                    lib_posix.close(server_sock_fd);
                    // the socket is the daemon's when the client did not create it
                    if (!win_client) dir.deleteFile(io, self.session_name) catch {};
                    return err;
                },
            }
        };
        // =======
        // WARNING: cannot use upstream allocator or io after this point since
        // we forked the process and there's a risk of a mutex (e.g. thread-safe
        // allocator) being locked by a thread prior to fork which can cause a
        // deadlock.
        // =======

        self.pid = pty_info.pid;

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const new_io = threaded.io();

        { // re-initialize logs with the session name as the filename
            log.log_system.deinit();
            var log_buf: [4096]u8 = undefined;
            const session_log_name = try std.fmt.bufPrint(
                &log_buf,
                "{s}.log",
                .{sesh_name},
            );
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const session_log_path = try std.fs.path.join(
                fba.allocator(),
                &.{ self.cfg.log_dir, session_log_name },
            );
            const log_mode = @import("sys.zig").permissions(self.cfg.log_mode);
            log.log_system.init(new_io, session_log_path, log_mode) catch {};
        }

        const gpa: std.mem.Allocator = blk: {
            if (builtin.mode == .debug) {
                const GPA = std.heap.DebugAllocator(.{});
                const Static = struct {
                    var gpa: GPA = .{};
                };
                break :blk Static.gpa.allocator();
            }
            break :blk std.heap.c_allocator;
        };

        defer {
            // a shell that exited is recorded before the socket goes, so a
            // supervisor that finds the session gone without a record knows
            // it was killed rather than exited
            if (self.child_exited) exit_record.write();
            // Close and unlink the listen socket BEFORE handleKill()'s
            // 500ms SIGHUP->SIGKILL grace sleep. Otherwise a `zmx run`
            // for the same name issued in that window will hang waiting
            // for a connect.
            lib_posix.close(server_sock_fd);
            std.log.info("deleting socket file session={s}", .{sesh_name});
            dir.deleteFile(new_io, sesh_name) catch |err| {
                std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
            };
            self.handleKill(gpa, new_io);
            self.deinit(gpa);
            lib_posix.close(pty_info.master_fd);
            _ = lib_posix.waitpid(self.pid, 0);
        }

        try daemonLoop(self, gpa, new_io, server_sock_fd, pty_info.master_fd);
        std.log.info("daemon loop shutdown", .{});
        return true;
    }

    fn setLeader(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        self.leader_idle = false;
        self.leader_generation +%= 1;
        // Send a resize message to the client so it can send us back their window size
        // so we can resize the pty and ghostty state.
        try ipc.appendMessage(gpa, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
        self.notifyRoles(gpa);
    }

    fn roleOf(self: *const Daemon, client: *const Client) ipc.Role {
        const leader = self.leader_client_fd orelse return .unowned;
        return if (leader == client.socket_fd) .leader else .follower;
    }

    /// Tell every managed terminal client whose role differs from the last one it was told.
    fn notifyRoles(self: *Daemon, gpa: std.mem.Allocator) void {
        for (self.clients.items) |client| {
            if (!client.managed or !client.is_terminal) continue;
            const current = self.roleOf(client);
            if (client.told_role == current) continue;
            client.told_role = current;
            // zeroes() so asBytes() ships no struct padding
            var change = std.mem.zeroes(ipc.RoleChange);
            change.generation = self.leader_generation;
            change.role = current;
            ipc.appendMessage(gpa, &client.write_buf, .Role, std.mem.asBytes(&change)) catch |err| {
                std.log.warn("failed to buffer role for client err={s}", .{@errorName(err)});
                client.told_role = null;
                continue;
            };
            client.has_pending_output = true;
        }
    }

    pub fn handleManage(self: *Daemon, client: *Client, payload: []const u8) void {
        _ = self;
        if (payload.len != @sizeOf(ipc.ManageFlags)) return;
        const flags = std.mem.bytesToValue(ipc.ManageFlags, payload);
        client.managed = true;
        client.claim_on_init = flags.claim;
    }

    pub fn handleIdentity(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        _ = self;
        if (!client.managed) return;
        var parts = std.mem.splitScalar(u8, payload, '\n');
        const token = parts.first();
        if (!role.isNonce(token)) return;
        const from = parts.next();
        if (from != null and !role.isNonce(from.?)) return;
        if (client.token) |s| gpa.free(s);
        if (client.reclaim_from) |s| gpa.free(s);
        client.reclaim_from = null;
        client.token = try gpa.dupe(u8, token);
        if (from) |f| client.reclaim_from = try gpa.dupe(u8, f);
    }

    /// Whether `client`, taking back a lead it lost with its link, may have it now: its own earlier
    /// attach still leads, or the leader only filled the vacancy and has not been used since.
    fn yieldsTo(self: *Daemon, client: *const Client) bool {
        const from = client.reclaim_from orelse return false;
        const leader = self.getLeaderClient() orelse return false;
        if (self.leader_idle) return true;
        const token = leader.token orelse return false;
        return std.mem.eql(u8, token, from);
    }

    /// Queue automation bytes without touching leadership, and say whether they were queued.
    pub fn handleType(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *const ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        const keys = terminal.encodeTyped(gpa, term, payload) catch |err| {
            std.log.warn("failed to encode typed input err={s}", .{@errorName(err)});
            try ipc.appendMessage(gpa, &client.write_buf, .Type, &[_]u8{@backingInt(ipc.TypeResult.rejected)});
            client.has_pending_output = true;
            return;
        };
        defer gpa.free(keys);
        const fits = keys.len > 0 and self.pty_write_buf.items.len + keys.len <= PTY_WRITE_BUF_MAX;
        if (fits) self.queuePtyInput(gpa, keys);
        const result: ipc.TypeResult = if (fits) .accepted else .rejected;
        try ipc.appendMessage(gpa, &client.write_buf, .Type, &[_]u8{@backingInt(result)});
        client.has_pending_output = true;
    }

    fn getLeaderClient(self: *Daemon) ?*Client {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                return client;
            }
        }
        return null;
    }

    /// relayPtyOutput answers DA queries while no terminal client is attached, then broadcasts the rest of `data`.
    fn relayPtyOutput(self: *Daemon, gpa: std.mem.Allocator, data: []u8) void {
        // until a client sends Init the daemon answers for the terminal, so fish never waits 10 s; an attach
        // that has not sent Init yet still receives output, and would answer a forwarded query a second time
        var output = data;
        if (!self.hasTerminalClient() and self.pty_write_buf.items.len < PTY_WRITE_BUF_MAX) {
            output = util.respondToDeviceAttributes(gpa, &self.pty_write_buf, data);
        }
        if (output.len == 0) return;

        // redraw=0 keeps the outer terminal from clearing prompt lines on resize (issue #111)
        const broadcast_data = util.rewritePromptRedraw(gpa, output) orelse output;
        defer if (broadcast_data.ptr != output.ptr) gpa.free(broadcast_data);
        for (self.clients.items) |client| {
            ipc.appendMessage(gpa, &client.write_buf, .Output, broadcast_data) catch |err| {
                std.log.warn(
                    "failed to buffer output for client err={s}",
                    .{@errorName(err)},
                );
                continue;
            };
            client.has_pending_output = true;
        }
    }

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, gpa: std.mem.Allocator, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return;
        }

        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{data});

        self.pty_write_buf.appendSlice(gpa, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
        };
    }

    pub fn handleInput(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{payload});

        // client is leader, send entire payload (ansi escape codes + text)
        if (self.leader_client_fd == client.socket_fd) {
            if (self.leader_idle and util.isLeaderUse(payload)) self.leader_idle = false;
            self.queuePtyInput(gpa, payload);
            return;
        }

        // a managed client leads only by claiming: what it sends while following is its terminal
        // answering queries, or a person typing at a pane that is covered
        if (client.managed) return;

        // check if leader needs to be updated by detecting any user input
        if (util.isUserInput(payload)) {
            try self.setLeader(gpa, client);
            self.queuePtyInput(gpa, payload);
        }
    }

    /// Queue input from `zmx send` without changing interactive client leadership.
    pub fn handleSend(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8) void {
        self.queuePtyInput(gpa, payload);
    }

    pub fn handleSwitch(self: *Daemon, gpa: std.mem.Allocator, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                // a managed client's terminal is bound to THIS session: its token, its role generation
                // and what it reads and types through `screen` and `type` all name it, so moving the
                // client to another daemon would leave every one of them pointing at the wrong session
                if (client.managed) {
                    std.log.info("ignoring switch to {s}: the leader is a managed client", .{session_name});
                    return;
                }
                // Include the daemon's current cwd so the new session can start
                // in the right directory. A remote cwd is left out: it names no
                // directory here, so the new session is better off with the
                // attaching client's own cwd than with a path it cannot enter.
                if (self.cwd.len > 0 and self.cwd_path.len > 0) {
                    var payload = gpa.alloc(u8, session_name.len + 1 + self.cwd.len) catch return;
                    defer gpa.free(payload);
                    @memcpy(payload[0..session_name.len], session_name);
                    payload[session_name.len] = '\n';
                    @memcpy(payload[session_name.len + 1 ..], self.cwd);
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, payload) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                } else {
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, session_name) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                }
                client.has_pending_output = true;
                return;
            }
        }
    }

    pub fn handleInit(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        if (!client.is_terminal) {
            // dropping the tail of a partly sent frame would make the client read the next frame inside it
            client.write_buf.shrinkRetainingCapacity(client.head_left);
            client.has_pending_output = client.head_left > 0;
            client.head_left = 0;
        }
        client.is_terminal = true;

        const vacant = self.leader_client_fd == null;
        if (vacant or client.claim_on_init or self.yieldsTo(client)) {
            try self.setLeader(gpa, client);
            self.leader_idle = vacant and !client.claim_on_init and client.reclaim_from == null;
        }
        // ahead of the snapshot below, so a managed client learns its role before any output
        self.notifyRoles(gpa);
        const is_leader = self.leader_client_fd == client.socket_fd;
        const resize = std.mem.bytesToValue(ipc.Resize, payload);

        // Resize our terminal (not yet the PTY) to the leader's size before
        // serializing, so the snapshot is laid out for the width the client
        // will render it at instead of being wrapped a second time on arrival.
        // Cursor position stays consistent because it is serialized from the
        // same, already-resized terminal; the PTY is resized below, so the
        // shell's own SIGWINCH redraw still arrives after the snapshot.
        if (is_leader) {
            try resizeTerm(gpa, term, resize.cols, resize.rows);
            self.screen_revision +%= 1;
        }

        if (self.has_pty_output) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (terminal.serializeTerminalState(gpa, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                // does not clear prompt lines on resize (issue #111).
                const restore_data = util.rewritePromptRedraw(gpa, term_output) orelse term_output;
                defer gpa.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) gpa.free(restore_data);
                ipc.appendMessage(gpa, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        // only resize if leader
        if (is_leader) {
            var ws = resize.winsize();
            _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);

            // On re-attach, deliver SIGWINCH to the foreground process group so
            // incremental renderers (Ink, Claude Code, etc.) know to repaint.
            // If the size changed, TIOCSWINSZ above already sent SIGWINCH; if the size
            // was unchanged, the kernel suppressed it, so signal the pgrp explicitly.
            if (self.has_pty_output) {
                var pgrp: lib_posix.pid_t = 0;
                if (cross.ioctl(pty_fd, cross.TIOCGPGRP, &pgrp) == 0 and pgrp > 0) {
                    lib_posix.kill(-pgrp, .WINCH) catch {};
                }
            }

            std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
        }
    }

    pub fn handleResize(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        // a managed client's window changing size is not a claim
        if (self.leader_client_fd == null and !client.managed) {
            try self.setLeader(gpa, client);
        }
        // only leader can resize
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws = resize.winsize();
        _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);
        try resizeTerm(gpa, term, resize.cols, resize.rows);
        self.screen_revision +%= 1;
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize) void {
        std.log.info("client detach session={s} fd={d}", .{ self.session_name, client.socket_fd });
        _ = self.closeClient(gpa, client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        // Go through closeClient so the leader is cleared like any other detach.
        while (self.clients.items.len > 0) {
            const last = self.clients.items.len - 1;
            _ = self.closeClient(gpa, self.clients.items[last], last, false);
        }
    }

    pub fn handleKill(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown(gpa);
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session={s} pid={d}", .{ self.session_name, self.pid });
        lib_posix.kill(-self.pid, lib_posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real) catch unreachable;
        lib_posix.kill(-self.pid, lib_posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
        self.setPwd(term);

        // zeroes() so asBytes() doesn't ship struct padding + unused cmd/cwd
        // tail bytes (daemon stack contents) to clients.
        var info = std.mem.zeroes(ipc.Info);
        info.protocol_version = ipc.PROTOCOL_VERSION;
        info.clients_len = self.clients.items.len - 1;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(gpa, arg) catch null
                else
                    null;
                defer if (quoted) |q| gpa.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (info.cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (info.cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(info.cmd[info.cmd_len..][0..ellipsis.len], ellipsis);
                        info.cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    info.cmd[info.cmd_len] = ' ';
                    info.cmd_len += 1;
                }
                @memcpy(info.cmd[info.cmd_len..][0..src.len], src);
                info.cmd_len += @intCast(src.len);
            }
        }

        info.cwd_len = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(info.cwd[0..info.cwd_len], self.cwd[0..info.cwd_len]);

        try ipc.appendMessage(gpa, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        self.setPwd(term);
        const format: util.HistoryFormat = if (payload.len > 0)
            @fromBackingInt(@intCast(payload[0]))
        else
            .plain;
        if (terminal.serializeTerminal(gpa, term, format)) |output| {
            defer gpa.free(output);
            try ipc.appendMessage(gpa, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(gpa, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleCapture(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Capture)) return;
        const request = std.mem.bytesToValue(ipc.Capture, payload);
        const format = std.enums.fromInt(util.HistoryFormat, request.format) orelse return;
        self.setPwd(term);
        const output = terminal.serializeTerminalRange(gpa, term, format, request.rows);
        defer if (output) |text| gpa.free(text);
        try ipc.appendMessage(gpa, &client.write_buf, .Capture, output orelse "");
        client.has_pending_output = true;
    }

    /// Read the daemon terminal using the current leader's layout.
    pub fn handleScreen(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        defer client.has_pending_output = true;
        const mode: ipc.ScreenMode = if (payload.len == 1) @fromBackingInt(@intCast(payload[0])) else .active;
        const all = switch (mode) {
            .active => false,
            .all => true,
            _ => return ipc.appendMessage(gpa, &client.write_buf, .Screen, ""),
        };
        const text = terminal.serializeScreenText(gpa, term, all) catch |err| {
            std.log.warn("failed to read screen err={s}", .{@errorName(err)});
            return ipc.appendMessage(gpa, &client.write_buf, .Screen, "");
        };
        defer gpa.free(text);

        const screen = term.screens.active;
        // zeroes() so asBytes() ships no struct padding
        var header = std.mem.zeroes(ipc.ScreenHeader);
        header.revision = self.screen_revision;
        header.cols = @intCast(term.cols);
        header.rows = @intCast(term.rows);
        header.cursor_x = @intCast(screen.cursor.x);
        header.cursor_y = @intCast(screen.cursor.y);
        header.alternate = @intFromBool(term.screens.active_key == .alternate);
        var reply = try std.ArrayList(u8).initCapacity(gpa, @sizeOf(ipc.ScreenHeader) + text.len);
        defer reply.deinit(gpa);
        reply.appendSliceAssumeCapacity(std.mem.asBytes(&header));
        reply.appendSliceAssumeCapacity(text);
        try ipc.appendMessage(gpa, &client.write_buf, .Screen, reply.items);
    }

    /// The program the session's shell runs: the session's command, or the shell it started.
    fn sessionShell(self: *const Daemon) []const u8 {
        if (self.command) |c| if (c.len > 0) return c[0];
        return self.shell;
    }

    pub fn handleRun(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;
        self.task_id = util.generateTaskId(io);

        if (payload.len == 0) return;

        const cmd = payload;

        // Chain the exit marker with `;` on the same line. `$?` captures the
        // exit code of the command (not the `;`). The sole exception is when
        // the command contains a heredoc (`<<`), the delimiter must be alone
        // on its line, so the marker goes on the next line instead.
        var buf: [1024]u8 = undefined;
        const marker = try util.getTaskExitMarker(&buf, self.task_id);
        var marker_buf: [1024]u8 = undefined;
        const shell_kind = util.ShellKind.of(self.sessionShell());
        const marker_line = try util.taskMarkerLine(&marker_buf, shell_kind, marker, cmd);

        // a failed cmdlet leaves $LASTEXITCODE as the last native program set it, so it starts at 0
        if (shell_kind == .powershell) self.queuePtyInput(gpa, "$global:LASTEXITCODE = 0; ");
        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(gpa, cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(gpa, cmd);
        }
        self.queuePtyInput(gpa, marker_line);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug("run command len={d}", .{payload.len});
    }

    /// Store the session's working directory as a plain path.
    ///
    /// Accepts either an OSC 7 value (`file://<host><path>`, percent-encoded)
    /// or a path. Decoding here rather than at each use keeps `zmx list`
    /// printing a path and lets the chdir on session create find directories
    /// whose names needed escaping.
    ///
    /// The value is copied, so callers may pass a temporary.
    pub fn setCwd(self: *Daemon, value: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var host_buf: [@import("sys.zig").HOST_NAME_MAX]u8 = undefined;
        const hostname = @import("sys.zig").gethostname(&host_buf) catch "";
        const cwd = util.parseOsc7Cwd(&buf, value, hostname) orelse {
            std.log.warn("ignoring unusable cwd={s}", .{value});
            return;
        };

        // Store the URI form. A caller that handed us a plain path gets one
        // built here, so `cwd` has the same shape no matter the source. A value
        // that already was a URI is kept verbatim, so `list` shows what the
        // shell actually reported.
        self.cwd = if (std.fs.path.isAbsolute(value))
            util.toOsc7Cwd(&self.cwd_buf, value, hostname) orelse return
        else blk: {
            if (value.len > self.cwd_buf.len) return;
            @memcpy(self.cwd_buf[0..value.len], value);
            break :blk self.cwd_buf[0..value.len];
        };

        // Only keep an openable path when it names a directory on this host.
        if (cwd.is_local and cwd.path.len <= self.cwd_path_buf.len) {
            @memcpy(self.cwd_path_buf[0..cwd.path.len], cwd.path);
            self.cwd_path = self.cwd_path_buf[0..cwd.path.len];
        } else {
            self.cwd_path = "";
        }
        std.log.info("set cwd={s} path={s}", .{ self.cwd, self.cwd_path });
    }

    fn setPwd(self: *Daemon, term: *ghostty_vt.Terminal) void {
        const pwd = term.getPwd() orelse return;
        if (std.mem.eql(u8, self.cwd, pwd)) return;
        self.setCwd(pwd);
    }

    pub fn handleOutput(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8, term: *ghostty_vt.Terminal, vt_stream: anytype) !void {
        vt_stream.nextSlice(payload);
        self.setPwd(term);
        self.has_pty_output = true;
        self.screen_revision +%= 1;
        for (self.clients.items) |client| {
            try ipc.appendMessage(gpa, &client.write_buf, .Output, payload);
            client.has_pending_output = true;
        }
        if (self.clients.items.len > 0) {
            lib_posix.kill(self.pid, lib_posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        // The commands skip queuePtyInput's cap: it would drop the chunks
        // past PTY_WRITE_BUF_MAX and leave the file cut short. The payload
        // is already bounded by ipc.MAX_PAYLOAD_LEN.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try gpa.alloc(u8, encoded_len);
            defer gpa.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            try self.pty_write_buf.appendSlice(gpa, "printf '%s' '");
            try self.pty_write_buf.appendSlice(gpa, encoded);
            if (is_first) {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d > '");
            } else {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d >> '");
            }
            try self.pty_write_buf.appendSlice(gpa, file_path);
            try self.pty_write_buf.appendSlice(gpa, "'");
            try self.pty_write_buf.appendSlice(gpa, "\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug(
            "write command len={d} file_path={s}",
            .{ file_content.len, file_path },
        );
    }

    fn handleEnvGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const leader_opt = self.getLeaderClient();
        const payload = if (leader_opt) |leader| leader.env_str orelse "" else "";
        try ipc.appendMessage(gpa, &client.write_buf, .EnvData, payload);
        client.has_pending_output = true;
    }

    fn handleEnvSet(_: *Daemon, gpa: std.mem.Allocator, client: *Client, env_str: []const u8) !void {
        std.log.info("handle env set payload={s}", .{env_str});
        try client.setEnv(gpa, env_str);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const out = try label.labelsToU8(gpa, self.labels);
        defer gpa.free(out);
        try ipc.appendMessage(gpa, &client.write_buf, .LabelData, out);
        client.has_pending_output = true;
    }

    fn handleLabelSet(self: *Daemon, gpa: std.mem.Allocator, client: *Client, labels: []const u8) !void {
        std.log.info("handle label set payload={s}", .{labels});

        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            if (kv.value.len == 0) {
                if (self.labels.fetchRemove(kv.key)) |existing| {
                    gpa.free(existing.key);
                    gpa.free(existing.value);
                }
                continue;
            }

            const owned_key = try gpa.dupe(u8, kv.key);
            errdefer gpa.free(owned_key);
            const owned_value = try gpa.dupe(u8, kv.value);
            errdefer gpa.free(owned_value);
            if (try self.labels.fetchPut(gpa, owned_key, owned_value)) |existing| {
                // fetchPut does NOT replace the key in the map, the old
                // key pointer stays. So free the new (unused) key and the
                // old value.
                gpa.free(owned_key);
                gpa.free(existing.value);
            }
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelClear(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.clearRetainingCapacity();
        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }
};

test "daemon deinit leaves the caller-owned socket path intact" {
    var cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var socket_path = "/tmp/zmx-test/socket".*;
    var daemon = Daemon.init(std.testing.io, &cfg, "test", &socket_path);

    daemon.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/tmp/zmx-test/socket", &socket_path);
}

test "terminal retains the configured scrollback without the default byte cap" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("first line\r\n");
    for (1..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");

    const history = terminal.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(history);
    try std.testing.expect(std.mem.startsWith(u8, history, "first line\n"));

    // Exceed the limit comfortably because Ghostty prunes whole pages.
    for (0..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");
    stream.nextSlice("latest line\r\n");

    const pruned_history = terminal.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(pruned_history);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "first line") == null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "latest line") != null);
}

fn testDaemon() Daemon {
    return .{
        .cfg = undefined,
        .clients = .empty,
        .leader_client_fd = null,
        .session_name = "test",
        .socket_path = "",
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
}

fn testClient(alloc: std.mem.Allocator, fd: i32, is_terminal: bool) !*Client {
    const c = try alloc.create(Client);
    c.* = .{ .alloc = alloc, .socket_fd = fd, .read_buf = try ipc.SocketBuffer.init(alloc), .write_buf = .empty };
    c.is_terminal = is_terminal;
    return c;
}

test "hasTerminalClient follows attach, detach and detach-all" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    // Real fds (pipes) so Client.deinit's close() is legal.
    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});

    try std.testing.expect(!daemon.hasTerminalClient());

    // A run/send/tail client doesn't count.
    const tail_client = try testClient(alloc, a[0], false);
    try daemon.clients.append(alloc, tail_client);
    try std.testing.expect(!daemon.hasTerminalClient());

    // An attach client does, until it disconnects.
    const term_client = try testClient(alloc, a[1], true);
    try daemon.clients.append(alloc, term_client);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, tail_client, 0, false);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, term_client, 0, false);
    try std.testing.expect(!daemon.hasTerminalClient());

    try daemon.clients.append(alloc, try testClient(alloc, b[0], true));
    try daemon.clients.append(alloc, try testClient(alloc, b[1], true));
    daemon.handleDetachAll(alloc);
    try std.testing.expect(!daemon.hasTerminalClient());
    try std.testing.expectEqual(@as(?i32, null), daemon.leader_client_fd);
}

fn queuedOutput(client: *const Client, out: []u8) []const u8 {
    var len: usize = 0;
    var rest: []const u8 = client.write_buf.items;
    while (rest.len >= @sizeOf(ipc.Header)) {
        const header = std.mem.bytesToValue(ipc.Header, rest[0..@sizeOf(ipc.Header)]);
        const body = rest[@sizeOf(ipc.Header)..][0..header.len];
        if (header.tag == .Output) {
            @memcpy(out[len..][0..body.len], body);
            len += body.len;
        }
        rest = rest[@sizeOf(ipc.Header) + header.len ..];
    }
    return out[0..len];
}

// regression: the creation attach's terminal answered a DA query the daemon had already answered before its Init
test "a DA query the daemon answers is not forwarded until a client sent Init" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    const fds = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds[1]);
    const client = try testClient(alloc, fds[0], false);
    try daemon.clients.append(alloc, client);
    defer _ = daemon.closeClient(alloc, client, 0, false);
    var seen: [256]u8 = undefined;

    var read1 = "a\x1b[cb\x1b[>0c\x1b[?62;22cz\x1b[".*;
    daemon.relayPtyOutput(alloc, &read1);
    try std.testing.expectEqualStrings("\x1b[?62;22c\x1b[>1;10;0c", daemon.pty_write_buf.items);
    try std.testing.expectEqualStrings("ab\x1b[?62;22cz\x1b[", queuedOutput(client, &seen));

    var read2 = "c".*;
    daemon.relayPtyOutput(alloc, &read2);
    try std.testing.expectEqualStrings("\x1b[?62;22c\x1b[>1;10;0c", daemon.pty_write_buf.items);
    try std.testing.expectEqualStrings("ab\x1b[?62;22cz\x1b[c", queuedOutput(client, &seen));

    var read3 = "\x1b[c".*;
    daemon.relayPtyOutput(alloc, &read3);
    try std.testing.expectEqualStrings("ab\x1b[?62;22cz\x1b[c", queuedOutput(client, &seen));

    client.is_terminal = true;
    daemon.pty_write_buf.clearRetainingCapacity();
    var read4 = "x\x1b[cy".*;
    daemon.relayPtyOutput(alloc, &read4);
    try std.testing.expectEqualStrings("", daemon.pty_write_buf.items);
    try std.testing.expectEqualStrings("ab\x1b[?62;22cz\x1b[cx\x1b[cy", queuedOutput(client, &seen));
}

test "send queues PTY input without changing leader" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    daemon.leader_client_fd = 42;
    defer daemon.pty_write_buf.deinit(alloc);

    daemon.handleSend(alloc, "hello");

    try std.testing.expectEqual(@as(?i32, 42), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("hello", daemon.pty_write_buf.items);
}

/// The last RoleChange queued for `client`, and how many were queued.
fn queuedRoles(client: *const Client) struct { last: ?ipc.RoleChange, count: usize } {
    var last: ?ipc.RoleChange = null;
    var count: usize = 0;
    var rest: []const u8 = client.write_buf.items;
    while (rest.len >= @sizeOf(ipc.Header)) {
        const header = std.mem.bytesToValue(ipc.Header, rest[0..@sizeOf(ipc.Header)]);
        const body = rest[@sizeOf(ipc.Header)..][0..header.len];
        if (header.tag == .Role) {
            last = std.mem.bytesToValue(ipc.RoleChange, body);
            count += 1;
        }
        rest = rest[@sizeOf(ipc.Header) + header.len ..];
    }
    return .{ .last = last, .count = count };
}

test "the first Init keeps a partly sent frame and drops the frames not yet sent" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    defer lib_posix.close(a[1]);
    const c = try lib_posix.pipe2(.{});
    defer lib_posix.close(c[1]);
    defer lib_posix.close(c[0]);

    const client = try testManaged(alloc, &daemon, a[0], false);
    try ipc.appendMessage(alloc, &client.write_buf, .Output, "partly-sent");
    try ipc.appendMessage(alloc, &client.write_buf, .Output, "never-sent");
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(alloc);
    const into_header = @sizeOf(ipc.Header) - 3;
    const into_payload = @sizeOf(ipc.Header) + 4 - into_header;
    for ([_]usize{ into_header, into_payload }) |n| {
        try wire.appendSlice(alloc, client.write_buf.items[0..n]);
        client.consumeWritten(alloc, n);
    }
    try daemon.handleInit(alloc, client, c[0], &term, std.mem.asBytes(&ipc.Resize{ .rows = 24, .cols = 80 }));
    try std.testing.expect(client.has_pending_output);
    try wire.appendSlice(alloc, client.write_buf.items);

    var rest: []const u8 = wire.items;
    var first: ?[]const u8 = null;
    var roles: usize = 0;
    while (rest.len > 0) {
        try std.testing.expect(rest.len >= @sizeOf(ipc.Header));
        const header = std.mem.bytesToValue(ipc.Header, rest[0..@sizeOf(ipc.Header)]);
        try std.testing.expect(rest.len >= @sizeOf(ipc.Header) + header.len);
        const body = rest[@sizeOf(ipc.Header)..][0..header.len];
        if (first == null) first = body;
        if (header.tag == .Role) roles += 1;
        try std.testing.expect(!std.mem.eql(u8, body, "never-sent"));
        rest = rest[@sizeOf(ipc.Header) + header.len ..];
    }
    try std.testing.expectEqualStrings("partly-sent", first.?);
    try std.testing.expectEqual(@as(usize, 1), roles);
    _ = daemon.closeClient(alloc, client, 0, false);
}

fn testManaged(alloc: std.mem.Allocator, daemon: *Daemon, fd: i32, claim: bool) !*Client {
    const client = try testClient(alloc, fd, false);
    try daemon.clients.append(alloc, client);
    const flags = ipc.ManageFlags{ .claim = claim };
    daemon.handleManage(client, std.mem.asBytes(&flags));
    return client;
}

test "a managed client leads by claiming, never by typing or resizing" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});
    defer lib_posix.close(b[1]);
    const pty = b[0];
    defer lib_posix.close(pty);
    const size = std.mem.asBytes(&ipc.Resize{ .rows = 30, .cols = 100 });

    // the first managed attach takes the vacant slot without asking for it
    const origin = try testManaged(alloc, &daemon, a[0], false);
    try daemon.handleInit(alloc, origin, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, a[0]), daemon.leader_client_fd);
    try std.testing.expectEqual(ipc.Role.leader, queuedRoles(origin).last.?.role);

    // a second one without the claim follows, and neither typing nor resizing promotes it
    const viewer = try testManaged(alloc, &daemon, a[1], false);
    try daemon.handleInit(alloc, viewer, pty, &term, size);
    try std.testing.expectEqual(ipc.Role.follower, queuedRoles(viewer).last.?.role);
    try daemon.handleInput(alloc, viewer, "typed by a person\r");
    try daemon.handleResize(alloc, viewer, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, a[0]), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("", daemon.pty_write_buf.items);
    try std.testing.expectEqual(@as(usize, 1), queuedRoles(viewer).count);

    // the leader going away leaves the session unowned: a follower's resize is still not a claim
    _ = daemon.closeClient(alloc, origin, 0, false);
    try std.testing.expectEqual(@as(?i32, null), daemon.leader_client_fd);
    try std.testing.expectEqual(ipc.Role.unowned, queuedRoles(viewer).last.?.role);
    try daemon.handleResize(alloc, viewer, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, null), daemon.leader_client_fd);

    _ = daemon.closeClient(alloc, viewer, 0, false);
}

test "a claiming attach takes the lead from a live leader and both are told" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});
    defer lib_posix.close(b[1]);
    const pty = b[0];
    defer lib_posix.close(pty);

    const origin = try testManaged(alloc, &daemon, a[0], false);
    try daemon.handleInit(alloc, origin, pty, &term, std.mem.asBytes(&ipc.Resize{ .rows = 59, .cols = 83 }));
    const viewer = try testManaged(alloc, &daemon, a[1], true);
    try daemon.handleInit(alloc, viewer, pty, &term, std.mem.asBytes(&ipc.Resize{ .rows = 60, .cols = 89 }));

    try std.testing.expectEqual(@as(?i32, a[1]), daemon.leader_client_fd);
    try std.testing.expectEqual(@as(usize, 89), term.cols);
    const told_origin = queuedRoles(origin).last.?;
    const told_viewer = queuedRoles(viewer).last.?;
    try std.testing.expectEqual(ipc.Role.follower, told_origin.role);
    try std.testing.expectEqual(ipc.Role.leader, told_viewer.role);
    try std.testing.expectEqual(told_origin.generation, told_viewer.generation);

    // the role reaches a managed client ahead of anything else its Init queues
    const first = std.mem.bytesToValue(ipc.Header, viewer.write_buf.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(ipc.Tag.Resize, first.tag);
    const second = std.mem.bytesToValue(ipc.Header, viewer.write_buf.items[@sizeOf(ipc.Header)..][0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(ipc.Tag.Role, second.tag);

    _ = daemon.closeClient(alloc, viewer, 1, false);
    _ = daemon.closeClient(alloc, origin, 0, false);
}

fn testIdentified(alloc: std.mem.Allocator, daemon: *Daemon, fd: i32, claim: bool, identity: []const u8) !*Client {
    const client = try testManaged(alloc, daemon, fd, claim);
    try daemon.handleIdentity(alloc, client, identity);
    return client;
}

test "a reconnect takes back a lead its own dropped attach still holds, and no other" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});
    const c = try lib_posix.pipe2(.{});
    defer lib_posix.close(c[1]);
    const pty = c[0];
    defer lib_posix.close(pty);
    const size = std.mem.asBytes(&ipc.Resize{ .rows = 30, .cols = 100 });

    const origin = try testIdentified(alloc, &daemon, a[0], false, "o1");
    try daemon.handleInit(alloc, origin, pty, &term, size);
    const dropped = try testIdentified(alloc, &daemon, a[1], true, "v1");
    try daemon.handleInit(alloc, dropped, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, a[1]), daemon.leader_client_fd);

    // naming another attach's token takes nothing from a leader that claimed
    const stranger = try testIdentified(alloc, &daemon, b[0], false, "v3\nv9");
    try daemon.handleInit(alloc, stranger, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, a[1]), daemon.leader_client_fd);
    try std.testing.expectEqual(ipc.Role.follower, queuedRoles(stranger).last.?.role);

    const back = try testIdentified(alloc, &daemon, b[1], false, "v2\nv1");
    try daemon.handleInit(alloc, back, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, b[1]), daemon.leader_client_fd);
    try std.testing.expectEqual(ipc.Role.leader, queuedRoles(back).last.?.role);
    try std.testing.expectEqual(ipc.Role.follower, queuedRoles(origin).last.?.role);

    _ = daemon.closeClient(alloc, back, 3, false);
    _ = daemon.closeClient(alloc, stranger, 2, false);
    _ = daemon.closeClient(alloc, dropped, 1, false);
    _ = daemon.closeClient(alloc, origin, 0, false);
}

test "a reconnect takes back a lead a vacant attach filled until that attach is used" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});
    const c = try lib_posix.pipe2(.{});
    defer lib_posix.close(c[1]);
    const pty = c[0];
    defer lib_posix.close(pty);
    const size = std.mem.asBytes(&ipc.Resize{ .rows = 30, .cols = 100 });

    // the origin re-attached without a claim after the viewer's attach went away
    const fallback = try testIdentified(alloc, &daemon, a[0], false, "o2");
    try daemon.handleInit(alloc, fallback, pty, &term, size);
    try std.testing.expect(daemon.leader_idle);

    // focus reports, motion and a terminal's answers leave it idle
    try daemon.handleInput(alloc, fallback, "\x1b[I\x1b[<35;4;4M\x1b[12;1R");
    try std.testing.expect(daemon.leader_idle);

    const back = try testIdentified(alloc, &daemon, a[1], false, "v2\nv1");
    try daemon.handleInit(alloc, back, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, a[1]), daemon.leader_client_fd);
    try std.testing.expect(!daemon.leader_idle);
    _ = daemon.closeClient(alloc, back, 1, false);

    // used once it typed or clicked, so the next reconnect follows
    const used = try testIdentified(alloc, &daemon, b[0], false, "o3");
    try daemon.handleInit(alloc, used, pty, &term, size);
    try daemon.handleInput(alloc, used, "\x1b[<0;4;4M");
    try std.testing.expect(!daemon.leader_idle);
    const late = try testIdentified(alloc, &daemon, b[1], false, "v3\nv2");
    try daemon.handleInit(alloc, late, pty, &term, size);
    try std.testing.expectEqual(@as(?i32, b[0]), daemon.leader_client_fd);
    try std.testing.expectEqual(ipc.Role.follower, queuedRoles(late).last.?.role);

    _ = daemon.closeClient(alloc, late, 2, false);
    _ = daemon.closeClient(alloc, used, 1, false);
    _ = daemon.closeClient(alloc, fallback, 0, false);
}

test "switch moves a stock leader and leaves a managed one bound to its session" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    const stock = try testClient(alloc, a[0], true);
    try daemon.clients.append(alloc, stock);
    daemon.leader_client_fd = a[0];
    try daemon.handleSwitch(alloc, "other");
    const sent = std.mem.bytesToValue(ipc.Header, stock.write_buf.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(ipc.Tag.Switch, sent.tag);

    const managed = try testManaged(alloc, &daemon, a[1], true);
    daemon.leader_client_fd = a[1];
    try daemon.handleSwitch(alloc, "other");
    try std.testing.expectEqual(@as(usize, 0), managed.write_buf.items.len);

    _ = daemon.closeClient(alloc, managed, 1, false);
    _ = daemon.closeClient(alloc, stock, 0, false);
}

test "an unmanaged client still leads by typing" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    daemon.leader_client_fd = 42;

    const a = try lib_posix.pipe2(.{});
    defer lib_posix.close(a[1]);
    const stock = try testClient(alloc, a[0], true);
    try daemon.clients.append(alloc, stock);
    try daemon.handleInput(alloc, stock, "x");

    try std.testing.expectEqual(@as(?i32, a[0]), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("x", daemon.pty_write_buf.items);
    try std.testing.expectEqual(@as(usize, 0), queuedRoles(stock).count);
    _ = daemon.closeClient(alloc, stock, 0, false);
}

test "typed input is encoded for the keyboard mode the program asked for" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    const legacy = try terminal.encodeTyped(alloc, &term, "ls -la\r\rcaf\xc3\xa9");
    defer alloc.free(legacy);
    try std.testing.expectEqualStrings("ls -la\r\rcaf\xc3\xa9", legacy);

    // every kitty flag: Return is reported as a key, with its release
    stream.nextSlice("\x1b[>31u");
    const kitty = try terminal.encodeTyped(alloc, &term, "ls\r");
    defer alloc.free(kitty);
    try std.testing.expect(std.mem.startsWith(u8, kitty, "ls"));
    try std.testing.expect(std.mem.indexOf(u8, kitty, "\x1b[13u") != null);
    try std.testing.expect(std.mem.indexOf(u8, kitty, "\x1b[13;1:3u") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, kitty, '\r') == null);
}

test "type queues bytes without the lead and says when the queue is full" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    daemon.leader_client_fd = 42;

    const a = try lib_posix.pipe2(.{});
    defer lib_posix.close(a[1]);
    const caller = try testClient(alloc, a[0], false);
    try daemon.clients.append(alloc, caller);

    try daemon.handleType(alloc, caller, &term, "\r");
    try std.testing.expectEqualStrings("\r", daemon.pty_write_buf.items);
    try std.testing.expectEqual(@as(?i32, 42), daemon.leader_client_fd);
    try std.testing.expectEqual(@backingInt(ipc.TypeResult.accepted), caller.write_buf.items[caller.write_buf.items.len - 1]);

    const too_much = try alloc.alloc(u8, Daemon.PTY_WRITE_BUF_MAX);
    defer alloc.free(too_much);
    @memset(too_much, 'x');
    try daemon.handleType(alloc, caller, &term, too_much);
    try std.testing.expectEqualStrings("\r", daemon.pty_write_buf.items);
    try std.testing.expectEqual(@backingInt(ipc.TypeResult.rejected), caller.write_buf.items[caller.write_buf.items.len - 1]);
    _ = daemon.closeClient(alloc, caller, 0, false);
}

test "screen answers with a header even for a blank screen" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 20, .rows = 5 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);

    const a = try lib_posix.pipe2(.{});
    defer lib_posix.close(a[1]);
    const caller = try testClient(alloc, a[0], false);
    try daemon.clients.append(alloc, caller);

    try daemon.handleScreen(alloc, caller, &term, &[_]u8{@backingInt(ipc.ScreenMode.active)});
    const blank = caller.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqual(@as(usize, @sizeOf(ipc.ScreenHeader)), blank.len);

    // a line longer than the grid wraps on screen and reads back as one line
    caller.write_buf.clearRetainingCapacity();
    stream.nextSlice("0123456789abcdefghijKLMNO\r\n> ab");
    daemon.screen_revision = 9;
    try daemon.handleScreen(alloc, caller, &term, &[_]u8{@backingInt(ipc.ScreenMode.active)});
    const reply = caller.write_buf.items[@sizeOf(ipc.Header)..];
    const header = std.mem.bytesToValue(ipc.ScreenHeader, reply[0..@sizeOf(ipc.ScreenHeader)]);
    try std.testing.expectEqual(@as(u64, 9), header.revision);
    try std.testing.expectEqual(@as(u16, 20), header.cols);
    try std.testing.expectEqual(@as(u16, 4), header.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), header.cursor_y);
    try std.testing.expectEqual(@as(u8, 0), header.alternate);
    try std.testing.expectEqualStrings("0123456789abcdefghijKLMNO\n> ab", reply[@sizeOf(ipc.ScreenHeader)..]);

    // a mode this daemon does not know gets an empty reply, never a guess
    caller.write_buf.clearRetainingCapacity();
    try daemon.handleScreen(alloc, caller, &term, &[_]u8{200});
    try std.testing.expectEqual(@as(usize, @sizeOf(ipc.Header)), caller.write_buf.items.len);
    _ = daemon.closeClient(alloc, caller, 0, false);
}

test "handleEnvGet returns leader client's environment variables including unsets" {
    const alloc = std.testing.allocator;
    var cfg = Cfg{
        .socket_dir = "/tmp",
        .log_dir = "/tmp",
    };

    var daemon = Daemon{
        .cfg = &cfg,
        .clients = .empty,
        .session_name = "test",
        .socket_path = try alloc.dupe(u8, ""),
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
    defer daemon.deinit(alloc);

    const fds1 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds1[1]);
    var client1 = Client{
        .alloc = alloc,
        .socket_fd = fds1[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client1.deinit(alloc);
    try client1.setEnv(alloc, "DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n");

    const fds2 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds2[1]);
    var client2 = Client{
        .alloc = alloc,
        .socket_fd = fds2[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client2.deinit(alloc);
    try client2.setEnv(alloc, "SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n");

    const fds_req = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds_req[1]);
    var client_req = Client{
        .alloc = alloc,
        .socket_fd = fds_req[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client_req.deinit(alloc);

    try daemon.clients.append(alloc, &client1);
    try daemon.clients.append(alloc, &client2);

    // No leader yet -> handleEnvGet returns empty string payload
    try daemon.handleEnvGet(alloc, &client_req);
    try std.testing.expect(client_req.write_buf.items.len > 0);
    client_req.write_buf.clearRetainingCapacity();

    // Set client1 as leader
    try daemon.setLeader(alloc, &client1);
    try std.testing.expectEqual(@as(?i32, fds1[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    // Wire message: [Header][Payload]
    const pay1 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n", pay1);
    client_req.write_buf.clearRetainingCapacity();

    // Switch leader to client2
    try daemon.setLeader(alloc, &client2);
    try std.testing.expectEqual(@as(?i32, fds2[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    const pay2 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n", pay2);
    client_req.write_buf.clearRetainingCapacity();

    // Client2 updates env
    try daemon.handleEnvSet(alloc, &client2, "DISPLAY=:99\n");
    try daemon.handleEnvGet(alloc, &client_req);
    const pay3 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:99\n", pay3);
}

extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

/// A raw PTY of the given size, so what is written to one side reaches the other byte for byte.
fn testPty(rows: u16, cols: u16) ![2]i32 {
    // Windows has no PTY pair to read a client's bytes from; its sessions run under ConPTY
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const master = try lib_posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer lib_posix.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
    const name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = try lib_posix.open(std.mem.span(name), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer lib_posix.close(slave);
    var tio: cross.termios = undefined;
    if (cross.tcgetattr(slave, &tio) != 0) return error.PtyUnavailable;
    cross.cfmakeraw(&tio);
    if (cross.tcsetattr(slave, cross.TCSANOW, &tio) != 0) return error.PtyUnavailable;
    var ws = std.mem.zeroes(cross.struct_winsize);
    ws.ws_row = rows;
    ws.ws_col = cols;
    if (cross.ioctl(master, cross.TIOCSWINSZ, &ws) != 0) return error.PtyUnavailable;
    return .{ master, slave };
}

/// A real daemonLoop on a thread, attached over its socket by the test, which can hand that socket to a
/// real client loop whose terminal is a PTY the test reads, or not.
const EndingSession = struct {
    const start_mark = "DRAIN-START-MARK\n";
    const final_mark = "DRAIN-FINAL-MARK\n";
    const term_cols = 101;

    alloc: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    cfg: Cfg,
    daemon: Daemon,
    server_fd: i32,
    /// [0] the daemon's master, [1] the shell's side
    shell_pty: [2]i32,
    /// [0] what the terminal reads, [1] the client's stdin and stdout
    term_pty: [2]i32,
    sock: i32,
    daemon_thread: std.Thread,
    client_thread: ?std.Thread = null,
    daemon_done_ms: std.atomic.Value(i64) = .init(0),
    client_done_ms: std.atomic.Value(i64) = .init(0),
    client_result: anyerror!ClientResult = error.NotRun,
    exit_ms: i64 = 0,

    fn start(self: *EndingSession, alloc: std.mem.Allocator) !void {
        signal.ignoreSigpipe(); // as main does: the client writes to a daemon that may be gone
        self.* = .{
            .alloc = alloc,
            .tmp = std.testing.tmpDir(.{}),
            .cfg = .{ .socket_dir = "", .log_dir = "" },
            .daemon = undefined,
            .server_fd = undefined,
            .shell_pty = try testPty(24, 80),
            .term_pty = try testPty(33, term_cols),
            .sock = -1,
            .daemon_thread = undefined,
        };
        const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/s", .{self.tmp.sub_path});
        self.daemon = Daemon.init(std.testing.io, &self.cfg, "drain-test", path);
        self.server_fd = try socket.createSocket(path);
        const flags = try lib_posix.fcntl(self.shell_pty[0], lib_posix.F.GETFL, 0);
        _ = try lib_posix.fcntl(self.shell_pty[0], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
        // the session socket is a pair whose sizes the test sets, so no host default decides what the
        // daemon keeps; the daemon's end is a client as an accept would make it
        var pair: [2]i32 = undefined;
        if (@import("sys.zig").socketpair(&pair) != 0) return error.NoSocketPair;
        for (pair) |fd| setBuffers(fd);
        _ = try lib_posix.fcntl(pair[0], lib_posix.F.SETFL, lib_posix.O_NONBLOCK);
        try self.daemon.clients.append(alloc, try testClient(alloc, pair[0], false));
        self.sock = pair[1];
        self.daemon_thread = try std.Thread.spawn(.{}, runDaemon, .{self});
        errdefer self.kill();

        const size = ipc.Resize{ .rows = 33, .cols = term_cols };
        try ipc.send(self.sock, .Init, std.mem.asBytes(&size));
        // the daemon sizes its PTY from its leader's Init
        const deadline = role.nowMs() + 10_000;
        while (true) : (sleepMs(5)) {
            var ws: cross.struct_winsize = undefined;
            if (cross.ioctl(self.shell_pty[1], cross.TIOCGWINSZ, &ws) == 0 and ws.ws_col == term_cols) break;
            if (role.nowMs() > deadline) return error.NeverAttached;
        }
    }

    fn setBuffers(fd: i32) void {
        if (builtin.os.tag == .windows) return;
        const size: c_int = 8192;
        for ([_]u32{ std.c.SO.SNDBUF, std.c.SO.RCVBUF }) |opt| {
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, opt, std.mem.asBytes(&size), @sizeOf(c_int));
        }
    }

    fn runDaemon(self: *EndingSession) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        daemonLoop(&self.daemon, self.alloc, threaded.io(), self.server_fd, self.shell_pty[0]) catch |err| {
            std.debug.panic("daemonLoop failed: {s}", .{@errorName(err)});
        };
        // as run's teardown does: the socket goes before the clients, which tells them the session ended
        const path = lib_posix.toPosixPath(self.daemon.socket_path) catch unreachable;
        lib_posix.unlink(&path);
        self.daemon.shutdown(self.alloc);
        self.daemon_done_ms.store(role.nowMs(), .release);
    }

    /// Hands the session socket to a client loop; the terminal reads nothing until the test does.
    fn attachClient(self: *EndingSession) !void {
        self.client_thread = try std.Thread.spawn(.{}, runClient, .{self});
    }

    fn runClient(self: *EndingSession) void {
        self.client_result = clientLoopOn(.{ .fd = self.sock, .wire = .current }, "", self.daemon.socket_path, self.term_pty[1], self.term_pty[1]);
        self.client_done_ms.store(role.nowMs(), .release);
    }

    /// The shell prints the start mark, `payload` and the final mark, and exits.
    fn shellPrintsAndExits(self: *EndingSession, payload: []const u8) !void {
        for ([_][]const u8{ start_mark, payload, final_mark }) |part| {
            var rest = part;
            while (rest.len > 0) rest = rest[try lib_posix.write(self.shell_pty[1], rest)..];
        }
        lib_posix.close(self.shell_pty[1]);
        self.shell_pty[1] = -1;
        // a Debug daemon parses slowly; it answers a Type until it has read the shell's exit, an Info always
        const probe = try socket.sessionConnect(self.daemon.socket_path);
        defer lib_posix.close(probe);
        var replies = try ipc.SocketBuffer.init(self.alloc);
        defer replies.deinit();
        const deadline = role.nowMs() + 20_000;
        while (true) : (sleepMs(10)) {
            try ipc.send(probe, .Type, "");
            try ipc.send(probe, .Info, "");
            var typed = false;
            info: while (true) {
                if (try replies.read(probe) == 0) return error.DaemonGone;
                while (replies.next()) |msg| switch (msg.header.tag) {
                    .Type => typed = true,
                    .Info => break :info,
                    else => {},
                };
            }
            if (!typed) break;
            if (role.nowMs() > deadline) return error.NeverDrained;
        }
        self.exit_ms = role.nowMs();
    }

    /// Fills the client's terminal, so the client can write nothing until the test reads; returns how much.
    fn fillTerminal(self: *EndingSession) !usize {
        const fd = self.term_pty[1];
        const flags = try lib_posix.fcntl(fd, lib_posix.F.GETFL, 0);
        _ = try lib_posix.fcntl(fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
        defer _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags) catch {};
        var n: usize = 0;
        while (true) n += lib_posix.write(fd, "x") catch break;
        return n;
    }

    fn queued(fd: i32) usize {
        var n: c_int = 0;
        if (cross.ioctl(fd, cross.FIONREAD, &n) != 0) return 0;
        return @intCast(n);
    }

    fn done(flag: *const std.atomic.Value(i64)) bool {
        return flag.load(.acquire) != 0;
    }

    fn waitFor(self: *EndingSession, flag: *const std.atomic.Value(i64)) void {
        const deadline = role.nowMs() + 20_000;
        while (!done(flag)) : (sleepMs(5)) {
            if (role.nowMs() > deadline) std.debug.panic("an ending session's loop did not finish in 20 s", .{});
        }
        _ = self;
    }

    fn kill(self: *EndingSession) void {
        if (!done(&self.daemon_done_ms)) {
            if (socket.sessionConnect(self.daemon.socket_path)) |fd| {
                ipc.send(fd, .Kill, "") catch {};
                lib_posix.close(fd);
            } else |_| {}
        }
        self.daemon_thread.join();
        if (self.client_thread) |t| t.join();
        self.client_thread = null;
    }

    fn deinit(self: *EndingSession) void {
        self.kill();
        if (!done(&self.client_done_ms) and self.sock >= 0) lib_posix.close(self.sock);
        for (self.shell_pty ++ self.term_pty) |fd| {
            if (fd >= 0) lib_posix.close(fd);
        }
        lib_posix.close(self.server_fd);
        self.daemon.deinit(self.alloc);
        self.alloc.free(self.daemon.socket_path);
        self.tmp.cleanup();
    }
};

fn tookAbout(what: []const u8, took: i64, budget: i64, slack: i64) !void {
    if (took >= @divTrunc(budget, 2) and took <= budget + slack) return;
    std.debug.print("{s} took {d} ms on a {d} ms deadline\n", .{ what, took, budget });
    return error.TestUnexpectedResult;
}

fn testPayload(alloc: std.mem.Allocator) ![]u8 {
    // more than the session socket holds
    const payload = try alloc.alloc(u8, 48 * 1024);
    for (payload, 0..) |*b, i| b.* = if (i % 100 == 99) '\n' else 'a' + @as(u8, @intCast(i % 26));
    return payload;
}

// regression: the daemon freed unsent output at the shell's exit, and the client dropped unwritten output at the hangup
test "a session's last output reaches a terminal that resumes, through the daemon and the client" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc);
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);
    const filled = try s.fillTerminal();

    try s.shellPrintsAndExits(payload);
    try std.testing.expect(!EndingSession.done(&s.daemon_done_ms) and EndingSession.queued(s.sock) > 0);
    try s.attachClient();
    s.waitFor(&s.daemon_done_ms);
    try std.testing.expect(!EndingSession.done(&s.client_done_ms));

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [65536]u8 = undefined;
    const limit = role.nowMs() + 20_000;
    while (true) {
        var pfd = [_]lib_posix.pollfd{.{ .fd = s.term_pty[0], .events = lib_posix.POLL.IN, .revents = 0 }};
        _ = try lib_posix.poll(&pfd, 100);
        if (pfd[0].revents & lib_posix.POLL.IN != 0) {
            try got.appendSlice(alloc, buf[0..try lib_posix.read(s.term_pty[0], &buf)]);
        } else if (EndingSession.done(&s.client_done_ms)) break;
        if (role.nowMs() > limit) return error.ReaderTimedOut;
    }
    const expected = try std.mem.concat(alloc, u8, &.{ EndingSession.start_mark, payload, EndingSession.final_mark });
    defer alloc.free(expected);
    try std.testing.expect(std.mem.endsWith(u8, got.items, EndingSession.final_mark));
    try std.testing.expectEqual(filled + expected.len, got.items.len);
    try std.testing.expect(std.mem.endsWith(u8, got.items, expected));
}

test "an ending session whose terminal never reads again ends the daemon and then the client on their deadlines" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc);
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);
    _ = try s.fillTerminal();

    try s.shellPrintsAndExits(payload);
    s.waitFor(&s.daemon_done_ms);
    const daemon_took = s.daemon_done_ms.load(.acquire) - s.exit_ms;
    try tookAbout("daemon", daemon_took, EXIT_DRAIN_MS, 3000);
    const attached = role.nowMs();
    try s.attachClient();
    s.waitFor(&s.client_done_ms);
    const client_took = s.client_done_ms.load(.acquire) - attached;
    try tookAbout("client", client_took, CLOSE_BUDGET_MS, 3000);
    const close_deadline = (try s.client_result).close_deadline_ms orelse return error.NoCloseDeadline;
    try std.testing.expect(close_deadline > s.client_done_ms.load(.acquire));

    _ = try s.fillTerminal();
    writeBy(s.term_pty[1], "\x1bc", close_deadline);
    try std.testing.expect(role.nowMs() <= close_deadline + 1000);
    const began = role.nowMs();
    writeBy(s.term_pty[1], "\x1bc", began + 200);
    try std.testing.expect(role.nowMs() - began >= 190);
}

test "a draining session takes no attach, input or command, and a kill ends it at once" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc);
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);

    try s.shellPrintsAndExits(payload);
    try std.testing.expect(!EndingSession.done(&s.daemon_done_ms));
    const late = try socket.sessionConnect(s.daemon.socket_path);
    defer lib_posix.close(late);
    const size = ipc.Resize{ .rows = 24, .cols = 80 };
    try ipc.send(late, .Init, std.mem.asBytes(&size));
    try ipc.send(late, .Type, "echo late\r");
    try ipc.send(late, .Run, "echo late");
    var pfd = [_]lib_posix.pollfd{.{ .fd = late, .events = lib_posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try lib_posix.poll(&pfd, 300));

    try ipc.send(late, .Kill, "");
    const sent = role.nowMs();
    s.waitFor(&s.daemon_done_ms);
    try std.testing.expect(s.daemon_done_ms.load(.acquire) - sent < EXIT_DRAIN_MS / 2);
}

test "a detach returns at the hangup as before, dropping what the client holds" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc);
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);
    _ = try s.fillTerminal();
    try s.attachClient();
    var rest: []const u8 = payload;
    while (rest.len > 0) rest = rest[try lib_posix.write(s.shell_pty[1], rest)..];
    sleepMs(100);

    const probe = try socket.sessionConnect(s.daemon.socket_path);
    defer lib_posix.close(probe);
    try ipc.send(probe, .DetachAll, "");
    const sent = role.nowMs();
    s.waitFor(&s.client_done_ms);
    try std.testing.expect(s.client_done_ms.load(.acquire) - sent < CLOSE_BUDGET_MS * 3 / 4);
    try std.testing.expectEqual(@as(?i64, null), (try s.client_result).close_deadline_ms);
}

/// A terminal for leaveTerminal that records what is done to it.
const TerminalLog = struct {
    out_fd: i32,
    takes: bool,
    calls: [8]Call = undefined,
    n: usize = 0,

    const Call = union(enum) { taken_by: i64, flush, restore_flushing: bool, reset: ?i64 };

    fn add(self: *TerminalLog, call: Call) void {
        self.calls[self.n] = call;
        self.n += 1;
    }
    pub fn outputTakenBy(self: *TerminalLog, deadline_ms: i64) bool {
        self.add(.{ .taken_by = deadline_ms });
        return self.takes;
    }
    pub fn flushOutput(self: *TerminalLog) void {
        self.add(.flush);
    }
    pub fn restoreTermios(self: *TerminalLog, flushing: bool) void {
        self.add(.{ .restore_flushing = flushing });
    }
    pub fn writeReset(self: *TerminalLog, deadline_ms: ?i64) void {
        self.add(.{ .reset = deadline_ms });
    }
};

test "leaving a terminal: a detach as upstream, a session end within the deadline and the reset's share" {
    const pty = try testPty(24, 80);
    defer for (pty) |fd| lib_posix.close(fd);
    const pipe = try lib_posix.pipe2(.{});
    defer for (pipe) |fd| lib_posix.close(fd);
    const d: i64 = 10_000;
    const C = TerminalLog.Call;

    var detach: TerminalLog = .{ .out_fd = pty[1], .takes = true };
    leaveTerminal(&detach, .detached);
    try std.testing.expectEqualDeep(&[_]C{ .{ .restore_flushing = true }, .{ .reset = null } }, detach.calls[0..detach.n]);

    var taken: TerminalLog = .{ .out_fd = pty[1], .takes = true };
    leaveTerminal(&taken, .{ .ended = d });
    try std.testing.expectEqualDeep(&[_]C{ .{ .taken_by = d - RESET_SHARE_MS }, .{ .restore_flushing = true }, .{ .reset = d }, .{ .taken_by = d } }, taken.calls[0..taken.n]);

    var unread: TerminalLog = .{ .out_fd = pty[1], .takes = false };
    leaveTerminal(&unread, .{ .ended = d });
    try std.testing.expectEqualDeep(&[_]C{ .{ .taken_by = d - RESET_SHARE_MS }, .flush, .{ .restore_flushing = false }, .{ .reset = d }, .{ .taken_by = d }, .flush }, unread.calls[0..unread.n]);

    // a stdout that is no terminal needs no share for a reset
    var file: TerminalLog = .{ .out_fd = pipe[1], .takes = true };
    leaveTerminal(&file, .{ .ended = d });
    try std.testing.expectEqual(C{ .taken_by = d }, file.calls[0]);
}

test "a signalled attach restores termios without waiting on unread output" {
    const pipe = try lib_posix.pipe2(.{});
    defer for (pipe) |fd| lib_posix.close(fd);
    var t: TerminalLog = .{ .out_fd = pipe[1], .takes = false };
    leaveTerminal(&t, .interrupted);

    try std.testing.expectEqual(@as(usize, 5), t.n);
    try std.testing.expectEqual(TerminalLog.Call.flush, t.calls[0]);
    try std.testing.expectEqualDeep(TerminalLog.Call{ .restore_flushing = false }, t.calls[1]);
    const deadline = t.calls[2].reset orelse return error.UnboundedReset;
    try std.testing.expectEqualDeep(TerminalLog.Call{ .taken_by = deadline }, t.calls[3]);
    try std.testing.expectEqual(TerminalLog.Call.flush, t.calls[4]);
}

fn signalFor(thread: std.c.pthread_t, ms: i64) void {
    const end = role.nowMs() + ms;
    while (role.nowMs() < end) : (sleepMs(20)) _ = std.c.pthread_kill(thread, .WINCH);
}

test "signals do not stretch a write bounded by a deadline" {
    // Windows delivers no signals to interrupt a write
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pty = try testPty(24, 80);
    defer for (pty) |fd| lib_posix.close(fd);
    const flags = try lib_posix.fcntl(pty[1], lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(pty[1], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
    while (true) _ = lib_posix.write(pty[1], "x") catch break;
    _ = try lib_posix.fcntl(pty[1], lib_posix.F.SETFL, flags);
    try signal.openSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.WINCH));

    const signaller = try std.Thread.spawn(.{}, signalFor, .{ std.c.pthread_self(), 1500 });
    defer signaller.join();
    const began = role.nowMs();
    writeBy(pty[1], "x", began + 200);
    try std.testing.expect(role.nowMs() - began < 1000);
}

fn alwaysTaken(_: i32) usize {
    return 0;
}

fn neverTaken(_: i32) usize {
    return 1;
}

test "the output queue wait returns at once when it is empty and gives up at its deadline" {
    var began = role.nowMs();
    try std.testing.expect(takenBy(-1, began + 1000, alwaysTaken));
    try std.testing.expect(role.nowMs() - began < 500);
    began = role.nowMs();
    try std.testing.expect(!takenBy(-1, began + 100, neverTaken));
    try std.testing.expect(role.nowMs() - began >= 100);
}

test "a pty nobody reads holds its output queue until the deadline, and a flush empties it" {
    if (builtin.os.tag == .linux) {
        std.debug.print("skipped: a Linux pty reports an empty output queue whether it is read or not\n", .{});
        return error.SkipZigTest;
    }
    const pty = try testPty(24, 80);
    defer for (pty) |fd| lib_posix.close(fd);
    const flags = try lib_posix.fcntl(pty[1], lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(pty[1], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
    while (true) _ = lib_posix.write(pty[1], "x") catch break;

    const began = role.nowMs();
    try std.testing.expect(!takenBy(pty[1], began + 200, ttyOutputQueued));
    try std.testing.expect(role.nowMs() - began <= 1200);
    try std.testing.expectEqual(@as(c_int, 0), cross.tcflush(pty[1], cross.TCOFLUSH));
    try std.testing.expect(takenBy(pty[1], role.nowMs(), ttyOutputQueued));
    while (true) _ = lib_posix.write(pty[1], "x") catch break;
    leaveTerminal(Tty{ .out_fd = pty[1], .in_fd = null, .orig = undefined, .reset = "\x1bc" }, .{ .ended = role.nowMs() + 400 });
    try std.testing.expect(takenBy(pty[1], role.nowMs(), ttyOutputQueued));
}

fn readFor(fd: i32, ms: i64, out: *[256]u8, len: *usize) void {
    const end = role.nowMs() + ms;
    while (role.nowMs() < end) {
        var pfd = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        if ((lib_posix.poll(&pfd, 20) catch 0) == 0) continue;
        len.* += lib_posix.read(fd, out[len.*..]) catch return;
    }
}

test "a session end's reset reaches a pty that is read" {
    const pty = try testPty(24, 80);
    defer for (pty) |fd| lib_posix.close(fd);
    var got: [256]u8 = undefined;
    var len: usize = 0;
    const reader = try std.Thread.spawn(.{}, readFor, .{ pty[0], 1000, &got, &len });
    leaveTerminal(Tty{ .out_fd = pty[1], .in_fd = null, .orig = undefined, .reset = "\x1bc" }, .{ .ended = role.nowMs() + 500 });
    reader.join();
    try std.testing.expectEqualStrings("\x1bc", got[0..len]);
}
