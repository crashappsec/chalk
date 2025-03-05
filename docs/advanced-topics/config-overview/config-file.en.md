---
title:
description:
---

# Chalk Configuration Options

This guide details all of the configuration options available in Chalk. These are all configurable variables that you can add in your configuration file. In some cases, there will also be other ways to set these values:

- There may be command-line flags built into chalk to set the variable. If so, they are mentioned below; the help on each flag will also show if it directly sets a variable.
- The pre-existing configuration might allow configuration through environment variable. Chalk prefers you define such things yourself if desired, though does have some defaults set up.

Note that Chalk embeds a configuration file inside its own binary. You can change this embedded configuration file by using chalk dump to write it to disk, editing it then using chalk load to install it. Chalk also supports external configuration files. By default, chalk evaluates configuration variables as follows:

1. Chalk locks in values for anything passed explicitly on the command-line. These override anything in the configuration file.
2. The embedded configuration is evaluated, which can override any system defaults (but not command-line flags)
3. If found, an external configuration file will be evaluated, which can generally override anything except command-line flags (unless you explicitly lock attributes).

The config file types can be disabled with the command-line flags `--no-use-embedded-config` or `--no-use-external-config`. Usually, the former is useful for testing, and the later is good for ensuring a well-configured binary doesn't pick up stray configurations.

  <table><thead><tr><th>Variable</th><th>Type</th><th>Default Value</th><th>Description</th></tr></thead><tbody><tr><td>config_path</td><td>list[string]</td><td><em>["/etc/chalk/", "/etc/", ".", "~/.config/chalk", "~"]</em></td><td>The path to search for an external configuration file.</td></tr><tr><td>config_filename</td><td>string</td><td><em>"chalk.c4m"</em></td><td>The file name to look for when searching for a file</td></tr><tr><td>default_command</td><td>string</td><td><i>None</i></td><td>
If no top-level command is passed on the command line, this command is
assumed.  By default, if the config file does not resolve the ambiguity,
then chalk will produce a help message.
</td></tr><tr><td>selected_command</td><td>string</td><td><em>""</em></td><td>

Once the command line is fully parsed, this will get the value of the
selected command. If the command is ambiguous, fill it in with the
value 'default_commmand'.

In that case, this field doesn't get set with a real value until after
all your configuration files run. Instead, it will be an empty
string.

</td></tr><tr><td>color</td><td>bool</td><td><i>None</i></td><td>
Whether to output ANSI color. If this is not explicitly set, will respect
the presence of a NO_ANSI environment variable, but is otherwise on by default.
</td></tr><tr><td>log_level</td><td>string</td><td><em>"warn"</em></td><td>
Determines what kind of logging messages show to the console. To see
everything, use 'trace' or 'verbose' (they are aliases).
</td></tr><tr><td>chalk_log_level</td><td>string</td><td><em>"error"</em></td><td>
Determines what kind of logging messages will be added to metadata via the
ERR_INFO or `_ERR_INFO` keys. During the chalk phase of chalking ops only,
per-object errors that are at least as severe as specified will be added to
the object's  `ERR_INFO` field.

Everything else will go to `_ERR_INFO`.

Generally, we recommend setting this to `warn` for docker, and `error`
for everything else, as docker only reports errors when there is a
problem where it had to restart the operation without chalk.

</td></tr><tr><td>virtual_chalk</td><td>bool</td><td><em>false</em></td><td>
This option implements 'virtual' chalking, where the chalk mark is not inserted into an artifact via codec. Instead, the chalk mark gets published to the "virtual" topic, and it is the user's responsibility to do something about it. Or else, you could treat it as a dry-run mode.

By default, virtual chalk marks will get appended to the file `./virtual-chalk.json`, but you can use the output system to send them anywhere (this is setup in the default configuration file).

</td></tr><tr><td>publish_audit</td><td>bool</td><td><em>false</em></td><td>
This controls whether the default 'usage' audit is published. The
usage audit is a pre-configured report called 'audit'.

By default, it is hooked up to a file sink, the location of which is
specified by the audit_location variable, and the max size of which is
specified by the audit_file_size variable.

</td></tr><tr><td>report_total_time</td><td>bool</td><td><em>false</em></td><td>
Chalk can report the time from start until the time a report is produced
by subscribing to the `_CHALK_RUN_TIME` host key. However, if you're running
on the command line, and want the total time to be output to stderr as the
very last thing, you can use this option (`--time` on the command line).
</td></tr><tr><td>audit_location</td><td>string</td><td><em>"chalk-audit.json"</em></td><td>
This controls where the default audit log goes, if enabled.  If you enable and set this to "", then you need to provide your own output configuration that subscribes to the 'audit' topic.

If you provide a file name only, the directories in log_search_path are tried in order. Failing that, it uses /tmp.

If you provide an absolute path, and the log file cannot be opened, then it falls back on the search path (keeping the file name portion).

