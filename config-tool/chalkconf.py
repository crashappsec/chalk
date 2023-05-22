#!/usr/bin/env python3
# John Viega. john@crashoverride.com

chalk_version = "0.4.3"
from textual.app     import *
from textual.containers import *
from textual.widgets import *
from textual.screen import *
from localized_text import *
from rich.markdown import *
import subprocess, json
from textual.widgets import Markdown as MDown
from pathlib import *
import sqlite3, os
import datetime, hashlib

# This is a normalized list, for instance, for getting the ID of
# a config.  Thus, the order matters, and it can't be a set;
# Python seems to randomize the order?

all_fields = [
    # Basics pane
    "use_cmd", "use_docker", "use_cicd", "use_extract", "lx86", "m1",
    # Main output config pane
    "report_co", "report_stdout", "report_stderr", "report_log", "report_http",
    "report_s3", "env_adds_report", "env_custom",
    # Env var customization
    "env_log", "env_post_url", "env_post_hdr", "env_s3_uri", "env_s3_secret",
    "env_s3_aid",
    # Log file config
    "log_loc", "log_truncate",
    # Https config
    "https_url", "https_header",
    # S3 config
    "s3_uri", "s3_access_id", "s3_secret",
    # Default Chalking behavior
    "chalk_minimal", "chalk_maximal", "chalk_ptr", "chalk_datetime",
    "chalk_embeds", "chalk_repo", "chalk_rand", "chalk_build_env",
    "chalk_sig", "chalk_sast", "chalk_sbom", "chalk_virtual",
    # Docker Auto-labeling
    "label_cid", "label_mdid", "label_repo", "label_commit", "label_branch",
    "label_prefix",
    # Chalk Insertion Report
    "crpt_minimal", "crpt_maximal", "crpt_errs", "crpt_embed", "crpt_host",
    "crpt_env", "crpt_sig", "crpt_sast", "crpt_sbom",
    # Docker insertion Report
    "drpt_labels", "drpt_tags", "drpt_dfile", "drpt_dfpath", "drpt_platform",
    "drpt_cmd", "drpt_ctx",
    # Extraction reporting
    "xrpt_env", "xrpt_containers", "xrpt_fullmark",
    # Final screen
    "release_build", "debug_build", "exe_name", "conf_name", "overwrite_config"
]

not_in_id = ["conf_name", "overwrite_config"]

radio_set_dbg    = (["release_build", "debug_build"], 0)
radio_set_minmax = (["chalk_minimal", "chalk_maximal"], 0)
radio_set_crep   = (["crpt_minimal", "crpt_maximal"], 0)
radio_set_use    = (["use_cmd", "use_docker", "use_cicd", "use_extract"], 0)
radio_set_arch   = (["lx86", "m1"], 0)

all_radio_sets = [radio_set_dbg, radio_set_minmax, radio_set_crep,
                  radio_set_use, radio_set_arch]

pane_switch_map = {
    "report_log" : "#log_conf",
    "report_http" : "#http_conf",
    "report_s3" : "#s3_conf",
    "env_custom" : "#envconf"
}

bool_defaults = {
    "chalk_ptr"        : True,
    "chalk_datetime"   : True,
    "chalk_embeds"     : False,
    "chalk_repo"       : False,
    "chalk_rand"       : False,
    "chalk_build_env"  : False,
    "chalk_sig"        : True,
    "chalk_sast"       : False,
    "chalk_sbom"       : False,
    "chalk_virtual"    : False,
    "label_cid"        : True,
    "label_mdid"       : True,
    "label_repo"       : True,
    "label_commit"     : True,
    "label_branch"     : True,
    "crpt_errs"        : False,
    "crpt_embed"       : False,
    "crpt_host"        : False,
    "crpt_env"         : False,
    "crpt_sig"         : False,
    "crpt_sast"        : False,
    "crpt_sbom"        : False,
    "drpt_labels"      : True,
    "drpt_tags"        : True,
    "drpt_dfile"       : False,
    "drpt_dfpath"      : True,
    "drpt_platform"    : True,
    "drpt_cmd"         : False,
    "drpt_ctx"         : False,
    "xrpt_env"         : True,
    "xrpt_containers"  : True,
    "xrpt_fullmark"    : False,
    "report_co"        : True,
    "report_stdout"    : True,
    "report_stderr"    : False,
    "report_log"       : True,
    "report_http"      : False,
    "report_s3"        : False,
    "env_adds_report"  : False,
    "env_custom"       : False,
    "overwrite_config" : False,
    "log_truncate"     : True
}

text_defaults = {
    "exe_name"      : "chalk",
    "conf_name"     : "default",
    "label_prefix"  : "run.crashoverride.",
    "log_loc"       : "./chalk-log.jsonl",
    "env_log"       : "CHALK_LOG_FILE",
    "env_post_url"  : "CHALK_POST_URL",
    "env_post_hdr"  : "CHALK_POST_HEADERS",
    "env_s3_uri"    : "CHALK_S3_URI",
    "env_s3_secret" : "CHALK_S3_SECRET",
    "env_s3_aid"    : "CHALK_S3_ACCESS_ID",
    "https_url"     : "chalk.crashoverride.run/report",
    "https_header"  : "",
    "s3_uri"        : "",
    "s3_access_id"  : "",
    "s3_secret"     : ""
}    

def is_true(d, k):
    if not k in d: return false
    return d[k] == True


profile_name_map = {
    "chalk_min"  : "chalking_ptr",
    "chalk_max"  : "chalking_default",
    "chalk_art"  : "artifact_report_insert_base",
    "chalk_host" : "host_report_insert_base",
    "labels"     : "chalk_labels",
    "x_min_host" : "host_report_minimal",
    "x_max_host" : "host_report_other_base",
    "x_min_art"  : "artifact_report_minimal",
    "x_max_art"  : "artifact_report_extract_base"
}    

def profile_set(profile, k, val):
    return 'profile.%s.key.%s.report = %s' % (profile_name_map[profile], k, val)

