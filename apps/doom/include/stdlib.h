#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

#define RAND_MAX 0x7fff

/* --- Memory allocation --- */
void  *malloc(size_t size);
void   free(void *ptr);
void  *calloc(size_t nmemb, size_t size);
void  *realloc(void *ptr, size_t size);

/* --- Process control --- */
void   exit(int code);
void   abort(void);

/* --- String / number conversion --- */
int    atoi(const char *s);
double atof(const char *s);
long   strtol(const char *s, char **endptr, int base);

/* --- Pseudo-random --- */
int    rand(void);
void   srand(unsigned int seed);

/* --- Sorting / searching --- */
void   qsort(void *base, size_t nmemb, size_t size,
             int (*compar)(const void *, const void *));
void  *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
               int (*compar)(const void *, const char *));

/* --- Environment --- */
char  *getenv(const char *name);
int    system(const char *command);

/* --- Integer math --- */
int    abs(int x);
long   labs(long x);

/* --- Filesystem stub (always fails) --- */
char  *mkdtemp(char *tmpl);

#ifdef __cplusplus
}
#endif
