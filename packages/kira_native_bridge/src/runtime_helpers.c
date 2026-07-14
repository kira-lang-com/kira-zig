#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <mach-o/loader.h>
const struct mach_header *_dyld_get_image_header_containing_address(const void *address) {
    (void)address;
    return NULL;
}
#endif
#endif

#if defined(_WIN32)
#define KIRA_BRIDGE_EXPORT __declspec(dllexport)
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#define KIRA_BRIDGE_EXPORT
#include <time.h>
#endif

static void (*kira_runtime_invoker)(uint32_t) = NULL;
typedef struct {
    const unsigned char *ptr;
    size_t len;
} KiraBridgeString;

typedef enum {
    KIRA_BRIDGE_VALUE_VOID = 0,
    KIRA_BRIDGE_VALUE_INTEGER = 1,
    KIRA_BRIDGE_VALUE_FLOAT = 2,
    KIRA_BRIDGE_VALUE_STRING = 3,
    KIRA_BRIDGE_VALUE_BOOLEAN = 4,
    KIRA_BRIDGE_VALUE_RAW_PTR = 5
} KiraBridgeValueTag;

typedef union {
    int64_t integer;
    double float64;
    KiraBridgeString string;
    uint8_t boolean;
    uintptr_t raw_ptr;
} KiraBridgePayload;

typedef struct {
    uint8_t tag;
    uint8_t reserved[7];
    KiraBridgePayload payload;
} KiraBridgeValue;

typedef struct {
    size_t len;
    KiraBridgeValue *items;
    /* Capacity of the `items` allocation, in elements. Invariant shared with the
     * VM heap (ownership.zig): the items buffer is always exactly max(cap, 1)
     * elements, len <= cap. Appends grow geometrically through `cap`, replacing
     * the old grow-by-one realloc that made building an n-element array O(n^2)
     * memcpy (the dominant native-frame cost in dense UI trees). */
    size_t cap;
} KiraArray;

/* Native-backend native-state token. These three fields are the C-ABI prefix shared with
 * the VM's `NativeStateBox` (packages/kira_vm_runtime/src/vm.zig). The VM appends VM-internal
 * metadata fields after this prefix, but tokens are never cast across backends: the native
 * path allocates/reads only this 3-field struct, and its `payload` is a raw byte buffer, while
 * the VM's payload holds Zig BridgeValue/Value arrays. A comptime assertion on the Zig side
 * enforces that this prefix layout stays in sync. */
typedef struct {
    uint64_t type_id;
    void *payload;
    void *runtime_payload;
} KiraNativeState;

static void (*kira_runtime_invoker_ex)(uint32_t, const KiraBridgeValue *, uint32_t, KiraBridgeValue *) = NULL;
static void *(*kira_array_alloc_fn)(size_t) = NULL;
static void (*kira_closure_destroy_fn)(uintptr_t) = NULL;
static void (*kira_array_free_fn)(void *, size_t) = NULL;
static void (*kira_live_first_frame_hook)(void) = NULL;
static void (*kira_live_log_hook)(const char*) = NULL;
static int kira_trace_execution_enabled = -1;
#if defined(_WIN32)
static int kira_stdout_binary_configured = 0;
#endif

static void kira_prepare_stdout(void) {
#if defined(_WIN32)
    if (!kira_stdout_binary_configured) {
        _setmode(_fileno(stdout), _O_BINARY);
        kira_stdout_binary_configured = 1;
    }
#endif
}

static int kira_trace_enabled(void) {
    /*
     * Memoize the environment lookup. This is called from kira_trace_log on every
     * array release, print, and bridge op, so a fresh getenv() here (a locked,
     * linear scan of the process environment) on each call dominated the runtime of
     * allocation-heavy native programs — the per-operation trace check was the bulk
     * of `kira_array_release`'s self time under profiling. Resolve the env var once
     * and cache it; kira_set_execution_trace_enabled still overrides explicitly.
     */
    if (kira_trace_execution_enabled < 0) {
        const char *value = getenv("KIRA_TRACE_EXECUTION");
        kira_trace_execution_enabled =
            (value != NULL && value[0] != '\0' && value[0] != '0') ? 1 : 0;
    }
    return kira_trace_execution_enabled;
}

