#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

int  strcasecmp(const char *a, const char *b);
int  strncasecmp(const char *a, const char *b, size_t n);
void bzero(void *s, size_t n);
void bcopy(const void *src, void *dst, size_t n);
int  bcmp(const void *s1, const void *s2, size_t n);

#ifdef __cplusplus
}
#endif
