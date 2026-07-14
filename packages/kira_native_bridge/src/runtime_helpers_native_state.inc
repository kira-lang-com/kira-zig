/* Registry of live native-backend state tokens. The VM tracks every box it
 * allocates (`native_state_boxes`) and frees survivors at teardown
 * (deinitTrackedNativeStates); this list is the native binary's equivalent.
 * Tokens have no scope-based lifetime — `nativeUserData` handles may alias
 * them for the whole program — so the only sound reclamation points are an
 * explicit `kira_native_state_free` (which unlinks) and process exit (the
 * destructor below frees every survivor through the same typed-interior
 * path). Registry nodes are external so the 3-field token ABI prefix shared
 * with the VM stays untouched. */
typedef struct KiraNativeStateNode {
    KiraNativeState *state;
    struct KiraNativeStateNode *next;
} KiraNativeStateNode;
static KiraNativeStateNode *kira_native_state_registry = NULL;

#if defined(_WIN32)
#include <windows.h>
static SRWLOCK kira_native_state_registry_lock = SRWLOCK_INIT;
static void kira_native_state_registry_acquire(void) { AcquireSRWLockExclusive(&kira_native_state_registry_lock); }
static void kira_native_state_registry_release(void) { ReleaseSRWLockExclusive(&kira_native_state_registry_lock); }
#else
#include <pthread.h>
static pthread_mutex_t kira_native_state_registry_lock = PTHREAD_MUTEX_INITIALIZER;
static void kira_native_state_registry_acquire(void) { pthread_mutex_lock(&kira_native_state_registry_lock); }
static void kira_native_state_registry_release(void) { pthread_mutex_unlock(&kira_native_state_registry_lock); }
#endif

static void kira_native_state_registry_teardown(void);

static void kira_native_state_registry_add(KiraNativeState *state) {
    static int teardown_registered = 0;
    KiraNativeStateNode *node = (KiraNativeStateNode *)malloc(sizeof(KiraNativeStateNode));
    if (node == NULL) return; /* untracked: survives to exit unreclaimed, never unsafe */
    node->state = state;
    kira_native_state_registry_acquire();
    if (!teardown_registered) {
        teardown_registered = 1;
        atexit(kira_native_state_registry_teardown);
    }
    node->next = kira_native_state_registry;
    kira_native_state_registry = node;
    kira_native_state_registry_release();
}

static void kira_native_state_registry_remove(KiraNativeState *state) {
    kira_native_state_registry_acquire();
    KiraNativeStateNode **link = &kira_native_state_registry;
    while (*link != NULL) {
        if ((*link)->state == state) {
            KiraNativeStateNode *dead = *link;
            *link = dead->next;
            free(dead);
            break;
        }
        link = &(*link)->next;
    }
    kira_native_state_registry_release();
}

KIRA_BRIDGE_EXPORT KiraNativeState *kira_native_state_alloc(uint64_t type_id, int64_t payload_size) {
    if (payload_size < 0) return NULL;
    KiraNativeState *state = (KiraNativeState *)calloc(1, sizeof(KiraNativeState));
    if (state == NULL) return NULL;
    state->type_id = type_id;
    state->payload = payload_size == 0 ? NULL : calloc(1, (size_t)payload_size);
    state->runtime_payload = NULL;
    if (payload_size != 0 && state->payload == NULL) {
        free(state);
        return NULL;
    }
    kira_native_state_registry_add(state);
    return state;
}

KIRA_BRIDGE_EXPORT void *kira_struct_alloc(uint64_t type_id, size_t size) {
    unsigned char *base = (unsigned char *)malloc(sizeof(uint64_t) + size);
    if (base == NULL) return NULL;
    *((uint64_t *)base) = type_id;
    void *payload = (void *)(base + sizeof(uint64_t));
    memset(payload, 0, size);
    return payload;
}

KIRA_BRIDGE_EXPORT uint64_t kira_struct_type_id(void *ptr) {
    if (ptr == NULL) return 0;
    return *(((uint64_t *)ptr) - 1);
}

KIRA_BRIDGE_EXPORT void kira_struct_free(void *ptr) {
    if (ptr == NULL) return;
    free(((unsigned char *)ptr) - sizeof(uint64_t));
}

KIRA_BRIDGE_EXPORT void *kira_native_state_payload(KiraNativeState *state) {
    if (state == NULL) return NULL;
    return state->payload;
}

