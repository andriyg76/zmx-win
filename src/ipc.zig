const std = @import("std");
const cross = @import("cross");
const socket = @import("socket.zig");
const lib_posix = @import("sys.zig").posix;

pub const PROTOCOL_VERSION: u8 = 1;

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    Switch = 11,
    Write = 12,
    TaskComplete = 13,
    LabelGet = 14,
    LabelSet = 15,
    LabelClear = 16,
    LabelData = 17,
    Send = 18,
    EnvGet = 19,
    EnvSet = 20,
    EnvData = 21,
    /// Scoped history: the active screen plus a bounded number of
    /// preceding scrollback rows. Request payload is `Capture`.
    Capture = 22,
    /// client -> daemon, before Init: this client takes part in explicit
    /// leadership. Payload is one `ManageFlags` byte.
    Manage = 26,
    /// daemon -> managed client: its role changed. Payload is a `RoleChange`.
    Role = 23,
    /// request: one `ScreenMode` byte.
    /// reply: a `ScreenHeader` followed by the text, or an empty payload for a mode it does not know.
    Screen = 24,
    /// request: typed text, each CR a Return key, encoded by the daemon for the
    /// session's keyboard mode and queued without taking the lead.
    /// reply: one `TypeResult` byte. Accepted means queued, not executed.
    Type = 25,
    /// client -> daemon, after Manage: the client's ZMX_MANAGED token, then, when it takes back a lead
    /// it lost with its link, a newline and the token of the attach that held it.
    Identity = 27,
    Unsupported = 255,
    // Non-exhaustive: this enum comes off the wire via bytesToValue and
    // @enumFromInt, so out-of-range values are representable
    // rather than UB. Switches must handle `_` (unknown tag).
    _,
};

comptime {
    if (@typeInfo(Tag).@"enum".mode == .exhaustive) @compileError(
        "ipc.Tag must stay non-exhaustive -- old daemons rely on `_` to ignore unknown tags",
    );
}

pub const Header = extern struct {
    tag: Tag,
    protocol_version: u8 = PROTOCOL_VERSION,
    _reserved: u16 = 0,
    len: u32,
};

pub const Resize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,

    pub fn winsize(self: Resize) cross.struct_winsize {
        return .{
            .ws_row = self.rows,
            .ws_col = self.cols,
            .ws_xpixel = self.xpixel,
            .ws_ypixel = self.ypixel,
        };
    }
};

/// Request payload for `Tag.Capture`. `format` is a `util.HistoryFormat`
/// and `rows` is how many scrollback rows to include above the active
/// screen; zero returns only the screen.
pub const Capture = extern struct {
    format: u8,
    _reserved: [3]u8 = @splat(0),
    rows: u32,
};

