#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#define MAX_GAMES 512
#define MAX_NAME 160
#define MAX_DEVICES 64

typedef struct {
    char kind[24];
    char name[MAX_NAME];
} Game;

typedef struct {
    int fd;
    char path[128];
} InputDevice;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} Color;

typedef struct {
    int fd;
    uint8_t *fb;
    uint8_t *rgb;
    long fb_size;
    int width;
    int height;
    int line_length;
    int bpp;
    int direct_write;
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
} Framebuffer;

typedef struct {
    int width;
    int height;
    uint8_t *data;
} Image;

typedef struct {
    uint8_t *data;
    size_t size;
    stbtt_fontinfo info;
    int ready;
} Font;

static const Color C_INK = {245, 255, 233};
static const Color C_MUTED = {156, 181, 156};
static const Color C_BG = {7, 16, 8};
static const Color C_PANEL = {13, 26, 18};
static const Color C_PANEL_STRONG = {20, 43, 28};
static const Color C_LIME = {216, 255, 41};
static const Color C_GREEN = {52, 211, 55};
static const Color C_CYAN = {88, 230, 255};
static const Color C_DARK = {4, 12, 7};

static const char *log_path = NULL;
static Font ui_font = {0};

static void log_line(const char *fmt, ...) {
    if (!log_path || !*log_path) return;

    FILE *f = fopen(log_path, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d] [C_UI] ",
            tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int file_exists(const char *path) {
    return path && *path && access(path, R_OK) == 0;
}

static int has_suffix(const char *s, const char *suffix) {
    size_t s_len = s ? strlen(s) : 0;
    size_t suffix_len = suffix ? strlen(suffix) : 0;
    if (s_len < suffix_len) return 0;
    return strcmp(s + s_len - suffix_len, suffix) == 0;
}

static void replace_extension(const char *path, const char *new_ext, char *out, size_t out_size) {
    if (!out || out_size == 0) return;
    out[0] = 0;
    if (!path || !*path) return;

    snprintf(out, out_size, "%s", path);
    char *slash = strrchr(out, '/');
    char *dot = strrchr(out, '.');
    if (!dot || (slash && dot < slash)) {
        strncat(out, new_ext, out_size - strlen(out) - 1);
        return;
    }
    *dot = 0;
    strncat(out, new_ext, out_size - strlen(out) - 1);
}

static void replace_basename_suffix(const char *path, const char *suffix, char *out, size_t out_size) {
    if (!out || out_size == 0) return;
    out[0] = 0;
    if (!path || !*path) return;
    snprintf(out, out_size, "%s", path);
    char *slash = strrchr(out, '/');
    char *base = slash ? slash + 1 : out;
    char *dot = strrchr(base, '.');
    if (dot) *dot = 0;
    strncat(out, suffix, out_size - strlen(out) - 1);
}

static int clamp_int(int value, int min_value, int max_value) {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}

static void trim_newline(char *s) {
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
        s[len - 1] = 0;
        len--;
    }
}

static int load_games(const char *path, Game *games, int max_games) {
    FILE *f = fopen(path, "r");
    if (!f) {
        log_line("Could not open games list: %s (%s)", path, strerror(errno));
        return -1;
    }

    int count = 0;
    char line[512];
    while (fgets(line, sizeof(line), f) && count < max_games) {
        trim_newline(line);
        if (!line[0]) continue;

        char *tab = strchr(line, '\t');
        if (tab) {
            *tab = 0;
            snprintf(games[count].kind, sizeof(games[count].kind), "%s", line);
            snprintf(games[count].name, sizeof(games[count].name), "%s", tab + 1);
        } else {
            snprintf(games[count].kind, sizeof(games[count].kind), "%s", "apk");
            snprintf(games[count].name, sizeof(games[count].name), "%s", line);
        }
        count++;
    }

    fclose(f);
    log_line("Loaded %d games for native UI.", count);
    return count;
}

static int load_truetype_font(Font *font, const char *path, const char *display_path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        log_line("Could not open UI font %s: %s.", path, strerror(errno));
        return 0;
    }

    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 0;
    }
    long size = ftell(f);
    if (size <= 0) {
        fclose(f);
        return 0;
    }
    rewind(f);

    font->data = (uint8_t *)malloc((size_t)size);
    if (!font->data) {
        fclose(f);
        return 0;
    }
    if (fread(font->data, 1, (size_t)size, f) != (size_t)size) {
        free(font->data);
        memset(font, 0, sizeof(*font));
        fclose(f);
        return 0;
    }
    fclose(f);

    if (!stbtt_InitFont(&font->info, font->data, stbtt_GetFontOffsetForIndex(font->data, 0))) {
        log_line("UI font is not a valid TrueType font: %s.", path);
        free(font->data);
        memset(font, 0, sizeof(*font));
        return 0;
    }

    font->size = (size_t)size;
    font->ready = 1;
    log_line("Loaded UI font: %s (%ld bytes)", display_path && *display_path ? display_path : path, size);
    return 1;
}

