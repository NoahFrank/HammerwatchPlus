"""Win32 plumbing for GameLab: window lookup, focus-free input messages, DLL injection,
foreground sampling. No function here touches the real keyboard, mouse, or focus:
input goes to one HWND through PostMessageW, which never moves the cursor or raises
a window (docs/PLAYBOOK.md, Phase 6 component 8)."""
from __future__ import annotations

import ctypes
import os
import subprocess
import threading
import time
from ctypes import wintypes

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)

u32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
u32.MapVirtualKeyW.restype = wintypes.UINT
u32.GetForegroundWindow.restype = wintypes.HWND
u32.WindowFromPoint.argtypes = [wintypes.POINT]
u32.WindowFromPoint.restype = wintypes.HWND
u32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
u32.GetAncestor.restype = wintypes.HWND
k32.VirtualAllocEx.restype = wintypes.LPVOID
k32.VirtualAllocEx.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t, wintypes.DWORD, wintypes.DWORD]
k32.WriteProcessMemory.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.LPCVOID, ctypes.c_size_t, ctypes.c_void_p]
k32.CreateRemoteThread.restype = wintypes.HANDLE
k32.CreateRemoteThread.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t, wintypes.LPVOID,
                                   wintypes.LPVOID, wintypes.DWORD, wintypes.LPVOID]
k32.GetModuleHandleW.restype = wintypes.HMODULE
k32.GetProcAddress.restype = wintypes.LPVOID
k32.GetProcAddress.argtypes = [wintypes.HMODULE, wintypes.LPCSTR]
ntdll = ctypes.WinDLL("ntdll")
ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]

CREATE_SUSPENDED = 0x4

WM_KEYDOWN, WM_KEYUP, WM_CHAR = 0x0100, 0x0101, 0x0102
WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP = 0x0200, 0x0201, 0x0202
VK = {"enter": 0x0D, "escape": 0x1B, "console": 0xC0, "backspace": 0x08, "tab": 0x09,
      "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27, "space": 0x20}
VK.update({c: ord(c.upper()) for c in "abcdefghijklmnopqrstuvwxyz0123456789"})


def windows_of(pid: int) -> list[dict]:
    """Top-level windows of `pid` on the calling thread's desktop."""
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def each(h, _):
        owner = wintypes.DWORD()
        u32.GetWindowThreadProcessId(h, ctypes.byref(owner))
        if owner.value == pid:
            r = wintypes.RECT()
            u32.GetClientRect(h, ctypes.byref(r))
            title, cls = ctypes.create_unicode_buffer(256), ctypes.create_unicode_buffer(256)
            u32.GetWindowTextW(h, title, 256)
            u32.GetClassNameW(h, cls, 256)
            found.append({"hwnd": h, "title": title.value, "class": cls.value, "w": r.right, "h": r.bottom,
                          "visible": bool(u32.IsWindowVisible(h))})
        return True
    u32.EnumWindows(each, 0)
    return found


def game_window(pid: int) -> int | None:
    """The SDL window HWR2 renders into (window topology: docs/RE_NOTES.md 2026-10-17)."""
    for w in windows_of(pid):
        if w["class"] == "SDL_app" and w["visible"]:
            return w["hwnd"]
    return None


def key(hwnd: int, vk: int, hold: float = 0.05) -> None:
    sc = u32.MapVirtualKeyW(vk, 0)
    u32.PostMessageW(hwnd, WM_KEYDOWN, vk, 1 | (sc << 16))
    if hold:
        time.sleep(hold)
    u32.PostMessageW(hwnd, WM_KEYUP, vk, 1 | (sc << 16) | (0xC0 << 24))
    if hold:
        time.sleep(0.03)


def text(hwnd: int, s: str, gap: float = 0.004) -> None:
    for ch in s:
        u32.PostMessageW(hwnd, WM_CHAR, ord(ch), 1)
        if gap:
            time.sleep(gap)


def click(hwnd: int, x: int, y: int) -> None:
    """Left click at client coordinates (x, y): message only, the cursor never moves."""
    lp = (y << 16) | (x & 0xFFFF)
    u32.PostMessageW(hwnd, WM_MOUSEMOVE, 0, lp)
    time.sleep(0.05)
    u32.PostMessageW(hwnd, WM_LBUTTONDOWN, 1, lp)
    time.sleep(0.05)
    u32.PostMessageW(hwnd, WM_LBUTTONUP, 0, lp)


def minimize(hwnd: int) -> bool:
    """SW_SHOWMINNOACTIVE: minimized, and the active window stays whatever it was."""
    u32.ShowWindow(hwnd, 7)
    return bool(u32.IsIconic(hwnd))


def restore_noactivate(hwnd: int) -> bool:
    """SW_SHOWNOACTIVATE: back from minimized at its last size, not activated. True if it
    was minimized. The lab window lives on the hidden desktop, so nothing appears to the user."""
    if not u32.IsIconic(hwnd):
        return False
    u32.ShowWindow(hwnd, 4)
    return True


GWL_EXSTYLE, WS_EX_NOACTIVATE = -20, 0x08000000
u32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
u32.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
u32.SetWindowLongPtrW.restype = ctypes.c_ssize_t
u32.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]


