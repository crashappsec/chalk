# published as ghcr.io/crashappsec/schema-precommit:latest
FROM python:3.10-slim

RUN apt-get update && \
    apt-get install -y \
        git \
        && \
    apt-get clean

# This is needed because the container runs as a different user than likely
# owns the checked-out version of the repository. Most likely the container is
# running as root and everything is owned by the local user. This makes git
# complain about dubious ownership and fail to run. Adding this global setting
# disables the error. We know we're good here.
RUN git config --global safe.directory '*'

RUN pip install pre-commit

COPY .pre-commit-config.yaml /
WORKDIR /

RUN git init && pre-commit install-hooks

CMD pre-commit run --all-files
