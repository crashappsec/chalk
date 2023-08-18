FROM python:3.11.3-alpine3.17

ARG POETRY_VERSION=1.5.1

# install poetry
RUN apk add --no-cache \
        curl \
        gcc \
        libressl-dev \
        musl-dev \
        make \
        cmake \
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

ENV CHALK_API_PARAMS="--workers=4 --error-logfile=- --access-logfile=- --timeout 30"
ENV CHALK_API_PORT="8585"
ENV CHALK_CERT_PARAMS=""

CMD /tests.env/bin/gunicorn -k uvicorn.workers.UvicornH11Worker main:app --reload -b :${CHALK_API_PORT} ${CHALK_API_PARAMS} ${CHALK_CERT_PARAMS}