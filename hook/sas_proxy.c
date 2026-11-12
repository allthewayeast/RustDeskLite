// ============================================================================
//  RustDesk 便携化 Hook（劫持 SAS.dll）
//  ---------------------------------------------------------------------------
//  三件事：
//    1) 把 %APPDATA%\RustDesk 在进程内重定向到 exe 目录
//       —— Roaming 返回 <exe目录的父目录>，RustDesk 自己拼上 "RustDesk"，
//          结果正好落在 <exe目录>\config 等位置（平铺，无 appdata 子层）。
//    2) 主进程启动后把主窗口显示出来并置前（即使被 SW_HIDE 启动）。
//    3) 托盘进程里给右键菜单追加「退出 RustDesk」，点击即关闭主程序。
//
//  手段：
//    - librustdesk.dll 静态导入 SAS.dll（系统里只有 1 个导出 SendSAS），
//      把同名 DLL 放在 rustdesk.exe 旁边即可被优先加载（应用目录优先）。
//    - DllMain 里同步挂钩 shell32!SHGetKnownFolderPath / user32!TrackPopupMenu*。
//      必须同步：CLI 子命令在 DllMain 返回后立刻读配置，异步线程来不及。
//
//  生效条件：exe 同目录存在名为 portable 的标记文件；否则完全透明转发。
//  兼容性：与 RustDesk 版本无关（挂的是系统 API，不是内部符号）。
//
//  调试：设置环境变量 RDLITE_HOOK_LOG=<文件路径>，会记录初始化过程。
//  编译：build-hook.ps1
// ============================================================================

#include <windows.h>
#include <shlobj.h>
#include <objbase.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <wchar.h>
#include "MinHook.h"

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")

typedef HRESULT(WINAPI *PFN_SHGetKnownFolderPath)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);
typedef BOOL(WINAPI *PFN_SendSAS)(BOOL);
typedef BOOL(WINAPI *PFN_TrackPopupMenu)(HMENU, UINT, int, int, int, HWND, const RECT *);
typedef BOOL(WINAPI *PFN_TrackPopupMenuEx)(HMENU, UINT, int, int, HWND, const LPTPMPARAMS);

// 自备 GUID 常量，避免不同工具链 knownfolders.h / uuid 库的差异
static const GUID kRoamingAppData = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}
};

static PFN_SHGetKnownFolderPath g_realSHGetKnownFolderPath = NULL;
static PFN_TrackPopupMenu g_realTrackPopupMenu = NULL;
static PFN_TrackPopupMenuEx g_realTrackPopupMenuEx = NULL;
static HMODULE g_realSas = NULL;
static PFN_SendSAS g_realSendSAS = NULL;
static WCHAR g_roamingDir[MAX_PATH * 2] = {0};
static BOOL g_enabled = FALSE;
static BOOL g_inited = FALSE;
static BOOL g_trayMode = FALSE;
static WNDPROC g_trayOldProc = NULL;
static HWND g_trayHwnd = NULL;
static LONG g_showStarted = 0;

// 托盘的「退出」菜单项 id（不会被 RustDesk 自身的 id 表命中）
#define TRAY_EXIT_ID 0x5244