def no_reporting(d):
    "report_co", "report_stdout", "report_stderr", "report_log", "report_http",
    "report_s3", "env_adds_report", "env_custom",

    if (is_true(d, "report_co") or is_true(d, "report_stdout") or
        is_true(d, "report_stderr") or is_true(d, "report_log") or
        is_true(d, "report_http") or is_true(d, "report_s3")):
        return False
    
    return True
    
def dict_to_con4m(d):
    if is_true(d, "lx86"):
        forLinux = True
    else:
        forLinux = False
    lines = []
    
    lines.append("cmd := argv0()")
    
    if is_true(d, "use_docker"):
        lines.append('default_command = "docker"')
        lines.append('log_level = "error"')
    elif is_true(d, "use_cicd"):
        lines.append('default_command = "insert"')
    elif is_true(d, "use_extract"):
        lines.append('default_command = "extract"')

    if is_true(d, "log_truncate"):
        filesink = "rotating_log"
    else:
        filesink = "file"

    s3_uri = d["s3_uri"]
    if s3_uri != "":
        if not s3_uri.startswith("s3://"):
            s3_uri = "s3://" + s3_uri

    lines.append("""# WARNING: This configuration was automatically generated
# by the Chalk install wizard.  Please do not edit it.  Instead, re-run it.

# Add in config for all the sinks we might need to generate;
# we will only subscribe the ones we need.

sink_config env_var_log_file {
  sink: "%s"
  filters: ["fix_new_line"]
  filename: env("%s")
} 

sink_config env_var_post {
  sink:    "post"
  uri:     env("%s")
  headers: env("%s")
}

sink_config env_var_s3 {
  sink:   "s3"
  secret: env("%s")
  uid:    env("%s")
  uri:    env("%s")
}

sink_config pre_config_log {
  sink:    "%s"
  filters: ["fix_new_line"]
  filename: "%s"
}

sink_config pre_config_post {
  sink:    "post"
  uri:     "%s"
  headers: "%s"
}

sink_config pre_config_s3 {
  sink:   "s3"
  uri:    "%s"
  secret: "%s"
  uid:    "%s"

}

# This determines whether we have been configured to output anything
# at all. It doesn't ensure the output configuration actually works!

set_sink := false

# If the settings chosen when generating this configuration allow env
# var configs to be in-addition-to a pre-configured value, then these
# will never get changed, resulting in a no-op.  Otherwise, they'll
# get set to False when sinks are properly configured via env var.

add_log_subscription := true
add_post_subscription := true
add_s3_subscription := true

ptr_value := ""
""" % (filesink, d["env_log"], d["env_post_url"], d["env_post_hdr"],
       d["env_s3_uri"], d["env_s3_secret"], d["env_s3_aid"], filesink,
       d["log_loc"], d["https_url"], d["https_header"], s3_uri,
       d["s3_secret"], d["s3_access_id"]))
                 
    if is_true(d, "env_adds_report"):
        extra_set_log  = ""
        extra_set_post = ""
        extra_set_s3   = ""

    else:
        extra_set_log  = "\n  add_log_subscription  := false"
        extra_set_post = "\n  add_post_subscription := false"
        extra_set_s3   = "\n  add_s3_subscription   := false"
        
    lines.append("""
if sink_config.env_var_log_file.filename != "" {
  subscribe("report", "env_var_log_file")%s
  set_sink := true
}  

if sink_config.env_var_post.uri != "" {
  subscribe("report", "env_var_post")%s
  set_sink := true
  ptr_value := sink_config.env_var_post.uri
}

s3_fields_found := 0
if sink_config.env_var_s3.uri != "" {
  s3_fields_found := 1
}
if sink_config.env_var_s3.secret != "" {
  s3_fields_found := s3_fields_found + 1
}
if sink_config.env_var_s3.uid != "" {
  s3_fields_found := s3_fields_found + 1
}
if s3_fields_found == 3 {
  subscribe("report", "env_var_s3")%s
  set_sink := true
  if ptr_value == "" {
    ptr_value := sink_config.env_var_s3.uri
  }
} 
elif s3_fields_found != 0 {
  error("environment variable setting for S3 output requires setting " + 
        "3 variables, but only " + $(s3_fields_found) + " were set.")
}
""" % (extra_set_log, extra_set_post, extra_set_s3))

    if is_true(d, "report_s3"):
        lines.append("""            
if add_s3_subscription {
      subscribe("report", "pre_config_s3")
      set_sink := true
      if ptr_value == "" {
          ptr_value := sink_config.pre_config_s3.uri
      }
}
""")

    if is_true(d, "report_http"):
        lines.append("""
if add_post_subscription {
      subscribe("report", "pre_config_post")
      set_sink := true
      if ptr_value == "" {
          ptr_value := sink_config.pre_config_post.uri
      }
}
""")

    if is_true(d, "report_log"):
        lines.append("""
if add_log_subscription {
    subscribe("report", "pre_config_log")
    set_sink := true
}
""")

    if is_true(d, "report_stdout"):
        lines.append("""
subscribe("report", "json_console_out")
set_sink := true
""")

    if not is_true(d, "report_stderr"):
        if no_reporting(d):
            lines.append("""
# No reporting was configured in the config generator,
# which we take to mean, when editing the chalk mark, the chalk mark
# becomes the storage location of record.  But, when running other operations,
# specifically an 'extract', we will leave the default subscription to
# stderr, if no other output sink is configured.
       
if set_sink == true or ["build", "insert", "delete"].contains(cmd) {
    unsubscribe("report", "json_console_error")
}
""")
        else:
              lines.append("""
# We assume one of the above reports is configured correctly.
unsubscribe("report", "json_console_error")
""")


    # If we configure one of these on, we need to turn on the running of the
    # tools too.
    enable_sbom = False
    enable_sast = False
              
    if is_true(d, "chalk_minimal"):
        lines.append("""
outconf.insert.chalk = "chalking_ptr"
outconf.build.chalk  = "chalking_ptr"

keyspec.CHALK_PTR.value = strip(ptr_value)
""")
              
        if not is_true(d, "chalk_ptr"):
            lines.append(profile_set('chalk_min', 'CHALK_PTR', 'false'))
        if not is_true(d, "chalk_datetime"):
            lines.append(profile_set('chalk_min', 'DATETIME', 'false'))
        if is_true(d, "chalk_embeds"):
            lines.append(profile_set('chalk_min', 'EMBEDDED_CHALK', 'true'))
        if is_true(d, "chalk_repo"):
            lines.append(profile_set('chalk_min', 'ORIGIN_URI', 'true'))
            lines.append(profile_set('chalk_min', 'BRANCH', 'true'))            
            lines.append(profile_set('chalk_min', 'COMMIT_ID', 'true'))
        if is_true(d, "chalk_rand"):
            lines.append(profile_set('chalk_min', 'CHALK_RAND', 'true'))
        if is_true(d, "chalk_build_env"):
            lines.append(profile_set('chalk_min', 'INSERTION_HOSTINFO', 'true'))
            lines.append(profile_set('chalk_min', 'INSERTION_NODENAME', 'true'))            
        if is_true(d, "chalk_sig"):
            lines.append(profile_set('chalk_min', 'SIGNATURE', 'true'))
            lines.append(profile_set('chalk_min', 'SIGN_PARAMS', 'true'))
        if is_true(d, "chalk_sbom"):
            lines.append(profile_set('chalk_min', 'SBOM', 'true'))
            enable_sbom = True
        if is_true(d, "chalk_sast"):
            lines.append(profile_set('chalk_min', 'SAST', 'true'))
            enable_sast = True
    else:
        # Positive results from is_true here are subtractive; negative ones
        # are additive.
        if not is_true(d, "chalk_ptr"):
            lines.append(profile_set('chalk_max', 'CHALK_PTR', 'true'))
        if is_true(d, "chalk_datetime"):
            lines.append(profile_set('chalk_max', 'DATETIME', 'false'))
        if is_true(d, "chalk_embeds"):
            lines.append(profile_set('chalk_max', 'EMBEDDED_CHALK', 'false'))
        if is_true(d, "chalk_repo"):
            lines.append(profile_set('chalk_max', 'ORIGIN_URI', 'false'))
            lines.append(profile_set('chalk_max', 'BRANCH', 'false'))
            lines.append(profile_set('chalk_max', 'COMMIT_ID', 'false'))
        if is_true(d, "chalk_rand"):
            lines.append(profile_set('chalk_max', 'CHALK_RAND', 'false'))
        if is_true(d, "chalk_build_env"):
            lines.append(profile_set('chalk_max', 'INSERTION_HOSTINFO', 'false'))
            lines.append(profile_set('chalk_max', 'INSERTION_NODENAME', 'false'))            
        if is_true(d, "chalk_sig"):
            lines.append(profile_set('chalk_max', 'SIGNATURE', 'false'))
            lines.append(profile_set('chalk_max', 'SIGN_PARAMS', 'false'))
        if is_true(d, "chalk_sbom"):
            lines.append(profile_set('chalk_max', 'SBOM', 'false'))
        else:
            enable_sbom = True
        if is_true(d, "chalk_sast"):
            lines.append(profile_set('chalk_max', 'SAST', 'false'))
        else:
            enable_sast = True
    if is_true(d, "chalk_virtual"):
        lines.append('virtual_chalk = true')
        lines.append('subscribe("virtual", "virtual_chalk_log")')
    if is_true(d, "label_cid"):
        lines.append(profile_set('labels', 'CHALK_ID', 'true'))
    if is_true(d, "label_mdid"):
        lines.append(profile_set('labels', 'METADATA_ID', 'true'))        
    if not is_true(d, "label_repo"):
        lines.append(profile_set('labels', 'ORIGIN_URI', 'false'))        
    if not is_true(d, "label_commit"):
        lines.append(profile_set('labels', 'COMMIT_ID', 'false'))
    if not is_true(d, "label_branch"):
        lines.append(profile_set('labels', 'BRANCH', 'false'))
        
    lines.append('docker.label_prefix = "' + d["label_prefix"] + '"')

    if is_true(d, "crpt_minimal"):
        lines.append(profile_set('chalk_host', 'CHALK_RAND', 'false'))
        lines.append(profile_set('chalk_host', '_ACTION_ID', 'false'))
        lines.append(profile_set('chalk_host', '_UNMARKED', 'false'))
        lines.append(profile_set('chalk_art',  'TIMESTAMP', 'false'))
        lines.append(profile_set('chalk_art',  'HASH_FILES', 'false'))
        lines.append(profile_set('chalk_art',  'COMPONENT_HASHES', 'false'))
        lines.append(profile_set('chalk_art',  'BUILD_ID', 'false'))
        lines.append(profile_set('chalk_art',  'BUILD_URI', 'false'))
        lines.append(profile_set('chalk_art',  'BUILD_API_URI', 'false'))
        lines.append(profile_set('chalk_art',  'BUILD_TRIGGER', 'false'))
        lines.append(profile_set('chalk_art',  'BUILD_CONTACT', 'false'))
        lines.append(profile_set('chalk_art',  'CHALK_RAND', 'false'))
        lines.append(profile_set('chalk_art',  'OLD_CHALK_METADATA_HASH', 'false'))
        lines.append(profile_set('chalk_art',  'OLD_CHALK_METADATA_ID', 'false'))
        lines.append(profile_set('chalk_art',  '_VIRTUAL', 'false'))
        
        if not is_true(d, "crpt_errs"):
            lines.append(profile_set('chalk_host', '_OP_ERRORS', 'false'))
            lines.append(profile_set('chalk_art',  'ERR_INFO', 'false'))
        if not is_true(d, "crpt_embed"):
            lines.append(profile_set('chalk_art',  'EMBEDDED_CHALK', 'false'))
        if not is_true(d, "crpt_host"):
            lines.append(profile_set('chalk_host', 'INSERTION_HOSTINFO', 'false'))
            lines.append(profile_set('chalk_host', 'INSERTION_NODENAME', 'false'))
        if is_true(d, "crpt_env"):
            lines.append(profile_set('chalk_host', 'ENV', 'true'))
        if not is_true(d, "crpt_sig"):
            lines.append(profile_set('chalk_art',  'SIGN_PARAMS', 'false'))
            lines.append(profile_set('chalk_art',  'SIGNATURE', 'false'))
        if is_true(d, "crpt_sast"):
            lines.append(profile_set('chalk_host', 'SAST', 'false'))
            lines.append(profile_set('chalk_art',  'SAST', 'false'))
        else:
            enable_sast = True
        if is_true(d, "crpt_sbom"):
            lines.append(profile_set('chalk_host', 'SBOM', 'false'))
            lines.append(profile_set('chalk_art',  'SBOM', 'false'))
        else:
            enable_sbom = True
    else:
        if is_true(d, "crpt_errs"):
            lines.append(profile_set('chalk_host', '_OP_ERRORS', 'false'))
            lines.append(profile_set('chalk_art',  'ERR_INFO', 'false'))
        if is_true(d, "crpt_embed"):
            lines.append(profile_set('chalk_art',  'EMBEDDED_CHALK', 'false'))
        if is_true(d, "crpt_host"):
            lines.append(profile_set('chalk_host', 'INSERTION_HOSTINFO', 'false'))
            lines.append(profile_set('chalk_host', 'INSERTION_NODENAME', 'false'))
        if not is_true(d, "crpt_env"):
            lines.append(profile_set('chalk_host', 'ENV', 'true'))
        if not is_true(d, "crpt_sig"):
            lines.append(profile_set('chalk_art',  'SIGN_PARAMS', 'false'))
            lines.append(profile_set('chalk_art',  'SIGNATURE', 'false'))
        if not is_true(d, "crpt_sast"):
            lines.append(profile_set('chalk_host', 'SAST', 'false'))
            lines.append(profile_set('chalk_art',  'SAST', 'false'))
        else:
            enable_sast = True
        if not is_true(d, "crpt_sbom"):
            lines.append(profile_set('chalk_host', 'SBOM', 'false'))
            lines.append(profile_set('chalk_art',  'SBOM', 'false'))
        else:
            enable_sbom = True

    if is_true(d, "drpt_labels"):
        lines.append(profile_set('chalk_art',   'DOCKER_LABELS', 'true'))
        lines.append(profile_set('chalk_host',  'DOCKER_LABELS', 'true'))
    else:
        lines.append(profile_set('chalk_art',   'DOCKER_LABELS', 'false'))
        lines.append(profile_set('chalk_host',  'DOCKER_LABELS', 'false'))        
    if is_true(d, "drpt_tags"):
        lines.append(profile_set('chalk_art',   'DOCKER_TAGS', 'true'))
        lines.append(profile_set('chalk_host',  'DOCKER_TAGS', 'true'))        
    else:
        lines.append(profile_set('chalk_art',   'DOCKER_TAGS', 'false'))
        lines.append(profile_set('chalk_host',  'DOCKER_TAGS', 'false'))        
    if is_true(d, "drpt_dfile"):
        lines.append(profile_set('chalk_art',   'DOCKER_FILE', 'true'))
        lines.append(profile_set('chalk_host',  'DOCKER_FILE', 'true'))        
    else:
        lines.append(profile_set('chalk_art',   'DOCKER_FILE', 'false'))
        lines.append(profile_set('chalk_host',  'DOCKER_FILE', 'false'))        
    if is_true(d, "drpt_dfpath"):
        lines.append(profile_set('chalk_art',   'DOCKERFILE_PATH', 'true'))
        lines.append(profile_set('chalk_host',  'DOCKERFILE_PATH', 'true'))
    else:
        lines.append(profile_set('chalk_art',   'DOCKERFILE_PATH', 'false'))
        lines.append(profile_set('chalk_host',  'DOCKERFILE_PATH', 'false'))
    if is_true(d, "drpt_platform"):
        lines.append(profile_set('chalk_art',   'DOCKER_PLATFORM', 'true'))
        lines.append(profile_set('chalk_host',  'DOCKER_PLATFORM', 'true'))        
    else:
        lines.append(profile_set('chalk_art',   'DOCKER_PLATFORM', 'false'))
        lines.append(profile_set('chalk_host',  'DOCKER_PLATFORM', 'false'))
    if is_true(d, "drpt_cmd"):
        lines.append(profile_set('chalk_host',  'ARGV', 'true'))
    else:
        lines.append(profile_set('chalk_host',  'ARGV', 'false'))                  
    if is_true(d, "drpt_ctx"):
        lines.append(profile_set('chalk_art',   'DOCKER_CONTEXT', 'true'))
        lines.append(profile_set('chalk_host',  'DOCKER_CONTEXT', 'true'))
    else:
        lines.append(profile_set('chalk_art',   'DOCKER_CONTEXT', 'false'))
        lines.append(profile_set('chalk_host',  'DOCKER_CONTEXT', 'false'))
    if is_true(d, "xrpt_fullmark"):
        x_rept_host = "x_min_host"
        x_rept_art  = "x_min_art"                  
    else:
        x_rept_host = "x_max_host"
        x_rept_art  = "x_max_art"
                  
    lines.append('outconf.extract.artifact_report = "%s"' %
                 profile_name_map[x_rept_art])
    lines.append('outconf.extract.host_report     = "%s"' %
                 profile_name_map[x_rept_host])
                  
    if not is_true(d, "xrpt_env"):
        lines.append(profile_set(x_rept_host, '_OP_CHALKER_COMMIT_ID', 'false'))
        lines.append(profile_set(x_rept_host, '_OP_CHALKER_VERSION', 'false'))
        lines.append(profile_set(x_rept_host, '_OP_PLATFORM', 'false'))
        lines.append(profile_set(x_rept_host, '_OP_HOSTINFO', 'false'))
        lines.append(profile_set(x_rept_host, '_OP_NODENAME', 'false'))
        lines.append(profile_set(x_rept_art, '_OP_CHALKER_COMMIT_ID', 'false'))
        lines.append(profile_set(x_rept_art, '_OP_CHALKER_VERSION', 'false'))
        lines.append(profile_set(x_rept_art, '_OP_PLATFORM', 'false'))
        lines.append(profile_set(x_rept_art, '_OP_HOSTINFO', 'false'))
        lines.append(profile_set(x_rept_art, '_OP_NODENAME', 'false'))
    if is_true(d, "xrpt_containers"):
        pass # not implemented yet.
              
    # Turn on sbom / sast if need be.
    if enable_sast:
        lines.append('run_sast_tools = true')
    if enable_sbom:
        lines.append('run_sbom_tools = true')
    
    return "\n".join(lines)

