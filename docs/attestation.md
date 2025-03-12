# Attestation

Chalk can automatically attest all chalked artifacts via
[cosign](https://github.com/sigstore/cosign).

## Configure

To configure attestation, use `setup` command.
This will create an attestation key and will print out the password
used to encrypt the private key:

```sh
$ chalk setup
------------------------------------------
CHALK_PASSWORD=91-qmuffjZlKOWSh-5T2RA==
------------------------------------------
Write this down. In future chalk commands, you will need
to provide it via CHALK_PASSWORD environment variable.

$ ls chalk.{key,pub}
󰌆 chalk.key  󰌆 chalk.pub
```

You will need to safely save password as well as the key.
We recommend to save it as a secret in your CI/CD.

## Using in CI/CD

In order to use attestation in CI/CD, you will need to reference
the secrets created earlier.

### GitHub Actions

```yaml
- name: Set up Chalk
  uses: crashappsec/setup-chalk-action@main
  with:
    password: ${{ secrets.CHALK_PASSWORD }}
    public_key: ${{ secrets.CHALK_PUBLIC_KEY }} # content of chalk.pub
    private_key: ${{ secrets.CHALK_PRIVATE_KEY }} # content of chalk.key
```

### Other

Similarly attestation can be enabled via `setup.sh`:

```sh
$ CHALK_PASSWORD=<password> \
  sh <(curl -fsSL https://crashoverride.run/setup.sh) \
    --public-key=./chalk.pub \
    --private-key=./chalk.key
```

## Verifying Attestation

Once an artifact is chalked, `extract` command will verify its attestation.
Chalk will report whether the artifact attestation signature was successfully validated.
That works for both files and docker images:

```sh
$ chalk extract ./myapp # file
$ chalk extract docker.io/example/image # docker image
```
