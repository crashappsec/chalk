FROM python:3.11.3-slim as base

# -------------------------------------------------------------------

FROM base as deps

ARG POETRY_VERSION=1.5.1
ENV PATH=/root/.local/bin:$PATH

RUN apt-get update && \
    apt-get install -y \
        git \
        curl \
        && \
    apt-get clean -y

RUN pip install pipx && \
    pipx install poetry==$POETRY_VERSION && \
    poetry self add "poetry-dynamic-versioning[plugin]"

ENV VIRTUAL_ENV=/server.env
ENV PATH=$VIRTUAL_ENV/bin:$PATH
RUN python -m venv $VIRTUAL_ENV

WORKDIR /server

COPY pyproject.toml poetry.lock /server/
RUN poetry install --no-plugins --no-root

ENTRYPOINT ["python", "-m", "server"]
CMD ["run", "--reload"]

# -------------------------------------------------------------------

FROM deps as build

# install staticx system deps
RUN apt-get update && \
    apt-get install -y \
    gcc \
    patchelf \
    scons

RUN pipx install staticx && \
    pipx install pyinstaller

# git to extract correct current version
COPY --from=git . .git/
COPY . /server/

# install via pip to get correct version/entrypoint
RUN pip install .
# create binary out of it
RUN pyinstaller \
    --onefile $VIRTUAL_ENV/bin/chalkserver \
    --path=/server.env/lib/python3.11/site-packages/ \
    --add-binary=$(ldconfig -p | grep libm.so.6 | cut -d">" -f2 | awk '{print $1}'):. \
    --add-binary=$(ldconfig -p | grep librt.so.1 | cut -d">" -f2 | awk '{print $1}'):. \
    --add-binary=$(ldconfig -p | grep libutil.so.1 | cut -d">" -f2 | awk '{print $1}'):.
# make that binary static
RUN staticx dist/chalkserver /chalkserver && \
    chmod 0755 /chalkserver

# -------------------------------------------------------------------

FROM alpine as static

COPY --from=build /chalkserver /bin/chalkserver

RUN /bin/chalkserver --version

ENTRYPOINT ["/bin/chalkserver"]
CMD ["run"]
