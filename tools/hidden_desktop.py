#!/usr/bin/env python
"""Run a child process on its own Windows desktop, boxed so it cannot hog the machine.

Two independent guarantees, because focus and load are two different problems
and fixing only one still leaves the desktop unusable:

1. **It cannot appear.** A Windows desktop object (below).
2. **It cannot starve you.** A job object that pins the whole process tree to
   all-but-two cores, runs it at idle priority, caps total memory, and kills
   every survivor when the handle closes.

The second half is the one that matters for Playwright. Chrome is a process
*tree* — browser, GPU, network, one renderer per site — and a browser booting a
WebGL app will happily take every core it can see. Priority alone is not enough:
idle-priority threads still get scheduled on all cores, and a GPU process at any
priority can wedge the compositor. The affinity mask is what makes the freeze
structurally impossible rather than merely unlikely.

Lifted from `C:\\FastProjects\\godot-forge\\hidden.py`, which is where this was
worked out and measured. The mechanism is a Windows *desktop object*
(`CreateDesktopW` — the kernel object, not the shell's "virtual desktops"): a
separate window-manager namespace with its own window list, its own z-order and
its own foreground window. `lpDesktop` is read by the kernel at `CreateProcess`,
before the child runs a single instruction, so nothing the child does afterwards
can put a window on the desktop you are looking at. There is no window-flag race
because there is no window on your desktop to race.

Descendants inherit it. A child spawned with `lpDesktop = NULL` — which is what
every ordinary launcher passes — lands on its parent's desktop. That is what
makes this work for **Playwright**: launch the *driver script* here and the
Chrome it starts is born on the hidden desktop too, so `headless=False` stays
available (real compositor, real GPU, real presented frames) without a window
ever appearing.

Two things godot-forge measured that carry over:

- Only the window manager is per-desktop; the GPU is not. Frames rendered here
  came out byte-identical to the same frames rendered on screen.
- Across a full run the foreground window on the real desktop never changed
  once, sampled every 50ms, while a fullscreen game held it.

Usage:

    import sys, hidden_desktop
    done = hidden_desktop.run([sys.executable, "my_playwright_driver.py"])
    print(done.stdout)

or from a shell:

    python C:/Users/udaha/.claude/tools/hidden_desktop.py python driver.py
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import tempfile
import time
from ctypes import wintypes
from pathlib import Path

WINDOWS = sys.platform == "win32"

if WINDOWS:
    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _u32 = ctypes.WinDLL("user32", use_last_error=True)

    _u32.CreateDesktopW.restype = wintypes.HANDLE
    _k32.CreateFileW.restype = wintypes.HANDLE
    _k32.CreateJobObjectW.restype = wintypes.HANDLE

    GENERIC_ALL = 0x10000000
    GENERIC_WRITE = 0x40000000
    FILE_SHARE_RW = 0x00000003
    CREATE_ALWAYS = 2
    FILE_ATTRIBUTE_NORMAL = 0x80
    STARTF_USESTDHANDLES = 0x00000100
    WAIT_TIMEOUT = 0x00000102
    INVALID_HANDLE = wintypes.HANDLE(-1).value

    CREATE_SUSPENDED = 0x00000004
    IDLE_PRIORITY_CLASS = 0x00000040
    BELOW_NORMAL_PRIORITY_CLASS = 0x00004000

    JOB_OBJECT_LIMIT_AFFINITY = 0x00000010
    JOB_OBJECT_LIMIT_PRIORITY_CLASS = 0x00000020
    JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200
    JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
    JobObjectBasicAccountingInformation = 1
    JobObjectExtendedLimitInformation = 9

    ULONG_PTR = ctypes.c_size_t

    class _JobBasicAccounting(ctypes.Structure):
        _fields_ = [
            ("TotalUserTime", ctypes.c_int64),
            ("TotalKernelTime", ctypes.c_int64),
            ("ThisPeriodTotalUserTime", ctypes.c_int64),
            ("ThisPeriodTotalKernelTime", ctypes.c_int64),
            ("TotalPageFaultCount", wintypes.DWORD),
            ("TotalProcesses", wintypes.DWORD),
            ("ActiveProcesses", wintypes.DWORD),
            ("TotalTerminatedProcesses", wintypes.DWORD),
        ]

    class _JobBasicLimits(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_int64),
            ("PerJobUserTimeLimit", ctypes.c_int64),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ULONG_PTR),
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class _IoCounters(ctypes.Structure):
        _fields_ = [(n, ctypes.c_uint64) for n in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class _JobExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", _JobBasicLimits),
            ("IoInfo", _IoCounters),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    class _StartupInfoW(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR),
            ("lpDesktop", wintypes.LPWSTR), ("lpTitle", wintypes.LPWSTR),
            ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
            ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD),
            ("dwXCountChars", wintypes.DWORD), ("dwYCountChars", wintypes.DWORD),
            ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
            ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
            ("lpReserved2", ctypes.POINTER(ctypes.c_byte)),
            ("hStdInput", wintypes.HANDLE), ("hStdOutput", wintypes.HANDLE),
            ("hStdError", wintypes.HANDLE),
        ]

    class _ProcessInformation(ctypes.Structure):
        _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
                    ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]

    class _SecurityAttributes(ctypes.Structure):
        _fields_ = [("nLength", wintypes.DWORD), ("lpSecurityDescriptor", wintypes.LPVOID),
                    ("bInheritHandle", wintypes.BOOL)]


DESKTOP = "claude_hidden"

# Exit code given to every process in the tree when `run()` kills it at the
# timeout (GNU `timeout` uses the same number). `run()` itself raises
# `subprocess.TimeoutExpired`, like `subprocess.run`; this is only what the
# killed processes report.
TIMEOUT_EXIT_CODE = 124


def _win_error(call: str) -> OSError:
    return ctypes.WinError(ctypes.get_last_error(), f"{call} failed")


def _inheritable_file(path: Path) -> int:
    sa = _SecurityAttributes(ctypes.sizeof(_SecurityAttributes), None, True)
    h = _k32.CreateFileW(str(path), GENERIC_WRITE, FILE_SHARE_RW, ctypes.byref(sa),
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, None)
    if h == INVALID_HANDLE:
        raise _win_error("CreateFileW")
    return h


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _active_processes(job) -> int:
    acct = _JobBasicAccounting()
    if not _k32.QueryInformationJobObject(job, JobObjectBasicAccountingInformation,
                                          ctypes.byref(acct), ctypes.sizeof(acct), None):
        return -1
    return acct.ActiveProcesses


def _kill_tree(job, exit_code: int, wait: float = 10.0) -> bool:
    """Terminate every process in the job and wait until they are really gone.

    `TerminateJobObject` (and `KILL_ON_JOB_CLOSE`) only *start* termination; it
    completes asynchronously. Until each process has exited, the file handles
    it inherited — our stdout.txt / stderr.txt — are still open, and deleting
    those files fails with a sharing violation. So wait, bounded, for the job's
    active-process count to reach zero. Returns whether it did.
    """
    _k32.TerminateJobObject(job, exit_code)
    deadline = time.monotonic() + wait
    while True:
        n = _active_processes(job)
        if n == 0:
            return True
        if n < 0 or time.monotonic() > deadline:
            return False
        time.sleep(0.02)


def _unlink_quietly(path: Path, wait: float = 2.0) -> None:
    """Delete a temp file, retrying briefly while something still holds it open.

    Never raises: a file still locked after `wait` is left behind rather than
    turning a finished run into a crash that loses its output.
    """
    deadline = time.monotonic() + wait
    while True:
        try:
            path.unlink(missing_ok=True)
            return
        except OSError:
            if time.monotonic() > deadline:
                return
            time.sleep(0.05)


def _make_job(cores: int | None, memory_mb: int) -> wintypes.HANDLE:
    """A job the whole child tree is born into, so no descendant escapes it.

    `KILL_ON_JOB_CLOSE` is the one that stops runs from accumulating: whatever
    happens to this script — clean exit, exception, being killed — every process
    in the tree dies when the handle closes. A Playwright driver that throws
    used to leave a browser behind, and three of those is a wedged machine.

    `BREAKAWAY_OK` is set because Chrome nests jobs of its own for sandboxing;
    without it the browser fails to start its renderers on older Windows. The
    limits still apply — a child may leave *this* job only if it asks, and
    Chrome's sandbox jobs are created inside it.
    """
    job = _k32.CreateJobObjectW(None, None)
    if not job:
        raise _win_error("CreateJobObjectW")

    total = os.cpu_count() or 4
    # Leave the user two cores no matter what. The point is not to be fast.
    keep = max(1, min(cores if cores else total - 2, total))
    info = _JobExtendedLimits()
    b = info.BasicLimitInformation
    b.LimitFlags = (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                    | JOB_OBJECT_LIMIT_PRIORITY_CLASS
                    | JOB_OBJECT_LIMIT_AFFINITY
                    | JOB_OBJECT_LIMIT_JOB_MEMORY
                    | JOB_OBJECT_LIMIT_BREAKAWAY_OK)
    b.PriorityClass = IDLE_PRIORITY_CLASS
    b.Affinity = (1 << keep) - 1
    info.BasicLimitInformation = b
    info.JobMemoryLimit = memory_mb * 1024 * 1024

    if not _k32.SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                        ctypes.byref(info), ctypes.sizeof(info)):
        _k32.CloseHandle(job)
        raise _win_error("SetInformationJobObject")
    return job


def run(cmd: list[str], cwd: Path | str | None = None, timeout: float = 1800.0,
        visible: bool = False, cores: int | None = None,
        memory_mb: int = 4096) -> subprocess.CompletedProcess:
    """Like subprocess.run(capture_output=True, text=True), boxed and out of sight.

    `visible=True` spawns on the caller's desktop instead — the only route by
    which a window ever reaches the screen, and never the fallback for one that
    failed. If the desktop cannot be created this raises rather than downgrading
    silently: the promise that it stays out of the way is the whole point, and a
    caller that disagrees can say so with `visible`.

    `cores` defaults to every core but two, `memory_mb` to 4 GB for the whole
    tree. Both are ceilings on the tree, not on one process.

    At `timeout` the whole tree is killed (each process exits with
    `TIMEOUT_EXIT_CODE`) and waited for, then `subprocess.TimeoutExpired` is
    raised with the output captured so far on `.stdout` / `.stderr` — the same
    contract as `subprocess.run`. Any descendant still running after the child
    exits normally is killed the same way before `run()` returns.
    """
    if visible or not WINDOWS:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              timeout=timeout)

    hdesk = _u32.CreateDesktopW(DESKTOP, None, None, 0, GENERIC_ALL, None)
    if not hdesk:
        raise OSError(
            f"cannot create the hidden desktop {DESKTOP!r} "
            f"(error {ctypes.get_last_error()}), so the child's window would "
            "have to open on your desktop. Refusing — pass visible=True to "
            "allow that deliberately.")

    job = _make_job(cores, memory_mb)
    tmp = Path(tempfile.mkdtemp(prefix="claude-hidden-"))
    out_path, err_path = tmp / "stdout.txt", tmp / "stderr.txt"
    h_out = h_err = None
    killed = False
    pi = _ProcessInformation()
    try:
        h_out, h_err = _inheritable_file(out_path), _inheritable_file(err_path)

        si = _StartupInfoW()
        si.cb = ctypes.sizeof(si)
        si.lpDesktop = "WinSta0\\" + DESKTOP  # the whole point of this module
        si.dwFlags = STARTF_USESTDHANDLES
        si.hStdInput = None
        si.hStdOutput = h_out
        si.hStdError = h_err

        # Suspended, so the limits are on before the first instruction runs —
        # the same reasoning as `lpDesktop`. A process that is allowed to run
        # first can spawn children that were never in the job.
        line = subprocess.list2cmdline(cmd)
        if not _k32.CreateProcessW(None, ctypes.create_unicode_buffer(line), None,
                                   None, True,
                                   CREATE_SUSPENDED | IDLE_PRIORITY_CLASS, None,
                                   str(cwd) if cwd else None,
                                   ctypes.byref(si), ctypes.byref(pi)):
            raise _win_error("CreateProcessW")
        if not _k32.AssignProcessToJobObject(job, pi.hProcess):
            _k32.TerminateProcess(pi.hProcess, 1)
            raise _win_error("AssignProcessToJobObject")
        if _k32.ResumeThread(pi.hThread) == wintypes.DWORD(-1).value:
            raise _win_error("ResumeThread")

        deadline = time.monotonic() + timeout
        timed_out = False
        while _k32.WaitForSingleObject(pi.hProcess, 200) == WAIT_TIMEOUT:
            if time.monotonic() > deadline:
                timed_out = True
                break
        # Kill the whole tree — not just the direct child — and wait for it to
        # be gone. On timeout that is bun/python *and* the browser it started;
        # after a normal exit it is any orphan still running, which the job's
        # kill-on-close would have killed anyway, only asynchronously and
        # while we were deleting files it still had open.
        _kill_tree(job, TIMEOUT_EXIT_CODE if timed_out else 1)
        killed = True
        code = wintypes.DWORD()
        _k32.GetExitCodeProcess(pi.hProcess, ctypes.byref(code))
        # Close the write ends before reading, or the tail can still be buffered.
        for h in (h_out, h_err):
            _k32.CloseHandle(h)
        h_out = h_err = None
        stdout, stderr = _read(out_path), _read(err_path)
        if timed_out:
            # Same shape as subprocess.run: partial output on the exception.
            raise subprocess.TimeoutExpired(cmd, timeout, output=stdout, stderr=stderr)
        return subprocess.CompletedProcess(cmd, code.value, stdout, stderr)
    finally:
        # Nothing here may raise: an exception from cleanup would replace the
        # result (or the TimeoutExpired carrying the partial output).
        for h in (h_out, h_err, pi.hProcess, pi.hThread, hdesk):
            if h:
                _k32.CloseHandle(h)
        # Tree dead before the job handle goes (kill-on-close would do it, but
        # without waiting) and before the files are deleted.
        if not killed:
            _kill_tree(job, 1)
        _k32.CloseHandle(job)
        for p in (out_path, err_path):
            _unlink_quietly(p)
        try:
            tmp.rmdir()
        except OSError:
            pass


if __name__ == "__main__":
    try:
        done = run(sys.argv[1:], cwd=Path.cwd())
    except subprocess.TimeoutExpired as e:
        sys.stdout.write(e.stdout or "")
        sys.stderr.write(e.stderr or "")
        sys.exit(TIMEOUT_EXIT_CODE)
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    sys.exit(done.returncode)
