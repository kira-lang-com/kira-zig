typedef long long (*kira_i64_callback)(long long value, void* user_data);

long long kira_invoke_callback(kira_i64_callback callback, void* user_data, long long value);
