FROM alpine
COPY example.sh /
ENTRYPOINT ["/bin/sh", "example.sh"]
