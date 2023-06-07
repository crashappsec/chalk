WIZARD_CSS = """
* {
    transition: background 500ms in_out_cubic, color 500ms in_out_cubic;
}

Screen {
    layers: base overlay help notifications;
    overflow: hidden;
}

WizardSidebar {
    margin: 2 1;
    width: 20;
    dock: left;
}

Wizard {
    content-align: center middle;
    align: center middle;
}

Body {
    margin: 0 0;
    height: 100%;
    width: 100%;
    overflow-y: scroll;
    align: center top;
}

BuildBinary {
    height: auto;
    content-align: left top;
}

BuildBinary > Container {
}

#conf_status {
    color: $secondary;
}

ReportingContainer {
    height: auto;
    border: solid $primary;
    width: auto;
    padding: 0 2 0 2;
}

.wizpanel {
    height: auto;
    min-height: 100vh;
    align: center top;
    overflow: hidden;
}

.picker {
    margin: 0 4;
    align: center top;
    height: auto;
}

WelcomePane {
    background: $boost;
    max-width: 100;
    min-width: 40;
    border: wide $primary;
    padding: 1 2;
    margin: 1 2;
    box-sizing: border-box;
}

#note_label {
    text-style: underline bold;
}

Switch {
    height: auto;
    width: auto;
    margin: 0 0 0 0;
}

.label {
    height: 3;
    margin: 0 0 0 1;
    content-align: center middle;
    width: auto;
}

RadioSet {
    padding: 0 2 0 2;
    border: solid $primary;
}

Input {
    width: auto;
    min-width: 40;
    margin: 0 0 1 0;
    border: solid $primary;
    color: $secondary;
}

Horizontal {
    height: auto;
    align: left top;
    margin: 0 0 0 4;
}

ExportMenu > RadioSet {
    content-align: center top;
}

RadioSet {
    margin: 0 0 2 4;
}

ReportingContainer {
    margin: 0 0 0 4;
}

#note {
    width: 100%;
    margin: 0 2 0 0;
}

ModalDelete {
    align: center middle;
}

AckModal {
    align: center middle;
}

.ack_md > MarkdownH2 {
    background:  $error;
    width: 100%;
}

ModalError > MarkdownH2 {
    background:  $error;
}

.modal_grid {
    grid-size: 2;
    grid-gutter: 1 2;
    grid-rows: 1fr 3;
    padding: 0 1;
    width: 80;
    height: 11;
    border: thick $background 80%;
    background: $surface;
}

S3Params > Grid {
    grid-size: 3;
    grid-gutter: 1 2;
    grid-columns: 5 46 20;
    padding: 0 1;
    height: 14;
    border: thick $background 80%;
    background: $surface;
    margin: 0 0 0 3;
}

.modal_vertical {
    padding: 0 1;
    width: 60;
    height: 11;
    border: thick $background 80%;
    background: $surface;
}

.model_q {
    align: center top;
}

AckModal > Vertical {
    padding: 0 1;
    width: 60;
    height: auto;
    border: thick $primary 80%;
    background: $surface;
    align: center middle;
    content-align: center middle;
}

AckModal > Vertical > Label {
    width: 1fr;
    content-align: center middle;
}

AckModal > Vertical > Button {
    width: 1fr;
    background: $primary;
    content-align: center middle;
    margin: 0 4;
}

.model_q {
    column-span: 2;
    height: 1fr;
    width: 1fr;
    content-align: center middle;
}

.modal_button {
    width: 100%;
    margin: 0 1;
    background: $primary;
}

.emphLabel {
    color: $primary-lighten-2;
    text-style: bold;
}

S3Params > Horizontal {
    margin: 0 0 0 4;
}

HttpParams > Horizontal {
    margin: 0 0 0 4;
}

Nav {
    dock: bottom;
    max-width: 80;
    max-height: 4;
    margin: 1 2;
    padding: 1 2;
    box-sizing: border-box;
    align: center top;

}

NavButton {
    margin: 1 1;
}

RunWizardButton {
    margin: 0 1;
    background: $primary;
    content-align: center middle;
    align: center middle;
}

.basicbutton {
    margin: 0 1;
    background: $primary;
    content-align: center middle;
    align: center middle;
}

WizSidebarButton {
    background: $secondary-background-darken-3;
    border: hkey $secondary-background-lighten-1;
    color: $text;
    background: $secondary-background;
    text-align: left;
}

WizSidebarButton:hover {
    background: $accent;
    color: $text;
    text-style: bold;
}

HttpParams > Grid {
    grid-size: 3;
    grid-columns: 22 9 50;
    grid-rows: 3;
    margin: 0 0 0 4;
}

Grid > Input {
    margin: 0 0 0 0;
}

HelpWindow {
    background: $surface;
    color: $text;
    height: 80vh;
    dock: right;
    width: 40%;
    layer: help;
    border-left: wide $primary;
    border-top: wide $primary;
    border-bottom: wide $primary;
    transition: offset 400ms in_out_cubic;
    text-align: left;
    align: left top;
    padding: 1 1 1 1;
    overflow-y: scroll;
    content-align: center top;
}

#help_dismiss {
    align: center bottom;
    margin: 0 0 0 4;
}

MarkdownH1 {
    background: $secondary-darken-3;
}

HelpWindow:focus {
    offset: 0 0 !important;
}

HelpWindow.-hidden {
    offset-x: 120%;
}

ConfigName {
    margin: 0 2;
}

ConfigDate {
    width: 24;
    margin: 0 2;
}

ConfigVersion {
    width: 13;
    margin: 0 2;
}

ConfigHdr {
    color: $secondary;
    text-style: bold;
    background: $primary;
}

#the_table {
    width: 100%;
    padding: 0 1;
}

.config_hdr {
    height: 1;
}

ConfigRow {
    width: 100%;
    margin: 0 0;
    content-align: center top;
    align: center top;
    align: left top;
    height: 1;
    box-sizing: content-box;
}

ConfigTable {
    align: center top;
    overflow-y: scroll;
    height: auto;
    width: 100%;
}

Footer {
    layer: notifications;
}

Horizontal.padme {
    margin: 2 0;
    padding: 1 0;
    align: center middle;
    content-align: center middle;
}

ModalError {
    align: center middle;
}

#errmsg {
    margin: 0 1;
}

#errbutt {
    width: 100%;
    margin: 0 1;
    background: $primary;
    align: center middle;
    content-align: center middle;
}

#errcol {
    padding: 0 1;
    width: 60;
    height: 11;
    border: thick $background 80%;
    background: $surface;
}

#errmsg {
    height: 1fr;
    width: 1fr;
    content-align: center middle;
}

#exportview {
    width: 100%;
    content-align: center middle;
}

#export_view {
    width: 100%;
}

#errbutt {
    width: 100%;
    align: center middle;
}

#note_label {
    margin: 2 0 0 4;
}

#note {
    margin: 0 0 0 3;
    width: 90%;
}
"""