def taskbar_add(hwnd: int) -> bool:
    """ITaskbarList::AddTab(hwnd) through raw COM: gives the window its taskbar button. It
    neither activates nor raises the window (ActivateTab would; it is not called)."""
    ole = ctypes.WinDLL("ole32")
    ole.CoInitialize(None)
    clsid, iid = (ctypes.create_string_buffer(16) for _ in range(2))
    ole.CLSIDFromString("{56FDF344-FD6D-11d0-958A-006097C9A090}", clsid)   # CLSID_TaskbarList
    ole.CLSIDFromString("{56FDF342-FD6D-11d0-958A-006097C9A090}", iid)     # IID_ITaskbarList
    obj = ctypes.c_void_p()
    if ole.CoCreateInstance(clsid, None, 1, iid, ctypes.byref(obj)) != 0 or not obj:   # CLSCTX_INPROC_SERVER
        return False
    vtbl = ctypes.cast(ctypes.cast(obj, ctypes.POINTER(ctypes.c_void_p))[0], ctypes.POINTER(ctypes.c_void_p))
    method = lambda i, *types: ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, *types)(vtbl[i])  # noqa: E731
    ok = method(3)(obj) == 0 and method(4, wintypes.HWND)(obj, hwnd) == 0             # HrInit, AddTab
    method(2)(obj)                                                                    # Release
    return ok


def allow_activation(hwnd: int) -> dict:
    """Watch mode, at the first frame: clear the WS_EX_NOACTIVATE the shim gave the game
    window at creation (tools/capture_shim) and give it its taskbar button, so from now on
    a human may click it. Only a style bit and the shell's button list change: nothing is
    activated, raised or focused here."""
    before = u32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
    if before & WS_EX_NOACTIVATE:
        u32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, before & ~WS_EX_NOACTIVATE)
    after = u32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
    return {"had_noactivate": bool(before & WS_EX_NOACTIVATE), "cleared": not after & WS_EX_NOACTIVATE,
            "ex_before": hex(before & 0xFFFFFFFF), "ex_after": hex(after & 0xFFFFFFFF),
            "taskbar_button": taskbar_add(hwnd) if before & WS_EX_NOACTIVATE else None}


def inject(proc: subprocess.Popen, dll: str, timeout_ms: int = 10000) -> bool:
    """LoadLibraryW(dll) inside `proc` via a remote thread. True when the thread ran and
    returned a module handle."""
    h = int(proc._handle)
    data = ctypes.create_unicode_buffer(dll)
    size = ctypes.sizeof(data)
    mem = k32.VirtualAllocEx(h, None, size, 0x3000, 0x04)        # MEM_COMMIT|RESERVE, RW
    if not mem or not k32.WriteProcessMemory(h, mem, data, size, None):
        return False
    load = k32.GetProcAddress(k32.GetModuleHandleW("kernel32.dll"), b"LoadLibraryW")
    th = k32.CreateRemoteThread(h, None, 0, load, mem, 0, None)
    if not th:
        return False
    k32.WaitForSingleObject(th, timeout_ms)
    code = wintypes.DWORD()
    k32.GetExitCodeThread(th, ctypes.byref(code))
    k32.CloseHandle(th)
    return code.value != 0


def resume(proc: subprocess.Popen) -> bool:
    """Resume a process started with creationflags=CREATE_SUSPENDED (after inject())."""
    return ntdll.NtResumeProcess(int(proc._handle)) == 0


class LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.UINT), ("dwTime", wintypes.DWORD)]


