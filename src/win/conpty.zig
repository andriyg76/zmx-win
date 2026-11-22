//! A session's shell under a pseudo console. The daemon reads and writes the shell through a socket, which
//! two threads bridge to the pseudo console's pipes, so its poll loop watches the shell as it watches a pty.
//! The shell and everything it starts run in a job that ends with the daemon.
const std = @import("std");
const api = @import("api.zig");
const posix = @import("posix.zig");

const Pty = struct {
    hpc: api.HPCON,
    process: api.HANDLE,
    job: api.HANDLE,
    pid: u32,
    in_w: api.HANDLE,
    out_r: api.HANDLE,
    bridge: api.SOCKET,
    rows: u16,
    cols: u16,
    closed: std.atomic.Value(bool) = .init(false),
};

/// A daemon runs one session, so it has at most one pseudo console.
var session: ?*Pty = null;

pub const Spawned = struct { fd: posix.fd_t, pid: i32 };

/// Starts `argv` under a new pseudo console of `rows` x `cols`, in the current directory and environment.
/// The first argument may be a bare program name, which Windows looks up on PATH.
pub fn spawn(argv: []const []const u8, rows: u16, cols: u16) !Spawned {
    const gpa = std.heap.c_allocator;
    var in_r: api.HANDLE = undefined;
    var in_w: api.HANDLE = undefined;
    var out_r: api.HANDLE = undefined;
    var out_w: api.HANDLE = undefined;
    if (api.CreatePipe(&in_r, &in_w, null, 0) == 0) return error.PipeFailed;
    if (api.CreatePipe(&out_r, &out_w, null, 0) == 0) return error.PipeFailed;

    var hpc: api.HPCON = undefined;
    if (api.CreatePseudoConsole(.{ .X = @intCast(cols), .Y = @intCast(rows) }, in_r, out_w, 0, &hpc) != 0)
        return error.PseudoConsoleFailed;
    // the pseudo console holds its own references; ours would keep the output pipe open past its close
    _ = api.CloseHandle(in_r);
    _ = api.CloseHandle(out_w);

    var attr_size: usize = 0;
    _ = api.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try gpa.alignedAlloc(u8, .of(usize), attr_size);
    defer gpa.free(attr_buf);
    const attrs: *anyopaque = attr_buf.ptr;
    if (api.InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) == 0) return error.AttributeListFailed;
    defer api.DeleteProcThreadAttributeList(attrs);
    if (api.UpdateProcThreadAttribute(attrs, 0, api.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(api.HPCON), null, null) == 0)
        return error.AttributeListFailed;

    var si: api.STARTUPINFOEXW = .{
        .StartupInfo = .{ .cb = @sizeOf(api.STARTUPINFOEXW) },
        .lpAttributeList = attrs,
    };
    // explicitly invalid stdio, so the shell never inherits handles the daemon was started with in place of
    // the pseudo console's
    si.StartupInfo.dwFlags = api.STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = api.INVALID_HANDLE_VALUE;
    si.StartupInfo.hStdOutput = api.INVALID_HANDLE_VALUE;
    si.StartupInfo.hStdError = api.INVALID_HANDLE_VALUE;
    var pi: api.PROCESS_INFORMATION = undefined;

    const cmdline = try commandLine(gpa, argv);
    defer gpa.free(cmdline);
    const flags = api.EXTENDED_STARTUPINFO_PRESENT | api.CREATE_SUSPENDED;
    if (api.CreateProcessW(null, cmdline.ptr, null, null, 0, flags, null, null, &si.StartupInfo, &pi) == 0) {
        std.log.err("CreateProcessW failed err={d} argv0={s}", .{ api.GetLastError(), argv[0] });
        api.ClosePseudoConsole(hpc);
        return error.SpawnFailed;
    }
    const job = api.CreateJobObjectW(null, null) orelse return error.JobFailed;
    var limits: api.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    limits.BasicLimitInformation.LimitFlags = api.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    _ = api.SetInformationJobObject(job, api.JobObjectExtendedLimitInformation, &limits, @sizeOf(api.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    if (api.AssignProcessToJobObject(job, pi.hProcess) == 0) {
        std.log.warn("AssignProcessToJobObject failed err={d}", .{api.GetLastError()});
    }
    // started suspended so that nothing it spawns escapes the job
    _ = api.ResumeThread(pi.hThread);
    _ = api.CloseHandle(pi.hThread);

    const pair = try posix.socketPair();
    const pty = try gpa.create(Pty);
    pty.* = .{
        .hpc = hpc,
        .process = pi.hProcess,
        .job = job,
        .pid = pi.dwProcessId,
        .in_w = in_w,
        .out_r = out_r,
        .bridge = pair[1],
        .rows = rows,
        .cols = cols,
    };
    session = pty;

    const fd = try posix.adoptSocket(pair[0]);
    posix.setPty(fd, pty);
    _ = posix.fcntl(fd, posix.F.SETFL, posix.O_NONBLOCK) catch {};

    (try std.Thread.spawn(.{}, pumpOutput, .{pty})).detach();
    (try std.Thread.spawn(.{}, pumpInput, .{pty})).detach();
    (try std.Thread.spawn(.{}, watchExit, .{pty})).detach();
    return .{ .fd = fd, .pid = @intCast(pi.dwProcessId) };
}

/// Pseudo console output to the daemon. It ends when the pseudo console closes after the shell exits, and
/// the shutdown then reads as the pty's EOF.
fn pumpOutput(pty: *Pty) void {
    var buf: [16384]u8 = undefined;
    var out: [16384 + Win32InputFilter.carry_max]u8 = undefined;
    var filter: Win32InputFilter = .{};
    // once the daemon stops reading, output is still drained so the pseudo console can close
    var sink = false;
    while (true) {
        var got: u32 = 0;
        if (api.ReadFile(pty.out_r, &buf, buf.len, &got, null) == 0 or got == 0) break;
        const bytes = filter.apply(buf[0..got], &out);
        if (!sink and bytes.len > 0 and !sendAll(pty.bridge, bytes)) sink = true;
    }
    _ = api.shutdown(pty.bridge, api.SD_SEND);
}

/// Drops the pseudo console's requests to turn win32-input-mode on and off. They ask the terminal hosting the
/// pseudo console, which is the daemon, to send keys as win32 input records; relayed, an attached terminal
/// that understands them starts encoding keys so, ctrl+\ included, and the client no longer sees the byte
/// it detaches on.
const Win32InputFilter = struct {
    const patterns = [_][]const u8{ "\x1b[?9001h", "\x1b[?9001l" };
    const carry_max = patterns[0].len - 1;
    carry: [carry_max]u8 = undefined,
    carry_len: usize = 0,

    fn apply(self: *Win32InputFilter, in: []const u8, out: []u8) []const u8 {
        var n: usize = 0;
        var src_buf: [carry_max]u8 = undefined;
        @memcpy(src_buf[0..self.carry_len], self.carry[0..self.carry_len]);
        const held = self.carry_len;
        self.carry_len = 0;
        var i: usize = 0;
        const total = held + in.len;
        while (i < total) {
            const c = if (i < held) src_buf[i] else in[i - held];
            if (c == 0x1b) {
                switch (self.matchAt(src_buf[0..held], in, i)) {
                    .full => {
                        i += patterns[0].len;
                        continue;
                    },
                    .partial => {
                        // the rest of a possible request arrives with the next read
                        while (i < total) : (i += 1) {
                            self.carry[self.carry_len] = if (i < held) src_buf[i] else in[i - held];
                            self.carry_len += 1;
                        }
                        break;
                    },
                    .none => {},
                }
            }
            out[n] = c;
            n += 1;
            i += 1;
        }
        return out[0..n];
    }

    fn matchAt(_: *Win32InputFilter, held: []const u8, in: []const u8, start: usize) enum { full, partial, none } {
        const total = held.len + in.len;
        for (patterns) |p| {
            var k: usize = 0;
            while (k < p.len and start + k < total) : (k += 1) {
                const c = if (start + k < held.len) held[start + k] else in[start + k - held.len];
                if (c != p[k]) break;
            } else {
                if (k == p.len) return .full;
                return .partial;
            }
        }
        return .none;
    }
};

test "win32-input-mode requests are dropped across reads" {
    var f: Win32InputFilter = .{};
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ab", f.apply("a\x1b[?9001hb", &out));
    try std.testing.expectEqualStrings("x", f.apply("x\x1b[?90", &out));
    try std.testing.expectEqualStrings("y", f.apply("01ly", &out));
    try std.testing.expectEqualStrings("\x1b[?25h", f.apply("\x1b[?25h", &out));
    try std.testing.expectEqualStrings("", f.apply("\x1b[", &out));
    try std.testing.expectEqualStrings("\x1b[1m", f.apply("1m", &out));
}

/// Daemon input to the pseudo console, until the daemon closes its end.
fn pumpInput(pty: *Pty) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = api.recv(pty.bridge, &buf, buf.len, 0);
        if (n <= 0) break;
        var rest = buf[0..@intCast(n)];
        while (rest.len > 0) {
            var wrote: u32 = 0;
            if (api.WriteFile(pty.in_w, rest.ptr, @intCast(rest.len), &wrote, null) == 0) return;
            rest = rest[wrote..];
        }
    }
}

