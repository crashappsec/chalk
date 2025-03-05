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

#### Step 1: Create a Workflow File

Create a `.github/workflows/chalk.yml` file in your repository:

```yaml
name: Build with Chalk

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3
      with:
        fetch-depth: 0  # Important: Fetch full history for complete git metadata

    - name: Download Chalk
      run: |
        curl -L -o chalk https://crashoverride.com/downloads/chalk-linux-amd64
        chmod +x chalk
        sudo mv chalk /usr/local/bin/

    - name: Build application
      run: |
        # Your normal build commands here
        make build

    - name: Apply Chalk mark
      run: |
        chalk insert ./bin/myapplication

    # For Docker-based applications
    - name: Build and mark Docker image
      run: |
        chalk docker build -t myorg/myapp:${{ github.sha }} .

    - name: Push Docker image
      run: |
        echo ${{ secrets.DOCKER_PASSWORD }} | docker login -u ${{ secrets.DOCKER_USERNAME }} --password-stdin
        chalk docker push myorg/myapp:${{ github.sha }}
```

#### Step 2: (Optional) Configure Chalk Output

If you want to store Chalk reports in GitHub, you can configure Chalk to output to a file and then
upload it as an artifact:

```yaml
- name: Configure Chalk
  run: |
    echo 'sink_config github_artifact { sink: "file"; filename: "chalk-report.json"; enabled: true; }' > chalk-config.c4m
    echo 'subscribe("report", "github_artifact")' >> chalk-config.c4m
    chalk load chalk-config.c4m

# After applying chalk mark
- name: Upload Chalk report
  uses: actions/upload-artifact@v3
  with:
    name: chalk-report
    path: chalk-report.json
```

### GitLab CI/CD

GitLab CI/CD is another popular platform with built-in CI/CD capabilities. Here's a simple example
of one way to integrate Chalk:

#### Step 1: Create a GitLab CI Configuration

Create or update your `.gitlab-ci.yml` file:

```yaml
stages:
  - build
  - mark
  - deploy

variables:
  CHALK_VERSION: "0.2.2"  # Update as needed

build:
  stage: build
  script:
    - make build
  artifacts:
    paths:
      - bin/myapplication

mark:
  stage: mark
  script:
    - curl -L -o chalk https://crashoverride.com/downloads/chalk-linux-amd64-${CHALK_VERSION}
    - chmod +x chalk
    - ./chalk insert bin/myapplication
    # For reporting to GitLab
    - mkdir -p reports
    - echo 'sink_config gitlab_report { sink: "file"; filename: "reports/chalk-report.json"; enabled: true; }' > chalk-config.c4m
    - echo 'subscribe("report", "gitlab_report")' >> chalk-config.c4m
    - ./chalk load chalk-config.c4m
    - ./chalk insert bin/myapplication
  artifacts:
    paths:
      - bin/myapplication
      - reports/
    reports:
      junit: reports/chalk-report.json

# For Docker-based applications
docker_build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - curl -L -o chalk https://crashoverride.com/downloads/chalk-linux-amd64-${CHALK_VERSION}
    - chmod +x chalk
    - ./chalk docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - echo "$CI_REGISTRY_PASSWORD" | docker login -u $CI_REGISTRY_USER --password-stdin $CI_REGISTRY
    - ./chalk docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

## Advanced CI/CD Integration Patterns

Beyond basic integration, here are some advanced patterns for using Chalk in CI/CD pipelines:

### Integrating with a Central Reporting Service

For enterprise deployments, you might want all Chalk reports to be sent to a central service for analysis:

```yaml
- name: Configure Chalk for central reporting
  run: |
    echo 'sink_config central_reporting { sink: "post"; uri: "https://chalk-reports.example.com/api/reports"; enabled: true; }' > chalk-config.c4m
    echo 'subscribe("report", "central_reporting")' >> chalk-config.c4m
    chalk load chalk-config.c4m
```

### Enabling Digital Signing

To add provenance verification capabilities:

```yaml
- name: Set up Chalk signing
  run: |
    echo "${CHALK_PRIVATE_KEY}" > chalk.key
    echo "${CHALK_PUBLIC_KEY}" > chalk.pub
    export CHALK_PASSWORD="${CHALK_KEY_PASSWORD}"
    chalk setup load
```

### Running SBOM and SAST Tools

To enhance security by automatically generating SBOMs and running security analysis:

```yaml
- name: Configure Chalk with security tools
  run: |
    echo 'run_sbom_tools: true' > chalk-config.c4m
    echo 'run_sast_tools: true' >> chalk-config.c4m
    chalk load chalk-config.c4m
```

### Integrating Chalk Verification into Deployment Pipelines

To verify the integrity of artifacts before deployment:

```yaml
- name: Verify artifact before deployment
  run: |
    chalk extract ./bin/myapplication
    if [ $? -ne 0 ]; then
      echo "Verification failed!"
      exit 1
    fi
```

## Best Practices for CI/CD Integration

1. **Store Chalk binary in your artifact repository**: Instead of downloading Chalk in every
   pipeline run, consider storing the binary in your organization's artifact repository for faster
   and more reliable access.

2. **Version pin your Chalk binary**: Explicitly specify which version of Chalk to use to ensure
   consistent behavior across pipeline runs.

3. **Use environment variables for sensitive configuration**: Never hardcode API keys, passwords, or
   other sensitive information in your pipeline configuration.

4. **Cache the Chalk configuration**: For complex configurations, consider creating a custom Docker
   image with Chalk pre-installed and configured.

5. **Incorporate Chalk verification in deployment gates**: Before promoting artifacts to production,
   verify their Chalk marks to ensure they haven't been tampered with.

6. **Integrate with security scanning**: Use the security information collected by Chalk (SBOMs,
   SAST results) as input for additional security scanning tools.

7. **Include Chalk reports in compliance documentation**: For regulated industries, archive Chalk
   reports alongside other build artifacts to help meet compliance requirements.

## Troubleshooting CI/CD Integration

### Common Issues

1. **Missing Git metadata**: Ensure your CI/CD checkout step fetches the full repository history to
   allow Chalk to capture accurate git information.

2. **Docker-in-Docker issues**: When using Chalk with Docker in CI/CD environments, ensure your
   container runtime has the necessary permissions.

3. **File permission problems**: CI/CD environments often run with restricted permissions. Ensure
   Chalk has write access to the artifacts it needs to mark.

### Debugging Tips

1. Increase Chalk's log level for more verbose output:

   ```bash
   chalk --log-level=verbose insert ./bin/myapplication
   ```

2. Use the `--show-config` flag to debug configuration issues:

   ```bash
   chalk --show-config insert ./bin/myapplication
   ```

3. Test your Chalk configuration locally before integrating it into your CI/CD pipeline.

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
