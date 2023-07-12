FROM ghcr.io/crashappsec/nim:ubuntu-1.6.12 as compile

# XXX this is needed for the github worker
# https://github.com/actions/runner/issues/2033
RUN if which git; then git config --global --add safe.directory "*"; fi

# FIXME get these dynamically
RUN nimble install -y https://github.com/crashappsec/con4m \
        https://github.com/crashappsec/nimutils \
        nimSHA2@0.1.1 \
        glob@0.11.2 \
        https://github.com/viega/zippy

ENV PATH="/root/.nimble/bin:${PATH}"

# we are doing this to only compile chalk once when we build this image
# ("compile"), and then, if we want to re-compile, we will do so via the cmd in
# docker-compose and rely on volume mounts to actually have an updated binary
# _without_ rebuilding the whole image. This step only ships you the
# dependencies you need to
FROM compile as build

ARG CHALK_BUILD="release"

WORKDIR /chalk

COPY . /chalk/

RUN --mount=type=cache,target=/root/.nimble,sharing=locked \
    yes | nimble $CHALK_BUILD

# -------------------------------------------------------------------

# published as ghcr.io/crashappsec/chalk:ubuntu-latest

FROM ubuntu:jammy-20230126 as release

RUN apt-get update -y \
    && apt-get install -y libpcre3 libpcre3-dev \
    && apt-get clean -y

WORKDIR /

COPY --from=build /chalk/chalk /chalk

CMD /chalk
