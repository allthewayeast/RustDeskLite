// 自测：验证 SAS.dll 把 wire_is_disable_installation 的返回数组 [0] 改成 true，
// 且返回的对象结构完好（type=6 / len=2 / 两个元素都是 bool），不会让 Dart 侧崩。
// 用法：与 SAS.dll、假的 librustdesk.dll、portable 标记一起放在同一目录后运行
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
typedef void (*PFN_SET)(int);

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
    if (arr->type != 6) { printf("  wire -> type=%d (NOT an array!)\n", arr->type); return -1; }
    intptr_t len = arr->value.as_array.length;
    DartCObject **vals = arr->value.as_array.values;
    printf("  wire -> array len=%lld", (long long)len);
    int first = -1;
    for (intptr_t i = 0; i < len && i < 4; i++) {
        DartCObject *e = vals[i];
        if (!e) { printf(" [%lld]=null", (long long)i); continue; }
        printf(" [%lld]=type%d:%d", (long long)i, e->type, e->type == 1 ? e->value.as_bool : -1);
        if (i == 0 && e->type == 1) first = e->value.as_bool;
    }
    printf("\n");
    return first;
}

int wmain(void) {
    HMODULE lib = LoadLibraryW(L"librustdesk.dll");
    printf("fake librustdesk = %p\n", (void *)lib);
    if (!lib) return 1;

    PFN_WIRE w = (PFN_WIRE)GetProcAddress(lib, "wire_is_disable_installation");
    PFN_INT f2 = (PFN_INT)GetProcAddress(lib, "rustdesk_is_disable_installation");
    PFN_SET set = (PFN_SET)GetProcAddress(lib, "fake_set_flag");

    printf("--- before hook (expect [0]=0 / int=0) ---\n");
    read_wire(w);
    printf("  int  -> %d\n", f2 ? f2() : -99);

    HMODULE sas = LoadLibraryW(L"SAS.dll");
    printf("SAS.dll = %p\n", (void *)sas);

    HMODULE sh = LoadLibraryW(L"shell32.dll");
    PFN_SHGetKnownFolderPath g = (PFN_SHGetKnownFolderPath)GetProcAddress(sh, "SHGetKnownFolderPath");
    PWSTR p = NULL;
    g((REFKNOWNFOLDERID)&kRoamingAppData, 0, NULL, &p);
    printf("roaming = %ls\n", p ? p : L"(null)");

    printf("--- after hook (expect [0]=1 / int=1) ---\n");
    int v1 = read_wire(w);
    int v2 = f2 ? f2() : -99;
    printf("  int  -> %d\n", v2);

    int pass = (v1 == 1 && v2 == 1);
    printf("\n%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 2;
}