static int load_font(Font *font, const char *path) {
    char candidate[512];
    memset(font, 0, sizeof(*font));
    if (!path || !*path) {
        log_line("No UI font path was provided. Using bitmap fallback.");
        return 0;
    }

    if (has_suffix(path, ".ttf") || has_suffix(path, ".otf")) {
        if (load_truetype_font(font, path, path)) return 1;
    } else if (has_suffix(path, ".woff2")) {
        replace_extension(path, ".ttf", candidate, sizeof(candidate));
        if (file_exists(candidate) && load_truetype_font(font, candidate, path)) {
            log_line("WOFF2 UI font resolved through companion TrueType font: %s", candidate);
            return 1;
        }
        log_line("WOFF2 font was provided but no readable companion TTF was found: %s", candidate);
    } else {
        if (load_truetype_font(font, path, path)) return 1;
    }

    replace_extension(path, ".ttf", candidate, sizeof(candidate));
    if (file_exists(candidate) && load_truetype_font(font, candidate, path)) return 1;

    log_line("Using bitmap fallback because no native-loadable UI font was available for: %s", path);
    return 0;
}

static void close_font(Font *font) {
    if (font->data) free(font->data);
    memset(font, 0, sizeof(*font));
}

static int read_ppm_token(FILE *f, char *out, size_t out_size) {
    int c;
    size_t pos = 0;

    do {
        c = fgetc(f);
        if (c == '#') {
            while (c != '\n' && c != EOF) c = fgetc(f);
        }
    } while (c != EOF && (c == ' ' || c == '\n' || c == '\r' || c == '\t'));

    if (c == EOF) return 0;

    while (c != EOF && c != ' ' && c != '\n' && c != '\r' && c != '\t') {
        if (pos + 1 < out_size) out[pos++] = (char)c;
        c = fgetc(f);
    }
    out[pos] = 0;
    return 1;
}

static Image load_ppm_file(const char *path) {
    Image img = {0, 0, NULL};
    if (!path || !*path) return img;

    FILE *f = fopen(path, "rb");
    if (!f) {
        log_line("Logo PPM not found: %s", path);
        return img;
    }

    char tok[64];
    if (!read_ppm_token(f, tok, sizeof(tok)) || strcmp(tok, "P6") != 0) {
        fclose(f);
        return img;
    }
    if (!read_ppm_token(f, tok, sizeof(tok))) { fclose(f); return img; }
    img.width = atoi(tok);
    if (!read_ppm_token(f, tok, sizeof(tok))) { fclose(f); return img; }
    img.height = atoi(tok);
    if (!read_ppm_token(f, tok, sizeof(tok))) { fclose(f); return img; }
    int maxv = atoi(tok);
    if (img.width <= 0 || img.height <= 0 || maxv != 255) {
        fclose(f);
        img.width = img.height = 0;
        return img;
    }

    size_t size = (size_t)img.width * (size_t)img.height * 3;
    img.data = (uint8_t *)malloc(size);
    if (!img.data) {
        fclose(f);
        img.width = img.height = 0;
        return img;
    }
    if (fread(img.data, 1, size, f) != size) {
        free(img.data);
        img.data = NULL;
        img.width = img.height = 0;
    }
    fclose(f);
    return img;
}

static Image load_logo_image(const char *path) {
    Image img = {0, 0, NULL};
    char candidate[512];

    if (!path || !*path) return img;

    if (has_suffix(path, ".ppm")) {
        img = load_ppm_file(path);
        if (img.data) return img;
    }

    replace_basename_suffix(path, "_420.ppm", candidate, sizeof(candidate));
    if (file_exists(candidate)) {
        img = load_ppm_file(candidate);
        if (img.data) {
            log_line("WebP/bitmap logo resolved through native PPM companion: %s", candidate);
            return img;
        }
    }

    replace_extension(path, ".ppm", candidate, sizeof(candidate));
    if (file_exists(candidate)) {
        img = load_ppm_file(candidate);
        if (img.data) {
            log_line("Logo resolved through PPM companion: %s", candidate);
            return img;
        }
    }

    img = load_ppm_file(path);
    if (!img.data) log_line("Could not load native logo image for: %s", path);
    return img;
}

static const char *glyph(char c) {
    switch (c) {
        case 'A': return "01110100011000111111100011000110001";
        case 'B': return "11110100011000111110100011000111110";
        case 'C': return "01111100001000010000100001000001111";
        case 'D': return "11110100011000110001100011000111110";
        case 'E': return "11111100001000011110100001000011111";
        case 'F': return "11111100001000011110100001000010000";
        case 'G': return "01111100001000010111100011000101111";
        case 'H': return "10001100011000111111100011000110001";
        case 'I': return "11111001000010000100001000010011111";
        case 'J': return "00111000100001000010100101001001100";
        case 'K': return "10001100101010011000101001001010001";
        case 'L': return "10000100001000010000100001000011111";
        case 'M': return "10001110111010110101100011000110001";
        case 'N': return "10001110011010110011100011000110001";
        case 'O': return "01110100011000110001100011000101110";
        case 'P': return "11110100011000111110100001000010000";
        case 'Q': return "01110100011000110001101011001001101";
        case 'R': return "11110100011000111110101001001010001";
        case 'S': return "01111100001000001110000010000111110";
        case 'T': return "11111001000010000100001000010000100";
        case 'U': return "10001100011000110001100011000101110";
        case 'V': return "10001100011000110001100010101000100";
        case 'W': return "10001100011000110101101011010101010";
        case 'X': return "10001100010101000100010101000110001";
        case 'Y': return "10001100010101000100001000010000100";
        case 'Z': return "11111000010001000100010001000011111";
        case '0': return "01110100011001110101110011000101110";
        case '1': return "00100011000010000100001000010001110";
        case '2': return "01110100010000100010001000100011111";
        case '3': return "11110000010000101110000010000111110";
        case '4': return "00010001100101010010111110001000010";
        case '5': return "11111100001000011110000010000111110";
        case '6': return "00110010001000011110100011000101110";
        case '7': return "11111000010001000100010000100001000";
        case '8': return "01110100011000101110100011000101110";
        case '9': return "01110100011000101111000010001011100";
        case '-': return "00000000000000011111000000000000000";
        case '_': return "00000000000000000000000000000011111";
        case '.': return "00000000000000000000000000110001100";
        case ':': return "00000011000110000000011000110000000";
        case '/': return "00001000100001000100010000100010000";
        case '+': return "00000001000010011111001000010000000";
        case '[': return "01110010000100001000010000100001110";
        case ']': return "01110000100001000010000100001001110";
        default: return "00000000000000000000000000000000000";
    }
}

