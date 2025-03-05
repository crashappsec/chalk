---
title: Customizing Configurations
description:
---

# Customizing Configurations

This guide is an introduction to editing configuration files, including defining custom configs and editing the default ones.

## Writing a custom config with a custom report template

Let's write a config that uses two templates to send data to two different sinks:

- one template is used to send data to an S3 bucket in AWS
- another template is used to populate data in a rotating file log in the local filesystem

We only want to send to S3 upon an `exec` and send all available information to it (using the builtin `report_all` template), and we only want to send a select set of information to the local filesystem upon a `build` or `insert` operation.

This is depicted in the following figure:

<!--![Custom Template](../../img/custom-template.png)-->

The configuration achieving the above is the following:

```con4m
# suppress stdout logs unless there is an error
log_level: "error"

# disable terminal output
custom_report.terminal_chalk_time.enabled: false
custom_report.terminal_other_op.enabled: false

# disable writing to default log
unsubscribe("report", "default_out")

# minimal report template
report_template report_localdisk {
  key.CHALK_VERSION.use                       = true
  key.DATETIME_WHEN_CHALKED.use               = true
  key.HOSTINFO_WHEN_CHALKED.use               = true
  key.NODENAME_WHEN_CHALKED.use               = true

  key._DATETIME.use                           = true
  key._CHALKS.use                             = true
  key._OP_ERRORS.use                          = true

  key.CHALK_ID.use                            = true
  key.PATH_WHEN_CHALKED.use                   = true
  key.ARTIFACT_TYPE.use                       = true
  key.OLD_CHALK_METADATA_ID.use               = true
  key.EMBEDDED_CHALK.use                      = true
  key.METADATA_ID.use                         = true
  key.DOCKER_FILE.use                         = true
  key.DOCKERFILE_PATH.use                     = true
  key.DOCKER_LABELS.use                       = true
  key.DOCKER_TAGS.use                         = true
  key._CURRENT_HASH.use                       = true
  key._VIRTUAL.use                            = true
  key._IMAGE_ID.use                           = true
  key._INSTANCE_CONTAINER_ID.use              = true
  key._INSTANCE_CREATION_DATETIME.use         = true
  key._REPO_TAGS.use                          = true
}

sink_config s3_sink_config {
  enabled: true
  sink:    "s3"
  region:  env("AWS_REGION")
  uri:     env("AWS_S3_BUCKET_URI")
  uid:     env("AWS_ACCESS_KEY_ID")
  secret:  env("AWS_SECRET_ACCESS_KEY")
}

# set up a custom template for saving information locally
sink_config chalk_log_file {
  sink: "rotating_log"
  enabled: true
  max: <<10mb>>
  filename: "/tmp/chalk_insert_build"
}

custom_report chalk_localdisk_logger {
  report_template: "report_localdisk"
  sink_configs: ["chalk_log_file"]
  use_when: ["insert", "build"]
}

custom_report chalk_s3_logger {
  report_template: "report_all"
  sink_configs: ["s3_sink_config"]
  use_when: ["exec"]
}

```

Notice that we have also suppressed local terminal output for the above report.

## Updating the default templates

Often times you won't need to write a custom config, but simply overwrite the builtin configuration, changing the default output for a given chalk operation or updating the used templates. This is easy in con4m. For instance, the default output configuration for `insert` is as follows:

```con4m
outconf insert {
  mark_template:          "mark_default"
  report_template:        "insertion_default"
}
```

If you want to use a "minimal" template for chalks inserted during an insert, all you need to specify in your config is

```con4m
outconf insert {
  mark_template:          "mark_minimal"
  report_template:        "insertion_default"
}
```

and that will overwrite the defaults.

If you want to use your own custom template, that you defined in your config, you may use that as well. For instance, assuming we have a `report_localdisk` template as in the previous section, we can specify

```con4m
outconf insert {
  mark_template: "minimal"
  report_template: "report_localdisk"
}
```

## Enabling or Disabling Specific Keys

If you would like to see a particular key enabled (or disabled) in a mark or report template, you can do that for individual keys instead of writing a whole new mark or report template.

For example, if you feel that the default reporting template for exec operations, `report_default`, is too noisy because it is always reporting process info that you don't care about, you can disable individual keys by adding the following to your config:

```con4m
report_template.report_default.key._PROCESS_PID.use: false
```

Enabling or disabling individual keys in specific templates takes the following format:

```
[template type].[template name].key.[key name].use: [bool]
```

Note that even if a particular key is explicitly enabled, the key _will not_ show up in the resulting chalk report or chalk mark if the data is not available.
