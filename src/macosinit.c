/*
 * John Viega, john@crashoverride.com
 * Copyright 2023, Crash Override, Inc.
 */
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdbool.h>
#include <sys/stat.h>

#define LIBNAME      "libssl.3.dylib"
#define DYLD_PREFIX  "DYLD_LIBRARY_PATH="
#define BREW_DEFAULT "/opt/homebrew"
#define BREW_PREFIX  "HOMEBREW_PREFIX="
#define OSSL3_PATH   "/opt/openssl@3/lib"
#define ALL_READ     S_IRUSR | S_IRGRP | S_IROTH

const char error_msg[] =
    "On MacOS, Chalk requires OpenSSLv3 libraries be installed.\n"
    "Generally, this is done via homebrew:\n"
    "\tbrew install openssl@3\n\n"
    "Chalk will pick this up directly by adding $HOMEBREW_PREFIX to your "
    "dynamic library load path ($DYLD_LIBRARY_PATH)\n"
    "Alternatively, you can manually install it, and set the environment var:\n"
    "\tDYLD_LIBRARY_PATH\n\n"
    "Which should point to the directory containing "
    LIBNAME
    ".\n";

/*
 * There are many ways we could improve this:
 *
 * 1. We could just carry around the object files we need, and load
 *    known good versions. This would prevent the inevitable issues w/
 *    people who don't have 'brew' installed, but would make the exe
 *    bigger by a fair bit (but not much bigger than if the mac
 *    supported static linking), would break if we didn't have a place
 *    to write it out (not much of a worry on a mac) and would be
 *    dependent on us for updating (which would be true in any case
 *    where we're statically linking).  Here, we'd want to drop them
 *    to disk only if we don't find them from a previous drop.
 *
 *    The big practical downside is managing the release process with
 *    for both x86 and arm MacOs.  That's not too horrible, but it's
 *    enough to not do this yet.
 *
 * 2. We could try to run brew for you if you don't have openssl3, but
 *    brew is installed. This would require a prompt, as I don't think
 *    people would love the surprise of brew going and tapping
 *    something without them being explicitly involved.
 *
 * 3. We could try to construct our own Mach-O file that is actually
 *    statically linked.
 *
 * 4. We could actually check to make sure the libraries are loadable,
 *    and look explicitly for the symbols in the libraries we find, on
 *    the off chance they're wrong.
 *
 * 5. If a DYLD_LIBRARY_PATH is set, but OpenSSL3 isn't found anywhere
 *    in it, we can still try to add it and re-exec.
 */
char *construct_dyld_entry(char *homebrew_prefix) {
    /*
     *  This function constructs the new envvar string to pass to the
     *  re-exec, pulling in the homebrew prefix, and appending the
     *  place under that prefix Brew puts OpenSSL3.  While this result
     *  is malloc'd, that won't be a factor after exec.
     */

    if (homebrew_prefix == NULL) {
        homebrew_prefix = BREW_DEFAULT;
    }

    int   n      = strlen(homebrew_prefix) + strlen(DYLD_PREFIX) +
                     strlen(OSSL3_PATH) + 1;
    char *result = (char *)malloc(n);
    char *p      = result;

    strcpy(p, DYLD_PREFIX);
    p += strlen(DYLD_PREFIX);
    strcpy(p, homebrew_prefix);
    p += strlen(homebrew_prefix);
    strcpy(p, OSSL3_PATH);
    p += strlen(OSSL3_PATH);
    *p = 0;

    return result;
}

char *env_value(char *p) {
    /*
     * This function returns the value associated with an environment
     * string, simply by looking for a = and scanning one past it.
     *
     * We don't create a new string, just return a pointer to the
     * right spot in the existing string, which is right at the null
     * if there's no equals sign.
     */
    while (*p && *p++ != '=');

    return p;
}

/*
 * If the environment variable didn't exist at all, then we add to the
 * path, and re-exec without checking.  It'll get checked on the
 * second exec.
 */
void add_path(int argc, char **argv, char **envp, char **p, char *brew_prefix) {
  int     n = p - envp + 2;
  char **new_envp = malloc(sizeof(char *) * n);
  char **q = new_envp;

  p = envp;

  while (*p) {
    *q++ = *p++;
  }

  *q++ = construct_dyld_entry(brew_prefix);
  *q   = 0;

  execve(argv[0], argv, new_envp);
  printf("Could not self-exec.\n");
  _exit(2);
}

