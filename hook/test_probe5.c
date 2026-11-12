// 用真实的 librustdesk.dll 验证 install-tip Hook：
//   Hook 前 [0] 应为 0（便携版没装 disable-installation 硬设置）
//   Hook 后 [0] 应为 1，且返回对象结构仍是 kArray[bool, bool]
// 只要这里不崩、字段都没变，Dart 侧读到的就是正常的 SyncReturn。
//
// 用法：probe5.exe [librustdesk.dll 的完整路径]
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <shlobj.h>

static const GUID kRoamingAppData = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}
};

typedef HRESULT(WINAPI *PFN_SHGetKnownFolderPath)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);
typedef int (*PFN_INT)(void);
typedef void *(*PFN_WIRE)(void);

typedef struct _DartCObject DartCObject;
struct _DartCObject {
    int type;
    union {
        int64_t as_int64;
        double as_double;
        const char *as_string;
        void *as_pointer;
        int as_bool;
        struct { intptr_t length; DartCObject **values; } as_array;
    } value;
};

static int read_wire(PFN_WIRE f) {
    void *obj = f();
    if (!obj) { printf("  wire -> null\n"); return -1; }
    DartCObject *arr = (DartCObject *)obj;
    if (arr->type != 6) { printf("  wire -> type=%d (not array!)\n", arr->type); return -1; }
    intptr_t len = arr->value.as_array.length;
    DartCObject **vals = arr->value.as_array.values;
    printf("  wire -> array len=%lld", (long long)len);
    int first = -1;
    for (intptr_t i = 0; i < len && i < 4; i++) {
        DartCObject *e = vals[i];
        if (!e) { printf(" [%lld]=null", (long long)i); continue; }
        printf(" [%lld]=type%d:%d", (long long)i, e->type,
               e->type == 1 ? (e->value.as_bool & 0xFF) : -1);
        if (i == 0 && e->type == 1) first = e->value.as_bool & 0xFF;
    }
    printf("\n");
    return first;
}

int wmain(int argc, wchar_t **argv) {
    const wchar_t *path = (argc > 1) ? argv[1] : L"C:\\Program Files\\RustDesk\\librustdesk.dll";

    HMODULE lib = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    printf("librustdesk = %p (err %lu)\n", (void *)lib, GetLastError());
    if (!lib) return 1;

    HMODULE sas = GetModuleHandleW(L"SAS.dll");   // 由 librustdesk 静态导入，应该已被加载
    printf("SAS.dll     = %p (ours=%d)\n", (void *)sas, sas != NULL);

    PFN_WIRE w = (PFN_WIRE)GetProcAddress(lib, "wire_is_disable_installation");
    PFN_INT  f = (PFN_INT)GetProcAddress(lib, "rustdesk_is_disable_installation");
    if (!w) { printf("wire export missing\n"); return 1; }

    printf("--- before hook ---\n");
    int a1 = read_wire(w);
    int a2 = f ? f() : -99;
    printf("  int  -> %d\n", a2);

    HMODULE sh = GetModuleHandleW(L"shell32.dll");
    PFN_SHGetKnownFolderPath g =
        (PFN_SHGetKnownFolderPath)GetProcAddress(sh, "SHGetKnownFolderPath");
    PWSTR p = NULL;
    g((REFKNOWNFOLDERID)&kRoamingAppData, 0, NULL, &p);
    printf("roaming = %ls\n", p ? p : L"(null)");

    printf("--- after hook ---\n");
    int b1 = read_wire(w);
    int b2 = f ? f() : -99;
    printf("  int  -> %d\n", b2);

    int pass = (a1 == 0 && a2 == 0 && b1 == 1 && b2 == 1);
    printf("\n%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 2;
}