//! The Windows counterpart of posix.zig. A descriptor is an index into a table of sockets, files and the
//! three stdio streams, so the loops can keep their i32 descriptors and poll() can stay WSAPoll over sockets:
//! every endpoint that is no socket (a ConPTY pipe, the console's input) is bridged into one by a thread.
const std = @import("std");
const api = @import("api.zig");
const stdio = @import("stdio.zig");
const mem = std.mem;

pub const fd_t = i32;
pub const socket_t = i32;
pub const pid_t = i32;
pub const mode_t = u32;
pub const nfds_t = u32;
pub const socklen_t = i32;

pub const STDIN_FILENO: fd_t = 0;
pub const STDOUT_FILENO: fd_t = 1;
pub const STDERR_FILENO: fd_t = 2;

pub const AF = struct {
    pub const UNIX: u32 = 1;
};
pub const SOCK = struct {
    pub const STREAM: u32 = 1;
    pub const NONBLOCK: u32 = 0x800;
    pub const CLOEXEC: u32 = 0x80000;
};
pub const POLL = struct {
    pub const IN: i16 = 0x0300;
    pub const OUT: i16 = 0x0010;
    pub const ERR: i16 = 0x0001;
    pub const HUP: i16 = 0x0002;
    pub const NVAL: i16 = 0x0004;
};
pub const F = struct {
    pub const GETFD: i32 = 1;
    pub const SETFD: i32 = 2;
    pub const GETFL: i32 = 3;
    pub const SETFL: i32 = 4;
};
pub const O = packed struct(u32) {
    ACCMODE: enum(u2) { RDONLY = 0, WRONLY = 1, RDWR = 2 } = .RDONLY,
    CREAT: bool = false,
    EXCL: bool = false,
    TRUNC: bool = false,
    APPEND: bool = false,
    NONBLOCK: bool = false,
    CLOEXEC: bool = false,
    _: u24 = 0,
};
pub const O_NONBLOCK: usize = 1 << @bitOffsetOf(O, "NONBLOCK");

pub const SIG = enum(u32) {
    HUP = 1,
    INT = 2,
    KILL = 9,
    PIPE = 13,
    TERM = 15,
    WINCH = 28,
    _,

    pub const DFL: ?*const fn (SIG) callconv(.c) void = null;
    pub const IGN: ?*const fn (SIG) callconv(.c) void = @ptrFromInt(1);
    pub const UNBLOCK: u32 = 1;
};
pub const SA = struct {
    pub const SIGINFO: u32 = 4;
};
pub const siginfo_t = extern struct { signo: i32 = 0 };
pub const sigset_t = u32;
pub const Sigaction = struct {
    handler: extern union {
        handler: ?*const fn (SIG) callconv(.c) void,
        sigaction: ?*const fn (SIG, *const siginfo_t, ?*anyopaque) callconv(.c) void,
    },
    mask: sigset_t,
    flags: u32,
};

pub const pollfd = extern struct { fd: fd_t, events: i16, revents: i16 };

pub const sockaddr = extern struct {
    family: u16,
    data: [14]u8,

    pub const un = extern struct {
        family: u16 = AF.UNIX,
        path: [108]u8,
    };
};

const PATH_MAX = 1024;

const Kind = enum { free, socket, file, stdin, stdout, stderr };
const Entry = struct {
    kind: Kind = .free,
    sock: api.SOCKET = api.INVALID_SOCKET,
    handle: ?api.HANDLE = null,
    nonblock: bool = false,
    /// a ConPTY behind this socket, for the ioctls that resize it or ask its size
    pty: ?*anyopaque = null,
};

const max_fds = 4096;
var table: [max_fds]Entry = init: {
    var t: [max_fds]Entry = @splat(.{});
    t[0].kind = .stdin;
    t[1].kind = .stdout;
    t[2].kind = .stderr;
    break :init t;
};
var table_lock: api.SRWLOCK = .{};

