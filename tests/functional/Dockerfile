# this needs to be before any FROM clauses
ARG BASE=ubuntu
ARG DOCKER_VERSION=24
ARG BUILDX_VERSION=0.14.0
ARG COSIGN_VERSION=2.2.3
ARG PYTHON_VERSION=3.12
ARG POETRY_VERSION=2.0.1

FROM docker:$DOCKER_VERSION AS docker
FROM docker/buildx-bin:$BUILDX_VERSION AS buildx
FROM ghcr.io/sigstore/cosign/cosign:v$COSIGN_VERSION AS cosign

# ----------------------------------------------------------------------------

FROM python:$PYTHON_VERSION-alpine3.17 AS alpine

# install chalk runtime deps
RUN apk add --no-cache \
    curl \
    gdb \
    git \
    gpg \
    strace

RUN if uname -m | grep -Ei "arm|aarch"; then \
    apk add --no-cache \
        gcc \
        libffi-dev \
        musl-dev \
    ; fi

# ----------------------------------------------------------------------------

FROM python:$PYTHON_VERSION-slim AS ubuntu

RUN apt-get update -y && \
    apt-get install -y \
        curl \
        gdb \
        gettext-base \
        git \
        gpg \
        strace \
        && \
    apt-get clean -y

# ----------------------------------------------------------------------------

FROM $BASE

ARG POETRY_VERSION
RUN pip install --no-cache-dir poetry==${POETRY_VERSION}

ENV VIRTUAL_ENV=/tests.env
ENV PATH=/tests.env/bin:$PATH
RUN python -m venv /tests.env

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

COPY pyproject.toml poetry.lock $WORKDIR/
RUN poetry install --no-plugins

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=buildx /buildx /usr/lib/docker/cli-plugins/docker-buildx

RUN docker context create node-amd64
RUN docker context create node-arm64
# docker buildx node is created via entrypoint
