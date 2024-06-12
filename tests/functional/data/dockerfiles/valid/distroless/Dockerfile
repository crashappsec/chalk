FROM python:3-slim as build
RUN set -x && \
    python3 -m venv /venv && \
    ln -fs /usr/bin/python /venv/bin/python3 && \
    ls -la /venv/bin

FROM gcr.io/distroless/python3-debian11
COPY --from=build /venv /venv
ENTRYPOINT ["/venv/bin/python3"]
SHELL ["-c"]
CMD import sys; \
    assert sys.executable == '/venv/bin/python3', sys.executable; \
    print("hello")
