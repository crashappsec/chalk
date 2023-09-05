FROM ghcr.io/crashappsec/nim:ubuntu-2.0.0 as nim

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

WORKDIR /tmp
ARG CON4M_BRANCH=main
RUN git clone https://github.com/crashappsec/con4m -b $CON4M_BRANCH

WORKDIR /tmp/con4m
RUN nimble install

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