static void LogA(const char *fmt, ...) {
    char path[MAX_PATH] = {0};
    DWORD n = GetEnvironmentVariableA("RDLITE_HOOK_LOG", path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    FILE *f = NULL;
    if (fopen_s(&f, path, "a") != 0 || !f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static BOOL GetExeDir(WCHAR *buf, DWORD cch) {
    DWORD n = GetModuleFileNameW(NULL, buf, cch);
    if (n == 0 || n >= cch) return FALSE;
    WCHAR *p = wcsrchr(buf, L'\\');
    if (!p) return FALSE;
    *p = 0;
    return TRUE;
}

// ---------------------------------------------------------------------------
//  计算要冒充的 Roaming 目录
//  目标：<返回值>\RustDesk 必须正好等于 exe 目录。
//  例：exe 在 %TEMP%\RustDesk → 返回 %TEMP%，配置落在 %TEMP%\RustDesk\config。
//  兜底：目录名不是 RustDesk 时直接返回 exe 目录（配置落在其下的 RustDesk 子目录），
//        仍然在临时目录内，退出时一并删除。
// ---------------------------------------------------------------------------
static void BuildRoamingDir(const WCHAR *exeDir, WCHAR *out, DWORD cch) {
    const WCHAR *base = wcsrchr(exeDir, L'\\');
    base = base ? base + 1 : exeDir;

    lstrcpynW(out, exeDir, cch);
    if (lstrcmpiW(base, L"RustDesk") == 0) {
        WCHAR *p = wcsrchr(out, L'\\');
        if (p && p != out) {
            *p = 0;      // 去掉最后一级，返回父目录
            return;
        }
    }
    // 兜底：保持 out = exeDir
    LogA("exe dir is not named RustDesk, fallback to exe dir");
}

// ---------------------------------------------------------------- 窗口相关
static BOOL IsMainClassName(HWND hwnd) {
    WCHAR cls[128] = {0};
    if (GetClassNameW(hwnd, cls, 128) <= 0) return FALSE;
    return lstrcmpW(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") == 0;
}

// 查找本进程主窗口时的上下文
typedef struct {
    HWND hwnd;
    BOOL requireTitle;
} FindCtx;

static BOOL CALLBACK FindMainProc(HWND hwnd, LPARAM lp) {
    FindCtx *ctx = (FindCtx *)lp;
    if (!IsMainClassName(hwnd)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    if (ctx->requireTitle && GetWindowTextLengthW(hwnd) == 0) return TRUE;   // 等 Flutter 设好标题
    ctx->hwnd = hwnd;
    return FALSE;
}

static HWND FindOwnMainWindow(BOOL requireTitle) {
    FindCtx ctx;
    ctx.hwnd = NULL;
    ctx.requireTitle = requireTitle;
    EnumWindows(FindMainProc, (LPARAM)&ctx);
    return ctx.hwnd;
}

static void ForceShow(HWND hwnd) {
    if (!hwnd) return;
    if (IsIconic(hwnd)) {
        ShowWindow(hwnd, SW_RESTORE);
    } else if (!IsWindowVisible(hwnd)) {
        ShowWindow(hwnd, SW_SHOW);
    }
    BringWindowToTop(hwnd);
    if (!SetForegroundWindow(hwnd)) {
        // 前台锁：模拟按一下 ALT 再抢
        keybd_event(VK_MENU, 0, 0, 0);
        SetForegroundWindow(hwnd);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0);
    }
}

// 主进程启动后被 SW_HIDE 启动（nsExec 等）时，把窗口显示出来
static DWORD WINAPI ShowWindowThread(LPVOID unused) {
    (void)unused;
    for (int i = 0; i < 50; i++) {          // 最长约 15 秒
        // 前 6 秒只认有标题的窗口，避免闪出一个还没画完的空白框
        HWND h = FindOwnMainWindow(i < 20);
        if (h) {
            ForceShow(h);
            LogA("main window forced visible");
            return 0;
        }
        Sleep(300);
    }
    LogA("main window not found in 15s");
    return 0;
}

// ---------------------------------------------------------------- 托盘退出
static BOOL CALLBACK QuitMainProc(HWND hwnd, LPARAM lp) {
    int *posted = (int *)lp;
    if (!IsMainClassName(hwnd)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId()) {      // 托盘进程里没有主窗口，目标在别的进程
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
        (*posted)++;
    }
    return TRUE;
}

static void QuitMainApp(void) {
    int posted = 0;
    EnumWindows(QuitMainProc, (LPARAM)&posted);
    LogA("tray exit: WM_CLOSE posted to %d window(s)", posted);
}

static LRESULT CALLBACK TraySubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_COMMAND && LOWORD(wParam) == TRAY_EXIT_ID) {
        QuitMainApp();
        return 0;
    }
    return CallWindowProcW(g_trayOldProc, hwnd, msg, wParam, lParam);
}

// 给托盘菜单补一个「退出 RustDesk」（重复弹菜单时不会重复添加）
static void PrepareTrayMenu(HWND hwnd, HMENU menu) {
    if (!hwnd || !menu) return;

    WCHAR cls[128] = {0};
    if (GetClassNameW(hwnd, cls, 128) <= 0) return;
    if (lstrcmpW(cls, L"tray_icon_app") != 0) return;   // 不是托盘窗口，别动别的菜单

    if (g_trayHwnd != hwnd) {
        g_trayOldProc = (WNDPROC)SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)TraySubclassProc);
        g_trayHwnd = hwnd;
        LogA("tray window subclassed");
    }

    int count = GetMenuItemCount(menu);
    for (int i = 0; i < count; i++) {
        if (GetMenuItemID(menu, i) == TRAY_EXIT_ID) return;   // 已经有了
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, TRAY_EXIT_ID, L"退出 RustDesk");
    LogA("tray menu item appended");
}

static BOOL WINAPI Hook_TrackPopupMenu(HMENU menu, UINT flags, int x, int y, int reserved,
                                       HWND hwnd, const RECT *rc) {
    PrepareTrayMenu(hwnd, menu);
    return g_realTrackPopupMenu(menu, flags, x, y, reserved, hwnd, rc);
}

static BOOL WINAPI Hook_TrackPopupMenuEx(HMENU menu, UINT flags, int x, int y, HWND hwnd,
                                         const LPTPMPARAMS params) {
    PrepareTrayMenu(hwnd, menu);
    return g_realTrackPopupMenuEx(menu, flags, x, y, hwnd, params);
}

