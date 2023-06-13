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
import conf_widgets
from css import WIZARD_CSS

__version__ = "0.1"

first_run = False

conftable = ConfigTable()
set_conf_table(conftable)

# Even if I put this in NewApp's __init__ it goes async and AlphaModal errors??
intro_md = MDown(CHALK_CONFIG_INTRO_TEXT, id="intro_md")

def finish_up():
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
          return ERR_EXISTS % confname
        else:
            update = True
            query = ("UPDATE configs SET date=?, CHALK_VERSION=?, id=?, " +
                     "json=?, note=? WHERE name=?")
            row = [timestamp, CHALK_VERSION, internal_id, config,
                   note, confname]
    else:
        idtest = cursor.execute("SELECT name FROM configs WHERE id=?",
                                [internal_id]).fetchone()
        if idtest != None:
            name = idtest[0]
            return ERR_DUPE % idtest[0]
        row = [confname, timestamp, CHALK_VERSION, internal_id, config, note]
        query = "INSERT INTO configs VALUES(?, ?, ?, ?, ?, ?)"

    if write_binary(confname, config, as_dict):
        cursor.execute(query, row)
        db.commit()
        if update:
            # Update by first deleting the existing row.  Then add the change.
            to_delete = -1
            for i in range(len(conf_widgets.row_ids)):
                where      = Coordinate(column = 0, row = i)
                found_name = conftable.the_table.get_cell_at(where)
                if found_name == confname:
                    to_delete = i
                    break
            conftable.the_table.remove_row(conf_widgets.row_ids[to_delete])
            conf_widgets.row_ids = (conf_widgets.row_ids[0:to_delete] +
                                    conf_widgets.row_ids[to_delete+1:])

        conftable.the_table.add_row(confname, timestamp, CHALK_VERSION, note,
                                    key=internal_id)
        conf_widgets.row_ids.append(internal_id)


class ConfWiz(Wizard):
    def load_sections(self):
        self.add_section(sectionBasics)
        self.add_section(sectionOutputConf)
        self.add_section(sectionChalking)
        self.add_section(sectionReporting)
        self.add_section(sectionBinGen)

class ConfWizScreen(ModalScreen):
    DEFAULT_CSS=WIZARD_CSS
    TITLE    = CHALK_TITLE
    BINDINGS = [
        Binding(key="q", action="abort_wizard", description = MAIN_MENU),
        Binding(key="left", action="prev()", description = PREV_LABEL),
        Binding(key="right", action="next()", description = NEXT_LABEL),
        Binding(key="space", action="next()", show=False),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
        Binding(key="h", action="wizard.toggle_class('HelpWindow', '-hidden')",
                description = HELP_TOGGLE),
        Binding(key="ctrl+q", action="quit", description = QUIT_LABEL)
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
        self.wiz.reset()

    def action_abort_wizard(self):
        self.wiz.abort_wizard()

# Convenience vars.

wiz            = ConfWiz(finish_up)
wiz_screen     = ConfWizScreen()
wiz_screen.wiz = wiz


set_wiz_screen(wiz_screen)
set_wizard(wiz)

class NewApp(App):

    DEFAULT_CSS=WIZARD_CSS
    TITLE    = CHALK_TITLE
    SCREENS  = {'confwiz' : wiz_screen }
    BINDINGS = [
        Binding(key = "q", action = "quit()", description = QUIT_LABEL),
        Binding(key = "up", action = "<scroll-up>", show = False),
        Binding(key = "down", action = "<scroll-down>", show = False),
    ]

    def compose(self):
        yield Header(show_clock = True)
        yield intro_md
        yield conftable
        yield Footer()

    def on_mount(self):
        if first_run:
            newbie_modal = AlphaModal(FIRST_TIME_INTRO, button_text = CHEEKY_OK)
            self.push_screen(newbie_modal)

if __name__ == "__main__":
    cached_stdout_fd = sys.stdout
    app = NewApp()
    set_app(app)
    app.run()
