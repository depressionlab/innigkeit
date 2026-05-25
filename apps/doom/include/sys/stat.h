#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <sys/types.h>

/* File type bits */
#define S_IFMT   0170000   /* mask for file type */
#define S_IFREG  0100000   /* regular file */
#define S_IFDIR  0040000   /* directory */
#define S_IFCHR  0020000   /* character device */
#define S_IFBLK  0060000   /* block device */
#define S_IFIFO  0010000   /* FIFO */
#define S_IFLNK  0120000   /* symbolic link */

/* Permission bits */
#define S_IRWXU  0000700   /* owner rwx */
#define S_IRUSR  0000400
#define S_IWUSR  0000200
#define S_IXUSR  0000100
#define S_IRWXG  0000070   /* group rwx */
#define S_IRGRP  0000040
#define S_IWGRP  0000020
#define S_IXGRP  0000010
#define S_IRWXO  0000007   /* others rwx */
#define S_IROTH  0000004
#define S_IWOTH  0000002
#define S_IXOTH  0000001

/* Type-test macros */
#define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
#define S_ISCHR(m)  (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)  (((m) & S_IFMT) == S_IFBLK)

struct stat {
    mode_t st_mode;
    off_t  st_size;
    uid_t  st_uid;
    gid_t  st_gid;
};

int stat(const char *path, struct stat *buf);
int mkdir(const char *path, mode_t mode);

#ifdef __cplusplus
}
#endif
