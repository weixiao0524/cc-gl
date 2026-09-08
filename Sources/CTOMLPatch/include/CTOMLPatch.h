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
CGLInspection cgl_mcp(const char *text, size_t length, size_t index);
CGLInspection cgl_mcp_edit(const char *text, size_t length, const char *name, int enabled);
void cgl_free(CGLInspection result);
#ifdef __cplusplus
}
#endif
