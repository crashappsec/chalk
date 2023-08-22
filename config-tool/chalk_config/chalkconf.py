#!/usr/bin/env python3
# John Viega. john@crashoverride.com
import asyncio
import hashlib
import json
import os
import platform
import signal
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib
import webbrowser
from pathlib import Path
import requests
from .conf_options import (
    check_for_updates,
    config_to_json,
    determine_sys_arch,
    json_to_dict,
    dict_to_id,
    get_app,
    get_chalk_url,
    get_wiz_screen,
    get_wizard,
    MIN_TTY_WIDTH,
    set_app,
    set_wiz_screen,
    set_wizard,
)
from . import conf_widgets  ##row_ids is why this is needed - ToDo cleanup
from .conf_widgets import (
    AlphaModal,
    ConfigTable,
    ProfilePicture,
    cursor,
    db,
    ReleaseNotesModal,
    set_conf_table,
    write_binary,
)
from .css import WIZARD_CSS
from .localized_text import *
from rich.markdown import *
from textual.app import *
from textual.containers import *
from textual.coordinate import *
from textual.screen import *
from textual.widgets import Markdown as MDown
from textual.widgets import *
from .__version__ import __version__
from .wiz_panes import ApiAuth, DisplayQrCode, init_sections
from .wizard import AckModal, ProfileModal, ReleaseNotesModal, UpdateModal, Wizard
from .log import get_logger

MODULE_LOCATION = os.path.dirname(__file__)

# Temporary until we have the upstream chalk static bins working X-platform
if platform.machine() != "x86_64" or platform.system() != "Linux":
    print(
        f"Error: System {platform.system()} {platform.machine()} detected, but currently only Linux x86_64 supported."
    )
    print("Exiting....")
    sys.exit(-2)

logger = get_logger(__name__)

# Check terminal width, a width different to 80 normally causes problems
rows, cols = os.popen("stty size", "r").read().split()
if int(cols) < MIN_TTY_WIDTH:
    input(
        f"\n[!] The width of the terminal is {cols} but needs to be a minimum of {MIN_TTY_WIDTH}. Please adjust your terminal width and relaunch. Exiting....\n"
    )
    sys.exit(-2)
logger.info(f"TTY detected as having {int(cols)} columns")

first_run = False

conftable = ConfigTable()
set_conf_table(conftable)

# Even if I put this in NewApp's __init__ it goes async and AlphaModal errors??
intro_md = MDown(CHALK_CONFIG_INTRO_TEXT, id="intro_md")


def update_next_button(label, variant="default"):
    """ """
    n_str = label
    n_button = wiz.query_one("#Next")
    n_button.update(n_str)
    n_button.label = n_str
    n_button.variant = variant
    n_button.refresh()


# Callback that is passed to Wizard() and is invoked when the wizard has finished
def finish_up():
    # ToDo - Band-Aid this is imported here because it breaks things if imported outside
    import datetime

    config = config_to_json()
    as_dict = json_to_dict(config)
    internal_id = dict_to_id(as_dict)
    logger.info(dir(datetime))
    timestamp = datetime.datetime.now().ctime()
    confname = wiz.query_one("#conf_name").value
    slam = wiz.query_one("#overwrite_config").value
    debug = wiz.query_one("#debug_build").value
    exe = wiz.query_one("#exe_name").value
    note = wiz.query_one("#note").value

    existing = cursor.execute(
        "SELECT id FROM configs WHERE name=?", [confname]
    ).fetchone()
    update = False
    if existing != None:
        if not slam:
            return ERR_EXISTS % confname
        else:
            update = True
            query = (
                "UPDATE configs SET date=?, CHALK_VERSION=?, id=?, "
                + "json=?, note=? WHERE name=?"
            )
            row = [timestamp, CHALK_VERSION, internal_id, config, note, confname]
    else:
        idtest = cursor.execute(
            "SELECT name FROM configs WHERE id=?", [internal_id]
        ).fetchone()
        if idtest != None:
            name = idtest[0]
            return ERR_DUPE % idtest[0]
        row = [confname, timestamp, CHALK_VERSION, internal_id, config, note]
        query = "INSERT INTO configs VALUES(?, ?, ?, ?, ?, ?)"

    if write_binary(exe, confname, config, as_dict):
        cursor.execute(query, row)
        db.commit()
        if update:
            # Update by first deleting the existing row.  Then add the change.
            to_delete = -1
            for i in range(len(conf_widgets.row_ids)):
                where = Coordinate(column=0, row=i)
                found_name = conftable.the_table.get_cell_at(where)
                if found_name == confname:
                    to_delete = i
                    break
            conftable.the_table.remove_row(conf_widgets.row_ids[to_delete])
            conf_widgets.row_ids = (
                conf_widgets.row_ids[0:to_delete]
                + conf_widgets.row_ids[to_delete + 1 :]
            )

        conftable.the_table.add_row(
            confname, timestamp, CHALK_VERSION, note, key=internal_id
        )
        conf_widgets.row_ids.append(internal_id)


