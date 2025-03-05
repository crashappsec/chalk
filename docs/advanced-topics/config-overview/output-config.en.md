---
title:
description:
---

# Chalk Mark Templates

Chalk decides what metadata keys should be added to a chalk mark based
on what keys are listed in the active `mark_template`. You can
configure a mark template for any command that creates chalk marks,
currently:

- `chalk insert` (the _insert_ operation)
- `chalk docker build` (the _build_ operation)
- `chalk setup` (the _setup_ operation)
- `chalk load` (the _load_ operation)

Just because a key is added in a mark template doesn't mean that the
mark will contain the key; the requested metadata needs to be
available at Chalk time. If it doesn't exist, Chalk omits the data
instead of adding empty value to the output.

Chalk marks are always output as JSON objects. The following keys are
required to be in a Chalk mark and will always be added, even if not
listed in the active `mark_template` (or even if turned off in the
template):

- `MAGIC`
- `CHALK_ID`
- `CHALK_VERSION`
- `METADATA_ID`

## Existing Chalk Mark Templates

Chalk ships with several templates you can use for your chalk marks,
depending on what information you want to keep around in your
artifacts.

You can list available templates and see what keys they set by running
`chalk help templates`.

If you wish to switch out the template that is being used for a
particular chalking operation, you need to reconfigure the operation,
which is done by setting the `mark_template` field in the operation's
`outconf` section, as shown below.

If you don't like any of the existing templates, you can easily edit
the ones provided, or create your own.

## Editing Chalk Mark Templates

Let's say you're using the default chalk mark template for insertion,
but you have enabled SBOMs and you don't like they're not written into
chalk marks!

The default `mark_template` object for insertion is called
`mark_default`. For each key you want the template to use, you add a
`key` object in it, with the name of the key, and set it's `use` field
to `true`.

Let's say that you also HATE that we write the `ARTIFACT_TYPE` in by
default, because, hey, that's redundant! You just have to set the
appropriate field to `false`.

The following configuration will do it!

```
mark_template mark_default {
  key SBOM {
    use: true
  }

  key ARTIFACT_TYPE {
    use: false
  }
}
```

In the Chalk config file, the above syntax doesn't overwrite the
entire existing template. The above syntax is 100% equal to:

```
mark_template.mark_default.key.SBOM.use          = true
mark_template.mark_default.key.ARTIFACT_TYPE.use = false
```

> ❗ The Chalk config file treats dot assignments and sections the
> same. The two notations are 100% interchangeable. And, the colon and
> the equals sign are the same thing.

Similarly, you can go for a combination of the two styles:

```
mark_template mark_default {
  key.SBOM.use         = true
  key.ARTIFACT_TYPE.use: false
}
```

> ⚠️ Mark templates only accept metadata keys available at
> 'chalk time'. Such keys are distinguished from 'run time' keys by
> their first character. Run-time keys always start with an
> underscore, whereas chalk-time keys do not.

## Creating New Chalk Mark Templates

You can use the exact same syntax as above to define new
templates. Any key you do not explicitly specify to use will NOT be
used, unless it's required in chalk marks.

> ❗ There are a few required fields (including `MAGIC`, `CHALK_ID` and
> `METADATA_ID`), that you do not have to specify. Even if you try to
> turn them off, they will still be added to a chalk mark.

Once you have added a new mark template to your configuration, all you
have to do to apply it is add your new report name into the
appropriate `outconf` field, as discussed below.

# Report Templates

Report templates specify what metadata gets added into reports. You
can use them for configuring what the primary report for any operation
will try to report. Similarly, you can use them to create custom
reports.

In many ways, report templates are similar to Chalk mark
templates. There are out-of-the-box templates that are also seen via
`chalk help templates`. You can edit them or replace them in the same
way.

The major difference is that report templates can contain ANY key,
whereas mark templates are limited to what's available at chalk
time. For an operation that inserts chalk marks, the data collection
for reporting is done after chalk marks are written, so keys only
available once an artifact is processed become available in the
report.

Similarly, when reporting in production environments with the `chalk
exec` command or the `chalk extract` command, you can report on any
available operational metadata from any one run of Chalk.

> ⚠️ When report templates are applied, chalk-keys are handled
> differently, depending on the operation. For insertion operations,
> they report what _would have been chalked_ (there is no requirement
> for your report to bubble up the fields actually chalked). Other
> operations report these keys only if they're extracted from
> artifacts.

To use the above template, we'd just have to tell the system when to
use this template, as described below.

Specifies what reporting templates to use for I/O on a per-command
basis. Only valid chalk commands are valid section names.

## Configuring Output Destinations

Virtually all output in Chalk is handled through a 'pub-sub'
(publish-subscribe) model. Chalk "publishes" data to "topics". To
listen to a topic:

1. Create a `sink_config`, which basically configures a specific
   output option, like a HTTP POST endpoint, an S3 bucket, or a log file.
2. Subscribe that configuration to the topic.
3. Optionally, unsubscribe any default configuration you'd like to remove.

All command reports are `published` to the `"report"` topic. If you
subscribe a sink configuration to the `"report"` topic, then you'll
get the default report sent to the sink per your configuration.

Custom reports get their own topic, and when you create a custom
report (see below), you will specify any `sink_config` objects to
auto-subscribe to the report.

> ❗ All other pub-topics should be considered internal; re-configure
> with care.

The documentation for each sink type will indicate what fields can be and/or need to be provided in the `sink_config`.

The default, out-of-the-box configuration (which you can rewrite)
creates a `sink_config` named `default_out`, that is subscribed
to a log file, `~/.local/chalk/chalk.log`.

To remove it, simply add to your configuration:

`unsubscribe("report", "default_out")`

> ☺ You can have multiple sinks configured simultaneously to send the
> report to multiple places (and the default configuration can do that
> via the above environment variables). If you want to send a
> different set of data, use a custom report instead.

## Adding additional reports

A `custom_report` section allows you to create secondary reports for
whatever purpose. For instance, in the default Chalk configuration,
the _primary_ report logs to a file, but a secondary report gives
summary information on the terminal.

Similarly, you could use a custom report to send summary statistics to
a central server. The report could even contain absolutely no data,
just providing a marker for when chalk successfully runs.

Or, you can use this to implement a second report that goes to a
different output location. For instance, you might want to send large
objects to cheap storage (SBOM and SAST output can get large), or send
more detailed logging to a data lake, or send a tiny bit of data to a
third party vendor.

You might consider a custom report as a failsafe, too. For instance,
when reporting from immutable or short-lived environments, you won't
want to use the built-in `report cache`, and should hedge against
network connectivity issues.

However! A custom report isn't even necessary if you just want to send
the default report to two places. Instead, you can simply add a second
`sink_config`, and independently subscribe that second sink
configuration to the `report` topic. When a topic publishes, _all_
subscribers get sent the report.

### Using Custom Reports

Custom reports require the following:

1. You must set the `report_template` field, which must be a string naming
   valid `report_template`, per above.
2. You must associate an output method, by first configuring an output
   sink (done via a `sink_config` section), and then add it to the
   custom report's `sink_configs` field (which is a list of valid sink
   configurations to get the report)
3. You can specify when the custom report should be run, based on what
   primary report runs, by adding the `use_when` field. This field is a
   list of strings which can contain any of the report names used in an
   outconf section (the same ones produced in the chalk `_OPERATION` key).

If you omit `use_when`, the report will run for any chalk command that
generates a report as a matter of course.

