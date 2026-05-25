#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <sys/types.h>

struct timeval {
    long tv_sec;   /* seconds */
    long tv_usec;  /* microseconds */
};

struct timezone {
    int tz_minuteswest; /* minutes west of Greenwich */
    int tz_dsttime;     /* type of DST correction */
};

/* Backed by innigkeit_uptime_ms() in innigkeit_libc.c */
int gettimeofday(struct timeval *tv, struct timezone *tz);

#ifdef __cplusplus
}
#endif