static int fb_open(Framebuffer *fb, const char *path) {
    memset(fb, 0, sizeof(*fb));
    fb->fd = open(path, O_RDWR);
    if (fb->fd < 0) {
        log_line("Could not open framebuffer %s: %s", path, strerror(errno));
        return -1;
    }

    if (ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->finfo) < 0 ||
        ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->vinfo) < 0) {
        log_line("Could not query framebuffer info: %s", strerror(errno));
        close(fb->fd);
        return -1;
    }

    fb->width = (int)fb->vinfo.xres;
    fb->height = (int)fb->vinfo.yres;
    fb->bpp = (int)fb->vinfo.bits_per_pixel;
    fb->line_length = (int)fb->finfo.line_length;
    long visible_size = (long)fb->line_length * (long)fb->height;
    long virtual_size = (long)fb->line_length * (long)fb->vinfo.yres_virtual;
    long reported_size = (long)fb->finfo.smem_len;
    fb->fb_size = (long)fb->finfo.smem_len;
    if (fb->fb_size <= 0) fb->fb_size = visible_size;
    if (fb->width <= 0 || fb->height <= 0 || !(fb->bpp == 16 || fb->bpp == 24 || fb->bpp == 32)) {
        log_line("Unsupported framebuffer mode: %dx%d %dbpp", fb->width, fb->height, fb->bpp);
        close(fb->fd);
        return -1;
    }

    log_line("Framebuffer info: %s %dx%d virt_y=%u line=%d bpp=%d smem_len=%lu visible=%ld virtual=%ld",
             path, fb->width, fb->height, fb->vinfo.yres_virtual, fb->line_length, fb->bpp,
             (unsigned long)fb->finfo.smem_len, visible_size, virtual_size);

    fb->fb = NULL;
    fb->fb_size = 0;
    fb->direct_write = 1;

    if (getenv("PILASRUNNER_FB_MMAP") && strcmp(getenv("PILASRUNNER_FB_MMAP"), "1") == 0) {
        long attempts[3] = {reported_size, visible_size, virtual_size};
        fb->fb = MAP_FAILED;
        for (int i = 0; i < 3; i++) {
            if (attempts[i] <= 0) continue;
            int duplicate = 0;
            for (int j = 0; j < i; j++) {
                if (attempts[j] == attempts[i]) duplicate = 1;
            }
            if (duplicate) continue;
            fb->fb = (uint8_t *)mmap(NULL, (size_t)attempts[i], PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
            if (fb->fb != MAP_FAILED) {
                fb->fb_size = attempts[i];
                fb->direct_write = 0;
                break;
            }
            log_line("Framebuffer mmap attempt length=%ld failed: %s", attempts[i], strerror(errno));
        }
        if (fb->fb == MAP_FAILED) {
            log_line("Could not mmap framebuffer after all length attempts. Falling back to pwrite framebuffer presentation.");
            fb->fb = NULL;
            fb->fb_size = 0;
            fb->direct_write = 1;
        } else if (fb->fb_size < visible_size) {
            log_line("Mapped framebuffer is smaller than visible frame: mapped=%ld visible=%ld", fb->fb_size, visible_size);
            munmap(fb->fb, (size_t)fb->fb_size);
            fb->fb = NULL;
            fb->fb_size = 0;
            fb->direct_write = 1;
        }
    } else {
        log_line("Using pwrite framebuffer presentation. Set PILASRUNNER_FB_MMAP=1 to opt into mmap.");
    }

    fb->rgb = (uint8_t *)malloc((size_t)fb->width * (size_t)fb->height * 3);
    if (!fb->rgb) {
        if (fb->fb && fb->fb != MAP_FAILED) munmap(fb->fb, (size_t)fb->fb_size);
        close(fb->fd);
        return -1;
    }

    log_line("Opened native framebuffer UI: %s %dx%d %dbpp", path, fb->width, fb->height, fb->bpp);
    return 0;
}

static void fb_close(Framebuffer *fb) {
    if (fb->rgb) free(fb->rgb);
    if (fb->fb && fb->fb != MAP_FAILED) munmap(fb->fb, (size_t)fb->fb_size);
    if (fb->fd >= 0) close(fb->fd);
}

static void rect(Framebuffer *fb, int x, int y, int w, int h, Color c) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > fb->width) w = fb->width - x;
    if (y + h > fb->height) h = fb->height - y;
    if (w <= 0 || h <= 0) return;

    for (int yy = y; yy < y + h; yy++) {
        uint8_t *p = fb->rgb + ((size_t)yy * (size_t)fb->width + (size_t)x) * 3;
        for (int xx = 0; xx < w; xx++) {
            *p++ = c.r;
            *p++ = c.g;
            *p++ = c.b;
        }
    }
}

