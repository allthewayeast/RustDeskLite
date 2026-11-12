// ============================================================================
//  RustDesk 便携化 Hook（劫持 SAS.dll）
//  ---------------------------------------------------------------------------
//  三件事：
//    1) 把 %APPDATA%\RustDesk 在进程内重定向到 exe 目录
//       —— Roaming 返回 <exe目录的父目录>，RustDesk 自己拼上 "RustDesk"，
//          结果正好落在 <exe目录>\config 等位置（平铺，无 appdata 子层）。
//    2) 主进程启动后把主窗口显示出来并置前（即使被 SW_HIDE 启动）。
//    3) 托盘进程里改写右键菜单：去掉「停止服务」（它会 sc delete 掉正式版的服务），
//       补一个「退出 RustDesk」（点击即关闭主程序）。
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
typedef BOOL(WINAPI *PFN_CreateProcessW)(LPCWSTR, LPWSTR, LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES,
                                        BOOL, DWORD, LPVOID, LPCWSTR, LPSTARTUPINFOW,
                                        LPPROCESS_INFORMATION);

// 自备 GUID 常量，避免不同工具链 knownfolders.h / uuid 库的差异
static const GUID kRoamingAppData = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}
};

static PFN_SHGetKnownFolderPath g_realSHGetKnownFolderPath = NULL;
static PFN_TrackPopupMenu g_realTrackPopupMenu = NULL;
static PFN_TrackPopupMenuEx g_realTrackPopupMenuEx = NULL;
static PFN_CreateProcessW g_realCreateProcessW = NULL;
static WCHAR g_nopPath[MAX_PATH + 16] = {0};
static HMODULE g_realSas = NULL;
static PFN_SendSAS g_realSendSAS = NULL;
static WCHAR g_roamingDir[MAX_PATH * 2] = {0};
static WCHAR g_exeDir[MAX_PATH] = {0};
static BOOL g_enabled = FALSE;
static BOOL g_inited = FALSE;
static BOOL g_trayMode = FALSE;
static BOOL g_cmMode = FALSE;      // 本进程是被控端拉起的连接管理窗口（--cm）
static WNDPROC g_trayOldProc = NULL;
static HWND g_trayHwnd = NULL;
static LONG g_showStarted = 0;
static BOOL g_tipHooksDone = FALSE;

// 托盘的「退出」菜单项 id。
// muda（RustDesk 用的菜单库）的 internal_id 是从 1 开始自增的小整数，
// 这里取 0x7F00 既不会撞上，又能安全落在 16 位内（个别系统会截断命令 id）。
#define TRAY_EXIT_ID 0x7F00

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

// ---------------------------------------------------------------- 关闭即隐藏
// 正式版点右上角 ✕ 只是隐藏窗口，进程留在托盘；便携版没有服务，
// Dart 侧的 windowManager.setPreventClose(true)（main.dart:112，未 await）
// 在初始化竞态下可能没生效，于是 WM_CLOSE 落到 DefWindowProc -> DestroyWindow
// -> WM_DESTROY -> PostQuitMessage(0)（runner/main.cpp:185 设了 quit_on_close=true），
// 进程直接退出。实测：不带服务时 SC_CLOSE 会让进程立刻消失。
//
// 这里在主窗口上拦 WM_CLOSE，改为 SW_HIDE，与正式版行为对齐。
// 恢复窗口靠托盘「打开」（再启一个实例，单实例逻辑会 ShowWindow 已有窗口）。
static WNDPROC g_mainOldProc = NULL;
static HWND g_mainHwnd = NULL;

// 托盘点「退出」时发给主窗口的自定义消息。
//
// 为什么不用 PostThreadMessageW(tid, WM_QUIT)：跨进程投递线程消息要求目标线程的
// 消息队列句柄（由 PostThreadMessage 在对方线程首次调 user32 时自动创建，外部拿不到），
// 实测直接返回 FALSE，线程收不到 —— 托盘的「退出」会变成死按钮。
// 走窗口消息没有这个问题：窗口句柄跨进程有效，消息在目标线程的消息泵里被取出。
//
// 为什么不直接 PostQuitMessage：实测目标线程调了 PostQuitMessage 后进程依然存活。
// Flutter 运行时不止一个消息泵（原生 runner 与平台线程各跑各的），只退出其中一个
// 留不住上下文。这里改为「置退出标志 + 放行 WM_CLOSE」，
// 走原生那条最可靠的链：DefWindowProc -> DestroyWindow -> WM_DESTROY
// -> PostQuitMessage(0)（runner/main.cpp:185 设了 quit_on_close=true）。
#define WM_RDLITE_QUIT (WM_APP + 0x51)

