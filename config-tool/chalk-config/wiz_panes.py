# This file has the panes specific to this app, so we can more easily
# reuse the wizard for other things.

from textual.app     import *
from textual.containers import *
from textual.coordinate import *
from textual.widgets import *
from textual.screen import *
from textual.messages import Message
from localized_text import *
from rich.markdown import *
from textual.widgets import Markdown as MDown
from pathlib import *
import sqlite3, os, urllib, tempfile, datetime, hashlib, subprocess, json, stat
from wizard import *
from conf_options import *
from conf_widgets import *
from localized_text import *
# import c0_api

# import pyqrcode
# import requests
from log import get_logger 

logger = get_logger(__name__)

def deal_with_overwrite_widget():
    wiz               = get_wizard()
    switch_row        = wiz.query_one("#switch_row")
    config_name_field = wiz.query_one("#conf_name")
    status            = wiz.query_one("#conf_status")

    show_switch = False

    v = config_name_field.value.strip()
    if v != "":
        arr = cursor.execute("SELECT id from configs where name=?",
                             [v]).fetchone()
        if arr != None:
            old_id = arr[0]
            new_id = dict_to_id(json_to_dict(config_to_json()))

            if old_id != new_id:
                show_switch  = True
                status.update(L_MODIFIED)
            else:
                status.update(L_UNMODIFIED)
        else:
            status.update(L_NEW_CONF)
    else:
        status.update(L_NO_NAME)

    if show_switch:
        switch_row.visible = True
    else:
        wiz.query_one("#overwrite_config").value = False
        switch_row.visible                       = False

# def qr_textualize_render(code, quiet_zone=0):
#     """
#     Quick n dirty renderer for showing QR in a pretty way that works with textualize - defaults don't
#     """
#     buf = io.StringIO()

#     border_row = '██' * (len(code[0]) + (quiet_zone*2))
    
#     #Every QR code start with a quiet zone at the top
#     for b in range(quiet_zone):
#         buf.write(border_row)
#         buf.write('\n')

#     for row in code:

#         #Draw the starting quiet zone
#         for b in range(quiet_zone):
#             buf.write('██')

#         #Actually draw the QR code
#         for bit in row:
#             if bit == 1:
#                 buf.write('  ')
#             elif bit == 0:
#                 buf.write('██')
#             #This is for debugging unfinished QR codes,
#             #unset pixels will be spaces.
#             else:
#                 buf.write(' ')

        
#         #Draw the ending quiet zone
#         for b in range(quiet_zone):
#             buf.write('██')
#         buf.write('\n')

#     #Every QR code ends with a quiet zone at the bottom
#     for b in range(quiet_zone):
#         buf.write(border_row)
#         buf.write('\n')

#     return buf.getvalue()

# class ApiAuth(WizContainer):
#     """
#     """
#     class OAuthSuccess(Message):
#         """
#         """
#         def __init__(self,  oidc_json: str, curr_user_json: str, result: str) -> None:
#             super().__init__()
#             self.oidc_json      = oidc_json
#             self.curr_user_json = curr_user_json
#             self.result         = result
            
#     def __init__(self, *args, **kwargs):
#         super().__init__(*args, **kwargs)
#         ##Setup Auth0 Env now we have been told to poll
#         self.oidc_auth_obj     = c0_api.CLIAuth(c0_api.AUTH0_DOMAIN, c0_api.AUTH0_CLIENT_ID)
#         self.oidc_widget_1     = OidcLinks()
#         self.oidc_widget_1.styles.padding = (0,4)
#         self.oidc_widget_1.styles.margin = (0,2)
#         self.oidc_widget_2     = OidcLinks()
#         self.oidc_widget_2.styles.padding = (1,4)
#         self.oidc_widget_2.styles.margin = (0,2)
#         self.authn_button      = PopBrowserButton(AUTHN_LABEL, variant="warning")
#         self.authn_button.styles.margin = (1,16)
#         self.qr_code_button    = QRButton(QR_LABEL, variant="warning")
#         self.qr_code_button.styles.margin = (0,16)
#         self.token_url         = "https://%s/oauth/token"%(c0_api.AUTH0_DOMAIN)
#         self.tokens_path       = ".chalk_tokens.json" #ToDo save tokens to disk
#         self.oidc_polling      = False
#         self.authenticated     = self.is_authenticated()
#         self.authn_failed      = False

#     def is_authenticated(self):
#         return self.oidc_auth_obj.authenticated
    
#     def has_failed(self):
#         return self.oidc_auth_obj.authn_failed
    
#     def get_id_token_json(self):
#         return self.oidc_auth_obj.id_token_json
    
