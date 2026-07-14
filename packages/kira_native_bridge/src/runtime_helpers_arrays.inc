KIRA_BRIDGE_EXPORT KiraArray *kira_array_alloc(int64_t len) {
    if (len < 0) return NULL;
    KiraArray *array = (KiraArray *)kira_bridge_alloc(sizeof(KiraArray));
    if (array == NULL) return NULL;
    array->len = (size_t)len;
    array->cap = array->len;
    /* Invariant (shared with ownership.zig): the items allocation is always
     * exactly max(cap, 1) elements — never NULL, even for an empty array. The
     * VM destroy path reconstructs the slice as items[0..max(cap,1)] and would
     * otherwise free a one-element slice at address 0 for an empty array
     * returned across the bridge (Codex review). */
    const size_t item_count = array->len == 0 ? 1 : array->len;
    array->items = (KiraBridgeValue *)kira_bridge_calloc(item_count, sizeof(KiraBridgeValue));
    if (array->items == NULL) {
        kira_bridge_free(array, sizeof(KiraArray));
        return NULL;
    }
    return array;
}

/*
 * Deep clone for the borrow->owned boundary (pure-native path). The LLVM backend
 * emits this when an owned value is produced from borrowed data (e.g. returning a
 * struct element read out of a borrowed array), so the new owner gets independent
 * array storage instead of aliasing the borrowed array. `clone_elem`, when
 * provided, deep-clones each RAW_PTR element (an array of heap structs); a null
 * `clone_elem` copies elements byte-for-byte (primitive/leaf element types).
 * Ownership model only — no reference counts.
 */
/*
 * Deep-copy a string element's byte buffer so the clone owns independent storage.
 * String buffers inside owned arrays follow the same ownership model as RAW_PTR
 * elements: the backend clones every string INTO an array element, so the element
 * always owns its buffer, kira_array_release frees it, and a clone must therefore
 * duplicate it (aliasing would double-free). Plain malloc — string buffers are
 * libc-owned on the native path even in hybrid builds.
 */
static void kira_bridge_clone_string_element(KiraBridgeValue *value) {
    if (value->tag != KIRA_BRIDGE_VALUE_STRING) return;
    const unsigned char *src = value->payload.string.ptr;
    size_t len = value->payload.string.len;
    if (src == NULL) return;
    unsigned char *buf = (unsigned char *)malloc(len == 0 ? 1 : len);
    if (buf == NULL) { value->payload.string.ptr = NULL; value->payload.string.len = 0; return; }
    memcpy(buf, src, len);
    value->payload.string.ptr = buf;
}

KIRA_BRIDGE_EXPORT KiraArray *kira_array_clone(const KiraArray *array, void *(*clone_elem)(void *)) {
    if (kira_array_alloc_fn != NULL) return (KiraArray *)array; /* hybrid: VM owns; no native clone */
    if (array == NULL || kira_bridge_probably_invalid_pointer(array)) return NULL;
    KiraArray *copy = (KiraArray *)kira_bridge_alloc(sizeof(KiraArray));
    if (copy == NULL) return NULL;
    copy->len = array->len;
    copy->cap = array->len;
    if (array->len == 0 || array->items == NULL || kira_bridge_probably_invalid_pointer(array->items)) {
        copy->len = array->len;
        copy->cap = 0;
        copy->items = NULL;
        return copy;
    }
    copy->items = (KiraBridgeValue *)kira_bridge_calloc(array->len, sizeof(KiraBridgeValue));
    if (copy->items == NULL) { copy->len = 0; copy->cap = 0; return copy; }
    for (size_t i = 0; i < array->len; i++) {
        copy->items[i] = array->items[i];
        if (clone_elem != NULL && array->items[i].tag == KIRA_BRIDGE_VALUE_RAW_PTR) {
            void *element = (void *)array->items[i].payload.raw_ptr;
            if (element != NULL) copy->items[i].payload.raw_ptr = (uintptr_t)clone_elem(element);
        }
        kira_bridge_clone_string_element(&copy->items[i]);
    }
    return copy;
}

KIRA_BRIDGE_EXPORT int64_t kira_array_len(const KiraArray *array) {
    if (!kira_array_is_active(array)) return 0;
    if (kira_bridge_probably_invalid_pointer(array->items)) return 0;
    return (int64_t)array->len;
}

