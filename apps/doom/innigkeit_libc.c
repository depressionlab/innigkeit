/*
 * Minimal C runtime for Innigkeit enough to satisfy doomgeneric.
 *
 * Provides: malloc/free/calloc/realloc, printf family, file I/O (initfs + data disk),
 * string utilities, time functions, exit, assert helpers.
 */

#include "innigkeit_syscalls.h"
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* ---- write / stdout ---- */

static int write_stdout(const char *buf, size_t len) {
    return (int)innigkeit_write(buf, len);
}

/* ---- malloc / free ---- */

/*
 * Simple heap backed by mmap. We use a fixed 64 MiB arena so that the
 * zone allocator can grab one big block at startup, as DOOM expects.
 * Allocations that exceed a page are rounded up and mmap'd directly.
 * free() is a no-op (acceptable: DOOM's zone allocator owns the memory).
 */

#define HEAP_SIZE   (64 * 1024 * 1024)
#define PAGE_SIZE   4096
#define ALIGN_UP(x, a)  (((x) + (a) - 1) & ~((a) - 1))

static uint8_t  *heap_base = NULL;
static size_t    heap_used = 0;
static size_t    heap_cap  = 0;

static void heap_init(void) {
    if (heap_base) return;
    heap_base = (uint8_t *)innigkeit_mmap(HEAP_SIZE);
    heap_cap  = (heap_base != NULL) ? HEAP_SIZE : 0;
    heap_used = 0;
}

void *malloc(size_t size) {
    heap_init();
    size = ALIGN_UP(size + sizeof(size_t), 16);
    if (heap_used + size > heap_cap) {
        /* Fall back to a fresh mmap page for oversized requests. */
        size_t pages = ALIGN_UP(size + sizeof(size_t), PAGE_SIZE);
        uint8_t *p = (uint8_t *)innigkeit_mmap(pages);
        if (!p) return NULL;
        *(size_t *)p = pages;
        return p + sizeof(size_t);
    }
    uint8_t *p = heap_base + heap_used;
    *(size_t *)p = size;
    heap_used += size;
    return p + sizeof(size_t);
}

void free(void *ptr) {
    (void)ptr; /* zone allocator owns all memory */
}

void *calloc(size_t nmemb, size_t size) {
    /* mmap returns zeroed pages; heap is zeroed on first touch */
    return malloc(nmemb * size);
}

void *realloc(void *old_ptr, size_t new_size) {
    /* Simple realloc: alloc new + memcpy. Works because free() is a no-op. */
    void *p = malloc(new_size);
    if (old_ptr && p) {
        size_t old_size = *((size_t *)((uint8_t *)old_ptr - sizeof(size_t)));
        size_t copy = (old_size < new_size) ? old_size : new_size;
        __builtin_memcpy(p, old_ptr, copy);
    }
    return p;
}

/* ---- string helpers ---- */

/* Most are compiler builtins; provide any not auto-provided. */

char *strcpy(char *dst, const char *src) {
    char *d = dst;
    while ((*d++ = *src++));
    return dst;
}

char *strncpy(char *dst, const char *src, size_t n) {
    size_t i;
    for (i = 0; i < n && src[i]; i++) dst[i] = src[i];
    for (; i < n; i++) dst[i] = 0;
    return dst;
}

char *strcat(char *dst, const char *src) {
    char *d = dst;
    while (*d) d++;
    while ((*d++ = *src++));
    return dst;
}

char *strncat(char *dst, const char *src, size_t n) {
    char *d = dst;
    while (*d) d++;
    while (n-- && (*d++ = *src++));
    *d = 0;
    return dst;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return p - s;
}

char *strchr(const char *s, int c) {
    for (; *s; s++) if (*s == (char)c) return (char *)s;
    return (c == 0) ? (char *)s : NULL;
}

char *strrchr(const char *s, int c) {
    const char *last = NULL;
    for (; *s; s++) if (*s == (char)c) last = s;
    return (char *)last;
}