static BOOL g_reallyClosing = FALSE;
static BOOL g_endSession = FALSE;     // 系统正在关机/注销

static LRESULT CALLBACK MainSubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    // 关机 / 注销：必须放行，否则窗口拦着不让关，系统会弹「此程序阻止关机」。
    // WM_QUERYENDSESSION 是系统在关机前问「能不能结束」，这里直接回 TRUE 并放行后续的
    // WM_CLOSE / WM_ENDSESSION。用户点 ✕ 不会走这条消息，所以不影响「关闭即隐藏」。
    if (msg == WM_QUERYENDSESSION) {
        g_endSession = TRUE;
        LogA("system shutdown/logoff, allowing close");
        return TRUE;
    }
    if (msg == WM_ENDSESSION) {
        g_endSession = (BOOL)wParam;
        return CallWindowProcW(g_mainOldProc, hwnd, msg, wParam, lParam);
    }

    if (msg == WM_CLOSE) {
        // 托盘「退出」置了标志，或系统正在关机 -> 放行，让窗口真正销毁
        if (g_reallyClosing || g_endSession) {
            LogA("main window real close, passing to DefWindowProc");
            return CallWindowProcW(g_mainOldProc, hwnd, msg, wParam, lParam);
        }
        ShowWindow(hwnd, SW_HIDE);
        LogA("main window hidden on close");
        return 0;
    }
    if (msg == WM_RDLITE_QUIT) {
        LogA("quit request: flag set, reposting WM_CLOSE");
        g_reallyClosing = TRUE;
        PostMessageW(hwnd, WM_CLOSE, 0, 0);   // 再走一遍 WM_CLOSE，这次放行
        return 0;
    }
    return CallWindowProcW(g_mainOldProc, hwnd, msg, wParam, lParam);
}

static void InstallMainCloseHook(HWND hwnd) {
    if (!hwnd) return;
    if (g_mainHwnd && IsWindow(g_mainHwnd)) return;   // 已经装过且窗口还在
    g_mainHwnd = hwnd;
    g_mainOldProc = (WNDPROC)SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)MainSubclassProc);
    LogA("main window subclassed for close-to-hide");
}

// ---------------------------------------------------------------- 隐藏连接管理窗口
// 被控端收到连接时，server/connection.rs:6412 的 start_ipc() 会拉起一个 `--cm` 进程
// （连接管理窗口 / Connection Manager）。它运行在独立进程、独立 HWND 上，
// 屏幕右上角、固定 300x490（consts.dart:355 kConnectionManagerWindowSizeClosedChat）。
//
// 上游本来就有隐藏开关，但三道门都过不去：
//   1. libs/hbb_common/password_security.rs:88 hide_cm() 需要
//      approve-mode='password' + verification-method='use-permanent-password' + allow-hide-cm
//   2. 更要命的是 src/ipc.rs:998：只有 is_pro() || is_custom_client() 才返回该值，
//      否则直接 None。我们 APP_NAME 是 "RustDesk" -> is_custom_client()=false
//   3. custom.txt 能改 app-name，但 common.rs:2617 要用官方私钥验签，伪造不了
//
// 所以只能在这一层处理。注意不能用一次性 hide：server_model.dart 在多个时机
// （168/175/284/286/524/526/570）会重新 showCmWindow()，必须持续压制。
//
// ---- 两个必须知道的实情（都是读源码 + 实测确认的，别再猜） ----
//
// 1) CM 窗口**不是** multi_window 子窗口，它走的是主窗口路径。
//    main.dart:50 的分支是：args.first == "multi_window" 才走 createWindow 那套
//    （那是"./DesktopMultiWindow.createWindow()"创建的子窗口，类名 RustdeskMultiWindow，
//    控制别人时的远程桌面窗口才是它）。`--cm` 进程 args[0] 是 "--cm"，进 else 分支，
//    走 runMainApp -> 普通主窗口，类名还是 FLUTTER_RUNNER_WIN32_WINDOW。
//    所以这里沿用 IsMainClassName 是对的。
//
// 2) 光 ShowWindow(SW_HIDE) 会在任务栏留下一个图标。
//    原因是主窗口在 flutter/windows/runner/win32_window.cpp 里用
//        CreateWindow(..., WS_OVERLAPPEDWINDOW, ...)
//    创建，是个"正常应用窗口"，任务栏必然出按钮。要摘掉它得改成工具窗口：
//        ex |= WS_EX_TOOLWINDOW;   // 不进任务栏、不进 Alt+Tab
//        ex &= ~WS_EX_APPWINDOW;   // 抵掉强制上任务栏的位
//    两个都要做：WS_EX_APPWINDOW 优先级高于 WS_EX_TOOLWINDOW，只加 TOOLWINDOW 不生效。
static volatile LONG g_cmStop = 0;

