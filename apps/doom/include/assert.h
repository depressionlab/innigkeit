#pragma once

#ifdef __cplusplus
extern "C" {
#endif

extern void __assert_fail(const char *expr, const char *file, unsigned line, const char *fn)
    __attribute__((noreturn));

#ifndef NDEBUG
#define assert(expr) \
    ((void)((expr) ? 0 : (__assert_fail(#expr, __FILE__, __LINE__, __func__), 0)))
#else
#define assert(expr) ((void)(expr))
#endif

#ifdef __cplusplus
}
#endif
