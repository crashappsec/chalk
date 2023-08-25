# Local Chalk Server

**Note**: most examples assume `PWD` is `server/` , not root of the repo,
unless otherwise specified.

## Default Servers

### HTTP

```sh
../make http
```

[http://localhost:8585](http://localhost:8585) should show chalk API docs.

### HTTPS Server

```sh
../make https
```

If you choose to run https server and are using self-signed certificate,
note that in order to access chalk API in the browser you might need
to install the certificate in the browser certificate store.
The URL of the site is [https://localhost:5858](https://localhost:5858).

Alternatively easy way to test the api is via `curl` and `--insecure` flag:

```sh
curl https://localhost:5858 --insecure
```

## Server CLI

Above commands start default http/https servers used for testing.
The server however has its own CLI.
See available options via `./make` script which will normalize
all commands to run in docker:

```sh
../make server --help
```

#### Running the server AND generate certificate

By providing TLS parameters to `run` command, it will create
the certificate if one does not already exist.

```sh
../make server \
    run \
        --certfile=cert.pem \
        --keyfile=cert.key \
        --domain=chalk.crashoverride.local
```

#### Generate certificate only

```sh
../make server \
    certonly \
        --certfile=cert.pem \
        --keyfile=cert.key \
        --domain=chalk.crashoverride.local
```

#### Running the server with existing certificate

```sh
../make server \
    run \
        --certfile=cert.pem \
        --keyfile=cert.key
```

## Database

By default server uses SQLite. However server can point to any other
[SQLAlchemy supported database](https://docs.sqlalchemy.org/en/20/dialects/#included-dialects).
To customize that, pass `DATABASE_URL` environment variable
with the URL to the database of your choosing.

### Browse SQLite

```sh
../make sqlite
```

Browse to [http://localhost:18080](http://localhost:18080)

## Run a test to insert data

### Manually

Simplest approach is to point `chalk` against the server by specifying
the following environment variables:

- `CHALK_POST_URL` - full URL for the server report endpoint
- `TLS_CERT_FILE` - path to the TLS cert if the server is using self-signed cert

`chalk` will honor these vars and will send reports to that endpoint.

Note that if you are using `TLS`, the certificate domain will need to match
the URL provided in `CHALK_POST_URL`. Default server uses `chalk.local` domain.
In order for chalk to be able to reach that domain, you might need to:

- Check that TLS cert domain is in your `/etc/hosts` or equivalent
  entry based on your OS.

  - `/etc/hosts` on OS X should have an entry like:

    ```
    127.0.0.1 chalk.local
    ```

  - Verify that ping works by `ping <domain>`.
    If not, you probably need to refresh your cache:

    - On OS X:

    ```sh
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
    ```

### Run Test

Alternatively you can run a test which will send some tests to the
http server:

```sh
# from root of the repo
./make tests test_sink.py::test_post_http_fastapi
```
