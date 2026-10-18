/* hwr2_capture.dll - in-process frame capture for GameLab (lab mode, hidden desktop).

   PrintWindow returns a blank image for HWR2's OpenGL window on a hidden desktop (no
   compositor). This DLL is injected into the GameLab copy of HWR2.exe by the launcher and
   replaces the exe's import of gdi32!SwapBuffers (bgfx's WGL backend presents with it).
   On each swap it looks for a request file in the working directory; when present it
   reads the back buffer with glReadPixels, writes a BMP to the path named in the request
   (via a .tmp + rename) and deletes the request. Nothing else is touched, and GL state
   it changes (read framebuffer, pack buffer, pack alignment, read buffer) is restored.

   Request file:  gamelab_capture.req   (one line: absolute output path ending in .bmp)
   Log lines:     gamelab_capture.log   (appended; injection, each capture, errors)

   It also replaces the exe's import of shell32!SHGetKnownFolderPath: when the launcher sets
   GAMELAB_LOCALAPPDATA, FOLDERID_LocalAppData resolves to that directory, so the game's own
   save backups (<LocalAppData>/HeroesofHammerwatch2/save_backups) land in the GameLab game
   dir instead of the user's profile. The game resolves the folder through the shell API, not
   the LOCALAPPDATA variable, so the hook must be in before the first call: the launcher
   starts HWR2.exe suspended, injects, then resumes. Every folder request is logged.

   It also hooks SDL2.dll's window-activation imports (see "focus" below): logged always,
   made non-activating in watch mode (GAMELAB_NO_ACTIVATE=1).

   Build: gcc -shared -O2 -Wall -o ../bin/hwr2_capture.dll hwr2_capture.c -lgdi32 -lopengl32 -lole32
*/
#include <windows.h>
#include <stdio.h>
#include <objbase.h>

typedef void (WINAPI *PFNGLREADPIXELS)(int, int, int, int, unsigned, unsigned, void *);
typedef void (WINAPI *PFNGLGETINTEGERV)(unsigned, int *);
typedef void (WINAPI *PFNGLPIXELSTOREI)(unsigned, int);
typedef void (WINAPI *PFNGLREADBUFFER)(unsigned);
typedef void (WINAPI *PFNGLBINDFRAMEBUFFER)(unsigned, unsigned);
typedef void (WINAPI *PFNGLBINDBUFFER)(unsigned, unsigned);
typedef PROC (WINAPI *PFNWGLGETPROCADDRESS)(LPCSTR);
typedef BOOL (WINAPI *PFNSWAPBUFFERS)(HDC);
typedef HRESULT (WINAPI *PFNSHGETKNOWNFOLDERPATH)(const GUID *, DWORD, HANDLE, PWSTR *);

#define GL_RGBA 0x1908
#define GL_BGRA 0x80E1
#define GL_UNSIGNED_BYTE 0x1401
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_READ_BUFFER 0x0C02
#define GL_BACK 0x0405
#define GL_VIEWPORT 0x0BA2
#define GL_READ_FRAMEBUFFER 0x8CA8
#define GL_READ_FRAMEBUFFER_BINDING 0x8CAA
#define GL_PIXEL_PACK_BUFFER 0x88EB
#define GL_PIXEL_PACK_BUFFER_BINDING 0x88ED

static PFNSWAPBUFFERS real_swap;
static PFNSHGETKNOWNFOLDERPATH real_known_folder;
/* FOLDERID_LocalAppData {F1B32785-6FBA-4FCF-9D55-7B8E7F157091} */
static const GUID LOCAL_APPDATA = {0xF1B32785, 0x6FBA, 0x4FCF, {0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}};
static PFNGLREADPIXELS glReadPixels_;
static PFNGLGETINTEGERV glGetIntegerv_;
static PFNGLPIXELSTOREI glPixelStorei_;
static PFNGLREADBUFFER glReadBuffer_;
static PFNGLBINDFRAMEBUFFER glBindFramebuffer_;
static PFNGLBINDBUFFER glBindBuffer_;
static unsigned long frames;