KIRA_BRIDGE_EXPORT void kira_array_store(KiraArray *array, int64_t index, const KiraBridgeValue *value) {
    if (!kira_array_is_active(array)) return;
    kira_array_repair_invalid_storage(array);
    if (array == NULL || index < 0 || (size_t)index >= array->len) return;
    if (value == NULL) return;
    array->items[index] = *value;
}

/*
 * Drop-before-overwrite store. Overwriting an element whose slot owns heap
 * contents (a struct element with its own array/struct fields) must destroy the
 * prior occupant, or it orphans every overwrite (the P2 element-overwrite leak).
 * `release_raw_ptr` is the element destructor (e.g. kira_destroy_Node); a null fn
 * means primitive elements with nothing to drop, degrading to a plain store. The
 * old-vs-new pointer guard makes storing the same element back a no-op rather than
 * a use-after-free. Mirrors the per-element destroy loop in kira_array_release so
 * an element is reclaimed exactly once whether the array is released wholesale or
 * a slot is overwritten. Ownership model, no refcounts — see kira_array_release.
 */
KIRA_BRIDGE_EXPORT void kira_array_store_release(KiraArray *array, int64_t index, const KiraBridgeValue *value, void (*release_raw_ptr)(void *)) {
    /*
     * A rejected store (inactive/null array, out-of-range index) still receives
     * an OWNED element the caller escaped — a boxed struct/enum shell or a
     * cloned string buffer. Dropping it on the floor leaks; release it through
     * the same typed paths a replaced element takes. Native only: the hybrid/VM
     * path owns its values.
     */
    if (!kira_array_is_active(array) || index < 0 || (size_t)index >= array->len) {
        if (kira_array_alloc_fn == NULL && value != NULL) {
            if (value->tag == KIRA_BRIDGE_VALUE_RAW_PTR && release_raw_ptr != NULL &&
                value->payload.raw_ptr != 0) {
                release_raw_ptr((void *)value->payload.raw_ptr);
            }
            if (value->tag == KIRA_BRIDGE_VALUE_STRING && value->payload.string.ptr != NULL) {
                free((void *)value->payload.string.ptr);
            }
        }
        return;
    }
    kira_array_repair_invalid_storage(array);
    if (value == NULL) return;
    /*
     * Defer on the hybrid/VM path exactly as kira_array_release does: the VM owns
     * and reclaims array memory through its own native-layout destructors.
     */
    if (kira_array_alloc_fn == NULL && release_raw_ptr != NULL &&
        array->items[index].tag == KIRA_BRIDGE_VALUE_RAW_PTR) {
        void *old = (void *)array->items[index].payload.raw_ptr;
        void *incoming = value->tag == KIRA_BRIDGE_VALUE_RAW_PTR ? (void *)value->payload.raw_ptr : NULL;
        if (old != NULL && old != incoming) release_raw_ptr(old);
    }
    /*
     * String elements own their byte buffer (the backend clones every string into
     * an element), so overwriting one must free the old buffer regardless of
     * whether a RAW_PTR element destructor was supplied. Same old!=incoming guard
     * as above so a self-store is a no-op.
     */
    if (kira_array_alloc_fn == NULL && array->items[index].tag == KIRA_BRIDGE_VALUE_STRING) {
        unsigned char *old = (unsigned char *)array->items[index].payload.string.ptr;
        const unsigned char *incoming =
            value->tag == KIRA_BRIDGE_VALUE_STRING ? value->payload.string.ptr : NULL;
        if (old != NULL && old != incoming) free(old);
    }
    array->items[index] = *value;
}

/*
 * Drop-before-overwrite for an owned ARRAY FIELD. Reassigning `obj.arr = newArr`
 * orphans the old array (the P2 field-overwrite leak: 16-byte KiraArray headers).
 * The backend emits this with the old and incoming array pointers and the element
 * destructor; it releases the old array unless it is null (moved-out/uninitialised
 * field) or the same pointer being stored back. Delegates to kira_array_release, so
 * it inherits the hybrid/VM deferral. Only sound because aggregate reads deep-clone
 * (value semantics) — the old field value is independently owned and not aliased by
 * the incoming value.
 */
