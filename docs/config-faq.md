---
title:
description:
---

# Frequently Asked Questions

## How do I check the currently loaded config?

If you would like to see what configuration is currently loaded in the chalk binary, use `dump` command.
This will output to terminal the currently loaded configuration in the form of loaded components, ex:

```sh
$ chalk load https://chalkdust.io/debug.c4m
$ chalk dump
use debug from "https://chalkdust.io"
```

If you would like to see the full configuration, instead of components, run:

```sh
$ chalk dump cache
               URL: https://chalkdust.io/debug
 ┌┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┐
 ┊  log_level: "trace"                                      ┊
 ┊                                                          ┊
 └┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┘
```

## How do I re-load the default config?

If you have loaded several configuration files and would like to restart with a clean slate, you can always go back to the chalk default empty configuration by running:

```sh
$ chalk load default --replace
```

This will remove _all_ loaded configs. Checking state via `chalk dump` should produce the following output:

```
$ chalk dump
# The default config is empty. Please see chalk documentation for examples.
```

## How do I load a config on top of the existing config?

If you would like to add a component to the config currently loaded in a chalk binary, simply run

```sh
$ chalk load <component>
```

For example, if your currently loaded configuration looks like this:

```sh
$ chalk dump
use debug from "https://chalkdust.io"
```

and you would like to add the `embed_sboms.c4m` component for compliance, you would run:

```sh
$ chalk load https://chalkdust.io/embed_sboms.c4m
```

Once loaded, the output of chalk dump should look like this:

```sh
$ chalk dump
use debug from "https://chalkdust.io"
use embed_sboms from "https://chalkdust.io"
```

## How do I load a config that replaces the existing config?

To replace the currently loaded config with an incoming config, run:

```sh
$ chalk load <component> --replace
```