static void shim_log(const char *fmt, ...)
{
    FILE *f = fopen("gamelab_capture.log", "a");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "[%02d:%02d:%02d.%03d] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int load_gl(void)
{
    if (glReadPixels_) return 1;
    HMODULE gl = GetModuleHandleA("opengl32.dll");
    if (!gl) return 0;
    PFNWGLGETPROCADDRESS wglGPA = (PFNWGLGETPROCADDRESS)GetProcAddress(gl, "wglGetProcAddress");
    glReadPixels_ = (PFNGLREADPIXELS)GetProcAddress(gl, "glReadPixels");
    glGetIntegerv_ = (PFNGLGETINTEGERV)GetProcAddress(gl, "glGetIntegerv");
    glPixelStorei_ = (PFNGLPIXELSTOREI)GetProcAddress(gl, "glPixelStorei");
    glReadBuffer_ = (PFNGLREADBUFFER)GetProcAddress(gl, "glReadBuffer");
    if (wglGPA) {
        glBindFramebuffer_ = (PFNGLBINDFRAMEBUFFER)wglGPA("glBindFramebuffer");
        glBindBuffer_ = (PFNGLBINDBUFFER)wglGPA("glBindBuffer");
    }
    return glReadPixels_ && glGetIntegerv_ && glPixelStorei_ && glReadBuffer_;
}

static void capture(const char *path)
{
    if (!load_gl()) { shim_log("ERR opengl32 functions not found"); return; }
    int vp[4] = {0}, prevRead = 0, prevPack = 0, prevAlign = 4, prevBuf = GL_BACK;
    glGetIntegerv_(GL_VIEWPORT, vp);
    HWND hwnd = WindowFromDC(wglGetCurrentDC());
    RECT rc; int w = vp[2], h = vp[3];
    if (hwnd && GetClientRect(hwnd, &rc)) { w = rc.right; h = rc.bottom; }
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) { shim_log("ERR bad size %dx%d", w, h); return; }
    glGetIntegerv_(GL_PACK_ALIGNMENT, &prevAlign);
    glGetIntegerv_(GL_READ_BUFFER, &prevBuf);
    if (glBindFramebuffer_) { glGetIntegerv_(GL_READ_FRAMEBUFFER_BINDING, &prevRead); glBindFramebuffer_(GL_READ_FRAMEBUFFER, 0); }
    if (glBindBuffer_) { glGetIntegerv_(GL_PIXEL_PACK_BUFFER_BINDING, &prevPack); glBindBuffer_(GL_PIXEL_PACK_BUFFER, 0); }
    glPixelStorei_(GL_PACK_ALIGNMENT, 4);
    glReadBuffer_(GL_BACK);
    size_t n = (size_t)w * h * 4;
    unsigned char *px = (unsigned char *)malloc(n);
    if (px) glReadPixels_(0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, px);
    glReadBuffer_(prevBuf);
    glPixelStorei_(GL_PACK_ALIGNMENT, prevAlign);
    if (glBindFramebuffer_) glBindFramebuffer_(GL_READ_FRAMEBUFFER, prevRead);
    if (glBindBuffer_) glBindBuffer_(GL_PIXEL_PACK_BUFFER, prevPack);
    if (!px) { shim_log("ERR out of memory"); return; }

    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) { shim_log("ERR cannot write %s", tmp); free(px); return; }
    BITMAPFILEHEADER fh = {0}; BITMAPINFOHEADER ih = {0};
    fh.bfType = 0x4D42; fh.bfOffBits = sizeof fh + sizeof ih; fh.bfSize = fh.bfOffBits + (DWORD)n;
    ih.biSize = sizeof ih; ih.biWidth = w; ih.biHeight = h;   /* bottom-up, as GL returns it */
    ih.biPlanes = 1; ih.biBitCount = 32; ih.biCompression = BI_RGB; ih.biSizeImage = (DWORD)n;
    fwrite(&fh, sizeof fh, 1, f); fwrite(&ih, sizeof ih, 1, f); fwrite(px, 1, n, f);
    fclose(f);
    free(px);
    DeleteFileA(path);
    if (!MoveFileA(tmp, path)) { shim_log("ERR rename to %s failed (%lu)", path, GetLastError()); return; }
    shim_log("captured frame %lu %dx%d -> %s", frames, w, h, path);
}

static BOOL WINAPI hooked_swap(HDC hdc)
{
    frames++;
    if ((frames & 3) == 0) {
        FILE *req = fopen("gamelab_capture.req", "rb");
        if (req) {
            char path[MAX_PATH] = {0};
            size_t got = fread(path, 1, sizeof path - 1, req);
            fclose(req);
            while (got && (path[got - 1] == '\n' || path[got - 1] == '\r' || path[got - 1] == ' ')) path[--got] = 0;
            DeleteFileA("gamelab_capture.req");
            if (got) capture(path);
        }
    }
    return real_swap(hdc);
}

static HRESULT WINAPI hooked_known_folder(const GUID *id, DWORD flags, HANDLE token, PWSTR *out)
{
    WCHAR lab[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"GAMELAB_LOCALAPPDATA", lab, MAX_PATH);
    int redirect = id && IsEqualGUID(id, &LOCAL_APPDATA) && n > 0 && n < MAX_PATH;
    shim_log("SHGetKnownFolderPath {%08lX-...}%s", id ? id->Data1 : 0UL, redirect ? " -> GAMELAB_LOCALAPPDATA" : " (passed through)");
    if (!redirect)
        return real_known_folder(id, flags, token, out);
    size_t bytes = (n + 1) * sizeof(WCHAR);
    *out = (PWSTR)CoTaskMemAlloc(bytes);
    if (!*out) return E_OUTOFMEMORY;
    memcpy(*out, lab, bytes);
    return S_OK;
}

