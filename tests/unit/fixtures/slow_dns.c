#include <netdb.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
static int slow_getaddrinfo(const char *name, const char *service,
                           const struct addrinfo *hints, struct addrinfo **result) {
    if (name && strcmp(name, "slow-resolver.test") == 0) {
        usleep(2000000);
        return EAI_AGAIN;
    }
    return getaddrinfo(name, service, hints, result);
}
__attribute__((used)) static struct { const void *replacement, *original; }
interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)slow_getaddrinfo, (const void *)getaddrinfo }
};
#else
#include <dlfcn.h>
#include <pthread.h>
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static int (*original_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
static void initialize(void) { original_getaddrinfo = dlsym(RTLD_NEXT, "getaddrinfo"); }
int getaddrinfo(const char *name, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
    if (name && strcmp(name, "slow-resolver.test") == 0) {
        usleep(2000000);
        return EAI_AGAIN;
    }
    pthread_once(&initialized, initialize);
    return original_getaddrinfo(name, service, hints, result);
}
#endif
