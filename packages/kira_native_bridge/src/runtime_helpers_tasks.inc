/* ---- async tasks (deferred execution) ------------------------------------
 *
 * Native mirror of the VM's task objects (kira_vm_runtime/src/vm_tasks.zig)
 * and the shared executor semantics (kira_runtime_abi): `kira_task_spawn`
 * captures a thunk + its packed scalar args WITHOUT running them; the deferred
 * call runs at first drive — `kira_task_await` joins it (aborting on a
 * cancelled task or a duplicate join, the native trap mirroring the VM's
 * RuntimeFailure), `kira_task_detach` drives and discards. A cancel observed
 * before the first drive prevents the work from ever running.
 *
 * Tasks stay allocated until process exit so a duplicate join is a clean trap
 * instead of a use-after-free — the same lifecycle the VM uses (frees at VM
 * deinit). The scalar-only restriction (KSEM159) means task slots never own
 * heap payloads. Every spawn also lands in `kira_task_registry`, and an
 * atexit teardown frees the survivors (task structs, unrun ctx/frame
 * payloads, the registry, and the ready-queue array) — the native binary's
 * equivalent of the VM's deinitTasks, and what keeps `leaks --atExit` clean.
 */

#define KIRA_TASK_PENDING 0
#define KIRA_TASK_COMPLETE 1
#define KIRA_TASK_CONSUMED 2

typedef struct KiraTask {
    void (*work)(void *ctx, KiraBridgeValue *out); /* NULL for ready/suspendable tasks */
    /* State-machine body (async transform): takes the frame, returns
     * 0 = complete / 1 = suspended. NULL for run-to-completion tasks. */
    int64_t (*body)(KiraBridgeValue *frame);
    void *ctx;                                     /* owned; freed after the run */
    KiraBridgeValue *frame;                        /* suspendable frame; owned */
    KiraBridgeValue ready_value;
    KiraBridgeValue result; /* valid once state == COMPLETE */
    uint8_t state;
    uint8_t cancel_requested;
    uint8_t detached;
    /* Monotonic wake deadline (ns) set by `taskSleep`: the executor skips the
     * task until the deadline passes. 0 = runnable immediately. */
    uint64_t wake_at_ns;
} KiraTask;

/* The suspendable task currently being driven; `kira_task_sleep` sets its
 * wake deadline instead of blocking the thread. */
static KiraTask *kira_task_current = NULL;