static void kira_trace_log(const char *domain, const char *event, const char *fmt, ...) {
    if (!kira_trace_enabled()) return;

    fprintf(stderr, "[trace][%s][%s] ", domain, event);
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
    fflush(stderr);
}

static int kira_bridge_probably_invalid_pointer(const void *ptr) {
    uintptr_t value = (uintptr_t)ptr;
    return value != 0 && value < 4096;
}

static void kira_array_repair_invalid_storage(KiraArray *array) {
    if (array == NULL) return;
    if (kira_bridge_probably_invalid_pointer(array->items)) {
        kira_trace_log("NATIVE", "ARRAY_REPAIR", "items=%p len=%llu", (void *)array->items, (unsigned long long)array->len);
        array->items = NULL;
        array->len = 0;
        array->cap = 0;
    }
}

static int kira_array_is_active(const KiraArray *array) {
    /*
     * Validity contract: reject only null and sentinel-small pointers. There is
     * deliberately no live-array registry to consult.
     *
     * A global linked-list registry (kira_active_arrays) used to exist here, but
     * once profiling removed the registry scan from this function the registry
     * became write-only dead weight: kira_array_register malloc'd a node on every
     * kira_array_alloc and kira_array_unregister was never called, so the list
     * grew unbounded — a genuine native memory leak under UI workloads. The whole
     * registry has been removed. Membership could never be the validity check
     * anyway: hybrid runtime calls pass arrays whose native layout was allocated
     * by the Zig VM bridge rather than by kira_array_alloc in this C helper, and
     * those borrowed arrays are valid for native reads, writes, and appends for
     * the duration of the call. The VM owns final destruction after it syncs the
     * borrowed layout back.
     */
    if (array == NULL || kira_bridge_probably_invalid_pointer(array)) return 0;
    return 1;
}

KIRA_BRIDGE_EXPORT void kira_set_execution_trace_enabled(uint8_t enabled) {
    kira_trace_execution_enabled = enabled != 0 ? 1 : 0;
}

/*
 * Hybrid closure teardown: runtime-exported closure blocks are allocated by the
 * VM allocator (exportRuntimeClosureToNative) and tracked VM-side, so a native
 * drop must hand them back to the runtime instead of calling libc free (which
 * traps on the smp pointer and would double-free at VM deinit). The hook
 * receives the UNTAGGED block pointer.
 */
KIRA_BRIDGE_EXPORT void kira_hybrid_install_closure_destroy(void (*destroy_fn)(uintptr_t)) {
    kira_closure_destroy_fn = destroy_fn;
}

KIRA_BRIDGE_EXPORT void kira_hybrid_install_array_allocator(void *(*alloc_fn)(size_t), void (*free_fn)(void *, size_t)) {
    kira_array_alloc_fn = alloc_fn;
    kira_array_free_fn = free_fn;
}

KIRA_BRIDGE_EXPORT void kira_live_install_first_frame_hook(void (*hook)(void)) {
    kira_live_first_frame_hook = hook;
}

KIRA_BRIDGE_EXPORT void kira_live_install_log_hook(void (*hook)(const char*)) {
    kira_live_log_hook = hook;
}

KIRA_BRIDGE_EXPORT void kira_live_emit_log_line(const char* line) {
    if (line == NULL) {
        return;
    }
    if (kira_live_log_hook != NULL) {
        kira_live_log_hook(line);
    }
    fprintf(stderr, "%s\n", line);
    fflush(stderr);
}

KIRA_BRIDGE_EXPORT void kira_live_emit_first_frame(void) {
    if (kira_live_first_frame_hook != NULL) {
        kira_live_first_frame_hook();
    }
}

static void *kira_bridge_alloc(size_t size) {
    if (size == 0) {
        size = 1;
    }
    if (kira_array_alloc_fn != NULL) {
        return kira_array_alloc_fn(size);
    }
    return malloc(size);
}

