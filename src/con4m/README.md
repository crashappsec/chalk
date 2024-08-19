# Con4m: Configuration and Far More

Con4m makes it easy to give users rich configurability via config
files and command line flags. You just have to write a spec to get
your config file format and your command line flags / parsing.

You can do all of your input validation either through Con4m's built
in constraints, or through custom validation routines (themselves
written in con4m). Your main program can skip all that logic, and just
get (or set) fields through a simple API.

You can also document all your fields, commands and flags in your
spec, which is then all easily accessible at runtime, or export the
whole thing to JSon.


By the 1.0 release, Con4m will be easily available in Go, Python, C
and Nim (in which it's written).  Currently, we build both a
command-line and libcon4m, so C and Nim are particularly easy.

But we've got a long way to go before 1.0-- we have a long backlog of
work that we only have been doing as needed for
[Chalk](https://github.com/crashappsec/chalk); once we ship that (in
mid Sept) we will spend significant time on it.


## Brief Overview
To the typical user, Con4m looks like a normal config file, somewhere
in the NginX family. But! power users get a statically typed Go-like
language that seamlessly integrates, for any power user needs, but is
tailored for configuration use cases (for instance, having built-in
data types for things like dates, times, durations and sizes). But,
Con4m can be invisible when people don't need the extra power.

You just write your own configuration file that specifies:

1. What sections and fields your want your configuration file to have,
   and what properties you want them to have.

2. What command-line commands and arguments you want to accept, and
   the properties you want them to have.

3. Any other custom validation you want to do.

Then, you just have to call con4m, passing your config, and then your
user's configuration file. You'll then be able to query results, and
if you like, change values, run callbacks, run additional config files
in the same context (or in different contexts)...

As an example, replicating the whole of the command-line parsing for
Docker took me about two hours, most of which was copying from their
docs.

Con4m validates configuration files before loading them, even making
sure the types and values all what YOU need them to be, if your
provide a brief specification defining the schema you want for your
config files.  That validation can include common constraints, (like
the value must be from a fixed list, must be in a particular range).
There are also constraints for field dependencies, and the ability to
write custom field checkers. You basically just write the spec for
what you want to accept in your config file, in Con4m, naturally.

You are in total control-- do you want command-line flags to take
prescendence over env variables?  Over the config file?  Do you want
users to be able to add their own environment variables to suit their
own needs?  It's all easy.

Con4m also allows you to 'stack' configuration files. For instance,
the app can load an internal default configuration hardcoded into the
program, then layer a system-level config over it, then layer a local
config on top.

After the configuration file loads, you can call any user-defined
functions provided, if your application might need feedback from the
user after configuration loads.

You can also create your own builtin functions to make available to
users who use the scripting capabilities.  Con4m currently offers over
100 builtins, which you can selectively disable if you so choose.  We
always drop privs before running, and you can easily make full audits
available.

## Basic Example

Let’s imagine the user has provided a config file like this:

```python
use_color: false
log_level: warn

host localhost {
      ip: "127.0.0.1"
      port: 8080
}
host workstation {
      port: 8080
      if env("CUSTOM_VAR") != "" {
         ip: env("CUSTOM_VAR")
      }
      else {
         ip: "10.12.1.10"
      }
}
```

In this example, the conditional runs when the config file is evaluated (if something needs to be evaluated dynamically, you can do that with a callback).

Con4m provides a number of builtin functions like env(), which makes it easy for you to check environment variables, but also for your users to customize environment variables to suit their needs.  You can easily provide your own built-in functions.

Let’s say the application writer has loaded this configuration file into the variable s. She may then write the following c42 spec:

```python
object host {
  field ip {
    type: IPAddr
    require: true
  }

  field use_tls {
    type: bool
    default: true
  }
}

# Stick this in a hidden variable, we'll use it for the command line too.

valid_log_levels := ["verbose", "info", "warn", "error", "none"]
root {
  allow host {}
  field use_color {
    type: bool
    require: false
  }

    field log_level {
    choice: valid_log_levels
    default: "info"
  }
}
```
When you load a user configuration file via Con4m, if you also pass it the above spec, the following will happen (in roughly this order):
- The spec file loads and is validated.
- The user's configuration is read in, and checked for syntax and type safety.
- If the user skips attributes where you've provided a default, those values will be loaded from your spec before evaluation. If you didn't provide a value, but the field is required, then the user gets an appropriate error before the configuration is evaluated.
- The user's config is evaluated.
- The user's config file is checked against the constraints provided in the spec.  You can also provide additional validation constraints, like forcing strings to be from a particular set of values, or having integers be in a range. Whenever these constraints are violated, the user gets a descriptive error message.

Any doc strings you provide (per section or per field) are programatically available, and can be put into nice tables.

You then get an easy API for querying and setting these values as your code runs. And, you can call back into the user's config via callback whenever needed.

## Command-line example
If you wanted to provide command-line flags that could be used, and want them to take presidence over the configuration file, you could do add the following:
```python
getopts {
  flag_yn color {
    yes_aliases: ["c"]
    no_aliases:  ["C"]
    field_to_set: "use_color"
    doc: "Enable colors (overriding any config file settings)"
  }
  flag_help { } # Automatically add help

  flag_choice log_level {
    aliases: ["l"]
    choices: valid_log_levels
    add_choice_flags: true
    field_to_set: "log_level"
  }

  ...

  command run {
    aliases: ["r"]
    args: (0, high())
    doc: """..."""

    flag_multi_arg host { ... }
  }
}
```

This will add top-level flags: `--color, --no-color, -c, -C, --help,
-h, --log-level, -l, --info, --warn, --error, --verbose`.

It will also add a `run` command with its own sub-flags, generate a
bunch of help docs, etc.

And on the command line, by default, con4m is as forgiving as
possible. For example, it doesn't care about spaces around an '=', and
if args are required, whether you drop it.  Nor does it care if flags
appear way before or after the command they're attached to (as long as
there is no ambiguity).  You can even have it try to guess the
top-level command so that it can be omitted or provided as a default
via config file.

# Getting Started

Currently, Con4m hasn't been officially released. We expect to provide
a distro with the stand-alone compiler.  But if you're interested, you
could use it, or at least, follow along while we're working.

Right now, you have to build from source, which requires Nim
(https://nim-lang.org/), a systems language that's fast and has strong
memory safety by default, yet somehow feels like Python. But it
doesn't have much of an ecosystem.

If you have Nim installed, you can easily install the current version
with nimble:

```bash
nimble install https://github.com/crashappsec/con4m
```

Then, you can run the `con4m` compiler, link to libcon4m, or, if
you're a Nim user, simply `import con4m`

# More Information

There's a lot of documentation embedded in con4m, but we will focus on
documentation later in the year. For now, the core capabilities are
best documented in the Chalk documentation, since it's the Chalk
config file format.

[Chalk](https://github.com/crashappsec/chalk)

# About

Con4m is open source under the Apache 2.0 license.

Con4m was written by John Viega (john@crashoverride.com), originally
for Chalk and other to-be-named projects, because other options for
flexibile configs (like HCL, or YAML DSLs) all kinda suck.