def idle_ms() -> int:
    """Milliseconds since the last real keyboard/mouse input on this session (GetLastInputInfo).
    PostMessage input to the game does not count: it never reaches the input queue."""
    info = LASTINPUTINFO(ctypes.sizeof(LASTINPUTINFO), 0)
    u32.GetLastInputInfo(ctypes.byref(info))
    return (k32.GetTickCount() - info.dwTime) & 0xFFFFFFFF


def process_started(pid: int) -> float | None:
    """Process creation time as a Unix timestamp (GetProcessTimes), None if unreadable."""
    h = k32.OpenProcess(0x1000, False, pid)        # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return None
    c, e, kt, ut = (wintypes.FILETIME() for _ in range(4))
    ok = k32.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kt), ctypes.byref(ut))
    k32.CloseHandle(h)
    if not ok:
        return None
    return ((c.dwHighDateTime << 32) | c.dwLowDateTime) / 1e7 - 11644473600


USER_INPUT_MS = 1500     # a focus change this soon after real input is the user's own


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]


k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE


def ancestors(pid: int) -> list[int]:
    """Parent chain of pid (CreateToolhelp32Snapshot), nearest first."""
    snap = k32.CreateToolhelp32Snapshot(0x2, 0)    # TH32CS_SNAPPROCESS
    parent = {}
    e = PROCESSENTRY32W()
    e.dwSize = ctypes.sizeof(e)
    ok = k32.Process32FirstW(snap, ctypes.byref(e))
    while ok:
        parent[e.th32ProcessID] = e.th32ParentProcessID
        ok = k32.Process32NextW(snap, ctypes.byref(e))
    k32.CloseHandle(snap)
    chain, seen = [], {pid}
    while (pid := parent.get(pid)) and pid not in seen:
        chain.append(pid)
        seen.add(pid)
    return chain


class ForegroundSampler:
    """Samples the real desktop's foreground window every `every` seconds from the
    launching process. `report()` says whether it ever left the starting window, lists
    every switch, and classes each one: "user" when real keyboard/mouse input came
    less than USER_INPUT_MS before it and the new owner is not a descendant of this
    launcher (the GameLab tree: runner, game); "unexplained" otherwise."""

    def __init__(self, every: float = 0.05, game_dir: str | None = None):
        self.every, self.samples, self._stop = every, [], threading.Event()
        self.t0 = time.time()
        self.me = os.getpid()
        self.start_hwnd = u32.GetForegroundWindow()
        self.switches: list[dict] = []
        # lab: every second, every top-level window on this (the user's input) desktop is
        # checked for an owner whose image lives in game_dir; the hidden desktop's windows
        # are invisible to EnumWindows from here, so any hit is a leak
        self.game_dir = game_dir.lower() if game_dir else None
        self.leaks: list[dict] = []
        self.window_scans = 0
        self._images: dict[int, str] = {}
        self._t = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        last = self.start_hwnd
        while not self._stop.is_set():
            h = u32.GetForegroundWindow()
            pid = wintypes.DWORD()
            u32.GetWindowThreadProcessId(h, ctypes.byref(pid))
            self.samples.append((h, pid.value))
            if self.game_dir and len(self.samples) % 20 == 1:
                self._scan_windows()
            if h != last:
                # who took it is read now, while the process and window still exist: the image
                # name resolved at report() time is empty once the game has exited
                now = time.time()
                title, cls = ctypes.create_unicode_buffer(256), ctypes.create_unicode_buffer(256)
                u32.GetWindowTextW(h, title, 256)
                u32.GetClassNameW(h, cls, 256)
                # what the user's input could have done: the window under the cursor (and its
                # owner) and whether a mouse button is down, all read-only
                pt = wintypes.POINT()
                u32.GetCursorPos(ctypes.byref(pt))
                under = u32.GetAncestor(u32.WindowFromPoint(pt), 2)     # GA_ROOT
                upid = wintypes.DWORD()
                u32.GetWindowThreadProcessId(under, ctypes.byref(upid))
                buttons = [n for n, vk in (("L", 1), ("R", 2), ("M", 4)) if u32.GetAsyncKeyState(vk) & 0x8000]
                self.switches.append({"t": round(now - self.t0, 2), "at": time.strftime("%H:%M:%S", time.localtime(now))
                                      + f".{int(now * 1000) % 1000:03d}", "pid": pid.value,
                                      "idle_ms": idle_ms(), "started": process_started(pid.value),
                                      "ours": self.me in ancestors(pid.value) or pid.value == self.me,
                                      "image": process_image_name(pid.value), "hwnd": h or 0,
                                      "class": cls.value, "title": title.value,
                                      "under_cursor_pid": upid.value, "buttons": "".join(buttons)})
                last = h
            time.sleep(self.every)

    def _scan_windows(self):
        found = []
        cb_t = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

        def cb(hwnd, _):
            pid = wintypes.DWORD()
            u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            found.append((hwnd, pid.value))
            return True

        u32.EnumWindows(cb_t(cb), 0)
        self.window_scans += 1
        for hwnd, pid in found:
            if pid not in self._images:
                self._images[pid] = process_image(pid).lower()
            if self._images[pid].startswith(self.game_dir):
                self.leaks.append({"t": round(time.time() - self.t0, 2), "pid": pid, "hwnd": hwnd})

    def __enter__(self):
        self._t.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._t.join()

    def report(self, forbidden_pids: set[int] = frozenset()) -> dict:
        owners = sorted({p for _, p in self.samples})
        for sw in self.switches:
            sw["image"] = sw.get("image") or process_image_name(sw["pid"])
            sw["cause"] = "user" if (not sw["ours"] and sw["idle_ms"] < USER_INPUT_MS
                                     and sw["pid"] not in forbidden_pids) else "unexplained"
        return {"samples": len(self.samples), "changed": bool(self.switches),
                "owner_pids": owners, "forbidden_seen": sorted(set(owners) & set(forbidden_pids)),
                "switches": self.switches,
                "unexplained": sum(1 for sw in self.switches if sw["cause"] != "user"),
                "window_scans": self.window_scans, "game_windows_on_input_desktop": self.leaks[:20]}