def config_to_json():
    result = {}
    for item in all_fields:
        widget = app.query_one("#" + item)
        result[item] = widget.value
    return json.dumps(result)

def dict_to_id(d):
    to_hash = chalk_version + "\n"
    for item in all_fields:
        if item in not_in_id:
            continue
        if not item in d:
            if item in bool_defaults:
                value = str(bool_defaults[item])
            elif item in text_defaults:
                value = text_defaults[item]
            else:
                for group in all_radio_sets:
                    items, default_ix = group
                    if not item in items: continue
                    if items[default_ix] == item:
                        value = 'True'
                    else:
                        value = 'False'
                    break
        else:
            value = str(d[item])
        to_hash += item + ":" + value + "\n"
    print(to_hash)
    return hashlib.sha256(to_hash.encode("utf-8")).hexdigest()[:32]

def json_to_dict(s):
    d = json.loads(s)
    if type(d) != type({}):
        raise ValueError("Saved Json is not an object type")
    for item in d:
        if not item in all_fields:
            raise ValueError("Key '" + item + "' is not a config key")
    for item in all_fields:
        if not item in d:
            # Load its default, if it's not a radio button.
            if item in bool_defaults:
                d[item] = bool_defaults[item]
            elif item in text_defaults:
                d[item] = text_defaults[item]
    for group in all_radio_sets:
        items, default_ix = group
        found_value     = False
        found_anything  = False
        for item in items:
            if item in d and d[item] == True:
                found_anything = True
                if found_value:
                    raise ValueError("Multiple radio buttons in the same set are enabled.")
                else:
                    found_value = True
        if not found_anything:
            default_name = items[default_ix]
            d[default_name] = True
        elif not found_value:
            raise ValueError("Explicit false values in radio button items, with no true value set.  Can set only the 'True' value or all values, or leave blank to accept the default.  All items in group: " + ", ".join(items))
    return d

