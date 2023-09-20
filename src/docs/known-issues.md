## Known Issues

### Upcoming breaking changes

- The current algorithm for computing the `METADATA_HASH` and
  `METADATA_ID` values will change in the next release. For this
  reason alone, do *not* yet productionize Chalk.

- Image-based file formats place chalk marks in a file on the image;
  currently, different formats have different names for the mark. We
  will go to one by the next release.

### Documentation

- We need to provide more tutorial / HOWTO style documentation for
  actually using Chalk for real use cases.

- The TUI is not yet documented.

### Containers

- Attestation support is not yet finished.

- Our support for container marking is currently limited to Docker.

- We will be leveraging docker image attestation for chalk marking
  when available / desired, but that didn't quite make it into the
  alpha.

- Currently Chalk does not fully support chalking `buildx`.  This will
  be added in the near future.

- Chalk does not yet have any awareness of `docker compose`, `bake` or
  similar frameworks atop Docker.

- Similarly, Chalk does not yet capture any metadata around
  orchestration layers like Kubernetes or cloud-provider managed
  container solutions.

- Chalk does not yet handle Docker HEREDOCs (which we've found aren't
  yet getting heavy use).  For example:

```bash
RUN <<EOF
#!/bin/sh
echo hi
EOF
```

- Metadata keys handling runtime container image info should be
  collectable during exec when docker dockers are available, or if the
  exec'd process is running outside a container.

- Chalk does yet not handle remote contexts.

- There are currently cases where Chalk will incorrectly assume that
  the context is remote, causing it not to chalk (it still calls the
  original `docker` comand line, of course).


- Chalk currently only looks at metadata for build and push commands,
  even where it would be useful context. We're not doing run (though,
  you can report on the raw commands if you like).

In all these cases, when chalk runs, it will not interfere with the
underlying docker operation, but nothing will be chalked or reported.

### Other Platforms

- Currently, we are only publishing a Linux/x86 version. By the time
  of our public release (when source will become available under the
  GPLv3), we intend to support x86-64 and ARM64 for Linux and MacOS.

- We don't expect to support running chalk on Windows at release. When
  we get to it, it will probably require WSL2, as the implementation
  does assume posix compatability in a few places.

### Data collection

- Git is currently the only VCS system we collect data from.

- When running chalk in 'exec' mode, Chalk does not collect as much
  data as it should.  Significantly more data is coming soon.

- Additionally, 'exec' mode currently reports only once when starting
  up. We intend to give options to report periodically, or on-demand
  (basically an automated health-check service).

- The 'env' command should collect everything that can be collected in
  `exec` mode.

- There are plenty of other integrations we could add. Please let us
  know what you'd find valuable.

### Chalk Marks

- We currently do not handle any form of PE binaries, so do not chalk
  .NET or other Windows applications. 

- We are working toward in-the-browser JavaScript, but this probably
  won't be done till early next year.

- We will do more to more natively mark serverless apps over the next
  few months.

### Other

- The GPG-based signature scheme is not yet ready and should not be
  used, except for giving basic feedback.