pub fn getTerminalSize(fd: i32) Resize {
    var ws: cross.struct_winsize = undefined;
    if (cross.ioctl(fd, cross.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
    }
    inline for (.{ lib_posix.STDOUT_FILENO, lib_posix.STDIN_FILENO, lib_posix.STDERR_FILENO }) |fallback_fd| {
        if (fallback_fd != fd) {
            if (cross.ioctl(fallback_fd, cross.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
                return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
            }
        }
    }
    if (lib_posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |tty_fd| {
        defer lib_posix.close(tty_fd);
        if (cross.ioctl(tty_fd, cross.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
        }
    } else |_| {}
    return .{ .rows = 24, .cols = 120 };
}

pub const MAX_PAYLOAD_LEN: usize = 64 * 1024 * 1024;

pub const ManageFlags = packed struct(u8) {
    /// take the lead when this client's Init arrives, even from a live leader
    claim: bool = false,
    _pad: u7 = 0,
};

pub const Role = enum(u8) {
    /// no client leads; the pty keeps its last size until one claims
    unowned = 0,
    leader = 1,
    follower = 2,
};

pub const RoleChange = extern struct {
    /// counts leadership changes of this daemon, so a client can drop a stale one
    generation: u32,
    role: Role,
};

pub const TypeResult = enum(u8) {
    accepted = 0,
    /// the pty input queue is full; nothing was queued
    rejected = 1,
};

pub const ScreenMode = enum(u8) {
    /// the visible screen only
    active = 0,
    /// scrollback followed by the visible screen
    all = 1,
    _,
};

pub const ScreenHeader = extern struct {
    /// advances on every pty read, resize and injected output, so two replies can be told apart
    revision: u64,
    cols: u16,
    rows: u16,
    /// zero-based, in the active screen
    cursor_x: u16,
    cursor_y: u16,
    alternate: u8,
};

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

/// Frozen wire shape. Do NOT add fields! New stats go in new `Tag` values
/// so old daemons (whose `_` arm ignores unknown tags) stay reachable.
/// Changing `@sizeOf(Info)` breaks `zmx list` against running daemons.
pub const Info = extern struct {
    clients_len: u64,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [MAX_CMD_LEN]u8,
    cwd: [MAX_CWD_LEN]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
    protocol_version: u8 = PROTOCOL_VERSION,
    _reserved: [6]u8 = @splat(0),
};

pub const Wire = enum {
    current,
    legacy,

    fn header(self: Wire, tag: Tag, len: u32) [@sizeOf(Header)]u8 {
        if (self == .current) return std.mem.asBytes(&Header{ .tag = tag, .len = len }).*;

        // zmx 0.8.1 used a packed { u8, u32 } backed by eight bytes.
        var bytes: [@sizeOf(Header)]u8 = @splat(0);
        bytes[0] = switch (tag) {
            .Manage => 22,
            .Identity => 26,
            else => @backingInt(tag),
        };
        std.mem.writeInt(u32, bytes[1..5], len, .little);
        return bytes;
    }

    fn decode(self: Wire, bytes: *const [@sizeOf(Header)]u8) Header {
        return switch (self) {
            .current => std.mem.bytesToValue(Header, bytes),
            .legacy => .{
                .tag = @fromBackingInt(@intCast(bytes[0])),
                .len = std.mem.readInt(u32, bytes[1..5], .little),
            },
        };
    }

    pub fn append(
        self: Wire,
        alloc: std.mem.Allocator,
        list: *std.ArrayList(u8),
        tag: Tag,
        data: []const u8,
    ) !void {
        try list.ensureUnusedCapacity(alloc, @sizeOf(Header) + data.len);
        list.appendSliceAssumeCapacity(&self.header(tag, @intCast(data.len)));
        list.appendSliceAssumeCapacity(data);
    }
};

pub fn send(fd: i32, tag: Tag, data: []const u8) !void {
    try (Connection{ .fd = fd, .wire = .current }).send(tag, data);
}

pub fn appendMessage(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tag: Tag,
    data: []const u8,
) !void {
    try Wire.current.append(alloc, list, tag, data);
}

pub const Connection = struct {
    fd: i32,
    wire: Wire,

    pub fn close(self: Connection) void {
        lib_posix.close(self.fd);
    }

    pub fn send(self: Connection, tag: Tag, data: []const u8) !void {
        try writeAll(self.fd, &self.wire.header(tag, @intCast(data.len)));
        try writeAll(self.fd, data);
    }
};

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try lib_posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

pub const Message = struct {
    tag: Tag,
    data: []u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) {
            alloc.free(self.data);
        }
    }
};

pub const SocketMsg = struct {
    header: Header,
    payload: []const u8,
};

pub const SocketBuffer = struct {
    wire: Wire = .current,
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
            .head = 0,
        };
    }

    pub fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    /// Reads from fd into buffer.
    /// Returns number of bytes read.
    /// Propagates error.WouldBlock and other errors to caller.
    /// Returns 0 on EOF.
    pub fn read(self: *SocketBuffer, fd: i32) !usize {
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try lib_posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    /// Returns the next complete message or `null` when none available.
    /// `buf` is advanced automatically; caller keeps the returned slices
    /// valid until the following `next()` (or `deinit`).
    pub fn next(self: *SocketBuffer) ?SocketMsg {
        const available = self.buf.items[self.head..];
        if (available.len < @sizeOf(Header)) return null;

        const hdr = self.wire.decode(available[0..@sizeOf(Header)]);
        if (hdr.len > MAX_PAYLOAD_LEN or hdr.protocol_version != PROTOCOL_VERSION) {
            // framing error / corrupted stream: clear buffer to avoid
            // infinite alloc
            self.buf.clearRetainingCapacity();
            self.head = 0;
            return null;
        }

        const total = @sizeOf(Header) + @as(usize, hdr.len);
        if (available.len < total) return null;

        const pay = available[@sizeOf(Header)..total];
        self.head += total;
        return .{ .header = hdr, .payload = pay };
    }
};

const ConnectError = error{
    ConnectionRefused,
    Unexpected,
};

/// Connect-only liveness check. Callers that don't read `Info` should use
/// this (not `probeSession`) so they survive `Info` shape changes.
pub fn connectSession(socket_path: []const u8) ConnectError!i32 {
    return socket.sessionConnect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
}

const SessionProbeError = error{
    Timeout,
    ConnectionRefused,
    Unexpected,
    InfoSizeMismatch,
    Unsupported,
    Ambiguous,
};

const SessionProbeResult = struct {
    connection: Connection,
    info: Info,
    labels: ?[]const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *const SessionProbeResult) void {
        if (self.labels) |lbl| self.alloc.free(lbl);
        self.connection.close();
    }
};