// 把窗口改成"工具窗口"，从任务栏和 Alt+Tab 里摘掉。
// 返回 TRUE 表示这次确实改了样式。
static BOOL MakeToolWindow(HWND hwnd) {
    LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    LONG_PTR want = (ex | WS_EX_TOOLWINDOW) & ~(LONG_PTR)WS_EX_APPWINDOW;
    if (want == ex) return FALSE;
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    // 改扩展样式后任务栏不会自己刷新。此时窗口本来就该是隐藏的，
    // 这里再 SW_HIDE 一次让它重建按钮；不发 SW_SHOW，避免窗口闪一下。
    ShowWindow(hwnd, SW_HIDE);
    return TRUE;
}

// CM 窗口查找的累加器：记录"最像 CM 窗口"的那个候选。
// 不用"找到第一个就返回"——Flutter 引擎的 1x1 辅助窗口在枚举顺序里
// 经常排在前面，必须比较后择优。
typedef struct {
    HWND best;
    int  bestArea;
} CmSearch;

static BOOL CALLBACK FindCmProc(HWND hwnd, LPARAM lp) {
    CmSearch *s = (CmSearch *)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    if (!IsMainClassName(hwnd)) return TRUE;

    RECT rc;
    if (!GetWindowRect(hwnd, &rc)) return TRUE;
    int w = rc.right - rc.left, h = rc.bottom - rc.top;

    // 最小化状态：rect 是 (-32000,-32000) 起算的"最小化矩形"，
    // 实测 CM 窗口只有 160x28 —— 不能按尺寸排除，直接视为强候选。
    // Flutter 的 1x1 辅助窗口从不最小化，所以这个例外很安全。
    if (IsIconic(hwnd)) {
        s->best = hwnd;
        s->bestArea = 0x7FFFFFFF;
        return FALSE;                      // 最小化的主窗口就是目标，无需再找
    }

    // 非最小化：按面积择优。1x1 辅助窗口面积只有 1，天然垫底。
    if (w < 50 || h < 50) {
        // 可能是辅助窗口；只有在还没有任何候选时才记下，避免误判为空
        if (s->best == NULL) { s->best = hwnd; s->bestArea = w * h; }
        return TRUE;
    }
    int area = w * h;
    if (area > s->bestArea) { s->best = hwnd; s->bestArea = area; }
    return TRUE;
}

static DWORD WINAPI HideCmWindowThread(LPVOID unused) {
    (void)unused;
    HWND last = NULL;
    for (int i = 0; i < 36000 && !g_cmStop; i++) {   // 最长约 60 分钟，随进程一起结束
        CmSearch s;
        s.best = NULL;
        s.bestArea = -1;
        EnumWindows(FindCmProc, (LPARAM)&s);
        HWND h = s.best;
        if (h) {
            if (h != last) {
                LogA("cm window found, suppressing %p", (void *)h);
                last = h;
            }
            // 先摘任务栏按钮，再隐藏。MakeToolWindow 内部判断是否真需要改，
            // 改过就不再重复 SetWindowLongPtr（否则每 100ms 都调一次）。
            if (MakeToolWindow(h)) LogA("cm window ex-style -> TOOLWINDOW (removed from taskbar)");
            if (IsWindowVisible(h)) ShowWindow(h, SW_HIDE);
        }
        Sleep(100);
    }
    return 0;
}

