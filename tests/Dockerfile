FROM python:3.11.3-alpine3.17

ARG POETRY_VERSION=1.5.1

# install chalk runtime deps
RUN apk add --no-cache curl

# M1-only deps to compile wheels on ARM
RUN if uname -m | grep -Ei "arm|aarch"; then \
    apk add --no-cache \
        gcc \
        libffi-dev \
        musl-dev \
    ; fi

RUN pip install --no-cache-dir poetry==${POETRY_VERSION}

ENV VIRTUAL_ENV=/tests.env
ENV PATH=/tests.env/bin:$PATH
RUN python -m venv /tests.env

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

COPY pyproject.toml poetry.lock $WORKDIR/
RUN poetry install --no-plugins

COPY --from=docker:24 /usr/local/bin/docker /usr/local/bin/docker

ENTRYPOINT ["pytest"]
