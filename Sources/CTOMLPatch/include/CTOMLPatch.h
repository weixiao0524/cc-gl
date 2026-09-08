#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    char *provider;
    char *base_url;
    char *error;
    size_t start;
    size_t end;
} CGLInspection;
CGLInspection cgl_inspect(const char *text, size_t length);
CGLInspection cgl_permission(const char *text, size_t length, const char *key);
void cgl_free(CGLInspection result);
#ifdef __cplusplus
}
#endif