/* ---- focus: SDL2.dll is the only module that imports the user32 calls that can activate a
   window (HWR2.exe imports none of them; objdump -p, docs/RE_NOTES.md 2026-10-17). Every call
   is logged with the foreground before and after it. With GAMELAB_NO_ACTIVATE=1 (watch mode)
   a call made while the foreground belongs to another process is made non-activating:
   ShowWindow gets the matching NOACTIVATE/NA command, SetWindowPos gets SWP_NOACTIVATE, and
   SetForegroundWindow / SetActiveWindow are refused. When the user has put the game in the
   foreground themselves, every call passes through unchanged. */
typedef BOOL (WINAPI *PFNSHOWWINDOW)(HWND, int);
typedef BOOL (WINAPI *PFNSETWINDOWPOS)(HWND, HWND, int, int, int, int, UINT);
typedef BOOL (WINAPI *PFNSETFOREGROUNDWINDOW)(HWND);
typedef HWND (WINAPI *PFNSETHWND)(HWND);
static PFNSHOWWINDOW real_show;
static PFNSETWINDOWPOS real_setpos;
static PFNSETFOREGROUNDWINDOW real_setfg;
static PFNSETHWND real_setactive, real_setfocus;
static int no_activate;
static LONG focus_lines;
#define FOCUS_LOG_CAP 200