const ProtocolProbe = struct { connection: Connection, info: Info };

/// Info, Kill and DetachAll ignore their payload. A current header with a
/// zero length reads as a legacy header with length one because the legacy
/// length starts at the byte that now holds PROTOCOL_VERSION. Supply that
/// byte so either daemon can handle the request immediately.
pub fn sendOneShot(fd: i32, tag: enum { info, kill, detach_all }) !void {
    const wire_tag: Tag = switch (tag) {
        .info => .Info,
        .kill => .Kill,
        .detach_all => .DetachAll,
    };
    try writeAll(fd, &(Wire.current.header(wire_tag, 0) ++ [1]u8{0}));
}

fn readProbeBytes(fd: i32, bytes: []u8) SessionProbeError!void {
    var rest = bytes;
    while (rest.len != 0) {
        var pfd = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        if ((lib_posix.poll(&pfd, 1000) catch return error.Unexpected) == 0) return error.Timeout;
        const n = lib_posix.read(fd, rest) catch return error.Unexpected;
        if (n == 0) return error.Unexpected;
        rest = rest[n..];
    }
}

/// Retries a reply `probeFraming` cannot settle on a fresh connection, three attempts in all.
fn probeProtocol(socket_path: []const u8) SessionProbeError!ProtocolProbe {
    for (0..2) |_| return probeOnce(socket_path) catch |err| switch (err) {
        error.Ambiguous => continue,
        else => return err,
    };
    return probeOnce(socket_path) catch |err| if (err == error.Ambiguous) error.Unexpected else err;
}

fn probeOnce(socket_path: []const u8) SessionProbeError!ProtocolProbe {
    const fd = try connectSession(socket_path);
    errdefer lib_posix.close(fd);
    sendOneShot(fd, .info) catch return error.Unexpected;

    const reply = try readProbeReply(fd);
    const wire = reply.wire;
    const connection_fd = switch (wire) {
        .legacy => fd,
        // The current daemon has one extra byte buffered from the probe.
        .current => blk: {
            const fresh = try connectSession(socket_path);
            lib_posix.close(fd);
            break :blk fresh;
        },
    };
    return .{ .connection = .{ .fd = connection_fd, .wire = wire }, .info = reply.info };
}

