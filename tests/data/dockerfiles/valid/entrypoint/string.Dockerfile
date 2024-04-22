FROM alpine
ENTRYPOINT set -x && echo hello
CMD foo # should not be used
