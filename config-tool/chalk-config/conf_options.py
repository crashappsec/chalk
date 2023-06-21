import datetime
import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import tempfile
import urllib
from pathlib import *

from localized_text import *

DB_PATH_LOCAL = Path(os.path.expanduser("~/.config/chalk"))
DB_PATH_SYSTEM = Path("/var/chalk-config/")
DB_FILE = Path("chalk-config.db")
BINARY_DEBUG_URL = "file://" + os.getcwd() + "/bin/chalk"
BINARY_RELEASE_URL = "file://" + os.getcwd() + "/bin/chalk-release"
CONTAINER_DEBUG_PATH = "/config-bin/chalk"
CONTAINER_RELEASE_PATH = "/config-bin/chalk-release"

if os.path.isdir("/outdir/"):
    OUTPUT_DIRECTORY = "/outdir/"
else:
    OUTPUT_DIRECTORY = os.getcwd()

app = None


def set_app(the_app):
    global app
    app = the_app


def get_app():
    return app


def set_wiz_screen(s):
    global wiz_screen
    wiz_screen = s


def get_wiz_screen():
    return wiz_screen


def set_wizard(w):
    global wizard
    wizard = w


def get_wizard():
    return wizard


def load_from_json(json_blob, confname=None, note=None):
    # Loading is broken out into two loops, one to clear existing
    # values to false / the empty string, and then one to set the
    # desired value.  It's done this way because it's was the most
    # clear way I could handle Textualize's RadioSet semantics
    # without some refactoring.
    #
    # Specifically, if we just try to loop once, and reset each value
    # if it needs resetting, you will end up with multiple radio
    # buttons set any time you've changed something from the default
    # value.  This is true even if you muck with the RadioSet state
    # directly.
    #
    # I could do this more efficiently without any real refactoring
    # (outside this function), but I don't think it is worth the more
    # verbose code; nobody is going to notice the 'performance
    # impact'.

    for k in all_fields:
        widget = wizard.query_one("#" + k)
        if type(widget.value) != type(""):
            widget.value = False
        else:
            widget.value = ""

    configset = json_to_dict(json_blob)
    for k in all_fields:
        widget = wizard.query_one("#" + k)

        if k in configset:
            if type(configset[k]) == str:
                widget.value = configset[k]
                continue

            if configset[k]:
                widget.toggle()

        if k in pane_switch_map:
            pane = wizard.query_one(pane_switch_map[k])
            pane.disabled = not widget.value

    if confname != None:
        wizard.query_one("#conf_name").value = confname
    if note != None:
        wizard.query_one("#note").value = note


# This is a normalized list, for instance, for getting the ID of
# a config.  Thus, the order matters, and it can't be a set;
# Python seems to randomize the order?
all_fields = [
    # Basics pane
    "use_cmd",
    "use_docker",
    "use_cicd",
    "use_extract",
    # Commented out "lx86", "m1", "macosx86",
    # Main output config pane
    "report_co",
    "report_stdout",
    "report_stderr",
    "report_log",
    "report_http",
    "report_s3",
    "env_adds_report",
    "env_custom",
    # Crash Override API config
    "c0api_toggle",
    # Env var customization
    "env_log",
    "env_post_url",
    "env_post_hdr",
    "env_s3_uri",
    "env_s3_secret",
    "env_s3_aid",
    # Log file config
    "log_loc",
    "log_truncate",
    # Https config
    "https_url",
    "https_header",
    # S3 config
    "s3_uri",
    "s3_access_id",
    "s3_secret",
    # Default Chalking behavior
    "chalk_minimal",
    "chalk_maximal",
    "chalk_ptr",
    "chalk_datetime",
    "chalk_embeds",
    "chalk_repo",
    "chalk_rand",
    "chalk_build_env",
    "chalk_sast",
    "chalk_sbom",
    "chalk_virtual",  # "chalk_sig",
    # Docker Auto-labeling
    "label_cid",
    "label_mdid",
    "label_repo",
    "label_commit",
    "label_branch",
    "label_prefix",
    # Chalk Insertion Report
    "crpt_minimal",
    "crpt_maximal",
    "crpt_errs",
    "crpt_embed",
    "crpt_host",
    "crpt_env",
    "crpt_sig",
    "crpt_sast",
    "crpt_sbom",
    # Docker insertion Report
    "drpt_labels",
    "drpt_tags",
    "drpt_dfile",
    "drpt_dfpath",
    "drpt_platform",
    "drpt_cmd",
    "drpt_ctx",
    # Extraction reporting
    "xrpt_env",
    "xrpt_containers",
    "xrpt_fullmark",
    # Final screen
    "release_build",
    "debug_build",
    "exe_name",
    "conf_name",
    "overwrite_config",
    "note",
]

