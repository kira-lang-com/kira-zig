#ifndef KIRA_MAIN_H
#define KIRA_MAIN_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KiraRuntime KiraRuntime;
typedef struct KiraDeveloper KiraDeveloper;

typedef enum KiraStatus {
    KIRA_STATUS_OK = 0,
    KIRA_STATUS_FAIL = 1
} KiraStatus;

typedef enum KiraDeveloperBackend {
    KIRA_DEVELOPER_BACKEND_DEFAULT = 0,
    KIRA_DEVELOPER_BACKEND_VM = 1,
    KIRA_DEVELOPER_BACKEND_LLVM = 2,
    KIRA_DEVELOPER_BACKEND_HYBRID = 3,
    KIRA_DEVELOPER_BACKEND_WASM32_EMSCRIPTEN = 4
} KiraDeveloperBackend;

KiraRuntime *kira_runtime_create(void);
void kira_runtime_destroy(KiraRuntime *runtime);
KiraStatus kira_runtime_load_bytecode_module(KiraRuntime *runtime, const char *path);
KiraStatus kira_runtime_run_main(KiraRuntime *runtime);
const char *kira_runtime_last_error(KiraRuntime *runtime);
KiraStatus kira_runtime_load_hybrid_module(KiraRuntime *runtime, const char *descriptor_path);
KiraStatus kira_runtime_attach_native_library(KiraRuntime *runtime, const char *manifest_path);

KiraDeveloper *kira_developer_create(void);
void kira_developer_destroy(KiraDeveloper *developer);
KiraStatus kira_developer_check(KiraDeveloper *developer, const char *path, KiraDeveloperBackend backend);
KiraStatus kira_developer_build(KiraDeveloper *developer, const char *path, KiraDeveloperBackend backend);
KiraStatus kira_developer_test(KiraDeveloper *developer, const char *path, KiraDeveloperBackend backend);
const char *kira_developer_report(KiraDeveloper *developer);
const char *kira_developer_last_error(KiraDeveloper *developer);

#ifdef __cplusplus
}
#endif

#endif
