---
title:
description:
---

# About

Chalk supports collecting a wide range of metadata. The _type_ of data to be
collected, the directives that define _when_ collection will happen, and
the specification of _where_ the collected metadata will be getting _sent to_
are defined in _chalk configurations (configs)_. In this section we will cover
the core components of a chalk config and how they come together.

# Reports

Reports are at the core of chalk as its the mechanism using which chalk informs
about all the metadata it collects. We ask chalk to collect metadata we care
about, and that metadata _always_ ends up in a _report_, which is always in
JSON format.

Think of the report as a document or binary object that is sent to an output
destination: it can be embedded in an artifact (e.g., injected in an
executable), sent to a web endpoint, or stored to a local or remote filesystem.

A report might be getting emitted under different conditions -- this is most
often done during core chalk operations, such as an `insert`, `exec`, etc.
-- but reports can also be configured to be emitted periodically or when a
condition is met.

The sections below discuss how exactly we can configure reports to be emitted
and what data ends being part of a report.

## Report Templates

The exact metadata that will be included in a report are defined in
_templates_, which are collections of metadata keys (with optional conditions
on when said metadata should be getting emitted). The same template can be
re-used across many reports. However, each of the different reports making
use of the template could have different trigger/generation conditions and
different destinations.

Here is an excerpt from the template used by default for any metadata extracted
upon a chalk `insert` operation:

```con4m
report_template insertion_default {
  shortdoc: "The default template for insertion operations"
  [...]
  if not in_container() {
    key._OP_ALL_PS_INFO.use                   = false
  }
  key.CHALK_VERSION.use                       = true
  key.DATE_CHALKED.use                        = false
  key.TIME_CHALKED.use                        = false
  key.TZ_OFFSET_WHEN_CHALKED.use              = false
  key.DATETIME_WHEN_CHALKED.use               = false
  key.EARLIEST_VERSION.use                    = false
  [...]
  # Runtime host keys.
  key._ACTION_ID.use                          = true
  key._ARGV.use                               = true
  key._ENV.use                                = true
  key._TENANT_ID.use                          = true
  key._OPERATION.use                          = true
  key._TIMESTAMP.use                          = true
  [...]
}
```

We define a report template using the `report_template` type definition,
followed by the template name (in this case `insertion_default`). Note that
the template contains definitions about what metadata keys to export (set to
`true`), and which to avoid (set to `false`) and under which conditions. For
instance, if we are not within a docker container, `_OP_ALL_PS_INFO` metadata
will not be emitted.

For all default report template definitions, see the
[base report templates file](https://github.com/crashappsec/chalk/blob/main/src/configs/base_report_templates.c4m).

This guide will not cover individual metadata keys in depth. All you need to
know is that we can define whether or not we care about a particular key inside
a template.

## Chalkmark Templates

Chalkmarks are _always embedded_ in an artifact (e.g., an ELF file, a python
script, or a docker container). We consider an artifact that has a chalk mark
to be "chalked", and chalk marks are included as part of a chalk report if
reporting on a chalked artifact.

Contrary to regular reports, there are restrictions on what metadata can be
included in a chalkmark. In particular, no metadata that is collected at
runtime (such as network connections or currently running processes) can be
included in chalkmarks.

Templates that define which keys are included in a chalk mark are of the type
`mark_template`. For instance, here is the "minimal" `mark_template` which
comes as a built-in with chalk:

```con4m
mark_template minimal {
  shortdoc: "Used for minimal chalk marks."
  doc: """
This template is intended for when you're durably recording artifact
information, and want to keep just enough information in the mark to
facilitate other people being able to validate the mark.

This is the default for `docker` chalk marks.
"""
  key.DATETIME_WHEN_CHALKED.use               = true
  key.CHALK_PTR.use                           = true
  key.SIGNATURE.use                           = true
  key.INJECTOR_PUBLIC_KEY.use                 = true
  key.$CHALK_CONFIG.use                       = true
  key.$CHALK_IMPLEMENTATION_NAME.use          = true
  key.$CHALK_LOAD_COUNT.use                   = true
  key.$CHALK_PUBLIC_KEY.use                   = true
  key.$CHALK_ENCRYPTED_PRIVATE_KEY.use        = true
  key.$CHALK_ATTESTATION_TOKEN.use            = true
}
```

For all default chalk mark template definitions, see the
[base chalk templates file](https://github.com/crashappsec/chalk/blob/main/src/configs/base_chalk_templates.c4m).

In chalk, metadata keys that start with an `_` denote that the metadata is
collected at runtime. For instance, `_TIMESTAMP` corresponds to the timestamp
at the time of the _chalk operation_ (the time at which `chalk insert` or
`chalk docker build` was run). These keys will show up in chalk reports but
they will never appear in the embedded chalk marks.

Metadata keys starting with `$` denote keys that are used by chalk internally.
These keys must be embedded in the chalk mark for certain chalk features, such
as attestation, to work properly.

The report templates and mark templates associated
with supported chalk operations can be viewed
[here](https://github.com/crashappsec/chalk/blob/main/src/configs/base_outconf.c4m).

# Chalk Configurations

A chalk configuration is a collection of specifications that define _when_
reports are to be created (what will be the condition for publishing the
reports) and _where_ reports are to be sent (what will be the _sinks_ for the
reports). Moreover, they contain information on what templates are to be used
for the different reports.

## Sinks

A report can be sent to one or more destinations, known as output sinks, such
as the local filesystem, an S3 bucket, or an API. For instance, the
following snippet defines a sink named `log_file_sink`, which denotes that
reports sent to it will be getting stored in local disk at `~/test_sink.log`:

```con4m
sink_config log_file_sink {
  sink: "file"
  filename: "~/test_sink.log"
}
```

Note that simply loading a configuration with `log_file_sink` _defined_ will
not write any chalk reports to `~/test_sink.log` on chalk operations. To push
output to any sink, the sink must _subscribe_ to the types of reports that it
wants to monitor.

Virtually all output in Chalk is handled through a 'pub-sub'
(publish-subscribe) model. Chalk actions "publish" data to "topics", then sinks
listen to ("subscribe") those topics. For instance, to send _all_ reports to
your newly created `log_file_sink` you may specify

```con4m
subscribe("report", "log_file_sink")
```

Chalk comes with a set of sinks already configured for both chalkmarks and
reports, and different chalk operations send data to different sinks by
default. In particular, note that chalk reports sent to terminal will often
be an abbreviated version of the full report that is written to a log file or
pushed to s3.

For a full list of what sinks are available by default, see
[here](https://github.com/crashappsec/chalk/blob/main/src/configs/base_sinkconfs.c4m).

# Related Documentation and References

Beyond this document, there's an extensive amount of reference material for users:

| Name                                              | What it is                                      |
| ------------------------------------------------- | ----------------------------------------------- |
| [**Writing Custom Configs**](./config-custom.md)  | An guide on customizing configs.                |
| [**Frequently Asked Questions**](./config-faq.md) | Frequently asked questions about configuration. |
