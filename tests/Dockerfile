FROM python:3.11.3-alpine3.17

ARG POETRY_VERSION=1.5.1

# install poetry
RUN apk add --no-cache \
        curl \
        gcc \
        libressl-dev \
        musl-dev \
        libffi-dev && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile=minimal && \
    source $HOME/.cargo/env && \
    pip install --no-cache-dir poetry==${POETRY_VERSION}

ENV VIRTUAL_ENV=/tests.env
ENV PATH=/tests.env/bin:$PATH
RUN python -m venv /tests.env

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

COPY pyproject.toml poetry.lock $WORKDIR/
RUN poetry install --no-plugins

# install chalk deps
RUN apk add --no-cache pcre gcompat

COPY --from=docker:24 /usr/local/bin/docker /usr/local/bin/docker

ENTRYPOINT ["/tests.env/bin/pytest"]