static void outline(Framebuffer *fb, int x, int y, int w, int h, Color c, int t) {
    rect(fb, x, y, w, t, c);
    rect(fb, x, y + h - t, w, t, c);
    rect(fb, x, y, t, h, c);
    rect(fb, x + w - t, y, t, h, c);
}

static void blend_pixel(Framebuffer *fb, int x, int y, Color c, uint8_t alpha) {
    if (alpha == 0 || x < 0 || y < 0 || x >= fb->width || y >= fb->height) return;
    uint8_t *p = fb->rgb + ((size_t)y * (size_t)fb->width + (size_t)x) * 3;
    if (alpha == 255) {
        p[0] = c.r;
        p[1] = c.g;
        p[2] = c.b;
        return;
    }
    p[0] = (uint8_t)(((int)p[0] * (255 - alpha) + (int)c.r * alpha) / 255);
    p[1] = (uint8_t)(((int)p[1] * (255 - alpha) + (int)c.g * alpha) / 255);
    p[2] = (uint8_t)(((int)p[2] * (255 - alpha) + (int)c.b * alpha) / 255);
}

static unsigned int next_codepoint(const char **cursor) {
    const unsigned char *s = (const unsigned char *)*cursor;
    if (!s[0]) return 0;
    if (s[0] < 0x80) {
        *cursor += 1;
        return s[0];
    }
    if ((s[0] & 0xe0) == 0xc0 && (s[1] & 0xc0) == 0x80) {
        *cursor += 2;
        return ((unsigned int)(s[0] & 0x1f) << 6) | (unsigned int)(s[1] & 0x3f);
    }
    if ((s[0] & 0xf0) == 0xe0 && (s[1] & 0xc0) == 0x80 && (s[2] & 0xc0) == 0x80) {
        *cursor += 3;
        return ((unsigned int)(s[0] & 0x0f) << 12) |
               ((unsigned int)(s[1] & 0x3f) << 6) |
               (unsigned int)(s[2] & 0x3f);
    }
    if ((s[0] & 0xf8) == 0xf0 && (s[1] & 0xc0) == 0x80 && (s[2] & 0xc0) == 0x80 && (s[3] & 0xc0) == 0x80) {
        *cursor += 4;
        return ((unsigned int)(s[0] & 0x07) << 18) |
               ((unsigned int)(s[1] & 0x3f) << 12) |
               ((unsigned int)(s[2] & 0x3f) << 6) |
               (unsigned int)(s[3] & 0x3f);
    }
    *cursor += 1;
    return '?';
}

static int font_text_width(const char *text, int px) {
    if (!ui_font.ready || !text || !*text) return 0;
    float scale = stbtt_ScaleForPixelHeight(&ui_font.info, (float)px);
    float width = 0.0f;
    unsigned int prev = 0;
    const char *p = text;
    while (*p) {
        unsigned int cp = next_codepoint(&p);
        int advance = 0;
        int lsb = 0;
        if (prev) width += (float)stbtt_GetCodepointKernAdvance(&ui_font.info, (int)prev, (int)cp) * scale;
        stbtt_GetCodepointHMetrics(&ui_font.info, (int)cp, &advance, &lsb);
        width += (float)advance * scale;
        prev = cp;
    }
    return (int)(width + 0.5f);
}

static void fit_text(const char *text, int px, int max_w, char *out, size_t out_size) {
    if (!out || out_size == 0) return;
    out[0] = 0;
    if (!text) return;
    snprintf(out, out_size, "%s", text);
    if (max_w <= 0 || !ui_font.ready || font_text_width(out, px) <= max_w) return;

    const char *suffix = "..";
    size_t suffix_len = strlen(suffix);
    size_t len = strlen(out);
    while (len > suffix_len + 1 && font_text_width(out, px) > max_w) {
        len--;
        while (len > 0 && ((unsigned char)out[len] & 0xc0) == 0x80) len--;
        out[len] = 0;
        if (len + suffix_len < out_size) {
            strcat(out, suffix);
        }
    }
}

static int draw_text_bitmap(Framebuffer *fb, int x, int y, const char *text, Color c, int px, int max_w) {
    int cx = x;
    int scale = px / 7;
    if (scale < 1) scale = 1;
    for (const char *p = text; *p; p++) {
        char ch = *p;
        if (ch >= 'a' && ch <= 'z') ch -= 32;
        if (max_w > 0 && cx + 5 * scale > x + max_w) break;
        const char *g = glyph(ch);
        for (int row = 0; row < 7; row++) {
            for (int col = 0; col < 5; col++) {
                if (g[row * 5 + col] == '1') {
                    rect(fb, cx + col * scale, y + row * scale, scale, scale, c);
                }
            }
        }
        cx += 6 * scale;
    }
    return cx;
}

