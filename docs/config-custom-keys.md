# Collecting Custom Metadata Keys

# Introduction

While Chalk is capable of collecting a lot of different kinds of metadata out
of the box, it’s also easy enough to add custom keys via the configuration
file. In this document we will show a few ways to add custom keys, and then
walk through the process of loading our custom configuration.

Currently, Chalk requires that any custom key begins either with `X_` or
`_X_`. The former is used for _chalk-time_ keys, which are ones that can be
inserted into chalk marks. This data is only collected once when a chalk mark
is inserted. The latter form is used for keys that can collected (if data
is available) for any operation (_run-time_ keys), and are always reported
per-operation (anything without the underscore in a report on a chalked
artifact is reporting on what’s in the chalk mark).

The use of the letter `X` is meant to evoke the word _extension_, and is
required to avoid accidental collisions as we expand the kinds of metadata
that Chalk can collect. We chose this because it is common, in that `MIME`
essentially does the same thing.

# Adding Custom Keys

In Chalk, you can define a custom metadata key in the configuration file, by
adding a `keyspec` section. Every `keyspec` section has two required fields,
the `kind` property and the `type` property.

The `kind` property is an enumeration, and the two values we’ll cover here are:

- `ChalkTimeHost` which are chalk-time keys, where the information is recorded
  once for the entire run. We will only collect data for these keys at chalk
  time. These keys never have a leading underscore, and when customizing, must
  start with `X_`.
- `RunTimeHost` keys can collect information at any phase. These keys must
  start with a leading underscore.

The other two options are for per-artifact data collection.

Through the rest of this section, we’ll build a custom configuration file
(which should have a `.c4m` extension; we use `test.c4m`), and then below, we
will show how to configure reporting, load the configuration, and use it all.

For custom keys, we generally recommend you keep everything strings, meaning
you will set the `type` field to `string`. Your strings will get escaped and
put into JSON strings when reporting.

### Our first custom key

Here, we are adding a hardcoded value. Whenever `chalk` inserts or reports this
metadata key, you should expect to see the same hardcoded value.

```con4m
# test.c4m
# Hardcode a value.
keyspec X_VALUE {
  kind:     ChalkTimeHost
  type:     string
  value:    "hello"
}
```

## Basic dynamic keys

With Chalk, you can do more dynamic collection as well. For instance, you can
collect the value of a specific environment variable:

```con4m
# test.c4m
# Get a value from an environment variable `ENV_VAR`.
keyspec X_ENV_VAR {
  kind:     ChalkTimeHost
  type:     string
  value:    env("ENV_VAR")
}
```

You can see the use of a builtin function named `env`. Chalk has many such
functions. You can see full documentation from the command line by typing
`chalk help builtins`; they will be presented in tables, sorted by category.

You’ll notice the `run` builtin allows us to easily capture all `stdout` and
`stderr` for a shell command. We can combine that with the `strip` builtin,
which removes leading and trailing white space:

```con4m
# test.c4m
# Get a value from the output of system command.
keyspec X_CMD {
  kind:     ChalkTimeHost
  type:     string
  value:    strip(run("echo world"))
}
```

## Callbacks

Using the `value` field has a few limitations:

- Everything you need to do must be doable as a single expression; you can’t
  add a block of code here.
- The code you add will get evaluated on every single run of Chalk, even if
  your program doesn’t end up asking for the `X_CMD` key. In some sense, that
  should be expected if you think of your config file as a program, where we are
  assigning to the `keyspec.X_CMD.value` attribute.

Both of these issues can be addressed if we create a simple function. Let’s
define a new `keyspec` object that makes use of one:

```con4m
# test.c4m
# For more advanced keys, if you need to do any special processing
# you can define a value callback where you can have more advanced logic.
keyspec X_FUNC {
  kind:     ChalkTimeHost
  type:     string
  callback: func key_callback
}

func key_callback(contexts) {
  return "hello " + env("ENV_VAR")
}
```

Here, you can see that, instead of using the `value` property, we set the
`callback` property. These two properties are mutually exclusive; your
configuration will not validate if you do both.

The `contexts` parameter is a colon-separated list of any contexts, which,
if using Chalk with docker, will be the available docker contexts. This is a
`string`, and your callback must accept one and only one string. The return
value in this case is also a `string` because we defined our `keyspec` to take
a string. All of these types are automatically validated when you try to load
your configuration. They do not need to be specified, but you may do so if you
like:

```con4m
func key_callback(contexts : string) -> string {
  return "hello " + env("ENV_VAR")
}
```

## Configuring Chalk to report keys

The above examples show how to define new keys, but doesn’t cover
how to turn them on. More detailed documentation is at
[Custom Configuration](./config-custom.md). Here, we’ll just cover a few of the
more common examples without detailed explanation.

You can combine all of these in one configuration.

### Add your custom keys to Docker labels

Chalk has a built in reporting configuration called `chalk_labels` that we
can add our keys to. The below config augments what is already added to the
`chalk_labels` template, it doesn’t replace it:

```con4m
# Automatically add these keys as docker labels during docker build wrapping.
# By default, docker uses the "chalk_labels" mark template for that.
# See:
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/chalk.c42spec#L1659-L1675
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/base_chalk_templates.c4m#L421-L437
mark_template chalk_labels {
  key.X_VALUE.use   = true
  key.X_ENV_VAR.use = true
  key.X_CMD.use     = true
  key.X_FUNC.use    = true
}
```

