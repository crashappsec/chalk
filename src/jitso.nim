## Just-in-time-shared-objects
## 
## This is the minimal set for a hacky answer to dlopen using memfd_create,
## requiring Linux kernel version 3.17 or greater (2014). 
##
## :Author: Brandon Edwards (brandon@crashoverride.com)
## :Copyright: 2023 Crash Override, Inc.
##

import tables

when hostOs == "linux":
  {. passL:"-rdynamic -Wl,-wrap,__open64_nocancel".}
  const 
    libc      = "libc.so.6"
    libssl    = "libssl.so.3"
    libpcre   = "libpcre.so.3"
    libcrypto = "libcrypto.so.3"
    libld     = "ld-linux-x86-64.so.2"
    libpath   = "/usr/lib/x86_64-linux-gnu/"
    jitsoLibraries = {
                      libc:      staticRead(libpath & libc),
                      libssl:    staticRead(libpath & libssl),
                      libpcre:   staticRead(libpath & libpcre),
                      libcrypto: staticRead(libpath & libcrypto),
                      libld:     staticRead(libpath & libld)
                      }.toTable()
  proc setupLibraryArrayC(
                         count: uint64
                         ): cint {.importc: "allocate_library_info_array".}
  proc setLibraryInfoC(
                      index: uint64,
                      name: ptr cchar,
                      data: ptr cchar,
                      length: uint64
                      ): cint {.importc: "set_library_info".}

  proc setupJitso() {.exportc.} =
    if 0 != setupLibraryArrayC(uint64(len(jitsoLibraries))):
      echo "DEBUG: failed to setup embedded library array"
      return
    var index = 0
    var foobar = jitsoLibraries[libc]
    var varname: string
    var data: string
    for name in jitsoLibraries.keys():
      varname = name
      var namePointer = cast[ptr cchar](addr(varname[0]))
      data = jitsoLibraries[name]
      var dataPointer = cast[ptr cchar](addr(data[0]))
      if 0 != setLibraryInfoC(uint64(index),
                              namePointer,
                              dataPointer,
                              uint64(len(data))):
        echo "failed to setup library: " & name
        return
      index += 1

  {.emit: """
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  char     *name;
  char     *data;
  long unsigned int length;
} library_info_t;

library_info_t    *library_info;
long unsigned int jit_library_count;
int               jitso_is_setup;

int allocate_library_info_array(long unsigned int count) {
  size_t total = (size_t)count * sizeof(library_info_t);
  library_info = (library_info_t *)malloc(total);
  if (NULL == library_info) {
    return -1;
  }
  memset((void *)library_info, 0, total);
  jit_library_count = count;
  return 0;
}

int set_library_info(long unsigned int index,
                     char *name,
                     char *data,
                     long unsigned int length) {
  // malloc'ing just in case Nim GC gets funky
  library_info_t *library;
  char *name_copy, *data_copy;
  size_t name_length;
  data_copy = (char *)malloc((size_t )length);
  if (NULL == data_copy) {
    goto free_and_fail;
  }
  name_length = strlen(name) + 1;
  name_copy = (char *)malloc(name_length);
  if (NULL == name_copy) {
    free(data_copy);
    goto free_and_fail;
  }

  memcpy(data_copy, data, length);
  memcpy(name_copy, name, name_length);
  library         = &library_info[index];  
  library->name   = name_copy;
  library->data   = data_copy;
  library->length = length;
  return 0;

free_and_fail:
  free(library_info);
  library_info      = NULL;
  jit_library_count = 0;
  return -1;
}

__attribute__((constructor)) int pre_main(int c, char *const a[]) {
  char *chalk_lib="/chalk:";
  char *ld_env_key="LD_LIBRARY_PATH";
  char *orig_env_key="CHALK_ORIGINAL_LD_PATH";
  char *chalk_already_set_env="CHALK_ALREADY_SET_ENV";
  char *orig_env, *new_env;
  if (NULL != getenv(chalk_already_set_env)) {
    if (NULL != (orig_env=getenv(orig_env_key))) {
      setenv(ld_env_key, orig_env, 1);
      unsetenv(orig_env_key);
    } else {
      unsetenv(ld_env_key);
    }
    unsetenv(chalk_already_set_env);
    jitso_is_setup = 0;
  } else {
    if (NULL != (orig_env=getenv(ld_env_key))) {
      new_env =(char *)malloc(strlen(orig_env)+strlen(chalk_lib)+1);
      strcat(new_env, chalk_lib);
      strcat(new_env, orig_env);
      setenv(orig_env_key, orig_env, 1);
    } else {
      new_env = chalk_lib;
    }
    setenv(ld_env_key, new_env, 1);                                 
    setenv(chalk_already_set_env, "yup", 1);
    execv("/proc/self/exe", a);
  }
  return 0;
}

int __wrap___open64_nocancel(const char *file, int flags, ...) {
  int index, mode, fd;
  char *library_data;
  ssize_t amount_written, remaining;
  index = mode = fd = 0;
  if (0 == jitso_is_setup) {
    setupJitso();
    jitso_is_setup = 1;
  }
  if (0 == strncmp(file, "/chalk/", 7)) {
    for (index = 0; index < jit_library_count; index++) {
      if (0 == strcmp(&file[7], library_info[index].name)) {
        fd = memfd_create(file, 0);
        if (-1 == fd) {
          // we can't get a memfd, so for now just stop trying
          // FIXME: revisit this: we could write to /tmp or /chalk
          break;
        }
        library_data   = library_info[index].data;
        remaining      = (ssize_t )library_info[index].length;
        amount_written = 0; 
        while (remaining > 0) {
          amount_written = write(fd, library_data, remaining);
          if (amount_written < 0) {
            // out of memory? other error? break
            break;
          }
          remaining    -= amount_written;
          library_data += amount_written;
        }
        if (remaining > 0) {
          // error writing?
          break;
        }
        lseek(fd, 0, SEEK_SET);
        return fd;
      } 
    }
  }
  if ((mode & O_CREAT != 0) || (mode & O_TMPFILE == O_TMPFILE)) {
    va_list arg;
    va_start(arg, flags);
    mode = va_arg(arg, int);
    va_end (arg);
  }
  return openat(AT_FDCWD, file, flags, mode);
}


""".}
