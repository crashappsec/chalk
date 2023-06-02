FROM alpine:latest

RUN apk add --no-cache clang clang-dev alpine-sdk                && \
  ln -sf /usr/bin/clang /usr/bin/cc                              


WORKDIR /workspace/src

CMD make


