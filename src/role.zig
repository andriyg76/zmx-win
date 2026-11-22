//! Client side of explicit leadership: turns the daemon's Role messages into a
//! title with a reserved prefix on the client's own stdout, so the terminal
//! hosting `zmx attach` learns whether this client leads. A title and not a
//! desktop notification: terminals rate-limit those, and a dropped report
//! leaves the terminal wrong about a role the daemon enforces.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const lib_posix = @import("sys.zig").posix;

/// How long a role may wait for a safe place in the output before one is forced.
pub const DEADLINE_MS: i64 = 250;

const NONCE_MAX = 64;

const NoopHandler = struct {
    pub fn deinit(_: *@This()) void {}

    pub fn vt(
        _: *@This(),
        comptime action: ghostty_vt.StreamAction.Tag,
        _: ghostty_vt.StreamAction.Value(action),
    ) void {}
};

/// The opt-in: `ZMX_MANAGED` holds a nonce chosen by the hosting terminal and
/// echoed in every report, so a title set by a program inside the session
/// cannot pass for one. Null when unset or not a plain token.
pub fn nonceFromEnv() ?[]const u8 {
    const value = lib_posix.getenv("ZMX_MANAGED") orelse return null;
    return if (isNonce(value)) value else null;
}

pub fn isNonce(value: []const u8) bool {
    if (value.len == 0 or value.len > NONCE_MAX) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

pub fn claimFromEnv() bool {
    return lib_posix.getenv("ZMX_MANAGED_CLAIM") != null;
}

/// The token of an earlier attach of this pane whose lead the hosting terminal takes back after the
/// link dropped. Null when unset or not a plain token.
pub fn reclaimFromEnv() ?[]const u8 {
    const value = lib_posix.getenv("ZMX_MANAGED_RECLAIM") orelse return null;
    return if (isNonce(value)) value else null;
}

pub const IdentityBuf = [NONCE_MAX * 2 + 1]u8;

/// The Identity payload: `nonce`, then a newline and `reclaim` when there is one.
pub fn identity(buf: *IdentityBuf, nonce: []const u8, reclaim: ?[]const u8) []const u8 {
    const from = reclaim orelse return std.fmt.bufPrint(buf, "{s}", .{nonce}) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}\n{s}", .{ nonce, from }) catch unreachable;
}


pub const Relay = struct {
    stream: ghostty_vt.Stream(NoopHandler),
    nonce: []const u8,
    /// newest role not written yet; an older one it replaces is never written
    pending: ?ipc.RoleChange = null,
    deadline_ms: i64 = 0,

    pub fn init(nonce: []const u8) Relay {
        return .{ .stream = .init(.{ .handler = .{} }), .nonce = nonce };
    }

    pub fn deinit(self: *Relay) void {
        self.stream.deinit();
    }

    /// Append daemon output to `out`, writing a pending role at the first point
    /// where it cannot split an escape sequence or a UTF-8 character.
    pub fn forward(self: *Relay, gpa: std.mem.Allocator, out: *std.ArrayList(u8), output: []const u8) !void {
        var rest = output;
        if (self.pending != null) {
            const stop = self.stream.nextSliceUntil(rest, .initOne(.ground)) orelse {
                try out.appendSlice(gpa, rest);
                return;
            };
            try out.appendSlice(gpa, rest[0..stop.consumed]);
            try self.flush(gpa, out);
            rest = rest[stop.consumed..];
        }
        self.stream.nextSlice(rest);
        try out.appendSlice(gpa, rest);
    }

    pub fn roleChanged(
        self: *Relay,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
        change: ipc.RoleChange,
        now_ms: i64,
    ) !void {
        if (self.pending == null) self.deadline_ms = now_ms + DEADLINE_MS;
        self.pending = change;
        if (self.stream.ground()) try self.flush(gpa, out);
    }

    /// Milliseconds the caller may block before `expire` is due, -1 for no limit.
    pub fn pollTimeout(self: *const Relay, now_ms: i64) i32 {
        if (self.pending == null) return -1;
        return @intCast(std.math.clamp(self.deadline_ms - now_ms, 0, DEADLINE_MS));
    }

    /// A program that stopped inside an escape sequence would hold a role back
    /// forever. CAN returns every terminal parser to ground; it lands only in a
    /// terminal whose role is changing, which is either new or about to be covered.
    pub fn expire(self: *Relay, gpa: std.mem.Allocator, out: *std.ArrayList(u8), now_ms: i64) !void {
        if (self.pending == null or now_ms < self.deadline_ms) return;
        try out.append(gpa, 0x18);
        // the terminal is at ground after CAN, so the tracker restarts there too
        self.stream.deinit();
        self.stream = .init(.{ .handler = .{} });
        try self.flush(gpa, out);
    }

    fn flush(self: *Relay, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        const change = self.pending orelse return;
        self.pending = null;
        var buf: [NONCE_MAX + 64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "\x1b]2;zmx-role;{s}:{s}:{d}\x1b\\", .{
            self.nonce,
            @tagName(change.role),
            change.generation,
        }) catch unreachable;
        try out.appendSlice(gpa, text);
    }
};