not_in_json = ["conf_name", "overwrite_config","c0api_toggle"]


radio_set_dbg = (["release_build", "debug_build"], 0)
radio_set_minmax = (["chalk_minimal", "chalk_maximal"], 0)
radio_set_crep = (["crpt_minimal", "crpt_maximal"], 1)
radio_set_use = (["use_cmd", "use_docker", "use_cicd", "use_extract"], 0)
# radio_set_arch   = (["lx86", "m1", "macosx86"], 0)

all_radio_sets = [
    radio_set_dbg,
    radio_set_minmax,
    radio_set_crep,
    radio_set_use,
]  # , radio_set_arch

pane_switch_map = {
    "report_log": "#log_conf",
    "report_http": "#http_conf",
    "report_s3": "#s3_conf",
    "env_custom": "#envconf",
    "api_auth" : "#c0apiuse",
    "auth_success_message" : "#c0authsuccess"
}

bool_defaults = {
    "chalk_ptr": True,
    "chalk_datetime": True,
    "chalk_embeds": False,
    "chalk_repo": False,
    "chalk_rand": False,
    "chalk_build_env": False,
    #    "chalk_sig"        : True,
    "chalk_sast": False,
    "chalk_sbom": False,
    "chalk_virtual": False,
    "label_cid": True,
    "label_mdid": True,
    "label_repo": True,
    "label_commit": True,
    "label_branch": True,
    "crpt_errs": False,
    "crpt_embed": False,
    "crpt_host": False,
    "crpt_env": False,
    "crpt_sig": False,
    "crpt_sast": False,
    "crpt_sbom": False,
    "drpt_labels": True,
    "drpt_tags": True,
    "drpt_dfile": False,
    "drpt_dfpath": True,
    "drpt_platform": True,
    "drpt_cmd": False,
    "drpt_ctx": False,
    "xrpt_env": True,
    "xrpt_containers": True,
    "xrpt_fullmark": False,
    "report_co": True,
    "report_stdout": True,
    "report_stderr": False,
    "report_log": True,
    "report_http": True,
    "report_s3": False,
    "env_adds_report": False,
    "env_custom": False,
    "overwrite_config": False,
    "log_truncate": True,
    "c0api_toggle"     : True,
}

text_defaults = {
    "exe_name": "chalk",
    "conf_name": "",
    "label_prefix": "run.crashoverride.",
    "log_loc": "./chalk-log.jsonl",
    "env_log": "CHALK_LOG_FILE",
    "env_post_url": "CHALK_POST_URL",
    "env_post_hdr": "CHALK_POST_HEADERS",
    "env_s3_uri": "CHALK_S3_URI",
    "env_s3_secret": "CHALK_S3_SECRET",
    "env_s3_aid": "CHALK_S3_ACCESS_ID",
    "https_url": "chalk.crashoverride.local/report",
    "https_header": "",
    "s3_uri": "",
    "s3_access_id": "",
    "s3_secret": "",
    "note": "",
}


