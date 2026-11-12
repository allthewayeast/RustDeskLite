// ============================================================================
//  RustDesk 便携化 Hook（劫持 SAS.dll）
//  ---------------------------------------------------------------------------
//  目标：让 RustDesk 的配置目录（%APPDATA%\RustDesk）在进程内被重定向到
//        <exe目录>\appdata\RustDesk，全程不碰用户的真实配置目录；
//        即使本进程被强制结束，系统里的 RustDesk 也不受任何影响。
//
//  手段：
//    1) librustdesk.dll 静态导入 SAS.dll（系统里只有 1 个导出 SendSAS），
//       把同名 DLL 放在 rustdesk.exe 旁边即可被优先加载（应用目录优先）。
//    2) DllMain 里同步挂钩 shell32!SHGetKnownFolderPath。
//       必须同步：CLI 子命令在 DllMain 返回后立刻读配置，异步线程来不及。
//    3) 当系统问 RoamingAppData 在哪时，返回 <exe目录>\appdata。
//
//  生效条件：exe 同目录存在名为 portable 的标记文件；否则只做透明转发。
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
#include "MinHook.h"

#pragma comment(lib, "ole32.lib")

typedef HRESULT(WINAPI *PFN_SHGetKnownFolderPath)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);
typedef BOOL(WINAPI *PFN_SendSAS)(BOOL);

// 自备 GUID 常量，避免不同工具链 knownfolders.h / uuid 库的差异
static const GUID kRoamingAppData = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}
};

static PFN_SHGetKnownFolderPath g_realSHGetKnownFolderPath = NULL;
static HMODULE g_realSas = NULL;
static PFN_SendSAS g_realSendSAS = NULL;
static WCHAR g_appDataDir[MAX_PATH * 2] = {0};
static BOOL g_enabled = FALSE;
static BOOL g_inited = FALSE;

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

// ---------------------------------------------------------------- 钩子本体
static HRESULT WINAPI Hook_SHGetKnownFolderPath(REFKNOWNFOLDERID rfid, DWORD dwFlags,
                                                HANDLE hToken, PWSTR *ppszPath) {
    HRESULT hr = g_realSHGetKnownFolderPath(rfid, dwFlags, hToken, ppszPath);

    if (!g_enabled || FAILED(hr) || !ppszPath || !*ppszPath || !rfid) return hr;
    if (memcmp(rfid, &kRoamingAppData, sizeof(GUID)) != 0) return hr;

    size_t len = 0;
    while (g_appDataDir[len]) len++;
    len += 1;

    PWSTR copy = (PWSTR)CoTaskMemAlloc(len * sizeof(WCHAR));
    if (copy) {
        for (size_t i = 0; i < len; i++) copy[i] = g_appDataDir[i];
        CoTaskMemFree(*ppszPath);
        *ppszPath = copy;
        CreateDirectoryW(g_appDataDir, NULL);   // 调用方通常期望目录已存在
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

    lstrcpynW(g_appDataDir, exeDir, MAX_PATH * 2);
    lstrcatW(g_appDataDir, L"\\appdata");
    CreateDirectoryW(g_appDataDir, NULL);
    g_enabled = TRUE;
    LogA("portable dir ready");

    MH_STATUS st = MH_Initialize();
    if (st != MH_OK) { LogA("MH_Initialize failed %d", (int)st); g_enabled = FALSE; return; }

    st = MH_CreateHookApi(L"shell32.dll", "SHGetKnownFolderPath",
                          &Hook_SHGetKnownFolderPath,
                          (LPVOID *)&g_realSHGetKnownFolderPath);
    if (st != MH_OK) { LogA("MH_CreateHookApi failed %d", (int)st); MH_Uninitialize(); g_enabled = FALSE; return; }

    st = MH_EnableHook(MH_ALL_HOOKS);
    if (st != MH_OK) { LogA("MH_EnableHook failed %d", (int)st); g_enabled = FALSE; return; }
    LogA("hook installed");
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