def load_from_json(json_blob):
    configset = json_to_dict(json_blob)
    for k in configset:
        widget = app.query_one("#" + k)
        widget.value = configset[k]
        # The above all sets values; this enables or disables panes
        # based on the variables that control whether or not they are
        # enabled.
        if k in pane_switch_map:
            pane = app.query_one(pane_switch_map[k])
            if pane.disabled == True and widget.value == True:
                pane.disabled = False
            elif pane.disabled == False and widget.value == False:
                pane.disabled = True

sqlite_inited = False

def sqlite_init():
    global db, cursor, sqlite_inited
    if sqlite_inited:
        return
    sqlite_inited = True
    base = os.path.expanduser('~')
    dir  = os.path.join(base, Path(".config") / Path("chalk"))
    os.makedirs(dir, exist_ok=True)
    fullpath = os.path.join(dir, "chalk-config.db")
    db = sqlite3.connect(fullpath)
    cursor = db.cursor()
    create = False
    try:
        r = cursor.execute("SELECT name FROM sqlite_master where name='configs'").fetchone()
        if r == None:
            create = True
    except:
        create = True
    if create:
        default_config = config_to_json()
        as_dict        = json_to_dict(default_config)
        internal_id    = dict_to_id(as_dict)
        timestamp      = datetime.datetime.now().ctime()
        cursor.execute("CREATE TABLE configs(name, date, chalk_version, id, " +
                       "json)")
        row = ['default', timestamp, chalk_version,
               internal_id, default_config]
        cursor.execute("INSERT INTO configs VALUES(?, ?, ?, ?, ?)", row)
        db.commit()
        
