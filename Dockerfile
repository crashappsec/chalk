FROM ghcr.io/crashappsec/nim:ubuntu-2.0.0 as nim
FROM gcr.io/projectsigstore/cosign:v2.2.3 as cosign

# -------------------------------------------------------------------

FROM nim as deps

# curl - chalk downloads some things directly with curl for the moment
RUN apt-get update -y && \
    apt-get install -y \
        curl \
        musl-tools \
        && \
    apt-get clean -y

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