bool validate_one_path(char *p) {
    /*
     * This function gets called on to see whether a single path in
     * DYLD_LIBRARY_PATH has libssl in it.  Note that we do also
     * require libcrypto, but in every place in the history of mankind
     * where libssl lived in the directory, libcrypto was there too
     * (or, I was a little lazy).
     *
     * Not only do we check for the existance of libssl (tho we do not
     * check the contents), we do check that the user has permission
     * to link aginst the file (read permissions are all that's
     * required).
     */
    struct stat info;

    int  l = strlen(p);
    char onepath[l + strlen(LIBNAME) + 2];

    strcpy(onepath, p);
    onepath[l] = '/';
    strcpy(&onepath[l+1], LIBNAME);
    if (stat(onepath, &info) == -1) {
        return false;
    }

    int fmt = info.st_mode & S_IFMT;

    /*
     * It's a file or a symbolic link to the file.  We'll double check
     * that it's readable by us.
     */
    if (fmt != S_IFREG && fmt != S_IFLNK) {
        return false;
    }
    /*
     * This is the mode brew chooses by default, so this should
     * usually be the path we take.
     */
    if ((info.st_mode & ALL_READ) == ALL_READ) {
        return true;
    }
    if (info.st_uid == geteuid()) {
        return (bool)(info.st_mode & S_IRUSR);
    }
    gid_t groups[255];
    int   num_groups = getgroups(255, groups);

    for (int i = 0; i < num_groups; i++) {
        if (groups[i] == info.st_gid) {
            return (bool)info.st_mode & S_IRGRP;
        }
    }

    return (bool)info.st_mode & S_IROTH;
}

/*
 * Here we're going to go through the existing DYLD_LIBRARY_PATH and
 * test each path until we find one that seems to have openssl3.
 *
 * Basically we'll start after the '=', and temporarily replace any
 * ':' separators in a path with a null, then call
 * validatate_one_path().
 */
bool validate_setting(char *envvar) {
    char *dup  = strdup(envvar);
    char *p    = dup;
    bool  last = false;

    while ((*p++) != '=');

    while (*p != 0) {
        char *end = p + 1;
        char cur = *end;
        while(cur != ':' && cur != 0) {
            end++;
            cur = *end;
        }
        if (cur == 0) {
            last = true;
        }
        *end = 0;
        if (validate_one_path(p)) {
            free(dup);
            return true;
        }
        if (last) {
            free(dup);
            return false;
        }
        *end = ':';
        p    = end;
    }

    free(dup);
    return true;
}

/*
 * This probably merits some explaination.  This attribute (respected
 * by both gcc and clang) adds a function that gets called early from
 * the 'prelude'... the part of the binary that sets stuff up before
 * the programmer's typical main() get applied (or, in Nim's case,
 * NimMain()).
 *
 * This is important, because Nim is smart enough to know we needed
 * libsslv3 and libcryptov3, and that they couldn't be statically
 * linked because MacOS hates me.  As a result, when it starts up, it
 * will try to load OpenSSLv3, and if it doesn't find it, it won't
 * give us the chance to fix it.
 *
 * So, this is us getting out ahead of it, looking to see if we can
 * patch up the user's environment, then re-execing ourselves.
 *
 * Of course, the re-exec might fail too, so we have to be a bit
 * careful about handling such failures to ensure termination.
 *
 * In this first pass, we only set up OpenSSL3 in DYLD_LIBRARY_PATH
 * when that env variable isn't provided at all, to make it super easy
 * on ourselves.
 */
void pre_main(int argc, const char **argv, const char **envp)
    __attribute__((constructor)) {
    char    **p       = envp;
    char    **dyld_p   = NULL;
    char    **brew_p   = NULL;


    while (*p) {
        /*
         * Just making one pass and pulling out the two env vars we
         * might want to check, IF they are present.  We'll act on
         * them after.
         */
        if (!strncmp(*p, BREW_PREFIX, strlen(BREW_PREFIX))) {
            brew_p = p;
        }
        if (!strncmp(*p, DYLD_PREFIX, strlen(DYLD_PREFIX))) {
            dyld_p = p;
        }
        p++;
    }
    if (dyld_p == NULL) {
        char *homebrew_prefix;

        if (brew_p != NULL) {
            homebrew_prefix = env_value(*brew_p);
        }
        else {
            homebrew_prefix = BREW_DEFAULT;
        }

        add_path(argc, argv, envp, p, homebrew_prefix);
    }
    else {
        if(validate_setting(*dyld_p)) {
            return;
        }
        else {
            printf("%s", error_msg);
            _exit(1);
        }
    }
}
