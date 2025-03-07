# Integrating Chalk with CI/CD Platforms

## Why Integrate Chalk into Your CI/CD Pipeline?

Modern software development relies heavily on Continuous Integration and Continuous Deployment
(CI/CD) pipelines to automate building, testing, and deploying applications. These pipelines
represent a critical juncture in the software lifecycle – the moment where source code transforms
into deployable artifacts that will eventually run in production environments.

Integrating Chalk into your CI/CD pipeline creates several powerful advantages:

### 1. Automatic Traceability Across the Software Lifecycle

When Chalk operates at build time, it creates a permanent connection between your source code and
your production artifacts. This connection enables developers, operations teams, and security
professionals to trace any production artifact back to its exact source commit, build environment,
and pipeline execution. This traceability becomes invaluable when investigating incidents,
debugging production issues, or conducting security forensics.

### 2. Enhanced Software Supply Chain Security

Recent high-profile supply chain attacks like SolarWinds have highlighted the
importance of knowing exactly what goes into your software. With Chalk in your
pipeline, you can automatically:

- Generate Software Bills of Materials (SBOMs) for every build
- Digitally sign artifacts to verify their provenance
- Collect and store code ownership information
- Document the build environment and dependencies

This information can help satisfy regulatory requirements (like NIST's SSDF or the US Executive
Order on Improving the Nation's Cybersecurity) and provide evidence for security certifications.

### 3. Improved Developer and Operations Collaboration

When an issue arises in production, operations teams often struggle to identify which team is
responsible for a particular service or artifact. By embedding ownership and repository information
directly into artifacts, Chalk eliminates the typical back-and-forth of "who owns this?" and allows
teams to route incidents to the correct owners immediately.

### 4. Automated Inventory Management

As organizations grow, keeping track of all deployed software becomes increasingly challenging.
Chalk automatically creates data that can be used to maintains a real-time inventory of
applications, helping organizations understand what they have running, where it's running, and who's
responsible for it – without requiring manual tracking or documentation.

### 5. Build Context Preservation

CI/CD systems contain valuable metadata about the build process that is typically lost once
artifacts are deployed. Chalk preserves this ephemeral information by embedding it directly into the
artifacts, ensuring it remains available throughout the software's lifecycle.

## Integrating Chalk with Common CI/CD Platforms

Now that we understand why integrating Chalk into CI/CD pipelines is valuable, let's explore how to
implement it on several popular platforms.

### GitHub Actions

GitHub Actions is a popular CI/CD platform integrated directly into GitHub repositories. Here's how
to incorporate Chalk into your GitHub Actions workflows:

1. Add [setup-chalk-action](https://github.com/crashappsec/setup-chalk-action) step:

   ```yaml
   - name: Set up Chalk
     uses: crashappsec/setup-chalk-action@main
     with:
       load: |
         https://chalkdust.io/run_sbom.c4m
         https://chalkdust.io/run_sast.c4m
         https://chalkdust.io/run_secret_scanner.c4m
   ```

1. Use Chalk. Setup action automatically wraps all `docker` invocations so for
   example building docker image via `action-buils`, chalk will wrap that
   build automatically:

   ```yaml
   - name: Build and push
     uses: docker/build-push-action@v6
     with:
       push: true
       tags: user/app:latest
   ```

1. To insert chalk marks for any other files use `chalk insert`:

   ```yaml
   - name: Build application
     run: |
       # Your normal build commands here
       make myapp

   - name: Apply Chalk mark
     run: |
       chalk insert ./myapp
   ```

1. Optionally you can store chalk log as GitHub artifact:

   ```yaml
   - name: Upload Chalk report
     uses: actions/upload-artifact@v3
     with:
       name: chalk-report
       path: ~/.local/chalk/chalk.log
   ```

### GitLab Pipelines

GitLab CI/CD is another popular platform with built-in CI/CD capabilities.
Here's a simple example of one way to integrate Chalk by installing it in
`before_script` with [`setup.sh`]:

```yaml
# .gitlab-ci.yml
build:
  image: docker:cli
  stage: build
  services:
    - docker:dind
  variables:
    CHALK_URL: https://crashoverride.run/setup.sh
  before_script:
    - apk add curl --no-cache
    - >
      sh <(curl -fsSL $CHALK_URL) --load="
        https://chalkdust.io/run_sbom.c4m
        https://chalkdust.io/run_sast.c4m
        https://chalkdust.io/run_secret_scanner.c4m
      "
  script:
    - docker buildx build -t myimage .
```

### Other CI/CD

Similarly Chalk can be installed in any CI/CD system via [`setup.sh`]:

```bash
sh <(curl -fsSL https://crashoverride.run/setup.sh) --load="
  https://chalkdust.io/run_sbom.c4m
  https://chalkdust.io/run_sast.c4m
  https://chalkdust.io/run_secret_scanner.c4m
"
```

## Advanced CI/CD Integration Patterns

Beyond basic integration, here are some advanced patterns for using Chalk in CI/CD pipelines:

### Enabling And Verifying Attestations

See [Attestation TODO](../advanced-topics/attestation.en.md) guide.

### Running External Tools

To enhance security by automatically running SBOM, SAST, and secret scanning tools
by loading these components:
load these components:

- https://chalkdust.io/run_sbom.c4m
- https://chalkdust.io/run_sast.c4m
- https://chalkdust.io/run_secret_scanner.c4m

## Best Practices for CI/CD Integration

- **Store Chalk binary in your artifact repository**: Instead of downloading Chalk in every
  pipeline run, consider storing the binary in your organization's artifact repository for faster
  and more reliable access.

- **Version pin your Chalk binary**: Explicitly specify which version of Chalk to use to ensure
  consistent behavior across pipeline runs.

- **Use CI/CD secrets for sensitive configuration**: Never hardcode API keys, passwords, or
  other sensitive information in your pipeline configuration.

- **Cache the Chalk configuration**: For complex configurations, consider creating a custom Docker
  image with Chalk pre-installed and configured.

- **Incorporate Chalk verification in deployment gates**: Before promoting artifacts to production,
  verify their Chalk marks to ensure they haven't been tampered with.

- **Integrate with security scanning**: Use the security information collected by Chalk (SBOMs,
  SAST results) as input for additional security scanning tools.

- **Include Chalk reports in compliance documentation**: For regulated industries, archive Chalk
  reports alongside other build artifacts to help meet compliance requirements.

## Troubleshooting CI/CD Integration

### Common Issues

- **Missing Git metadata**: Ensure your CI/CD checkout step fetches the full repository history to
  allow Chalk to capture accurate git information.

- **Docker-in-Docker issues**: When using Chalk with Docker in CI/CD environments, ensure your
  container runtime has the necessary permissions.

- **File permission problems**: CI/CD environments often run with restricted permissions. Ensure
  Chalk has write access to the artifacts it needs to mark.

### Debugging Tips

- Increase Chalk's log level for more verbose output by loading `debug.c4m`
  module from https://chalkdust.io/debug.c4m:

  ```yaml
  - name: Set up Chalk
    uses: crashappsec/setup-chalk-action@main
    with:
      load: |
        https://chalkdust.io/debug.c4m
  ```

- Use the `--show-config` flag to debug configuration issues:

  ```bash
  chalk --show-config version
  ```

- Test your Chalk configuration locally before integrating it into your CI/CD pipeline.

## Wrapping-up

Integrating Chalk into your CI/CD pipeline allows you to automatically collect valuable metadata
about your software, create a permanent link between source code and production artifacts, and
enhance your security posture with supply chain verification.

By following the examples and best practices in this guide, you can implement Chalk in a way that
adds minimal overhead to your build process while providing substantial benefits throughout your
software's lifecycle.

Remember that the specific integration approach may vary based on your organization's requirements
and existing toolchain. Chalk's flexibility allows it to fit into virtually any CI/CD process,
whether you're building traditional applications, containers, or cloud native services.

[`setup.sh`]: https://github.com/crashappsec/setup-chalk-action/blob/main/setup.sh