char *strstr(const char *haystack, const char *needle) {
    if (!*needle) return (char *)haystack;
    size_t nl = strlen(needle);
    for (; *haystack; haystack++)
        if (__builtin_memcmp(haystack, needle, nl) == 0) return (char *)haystack;
    return NULL;
}

char *strtok(char *str, const char *delim) {
    static char *saved = NULL;
    if (str) saved = str;
    if (!saved) return NULL;
    while (*saved && strchr(delim, *saved)) saved++;
    if (!*saved) return NULL;
    char *tok = saved;
    while (*saved && !strchr(delim, *saved)) saved++;
    if (*saved) *saved++ = 0;
    return tok;
}

long strtol(const char *s, char **end, int base) {
    while (*s == ' ' || *s == '\t') s++;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; } else if (*s == '+') s++;
    if (base == 0) { base = 10; if (*s == '0') { base = 8; s++; if (*s == 'x' || *s == 'X') { base = 16; s++; } } }
    long v = 0;
    for (;;) {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (*s >= 'a' && *s <= 'z') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'Z') d = *s - 'A' + 10;
        else break;
        if (d >= base) break;
        v = v * base + d;
        s++;
    }
    if (end) *end = (char *)s;
    return neg ? -v : v;
}

int atoi(const char *s) { return (int)strtol(s, NULL, 10); }
double atof(const char *s) {
    while (isspace((unsigned char)*s)) s++;
    double sign = 1.0; if (*s == '-') { sign = -1.0; s++; } else if (*s == '+') s++;
    double v = 0.0;
    while (isdigit((unsigned char)*s)) v = v * 10.0 + (*s++ - '0');
    if (*s == '.') { s++; double f = 0.1; while (isdigit((unsigned char)*s)) { v += (*s++ - '0') * f; f *= 0.1; } }
    return sign * v;
}
char *strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) __builtin_memcpy(p, s, n);
    return p;
}
char *strndup(const char *s, size_t n) {
    size_t len = strlen(s); if (len > n) len = n;
    char *p = (char *)malloc(len + 1);
    if (p) { __builtin_memcpy(p, s, len); p[len] = 0; }
    return p;
}

