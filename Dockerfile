FROM ghcr.io/crashappsec/nim:ubuntu-1.6.12 as compile

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

COPY chalk_internal.nimble /chalk/

# con4m - for verifying config files
#         and nimble sync fails to sync it as it has bin configured
# bump  - for cutting releases
RUN nimble install -y \
    https://github.com/crashappsec/con4m \
    https://github.com/disruptek/bump

# generate lock file in order to use nimble sync
# as repo does not use lock files as they cause trouble outside of docker
# nimble sync requires git repo
# so we create dummy git repo with empty commit
# and then immediately clean-up
RUN git init -b main . && \
    git config user.name "chalk" && \
    git config user.email "chalk@crashoverride.com" && \
    git commit --allow-empty -m "for nimble sync" && \
    nimble lock && \
    nimble sync && \
    rm -rf .git

# -------------------------------------------------------------------
# build chalk binary to be copied into final release stage

FROM compile as build

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

RUN --mount=type=cache,target=/root/.nimble,sharing=locked \
    yes | nimble $CHALK_BUILD

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
