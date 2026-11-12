// 自测：验证托盘菜单「停止服务」被移除、且不误删未知结构
//
// 做法：建一个类名为 tray_icon_app 的窗口（Hook 只对这类窗口生效），
// 在后台线程里真调 TrackPopupMenu(TPM_RETURNCMD)，主线程用 WM_CANCELMODE 关掉它，
// 等调用返回后检查同一个 HMENU 的结构 —— Hook 改的就是这个句柄。
//
// 用法：与 SAS.dll、portable 标记放在同一目录，且命令行必须带 --tray 运行。
#include <windows.h>
#include <stdio.h>
#include <locale.h>

#define TRAY_EXIT_ID 0x7F00

static int g_fail = 0;
static HWND  g_owner;
static HMENU g_menu;
static volatile LONG g_done;
static int   g_ret;

static void Check(const char *name, int ok, WCHAR *detail) {
    wprintf(L"  [%s] %hs", ok ? L"PASS" : L"FAIL", name);
    if (detail) wprintf(L" : %s", detail);
    wprintf(L"\n");
    if (!ok) g_fail++;
}

// 数出「非空白」项，并检查是否含指定子串
static int CountItems(HMENU m) { return GetMenuItemCount(m); }

static int HasText(HMENU m, const WCHAR *needle) {
    int n = GetMenuItemCount(m);
    for (int i = 0; i < n; i++) {
        WCHAR t[128] = {0};
        if (GetMenuStringW(m, i, t, 128, MF_BYPOSITION) > 0 && wcsstr(t, needle)) return 1;
    }
    return 0;
}

static void DumpMenu(HMENU m) {
    int n = GetMenuItemCount(m);
    wprintf(L"    %d 项:", n);
    for (int i = 0; i < n; i++) {
        WCHAR t[128] = {0};
        GetMenuStringW(m, i, t, 128, MF_BYPOSITION);
        wprintf(L" [%d:'%s']", (int)GetMenuItemID(m, i), t);
    }
    wprintf(L"\n");
}

static DWORD WINAPI MenuThread(LPVOID unused) {
    (void)unused;
    g_ret = (int)TrackPopupMenu(g_menu, TPM_LEFTALIGN | TPM_RETURNCMD,
                                10, 10, 0, g_owner, NULL);
    InterlockedExchange(&g_done, 1);
    return 0;
}

// 弹一次菜单并立刻关掉，返回 TrackPopupMenu 的返回值
static int ShowAndDismiss(HMENU menu) {
    g_menu = menu;
    InterlockedExchange(&g_done, 0);
    g_ret = -12345;

    DWORD tid = 0;
    HANDLE th = CreateThread(NULL, 0, MenuThread, NULL, 0, &tid);
    if (!th) { wprintf(L"    CreateThread 失败\n"); return -12345; }

    // 等菜单真的弹出来再关，否则消息会丢
    HWND hMenuWnd = NULL;
    for (int i = 0; i < 40; i++) {
        Sleep(50);
        hMenuWnd = FindWindowW(L"#32768", NULL);
        if (hMenuWnd) break;
    }
    if (hMenuWnd) {
        PostMessageW(hMenuWnd, WM_KEYDOWN, VK_ESCAPE, 0);
        PostMessageW(hMenuWnd, WM_KEYUP, VK_ESCAPE, 0);
    }
    PostThreadMessageW(tid, WM_CANCELMODE, 0, 0);

    for (int i = 0; i < 60 && !g_done; i++) Sleep(50);
    if (!g_done) {                          // 兜底：再补一次取消
        if (hMenuWnd) PostMessageW(hMenuWnd, WM_CANCELMODE, 0, 0);
        PostThreadMessageW(tid, WM_CANCELMODE, 0, 0);
        for (int i = 0; i < 40 && !g_done; i++) Sleep(50);
    }
    if (!g_done) {
        wprintf(L"    !! 菜单关不掉，测试中止\n");
        ExitProcess(3);
    }
    WaitForSingleObject(th, 2000);
    CloseHandle(th);
    return g_ret;
}

static LRESULT CALLBACK OwnerProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    return DefWindowProcW(h, m, w, l);
}

