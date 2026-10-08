// run-hidden — the launcher behind scheduledTasks.<name>.hideConsole.
//
//   run-hidden.exe <program> [arguments...]
//
// Task Scheduler can only start an executable; it cannot ask for
// CREATE_NO_WINDOW. A console program started directly by a task gets a
// console window before its own code runs, so `-WindowStyle Hidden` and the
// like can only hide a window that has already flashed. This program is
// GUI-subsystem (-mwindows), so starting it creates no console, and it starts
// the real command with CREATE_NO_WINDOW: a console session with no window,
// inherited by the command's own console children.
//
// The command runs inside a job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
// When Task Scheduler stops the task (it terminates this process, the task's
// engine process) or its execution time limit ends it, the job's last handle
// closes and the whole tree goes with it. When the command exits on its own,
// the limit is cleared first, so anything it deliberately left running (a
// daemon it spawned, a GUI program it launched) keeps running.
//
// The job also sets JOB_OBJECT_LIMIT_BREAKAWAY_OK: a process in the tree that
// starts a child with CREATE_BREAKAWAY_FROM_JOB puts that child outside the
// job, so the child outlives a stop. Only a child created with that flag
// leaves; every other process stays in the job and dies with it.
//
// Exit code: the command's, so the task's last result is the command's. If a
// call here fails, the Win32 error code instead.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// Everything after this program's own name in the raw command line, which is
// exactly the child's command line: CreateProcessW takes one string, so it is
// passed through untouched rather than split and re-quoted.
static const wchar_t *after_program_name(const wchar_t *p)
{
    if (*p == L'"') {
        p++;
        while (*p != L'\0' && *p != L'"') {
            p++;
        }
        if (*p == L'"') {
            p++;
        }
    } else {
        while (*p != L'\0' && *p != L' ' && *p != L'\t') {
            p++;
        }
    }
    while (*p == L' ' || *p == L'\t') {
        p++;
    }
    return p;
}

static int set_kill_on_close(HANDLE job, BOOL kill)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    ZeroMemory(&limits, sizeof limits);
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_BREAKAWAY_OK | (kill ? JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE : 0);
    return SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR args, int show)
{
    (void)instance;
    (void)previous;
    (void)args;
    (void)show;

    const wchar_t *rest = after_program_name(GetCommandLineW());
    if (*rest == L'\0') {
        return ERROR_BAD_ARGUMENTS;
    }

    // CreateProcessW may write to its command-line buffer, so hand it a copy.
    size_t bytes = (lstrlenW(rest) + 1) * sizeof(wchar_t);
    wchar_t *command = HeapAlloc(GetProcessHeap(), 0, bytes);
    if (command == NULL) {
        return ERROR_NOT_ENOUGH_MEMORY;
    }
    CopyMemory(command, rest, bytes);

    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job == NULL || !set_kill_on_close(job, TRUE)) {
        return (int)GetLastError();
    }

    STARTUPINFOW startup;
    ZeroMemory(&startup, sizeof startup);
    startup.cb = sizeof startup;
    PROCESS_INFORMATION child;
    ZeroMemory(&child, sizeof child);

    // Suspended until it is in the job, so nothing it starts can escape it.
    DWORD flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, flags, NULL, NULL, &startup, &child)) {
        return (int)GetLastError();
    }
    if (!AssignProcessToJobObject(job, child.hProcess) || ResumeThread(child.hThread) == (DWORD)-1) {
        DWORD error = GetLastError();
        TerminateProcess(child.hProcess, error);
        return (int)error;
    }
    CloseHandle(child.hThread);

    WaitForSingleObject(child.hProcess, INFINITE);
    DWORD code = 0;
    if (!GetExitCodeProcess(child.hProcess, &code)) {
        return (int)GetLastError();
    }

    // The command finished by itself: let whatever it left behind live.
    if (!set_kill_on_close(job, FALSE)) {
        return (int)GetLastError();
    }
    return (int)code;
}
