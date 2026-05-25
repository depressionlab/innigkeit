#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* open() flags */
#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_RDWR   0x0002
#define O_CREAT  0x0040
#define O_TRUNC  0x0200

int open(const char *path, int flags, ...);
int close(int fd);

#ifdef __cplusplus
}
#endif
