FROM alpine as base

FROM base as one
ENTRYPOINT ["one", "entrypoint"]
CMD one cmd

FROM one as two
ENTRYPOINT ["two", "entrypoint"]
