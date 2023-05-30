# Compiling and Running Chalk

First compilation of chalk can be really slow (in excess of 10min), as required
packages are fetched for the first time, however subsequent builds should be
significantly faster.

### Via local install

- Install [nimble](https://nim-lang.org/install.html)
- **Compile** via `nimble build -d:release`
- **Run** via `./chalk`

### Via Docker

#### Prerequisites

Install [`docker`](https://docs.docker.com/engine/install/) and
[`docker-compose`](https://docs.docker.com/compose/install/) in your system.

#### Compiling & Running

- **Compile** via `docker compose build chalk`
- **Run** via `docker compose run --rm chalk --help`

##### Common Issues

**1. If you are getting**

```
 > [prod 2/7] RUN apk add --no-cache g++ pcre-dev:
#0 0.320 ERROR: Unable to lock database: Permission denied
#0 0.320 ERROR: Failed to open apk database: Permission denied
```

Rebuild via `DOCKER_BUILDKIT=0 docker compose build chalk --no-cache`