// 主进程启动后被 SW_HIDE 启动（nsExec 等）时，把窗口显示出来。
// 注意：`--cm` 进程不走这里 —— 那是连接管理窗口，要隐藏而不是显示，
// 由 HideCmWindowThread 负责。
static DWORD WINAPI ShowWindowThread(LPVOID unused) {
    (void)unused;
    for (int i = 0; i < 50; i++) {          // 最长约 15 秒
        // 前 6 秒只认有标题的窗口，避免闪出一个还没画完的空白框
        HWND h = FindOwnMainWindow(i < 20);
        if (h) {
            InstallMainCloseHook(h);        // 关闭时隐藏而不是退出
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
// 主窗口被我们子类化过（见 MainSubclassProc），WM_CLOSE 已被改成 hide，
// 所以这里不能再用 WM_CLOSE 收尾 —— 改为投递 WM_RDLITE_QUIT，
// 由主进程在自己的线程里 PostQuitMessage，退出消息循环。
static BOOL CALLBACK QuitHardProc(HWND hwnd, LPARAM lp) {
    int *posted = (int *)lp;
    if (!IsMainClassName(hwnd)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == GetCurrentProcessId()) return TRUE;   // 只发给别的进程（主进程）
    if (PostMessageW(hwnd, WM_RDLITE_QUIT, 0, 0)) (*posted)++;
    return TRUE;
}

static void QuitMainApp(void) {
    int posted = 0;
    EnumWindows(QuitHardProc, (LPARAM)&posted);
    LogA("tray exit: WM_RDLITE_QUIT posted to %d window(s)", posted);
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

// ---------------------------------------------------------------- 托盘菜单：去「停止服务」
// muda 0.17.1 在 Windows 上弹菜单固定带 TPM_RETURNCMD（muda platform_impl/windows:
// show_context_menu），选中项通过 **返回值** 交给 menu_selected，不会向窗口发
// WM_COMMAND —— 所以 TraySubclassProc 里的 WM_COMMAND 分支根本收不到点击，
// 「退出 RustDesk」必须在 TrackPopupMenu 返回之后自己判断返回值。
//
// 移除「停止服务」用位置判据，不用文案：tray.rs 里固定是
//     append_items(&[&open_i, quit_i])       // quit_i 就是「停止服务」
// 即菜单原始内容恒为 [打开] 或 [打开, 停止服务]（后者在 hide-stop-service=Y 时不存在）。
// 文案随语言变、ja/hi 两个语言包里该 key 甚至是空串，靠文本匹配不可靠。

// 数出原始项数（Hook 动手之前的项数）。
// PrepareTrayMenu 若加过，必定在**末尾**追加了一对「分隔线 + 退出」，
// 所以直接减 2 即可 —— 不靠 GetMenuItemID 判断分隔线
// （实测它对本进程 AppendMenuW 加的分隔线返回 0，不是文档说的 -1，不能用来识别）。
static int CountOriginalItems(HMENU menu) {
    int n = GetMenuItemCount(menu);
    if (n >= 2 && GetMenuItemID(menu, n - 1) == TRAY_EXIT_ID) return n - 2;
    return n;
}

// 原始项恰好是 [打开, 停止服务] 时摘掉后者。多于 2 项说明结构变了（未来版本），
// 宁可不动也不猜错位置删掉别人的菜单项。
static void RemoveStopServiceItem(HMENU menu) {
    int orig = CountOriginalItems(menu);
    if (orig != 2) {
        if (orig > 2) LogA("tray menu has %d items, skip stop-service removal", orig);
        return;
    }
    if (DeleteMenu(menu, 1, MF_BYPOSITION)) LogA("tray menu: stop-service removed");
}

// 统一处理 TrackPopupMenu / TrackPopupMenuEx 的返回值。
// 带 TPM_RETURNCMD 时返回值就是选中项 id（muda 正是这么用的），要自己消化：
// 命中我们的「退出」就关主程序，并且返回 0 让 muda 的 find_by_id 落空、不产生事件。
static int HandleMenuResult(UINT flags, int ret) {
    if (!(flags & TPM_RETURNCMD)) return ret;
    if (ret > 0 && (UINT)ret == TRAY_EXIT_ID) {
        QuitMainApp();
        return 0;
    }
    return ret;
}

static BOOL WINAPI Hook_TrackPopupMenu(HMENU menu, UINT flags, int x, int y, int reserved,
                                       HWND hwnd, const RECT *rc) {
    PrepareTrayMenu(hwnd, menu);
    RemoveStopServiceItem(menu);
    return HandleMenuResult(flags, g_realTrackPopupMenu(menu, flags, x, y, reserved, hwnd, rc));
}

static BOOL WINAPI Hook_TrackPopupMenuEx(HMENU menu, UINT flags, int x, int y, HWND hwnd,
                                         const LPTPMPARAMS params) {
    PrepareTrayMenu(hwnd, menu);
    RemoveStopServiceItem(menu);
    return HandleMenuResult(flags, g_realTrackPopupMenuEx(menu, flags, x, y, hwnd, params));
}

// ---------------------------------------------------------------- 隐藏"未安装版本"提示
// 首页红卡的条件是 (Windows && !isDisableInstallation() && !isInstalled())，
// 见 flutter/lib/desktop/pages/desktop_home_page.dart:461。
//
// Dart 侧的 isDisableInstallation() 走 flutter_rust_bridge 生成的
//   wire_is_disable_installation() -> *mut DartCObject
// 注意它返回的是指针（WireSyncReturn = *mut DartCObject），绝对不能直接返回整数。
// 实测（1.5.1）返回的是一个长度 2 的数组对象：
//   [0] bool = is_disable_installation() 的结果
//   [1] bool = 调用是否成功（true）
// 这里的做法：先调用原函数拿到**由 Rust 正常分配**的对象，只把 [0] 的布尔字节改成 1。
// 结构仍由 Dart 正常释放；形状不符合预期时不做任何修改，绝不会破坏内存。
typedef void *(*PFN_WireReturn)(uintptr_t, uintptr_t, uintptr_t, uintptr_t);

static int WINAPI Hook_DisableInstallationInt(void) { return 1; }   // rustdesk_is_disable_installation
static PFN_WireReturn g_realWireDisableInstallation = NULL;

// 校验并改写 DartCObject(kArray[bool, bool]) 的第一个布尔值
static void ForceFirstBoolTrue(void *obj) {
    if (!obj) return;
    int type = *(int *)obj;                        // Dart_CObject_kArray = 6（偏移 0）
    intptr_t len = *(intptr_t *)((char *)obj + 8); // as_array.length（8 字节，偏移 8）
    void **vals = *(void ***)((char *)obj + 16);   // as_array.values（偏移 16）
    if (type != 6 || len != 2 || !vals || !vals[0]) return;

    unsigned char *elem = (unsigned char *)vals[0];
    int etype = *(int *)elem;                      // Dart_CObject_kBool = 1
    if (etype != 1) return;
    elem[8] = 1;                                   // union 里 as_bool 的字节（其余是填充）
}

static void *WINAPI Hook_WireDisableInstallation(uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4) {
    if (!g_realWireDisableInstallation) return NULL;   // 不该发生；宁可返回空也不猜
    void *obj = g_realWireDisableInstallation(a1, a2, a3, a4);
    ForceFirstBoolTrue(obj);
    return obj;
}

// 程序目录放 show-install-tip 文件 → 保留上游提示，不做任何拦截
static BOOL KeepInstallTip(void) {
    if (!g_exeDir[0]) return FALSE;
    WCHAR opt[MAX_PATH + 24];
    lstrcpynW(opt, g_exeDir, MAX_PATH + 24);
    lstrcatW(opt, L"\\show-install-tip");
    return GetFileAttributesW(opt) != INVALID_FILE_ATTRIBUTES;
}

// 只在第一次 SHGetKnownFolderPath 之后装（见 Hook_SHGetKnownFolderPath）：
// 那时 librustdesk.dll 早已初始化完毕，取导出、改代码都安全；
// 而 DllMain 阶段本 DLL 正被 librustdesk.dll 导入，模块还没就绪。
static void EnsureTipHooks(void) {
    if (g_tipHooksDone) return;
    g_tipHooksDone = TRUE;
    if (KeepInstallTip()) { LogA("show-install-tip marker present, keep install tip"); return; }

    HMODULE lib = GetModuleHandleW(L"librustdesk.dll");
    if (!lib) { LogA("librustdesk.dll not loaded, skip install-tip hook"); return; }

    LPVOID pWire = (LPVOID)GetProcAddress(lib, "wire_is_disable_installation");
    if (pWire) {
        MH_STATUS st = MH_CreateHook(pWire, &Hook_WireDisableInstallation,
                                     (LPVOID *)&g_realWireDisableInstallation);
        LogA("hook wire_is_disable_installation: %d", (int)st);
        // 绝不能像整数返回那样改字节兜底：Dart 侧拿到假指针会直接崩。
        if (st == MH_OK && MH_EnableHook(pWire) != MH_OK) g_realWireDisableInstallation = NULL;
    } else {
        LogA("export wire_is_disable_installation not found");
    }

    LPVOID pInt = (LPVOID)GetProcAddress(lib, "rustdesk_is_disable_installation");
    if (pInt) {
        MH_STATUS st = MH_CreateHook(pInt, &Hook_DisableInstallationInt, NULL);
        LogA("hook rustdesk_is_disable_installation: %d", (int)st);
        if (st == MH_OK) MH_EnableHook(pInt);
    }
}

// ---------------------------------------------------------------- 抑制 UAC 探测风暴
// RustDesk 在“未安装”模式下，采集循环每帧都会执行
//     cmd /C tasklist | findstr consent.exe
// 来探测 UAC 安全桌面（src/server/video_service.rs:750 → is_process_consent_running()）。
// 这里把它换成自带的 2.5 KB 空程序：不再拉起 cmd / tasklist / findstr 三个进程，
// 输出的仍是“没有 consent.exe”，与便携模式（没有服务、本来就抓不到安全桌面）一致。
static BOOL WINAPI Hook_CreateProcessW(LPCWSTR app, LPWSTR cmd, LPSECURITY_ATTRIBUTES pa,
                                       LPSECURITY_ATTRIBUTES ta, BOOL inherit, DWORD flags,
                                       LPVOID env, LPCWSTR cwd, LPSTARTUPINFOW si,
                                       LPPROCESS_INFORMATION pi) {
    if (g_nopPath[0] && cmd && wcsstr(cmd, L"findstr consent.exe")) {
        WCHAR line[MAX_PATH + 16];
        wsprintfW(line, L"\"%s\"", g_nopPath);
        return g_realCreateProcessW(NULL, line, pa, ta, inherit, flags | CREATE_NO_WINDOW,
                                    env, cwd, si, pi);
    }
    return g_realCreateProcessW(app, cmd, pa, ta, inherit, flags, env, cwd, si, pi);
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

        // 第一次被调用说明已离开 DllMain 的加载器锁，可以安全地装第二批钩子/起线程
        EnsureTipHooks();
        if (InterlockedCompareExchange(&g_showStarted, 1, 0) == 0) {
            // --cm 进程：连接管理窗口只隐藏、不显示
            HANDLE t = CreateThread(NULL, 0, g_cmMode ? HideCmWindowThread : ShowWindowThread,
                                    NULL, 0, NULL);
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

    lstrcpynW(g_exeDir, exeDir, MAX_PATH);
    BuildRoamingDir(exeDir, g_roamingDir, MAX_PATH * 2);
    CreateDirectoryW(g_roamingDir, NULL);
    g_enabled = TRUE;
    LogA("portable mode: roaming -> %ls", g_roamingDir);

    // 托盘进程才需要菜单钩子
    const WCHAR *cmdline = GetCommandLineW();
    g_trayMode = (cmdline && wcsstr(cmdline, L"--tray") != NULL);
    g_cmMode = (cmdline && wcsstr(cmdline, L"--cm") != NULL);

    // 自带的空程序（替代每帧的 tasklist | findstr）
    lstrcpynW(g_nopPath, exeDir, MAX_PATH + 16);
    lstrcatW(g_nopPath, L"\\rdnop.exe");
    if (GetFileAttributesW(g_nopPath) == INVALID_FILE_ATTRIBUTES) g_nopPath[0] = 0;

    MH_STATUS st = MH_Initialize();
    if (st != MH_OK) { LogA("MH_Initialize failed %d", (int)st); g_enabled = FALSE; return; }

    st = MH_CreateHookApi(L"shell32.dll", "SHGetKnownFolderPath",
                          &Hook_SHGetKnownFolderPath,
                          (LPVOID *)&g_realSHGetKnownFolderPath);
    if (st != MH_OK) { LogA("hook SHGetKnownFolderPath failed %d", (int)st); MH_Uninitialize(); g_enabled = FALSE; return; }

    if (g_nopPath[0]) {
        st = MH_CreateHookApi(L"kernel32.dll", "CreateProcessW",
                              &Hook_CreateProcessW, (LPVOID *)&g_realCreateProcessW);
        LogA("hook CreateProcessW: %d (nop=%ls)", (int)st, g_nopPath);
    }

    if (!KeepInstallTip()) LogA("install-tip hook deferred to first folder query");

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
