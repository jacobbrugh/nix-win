# run-hidden on a real Windows host: the launcher behind
# scheduledTasks.<name>.hideConsole.
#
#   pwsh -NoProfile -File tests/run-hidden-live.ps1 -Launcher <path>\run-hidden.exe
#
# Build the launcher with
#   nix build .#packages.x86_64-linux.run-hidden
# and copy result/bin/run-hidden.exe to the Windows side.
#
# Checks, in order:
#   1. the command's exit code is the launcher's exit code;
#   2. terminating the launcher (what a task stop does) kills the command and
#      everything it started;
#   3. a command that exits on its own leaves what it deliberately started
#      running;
#   4. no console window appears, against a positive control that does open
#      one, so the window probe is proven able to see one;
#   5. a child started with CREATE_BREAKAWAY_FROM_JOB survives terminating the
#      launcher;
#   6. under an intermediate job with KILL_ON_JOB_CLOSE and SILENT_BREAKAWAY_OK
#      (the shape of an interpreter launcher), a grandchild started without
#      that flag still dies with the launcher;
#   7. under that intermediate job, a grandchild started with the flag survives.
param(
    [Parameter(Mandatory)][string]$Launcher
)
$ErrorActionPreference = 'Stop'
$Launcher = (Resolve-Path -LiteralPath $Launcher).Path
$failures = 0

function Assert-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name -- $Detail" -ForegroundColor Red
        $script:failures++
    }
}

# Every process descended from $Root, by parent id (creation order guards
# against a recycled parent id).
function Get-Descendants([int]$Root) {
    $all = @(Get-CimInstance Win32_Process)
    $found = [System.Collections.Generic.List[object]]::new()
    $frontier = [System.Collections.Generic.Queue[object]]::new()
    $rootProc = $all | ForEach-Object { if ($_.ProcessId -eq $Root) { $_ } }
    if ($null -eq $rootProc) { return @() }
    $frontier.Enqueue($rootProc)
    while ($frontier.Count -gt 0) {
        $p = $frontier.Dequeue()
        foreach ($c in $all) {
            if ($c.ParentProcessId -eq $p.ProcessId -and $c.CreationDate -ge $p.CreationDate -and $c.ProcessId -ne $p.ProcessId) {
                $found.Add($c)
                $frontier.Enqueue($c)
            }
        }
    }
    return $found.ToArray()
}

