CHALK_VERSION = "0.4.3"
CHALK_TITLE = "Chalk v." + CHALK_VERSION + " Configuration Tool"

ERROR_TEXT = """An error occurred during [red]Chalk[/] installation.

Press Enter to return to Windows, or

Press CTRL+ALT+DEL to restart your computer. If you do this,
you will lose any unsaved information in all open applications.

Error: 0E : 016F : BFF9B3D4
"""

INTRO_TEXT    = """
# Chalk Configuration Tool (alpha 1)
## Welcome to the **Chalk** configuration tool!

Chalk is like GPS for your code. It makes it esy to find where your code, containers and binaries are deployed.

In CI/CD, Chalk captures data about software, marking executables and containers. Then, wherever you see an artifact, you can extract the mark, so that you can easily look up the info you have, add new info, etc.

This wizard currently allows you to setup and manage chalk configurations via Wizard.  The wizard covers the most common functionality, but if you want more customization, you can manually create a configuration.  See the documentation.

Note that the wizard will build a configuration, and generate a
binary.  'Export' will give you either a JSON blob used within this
tool, or the actual **con4m** code generated from it.

"""

BEGIN_LABEL = "Begin!"
ABORT_LABEL = "Nope, sorry."

KEYPRESS_QUIT = "Quit install"
KEYPRESS_GO   = "Begin install"

BASICS_PANE_MAIN = """
# Setting The Default Command
How are you primarily intending to use this Chalk binary?
(See 'Help' below for more details).
"""
BASICS_PANE_CMDLINE = "On the command line"
BASICS_PANE_DOCKER  = "In CI/CD, wrapping the docker command"
BASICS_PANE_OTHER   = "In CI/CD, after building stand-alone artifacts"

REPORTING_PANE_MAIN= """\
# Report Output Configurations
When Chalk finishes running, where should output get sent by default? (Select all that apply)"""

REPORTING_PANE_CO = "Send it to Crash Override (coming soon)"
REPORTING_PANE_STDOUT = "Output to stdout"
REPORTING_PANE_LOG = "Output to a log file"
REPORTING_PANE_HTTPS = "Output to an https URL"
REPORTING_PANE_S3 = "Output to an S3 bucket"

REPORTING_PANE_ENV="""

Note that you can use environment variables to configure output sinks as well.  Environment variables can be used to re-configure the defaults, or to add additional reporting.

You can also customize the names of environment variables. If you choose to do that, you will do so on the next screen.
"""

REPORTING_ENV_LABEL="Env vars create additional report"

REPORTING_ENV2_LABEL="Customize environment variables?"


LOG_PARAMS = """# Log File Configuration

The path to the file must already exist on any machine on which this runs, and the file must be writable."""

HTTPS_PARAMS = """# HTTPS Post Config
Data gets sent with the following header:
```
Content-Type: application/json
```

If you need to add a custom MIME header to the POST (e.g., for authentication), please do so below, exactly as it should appear.  Eg:
```
X-My-Auth-Id: WRGFsdf-sdfasdf-SDFkdj
```
"""
