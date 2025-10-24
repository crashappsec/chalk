SHELL=bash
BINARY=chalk
CHALK_BUILD?=release

ifeq "$(CHALK_BUILD)" "debug"
export DEBUG=true
endif

_DOCKER_ARGS=
_DOCKER=docker compose run --rm $(_DOCKER_ARGS) chalk
DOCKER?=$(_DOCKER)

ifeq "$(DOCKER)" ""
DOCKER_N00B=
else
DOCKER_N00B=--docker
endif

ifeq "$(shell [ -t 0 ] && echo interactive)" "interactive"
CRASHAPPSEC=git@github.com:crashappsec
else
CRASHAPPSEC=https://github.com/crashappsec
endif

SOURCES=$(wildcard *.nims)
SOURCES+=$(wildcard *.nimble)
SOURCES+=$(shell find src/ -name '*.nim')
SOURCES+=$(shell find src/ -name '*.c4m')
SOURCES+=$(shell find src/ -name '*.c42spec')
SOURCES+=$(shell find src/ -name '*.md')
SOURCES+=$(shell find src/ -name '*.c')
SOURCES+=$(shell find ../con4m -name '*.nim' 2> /dev/null)
SOURCES+=$(shell find ../con4m -name '*.c4m' 2> /dev/null)
SOURCES+=$(shell find ../nimutils -name '*.nim' 2> /dev/null)
SOURCES+=$(shell find ../nimutils -name '*.c' 2> /dev/null)
SOURCES+=$(shell find ../n00b/include -name '*.h' 2> /dev/null)
SOURCES+=src/docs/CHANGELOG.md
SOURCES+=../n00b/dist/libs/libn00b.a
SOURCES+=nimble.paths
N00B_SOURCES=$(shell find ../n00b -name '*.c' 2> /dev/null)
N00B_SOURCES=$(shell find ../n00b -name '*.nc' 2> /dev/null)
N00B_SOURCES+=$(shell find ../n00b -name '*.h' 2> /dev/null)

VERSION=$(shell cat src/configs/base_keyspecs.c4m \
          | grep -E "chalk_version\s+:=" | cut -d'"' -f2 | head -n1)

BUILDS=$(shell cat *.nimble | grep -E '^task.*build' | cut -d, -f1 | awk '{print $$2}')

# in case nimble bin is not in PATH - e.g. vanilla shell
export PATH:=$(HOME)/.nimble/bin:$(PATH)

# not PHONY jobs on purpose but instead rebuilds chalk
# when any of the nim sources change
# (a.k.a what Makefile is good at :D)
$(BINARY): $(BINARY).bck
	cp $^ $@
# automatically run setup to configure cosign for easy local testing
ifneq "$(CHALK_PASSWORD)" ""
	./$@ setup
endif

# as chalk load modifies existing binary,
# when no source files change, recopy the backup
# to get back to original compiled binary
$(BINARY).bck: $(SOURCES)
ifneq "$(TMUX)" ""
	reset
	tmux clear-history
endif
	$(DOCKER) nimble -y $(CHALK_BUILD)
	mv $(BINARY) $@
	cp $@ $(BINARY)
	ls -la $(BINARY) $@

debug: DEBUG=true
$(BUILDS):
	$(eval export CHALK_BUILD=$@)
	$(eval export DEBUG)
	-rm -f $(BINARY) $(BINARY).bck
	$(MAKE) $(BINARY)

src/docs/CHANGELOG.md: CHANGELOG.md
	cp $^ $@

.PHONY: version
version:
	  @echo $(VERSION)

.PHONY: clean
clean:
	-$(DOCKER) rm -rf $(BINARY) $(BINARY).bck dist nimutils con4m nimble.develop nimble.paths

watch: $(SOURCES)
	echo $^ | tr ' ' '\n' | entr $(MAKE)

../%/README.md:
	git clone $(CRASHAPPSEC)/$*.git $(@D)

../n00b/dist/libs/libn00b.a: ../n00b/README.md $(N00B_SOURCES)
	cd ../n00b && ./bin/ndev $(DOCKER_N00B) dist
	touch $@

