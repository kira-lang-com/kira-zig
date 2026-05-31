/*
 * Focused regression test for the native array registry leak.
 *
 * Before the fix, kira_array_alloc() called kira_array_register(), which did one
 * raw malloc() per allocation to push a node onto a global linked list that was
 * never freed (kira_array_unregister was never called) and never read (the
 * registry scan in kira_array_is_active had already been removed). That is an
 * unbounded native leak: 2 raw mallocs per zero-length array instead of 1.
 *
 * This test interposes the process allocator (counting wrapper over the real
 * libc allocator via dlsym(RTLD_NEXT, ...)) and measures the number of raw
 * allocations performed by kira_array_alloc(). With the registry removed each
 * zero-length array must cost exactly ONE allocation (the KiraArray struct).
 * A nonzero per-array registry node would push this to two and fail the test.
 *
 * It also asserts the array contract and value behavior are preserved.
 *
 * Build/run (driven by run_array_registry_leak_test.sh):
 *   cc -O2 array_registry_leak_test.c ../../../packages/kira_native_bridge/src/runtime_helpers.c -o leak_test && ./leak_test
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* ---- counting allocator interposer -------------------------------------- */

static void *(*real_malloc)(size_t) = NULL;
static void *(*real_calloc)(size_t, size_t) = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;
static void (*real_free)(void *) = NULL;

static int resolving = 0;
static long alloc_count = 0;   /* allocations while `counting` is set */
static long free_count = 0;    /* frees while `counting` is set */
static int counting = 0;

/* Tiny bootstrap arena to serve allocations that happen *during* dlsym(). */
static char boot_arena[1 << 16];
static size_t boot_off = 0;
static int in_boot(const void *p) {
    return (const char *)p >= boot_arena && (const char *)p < boot_arena + sizeof(boot_arena);
}
static void *boot_alloc(size_t n) {
    size_t a = (n + 15) & ~(size_t)15;
    if (boot_off + a > sizeof(boot_arena)) return NULL;
    void *p = boot_arena + boot_off;
    boot_off += a;
    return p;
}

static void resolve_real(void) {
    if (real_malloc || resolving) return;
    resolving = 1;
    real_malloc = (void *(*)(size_t))dlsym(RTLD_NEXT, "malloc");
    real_calloc = (void *(*)(size_t, size_t))dlsym(RTLD_NEXT, "calloc");
    real_realloc = (void *(*)(void *, size_t))dlsym(RTLD_NEXT, "realloc");
    real_free = (void (*)(void *))dlsym(RTLD_NEXT, "free");
    resolving = 0;
}

void *malloc(size_t n) {
    if (!real_malloc) { resolve_real(); if (!real_malloc) return boot_alloc(n); }
    if (counting) alloc_count++;
    return real_malloc(n);
}

void *calloc(size_t c, size_t s) {
    if (!real_calloc) { resolve_real(); if (!real_calloc) { void *p = boot_alloc(c * s); if (p) memset(p, 0, c * s); return p; } }
    if (counting) alloc_count++;
    return real_calloc(c, s);
}

void *realloc(void *p, size_t n) {
    if (!real_realloc) { resolve_real(); }
    if (counting) alloc_count++;
    return real_realloc(p, n);
}

void free(void *p) {
    if (in_boot(p)) return;            /* bootstrap allocations are never freed */
    if (!real_free) { resolve_real(); }
    if (counting && p != NULL) free_count++;
    if (real_free) real_free(p);
}

/* ---- bridge surface under test ------------------------------------------ */

typedef struct { const unsigned char *ptr; size_t len; } KiraBridgeString;
typedef union { int64_t integer; double float64; KiraBridgeString string; uint8_t boolean; uintptr_t raw_ptr; } KiraBridgePayload;
typedef struct { uint8_t tag; uint8_t reserved[7]; KiraBridgePayload payload; } KiraBridgeValue;
typedef struct KiraArray KiraArray;

extern KiraArray *kira_array_alloc(int64_t len);
extern int64_t kira_array_len(const KiraArray *array);
extern void kira_array_store(KiraArray *array, int64_t index, const KiraBridgeValue *value);
extern void kira_array_append(KiraArray *array, const KiraBridgeValue *value);
extern void kira_array_load(const KiraArray *array, int64_t index, KiraBridgeValue *out_value);
extern void kira_array_release(KiraArray *array, void (*release_raw_ptr)(void *));

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL: %s (line %d)\n", #cond, __LINE__); return 1; } } while (0)

/* element destructor for section 5: frees the heap element and counts it. */
static long g_destroyed = 0;
static void test_destroy_element(void *p) {
    if (real_free) real_free(p);
    g_destroyed++;
}