def test_stuff():
    json = config_to_json()
    print(json)
    d = json_to_dict(json)
    f = open('chalk.conf', 'w')
    f.write(dict_to_con4m(d))
    f.close()
    quit()

class ConfigName(Label):
    pass

class ConfigDate(Label):
    pass

class ConfigVersion(Label):
    pass

class ConfigEdit(Button):
    pass

class ConfigDelete(Button):
    pass

class ConfigExport(Button):
    pass

class ConfigHdr(Horizontal):
    pass

class ConfigRow(Horizontal):
    def __init__(self, name, date, iid, version, json):
        Horizontal.__init__(self, id="confrow_" + name)
        self.iid = iid
        self.name_label = name
        self.date_label = date
        self.vers_label = version
        self.json       = json

    def compose(self):
        yield ConfigName(self.name_label, classes="conflabel")
        yield ConfigDate(self.date_label, classes="confdate")
        yield ConfigVersion(self.vers_label, classes="confvers")
        edit = ConfigEdit(label="Edit", id="e_" + self.iid)
        edit.json = self.json
        yield edit
        yield ConfigDelete(label="Delete", id = "d_" + self.iid)
        yield ConfigExport(label="Export", id="x_" + self.iid)

class ConfigTable(Container):
    def compose(self):
        yield ConfigHdr(ConfigName("Configuration Name"),
                        ConfigDate("Date Created"),
                        ConfigVersion("Chalk Version"))

        sqlite_init()
        rows = cursor.execute("SELECT * FROM configs").fetchall()
        for row in rows:
            yield ConfigRow(row[0], row[1], row[2], row[3], row[4])
        

class ReportingContainer(Container):
    pass

class HelpWindow(MDown):
    def action_help(self):
        self.wiz.action_help()

    def on_click(self):
        self.toggle_class('-hidden')

class NavButton(Button):
    def __init__(self, id, wiz, disabled=False):
        Button.__init__(self, label=id, id=id, variant="primary", disabled=disabled)
        self.wiz = wiz
    def on_button_pressed(self):
        self.wiz.action_label(self.id)

class WizContainer(Container):
    def entered(self):
        self.has_entered = True
    def complete(self):
        if not self.has_entered:
            return False
        if self.disabled:
            return True
        return True # Todo: check the text box
    def toggle(self):
        self.disabled = not self.disabled
    def doc(self):
        return """# Some title
## Some subtitle
Some content
"""

