/*
 * doomgeneric platform implementation for Innigkeit OS.
 *
 * DG_Init:         Map framebuffer; set up screen buffer.
 * DG_DrawFrame:    Blit DG_ScreenBuffer -> framebuffer (scaled or 1:1).
 * DG_SleepMs:      Busy-wait using uptime_ms.
 * DG_GetTicksMs:   Return uptime_ms.
 * DG_GetKey:       PS/2 scancode -> DOOM key (read from stdin via `read` syscall).
 * DG_SetWindowTitle: No-op.
 */

#include <doomgeneric.h>
#include <doomkeys.h>
#include "innigkeit_syscalls.h"
#include <stdint.h>
#include <stddef.h>

/* DOOM renders at 320x200; we scale it up 2x to 640x400 on screen. */
#define DOOM_W  DOOMGENERIC_RESX   /* 320 */
#define DOOM_H  DOOMGENERIC_RESY   /* 200 */
#define SCALE   2

static volatile uint32_t *s_fb     = NULL;
static uint32_t           s_fb_w   = 0;
static uint32_t           s_fb_h   = 0;
static uint32_t           s_stride = 0; /* pixels per row */

/* Key event ring buffer */
#define KEYQUEUE_SIZE 32
static uint16_t s_key_queue[KEYQUEUE_SIZE];
static unsigned s_key_write = 0;
static unsigned s_key_read  = 0;

static void key_push(int pressed, unsigned char doom_key) {
    if (doom_key == 0) return;
    s_key_queue[s_key_write] = (uint16_t)((pressed << 8) | doom_key);
    s_key_write = (s_key_write + 1) % KEYQUEUE_SIZE;
}

/*
 * Translate a PS/2 set-1 make code to a DOOM key code.
 * is_extended: non-zero if the byte was preceded by a 0xE0 prefix.
 */
static unsigned char scancode_to_doom(unsigned char make, int is_extended) {
    if (is_extended) {
        switch (make) {
        case 0x48: return KEY_UPARROW;
        case 0x50: return KEY_DOWNARROW;
        case 0x4B: return KEY_LEFTARROW;
        case 0x4D: return KEY_RIGHTARROW;
        case 0x1D: return KEY_RCTRL;
        case 0x38: return KEY_RALT;
        default:   return 0;
        }
    }
    switch (make) {
    case 0x1C: return KEY_ENTER;
    case 0x01: return KEY_ESCAPE;
    case 0x1D: return KEY_FIRE;    /* Left Ctrl -> fire */
    case 0x39: return KEY_USE;     /* Space -> use/open */
    case 0x2A: case 0x36: return KEY_RSHIFT;
    case 0x38: return KEY_LALT;
    case 0x0F: return KEY_TAB;
    case 0x57: return KEY_F11;
    case 0x58: return KEY_F12;
    case 0x3B: return KEY_F1;  case 0x3C: return KEY_F2;
    case 0x3D: return KEY_F3;  case 0x3E: return KEY_F4;
    case 0x3F: return KEY_F5;  case 0x40: return KEY_F6;
    case 0x41: return KEY_F7;  case 0x42: return KEY_F8;
    case 0x43: return KEY_F9;  case 0x44: return KEY_F10;
    default:
        if (make >= 0x02 && make <= 0x0D) {
            static const char nums[] = "1234567890-=";
            return (unsigned char)nums[make - 0x02];
        }
        if (make == 0x10) return 'q'; if (make == 0x11) return 'w';
        if (make == 0x12) return 'e'; if (make == 0x13) return 'r';
        if (make == 0x14) return 't'; if (make == 0x15) return 'y';
        if (make == 0x16) return 'u'; if (make == 0x17) return 'i';
        if (make == 0x18) return 'o'; if (make == 0x19) return 'p';
        if (make == 0x1E) return 'a'; if (make == 0x1F) return 's';
        if (make == 0x20) return 'd'; if (make == 0x21) return 'f';
        if (make == 0x22) return 'g'; if (make == 0x23) return 'h';
        if (make == 0x24) return 'j'; if (make == 0x25) return 'k';
        if (make == 0x26) return 'l';
        if (make == 0x2C) return 'z'; if (make == 0x2D) return 'x';
        if (make == 0x2E) return 'c'; if (make == 0x2F) return 'v';
        if (make == 0x30) return 'b'; if (make == 0x31) return 'n';
        if (make == 0x32) return 'm';
        return 0;
    }
}

