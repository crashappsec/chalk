import datetime
import hashlib
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import urllib
import urllib.request
import webbrowser
from pathlib import *

#import ascii_magic
from conf_options import *
from css import WIZARD_CSS
from localized_text import *
from rich.markdown import *
from textual.app import *
from textual.containers import *
from textual.coordinate import *
from textual.reactive import Reactive
from textual.screen import *
from textual.widgets import Markdown as MDown
from textual.widgets import *
from wizard import *

global cursor, conftable
cursor = None
conftable = None


def set_conf_table(t):
    global conftable
    conftable = t


def try_system_init():
    global db
    try:
        db = sqlite3.connect(os.path.join(DB_PATH_SYSTEM, DB_FILE))
        return True
    except:
        return False


def local_init():
    global db
    os.makedirs(DB_PATH_LOCAL, exist_ok=True)
    db = sqlite3.connect(os.path.join(DB_PATH_LOCAL, DB_FILE))


def sqlite_init():
    global cursor, first_run

    if not try_system_init():
        local_init()

    cursor = db.cursor()

    try:
        cursor.execute(
            "CREATE TABLE configs(name, date, CHALK_VERSION, id, " + "json, note)"
        )
        timestamp = datetime.datetime.now().ctime()
        rows = []
        for config in default_configs:
            (d, name, note) = config
            internal_id = dict_to_id(d)
            jstr = json.dumps(d)
            row = [name, timestamp, CHALK_VERSION, internal_id, jstr, note]
            cursor.execute("INSERT INTO configs VALUES(?, ?, ?, ?, ?, ?)", row)
        db.commit()
        first_run = True
    except:
        pass  # Already created.


sqlite_init()

global row_ids
row_ids = []


# Empty parents for the sake of CSS addressing.
class ConfigName(Label):
    pass


class ConfigDate(Label):
    pass


class ConfigVersion(Label):
    pass


class ConfigDelete(Button):
    pass


class ConfigExport(Button):
    pass


class ConfigHdr(Horizontal):
    pass


class OutfileRow(Horizontal):
    pass


class ReportingContainer(Container):
    pass


class ModalDelete(ModalScreen):
    DEFAULT_CSS = WIZARD_CSS
    BINDINGS = [("q", "pop_screen()", CANCEL_LABEL), ("d", "delete", DELETE_LABEL)]

    def __init__(self, name, iid):
        super().__init__()
        self.profilename = name
        self.iid = iid

    def compose(self):
        yield Header(show_clock=True)
        yield Grid(
            Label(CONFIRM_DELETE % self.profilename, classes="model_q"),
            Button(YES_LABEL, id="delete_confirm", classes="modal_button"),
            Button(NO_LABEL, id="delete_nope", classes="modal_button"),
            classes="modal_grid",
        )
        yield Footer()

    async def on_button_pressed(self, event):
        if event.button.id == "delete_confirm":
            cursor.execute('DELETE FROM configs WHERE id="' + self.iid + '"')
            db.commit()
            conftable.the_table.remove_row(self.iid)
            msg = ACK_DELETE % self.profilename

            self.app.push_screen(AckModal(msg, pops=2))
        else:
            self.app.pop_screen()


class ExportMenu(Screen):
    DEFAULT_CSS=WIZARD_CSS
    BINDINGS = [("escape", "pop_screen()", CANCEL_LABEL)]

    def __init__(self, iid, name, jconf):
        super().__init__()
        self.iid = iid
        self.confname = name
        self.jconf = jconf

    def compose(self):
        yield Header(show_clock=True)
        yield MDown(EXPORT_MENU_INTRO)
        yield RadioSet(
            RadioButton(JSON_LABEL, True, id="export_json"),
            RadioButton(CON4M_LABEL, id="export_con4m"),
            id="set_export",
        )
        yield OutfileRow(
            Input(placeholder=PLACEHOLD_FILE, id="conf_outfile", value=self.confname),
            Label(PLACEHOLD_OUTFILE, classes="label"),
        )
        yield Horizontal(
            Button(EXPORT_LABEL, id="export_go", classes="basicbutton"),
            Button(CANCEL_LABEL, id="export_cancel", classes="basicbutton"),
        )
        yield Footer()

    async def on_button_pressed(self, event):
        if event.button.id == "export_go":
            val_is_json = self.query_one("#export_json").value
            if val_is_json:
                to_out = self.jconf
                ext = ".json"
            else:
                to_out = dict_to_con4m(json_to_dict(self.jconf))
                ext = ".c4m"
            fname = self.query_one("#conf_outfile").value
            if not "." in fname:
                fname += ext
            f = open(fname, "w")
            f.write(to_out)
            f.close()
            msg = ACK_EXPORT % fname
            await self.app.push_screen(AckModal(msg, pops=2))
        else:
            self.app.pop_screen()


