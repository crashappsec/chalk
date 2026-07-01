ARG BASE=alpine
ARG NIM_VERSION=2.2.4

FROM nimlang/nim:$NIM_VERSION-$BASE-regular AS nim

# -------------------------------------------------------------------

FROM alpine:edge AS alpine

RUN apk add --no-cache \
    bash \
    cmake \
    curl \
    gcc \
    git \
    make \
    musl-dev \
    openssl \
    strace

# add musl-gcc so its consistent CC with ubuntu
RUN ln -s $(which gcc) /usr/bin/musl-gcc

# -------------------------------------------------------------------

FROM ubuntu AS ubuntu

RUN apt-get update -y && \
    apt-get install -y \
        cmake \
        curl \
        git \
        make \
        musl-tools \
        strace \
        && \
    apt-get clean -y

# -------------------------------------------------------------------

FROM $BASE AS deps

COPY --from=nim /nim /nim
ENV PATH=$HOME/.nimble/bin:/nim/bin:$PATH

# XXX this is needed for the github worker
# https://github.com/actions/runner/issues/2033
RUN if which git; then git config --global --add safe.directory "*"; fi

WORKDIR /chalk

# Build any static deps not bundled in nimutils' pre-built package directory.
# Uses the local nimutils tree (mounted as a build context) so that changes to
# buildlibs.sh (e.g. ensure_zlib) take effect without a nimutils release.
# COPY --from=nimutils bin/buildlibs.sh /tmp/nimutils-local/bin/
# COPY --from=nimutils files/deps/ /tmp/nimutils-local/deps/
# RUN bash /tmp/nimutils-local/bin/buildlibs.sh /tmp/nimutils-local/deps
# COPY --from=nimutils bin/header_install.sh /tmp/nimutils-local/bin/
# COPY --from=nimutils nimutils/c/ /tmp/nimutils-local/nimutils/c/
# RUN ls -la /tmp/nimutils-local/nimutils/c/ && NIMUTILS_DIR=/tmp/nimutils-local bash /tmp/nimutils-local/bin/header_install.sh

COPY *.nimble /chalk/

RUN nimble install --depsOnly --verbose
