## Running the server

From the root of the repo run
`docker compose run --rm --service-ports server`

or, if you want to generate certificates for a different domain than [tests.crashoverride.run]()

`CHALK_SERVER_CERT_GEN_DOMAIN="your.domain.here" docker compose run --rm --service-ports server`

Inject some data. For instance given the following config

```
crashoverride_usage_reporting_url = "http://tests.crashoverride.run:8585/beacon"
sink_config my_https_config {
  enabled: true
  sink:    "post"
  uri:     env("CHALK_POST_URL")

  if env_exists("CHALK_POST_HEADERS") {
    headers: mime_to_dict(env("CHALK_POST_HEADERS"))
  }
}

log_level = "trace"

ptr_url := ""
if env_exists("CHALK_POST_URL") {
  subscribe("report", "my_https_config")
  configured_sink := true
  if ptr_url == "" {
    ptr_url := env("CHALK_POST_URL")
  }
}
```

make a temp directory in the `chalk-internal` root if not already present:

`mkdir tmp`

and assuming /etc/hosts contains `127.0.0.1 tests.crashoverride.run` you can run

`CHALK_POST_URL="http://tests.crashoverride.run:8585/report" chalk insert --config-file=./usage_stats.conf tmp --no-embedded-config`

## Browse data

- Run `docker compose up sqlitebrowser`
- Browse to `localhost:3000`
- Open `sql_app.db` and browse around