static uint64_t kira_task_now_ns(void) {
#if defined(_WIN32)
    return (uint64_t)GetTickCount64() * 1000000ull;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static void kira_task_sleep_ns(uint64_t ns) {
#if defined(_WIN32)
    uint64_t milliseconds = (ns + 999999ull) / 1000000ull;
    if (milliseconds > (uint64_t)MAXDWORD) milliseconds = (uint64_t)MAXDWORD;
    Sleep((DWORD)milliseconds);
#else
    struct timespec ts;
    ts.tv_sec = (time_t)(ns / 1000000000ull);
    ts.tv_nsec = (long)(ns % 1000000000ull);
    nanosleep(&ts, NULL);
#endif
}

/* Cooperative executor ready-queue (FIFO): spawn enqueues, await pops-and-runs
 * until its target completes, and `kira_task_drain_all` (emitted after the
 * program entrypoint) runs the remainder — detached tasks outliving their
 * handles. Mirrors the VM executor in kira_vm_runtime/src/vm_interpreter_tasks.zig. */
static KiraTask **kira_task_queue = NULL;
static size_t kira_task_queue_len = 0;
static size_t kira_task_queue_cap = 0;
static size_t kira_task_queue_head = 0;

/* Registry of every task ever spawned. Popped tasks leave the ready-queue but
 * must stay allocated (handles may still be awaited/detached — a duplicate
 * join must trap, not use-after-free), so the registry is the single owner:
 * its atexit teardown frees all task structs, any ctx/frame a cancelled task
 * never ran (run_one frees those on the normal paths), the registry itself,
 * and the ready-queue array. The executor is single-threaded/cooperative, so
 * no lock. */
static KiraTask **kira_task_registry = NULL;
static size_t kira_task_registry_len = 0;
static size_t kira_task_registry_cap = 0;

static void kira_task_registry_teardown(void) {
    for (size_t index = 0; index < kira_task_registry_len; index++) {
        KiraTask *task = kira_task_registry[index];
        free(task->ctx);
        free(task->frame);
        free(task);
    }
    free(kira_task_registry);
    kira_task_registry = NULL;
    kira_task_registry_len = 0;
    kira_task_registry_cap = 0;
    free(kira_task_queue);
    kira_task_queue = NULL;
    kira_task_queue_len = 0;
    kira_task_queue_cap = 0;
    kira_task_queue_head = 0;
}

static void kira_task_registry_add(KiraTask *task) {
    static int teardown_registered = 0;
    if (!teardown_registered) {
        teardown_registered = 1;
        atexit(kira_task_registry_teardown);
    }
    if (kira_task_registry_len == kira_task_registry_cap) {
        size_t next_cap = kira_task_registry_cap == 0 ? 16 : kira_task_registry_cap * 2;
        KiraTask **grown = (KiraTask **)realloc(kira_task_registry, next_cap * sizeof(KiraTask *));
        if (grown == NULL) return; /* untracked: survives to exit unreclaimed, never unsafe */
        kira_task_registry = grown;
        kira_task_registry_cap = next_cap;
    }
    kira_task_registry[kira_task_registry_len++] = task;
}

static void kira_task_enqueue(KiraTask *task) {
    if (kira_task_queue_len == kira_task_queue_cap) {
        size_t next_cap = kira_task_queue_cap == 0 ? 16 : kira_task_queue_cap * 2;
        KiraTask **grown = (KiraTask **)realloc(kira_task_queue, next_cap * sizeof(KiraTask *));
        if (grown == NULL) {
            fprintf(stderr, "kira task spawn failed: out of memory\n");
            abort();
        }
        kira_task_queue = grown;
        kira_task_queue_cap = next_cap;
    }
    kira_task_queue[kira_task_queue_len++] = task;
}

/* Pop the next DUE pending task (FIFO among due tasks); parked tasks whose
 * wake deadline has not passed stay queued. NULL when nothing is due. */
static KiraTask *kira_task_pop_next(void) {
    uint64_t now = kira_task_now_ns();
    size_t index = kira_task_queue_head;
    while (index < kira_task_queue_len) {
        KiraTask *task = kira_task_queue[index];
        if (task->state != KIRA_TASK_PENDING) {
            if (index == kira_task_queue_head) kira_task_queue_head++;
            index++;
            continue;
        }
        if (task->wake_at_ns <= now) {
            memmove(&kira_task_queue[index], &kira_task_queue[index + 1], (kira_task_queue_len - index - 1) * sizeof(KiraTask *));
            kira_task_queue_len--;
            return task;
        }
        index++;
    }
    return NULL;
}

/* Like pop_next, but when every pending task is parked on a wake deadline,
 * sleep until the earliest deadline and retry. NULL only when no pending
 * tasks remain at all. */
static KiraTask *kira_task_pop_next_or_wait(void) {
    for (;;) {
        KiraTask *task = kira_task_pop_next();
        if (task != NULL) return task;
        uint64_t earliest = 0;
        int found = 0;
        for (size_t index = kira_task_queue_head; index < kira_task_queue_len; index++) {
            KiraTask *pending = kira_task_queue[index];
            if (pending->state != KIRA_TASK_PENDING) continue;
            if (!found || pending->wake_at_ns < earliest) {
                earliest = pending->wake_at_ns;
                found = 1;
            }
        }
        if (!found) return NULL;
        uint64_t now = kira_task_now_ns();
        if (earliest > now) kira_task_sleep_ns(earliest - now);
    }
}

/* Run one popped task. A cancel observed before the run wins: the call never
 * executes (for a suspendable body, a cancel observed at a suspend point
 * abandons the remainder — flag-check cancellation). A suspended drive
 * re-enqueues the task (round-robin); a detached task's result is discarded. */
static void kira_task_run_one(KiraTask *task) {
    if (task->cancel_requested) {
        task->state = KIRA_TASK_CONSUMED;
        free(task->ctx);
        task->ctx = NULL;
        free(task->frame);
        task->frame = NULL;
        return;
    }
    if (task->body != NULL) {
        /* This drive consumes any prior wake deadline; `kira_task_sleep`
         * inside the body sets a fresh one before suspending. */
        task->wake_at_ns = 0;
        KiraTask *previous_current = kira_task_current;
        kira_task_current = task;
        int64_t status = task->body(task->frame);
        kira_task_current = previous_current;
        if (status == 1) {
            /* Suspended at a yield point: back of the queue (round-robin). */
            kira_task_enqueue(task);
            return;
        }
        if (task->detached) {
            task->state = KIRA_TASK_CONSUMED;
        } else {
            task->result = task->frame[1];
            if (task->result.tag == KIRA_BRIDGE_VALUE_VOID) {
                task->result.tag = KIRA_BRIDGE_VALUE_INTEGER;
                task->result.payload.integer = 0;
            }
            task->state = KIRA_TASK_COMPLETE;
        }
        free(task->frame);
        task->frame = NULL;
        return;
    }
    KiraBridgeValue out;
    memset(&out, 0, sizeof(out));
    if (task->work != NULL) {
        task->work(task->ctx, &out);
    } else {
        out = task->ready_value;
    }
    free(task->ctx);
    task->ctx = NULL;
    if (task->detached) {
        task->state = KIRA_TASK_CONSUMED;
    } else {
        task->result = out;
        task->state = KIRA_TASK_COMPLETE;
    }
}

KIRA_BRIDGE_EXPORT KiraBridgeValue *kira_task_alloc_args(uint32_t argc) {
    if (argc == 0) {
        return (KiraBridgeValue *)calloc(1, sizeof(KiraBridgeValue));
    }
    return (KiraBridgeValue *)calloc(argc, sizeof(KiraBridgeValue));
}

KIRA_BRIDGE_EXPORT KiraTask *kira_task_spawn(void (*work)(void *, KiraBridgeValue *), void *ctx) {
    KiraTask *task = (KiraTask *)calloc(1, sizeof(KiraTask));
    if (task == NULL) {
        fprintf(stderr, "kira task spawn failed: out of memory\n");
        abort();
    }
    task->work = work;
    task->ctx = ctx;
    kira_task_registry_add(task);
    kira_task_enqueue(task);
    kira_trace_log("TASK", "SPAWN", "task=%p", (void *)task);
    return task;
}

/* Spawn a state-machine body: `frame` (calloc'd by kira_task_alloc_args) holds
 * resume state in slot 0, the eventual result in slot 1, and the seeded args
 * in slots 2..; the executor drives `body(frame)` by status until complete. */
KIRA_BRIDGE_EXPORT KiraTask *kira_task_spawn_suspendable(int64_t (*body)(KiraBridgeValue *), KiraBridgeValue *frame) {
    KiraTask *task = (KiraTask *)calloc(1, sizeof(KiraTask));
    if (task == NULL) {
        fprintf(stderr, "kira task spawn failed: out of memory\n");
        abort();
    }
    task->body = body;
    task->frame = frame;
    kira_task_registry_add(task);
    kira_task_enqueue(task);
    kira_trace_log("TASK", "SPAWN_SUSPENDABLE", "task=%p", (void *)task);
    return task;
}

KIRA_BRIDGE_EXPORT KiraTask *kira_task_spawn_ready(const KiraBridgeValue *value) {
    KiraTask *task = (KiraTask *)calloc(1, sizeof(KiraTask));
    if (task == NULL) {
        fprintf(stderr, "kira task spawn failed: out of memory\n");
        abort();
    }
    task->ready_value = *value;
    kira_task_registry_add(task);
    kira_task_enqueue(task);
    kira_trace_log("TASK", "SPAWN_READY", "task=%p", (void *)task);
    return task;
}

KIRA_BRIDGE_EXPORT void kira_task_await(KiraTask *task, KiraBridgeValue *out) {
    memset(out, 0, sizeof(*out));
    if (task == NULL) {
        fprintf(stderr, "kira runtime failure: expected a task handle\n");
        abort();
    }
    if (task->state == KIRA_TASK_CONSUMED || task->detached) {
        if (task->cancel_requested && !task->detached) {
            fprintf(stderr, "kira runtime failure: awaited a cancelled task\n");
        } else {
            fprintf(stderr, "kira runtime failure: task was already joined or detached\n");
        }
        abort();
    }
    if (task->cancel_requested) {
        /* The deferred work never runs on a cancelled task; joining it is a
         * trap (there is no value to yield). */
        task->state = KIRA_TASK_CONSUMED;
        fprintf(stderr, "kira runtime failure: awaited a cancelled task\n");
        abort();
    }
    while (task->state == KIRA_TASK_PENDING) {
        KiraTask *next = kira_task_pop_next_or_wait();
        if (next == NULL) {
            fprintf(stderr, "kira runtime failure: task executor queue drained before the awaited task completed\n");
            abort();
        }
        kira_task_run_one(next);
    }
    *out = task->result;
    memset(&task->result, 0, sizeof(task->result));
    task->state = KIRA_TASK_CONSUMED;
    kira_trace_log("TASK", "AWAIT", "task=%p tag=%u", (void *)task, (unsigned)out->tag);
}

KIRA_BRIDGE_EXPORT void kira_task_cancel(KiraTask *task) {
    if (task == NULL || task->state != KIRA_TASK_PENDING) return;
    task->cancel_requested = 1;
}

/* Stop waiting: the work still runs when the executor reaches the task (unless
 * cancelled first); the result is discarded. */
KIRA_BRIDGE_EXPORT void kira_task_detach(KiraTask *task) {
    if (task == NULL) return;
    switch (task->state) {
        case KIRA_TASK_PENDING:
            task->detached = 1;
            break;
        case KIRA_TASK_COMPLETE:
            memset(&task->result, 0, sizeof(task->result));
            task->state = KIRA_TASK_CONSUMED;
            break;
        default:
            break;
    }
    kira_trace_log("TASK", "DETACH", "task=%p", (void *)task);
}

/* `taskSleep(ms)`: park the current suspendable task with a wake deadline
 * (the transform's following SUSPENDED return hands control back), or block
 * the thread outside one. */
KIRA_BRIDGE_EXPORT void kira_task_sleep(int64_t milliseconds) {
    uint64_t ms = milliseconds > 0 ? (uint64_t)milliseconds : 0;
    if (kira_task_current != NULL) {
        kira_task_current->wake_at_ns = kira_task_now_ns() + ms * 1000000ull;
        return;
    }
    if (ms > 0) kira_task_sleep_ns(ms * 1000000ull);
}

/* True when the task is no longer pending (complete, consumed, or
 * cancel-requested): joining it will not need to drive the executor. */
KIRA_BRIDGE_EXPORT int64_t kira_task_is_complete(const KiraTask *task) {
    if (task == NULL) return 1;
    return (task->state != KIRA_TASK_PENDING || task->cancel_requested) ? 1 : 0;
}

/* `taskYield()`: run the next queued task (if any) to completion before the
 * yielding body continues. A no-op when the queue is drained. */
KIRA_BRIDGE_EXPORT void kira_task_yield(void) {
    KiraTask *task = kira_task_pop_next();
    if (task == NULL) return;
    kira_task_run_one(task);
    if (task->state == KIRA_TASK_COMPLETE && task->detached) {
        memset(&task->result, 0, sizeof(task->result));
        task->state = KIRA_TASK_CONSUMED;
    }
}

/* End-of-run drain, emitted by the backend after the program entrypoint
 * returns: run every remaining non-cancelled task (detached tasks outliving
 * their handles). */
KIRA_BRIDGE_EXPORT void kira_task_drain_all(void) {
    KiraTask *task = NULL;
    while ((task = kira_task_pop_next_or_wait()) != NULL) {
        kira_task_run_one(task);
        if (task->state == KIRA_TASK_COMPLETE) {
            memset(&task->result, 0, sizeof(task->result));
            task->state = KIRA_TASK_CONSUMED;
        }
    }
}