fn readProbeReply(fd: i32) SessionProbeError!struct { wire: Wire, info: Info } {
    var header_bytes: [@sizeOf(Header)]u8 = undefined;
    try readProbeBytes(fd, &header_bytes);
    // output or a task completion can arrive before the Info reply
    const wire = try probeFraming(fd, &header_bytes);
    while (true) : (try readProbeBytes(fd, &header_bytes)) {
        const hdr = wire.decode(&header_bytes);
        if (hdr.protocol_version != PROTOCOL_VERSION) return error.Unexpected;

        switch (hdr.tag) {
            .Info => {
                if (hdr.len != @sizeOf(Info)) return error.InfoSizeMismatch;
                var info: Info = undefined;
                try readProbeBytes(fd, std.mem.asBytes(&info));
                return .{ .wire = wire, .info = info };
            },
            .Output, .TaskComplete => {
                if (hdr.len == 0 or hdr.len > MAX_PAYLOAD_LEN) return error.Unexpected;
                try discardProbeBytes(fd, hdr.len);
            },
            else => return error.Unexpected,
        }
    }
}

/// Picks the framing of a reply opening with `header_bytes`, leaving the next header to read there.
/// The nine bytes after an Output that reads both ways arrive in either framing; it is current only
/// when their last eight cannot open a legacy frame, since raw output can hold any header.
fn probeFraming(fd: i32, header_bytes: *[@sizeOf(Header)]u8) SessionProbeError!Wire {
    const as_current = opensProbeReply(.current, Wire.current.decode(header_bytes));
    const as_legacy = opensProbeReply(.legacy, Wire.legacy.decode(header_bytes));
    if (as_current != as_legacy) return if (as_current) .current else .legacy;
    if (!as_current) return error.Unexpected;

    var after: [1 + @sizeOf(Header)]u8 = undefined;
    try readProbeBytes(fd, &after);
    if (opensProbeReply(.legacy, Wire.legacy.decode(after[1..]))) return error.Ambiguous;
    try discardProbeBytes(fd, Wire.current.decode(header_bytes).len - after.len);
    try readProbeBytes(fd, header_bytes);
    return .current;
}

fn discardProbeBytes(fd: i32, len: usize) SessionProbeError!void {
    var remaining = len;
    var discard: [4096]u8 = undefined;
    while (remaining > 0) {
        const n = @min(remaining, discard.len);
        try readProbeBytes(fd, discard[0..n]);
        remaining -= n;
    }
}

/// Whether `hdr` can open a probe reply in `wire`'s framing. TaskComplete carries one byte and Info
/// its 552 in both, so only Output reads both ways: a legacy one-byte Output whose packed header
/// carries padding, or a current Output whose length is a multiple of 256.
fn opensProbeReply(wire: Wire, hdr: Header) bool {
    if (hdr.protocol_version != PROTOCOL_VERSION or hdr._reserved != 0) return false;
    // 0.8.1 relays its PTY in 4 KiB reads; a current header's nonzero low length byte reads as 2^24 or more
    const max_output: usize = if (wire == .legacy) (1 << 24) - 1 else MAX_PAYLOAD_LEN;
    return switch (hdr.tag) {
        .Info => hdr.len == @sizeOf(Info),
        .TaskComplete => hdr.len == 1,
        .Output => hdr.len != 0 and hdr.len <= max_output,
        else => false,
    };
}

pub fn connectProtocol(socket_path: []const u8) SessionProbeError!Connection {
    return (try probeProtocol(socket_path)).connection;
}

pub fn probeSession(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
) SessionProbeError!SessionProbeResult {
    const probe = try probeProtocol(socket_path);
    const connection = probe.connection;
    const labels = blk: {
        connection.send(.LabelGet, "") catch break :blk null;
        break :blk readReply(alloc, connection, .LabelData, 50) catch null;
    };
    return .{ .connection = connection, .info = probe.info, .labels = labels, .alloc = alloc };
}

//  WIRE PROTOCOL FREEZE: read before "fixing" any test below.
//
//  Changing these constants does not fix the test; it breaks every
//  running daemon for every user until they `pkill -f zmx`.
//
//  Need a new field?   → add a new `Tag` value (next free integer).
//  Need to remove one? → don't. Reserve the integer, stop sending it.
test "Info wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 552), @sizeOf(Info));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Resize));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Capture));
}

