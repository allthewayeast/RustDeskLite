// 自测用：模拟 librustdesk.dll 的两个导出，默认返回 0（false）
// 编译：/LD 输出为 librustdesk.dll，放在探针同目录
#include <windows.h>

__declspec(dllexport) int wire_is_disable_installation(void) { return 0; }
__declspec(dllexport) int rustdesk_is_disable_installation(void) { return 0; }

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    (void)hModule; (void)reason; (void)lpReserved;
    return TRUE;
}