class BuildBinary(WizContainer):
    def compose(self):
        self.has_entered = False
        yield Static("""Do you want a release build?""")
        yield RadioSet(RadioButton("Yes", True, id="release_build"),
                       RadioButton("No, give me a debug build", id="debug_build"))        
        yield Horizontal(Input(placeholder="exe name", id = "exe_name",
                               value=text_defaults["exe_name"]),
                         Label("File to output", classes="label"))
        yield Horizontal(Input(placeholder="configuration name",
                               id = "conf_name",
                               value = text_defaults["conf_name"]),
                         Label("Name this configuration to save it",
                               classes="label"))
        yield Horizontal(Switch(value = True, id="overwrite_config"),
                         Label("Overwrite any config with the same name"))
        

class ChalkOpts(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
When we add chalk marks to software, what kinds of information do you want to put into the software itself?  Note that this is separate from what gets reported when chalking.

Note that things listed as 'coming soon' can be configured manually, but are not yet in this user interface.
""")
        yield RadioSet(RadioButton("Basic Chalk IDing info, plus:", value=True,
                                   id="chalk_minimal"),
                       RadioButton("Everything, except: ", id="chalk_maximal"))
        yield ReportingContainer(
            Checkbox("URL for where reporting goes", value=True,
                     id="chalk_ptr"),
            Checkbox("Date/time of marking", value=True, id="chalk_datetime"),
            Checkbox("Info about embedded executable content (e.g., scripts " +
                     "in Zip files)", id="chalk_embeds"),
            Checkbox("Discovered source repository information",
                     id="chalk_repo"),
            Checkbox("A random value for unique builds", id="chalk_rand"),
            Checkbox("Information about the build host", id="chalk_build_env"),
            EnablingCheckbox("sigmenu", "A digitial signature -- coming soon",
                             id="chalk_sig", disabled=True),
            Checkbox("Semgrep scan results -- This can get large",
                     id="chalk_sast"),
            Checkbox("SBOM -- a 'Software Bill Of Materials'.  " +
                     "This can get large", id="chalk_sbom"),
            Checkbox("Actually, don't put them in the artifact, " + 
                     "write to a file", id="chalk_virtual")
        )

class DockerChalking(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
When chalking Docker containers, it's best to wrap every call to Docker, but it's important to wrap **docker build** and **docker push** to make it easy to track containers you create.

When running in Docker mode, there are some things we currently cannot chalk (we ignore them), such as remote contexts and images built via **docker compose**.

We also can automatically label containers as we chalk them. You can configure your label setup here.
""")
        yield Horizontal(Input(placeholder="Enter label prefix",
                               id = "label_prefix",
                               value= text_defaults["label_prefix"]),
                         Label("The label prefix to use", classes="label"))
        yield ReportingContainer(
            Checkbox("Label the Chalk ID (unique identifier for pre-chalk software)", value=True, id="label_cid"),
            Checkbox("Label the Metadata ID (identifies the post-chalk software)", value=True, id="label_mdid"),
            Checkbox("Label the source repository URI found at build", value=True, id="label_repo"),
            Checkbox("Label the commit ID found at build", value=True, id="label_commit"),
            Checkbox("Label the branch found at build", value=True, id="label_branch")
        )
        
class ReportingOptsChalkTime(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
In the report we generate after a chalk mark is written, what kind of information do you want?  

Note that things listed as 'coming soon' can be configured manually, but are not yet in this user interface.
""")
        yield RadioSet(RadioButton("Key build-time information, plus:", id="crpt_minimal"),
                       RadioButton("Everything, except: ", value=True, id="crpt_maximal"))
        yield ReportingContainer(
            Checkbox("Info on any significant errors found during chalking", id="crpt_errs"),
            Checkbox("Info about embedded executable content (e.g., scripts in Zip files)", id="crpt_embed"),
            Checkbox("Information about the build host", id="crpt_host"),            
            EnablingCheckbox("redaction", "Build-time environment vars (redaction options on next screen if selected) -- coming soon", disabled=True, id="crpt_env"),
            EnablingCheckbox("sig", "A digitial signature -- coming soon", disabled=True, id="crpt_sig"),
            
            Checkbox("Semgrep scan results -- Can impact build speeds", id="crpt_sast", value=True),
            Checkbox("SBOM -- a 'Software Bill Of Materials'. Significant build speed impact is typical.", id="crpt_sbom", value=True)
        )

class ReportingOptsDocker(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
When chalking Docker containers, what Docker-specific info would you like reported back at chalk time?""")
        yield ReportingContainer(
            Checkbox("Any labels added during the build (minus ones added automatically via Chalk", value=True, id="drpt_labels"),
            Checkbox("Any tags added during the build", value=True, id="drpt_tags"),
            Checkbox("The Dockerfile used to build the container", id="drpt_dfile"),
            Checkbox("The path to the Dockerfile on the build system", id="drpt_dfpath"),
            Checkbox("The platform passed to [grey bold]docker build[/]", id="drpt_platform"),
            Checkbox("The full command-line arguments", id="drpt_cmd"),
            Checkbox("The docker context used during the build", id="drpt_ctx")
        )