def locate_read_changelogs():
    """
    Depending on which environment the config tool is running in the changelogs end up in different locations
    Native Python+Poetry vs PyInstaller vs PyInstaller in a Container
    """
    # FIXME auto-generate this from functions
    chalk_changelog_data = """
# Chalk Changelog

## 2023-06-26 - v0.4.4

- Initial release
    """
    config_changelog_data = """
# Config-Tool Changelog

## 2023-06-26 - v0.1.1

- Initial release
    """
    return chalk_changelog_data, config_changelog_data


async def do_test_server_download(testserverurl, loc):
    """
    Perform the actual download
    """
    # Check to see if this has already been downloaded to the pipx install location
    if os.path.exists(loc):
        logger.info(
            f"Chalk test server already downloaded, located at: {loc}. Skipping re-download."
        )
        # get_app().test_server_download_successful = True

    else:
        try:
            # Ensure bins dir is created
            os.makedirs(loc.parents[0], exist_ok=True)

            # Download the test server (via a 302 redirect)
            logger.info(f"Downloading Chalk test server to {loc}")
            test_server_binary = requests.get(
                testserverurl, stream=True, allow_redirects=True
            )

            # Write the file to the disk
            try:
                f = loc.open("wb")
                f.write(test_server_binary.content)
                f.close()
            except Exception as err:
                logger.error(
                    f"Error writing downloaded server to local fielsystem: '{err}'"
                )
                return ""
        except Exception as err:
            logger.error(f"Error downloading Chalk tests server: '{err}'")
            # Returning empty string causes a error modal to pop
            return ""

    # Ensure bin has exec bit set
    st = os.stat(loc)
    os.chmod(loc, st.st_mode | stat.S_IEXEC)

    # Symlink specific version to common path
    os.symlink(loc, loc.parents[0] / "chalkserver")

    return loc


async def do_test_staticsite_download(staticsitefilesurl, loc_static):
    # Check to see if this has already been downloaded to the pipx install location
    if os.path.exists(loc_static):
        logger.info(
            f"Chalk static site data already downloaded, located at: {loc_static}. Skipping re-download."
        )
        get_app().test_server_download_successful = True
    else:
        try:
            # Ensure site dir is created
            os.makedirs(loc_static.parents[0], exist_ok=True)

            # Download static files
            logger.info(f"Downloading static site files to {loc_static}")
            static_site_files = requests.get(
                staticsitefilesurl, stream=True, allow_redirects=True
            )

            # Write files
            try:
                f = loc_static.open("wb")
                f.write(static_site_files.content)
                f.close()
            except Exception as err:
                logger.error(
                    f"Error writing downloaded static site to local fielsystem: '{err}'"
                )
                return ""
        except Exception as err:
            # Returning empty string causes a error modal to pop
            logger.error(f"Error downloading Chalk tests static site: '{err}'")
            return ""

        try:
            # unzip
            tar = tarfile.open(loc_static)
            tar.extractall(path=loc_static.parents[0])
            tar.close()
        except Exception as err:
            logger.error(f"Error tar-gunzipping static site data: '{err}'")
            return ""

    return loc_static


