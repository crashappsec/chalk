#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum resolution_state { RESOLUTION_PENDING, RESOLUTION_DONE, RESOLUTION_ABANDONED };

struct resolution {
    pthread_mutex_t lock;
    char *host;
    char *service;
    char *addresses;
    int pipefd[2];
    enum resolution_state state;
    int status;
};

static int64_t monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void dispose_resolution(struct resolution *task) {
    close(task->pipefd[0]);
    close(task->pipefd[1]);
    pthread_mutex_destroy(&task->lock);
    free(task->host);
    free(task->service);
    free(task->addresses);
    free(task);
}

static void *resolve_worker(void *data) {
    struct resolution *task = data;
    struct addrinfo hints = {0}, *results = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int status = getaddrinfo(task->host, task->service, &hints, &results);
    char *addresses = NULL;
    size_t used = 0;
    int count = 0;
    if (status == 0) {
        for (struct addrinfo *item = results; item && count < 64; item = item->ai_next) {
            char address[1025];
            if (getnameinfo(item->ai_addr, item->ai_addrlen, address, sizeof(address),
                            NULL, 0, NI_NUMERICHOST) != 0) continue;
            size_t length = strlen(address);
            char *grown = realloc(addresses, used + length + 2);
            if (!grown) {
                free(addresses);
                addresses = NULL;
                break;
            }
            addresses = grown;
            memcpy(addresses + used, address, length);
            used += length;
            addresses[used++] = '\n';
            addresses[used] = '\0';
            count++;
        }
        freeaddrinfo(results);
    }
    pthread_mutex_lock(&task->lock);
    if (task->state == RESOLUTION_ABANDONED) {
        pthread_mutex_unlock(&task->lock);
        free(addresses);
        dispose_resolution(task);
        return NULL;
    }
    task->addresses = addresses;
    task->status = addresses ? 0 : 1;
    task->state = RESOLUTION_DONE;
    char ready = 1;
    while (write(task->pipefd[1], &ready, 1) < 0 && errno == EINTR) {}
    pthread_mutex_unlock(&task->lock);
    return NULL;
}

char *chalk_resolve_deadline(const char *host, const char *service,
                             int timeout_ms, int *status) {
    *status = 1;
    if (timeout_ms <= 0) { *status = 2; return NULL; }
    int64_t deadline = monotonic_ms() + timeout_ms;
    struct resolution *task = calloc(1, sizeof(*task));
    if (!task) return NULL;
    task->host = strdup(host);
    task->service = strdup(service);
    if (!task->host || !task->service || pipe(task->pipefd) != 0) {
        free(task->host); free(task->service); free(task); return NULL;
    }
    fcntl(task->pipefd[0], F_SETFD, FD_CLOEXEC);
    fcntl(task->pipefd[1], F_SETFD, FD_CLOEXEC);
    if (pthread_mutex_init(&task->lock, NULL) != 0) {
        close(task->pipefd[0]); close(task->pipefd[1]);
        free(task->host); free(task->service); free(task); return NULL;
    }
    pthread_t worker;
    if (pthread_create(&worker, NULL, resolve_worker, task) != 0) {
        dispose_resolution(task); return NULL;
    }
    pthread_detach(worker);
    struct pollfd ready = { .fd = task->pipefd[0], .events = POLLIN };
    while (1) {
        int64_t left = deadline - monotonic_ms();
        if (left <= 0) break;
        int result = poll(&ready, 1, left > INT_MAX ? INT_MAX : (int)left);
        if (result > 0 || (result < 0 && errno != EINTR)) break;
    }
    pthread_mutex_lock(&task->lock);
    char *addresses = NULL;
    if (task->state == RESOLUTION_DONE) {
        if (monotonic_ms() < deadline) {
            addresses = task->addresses;
            task->addresses = NULL;
            *status = task->status;
        } else {
            *status = 2;
        }
        pthread_mutex_unlock(&task->lock);
        dispose_resolution(task);
    } else {
        /* The worker owns all allocations after the caller's deadline. */
        task->state = RESOLUTION_ABANDONED;
        pthread_mutex_unlock(&task->lock);
        *status = 2;
    }
    return addresses;
}

void chalk_resolve_free(char *addresses) { free(addresses); }
