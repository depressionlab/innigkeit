#pragma once
#include <stdint.h>
#include <stddef.h>

/*
 * Thin wrappers around Innigkeit kernel syscalls, callable from C.
 * These are exported by syscalls.zig in the same module.
 */

/* Write bytes to stdout (fd 1). Returns bytes written or negative error. */
long innigkeit_write(const void *buf, size_t len);

/* Exit the current process. */
__attribute__((noreturn)) void innigkeit_exit(int code);

/* Map anonymous zero-filled memory of `size` bytes. Returns VA or 0 on error. */
void *innigkeit_mmap(size_t size);

/* Unmap a previously mapped range. */
void innigkeit_munmap(void *addr, size_t size);

/* Map the bootloader framebuffer. Fills *info and returns pixel pointer, or NULL. */
typedef struct {
    uint32_t width, height, pitch;
    uint8_t  bpp;
    uint8_t  _pad[3];
} InnigkeitFbInfo;
volatile uint32_t *innigkeit_framebuffer_map(InnigkeitFbInfo *info);

/* Return milliseconds since kernel boot. */
uint64_t innigkeit_uptime_ms(void);

/* Read bytes from data disk (device 1) at byte_offset into buf. Returns bytes read or -error. */
typedef struct {
    uint64_t byte_offset;
    uintptr_t buf_ptr;
    size_t    buf_len;
} InnigkeitBlkReadSpec;
long innigkeit_blk_read(uint64_t byte_offset, void *buf, size_t len);

/* Read a file from initfs. buf_len==0 -> returns file size (stat mode). */
typedef struct {
    uintptr_t name_ptr;
    uint32_t  name_len;
    uint32_t  _pad;
    uintptr_t buf_ptr;
    size_t    buf_len;
} InnigkeitInitfsSpec;
long innigkeit_initfs_read(const char *name, size_t name_len, void *buf, size_t buf_len);

/* Non-blocking drain of raw PS/2 bytes (incl. 0xE0 prefix and break bit).
 * Returns byte count copied, or 0 if no keys are pending. */
long innigkeit_kbd_read(void *buf, size_t len);