def process_image(pid: int) -> str:
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return ""
    buf = ctypes.create_unicode_buffer(1024)
    size = wintypes.DWORD(1024)
    k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
    k32.CloseHandle(h)
    return buf.value


def process_image_name(pid: int) -> str:
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return ""
    buf = ctypes.create_unicode_buffer(1024)
    size = wintypes.DWORD(1024)
    k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
    k32.CloseHandle(h)
    return buf.value.rsplit("\\", 1)[-1]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


def print_window(hwnd: int, flags: int = 2):
    """PrintWindow(hwnd, flags) of the client area into a PIL image (None on failure).
    flags 1 = PW_CLIENTONLY, 2 = PW_RENDERFULLCONTENT (DWM redirection, needed for GPU windows)."""
    from PIL import Image
    g32 = ctypes.WinDLL("gdi32")
    g32.CreateCompatibleDC.restype = wintypes.HDC
    g32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
    g32.SelectObject.restype = wintypes.HGDIOBJ
    u32.GetDC.restype = wintypes.HDC
    H = ctypes.c_void_p
    g32.CreateCompatibleDC.argtypes = [H]
    g32.CreateCompatibleBitmap.argtypes = [H, ctypes.c_int, ctypes.c_int]
    g32.SelectObject.argtypes = [H, H]
    g32.GetDIBits.argtypes = [H, H, wintypes.UINT, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
    g32.DeleteObject.argtypes = [H]
    g32.DeleteDC.argtypes = [H]
    u32.GetDC.argtypes = [wintypes.HWND]
    u32.ReleaseDC.argtypes = [wintypes.HWND, H]
    u32.PrintWindow.argtypes = [wintypes.HWND, H, wintypes.UINT]
    rect = wintypes.RECT()
    u32.GetClientRect(wintypes.HWND(hwnd), ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w <= 0 or h <= 0:
        return None
    wdc = u32.GetDC(wintypes.HWND(hwnd))
    mdc = g32.CreateCompatibleDC(wdc)
    bmp = g32.CreateCompatibleBitmap(wdc, w, h)
    old = g32.SelectObject(mdc, bmp)
    ok = u32.PrintWindow(wintypes.HWND(hwnd), mdc, flags | 1)
    bi = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    g32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bi), 0)
    g32.SelectObject(mdc, old)
    g32.DeleteObject(bmp)
    g32.DeleteDC(mdc)
    u32.ReleaseDC(wintypes.HWND(hwnd), wdc)
    if not ok:
        return None
    return Image.frombuffer("RGB", (w, h), bytes(buf), "raw", "BGRX", 0, 1)
