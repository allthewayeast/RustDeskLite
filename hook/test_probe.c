// 探针：显式加载 SAS.dll（模拟 librustdesk 的行为），再问系统 Roaming 目录在哪
#include <windows.h>
#include <stdio.h>
#include <shlobj.h>

static const GUID kRoamingAppData = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}
};

typedef HRESULT(WINAPI *PFN)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);

int wmain(void) {
    HMODULE h = LoadLibraryW(L"SAS.dll");
    wprintf(L"LoadLibrary(SAS.dll) = %p\n", (void *)h);
    Sleep(400);   // 等 hook 线程装好

    HMODULE sh = LoadLibraryW(L"shell32.dll");
    PFN f = (PFN)GetProcAddress(sh, "SHGetKnownFolderPath");
    if (!f) { wprintf(L"no SHGetKnownFolderPath\n"); return 1; }

    PWSTR p = NULL;
    HRESULT hr = f((REFKNOWNFOLDERID)&kRoamingAppData, 0, NULL, &p);
    wprintf(L"hr=0x%08lX path=%s\n", (unsigned long)hr, p ? p : L"(null)");
    return 0;
}
