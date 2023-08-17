FROM python:3.11.3-alpine3.17

ARG POETRY_VERSION=1.5.1

# install poetry
RUN apk add --no-cache \
        curl \
        gcc \
        libressl-dev \
        libffi-dev \
        musl-dev && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile=minimal && \
    source $HOME/.cargo/env && \
    pip install --no-cache-dir poetry==${POETRY_VERSION}


ENV VIRTUAL_ENV=/chalkconf.env
ENV PATH=/chalkconf.env/bin:$PATH
RUN python -m venv /chalkconf.env

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

WORKDIR /config-tool

COPY pyproject.toml poetry.lock $WORKDIR/
RUN poetry install --with dev --no-plugins --no-root

RUN apk add --update --no-cache alpine-sdk \
        pcre \
        gcompat \
        upx \
        binutils \
        libffi \
        libffi-dev \
        tk