/* Shallow free of a native-backend native-state token (`nativeStateFree`).
 * Frees the payload byte buffer and the token itself; interior heap values
 * (arrays/strings copied into the payload) stay governed by the array/string
 * ownership model. `runtime_payload` is VM-owned metadata and is never set on
 * native-allocated tokens, so it is not touched here. Outstanding
 * `nativeRecover` views into this state become dangling — freeing is the
 * caller's declaration that no views survive. */
/* Typed interior teardown hook for native-state tokens. The LLVM backend's
 * generated kira_capi_state_interior_release (installed by the same global
 * constructor as the closure-destroy hook, native builds only) switches on
 * state->type_id and frees the heap values the payload's bridge slots own
 * (string buffers, arrays, boxed structs, closures, type-erased shells) —
 * VM parity with freeNativeState, which destroys interiors. NULL (hybrid /
 * drop-disabled builds) keeps the historical shallow free. */
static void (*kira_state_interior_release_fn)(KiraNativeState *) = NULL;

KIRA_BRIDGE_EXPORT void kira_capi_install_state_interior_release(void (*release_fn)(KiraNativeState *)) {
    kira_state_interior_release_fn = release_fn;
}

static void kira_native_state_dispose(KiraNativeState *state) {
    if (kira_state_interior_release_fn != NULL) {
        kira_state_interior_release_fn(state);
    }
    free(state->payload);
    state->payload = NULL;
    free(state);
}

KIRA_BRIDGE_EXPORT void kira_native_state_free(KiraNativeState *state) {
    if (state == NULL) return;
    kira_native_state_registry_remove(state);
    kira_native_state_dispose(state);
}

/* Process-exit teardown of surviving native-state tokens — VM parity with
 * deinitTrackedNativeStates. Registered via atexit on the first allocation
 * (see kira_native_state_registry_add), so it runs during exit() before the
 * final leak accounting: tokens that legitimately live for the whole program
 * (userdata handles held by FFI callbacks) are reclaimed rather than
 * reported as leaks. Interiors go through the typed release hook when
 * installed (native builds); hybrid keeps the shallow free (VM-owned
 * interiors are the VM's to drop). */
static void kira_native_state_registry_teardown(void) {
    kira_native_state_registry_acquire();
    KiraNativeStateNode *node = kira_native_state_registry;
    kira_native_state_registry = NULL;
    kira_native_state_registry_release();
    while (node != NULL) {
        KiraNativeStateNode *next = node->next;
        kira_native_state_dispose(node->state);
        free(node);
        node = next;
    }
}

KIRA_BRIDGE_EXPORT void *kira_native_state_recover(void *user_data, uint64_t expected_type_id) {
    KiraNativeState *state = (KiraNativeState *)user_data;
    if (state == NULL) {
        fprintf(stderr, "kira native state recovery failed: userdata was null\n");
        abort();
    }
    if (state->type_id != expected_type_id) {
        fprintf(stderr, "kira native state recovery failed: userdata type mismatch\n");
        abort();
    }
    return state->payload;
}

KIRA_BRIDGE_EXPORT void kira_hybrid_install_runtime_invoker(void (*invoker)(uint32_t, const KiraBridgeValue *, uint32_t, KiraBridgeValue *)) {
    kira_runtime_invoker_ex = invoker;
}

KIRA_BRIDGE_EXPORT void kira_hybrid_call_runtime(uint32_t function_id, const KiraBridgeValue *args, uint32_t arg_count, KiraBridgeValue *out_result) {
    kira_trace_log("TRAMPOLINE", "ENTER", "native->runtime fn=%u args=%u", function_id, arg_count);
    if (kira_runtime_invoker_ex != NULL) {
        kira_runtime_invoker_ex(function_id, args, arg_count, out_result);
        if (out_result != NULL) {
            kira_trace_log("TRAMPOLINE", "RETURN", "runtime->native fn=%u tag=%u", function_id, (unsigned)out_result->tag);
        } else {
            kira_trace_log("TRAMPOLINE", "RETURN", "runtime->native fn=%u", function_id);
        }
        return;
    }
    if (kira_runtime_invoker != NULL) {
        kira_runtime_invoker(function_id);
        kira_trace_log("TRAMPOLINE", "RETURN", "runtime->native fn=%u", function_id);
    }
}

