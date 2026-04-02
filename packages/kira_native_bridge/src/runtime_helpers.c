#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#if defined(_WIN32)
#define KIRA_BRIDGE_EXPORT __declspec(dllexport)
#else
#define KIRA_BRIDGE_EXPORT
#endif

static void (*kira_runtime_invoker)(uint32_t) = NULL;

KIRA_BRIDGE_EXPORT void kira_native_print_i64(int64_t value) {
    printf("%lld\n", (long long)value);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_native_print_string(const unsigned char *ptr, size_t len) {
    fwrite(ptr, 1, len, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_hybrid_install_runtime_invoker(void (*invoker)(uint32_t)) {
    kira_runtime_invoker = invoker;
}

KIRA_BRIDGE_EXPORT void kira_hybrid_call_runtime(uint32_t function_id) {
    if (kira_runtime_invoker != NULL) {
        kira_runtime_invoker(function_id);
    }
}