base_config = text_defaults | bool_defaults
for s in all_radio_sets:
    items, ix = s
    base_config[items[ix]] = True


global default_configs

default_configs = [(base_config, "default", "Outputs to a logfile and stderr")]


default_config_json = json.dumps(base_config)

# This stuff is here because I can't be sure my widgets are fully
# loaded when I click the edit button.  WTF.

json_txt = default_config_json
name_kludge = None
note_kludge = None


profile_name_map = {
    "chalk_min": "chalking_ptr",
    "chalk_max": "chalking_default",
    "chalk_art": "artifact_report_insert_base",
    "chalk_host": "host_report_insert_base",
    "labels": "chalk_labels",
    "x_min_host": "host_report_minimal",
    "x_max_host": "host_report_other_base",
    "x_min_art": "artifact_report_minimal",
    "x_max_art": "artifact_report_extract_base",
}


def profile_set(profile, k, val):
    return "profile.%s.key.%s.report = %s" % (profile_name_map[profile], k, val)


def no_reporting(d):
    "report_co", "report_stdout", "report_stderr", "report_log", "report_http",
    "report_s3", "env_adds_report", "env_custom",

    if (
        is_true(d, "report_co")
        or is_true(d, "report_stdout")
        or is_true(d, "report_stderr")
        or is_true(d, "report_log")
        or is_true(d, "report_http")
        or is_true(d, "report_s3")
    ):
        return False

    return True


def config_to_json():
    result = {}
    for item in all_fields:
        if item in not_in_json:
            continue

        widget = wizard.query_one("#" + item)

        result[item] = widget.value
    return json.dumps(result)


def dict_to_id(d):
    to_hash = CHALK_VERSION + "\n"
    for item in all_fields:
        if item in not_in_json:
            continue
        if not item in d:
            if item in bool_defaults:
                value = str(bool_defaults[item])
            elif item in text_defaults:
                value = text_defaults[item]
            else:
                for group in all_radio_sets:
                    items, default_ix = group
                    if not item in items:
                        continue
                    if items[default_ix] == item:
                        value = "True"
                    else:
                        value = "False"
                    break
        else:
            value = str(d[item])
        to_hash += item + ":" + value + "\n"
    return hashlib.sha256(to_hash.encode("utf-8")).hexdigest()[:32]


def json_to_dict(s):
    # The exception values are just hardcoded, because these should
    # be seen only due to programmer error, not user error.
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
        found_value = None
        found_anything = False
        for item in items:
            if item in d and d[item] == True:
                found_anything = True
                if found_value:
                    raise ValueError(
                        "Multiple radio buttons in the same set are enabled (got: '%s' and '%s')"
                        % (found_value, item)
                    )
                else:
                    found_value = item
        if not found_anything:
            default_name = items[default_ix]
            d[default_name] = True
        elif not found_value:
            raise ValueError(
                "Explicit false values in radio button items, with no true value set.  Can set only the 'True' value or all values, or leave blank to accept the default.  All items in group: "
                + ", ".join(items)
            )
    return d


##### Start con4m generation here.


