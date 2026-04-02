#ifndef KIRA_MAIN_H
#define KIRA_MAIN_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KiraRuntime KiraRuntime;

typedef enum KiraStatus {
    KIRA_STATUS_OK = 0,
    KIRA_STATUS_FAIL = 1
} KiraStatus;

KiraRuntime *kira_runtime_create(void);
void kira_runtime_destroy(KiraRuntime *runtime);
KiraStatus kira_runtime_load_bytecode_module(KiraRuntime *runtime, const char *path);
KiraStatus kira_runtime_run_main(KiraRuntime *runtime);
const char *kira_runtime_last_error(KiraRuntime *runtime);
KiraStatus kira_runtime_load_hybrid_module(KiraRuntime *runtime, const char *descriptor_path);
KiraStatus kira_runtime_attach_native_library(KiraRuntime *runtime, const char *manifest_path);

#ifdef __cplusplus
}
#endif

#endif
