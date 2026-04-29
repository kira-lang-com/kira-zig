#include "fs.h"

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

typedef struct fs_file_handle {
#ifdef _WIN32
    HANDLE handle;
#else
    int fd;
#endif
} fs_file_handle;

typedef struct fs_directory_listing {
    char** entries;
    int count;
} fs_directory_listing;

static char* fs_strdup_local(const char* text) {
    if (text == NULL) {
        return NULL;
    }
    size_t length = strlen(text);
    char* copy = (char*)malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, text, length + 1);
    return copy;
}

static fs_read_result fs_empty_result(void) {
    fs_read_result result;
    result.ok = false;
    result.data = "";
    result.size = 0;
    return result;
}

static fs_read_result fs_buffer_result(char* data, uint64_t size) {
    fs_read_result result;
    result.ok = data != NULL;
    result.data = data == NULL ? "" : data;
    result.size = data == NULL ? 0 : size;
    return result;
}

void* fs_open_read(const char* path) {
    if (path == NULL) {
        return NULL;
    }

    fs_file_handle* file = (fs_file_handle*)malloc(sizeof(fs_file_handle));
    if (file == NULL) {
        return NULL;
    }

#ifdef _WIN32
    file->handle = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file->handle == INVALID_HANDLE_VALUE) {
        free(file);
        return NULL;
    }
#else
    file->fd = open(path, O_RDONLY);
    if (file->fd < 0) {
        free(file);
        return NULL;
    }
#endif

    return file;
}

bool fs_is_open(void* handle) {
    return handle != NULL;
}

fs_read_result fs_read_all_from_handle(void* handle) {
    if (handle == NULL) {
        return fs_empty_result();
    }

    fs_file_handle* file = (fs_file_handle*)handle;

#ifdef _WIN32
    LARGE_INTEGER size_value;
    if (!GetFileSizeEx(file->handle, &size_value) || size_value.QuadPart < 0) {
        return fs_empty_result();
    }
    uint64_t size = (uint64_t)size_value.QuadPart;
    char* buffer = (char*)malloc((size_t)size + 1);
    if (buffer == NULL) {
        return fs_empty_result();
    }
    DWORD total_read = 0;
    while (total_read < size) {
        DWORD chunk_read = 0;
        DWORD remaining = (DWORD)(size - total_read);
        if (!ReadFile(file->handle, buffer + total_read, remaining, &chunk_read, NULL)) {
            free(buffer);
            return fs_empty_result();
        }
        if (chunk_read == 0) {
            break;
        }
        total_read += chunk_read;
    }
    buffer[total_read] = '\0';
    return fs_buffer_result(buffer, total_read);
#else
    struct stat info;
    if (fstat(file->fd, &info) != 0 || info.st_size < 0) {
        return fs_empty_result();
    }
    uint64_t size = (uint64_t)info.st_size;
    char* buffer = (char*)malloc((size_t)size + 1);
    if (buffer == NULL) {
        return fs_empty_result();
    }
    uint64_t total_read = 0;
    while (total_read < size) {
        ssize_t chunk_read = read(file->fd, buffer + total_read, (size_t)(size - total_read));
        if (chunk_read < 0) {
            free(buffer);
            return fs_empty_result();
        }
        if (chunk_read == 0) {
            break;
        }
        total_read += (uint64_t)chunk_read;
    }
    buffer[total_read] = '\0';
    return fs_buffer_result(buffer, total_read);
#endif
}

void fs_close(void* handle) {
    if (handle == NULL) {
        return;
    }

    fs_file_handle* file = (fs_file_handle*)handle;
#ifdef _WIN32
    if (file->handle != INVALID_HANDLE_VALUE) {
        CloseHandle(file->handle);
    }
#else
    if (file->fd >= 0) {
        close(file->fd);
    }
#endif
    free(file);
}

fs_read_result fs_read_file(const char* path) {
    void* file = fs_open_read(path);
    if (file == NULL) {
        return fs_empty_result();
    }
    fs_read_result result = fs_read_all_from_handle(file);
    fs_close(file);
    return result;
}

