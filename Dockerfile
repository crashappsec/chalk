FROM ghcr.io/crashappsec/nim:alpine-latest as build

ARG CHALK_BUILD="release"

WORKDIR /chalk

COPY . /chalk/

RUN --mount=type=cache,target=/root/.nimble,sharing=locked \
    yes | nimble $CHALK_BUILD

# -------------------------------------------------------------------

FROM alpine:latest as prod

RUN apk add --no-cache pcre gcompat

WORKDIR /

COPY --from=build /chalk/chalk /chalk

ENTRYPOINT /chalk
