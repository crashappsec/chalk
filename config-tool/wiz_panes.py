from textual.app     import *
from textual.containers import *
from textual.coordinate import *
from textual.widgets import *
from textual.screen import *
from localized_text import *
from rich.markdown import *
from textual.widgets import Markdown as MDown
from pathlib import *
import sqlite3, os, urllib, tempfile, datetime, hashlib, subprocess, json, stat
from wizard import *
from conf_options import *
from conf_widgets import *

def deal_with_overwrite_widget():
    switch_row        = get_wizard().query_one("#switch_row")
    config_name_field = get_wizard().query_one("#conf_name")

    show_switch = False
    
    v = config_name_field.value.strip()
    if v != "":
        arr = cursor.execute("SELECT id from configs where name=?",
                             [v]).fetchone()
        if arr != None:
            old_id = arr[0]
            new_id = dict_to_id(json_to_dict(config_to_json()))

            if old_id != new_id:
                show_switch = True
        
    if show_switch:
        switch_row.visible = True
    else:
        switch_row.visible = False
        get_wizard().query_one("#overwrite_config").value = False
        
class BuildBinary(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""# Output a Configured Binary
Do you want a release build?""")
        yield RadioSet(RadioButton("Yes", True, id="release_build"),
                       RadioButton("No, give me a debug build", id="debug_build"))
        yield Horizontal(Input(placeholder="exe name", id = "exe_name"),
                         Label("Binary name (will output here)", classes="label"))
        yield Horizontal(Input(placeholder="configuration name",
                               id = "conf_name"),
                         Label("Configuration Name",
                               classes="label"))
        yield Horizontal(Switch(id="overwrite_config", value=False),
                         Label("Overwrite saved configuration",
                               classes="label"), id = "switch_row")
        
        yield MDown("### Build comment", id="note_label")
        yield Input(placeholder="Enter note (optional)", id="note")

    def on_mount(self):
        deal_with_overwrite_widget()
        
    def on_descendant_blur(self, event):
        deal_with_overwrite_widget()

    def enter_step(self):
        self.has_entered = True
        deal_with_overwrite_widget()
                            
    def validate_inputs(self):
        binname = get_wizard().query_one("#exe_name").value.strip()
        confname = get_wizard().query_one("#conf_name").value.strip()
        
        if binname == "":
            return "Binary name is required."
        if confname == "":
            return "The configuration name is required."
    
    def doc(self):
        return """# Finishing Up

It's time to save your config (in our local SQLite database), and output your custom chalk binary.

If you want to re-create the binary later, you can re-do the wizard (loading this config); select "overwrite", without changing anything else.   We probably will eventually allow this from the main screen.

If you do make configuration changes, you can easily turn it into a second configuration by changing the name to something unique.

The "Build comment" field is just for your own documentation when using this tool.
"""
        
class ChalkOpts(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
# Chalk Mark Config
When we add chalk marks to software, what kinds of information do you want to put into the software itself?
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
            #EnablingCheckbox("sigmenu", "A digitial signature -- coming soon",
            #                 id="chalk_sig", disabled=True),
            Checkbox("Semgrep scan results -- This can get large",
                     id="chalk_sast"),
            Checkbox("SBOM -- a 'Software Bill Of Materials'.  " +
                     "This can get large", id="chalk_sbom"),
            Checkbox("Actually, don't put them in the artifact, " +
                     "write to a file", id="chalk_virtual")
        )

    def doc(self):
        return """
# Chalking basics
Chalk marks are, by default, stored as JSON in benign part of artifacts.  That makes them easy to find when needed.

 The JSON will always appear on a single line, and will start with: `{"MAGIC" : "dadfedabbadabbed",`.  That makes it easy to extract marks in binaries with:
```bash
strings mybinary | grep dadfedabbadabbed
```

The mark always is JSON, but might be embedded differently depending on the file type. For instance, in Unix scripts (i.e., starting with `#!`), it will generally be embedded in a comment starting with '#'.

## What to Chalk
Generally, you can put any metadata you want in the chalk mark. Most metadata we collect will be small, though SBOMs and SAST tool results could be large.  You can go minimal, and only put in identifying information, and then send the rest of the metadata you're interested in from the build environment somewhere else.  The identifying info will get reported, AND go into the mark, so you can easily tie things together.

Some of the identifiers of note:

- `CHALK_ID` is unique per code artifact, calculated whenever possible from the hash of the UNCHALKED artifact.  That hash will generally be available as `ARTIFACT_HASH`.
- `METADATA_HASH` is essentially a hash of the metadata that actually got inserted into the chalk mark.

- `METADATA_ID` is a more readable version derived from the metadata hash value.

If you do not want to add chalk marks directly to an artifact, you don't have to.  The chalk mark still gets produced.  With binaries configured via this Wizard, they currently will get dropped in a file named *virtual.json*.

However, we recommend only using these for dry runs, as keeping track of the marks becomes far more error prone.

"""

class DockerChalking(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""
# Docker Auto-Labeling
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
        
    def doc(self):
        return """# The metadata Chalk reports on can be automatically added to docker labels to your image when you run *'chalk docker build ...'*

The OCI standard for labels requires them to start with reverse-DNS entries.  The value you provide will be added to the label name, with a suffix consisting of a value derived from the metadata key, adhering to OSI name standards.  

For instance, by default, the label for the Chalk ID would be: 
```
run.crashoverride.chalk-id
```

If your container build uses Docker features unsupported by chalk, the labels will *NOT* get added.  Chalk falls back on running docker as-is, without reporting, if it cannot completely comprehend the semantics of the build.

Specifically, Chalk currently doesn't yet support remote build contexts.
"""

class ReportingOptsChalkTime(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""# Post-Chalking Report Contents

In the report we generate after a chalk mark is written, what kind of information do you want?

Note that things listed as 'coming soon' can be configured manually, but are not yet in this user interface.
""")
        yield RadioSet(RadioButton("Key build-time information, plus:", id="crpt_minimal"),
                       RadioButton("Everything, except: ", id="crpt_maximal"))
        yield ReportingContainer(
            Checkbox("Info on any significant errors found during chalking", id="crpt_errs"),
            Checkbox("Info about embedded executable content (e.g., scripts in Zip files)", id="crpt_embed"),
            Checkbox("Information about the build host", id="crpt_host"),
            EnablingCheckbox("redaction", "Build-time environment vars (redaction options on next screen if selected) -- coming soon", disabled=True, id="crpt_env"),
            EnablingCheckbox("sig", "A digitial signature -- coming soon", disabled=True, id="crpt_sig"),

            Checkbox("Semgrep scan results -- Can impact build speeds", id="crpt_sast"),
            Checkbox("SBOM -- a 'Software Bill Of Materials'. Significant build speed impact is typical.", id="crpt_sbom")
        )
    def doc(self):
        return """
# Post-Chalking Report info
All the stuff on this screen is what gets put in the report generated after chalking. This is different from what actually goes into the chalk mark.


### RE: "coming soon"
Note that things listed as 'coming soon' can be configured manually, but are not yet working through this wizard.
"""

