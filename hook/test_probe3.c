// 自测：验证 CreateProcessW 钩子把 "cmd /C tasklist | findstr consent.exe" 顶替成 rdnop.exe
// 用法：与 SAS.dll、rdnop.exe、portable 标记放在同一目录后运行
#include <windows.h>
#include <stdio.h>

typedef struct {
    DWORD pid;
    WCHAR image[MAX_PATH];
} Probe;

int wmain(void) {
    HMODULE sas = LoadLibraryW(L"SAS.dll");
    wprintf(L"SAS.dll = %p\n", (void *)sas);

    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {0};
    WCHAR cmd[] = L"cmd.exe /C tasklist | findstr consent.exe";
    BOOL ok = CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    wprintf(L"CreateProcess = %d, pid = %lu\n", ok, ok ? pi.dwProcessId : 0);
    if (!ok) return 1;

    WCHAR path[MAX_PATH] = {0};
    DWORD len = MAX_PATH;
    if (QueryFullProcessImageNameW(pi.hProcess, 0, path, &len)) {
        wprintf(L"image = %s\n", path); fflush(stdout);
    } else {
        wprintf(L"query failed, err=%lu\n", GetLastError()); fflush(stdout);
    }
    WaitForSingleObject(pi.hProcess, 10000);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 0;
}
