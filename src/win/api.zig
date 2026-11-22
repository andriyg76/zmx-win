//! Win32 and Winsock declarations zmx's Windows port needs; Zig's std declares few of them.
const std = @import("std");

pub const BOOL = i32;
pub const DWORD = u32;
pub const WORD = u16;
pub const HANDLE = *anyopaque;
pub const HPCON = *anyopaque;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
pub const SOCKET_ERROR: i32 = -1;

pub const COORD = extern struct { X: i16, Y: i16 };
pub const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: u16,
    dwControlKeyState: DWORD,
};
pub const INPUT_RECORD = extern struct {
    EventType: WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        WindowBufferSizeEvent: COORD,
        _pad: [16]u8,
    },
};
pub const KEY_EVENT: WORD = 0x0001;
pub const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;
pub const CTRL_CLOSE_EVENT: DWORD = 2;
pub const CTRL_LOGOFF_EVENT: DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: DWORD = 6;

pub const FILE_TYPE_CHAR: DWORD = 0x0002;
pub const FILE_TYPE_PIPE: DWORD = 0x0003;

pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const ERROR_FILE_EXISTS: DWORD = 80;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const STILL_ACTIVE: DWORD = 259;

pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const DETACHED_PROCESS: DWORD = 0x00000008;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;
pub const CREATE_SUSPENDED: DWORD = 0x00000004;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
pub const PROCESS_TERMINATE: DWORD = 0x0001;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;

pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
pub const JobObjectExtendedLimitInformation: i32 = 9;

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};
pub const IO_COUNTERS = extern struct { r: [6]u64 };
pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};
pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{ .r = @splat(0) },
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetStdHandle(n: DWORD, h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileType(h: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreatePipe(r: *HANDLE, w: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disp: DWORD, flags: DWORD, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn CreateHardLinkW(new: [*:0]const u16, existing: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadConsoleInputW(h: HANDLE, buf: [*]INPUT_RECORD, n: DWORD, read: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushConsoleInputBuffer(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
pub extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreatePseudoConsole(size: COORD, in: HANDLE, out: HANDLE, flags: DWORD, hpc: *HPCON) callconv(.winapi) i32;
pub extern "kernel32" fn ResizePseudoConsole(hpc: HPCON, size: COORD) callconv(.winapi) i32;
pub extern "kernel32" fn ClosePseudoConsole(hpc: HPCON) callconv(.winapi) void;
pub extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attr: usize, value: ?*const anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn CreateProcessW(
    app: ?[*:0]const u16,
    cmd: ?[*:0]u16,
    psa: ?*SECURITY_ATTRIBUTES,
    tsa: ?*SECURITY_ATTRIBUTES,
    inherit: BOOL,
    flags: DWORD,
    env: ?*anyopaque,
    cwd: ?[*:0]const u16,
    si: *STARTUPINFOW,
    pi: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]u16, n: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
pub extern "kernel32" fn CreateJobObjectW(sa: ?*SECURITY_ATTRIBUTES, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: i32, info: *const anyopaque, len: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, proc: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, n: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
pub extern "kernel32" fn GetComputerNameExA(kind: i32, buf: [*]u8, n: *DWORD) callconv(.winapi) BOOL;

pub const WSADATA = extern struct { data: [408]u8 };
pub const WSAPOLLFD = extern struct { fd: SOCKET, events: i16, revents: i16 };
pub const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667e));
pub const FIONREAD: i32 = @bitCast(@as(u32, 0x4004667f));
pub const SD_SEND: i32 = 1;
pub const SD_BOTH: i32 = 2;

pub extern "ws2_32" fn WSAStartup(ver: WORD, data: *WSADATA) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
pub extern "ws2_32" fn socket(af: i32, t: i32, p: i32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn bind(s: SOCKET, a: *const anyopaque, l: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(s: SOCKET, b: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn connect(s: SOCKET, a: *const anyopaque, l: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn accept(s: SOCKET, a: ?*anyopaque, l: ?*i32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn send(s: SOCKET, b: [*]const u8, l: i32, f: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn recv(s: SOCKET, b: [*]u8, l: i32, f: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, arg: *u32) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAPoll(fds: [*]WSAPOLLFD, n: u32, t: i32) callconv(.winapi) i32;

pub const WSAEWOULDBLOCK: i32 = 10035;
pub const WSAEINPROGRESS: i32 = 10036;
pub const WSAEINTR: i32 = 10004;
pub const WSAEADDRINUSE: i32 = 10048;
pub const WSAECONNABORTED: i32 = 10053;
pub const WSAECONNRESET: i32 = 10054;
pub const WSAENOTCONN: i32 = 10057;
pub const WSAESHUTDOWN: i32 = 10058;
pub const WSAECONNREFUSED: i32 = 10061;
pub const WSAENAMETOOLONG: i32 = 10063;
pub const WSAEACCES: i32 = 10013;
pub const WSAEINVAL: i32 = 10022;
pub const WSAENOTSOCK: i32 = 10038;

/// Encodes UTF-8 `s` as a NUL-terminated UTF-16 string in `buf`.
pub fn wide(buf: []u16, s: []const u8) error{NameTooLong}![:0]u16 {
    const n = std.unicode.wtf8ToWtf16Le(buf[0 .. buf.len - 1], s) catch return error.NameTooLong;
    buf[n] = 0;
    return buf[0..n :0];
}

pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
pub extern "kernel32" fn AcquireSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) void;
pub const INIT_ONCE = extern struct { ptr: ?*anyopaque = null };
pub extern "kernel32" fn InitOnceExecuteOnce(once: *INIT_ONCE, f: *const fn (*INIT_ONCE, ?*anyopaque, ?*?*anyopaque) callconv(.winapi) BOOL, param: ?*anyopaque, ctx: ?*?*anyopaque) callconv(.winapi) BOOL;

/// Runs `f` once per `once`, however many threads call it.
pub fn callOnce(once: *INIT_ONCE, comptime f: fn () void) void {
    const S = struct {
        fn run(_: *INIT_ONCE, _: ?*anyopaque, _: ?*?*anyopaque) callconv(.winapi) BOOL {
            f();
            return 1;
        }
    };
    _ = InitOnceExecuteOnce(once, S.run, null, null);
}