class ReportingExtraction(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
If running chalk to extract marks from software, what do you want to report, beyond basic identifying information?""")
        yield ReportingContainer(
            Checkbox("Information about the operating environment", value=True, id="xrpt_env"),
            Checkbox("Automatically report on any running containers seen locally (coming soon)", value=True, disabled=True, id="xrpt_containers"),
            Checkbox("All data found in the chalk mark", id="xrpt_fullmark")
        )


class LogParams(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield Static(LOG_PARAMS)
        yield Horizontal(Label("Log file location: ", classes="label"),
                         Input(placeholder="/path/to/log/file",
                               id = "log_loc",
                               value = text_defaults["log_loc"]))
        yield Horizontal(Switch(value=True, id="log_truncate"),
                         Static("Enforce max size", classes="label"))

class CustomEnv(WizContainer):
    # CHALK_POST_URL, CHALK_POST_HEADERS
    # AWS_S3_BUCKET_URI, AWS_ACCESS_SECRET, AWS_ACCESS_ID
    # CHALK_LOG
    
    def compose(self):
        self.has_entered = False
        yield Container(
            Label("Environment Variable Configuration"),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_log", value = text_defaults["env_log"]),
                Label("Log file path", classes="label")),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_post_url",
                      value = text_defaults["env_post_url"]),
                Label("HTTPS POST url", classes="label")),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_post_hdr",
                      value = text_defaults["env_post_hdr"]),
                Label("HTTPS extra MIME headers", classes="label")),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_s3_uri", value = text_defaults["env_s3_uri"]),
                Label("S3 Bucket uri (must be an s3 URL)", classes="label")),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_s3_secret",
                      value = text_defaults["env_s3_secret"]),
                Label("S3 AWS access secret", classes="label")),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_s3_aid", value = text_defaults["env_s3_aid"]),
                Label("S3 AWS access ID", classes="label")))

class HttpParams(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield Static(HTTPS_PARAMS)
        yield Horizontal(Label("URL for POST: ", classes="label"),
                         Label("https://", classes="label emphLabel"),
                         Input(placeholder="Enter url",
                               id = "https_url",
                               value = text_defaults["https_url"])
                         )
        yield Horizontal(
                         Label("Extra MIME header: ", classes="label"),
                         Input(id = "https_header")
            )

class S3Params(WizContainer):        
    def compose(self):
        self.has_entered  = False
        yield Static("Enter values for S3 parameters")
        yield Horizontal(Label("s3://", classes="label emphLabel"),
                         Input(placeholder="Enter bucket path",
                               id = "s3_uri"),
                         Label("AWS Bucket Path", classes="label"))
        yield Horizontal(Label("     ", classes="label"),
                         Input(placeholder="Enter AWS Access ID",
                               id = "s3_access_id"),
                         Label("AWS Access ID", classes="label"))
        yield Horizontal(Label("     ", classes="label"),
                         Input(placeholder="Enter AWS secret",
                               id = "s3_secret"),
                         Label("AWS Secret", classes="label"))

class WelcomePane(MDown):
    def entered(self):
      self.has_entered = True
    def complete(self):
        try:
            return self.has_entered
        except:
            self.has_entered = False
            return False
    def doc(self):
        return """# Default help documentation

This is a default message, meant to be filled in by future generations of me.

## h2
### h3
"""

class WizardStep:
    def __init__(self, name, widget, disabled=False, help=None, callback=None):
        self.name     = name
        self.widget   = widget
        self.disabled = disabled
        self.help     = help
        self.callback = callback
        widget.id = name
    def entered(self):
        return self.widget.entered()
    def complete(self):
        return self.widget.complete()
    
class WizardSection:
    def __init__(self, name):
        self.name       = name
        self.step_dict  = {}
        self.step_order = []
        self.step_index = 0
    def add_step(self, name, widget, disabled=False, help=None, callback=None):
        new_step = WizardStep(name, widget, disabled, help, callback)
        self.step_dict[name] = new_step
        self.step_order.append(new_step)
    def start_section(self):
        self.step_index = 0
        return self.step_order[0]
    def goto_section_end(self):
        self.step_index = len(self.step_order)
        return self.backwards()
    def advance(self):
        while True:
            self.step_index += 1
            if self.step_index >= len(self.step_order):
                return None
            step = self.step_order[self.step_index]
            if not step.widget.disabled:
                return step
    def backwards(self):
        while True:
            self.step_index -= 1
            if self.step_index < 0:
                return None
            step = self.step_order[self.step_index]
            if not step.widget.disabled:
                return step
    def lookup(self, name):
        if name in self.step_dict:
            return name
        return None
    def complete(self):
        if not len(self.step_order):
            return True
        return self.step_order[-1].widget.complete()

class EnablingCheckbox(Checkbox):
    def __init__(self, target, title, value=False, disabled=False, id=None):
        Checkbox.__init__(self, title, value, disabled=disabled, id=id)
        self.refd_id = "#" + target
       
    def on_checkbox_changed(self, event: Checkbox.Changed):
        app.query_one(self.refd_id).toggle()

class EnvToggle(Switch):
    def on_click(self):
        envpane = app.query_one("#envconf")
        envpane.disabled = not envpane.disabled
        
class ReportingPane(WizContainer):
    def compose(self):
        self.has_entered = False
        yield Static(REPORTING_PANE_MAIN)
        yield ReportingContainer(Checkbox(REPORTING_PANE_CO, value=True,
                                          id="report_co"),
                       Checkbox(REPORTING_PANE_STDOUT, value=True,
                                id="report_stdout"),
                       Checkbox("Output to stderr", id="report_stderr"),
                       EnablingCheckbox("log_conf", REPORTING_PANE_LOG,
                                        id="report_log"),
                       EnablingCheckbox("http_conf", REPORTING_PANE_HTTPS,
                                        id="report_http"),
                       EnablingCheckbox("s3_conf", REPORTING_PANE_S3,
                                        id="report_s3"))
        yield ReportingContainer(MDown(REPORTING_PANE_ENV),
                        Horizontal(Switch(value=False, id="env_adds_report"),
                        Label(REPORTING_ENV_LABEL, classes="label")),
                        Horizontal(EnvToggle(value=False, id="env_custom"),
                                   Label(REPORTING_ENV2_LABEL, classes="label")))
    def complete(self):
        return self.has_entered
    
class WizardSidebar(Container):  pass
class Body(ScrollableContainer): pass

class WizSidebarButton(Button):
    def __init__(self, label, wiz):
        super().__init__(label)
        self.disabled = True
        self.wiz      = wiz
    def on_click(self):
        self.wiz.action_section(self.label)

class UsagePane(Container):
    def entered(self):
        self.has_entered = True
    def compose(self):
        yield MDown(BASICS_PANE_MAIN)
        yield RadioSet(RadioButton(BASICS_PANE_CMDLINE, value=True,
                                   id="use_cmd"),
                       RadioButton(BASICS_PANE_DOCKER, id="use_docker"),
                       RadioButton(BASICS_PANE_OTHER, id="use_cicd"),
                       RadioButton("In production, as a chalk mark scanner",
                                   id="use_extract")
                       )
        yield Container(Label("""What platform are we configuring the binary for?"""),
                        RadioSet(RadioButton("Linux (x86 family only)", True, id="lx86"),
                                 RadioButton("OS X (M1 family only)", id="m1")))

    def complete(self):
        try:
            return self.has_entered
        except:
            self.has_entered = False
            return False
    def doc(self):
        return """# Usage
    
Here's some more help for you.
"""
    
class Nav(Horizontal):
    pass

sectionIntro      = WizardSection("Intro")    
sectionBasics     = WizardSection("Basics")
sectionOutputConf = WizardSection("Output Config")
sectionChalking   = WizardSection("Chalking")
sectionReporting  = WizardSection("Reporting")
sectionBinGen     = WizardSection("Finish")

sectionIntro.add_step("intro", WelcomePane(INTRO_TEXT))
sectionBasics.add_step("basics", UsagePane())
sectionOutputConf.add_step("reporting", ReportingPane())
sectionOutputConf.add_step("envconf", CustomEnv(disabled=True))
sectionOutputConf.add_step("log_conf", LogParams(disabled=True))
sectionOutputConf.add_step("http_conf", HttpParams(disabled=True))
sectionOutputConf.add_step("s3_conf", S3Params(disabled=True))

sectionChalking.add_step("chalking_base", ChalkOpts())
sectionChalking.add_step("chalking_docker", DockerChalking())

sectionReporting.add_step("reporting_base", ReportingOptsChalkTime())
sectionReporting.add_step("reporting_docker", ReportingOptsDocker())
sectionReporting.add_step("reporting_extract", ReportingExtraction())

                     
sectionBinGen.add_step("final", BuildBinary())

sidebar_buttons = []

class Wizard(App):
    CSS_PATH = "wizard.css"
    TITLE    = CHALK_TITLE
    BINDINGS = [
        Binding(key="q", action="quit", description=KEYPRESS_QUIT),
        Binding(key="left", action="prev()", description="Previous Screen"),
        Binding(key="right", action="next()", description="Next Screen"),
        Binding(key="space", action="next()", show=False),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
        Binding(key="h", action="app.toggle_class('HelpWindow', '-hidden')",
                description="Toggle Help")
    ]        

    def __init__(self, end_callback):
        super().__init__()
        self.end_callback = end_callback
        
    def add_section(self, s: WizardSection):
        self.sections.append(s)
        self.by_name[s.name] = s
        button = WizSidebarButton(s.name, self)
        sidebar_buttons.append(button)
        self.sidebar_contents.append(button)

    def build_panels(self):
        self.panels = []
        for section in self.sections:
            for step in section.step_order:
                self.panels.append(step.widget)
        return ContentSwitcher(*self.panels, initial=self.panels[0].id)

    def load_sections(self):
        self.sections = []
        self.by_name = {}
        self.section_index = 0
        self.sidebar_contents = []
        self.add_section(sectionIntro)
        self.add_section(sectionBasics)
        self.add_section(sectionOutputConf)
        self.add_section(sectionChalking)
        self.add_section(sectionReporting)
        self.add_section(sectionBinGen)
        for i in range(len(self.sections)):
            self.by_name[self.sections[i].name] = i
        self.update_menu()
        
    def compose(self):
        global helpwin
        self.load_sections()
        self.switcher = self.build_panels()
        self.current_panel = self.panels[0]
        self.first_panel   = self.current_panel
        helpwin = HelpWindow(id="helpwin", name="Help Window",
                             classes="-hidden",
                             markdown=self.first_panel.doc())        
        helpwin.wiz = self
        yield helpwin
        yield WizardSidebar(*self.sidebar_contents)
        self.next_button = NavButton("Next", self)
        self.help_button = NavButton("Help", self)
        self.prev_button = NavButton("Back", self, disabled = True)
        buttons = Nav(self.prev_button, self.next_button, self.help_button)
        helpwin.update(self.first_panel.doc()) 
        body   = Body(self.switcher)
        yield Header(show_clock=True)
        #yield ConfigTable()
        yield body
        yield buttons
        yield Footer()

    def set_panel(self, new_panel):
      self.current_panel = new_panel
      self.switcher.current = new_panel.id
      new_panel.entered()
      helpwin.update(new_panel.doc())
      self.update_menu()
      
    def action_section(self, label):
        self.section_index = self.by_name[str(label)]
        step = self.sections[self.section_index].start_section()
        self.set_panel(step.widget)

    def action_section_end(self, label):
        self.section_index = self.by_name[str(label)]
        step = self.sections[self.section_index].goto_section_end()
        self.set_panel(step.widget)

    def update_menu(self):
        try:
            self.current_panel
        except:
            self.current_panel = None
            self.first_panel   = None

        if self.current_panel and not self.current_panel.complete():
            self.next_button.disabled = True
        elif self.current_panel:
            self.next_button.disabled = False
        if self.current_panel:
            if self.current_panel == self.first_panel:
                self.prev_button.disabled = True
            else:
                self.prev_button.disabled = False
        for i in range(len(sidebar_buttons)):
            if self.section_index >= i:
                disable = False
            else:
                disable = True
            sidebar_buttons[i].disabled = disable
    
    def action_label(self, id):
        if id == "Help":
            self.action_help()
        elif id == "Next":
            return self.action_next()
        else:
            return self.action_prev()

    def action_next(self):
        sqlite_init()
        new_step = self.sections[self.section_index].advance()
        if not new_step:
            self.section_index += 1
            if self.section_index == len(self.sections):
                self.end_callback()
            self.action_section(str(self.sections[self.section_index].name))
        else:
            self.set_panel(new_step.widget)

    def action_help(self):
        if helpwin.has_class("-hidden"):
            helpwin.remove_class("-hidden")
        else:
            helpwin.add_class("-hidden")

    def action_prev(self):
        if self.current_panel == self.first_panel:
            return
        new_step = self.sections[self.section_index].backwards()
        if not new_step:
            self.section_index -= 1
            name = str(self.sections[self.section_index].name)
            self.action_section_end(name)
        else:
            self.set_panel(new_step.widget)

if __name__ == "__main__":
    cached_stdout_fd = sys.stdout
    app = Wizard(end_callback=test_stuff)
    app.run()
   