pub fn nowMs() i64 {
    if (@import("builtin").os.tag == .windows) return @intCast(@import("win/api.zig").GetTickCount64());
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const testing = std.testing;

fn role(generation: u32, r: ipc.Role) ipc.RoleChange {
    return .{ .generation = generation, .role = r };
}

const leader_osc = "\x1b]2;zmx-role;n1:leader:7\x1b\\";

test "isNonce accepts plain tokens only" {
    try testing.expect(isNonce("a1B-2"));
    try testing.expect(!isNonce(""));
    try testing.expect(!isNonce("a;b"));
    try testing.expect(!isNonce("a b"));
    try testing.expect(!isNonce(&@as([NONCE_MAX + 1]u8, @splat('x'))));
}

test "identity carries the reclaimed token after a newline" {
    var buf: IdentityBuf = undefined;
    try testing.expectEqualStrings("n2", identity(&buf, "n2", null));
    try testing.expectEqualStrings("n2\nn1", identity(&buf, "n2", "n1"));
}

test "role at ground is written at once" {
    var relay = Relay.init("n1");
    defer relay.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try relay.forward(testing.allocator, &out, "hello");
    try relay.roleChanged(testing.allocator, &out, role(7, .leader), 0);
    try testing.expectEqualStrings("hello" ++ leader_osc, out.items);
    try testing.expectEqual(@as(i32, -1), relay.pollTimeout(0));
}

test "role waits for every split point of an escape sequence and a UTF-8 character" {
    // CSI, OSC with ST, DCS, and a three-byte character
    const stream = "\x1b[1;31mA\x1b]0;title\x1b\\B\x1bPq#0\x1b\\C\xe2\x82\xacD";
    var split: usize = 1;
    while (split < stream.len) : (split += 1) {
        var relay = Relay.init("n1");
        defer relay.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);

        try relay.forward(testing.allocator, &out, stream[0..split]);
        try relay.roleChanged(testing.allocator, &out, role(7, .leader), 0);
        try relay.forward(testing.allocator, &out, stream[split..]);

        // the notification is whole, and removing it gives back the stream byte for byte
        const at = std.mem.indexOf(u8, out.items, leader_osc) orelse return error.RoleMissing;
        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(testing.allocator);
        try rebuilt.appendSlice(testing.allocator, out.items[0..at]);
        try rebuilt.appendSlice(testing.allocator, out.items[at + leader_osc.len ..]);
        try testing.expectEqualStrings(stream, rebuilt.items);

        // and it sits where a fresh parser fed the bytes before it is at ground
        var check = Relay.init("n1");
        defer check.deinit();
        check.stream.nextSlice(out.items[0..at]);
        try testing.expect(check.stream.ground());
    }
}

test "a newer role replaces one still waiting" {
    var relay = Relay.init("n1");
    defer relay.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try relay.forward(testing.allocator, &out, "\x1b]0;unfinished");
    try relay.roleChanged(testing.allocator, &out, role(5, .unowned), 0);
    try relay.roleChanged(testing.allocator, &out, role(6, .follower), 10);
    try relay.forward(testing.allocator, &out, "\x1b\\");

    try testing.expect(std.mem.indexOf(u8, out.items, "unowned") == null);
    try testing.expect(std.mem.endsWith(u8, out.items, "\x1b]2;zmx-role;n1:follower:6\x1b\\"));
}

test "an unfinished sequence is cancelled at the deadline" {
    var relay = Relay.init("n1");
    defer relay.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try relay.forward(testing.allocator, &out, "\x1bPnever finished");
    try relay.roleChanged(testing.allocator, &out, role(7, .leader), 100);
    try testing.expectEqual(@as(i32, 250), relay.pollTimeout(100));
    try testing.expectEqual(@as(i32, 0), relay.pollTimeout(400));

    try relay.expire(testing.allocator, &out, 200);
    try testing.expect(std.mem.indexOf(u8, out.items, "zmx-role") == null);

    try relay.expire(testing.allocator, &out, 350);
    try testing.expectEqualStrings("\x1bPnever finished\x18" ++ leader_osc, out.items);
    try testing.expect(relay.stream.ground());
    try testing.expectEqual(@as(i32, -1), relay.pollTimeout(350));
}