async def launch_server():
    """
    Run the local server
    """
    server_bin_path = get_app().server_bin_filepath
    logger.info(f"Running test server at path {server_bin_path}")
    server_proc = await asyncio.create_subprocess_shell(
        str(server_bin_path),
        cwd=server_bin_path.parents[0],
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    logger.info(f"Server process object {server_proc}")
    return server_proc


def pop_user_profile(
    user_name, user_email, user_id, user_picture, success_msg=False, pop_off=1
):
    """
    Pop up a modal showing the logged in user profile
    """
    # Progress to next step now authentication has completed
    if success_msg:
        user_profile_data = "%s\n" % LOGIN_SUCCESS
    else:
        user_profile_data = "%s\n" % PROFILE_LABEL
    user_profile_data += """Crash ⍉verride has you...

Follow the white rabbit. Knock, Knock .... 🐇🐇🐇"""
    user_profile_data += f"\n### Authenticated profile:\n\n User: {user_name} ({user_email})\n\n User ID: {user_id}\n\n User Pic:\n\n"
    # ToDo - Breaks rendering in Textual right now, will come back to
    pic = ProfilePicture().generate(user_picture)
    get_app().push_screen(ProfileModal(user_profile_data, pic=pic, pops=pop_off))


def detect_ssh_session():
    if "SSH_CLIENT" in os.environ or "SSH_TTY" in os.environ:
        # Yes we are running in an SSH terminal
        return True
    # No we are running locally
    return False


class ConfWiz(Wizard):
    def __init__(
        self,
        end_callback,
        sectionBasics,
        sectionOutputConf,
        sectionChalking,
        sectionReporting,
        sectionBinGen,
    ):
        self.sectionBasics = sectionBasics
        self.sectionOutputConf = sectionOutputConf
        self.sectionChalking = sectionChalking
        self.sectionReporting = sectionReporting
        self.sectionBinGen = sectionBinGen
        super().__init__(end_callback)

        # Define which panel contains the API authn switch
        self.api_authn_panel = self.panels[1]

    def load_sections(self):
        self.add_section(sectionBasics)  # panel 0 - self.first_panel
        self.add_section(sectionOutputConf)  # panel 1 - self.api_authn_panel
        self.add_section(sectionChalking)
        self.add_section(sectionReporting)
        self.add_section(sectionBinGen)

    def action_next(self):
        # Hack - this effectively disables the keybinds to the next_button stopping
        # the user from being able to bypass the disabled button via a keybind if not authenticated
        if (
            not get_app().login_widget.is_authenticated()
            and self.current_panel == self.api_authn_panel
            and self.next_button.disabled == True
        ):
            return

        super().action_next()

        # Disable the next_button on the report output config panel until user is authenticated
        if (
            not get_app().login_widget.is_authenticated()
            and self.current_panel == self.api_authn_panel
            and get_wizard().query_one("#report_co") == True
        ):
            update_next_button("Please Login")
            self.next_button.disabled = True


class ConfWizScreen(ModalScreen):
    DEFAULT_CSS = WIZARD_CSS
    TITLE = CHALK_TITLE
    BINDINGS = [
        Binding(key="escape", action="abort_wizard", description=MAIN_MENU),
        Binding(key="left", action="prev()", description=PREV_LABEL),
        Binding(key="right", action="next()", description=NEXT_LABEL),
        Binding(key="space", action="next()", show=False),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
        Binding(key="a", action=None, show=False),
        Binding(key="b", action=None),
        Binding(key="d", action=None),
        Binding(key="h", action="show_help", description=HELP_TOGGLE),
        Binding(key="l", action=None),
        Binding(key="r", action=None),
        Binding(key="u", action=None, show=False),
    ]

    def compose(self):
        yield Header(show_clock=False)
        yield self.wiz
        yield Footer()

    def action_next(self):
        self.wiz.action_next()

    def action_prev(self):
        self.wiz.action_prev()

    def on_screen_resume(self):
        self.wiz.reset()

    def action_show_help(self):
        """ """
        self.wiz.action_help()

    def action_abort_wizard(self):
        self.wiz.abort_wizard()


class LoginScreen(ModalScreen):
    """
    Screen to login to Crash ⍉verride API via OIDC
    """

    DEFAULT_CSS = WIZARD_CSS
    TITLE = LOGIN_TITLE
    BINDINGS = [
        Binding(key="escape", action="abort_wizard", description=MAIN_MENU),
        Binding(key="a", action=None, description=LOGIN_LABEL, show=False),
        Binding(key="b", action=None, description=MAIN_MENU, show=False),
        Binding(key="c", action=None, description=MAIN_MENU, show=False),
        Binding(key="l", action=None, description=MAIN_MENU, show=False),
        Binding(key="q", action="display_qr", description=QR_LABEL),
        Binding(key="ctrl+q", action=None, description=MAIN_MENU, show=False),
        Binding(key="r", action=None, description=MAIN_MENU, show=False),
        Binding(key="u", action=None, description=MAIN_MENU, show=False),
    ]
    AUTO_FOCUS = None
    login_widget = None

    def on_api_auth_auth_success(self, event: ApiAuth.AuthSuccess) -> None:
        """ """
        my_app = get_app()

        ##Authentication attempt outcome
        if event.result == "success":
            # Write token to db tokens table
            self.save_token_to_db(event)

            # Set user / authenticated values at the app level
            my_app.user_name = event.auth_obj.user_name
            my_app.user_email = event.auth_obj.user_email
            my_app.user_id = event.auth_obj.user_id
            my_app.user_picture = event.auth_obj.user_picture

            # Update loginbutton on main page button bar to show logged in user
            user_str = "Logged In!"
            l_btn = conftable.login_button
            l_btn.label = user_str
            l_btn.variant = "success"
            l_btn.update(user_str)
            l_btn.refresh()
            # If the login button is hit from main screen the wizard DOM hasn't
            # been built yet so this fails ....... async DOMs suck
            try:
                # Update inline login button on wizard page to show logged in user
                wiz_l_btn = wiz.query_one("#wiz_login_button")
                wiz_l_btn.label = user_str
                wiz_l_btn.variant = "success"
                wiz_l_btn.update(user_str)
                wiz_l_btn.refresh()

                # Ensure wizard's next button is enabled
                update_next_button("Next")
                wiz.next_button.disabled = False
            except:
                pass
            # Show the user authentication successful in a pop-up
            pop_user_profile(
                my_app.user_name,
                my_app.user_email,
                my_app.user_id,
                my_app.user_picture,
                success_msg=True,
                pop_off=2,
            )

        elif event.result == "id_token_verification_failure":
            # Pop error window
            err_msg = "## ID Token verification failure"  # Todo localise
            get_app().push_screen(AckModal(err_msg, pops=2))
            # Reset login widget
            my_app.login_widget.auth_status_checker.stop()
        elif event.result == "authentication_failure":
            # Pop error window
            err_msg = "## Login failure"  # Todo localise
            get_app().push_screen(AckModal(err_msg, pops=2))
            # Reset login widget
            my_app.login_widget.reset_login_widget()
        else:
            # Pop error window
            err_msg = "Unknown login error"  # Todo localise
            get_app().push_screen(AckModal(err_msg, pops=2))

    def _create_db_authn_table(self):
        """
        Create a table in the local DB to store issued bearer tokens
        Bearer tokens are issued to a user but may be shared across multiple chalk profiles
        they also need to be accessible across multiple invocations of the config-tool
        """
        try:
            # Create table
            cursor.execute(
                """CREATE TABLE IF NOT EXISTS tokens (co_api_token, tenat_id, post_url, timestamp, name, email, uid, image)"""
            )
            # commit the changes to db
            db.commit()
        except:
            raise

    def save_token_to_db(self, event):
        try:
            # Check DB table exists, if not create it
            self._create_db_authn_table()
            params = (
                event.auth_obj.token,
                event.auth_obj.revision_id,
                event.auth_obj.crash_override_api_url,
                str(time.time()),
                event.auth_obj.user_name,
                event.auth_obj.user_email,
                event.auth_obj.user_id,
                event.auth_obj.user_picture,
            )
            sql_str = "INSERT INTO tokens (co_api_token, tenat_id, post_url, timestamp, name, email, uid, image) values(?,?,?,?,?,?,?,?)"
            cursor.execute(sql_str, params)
            db.commit()
        except:
            raise

    def get_bearer_token_from_db(self):
        """
        Grab bearer token from DB
        """
        try:
            cursor.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='tokens';"
            )
            rows = cursor.fetchall()
            if not rows:
                logger.info(
                    "tokens table not found in db, proceeding in logged out state"
                )
                return None, None, None, None, None, None, None, None
        except:
            return None, None, None, None, None, None, None, None

        logger.info("Getting C0 API token from DB.....")
        try:
            cursor.execute(
                "SELECT co_api_token, tenat_id, post_url, timestamp, name, email, uid, image from tokens"
            )
            rows = cursor.fetchall()
            logger.info(rows)
            api_token, tenant_id, api_url, timestamp, name, email, uid, image = rows[0]
        except:
            return None, None, None, None, None, None, None, None

        return api_token, tenant_id, api_url, timestamp, name, email, uid, image

    def clear_token_from_db(self):
        """
        Remove API token from DB
        NOTE: Currently this just hoses all rows in the table
        """
        try:
            cursor.execute("DELETE FROM tokens;")
            db.commit()
            self.login_widget.crashoverride_auth_obj.authenticated = False
            user_str = "L⍉gin"
            l_btn = conftable.login_button
            l_btn.label = user_str
            l_btn.variant = "default"
            l_btn.update(user_str)
            l_btn.refresh()
            return True
        except:
            return False

    def compose(self):
        yield Header(show_clock=True)
        yield self.login_widget
        yield Footer()

    def action_next(self):
        self.wiz.action_next()

    def action_open_authn_webpage(self):
        """
        Pop open a new browser window at the login page with code filled out
        """
        webbrowser.open(self.login_widget.device_code_json["verification_uri_complete"])

    def action_display_qr(self):
        """ """
        get_app().action_display_qr()

    def action_abort_wizard(self):
        my_app = get_app()
        my_app.pop_screen()


