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

global cursor
cursor = None


def sqlite_init():
    global db, cursor, first_run
    base = os.path.expanduser('~')
    dir  = os.path.join(base, Path(".config") / Path("chalk"))
    os.makedirs(dir, exist_ok=True)
    fullpath = os.path.join(dir, "chalk-config.db")
    db = sqlite3.connect(fullpath)
    cursor = db.cursor()

    try:
        cursor.execute("CREATE TABLE configs(name, date, chalk_version, id, " +
                        "json, note)")
        timestamp = datetime.datetime.now().ctime()
        rows = []
        for config in default_configs:
            (d, name, note) = config
            print(d, name, note)
            internal_id = dict_to_id(d)
            jstr = json.dumps(d)
            row = [name, timestamp, chalk_version, internal_id, jstr, note]
            cursor.execute('INSERT INTO configs VALUES(?, ?, ?, ?, ?, ?)', row)
        db.commit()
        first_run = True
    except:
        pass # Already created.

sqlite_init()    

global row_ids
row_ids = []
    
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

class ModalDelete(ModalScreen):
    CSS_PATH = "wizard.css"
    BINDINGS = [("q", "pop_screen()", "Cancel"), ("d", "delete", "Delete")]

    def __init__(self, name, iid):
        super().__init__()
        self.profilename = name
        self.iid = iid

    def compose(self):
        yield Header(show_clock=True)
        yield Grid(
            Label('Really delete profile "' + self.profilename + '"?',
                  classes="model_q"),
            Button("Yes", id="delete_confirm", classes="modal_button"),
            Button("No", id="delete_nope",  classes="modal_button"),
            id="del_modal",
            classes = "modal_grid"
            )
        yield Footer()
    async def on_button_pressed(self, event):
        if event.button.id == "delete_confirm":
            cursor.execute('DELETE FROM configs WHERE id="' + self.iid + '"')
            db.commit()
            self.app.query_one("#the_table").remove_row(self.iid)
            msg = "Configuration '" + self.profilename + """' has been deleted.

Note that this does NOT remove any binaries generated for this configuration.
"""
            await self.app.push_screen(AckModal("# Success!\n" + msg, pops=2))
        self.app.pop_screen()

class OutfileRow(Horizontal):
    pass

class ExportMenu(Screen):
    CSS_PATH = "wizard.css"
    BINDINGS = [("q", "pop_screen()", "Cancel")]

    def __init__(self, iid, name, jconf):
        super().__init__()
        self.iid = iid
        self.confname = name
        self.jconf = jconf

    def compose(self):
        yield Header(show_clock=True)
        yield MDown("""
# Export Configuration

Export your configuration to share or back it up, if you like. Note
that, for backups, you may consider copying the SQLite database, which lives in
`~/.config/chalk/chalk-config.db`.

JSON is only read and written by this configuration tool (though currently, we have not yet added a feature to directly import this).  **Con4m** is Chalk's native configuration file, and can do far more than this configuration tool does.  However, this tool cannot import Chalk.  Similarly, Chalk does not import this tool's JSON files.

If you do not provide an extension below, we use the default (.json or .c4m depending on the type).
""")
        yield RadioSet(RadioButton("JSON",
                                   True, id = "export_json"),
                       RadioButton("Con4m", id = "export_con4m"))
        yield OutfileRow(Input(placeholder= "Enter file name",
                               id="conf_outfile", value = self.confname),
                         Label("Output File Name", classes="label"))
        yield Horizontal( Button("Export", id="export_go",
                                 classes="basicbutton"),
                          Button("Cancel", id="export_cancel",
                                 classes="basicbutton"))
        yield Footer()
    async def on_button_pressed(self, event):
        if event.button.id == "export_go":
            val_is_json = self.query_one("#export_json").value
            if val_is_json:
                to_out = self.jconf
                ext    = ".json"
            else:
                to_out = dict_to_con4m(json_to_dict(self.jconf))
                ext    = ".c4m"
            fname = self.query_one("#conf_outfile").value
            if not '.' in fname:
                fname += ext
            f = open(fname, 'w')
            f.write(to_out)
            f.close()
            msg = "Configuration saved to: " + fname
            await self.app.push_screen(AckModal("# Success!\n" + msg, pops=2))
        else:
            self.app.pop_screen()

