// 自测用：按 flutter_rust_bridge v1 的真实布局模拟两个导出
//   wire_is_disable_installation() -> *mut DartCObject
//   返回 DartCObject(kArray)[ bool(值), bool(success) ]
// 编译：/LD 输出为 librustdesk.dll，放在探针同目录
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct _DartCObject DartCObject;
struct _DartCObject {
    int type;                 // 0
    union {
        int64_t as_int64;
        double as_double;
        const char *as_string;
        const uint8_t *as_byte_array;
        void *as_pointer;
        int as_bool;          // offset 8
        struct { intptr_t length; DartCObject **values; } as_array;   // len@8, values@16
        struct { void *callback; void *user_data; } as_external_typed_data;
    } value;
};

static int g_flag = 0;        // 模拟 is_disable_installation() 的返回值

__declspec(dllexport) void *wire_is_disable_installation(void) {
    DartCObject *arr = (DartCObject *)calloc(1, sizeof(DartCObject));
    DartCObject *v = (DartCObject *)calloc(1, sizeof(DartCObject));
    DartCObject *ok = (DartCObject *)calloc(1, sizeof(DartCObject));
    DartCObject **vals = (DartCObject **)calloc(2, sizeof(DartCObject *));
    v->type = 1;  v->value.as_bool = g_flag;
    ok->type = 1; ok->value.as_bool = 1;
    vals[0] = v; vals[1] = ok;
    arr->type = 6;
    arr->value.as_array.length = 2;
    arr->value.as_array.values = vals;
    return arr;
}

__declspec(dllexport) int rustdesk_is_disable_installation(void) { return g_flag; }

__declspec(dllexport) void fake_set_flag(int v) { g_flag = v; }

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    (void)hModule; (void)reason; (void)lpReserved;
    return TRUE;
}