/// Closes the pseudo console once the shell exits, which flushes its last output and ends pumpOutput.
fn watchExit(pty: *Pty) void {
    _ = api.WaitForSingleObject(pty.process, api.INFINITE);
    closeConsole(pty);
}

fn closeConsole(pty: *Pty) void {
    if (pty.closed.swap(true, .acq_rel)) return;
    api.ClosePseudoConsole(pty.hpc);
}

fn sendAll(s: api.SOCKET, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = api.send(s, rest.ptr, @intCast(rest.len), 0);
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

fn find(pid: u32) ?*Pty {
    const pty = session orelse return null;
    return if (pty.pid == pid) pty else null;
}

/// Closes the session's pseudo console, the hangup its programs see; false when `pid` is not its shell.
pub fn hangup(pid: u32) bool {
    const pty = find(pid) orelse return false;
    // the daemon is shutting down and reads no more output; failing pumpOutput's send makes it drain instead,
    // or ClosePseudoConsole would wait on it
    _ = api.shutdown(pty.bridge, api.SD_SEND);
    closeConsole(pty);
    return true;
}

/// Ends the session's job; false when `pid` is not its shell.
pub fn terminate(pid: u32) bool {
    const pty = find(pid) orelse return false;
    _ = api.TerminateJobObject(pty.job, 1);
    return true;
}

/// Waits for the shell `pid` and returns its exit code, or 0 for a process this daemon did not start.
pub fn wait(pid: i32) u32 {
    const pty = find(@intCast(pid)) orelse return 0;
    _ = api.WaitForSingleObject(pty.process, api.INFINITE);
    var code: u32 = 0;
    _ = api.GetExitCodeProcess(pty.process, &code);
    return code;
}

pub fn resize(fd: posix.fd_t, rows: u16, cols: u16) bool {
    const pty: *Pty = @ptrCast(@alignCast(posix.ptyOf(fd) orelse return false));
    if (rows == 0 or cols == 0) return false;
    // a resize repaints the whole console, and every attach sends one; at the same size it would follow the
    // daemon's own redraw with a second one
    if (pty.rows == rows and pty.cols == cols) return true;
    pty.rows = rows;
    pty.cols = cols;
    if (pty.closed.load(.acquire)) return true;
    return api.ResizePseudoConsole(pty.hpc, .{ .X = @intCast(cols), .Y = @intCast(rows) }) == 0;
}

pub fn size(fd: posix.fd_t) ?[2]u16 {
    const pty: *Pty = @ptrCast(@alignCast(posix.ptyOf(fd) orelse return null));
    return .{ pty.rows, pty.cols };
}

/// Builds a command line CommandLineToArgvW splits back into `argv`.
pub fn commandLine(gpa: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    for (argv, 0..) |arg, i| {
        if (i > 0) try line.append(gpa, ' ');
        try appendQuoted(gpa, &line, arg);
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, line.items);
}

fn appendQuoted(gpa: std.mem.Allocator, line: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) {
        try line.appendSlice(gpa, arg);
        return;
    }
    try line.append(gpa, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        if (c == '"') try line.appendNTimes(gpa, '\\', backslashes * 2 + 1) else try line.appendNTimes(gpa, '\\', backslashes);
        backslashes = 0;
        try line.append(gpa, c);
    }
    try line.appendNTimes(gpa, '\\', backslashes * 2);
    try line.append(gpa, '"');
}

test "command line quoting round-trips the CommandLineToArgvW rules" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { argv: []const []const u8, want: []const u8 }{
        .{ .argv = &.{ "pwsh", "-NoLogo" }, .want = "pwsh -NoLogo" },
        .{ .argv = &.{ "a b", "" }, .want = "\"a b\" \"\"" },
        .{ .argv = &.{"say \"hi\""}, .want = "\"say \\\"hi\\\"\"" },
        .{ .argv = &.{"C:\\dir with space\\"}, .want = "\"C:\\dir with space\\\\\"" },
    };
    for (cases) |c| {
        const got = try commandLine(gpa, c.argv);
        defer gpa.free(got);
        const want = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, c.want);
        defer gpa.free(want);
        try std.testing.expectEqualSlices(u16, want, got);
    }
}