static int draw_text(Framebuffer *fb, int x, int y, const char *text, Color c, int px, int max_w) {
    if (!text || !*text) return x;
    if (!ui_font.ready) return draw_text_bitmap(fb, x, y, text, c, px, max_w);

    char fitted[256];
    fit_text(text, px, max_w, fitted, sizeof(fitted));

    float scale = stbtt_ScaleForPixelHeight(&ui_font.info, (float)px);
    int ascent = 0, descent = 0, line_gap = 0;
    stbtt_GetFontVMetrics(&ui_font.info, &ascent, &descent, &line_gap);
    int baseline = y + (int)((float)ascent * scale + 0.5f);
    float cx = (float)x;
    unsigned int prev = 0;
    const char *p = fitted;

    while (*p) {
        unsigned int cp = next_codepoint(&p);
        if (max_w > 0 && (int)cx >= x + max_w) break;
        if (prev) cx += (float)stbtt_GetCodepointKernAdvance(&ui_font.info, (int)prev, (int)cp) * scale;

        int advance = 0, lsb = 0;
        stbtt_GetCodepointHMetrics(&ui_font.info, (int)cp, &advance, &lsb);

        int w = 0, h = 0, xoff = 0, yoff = 0;
        unsigned char *bitmap = stbtt_GetCodepointBitmap(&ui_font.info, scale, scale, (int)cp, &w, &h, &xoff, &yoff);
        if (bitmap) {
            int gx = (int)(cx + 0.5f) + xoff;
            int gy = baseline + yoff;
            for (int yy = 0; yy < h; yy++) {
                for (int xx = 0; xx < w; xx++) {
                    int px_pos = gx + xx;
                    int py_pos = gy + yy;
                    if (max_w > 0 && px_pos >= x + max_w) continue;
                    blend_pixel(fb, px_pos, py_pos, c, bitmap[yy * w + xx]);
                }
            }
            stbtt_FreeBitmap(bitmap, NULL);
        }

        cx += (float)advance * scale;
        prev = cp;
    }
    return (int)(cx + 0.5f);
}

static void blit_ppm(Framebuffer *fb, int x, int y, const Image *img, int scale) {
    if (!img || !img->data || scale <= 0) return;
    for (int yy = 0; yy < img->height; yy++) {
        for (int xx = 0; xx < img->width; xx++) {
            const uint8_t *p = img->data + ((size_t)yy * (size_t)img->width + (size_t)xx) * 3;
            if (p[0] == 6 && p[1] == 17 && p[2] == 10) continue;
            Color c = {p[0], p[1], p[2]};
            rect(fb, x + xx * scale, y + yy * scale, scale, scale, c);
        }
    }
}

static void blit_ppm_fit(Framebuffer *fb, int x, int y, const Image *img, int target_w, int target_h) {
    if (!img || !img->data || target_w <= 0 || target_h <= 0) return;
    for (int yy = 0; yy < target_h; yy++) {
        int src_y = yy * img->height / target_h;
        for (int xx = 0; xx < target_w; xx++) {
            int src_x = xx * img->width / target_w;
            const uint8_t *p = img->data + ((size_t)src_y * (size_t)img->width + (size_t)src_x) * 3;
            if (p[0] == 6 && p[1] == 17 && p[2] == 10) continue;
            blend_pixel(fb, x + xx, y + yy, (Color){p[0], p[1], p[2]}, 255);
        }
    }
}

static uint32_t pack_component(uint8_t v, struct fb_bitfield field) {
    if (field.length == 0) return 0;
    uint32_t max = (1u << field.length) - 1u;
    return ((uint32_t)v * max / 255u) << field.offset;
}

static void present(Framebuffer *fb) {
    uint8_t *direct_row = NULL;
    if (fb->direct_write) {
        direct_row = (uint8_t *)malloc((size_t)fb->line_length);
        if (!direct_row) return;
    }

    for (int y = 0; y < fb->height; y++) {
        uint8_t *dst = fb->direct_write ? direct_row : fb->fb + (size_t)y * (size_t)fb->line_length;
        const uint8_t *src = fb->rgb + (size_t)y * (size_t)fb->width * 3;
        if (fb->direct_write) memset(direct_row, 0, (size_t)fb->line_length);
        for (int x = 0; x < fb->width; x++) {
            uint8_t r = src[0], g = src[1], b = src[2];
            src += 3;
            if (fb->bpp == 16) {
                uint16_t px = (uint16_t)(pack_component(r, fb->vinfo.red) |
                                         pack_component(g, fb->vinfo.green) |
                                         pack_component(b, fb->vinfo.blue));
                dst[0] = (uint8_t)(px & 0xff);
                dst[1] = (uint8_t)(px >> 8);
                dst += 2;
            } else if (fb->bpp == 24) {
                dst[0] = b; dst[1] = g; dst[2] = r; dst += 3;
            } else {
                uint32_t px = pack_component(r, fb->vinfo.red) |
                              pack_component(g, fb->vinfo.green) |
                              pack_component(b, fb->vinfo.blue);
                if (fb->vinfo.transp.length) px |= pack_component(255, fb->vinfo.transp);
                dst[0] = (uint8_t)(px & 0xff);
                dst[1] = (uint8_t)((px >> 8) & 0xff);
                dst[2] = (uint8_t)((px >> 16) & 0xff);
                dst[3] = (uint8_t)((px >> 24) & 0xff);
                dst += 4;
            }
        }
        if (fb->direct_write) {
            ssize_t ignored = pwrite(fb->fd, direct_row, (size_t)fb->line_length, (off_t)y * (off_t)fb->line_length);
            (void)ignored;
        }
    }

    if (direct_row) free(direct_row);
}

static int scaled(int value, double s) {
    int out = (int)((double)value * s);
    return out < 1 ? 1 : out;
}