test "Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Input, 0 },     .{ Tag.Output, 1 },        .{ Tag.Resize, 2 },
        .{ Tag.Detach, 3 },    .{ Tag.DetachAll, 4 },     .{ Tag.Kill, 5 },
        .{ Tag.Info, 6 },      .{ Tag.Init, 7 },          .{ Tag.History, 8 },
        .{ Tag.Run, 9 },       .{ Tag.Ack, 10 },          .{ Tag.Switch, 11 },
        .{ Tag.Write, 12 },    .{ Tag.TaskComplete, 13 }, .{ Tag.LabelGet, 14 },
        .{ Tag.LabelSet, 15 }, .{ Tag.LabelClear, 16 },   .{ Tag.LabelData, 17 },
        .{ Tag.Send, 18 },     .{ Tag.EnvGet, 19 },       .{ Tag.EnvSet, 20 },
        .{ Tag.EnvData, 21 },  .{ Tag.Capture, 22 },      .{ Tag.Unsupported, 255 },
        .{ Tag.Role, 23 },     .{ Tag.Screen, 24 },       .{ Tag.Type, 25 },
        .{ Tag.Manage, 26 },   .{ Tag.Identity, 27 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @backingInt(p[0]));
}

pub fn roundTripForTag(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    request_tag: Tag,
    payload: []const u8,
    expected_tag: Tag,
) SessionProbeError![]u8 {
    return roundTripLarge(alloc, socket_path, request_tag, payload, expected_tag, 1000);
}

pub fn roundTripLarge(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    request_tag: Tag,
    payload: []const u8,
    expected_tag: Tag,
    timeout_ms: i32,
) SessionProbeError![]u8 {
    const connection = try connectProtocol(socket_path);
    defer connection.close();
    connection.send(request_tag, payload) catch return error.Unexpected;
    return readReply(alloc, connection, expected_tag, timeout_ms);
}

fn readReply(
    alloc: std.mem.Allocator,
    connection: Connection,
    expected_tag: Tag,
    timeout_ms: i32,
) SessionProbeError![]u8 {
    const fd = connection.fd;
    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();
    sb.wire = connection.wire;

    while (true) {
        var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        const poll_result = lib_posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
        if (poll_result == 0) return error.Timeout;

        const n = sb.read(fd) catch return error.Unexpected;
        if (n == 0) return error.Unexpected;

        while (sb.next()) |msg| {
            if (msg.header.tag == .Unsupported) return error.Unsupported;
            if (msg.header.tag == expected_tag) {
                return alloc.dupe(u8, msg.payload) catch return error.Unexpected;
            }
        }
    }
}

