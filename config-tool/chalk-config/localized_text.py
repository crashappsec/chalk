CHALK_VERSION = "0.4.3"
CHALK_TITLE = "Chalk v." + CHALK_VERSION + " Configuration Tool"

# Screen titless (used on modals / sub-screens)
LOGIN_TITLE   = "Login to, or Register, your Crash Override API" 
QR_CODE_TITLE = "# Scan the QR code to login via your mobile device"

# Action labels (used for buttons and bindings)
NEW_LABEL     = "New Config"
EDIT_LABEL    = "Edit"
EXPORT_LABEL  = "Export"
DELETE_LABEL  = "Delete"
BEGIN_LABEL   = "Begin!"
ABORT_LABEL   = "Nope, sorry."
CANCEL_LABEL  = "Cancel"
YES_LABEL     = "Yes"
NO_LABEL      = "No"
JSON_LABEL    = "JSON"
KEYPRESS_QUIT = "Quit install"
KEYPRESS_GO   = "Begin install"
CON4M_LABEL   = "Con4m"
DISMISS_LABEL = "Dismiss"
RELEASE_BUILD = YES_LABEL
DEBUG_BUILD   = "No, give me a debug build"
MAIN_MENU     = "Main Menu"
PREV_LABEL    = "Previous Screen"
NEXT_LABEL    = "Next Screen"
HELP_TOGGLE   = "Toggle Help"
QUIT_LABEL    = "Quit"
CHEEKY_OK     = "Got it."
LOGIN_LABEL   = "Login to Crash ⍉verride"
QR_LABEL      = "Show QR Code"
BACK_LABEL    = "Go Back"
LOGIN_SUCCESS = "# Authentication Successful\n"
PROFILE_LABEL = "# User Profile\n"
AUTHN_LABEL   = "Authenticate"

# Wizard sidebar labels

SB_BASICS     = "Basics"
SB_OUTPUT     = "Output Config"
SB_CHALK      = "Chalking"
SB_REPORT     = "Reporting"
SB_FINISH     = "Finish"

# Labels to go with Input widgets and switches.
L_BIN_NAME    = "Binary name (will output here)"
L_CONF_NAME   = "Configuration Name"
L_OVERWRITE   = "Overwrite saved configuration"
L_NOTE        = "Build comment"
L_LPREFIX     = "The label prefix to use"
L_LOG_LOC     = "Log file location: "
L_LOG_SIZE    = "Enforce max size"
L_ENV_LOG     = "Log file path"
L_ENV_POST    = "HTTPS POST url"
L_ENV_MIME    = "HTTPS extra MIME headers"
L_ENV_S3_URI  = "S3 Bucket uri (must be an s3 URL)"
L_ENV_S3_SEC  = "S3 AWS access secret"
L_ENV_S3_ID   = "S3 AWS access ID"
L_POST_URL    = "URL for POST: "
L_POST_HTTPS  = "https://"
L_POST_MIME   = "Extra MIME header: "
L_S3_URI      = "AWS Bucket Path"
L_S3_SEC      = "AWS Secret"
L_S3_AID      = "AWS Access ID"
L_ADD_REPORT  = "Env vars create additional report"
L_CUSTOM_ENV  = "Customize environment variables?"
L_NEW_CONF    = "New configuration (not yet saved)"
L_MODIFIED    = "Existing config modified (needs saving)"
L_UNMODIFIED  = "Configuration unchanged"
L_NO_NAME     = "Unsaved (config name required)"
L_C0API_USE   = "Make use of Crash Override API and services"

# Placeholder text in Input widgets.
PLACEHOLD_FILE    = "Enter file name"
PLACEHOLD_OUTFILE = "Output file name"
PLACEHOLD_EXE     = "Executable name"
PLACEHOLD_CONF    = "Configuration name"
PLACEHOLD_NOTE    = "Enter note (optional)"
PLACEHOLD_LPREFIX = "Enter label prefix"
PLACEHOLD_ENV     = "Enter name or leave blank to disallow"
PLACEHOLD_URL     = "Enter url"
PLACEHOLD_MIME    = "Optional"
PLACEHOLD_S3_URI  = "Enter bucket path"
PLACEHOLD_S3_SEC  = "Enter AWS secret"
PLACEHOLD_S3_AID  = "Enter AWS Access ID"

# Radio Button labels
R_CMIN = "Basic Chalk IDing info, plus:"
R_CMAX = "Everything, except: "

R_RMIN = "Key build-time information, plus:"
R_RMAX = "Everything, except: "