int main(void) {
    resolve_real();

    /* ---- 1. registry leak proof: allocations per array is exactly 1 ------ */
    enum { N = 4096 };
    counting = 1;
    long before = alloc_count;
    KiraArray *arrays[N];
    for (int i = 0; i < N; i++) arrays[i] = kira_array_alloc(0); /* len 0 => only the struct allocates */
    long per_array_total = alloc_count - before;
    counting = 0;

    fprintf(stderr, "allocations for %d zero-length arrays = %ld (expect %d)\n", N, per_array_total, N);
    /* New code: 1 alloc/array (KiraArray struct). Old code: 2 (struct + leaked registry node). */
    CHECK(per_array_total == (long)N);

    for (int i = 0; i < N; i++) CHECK(arrays[i] != NULL);

    /* ---- 2. contract: null is inactive ---------------------------------- */
    CHECK(kira_array_len(NULL) == 0);
    KiraBridgeValue out;
    memset(&out, 0xAB, sizeof(out));
    kira_array_load(NULL, 0, &out);
    CHECK(out.tag == 0 && out.payload.integer == 0); /* zero-filled on inactive */

    /* ---- 3. value behavior preserved: alloc / store / load / append ----- */
    KiraArray *a = kira_array_alloc(3);
    CHECK(a != NULL);
    CHECK(kira_array_len(a) == 3);

    KiraBridgeValue v = (KiraBridgeValue){0};
    v.tag = 1; v.payload.integer = 42;
    kira_array_store(a, 1, &v);
    KiraBridgeValue got = (KiraBridgeValue){0};
    kira_array_load(a, 1, &got);
    CHECK(got.tag == 1 && got.payload.integer == 42);

    /* out-of-bounds store is ignored, out-of-bounds load zero-fills */
    kira_array_store(a, 99, &v);
    memset(&got, 0x7F, sizeof(got));
    kira_array_load(a, 99, &got);
    CHECK(got.tag == 0 && got.payload.integer == 0);

    /* append grows length and stores the value */
    KiraBridgeValue w = (KiraBridgeValue){0};
    w.tag = 1; w.payload.integer = 7;
    kira_array_append(a, &w);
    CHECK(kira_array_len(a) == 4);
    kira_array_load(a, 3, &got);
    CHECK(got.tag == 1 && got.payload.integer == 7);

    /* ---- 4. ownership-model release reclaims (free at the owner's drop) ----
     * No VM allocator installed => pure-native path with KIRA_ARRAY_OWNERSHIP_FREE.
     * Allocating M arrays of length 3 then releasing them must return live
     * allocations to baseline (struct + items freed). The element destructor runs
     * once per RAW_PTR element. (When the ownership-free build flag is off, release
     * defers and this section is skipped.) */
#if defined(KIRA_ARRAY_OWNERSHIP_FREE)
    enum { M = 4096 };
    counting = 1;
    long live_before = alloc_count - free_count;
    KiraArray *rs[M];
    for (int i = 0; i < M; i++) rs[i] = kira_array_alloc(3);
    long live_after_alloc = alloc_count - free_count;
    for (int i = 0; i < M; i++) kira_array_release(rs[i], NULL);
    long live_after_release = alloc_count - free_count;
    counting = 0;
    CHECK(live_after_alloc - live_before == 2 * (long)M); /* struct + items per array */
    CHECK(live_after_release == live_before);             /* fully reclaimed */

    /* element destructor runs for each heap (RAW_PTR) element */
    g_destroyed = 0;
    KiraArray *holder = kira_array_alloc(2);
    for (int i = 0; i < 2; i++) {
        KiraBridgeValue e = (KiraBridgeValue){0};
        e.tag = 5; /* RAW_PTR */
        e.payload.raw_ptr = (uintptr_t)real_malloc(64);
        kira_array_store(holder, i, &e);
    }
    kira_array_release(holder, test_destroy_element);
    CHECK(g_destroyed == 2);
    fprintf(stderr, "PASS: registry leak removed, behavior preserved, ownership release reclaims\n");
#else
    /* Free gated off: release must defer (no free, no crash, storage intact). */
    counting = 1;
    long live_after_alloc = alloc_count - free_count;
    KiraArray *r = kira_array_alloc(3);
    kira_array_store(r, 0, &v);
    kira_array_release(r, test_destroy_element);
    long live_after_release = alloc_count - free_count;
    counting = 0;
    CHECK(live_after_release >= live_after_alloc);  /* no reclamation */
    CHECK(g_destroyed == 0);
    CHECK(kira_array_len(r) == 3);
    kira_array_load(r, 0, &got);
    CHECK(got.tag == 1 && got.payload.integer == 42);
    fprintf(stderr, "PASS: registry leak removed, behavior preserved, release is a safe no-op\n");
#endif
    return 0;
}
