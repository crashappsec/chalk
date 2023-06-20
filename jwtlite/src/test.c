#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include "aes_x86.h"
#include "mint.h"

#define TEST_KEY  "\xab\xba\xda\xba\xd0\x00\x00\x00" \
                  "\xab\xba\xda\xba\xd0\x00\x00\x00"
#define TEST_UID  "a779384b-ed4a-441a-95b6-577caeeec081"
#define DEFAULT_ITERS 1000000  // One million.

uint64_t iters = DEFAULT_ITERS;

void *run_thread(void *ret) {
    int             i     = 0;
    uint64_t        fails = 0;
    uint64_t        local_iters = iters;
    char            token[TOKEN_LEN];
    uint8_t         uid[JSON_UID_LEN];
    char           *test_key = TEST_KEY;
    char           *test_uid = TEST_UID;
    schedule_t      ctx;

    aes128_init((uint8_t *)test_key, &ctx);

    for (i = 0; i < local_iters; i++) {
        jwt_mint(&ctx, (uint8_t *)test_uid, i & 0xff, (uint8_t *)token);
        if (!jwt_validate(&ctx, (uint8_t *)token, uid)) {
            fails++;
        }
    }
    if (!ret) {
        pthread_exit((void *)fails);
    }
    return (void *)fails;
}

static double time_diff(struct timespec *end, struct timespec *start) {
    return ((double)(end->tv_sec - start->tv_sec))
         + ((end->tv_nsec - start->tv_nsec) / 1000000000.0);
}

int
main(int argc, char **argv, char **envp) {
    char           *ptr = NULL;
    uint64_t        nthreads = 1;
    struct timespec ts_start, ts_end;
    double          diff;
    uint64_t        total_fails = 0;
    uint64_t        total_iters;

    if (argc >= 2) {
        if (!(nthreads = strtoull(argv[1], &ptr, 10))) {
            printf("Invalid thread count.\n");
            return 1;
        }
    }

    if (argc >= 3) {
        if (!(iters = strtoull(argv[2], &ptr, 10))) {
            printf("Invalid iteration count.\n");
            return 1;
        }
    }

    total_iters = iters * nthreads;

    printf("Spawning %lu threads.\n", nthreads);
    printf("Running %lu iterations per thread.\n", iters);

    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    if (nthreads == 1) {
        total_fails = (uint64_t)run_thread((void *)1);
        printf("Done with single thread.\n");
    }
    else {
        pthread_t *threads = (pthread_t *)malloc(sizeof(pthread_t) * nthreads);
        uint64_t   fails = 0;
        int        i;

        for (i = 0; i < nthreads; i++) {
            pthread_create(&threads[i],
                           NULL,
                           (void *(*)())run_thread,
                           NULL);
        }
        for (i = 0; i < nthreads; i++) {
            pthread_join(threads[i], (void **) &fails);
            total_fails += fails;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &ts_end);
    diff = time_diff(&ts_end, &ts_start);

    // Each run does a mint and an validate, so multiply by 2.

    printf("Did %ld mints + validates in %.4f seconds (ops/sec: %.3f)\n",
           total_iters*2, diff, (total_iters*2/diff));

    if (total_fails != 0) {
        printf("WARNING:  You had %lu failures (expected 0)!\n", total_fails);
    }

    return 0;
}
