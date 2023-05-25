from textual.app     import *
from textual.containers import *
from textual.coordinate import *
from textual.widgets import *
from textual.screen import *
from localized_text import *
from rich.markdown import *
from textual.widgets import Markdown as MDown

from conf_options import *

class AckModal(ModalScreen):
    CSS_PATH = "wizard.css"

    def __init__(self, msg, pops=1, button_text="Okay"):
        super().__init__()
        self.msg = msg
        self.pops = pops
        self.button_text = button_text

    def compose(self):
        yield Header(show_clock=True)
        yield Vertical (
            MDown(self.msg, id="modalmsg", classes="ack_md"),
            Button(self.button_text, id="acked"),
            )
        yield Footer()

    def on_button_pressed(self):
        while self.pops:
            self.app.pop_screen()
            self.pops = self.pops - 1

class HelpWindow(Container):
    def action_help(self):
        self.wiz.action_help()
    def on_click(self):
        self.toggle_class('-hidden')
    def compose(self):
        yield self.md_widget
        yield Button("Dismiss", classes="basicbutton", id="help_dismiss")
    def update(self, contents):
        self.md_widget.update(contents)
    def on_button_pressed(self):
        self.toggle_class('-hidden')
    
class NavButton(Button):
    def __init__(self, id, wiz, disabled=False):
        Button.__init__(self, label=id, id=id, variant="primary",
                        disabled=disabled)
        self.wiz = wiz
    def on_button_pressed(self):
        self.wiz.action_label(self.id)

class Nav(Horizontal):
    pass

class WizardSidebar(Container):  pass
class Body(ScrollableContainer): pass

class WizSidebarButton(Button):
    def __init__(self, label, wiz):
        super().__init__(label)
        self.disabled = True
        self.wiz      = wiz
    def on_click(self):
        self.wiz.action_section(self.label)
        
# Container object specific to wizard "steps".        
class WizContainer(Container):
    def enter_step(self):
        self.has_entered = True
    def complete(self):
        if not self.has_entered:
            return False
        if self.disabled:
            return True
        return True # Todo: check the text box
    def toggle(self):
        self.disabled = not self.disabled
    def validate_inputs(self):
        return None # No errors to block moving.
    def doc(self):
        return "No help provided."

class WizardStep:
    def __init__(self, name, widget, disabled=False, help=None):
        self.name     = name
        self.widget   = widget
        self.disabled = disabled
        self.help     = help
        widget.id = name
    def enter_step(self):
        return self.widget.enter_step()
    def complete(self):
        return self.widget.complete()

class WizardSection:
    def __init__(self, name):
        self.name       = name
        self.step_dict  = {}
        self.step_order = []
        self.step_index = 0
    def add_step(self, name, widget, disabled=False, help=None):
        new_step = WizardStep(name, widget, disabled, help)
        self.step_dict[name] = new_step
        self.step_order.append(new_step)
    def start_section(self):
        self.step_index = 0
        return self.step_order[0]
    def goto_section_end(self):
        self.step_index = len(self.step_order)
        return self.backwards()
    def advance(self):
        self.step_index_starting = self.step_index
        while True:
            self.step_index += 1
            if self.step_index >= len(self.step_order):
                return None
            step = self.step_order[self.step_index]
            if not step.widget.disabled:
                return step
    def unadvance(self):
        self.step_index = self.step_index_starting
    def backwards(self):
        while True:
            self.step_index -= 1
            if self.step_index < 0:
                return None
            step = self.step_order[self.step_index]
            if not step.widget.disabled:
                return step
    def lookup(self, name):
        if name in self.step_dict:
            return name
        return None
    def complete(self):
        if not len(self.step_order):
            return True
        return self.step_order[-1].widget.complete()