static void *kira_bridge_calloc(size_t count, size_t size) {
    const size_t total = count * size;
    void *ptr = kira_bridge_alloc(total);
    if (ptr != NULL) {
        memset(ptr, 0, total == 0 ? 1 : total);
    }
    return ptr;
}

static void kira_bridge_free(void *ptr, size_t size) {
    if (ptr == NULL) {
        return;
    }
    if (kira_array_free_fn != NULL) {
        kira_array_free_fn(ptr, size == 0 ? 1 : size);
        return;
    }
    free(ptr);
}

KIRA_BRIDGE_EXPORT void kira_native_write_i64(int64_t value) {
    kira_prepare_stdout();
    kira_trace_log("NATIVE", "PRINT", "i64");
    printf("%lld", (long long)value);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_native_write_f64(double value) {
    kira_prepare_stdout();
    kira_trace_log("NATIVE", "PRINT", "f64");
    printf("%g", value);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_native_write_string(const unsigned char *ptr, uint64_t len) {
    kira_prepare_stdout();
    kira_trace_log("NATIVE", "PRINT", "string len=%llu", (unsigned long long)len);
    fwrite(ptr, 1, (size_t)len, stdout);
    fflush(stdout);
}

/*
 * The incoming value is a Kira i64 register (a pointer widened to 64 bits), so the
 * parameter is uint64_t on every target — NOT uintptr_t, which is 32-bit on wasm32
 * and would disagree with the backend's void(i64) declaration (wasm-ld signature
 * mismatch). Casting to void* / printing truncates to the real pointer width.
 */
KIRA_BRIDGE_EXPORT void kira_native_write_ptr(uint64_t value) {
    kira_prepare_stdout();
    kira_trace_log("NATIVE", "PRINT", "ptr");
    printf("0x%llx", (unsigned long long)value);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_native_write_newline(void) {
    kira_prepare_stdout();
    fputc('\n', stdout);
    fflush(stdout);
}

KIRA_BRIDGE_EXPORT void kira_native_print_i64(int64_t value) {
    kira_native_write_i64(value);
    kira_native_write_newline();
}

KIRA_BRIDGE_EXPORT void kira_native_print_f64(double value) {
    kira_native_write_f64(value);
    kira_native_write_newline();
}

KIRA_BRIDGE_EXPORT void kira_native_print_string(const unsigned char *ptr, uint64_t len) {
    kira_native_write_string(ptr, len);
    kira_native_write_newline();
}

/*
 * String primitives (`String(x)` conversions and `s.charAt/substring/indexOf`).
 * Semantics mirror the VM interpreter arms in vm_interpreter.zig exactly —
 * parity is the contract:
 *   - String(Int)  → base-10, matches Zig `{d}` (plain %lld).
 *   - String(Bool) → "true"/"false".
 *   - String(Float)→ shortest decimal that round-trips through strtod, expanded
 *     to plain (non-scientific) notation — byte-identical to Zig's `{d}` float
 *     rendering the VM uses. NaN/inf render "nan"/"inf"/"-inf".
 *   - charAt OOB and substring invalid-range ABORT (the VM traps; the pure-Kira
 *     test driver's KTRAP re-run depends on the abort, so no soft sentinel).
 *   - indexOf: empty needle → 0, absent → -1.
 * Out-params write a {ptr,len} KiraBridgeString slot; buffers are plain malloc,
 * matching the string-buffer ownership model used by the array element clone
 * path above (libc-owned on the native path even in hybrid builds).
 */
static void kira_string_out(KiraBridgeString *out, const char *bytes, size_t len) {
    unsigned char *buf = (unsigned char *)malloc(len == 0 ? 1 : len);
    if (buf == NULL) {
        fprintf(stderr, "kira string allocation failed\n");
        abort();
    }
    memcpy(buf, bytes, len);
    out->ptr = buf;
    out->len = len;
}

KIRA_BRIDGE_EXPORT void kira_string_from_i64(int64_t value, KiraBridgeString *out) {
    char tmp[32];
    int n = snprintf(tmp, sizeof tmp, "%lld", (long long)value);
    kira_string_out(out, tmp, (size_t)n);
}

KIRA_BRIDGE_EXPORT void kira_string_from_bool(int64_t value, KiraBridgeString *out) {
    if (value != 0) kira_string_out(out, "true", 4);
    else kira_string_out(out, "false", 5);
}

KIRA_BRIDGE_EXPORT void kira_string_from_f64(double value, KiraBridgeString *out) {
    if (isnan(value)) { kira_string_out(out, "nan", 3); return; }
    if (isinf(value)) {
        if (value < 0) kira_string_out(out, "-inf", 4);
        else kira_string_out(out, "inf", 3);
        return;
    }
    /* Shortest %.*g that round-trips (Zig {d} equivalence), then expand any
     * scientific form to plain decimal so 1e20 renders as the full digit run
     * and 1.5e-7 as 0.00000015 — the notation Zig's {d} always uses. */
    char g[64];
    int prec;
    for (prec = 1; prec <= 17; prec++) {
        snprintf(g, sizeof g, "%.*g", prec, value);
        if (strtod(g, NULL) == value) break;
    }
    const char *e = strpbrk(g, "eE");
    if (e == NULL) {
        kira_string_out(out, g, strlen(g));
        return;
    }
    /* Split mantissa/exponent: [-]D[.DDD] e [+-]XX */
    char plain[1100]; /* |exp| <= 308 for doubles; buffer is comfortably larger */
    size_t pn = 0;
    int exp10 = (int)strtol(e + 1, NULL, 10);
    int neg = g[0] == '-';
    const char *m = g + (neg ? 1 : 0);
    char digits[32];
    size_t nd = 0;
    int point = -1; /* digit count before the '.' in the mantissa */
    for (const char *p = m; p < e; p++) {
        if (*p == '.') { point = (int)nd; continue; }
        digits[nd] = *p;
        nd = nd + 1;
    }
    if (point < 0) point = (int)nd;
    int dp = point + exp10; /* decimal point position within `digits` */
    if (neg) plain[pn++] = '-';
    if (dp <= 0) {
        plain[pn++] = '0';
        plain[pn++] = '.';
        for (int i = 0; i < -dp; i++) plain[pn++] = '0';
        for (size_t i = 0; i < nd; i++) plain[pn++] = digits[i];
    } else if ((size_t)dp >= nd) {
        for (size_t i = 0; i < nd; i++) plain[pn++] = digits[i];
        for (int i = 0; i < dp - (int)nd; i++) plain[pn++] = '0';
    } else {
        for (int i = 0; i < dp; i++) plain[pn++] = digits[i];
        plain[pn++] = '.';
        for (size_t i = (size_t)dp; i < nd; i++) plain[pn++] = digits[i];
    }
    kira_string_out(out, plain, pn);
}

KIRA_BRIDGE_EXPORT int64_t kira_string_char_at(const unsigned char *ptr, int64_t len, int64_t index) {
    if (ptr == NULL || index < 0 || index >= len) {
        fprintf(stderr, "kira runtime trap: string index is out of bounds\n");
        abort();
    }
    return (int64_t)ptr[index];
}

KIRA_BRIDGE_EXPORT void kira_string_substring(const unsigned char *ptr, int64_t len, int64_t start, int64_t end, KiraBridgeString *out) {
    if (start < 0 || end > len || start > end) {
        fprintf(stderr, "kira runtime trap: string substring range is out of bounds\n");
        abort();
    }
    kira_string_out(out, (const char *)(ptr + start), (size_t)(end - start));
}

KIRA_BRIDGE_EXPORT int64_t kira_string_index_of(const unsigned char *hptr, int64_t hlen, const unsigned char *nptr, int64_t nlen) {
    if (nlen == 0) return 0;
    if (hlen < nlen) return -1;
    for (int64_t i = 0; i + nlen <= hlen; i++) {
        if (memcmp(hptr + i, nptr, (size_t)nlen) == 0) return i;
    }
    return -1;
}

/* Cohesive runtime subsystems remain textual includes so they share the bridge
 * ABI types and allocator hooks above while keeping every source file small
 * enough to review independently. */
#include "runtime_helpers_arrays.inc"
#include "runtime_helpers_native_state.inc"
#include "runtime_helpers_tasks.inc"
