# Automatically run SAST tools on build

### Use Chalk to automatically run SAST tools such as Semgrep on every build

## Summary

Static Application Security Testing (SAST) is a type of security testing that
is run on the source code, byte code, or binary code of an application without
running the application itself. One of the most popular SAST tools is the open
source tool [Semgrep](https://semgrep.dev/docs/), which will scan your source
code for vulnerabilities, secrets leakage, and other issues according to a set
of rules for each supported language, outputting a list of results that can be
addressed by the security team. Chalk supports Semgrep integration out of the
box, and other SAST tools can be added via the tools plugin.

This how-to uses Chalk to automate running Semgrep on build in three steps:

1. Configure Chalk to run Semgrep on build.

1. Build software using Docker that automatically generates SAST reports.

## Steps

### Before you start

You should have a working installation of Chalk. If not, see
[Installation Guide](./install.md).

### Step 1: Configure Chalk to run Semgrep on build

Chalk can load remote modules to reconfigure functionality. For this guide, we
will be loading SAST modules:

```bash
$ chalk load https://chalkdust.io/run_sast.c4m
$ chalk load https://chalkdust.io/embed_sast.c4m
```

These modules:

- `run_sast.c4m` - enable running SAST tools during builds
- `embed_sast.c4m` - embeds SAST findings into the chalk mark.
  Note that SAST results can be quite large which will increase the artifact
  size. If that is a concern, we recommend shipping SAST data to and external
  sink such as either S3 or an API.

The resulting binary will be fully configured, and can be moved or copied to
other machines without losing the configuration.

There's nothing else you need to do to keep this new configuration -- Chalk
rewrites data fields in its own binary when saving the configuration changes.

You can always check what configuration has been loaded by running:

```bash
$ chalk dump
```

### Step 2: Build software

Let's pick an off-the-shelf project and treat it like we're building part of it
in a build pipeline. We'll use a sample Docker project called `wordsmith`.

To clone and build the `wordsmith` project, run:

```bash
git clone https://github.com/dockersamples/wordsmith
cd wordsmith/api
chalk docker build -t localhost:5000/wordsmith:latest .
```

You'll see Docker run normally (it'll take a minute or so). Once Docker is
finished, you'll see some summary info from chalk on your command line in JSON
format.

The terminal report (displayed after the docker ouput) should look like this:

```json
[
  {
    "_OPERATION": "build",
    "_CHALKS": [
      {
        "CHALK_ID": "DNSNGG-YZX3-84VB-5KY9N2",
        "METADATA_ID": "TV21QT-RB9P-FTVD-MVDS1N",
        "DOCKERFILE_PATH_WITHIN_VCTL": "api/Dockerfile",
        "ORIGIN_URI": "https://github.com/dockersamples/wordsmith",
    [...]
```

To check that the container pushed has been successfully chalked, we can run:

```bash
$ chalk extract localhost:5000/wordsmith:latest
[
  {
    "_OPERATION": "extract",
    "_CHALKS": [
      {
        "_OP_ARTIFACT_TYPE": "Docker Image",
        "CHALK_ID": "DNSNGG-YZX3-84VB-5KY9N2",
        "METADATA_ID": "TV21QT-RB9P-FTVD-MVDS1N",
      }
    [...]
```

In particular, note that the `METADADATA_ID` for the build and extract operations
are the same -- this ID is how we will track the container.

Checking the raw chalk mark, we can see the SAST data has been embedded:

```bash
$ docker run -it --rm --entrypoint=cat localhost:5000/wordsmith:latest /chalk.json | jq
{
  "CHALK_ID": "DNSNGG-YZX3-84VB-5KY9N2",
  "METADATA_ID": "TV21QT-RB9P-FTVD-MVDS1N",
  [...]
  "SAST": {
    "semgrep": {
      "$schema": "https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/schemas/sarif-schema-2.1.0.json",
      "runs": [
        {
          "invocations": [{ "executionSuccessful": true, "toolExecutionNotifications": [] }],
          "results": [
            {
              "fingerprints": {
                "matchBasedId/v1": "23d567180068397303e8395a08b5a9dcd08bb7606d48ec550df13ac7e992afc60d17c99e8e24f3e5465b2ca0a525de4b1938a3527dd06d6a87623ccd565a9052_0"
              },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": { "uri": "src/main/java/Main.java", "uriBaseId": "%SRCROOT%" },
                    "region": {
                      "endColumn": 120,
                      "endLine": 26,
                      "snippet": {
                        "text": " try (ResultSet set = statement.executeQuery(\"SELECT word FROM \" + table + \" ORDER BY random() LIMIT 1\")) {"
                      },
                      "startColumn": 38,
                      "startLine": 26
                    }
                  }
                }
              ],
              "message": {
                "text": "Detected a formatted string in a SQL statement. This could lead to SQL injection if variables in the SQL statement are not properly sanitized. Use a prepared statements (java.sql.PreparedStatement) instead. You can obtain a PreparedStatement using 'connection.prepareStatement'."
              },
              "properties": {},
              "ruleId": "java.lang.security.audit.formatted-sql-string.formatted-sql-string"
            }
          ],
  [...]
```

If the image we have built here is run as a container, the chalk mark will be
included in a `/chalk.json` file in the root of the container file system.

If there's ever any sort of condition that chalk cannot handle (e.g., if you
move to a future docker upgrade without updating chalk, then use features
that `chalk` doesn't understand), chalk will _always_ make sure the original
`docker` command gets run if the wrapped command does not exit successfully.
This ensures that adding Chalk to a build pipeline will not break any existing
workflows.
