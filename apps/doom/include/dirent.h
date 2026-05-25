#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

/* Opaque directory stream */
typedef void DIR;

struct dirent {
    char d_name[256];
};

DIR           *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int            closedir(DIR *dirp);

#ifdef __cplusplus
}
#endif