fn alloc(e: Entry) error{ProcessFdQuotaExceeded}!fd_t {
    api.AcquireSRWLockExclusive(&table_lock);
    defer api.ReleaseSRWLockExclusive(&table_lock);
    for (table[3..], 3..) |*slot, i| {
        if (slot.kind == .free) {
            slot.* = e;
            return @intCast(i);
        }
    }
    return error.ProcessFdQuotaExceeded;
}

pub fn entry(fd: fd_t) ?*Entry {
    if (fd < 0 or fd >= max_fds) return null;
    const e = &table[@intCast(fd)];
    return if (e.kind == .free) null else e;
}

/// adopt gives a socket made outside this table (a bridge's end) a descriptor.
pub fn adoptSocket(s: api.SOCKET) !fd_t {
    return alloc(.{ .kind = .socket, .sock = s });
}

pub fn setPty(fd: fd_t, pty: *anyopaque) void {
    if (entry(fd)) |e| e.pty = pty;
}

pub fn ptyOf(fd: fd_t) ?*anyopaque {
    const e = entry(fd) orelse return null;
    return e.pty;
}

/// The socket a descriptor reads from, starting the stdin bridge on first use.
fn sockOf(fd: fd_t) ?api.SOCKET {
    const e = entry(fd) orelse return null;
    return switch (e.kind) {
        .socket => e.sock,
        .stdin => stdio.inputSocket(),
        .stdout => stdio.outputSocket(),
        else => null,
    };
}

var wsa_once: api.INIT_ONCE = .{};
fn wsaStartup() void {
    var data: api.WSADATA = undefined;
    _ = api.WSAStartup(0x0202, &data);
}
pub fn ensureWinsock() void {
    api.callOnce(&wsa_once, wsaStartup);
}

const UnexpectedError = error{Unexpected};

pub fn getuid() u32 {
    return 0;
}

pub fn getpid() i32 {
    return @intCast(api.GetCurrentProcessId());
}

pub fn sigemptyset() sigset_t {
    return 0;
}

/// Records the handler a signal runs; on Windows signal.zig's wake handler is the only one, raised by the
/// console's control handler and the console input bridge rather than by the kernel.
pub fn sigaction(sig: SIG, noalias act: ?*const Sigaction, noalias oact: ?*Sigaction) void {
    _ = oact;
    const a = act orelse return;
    stdio.setSignalHandler(sig, a.handler.sigaction);
}

pub fn getenv(key: []const u8) ?[:0]const u8 {
    if (mem.indexOfScalar(u8, key, '=') != null) return null;
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const v = std.c.getenv(buf[0..key.len :0]) orelse return null;
    return mem.sliceTo(v, 0);
}

const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
} || UnexpectedError;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    ensureWinsock();
    const s = api.socket(@intCast(domain), @intCast(socket_type & ~(SOCK.NONBLOCK | SOCK.CLOEXEC)), @intCast(protocol));
    if (s == api.INVALID_SOCKET) return error.SystemResources;
    errdefer _ = api.closesocket(s);
    _ = api.SetHandleInformation(@ptrFromInt(s), api.HANDLE_FLAG_INHERIT, 0);
    const nonblock = socket_type & SOCK.NONBLOCK != 0;
    if (nonblock) try setNonblock(s, true);
    return alloc(.{ .kind = .socket, .sock = s, .nonblock = nonblock });
}

fn setNonblock(s: api.SOCKET, on: bool) UnexpectedError!void {
    var arg: u32 = @intFromBool(on);
    if (api.ioctlsocket(s, api.FIONBIO, &arg) != 0) return error.Unexpected;
}

pub fn close(fd: fd_t) void {
    api.AcquireSRWLockExclusive(&table_lock);
    defer api.ReleaseSRWLockExclusive(&table_lock);
    if (fd < 3 or fd >= max_fds) return;
    const e = &table[@intCast(fd)];
    switch (e.kind) {
        .socket => _ = api.closesocket(e.sock),
        .file => if (e.handle) |h| {
            _ = api.CloseHandle(h);
        },
        else => {},
    }
    e.* = .{};
}

