## This contains the base configuration.  The key entries should not
## change unless the specification changes, with the exception of any
## keys starting with 'X'.
##
## Any statically linked plugins and output hooks all need to have an
## entry here, but the contents (when we provide them) can mostly be
## overriden, the exceptions being the specification of what keys
## plugins export, and whether plugins are codecs.
##
## Currently, we don't support dynamic plugins, but generally you can
## do what you want via con4m.
##
## Nothing should really be in here that doesn't need to be here-- add
## it to defaultconfig.nim, which users can change.
## 
## Note, if you end up w/ syntax errors in this file, when you run sami 
## and get an error, the line number will be relative to the first line 
## after the """ below, so add 20 to get the line # in this file.

const baseConfig* = """
sami_version := "0.2.0"
ascii_magic := "dadfedabbadabbed"

extraction_output_handlers: []
injection_prev_sami_output_handlers: []
injection_output_handlers: []
deletion_output_handlers: []

key _MAGIC json {
    required: true
    missing_action: "abort"
    system: true
    squash: true
    type: "string"
    value: ascii_magic
    standard: true
    since: "0.1.0"
    output_order: 0
    in_ref: true
}

key SAMI_ID {
    required: true
    missing_action: "error"
    system: true
    squash: false
    type: "integer"
    standard: true
    since: "0.1.0"
    output_order: 1
    in_ref: true
}

key SAMI_VERSION {
    required: true
    missing_action: "error"
    system: true
    type: "string"
    value: sami_version
    standard: true
    since: "0.1.0"
    output_order: 2
    in_ref: true
}

key SAMI_PTR {
    required: false
    type: "string"
    standard: true
    since: "0.10"
    output_order: 3
    in_ref: true
}

key TIMESTAMP {
    required: true
    missing_action: "error"
    system: true
    type: "integer"
    since: "0.1.0"
    output_order: 4
    standard: true
}

key EARLIEST_VERSION {
    type: "string"
    since: "0.1.0"
    system: true
    value: sami_version
    output_order: 5
    standard: true
}

key ARTIFACT_PATH {
    type: "string"
    since: "0.1.0"
    codec: true
    output_order: 6
    standard: true
}

key INSERTION_HOSTINFO {
    type: "string"
    since: "0.1.0"
    output_order: 7
    standard: true
}

key ORIGIN_URI {
    type: "string"
    missing_action: "warn"
    since: "0.1.0"
    output_order: 8
    standard: true
}

key ARTIFACT_VERSION {
    type: "string"
    since: "0.1.0"
    output_order: 9
    standard: true
}

key ARTIFACT_FILES {
    type: "[string]"
    since: "0.1.0"
    output_order: 10
    standard: true
}

key IAM_USERNAME {
    must_force: true
    type: "string"
    since: "0.1.0"
    output_order: 11
    standard: true
}

key IAM_UID {
    must_force: true
    type: "integer"
    since: "0.1.0"
    output_order: 12
    standard: true
}

key BUILD_URI {
    type: "string"
    since: "0.1.0"
    output_order: 13
    standard: true
}

key STORE_URI {
    type: "string"
    since: "0.1.0"
    output_order: 14
    standard: true
}

key BRANCH {
    type: "string"
    since: "0.1.0"
    standard: true
    output_order: 15
}

key SRC_URI {
    type: "string"
    since: "0.1.0"
    standard: true
    output_order: 16
}

key REPO_ORIGIN {
    type: "string"
    system: false
    since: "0.1.0"
    standard: true
    output_order: 17
}

key HASH {
    type: "string"
    since: "0.1.0"
    codec: true
    standard: true
    output_order: 18
}

key HASH_FILES {
    type: "[string]"
    since: "0.1.0"
    codec: true
    standard: true
    output_order: 19
}

key COMMIT_ID {
    type: "string"
    since: "0.1.0"
    standard: true
    output_order: 20
}

key JOB_ID {
    type: "string"
    since: "0.1.0"
    standard: true
    output_order: 21
}

key CODE_OWNERS {
    type: "string"
    since: "0.1.0"
    standard: true
    output_order: 22
}

key BUILD_OWNERS {
    type: "string"
    since: "0.1.0"
    standard: true
    output_order: 23
}

key INJECTOR_ID {
    type: "int"
    since: "0.1.0"
    standard: true
    output_order: 24
}

key X_SAMI_CONFIG {
    system: true
    type: "string"
    since: "0.1.0"
}

key OLD_SAMI {
    type: "sami"
    since: "0.1.0"
    standard: true
    output_order: 996
}

key EMBEDS {
    type: "[(string, sami)]"
    standard: true
    output_order: 997
    since: "0.1.0"
}

key SBOMS {
    type: "{string, string}"
    since: "0.1.0"
    standard: true
    output_order: 998
}


key ERR_INFO {
    type: "[string]"
    standard: true
    since: "0.1.0"
    system: true
    standard: true
    output_order: 999
}

key SIGNATURE {
    type: "{string : string}"
    since: "0.1.0"
    standard: true
    output_order: 1000
    in_ref: true
}

# Doesn't do any keys other than the codec defaults, which are:
# ARTIFACT_PATH, HASH, HASH_FILES

plugin elf {
    codec: true
    keys: []
}

plugin shebang {
    codec: true
    keys: []
}

# Probably should add file time of artifact, date of branch
# and any tag associated.
plugin "vctl-git" {
    keys: ["COMMIT_ID", "BRANCH", "ORIGIN_URI"]
}

plugin authors {
    keys: ["CODE_OWNERS"]
}

plugin "github-codeowners" {
    keys: ["CODE_OWNERS"]
}

plugin sbomCallback {
    keys: ["SBOMS"]
}

# This plugin is the only thing allowed to set these keys. However, it
# should run last to make sureit knows what other fields are being set
# before deciding how to handle the OLD_SAMI field.  Thus, the setting
# to 32-bit maxint (though should consider using the whole 64-bits).

plugin system {
    keys: ["TIMESTAMP", "SAMI_ID", "OLD_SAMI", "X_SAMI_CONFIG", "INJECTOR_ID"]
    priority: 2147483647
}

# This plugin takes values from the conf file. By default, these
# are of the lowest priority of anything that can conflict.
# This will set SAMI_VERSION, EARLIEST_VERSION, SAMI_REF (if provided)
#  and _MAGIC.
plugin conffile {
    keys: ["*"]
    priority: 2147483646
}

# If you add more sinks, please make sure they get locked in the
# lockBuiltinKeys() function in config.nim

sink stdout {
  docstring: "A sink that writes to stdout"
}

sink stderr {
  docstring: "A sink that writes to stderr"
}

sink file {
  needs_filename: true # Assumes uses_filename
  docstring: "A sink that writes a local file"
}

sink s3 {
  needs_secret: true
  needs_userid: true
  needs_uri: true
  uses_region: true
  uses_aux: true
  docstring: "A sink for S3 buckets"
}

sink post {
  needs_uri: true
  docstring: "Generic HTTP/HTTPS post to a URL. Add custom headers by providing an implementation to the callback getPostHeaders(), which should return a dictionary where all keys and values are strings."
}

sink custom {
  uses_secret: true
  uses_userid: true
  uses_filename: true
  uses_uri: true
  uses_region: true
  uses_aux: true
  docstring: "Implement a custom sink via a con4m callback"
}

outhook defaultLog {
  sink: "stderr"
  filters: [
             ["logLevel", "info"]
           ]
}

outhook defaultOut {
  sink: "stdout"
}

outhook debug {
  sink: "debug"
  filters: [
             ["debugEnabled"]
           ]
}

stream error { 
  hooks: ["defaultLog"]
}

stream warn {
  hooks: ["defaultLog"]  
}

stream inform {
  hooks: ["defaultLog"]
 }
stream trace {
  hooks: ["defaultLog"]
}

stream debug {
  hooks: ["debug"]
 }

stream extract {
  hooks: ["defaultOut"]
 }

stream inject { 
  hooks: ["defaultOut"]
}

stream nesting { 
}

stream delete {
}

stream confload {
}

stream confdump {
}
"""
