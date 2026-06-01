/**
 * ejs_util.h — core 内部通用小工具
 *
 * 仅供 core/src 内部实现使用，不作为 public ABI 暴露。
 */

#ifndef EJS_UTIL_H
#define EJS_UTIL_H

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static inline char * ejs_strdup_or_null(const char *value) {
    if (value == NULL) {
        return NULL;
    }

    size_t len = strlen(value);
    char *copy = (char *)malloc(len + 1u);

    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, value, len + 1u);
    return copy;
}

#endif /* EJS_UTIL_H */
