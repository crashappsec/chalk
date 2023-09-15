FROM ghcr.io/crashappsec/nim:ubuntu-2.0.0 as nim
FROM gcr.io/projectsigstore/cosign as cosign

# -------------------------------------------------------------------
# con4m install static deps for build which requires
# more system deps so we do that in a separate docker step

FROM nim as con4m

# deps for compiling static deps
RUN apt-get update -y && \
    apt-get install -y \
        autoconf \
        cmake \
        file \
        g++ \
        gcc \
        git \
        m4 \
        make \
        && \
    apt-get clean -y

WORKDIR /tmp/con4m

# note this is not copied from nimble file on purpose
# as static libs take a while to build so we want to cache
# even when versions change
ARG CON4M_VERSION=v0.1.1
# for testing if we want to build on top of con4m branch
# we can set this arg
ARG CON4M_BRANCH=

RUN set -x && \
    git clone https://github.com/crashappsec/con4m . && \
    git checkout ${CON4M_BRANCH:-${CON4M_VERSION}} && \
    nimble install

# -------------------------------------------------------------------

FROM nim as deps

# curl - chalk downloads some things directly with curl for the moment
RUN apt-get update -y && \
    apt-get install -y \
        curl \
        && \
    apt-get clean -y

# XXX this is needed for the github worker
# https://github.com/actions/runner/issues/2033
RUN if which git; then git config --global --add safe.directory "*"; fi

WORKDIR /chalk

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY --from=con4m /root/.local/c0 /root/.local/c0
COPY *.nimble /chalk/

# build chalk so that all deps are installed
# this requires creating dummy source file
RUN mkdir src && \
    touch src/chalk.nim && \
    nimble build

# -------------------------------------------------------------------
# build chalk binary to be copied into final release stage

FROM deps as build

ARG CHALK_BUILD="release"

WORKDIR /chalk

# copying only necessary files for build
# vs COPY . /chalk/
# as repo has other tools and copying only necessary files
# optimizes docker build cache
COPY --chmod=755 bin/devmode /chalk/bin/
COPY config.nims /chalk/
COPY ./src/ /chalk/src/
# for chalk commit id
COPY ./.git/ /chalk/.git/


RUN yes | nimble $CHALK_BUILD

# -------------------------------------------------------------------
# published as ghcr.io/crashappsec/chalk:alpine

FROM alpine:latest as alpine

# curl     - chalk downloads some things directly with curl for the moment
# ca-certs - even though chalk is a static binary, in order to do external
#            calls openssl requires ca-certificates to be installed
#            on the system
RUN apk add --no-cache \
    ca-certificates \
    curl

COPY --from=build /chalk/chalk /chalk

ENTRYPOINT ["/chalk"]

# -------------------------------------------------------------------
# published as ghcr.io/crashappsec/chalk:ubuntu

FROM ubuntu:jammy-20230126 as ubuntu

# curl     - chalk downloads some things directly with curl for the moment
# ca-certs - even though chalk is a static binary, in order to do external
#            calls openssl requires ca-certificates to be installed
#            on the system
RUN apt-get update -y && \
    apt-get install -y \
        ca-certificates \
        curl \
        && \
    apt-get clean -y

COPY --from=build /chalk/chalk /chalk

ENTRYPOINT ["/chalk"]