class ReportingOptsDocker(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""# Additional Chalk report configuration for Docker

When chalking Docker containers, what Docker-specific info would you like reported back at chalk time?""")
        yield ReportingContainer(
            Checkbox("Any labels added during the build (minus ones added automatically via Chalk", id="drpt_labels"),
            Checkbox("Any tags added during the build", id="drpt_tags"),
            Checkbox("The Dockerfile used to build the container", id="drpt_dfile"),
            Checkbox("The path to the Dockerfile on the build system", id="drpt_dfpath"),
            Checkbox("The platform passed to [grey bold]docker build[/]", id="drpt_platform"),
            Checkbox("The full command-line arguments", id="drpt_cmd"),
            Checkbox("The docker context used during the build", id="drpt_ctx")
        )
    def doc(self):
        return """
# Additional Reporting when chalking Docker containers
When Chalk monitors the 'docker build' command (via 'chalk docker build...'), it can report on other docker-specific information.

Note that container images only get chalked via this path; 'chalk insert' does not chalk docker images.
"""

class ReportingExtraction(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown("""# Extraction Reporting

If running chalk to extract marks from software, what do you want to report, beyond basic identifying information?
""")
        yield ReportingContainer(
            Checkbox("Information about the operating environment", id="xrpt_env"),
            Checkbox("Automatically report on any running containers seen locally (coming soon)", disabled=True, id="xrpt_containers"),
            Checkbox("All data found in the chalk mark", id="xrpt_fullmark")
        )
    def doc(self):
        return """ # Extraction-time Reporting
When you run 'chalk extract', Chalk will generate a report that can include:
1. Data about the extraction.
2. Data about the operating environment at the time extraction ran.
3. Data about artifacts at the time of extraction (e.g., their current hash, and where they live on the file system).

By default, we only report back basic identification information and runtime information; we assume you already stashed the full mark.  

If you want to selectively report some fields, that's outside the scope of this wizard, and requires a custom configuration.
"""

class LogParams(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield MDown(LOG_PARAMS)
        yield Horizontal(Label("Log file location: ", classes="label"),
                         Input(placeholder="/path/to/log/file",
                               id = "log_loc"))
        yield Horizontal(Switch(id="log_truncate"),
                         Static("Enforce max size", classes="label"))

class CustomEnv(WizContainer):
    # CHALK_POST_URL, CHALK_POST_HEADERS
    # AWS_S3_BUCKET_URI, AWS_ACCESS_SECRET, AWS_ACCESS_ID
    # CHALK_LOG

    def compose(self):
        self.has_entered = False
        yield Container(
            MDown("""
# Environment Variable Configuration"""),
            Horizontal(
                Input(placeholder="Enter name or leave blank to disallow",
                      id = "env_log"),
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
    def doc(self):
        return """# Custom Environment Variables
This tool generates a config file that consults environment variables for configuring output to various places like HTTPS endpoints or S3 buckets.  Generally, if the required environment variables are present, then Chalk will use them to set up an output.  

That output might be instead of the default configuration for that output type... that behavior is set on the previous screen.

Here, you can rename the environment variables we use in this logic.  If you don't ever want to allow a certain output type, then leave the appropriate field blank.

Though, that would be silly, really.
"""

class HttpParams(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield MDown(HTTPS_PARAMS)
        yield Grid(Label("URL for POST: ", classes="label"),
                         Label("https://", classes="label emphLabel"),
                         Input(placeholder="Enter url",
                               id = "https_url",
                               value = text_defaults["https_url"]),
                         Label("Extra MIME header: ", classes="label"),
                         Label(""),
                         Input(id = "https_header")
            )
    def validate_inputs(self):
        print("Validate from https")        
        field = get_wizard().query_one("#https_url")
        url = field.value
        http_start = "http://"
        https_start = "https://"
        
        if url.startswith(http_start):
            return "HTTP URLs not supported; only HTTPS"

        if url.startswith(https_start):
            field.value = field.value[len(https_start):]
            
        if not "." in url:
            return "You must provide a valid URL."

        return None
        
    def doc(self):
        return """# About Chalk's use of HTTPS POST
Important things to note about https output:
1. Chalk currently *requires* HTTPS, not HTTP
2. Chalk currently *requires* certificate validation.  
3. Chalk will always just post the JSON blob containing its report as a document of ```Content-Type: application/json```
4. The additional MIME header is strictly optional.  It may be necessary for authentication.  

We might relax the first things real soon now, if you sign a waiver allowing you to shoot yourself in the foot :)

For the additional MIME header, If you need the value to be dynamic, or need more than one header, then you'll have to manually edit your configuration file.  You can always put in a placeholder, generate the con4m output file from the Export menu, and then only edit that one piece of it.
"""

class S3Params(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield MDown("# S3 output configuration parameters")
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

    def validate_inputs(self):
        f1 = get_wizard().query_one("#s3_uri").value.strip()
        f2 = get_wizard().query_one("#s3_access_id").value.strip()
        f3 = get_wizard().query_one("#s3_secret").value.strip()
        s3_start = "s3://"

        if f1.startswith(s3_start):
            get_wizard().query_one("#s3_uri").value = f1[len(s3_start):]
            
        if f1 == "" or f2 == "" or f3 == "":
            return "All fields must be provided."

    def doc(self):
        return """# S3 Output configuration
Important things to note about our S3 output sink:

1. It only accepts S3 bucket urls in the s3:// format.
2. S3 bucket names SHOULD NOT contain dots.  Use dashes where you'd naturally go for dots.  If you use dashes, we do proper validation of the TLS connection to Amazon.  If you use dots, then we cannot, because Amazon's wildcard cert doesn't support it (this is a fundamental issue with all wildcard certs).
"""

class ReportingPane(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown(REPORTING_PANE_MAIN)
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
    def doc(self):
        return """
# Output Reporting

These reports are always run after Chalk is invoked. If artifacts have been marked, key data from the chalk mark will get reported, potentially along with other info that wasn't put into the mark.  You can select what goes into reports and what goes into the chalk marks later in the wizard.

## Note
There are things you cannot do through this Wizard, such as having each output configuration get different data sent to it.

This Wizard is only designed to handle the most common cases.  If you need more flexibility, you should consider writing a configuration file directly, instead of generating one.

For documentation on that, please see our web page.
"""
class UsagePane(WizContainer):
    def enter_step(self):
        self.has_entered = True
    def compose(self):
        yield MDown(BASICS_PANE_MAIN)
        yield RadioSet(RadioButton(BASICS_PANE_CMDLINE, value=True,
                                   id="use_cmd"),
                       RadioButton(BASICS_PANE_DOCKER, id="use_docker"),
                       RadioButton(BASICS_PANE_OTHER, id="use_cicd"),
                       RadioButton("In production, as a chalk mark scanner",
                                   id="use_extract"))
        # yield Container(Label("""What platform are we configuring the binary for?"""),
        #                 RadioSet(RadioButton("Linux (x86-64 only)", True, id="lx86"),
        #                          RadioButton("OS X (M1 family)", id="m1"),
        #                          RadioButton("OS X (x86)", id="macosx86")))


    def complete(self):
        try:
            return self.has_entered
        except:
            self.has_entered = False
            return False
    def doc(self):
        return """# Usage

If you're not using it as a command-line tool, we will set the default command so that no command need be provided on the command line by default.

For instance, if running as a docker wrapper, this allows you to alias docker to the chalk binary.
"""
    
sectionBasics     = WizardSection("Basics")
sectionOutputConf = WizardSection("Output Config")
sectionChalking   = WizardSection("Chalking")
sectionReporting  = WizardSection("Reporting")
sectionBinGen     = WizardSection("Finish")

sectionBasics.add_step("basics", UsagePane())
sectionOutputConf.add_step("reporting", ReportingPane())
sectionOutputConf.add_step("envconf", CustomEnv(disabled=True))
sectionOutputConf.add_step("log_conf", LogParams(disabled=True))
sectionOutputConf.add_step("http_conf", HttpParams(disabled=True))
sectionOutputConf.add_step("s3_conf", S3Params(disabled=True))
sectionChalking.add_step("chalking_base", ChalkOpts())
sectionReporting.add_step("reporting_base", ReportingOptsChalkTime())
sectionReporting.add_step("reporting_docker", ReportingOptsDocker())
sectionChalking.add_step("chalking_docker", DockerChalking())
sectionReporting.add_step("reporting_extract", ReportingExtraction())
sectionBinGen.add_step("final", BuildBinary())

