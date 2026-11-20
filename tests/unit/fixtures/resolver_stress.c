#include <assert.h>
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
char *chalk_resolve_deadline(const char *, const char *, int, int *);
void chalk_resolve_free(char *);
int mock_getaddrinfo(const char *host, const char *service,
                      const struct addrinfo *hints, struct addrinfo **result) {
    sigset_t mask;
    assert(pthread_sigmask(SIG_SETMASK, NULL, &mask) == 0);
    assert(sigismember(&mask, SIGHUP) == 1);
    assert(sigismember(&mask, SIGINT) == 1);
    assert(sigismember(&mask, SIGQUIT) == 1);
    assert(sigismember(&mask, SIGTERM) == 1);
    if (strcmp(host, "slow-resolver.test") == 0) {
        usleep(2000000);
        return EAI_AGAIN;
    }
    return getaddrinfo(host, service, hints, result);
}
static int descriptors(void) {
    int count = 0;
    for (int i = 0; i < 4096; i++) if (fcntl(i, F_GETFD) >= 0) count++;
    return count;
}
int main(void) {
    int status;
    char *address = chalk_resolve_deadline("127.0.0.1", "80", 1000, &status);
    assert(status == 0 && address && strstr(address, "127.0.0.1"));
    chalk_resolve_free(address);
    int baseline = descriptors();
    for (int i = 0; i < 40; i++) {
        address = chalk_resolve_deadline("slow-resolver.test", "80", 1, &status);
        assert(status == 2 && address == NULL);
    }
    usleep(2500000);
    assert(descriptors() == baseline);
    for (int i = 0; i < 100; i++) {
        address = chalk_resolve_deadline("127.0.0.1", "80", 1000, &status);
        assert(status == 0 && address);
        chalk_resolve_free(address);
    }
    assert(descriptors() == baseline);
    puts("Resolver success, deadline and delayed cleanup checks passed");
    return 0;
}
