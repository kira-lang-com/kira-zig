#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#if defined(_WIN32)
#define KIRA_BRIDGE_EXPORT __declspec(dllexport)
#else
#define KIRA_BRIDGE_EXPORT
#endif

static void (*kira_runtime_invoker)(uint32_t) = NULL;
typedef struct {
    const unsigned char *ptr;
    size_t len;
} KiraBridgeString;

typedef enum {
    KIRA_BRIDGE_VALUE_VOID = 0,
    KIRA_BRIDGE_VALUE_INTEGER = 1,
    KIRA_BRIDGE_VALUE_STRING = 2,
    KIRA_BRIDGE_VALUE_BOOLEAN = 3,
    KIRA_BRIDGE_VALUE_RAW_PTR = 4
} KiraBridgeValueTag;

typedef union {
    int64_t integer;
    KiraBridgeString string;
    uint8_t boolean;
    uintptr_t raw_ptr;
} KiraBridgePayload;

typedef struct {
    uint8_t tag;
    uint8_t reserved[7];
    KiraBridgePayload payload;
} KiraBridgeValue;

static void (*kira_runtime_invoker_ex)(uint32_t, const KiraBridgeValue *, uint32_t, KiraBridgeValue *) = NULL;

KIRA_BRIDGE_EXPORT void kira_native_print_i64(int64_t value) {
    printf("%lld\n", (long long)value);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_native_print_string(const unsigned char *ptr, size_t len) {
    fwrite(ptr, 1, len, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_hybrid_install_runtime_invoker(void (*invoker)(uint32_t, const KiraBridgeValue *, uint32_t, KiraBridgeValue *)) {
    kira_runtime_invoker_ex = invoker;
}

KIRA_BRIDGE_EXPORT void kira_hybrid_call_runtime(uint32_t function_id, const KiraBridgeValue *args, uint32_t arg_count, KiraBridgeValue *out_result) {
    if (kira_runtime_invoker_ex != NULL) {
        kira_runtime_invoker_ex(function_id, args, arg_count, out_result);
        return;
    }
    if (kira_runtime_invoker != NULL) {
        kira_runtime_invoker(function_id);
    }
}
