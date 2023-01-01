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

const baseConfig = """
sami_version := "0.2.0"
ascii_magic := "dadfedabbadabbed"

extraction_output_handlers: []
injection_prev_sami_output_handlers: []
injection_output_handlers: []

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

key SRC_PATH {
    type: "string"
    since: "0.1.0"
    codec: true
    output_order: 6
    standard: true
}

key FILE_NAME {
    type: "string"
    since: "0.1.0"
    codec: true
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
# SRC_PATH, FILE_NAME, HASH, HASH_FILES

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
    keys: ["TIMESTAMP", "SAMI_ID", "OLD_SAMI"]
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

output stdout {
}

output local_file {
}

output s3 {
}
"""