#     def get_token_json(self):
#         return self.oidc_auth_obj.token_json

#     def oauthstatuscheck(self):
#         """
#         Called once every 5 seconds (via set_interval())
#         Checks if an oauth token check endpoint has generated, if not just returns.
#         If it has it polls the endpoint looking for a HTTP 200 indicating successful 
#         auth along with the json payload of tokens

#         A message is then posted to the parent widget to recieve that will trigger it
#         to auto-advance to the next page in the wizard
#         """
#         if self.is_authenticated() or self.has_failed():
#             return
        
#         ##Poll token endpoint waiting for user to enter the right code
#         token_data = {'grant_type'  : 'urn:ietf:params:oauth:grant-type:device_code',
#                       'device_code' : self.oidc_auth_obj.device_code_json['device_code'],
#                       'client_id'   : self.oidc_auth_obj.auth0_client_id}

#         resp = requests.post(self.token_url, data=token_data)
#         self.oidc_auth_obj.token_json = resp.json()

#         if resp.status_code == 200:
#             #Verify & decode id token
#             verified, id_token_json = self.oidc_auth_obj.oidc_token_validate(self.oidc_auth_obj.token_json["id_token"], decode = True)
#             if not verified:
#                 ##Token verification error - this is bad, login failed - post a message 
#                 self.post_message(self.OAuthSuccess(self.oidc_auth_obj.token_json, None, "id_token_verification_failure"))
#                 self.authn_failed = True
#                 self.oauth_status_checker.stop()
#                 return None
                
#             #Save verified ID token
#             self.oidc_auth_obj.id_token_json = id_token_json

#             ##Setting this value indicates auth'd, causes the watcher to trigger
#             self.oidc_auth_obj.authenticated = True
#             self.oauth_status_checker.stop()

#             ##Post message to be picked up by LoginScreen
#             self.post_message(self.OAuthSuccess(self.oidc_auth_obj.token_json, id_token_json, "success"))
#             return None
            
#         ## Error handling.....
#         elif self.oidc_auth_obj.token_json['error'] not in ('authorization_pending', 'slow_down'):
#             self.authn_failed = True
#             self.oauth_status_checker.stop()
#             self.post_message(self.OAuthSuccess(self.oidc_auth_obj.token_json, None, "authentication_failure"))
#             return None

#         #ToDo Handle slow downs
#         ##We pendin' ..... sleep a bit
            
#     def reset_login_widget(self):
#         """
#         Reset the login widgeet using a newly generated device code
#         """
#         self.oauth_status_checker.stop()
#         self.oidc_polling = False
#         self.authn_failed = False
#         ret = self.start_oidc_polling()


#     def start_oidc_polling(self):
#         """
#         """        
#         ##Call API for device code
#         self.device_code_json = self.oidc_auth_obj.get_device_code()

#         #ToDo
#         if not self.device_code_json:
#             return -1

#         ##Build instructions to include the correct URLs and code
#         self.oidc_widget_1.update("To enable the Chalk binaries built by the Chalk Configuration Tool to send data to your Crash Override account you must authorize it\n\nClick the button to login to Crash Override\n\n")
#         self.oidc_widget_1.refresh()
#         self.oidc_widget_2.update("Or, browse to\n\n1. %s\n\nAlternatively \n\n1. Navigate to: %s\n2. Enter the following code: %s\n\nIf you would like to login from another device, click the button to display a QR code"%(self.device_code_json['verification_uri_complete'], self.device_code_json['verification_uri'], self.device_code_json['user_code']))
#         self.oidc_widget_2.refresh()

#         ##Start background task that polls oauth
#         self.oauth_status_checker = self.set_interval(5 , self.oauthstatuscheck)

#         return 0

#     def compose(self):

#         self.has_entered = False
 
#         yield Center(
#             MDown(LOGIN_LABEL),
#             self.oidc_widget_1,
#             self.authn_button,
#             self.oidc_widget_2,
#             self.qr_code_button,
#         )

#     def doc(self):
#         return "LOGIN HELP HERE TBD"

# class DisplayQrCode(WizContainer):

#     def __init__(self, *args, **kwargs):
#         super().__init__(*args, **kwargs)
#         self.data_to_encode = ""
#         self.qr_widget      = QrCode(id="qrcode")
#         self.url_widget     = Static()
        
        
#     def generate_qr(self, data_to_encode):
#         """
#         """
#         self.data_to_encode = data_to_encode
#         qr = pyqrcode.create(data_to_encode)
#         qr.textualize = qr_textualize_render
#         self.qr_widget.qr_string = qr.textualize(qr.code, quiet_zone=1)
#         self.qr_widget.refresh()