R_UCMD     = "On the command line"
R_UDOCKER  = "In CI/CD, wrapping the docker command"
R_UCICD    = "In CI/CD, after building stand-alone artifacts"
R_UEXTRACT = "In production, as a chalk mark scanner"

# Checkbox text
CO_CRASH   = "Send it to Crash Override (coming soon)"
CO_STDOUT  = "Output to stdout"
CO_STDERR  = "Output to stderr"
CO_LOG     = "Output to a log file"
CO_POST    = "Output to an https URL"
CO_S3      = "Output to an S3 bucket"

CC_URL     = "URL for where reporting goes"
CC_DATE    = "Date/time of marking"
CC_EMBED   = "Info about embedded content (e.g., scripts in Zip files)"
CC_REPO    = "Discovered source repository information"
CC_RAND    = "A random value for unique builds"
CC_HOST    = "Information about the build host"
CC_SIG     = "A digitial signature -- coming soon"
CC_SAST    = "Semgrep scan results (sometimes large)"
CC_SBOM    = "SBOM -- a 'Software Bill Of Materials' (often large)"
CC_VIRTUAL = "Actually, don't put them in the artifact, write to a file"

CL_CID     = "Label the Chalk ID (unique identifier for pre-chalk software)"
CL_MID     = "Label the Metadata ID (identifies the post-chalk software)"
CL_REPO    = "Label the source repository URI found at build"
CL_COMMIT  = "Label the commit ID found at build"
CL_BRANCH  = "Label the branch found at build"

CR_ERRS    = "Info on any significant errors found during chalking"
CR_EMBED   = "Info about embedded executable content (e.g., scripts in Zip files)"
CR_BUILD   = "Information about the build host"
CR_REDACT  = "Build-time environment vars (redaction options on next screen if selected) -- coming soon"
CR_SIGN    = "A digitial signature -- coming soon"
CR_SAST    = "Semgrep scan results -- Can impact build speeds"
CR_SBOM    = "SBOM / 'Software Bill Of Materials' (significant build speed impact typical)"

CD_LABELS  = "Any labels added during the build (minus ones added automatically via Chalk"
CD_TAGS    = "Any tags added during the build"
CD_FILE    = "The Dockerfile used to build the container"
CD_PATH    = "The path to the Dockerfile on the build system"
CD_PLAT    = "The platform passed to [grey bold]docker build[/]"
CD_ARGS    = "The full command-line arguments"
CD_CTX     = "The docker context used during the build"

CX_ENV     = "Information about the operating environment"
CX_CONTAIN = "Automatically report on any running containers seen locally (coming soon)"
CX_MARK    = "All data found in the chalk mark"

# Columns for the configuration table
COL_NAME = "Configuration Name"
COL_DATE = "Modification Time"
COL_VERS = "Chalk Version"
COL_NOTE = "Description / note"

# Validation errors for app panes.
E_BNAME = "A name for the binary name is required."
E_CNAME = "The configuration name is required."

# Text for basic modal prompts.  These use Markdown, and %s for any subs.
# For title, errors use h2 (which we make red for markdown).  Others use h1.
CONFIRM_DELETE = "Really delete '%s' ?"
ACK_EXPORT     = """ # Success!

Configuration saved to: %s"""

ACK_DELETE     = """# Success!

Configuration '%s' has been deleted.

Note that this does NOT remove any binaries generated for this configuration.
"""

GENERATION_FAILED =  """# Warning: Binary Generation Failed
Your configuration has been saved, but no binary has been produced.

Generally, this is one of two issues:
1. Connectivity to the base binary (currently, it should go in ./bin/chalk)
2. You're running on a Mac; we only inject on Linux.  Export the con4m config from the main menu, and on a Linux machine run:
```
chalk load [yourconfig]
```
"""

GENERATION_EXCEPTION = """## Error

Binary generation failed with the following message:
```
%s
```

Your configuration has been saved, but no binary was produced.
"""
GENERATION_OK = """# Success!

The configuration has been saved, and your binary written to:
```
%s
```
"""

# Wizard uses this for prepending to validation errors.
ERR_HDR = "## Error\n\n"

# These are error messages returned from validation.
ERR_HTTP         = "HTTP URLs not supported; only HTTPS"
ERR_NO_URL       = "You must provide a valid URL."
ERR_ALL_REQUIRED = "All fields are required."
ERR_EXISTS       = """
Configuration '%s' already exists. Please rename, or select the option to replace the existing configuration.
"""
ERR_DUPE         = """
Did not create the configuration, because the configuration named '%s'
is an identical configuration.
"""