static void poll_keyboard(void) {
    uint8_t raw[32];
    long n = innigkeit_kbd_read(raw, sizeof(raw));
    if (n <= 0) return;

    static int in_extended = 0;
    for (long i = 0; i < n; i++) {
        uint8_t byte = raw[i];
        if (byte == 0xE0) {
            in_extended = 1;
            continue;
        }
        int ext = in_extended;
        in_extended = 0;

        int is_break = (byte & 0x80) != 0;
        uint8_t make = byte & 0x7F;
        unsigned char dk = scancode_to_doom(make, ext);
        if (dk != 0) key_push(!is_break, dk);
    }
}

void DG_Init(void) {
    InnigkeitFbInfo info;
    volatile uint32_t *fb = innigkeit_framebuffer_map(&info);
    if (!fb) {
        printf("DG_Init: no framebuffer\n");
        return;
    }
    s_fb     = fb;
    s_fb_w   = info.width;
    s_fb_h   = info.height;
    s_stride = info.pitch / 4;
    printf("DG_Init: framebuffer %ux%u stride=%u\n", s_fb_w, s_fb_h, s_stride);
}

void DG_DrawFrame(void) {
    if (!s_fb || !DG_ScreenBuffer) return;

    /*
     * Scale the 320x200 DOOM frame up to SCALExSCALE blocks.
     * DG_ScreenBuffer pixels are BGRX (same format as the framebuffer).
     * Centre the scaled image if the display is larger.
     */
    uint32_t dst_w   = (uint32_t)(DOOM_W * SCALE);
    uint32_t dst_h   = (uint32_t)(DOOM_H * SCALE);
    uint32_t offset_x = (s_fb_w > dst_w) ? (s_fb_w - dst_w) / 2 : 0;
    uint32_t offset_y = (s_fb_h > dst_h) ? (s_fb_h - dst_h) / 2 : 0;

    for (uint32_t sy = 0; sy < (uint32_t)DOOM_H; sy++) {
        const uint32_t *src_row = DG_ScreenBuffer + sy * DOOM_W;
        for (uint32_t sx = 0; sx < (uint32_t)DOOM_W; sx++) {
            uint32_t pixel = src_row[sx];
            uint32_t fy = offset_y + sy * SCALE;
            uint32_t fx = offset_x + sx * SCALE;
            /* Write SCALExSCALE block */
            for (uint32_t dy = 0; dy < SCALE; dy++) {
                uint32_t row = fy + dy;
                if (row >= s_fb_h) break;
                volatile uint32_t *dst_row_p = s_fb + row * s_stride + fx;
                for (uint32_t dx = 0; dx < SCALE; dx++) {
                    if (fx + dx < s_fb_w) dst_row_p[dx] = pixel;
                }
            }
        }
    }

    poll_keyboard();
}

void DG_SleepMs(uint32_t ms) {
    uint64_t target = innigkeit_uptime_ms() + ms;
    while (innigkeit_uptime_ms() < target)
        ; /* busy-wait; yield once the scheduler has a sleep syscall */
}

uint32_t DG_GetTicksMs(void) {
    return (uint32_t)innigkeit_uptime_ms();
}

int DG_GetKey(int *pressed, unsigned char *doom_key) {
    if (s_key_read == s_key_write) return 0;
    uint16_t data = s_key_queue[s_key_read];
    s_key_read = (s_key_read + 1) % KEYQUEUE_SIZE;
    *pressed  = data >> 8;
    *doom_key = data & 0xFF;
    return 1;
}

void DG_SetWindowTitle(const char *title) {
    (void)title;
}
