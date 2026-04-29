#ifndef KIRA_FOUNDATION_FS_H
#define KIRA_FOUNDATION_FS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fs_read_result {
    bool ok;
    const char* data;
    uint64_t size;
} fs_read_result;

void* fs_open_read(const char* path);
bool fs_is_open(void* handle);
fs_read_result fs_read_all_from_handle(void* handle);
void fs_close(void* handle);

fs_read_result fs_read_file(const char* path);
bool fs_write_file(const char* path, const char* data);
bool fs_file_exists(const char* path);
uint64_t fs_file_size(const char* path);
void fs_free_buffer(const char* buffer);

void* fs_list_directory(const char* path);
int fs_directory_count(void* listing);
const char* fs_directory_entry(void* listing, int index);
void fs_free_directory_listing(void* listing);

#ifdef __cplusplus
}
#endif

#endif
