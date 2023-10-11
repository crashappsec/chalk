# this needs to be before any FROM clauses
ARG BASE=ubuntu
ARG PYTHON_VERSION=3.11.3

# ----------------------------------------------------------------------------

FROM python:$PYTHON_VERSION-alpine3.17 as alpine

# install chalk runtime deps
RUN apk add --no-cache curl git

RUN if uname -m | grep -Ei "arm|aarch"; then \
    apk add --no-cache \
        gcc \
        libffi-dev \
        musl-dev \
    ; fi

# ----------------------------------------------------------------------------

FROM python:$PYTHON_VERSION-slim as ubuntu

RUN apt-get update -y && \
    apt-get install -y \
        curl \
        git \
        gdb \
        && \
    apt-get clean -y

# ----------------------------------------------------------------------------

FROM gcr.io/projectsigstore/cosign as cosign

# ----------------------------------------------------------------------------

FROM $BASE

ARG POETRY_VERSION=1.5.1

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign

RUN pip install --no-cache-dir poetry==${POETRY_VERSION}

ENV VIRTUAL_ENV=/tests.env
ENV PATH=/tests.env/bin:$PATH
RUN python -m venv /tests.env

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

COPY pyproject.toml poetry.lock $WORKDIR/
RUN poetry install --no-plugins

COPY --from=docker:24 /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker/buildx-bin:0.11.2 /buildx /usr/lib/docker/cli-plugins/docker-buildx

ENTRYPOINT ["pytest"]