### Add your custom keys to the Docker chalk mark

Chalk also uses reporting templates to figure out what to stick in a chalk
mark. By default, the predefined template used when chalking `docker`
containers is called `mark_default` and you can add to it like so:

```con4m
# Automatically add these keys to the chalk mark embedded in the docker image.
# By default, docker wrapping uses the "mark_default" template for embedded chalkmarks.
# See:
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/base_outconf.c4m#L20-L23
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/base_chalk_templates.c4m#L244-L330
mark_template mark_default {
  key.X_VALUE.use   = true
  key.X_ENV_VAR.use = true
  key.X_CMD.use     = true
  key.X_FUNC.use    = true
}
```

### Showing your keys on the command line

You might want your keys to show up on the summary report we print on the
command line when you are manually playing around with the command. The summary
report changes based on the command, but the defaults are that operations that
insert chalk marks use the `terminal_insert` template, and all other operations
use `terminal_rest`.

By the way, if you want other keys to show in this report that don’t already
show, you can add them to the list. Or, turn them off if they’re on, by setting
the value to `false`.

Finally, remember that, since we’re adding chalk-time keys in these examples,
even with the below configuration, they would only show up when running `chalk
extract` if they are added to the chalk mark.

If you want different behavior, also create a custom run-time key.

```con4m
# Show these values in terminal output when running docker build.
# The terminal output is reported via a custom report which uses the "terminal_insert" reporting template,
# and "json_console_out" which sends output to stdout.
# See:
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/ioconfig.c4m#L11-L16
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/base_report_templates.c4m#L2015-L2113
report_template terminal_insert {
  key.X_VALUE.use   = true
  key.X_ENV_VAR.use = true
  key.X_CMD.use     = true
  key.X_FUNC.use    = true
}

# Show these values in terminal output when running `chalk extract` on the built image.
# Similar to the above, the non-insert operations have a different custom report,
# which uses the "terminal_rest" reporting template.
# See:
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/ioconfig.c4m#L18-L23
# https://github.com/crashappsec/chalk/blob/f8124016855e5a10ab7995f3a8bdfc9e08f06042/src/configs/base_report_templates.c4m#L2115-L2219
report_template terminal_rest {
  key.X_VALUE.use   = true
  key.X_ENV_VAR.use = true
  key.X_CMD.use     = true
  key.X_FUNC.use    = true
}
```

You can also send your keys anywhere you want (Log files, S3 buckets, restful
endpoints, …). Please check the documentation for more details.

# Loading Your Custom Configuration

For this example, we’re going to first turn on docker entry point wrapping. Run
the following command to import the module that turns on docker entry point
wrapping:

```bash
$ chalk load https://chalkdust.io/wrap_entrypoints.c4m
```

When you run this command, you should see something like:

```bash
 Configuring Component: https://chalkdust.io/wrap_entrypoints
 Finished configuration for https://chalkdust.io/wrap_entrypoints
info:  [testing config]: Validating configuration.
info:  [testing config]: Configuration successfully validated.
info:  Configuration replaced in binary: /root/Code/co/chalk/chalk
info:  /root/.local/chalk/chalk.log: Open (sink conf='default_out')
info:  Full chalk report appended to: ~/.local/chalk/chalk.log
```

This only needs to be done once; `chalk` will add the module to its own
internal chalk mark, and automatically load it in future runs.

Now, we can load our own custom configuration, from the local file system:

```bash
$ chalk load test.c4m
```

# Using your binary

Now that the configs are loaded into our binary, every time we use that binary
your extensions will run.

We can do a docker build which will wrap the image and insert `/chalk.json`

```bash
$ echo FROM alpine | ENV_VAR=world ./chalk docker build -f - . -t chalk_custom_keys
...
[
  {
    "_OPERATION": "build",
    "_CHALKS": [
      {
        "CHALK_ID": "XHY0JF-KCER-KJPH-R3DHCZ",
        "METADATA_ID": "39C51D-076C-PNDM-SS8WAA",
        ...
      }
    ],
    "X_CMD": "world",
    "X_ENV_VAR": "world",
    "X_FUNC": "hello world",
    "X_VALUE": "hello",
    ...
  }
]
```

Note that the report now contains all the custom keys.

## Inspect image

Now that we have the `chalk_custom_keys` image, let’s extract the chalk mark
out of it:

```bash
$ chalk --log-level=none extract chalk_custom_keys
[
  {
    "_OPERATION": "extract",
    "_CHALKS": [
      {
        "CHALK_ID": "XHY0JF-KCER-KJPH-R3DHCZ",
        "X_CMD": "world",
        "X_ENV_VAR": "world",
        "X_FUNC": "hello world",
        "X_VALUE": "hello",
        ...
      }
    ],
    ...
  }
]
```

You can see that the chalk mark contains the same custom keys.

We can also directly inspect the `/chalk.json` too:

```bash
$ docker run -it --rm --entrypoint=cat chalk_custom_keys /chalk.json | jq
{
  "X_CMD": "world",
  "X_ENV_VAR": "world",
  "X_FUNC": "hello world",
  "X_VALUE": "hello",
  ...
}
```

Finally let’s see the labels for the image:

```bash
$ docker image inspect chalk_custom_keys | jq '.[].Config.Labels'
{
  ...
  "run.crashoverride.x-cmd": "world",
  "run.crashoverride.x-env-var": "world",
  "run.crashoverride.x-func": "hello world",
  "run.crashoverride.x-value": "hello"
}
```
