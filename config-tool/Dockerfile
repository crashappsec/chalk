FROM python:3.11.3-alpine3.17 as base

# install system deps
RUN apk add --no-cache git

# https://github.com/actions/runner/issues/2033
# This is needed because the container runs as a different user than likely
# owns the checked-out version of the repository. Most likely the container is
# running as root and everything is owned by the local user. This makes git
# complain about dubious ownership and fail to run. Adding this global setting
# disables the error. We know we're good here.
RUN git config --global safe.directory '*'

# -------------------------------------------------------------------

FROM base as deps

ARG POETRY_VERSION=1.5.1

# install poetry
RUN pip install --no-cache-dir poetry==${POETRY_VERSION} && \
    poetry self add "poetry-dynamic-versioning[plugin]"

ENV VIRTUAL_ENV=/chalkconf.env
ENV PATH=$VIRTUAL_ENV/bin:$PATH
RUN python -m venv $VIRTUAL_ENV

RUN mkdir -p /.cache/pypoetry \
    && chmod 0777 /.cache/pypoetry

WORKDIR /config-tool

COPY pyproject.toml poetry.lock /config-tool/
RUN poetry install --with dev --no-plugins --no-root

# -------------------------------------------------------------------

FROM deps as build

# git to extract correct current version
COPY --from=git . .git/
COPY . /config-tool

# install via pip to get proper version tagged
RUN pip install .

# -------------------------------------------------------------------

FROM base as release

ENV VIRTUAL_ENV=/chalkconf.env
ENV PATH=/chalkconf.env/bin:$PATH
COPY --from=build /chalkconf.env /chalkconf.env

CMD ["chalkconf"]