class ConfigTable(Container):
    def __init__(self):
        super().__init__(id="conftbl")
        self.the_table = DataTable(id="the_table")
        self.the_table.cursor_type = "row"   
        self.the_table.styles.margin = (0,3)

        #ToDo update proper localized strings
        self.login_button = LoginButton(label="L⍉gin", classes="basicbutton", id="login_button")
             
    async def on_mount(self):
        await self.the_table.mount()
        global row_ids
        cols = (COL_NAME, COL_DATE, COL_VERS, COL_NOTE)
        self.the_table.add_columns(*cols)
        r = cursor.execute("SELECT * FROM configs").fetchall()
        rows = []
        row_ids = []
        for row in r:
            r = [row[0], row[1], row[2], row[5]]
            row_ids.append(row[3])
            try:
                self.the_table.add_row(*r, key=row[3])
            except:
                # The above should only fail if the same key appears
                # twice, which shouldn't happen when we're managing it,
                # but just be defensive for when people have munged the DB
                # manually.
                #
                # This basically causes us to skip displaying anything that's
                # inserted into the DB that's the same config, different name,
                # past the first one seen.
                pass

    def compose(self):
        yield self.the_table
        yield Horizontal(
            self.login_button,
            RunWizardButton(label=NEW_LABEL),
            EditConfigButton(label=EDIT_LABEL, classes="basicbutton"),
            DelConfigButton(label=DELETE_LABEL, classes="basicbutton"),
            ExConfigButton(label=EXPORT_LABEL, classes="basicbutton"),
            ReleaseNotesButton(label="Release Notes", classes="basicbutton"), #ToDo localize
            classes="padme",
        )


class ReleaseNotesButton(Button):
    async def on_button_pressed(self):
        """
        Pop open release notes modal
        """
        get_app().action_releasenotes()
  
class RunWizardButton(Button):
    async def on_button_pressed(self):
        await self.app.push_screen("confwiz")
        load_from_json(default_config_json)


class EditConfigButton(Button):
    async def on_button_pressed(self):
        await self.app.push_screen("confwiz")
        cursor_row = conftable.the_table.cursor_row
        r = cursor.execute(
            "SELECT json, name, note FROM configs WHERE id=?", [row_ids[cursor_row]]
        ).fetchone()
        if r is not None:
            json_txt, name, note = r
            load_from_json(json_txt, name, note)


class DelConfigButton(Button):
    def on_button_pressed(self):
        cursor_row = self.app.query_one("#the_table").cursor_row
        # FIXME make button stransparent
        names = cursor.execute(
            'SELECT name FROM configs where id="%s"' % row_ids[cursor_row]
        ).fetchone()
        if names:
            self.app.push_screen(ModalDelete(name=names[0], iid=row_ids[cursor_row]))


class ExConfigButton(Button):
    def on_button_pressed(self):
        cursor_row = self.app.query_one("#the_table").cursor_row
        items = cursor.execute(
            'SELECT name, json FROM configs where id="%s"' % row_ids[cursor_row]
        ).fetchone()
        if items:
            menu = ExportMenu(row_ids[cursor_row], items[0], items[1])
            self.app.push_screen(menu)


class EnablingCheckbox(Checkbox):
    def __init__(self, target, title, value=False, disabled=False, id=None):
        Checkbox.__init__(self, title, value, disabled=disabled, id=id)
        self.refd_id = "#" + target
        self.original_state = value

    def reset(self):
        if self.value != self.original_state:
            self.value = self.original_state

    def on_checkbox_changed(self, event: Checkbox.Changed):
        get_wizard().query_one(self.refd_id).toggle()


class HttpsUrlCheckbox(Checkbox):
    def __init__(self, title, id):
        self.original_state = True
        Checkbox.__init__(self, title, self.original_state, id=id)
        self.refd_id = "#http_conf"

    def reset(self):
        if self.value != self.original_state:
            self.value = self.original_state

    def on_checkbox_changed(self, event: Checkbox.Changed):
        ##Enable/disable to HTTPS URL config pane in the wizard
        get_wizard().query_one(self.refd_id).toggle()

        ##Todo abstract the enable/disable next button logic to avoid ever growing custom logic, but until then ....
        ## Enable / disable the next button based on what has been selected / if HTTPS_URL disabled
        if self.value:
            ##Enable API toggle
            get_wizard().query_one("#c0api_toggle").disabled = False
            ##If switch set on, enable login button
            if get_wizard().query_one("#c0api_toggle").value:
                get_wizard().query_one("#wiz_login_button").disabled = False
                ##If we aren't authenticated disable next button
                if not get_app().login_widget.is_authenticated() and get_wizard().current_panel == get_wizard().api_authn_panel:
                    get_wizard().next_button.disabled = True
            else:
                get_wizard().next_button.disabled = False
        else:
            get_wizard().query_one("#wiz_login_button").disabled = True
            get_wizard().query_one("#c0api_toggle").disabled = True
            get_wizard().next_button.disabled = False