class QrCodeScreen(ModalScreen):
    """
    Screen to display QR Code of OAuth URL
    """

    DEFAULT_CSS = WIZARD_CSS
    BINDINGS = [
        Binding(key="escape", action="complete", description=BACK_LABEL),
        Binding(key="space", action="complete", description=BACK_LABEL, show=False),
        Binding(key="left", action="complete", description=BACK_LABEL, show=False),
        Binding(key="enter", action="complete", description=BACK_LABEL, show=False),
        Binding(key="a", action=None, description=LOGIN_LABEL, show=False),
        Binding(key="b", action=None, description=MAIN_MENU, show=False),
        Binding(key="c", action=None, description=MAIN_MENU, show=False),
        Binding(key="l", action=None, description=MAIN_MENU, show=False),
        Binding(key="ctrl+q", action=None, description=MAIN_MENU, show=False),
        Binding(key="r", action=None, description=MAIN_MENU, show=False),
        Binding(key="u", action=None, description=MAIN_MENU, show=False),
    ]

    qr_code_widget = None
    hdr_widget = MDown(QR_CODE_TITLE)
    hdr_widget.styles.margin = (0, 10)
    hdr_widget.styles.padding = (1, 4)

    def compose(self):
        yield self.hdr_widget
        yield self.qr_code_widget
        yield Footer()

    def action_complete(self):
        my_app = get_app()
        my_app.pop_screen()


