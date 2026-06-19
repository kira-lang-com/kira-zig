#ifndef KIRA_FOUNDATION_ARGUMENT_PARSER_H
#define KIRA_FOUNDATION_ARGUMENT_PARSER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum kap_token_kind {
    KAP_TOKEN_POSITIONAL = 0,
    KAP_TOKEN_LONG_OPTION = 1,
    KAP_TOKEN_SHORT_OPTION = 2,
    KAP_TOKEN_COMMAND_TERMINATOR = 3,
    KAP_TOKEN_EMPTY = 4
} kap_token_kind;

kap_token_kind kap_classify_token(const char* token);
bool kap_is_help_token(const char* token);
bool kap_has_inline_value(const char* token);
const char* kap_option_name(const char* token);
const char* kap_inline_value(const char* token);
void kap_free_string(const char* value);

#ifdef __cplusplus
}
#endif

#endif
