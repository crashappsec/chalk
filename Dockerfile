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

# Install static libs and C headers from the nimutils sibling repo.
# buildlibs.sh copies platform-specific pre-built .a files from
# files/deps/lib/{os}-{arch}/; header_install.sh copies nimutils/c/ headers.
# Both land in ~/.local/c0/ so chalk's config.nims can link against them.
COPY --from=nimutils bin/buildlibs.sh /tmp/nimutils/bin/
COPY --from=nimutils files/deps/ /tmp/nimutils/deps/
RUN bash /tmp/nimutils/bin/buildlibs.sh /tmp/nimutils/deps

COPY --from=nimutils bin/header_install.sh /tmp/nimutils/bin/
COPY --from=nimutils nimutils/c/ /tmp/nimutils/nimutils/c/
RUN NIMUTILS_DIR=/tmp/nimutils bash /tmp/nimutils/bin/header_install.sh

COPY *.nimble /chalk/

RUN nimble install --depsOnly --verbose