#         self.url_widget = Static( "( %s )"%(self.data_to_encode))
#         self.url_widget.styles.margin = (0,20)

#     def compose(self):
#         yield Container(
#             self.qr_widget,
#             self.url_widget,   ## Add in URL that it represents
#         )

class BuildBinary(WizContainer):
    def compose(self):
        self.has_entered = False
        yield Container(
            MDown(BUILD_BIN_INTRO),
            RadioSet(RadioButton(RELEASE_BUILD, True, id = "release_build"),
                       RadioButton(DEBUG_BUILD, id = "debug_build"),
                     id = "set_bin_debug"),
            Horizontal(Input(placeholder = PLACEHOLD_EXE, id = "exe_name"),
                         Label(L_BIN_NAME, classes="label")),
            Horizontal(Input(placeholder = PLACEHOLD_CONF, id = "conf_name"),
                         Label(L_CONF_NAME, classes = "label")),
            Label(L_NOTE, id="note_label"),
            Input(placeholder=PLACEHOLD_NOTE, id="note"),
            Horizontal(Switch(id="overwrite_config", value=False),
                         Label(L_OVERWRITE, classes="label"),
                       id = "switch_row"),
            MDown("", id = "conf_status"))

    def on_mount(self):
        deal_with_overwrite_widget()

    def on_focus(self):
        deal_with_overwrite_widget()

    def on_descendant_blur(self, event):
        deal_with_overwrite_widget()

    def enter_step(self):
        self.has_entered = True
        deal_with_overwrite_widget()

    def on_descendant_focus(self, event):
        deal_with_overwrite_widget()

    def validate_inputs(self):
        binname = get_wizard().query_one("#exe_name").value.strip()
        confname = get_wizard().query_one("#conf_name").value.strip()

        if binname == "":
            return E_BNAME
        if confname == "":
            return E_CNAME

    def doc(self):
        return BUILD_BIN_DOC