class ConfigTable(Container):
    def __init__(self):
        super().__init__(id="conftbl")
        self.the_table = DataTable(id="the_table")
        self.the_table.cursor_type = "row"

    def on_mount(self):
        global row_ids
        cols = ("Configuration Name", "Date Created", "Chalk Version", "Note")
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
                pass
        
    def compose(self):
        yield self.the_table
        yield Horizontal(RunWizardButton(id="wizbutt",
                                         label="New Config"),
                         EditConfigButton(id="edbutt",
                                          label="Edit",
                                          classes="basicbutton"),
                         DelConfigButton(id="debutt",
                                         label="Delete", classes="basicbutton"),
                         ExConfigButton(id="exbutt",
                                        label="Export", classes="basicbutton"),
                                 classes="padme")

class ReportingContainer(Container):
    pass

class RunWizardButton(Button):
    async def on_button_pressed(self):
        try:
            load_from_json(default_config_json)
        except:
            json_text = default_config_json
            name_kludge = None
            note_kludge = None
            # If we haven't actually gone into the wizard, then load_from_json
            # will fail, because the Wiz screen won't have mounted.  So
            # on_mount will check the json_txt global, and if it's not None,
            # then it loads it for us.

        await self.app.push_screen('confwiz')
        get_wiz_screen().query_one("#conf_name").value = ""

class EditConfigButton(Button):
    def on_button_pressed(self):
        global json_txt, name_kludge, note_kludge
        
        cursor_row = self.app.query_one("#the_table").cursor_row
        r = cursor.execute("SELECT json, name, note FROM configs WHERE id=?",
                           [row_ids[cursor_row]])
        (json_txt, name_kludge, note_kludge) = r.fetchone()
        try:
           load_from_json(json_txt, name_kludge, note_kludge)
            # If we haven't actually gone into the wizard, then load_from_json
            # will fail, because the Wiz screen won't have mounted.  So
            # on_mount will check the json_txt global, and if it's not None,
            # then it loads it for us.
        except:
            pass
        self.app.push_screen('confwiz')

class DelConfigButton(Button):
    def on_button_pressed(self):
        cursor_row = self.app.query_one("#the_table").cursor_row
        name = cursor.execute('SELECT name FROM configs where id="%s"' %
                             row_ids[cursor_row]).fetchone()[0]
        self.app.push_screen(ModalDelete(name=name, iid=row_ids[cursor_row]))

class ExConfigButton(Button):
    def on_button_pressed(self):
        cursor_row = self.app.query_one("#the_table").cursor_row
        items = cursor.execute('SELECT name, json FROM configs where id="%s"' %
                             row_ids[cursor_row]).fetchone()
        menu = ExportMenu(row_ids[cursor_row], items[0], items[1])
        self.app.push_screen(menu)

class EnablingCheckbox(Checkbox):
    def __init__(self, target, title, value=False, disabled=False, id=None):
        Checkbox.__init__(self, title, value, disabled=disabled, id=id)
        self.refd_id = "#" + target

    def on_checkbox_changed(self, event: Checkbox.Changed):
        get_wizard().query_one(self.refd_id).toggle()

class EnvToggle(Switch):
    def on_click(self):
        envpane = get_wizard().query_one("#envconf")
        envpane.disabled = not envpane.disabled
        
class AlphaModal(AckModal):
    def on_mount(self):
        intro_md.update(INTRO_TEXT)

def write_binary(dict, config, d):
    binname = d["exe_name"]
    base_binary = urllib.request.urlopen(current_binary_url).read()
    dir = Path(tempfile.mkdtemp())
    loc = dir / Path(binname)
    f = loc.open("wb")
    f.write(base_binary)
    f.close()
    loc.chmod(stat.S_IEXEC | stat.S_IWRITE | stat.S_IREAD | stat.S_IXGRP)
    loc.rename(Path(".") / Path(binname))

    c4mfile = tempfile.NamedTemporaryFile()
    c4mfile.write(dict_to_con4m(d).encode('utf-8'))
    c4mfile.flush()
    c4mfilename = c4mfile.name
    try:
        if subprocess.run(["./" + binname, "load", c4mfilename]):
            get_app().push_screen(
                AckModal("""# Warning: Binary Generation Failed
Your configuration has been saved, but no binary has been produced.

Generally, this is one of two issues:
1. Connectivity to the base binary (currently, it should go in ./bin/chalk)
2. You're running on a Mac; we only inject on Linux.  Export the con4m config from the main menu, and on a Linux machine run:
```
chalk load [yourconfig]
```""", pops=2))
            return True
        else:
            get_app().push_screen(AckModal("""# Success!
The configuration has been saved, and your binary written to:
```
%s
```""" % binname, pops=2))
            return True
    except Exception as e:
        get_app().push_screen(AckModal("""## Error
Binary generation failed with the following message:
```
%s
```

Your configuration has been saved, but no binary was produced.""" % repr(e)))
        


        
