## Running the server via gunicorn (HTTP)

From the root of the repo run `docker compose run --rm --service-ports --use-aliases server`. Visit
localhost:8585 in your browser and you should be seeing the chalk docs.

#### Invoking this as a python program (HTTP)

- `docker compose run --rm --service-ports server sh -c "python $PWD/server/app/main.py --help"`
- go to `http://0.0.0.0:8585` in your browser

## Running the server without keys (HTTPS)

- `docker compose run --rm --service-ports --use-aliases server sh -c "python $PWD/server/app/main.py --domain chalk.crashoverride.local"`

## Running the server with existing keys (HTTPS)

- `docker compose run --rm --service-ports --use-aliases --env "CHALK_CERT_PARAMS=--keyfile=keys/host.key --certfile=keys/host.cert" server`

#### Invoking this as a python program (HTTPS)

- Place your keys in a location under `server/app` (e.g., `mkdir -p server/app/keys`), and pass them as arguments
  relative to server/app:
- `docker compose run --rm --service-ports --use-aliases server sh -c "python $PWD/server/app/main.py --keyfile keys/host.key --certfile keys/host.cert"`
- go to `https://0.0.0.0:8585` in your browser

## Browsing data

- Spin up sqlitebrowser via `docker compose run --rm --service-ports sqlitebrowser`. Navigate to
  `http://localhost:3000/`, select `"Open Database"` from the UI and select
  your database. Only databases in `/server/app/db/data` are visible to the
  container.

### Run a test to insert data

- Check that `chalk.crashoverride.local` is in your /etc/hosts or equivalent
  entry based on your OS.

  - `/etc/hosts` on OS X should have an entry like:
    `127.0.0.1 chalk.crashoverride.local`

- from the root of the repo run `docker compose run --rm tests test_sink.py::test_post_http_fastapi`.
  The test should pass.

- Spin up sqlitebrowser via `docker compose up -d sqlitebrowser`. Navigate to
  `http://localhost:3000/`, select `"Open Database"` from the UI and select `chalkdb.sqlite` as
  your database. You should see two tables, one for chalks one for stats

make a temp directory in the `chalk-internal` root if not already present:

`mkdir tmp`

and assuming /etc/hosts contains `127.0.0.1 tests.crashoverride.run` you can run

`CHALK_POST_URL="http://tests.crashoverride.run:8585/report" chalk insert --config-file=./usage_stats.conf tmp --no-embedded-config`

## Browse data

- Run `docker compose up sqlitebrowser`
- Browse to `localhost:3000`
- Open `sql_app.db` and browse around
