FROM ghcr.io/crashappsec/nim:ubuntu-2.2.4 AS nim
FROM ghcr.io/sigstore/cosign/cosign:v2.2.3 AS cosign

# -------------------------------------------------------------------

FROM nim AS deps

# curl - chalk downloads some things directly with curl for the moment
RUN apt-get update -y && \
    apt-get install -y \
        curl \
        make \
        musl-tools \
        strace \
        && \
    apt-get clean -y

# XXX this is needed for the github worker
# https://github.com/actions/runner/issues/2033
RUN if which git; then git config --global --add safe.directory "*"; fi

WORKDIR /chalk

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY *.nimble /chalk/

RUN nimble install --depsOnly

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
