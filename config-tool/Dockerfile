FROM python:3.11.3-alpine3.17 as deps

ARG POETRY_VERSION=1.5.1

# install system eps
RUN apk add --no-cache git

# install poetry
RUN pip install --no-cache-dir poetry==${POETRY_VERSION} && \
    poetry self add "poetry-dynamic-versioning[plugin]"

ENV VIRTUAL_ENV=/chalkconf.env
ENV PATH=/chalkconf.env/bin:$PATH
RUN python -m venv /chalkconf.env

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

WORKDIR /config-tool

COPY pyproject.toml poetry.lock $WORKDIR/
RUN poetry install --with dev --no-plugins --no-root

# -------------------------------------------------------------------

FROM deps as build

# git to extract correct current version
COPY --from=git . .git/
COPY . /config-tool

# install via pip to get proper version tagged
RUN pip install .

# -------------------------------------------------------------------

FROM python:3.11.3-alpine3.17 as release

ENV VIRTUAL_ENV=/chalkconf.env
ENV PATH=/chalkconf.env/bin:$PATH
COPY --from=build /chalkconf.env /chalkconf.env

CMD ["chalkconf"]