int isdigit(int c) { return c >= '0' && c <= '9'; }
int isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isalpha(int c) { return isupper(c) || islower(c); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int ispunct(int c) { return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~'); }
int isprint(int c) { return c >= 0x20 && c < 0x7f; }
int toupper(int c) { return islower(c) ? c - 32 : c; }
int tolower(int c) { return isupper(c) ? c + 32 : c; }

void bzero(void *s, size_t n) { __builtin_memset(s, 0, n); }
void bcopy(const void *src, void *dst, size_t n) { __builtin_memmove(dst, src, n); }
int  bcmp(const void *s1, const void *s2, size_t n) { return __builtin_memcmp(s1, s2, n); }

int vsprintf(char *buf, const char *fmt, va_list ap) {
    return vsnprintf(buf, (size_t)-1, fmt, ap);
}

int sprintf(char *buf, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vsprintf(buf, fmt, ap);
    va_end(ap); return r;
}

static char printf_buf[4096];
int vprintf(const char *fmt, va_list ap) {
    int n = vsnprintf(printf_buf, sizeof(printf_buf), fmt, ap);
    write_stdout(printf_buf, (size_t)(n < (int)sizeof(printf_buf) ? n : (int)sizeof(printf_buf) - 1));
    return n;
}

int printf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vprintf(fmt, ap);
    va_end(ap); return r;
}

int vfprintf(void *stream, const char *fmt, va_list ap) {
    (void)stream; return vprintf(fmt, ap);
}

int fprintf(void *stream, const char *fmt, ...) {
    (void)stream;
    va_list ap; va_start(ap, fmt);
    int r = vprintf(fmt, ap);
    va_end(ap); return r;
}

int puts(const char *s) {
    write_stdout(s, strlen(s));
    write_stdout("\n", 1);
    return 0;
}

int putchar(int c) {
    char ch = (char)c;
    write_stdout(&ch, 1);
    return c;
}

int fputs(const char *s, void *stream) { (void)stream; return puts(s) >= 0 ? 0 : -1; }
int fputc(int c, void *stream) { (void)stream; return putchar(c); }

/* ---- errno / assert / abort ---- */

int errno_val = 0;
int *__errno_location(void) { return &errno_val; }

void abort(void) {
    write_stdout("abort()\n", 8);
    innigkeit_exit(1);
}

void __assert_fail(const char *expr, const char *file, unsigned line, const char *fn) {
    char buf[256];
    snprintf(buf, sizeof(buf), "assert failed: %s at %s:%u (%s)\n", expr, file, line, fn);
    write_stdout(buf, strlen(buf));
    innigkeit_exit(1);
}

void exit(int code) {
    innigkeit_exit(code);
}

/* ---- file I/O (FILE*) ---- */

/*
 * Pseudo-FILE implementation: each FILE is an in-memory buffer loaded at open time.
 * - initfs files: loaded via initfs_read syscall
 * - "/doom1.wad" (and any path matching WAD_DISK_PATH): loaded from data disk device 1
 *
 * We use mmap for the buffer so free() is a no-op.
 */

#define WAD_DISK_PATH  "/doom1.wad"
#define MAX_FILES      16

typedef struct {
    uint8_t *data;
    size_t   size;
    size_t   pos;
    bool     in_use;
    bool     eof;
} MemFile;

static MemFile s_files[MAX_FILES];

void *stdin  = NULL;
void *stdout = NULL;
void *stderr = NULL;

static MemFile *alloc_file(void) {
    for (int i = 0; i < MAX_FILES; i++)
        if (!s_files[i].in_use) { s_files[i] = (MemFile){0}; s_files[i].in_use = true; return &s_files[i]; }
    return NULL;
}

static bool load_from_initfs(MemFile *f, const char *path) {
    size_t name_len = strlen(path);
    /* Strip leading slash for initfs lookup */
    const char *name = (path[0] == '/') ? path + 1 : path;
    size_t nlen = strlen(name);

    InnigkeitInitfsSpec spec = { (uintptr_t)name, (uint32_t)nlen, 0, 0, 0 };
    long sz = innigkeit_initfs_read(name, nlen, NULL, 0);
    if (sz < 0) return false;

    f->data = (uint8_t *)innigkeit_mmap((size_t)sz + PAGE_SIZE);
    if (!f->data) return false;
    f->size = (size_t)sz;

    long got = innigkeit_initfs_read(name, nlen, f->data, f->size);
    if (got < 0) return false;
    f->size = (size_t)got;
    return true;
}

static bool load_from_disk(MemFile *f) {
    /* Data disk: device 1. We read the whole WAD into memory. */
    /* First 8 bytes of a WAD are: IWAD/PWAD magic + uint32 lumpcount + uint32 infooffset */
    uint8_t header[8];
    long r = innigkeit_blk_read(0, header, 8);
    if (r < 8) return false;
    /* WAD size: we don't know upfront. Read the directory offset + 16 bytes of lump count. */
    /* WAD format: [4 magic][4 lumpcount][4 infotableofs] */
    uint32_t lump_count, info_ofs;
    __builtin_memcpy(&lump_count, header + 4, 4);
    __builtin_memcpy(&info_ofs,   header + 8, 4);  /* wait, header is only 8 bytes... */
    /* Re-read full 12-byte header */
    uint8_t hdr12[12];
    r = innigkeit_blk_read(0, hdr12, 12);
    if (r < 12) return false;
    __builtin_memcpy(&lump_count, hdr12 + 4, 4);
    __builtin_memcpy(&info_ofs,   hdr12 + 8, 4);

    /* WAD total size = infotableofs + lumpcount * 16 */
    size_t total = (size_t)info_ofs + (size_t)lump_count * 16;
    if (total < 12) total = 12;

    f->data = (uint8_t *)innigkeit_mmap(total + PAGE_SIZE);
    if (!f->data) return false;
    f->size = total;

    /* Read in 4KB chunks */
    size_t done = 0;
    while (done < total) {
        size_t chunk = (total - done < 4096) ? (total - done) : 4096;
        r = innigkeit_blk_read((uint64_t)done, f->data + done, chunk);
        if (r <= 0) break;
        done += (size_t)r;
    }
    f->size = done;
    printf("doom: loaded WAD from disk: %zu bytes (%u lumps)\n", f->size, lump_count);
    /* Diagnostic: print magic + first 5 lump names so we can verify the WAD. */
    printf("doom: WAD magic=[%.4s] first lumps:", hdr12);
    uint32_t shown = lump_count < 5 ? lump_count : 5;
    for (uint32_t i = 0; i < shown; i++) {
        /* Each directory entry is 16 bytes: filepos(4)+size(4)+name(8). Name is at +8. */
        const uint8_t *entry = f->data + info_ofs + i * 16;
        char name[9];
        __builtin_memcpy(name, entry + 8, 8);
        name[8] = '\0';
        printf(" [%.8s]", name);
    }
    /* Scan directory for TEXTURE1/TEXTURE2 to verify they exist in the raw WAD. */
    bool found_t1 = false, found_t2 = false;
    for (uint32_t i = 0; i < lump_count; i++) {
        const char *name = (const char *)(f->data + info_ofs + i * 16 + 8);
        if (__builtin_memcmp(name, "TEXTURE1", 8) == 0) found_t1 = true;
        if (__builtin_memcmp(name, "TEXTURE2", 8) == 0) found_t2 = true;
    }
    printf("doom: TEXTURE1 in raw WAD: %s  TEXTURE2: %s\n",
           found_t1 ? "YES" : "NO", found_t2 ? "YES" : "NO");
    printf("\n");
    return true;
}

void *fopen(const char *path, const char *mode) {
    (void)mode;
    MemFile *f = alloc_file();
    if (!f) return NULL;

    bool ok = false;
    if (__builtin_strcmp(path, WAD_DISK_PATH) == 0 || __builtin_strcmp(path, "doom1.wad") == 0) {
        ok = load_from_disk(f);
    }
    if (!ok) {
        ok = load_from_initfs(f, path);
    }
    if (!ok) { f->in_use = false; return NULL; }
    return (void *)f;
}

size_t fread(void *ptr, size_t size, size_t count, void *stream) {
    MemFile *f = (MemFile *)stream;
    if (!f || !f->in_use) return 0;
    size_t want = size * count;
    size_t avail = (f->pos < f->size) ? (f->size - f->pos) : 0;
    size_t got = (want < avail) ? want : avail;
    if (got == 0) { f->eof = true; return 0; }
    __builtin_memcpy(ptr, f->data + f->pos, got);
    f->pos += got;
    return got / size;
}

size_t fwrite(const void *ptr, size_t size, size_t count, void *stream) {
    (void)stream; /* writes go to stdout */
    write_stdout((const char *)ptr, size * count);
    return count;
}

int fseek(void *stream, long offset, int whence) {
    MemFile *f = (MemFile *)stream;
    if (!f || !f->in_use) return -1;
    long new_pos;
    if (whence == 0 /* SEEK_SET */) new_pos = offset;
    else if (whence == 1 /* SEEK_CUR */) new_pos = (long)f->pos + offset;
    else if (whence == 2 /* SEEK_END */) new_pos = (long)f->size + offset;
    else return -1;
    if (new_pos < 0) return -1;
    f->pos = (size_t)new_pos;
    f->eof = false;
    return 0;
}

long ftell(void *stream) {
    MemFile *f = (MemFile *)stream;
    return (f && f->in_use) ? (long)f->pos : -1;
}

int feof(void *stream) {
    MemFile *f = (MemFile *)stream;
    return (f && f->eof) ? 1 : 0;
}

int ferror(void *stream) { (void)stream; return 0; }

int fclose(void *stream) {
    MemFile *f = (MemFile *)stream;
    if (f) f->in_use = false;
    return 0;
}

int fflush(void *stream) { (void)stream; return 0; }

char *fgets(char *buf, int n, void *stream) {
    MemFile *f = (MemFile *)stream;
    if (!f || n <= 1 || f->eof) return NULL;
    int i = 0;
    for (; i < n - 1; i++) {
        if (f->pos >= f->size) { f->eof = true; break; }
        buf[i] = (char)f->data[f->pos++];
        if (buf[i] == '\n') { i++; break; }
    }
    if (i == 0) return NULL;
    buf[i] = 0;
    return buf;
}

/* ---- time / gettimeofday ---- */

typedef struct { long tv_sec; long tv_usec; } timeval;
typedef struct { int tz_minuteswest; int tz_dsttime; } timezone;

int gettimeofday(timeval *tv, timezone *tz) {
    (void)tz;
    if (tv) {
        uint64_t ms = innigkeit_uptime_ms();
        tv->tv_sec  = (long)(ms / 1000);
        tv->tv_usec = (long)((ms % 1000) * 1000);
    }
    return 0;
}

long time(long *t) {
    uint64_t ms = innigkeit_uptime_ms();
    long s = (long)(ms / 1000);
    if (t) *t = s;
    return s;
}

typedef long clock_t;
#define CLOCKS_PER_SEC 1000
clock_t clock(void) {
    return (clock_t)innigkeit_uptime_ms();
}

char *getenv(const char *name) { (void)name; return NULL; }
int system(const char *cmd) { (void)cmd; return -1; }

int open(const char *path, int flags, ...) { (void)path; (void)flags; return -1; }
int close(int fd) { (void)fd; return -1; }
long read(int fd, void *buf, size_t len) { (void)fd; (void)buf; (void)len; return -1; }
int unlink(const char *path) { (void)path; return -1; }
int rename(const char *old, const char *newp) { (void)old; (void)newp; return -1; }
char *getcwd(char *buf, size_t size) { if (buf && size > 0) buf[0] = 0; return buf; }
int chdir(const char *path) { (void)path; return -1; }
char *mkdtemp(char *tmpl) { (void)tmpl; return NULL; }

/* DIR stubs */
void *opendir(const char *path) { (void)path; return NULL; }
void *readdir(void *dir) { (void)dir; return NULL; }
int closedir(void *dir) { (void)dir; return 0; }

/* usleep: busy-wait using uptime_ms */
int usleep(unsigned long usec) {
    uint64_t target_ms = innigkeit_uptime_ms() + usec / 1000;
    while (innigkeit_uptime_ms() < target_ms) ;
    return 0;
}

/* stat stubs */
int stat(const char *path, void *buf) { (void)path; (void)buf; return -1; }
int fstat(int fd, void *buf) { (void)fd; (void)buf; return -1; }
int mkdir(const char *path, unsigned mode) { (void)path; (void)mode; return -1; }
int access(const char *path, int mode) { (void)path; (void)mode; return -1; }
int remove(const char *path) { (void)path; return -1; }

int sscanf(const char *str, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int count = 0;
    while (*fmt && *str) {
        if (*fmt != '%') { if (*fmt == *str) { fmt++; str++; } else break; continue; }
        fmt++;
        switch (*fmt) {
        case 'd': { int *p = va_arg(ap, int *); *p = (int)strtol(str, (char **)&str, 10); count++; break; }
        case 's': {
            char *p = va_arg(ap, char *);
            while (*str && isspace((unsigned char)*str)) str++;
            while (*str && !isspace((unsigned char)*str)) *p++ = *str++;
            *p = 0; count++; break; }
        default: break;
        }
        fmt++;
    }
    va_end(ap); return count;
}


/* rand / srand */
static unsigned long rand_state = 1;
int rand(void) { rand_state = rand_state * 1103515245 + 12345; return (int)((rand_state >> 16) & 0x7fff); }
void srand(unsigned seed) { rand_state = seed; }

/* abs / labs */
int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }

void qsort(void *base, size_t n, size_t size, int (*cmp)(const void*, const void*)) {
    char *b = (char *)base;
    char *tmp = (char *)malloc(size);
    if (!tmp) return;
    for (size_t i = 1; i < n; i++) {
        __builtin_memcpy(tmp, b + i * size, size);
        size_t j = i;
        while (j > 0 && cmp(b + (j-1)*size, tmp) > 0) {
            __builtin_memcpy(b + j*size, b + (j-1)*size, size);
            j--;
        }
        __builtin_memcpy(b + j*size, tmp, size);
    }
    free(tmp);
}

/* bsearch */
void *bsearch(const void *key, const void *base, size_t n, size_t size,
              int (*cmp)(const void*, const void*)) {
    const char *lo = (const char *)base, *hi = lo + n * size;
    while (lo < hi) {
        const char *mid = lo + ((hi - lo) / size / 2) * size;
        int r = cmp(key, mid);
        if (r < 0) hi = mid;
        else if (r > 0) lo = mid + size;
        else return (void *)mid;
    }
    return NULL;
}

/* math (integer subset) */
double fabs(double x)  { return x < 0 ? -x : x; }
double floor(double x) { return (double)(long long)x - (x < (double)(long long)x ? 1.0 : 0.0); }
double ceil(double x)  { long long t = (long long)x; return (double)(x > (double)t ? t + 1 : t); }
double sqrt(double x)  {
    if (x <= 0) return 0;
    double r = x;
    for (int i = 0; i < 40; i++) r = 0.5 * (r + x / r);
    return r;
}
double sin(double x)   {
    /* Taylor: x - x^3/6 + x^5/120 - x^7/5040 + ... */
    double x2 = x * x, t = x, s = x;
    t *= -x2 / 6.0;    s += t;
    t *= -x2 / 20.0;   s += t;
    t *= -x2 / 42.0;   s += t;
    t *= -x2 / 72.0;   s += t;
    return s;
}
double cos(double x)   {
    double x2 = x * x, t = 1.0, s = 1.0;
    t *= -x2 / 2.0;   s += t;
    t *= -x2 / 12.0;  s += t;
    t *= -x2 / 30.0;  s += t;
    t *= -x2 / 56.0;  s += t;
    return s;
}
double atan2(double y, double x) {
    if (x == 0 && y == 0) return 0;
    double ax = fabs(x), ay = fabs(y);
    double a;
    if (ax >= ay) {
        double r = ay / ax;
        a = r * (0.9817 - 0.1963 * r * r);
    } else {
        double r = ax / ay;
        a = 1.5708 - r * (0.9817 - 0.1963 * r * r);
    }
    if (x < 0) a = 3.14159265 - a;
    return y < 0 ? -a : a;
}
double log(double x)   { return (x > 0) ? (x - 1) - (x - 1) * (x - 1) / 2.0 : 0; } /* rough */
double exp(double x)   {
    double s = 1.0, t = 1.0;
    for (int i = 1; i < 20; i++) { t *= x / i; s += t; }
    return s;
}
double pow(double x, double y) {
    if (y == 0) return 1;
    if (y == (double)(long long)y) {
        long long n = (long long)y; double r = 1;
        double b = n < 0 ? 1.0/x : x; if (n < 0) n = -n;
        while (n) { if (n & 1) r *= b; b *= b; n >>= 1; }
        return r;
    }
    return exp(y * log(x));
}
float fabsf(float x) { return (float)fabs((double)x); }
float sqrtf(float x) { return (float)sqrt((double)x); }
float sinf(float x)  { return (float)sin((double)x); }
float cosf(float x)  { return (float)cos((double)x); }
float atan2f(float y, float x) { return (float)atan2((double)y, (double)x); }