# These are all mark-down blocks for window intros.
CHALK_OPTS_INTRO = """
# Chalk Mark Config
When we add chalk marks to software, what kinds of information do you want to put into the software itself?
"""

CUSTOM_ENV_INTRO = """# Environment Variable Naming
"""

LOG_PARAMS_INTRO = """# Log File Configuration

The path to the file must already exist on any machine on which this runs, and the file must be writable."""

HTTPS_PARAMS_INTRO = """# HTTPS Post Config
Data gets sent with the following header:
```
Content-Type: application/json
```

If you need to add a custom MIME header to the POST (e.g., for authentication), please do so below, exactly as it should appear.  Eg:
```
X-My-Auth-Id: WRGFsdf-sdfasdf-SDFkdj
```
"""

S3_PARAMS_INTRO = "# S3 output configuration parameters"

REPORTING_PANE_INTRO= """# Report Output Configurations

When Chalk finishes running, where should output get sent by default? (Select all that apply)
"""

REPORTING_ENV_INTRO = """

Note that you can use environment variables to configure output sinks as well.  Environment variables can be used to re-configure the defaults, or to add additional reporting.

You can also customize the names of environment variables. If you choose to do that, you will do so on the next screen.
"""

DOCKER_REPORTING_INTRO = """# Additional Chalk reporting for Docker

When chalking Docker containers, what Docker-specific info would you like reported back at chalk time?"""

DOCKER_LABEL_INTRO = """
# Docker Auto-Labeling
When chalking Docker containers, it's best to wrap every call to Docker, but it's important to wrap **docker build** and **docker push** to make it easy to track containers you create.

When running in Docker mode, there are some things we currently cannot chalk (we ignore them), such as remote contexts and images built via **docker compose**.

We also can automatically label containers as we chalk them. You can configure your label setup here.
"""

REPORTING_INTRO = """# Post-Chalking Report Contents

In the report we generate after a chalk mark is written, what kind of information do you want?

Note that things listed as 'coming soon' can be configured manually, but are not yet in this user interface.
"""

EXTRACT_INTRO = """# Extraction Reporting

If running chalk to extract marks from software, what do you want to report, beyond basic identifying information?
"""

BUILD_BIN_INTRO = """# Output a Configured Binary
Do you want a release build?
"""

EXPORT_MENU_INTRO = """
# Export Configuration

Export your configuration to share or back it up, if you like. Note
that, for backups, you may consider copying the SQLite database, which lives in
`~/.config/chalk/chalk-config.db`.

JSON is only read and written by this configuration tool (though currently, we have not yet added a feature to directly import this).  **Con4m** is Chalk's native configuration file, and can do far more than this configuration tool does.  However, this tool cannot import Chalk.  Similarly, Chalk does not import this tool's JSON files.

If you do not provide an extension below, we use the default (.json or .c4m depending on the type).
"""

USAGE_INTRO = """# Setting The Default Command

How are you primarily intending to use this Chalk binary?
(See 'Help' below for more details).
"""

# Help strings.
YOU_ARE_NO_HELP = "# Sorry!\nThere's no help for this step."

CHALK_OPT_DOC = """
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

OUT_DOC = """
# Output Reporting

These reports are always run after Chalk is invoked. If artifacts have been marked, key data from the chalk mark will get reported, potentially along with other info that wasn't put into the mark.  You can select what goes into reports and what goes into the chalk marks later in the wizard.

## Note
There are things you cannot do through this Wizard, such as having each output configuration get different data sent to it.

This Wizard is only designed to handle the most common cases.  If you need more flexibility, you should consider writing a configuration file directly, instead of generating one.

For documentation on that, please see our web page.
"""

LOG_DOC = """
The max-size option is currently not configurable through this wizard, only a con4m config.  If a write would exceed 10MB, then it removes the oldest 25% of entries.

Without this option, you're responsible for dealing with disk space issues.
"""

API_DOC = "### Crash Override's API Configuration\n The Crash Override API adds features and long term data storage to your Chalking experience ...."

ENV_DOC =  """# Custom Environment Variables
This tool generates a config file that consults environment variables for configuring output to various places like HTTPS endpoints or S3 buckets.  Generally, if the required environment variables are present, then Chalk will use them to set up an output.

That output might be instead of the default configuration for that output type... that behavior is set on the previous screen.

Here, you can rename the environment variables we use in this logic.  If you don't ever want to allow a certain output type, then leave the appropriate field blank.

