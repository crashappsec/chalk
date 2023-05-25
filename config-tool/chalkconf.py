#!/usr/bin/env python3
# John Viega. john@crashoverride.com

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
from wiz_panes import *
from conf_widgets import row_ids

first_run = False

conftable = ConfigTable()

# Even if I put this in NewApp's __init__ it goes async and AlphaModal errors??
intro_md = MDown(INTRO_TEXT, id="intro_md")

def finish_up():
    print("Finishing up...")
    global row_ids

    config      = config_to_json()
    as_dict     = json_to_dict(config)
    internal_id = dict_to_id(as_dict)
    timestamp   = datetime.datetime.now().ctime()
    confname    = wiz.query_one("#conf_name").value
    slam        = wiz.query_one("#overwrite_config").value
    debug       = wiz.query_one("#debug_build").value
    exe         = wiz.query_one("#exe_name").value
    note        = wiz.query_one("#note").value

    existing = cursor.execute('SELECT id FROM configs WHERE name=?',
                              [confname]).fetchone()
    update = False
    if existing != None:
        if not slam:
          return ("Configuration '" + confname +
                  "' already exists. Please rename, or select " +
                 "the option to replace the existing configuration.")
        else:
            update = True
            query = ("UPDATE configs SET date=?, chalk_version=?, id=?, " +
                     "json=?, note=? WHERE name=?")
            row = [timestamp, chalk_version, internal_id, config,
                   note, confname]
    else:
        idtest = cursor.execute("SELECT name FROM configs WHERE id=?",
                                [internal_id]).fetchone()
        if idtest != None:
            name = idtest[0]
            return ("Did not create the configuration, because the " +
                    "configuration named '" + name +
                    "' is an identical configuration.")
        row = [confname, timestamp, chalk_version, internal_id, config, note]
        query = "INSERT INTO configs VALUES(?, ?, ?, ?, ?, ?)"

    if write_binary(confname, config, as_dict):
        cursor.execute(query, row)
        db.commit()
        if update:
            # Update by first deleting the existing row.  Then add the change.
            to_delete = -1
            for i in range(len(row_ids)):
                where      = Coordinate(column = 0, row = i)
                found_name = conftable.the_table.get_cell_at(where)
                if found_name == confname:
                    to_delete = i
                    break
            conftable.the_table.remove_row(row_ids[to_delete])
            row_ids = row_ids[0:to_delete] + row_ids[to_delete+1:]
            
        conftable.the_table.add_row(confname, timestamp, chalk_version, note,
                                    key=internal_id)
        row_ids.append(internal_id)


class ConfWiz(Wizard):
    def load_sections(self):
        self.add_section(sectionBasics)
        self.add_section(sectionOutputConf)
        self.add_section(sectionChalking)
        self.add_section(sectionReporting)
        self.add_section(sectionBinGen)

class ConfWizScreen(ModalScreen):
    CSS_PATH = "wizard.css"
    TITLE    = CHALK_TITLE
    BINDINGS = [
        Binding(key="q", action="pop_screen()", description="Main Menu"),
        Binding(key="left", action="prev()", description="Previous Screen"),
        Binding(key="right", action="next()", description="Next Screen"),
        Binding(key="space", action="next()", show=False),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
        Binding(key="h", action="wizard.toggle_class('HelpWindow', '-hidden')",
                description="Toggle Help"),
        Binding(key="ctrl+q", action="quit", description="Quit")
    ]

    def compose(self):
        yield Header(show_clock=True)
        yield self.wiz
        yield Footer()

    def action_next(self):
        self.wiz.action_next()

    def action_prev(self):
        self.wiz.action_prev()

    def on_screen_resume(self):
        if not self.wiz.suspend_reset:
            self.wiz.suspend_reset = True
            self.wiz.section_index = 0
            self.wiz.current_panel = self.wiz.first_panel
            self.wiz.set_panel(self.wiz.first_panel)
            
    def on_screen_suspend(self):
       helpwin = self.wiz.query_one("#helpwin")
       
       if helpwin != None and not helpwin.has_class('-hidden'):
           helpwin.toggle_class('-hidden')

wiz            = ConfWiz(finish_up)           
wiz_screen     = ConfWizScreen()
wiz_screen.wiz = wiz

set_wiz_screen(wiz_screen)
set_wizard(wiz)

# This is here because, for some reason, if I yield it directly,
# adding the first-run modal erases the contents, so we have to add
# the text back in during the modal's mounting.  It's easier to have
# the global reference than search for it, esp when we never know when
# our stuff inside funcs is going to be secretly async.

class NewApp(App):

    CSS_PATH = "wizard.css"
    TITLE    = CHALK_TITLE
    SCREENS  = {'confwiz' : wiz_screen }
    BINDINGS = [
        Binding(key="q", action="quit()", description="Quit"),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
    ]

    def compose(self):
        yield Header(show_clock=True)
        yield intro_md
        yield conftable
        yield Footer()

    def on_mount(self):
        if first_run:
            self.push_screen(AlphaModal("""# Chalk Config Tool ALPHA 1: WARNING!
This is an early beta of this configuration tool. Currently, it only works with Linux binaries, and it requires you to have the binaries locally. 

 Specifically, it looks for them under the current working directory, in:
```
bin/chalk
```

Also, some Wizard functionality is not available yet through the wizard (e.g., sending back to Crash Override).

""", button_text="Got it."))

if __name__ == "__main__":
    cached_stdout_fd = sys.stdout
    app = NewApp()
    set_app(app)
    app.run()
