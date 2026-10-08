# Helper for tests/run-hidden-live.ps1, run by the launcher under test.
#
# Optionally puts itself into a job of its own with KILL_ON_JOB_CLOSE and
# SILENT_BREAKAWAY_OK (the shape of a launcher that wraps an interpreter in such
# a job), then starts `ping -n <Count> 127.0.0.1`, with or without
# CREATE_BREAKAWAY_FROM_JOB, and waits forever. The test terminates the launcher
# and checks whether that ping survived.
param(
    [Parameter(Mandatory)][int]$Count,
    [switch]$Breakaway,
    [switch]$SilentJob
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class BreakawayHelper {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr attrs, IntPtr name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, ref ExtendedLimits info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string dir, ref StartupInfo si, out ProcessInformation pi);

    const uint KILL_ON_JOB_CLOSE = 0x2000, SILENT_BREAKAWAY_OK = 0x1000;
    const uint CREATE_NO_WINDOW = 0x08000000, CREATE_BREAKAWAY_FROM_JOB = 0x01000000;

    public static void JoinSilentJob() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
        if (job == IntPtr.Zero) throw new Win32Exception();
        var limits = new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags = KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK;
        if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(limits))) throw new Win32Exception();
        if (!AssignProcessToJobObject(job, GetCurrentProcess())) throw new Win32Exception();
        // The handle is deliberately kept open for the life of this process.
    }

    public static int Start(string commandLine, bool breakaway) {
        var si = new StartupInfo(); si.cb = Marshal.SizeOf(si);
        ProcessInformation pi;
        uint flags = CREATE_NO_WINDOW | (breakaway ? CREATE_BREAKAWAY_FROM_JOB : 0);
        if (!CreateProcessW(null, new System.Text.StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                flags, IntPtr.Zero, null, ref si, out pi)) throw new Win32Exception();
        return pi.dwProcessId;
    }
}
'@

if ($SilentJob) { [BreakawayHelper]::JoinSilentJob() }
$null = [BreakawayHelper]::Start("$env:SystemRoot\System32\PING.EXE -n $Count 127.0.0.1", [bool]$Breakaway)
[System.Threading.Thread]::Sleep([System.Threading.Timeout]::Infinite)
