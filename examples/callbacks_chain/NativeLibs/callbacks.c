#include "callbacks.h"

long long kira_invoke_callback(kira_i64_callback callback, void* user_data, long long value) {
    return callback(value, user_data);
}