class EnvToggle(Switch):
    def on_click(self):
        envpane = get_wizard().query_one("#envconf")
        envpane.disabled = not envpane.disabled

class AlphaModal(AckModal):
    def on_mount(self):
        intro_md.update(INTRO_TEXT)

class LoginButton(Button):
    async def on_button_pressed(self):
        get_app().action_login()

class QRButton(Button):
    async def on_button_pressed(self):
        get_app().action_display_qr()

class PopBrowserButton(Button):
    async def on_button_pressed(self):
        webbrowser.open(get_app().login_widget.device_code_json['verification_uri_complete'])

# class ProfilePicture(Static):
#     ascii_picture = Reactive("")
#     def render(self) -> str:
#         return self.ascii_picture
    
#     def generate(self, data):
#         #Todo exceptions
#         a = ascii_magic.AsciiArt.from_url(data)
#         self.ascii_picture = "\n\n%s\n\n\n\n"%(a.to_ascii(columns=30))
#         return self.ascii_picture

class OidcLinks(MDown):
    """
    Markdown object that will contain the genrated OIDC links
    """
    markdown = Reactive("")
    def render(self) -> str:
        return self.markdown

class QrCode(Static):
    """
    Object that will hold an ASCII art QRcode
    """
    qr_string = Reactive("")
    def render(self) -> str:
        return self.qr_string

class C0ApiToggle(Switch):
    def on_switch_changed(self):
        ##Based on switch position......
        if self.value:
            ##Enable the inline login button
            get_wizard().query_one("#wiz_login_button").disabled = False
            ##Set URL value in HTTPS pane
            get_wizard().query_one("#https_url").value = "chalk.crashoverride.run/report"
        
            ##Disable the Next button if we are not yet authenticated and wanting to use the API 
            if not get_app().authenticated and get_wizard().current_panel == get_wizard().panels[1]:
                get_wizard().next_button.disabled = True
        else:
            get_wizard().query_one("#wiz_login_button").disabled = True
            get_wizard().next_button.disabled = False
            get_wizard().query_one("#https_url").value = text_defaults["https_url"]
            
def write_from_local(dict, config, d):
    binname  = d["exe_name"]
    
    if d["release_build"]:
        chalk_bin = CONTAINER_RELEASE_PATH
    else:
        chalk_bin = CONTAINER_DEBUG_PATH

    c4mfilename = "/tmp/c4mfile"
    c4mfile = open(c4mfilename, "wb")
    c4mfile.write(dict_to_con4m(d).encode("utf-8"))
    c4mfile.close()

    try:
        subproc = subprocess.run([chalk_bin, "--error", "load", c4mfilename])
        if subproc.returncode:
            get_app().push_screen(AckModal(GENERATION_FAILED, pops=2))
            return True
        else:
            newloc = Path(OUTPUT_DIRECTORY) / Path(binname)
            shutil.move(chalk_bin + ".new", newloc)
            newloc.chmod(0o774)
            get_app().push_screen(AckModal(GENERATION_OK % newloc, pops=2))
            return True
    except Exception as e:
        err = chalk_bin + " load " + c4mfilename + ": "
        get_app().push_screen(AckModal(GENERATION_EXCEPTION % (err + repr(e))))


def write_from_url(dict, config, d):
    binname = d["exe_name"]

    if d["release_build"]:
        chalk_url = BINARY_RELEASE_URL
    else:
        chalk_url = BINARY_DEBUG_URL

    base_binary = urllib.request.urlopen(chalk_url).read()
    dir = Path(tempfile.mkdtemp())
    loc = dir / Path(binname)
    f = loc.open("wb")
    f.write(base_binary)
    f.close()

    c4mfile = tempfile.NamedTemporaryFile()
    c4mfile.write(dict_to_con4m(d).encode("utf-8"))
    c4mfile.flush()
    c4mfilename = c4mfile.name
    loc.chmod(0o774)
    try:
        subproc = subprocess.run([loc, "--error", "load", c4mfilename])
        if subproc.returncode:
            get_app().push_screen(AckModal(GENERATION_FAILED, pops=2))
            return True
        else:
            newloc = Path(OUTPUT_DIRECTORY) / Path(binname)
            shutil.move(loc.as_posix() + ".new", newloc)
            newloc.chmod(0o774)
            get_app().push_screen(AckModal(GENERATION_OK % binname, pops=2))
            return True
    except Exception as e:
        raise
        get_app().push_screen(
            AckModal(loc.as_posix() + ": " + GENERATION_EXCEPTION % repr(e))
        )


def write_binary(dict, config, d):
    if "CHALK_BINARIES_ARE_LOCAL" in os.environ:
        return write_from_local(dict, config, d)
    else:
        return write_from_url(dict, config, d)