static void render_ui(Framebuffer *fb, const Game *games, int count, int selected,
                      const char *runtime, const char *loader, const Image *logo) {
    int margin = clamp_int(fb->width / 42, 10, 24);
    int gap = clamp_int(fb->width / 90, 8, 18);
    int top_h = clamp_int(fb->height / 5, 74, 104);
    int footer_h = clamp_int(fb->height / 11, 38, 54);
    int title_px = clamp_int(fb->height / 16, 24, 38);
    int body_px = clamp_int(fb->height / 24, 16, 24);
    int small_px = clamp_int(fb->height / 31, 13, 18);
    int tiny_px = clamp_int(fb->height / 38, 11, 15);
    int two_col = fb->width >= 560 && fb->height >= 360;
    char runtime_line[128];
    snprintf(runtime_line, sizeof(runtime_line), "gmloader-next %s", runtime);

    rect(fb, 0, 0, fb->width, fb->height, C_BG);
    rect(fb, 0, 0, fb->width, top_h + margin / 2, (Color){10, 18, 13});
    outline(fb, margin / 2, margin / 2, fb->width - margin, fb->height - margin, (Color){66, 88, 34}, 2);

    int top_x = margin, top_y = margin;
    int top_w = fb->width - margin * 2;
    rect(fb, top_x, top_y, top_w, top_h, (Color){6, 17, 10});
    outline(fb, top_x, top_y, top_w, top_h, (Color){64, 90, 31}, 2);

    int logo_h = top_h - 16;
    int logo_w = logo && logo->height ? logo->width * logo_h / logo->height : 0;
    logo_w = clamp_int(logo_w, 0, clamp_int(fb->width / 5, 64, 132));
    if (logo && logo->data && logo_w > 0) blit_ppm_fit(fb, top_x + 10, top_y + 8, logo, logo_w, logo_h);
    int title_x = top_x + 20 + logo_w;
    int meta_w = clamp_int(fb->width / 5, 96, 184);
    draw_text(fb, title_x, top_y + clamp_int(top_h / 4, 12, 22), "YoYo Pilas Runner", C_LIME, title_px, top_w - logo_w - meta_w - 34);
    draw_text(fb, title_x, top_y + clamp_int(top_h / 2 + 8, 36, 58), "GameMaker ports launcher", C_MUTED, small_px, top_w - logo_w - meta_w - 34);

    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char clock_text[16];
    snprintf(clock_text, sizeof(clock_text), "%02d:%02d", tmv.tm_hour, tmv.tm_min);
    draw_text(fb, top_x + top_w - meta_w, top_y + top_h / 2 - body_px, clock_text, C_CYAN, body_px, meta_w);
    draw_text(fb, top_x + top_w - meta_w, top_y + top_h / 2 + 8, "PortMaster", C_MUTED, tiny_px, meta_w);

    int content_y = top_y + top_h + gap;
    int content_h = fb->height - content_y - footer_h - margin;
    int left_x = margin, left_y = content_y;
    int left_w = two_col ? clamp_int((fb->width - margin * 2 - gap) * 43 / 100, 236, 430) : fb->width - margin * 2;
    int left_h = content_h;
    int right_x = two_col ? left_x + left_w + gap : left_x;
    int right_y = two_col ? left_y : left_y + content_h * 58 / 100 + gap;
    int right_w = two_col ? fb->width - right_x - margin : left_w;
    int right_h = two_col ? left_h : fb->height - right_y - footer_h - margin;
    if (!two_col) left_h = right_y - left_y - gap;

    rect(fb, left_x, left_y, left_w, left_h, C_PANEL);
    outline(fb, left_x, left_y, left_w, left_h, (Color){52, 88, 35}, 2);
    rect(fb, right_x, right_y, right_w, right_h, C_PANEL);
    outline(fb, right_x, right_y, right_w, right_h, (Color){52, 88, 35}, 2);

    char count_line[48];
    snprintf(count_line, sizeof(count_line), "%d game%s", count, count == 1 ? "" : "s");
    draw_text(fb, left_x + 14, left_y + 12, "Games", C_LIME, body_px, left_w / 2);
    draw_text(fb, left_x + left_w / 2, left_y + 14, count_line, C_MUTED, small_px, left_w / 2 - 16);

    int row_h = clamp_int((left_h - 52) / 5, 44, 62);
    int row_gap = clamp_int(fb->height / 120, 4, 8);
    int page_size = (left_h - 48) / (row_h + row_gap);
    if (page_size < 3) page_size = 3;
    int start = selected - page_size / 2;
    if (start < 0) start = 0;
    if (start + page_size > count) start = count - page_size;
    if (start < 0) start = 0;
    int end = start + page_size;
    if (end > count) end = count;

    int row_y = left_y + 42;
    for (int i = start; i < end; i++) {
        int is_sel = i == selected;
        rect(fb, left_x + 10, row_y, left_w - 20, row_h, is_sel ? (Color){47, 70, 24} : (Color){9, 20, 13});
        if (is_sel) outline(fb, left_x + 10, row_y, left_w - 20, row_h, C_LIME, 2);
        int icon = clamp_int(row_h - 16, 28, 42);
        int tx = left_x + 18, ty = row_y + (row_h - icon) / 2;
        rect(fb, tx, ty, icon, icon, is_sel ? C_LIME : C_GREEN);
        char initial[2] = {games[i].name[0], 0};
        draw_text(fb, tx + icon / 2 - small_px / 3, ty + icon / 2 - small_px / 2, initial, C_DARK, small_px, icon);
        int text_x = tx + icon + 10;
        int tag_w = clamp_int(left_w / 5, 44, 74);
        draw_text(fb, text_x, row_y + 8, games[i].name, C_INK, small_px, left_w - (text_x - left_x) - tag_w - 20);
        draw_text(fb, text_x, row_y + row_h - tiny_px - 8, runtime_line, C_MUTED, tiny_px, left_w - (text_x - left_x) - tag_w - 20);
        draw_text(fb, left_x + left_w - tag_w - 12, row_y + row_h / 2 - tiny_px / 2, runtime, C_CYAN, tiny_px, tag_w);
        row_y += row_h + row_gap;
    }

    const Game *g = &games[selected];
    int stage_x = right_x + 14, stage_y = right_y + 14;
    int stage_w = right_w - 28, stage_h = clamp_int(right_h * 44 / 100, 128, 202);
    rect(fb, stage_x, stage_y, stage_w, stage_h, (Color){3, 11, 7});
    outline(fb, stage_x, stage_y, stage_w, stage_h, (Color){64, 90, 31}, 2);
    int cover = clamp_int(stage_h - 62, 58, 94);
    rect(fb, stage_x + 16, stage_y + stage_h - cover - 16, cover, cover, C_LIME);
    char initial[2] = {g->name[0], 0};
    draw_text(fb, stage_x + 16 + cover / 2 - body_px / 3, stage_y + stage_h - cover / 2 - body_px / 2, initial, C_DARK, title_px, cover);
    int detail_x = stage_x + cover + 28;
    int detail_w = stage_w - (detail_x - stage_x) - 14;
    draw_text(fb, detail_x, stage_y + 18, g->kind, C_CYAN, tiny_px, detail_w);
    draw_text(fb, detail_x, stage_y + 42, g->name, C_INK, title_px, detail_w);
    draw_text(fb, detail_x, stage_y + stage_h - 54, runtime_line, C_MUTED, small_px, detail_w);
    draw_text(fb, detail_x, stage_y + stage_h - 30, "controls mapped", C_MUTED, tiny_px, detail_w);

    int info_y = stage_y + stage_h + gap;
    int info_h = clamp_int(right_h / 5, 58, 80);
    int stat_w = (stage_w - gap * 2) / 3;
    const char *labels[3] = {"Arch", "Saves", "Input"};
    const char *values[3] = {runtime, "Ready", "Mapped"};
    for (int i = 0; i < 3; i++) {
        int bx = stage_x + i * (stat_w + gap);
        rect(fb, bx, info_y, stat_w, info_h, (Color){7, 23, 18});
        outline(fb, bx, info_y, stat_w, info_h, (Color){28, 66, 52}, 2);
        draw_text(fb, bx + 10, info_y + 8, labels[i], C_MUTED, tiny_px, stat_w - 20);
        draw_text(fb, bx + 10, info_y + info_h / 2, values[i], i == 0 ? C_CYAN : C_LIME, small_px, stat_w - 20);
    }

    int action_y = info_y + info_h + gap;
    int action_h = clamp_int(right_h / 7, 42, 58);
    rect(fb, stage_x, action_y, stage_w, action_h, C_LIME);
    draw_text(fb, stage_x + 16, action_y + action_h / 2 - body_px / 2, "A / B / Start  Launch", C_DARK, body_px, stage_w - 32);

    int help_y = action_y + action_h + gap;
    int help_h = right_y + right_h - help_y - 14;
    if (help_h > 28) {
        rect(fb, stage_x, help_y, stage_w, help_h, (Color){9, 20, 13});
        outline(fb, stage_x, help_y, stage_w, help_h, (Color){52, 88, 35}, 2);
        draw_text(fb, stage_x + 12, help_y + 10, "D-Pad moves   Select exits", C_MUTED, small_px, stage_w - 24);
        if (help_h > 58) draw_text(fb, stage_x + 12, help_y + 34, "Select + Start closes gameplay", C_MUTED, tiny_px, stage_w - 24);
    }

    int footer_y = fb->height - footer_h - margin / 2;
    rect(fb, margin, footer_y, fb->width - margin * 2, footer_h, (Color){6, 17, 10});
    draw_text(fb, margin + 12, footer_y + footer_h / 2 - small_px / 2, "Always opens this UI before launching a game", C_MUTED, small_px, fb->width - margin * 2 - 24);

    present(fb);
}

