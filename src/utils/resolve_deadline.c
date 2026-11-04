#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
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

static int wait_until(int fd, short events, int64_t deadline) {
    struct pollfd event = { .fd = fd, .events = events };
    while (1) {
        int64_t left = deadline - monotonic_ms();
        if (left <= 0) return 0;
        int ready = poll(&event, 1, left > INT_MAX ? INT_MAX : (int)left);
        if (ready > 0) return 1;
        if (ready < 0 && errno != EINTR) return -1;
    }
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
    sigset_t blocked, previous;
    sigfillset(&blocked);
    if (pthread_sigmask(SIG_SETMASK, &blocked, &previous) != 0) {
        dispose_resolution(task); return NULL;
    }
    int started = pthread_create(&worker, NULL, resolve_worker, task);
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    if (started != 0) { dispose_resolution(task); return NULL; }
    pthread_detach(worker);
    int waited = wait_until(task->pipefd[0], POLLIN, deadline);
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
        *status = waited < 0 ? 1 : 2;
    }
    return addresses;
}

void chalk_resolve_free(char *addresses) { free(addresses); }

int chalk_connect_numeric(const char *address, uint16_t port, int timeout_ms, int *status) {
    *status = 1;
    if (timeout_ms <= 0) { *status = 2; return -1; }
    int64_t deadline = monotonic_ms() + timeout_ms;
    char numeric[1025];
    if (strlen(address) >= sizeof(numeric)) return -1;
    strcpy(numeric, address);
    char *zone = strchr(numeric, '%');
    uint32_t scope = 0;
    if (zone) {
        *zone++ = '\0';
        char *end;
        unsigned long value = strtoul(zone, &end, 10);
        if (*zone && !*end && value <= UINT32_MAX) scope = (uint32_t)value;
        else scope = if_nametoindex(zone);
        if (!scope) return -1;
    }
    union { struct sockaddr_in ipv4; struct sockaddr_in6 ipv6; } target = {0};
    const struct sockaddr *socket_address;
    socklen_t length;
    int family;
    if (!zone && inet_pton(AF_INET, numeric, &target.ipv4.sin_addr) == 1) {
        target.ipv4.sin_family = AF_INET;
        target.ipv4.sin_port = htons(port);
#ifdef __APPLE__
        target.ipv4.sin_len = sizeof(target.ipv4);
#endif
        socket_address = (const struct sockaddr *)&target.ipv4;
        length = sizeof(target.ipv4);
        family = AF_INET;
    } else {
        memset(&target, 0, sizeof(target));
        if (inet_pton(AF_INET6, numeric, &target.ipv6.sin6_addr) != 1) return -1;
        target.ipv6.sin6_family = AF_INET6;
        target.ipv6.sin6_port = htons(port);
        target.ipv6.sin6_scope_id = scope;
#ifdef __APPLE__
        target.ipv6.sin6_len = sizeof(target.ipv6);
#endif
        socket_address = (const struct sockaddr *)&target.ipv6;
        length = sizeof(target.ipv6);
        family = AF_INET6;
    }
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return -1; }
    if (connect(fd, socket_address, length) != 0) {
        if (errno != EINPROGRESS && errno != EWOULDBLOCK) { close(fd); return -1; }
        int ready = wait_until(fd, POLLOUT, deadline);
        if (ready <= 0) { close(fd); *status = ready == 0 ? 2 : 1; return -1; }
        int error = 0;
        socklen_t error_size = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) != 0 || error) {
            close(fd); return -1;
        }
    }
    if (monotonic_ms() >= deadline) { close(fd); *status = 2; return -1; }
    *status = 0;
    return fd;
}