Defaults to 'chalk-audit.json'

</td></tr><tr><td>audit_file_size</td><td>Size</td><td><em>95MB 376KB 376B</em></td><td>
When using the default log file for the built-in audit report (which, by the way, is off by default), this controls the maximum size allowable for the audit log. If a write to the cache would exceed this amount, the system will truncate down to 75% of the size.
</td></tr><tr><td>log_search_path</td><td>list[string]</td><td><em>["/var/log/chalk/", "~/.log/chalk/", "."]</em></td><td>
Any time you open a log file (for instance, with the output sink configurations, or with the builtin (optional) audit log, relative paths attempt to open a log file, checking each one of these locations until one succeeds (making any directories necessary).

This path is also searched if there is a problem writing log files where an explicit path is given.

Note that if nothing in this path works, Chalk tries to create a temporary directory for log files, just for that invocation.

</td></tr><tr><td>artifact_search_path</td><td>list[string]</td><td><em>["."]</em></td><td>
Set the default path to search for artifacts, unless overridden by command-line arguments.
</td></tr><tr><td>default_tmp_dir</td><td>string</td><td><i>None</i></td><td>

Generally, systems use `/tmp` for temporary files, and most modern API
interfaces to using `/tmp` take mitigation against file-based race
conditions, for instance, by leveraging per-app directories and
randomness in selecting file names.

However, there are times when the system default isn't a good option
for Chalk when it needs temporary space. Specifically, we've learned
that, for those running Docker via Snap on Ubuntu systems, Snap's
isolation of temporary files means that users will get an error if we
try to use /tmp to, for instance, write out a temporary docker file
that we want to use with a container.

Specifying a directory outside of `/tmp` addresses that problem, which
can easily be done with the quite standard `TMPDIR` environment
variable.

However, Chalk philosophically doesn't want to leave opportunity for
people to "forget" to do things when deploying us. So this field
allows you to pick a place for temporary files to use IF no value for
`TMPDIR` is provided.

If neither is provided, you may very well end up with `/tmp` or
`/var/tmp`, which should be great in most cases.

</td></tr><tr><td>always_try_to_sign</td><td>bool</td><td><em>true</em></td><td>
When true, Chalk will attempt to use Cosign to sign *all* artifacts
when chalking. If it's false, Chalk will still try to sign when
chalking containers, as otherwise it's not practical to determine when
containers have been modified since chalking.

Even if this is false, Chalk will try to sign if either the chalking
template or the reporting template have SIGNATURE set.

</td></tr><tr><td>inform_if_cant_sign</td><td>bool</td><td><em>false</em></td><td>
If true, when code signing is on, but Chalk cannot find a passphrase in
its environment, this will cause an info-level message to be logged.
</td></tr><tr><td>use_transparency_log</td><td>bool</td><td><em>false</em></td><td>
When this is true, digital signings will get published to a
transparency log, and extracts from container images will attempt to
validate in the transparency log.
</td></tr><tr><td>use_secret_manager</td><td>bool</td><td><em>true</em></td><td>
Any signing keys generated or imported are encrypted by a randomly
generated password (which is derived by encoding 128 bits taken from a
cryptographically secure source).

The password is NOT stored in the binary. You can choose to provide
the password via the CHALK_PASSWORD environment variable, or you may
escrow it in our secret manager.

If this is true, when you set up signing, the password will get
encrypted by another randomly generated value, stored in your
binary. The result will posted to our free service over TLS; the
service will then be queried as it is needed.

If you do not select this when setting up signing, the password will
be written to stdout a single time. Or, you can set the password
manually via the CHALK_PASSWORD environment variable (if using the
manager, the env variable is ignored during setup).

Once you have configured signing, Chalk will first try to read the
password from the CHALK_PASSWORD environment variable. If the
environment variable doesn't exist, what happens next is dependant on
this variable.

If it's true, then we attempt to query the secret manager before
giving up. If it's false, we immediately move on without signing.

Note that if you provide the environment variable, then the secret
manager currently does not run. We may eventually make it a fallback.

</td></tr><tr><td>secret_manager_timeout</td><td>Duration</td><td><em>3 secs</em></td><td>
If the timeout is exceeded and the operation fails, chalk will proceed,
just without doing any signing / verifying.
</td></tr><tr><td>signing_key_location</td><td>string</td><td><em>"./chalk.key"</em></td><td>

This is only used for the `chalk setup` command; it dictates where to
either find a key pair to load, or where to write a keypair being
generated.

Chalk will also embed the keypairs internally, for future operations.

</td></tr><tr><td>api_login</td><td>bool</td><td><em>true</em></td><td>
Enable the use of the Crash Override API for secret management.
</td></tr><tr><td>ignore_patterns</td><td>list[string]</td><td><em>[".*/\..*", ".*\.txt", ".*\.json"]</em></td><td>
For operations that insert or remove chalk marks, this is a list of
regular expressions for files to ignore when scanning for artifacts to
chalk.

The 'extract' operation ignores this.

</td></tr><tr><td>load_external_config</td><td>bool</td><td><em>true</em></td><td>
Turn this off to prevent accidentally picking up an external configuration file. You can always re-enable at the command line with --yes-external-config
</td></tr><tr><td>load_embedded_config</td><td>bool</td><td><em>true</em></td><td>
This variable controls whether the embedded configuration file runs. Obviously, setting this from within the embedded configuration file is pointless, as it's used before then. But, you can set this with --no-use-embedded-config at the command line.

This is primarily meant to make it easier to test new configurations by disabling the embedded config and only running the external (candidate) config.

</td></tr><tr><td>run_sbom_tools</td><td>bool</td><td><em>false</em></td><td>
When true, this will cause chalk to run any configured and enabled SBOM tool implementations. Currently, this is just `syft`, which will be downloaded into /tmp if not found on the system.

You can change that directory by setting the global variable `SYFT_EXE_DIR` with the `:=` operator (it is _not_ an attribute).
The syft command line arguments used at invocation (minus the target location) can be set via the `SYFT_ARGV` global variable. It's default value is:

```
-o cyclonedx-json 2>/dev/null
```

</td></tr><tr><td>run_sast_tools</td><td>bool</td><td><em>false</em></td><td>
When true, this will cause chalk to run any configured static analysis security testing (SAST) tools.  This is off by default, since it could add a noticeable delay to build time for large code bases.

Currently, the only available tool out of the box is semgrep, and will only work on machines that either already have semgrep installed, or have Python3 installed.

</td></tr><tr><td>recursive</td><td>bool</td><td><em>true</em></td><td>
When scanning for artifacts, if this is true, directories in the
artifact search path will be traversed recursively.
</td></tr><tr><td>docker_exe</td><td>string</td><td><i>None</i></td><td>
When running the 'docker' command, this tells chalk where to look for the docker executable to exec.

If this is not provided, or if the file is not found, chalk will search the PATH for the first instance of 'docker' that is not itself (We generally expect renaming chalk to docker and using this variable to point to the actual docker EXE will be the most seamless approach).

Note that, when chalk is invoked with 'docker' as its EXE name, the default IO configuration is to _NOT_ anything chalk-specific on the console.

</td></tr><tr><td>chalk_contained_items</td><td>bool</td><td><em>false</em></td><td>
When chalking an artifact that can itself contain artifacts, this field dictates whether the contents should be chalked, or if just the outer artifact.  This also controls whether, on extraction, chalk will report contents.

Currently, this is only fully respected for artifacts in ZIP format (e.g., JAR files)

When this is true, docker builds will chalk items in any local context directories. Remote contexts currently do not get chalked when this is true.

</td></tr><tr><td>show_config</td><td>bool</td><td><em>false</em></td><td>
When set to true,configuration information will be output after Chalk
otherwise has finished running.

This is similar to the 'chalk config' command, except that it causes
the same type of information to be added at the end of _any_
operation.

This is useful when you have conditional logic in your configuration
file, and want to see the results of config file evaluation for
specific sets of command-line arguments.

</td></tr><tr><td>use_report_cache</td><td>bool</td><td><em>true</em></td><td>
The report cache is a localfile in JSON format that stores any reports that don't reach their destination. This will get used any time publishing to *any* sink fails to write.

The report cache will re-publish on subsequent runs by appending any unsent messages to the json report (this is why reports are an array). It does so on a sink-by-sink basis, based on the name of the sink. It will never publish to the same sink twice.

A few important notes:

1. This functionality applies both to the default 'report' topic, and for custom reports.

2. If the report cache successfully flushes all its contents, it will leave a zero-byte file (it does not remove the file). Still, it doesn't write the file for the first time until there is a failure.

3. If, for any reason, writing to the report cache fails, there will be a forced write to stderr, whether you've subscribed to it or not, in an attempt to prevent data loss.

4. There is currently not a way to specify a 'fallback' sink.

5. If this is off, there is no check for previously cached data.

Note that this field is set on the command line with --use-report-cache / --no-use-report-cache.

</td></tr><tr><td>report_cache_location</td><td>string</td><td><em>"./chalk-reports.jsonl"</em></td><td>
Where to write the report cache, if in use.  Note that Chalk does not try to write this where log files go, since it is not really a log file.  It only tries to write to the one configured location, and failing that will try a tmp file or writing to the user (see the docs for use_report_cache).
</td></tr><tr><td>report_cache_lock_timeout_sec</td><td>int</td><td><em>15</em></td><td>
When using the report cache, it's possible multiple parallel instances
of chalk on the same machine will be attempting to use the same cache
file.

For cases when this happens, Chalk uses a file locking system. If
another running process holds the lock, chalk will keep retrying once
per second for the number of specified seconds, before giving up
(stale lock files are ignored).

This variable then controls how many retries will be made, and thus
the approximate maximum delay to the start of work.

If you're running tools via chalk that can take a while to run, then
you probably want to bump this number up, or use multiple report
caches, or somesuch.

If you have more typical build runs that complete quickly, then this
number can stay pretty low.

</td></tr><tr><td>force_output_on_reporting_fails</td><td>bool</td><td><em>true</em></td><td>
If this is true, and no reporting configurations successfully handle the metadata, then this will cause the report that should have been output to write to the user's terminal if there is one, or stderr if not.

Note that this is NOT checked if there is a report cache enabled; even if the report cache fails, then there will be console output.

</td></tr><tr><td>env_always_show</td><td>list[string]</td><td><em>["PATH", "PWD", "XDG_SESSION_TYPE", "USER", "SSH_TTY"]</em></td><td>
For the INJECTOR_ENV and _ENV metadata keys, any environment variable listed here will get reported with its actual value at the time the chalk command is invoked.
</td></tr><tr><td>env_never_show</td><td>list[string]</td><td><em>[]</em></td><td>
For the INJECTOR_ENV and _ENV metadata keys, any environment variable listed here will get ignored.
</td></tr><tr><td>env_redact</td><td>list[string]</td><td><em>["AWS_SECRET_ACCESS_KEY"]</em></td><td>
For the INJECTOR_ENV and _ENV metadata keys, any environment variable listed here will get redacted for privacy.  Currently, that means we give the value <<redacted>>; we do not try to detect sensitive data and redact it.
</td></tr><tr><td>env_default_action</td><td>string</td><td><em>"ignore"</em></td><td>
For the INJECTOR_ENV and _ENV metadata keys, any environment variable that is not listed explicitly in the above lists will be handled as specified here.
</td></tr><tr><td>aws_iam_role</td><td>string</td><td><i>None</i></td><td>
Currently, this is only used for looking up security credentials if using the
IMDSV2 metadata plugin.

If you have the value in an environment variable, you can pass it to chalk
with something like:

```
if env_exists("AWS_IAM_ROLE") {
  aws_iam_role = env("AWS_IAM_ROLE")
}
```

</td></tr><tr><td>skip_command_report</td><td>bool</td><td><em>false</em></td><td>
Skip publishing the command report (i.e., the PRIMARY report). NO output sinks will get it.

For most commands, this defeats the purpose of Chalk, so use it sparingly.

Note that this doesn't turn off any custom reports; you have to disable those separately.

</td></tr><tr><td>skip_summary_report</td><td>bool</td><td><em>false</em></td><td>
Skip publishing the summary report that's typically printed to the terminal.

This is checked before the user config is loaded; it's only settable
via command line flag.

However, if you want to disable it in your config file, you can just set:

```
custom_report_terminal_chalk_time.enabled: false
custom_report.terminal_other_op.enabled: false
```

</td></tr><tr><td>symlink_behavior</td><td>string</td><td><em>"skip"</em></td><td>
Chalk never follows directory links. When running non-chalking operations, chalk will read the file on the other end of the link, and report using the file name of the link.

For insertion operations, Chalk will, out of the box, warn on symbolic links, without processing them.

This variable controls what happens in those cases:

- <em>skip</em> will not process files that are linked.
- <em>clobber</em> will read the artifact on the other end of the link, and, if writing, try to replace the file being linked to.
- <em>copy</em> will read the artifact on the other end of the link, and, if writing, will replace the link with a modified file, leaving the file on the other end of the link intact.
</td></tr><tr><td>install_completion_script</td><td>bool</td><td><em>true</em></td><td>
When this is true, on startup chalk will look for a chalk auto-completion
script in the local user's directory:

~/.local/share/bash_completion/completions/chalk.bash

If it's not present, chalk will attempt to install it.

</td></tr><tr><td>use_pager</td><td>bool</td><td><em>true</em></td><td>
When using the help system, this controls whether documents are dumped
directly to the terminal, or passed through your system's pager.

To skip the pager on the command line, use the `--no-pager` flag.

</td></tr></tbody></table>

# Configuration for the _docker_ section

These are configuration options specific to how Chalk will behave when
running the `chalk docker` command.

<p>
We recommend having `chalk` be installed in such a manner as to *wrap*
`docker`. This means nobody doing a build or push will need to worry
about any sort of setup or configuration.
<p>
In such a scenario, `chalk` will automatically and transparently call
`docker` for you. With these options, you can configure what data gets
captured, but you can also add labels or environment variables
automatically into the container.
<p>
Additionally, you can automatically *wrap* your containers to enable
chalk to collect data when the container starts up (or beyond).
<p>
The behavior for execution time is configured in the `exec` section.
<p>
Note that if a docker operation that chalk wraps ever fails, Chalk
will run it again without itself in the way. Such cases are the only
times in the default configuration where error messages are logged to
the console (when running `chalk docker`).
<table><thead><tr><th>Variable</th><th>Type</th><th>Default Value</th><th>Description</th></tr></thead><tbody><tr><td>wrap_entrypoint</td><td>bool</td><td><em>false</em></td><td>
When running the docker command, this option causes `chalk docker build` to
modify containers to, on entry, use `chalk exec` to spawn your process.

Note that, by default, Chalk will use its own binary for the wrapping, unless
it sees an arch flag and determines that this is the wrong binary.

In such a case, you should have a binary available for the
architecture you are building for to copy in, which can be specified
via the `arch_binary_locations` field.

Note that _either_ we need to be able to copy the chalk binary into
the context directory before invoking Docker, or you need to be on a
version of Docker that accepts `--build-context`, otherwise the
wrapping will fail (though just the wrapping).

The configuration of the chalk process inside the container will be
inherited from the binary doing the chalking.

If, when wrapping, your chalk binary is using an external
configuration file, that file will NOT get used inside the
container. The wrapped binary currently only uses the embedded
configuration present in the binary in the time of the wrapping.

</td></tr><tr><td>arch_binary_locations</td><td>dict[string, string]</td><td><i>None</i></td><td>
Whenever Chalk does automatic entry-point wrapping, it uses its own
binary and its own `exec` config to move into the entry
point. However, if the container being built is of a different
architecture, it cannot do that.

If this field is set, it maps docker architecture strings to locations
where the configured Chalk binary lives for the platform. Currently,
this only accepts local file system paths, so the binary must be
local.

If there isn't an architecture match, and no binary can be found per
this field,

Keys are expected in "Os/Architecture/Variant" form, eg:
"linux/arm64", "linux/amd64", "linux/arm/v7" etc.

Note that Chalk itself is only targeted for a subset of the platforms
that officially support Docker, specifically Linux on arm64 and amd64
(no Windows yet). If an entrypoint wrapping is performed on any
architecture not in this set (bravo for getting Chalk to build!), it
will still refuse to copy itself in, except via this configuration
field.

</td></tr><tr><td>label_prefix</td><td>string</td><td><em>"run.crashoverride."</em></td><td>
When docker labels are used, they are supposed to have a reverse-DNS
prefix for the organization that added them. You generally should add
your own organization here.
</td></tr><tr><td>label_template</td><td>string</td><td><em>"chalk_labels"</em></td><td>
The named `mark_template` guides what labels will be automatically
added to docker images when we successfully chalk them. The only
allowed keys are Chalk-time keys. And, if the metadata is not
available, then no key will be added.

For instance, the `HASH` key cannot currently appear in docker chalks,
because it is not available for chalk-time, so will not appear as
a label. But, you can add `METADATA_ID`, `CHALK_ID`, etc. or anything
else that is collectable before the build.

</td></tr><tr><td>custom_labels</td><td>dict[string, string]</td><td><i>None</i></td><td>
Any labels added here will be added as a `LABEL` line to the chalked
container.  This will add `label_prefix` before the keys, and will not
add if the key is not an alphanumeric value.
</td></tr><tr><td>report_unwrapped_commands</td><td>bool</td><td><em>false</em></td><td>
If true, host reports will be generated for docker commands we do not wrap.
By default, we do not report.  If you set this to 'true', it's helpful to
have `_ARGV` in your report, to get more telemetry.

Note that failed chalk attempts get published to the 'fail' topic, and there
are no default output sinks subscribed to this topic.

</td></tr><tr><td>report_empty_fields</td><td>bool</td><td><em>false</em></td><td>
Docker's internal reporting often gives results that are empty when
not set.  If this is on, such fields are elided on reporting.

</td></tr><tr><td>additional_env_vars</td><td>dict[string, string]</td><td><em>{}</em></td><td>
When doing non-virtual chalking of a container, this will
automatically add an `ENV` statement to the *end* of the Dockerfile
passed to the final build. Keys may only have letters, numbers and
underscores (and cannot start with a number); the values are always
quoted per JSON rules.

If you want to add chalk-time metadata, have the value be the chalk
key, prefixed with an @. For instance:

```
{ "ARTIFACT_IDENTIFIER" : "@CHALK_ID" }
```

will add something to the dockerfile like:

```
ENV ARTIFACT_IDENTIFIER="X6VRPZ-C828-KDNS-QDXRT0"
```

</td></tr></tbody></table>

# Configuration for the _exec_ section

When the `chalk docker` command wraps a container, it inserts a
version of itself into the container, to be able to do data collection
in the runtime environment. Although we do this by replacing the
docker entry point, the default behaves as if your workload was still
the entry point. It's called the same way, and stays PID 1, so when it
dies, the whole container dies.

<p>
The 'exec' command works by forking, and having the child do the chalk
reporting.  The wrapping process automatically calls chalk properly to
run the true entrypoint.  However, you can manually configure wrapping
in this section.
<p>
The `exec` command is the one used by automatic wrapping to spawn your
entry point, and begin runtime reporting. You can report a fixed
amount of time after startup, or you can configure periodic reports as
well.
<table><thead><tr><th>Variable</th><th>Type</th><th>Default Value</th><th>Description</th></tr></thead><tbody><tr><td>command_name</td><td>string</td><td><em>""</em></td><td>
This is the name of the program to run, when running the 'exec' command.  This command will end up being the process you directly spawned; chalking happens in a forked-off process.

You must set a value for this variable or pass the --exec-command-name flag to be able to use the 'exec' command.

</td></tr><tr><td>initial_sleep_time</td><td>Duration</td><td><em>50 msec</em></td><td>
Controls how long after exec + fork Chalk waits before collecting data
on the exec'd process for the first time.

When chalk is configured to be the parent after fork, it's important
to give ourselves enough time for the exec() to occur, so that the
child's process info doesn't look like Chalk.

When chalk isn't the parent, it's still not bad to allow some
initialization time; it improves the data collection. However, in this
scenario, short-lived containers could die and prevent us from
reporting, so it may be best to keep this well under a second in general.

See `get_heartbeat_rate` for the subsequent sleep period.

</td></tr><tr><td>search_path</td><td>list[string]</td><td><em>[]</em></td><td>
While the 'exec' command does, by default, search the PATH environment variable looking for what you want to run, this array gets searched first, so if you know where the executable should be, or if you're worried that PATH won't be set, you can put it here.

Also, you can turn off use of PATH via exec.use_path, in which case this becomes the sole search path.

</td></tr><tr><td>chalk_as_parent</td><td>bool</td><td><em>false</em></td><td>
When running the 'exec' command, this flag sets up Chalk to be the parent process.  The Chalk default is to be the child process.  However, when execing a short-lived process running inside a container, there is no way for Chalk to keep itself alive as the child once the parent dies, unless the parent had previously intervened.

As a result, when this is set to true, during an 'exec' operation, Chalk forks and takes the parent role, and the child process execs. Chalk does its work, then calls waitpid() on the process, and returns whatever exit value the exec'd process returned.

This can be set at the command-line with --chalk-as-parent (aka --pg-13)

</td></tr><tr><td>reporting_probability</td><td>int</td><td><em>100</em></td><td>
When doing a 'chalk exec', this controls the probability associated with whether we actually send a report, instead of exec-only.  This is intended for high-volume, short-lifetime workloads that only want to sample.  It must be an integer percentage.
</td></tr><tr><td>default_args</td><td>list[string]</td><td><em>[]</em></td><td>
When running chalk in 'exec' mode, these are the arguments that should, by default, be passed to the spawned process.

If command-line arguments are provided, you have three options:

1. Always send these arguments, and have any additional arguments be appended to these arguments. For these semantics, set append_command_line_args to true.
2. Have the command line arguments REPLACE these arguments. For these semantics, set override_ok to true. This is chalk's default behavior, absent of any other configuration.
3. Disallow any command-line argument passing. For this behavior, set both of the above variables to 'false'.

Setting both to 'true' at the same time is not semantically valid, and will give you an error message; nothing will run.

</td></tr><tr><td>append_command_line_args</td><td>bool</td><td><em>false</em></td><td>
When true, any command-line arguments will be appended to exec.default_args instead of replacing them.
</td></tr><tr><td>override_ok</td><td>bool</td><td><em>true</em></td><td>
When true, if the 'chalk exec' command has any arguments passed, they will replace any arguments provided in default_args.
</td></tr><tr><td>use_path</td><td>bool</td><td><em>true</em></td><td>
When this is true, the PATH environment variable will be searched for your executable (skipping this executable, in case you want to rename it for convenience).

If it is NOT true, set exec.searchpath to provide any locations Chalk should check for the executable to exec.

</td></tr><tr><td>heartbeat</td><td>bool</td><td><em>false</em></td><td>
When this is true, Chalk will, after initial reporting, connect
periodically to post "heartbeat" reports. The beacon report frequency is
controlled by the `heartbeat_rate` field.
</td></tr><tr><td>heartbeat_rate</td><td>Duration</td><td><em>20 secs</em></td><td>
When `heartbeat` is true, after any report, chalk will sleep the specified
amount of time before providing another heartbeat report.

Note that, when Chalk is running in a container, the container may
exit before any particular report completes, and can even kill one in
the middle of it posting.

When running outside a container, or if inside a container, but
running as a parent process, the heartbeat process will exit after a
final report, if the monitored process has exited.

</td></tr></tbody></table>

# Configuration for the _extract_ section

These are configuration options specific to how container extraction
works for containers (plenty of the global options apply to
extraction). Currently, the only options involve how we handle looking
for chalk marks on images, particularly since extracting large docker
images to look for marks in the top layer isn't necessarily fast.

If you have code signing set up, marks will be added locally on build,
but when you push, we will add a signed attestation using the In Toto
standard (and the Cosign tool for the moment). Such marks are MUCH
faster to access reliably and are the preferred method. See the `chalk
setup` command.

<table><thead><tr><th>Variable</th><th>Type</th><th>Default Value</th><th>Description</th></tr></thead><tbody><tr><td>ignore_unsigned_images</td><td>bool</td><td><em>false</em></td><td>
When running a scan of all images, if this is `true`, Chalk only will try to extract Chalk marks from locally stored images if the image has a Chalk signature added via cosign attestations.

By default we skip unsigned images, because the process (necessarily) involves downloading the container image.

</td></tr><tr><td>search_base_layers_for_marks</td><td>bool</td><td><em>false</em></td><td>
When extracting from images when `ignore_unsigned_images = false`, Chalk will start by checking for a digital signature containing the Chalk mark in the repo, when available.
<p>
But if there's no signature, assuming `ignore_unsigned_images` is true, Chalk looks in the top layer of the file system.
<p>
When no Chalk can be found in either place, if this attribute is set to true, we'll look at the other layers in the image and report the `CHALK_ID` and `METADATA_ID` of the topmost layer with a mark, using the `_FOUND_BASE_MARK` key (the image itself is said to be unchalked; it's more about being able to use knowledge of a chalked base image).
<p>
Note that this does nothing unless `ignore_unsigned_images` is false.
</td></tr></tbody></table>