static int fg_is_ours(void)
{
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

static void focus_log(const char *call, HWND h, long arg, long arg2, HWND fg_before, const char *action)
{
    LONG n = InterlockedIncrement(&focus_lines);
    if (n > FOCUS_LOG_CAP) return;
    HWND fg_after = GetForegroundWindow();
    DWORD pid = 0;
    GetWindowThreadProcessId(fg_after, &pid);
    shim_log("focus %s(hwnd=%p, %ld, 0x%lx) %s; fg %p -> %p%s%s", call, (void *)h, arg, arg2, action,
             (void *)fg_before, (void *)fg_after,
             fg_before != fg_after && pid == GetCurrentProcessId() ? " TOOK FOREGROUND" : "",
             n == FOCUS_LOG_CAP ? " (log cap reached)" : "");
}

static BOOL WINAPI hooked_show(HWND h, int cmd)
{
    HWND before = GetForegroundWindow();
    int use = cmd;
    if (no_activate && !fg_is_ours()) {
        switch (cmd) {
        case SW_SHOWNORMAL: case SW_RESTORE: use = SW_SHOWNOACTIVATE; break;
        case SW_SHOW: case SW_SHOWDEFAULT: use = SW_SHOWNA; break;
        case SW_SHOWMINIMIZED: case SW_MINIMIZE: use = SW_SHOWMINNOACTIVE; break;
        }
    }
    BOOL r = real_show(h, use);
    focus_log("ShowWindow", h, cmd, use, before, use != cmd ? "rewritten (cmd -> 2nd arg)" : "passed");
    return r;
}

static BOOL WINAPI hooked_setpos(HWND h, HWND after, int x, int y, int cx, int cy, UINT flags)
{
    HWND before = GetForegroundWindow();
    UINT use = flags;
    if (no_activate && !fg_is_ours()) use |= SWP_NOACTIVATE;
    BOOL r = real_setpos(h, after, x, y, cx, cy, use);
    if (!(flags & SWP_NOACTIVATE) || before != GetForegroundWindow())
        focus_log("SetWindowPos", h, (long)(LONG_PTR)after, flags, before, use != flags ? "SWP_NOACTIVATE added" : "passed");
    return r;
}

static BOOL WINAPI hooked_setfg(HWND h)
{
    HWND before = GetForegroundWindow();
    if (no_activate && !fg_is_ours()) {
        focus_log("SetForegroundWindow", h, 0, 0, before, "refused");
        return FALSE;
    }
    BOOL r = real_setfg(h);
    focus_log("SetForegroundWindow", h, r, 0, before, "passed");
    return r;
}

static HWND WINAPI hooked_setactive(HWND h)
{
    HWND before = GetForegroundWindow();
    if (no_activate && !fg_is_ours()) {
        focus_log("SetActiveWindow", h, 0, 0, before, "refused");
        return NULL;
    }
    HWND r = real_setactive(h);
    focus_log("SetActiveWindow", h, 0, 0, before, "passed");
    return r;
}

/* Watch mode: SDL's top-level windows are born WS_EX_NOACTIVATE, so neither a click on them
   nor the system's hand-off when the foreground window closes can activate them while the
   game loads. Such a window also has no taskbar button, which is wanted: clicking a taskbar
   button lets explorer activate the window regardless (20261017-200812). At the first frame the
   runner clears WS_EX_NOACTIVATE and adds the button (winproc.allow_activation), after which
   the human may click it like any window. */
typedef HWND (WINAPI *PFNCREATEWINDOWEXW)(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
static PFNCREATEWINDOWEXW real_create;

static HWND WINAPI hooked_create(DWORD ex, LPCWSTR cls, LPCWSTR name, DWORD style, int x, int y, int w, int h,
                                 HWND parent, HMENU menu, HINSTANCE inst, LPVOID param)
{
    DWORD use = ex;
    if (no_activate && !parent && !(style & WS_CHILD)) use |= WS_EX_NOACTIVATE;
    HWND r = real_create(use, cls, name, style, x, y, w, h, parent, menu, inst, param);
    shim_log("focus CreateWindowExW(ex=0x%lx -> 0x%lx, style=0x%lx, parent=%p) -> %p", ex, use, style, (void *)parent, (void *)r);
    return r;
}

static HWND WINAPI hooked_setfocus(HWND h)
{
    HWND before = GetForegroundWindow();
    HWND r = real_setfocus(h);
    focus_log("SetFocus", h, 0, 0, before, "passed");
    return r;
}

/* Replace `func` imported from `dll` in `module`'s import table; returns the original or NULL. */
static void *hook_iat(HMODULE exe, const char *dll, const char *func, void *hook)
{
    if (!exe) return NULL;
    BYTE *base = (BYTE *)exe;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
    for (; imp->Name; imp++) {
        if (lstrcmpiA((char *)(base + imp->Name), dll) != 0) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA *slots = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, slots++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            IMAGE_IMPORT_BY_NAME *ibn = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
            if (strcmp((char *)ibn->Name, func) != 0) continue;
            DWORD old;
            VirtualProtect(&slots->u1.Function, sizeof(void *), PAGE_READWRITE, &old);
            void *orig = (void *)slots->u1.Function;
            slots->u1.Function = (ULONG_PTR)hook;
            VirtualProtect(&slots->u1.Function, sizeof(void *), old, &old);
            return orig;
        }
    }
    return NULL;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        HMODULE exe = GetModuleHandleA(NULL);
        real_swap = (PFNSWAPBUFFERS)hook_iat(exe, "gdi32.dll", "SwapBuffers", (void *)hooked_swap);
        real_known_folder = (PFNSHGETKNOWNFOLDERPATH)hook_iat(exe, "shell32.dll", "SHGetKnownFolderPath", (void *)hooked_known_folder);
        shim_log("injected; SwapBuffers %s, SHGetKnownFolderPath %s",
                 real_swap ? "hooked" : "ERR import not found",
                 real_known_folder ? "hooked" : "ERR import not found");
        HMODULE sdl = GetModuleHandleA("SDL2.dll");
        char flag[8] = {0};
        no_activate = GetEnvironmentVariableA("GAMELAB_NO_ACTIVATE", flag, sizeof flag) > 0 && flag[0] == '1';
        real_show = (PFNSHOWWINDOW)hook_iat(sdl, "user32.dll", "ShowWindow", (void *)hooked_show);
        real_setpos = (PFNSETWINDOWPOS)hook_iat(sdl, "user32.dll", "SetWindowPos", (void *)hooked_setpos);
        real_setfg = (PFNSETFOREGROUNDWINDOW)hook_iat(sdl, "user32.dll", "SetForegroundWindow", (void *)hooked_setfg);
        real_setactive = (PFNSETHWND)hook_iat(sdl, "user32.dll", "SetActiveWindow", (void *)hooked_setactive);
        real_setfocus = (PFNSETHWND)hook_iat(sdl, "user32.dll", "SetFocus", (void *)hooked_setfocus);
        real_create = (PFNCREATEWINDOWEXW)hook_iat(sdl, "user32.dll", "CreateWindowExW", (void *)hooked_create);
        shim_log("focus hooks in SDL2.dll: ShowWindow %s, SetWindowPos %s, SetForegroundWindow %s, "
                 "SetActiveWindow %s, SetFocus %s, CreateWindowExW %s; no_activate=%d",
                 real_show ? "hooked" : "ERR", real_setpos ? "hooked" : "ERR", real_setfg ? "hooked" : "ERR",
                 real_setactive ? "hooked" : "ERR", real_setfocus ? "hooked" : "ERR",
                 real_create ? "hooked" : "ERR", no_activate);
    }
    return TRUE;
}