const ConnectError = error{
    AccessDenied,
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    SystemResources,
    ConnectionRefused,
    NetworkUnreachable,
    ConnectionTimedOut,
    WouldBlock,
    FileNotFound,
    ConnectionResetByPeer,
    ConnectionPending,
} || UnexpectedError;

pub fn connect(sock: socket_t, sock_addr: *const sockaddr, len: socklen_t) ConnectError!void {
    const s = sockOf(sock) orelse return error.Unexpected;
    if (api.connect(s, sock_addr, len) == 0) return;
    return switch (api.WSAGetLastError()) {
        api.WSAECONNREFUSED => error.ConnectionRefused,
        api.WSAEWOULDBLOCK, api.WSAEINPROGRESS => error.WouldBlock,
        api.WSAEADDRINUSE => error.AddressInUse,
        api.WSAEACCES => error.AccessDenied,
        api.WSAECONNRESET => error.ConnectionResetByPeer,
        else => error.Unexpected,
    };
}

const BindError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    ReadOnlyFileSystem,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    AlreadyBound,
} || UnexpectedError;

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    const s = sockOf(sock) orelse return error.FileDescriptorNotASocket;
    if (api.bind(s, addr, len) == 0) return;
    return switch (api.WSAGetLastError()) {
        api.WSAEADDRINUSE => error.AddressInUse,
        api.WSAEACCES => error.AccessDenied,
        api.WSAENAMETOOLONG => error.NameTooLong,
        api.WSAEINVAL => error.AlreadyBound,
        else => error.Unexpected,
    };
}

const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    NetworkSubsystemFailed,
    SystemResources,
    AlreadyConnected,
    SocketNotBound,
} || UnexpectedError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    const s = sockOf(sock) orelse return error.FileDescriptorNotASocket;
    if (api.listen(s, backlog) == 0) return;
    return switch (api.WSAGetLastError()) {
        api.WSAEADDRINUSE => error.AddressInUse,
        api.WSAEINVAL => error.SocketNotBound,
        else => error.Unexpected,
    };
}

const AcceptError = error{
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    ProtocolFailure,
    BlockedByFirewall,
    WouldBlock,
    ConnectionResetByPeer,
    NetworkSubsystemFailed,
    OperationNotSupported,
} || UnexpectedError;

pub fn accept(sock: socket_t, addr: ?*sockaddr, addr_size: ?*socklen_t, flags: u32) AcceptError!socket_t {
    const s = sockOf(sock) orelse return error.FileDescriptorNotASocket;
    const a = api.accept(s, addr, addr_size);
    if (a == api.INVALID_SOCKET) return switch (api.WSAGetLastError()) {
        api.WSAEWOULDBLOCK => error.WouldBlock,
        api.WSAECONNRESET => error.ConnectionResetByPeer,
        api.WSAEINVAL => error.SocketNotListening,
        else => error.Unexpected,
    };
    errdefer _ = api.closesocket(a);
    _ = api.SetHandleInformation(@ptrFromInt(a), api.HANDLE_FLAG_INHERIT, 0);
    const nonblock = flags & SOCK.NONBLOCK != 0;
    // an accepted socket inherits the listener's non-blocking mode, so it is set either way
    try setNonblock(a, nonblock);
    return alloc(.{ .kind = .socket, .sock = a, .nonblock = nonblock });
}

const LinkError = error{PathAlreadyExists} || UnexpectedError;

pub fn link(old: [*:0]const u8, new: [*:0]const u8) LinkError!void {
    var ob: [PATH_MAX]u16 = undefined;
    var nb: [PATH_MAX]u16 = undefined;
    const o = api.wide(&ob, mem.span(old)) catch return error.Unexpected;
    const n = api.wide(&nb, mem.span(new)) catch return error.Unexpected;
    if (api.CreateHardLinkW(n, o, null) != 0) return;
    return switch (api.GetLastError()) {
        api.ERROR_ALREADY_EXISTS, api.ERROR_FILE_EXISTS => error.PathAlreadyExists,
        else => error.Unexpected,
    };
}