// ---------------------------------------------------------------- 钩子本体
static HRESULT WINAPI Hook_SHGetKnownFolderPath(REFKNOWNFOLDERID rfid, DWORD dwFlags,
                                                HANDLE hToken, PWSTR *ppszPath) {
    HRESULT hr = g_realSHGetKnownFolderPath(rfid, dwFlags, hToken, ppszPath);

    if (!g_enabled || FAILED(hr) || !ppszPath || !*ppszPath || !rfid) return hr;
    if (memcmp(rfid, &kRoamingAppData, sizeof(GUID)) != 0) return hr;

    size_t len = 0;
    while (g_roamingDir[len]) len++;
    len += 1;

    PWSTR copy = (PWSTR)CoTaskMemAlloc(len * sizeof(WCHAR));
    if (copy) {
        for (size_t i = 0; i < len; i++) copy[i] = g_roamingDir[i];
        CoTaskMemFree(*ppszPath);
        *ppszPath = copy;
        CreateDirectoryW(g_roamingDir, NULL);   // 调用方通常期望目录已存在

        // 第一次被调用说明已离开 DllMain 的加载器锁，可以安全地起线程
        if (InterlockedCompareExchange(&g_showStarted, 1, 0) == 0) {
            HANDLE t = CreateThread(NULL, 0, ShowWindowThread, NULL, 0, NULL);
            if (t) CloseHandle(t);
        }
    }
    return hr;
}

// ---------------------------------------------------------------- 初始化
static void EnsureInit(void) {
    if (g_inited) return;
    g_inited = TRUE;

    WCHAR exeDir[MAX_PATH] = {0};
    if (!GetExeDir(exeDir, MAX_PATH)) { LogA("GetExeDir failed"); return; }

    WCHAR marker[MAX_PATH + 16];
    lstrcpynW(marker, exeDir, MAX_PATH + 16);
    lstrcatW(marker, L"\\portable");
    if (GetFileAttributesW(marker) == INVALID_FILE_ATTRIBUTES) { LogA("no portable marker, skip"); return; }

    BuildRoamingDir(exeDir, g_roamingDir, MAX_PATH * 2);
    CreateDirectoryW(g_roamingDir, NULL);
    g_enabled = TRUE;
    LogA("portable mode: roaming -> %ls", g_roamingDir);

    // 托盘进程才需要菜单钩子
    const WCHAR *cmdline = GetCommandLineW();
    g_trayMode = (cmdline && wcsstr(cmdline, L"--tray") != NULL);

    MH_STATUS st = MH_Initialize();
    if (st != MH_OK) { LogA("MH_Initialize failed %d", (int)st); g_enabled = FALSE; return; }

    st = MH_CreateHookApi(L"shell32.dll", "SHGetKnownFolderPath",
                          &Hook_SHGetKnownFolderPath,
                          (LPVOID *)&g_realSHGetKnownFolderPath);
    if (st != MH_OK) { LogA("hook SHGetKnownFolderPath failed %d", (int)st); MH_Uninitialize(); g_enabled = FALSE; return; }

    if (g_trayMode) {
        st = MH_CreateHookApi(L"user32.dll", "TrackPopupMenu",
                              &Hook_TrackPopupMenu, (LPVOID *)&g_realTrackPopupMenu);
        LogA("hook TrackPopupMenu: %d", (int)st);
        st = MH_CreateHookApi(L"user32.dll", "TrackPopupMenuEx",
                              &Hook_TrackPopupMenuEx, (LPVOID *)&g_realTrackPopupMenuEx);
        LogA("hook TrackPopupMenuEx: %d", (int)st);
    }

    st = MH_EnableHook(MH_ALL_HOOKS);
    if (st != MH_OK) { LogA("MH_EnableHook failed %d", (int)st); g_enabled = FALSE; return; }
    LogA("hook installed (tray=%d)", (int)g_trayMode);
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    (void)lpReserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hModule);
        EnsureInit();
    }
    return TRUE;
}

// ---------------------------------------------------------------- 原样转发
// 真实 SAS.dll 只有 SendSAS 一个导出，按需从 System32 加载后转发。
__declspec(dllexport) BOOL WINAPI SendSAS(BOOL AsUser) {
    if (!g_realSendSAS) {
        WCHAR path[MAX_PATH] = {0};
        UINT n = GetSystemDirectoryW(path, MAX_PATH);
        if (n > 0 && n < MAX_PATH - 12) {
            lstrcatW(path, L"\\SAS.dll");
            g_realSas = LoadLibraryW(path);
            if (g_realSas) g_realSendSAS = (PFN_SendSAS)GetProcAddress(g_realSas, "SendSAS");
        }
    }
    return g_realSendSAS ? g_realSendSAS(AsUser) : FALSE;
}
