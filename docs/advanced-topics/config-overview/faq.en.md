---
title:
description:
---

# Frequently Asked Questions

## How do I check the currently loaded config?

If you would like to see what configuration is currently loaded in the chalk binary, run:

```sh
chalk dump
```

This will output to terminal the currently loaded configuration in the form of loaded components, ex:

```
liming@system76-pc:~/workspace/chalk$ ./chalk dump
use xxx from "/home/liming/workspace/chalk"
```

If you would like to see the full configuration, instead of components, run:

```sh
chalk dump cache
```

This will output to terminal the contents of the components, ex:

<!--![Chalk Dump Output](../../img/chalk_dump.png)-->

## How do I re-load the default config?

If you have loaded several configuration files and would like to restart with a clean slate, you can always go back to the chalk default empty configuration by running:

```sh
chalk load default
```

This will remove _all_ loaded configs. Checking state via `chalk dump` should produce the following output:

```
liming@system76-pc:~/workspace/chalk$ ./chalk dump
# The default config is empty. Please see chalk documentation for examples.
```

## How do I load a config on top of the existing config?

If you would like to add a component to the config currently loaded in a chalk binary, simply run

```sh
chalk load component
```

For example, if your currently loaded configuration looks like this:

```sh
liming@system76-pc:~/workspace/chalk$ ./chalk dump
use app_inventory from "https://chalkdust.io"
use reporting_server from "https://chalkdust.io"
```

and you would like to add the `embed_sboms.c4m` component for compliance, you would run:

```sh
chalk load https://chalkdust.io/embed_sboms.c4m
```

Once loaded, the output of chalk dump should look like this:

```sh
liming@system76-pc:~/workspace/chalk$ ./chalk dump
use app_inventory from "https://chalkdust.io"
use reporting_server from "https://chalkdust.io"
use embed_sboms from "https://chalkdust.io"
```

## How do I load a config that replaces the existing config?

To replace the currently loaded config with an incoming config, run:

```sh
chalk load component --replace
```
