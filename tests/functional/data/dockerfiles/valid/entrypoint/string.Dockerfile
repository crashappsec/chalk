FROM alpine
ENTRYPOINT echo hello
CMD foo # should not be used