int wmain(void) {
    SetConsoleOutputCP(CP_UTF8);
    setlocale(LC_ALL, ".UTF8");             // 否则 wprintf 把非 ASCII 输出成 '?'
    HMODULE sas = LoadLibraryW(L"SAS.dll");
    wprintf(L"SAS.dll = %p\n", (void *)sas);
    if (!sas) { wprintf(L"FAIL: 无法加载 SAS.dll\n"); return 1; }

    // Hook 只处理类名为 tray_icon_app 的窗口
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = OwnerProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"tray_icon_app";
    if (!RegisterClassW(&wc)) { wprintf(L"RegisterClass 失败 %lu\n", GetLastError()); return 1; }
    g_owner = CreateWindowExW(0, L"tray_icon_app", L"tray", 0,
                              0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
    if (!g_owner) { wprintf(L"CreateWindow 失败 %lu\n", GetLastError()); return 1; }
    wprintf(L"owner window = %p\n", (void *)g_owner);

    // ---- 1. [打开, 停止服务] → 停止服务应被摘掉，「退出」应被补上 ----
    wprintf(L"\n== 1. 菜单最初是 [打开, 停止服务] ==\n");
    HMENU m1 = CreatePopupMenu();
    AppendMenuW(m1, MF_STRING, 100, L"Open");
    AppendMenuW(m1, MF_STRING, 101, L"Stop service");
    wprintf(L"  before:\n"); DumpMenu(m1);
    ShowAndDismiss(m1);
    wprintf(L"  after:\n");  DumpMenu(m1);
    {
        WCHAR d[128];
        wsprintfW(d, L"%d 项", CountItems(m1));
        Check("停止服务已移除", !HasText(m1, L"Stop service"), d);
        Check("「退出」已补上", HasText(m1, L"\u9000\u51fa"), NULL);
        Check("「打开」保留", HasText(m1, L"Open"), NULL);
    }
    DestroyMenu(m1);

    // ---- 2. [打开]（hide-stop-service=Y 的情形）→ 只补「退出」 ----
    wprintf(L"\n== 2. 菜单最初只有 [打开] ==\n");
    HMENU m2 = CreatePopupMenu();
    AppendMenuW(m2, MF_STRING, 100, L"Open");
    wprintf(L"  before:\n"); DumpMenu(m2);
    ShowAndDismiss(m2);
    wprintf(L"  after:\n");  DumpMenu(m2);
    {
        WCHAR d[128];
        wsprintfW(d, L"%d 项", CountItems(m2));
        Check("项数 = 3（打开 + 分隔线 + 退出）", CountItems(m2) == 3, d);
        Check("「打开」保留", HasText(m2, L"Open"), NULL);
    }
    DestroyMenu(m2);

    // ---- 3. 未知结构（3 项）→ 不许猜位置删别人的菜单项 ----
    wprintf(L"\n== 3. 菜单有 3 项（结构未知，应原样不动）==\n");
    HMENU m3 = CreatePopupMenu();
    AppendMenuW(m3, MF_STRING, 100, L"Open");
    AppendMenuW(m3, MF_STRING, 101, L"Stop service");
    AppendMenuW(m3, MF_STRING, 102, L"Extra");
    wprintf(L"  before:\n"); DumpMenu(m3);
    ShowAndDismiss(m3);
    wprintf(L"  after:\n");  DumpMenu(m3);
    {
        WCHAR d[128];
        wsprintfW(d, L"%d 项", CountItems(m3));
        Check("未删除任何原有项", HasText(m3, L"Stop service") && HasText(m3, L"Extra"), d);
        Check("项数 = 5（3 原有 + 分隔线 + 退出）", CountItems(m3) == 5, NULL);
    }
    DestroyMenu(m3);

    // ---- 4. 取消（ESC）时返回值应为 0，不能误判成选中 ----
    wprintf(L"\n== 4. ESC 取消的返回值 ==\n");
    HMENU m4 = CreatePopupMenu();
    AppendMenuW(m4, MF_STRING, 100, L"Open");
    int ret = ShowAndDismiss(m4);
    {
        WCHAR d[64];
        wsprintfW(d, L"ret=%d", ret);
        Check("取消返回 0", ret == 0, d);
    }
    DestroyMenu(m4);

    DestroyWindow(g_owner);

    wprintf(L"\n%s\n", g_fail == 0 ? L"PASS" : L"FAIL");
    return g_fail == 0 ? 0 : 2;
}