static int open_inputs(InputDevice *devices, int *count) {
    DIR *dir = opendir("/dev/input");
    if (!dir) {
        log_line("Could not open /dev/input: %s", strerror(errno));
        return -1;
    }

    struct dirent *ent;
    while ((ent = readdir(dir)) && *count < MAX_DEVICES) {
        if (!starts_with(ent->d_name, "event")) continue;
        char path[128];
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        int exists = 0;
        for (int i = 0; i < *count; i++) {
            if (strcmp(devices[i].path, path) == 0) exists = 1;
        }
        if (exists) continue;
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            log_line("Could not open input %s: %s", path, strerror(errno));
            continue;
        }
        devices[*count].fd = fd;
        snprintf(devices[*count].path, sizeof(devices[*count].path), "%s", path);
        (*count)++;
        log_line("Native UI watching %s", path);
    }
    closedir(dir);
    return 0;
}

static int event_action(uint16_t type, uint16_t code, int32_t value) {
    if (type == EV_KEY) {
        if (!(value == 1 || value == 2)) return 0;
        if (code == KEY_UP || code == BTN_DPAD_UP || code == BTN_TRIGGER_HAPPY3) return -1;
        if (code == KEY_DOWN || code == BTN_DPAD_DOWN || code == BTN_TRIGGER_HAPPY4) return 1;
        if (code == KEY_ENTER || code == KEY_SPACE || code == BTN_A || code == BTN_B ||
            code == BTN_X || code == BTN_Y || code == BTN_START || code == BTN_MODE ||
            code == KEY_OK || code == BTN_TRIGGER_HAPPY1) return 2;
        if (code == KEY_ESC || code == KEY_BACK || code == BTN_SELECT || code == BTN_TRIGGER_HAPPY2) return 3;
    }
    if (type == EV_ABS) {
        if (code == ABS_HAT0Y) {
            if (value < 0) return -1;
            if (value > 0) return 1;
        }
        if (code == ABS_Y) {
            if (value < -16000) return -1;
            if (value > 16000) return 1;
        }
    }
    return 0;
}

