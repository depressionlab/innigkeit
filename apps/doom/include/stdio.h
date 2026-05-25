#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdarg.h>

/* FILE is opaque; our implementation stores MemFile* as void* */
typedef void FILE;

/* Standard streams, defined in innigkeit_libc.c */
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

/* Sentinel values */
#define EOF      (-1)

/* fseek whence constants */
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

/* --- File operations --- */
FILE   *fopen(const char *path, const char *mode);
int     fclose(FILE *stream);
size_t  fread(void *ptr, size_t size, size_t count, FILE *stream);
size_t  fwrite(const void *ptr, size_t size, size_t count, FILE *stream);
int     fseek(FILE *stream, long offset, int whence);
long    ftell(FILE *stream);
int     feof(FILE *stream);
int     ferror(FILE *stream);
int     fflush(FILE *stream);
char   *fgets(char *buf, int n, FILE *stream);
int     fputs(const char *s, FILE *stream);
int     fputc(int c, FILE *stream);

/* --- Formatted output --- */
int     printf(const char *fmt, ...);
int     fprintf(FILE *stream, const char *fmt, ...);
int     vfprintf(FILE *stream, const char *fmt, va_list ap);
int     snprintf(char *buf, size_t size, const char *fmt, ...);
int     sprintf(char *buf, const char *fmt, ...);
int     vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int     vsprintf(char *buf, const char *fmt, va_list ap);

/* --- Formatted input --- */
int     sscanf(const char *str, const char *fmt, ...);

/* --- Character / line output --- */
int     puts(const char *s);
int     putchar(int c);
int     fputs(const char *s, FILE *stream);
int     fputc(int c, FILE *stream);

/* --- File system --- */
int     remove(const char *path);
int     rename(const char *old, const char *newp);

#ifdef __cplusplus
}
#endif
