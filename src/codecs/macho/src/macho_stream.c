/**
 * @file macho_stream.c
 * @brief Stream constructors + free.  Trimmed to just what chalk needs.
 */

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "macho_stream.h"

macho_stream_t *
macho_stream_new(n00b_buffer_t *buf)
{
    if (!buf) {
        return NULL;
    }

    macho_stream_t *s = (macho_stream_t *)calloc(1, sizeof(*s));

    if (!s) {
        return NULL;
    }

    s->buf         = buf;
    s->pos         = 0;
    s->swap_endian = false;
    return s;
}

n00b_result_t(macho_stream_t *)
macho_stream_from_file(const char *path)
{
    int fd = open(path, O_RDONLY);

    if (fd < 0) {
        return n00b_result_err(macho_stream_t *, errno);
    }

    struct stat st;

    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return n00b_result_err(macho_stream_t *, e);
    }

    size_t         file_size = (size_t)st.st_size;
    n00b_buffer_t *buf       = n00b_buffer_new((int64_t)file_size);

    if (!buf) {
        close(fd);
        return n00b_result_err(macho_stream_t *, ENOMEM);
    }

    if (file_size > 0) {
        ssize_t total = 0;

        while ((size_t)total < file_size) {
            ssize_t n = read(fd, buf->data + total,
                             file_size - (size_t)total);

            if (n < 0) {
                if (errno == EINTR) {
                    continue;
                }

                int e = errno;
                close(fd);
                n00b_buffer_destroy(buf);
                return n00b_result_err(macho_stream_t *, e);
            }

            if (n == 0) {
                break;
            }

            total += n;
        }

        buf->byte_len = (size_t)total;
    }

    close(fd);

    macho_stream_t *s = macho_stream_new(buf);

    if (!s) {
        n00b_buffer_destroy(buf);
        return n00b_result_err(macho_stream_t *, ENOMEM);
    }

    return n00b_result_ok(macho_stream_t *, s);
}

void
macho_stream_free(macho_stream_t *s)
{
    if (!s) {
        return;
    }

    n00b_buffer_destroy(s->buf);
    free(s);
}
