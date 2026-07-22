#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int read_all(int fd, uint8_t *buffer, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t got = read(fd, buffer + done, size - done);
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (got == 0) {
            return -1;
        }
        done += (size_t)got;
    }
    return 0;
}

static int write_all(int fd, const uint8_t *buffer, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t wrote = write(fd, buffer + done, size - done);
        if (wrote < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        done += (size_t)wrote;
    }
    return 0;
}

static int replace_all_padded(uint8_t *buffer, size_t size, const char *from, const char *to) {
    const size_t from_size = strlen(from) + 1;
    const size_t to_size = strlen(to) + 1;
    int count = 0;

    if (to_size > from_size) {
        return -1;
    }

    uint8_t *cursor = buffer;
    size_t left = size;
    while (left >= from_size) {
        uint8_t *where = (uint8_t *)memmem(cursor, left, from, from_size);
        if (!where) {
            break;
        }
        memset(where, 0, from_size);
        memcpy(where, to, to_size);
        count++;

        size_t consumed = (size_t)(where - cursor) + from_size;
        cursor += consumed;
        left -= consumed;
    }

    return count;
}

int main(int argc, char **argv) {
    static const char needed_from[] = "libandroid.so";
    static const char needed_to[] = "libopensle.so";
    static const char dlopen_from[] = "libOpenSLES.so";
    static const char dlopen_to[] = "libEGL.so";

    if (argc != 2) {
        fprintf(stderr, "usage: %s <libyoyo.so>\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open failed for %s: %s\n", path, strerror(errno));
        return 1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        fprintf(stderr, "stat failed for %s: %s\n", path, strerror(errno));
        close(fd);
        return 1;
    }

    uint8_t *buffer = (uint8_t *)malloc((size_t)st.st_size);
    if (!buffer) {
        fprintf(stderr, "allocation failed for %s\n", path);
        close(fd);
        return 1;
    }

    if (read_all(fd, buffer, (size_t)st.st_size) != 0) {
        fprintf(stderr, "read failed for %s: %s\n", path, strerror(errno));
        free(buffer);
        close(fd);
        return 1;
    }

    if (memmem(buffer, (size_t)st.st_size, needed_to, sizeof(needed_to)) == NULL &&
        memmem(buffer, (size_t)st.st_size, needed_from, sizeof(needed_from)) == NULL) {
        fprintf(stderr, "libandroid.so dependency string was not found in %s\n", path);
        free(buffer);
        close(fd);
        return 3;
    }

    int needed_count = replace_all_padded(buffer, (size_t)st.st_size, needed_from, needed_to);
    int dlopen_count = replace_all_padded(buffer, (size_t)st.st_size, dlopen_from, dlopen_to);
    if (needed_count < 0 || dlopen_count < 0) {
        fprintf(stderr, "internal replacement size error while patching %s\n", path);
        free(buffer);
        close(fd);
        return 1;
    }

    if (lseek(fd, 0, SEEK_SET) < 0 || write_all(fd, buffer, (size_t)st.st_size) != 0) {
        fprintf(stderr, "write failed for %s: %s\n", path, strerror(errno));
        free(buffer);
        close(fd);
        return 1;
    }

    free(buffer);
    close(fd);
    fprintf(stderr, "patched %s: dependency replacements=%d, dlopen replacements=%d\n",
            path, needed_count, dlopen_count);
    return 0;
}
