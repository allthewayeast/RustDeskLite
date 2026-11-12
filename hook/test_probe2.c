// 自测：验证 SAS.dll 是否把 is_disable_installation 系列导出改成恒返回 1
// 用法：与 SAS.dll、假的 librustdesk.dll、portable 标记一起放在同一目录后运行
#include <windows.h>
#include <stdio.h>
#include <shlobj.h>

static const GUID kRoamingAppData = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}
};

typedef HRESULT(WINAPI *PFN_SHGetKnownFolderPath)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);
typedef int (*PFN_INT)(void);

int wmain(void) {
    HMODULE lib = LoadLibraryW(L"librustdesk.dll");
    wprintf(L"fake librustdesk = %p\n", (void *)lib);
    if (!lib) return 1;

    PFN_INT f1 = (PFN_INT)GetProcAddress(lib, "wire_is_disable_installation");
    PFN_INT f2 = (PFN_INT)GetProcAddress(lib, "rustdesk_is_disable_installation");
    wprintf(L"before: wire=%d rustdesk=%d  (期望 0 / 0)\n", f1 ? f1() : -99, f2 ? f2() : -99);

    HMODULE sas = LoadLibraryW(L"SAS.dll");
    wprintf(L"SAS.dll = %p\n", (void *)sas);

    // 第一次查询 Roaming 会触发第二批钩子
    HMODULE sh = LoadLibraryW(L"shell32.dll");
    PFN_SHGetKnownFolderPath g = (PFN_SHGetKnownFolderPath)GetProcAddress(sh, "SHGetKnownFolderPath");
    PWSTR p = NULL;
    g((REFKNOWNFOLDERID)&kRoamingAppData, 0, NULL, &p);
    wprintf(L"roaming = %s\n", p ? p : L"(null)");

    wprintf(L"after : wire=%d rustdesk=%d  (期望 1 / 1)\n", f1 ? f1() : -99, f2 ? f2() : -99);
    return 0;
}
