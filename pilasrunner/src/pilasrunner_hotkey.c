#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#define MAX_DEVICES 64

typedef struct {
    int fd;
    char path[128];
} InputDevice;

static const int SELECT_CODES[] = {1, 139, 158, 174, 314, 353, 704};
static const int START_CODES[] = {28, 172, 315, 316, 352, 705};
static const int SELECT_START_PAIR_A = 704;
static const int SELECT_START_PAIR_B = 705;

static const char *log_path = NULL;

static void log_line(const char *fmt, ...) {
    if (!log_path || !*log_path) return;
    FILE *f = fopen(log_path, "a");
    if (!f) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d] [HOTKEY_C] ",
            tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static const char *arg_value(int argc, char **argv, const char *name, const char *fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return fallback;
}

static int pid_alive(pid_t pid) {
    if (pid <= 0) return 0;
    if (kill(pid, 0) == 0) return 1;
    return errno == EPERM;
}

static int contains_code(const int *codes, size_t count, int code) {
    for (size_t i = 0; i < count; i++) {
        if (codes[i] == code) return 1;
    }
    return 0;
}

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
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
        log_line("Watching input device %s.", path);
    }
    closedir(dir);
    return 0;
}

static void write_flag(const char *flag_path) {
    if (!flag_path || !*flag_path) return;
    FILE *f = fopen(flag_path, "w");
    if (!f) return;
    fprintf(f, "select_start\n");
    fclose(f);
}

static void force_kill(pid_t pid, const char *flag_path) {
    write_flag(flag_path);
    log_line("Select + Start detected. Sending immediate SIGKILL to pid %ld.", (long)pid);
    if (getpgid(pid) == pid) {
        log_line("Target pid %ld is a process-group leader. Sending group SIGKILL too.", (long)pid);
        if (kill(-pid, SIGKILL) != 0) {
            log_line("Process-group SIGKILL failed for pgid %ld: %s", (long)pid, strerror(errno));
        }
    }
    if (kill(pid, SIGKILL) != 0) {
        log_line("SIGKILL failed for pid %ld: %s", (long)pid, strerror(errno));
    }
}

int main(int argc, char **argv) {
    pid_t pid = (pid_t)atoi(arg_value(argc, argv, "--pid", "0"));
    const char *flag_path = arg_value(argc, argv, "--flag", "");
    log_path = arg_value(argc, argv, "--log", "");

    if (pid <= 0 || !flag_path[0]) {
        fprintf(stderr, "Usage: pilasrunner-hotkey --pid PID --flag FILE --log FILE\n");
        return 1;
    }

    InputDevice devices[MAX_DEVICES];
    int device_count = 0;
    memset(devices, 0, sizeof(devices));
    for (int i = 0; i < MAX_DEVICES; i++) devices[i].fd = -1;

    int pressed_select = 0;
    int pressed_start = 0;
    int pressed_pair_a = 0;
    int pressed_pair_b = 0;
    time_t next_rescan = 0;
    time_t arm_at = time(NULL) + 1;
    int armed = 0;
    int debug_budget = 120;

    log_line("Native hotkey watcher started for pid %ld. Select codes include 704; start codes include 705. Arming after launch input is released.", (long)pid);

    while (pid_alive(pid)) {
        time_t now = time(NULL);
        if (now >= next_rescan) {
            open_inputs(devices, &device_count);
            next_rescan = now + 2;
        }

        if (!armed && now >= arm_at && !pressed_select && !pressed_start && !pressed_pair_a && !pressed_pair_b) {
            armed = 1;
            log_line("Native hotkey watcher armed for pid %ld.", (long)pid);
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
            usleep(250000);
            continue;
        }

        struct timeval tv = {0, 250000};
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0 && errno == EINTR) continue;
        if (ret <= 0) continue;

        for (int i = 0; i < device_count; i++) {
            int fd = devices[i].fd;
            if (fd < 0 || !FD_ISSET(fd, &rfds)) continue;

            struct input_event ev;
            while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
                if (ev.type != EV_KEY) continue;
                if (!(ev.value == 0 || ev.value == 1 || ev.value == 2)) continue;

                if (debug_budget > 0) {
                    log_line("EV_KEY device=%s code=%u value=%d", devices[i].path, ev.code, ev.value);
                    debug_budget--;
                }

                int down = ev.value == 1 || ev.value == 2;
                if (contains_code(SELECT_CODES, sizeof(SELECT_CODES) / sizeof(SELECT_CODES[0]), ev.code)) pressed_select = down;
                if (contains_code(START_CODES, sizeof(START_CODES) / sizeof(START_CODES[0]), ev.code)) pressed_start = down;
                if (ev.code == SELECT_START_PAIR_A) pressed_pair_a = down;
                if (ev.code == SELECT_START_PAIR_B) pressed_pair_b = down;

                now = time(NULL);
                if (!armed) {
                    if (now >= arm_at && !pressed_select && !pressed_start && !pressed_pair_a && !pressed_pair_b) {
                        armed = 1;
                        log_line("Native hotkey watcher armed for pid %ld.", (long)pid);
                    }
                    continue;
                }

                if ((pressed_select && pressed_start) || (pressed_pair_a && pressed_pair_b)) {
                    force_kill(pid, flag_path);
                    for (int j = 0; j < device_count; j++) {
                        if (devices[j].fd >= 0) close(devices[j].fd);
                    }
                    return 0;
                }
            }
        }
    }

    log_line("Target pid %ld is no longer alive. Native hotkey watcher exiting.", (long)pid);
    for (int i = 0; i < device_count; i++) {
        if (devices[i].fd >= 0) close(devices[i].fd);
    }
    return 0;
}
