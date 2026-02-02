ARG BASE=alpine
ARG NIM_VERSION=2.2.4

FROM nimlang/nim:$NIM_VERSION-$BASE-regular AS nim

# -------------------------------------------------------------------

FROM alpine:edge AS alpine

RUN apk add --no-cache \
    bash \
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

COPY *.nimble /chalk/

RUN nimble install --depsOnly --verbose