Though, that would be silly, really.
"""

HTTP_PARAMS_DOC = """# About Chalk's use of HTTPS POST
Important things to note about https output:
1. Chalk currently *requires* HTTPS, not HTTP
2. Chalk currently *requires* certificate validation.
3. Chalk will always just post the JSON blob containing its report as a document of ```Content-Type: application/json```
4. The additional MIME header is strictly optional.  It may be necessary for authentication.

We might relax the first things real soon now, if you sign a waiver allowing you to shoot yourself in the foot :)

For the additional MIME header, If you need the value to be dynamic, or need more than one header, then you'll have to manually edit your configuration file.  You can always put in a placeholder, generate the con4m output file from the Export menu, and then only edit that one piece of it.
"""

S3_PARAMS_DOC = """# S3 Output configuration
Important things to note about our S3 output sink:

1. It only accepts S3 bucket urls in the s3:// format.
2. S3 bucket names SHOULD NOT contain dots.  Use dashes where you'd naturally go for dots.  If you use dashes, we do proper validation of the TLS connection to Amazon.  If you use dots, then we cannot, because Amazon's wildcard cert doesn't support it (this is a fundamental issue with all wildcard certs).
"""

CHALK_REPORT_DOC = """
# Post-Chalking Report info
All the stuff on this screen is what gets put in the report generated after chalking. This is different from what actually goes into the chalk mark.


### RE: "coming soon"
Note that things listed as 'coming soon' can be configured manually, but are not yet working through this wizard.
"""

DOCKER_REPORT_DOC = """
# Additional reporting when chalking Docker containers
When Chalk monitors the 'docker build' command (via 'chalk docker build...'), it can report on other docker-specific information.

Note that container images only get chalked via this path; 'chalk insert' does not chalk docker images.
"""

DOCKER_LABEL_DOC = """# Docker Auto-Labeling

The metadata Chalk reports on can be automatically added to docker labels to your image when you run *'chalk docker build ...'*

The OCI standard for labels requires them to start with reverse-DNS entries.  The value you provide will be added to the label name, with a suffix consisting of a value derived from the metadata key, adhering to OSI name standards.

For instance, by default, the label for the Chalk ID would be:
```
run.crashoverride.chalk-id
```

If your container build uses Docker features unsupported by chalk, the labels will *NOT* get added.  Chalk falls back on running docker as-is, without reporting, if it cannot completely comprehend the semantics of the build.

Specifically, Chalk currently doesn't yet support remote build contexts.
"""

EXTRACT_DOC =  """ # Extraction-time Reporting
When you run 'chalk extract', Chalk will generate a report that can include:
1. Data about the extraction.
2. Data about the operating environment at the time extraction ran.
3. Data about artifacts at the time of extraction (e.g., their current hash, and where they live on the file system).

By default, we only report back basic identification information and runtime information; we assume you already stashed the full mark.

If you want to selectively report some fields, that's outside the scope of this wizard, and requires a custom configuration.
"""

BUILD_BIN_DOC = """# Finishing Up

It's time to save your config (in our local SQLite database), and output your custom chalk binary.

If you want to re-create the binary later, you can re-do the wizard (loading this config); select "overwrite", without changing anything else.   We probably will eventually allow this from the main screen.

If you do make configuration changes, you can easily turn it into a second configuration by changing the name to something unique.

The "Build comment" field is just for your own documentation when using this tool.
"""

CHALK_CONFIG_INTRO_TEXT    = """
# Chalk Configuration Tool (alpha 1)
## Welcome to the **Chalk** configuration tool!

Chalk is like GPS for your code. It makes it easy to find where your code, containers and binaries are deployed.

In CI/CD, Chalk captures data about software, marking executables and containers. Then, wherever you see an artifact, you can extract the mark, so that you can easily look up the info you have, add new info, etc.

This wizard currently allows you to setup and manage chalk configurations.  The wizard covers the most common functionality, but if you want more customization, you can manually create a configuration.  See the documentation.

Note that the wizard will build a configuration, and generate a
binary.  'Export' will give you either a JSON blob used within this
tool, or the actual **con4m** code generated from it.

"""

FIRST_TIME_INTRO = """# Chalk Config Tool ALPHA 1: WARNING!
This is an early beta of this configuration tool. Currently, it only works with Linux binaries, and it requires you to have the binaries locally.

 Specifically, it looks for them under the current working directory, in:
```
bin/chalk
```

Also, some Wizard functionality is not available yet through the wizard (e.g., sending back to Crash Override).
"""
