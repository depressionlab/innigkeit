#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

typedef long time_t;
typedef long clock_t;

#define CLOCKS_PER_SEC 1000

/* Broken-down calendar time (not populated by our stubs) */
struct tm {
    int tm_sec;    /* seconds [0,60] */
    int tm_min;    /* minutes [0,59] */
    int tm_hour;   /* hours   [0,23] */
    int tm_mday;   /* day of month [1,31] */
    int tm_mon;    /* months since January [0,11] */
    int tm_year;   /* years since 1900 */
    int tm_wday;   /* days since Sunday [0,6] */
    int tm_yday;   /* days since January 1 [0,365] */
    int tm_isdst;  /* Daylight Saving Time flag */
};

/* time() returns seconds since the epoch (boot epoch in our case) */
time_t  time(time_t *tloc);

/* clock() returns milliseconds elapsed (CLOCKS_PER_SEC == 1000) */
clock_t clock(void);

#ifdef __cplusplus
}
#endif
