#include "argument_parser.h"

#include <stdlib.h>
#include <string.h>

static char* kap_copy_range(const char* start, size_t length) {
    char* result = (char*)malloc(length + 1);
    if (result == NULL) {
        return NULL;
    }
    memcpy(result, start, length);
    result[length] = '\0';
    return result;
}

kap_token_kind kap_classify_token(const char* token) {
    if (token == NULL || token[0] == '\0') {
        return KAP_TOKEN_EMPTY;
    }
    if (strcmp(token, "--") == 0) {
        return KAP_TOKEN_COMMAND_TERMINATOR;
    }
    if (token[0] == '-' && token[1] == '-' && token[2] != '\0') {
        return KAP_TOKEN_LONG_OPTION;
    }
    if (token[0] == '-' && token[1] != '\0') {
        return KAP_TOKEN_SHORT_OPTION;
    }
    return KAP_TOKEN_POSITIONAL;
}

bool kap_is_help_token(const char* token) {
    if (token == NULL) {
        return false;
    }
    return strcmp(token, "--help") == 0 || strcmp(token, "-h") == 0 || strcmp(token, "help") == 0;
}

bool kap_has_inline_value(const char* token) {
    if (token == NULL) {
        return false;
    }
    return strchr(token, '=') != NULL;
}

const char* kap_option_name(const char* token) {
    if (token == NULL) {
        return kap_copy_range("", 0);
    }

    const char* start = token;
    if (token[0] == '-' && token[1] == '-') {
        start = token + 2;
    } else if (token[0] == '-') {
        start = token + 1;
    }

    const char* equals = strchr(start, '=');
    size_t length = equals == NULL ? strlen(start) : (size_t)(equals - start);
    return kap_copy_range(start, length);
}

const char* kap_inline_value(const char* token) {
    if (token == NULL) {
        return kap_copy_range("", 0);
    }
    const char* equals = strchr(token, '=');
    if (equals == NULL) {
        return kap_copy_range("", 0);
    }
    return kap_copy_range(equals + 1, strlen(equals + 1));
}

void kap_free_string(const char* value) {
    if (value != NULL) {
        free((void*)value);
    }
}
