// A process under its own pseudo console, the way agterm-win starts a pane: `zmx attach` gets a real console, so it
// attaches as a terminal client rather than a run/send one. Output is collected as it arrives; DSR and DA queries are
// answered, since nothing else stands in for the terminal.
using System;
using System.Collections;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class ZmxConPty : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    struct Coord { public short X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(Coord size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr pc);
    [DllImport("kernel32.dll")]
    static extern void ClosePseudoConsole(IntPtr pc);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnSize);
    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string currentDirectory, ref StartupInfoEx startupInfo, out ProcessInformation info);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    const uint ExtendedStartupInfoPresent = 0x00080000, CreateUnicodeEnvironment = 0x00000400;
    static readonly IntPtr PseudoConsoleAttribute = (IntPtr)0x00020016;

    IntPtr console;
    readonly FileStream input, output;
    readonly StringBuilder text = new StringBuilder();
    readonly Thread reader;
    public System.Diagnostics.Process Process { get; }

    public ZmxConPty(string commandLine, IDictionary environment, string workingDirectory, short rows, short cols)
    {
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
            throw new Win32Exception();
        int hr = CreatePseudoConsole(new Coord { X = cols, Y = rows }, inRead, outWrite, 0, out console);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        inRead.Dispose();
        outWrite.Dispose();
        input = new FileStream(inWrite, FileAccess.Write);
        output = new FileStream(outRead, FileAccess.Read);

        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        IntPtr list = Marshal.AllocHGlobal(size);
        IntPtr block = EnvironmentBlock(environment);
        try
        {
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Win32Exception();
            if (!UpdateProcThreadAttribute(list, 0, PseudoConsoleAttribute, console, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception();
            var startup = new StartupInfoEx { lpAttributeList = list };
            startup.StartupInfo.cb = Marshal.SizeOf<StartupInfoEx>();
            ProcessInformation info;
            if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    ExtendedStartupInfoPresent | CreateUnicodeEnvironment, block, workingDirectory, ref startup, out info))
                throw new Win32Exception();
            Process = System.Diagnostics.Process.GetProcessById(info.dwProcessId);
            CloseHandle(info.hThread);
            CloseHandle(info.hProcess);
        }
        finally
        {
            DeleteProcThreadAttributeList(list);
            Marshal.FreeHGlobal(list);
            Marshal.FreeHGlobal(block);
        }
        reader = new Thread(Read) { IsBackground = true };
        reader.Start();
    }

    static IntPtr EnvironmentBlock(IDictionary environment)
    {
        var keys = new string[environment.Count];
        environment.Keys.CopyTo(keys, 0);
        Array.Sort(keys, StringComparer.OrdinalIgnoreCase);
        var block = new StringBuilder();
        foreach (var key in keys) block.Append(key).Append('=').Append(environment[key]).Append('\0');
        block.Append('\0');
        return Marshal.StringToHGlobalUni(block.ToString());
    }

    void Read()
    {
        var buffer = new byte[8192];
        var decoder = new UTF8Encoding(false).GetDecoder();
        var chars = new char[8192];
        try
        {
            int n;
            while ((n = output.Read(buffer, 0, buffer.Length)) > 0)
            {
                int count = decoder.GetChars(buffer, 0, n, chars, 0);
                var chunk = new string(chars, 0, count);
                lock (text) text.Append(chunk);
                if (chunk.Contains("\x1b[6n")) Write("\x1b[1;1R");
                if (chunk.Contains("\x1b[c") || chunk.Contains("\x1b[0c")) Write("\x1b[?1;0c");
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public string Output { get { lock (text) return text.ToString(); } }

    public void Write(string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        lock (input) { input.Write(bytes, 0, bytes.Length); input.Flush(); }
    }

    public void Dispose()
    {
        try { if (!Process.HasExited) Process.Kill(); } catch (InvalidOperationException) { }
        if (console != IntPtr.Zero) { ClosePseudoConsole(console); console = IntPtr.Zero; }
        input.Dispose();
        output.Dispose();
    }
}
