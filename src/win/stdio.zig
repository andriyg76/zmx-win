//! The attach client's console: a thread bridges stdin into a socket poll() can watch, console window
//! resizes and control events become the signals the client loop wakes on, and the raw mode termios would
//! set is the console's VT input and output modes.
const std = @import("std");
const api = @import("api.zig");
const posix = @import("posix.zig");

pub fn isConsole(which: api.DWORD) bool {
    const h = api.GetStdHandle(which) orelse return false;
    var mode: api.DWORD = 0;
    return api.GetConsoleMode(h, &mode) != 0;
}

// ---- signals ----

const Handler = *const fn (posix.SIG, *const posix.siginfo_t, ?*anyopaque) callconv(.c) void;
var handlers: [32]?Handler = @splat(null);
var ctrl_installed = std.atomic.Value(bool).init(false);

pub fn setSignalHandler(sig: posix.SIG, handler: ?Handler) void {
    const n = @backingInt(sig);
    if (n >= handlers.len) return;
    // SIG_DFL and SIG_IGN arrive here as the small integers they are on POSIX
    handlers[n] = if (handler) |h| (if (@intFromPtr(h) <= 1) null else h) else null;
    if (!ctrl_installed.swap(true, .acq_rel)) _ = api.SetConsoleCtrlHandler(onCtrl, 1);
}

pub fn raise(sig: posix.SIG) bool {
    const n = @backingInt(sig);
    const h = handlers[n] orelse return false;
    const info: posix.siginfo_t = .{ .signo = @intCast(n) };
    h(sig, &info, null);
    return true;
}

fn onCtrl(event: api.DWORD) callconv(.winapi) api.BOOL {
    const sig: posix.SIG = switch (event) {
        api.CTRL_C_EVENT => .INT,
        api.CTRL_BREAK_EVENT => .TERM,
        api.CTRL_CLOSE_EVENT => .HUP,
        api.CTRL_LOGOFF_EVENT, api.CTRL_SHUTDOWN_EVENT => .TERM,
        else => return 0,
    };
    if (!raise(sig)) return 0;
    // after a close the process ends once this returns, so the loop gets a moment to leave the console
    if (event == api.CTRL_CLOSE_EVENT) api.Sleep(500);
    return 1;
}

// ---- stdin bridge ----

var input_once: api.INIT_ONCE = .{};
var input_sock: api.SOCKET = api.INVALID_SOCKET;

/// The socket stdin reads from, started on first use.
pub fn inputSocket() ?api.SOCKET {
    api.callOnce(&input_once, startInput);
    return if (input_sock == api.INVALID_SOCKET) null else input_sock;
}

fn startInput() void {
    const pair = posix.socketPair() catch return;
    const h = api.GetStdHandle(api.STD_INPUT_HANDLE) orelse {
        // no stdin at all reads as an empty one
        _ = api.closesocket(pair[1]);
        input_sock = pair[0];
        return;
    };
    var mode: api.DWORD = 0;
    const console = api.GetConsoleMode(h, &mode) != 0;
    const t = (if (console) std.Thread.spawn(.{}, pumpConsole, .{ h, pair[1] }) else std.Thread.spawn(.{}, pumpPipe, .{ h, pair[1] })) catch {
        _ = api.closesocket(pair[0]);
        _ = api.closesocket(pair[1]);
        return;
    };
    t.detach();
    input_sock = pair[0];
}

fn pumpPipe(h: api.HANDLE, out: api.SOCKET) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (api.ReadFile(h, &buf, buf.len, &got, null) == 0 or got == 0) break;
        if (!sendAll(out, buf[0..got])) return;
    }
    _ = api.shutdown(out, api.SD_SEND);
}

