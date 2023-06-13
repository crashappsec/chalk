#!/usr/bin/env python3
# John Viega. john@crashoverride.com
import os
import webbrowser

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

MODULE_LOCATION = os.path.abspath(os.path.dirname(__file__))
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
    def __init__(self,end_callback):
        super().__init__(end_callback)

        ##Define which panel contains the API authn switch
        self.api_authn_panel = self.panels[1]

    def load_sections(self):
        self.add_section(sectionBasics)      #panel 0 - self.first_panel
        self.add_section(sectionOutputConf)  #panel 1 - self.api_authn_panel
        self.add_section(sectionChalking)
        self.add_section(sectionReporting)
        self.add_section(sectionBinGen)
    
    def action_next(self):
        
        ##Hack - this effectively disables the keybinds to the next_button stopping
        ## the user from being able to bypass the disabled button via a keybind if not authenticated
        if not get_app().login_widget.is_authenticated() and self.current_panel == self.api_authn_panel and self.next_button.disabled == True:
            return

        super().action_next()

        ##Disable the next_button until user is authenticated
        if not get_app().login_widget.is_authenticated() and self.current_panel == self.api_authn_panel:
            self.next_button.disabled = True

class ConfWizScreen(ModalScreen):
    DEFAULT_CSS=WIZARD_CSS
    TITLE    = CHALK_TITLE
    BINDINGS = [
        Binding(key="escape", action="abort_wizard", description = MAIN_MENU),
        Binding(key="left", action="prev()", description = PREV_LABEL),
        Binding(key="right", action="next()", description = NEXT_LABEL),
        Binding(key="space", action="next()", show=False),
        Binding(key="up", action="<scroll-up>", show=False),
        Binding(key="down", action="<scroll-down>", show=False),
        Binding(key="h", action="wizard.toggle_class('HelpWindow', '-hidden')",
                description = HELP_TOGGLE),
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

class LoginScreen(ModalScreen):
    """
    Screen to login to Crash ⍉verride API via OIDC
    """
    DEFAULT_CSS=WIZARD_CSS
    TITLE    = LOGIN_TITLE
    BINDINGS = [
        Binding(key="escape", action="abort_wizard", description = MAIN_MENU),
        Binding(key="a", action="open_authn_webpage", description = LOGIN_LABEL),
        Binding(key="q", action="display_qr", description = QR_LABEL),
        Binding(key="ctrl+q", action=None, description = MAIN_MENU, show=False),
        Binding(key="c", action=None, description = MAIN_MENU, show=False),
        Binding(key="l", action=None, description = MAIN_MENU, show=False),
        Binding(key="h", action="wizard.toggle_class('HelpWindow', '-hidden')",
                description = HELP_TOGGLE)
    ]
    AUTO_FOCUS   = None
    login_widget = None

    def on_api_auth_oauth_success(self, event: ApiAuth.OAuthSuccess) -> None:
        """
        """
        my_app = get_app()

        ##Pass message up to app so they can be easily graabbed by any screen etc
        my_app.authenticated  = my_app.login_widget.is_authenticated()
        my_app.id_token_json  = my_app.login_widget.get_id_token_json()
        my_app.curr_user_json = my_app.login_widget.get_token_json()

        ##Update loginbutton on main page button bar to show logged in user
        user_str = "Hi %s!"%(event.curr_user_json["given_name"])
        l_btn = conftable.login_button
        l_btn.label = user_str
        l_btn.variant = "success"
        l_btn.update(user_str)
        l_btn.refresh()
        ##If the login button is hit from main screen the wizard DOM hasn't
        ## been built yet so this fails ....... async DOMs suck
        try:
            ## Update inline login button on wizard page to show logged in user
            wiz_l_btn = wiz.query_one("#wiz_login_button")
            wiz_l_btn.label = user_str
            wiz_l_btn.variant = "success"
            wiz_l_btn.update(user_str)
            wiz_l_btn.refresh()

            ##Ensure wizard's next button is enabled
            wiz.next_button.disabled = False
        except:
            pass

        f=open("/tmp/hhh", "w")
        f.write("%s"%(my_app.login_widget.get_id_token_json()) )
        f.close()

        ##Show the user authentication successful in a pop-up
        pop_user_profile(my_app.login_widget.get_id_token_json(), success_msg=True, pop_off=2)
           
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
        webbrowser.open(self.login_widget.device_code_json['verification_uri_complete'])

    def action_display_qr(self):
        """
        """
        get_app().action_display_qr()

    def action_abort_wizard(self):
        my_app = get_app()
        my_app.pop_screen()

class QrCodeScreen(ModalScreen):
    """
    Screen to display QR Code of OAuth URL
    """
    DEFAULT_CSS=WIZARD_CSS
    BINDINGS = [
        Binding(key="escape", action="complete", description = BACK_LABEL),
        Binding(key="space", action="complete", description = BACK_LABEL, show=False),
        Binding(key="left", action="complete", description = BACK_LABEL, show=False),
        Binding(key="enter", action="complete", description = BACK_LABEL, show=False),
    ]

    qr_code_widget = None
    hdr_widget     = MDown(QR_CODE_TITLE)
    hdr_widget.styles.margin = (0,10)
    hdr_widget.styles.padding = (1,4)
    def compose(self):
        yield self.hdr_widget
        yield self.qr_code_widget
        yield Footer()

    def action_complete(self):
        my_app = get_app()
        my_app.pop_screen()

def pop_user_profile( id_token_json, success_msg = False, pop_off=1):
    """
    Pop up a modal showing the logged in user profile
    """
    ## Progress to next step now authentication has completed
    if success_msg:
        user_profile_data = "%s\n"%LOGIN_SUCCESS
    else:
        user_profile_data = "%s\n"%PROFILE_LABEL

    user_profile_data += """Crash ⍉verride has you...

Follow the white rabbit. Knock, Knock, %s .... 🐇🐇🐇"""%(id_token_json["given_name"])
                                                     
    user_profile_data+="\n### Logged in user profile:\n\n Name: %s\n\n Email: %s (verified = %s)\n\n Auth Expires: %s UTC"%(id_token_json["name"],id_token_json["email"],id_token_json["email_verified"],str(time.asctime(time.gmtime(id_token_json["exp"]))))

    #ToDo - Breaks rendering in Textual right now, will come back to
    #pic = ProfilePicture().generate(get_app().id_token_json["picture"])
    #get_app().push_screen(AckModal(user_profile_data, ascii_art=pic, pops=pop_off))

    get_app().push_screen(AckModal(user_profile_data, pops=pop_off))

# Convenience vars.

##Crash Override API login screen - OIDC
login_widget              = ApiAuth()
login_widget.styles.margin = (0,10)
login_screen              = LoginScreen()
login_screen.login_widget = login_widget

##QR code screen
qr_code_widget                 = DisplayQrCode()
qr_code_widget.styles.margin   = (0,10)
qr_code_widget.styles.padding  = (0,25)
qr_code_screen                 = QrCodeScreen()
qr_code_screen.qr_code_widget  = qr_code_widget

##Main Wizard screen - multiple steps
wiz            = ConfWiz(finish_up)
wiz_screen     = ConfWizScreen()
wiz_screen.wiz = wiz

##Back reference to wizard object in other screens
login_screen.wiz        = wiz

set_wiz_screen(wiz_screen)
set_wizard(wiz)

class NewApp(App):

    DEFAULT_CSS=WIZARD_CSS
    TITLE    = CHALK_TITLE
    SCREENS  = {'confwiz'          : wiz_screen,
                'loginscreen'      : login_screen,
                'qrcodescreen'     : qr_code_screen }
    BINDINGS = [
        Binding(key = "ctrl+q", action = "quit", description = QUIT_LABEL, priority=True),
        Binding(key = "l", action = "login()", description = LOGIN_LABEL),
        Binding(key = "up", action = "<scroll-up>", show = False),
        Binding(key = "down", action = "<scroll-down>", show = False),
        Binding(key = "c", action = "changelog()", description = "View Changelogs" ), #CHANGELOG_LABEL
        #Binding(key="n", action="newconfig()", show = False),
    ]
    use_c0_api     = True
    authenticated  = False
    curr_user_json = {}
    id_token_json  = {}
    config_widget  = wiz
    login_widget   = login_widget
    qr_code_widget = qr_code_widget

    def compose(self):
        yield Header(show_clock = True, id="chalk_header")
        yield intro_md
        yield conftable
        yield Footer()

    def on_mount(self):
        if first_run:
            newbie_modal = AlphaModal(FIRST_TIME_INTRO, button_text = CHEEKY_OK)
            self.push_screen(newbie_modal)

    #def action_newconfig(self):
        #wiz_screen = self.SCREENS["confwiz"]
        #wiz_screen.wiz

        #conftable.next_button.disabled=True
        #conftable.action_next()
        #conftable.app.push_screen('confwiz')
        #load_from_json(default_config_json)

    def action_login(self):
        """
        Initiate the user registration/login process for Crash Override API
        """
        if not self.authenticated:
            #Start background task that polls Auth0 API
            self.login_widget.start_oidc_polling()
            #Display screen in terminal
            conftable.app.push_screen("loginscreen")
        else:
            ##If we are already authentcated just show the user profile of logged in user
            pop_user_profile(self.id_token_json)

    def action_display_qr(self):
        """
        Pop up a screen showing the QR code of the login URL
        """
        self.qr_code_widget.generate_qr(self.login_widget.device_code_json['verification_uri_complete'])
        conftable.app.push_screen("qrcodescreen")
        qr_code_screen.set_focus(None)

    def action_changelog(self):
        """
        Pop up a screen to show the changelogs for both chalk and config-tool
        """
        changelog_data_chalk       = "changelog empty" #Todo localize these
        changelog_data_config_tool = "changelog empty"

        try:
            with open(os.path.join(MODULE_LOCATION,"CHANGELOG.md"), "r") as fo:
                changelog_data_config_tool = fo.read()

            with open(os.path.join("%s"%(os.path.sep).join(MODULE_LOCATION.split(os.path.sep)),"..","..","CHANGELOG.md"), "r") as fo:
                 changelog_data_chalk = fo.read()
            
            self.push_screen(ChangelogModal([changelog_data_chalk, changelog_data_config_tool]))
        except:
            raise

if __name__ == "__main__":
    cached_stdout_fd = sys.stdout
    app = NewApp()
    set_app(app)
    app.run()
