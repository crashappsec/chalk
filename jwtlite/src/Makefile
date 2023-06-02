CC           = cc
TESTEXE      = /workspace/bin/test
SCRATCH_DIR  = /workspace/scratch
INCLUDE_DIRS = -I/workspace/include
CFLAGS       = -g -msse -msse2 -maes -Ofast
PWD          = $(shell pwd)

SRCFILES := $(shell find . -name "*.c")
OBJFILES := $(patsubst %.c,$(SCRATCH_DIR)/%.o,$(SRCFILES))
DEPS     := $(patsubst %.c,$(SCRATCH_DIR)/%.d,$(SRCFILES))

D1 = $(shell echo source files:  $(SRCFILES))
D2 = $(shell echo object files:  $(OBJFILES))

-include $(DEPS)

build: $(TESTEXE)

$(TESTEXE): $(OBJFILES)
	cc $(OBJFILES) -o $(TESTEXE) -lpthread
	chmod +x $(TESTEXE)

$(SCRATCH_DIR)/%.o:%.c
	cc $(CFLAGS) $(INCLUDE_DIRS) -MMD -MP -c $< -o $@

run:	$(TESTEXE)
	$(TESTEXE)

clean:
	-rm -rf $(SCRATCH_DIR)/* /workspace/bin/*

remake:	clean build

.PHONY: clean
