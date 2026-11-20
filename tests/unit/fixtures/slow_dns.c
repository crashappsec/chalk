#define _GNU_SOURCE
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*lookup_fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
static int repeated_lookup;
static int controlled_lookup(const char *name, const char *service,
                             const struct addrinfo *hints, struct addrinfo **result,
                             lookup_fn original) {
    if (name && strcmp(name, "slow-resolver.test") == 0) {
        usleep(2000000);
        return EAI_AGAIN;
    }
    if (name && strcmp(name, "second-lookup.test") == 0) {
        if (repeated_lookup++) usleep(2000000);
        return original("127.0.0.1", service, hints, result);
    }
    if (getenv("CHALK_TEST_SLOW_NUMERIC") && name &&
        (!strcmp(name, "127.0.0.1") || !strcmp(name, "::1"))) usleep(2000000);
    return original(name, service, hints, result);
}
#ifdef __APPLE__
static int wrapped_getaddrinfo(const char *name, const char *service,
                               const struct addrinfo *hints, struct addrinfo **result) {
    return controlled_lookup(name, service, hints, result, getaddrinfo);
}
__attribute__((used)) static struct { const void *replacement, *original; }
interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)wrapped_getaddrinfo, (const void *)getaddrinfo }
};
#else
int __real_getaddrinfo(const char *, const char *, const struct addrinfo *, struct addrinfo **);
int __wrap_getaddrinfo(const char *name, const char *service,
                       const struct addrinfo *hints, struct addrinfo **result) {
    return controlled_lookup(name, service, hints, result, __real_getaddrinfo);
}
#endif