/// Console input records to UTF-8. With ENABLE_VIRTUAL_TERMINAL_INPUT on, the console turns every key into
/// the characters a terminal would send, so only key-down characters are forwarded.
fn pumpConsole(h: api.HANDLE, out: api.SOCKET) void {
    var records: [128]api.INPUT_RECORD = undefined;
    var bytes: [128 * 4]u8 = undefined;
    var high: ?u16 = null;
    while (true) {
        var got: u32 = 0;
        if (api.ReadConsoleInputW(h, &records, records.len, &got) == 0) break;
        var n: usize = 0;
        var resized = false;
        for (records[0..got]) |r| {
            switch (r.EventType) {
                api.KEY_EVENT => {
                    const k = r.Event.KeyEvent;
                    if (k.bKeyDown == 0 or k.uChar == 0) continue;
                    const c = k.uChar;
                    if (std.unicode.utf16IsHighSurrogate(c)) {
                        high = c;
                        continue;
                    }
                    const cp: u21 = if (std.unicode.utf16IsLowSurrogate(c)) blk: {
                        const hi = high orelse continue;
                        high = null;
                        break :blk std.unicode.utf16DecodeSurrogatePair(&.{ hi, c }) catch continue;
                    } else c;
                    var repeat: usize = @max(k.wRepeatCount, 1);
                    while (repeat > 0) : (repeat -= 1) {
                        if (n + 4 > bytes.len) break;
                        n += std.unicode.utf8Encode(cp, bytes[n..][0..4]) catch break;
                    }
                },
                api.WINDOW_BUFFER_SIZE_EVENT => resized = true,
                else => {},
            }
        }
        if (n > 0 and !sendAll(out, bytes[0..n])) return;
        if (resized) _ = raise(.WINCH);
    }
    _ = api.shutdown(out, api.SD_SEND);
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

// ---- modes and size ----

pub const Modes = extern struct { in: api.DWORD, out: api.DWORD, in_cp: u32, out_cp: u32 };

pub fn getModes() ?Modes {
    const in = api.GetStdHandle(api.STD_INPUT_HANDLE) orelse return null;
    var m: Modes = .{ .in = 0, .out = 0, .in_cp = api.GetConsoleCP(), .out_cp = GetConsoleOutputCP() };
    if (api.GetConsoleMode(in, &m.in) == 0) return null;
    if (api.GetStdHandle(api.STD_OUTPUT_HANDLE)) |out| _ = api.GetConsoleMode(out, &m.out);
    return m;
}
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;

pub fn setModes(m: Modes) void {
    if (api.GetStdHandle(api.STD_INPUT_HANDLE)) |in| _ = api.SetConsoleMode(in, m.in);
    if (api.GetStdHandle(api.STD_OUTPUT_HANDLE)) |out| _ = api.SetConsoleMode(out, m.out);
    _ = api.SetConsoleCP(m.in_cp);
    _ = api.SetConsoleOutputCP(m.out_cp);
}

/// The modes cfmakeraw stands for: keys as VT input with no line editing, echo or Ctrl+C handling, window
/// resizes reported, and output interpreted as VT in UTF-8.
pub fn rawModes(m: Modes) Modes {
    return .{
        .in = api.ENABLE_VIRTUAL_TERMINAL_INPUT | api.ENABLE_WINDOW_INPUT,
        .out = m.out | api.ENABLE_PROCESSED_OUTPUT | api.ENABLE_VIRTUAL_TERMINAL_PROCESSING | api.DISABLE_NEWLINE_AUTO_RETURN,
        .in_cp = 65001,
        .out_cp = 65001,
    };
}

pub fn flushInput() void {
    if (api.GetStdHandle(api.STD_INPUT_HANDLE)) |in| _ = api.FlushConsoleInputBuffer(in);
}

/// The visible window of the console on `which`, in rows and columns.
pub fn windowSize(which: api.DWORD) ?[2]u16 {
    const h = api.GetStdHandle(which) orelse return null;
    var info: api.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (api.GetConsoleScreenBufferInfo(h, &info) == 0) return null;
    const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    const cols = info.srWindow.Right - info.srWindow.Left + 1;
    if (rows <= 0 or cols <= 0) return null;
    return .{ @intCast(rows), @intCast(cols) };
}