class Wizard(Container):
    def __init__(self, end_callback):
        self.sidebar_buttons = []
        super().__init__()
        self.end_callback = end_callback
        self.sections = []
        self.by_name = {}
        self.section_index = 0
        self.sidebar_contents = []
        self.suspend_reset = False
        self.helpwin = HelpWindow(id="helpwin",
                                  name="Help Window",
                                  classes="-hidden")
        self.helpwin.md_widget = MDown()
        self.helpwin.wiz = self
        self._load_sections()

    def on_mount(self):
        load_from_json(json_txt, name_kludge, note_kludge)

    # Sometimes errors yield weird problems; this version helps avoid them.
    # async def on_mount(self):
    #     while 1:
    #         try:
    #             load_from_json(json_txt)
    #             return
    #         except:
    #             yield

    def add_section(self, s: WizardSection):
        self.sections.append(s)
        self.by_name[s.name] = s
        button = WizSidebarButton(s.name, self)
        self.sidebar_buttons.append(button)
        self.sidebar_contents.append(button)

    def build_panels(self):
        self.panels = []
        for section in self.sections:
            for step in section.step_order:
                self.panels.append(step.widget)
        return ContentSwitcher(*self.panels, initial=self.panels[0].id,
                               classes="wizpanel")

    def _load_sections(self):
        self.load_sections()
        for i in range(len(self.sections)):
            self.by_name[self.sections[i].name] = i
        self.update_menu()

    def compose(self):
        self.switcher = self.build_panels()
        self.current_panel = self.panels[0]
        self.first_panel   = self.current_panel
        self.helpwin.update(self.first_panel.doc())
        yield self.helpwin
        yield WizardSidebar(*self.sidebar_contents)
        self.next_button = NavButton("Next", self)
        self.help_button = NavButton("Help", self)
        self.prev_button = NavButton("Back", self)
        buttons = Nav(self.prev_button, self.next_button, self.help_button)
        self.helpwin.update(self.first_panel.doc())
        body   = Body(self.switcher)
        yield body
        yield buttons

    def set_panel(self, new_panel):
      self.current_panel = new_panel
      self.switcher.current = new_panel.id
      new_panel.enter_step()
      self.helpwin.update(new_panel.doc())
      self.update_menu()

    def action_section(self, label):
        self.section_index = self.by_name[str(label)]
        step = self.sections[self.section_index].start_section()
        self.set_panel(step.widget)

    def action_section_end(self, label):
        self.section_index = self.by_name[str(label)]
        step = self.sections[self.section_index].goto_section_end()
        self.set_panel(step.widget)

    def update_menu(self):
        try:
            self.current_panel
        except:
            self.current_panel = None
            self.first_panel   = None

        if self.current_panel and not self.current_panel.complete():
            self.next_button.disabled = True
        elif self.current_panel:
            self.next_button.disabled = False
        for i in range(len(self.sidebar_buttons)):
            if self.section_index >= i:
                disable = False
            else:
                disable = True
            self.sidebar_buttons[i].disabled = disable

    def action_label(self, id):
        if id == "Help":
            self.action_help()
        elif id == "Next":
            err = self.current_panel.validate_inputs()
            if err:
                self.app.push_screen(AckModal(msg = "## Error\n" + err,
                                              pops = 1))
                return
            return self.action_next()
        else:
            return self.action_prev()

    def run_callback(self):
        cb_results = self.end_callback()
        
        if not cb_results:
            self.section_index = 0
            self.set_panel(self.first_panel)
        else:
            self.section_index -= 1
            self.suspend_reset = True
            self.app.push_screen(AckModal(msg = "## Error: \n" +
                                          cb_results))
            self.sections[self.section_index].unadvance()
        

        
    def action_next(self):
        new_step = self.sections[self.section_index].advance()
        if not new_step:
            self.section_index += 1
            if self.section_index == len(self.sections):
                self.run_callback()
            else:
                self.action_section(str(self.sections[self.section_index].name))
        else:
            self.set_panel(new_step.widget)

    def action_help(self):
        if self.helpwin.has_class("-hidden"):
            self.helpwin.remove_class("-hidden")
        else:
            self.helpwin.add_class("-hidden")

    def action_prev(self):
        if self.current_panel == self.first_panel:
            self.app.pop_screen()
            return
        new_step = self.sections[self.section_index].backwards()
        if not new_step:
            self.section_index -= 1
            name = str(self.sections[self.section_index].name)
            self.action_section_end(name)
        else:
            self.set_panel(new_step.widget)