KIRA_BRIDGE_EXPORT void kira_array_release(KiraArray *array, void (*release_raw_ptr)(void *));

KIRA_BRIDGE_EXPORT void kira_array_release_replaced(KiraArray *old_array, KiraArray *incoming, void (*release_raw_ptr)(void *)) {
    if (old_array == NULL || old_array == incoming) return;
    /*
     * Defense-in-depth. A struct array field is an untagged raw KiraArray* (unlike a
     * tagged bridge-value element), so a non-heap value in the field would be freed
     * blindly — this aborted on device (0x4628d3 in a foundation FFI struct). The
     * backend already restricts this call to non-FFI struct types whose array fields
     * are always kira_array_alloc'd, but guard anyway: kira_bridge_alloc returns at
     * least 16-byte-aligned pointers, so reject anything unaligned or in the low
     * sentinel range rather than free a value that was never allocated.
     */
    uintptr_t bits = (uintptr_t)old_array;
    if (bits < 0x1000 || (bits & 0xF) != 0) return;
    kira_array_release(old_array, release_raw_ptr);
}

/*
 * Free an owned closure value. A closure i64 is either a callable-value (a bare
 * function id, high bit clear, within u32 — no heap) or a tagged heap closure block
 * { i64 fn_id; i64 count; KiraBridgeValue[] } with the high bit set. Used to drop an
 * owned closure parameter at the callee's scope exit. Tag-safe and null/sentinel-safe
 * so it also accepts plain heap raw pointers (high bit already clear). Captured heap
 * values are left untouched (ambiguous without per-capture type info — conservative:
 * leak rather than risk freeing a shared/static capture or a double free).
 */
/*
 * The closure value is a Kira i64 register carrying a tagged pointer (the closure
 * tag is bit 63), so the parameter is uint64_t on every target. uintptr_t would be
 * 32-bit on wasm32 — it could not hold the tag bit AND would disagree with the
 * backend's void(i64) declaration (wasm-ld signature mismatch). The 64-bit tag math
 * below therefore stays correct on wasm32; casting the untagged bits to void*
 * truncates to the real 32-bit pointer.
 */
KIRA_BRIDGE_EXPORT void kira_destroy_closure(uint64_t value) {
    if (value == 0) return;
    if (value <= 0xFFFFFFFFULL) return; /* callable-value function id: nothing to free */
    /*
     * Only an actual closure block carries the high tag bit (set in lowerConstClosure).
     * An owned raw_ptr parameter that is NOT a closure — e.g. an FFI/native-state userdata
     * pointer passed as `RawPtr` — has the high bit clear and must NOT be freed: it is
     * owned by the caller (the native-state box), and freeing it corrupts that box (seen as
     * "userdata type mismatch" on a later nativeRecover). The high bit cleanly separates a
     * real closure value from a borrowed raw pointer, so this is safe for both.
     */
    if ((value & 0x8000000000000000ULL) == 0) return;
    void *ptr = (void *)(value & 0x7FFFFFFFFFFFFFFFULL); /* clear the closure tag bit */
    uintptr_t bits = (uintptr_t)ptr;
    if (bits < 0x1000 || (bits & 0x7) != 0) return; /* not a heap-allocated block */
    if (kira_closure_destroy_fn != NULL) {
        kira_closure_destroy_fn(bits);
        return;
    }
    free(ptr);
}

KIRA_BRIDGE_EXPORT void kira_array_append(KiraArray *array, const KiraBridgeValue *value) {
    if (!kira_array_is_active(array)) return;
    kira_array_repair_invalid_storage(array);
    if (array == NULL || value == NULL) return;
    if (array->items != NULL && array->len < array->cap) {
        array->items[array->len] = *value;
        array->len = array->len + 1;
        return;
    }
    size_t next_cap = array->cap < 4 ? 4 : array->cap * 2;
    if (next_cap < array->len + 1) next_cap = array->len + 1;
    KiraBridgeValue *next_items = (KiraBridgeValue *)kira_bridge_alloc(next_cap * sizeof(KiraBridgeValue));
    if (next_items == NULL) return;
    if (array->items != NULL && array->len != 0) {
        memcpy(next_items, array->items, array->len * sizeof(KiraBridgeValue));
    }
    if (array->items != NULL) {
        kira_bridge_free(array->items, (array->cap == 0 ? 1 : array->cap) * sizeof(KiraBridgeValue));
    }
    array->items = next_items;
    array->cap = next_cap;
    array->items[array->len] = *value;
    array->len = array->len + 1;
}