class ChalkOpts(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown(CHALK_OPTS_INTRO)
        yield RadioSet(RadioButton(R_CMIN, value=True, id="chalk_minimal"),
                       RadioButton(R_CMAX, id="chalk_maximal"),
                       id = "set_chalk_min")
        yield ReportingContainer(
            Checkbox(CC_URL, value=True, id="chalk_ptr"),
            Checkbox(CC_DATE, value=True, id="chalk_datetime"),
            Checkbox(CC_EMBED, id="chalk_embeds"),
            Checkbox(CC_REPO, id="chalk_repo"),
            Checkbox(CC_RAND, id="chalk_rand"),
            Checkbox(CC_HOST, id="chalk_build_env"),
            # Commented out since sigmenu hasn't been written yet
            #EnablingCheckbox("sigmenu", CC_SIG, id="chalk_sig", disabled=True),
            Checkbox(CC_SAST, id="chalk_sast"),
            Checkbox(CC_SBOM, id="chalk_sbom"),
            Checkbox(CC_VIRTUAL, id="chalk_virtual")
        )

    def doc(self):
        return CHALK_OPT_DOC

class DockerChalking(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown(DOCKER_LABEL_INTRO)
        yield Horizontal(Input(placeholder=PLACEHOLD_LPREFIX,
                               id = "label_prefix",
                               value= text_defaults["label_prefix"]),
                         Label(L_LPREFIX, classes="label"))
        yield ReportingContainer(
            Checkbox(CL_CID, value=True, id="label_cid"),
            Checkbox(CL_MID, value=True, id="label_mdid"),
            Checkbox(CL_REPO, value=True, id="label_repo"),
            Checkbox(CL_COMMIT, value=True, id="label_commit"),
            Checkbox(CL_BRANCH, value=True, id="label_branch")
        )

    def doc(self):
        return DOCKER_LABEL_DOC

class ReportingOptsChalkTime(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown(REPORTING_INTRO)
        yield RadioSet(RadioButton(R_RMIN, id="crpt_minimal"),
                       RadioButton(R_RMAX, id="crpt_maximal"),
                       id = "set_report_min")
        yield ReportingContainer(
            Checkbox(CR_ERRS, id="crpt_errs"),
            Checkbox(CR_EMBED, id="crpt_embed"),
            Checkbox(CR_BUILD, id="crpt_host"),
            EnablingCheckbox("redaction", CR_REDACT, disabled=True,
                             id="crpt_env"),
            EnablingCheckbox("sig", CR_SIGN, disabled=True, id="crpt_sig"),
            Checkbox(CR_SAST, id="crpt_sast"),
            Checkbox(CR_SBOM, id="crpt_sbom")
        )
    def doc(self):
        return CHALK_REPORT_DOC

class ReportingOptsDocker(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown(DOCKER_REPORTING_INTRO)
        yield ReportingContainer(
            Checkbox(CD_LABELS, id = "drpt_labels"),
            Checkbox(CD_TAGS, id  = "drpt_tags"),
            Checkbox(CD_FILE, id="drpt_dfile"),
            Checkbox(CD_PATH, id="drpt_dfpath"),
            Checkbox(CD_PLAT, id="drpt_platform"),
            Checkbox(CD_ARGS, id="drpt_cmd"),
            Checkbox(CD_CTX, id="drpt_ctx")
        )
    def doc(self):
        return DOCKER_REPORT_DOC

class ReportingExtraction(WizContainer):
    def compose(self):
        self.has_entered = False
        yield MDown(EXTRACT_INTRO)
        yield ReportingContainer(
            Checkbox(CX_ENV, id="xrpt_env"),
            Checkbox(CX_CONTAIN, disabled=True, id="xrpt_containers"),
            Checkbox(CX_MARK, id="xrpt_fullmark")
        )
    def doc(self):
        return EXTRACT_DOC

class LogParams(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield MDown(LOG_PARAMS_INTRO)
        yield Horizontal(Label(L_LOG_LOC, classes="label"),
                         Input(placeholder="/path/to/log/file",
                               id = "log_loc"))
        yield Horizontal(Switch(id="log_truncate"),
                         Label(L_LOG_SIZE, classes="label"))
    def doc(self):
        return LOG_DOC

class CustomEnv(WizContainer):
    # CHALK_POST_URL, CHALK_POST_HEADERS
    # AWS_S3_BUCKET_URI, AWS_ACCESS_SECRET, AWS_ACCESS_ID
    # CHALK_LOG

    def compose(self):
        self.has_entered = False
        yield Container(
            MDown(CUSTOM_ENV_INTRO),
            Horizontal(
                Input(placeholder = PLACEHOLD_ENV, id = "env_log"),
                Label(L_ENV_LOG, classes="label")),
            Horizontal(
                Input(placeholder = PLACEHOLD_ENV, id = "env_post_url"),
                Label(L_ENV_POST, classes="label")),
            Horizontal(
                Input(placeholder = PLACEHOLD_ENV, id = "env_post_hdr"),
                Label(L_ENV_MIME, classes="label")),
            Horizontal(
                Input(placeholder = PLACEHOLD_ENV, id = "env_s3_uri"),
                Label(L_ENV_S3_URI, classes="label")),
            Horizontal(
                Input(placeholder = PLACEHOLD_ENV, id = "env_s3_secret"),
                Label(L_ENV_S3_SEC, classes="label")),
            Horizontal(
                Input(placeholder = PLACEHOLD_ENV, id = "env_s3_aid"),
                Label(L_ENV_S3_ID, classes="label"))
                )
        
    def doc(self):
        return ENV_DOC

class HttpParams(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield MDown(HTTPS_PARAMS_INTRO)
        yield Grid(Label(L_POST_URL, classes="label"),
                         Label(L_POST_HTTPS, classes="label emphLabel"),
                         Input(placeholder = PLACEHOLD_URL, id = "https_url"),
                         Label(L_POST_MIME, classes="label"),
                         Label(""),
                         Input(placeholder = PLACEHOLD_MIME,
                               id = "https_header")
            )
    def validate_inputs(self):
        field = get_wizard().query_one("#https_url")
        url = field.value
        http_start = "http://"
        https_start = "https://"

        if url.startswith(http_start):
            return ERR_HTTP

        if url.startswith(https_start):
            field.value = field.value[len(https_start):]

        if not "." in url:
            return ERR_NO_URL

        return None

    def doc(self):
        return HTTP_PARAMS_DOC

class S3Params(WizContainer):
    def compose(self):
        self.has_entered  = False
        yield MDown(S3_PARAMS_INTRO)
        yield Grid(Label("s3://", classes = "label emphLabel"),
                   Input(placeholder = PLACEHOLD_S3_URI, id = "s3_uri"),
                   Label(L_S3_URI, classes = "label"),
                   Label(""),
                   Input(placeholder = PLACEHOLD_S3_SEC, id = "s3_secret"),
                   Label(L_S3_SEC, classes = "label"),
                   Label(""),
                   Input(placeholder= PLACEHOLD_S3_AID, id = "s3_access_id"),
                   Label(L_S3_AID, classes="label"))

    def validate_inputs(self):
        f1 = get_wizard().query_one("#s3_uri").value.strip()
        f2 = get_wizard().query_one("#s3_access_id").value.strip()
        f3 = get_wizard().query_one("#s3_secret").value.strip()
        s3_start = "s3://"

        if f1.startswith(s3_start):
            get_wizard().query_one("#s3_uri").value = f1[len(s3_start):]

        if f1 == "" or f2 == "" or f3 == "":
            return ERR_ALL_REQUIRED

    def doc(self):
        return S3_PARAMS_DOC

class ReportingPane(WizContainer):
    
    #inline_login_btn = LoginButton(label="Login", classes="basicbutton", id="wiz_login_button")
    def compose(self):
        self.has_entered = False

        yield MDown(REPORTING_PANE_INTRO)
        yield ReportingContainer(
                        Checkbox(CO_CRASH, value=True, id="report_co"),
                        Checkbox(CO_STDOUT, value=True, id="report_stdout"),
                        Checkbox(CO_STDERR, id="report_stderr"),
                        EnablingCheckbox("log_conf", CO_LOG,  id="report_log"),
                        HttpsUrlCheckbox(CO_POST ,id="report_http"),
                        EnablingCheckbox("s3_conf", CO_S3,  id="report_s3"))
        # yield MDown(API_DOC)
        #yield Horizontal(C0ApiToggle(value=True, id="c0api_toggle"),
        #                           Label(L_C0API_USE, classes="label"), 
        #                           self.inline_login_btn)
        yield MDown()
        yield MDown("### Environment Variable Configuration")
        yield MDown(REPORTING_ENV_INTRO)
        yield Horizontal(Switch(value=False, id="env_adds_report"),
                         Label(L_ADD_REPORT, classes="label"))
        yield Horizontal(EnvToggle(value=False, id="env_custom"),
                         Label(L_CUSTOM_ENV, classes="label"))
        
        ##Update login button if user is already logged in
        # if  get_app().authenticated == True:
        #         #user_str = "Hi %s!"%(get_app().current_user_name)
        #         user_str = "Hi %s!"%(get_app().login_widget.oidc_auth_obj.current_user_name)
                
        #         self.inline_login_btn.label = user_str
        #         self.inline_login_btn.variant = "success"
        #         self.inline_login_btn.update(user_str)
        #         self.inline_login_btn.refresh()

    def complete(self):
        return self.has_entered
    def doc(self):
        return OUT_DOC

class UsagePane(WizContainer):
    def enter_step(self):
        self.has_entered = True
    def compose(self):
        yield MDown(USAGE_INTRO)
        yield RadioSet(RadioButton(R_UCMD, id="use_cmd"),
                       RadioButton(R_UDOCKER, id="use_docker"),
                       RadioButton(R_UCICD, id="use_cicd"),
                       RadioButton(R_UEXTRACT, id="use_extract"),
                       id = "set_usage")
        # yield Container(Label("""What platform are we configuring the binary for?"""),
        #                 RadioSet(RadioButton("Linux (x86-64 only)", True, id="lx86"),
        #                          RadioButton("OS X (M1 family)", id="m1"),
        #                          RadioButton("OS X (x86)", id="macosx86")))


    def complete(self):
        try:
            return self.has_entered
        except Exception as e:
            logger.error(e)
            self.has_entered = False
            return False
    def doc(self):
        return """# Usage

If you're not using it as a command-line tool, we will set the default command so that no command need be provided on the command line by default.

For instance, if running as a docker wrapper, this allows you to alias docker to the chalk binary.
"""

sectionBasics     = WizardSection(SB_BASICS)
sectionOutputConf = WizardSection(SB_OUTPUT)
sectionChalking   = WizardSection(SB_CHALK)
sectionReporting  = WizardSection(SB_REPORT)
sectionBinGen     = WizardSection(SB_FINISH)

sectionBasics.add_step("basics", UsagePane())
sectionOutputConf.add_step("reporting", ReportingPane())
sectionOutputConf.add_step("envconf", CustomEnv(disabled=True))
sectionOutputConf.add_step("log_conf", LogParams(disabled=True))
sectionOutputConf.add_step("http_conf", HttpParams(disabled=False))
sectionOutputConf.add_step("s3_conf", S3Params(disabled=True))
sectionChalking.add_step("chalking_base", ChalkOpts())
sectionReporting.add_step("reporting_base", ReportingOptsChalkTime())
sectionReporting.add_step("reporting_docker", ReportingOptsDocker())
sectionChalking.add_step("chalking_docker", DockerChalking())
sectionReporting.add_step("reporting_extract", ReportingExtraction())
sectionBinGen.add_step("final", BuildBinary())