pub fn unlink(path: [*:0]const u8) void {
    var b: [PATH_MAX]u16 = undefined;
    const p = api.wide(&b, mem.span(path)) catch return;
    _ = api.DeleteFileW(p);
}

pub fn ensureDir(path: [*:0]const u8, mode: mode_t) bool {
    _ = mode;
    var b: [PATH_MAX]u16 = undefined;
    const p = api.wide(&b, mem.span(path)) catch return false;
    if (api.CreateDirectoryW(p, null) != 0) return true;
    return api.GetLastError() == api.ERROR_ALREADY_EXISTS;
}

/// Whether `path` names an existing file, a session socket included.
pub fn exists(path: [*:0]const u8) bool {
    var b: [PATH_MAX]u16 = undefined;
    const p = api.wide(&b, mem.span(path)) catch return false;
    return api.GetFileAttributesW(p) != 0xFFFFFFFF;
}

pub fn isatty(fd: fd_t) bool {
    const e = entry(fd) orelse return false;
    return switch (e.kind) {
        .stdin => stdio.isConsole(api.STD_INPUT_HANDLE),
        .stdout => stdio.isConsole(api.STD_OUTPUT_HANDLE),
        .stderr => stdio.isConsole(api.STD_ERROR_HANDLE),
        else => false,
    };
}

pub fn rename(old: [*:0]const u8, new: [*:0]const u8) bool {
    var ob: [PATH_MAX]u16 = undefined;
    var nb: [PATH_MAX]u16 = undefined;
    const o = api.wide(&ob, mem.span(old)) catch return false;
    const n = api.wide(&nb, mem.span(new)) catch return false;
    return MoveFileExW(o, n, 0x1 | 0x8) != 0; // REPLACE_EXISTING | WRITE_THROUGH
}
extern "kernel32" fn MoveFileExW(old: [*:0]const u16, new: [*:0]const u16, flags: u32) callconv(.winapi) api.BOOL;

pub fn sleepMs(ms: u64) void {
    api.Sleep(@intCast(@min(ms, std.math.maxInt(u32) - 1)));
}

const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || UnexpectedError;

/// Only the non-blocking flag means anything here; inheritance is off for every handle this layer makes.
pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    const e = entry(fd) orelse return error.Unexpected;
    switch (cmd) {
        F.GETFL => return if (e.nonblock) O_NONBLOCK else 0,
        F.SETFL => {
            const on = arg & O_NONBLOCK != 0;
            if (sockOf(fd)) |s| try setNonblock(s, on);
            e.nonblock = on;
            return 0;
        },
        else => return 0,
    }
}

const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    LockViolation,
    WouldBlock,
    ConnectionResetByPeer,
    ProcessNotFound,
    NoDevice,
    MessageTooBig,
} || UnexpectedError;

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    const e = entry(fd) orelse return error.NotOpenForWriting;
    const len: u32 = @intCast(@min(bytes.len, std.math.maxInt(i32)));
    switch (e.kind) {
        .socket => {
            const n = api.send(e.sock, bytes.ptr, @intCast(len), 0);
            if (n >= 0) return @intCast(n);
            return switch (api.WSAGetLastError()) {
                api.WSAEWOULDBLOCK => error.WouldBlock,
                api.WSAECONNRESET, api.WSAECONNABORTED => error.ConnectionResetByPeer,
                api.WSAESHUTDOWN, api.WSAENOTCONN => error.BrokenPipe,
                else => error.Unexpected,
            };
        },
        .stdout => if (stdio.outputSocket()) |sock| {
            setNonblock(sock, e.nonblock) catch {};
            const n = api.send(sock, bytes.ptr, @intCast(len), 0);
            if (n >= 0) {
                stdio.outputSent(@intCast(n));
                return @intCast(n);
            }
            return if (api.WSAGetLastError() == api.WSAEWOULDBLOCK) error.WouldBlock else error.BrokenPipe;
        } else return writeHandle(api.GetStdHandle(api.STD_OUTPUT_HANDLE), bytes[0..len]),
        .stderr, .file => {
            const h = switch (e.kind) {
                .stdout => api.GetStdHandle(api.STD_OUTPUT_HANDLE),
                .stderr => api.GetStdHandle(api.STD_ERROR_HANDLE),
                else => e.handle,
            } orelse return error.NotOpenForWriting;
            var written: u32 = 0;
            if (api.WriteFile(h, bytes.ptr, len, &written, null) == 0) {
                return if (api.GetLastError() == api.ERROR_BROKEN_PIPE) error.BrokenPipe else error.InputOutput;
            }
            return written;
        },
        else => return error.NotOpenForWriting,
    }
}