KIRA_BRIDGE_EXPORT void kira_array_load(const KiraArray *array, int64_t index, KiraBridgeValue *out_value) {
    KiraBridgeValue zero = {0};
    if (out_value == NULL) return;
    if (!kira_array_is_active(array) || kira_bridge_probably_invalid_pointer(array->items) || index < 0 || (size_t)index >= array->len) {
        *out_value = zero;
        return;
    }
    *out_value = array->items[index];
}

/* Element DRAIN (checker-verified move out of an OWNED array): hand the
 * element's bridge value to the caller — which now owns it — and tombstone
 * the slot to VOID so kira_array_release skips it and a later read of the
 * drained slot yields a zero value (deterministic dispatch failure) instead
 * of a double free. */
KIRA_BRIDGE_EXPORT void kira_array_take(KiraArray *array, int64_t index, KiraBridgeValue *out_value) {
    KiraBridgeValue zero = {0};
    if (out_value == NULL) return;
    if (!kira_array_is_active(array) || kira_bridge_probably_invalid_pointer(array->items) || index < 0 || (size_t)index >= array->len) {
        *out_value = zero;
        return;
    }
    *out_value = array->items[index];
    array->items[index] = zero;
}

KIRA_BRIDGE_EXPORT void kira_array_release(KiraArray *array, void (*release_raw_ptr)(void *)) {
    if (!kira_array_is_active(array)) {
        kira_trace_log("NATIVE", "ARRAY_RELEASE_SKIP", "array=%p", (void *)array);
        return;
    }

    /*
     * Hybrid path: the VM owns and reclaims array memory via its own
     * native-layout destructors, and VM arrays may not carry a refcount field.
     * Defer, and never touch the refcount.
     */
    if (kira_array_alloc_fn != NULL) {
        kira_trace_log("NATIVE", "ARRAY_RELEASE_DEFERRED", "array=%p len=%llu", (void *)array, (unsigned long long)array->len);
        return;
    }

    kira_array_repair_invalid_storage(array);

    /*
     * Ownership model (no reference counts). The LLVM backend, driven by the borrow
     * checker, emits exactly one release at each owned array's drop point; moves
     * transfer ownership (the source is not dropped) and borrows are never dropped,
     * while owned values produced from borrowed data are deep-cloned (kira_array_clone)
     * so they own independent storage — at struct copies, native-state boxing,
     * borrowed element/field stores, and borrowed-array returns. Checker-verified
     * field move-outs null the source storage so the old owner cannot re-release.
     * A release here is then the sole owner going away: run the element destructor
     * on RAW_PTR elements, then free the items buffer and the struct.
     *
     * This used to be gated behind KIRA_ARRAY_OWNERSHIP_FREE (defer-by-default)
     * while clone/drop coverage was incomplete; the gate is gone and the free path
     * is the only behavior. History: .codex/work/reports/
     * array-registry-leak-and-promotion.md §7b–§7j.
     */
    kira_trace_log("NATIVE", "ARRAY_RELEASE_FREE", "array=%p len=%llu", (void *)array, (unsigned long long)array->len);
    if (array->items != NULL && !kira_bridge_probably_invalid_pointer(array->items)) {
        for (size_t i = 0; i < array->len; i++) {
            if (release_raw_ptr != NULL && array->items[i].tag == KIRA_BRIDGE_VALUE_RAW_PTR) {
                void *element = (void *)array->items[i].payload.raw_ptr;
                if (element != NULL) release_raw_ptr(element);
            }
            /* String elements own their buffer (cloned in by the backend); free it
             * with the array regardless of the RAW_PTR element destructor. */
            if (array->items[i].tag == KIRA_BRIDGE_VALUE_STRING &&
                array->items[i].payload.string.ptr != NULL) {
                free((void *)array->items[i].payload.string.ptr);
            }
        }
    }
    kira_bridge_free(array->items, (array->cap == 0 ? 1 : array->cap) * sizeof(KiraBridgeValue));
    kira_bridge_free(array, sizeof(KiraArray));
}