function Wait-Descendant([int]$Root, [string]$Name) {
    for ($i = 0; $i -lt 100; $i++) {
        foreach ($d in (Get-Descendants $Root)) {
            if ($d.Name -eq $Name) { return [int]$d.ProcessId }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "no $Name appeared under pid $Root"
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class RunHiddenProbe {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    // Visible top-level console windows: the classic console host and the
    // terminal that may be registered as the default console host.
    public static HashSet<long> ConsoleWindows() {
        var found = new HashSet<long>();
        EnumWindows((h, _) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            var c = sb.ToString();
            if (c == "ConsoleWindowClass" || c == "CASCADIA_HOSTING_WINDOW_CLASS") found.Add(h.ToInt64());
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

# 1. Exit code.
$p = Start-Process -FilePath $Launcher -ArgumentList 'cmd.exe /c exit 7' -PassThru -Wait
Assert-Check 'exit code passes through' ($p.ExitCode -eq 7) "launcher exited $($p.ExitCode), want 7"

$p = Start-Process -FilePath $Launcher -ArgumentList 'no-such-program-run-hidden.exe' -PassThru -Wait
Assert-Check 'a command that cannot start reports the Win32 error' ($p.ExitCode -eq 2) "launcher exited $($p.ExitCode), want 2 (ERROR_FILE_NOT_FOUND)"

# 2. Terminating the launcher kills the tree.
$p = Start-Process -FilePath $Launcher -ArgumentList 'cmd.exe /c ping -n 60 127.0.0.1' -PassThru
$ping = Wait-Descendant $p.Id 'PING.EXE'
Stop-Process -Id $p.Id -Force
Start-Sleep -Milliseconds 500
$alive = $null -ne (Get-Process -Id $ping -ErrorAction SilentlyContinue)
Assert-Check 'terminating the launcher kills the command tree' (-not $alive) "ping pid $ping still running"
if ($alive) { Stop-Process -Id $ping -Force }

# 3. A command that exits by itself leaves what it started. The command
# (cmd /c start) is gone almost at once, so the started ping is found by its
# distinctive count rather than by walking a tree that no longer exists.
$p = Start-Process -FilePath $Launcher -ArgumentList 'cmd.exe /c start "" /b ping -n 37 127.0.0.1' -PassThru
$p.WaitForExit()
Start-Sleep -Milliseconds 500
$ping = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | ForEach-Object {
        if ($_.CommandLine -like '*-n 37 127.0.0.1*') { $_ } })
Assert-Check 'a normal exit leaves started processes running' ($ping.Count -eq 1) "found $($ping.Count) surviving ping process(es), want 1"
foreach ($x in $ping) { Stop-Process -Id $x.ProcessId -Force }

# 4. No console window, against a positive control.
$before = [RunHiddenProbe]::ConsoleWindows()
$control = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ping -n 4 127.0.0.1' -PassThru
Start-Sleep -Seconds 2
$during = [RunHiddenProbe]::ConsoleWindows()
$control.WaitForExit()
$controlSaw = @($during | ForEach-Object { if (-not $before.Contains($_)) { $_ } }).Count
Assert-Check 'control: a direct console launch opens a window the probe sees' ($controlSaw -gt 0) 'the probe saw no new console window, so check 4 proves nothing'

Start-Sleep -Seconds 1
$before = [RunHiddenProbe]::ConsoleWindows()
$p = Start-Process -FilePath $Launcher -ArgumentList 'cmd.exe /c ping -n 4 127.0.0.1' -PassThru
Start-Sleep -Seconds 2
$during = [RunHiddenProbe]::ConsoleWindows()
$p.WaitForExit()
$hiddenSaw = @($during | ForEach-Object { if (-not $before.Contains($_)) { $_ } }).Count
Assert-Check 'the launched command opens no console window' ($hiddenSaw -eq 0) "$hiddenSaw new console window(s)"

# 5-7. Breakaway. The helper starts `ping -n <count>`; the distinctive count
# finds it after the launcher is gone.
$helper = Join-Path $PSScriptRoot 'run-hidden-breakaway-helper.ps1'
function Get-Ping([int]$Count) {
    @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | ForEach-Object {
            if ($_.CommandLine -like "*-n $Count 127.0.0.1*") { $_ } })
}
function Test-Breakaway([int]$Count, [string]$HelperArgs) {
    $p = Start-Process -FilePath $Launcher -PassThru `
        -ArgumentList "pwsh.exe -NoProfile -NonInteractive -File `"$helper`" -Count $Count $HelperArgs"
    for ($i = 0; $i -lt 150 -and (Get-Ping $Count).Count -eq 0; $i++) { Start-Sleep -Milliseconds 100 }
    if ((Get-Ping $Count).Count -eq 0) {
        # CreateProcess refuses CREATE_BREAKAWAY_FROM_JOB when the job does not
        # allow breakaway; -1 fails every check below.
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return -1
    }
    Stop-Process -Id $p.Id -Force
    Start-Sleep -Milliseconds 500
    $left = Get-Ping $Count
    foreach ($x in $left) { Stop-Process -Id $x.ProcessId -Force }
    return $left.Count
}
$n = Test-Breakaway 41 '-Breakaway'
Assert-Check 'a child started with CREATE_BREAKAWAY_FROM_JOB survives the launcher' ($n -eq 1) "found $n surviving ping process(es), want 1"
$n = Test-Breakaway 42 '-SilentJob'
Assert-Check 'under a silent-breakaway job, a grandchild without the flag dies with the launcher' ($n -eq 0) "found $n surviving ping process(es), want 0"
$n = Test-Breakaway 43 '-SilentJob -Breakaway'
Assert-Check 'under a silent-breakaway job, a grandchild with the flag survives the launcher' ($n -eq 1) "found $n surviving ping process(es), want 1"

if ($failures -gt 0) {
    Write-Host "$failures check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all checks passed'
