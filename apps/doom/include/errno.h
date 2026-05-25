#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Global errno variable, defined in innigkeit_libc.c */
extern int errno_val;
#define errno errno_val

/* POSIX error codes (subset used by DOOM and its libc) */
#define EPERM    1   /* Operation not permitted */
#define ENOENT   2   /* No such file or directory */
#define ESRCH    3   /* No such process */
#define EINTR    4   /* Interrupted system call */
#define EIO      5   /* I/O error */
#define ENXIO    6   /* No such device or address */
#define EBADF    9   /* Bad file number */
#define ECHILD  10   /* No child processes */
#define EAGAIN  11   /* Try again */
#define ENOMEM  12   /* Out of memory */
#define EACCES  13   /* Permission denied */
#define EFAULT  14   /* Bad address */
#define EBUSY   16   /* Device or resource busy */
#define EEXIST  17   /* File exists */
#define ENODEV  19   /* No such device */
#define ENOTDIR 20   /* Not a directory */
#define EISDIR  21   /* Is a directory */
#define EINVAL  22   /* Invalid argument */
#define ENFILE  23   /* File table overflow */
#define EMFILE  24   /* Too many open files */
#define ENOSPC  28   /* No space left on device */
#define EROFS   30   /* Read-only file system */
#define EPIPE   32   /* Broken pipe */
#define ERANGE  34   /* Math result not representable */
#define ENOSYS  38   /* Function not implemented */

#ifdef __cplusplus
}
#endif