# Convenience vars.
# Crash Override API login screen - OIDC
login_widget = ApiAuth()
login_widget.styles.margin = (0, 10)
login_screen = LoginScreen()
login_screen.login_widget = login_widget

# QR code screen
qr_code_widget = DisplayQrCode()
qr_code_widget.styles.margin = (0, 10)
qr_code_widget.styles.padding = (0, 25)
qr_code_screen = QrCodeScreen()
qr_code_screen.qr_code_widget = qr_code_widget

# Wizard screen
wiz_screen = ConfWizScreen()


class NewApp(App):
    DEFAULT_CSS = WIZARD_CSS
    TITLE = CHALK_TITLE
    SCREENS = {
        "confwiz": wiz_screen,
        "loginscreen": login_screen,
        "qrcodescreen": qr_code_screen,
    }
    BINDINGS = [
        Binding(key="ctrl+q", action="quit", description=QUIT_LABEL, priority=True),
        Binding(key="a", action="about", description="About"),
        Binding(key="l", action="login()", description=LOGIN_LABEL),
        Binding(
            key="b",
            action="generate_chalk_binary()",
            description="Generate Chalk Binary",
        ),  # ToDo localize
        Binding(key="r", action="releasenotes()", description="Release Notes"),
        Binding(key="u", action="check_for_updates", description="Check for Updates"),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
        # Binding(key="n", action="newconfig()", show = False),
    ]
    config_table = conftable
    login_widget = login_widget
    qr_code_widget = qr_code_widget

    # determine correct arch
    system, machine = determine_sys_arch()
    version = __version__.split('.post')[0]
    server_bin_name = f"chalkserver-{version}-{system}-{machine}"
    static_site_url = "https://dl.crashoverride.run/chalksite.tar.gz"
    test_server_url = f"https://dl.crashoverride.run/{server_bin_name}"
    server_proc = None
    server_bin_filepath = (
        Path(MODULE_LOCATION)
        / "bin"
        / Path(urllib.parse.urlparse(test_server_url).path[1:])
    )
    staticsite_filepath = (
        Path(MODULE_LOCATION)
        / "bin"
        / Path(urllib.parse.urlparse(static_site_url).path[1:])
    )
    test_server_download_successful = False
    test_server_running = False
    user_name = ""
    user_email = ""
    user_id = ""
    user_picture = ""
    is_in_ssh_session = detect_ssh_session()

    def compose(self):
        yield Header(show_clock=False, id="chalk_header")
        yield intro_md
        yield conftable
        yield Footer()

    def on_mount(self):
        if first_run:
            newbie_modal = AlphaModal(FIRST_TIME_INTRO, button_text=CHEEKY_OK)
            self.push_screen(newbie_modal)

        # If chalkserver already downloaded auto-update button to 'run' it
        if os.path.exists(
            Path(MODULE_LOCATION) / "bin" / "chalkserver"
        ) and os.path.exists(Path(MODULE_LOCATION) / "bin" / "site"):
            # Update button to 'run server'
            dl_button = conftable.download_button
            dl_str = "Run Server"
            dl_button.label = dl_str
            dl_button.variant = "success"
            dl_button.refresh()
            self.test_server_download_successful = True

        # If user logged in on a previous session, grab API token from db
        (
            api_token,
            tenant_id,
            api_url,
            timestamp,
            name,
            email,
            uid,
            image,
        ) = self.SCREENS["loginscreen"].get_bearer_token_from_db()
        if api_token:
            # Update app state
            self.user_name = name
            self.user_email = email
            self.user_id = uid
            self.user_picture = image
            self.login_widget.crashoverride_auth_obj.authenticated = True

            # Update loginbutton on main page button bar to show logged in user
            user_str = "Logged In!"
            l_btn = conftable.login_button
            l_btn.label = user_str
            l_btn.variant = "success"
            l_btn.update(user_str)
            l_btn.refresh()

    # def action_newconfig(self):
    # wiz_screen = self.SCREENS["confwiz"]
    # wiz_screen.wiz

    # conftable.next_button.disabled=True
    # conftable.action_next()
    # conftable.app.push_screen('confwiz')
    # load_from_json(default_config_json)

    def action_check_for_updates(self):
        """
        Temporary way to check for updates
        """
        updates_available, remote_ver = check_for_updates()
        if updates_available:
            update_msg = f"# Update Available\n\nYou are running {__version__}, the latest version on the server is {remote_ver.decode('utf-8')}"
            self.push_screen(
                UpdateModal(
                    msg=update_msg,
                    button_text="Update",
                    cancel_text=" Go back...",
                    wiz=self,
                )
            )
        else:
            update_msg = f"# No Update Available\n\nYou are running the latest version which is {__version__}"
            self.push_screen(AckModal(msg=update_msg, wiz=self))

    def action_about(self):
        """
        Show pop-up window with a variety of environment info
        """
        about_msg = f""" # About Chalk Config Tool\n\n
* **TUI Ver:** {self.version}\n\n
* **Sys:** {self.system}\n\n
* **Arch:** {self.machine}\n\n
* **Path:** {MODULE_LOCATION}\n\n
* **CWD:** {os.getcwd()}\n\n
* **BaseChalk URL:** {get_chalk_url()}\n\n
* **Test Server URL:** {self.test_server_url}\n\n
* **Static-site URL:** {self.static_site_url}\n\n
"""
        self.push_screen(AckModal(msg=about_msg, wiz=self))

    def action_login(self):
        """
        Initiate the user registration/login process for Crash Override API
        """
        if not self.login_widget.is_authenticated():
            # Start background task that polls chalk API
            ret = self.login_widget.start_auth_polling()

            # Display screen in terminal
            conftable.app.push_screen("loginscreen")
        else:
            ##If we are already authentcated just show the user profile of logged in user
            # pop_user_profile(self.login_widget.crashoverride_auth_obj)
            pop_user_profile(
                self.user_name, self.user_email, self.user_id, self.user_picture
            )

    def action_display_qr(self):
        """
        Pop up a screen showing the QR code of the login URL
        """
        self.qr_code_widget.generate_qr(
            self.login_widget.crashoverride_auth_obj.auth_url
        )
        conftable.app.push_screen("qrcodescreen")
        qr_code_screen.set_focus(None)

    def action_releasenotes(self):
        """
        Pop up a screen to show the release notes for both chalk and config-tool
        """
        changelog_data_chalk, changelog_data_config_tool = locate_read_changelogs()
        self.push_screen(
            ReleaseNotesModal([changelog_data_chalk, changelog_data_config_tool])
        )

    async def action_generate_chalk_binary(self):
        """
        Action to build currently selected binary
        """
        await conftable.binary_genration_button.on_button_pressed()

    async def action_downloadtestserver(self):
        """
        Download the test chalk server
        """
        #  Set if server downloaded or already present on system
        if self.test_server_download_successful:
            if not self.test_server_running:
                # Server already downloaded, try and run it in a background process instead
                self.server_proc = await launch_server()
                sub_pid = await self.server_proc.stderr.readline()
                logger.info(f"Subprocess stderr {sub_pid}")
                self.sub_pid = int(sub_pid.split(b"[")[-1].split(b"]")[0])
                logger.info(f"Server process to kill: {self.sub_pid}")

                # ToDo check return
                self.test_server_running = True

                # Update button to 'stop server'
                dl_button = conftable.download_button
                dl_str = "Stop Server"
                dl_button = conftable.download_button
                dl_button.label = dl_str
                dl_button.variant = "error"
                dl_button.refresh()
                launch_msg = f"# Chalk Test Server Running!\n\nURL of Server: http://127.0.0.1:8585\n\nChalk Test Server process: {self.server_proc}"

                await asyncio.sleep(1.0)
                self.push_screen(AckModal(msg=launch_msg, wiz=self))

            else:
                ##Stop server
                logger.info(f"Stopping Chalk Test Server, kill PID {self.sub_pid}")
                shutdown_msg = f"# Chalk Test Server Shutdown\n\nProcess exited."
                os.kill(self.sub_pid, signal.SIGTERM)
                self.test_server_running = False

                # Update button to 'run server'
                dl_button = conftable.download_button
                dl_str = "Run Server"
                dl_button = conftable.download_button
                dl_button.label = dl_str
                dl_button.variant = "success"
                dl_button.refresh()

                await asyncio.sleep(1.0)
                self.push_screen(AckModal(msg=shutdown_msg, wiz=self))
                self.sub_pid = None

            return None

        # Update download on main page button bar to show in progress
        dl_str = "Downloading ..."
        dl_button = conftable.download_button
        dl_button.label = dl_str
        dl_button.variant = "warning"
        dl_button.refresh()

        # Dumb but this is needed for the button to actually change ....
        await asyncio.sleep(1.0)

        # # determine correct arch
        # system, machine = determine_sys_arch()
        # version = f"{__version__}"
        # server_bin_name = f"chalkserver-{version}-{system}-{machine}"

        # construct urls
        # test_server_url = "https://dl.crashoverride.run/%s"%(server_bin_name)
        # static_files_url = "https://dl.crashoverride.run/chalksite.tar.gz"

        # Download server
        bin_ret = await do_test_server_download(
            self.test_server_url, self.server_bin_filepath
        )
        static_ret = await do_test_staticsite_download(
            self.static_site_url, self.staticsite_filepath
        )

        # pop download complete screen
        if bin_ret and static_ret:
            self.test_server_download_successful = True
            dl_str = "Run Server"
            dl_button = conftable.download_button
            dl_button.label = dl_str
            dl_button.variant = "success"
            dl_button.refresh()
            completion_msg = f"# Download Complete !\n\nChalk Test Server downloaded to: {self.server_bin_filepath}"

            self.push_screen(AckModal(msg=completion_msg, wiz=self))

        # pop download failed download screen
        else:
            logger.error(
                "Null path returned from do_test_server_download cancelling download"
            )
            dl_button = conftable.download_button
            dl_str = "Get Test Server"
            dl_button = conftable.download_button
            dl_button.label = dl_str
            dl_button.variant = "default"
            dl_button.refresh()
            wiz.require_ack("Download Failed 👎")  # add in erorr description