# Configuration for the _env_config_ section

This section is for internal configuration information gathering
runtime environment information when running with the 'env' command,
which is similar to the exec command, but where the exec command
executes a subprocess that is the focus of reporting, env just reports
on the host environment, and optionally any processes that you're
interested.

Eventually it (and the exec command) will allow you to specify process
patterns to explicitly report on as well.

# Configuration for the _source_marks_ section

These options control whether and how source-code based artifacts are
marked, particularly executable scripting content.

<p>
Generally, the marking occurs by sticking the mark in a comment.
<p>
Currently, the intent for source marking is to mark content that will
be shipped and run in source code form. While you *can* mark every
source file, we don't really encourage it. For that reason, by
default, our database only contains reasonably well used scripting
languages, and is configured to only mark things with unix Shebangs
(extraction doesn't consider the shebang).
<p>
We also definitely do **not** recommend marking code while it is in a
repository. Git does that job well, and no tooling exists to help
recalculate every time you make an edit.
<p>
Ideally, you might wish to mark both a file and any
dependencies. Currently, with the exception of container images /
containers, Chalk doesn't handle that, as it's significantly difficult
to be particularly precise about what is part of the artifact and what
isn't.
<table><thead><tr><th>Variable</th><th>Type</th><th>Default Value</th><th>Description</th></tr></thead><tbody><tr><td>only_mark_shebangs</td><td>bool</td><td><em>true</em></td><td>
If this is true, we will only mark files that have a shebang line
(i.e., the first line starts with `#!`).

This is useful in many scripting languages, as the main entry point is
often made executable and given a shebang, whereas supporting files
are not.

Currently, Chalk has no native support to try to determine which files
the language is likely to deem an entry point. We do not attempt to
understand any package/module system, etc.

If you'd like to do that, you can add a custom callback.

Extraction does not check this. It will attempt to extract from any
file that appears to be valid utf when looking at the first 256 bytes,
unless you provide a custom callback.

</td></tr><tr><td>only_mark_when_execute_set</td><td>bool</td><td><em>false</em></td><td>

When this is true, Chalk will not attempt to mark source code _unless_
the executable bit is set. However, the execute bit can get added later;
it's a trade-off!

Extraction does not check this. It will attempt to extract from any
file that appears to be valid utf when looking at the first 256 bytes,
unless you provide a custom callback.

</td></tr><tr><td>text_only_extensions</td><td>list[string]</td><td><em>["json", "jsonl", "txt", "text", "md", "docx"]</em></td><td>
Chalk extraction generally assumes that if it finds a chalk mark in a
text file, then it should report it. But, that isn't true for
documentation!

So for all operations, we assume the extensions in this list can _never_
be source code.

</td></tr><tr><td>custom_logic</td><td>(string, string, string, bool, bool) -> bool</td><td><i>None</i></td><td>
If you'd like to have fine-grained control over what source gets
marked, you can do so by setting a callback.

Your callback will _not_ supersede `shebangs_when_no_extension_match`
and `only_mark_when_execute_is_set`. Your callback will only get run
if those checks would lead to the file otherwise being marked.

The callback receives the following parameters:

1. The (resolved) file name for the file being considered.
2. The detected language (see below).
3. The file extension (so you don't have to carve it out of the file name).
4. A boolean indicating whether there was a shebang line (if
   `only_mark_shebangs` is on, this will always be true).
5. A boolean indicating whether the execute bit is set on the file system.
   This will always be true if `only_mark_when_execute_set` is true.

Language detection prefers the shebang line, if it's captured. The
language name will be matched with the following rules:

- We look at the first item after the #!, which will either be a full path or
  an exe name (where the path is searched).
- Any directory component is stripped.
- If the value is the word `env` then we instead look at the first non-flag
  item (again, stripping any directory component, even though generally
  we wouldn't expect to see any).
- Any trailing sequence of numbers and dots are removed.

Therefore, all of these will normalize the same way:

#! python
#! python3
#! /bin/env python
#! /bin/env python3.3.1

If chalk does not recognize the language, and your logic says to mark,
it will proceed to mark it, assuming that '#' is the comment character.
Alternatively, you can add the language to our database.

If there was no shebang line, or we did not look at the shebang line,
then we consult `source_marks.extensions_to_languages_map`.

If that turns up nothing, or if there is no extension, then we look at
the executable bit. If it's set, then we check to see if the file
seems to be valid utf-8, by looking at the first 256 bytes. If it is,
then we assume `sh` as the language.

Otherwise, we will assume the file is _not_ an executable.

This also means that we might use odd language names, like 'node',
since it's the thing we're likely to see in a shebang line.

</td></tr><tr><td>language_to_comment_map</td><td>dict[string, string]</td><td><em>{"sh" : "#", "csh" : "#", "tcsh" : "#", "ksh" : "#", "zsh" : "#", "terraform" : "//", "node" : "//", "php" : "//", "perl" : "#", "python" : "#", "ruby" : "#", "expect" : "#", "tcl" : "#", "ack" : "#", "awk" : "#"}</em></td><td>Maps binary names for lang runtimes to their comment type</td></tr><tr><td>extensions_to_languages_map</td><td>dict[string, string]</td><td><em>{"sh" : "sh", "csh" : "csh", "tcsh" : "tcsh", "ksh" : "ksh", "zsh" : "zsh", "hcl" : "terraform", "nomad" : "terraform", "tf" : "terraform", "_js" : "node", "bones" : "node", "cjs" : "node", "es6" : "node", "jake" : "node", "jakefile" : "node", "js" : "node", "jsb" : "node", "jscad" : "node", "jsfl" : "node", "jsm" : "node", "jss" : "node", "mjs" : "node", "njs" : "node", "pac" : "node", "sjs" : "node", "ssjs" : "node", "xsjs" : "node", "xsjslib" : "node", "aw" : "php", "ctp" : "php", "phakefile" : "php", "php" : "php", "php3" : "php", "php4" : "php", "php5" : "php", "php_cs" : "php", "dist" : "php", "phps" : "php", "phpt" : "php", "phtml" : "php", "ack" : "perl", "al" : "perl", "cpanfile" : "perl", "pl" : "perl", "perl" : "perl", "ph" : "perl", "plh" : "perl", "plx" : "perl", "pm" : "perl", "psgi" : "perl", "rexfile" : "perl", "buck" : "python", "bazel" : "python", "gclient" : "python", "gyp" : "python", "gypi" : "python", "lmi" : "python", "py" : "python", "py3" : "python", "pyde" : "python", "pyi" : "python", "pyp" : "python", "pyt" : "python", "pyw" : "python", "sconscript" : "python", "sconstruct" : "python", "snakefile" : "python", "tac" : "python", "workspace" : "python", "wscript" : "python", "wsgi" : "python", "xpy" : "python", "appraisals" : "ruby", "berksfile" : "ruby", "brewfile" : "ruby", "builder" : "ruby", "buildfile" : "ruby", "capfile" : "ruby", "dangerfile" : "ruby", "deliverfile" : "ruby", "eye" : "ruby", "fastfile" : "ruby", "gemfile" : "ruby", "gemfile.lock" : "ruby", "gemspec" : "ruby", "god" : "ruby", "guardfile" : "ruby", "irbrc" : "ruby", "jarfile" : "ruby", "jbuilder" : "ruby", "mavenfile" : "ruby", "mspec" : "ruby", "podfile" : "ruby", "podspec" : "ruby", "pryrc" : "ruby", "puppetfile" : "ruby", "rabl" : "ruby", "rake" : "ruby", "rb" : "ruby", "rbuild" : "ruby", "rbw" : "ruby", "rbx" : "ruby", "ru" : "ruby", "snapfile" : "ruby", "thor" : "ruby", "thorfile" : "ruby", "vagrantfile" : "ruby", "watchr" : "ruby", "tcl" : "tcl", "itk" : "tcl", "tk" : "tcl", "awk" : "awk", "gawk" : "gawk", "mawk" : "mawk", "nawk" : "nawk"}</em></td><td>
Maps file extensions to the binary names for lang runtimes. We use
this for more reliable language detection, which is why we go with
pretty weird language names.
</td></tr></tbody></table>