Additionally, you can set the `enabled` field to `false` if you want
to disable it (it's true by default).

> ❗ Sink configurations can have different requirements to set
> up. Within Chalk, see `chalk help sinks` for more details.

Putting it all together, here's a simple example of adding a custom
report that simply logs new `METADATA_ID`s to a log file whenever
chalking occurs:

```
report_template mdlog_report {
  key.METADATA_ID.use = true
}

sink_config mdlog_file {
  sink: "file"
  filename: "./mdlog.jsonl"
}

custom_report mdlog {
  report_template: "mdlog_report"
  sink_configs:    ["mdlog_file"]
  use_when:        ["insert", "build"]
}
```

We can test this configuration by putting it in `test.c4m` then:

```
chalk load test.c4m
echo "#!/bin/bash" > test_mark
chalk test_mark
cat mdlog.jsonl
```

You should see a line like:

```
[ { "_CHALKS" : [{ "METADATA_ID" : "0ZEQCN-N3RF-EQ87-MW1N74" }] } ]
```

## Available output sinks

As mentioned above, if you wish to control where to send reporting
data, you can create a `sink_config` object that configures one of the
below sink types. The descriptions for each sink type describe what
fields are required or allowed for each kind of sink.

Remember that to use a sink, you need to either assign it to a custom
report, or `subscribe()` it to a topic.

## file

- _Overview_
  Log appending to a local file
- _Detail_

| Parameter         | Type           | Required | Description                                                                      |
| ----------------- | -------------- | -------- | -------------------------------------------------------------------------------- |
| `filename`        | `string`       | yes      | The file name for the output.                                                    |
| `log_search_path` | `list[string]` | no       | An ordered list of directories for the file to live.                             |
| `use_search_path` | `bool`         | no       | Controls whether or not to use the `log_search_path` at all. Defaults to `true`. |

The log file consists of rows of JSON objects (the `jsonl` format).

The `log_search_path` is a Unix style path (colon separated) that the
system will march down, trying to find a place where it can open the
named, skipping directories where there isn't write permission. In no
value is provided, the default is `["/var/log/", "~/log/", "."]`.

If the `filename` parameter has a slash in it, it will always be tried
first, before the search path is checked.

If nothing in the search path is openable, or if no search path was
given, and the file location was not writable, the system tries to
write to a temporary file as a last resort.

If `use_search_path` is false, the system just looks at the `filename`
field; if it's a relative path, it resolves it based on the current
working directory. In this mode, if the log file cannot be opened,
then the sink configuration will error when used.

## rotating_log

- _Overview_
  A self-truncating log file
- _Detail_

| Parameter           | Type          | Required | Description                                                |
| ------------------- | ------------- | -------- | ---------------------------------------------------------- |
| `filename`          | `string`      | true     | The name to use for the log file.                          |
| `max`               | `Size`        | true     | The size at which truncation should occur.                 |
| `log_search_path`   | list[string]` | false    | An ordered list of directories for the file to live.       |
| `truncation_amount` | `Size`        | false    | The target size to which the log file should be truncated. |

When the file size reaches the `max` threshold (in bytes), it is
truncated, removing records until it has truncated `truncation_amount`
bytes of data. If the `truncation_amount` field is not provided, it is
set to 25% of `max`.

The log file consists of rows of JSON objects (the `jsonl`
format). When we delete, we delete full records, from oldest to
newest. Since we delete full reocrds, we may delete slightly more than
the truncation amount specified as a result.

The deletion process guards against catastrophic failure by copying
undeleted data into a new, temporary log file, and swapping it into
the destination file once finished. As a result, you should assume you
need 2x the value of `max` available in terms of disk space.

`max` and `truncation_amount` should be Size objects (e.g., `<< 100mb >>` )

## s3

- _Overview_
  S3 object storage
- _Detail_

| Parameter | Type     | Required | Description                                         |
| --------- | -------- | -------- | --------------------------------------------------- |
| `secret`  | `string` | true     | A valid AWS auth token                              |
| `uid`     | `string` | true     | A valid AWS access identifier                       |
| `uri`     | `string` | true     | The URI for the bucket in `s3:` format; see below   |
| `region`  | `string` | false    | The region (defaults to "us-east-1")                |
| `extra`   | `string` | false    | A prefix added to the object path within the bucket |

To ensure uniqueness, each run of chalk constructs a unique object
name. Here are the components:

1. An integer consisting of the machine's local time in ms
2. A 26-character cryptographically random ID (using a base32 character set)
3. The value of the `extra` field, if provided.
4. Anything provided in the `uri` field after the host.

These items are separated by dashes.

The timestamp goes before the timestamp to ensure files are listed in
a sane order.

The user is responsible for making sure the last two values are valid;
this will not be checked; the operation will fail if they are not.

Generally, you should not use dots in your bucket name, as this will
thwart TLS protection of the connection.

## post

- _Overview_
  HTTP/HTTPS POST
- _Detail_

| Parameter          | Required | Description                                                    |
| ------------------ | -------- | -------------------------------------------------------------- |
| `uri`              | true     | The full URI to the endpoint to which the POST should be made. |
| `content_type`     | false    | The value to pass for the "content-type" header                |
| `headers`          | false    | A dictionary of additional mime headers                        |
| `disallow_http`    | false    | Do not allow HTTP connections, only HTTPS                      |
| `timeout`          | false    | Connection timeout in ms                                       |
| `pinned_cert_file` | false    | TLS certificate file                                           |

The post will always be a single JSON object, and the default
content-type field will be `application/json`. Changing this value
doesn't change what is posted; it is only there in case a particular
endpoint requires a different value.

If HTTPS is used, the connection will fail if the server doesn't have
a valid certificate. Unless you provide a specific certificate via the
`pinned_cert_file` field, self-signed certificates will not be
considered valid.

The underlying TLS library requires certificates to live on the file
system. However, you can embed your certificate in your configuration
in PEM format, and use config builtin functions to write it to disk,
if needed, before configuring the sink.

If additional headers need to be passed (for instance, a bearer
token), the `headers` field is converted directly to MIME. If you
wish to pass the raw MIME, you can use the `mime_to_dict` builtin.
For example, the default configuration uses the following sink
configuration:

```
sink_config my_https_config {
  enabled: true
  sink:    "post"
  uri:     env("CHALK_POST_URL")

  if env_exists("TLS_CERT_FILE") {
    pinned_cert_file: env("TLS_CERT_FILE")
  }

  if env_exists("CHALK_POST_HEADERS") {
    headers: mime_to_dict(env("CHALK_POST_HEADERS"))
  }
}
```

## stdout

- _Overview_
  Write to stdout
- _Detail_

When configuring, this sink take no configuration parameters.

## stderr

- _Overview_
  Write to stderr
- _Detail_

This sink take no configuration parameters.