bool fs_write_file(const char* path, const char* data) {
    if (path == NULL || data == NULL) {
        return false;
    }

    size_t size = strlen(data);
#ifdef _WIN32
    HANDLE file = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    BOOL ok = WriteFile(file, data, (DWORD)size, &written, NULL);
    CloseHandle(file);
    return ok && written == size;
#else
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        return false;
    }
    size_t total_written = 0;
    while (total_written < size) {
        ssize_t written = write(fd, data + total_written, size - total_written);
        if (written < 0) {
            close(fd);
            return false;
        }
        total_written += (size_t)written;
    }
    close(fd);
    return true;
#endif
}

bool fs_file_exists(const char* path) {
    if (path == NULL) {
        return false;
    }
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path);
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
#else
    struct stat info;
    return stat(path, &info) == 0 && S_ISREG(info.st_mode);
#endif
}

uint64_t fs_file_size(const char* path) {
    if (path == NULL) {
        return 0;
    }
#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetFileAttributesExA(path, GetFileExInfoStandard, &data)) {
        return 0;
    }
    ULARGE_INTEGER size;
    size.HighPart = data.nFileSizeHigh;
    size.LowPart = data.nFileSizeLow;
    return (uint64_t)size.QuadPart;
#else
    struct stat info;
    if (stat(path, &info) != 0 || info.st_size < 0) {
        return 0;
    }
    return (uint64_t)info.st_size;
#endif
}

void fs_free_buffer(const char* buffer) {
    if (buffer != NULL && buffer[0] != '\0') {
        free((void*)buffer);
    }
}

static bool fs_listing_add(fs_directory_listing* listing, const char* name) {
    char** next = (char**)realloc(listing->entries, sizeof(char*) * (size_t)(listing->count + 1));
    if (next == NULL) {
        return false;
    }
    listing->entries = next;
    listing->entries[listing->count] = fs_strdup_local(name);
    if (listing->entries[listing->count] == NULL) {
        return false;
    }
    listing->count += 1;
    return true;
}

void* fs_list_directory(const char* path) {
    if (path == NULL) {
        return NULL;
    }

    fs_directory_listing* listing = (fs_directory_listing*)calloc(1, sizeof(fs_directory_listing));
    if (listing == NULL) {
        return NULL;
    }

#ifdef _WIN32
    size_t path_len = strlen(path);
    char* pattern = (char*)malloc(path_len + 3);
    if (pattern == NULL) {
        free(listing);
        return NULL;
    }
    memcpy(pattern, path, path_len);
    pattern[path_len] = '\\';
    pattern[path_len + 1] = '*';
    pattern[path_len + 2] = '\0';

    WIN32_FIND_DATAA data;
    HANDLE find = FindFirstFileA(pattern, &data);
    free(pattern);
    if (find == INVALID_HANDLE_VALUE) {
        free(listing);
        return NULL;
    }
    do {
        if (strcmp(data.cFileName, ".") != 0 && strcmp(data.cFileName, "..") != 0) {
            fs_listing_add(listing, data.cFileName);
        }
    } while (FindNextFileA(find, &data));
    FindClose(find);
#else
    DIR* dir = opendir(path);
    if (dir == NULL) {
        free(listing);
        return NULL;
    }
    struct dirent* entry = NULL;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            fs_listing_add(listing, entry->d_name);
        }
    }
    closedir(dir);
#endif

    return listing;
}

int fs_directory_count(void* listing_handle) {
    if (listing_handle == NULL) {
        return 0;
    }
    fs_directory_listing* listing = (fs_directory_listing*)listing_handle;
    return listing->count;
}

const char* fs_directory_entry(void* listing_handle, int index) {
    if (listing_handle == NULL) {
        return "";
    }
    fs_directory_listing* listing = (fs_directory_listing*)listing_handle;
    if (index < 0 || index >= listing->count) {
        return "";
    }
    return listing->entries[index];
}

void fs_free_directory_listing(void* listing_handle) {
    if (listing_handle == NULL) {
        return;
    }
    fs_directory_listing* listing = (fs_directory_listing*)listing_handle;
    for (int i = 0; i < listing->count; i += 1) {
        free(listing->entries[i]);
    }
    free(listing->entries);
    free(listing);
}
