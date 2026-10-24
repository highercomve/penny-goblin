"""Application-owned controls around the isolated bank page."""
from gi.repository import Gtk

CSS = """
.penny-bank { background: @theme_bg_color; color: @theme_fg_color; }
.penny-bank headerbar { box-shadow: none; }
.penny-bank .bank-heading { font-size: 15px; font-weight: 600; }
.penny-bank .bank-caption { font-size: 12px; color: alpha(@theme_fg_color, .65); }
.penny-bank .bank-steps { padding: 0 16px; border-bottom: 1px solid alpha(@theme_fg_color, .12); }
.penny-bank .bank-step { padding: 12px 4px; font-size: 12px; color: alpha(@theme_fg_color, .55); border-bottom: 3px solid transparent; }
.penny-bank .bank-step.active { color: @theme_fg_color; font-weight: 600; border-bottom-color: #68b184; }
.penny-bank .bank-step.complete { color: #68b184; }
.penny-bank .bank-footer { padding: 16px 20px; border-top: 1px solid alpha(@theme_fg_color, .12); }
.penny-bank .bank-status { font-size: 15px; font-weight: 600; }
.penny-bank .bank-detail { font-size: 13px; color: alpha(@theme_fg_color, .7); }
.penny-bank .bank-footer.error .bank-status { color: @error_color; }
.penny-bank .bank-primary { background: #2d6a4f; color: #fff; border: 0; border-radius: 20px; padding: 8px 20px; min-height: 24px; font-weight: 600; box-shadow: none; }
.penny-bank .bank-primary:hover { background: #24583f; }
.penny-bank .bank-primary:disabled { background: alpha(@theme_fg_color, .1); color: alpha(@theme_fg_color, .4); }
.penny-bank .bank-secondary { background: transparent; border: 0; box-shadow: none; border-radius: 20px; padding: 8px 12px; }
.penny-bank progressbar trough { min-height: 2px; border: 0; border-radius: 0; }
.penny-bank progressbar progress { min-height: 2px; background: #68b184; border: 0; border-radius: 0; }
"""


class BankChrome:
    def __init__(self, window, view, bank="Santander", download=False, file_type="PDF"):
        self.download = download
        window.add_css_class("penny-bank")
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        header = Gtk.HeaderBar()
        heading = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title = Gtk.Label(label=f"{bank} import")
        title.add_css_class("bank-heading")
        caption = Gtk.Label(label="Penny Goblin · Private session")
        caption.add_css_class("bank-caption")
        heading.append(title)
        heading.append(caption)
        header.set_title_widget(heading)
        reload = Gtk.Button(icon_name="view-refresh-symbolic")
        reload.set_tooltip_text("Reload bank page")
        reload.connect("clicked", lambda *_: self.view.reload())
        header.pack_start(reload)
        window.set_titlebar(header)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        steps = Gtk.Box(homogeneous=True, spacing=12)
        steps.add_css_class("bank-steps")
        self.steps = []
        for text in ("1  Sign in", f"2  Download {file_type}" if download else "2  Choose card", "3  Review"):
            label = Gtk.Label(label=text)
            label.add_css_class("bank-step")
            steps.append(label)
            self.steps.append(label)
        box.append(steps)
        self.progress = Gtk.ProgressBar()
        self.progress.set_visible(False)
        box.append(self.progress)
        view.set_vexpand(True)
        self.pages = Gtk.Stack()
        self.pages.set_vexpand(True)
        self.view = view
        self.pages.add_child(view)
        box.append(self.pages)

        self.footer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.footer.add_css_class("bank-footer")
        status = Gtk.Box(spacing=12)
        self.spinner = Gtk.Spinner()
        self.spinner.set_visible(False)
        status.append(self.spinner)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        text.set_hexpand(True)
        self.title = Gtk.Label(xalign=0)
        self.title.add_css_class("bank-status")
        self.detail = Gtk.Label(xalign=0)
        self.detail.add_css_class("bank-detail")
        for label in (self.title, self.detail):
            label.set_wrap(True)
            label.set_max_width_chars(70)
            text.append(label)
        status.append(text)
        self.footer.append(status)
        actions = Gtk.Box(spacing=8)
        self.back = Gtk.Button(label="Back to sign-in")
        self.back.add_css_class("bank-secondary")
        actions.append(self.back)
        spacer = Gtk.Box()
        spacer.set_hexpand(True)
        actions.append(spacer)
        self.primary = Gtk.Button()
        self.primary.add_css_class("bank-primary")
        actions.append(self.primary)
        self.footer.append(actions)
        box.append(self.footer)
        window.set_child(box)
        self.stage = 1
        self.action = "movements"
        self.update(1, f"Sign in to {bank}", "Use your RUT and password on the bank’s page.")

    def update(self, stage, title, detail, *, busy=False, error=False, ready=False):
        self.stage = stage
        self.action = "review" if ready else "retry" if error else "movements"
        self.title.set_text(title)
        self.detail.set_text(detail)
        self.footer.remove_css_class("error")
        if error:
            self.footer.add_css_class("error")
        self.spinner.set_visible(busy)
        self.spinner.set_spinning(busy)
        self.back.set_visible(stage > 1 or error)
        self.primary.set_label("Review movements" if ready else "Try again" if error else "Open card movements")
        self.primary.set_sensitive(not busy)
        self.primary.set_visible(not self.download or ready or error)
        for index, label in enumerate(self.steps, 1):
            label.remove_css_class("active")
            label.remove_css_class("complete")
            if index == stage:
                label.add_css_class("active")
            elif index < stage:
                label.add_css_class("complete")

    def page_progress(self, view):
        if view is not self.view:
            return
        self.progress.set_fraction(view.get_estimated_load_progress())
        self.progress.set_visible(view.is_loading())

    def show_view(self, view):
        if view.get_parent() is None:
            self.pages.add_child(view)
        self.pages.set_visible_child(view)
        self.view = view
