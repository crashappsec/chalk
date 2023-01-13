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
# "logs" topic, which automatically is hooked to stderr by default.

log_level: "info" 

log("info", "Loading the default SAMI config")

key INSERTION_HOSTINFO {
    info, exitCode := system("uname -a")
    if exitCode == 0 {
      value: info
    }
}


cmd  := argv0()
args := argv()

log("trace", "running command: " + cmd)

sinkConfig("redirectableOut", "stdout", {}, ["color"])
sinkConfig("defaultOut",      "stderr", {}, ["addTopic"])


if cmd != "defaults" {
    subscribe("defaults", "defaultOut")
}

if cmd == "extract" or cmd == "inject" or cmd == "del" {

  if envExists("AWS_S3_BUCKET_URI") {
    if not envExists("AWS_ACCESS_ID") {
       log("warn", "To configure AWS must provide AWS_ACCESS_ID")
    } elif not envExists("AWS_ACCESS_SECRET") {
       log("warn", "To configure AWS must provide AWS_ACCESS_SECRET")       
    } else {
      sinkConfig("s3", "s3", { "secret" : env("AWS_ACCESS_SECRET"),
                               "userid" : env("AWS_ACCESS_ID"),
                               "uri"    : env("AWS_S3_BUCKET_URI") }, [] )
    }
  }

  subscribe("extract", "defaultOut") # Writes SAMIs extracted w/ 'extract' cmd
  subscribe("nesting", "defaultOut") # Writes extracted samis when injecting
  subscribe("inject",  "defaultOut") # Writes full SAMIs (no ptrs) being injected
}
elif cmd == "dump" {
  if len(args) > 0 {
    sinkConfig("dumpOut", "file", {"filename" : args[0]}, ["color"])
  }
  else {
    sinkConfig("dumpOut", "stdout", {}, ["color"])
  }

  subscribe("confdump", "dumpOut")
}
else {
  if cmd == "load" {
    subscribe("confload", "redirectableOut")
  } elif cmd == "version" {
    subscribe("version",  "redirectableOut")
  }
}


"""
