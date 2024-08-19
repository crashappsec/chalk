#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include "con4m.h"

char *configTest = "test section {\n  attr = \"hello, world!\"\nf = 12\n}";

char *
read_file(char *filename)
{
    char *result = NULL;
    FILE *fp     = fopen(filename, "rb");
    long  sz;

    if (fp == NULL) {
        return NULL;
    }
    if (!fseek(fp, 0, SEEK_END)) {
        sz = ftell(fp);

        if (fp < 0) {
            return NULL;
        }

        result = malloc(sz + 1);
        fseek(fp, 0, SEEK_SET);
    } else {
        return NULL;
    }
    if (fread(result, 1, sz, fp) < sz) {
        return NULL;
    }
    result[sz] = 0;

    return result;
}

int
main(int argc, char *argv[], char *envp[])
{
    char   *err;
    int64_t ignore;
    NimMain();
    char  *samispec = read_file("tests/spec/s2-sami.c4m");
    C4Spec specobj  = c4mLoadSpec(samispec, "tests/spec/s2-sami.c4m", &ignore);

    char *res = c4mOneShot(configTest, "whatevs.c4m");
    printf("%s\n", res);
    c4mStrDelete(res);
    void *res2 = c4mFirstRun(configTest, "whatevs.c4m", 1, NULL, &err);
    if (!res2) {
        printf("%s", err);
        exit(0);
    }
    printf("res2 @%p\n", res2);
    assert(!c4mSetAttrInt(res2, "f", 14));
    AttrErr errno = 0;
    printf("This should be 14: %ld\n", c4mGetAttrInt(res2, "f", &errno));
    c4mSetAttrStr(res2, "foo", "bar");
    printf("foo = %s\n", c4mGetAttrStr(res2, "foo", &errno));

    char *chalkcfg = read_file("tests/samibase.c4m");

    if (chalkcfg == NULL) {
        printf("Couldn't read test file.\n");
        exit(0);
    }
    void *res3 = c4mFirstRun(chalkcfg, "samibase.c4m", 1, NULL, &err);
    if (!res3) {
        printf("%s", err);
        exit(0);
    }
    char  **sects;
    int64_t num_sects, i;

    num_sects = c4GetSections(res3, "key", &sects);

    for (i = 0; i < num_sects; i++) {
        printf("%s\n", sects[i]);
    }

    printf("\n---Fields for key 'METADATA_ID':\n");

    char  **fields;
    int64_t num_fields;
    num_fields = c4GetFields(res3, "key.METADATA_ID", &fields);
    for (i = 0; i < num_fields; i += 2) {
        printf("%s: %s\n", fields[i], fields[i + 1]);
    }

    c4mArrayDelete(sects);
    c4mArrayDelete(fields);
    printf("\nRoot scope contents:\n");
    num_fields = c4EnumerateScope(res3, "", &fields); // Root scope.
    for (i = 0; i < num_fields; i += 2) {
        printf("%s: %s\n", fields[i], fields[i + 1]);
    }

    return 0;
}