fn writeHandle(handle: ?api.HANDLE, bytes: []const u8) WriteError!usize {
    const h = handle orelse return error.NotOpenForWriting;
    var written: u32 = 0;
    if (api.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null) == 0) {
        return if (api.GetLastError() == api.ERROR_BROKEN_PIPE) error.BrokenPipe else error.InputOutput;
    }
    return written;
}

pub const ReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    WouldBlock,
    Canceled,
    AccessDenied,
    ProcessNotFound,
    LockViolation,
} || UnexpectedError;

pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;
    const e = entry(fd) orelse return error.NotOpenForReading;
    const len: u32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
    if (e.kind == .file) {
        var got: u32 = 0;
        if (api.ReadFile(e.handle.?, buf.ptr, len, &got, null) == 0) {
            return if (api.GetLastError() == api.ERROR_BROKEN_PIPE) 0 else error.InputOutput;
        }
        return got;
    }
    const s = sockOf(fd) orelse return error.NotOpenForReading;
    // the stdin bridge is non-blocking exactly when the caller set its descriptor so
    if (e.kind == .stdin) setNonblock(s, e.nonblock) catch {};
    const n = api.recv(s, buf.ptr, @intCast(len), 0);
    if (n >= 0) return @intCast(n);
    return switch (api.WSAGetLastError()) {
        api.WSAEWOULDBLOCK => error.WouldBlock,
        api.WSAECONNRESET, api.WSAECONNABORTED => error.ConnectionResetByPeer,
        api.WSAENOTCONN => error.SocketNotConnected,
        api.WSAESHUTDOWN => 0,
        else => error.Unexpected,
    };
}

const OpenError = error{
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,
    NameTooLong,
    SystemResources,
    FileTooBig,
    IsDir,
    NoSpaceLeft,
    NotDir,
    PathAlreadyExists,
    DeviceBusy,
    FileLocksNotSupported,
    BadPathName,
    InvalidUtf8,
    InvalidWtf8,
    NetworkNotFound,
    ProcessNotFound,
    FileBusy,
    WouldBlock,
} || UnexpectedError;

pub fn open(file_path: []const u8, flags: O, perm: mode_t) OpenError!fd_t {
    _ = perm;
    // there is no controlling terminal to open; callers fall back as when /dev/tty is missing
    if (mem.eql(u8, file_path, "/dev/tty")) return error.NoDevice;
    const path = if (mem.eql(u8, file_path, "/dev/null")) "NUL" else file_path;
    var b: [PATH_MAX]u16 = undefined;
    const p = api.wide(&b, path) catch return error.NameTooLong;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const access: u32 = switch (flags.ACCMODE) {
        .RDONLY => GENERIC_READ,
        .WRONLY => GENERIC_WRITE,
        .RDWR => GENERIC_READ | GENERIC_WRITE,
    };
    // CREATE_NEW 1, CREATE_ALWAYS 2, OPEN_EXISTING 3, OPEN_ALWAYS 4, TRUNCATE_EXISTING 5
    const disposition: u32 = if (flags.CREAT and flags.EXCL) 1 else if (flags.CREAT and flags.TRUNC) 2 else if (flags.CREAT) 4 else if (flags.TRUNC) 5 else 3;
    const share: u32 = 0x1 | 0x2 | 0x4;
    const h = api.CreateFileW(p, access, share, null, disposition, 0x80, null);
    if (h == api.INVALID_HANDLE_VALUE) return switch (api.GetLastError()) {
        2, 3 => error.FileNotFound,
        5 => error.AccessDenied,
        80, 183 => error.PathAlreadyExists,
        else => error.Unexpected,
    };
    errdefer _ = api.CloseHandle(h);
    return alloc(.{ .kind = .file, .handle = h });
}