def main():
    global sectionBasics, sectionOutputConf, sectionChalking, sectionReporting, sectionBinGen, wiz, wiz_screen, login_screen

    logger.info("Running chalk-config")
    if not sys.stdout.isatty():
        raise SystemExit(
            "Can only run in a TTY. Please run via -it if running in docker"
        )

    env_vars = os.environ
    term = env_vars.get("TERM", "")
    color = env_vars.get("COLORTERM", "")
    # FIXME just adjust the CSS
    if not (("256" in term) or ("true" in color)):
        raise SystemExit(
            f"Please set $TERM and $COLORTERM to allow 256 colors and truecolor respectively. Found: TERM={term} COLORTERM={color}"
        )
    cached_stdout_fd = sys.stdout
    app = NewApp()
    set_app(app)
    (
        sectionBasics,
        sectionOutputConf,
        sectionChalking,
        sectionReporting,
        sectionBinGen,
    ) = init_sections()

    # Main Wizard screen - multiple steps
    wiz = ConfWiz(
        finish_up,
        sectionBasics,
        sectionOutputConf,
        sectionChalking,
        sectionReporting,
        sectionBinGen,
    )
    wiz_screen.wiz = wiz

    # Back reference to wizard object in other screens
    login_screen.wiz = wiz

    set_wiz_screen(wiz_screen)
    set_wizard(wiz)

    app.run()


if __name__ == "__main__":
    main()