../nimutils/README.md:
	git clone $(CRASHAPPSEC)/nimutils.git $(@D)
	git --git-dir=$(@D)/.git --work-tree=$(@D) checkout libn00b

../con4m/README.md:
	git clone $(CRASHAPPSEC)/con4m.git $(@D)
	git --git-dir=$(@D)/.git --work-tree=$(@D) checkout dev

nimble.paths: ../nimutils/README.md
nimble.paths: ../con4m/README.md
	echo --noNimblePath > $@
	echo '--path:"$(abspath $(dir $(shell find ../nimutils -name nimutils.nim)))"' >> $@
	echo '--path:"$(abspath $(dir $(shell find ../con4m -name con4m.nim)))"' >> $@

# ----------------------------------------------------------------------------
# TESTS

# needed for the registry tests
export IP=$(firstword $(shell hostname -I 2> /dev/null || hostname -i 2> /dev/null))

# normally this is not required to run on a host
# as it always runs within the test container
# but is provided as separate make target to provision
# acceptable builder instance locally for multi-platform builds
.PHONY: docker-builder
docker-builder:
	./tests/functional/entrypoint.sh true

# docker buildx - each builder node has its own config
# how it handles insecure registries however as chalk
# splits 'docker buildx --push' into:
# * docker buildx build
# * docker push
# and `docker push` does not honor buildx registry configs
# we need to adjust docker daemon configs to allow insecure
# registry which is used in tests
.PHONY: /etc/docker/daemon.json
/etc/docker/daemon.json:
ifneq "$(shell which systemctl 2> /dev/null)" ""
	sudo -E python3 ./tests/functional/data/templates/docker/daemon.py $@ --write --fail-on-changes \
		|| sudo systemctl restart docker \
		|| echo Please restart docker daemon after changing docker config
endif

$(HOME)/.pdbrc.py:
	touch $@

.PHONY: docker-setup
docker-setup: /etc/docker/daemon.json
docker-setup: /etc/docker/certs.d/$(IP)\:5045/ca.crt
# this actually gets used by 5046 which tests whether 5046 can be
# connected to with insecure https
docker-setup: /etc/docker/certs.d/$(IP)\:5044/ca.crt

/etc/docker/certs.d/$(IP)\:%/ca.crt:
	sudo mkdir -p $(@D)
	sudo mkdir -p /etc/docker/keys/$(IP):$*
	sudo openssl req \
	  -newkey rsa:2048 \
	  -nodes -sha256 \
	  -subj '/CN=$(IP)/O=CrashOverride./C=US' \
	  -addext "subjectAltName = IP:$(IP)" \
	  -x509 \
	  -days 365 \
	  -keyout /etc/docker/keys/$(IP):$*/ca.key \
	  -out $@

.PHONY: tests
tests: DOCKER=$(_DOCKER) # force rebuilds to use docker to match tests
tests: $(HOME)/.pdbrc.py
tests: docker-setup
tests: $(BINARY) # note this will rebuild chalk if necessary
	docker compose run --rm tests $(make_args) $(args)

.PHONY: unit-tests
unit-tests:
	$(DOCKER) nimble test args='$(args)'

.PHONY: parallel
tests_parallel: make_args=-nauto
tests_parallel: tests

.PHONY: tests_bash
tests_bash:
	docker compose run --rm --no-deps tests bash

.PHONY: src/utils/pingttl
src/utils/pingttl: src/utils/pingttl.nim
	$(DOCKER) nim c -r $< 1.1.1.1 1
	-docker compose run --rm --no-deps --entrypoint=strace tests -- $$(pwd)/$@ 1.1.1.1 1
	-docker compose run --rm --no-deps --entrypoint=strace tests -- $$(pwd)/$@ 1.1.1.1 2

# ----------------------------------------------------------------------------
# MISC

.PHONY: lint-dust
lint-dust:
	pre-commit run --files ./dust-lambda-extension/**

.PHONY: lint-all
lint-all:
	pre-commit run --all-files