def is_true(d, k):
    if not k in d:
        return False
    return d[k] == True


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

    # Not going to bother pulling this out for translation; we get to
    # expect that other developers can deal w/ english only.
    lines.append(
        """# WARNING: This configuration was automatically generated
# by the Chalk install wizard.  Please do not edit it.  Instead, re-run it.

# Add in config for all the sinks we might need to generate;
# we will only subscribe the ones we need.

# If the config doesn't want a variable to be settable, the below
# code will read env(""), which will reduce to the empty string, which
# Chalk knows means the config isn't going to be used.

sink_config env_var_log_file {
  sink: "%s"
  filters: ["fix_new_line"]
  max: <<10mb>>
  filename: env("%s")
}

sink_config env_var_post {
  sink:    "post"
  uri:     env("%s")
  headers: mime_to_dict(env("%s"))
}

sink_config env_var_s3 {
  sink:   "s3"
  secret: env("%s")
  uid:    env("%s")
  uri:    env("%s")
}

sink_config pre_config_log {
  sink:    "%s"
  max: <<10mb>>
  filters: ["fix_new_line"]
  filename: "%s"
}

sink_config pre_config_post {
  sink:    "post"
  uri:     "%s"
  headers: mime_to_dict("%s")
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
"""
        % (
            filesink,
            d["env_log"],
            d["env_post_url"],
            d["env_post_hdr"],
            d["env_s3_uri"],
            d["env_s3_secret"],
            d["env_s3_aid"],
            filesink,
            d["log_loc"],
            d["https_url"],
            d["https_header"],
            s3_uri,
            d["s3_secret"],
            d["s3_access_id"],
        )
    )

    if is_true(d, "env_adds_report"):
        extra_set_log = ""
        extra_set_post = ""
        extra_set_s3 = ""

    else:
        extra_set_log = "\n  add_log_subscription  := false"
        extra_set_post = "\n  add_post_subscription := false"
        extra_set_s3 = "\n  add_s3_subscription   := false"

    lines.append(
        """
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
"""
        % (extra_set_log, extra_set_post, extra_set_s3)
    )

    if is_true(d, "report_s3"):
        lines.append(
            """
if add_s3_subscription {
      subscribe("report", "pre_config_s3")
      set_sink := true
      if ptr_value == "" {
          ptr_value := sink_config.pre_config_s3.uri
      }
}
"""
        )

    if is_true(d, "report_http"):
        lines.append(
            """
if add_post_subscription {
      subscribe("report", "pre_config_post")
      set_sink := true
      if ptr_value == "" {
          ptr_value := sink_config.pre_config_post.uri
      }
}
"""
        )

    if is_true(d, "report_log"):
        lines.append(
            """
if add_log_subscription {
    subscribe("report", "pre_config_log")
    set_sink := true
}
"""
        )

    if is_true(d, "report_stdout"):
        lines.append(
            """
subscribe("report", "json_console_out")
set_sink := true
"""
        )

    if not is_true(d, "report_stderr"):
        if no_reporting(d):
            lines.append(
                """
# No reporting was configured in the config generator,
# which we take to mean, when editing the chalk mark, the chalk mark
# becomes the storage location of record.  But, when running other operations,
# specifically an 'extract', we will leave the default subscription to
# stderr, if no other output sink is configured.

if set_sink == true or ["build", "insert", "delete"].contains(cmd) {
    unsubscribe("report", "json_console_error")
}
"""
            )
        else:
            lines.append(
                """
# We assume one of the above reports is configured correctly.
unsubscribe("report", "json_console_error")
"""
            )

    # If we configure one of these on, we need to turn on the running of the
    # tools too.
    enable_sbom = False
    enable_sast = False

    if is_true(d, "chalk_minimal"):
        lines.append(
            """
outconf.insert.chalk = "chalking_ptr"
outconf.build.chalk  = "chalking_ptr"

keyspec.CHALK_PTR.value = strip(ptr_value)
"""
        )

        if not is_true(d, "chalk_ptr"):
            lines.append(profile_set("chalk_min", "CHALK_PTR", "false"))
        if not is_true(d, "chalk_datetime"):
            lines.append(profile_set("chalk_min", "DATETIME", "false"))
        if is_true(d, "chalk_embeds"):
            lines.append(profile_set("chalk_min", "EMBEDDED_CHALK", "true"))
        if is_true(d, "chalk_repo"):
            lines.append(profile_set("chalk_min", "ORIGIN_URI", "true"))
            lines.append(profile_set("chalk_min", "BRANCH", "true"))
            lines.append(profile_set("chalk_min", "COMMIT_ID", "true"))
        if is_true(d, "chalk_rand"):
            lines.append(profile_set("chalk_min", "CHALK_RAND", "true"))
        if is_true(d, "chalk_build_env"):
            lines.append(profile_set("chalk_min", "INSERTION_HOSTINFO", "true"))
            lines.append(profile_set("chalk_min", "INSERTION_NODENAME", "true"))
        # if is_true(d, "chalk_sig"):
        #    lines.append(profile_set('chalk_min', 'SIGNATURE', 'true'))
        #    lines.append(profile_set('chalk_min', 'SIGN_PARAMS', 'true'))
        if is_true(d, "chalk_sbom"):
            lines.append(profile_set("chalk_min", "SBOM", "true"))
            enable_sbom = True
        if is_true(d, "chalk_sast"):
            lines.append(profile_set("chalk_min", "SAST", "true"))
            enable_sast = True
    else:
        # Positive results from is_true here are subtractive; negative ones
        # are additive.
        if not is_true(d, "chalk_ptr"):
            lines.append(profile_set("chalk_max", "CHALK_PTR", "true"))
        if is_true(d, "chalk_datetime"):
            lines.append(profile_set("chalk_max", "DATETIME", "false"))
        if is_true(d, "chalk_embeds"):
            lines.append(profile_set("chalk_max", "EMBEDDED_CHALK", "false"))
        if is_true(d, "chalk_repo"):
            lines.append(profile_set("chalk_max", "ORIGIN_URI", "false"))
            lines.append(profile_set("chalk_max", "BRANCH", "false"))
            lines.append(profile_set("chalk_max", "COMMIT_ID", "false"))
        if is_true(d, "chalk_rand"):
            lines.append(profile_set("chalk_max", "CHALK_RAND", "false"))
        if is_true(d, "chalk_build_env"):
            lines.append(profile_set("chalk_max", "INSERTION_HOSTINFO", "false"))
            lines.append(profile_set("chalk_max", "INSERTION_NODENAME", "false"))
        # if is_true(d, "chalk_sig"):
        #    lines.append(profile_set('chalk_max', 'SIGNATURE', 'false'))
        #    lines.append(profile_set('chalk_max', 'SIGN_PARAMS', 'false'))
        if is_true(d, "chalk_sbom"):
            lines.append(profile_set("chalk_max", "SBOM", "false"))
        else:
            enable_sbom = True
        if is_true(d, "chalk_sast"):
            lines.append(profile_set("chalk_max", "SAST", "false"))
        else:
            enable_sast = True
    if is_true(d, "chalk_virtual"):
        lines.append("virtual_chalk = true")
        lines.append('subscribe("virtual", "virtual_chalk_log")')
    if is_true(d, "label_cid"):
        lines.append(profile_set("labels", "CHALK_ID", "true"))
    if is_true(d, "label_mdid"):
        lines.append(profile_set("labels", "METADATA_ID", "true"))
    if not is_true(d, "label_repo"):
        lines.append(profile_set("labels", "ORIGIN_URI", "false"))
    if not is_true(d, "label_commit"):
        lines.append(profile_set("labels", "COMMIT_ID", "false"))
    if not is_true(d, "label_branch"):
        lines.append(profile_set("labels", "BRANCH", "false"))

    lines.append('docker.label_prefix = "' + d["label_prefix"] + '"')

    if is_true(d, "crpt_minimal"):
        lines.append(profile_set("chalk_host", "CHALK_RAND", "false"))
        lines.append(profile_set("chalk_host", "_ACTION_ID", "false"))
        lines.append(profile_set("chalk_host", "_UNMARKED", "false"))
        lines.append(profile_set("chalk_art", "TIMESTAMP", "false"))
        lines.append(profile_set("chalk_art", "HASH_FILES", "false"))
        lines.append(profile_set("chalk_art", "COMPONENT_HASHES", "false"))
        lines.append(profile_set("chalk_art", "BUILD_ID", "false"))
        lines.append(profile_set("chalk_art", "BUILD_URI", "false"))
        lines.append(profile_set("chalk_art", "BUILD_API_URI", "false"))
        lines.append(profile_set("chalk_art", "BUILD_TRIGGER", "false"))
        lines.append(profile_set("chalk_art", "BUILD_CONTACT", "false"))
        lines.append(profile_set("chalk_art", "CHALK_RAND", "false"))
        lines.append(profile_set("chalk_art", "OLD_CHALK_METADATA_HASH", "false"))
        lines.append(profile_set("chalk_art", "OLD_CHALK_METADATA_ID", "false"))
        lines.append(profile_set("chalk_art", "_VIRTUAL", "false"))

        if not is_true(d, "crpt_errs"):
            lines.append(profile_set("chalk_host", "_OP_ERRORS", "false"))
            lines.append(profile_set("chalk_art", "ERR_INFO", "false"))
        if not is_true(d, "crpt_embed"):
            lines.append(profile_set("chalk_art", "EMBEDDED_CHALK", "false"))
        if not is_true(d, "crpt_host"):
            lines.append(profile_set("chalk_host", "INSERTION_HOSTINFO", "false"))
            lines.append(profile_set("chalk_host", "INSERTION_NODENAME", "false"))
        if is_true(d, "crpt_env"):
            lines.append(profile_set("chalk_host", "ENV", "true"))
        if not is_true(d, "crpt_sig"):
            lines.append(profile_set("chalk_art", "SIGN_PARAMS", "false"))
            lines.append(profile_set("chalk_art", "SIGNATURE", "false"))
        if is_true(d, "crpt_sast"):
            lines.append(profile_set("chalk_host", "SAST", "false"))
            lines.append(profile_set("chalk_art", "SAST", "false"))
        else:
            enable_sast = True
        if is_true(d, "crpt_sbom"):
            lines.append(profile_set("chalk_host", "SBOM", "false"))
            lines.append(profile_set("chalk_art", "SBOM", "false"))
        else:
            enable_sbom = True
    else:
        if is_true(d, "crpt_errs"):
            lines.append(profile_set("chalk_host", "_OP_ERRORS", "false"))
            lines.append(profile_set("chalk_art", "ERR_INFO", "false"))
        if is_true(d, "crpt_embed"):
            lines.append(profile_set("chalk_art", "EMBEDDED_CHALK", "false"))
        if is_true(d, "crpt_host"):
            lines.append(profile_set("chalk_host", "INSERTION_HOSTINFO", "false"))
            lines.append(profile_set("chalk_host", "INSERTION_NODENAME", "false"))
        if not is_true(d, "crpt_env"):
            lines.append(profile_set("chalk_host", "ENV", "true"))
        if not is_true(d, "crpt_sig"):
            lines.append(profile_set("chalk_art", "SIGN_PARAMS", "false"))
            lines.append(profile_set("chalk_art", "SIGNATURE", "false"))
        if not is_true(d, "crpt_sast"):
            lines.append(profile_set("chalk_host", "SAST", "false"))
            lines.append(profile_set("chalk_art", "SAST", "false"))
        else:
            enable_sast = True
        if not is_true(d, "crpt_sbom"):
            lines.append(profile_set("chalk_host", "SBOM", "false"))
            lines.append(profile_set("chalk_art", "SBOM", "false"))
        else:
            enable_sbom = True

    if is_true(d, "drpt_labels"):
        lines.append(profile_set("chalk_art", "DOCKER_LABELS", "true"))
        lines.append(profile_set("chalk_host", "DOCKER_LABELS", "true"))
    else:
        lines.append(profile_set("chalk_art", "DOCKER_LABELS", "false"))
        lines.append(profile_set("chalk_host", "DOCKER_LABELS", "false"))
    if is_true(d, "drpt_tags"):
        lines.append(profile_set("chalk_art", "DOCKER_TAGS", "true"))
        lines.append(profile_set("chalk_host", "DOCKER_TAGS", "true"))
    else:
        lines.append(profile_set("chalk_art", "DOCKER_TAGS", "false"))
        lines.append(profile_set("chalk_host", "DOCKER_TAGS", "false"))
    if is_true(d, "drpt_dfile"):
        lines.append(profile_set("chalk_art", "DOCKER_FILE", "true"))
        lines.append(profile_set("chalk_host", "DOCKER_FILE", "true"))
    else:
        lines.append(profile_set("chalk_art", "DOCKER_FILE", "false"))
        lines.append(profile_set("chalk_host", "DOCKER_FILE", "false"))
    if is_true(d, "drpt_dfpath"):
        lines.append(profile_set("chalk_art", "DOCKERFILE_PATH", "true"))
        lines.append(profile_set("chalk_host", "DOCKERFILE_PATH", "true"))
    else:
        lines.append(profile_set("chalk_art", "DOCKERFILE_PATH", "false"))
        lines.append(profile_set("chalk_host", "DOCKERFILE_PATH", "false"))
    if is_true(d, "drpt_platform"):
        lines.append(profile_set("chalk_art", "DOCKER_PLATFORM", "true"))
        lines.append(profile_set("chalk_host", "DOCKER_PLATFORM", "true"))
    else:
        lines.append(profile_set("chalk_art", "DOCKER_PLATFORM", "false"))
        lines.append(profile_set("chalk_host", "DOCKER_PLATFORM", "false"))
    if is_true(d, "drpt_cmd"):
        lines.append(profile_set("chalk_host", "ARGV", "true"))
    else:
        lines.append(profile_set("chalk_host", "ARGV", "false"))
    if is_true(d, "drpt_ctx"):
        lines.append(profile_set("chalk_art", "DOCKER_CONTEXT", "true"))
        lines.append(profile_set("chalk_host", "DOCKER_CONTEXT", "true"))
    else:
        lines.append(profile_set("chalk_art", "DOCKER_CONTEXT", "false"))
        lines.append(profile_set("chalk_host", "DOCKER_CONTEXT", "false"))
    if is_true(d, "xrpt_fullmark"):
        x_rept_host = "x_min_host"
        x_rept_art = "x_min_art"
    else:
        x_rept_host = "x_max_host"
        x_rept_art = "x_max_art"

    lines.append(
        'outconf.extract.artifact_report = "%s"' % profile_name_map[x_rept_art]
    )
    lines.append(
        'outconf.extract.host_report     = "%s"' % profile_name_map[x_rept_host]
    )

    if not is_true(d, "xrpt_env"):
        lines.append(profile_set(x_rept_host, "_OP_CHALKER_COMMIT_ID", "false"))
        lines.append(profile_set(x_rept_host, "_OP_CHALKER_VERSION", "false"))
        lines.append(profile_set(x_rept_host, "_OP_PLATFORM", "false"))
        lines.append(profile_set(x_rept_host, "_OP_HOSTINFO", "false"))
        lines.append(profile_set(x_rept_host, "_OP_NODENAME", "false"))
        lines.append(profile_set(x_rept_art, "_OP_CHALKER_COMMIT_ID", "false"))
        lines.append(profile_set(x_rept_art, "_OP_CHALKER_VERSION", "false"))
        lines.append(profile_set(x_rept_art, "_OP_PLATFORM", "false"))
        lines.append(profile_set(x_rept_art, "_OP_HOSTINFO", "false"))
        lines.append(profile_set(x_rept_art, "_OP_NODENAME", "false"))

    if is_true(d, "xrpt_containers"):
        pass  # not implemented yet.

    # Turn on sbom / sast if need be.
    if enable_sast:
        lines.append("# Turn on running Semgrep")
        lines.append("run_sast_tools = true")
    if enable_sbom:
        lines.append("# Turn on running SBOM tools")
        lines.append("run_sbom_tools = true")

    return "\n".join(lines)
