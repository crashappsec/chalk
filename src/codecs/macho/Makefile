# Standalone build for the carved Mach-O codec.
#
# Chalk's main build is nim/nimble + {.compile.} pragmas — see
# src/plugins/codecCerts.nim for the integration pattern.  This
# Makefile exists for PR 2 to prove the carved sources compile and
# work in isolation against fixture Mach-Os, before any nim glue is
# written (that lands in PR 3).
#
# Usage:
#   make           # builds libchalk_macho.a and bin/macho_smoke
#   make test      # runs the smoke test against tests/fixtures/macho/*
#   make clean

CC      ?= clang
CFLAGS  ?= -std=c23 -O0 -g -Wall \
           -Wno-unused-function -Wno-unused-parameter \
           -Wno-unused-but-set-variable
INCLUDE := -Iinclude

SRC := \
    src/n00b_shim.c \
    src/macho_stream.c \
    src/macho.c \
    src/chalk_macho.c

OBJ := $(SRC:src/%.c=build/%.o)

LIB := build/libchalk_macho.a
BIN := build/macho_smoke

.PHONY: all clean test

all: $(LIB) $(BIN)

build:
	@mkdir -p build

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) $(INCLUDE) -c $< -o $@

$(LIB): $(OBJ)
	ar rcs $@ $^

# OpenSSL libcrypto: chalk caches a static .a in ~/.local/c0/libs/
# (see config.nims).  Reuse that here so the standalone smoke test
# matches what the main chalk build links against.
C0_LIBS    ?= $(HOME)/.local/c0/libs
LIBCRYPTO  := $(C0_LIBS)/libcrypto.a

$(BIN): test/macho_smoke.c $(LIB) $(LIBCRYPTO)
	$(CC) $(CFLAGS) $(INCLUDE) $< -L build -lchalk_macho $(LIBCRYPTO) -o $@

test: $(BIN)
	@echo "==> running macho_smoke against fixtures"
	@if [ -d tests/fixtures/macho ]; then \
	  for f in tests/fixtures/macho/*; do \
	    [ -f "$$f" ] || continue; \
	    echo "--- $$f"; \
	    $(BIN) "$$f" || exit 1; \
	  done; \
	else \
	  echo "no fixtures yet — generate them per docs/design-macho-codec.md test plan"; \
	fi

clean:
	rm -rf build
