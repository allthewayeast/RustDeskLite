// 只读探针：直接调用真实 librustdesk.dll 的 wire_is_disable_installation，
// 打印它返回的 DartCObject（FRB 的 WireSyncReturn）内存布局，用于确认能否安全改值。
#include <windows.h>
#include <stdio.h>

typedef void *(*PFN_WIRE)(void);

static void hexdump(const unsigned char *p, int n) {
    for (int i = 0; i < n; i++) {
        printf("%02x ", p[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    printf("\n");
}

int wmain(void) {
    const wchar_t *path = L"C:\\Program Files\\RustDesk\\librustdesk.dll";
    HMODULE lib = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    printf("lib = %p (err %lu)\n", (void *)lib, GetLastError());
    if (!lib) return 1;

    PFN_WIRE f = (PFN_WIRE)GetProcAddress(lib, "wire_is_disable_installation");
    printf("wire_is_disable_installation = %p\n", (void *)f);
    if (!f) return 1;

    void *obj = f();
    printf("returned = %p\n", obj);
    if (!obj) return 1;

    printf("--- first 32 bytes of returned object ---\n");
    hexdump((const unsigned char *)obj, 32);

    int type = *(int *)obj;
    long long len = *(long long *)((char *)obj + 8);
    void **vals = *(void ***)((char *)obj + 16);
    printf("type=%d len=%lld vals=%p\n", type, len, (void *)vals);
    if (type == 6 && vals) {
        for (int i = 0; i < len && i < 4; i++) {
            unsigned char *e = (unsigned char *)vals[i];
            printf("  elem[%d] ptr=%p type=%d value_byte=%d  bytes:", i, (void *)e,
                   e ? *(int *)e : -1, e ? (int)e[8] : -1);
            for (int k = 0; k < 16 && e; k++) printf(" %02x", e[k]);
            printf("\n");
        }
    }
    return 0;
}
