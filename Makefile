CHALK_BUILD?=release
_DOCKER=docker compose run --rm chalk
DOCKER?=$(_DOCKER)

SOURCES=$(wildcard *.nims)
SOURCES+=$(wildcard *.nimble)
SOURCES+=$(shell find src/ -name '*.nim')
SOURCES+=$(shell find src/ -name '*.c4m')
SOURCES+=$(shell find src/ -name '*.c42spec')

# not PHONY jobs on purpose but instead rebuilds chalk
# when any of the nim sources change
# (a.k.a what Makefile is good at :D)
chalk: $(SOURCES)
	-rm @
	$(DOCKER) nimble $(CHALK_BUILD)

.PHONY: debug release
debug release:
	-rm -f chalk
	$(DOCKER) nimble $@

.PHONY: version
version:
	  @cat *.nimble | grep -E "version\s+=" | cut -d'"' -f2

.PHONY: clean
clean:
	-rm -f chalk src/c4autoconf.nim

# ----------------------------------------------------------------------------
# TOOL MAKEFILES

TOOLS=config-tool server

.PHONY: $(TOOLS)
$(TOOLS):
	make -C $@

$(addsuffix /%,$(TOOLS)):
	make -C $(@D) $*

# ----------------------------------------------------------------------------
# TESTS

.PHONY: tests
tests: DOCKER=$(_DOCKER) # force rebuilds to use docker to match tests
tests: chalk # note this will rebuild chalk if necessary
	docker compose run --rm tests -v $(args)

# ----------------------------------------------------------------------------
# MISC

.PHONY: sqlite
sqlite: server/sqlite