static void write_selection(const char *path, int selected) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%d\n", selected);
    fclose(f);
}

static const char *arg_value(int argc, char **argv, const char *name, const char *fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return fallback;
}

int main(int argc, char **argv) {
    const char *games_path = arg_value(argc, argv, "--games", "");
    const char *selection_path = arg_value(argc, argv, "--selection", "");
    const char *runtime = arg_value(argc, argv, "--runtime", "unknown");
    const char *loader = arg_value(argc, argv, "--loader", "next");
    const char *logo_path = arg_value(argc, argv, "--logo", "");
    const char *font_path = arg_value(argc, argv, "--font", "");
    const char *fb_path = arg_value(argc, argv, "--fb", getenv("PILASRUNNER_FB") ? getenv("PILASRUNNER_FB") : "/dev/fb0");
    log_path = arg_value(argc, argv, "--log", "");

    if (!games_path[0] || !selection_path[0]) {
        fprintf(stderr, "Usage: pilasrunner-ui --games FILE --selection FILE [--runtime ARCH] [--loader MODE] [--font TTF]\n");
        return 1;
    }

    Game games[MAX_GAMES];
    int game_count = load_games(games_path, games, MAX_GAMES);
    if (game_count <= 0) return 1;

    load_font(&ui_font, font_path);

    Framebuffer fb;
    if (fb_open(&fb, fb_path) != 0) {
        close_font(&ui_font);
        return 3;
    }

    Image logo = load_logo_image(logo_path);
    InputDevice devices[MAX_DEVICES];
    int device_count = 0;
    memset(devices, 0, sizeof(devices));
    for (int i = 0; i < MAX_DEVICES; i++) devices[i].fd = -1;
    open_inputs(devices, &device_count);
    if (device_count <= 0) {
        log_line("No input devices available for native UI.");
        fb_close(&fb);
        if (logo.data) free(logo.data);
        close_font(&ui_font);
        return 3;
    }

    int selected = 0;
    time_t next_rescan = time(NULL) + 2;
    render_ui(&fb, games, game_count, selected, runtime, loader, &logo);

    for (;;) {
        time_t now = time(NULL);
        if (now >= next_rescan) {
            open_inputs(devices, &device_count);
            next_rescan = now + 2;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = -1;
        for (int i = 0; i < device_count; i++) {
            if (devices[i].fd >= 0) {
                FD_SET(devices[i].fd, &rfds);
                if (devices[i].fd > maxfd) maxfd = devices[i].fd;
            }
        }
        if (maxfd < 0) {
            fb_close(&fb);
            if (logo.data) free(logo.data);
            close_font(&ui_font);
            return 3;
        }

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 250000;
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0 && errno == EINTR) continue;
        if (ret < 0) break;
        if (ret == 0) continue;

        int action = 0;
        for (int i = 0; i < device_count; i++) {
            int fd = devices[i].fd;
            if (fd < 0 || !FD_ISSET(fd, &rfds)) continue;
            struct input_event ev;
            while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
                action = event_action(ev.type, ev.code, ev.value);
                if (action) {
                    log_line("Input action=%d type=%u code=%u value=%d", action, ev.type, ev.code, ev.value);
                    break;
                }
            }
            if (action) break;
        }

        if (action == -1) {
            selected = (selected + game_count - 1) % game_count;
            render_ui(&fb, games, game_count, selected, runtime, loader, &logo);
        } else if (action == 1) {
            selected = (selected + 1) % game_count;
            render_ui(&fb, games, game_count, selected, runtime, loader, &logo);
        } else if (action == 2) {
            write_selection(selection_path, selected);
            fb_close(&fb);
            for (int i = 0; i < device_count; i++) if (devices[i].fd >= 0) close(devices[i].fd);
            if (logo.data) free(logo.data);
            close_font(&ui_font);
            return 0;
        } else if (action == 3) {
            fb_close(&fb);
            for (int i = 0; i < device_count; i++) if (devices[i].fd >= 0) close(devices[i].fd);
            if (logo.data) free(logo.data);
            close_font(&ui_font);
            return 2;
        }
    }

    fb_close(&fb);
    for (int i = 0; i < device_count; i++) if (devices[i].fd >= 0) close(devices[i].fd);
    if (logo.data) free(logo.data);
    close_font(&ui_font);
    return 3;
}