pub fn exit(status: u8) noreturn {
    std.process.exit(status);
}

const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || UnexpectedError;

/// A connected pair of sockets, standing in for a pipe so that poll() can watch it.
pub fn pipe2(flags: O) PipeError![2]fd_t {
    const pair = socketPair() catch return error.Unexpected;
    errdefer {
        _ = api.closesocket(pair[0]);
        _ = api.closesocket(pair[1]);
    }
    if (flags.NONBLOCK) {
        try setNonblock(pair[0], true);
        try setNonblock(pair[1], true);
    }
    const r = try alloc(.{ .kind = .socket, .sock = pair[0], .nonblock = flags.NONBLOCK });
    errdefer close(r);
    const w = try alloc(.{ .kind = .socket, .sock = pair[1], .nonblock = flags.NONBLOCK });
    return .{ r, w };
}

var pair_seq = std.atomic.Value(u32).init(0);

/// socketPair connects two AF_UNIX sockets through a listener on a throwaway path, as Windows has no socketpair.
pub fn socketPair() ![2]api.SOCKET {
    ensureWinsock();
    var tmp: [PATH_MAX]u8 = undefined;
    const dir = getenv("TEMP") orelse getenv("TMP") orelse "C:/Windows/Temp";
    const path = try std.fmt.bufPrintSentinel(&tmp, "{s}\\zmx-sp-{d}-{d}", .{ dir, api.GetCurrentProcessId(), pair_seq.fetchAdd(1, .monotonic) }, 0);
    var addr = try initUnix(path);
    unlink(path);
    defer unlink(path);

    const l = api.socket(1, 1, 0);
    if (l == api.INVALID_SOCKET) return error.Unexpected;
    defer _ = api.closesocket(l);
    if (api.bind(l, &addr.any, addr.getOsSockLen()) != 0) return error.Unexpected;
    if (api.listen(l, 1) != 0) return error.Unexpected;

    const c = api.socket(1, 1, 0);
    if (c == api.INVALID_SOCKET) return error.Unexpected;
    errdefer _ = api.closesocket(c);
    if (api.connect(c, &addr.any, addr.getOsSockLen()) != 0) return error.Unexpected;
    const a = api.accept(l, null, null);
    if (a == api.INVALID_SOCKET) return error.Unexpected;
    for ([_]api.SOCKET{ a, c }) |s| _ = api.SetHandleInformation(@ptrFromInt(s), api.HANDLE_FLAG_INHERIT, 0);
    return .{ a, c };
}

const WaitPidResult = struct { pid: pid_t, status: u32 };

pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
    _ = flags;
    return .{ .pid = pid, .status = @import("conpty.zig").wait(pid) << 8 };
}

pub const PollError = error{
    NetworkSubsystemFailed,
    SystemResources,
} || UnexpectedError;

pub fn pollOrInterrupted(fds: []pollfd, timeout: i32) PollError!usize {
    return poll(fds, timeout);
}

