#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

/* Standard file-descriptor numbers */
#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

/* access() mode bits */
#define F_OK 0   /* existence */
#define X_OK 1   /* execute   */
#define W_OK 2   /* write     */
#define R_OK 4   /* read      */

int access(const char *path, int mode);
int unlink(const char *path);
char *getcwd(char *buf, size_t size);
int chdir(const char *path);

/* Busy-wait stub using uptime_ms */
int usleep(unsigned long usec);

#ifdef __cplusplus
}
#endif
