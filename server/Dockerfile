FROM python:3.11.3-alpine as base

ENV VIRTUAL_ENV=/server.env
ENV PATH=$VIRTUAL_ENV/bin:$PATH

COPY --from=gcr.io/projectsigstore/cosign:v2.1.1 /ko-app/cosign /usr/local/bin/cosign

# -------------------------------------------------------------------

FROM base as deps

ARG POETRY_VERSION=1.5.1
ENV PATH=/root/.local/bin:$PATH

RUN apk add --no-cache \
        git \
        curl

# deps to compile wheels on ARM
RUN if uname -m | grep -Ei "arm|aarch"; then \
    apk add --no-cache \
        gcc \
        libffi-dev \
        libc-dev \
    ; fi

RUN pip install pipx && \
    pipx install poetry==$POETRY_VERSION && \
    poetry self add "poetry-dynamic-versioning[plugin]"

RUN python -m venv $VIRTUAL_ENV
WORKDIR /server

COPY pyproject.toml poetry.lock /server/
RUN poetry install --no-plugins --no-root

ENTRYPOINT ["python", "-m", "server"]
CMD ["run", "--reload"]

# -------------------------------------------------------------------

FROM deps as build

# git to extract correct current version
COPY --from=git . .git/
COPY . /server/

# install via pip to get correct version/entrypoint
RUN pip install .

# -------------------------------------------------------------------

FROM base as release

COPY --from=build $VIRTUAL_ENV $VIRTUAL_ENV

RUN chalkserver --version

ENTRYPOINT ["chalkserver"]
CMD ["run"]