/// WSAPoll over the descriptors' sockets, stdin's and stdout's bridges included. A stderr or file descriptor
/// is always writable, since its writes block, and polling one ends the wait at once.
pub fn poll(fds: []pollfd, timeout: i32) PollError!usize {
    var wfds_buf: [256]api.WSAPOLLFD = undefined;
    if (fds.len > wfds_buf.len) return error.SystemResources;
    const wfds = wfds_buf[0..fds.len];
    var ready: usize = 0;
    var watched: usize = 0;
    for (fds, wfds) |*p, *w| {
        p.revents = 0;
        w.* = .{ .fd = api.INVALID_SOCKET, .events = 0, .revents = 0 };
        if (p.fd < 0) continue;
        const e = entry(p.fd) orelse {
            p.revents = POLL.NVAL;
            ready += 1;
            continue;
        };
        switch (e.kind) {
            .stderr, .file => {
                p.revents = p.events & POLL.OUT;
                if (p.revents != 0) ready += 1;
            },
            else => {
                w.* = .{ .fd = sockOf(p.fd) orelse api.INVALID_SOCKET, .events = p.events & (POLL.IN | POLL.OUT), .revents = 0 };
                if (w.fd != api.INVALID_SOCKET) watched += 1;
            },
        }
    }
    const t: i32 = if (ready > 0) 0 else timeout;
    if (watched == 0) {
        if (t > 0) api.Sleep(@intCast(t)) else if (t < 0) api.Sleep(api.INFINITE);
        return ready;
    }
    // WSAPoll rejects an array whose entries are all ignored, so only the watched ones are passed
    var packed_buf: [256]api.WSAPOLLFD = undefined;
    var map: [256]usize = undefined;
    var n: usize = 0;
    for (wfds, 0..) |w, i| {
        if (w.fd == api.INVALID_SOCKET) continue;
        packed_buf[n] = w;
        map[n] = i;
        n += 1;
    }
    const rc = api.WSAPoll(&packed_buf, @intCast(n), t);
    if (rc < 0) return error.Unexpected;
    for (packed_buf[0..n], map[0..n]) |w, i| {
        fds[i].revents = w.revents;
        if (w.revents != 0) ready += 1;
    }
    return ready;
}

pub fn toPosixPath(file_path: []const u8) error{NameTooLong}![PATH_MAX - 1:0]u8 {
    var path_with_null: [PATH_MAX - 1:0]u8 = undefined;
    if (file_path.len >= PATH_MAX) return error.NameTooLong;
    @memcpy(path_with_null[0..file_path.len], file_path);
    path_with_null[file_path.len] = 0;
    return path_with_null;
}

const Address = extern union {
    any: sockaddr,
    un: sockaddr.un,

    pub fn getOsSockLen(_: Address) socklen_t {
        return @sizeOf(sockaddr.un);
    }
};

pub fn initUnix(path: []const u8) !Address {
    var sock_addr = sockaddr.un{ .path = undefined };
    if (path.len + 1 > sock_addr.path.len) return error.NameTooLong;
    @memset(&sock_addr.path, 0);
    @memcpy(sock_addr.path[0..path.len], path);
    return Address{ .un = sock_addr };
}

const KillError = error{ ProcessNotFound, PermissionDenied } || UnexpectedError;

/// A negative pid names the session's job, the shell and everything it started. HUP closes the session's
/// pseudo console, which sends its programs CTRL_CLOSE_EVENT; KILL and TERM end the job; WINCH has nothing to
/// do, since resizing the pseudo console already tells its programs.
pub fn kill(pid: pid_t, sig: SIG) KillError!void {
    const conpty = @import("conpty.zig");
    const target: u32 = @intCast(@abs(pid));
    switch (sig) {
        .WINCH => return,
        .HUP => if (conpty.hangup(target)) return,
        else => if (conpty.terminate(target)) return,
    }
    const h = api.OpenProcess(api.PROCESS_TERMINATE, 0, target) orelse return error.ProcessNotFound;
    defer _ = api.CloseHandle(h);
    if (api.TerminateProcess(h, 128 + @as(u32, @backingInt(sig))) == 0) return error.PermissionDenied;
}
