const defaultConfig* = """

color: true

# If not provided, log_level will default to "warn".
# Options for log_level are:
# "trace" (show verbose messages)
# "info"  (show default messages)
# "warn"  (don't show informational messages, but do show warnings and errors)
# "error" (show ONLY actual fatal errors) 
# "none"  (show nothing, not even errors)
#
# You can configure where these messages go; they get published to the
# "logs" topic, which automatically is hooked to stderr with the 
# following hook:
#
# outhook logDefault {
#   sink: "stderr"
#  filters: [ "logLevelFilter", "logPrefixFilter"]
# }
#
# You can add additional hooks configured for other sinks, and subscribe them:
# outhook s3LogHook {
#   sink:     "s3"
#   secret:   "ADD AWS SECRET HERE"
#   uid:      "ADD AWS UID HERE"
#   uri:      "s3://your-bucket-name/object-name"
# }
#
# subscribe("logs", "s3loghook")
#
# If you want, you can remove the old hook altogether with:
# unsubscribe("logs", "logDefault")
#
#
# The following hook is pre-defined and used with the below subscriptions.
# outhook defaultOut {
#  sink: "stderr",
#  filter: [ "prettyJson", "addTopic" ]
# }
#
# See the documentation for more on filters, but it is possible to
# build a custom filter.

outhook defaultDryRun {
  sink: "stderr"
}

outhook defaultDebug {
  sink: "stderr"
}

log_level: "info" 

log("info", "Loading the default SAMI config")

# Set up output subscriptions.

subscribe("extract",  "defaultOut") # Writes SAMIs extracted w/ 'extract' cmd
subscribe("inject",   "defaultOut") # Writes full SAMIs (no ptrs) being injected
subscribe("nesting",  "defaultOut") # Writes extracted samis when injecting
subscribe("defaults", "defaultOut") # Writes out the config after loading, but
                                    # only when running 'defaults' command
subscribe("delete",   "defaultOut") # Writes samis deleted w/ 'delete' cmd
subscribe("confload", "defaultOut") # Log any config embedded.
subscribe("confdump", "defaultOut") # Handle the output of any config dumped.

# Confdump will probably change shortly to accept a file name, and
# will have a filter applied by default that, if a file name is
# provided, will NOT output to that hook.

# There's no debug output in the code base, but
# if you're hacking on the code base you can use this.
subscribe("debug", "defaultDebug")

key INSERTION_HOSTINFO {
    info, exitCode := system("uname -a")
    if exitCode == 0 {
      value: info
    }
}

outhook s3 {
  sink: "s3"
  if envExists("AWS_ACCESS_SECRET") {
    secret: env("AWS_ACCESS_SECRET")
  }
  else {
    secret: "No AWS secret provided.  Set the env variable AWS_ACCESS_SECRET"
  }
  if envExists("AWS_ACCESS_ID") {
    userid: env("AWS_ACCESS_ID")
  }
  else {
    userid: "No AWS access id provided.  Set the env variable AWS_ACCESS_ID"
  }
  if envExists("AWS_REGION") {
    region: env("AWS_REGION")
  }
  if envExists("AWS_S3_BUCKET_URI") {
    uri: env("AWS_S3_BUCKET_URI")
  }
  else {
    uri: "s3://example-bucket/example-object-path"
  }
}

"""