test "zeroed Info has no stack garbage in wire bytes" {
    var info = std.mem.zeroes(Info);
    info.clients_len = 3;
    info.pid = 999;
    info.task_exit_code = 7;
    const bytes = std.mem.asBytes(&info);
    // Tail padding after task_exit_code must be zero (asBytes ships it).
    const last_field_end = @offsetOf(Info, "task_exit_code") + @sizeOf(u8);
    for (bytes[last_field_end..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "legacy headers carry agterm 0.8.1 tag numbers" {
    inline for (.{ .{ Tag.Manage, 22 }, .{ Tag.Identity, 26 }, .{ Tag.Role, 23 }, .{ Tag.Screen, 24 }, .{ Tag.Type, 25 }, .{ Tag.Init, 7 } }) |p| {
        const bytes = Wire.legacy.header(p[0], 3);
        try std.testing.expectEqual(@as(u8, p[1]), bytes[0]);
        try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[1..5], .little));
    }
}

test "probe identifies both wire formats after unsolicited output" {
    for ([_]Wire{ .current, .legacy }) |wire| {
        var fds: [2]i32 = undefined;
        if (@import("sys.zig").socketpair(&fds) != 0) return error.NoSocketPair;
        defer for (fds) |fd| lib_posix.close(fd);

        const peer: Connection = .{ .fd = fds[0], .wire = wire };
        try peer.send(.Output, "$");
        try peer.send(.TaskComplete, "\x00");
        var info = std.mem.zeroes(Info);
        info.pid = 123;
        try peer.send(.Info, std.mem.asBytes(&info));

        const reply = try readProbeReply(fds[1]);
        try std.testing.expectEqual(wire, reply.wire);
        try std.testing.expectEqual(info.pid, reply.info.pid);
    }
}

test "probe settles a busy current daemon's first frame that reads in both framings" {
    // regression: a busy daemon's 4096-byte Output reads as a padded 0.8.1 one-byte Output
    var fds: [2]i32 = undefined;
    if (@import("sys.zig").socketpair(&fds) != 0) return error.NoSocketPair;
    defer for (fds) |fd| lib_posix.close(fd);
    var text: [4096]u8 = undefined;
    @memset(&text, 'y');
    var info = std.mem.zeroes(Info);
    info.pid = 321;
    const peer: Connection = .{ .fd = fds[0], .wire = .current };
    try peer.send(.Output, &text);
    try peer.send(.Info, std.mem.asBytes(&info));

    const reply = try readProbeReply(fds[1]);
    try std.testing.expectEqual(Wire.current, reply.wire);
    try std.testing.expectEqual(info.pid, reply.info.pid);
}

test "probe refuses to guess when the bytes after an ambiguous frame open a legacy one" {
    var fake = std.mem.zeroes(Info);
    fake.pid = 666;
    var info = std.mem.zeroes(Info);
    info.pid = 321;
    const padded_output = [_]u8{ 1, 1, 0, 0, 0, 0, 1, 0, 'x' };
    const legacy_info = Wire.legacy.header(.Info, @sizeOf(Info)) ++ std.mem.toBytes(info);
    var current_output: [@sizeOf(Header) + 4096]u8 = undefined;
    current_output[0..@sizeOf(Header)].* = Wire.current.header(.Output, 4096);
    @memset(current_output[@sizeOf(Header)..], 'y');
    current_output[@sizeOf(Header) + 1 ..][0 .. @sizeOf(Header) + @sizeOf(Info)].* =
        Wire.legacy.header(.Info, @sizeOf(Info)) ++ std.mem.toBytes(fake);
    const current_info = Wire.current.header(.Info, @sizeOf(Info)) ++ std.mem.toBytes(info);
    const cases = [_][]const []const u8{ &.{ &padded_output, &legacy_info }, &.{ &current_output, &current_info } };
    for (cases) |frames| {
        var fds: [2]i32 = undefined;
        if (@import("sys.zig").socketpair(&fds) != 0) return error.NoSocketPair;
        defer for (fds) |fd| lib_posix.close(fd);
        for (frames) |frame| try writeAll(fds[0], frame);
        try std.testing.expectError(error.Ambiguous, readProbeReply(fds[1]));
    }
}

test "probe reads a padded legacy task completion as legacy" {
    var fds: [2]i32 = undefined;
    if (@import("sys.zig").socketpair(&fds) != 0) return error.NoSocketPair;
    defer for (fds) |fd| lib_posix.close(fd);
    try writeAll(fds[0], &[_]u8{ 13, 1, 0, 0, 0, 7, 7, 7, 0 });
    var info = std.mem.zeroes(Info);
    info.pid = 77;
    try (Connection{ .fd = fds[0], .wire = .legacy }).send(.Info, std.mem.asBytes(&info));

    const reply = try readProbeReply(fds[1]);
    try std.testing.expectEqual(Wire.legacy, reply.wire);
    try std.testing.expectEqual(info.pid, reply.info.pid);
}

test "a one-shot request reads as a one-byte request on a 0.8.1 daemon" {
    var fds: [2]i32 = undefined;
    if (@import("sys.zig").socketpair(&fds) != 0) return error.NoSocketPair;
    defer for (fds) |fd| lib_posix.close(fd);
    try sendOneShot(fds[0], .info);
    var bytes: [@sizeOf(Header) + 1]u8 = undefined;
    try readProbeBytes(fds[1], &bytes);

    try std.testing.expectEqual(@as(u32, 0), Wire.current.decode(bytes[0..@sizeOf(Header)]).len);
    const legacy = Wire.legacy.decode(bytes[0..@sizeOf(Header)]);
    try std.testing.expectEqual(Tag.Info, legacy.tag);
    try std.testing.expectEqual(@as(u32, 1), legacy.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[@sizeOf(Header)]);
}
