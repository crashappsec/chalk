ARG BASE=alpine
FROM ghcr.io/sigstore/cosign/cosign:v2.2.3 AS cosign

# -------------------------------------------------------------------

FROM ghcr.io/crashappsec/nim:alpine-2.0.8 AS alpine

RUN apk add --no-cache \
    bash \
    curl \
    make \
    musl-dev \
    openssl \
    strace

# add musl-gcc so its consistent CC with ubuntu
RUN ln -s $(which gcc) /usr/bin/musl-gcc

# -------------------------------------------------------------------

FROM ghcr.io/crashappsec/nim:ubuntu-2.0.8 AS ubuntu

RUN apt-get update -y && \
    apt-get install -y \
        curl \
        make \
        musl-tools \
        strace \
        && \
    apt-get clean -y

# -------------------------------------------------------------------

FROM $BASE AS deps

# XXX this is needed for the github worker
# https://github.com/actions/runner/issues/2033
RUN if which git; then git config --global --add safe.directory "*"; fi

WORKDIR /chalk

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY *.nimble /chalk/
COPY src/config_version.nim /chalk/src/

# build chalk so that all deps are installed
# this requires creating dummy source file
# as well as keyspec with dummy chalk version
RUN mkdir -p src/configs && \
    echo 'chalk_version := "0.0.0"' > src/configs/base_keyspecs.c4m && \
    touch src/chalk.nim && \
    nimble build --verbose

# -------------------------------------------------------------------
# build chalk binary to be copied into final release stage

FROM deps AS build

ARG CHALK_BUILD="release"

WORKDIR /chalk

# copying only necessary files for build
# vs COPY . /chalk/
# as repo has other tools and copying only necessary files
# optimizes docker build cache
COPY config.nims /chalk/
COPY ./src/ /chalk/src/
# for chalk commit id
COPY ./.git/ /chalk/.git/


RUN yes | nimble $CHALK_BUILD

# -------------------------------------------------------------------
# official image with chalk binary for easy copy
# in other docker builds via:
# COPY --from=chalk /chalk /chalk

FROM scratch

COPY --from=build /chalk/chalk /chalk

ENTRYPOINT ["/chalk"]
