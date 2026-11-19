#!/usr/bin/env python3
import os
import re
import subprocess
import time
import urllib.parse
import urllib.request

os.environ["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
os.environ["WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS"] = "1"
os.environ["WEBKIT_FORCE_SANDBOX"] = "0"
os.environ["LIBGL_ALWAYS_SOFTWARE"] = "1"
os.environ["GSK_RENDERER"] = "cairo"
os.environ["GDK_BACKEND"] = "x11"
os.environ["GTK_THEME"] = "Adwaita:light"

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('WebKit2', '4.1')
from gi.repository import Gtk, Gdk, GLib, WebKit2

DEFAULT_HOME = os.environ.get("XIQI_URL", "http://127.0.0.1:3000").strip() or "http://127.0.0.1:3000"
BASE_URL = DEFAULT_HOME.rstrip("/")

MODERN_DESKTOP_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

URL_PATTERN = re.compile(
    r'^(https?://\S+|localhost(:\d+)?(/.*)?|xiqios(\.local)?(:\d+)?(/.*)?|[a-z0-9-]+:\d+(/.*)?|[a-z0-9-]+(\.[a-z0-9-]+)+([/:?#].*)?)$',
    re.IGNORECASE,
)

HOME_URI_PATTERN = re.compile(
    r'^https?://(?:127\.0\.0\.1|127\.0\.0|localhost|xiqios(?:\.local)?)(?::(?:3000|80|443))?(?:/(?:index\.html)?(?:\?)?)?$',
    re.IGNORECASE,
)

LIGHT_CSS = b"""
window, dialog, box, toolbar, notebook, header, stack, scrolledwindow, viewport {
  background-color: #ffffff;
  color: #0f172a;
}
notebook > header, notebook > header > tabs, notebook > header > tabs > tab {
  background-color: #f8fafc;
  color: #0f172a;
}
notebook > header > tabs > tab:checked {
  background-color: #ffffff;
  color: #0f172a;
}
entry {
  background-color: #ffffff;
  color: #0f172a;
  border: 1px solid #cbd5e1;
  border-radius: 6px;
}
button {
  background-image: none;
  background-color: #f8fafc;
  color: #0f172a;
  border: 1px solid #cbd5e1;
  border-radius: 6px;
}
button:hover {
  background-color: #f1f5f9;
}
"""


def apply_keyboard_layout(model="abnt2", layout="br", variant=""):
    cmd = ["setxkbmap", "-model", model, "-layout", layout]
    if variant:
        cmd.extend(["-variant", variant])
    try:
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    except Exception:
        pass


def is_home_uri(uri):
    if not uri:
        return True
    s = str(uri).strip()
    if s in ("", "about:blank"):
        return True
    return bool(HOME_URI_PATTERN.match(s))


def is_server_ready(base_url=BASE_URL, timeout=1.0):
    check_url = base_url.rstrip("/") + "/api/system"
    try:
        with urllib.request.urlopen(check_url, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def wait_for_server(base_url=BASE_URL, max_wait_sec=20.0):
    deadline = time.monotonic() + max_wait_sec
    while time.monotonic() < deadline:
        if is_server_ready(base_url, timeout=0.8):
            return True
        time.sleep(0.5)
    return is_server_ready(base_url, timeout=0.8)


class XiqiBrowser(Gtk.Window):
    def __init__(self):
        super().__init__(title="Navegador XIQI OS v1.0 — Corporação Engecema")
        self.set_default_size(1280, 800)
        self.maximize()
        self.connect("destroy", Gtk.main_quit)
        self.connect("key-press-event", self.on_key_press)
        self.connect("window-state-event", self.on_window_state_event)
        self.connect("visibility-notify-event", self.on_visibility_event)
        self.add_events(Gdk.EventMask.VISIBILITY_NOTIFY_MASK | Gdk.EventMask.STRUCTURE_MASK)

        apply_keyboard_layout("abnt2", "br")
        self.disable_screen_power_timers()

        gtk_settings = Gtk.Settings.get_default()
        if gtk_settings is not None:
            try:
                gtk_settings.set_property("gtk-application-prefer-dark-theme", False)
            except Exception:
                pass
            try:
                gtk_settings.set_property("gtk-theme-name", "Adwaita")
            except Exception:
                pass

        try:
            css_provider = Gtk.CssProvider()
            css_provider.load_from_data(LIGHT_CSS)
            screen = Gdk.Screen.get_default()
            if screen is not None:
                Gtk.StyleContext.add_provider_for_screen(
                    screen, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                )
                screen.connect("size-changed", self.on_screen_changed)
                screen.connect("monitors-changed", self.on_screen_changed)
        except Exception:
            pass

        self.is_fullscreen = os.environ.get("XIQI_FULLSCREEN", "1") == "1"
        self.is_iconified = False

        self.ctx = self._build_web_context()
        cm = self.ctx.get_cookie_manager()
        cm.set_accept_policy(WebKit2.CookieAcceptPolicy.ALWAYS)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(vbox)

        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        toolbar.set_border_width(4)
        vbox.pack_start(toolbar, False, False, 0)

        for lbl, fn in [
            ("◀ Voltar", lambda w: self.safe_nav("go_back")),
            ("Avançar ▶", lambda w: self.safe_nav("go_forward")),
            ("↻ Recarregar", lambda w: self.safe_nav("reload")),
            ("⌂ Início", lambda w: self.safe_load(DEFAULT_HOME)),
        ]:
            b = Gtk.Button(label=lbl)
            b.connect("clicked", fn)
            toolbar.pack_start(b, False, False, 0)

        self.url_entry = Gtk.Entry()
        self.url_entry.set_placeholder_text("Pesquisar ou digitar endereço URL...")
        self.url_entry.connect("activate", self.on_url_enter)
        toolbar.pack_start(self.url_entry, True, True, 4)

        btn_new = Gtk.Button(label="+ Nova Aba")
        btn_new.connect("clicked", lambda w: self.add_tab(DEFAULT_HOME, "XIQI OS v1.0"))
        toolbar.pack_start(btn_new, False, False, 0)

        btn_kbd = Gtk.Button(label="⌨ ABNT2")
        btn_kbd.set_tooltip_text("Configurar layout de teclado (Alt+Shift+K)")
        btn_kbd.connect("clicked", lambda w: self.open_keyboard_dialog())
        toolbar.pack_start(btn_kbd, False, False, 0)

        btn_min = Gtk.Button(label="_")
        btn_min.set_tooltip_text("Minimizar janela para alternar janelas")
        btn_min.connect("clicked", lambda w: self.minimize_window())
        toolbar.pack_start(btn_min, False, False, 0)

        self.notebook = Gtk.Notebook()
        self.notebook.set_scrollable(True)
        self.notebook.connect("switch-page", self.on_switch_page)
        vbox.pack_start(self.notebook, True, True, 0)

        initial_wv = self.add_tab(None, "XIQI OS v1.0")
        self.notebook.set_current_page(0)
        self.url_entry.set_text("")
        self.show_all()
        if self.is_fullscreen:
            self.fullscreen()

        if initial_wv is not None:
            GLib.idle_add(lambda: self.load_when_ready(initial_wv, DEFAULT_HOME))
        GLib.timeout_add_seconds(60, self.keep_display_alive)

    def disable_screen_power_timers(self):
        for args in (
            ["xset", "s", "off"],
            ["xset", "-dpms"],
            ["xset", "s", "noblank"],
            ["xset", "s", "0", "0"],
        ):
            try:
                subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
            except Exception:
                pass

    def keep_display_alive(self):
        self.disable_screen_power_timers()
        if not self.is_iconified:
            wv = self.current_webview()
            if wv is not None:
                wv.queue_draw()
            self.queue_draw()
        return True

    def on_window_state_event(self, widget, event):
        self.is_iconified = bool(event.new_window_state & Gdk.WindowState.ICONIFIED)
        return False

    def on_visibility_event(self, widget, event):
        if not self.is_iconified and event.state == Gdk.VisibilityState.UNOBSCURED:
            wv = self.current_webview()
            if wv is not None:
                wv.queue_draw()
        return False

    def on_screen_changed(self, _screen):
        self.disable_screen_power_timers()
        try:
            subprocess.run(["xrandr", "--auto"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        except Exception:
            pass
        if not self.is_iconified:
            if self.is_fullscreen:
                self.fullscreen()
            self.present()
            wv = self.current_webview()
            if wv is not None:
                wv.queue_draw()
            self.queue_draw()

    def _build_web_context(self):
        base_data = os.path.join(os.path.expanduser("~"), ".local", "share", "xiqi-browser")
        base_cache = os.path.join(os.path.expanduser("~"), ".cache", "xiqi-browser")
        try:
            os.makedirs(base_data, mode=0o700, exist_ok=True)
            os.makedirs(base_cache, mode=0o700, exist_ok=True)
            os.chmod(base_data, 0o700)
            os.chmod(base_cache, 0o700)
            data_mgr = WebKit2.WebsiteDataManager(
                base_data_directory=base_data,
                base_cache_directory=base_cache,
            )
            ctx = WebKit2.WebContext.new_with_website_data_manager(data_mgr)
            cm = ctx.get_cookie_manager()
            cm.set_persistent_storage(
                os.path.join(base_data, "cookies.sqlite"),
                WebKit2.CookiePersistentStorage.SQLITE,
            )
            return ctx
        except Exception:
            return WebKit2.WebContext.new_ephemeral()

    def minimize_window(self):
        if self.is_fullscreen:
            self.unfullscreen()
            self.is_fullscreen = False
        self.iconify()

    def open_keyboard_dialog(self):
        dlg = Gtk.Dialog(
            title="Configuração de Teclado — XIQI OS",
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL,
        )
        dlg.set_default_size(380, 180)
        box = dlg.get_content_area()
        box.set_border_width(14)
        box.set_spacing(10)

        lbl = Gtk.Label(label="Selecione o mapa de teclado do sistema:")
        lbl.set_xalign(0)
        box.pack_start(lbl, False, False, 0)

        combo = Gtk.ComboBoxText()
        layouts = [
            ("abnt2|br|", "Português (Brasil — ABNT2 Padrão)"),
            ("abnt2|br|nodeadkeys", "Português (Brasil — ABNT2 Sem Teclas Mortas)"),
            ("pc105|us|intl", "Inglês (EUA Internacional com Acentos)"),
            ("pc105|us|", "Inglês (EUA Padrão)"),
        ]
        for key, label in layouts:
            combo.append(key, label)
        combo.set_active(0)
        box.pack_start(combo, False, False, 0)

        status_lbl = Gtk.Label(label="")
        status_lbl.set_xalign(0)
        box.pack_start(status_lbl, False, False, 0)

        btn_apply = dlg.add_button("Aplicar", Gtk.ResponseType.OK)
        dlg.add_button("Fechar", Gtk.ResponseType.CLOSE)

        def on_resp(_d, resp_id):
            if resp_id == Gtk.ResponseType.OK:
                active_id = combo.get_active_id() or "abnt2|br|"
                model, layout, variant = active_id.split("|")
                apply_keyboard_layout(model, layout, variant)
                status_lbl.set_text("Layout aplicado: " + (combo.get_active_text() or layout))
                return
            dlg.destroy()

        dlg.connect("response", on_resp)
        dlg.show_all()
        btn_apply.grab_focus()

    def load_when_ready(self, webview, uri):
        if is_server_ready(BASE_URL, timeout=0.35):
            webview.load_uri(uri)
            return False
        GLib.timeout_add(200, lambda: self.load_when_ready(webview, uri))
        return False

    def on_key_press(self, widget, event):
        if event.keyval == Gdk.KEY_F11:
            if self.is_fullscreen:
                self.unfullscreen()
                self.is_fullscreen = False
            else:
                self.fullscreen()
                self.is_fullscreen = True
            return True
        if (
            (event.state & Gdk.ModifierType.MOD1_MASK)
            and (event.state & Gdk.ModifierType.SHIFT_MASK)
            and event.keyval in (Gdk.KEY_k, Gdk.KEY_K)
        ):
            self.open_keyboard_dialog()
            return True
        return False

    def current_webview(self):
        idx = self.notebook.get_current_page()
        if idx < 0:
            return None
        return self.notebook.get_nth_page(idx)

    def safe_nav(self, method_name):
        wv = self.current_webview()
        if wv is not None:
            getattr(wv, method_name)()

    def safe_load(self, uri):
        wv = self.current_webview()
        if wv is not None and isinstance(uri, str) and re.match(r'^https?://', uri, re.IGNORECASE):
            wv.load_uri(uri)

    def update_address_bar(self, uri):
        if is_home_uri(uri):
            self.url_entry.set_text("")
        else:
            self.url_entry.set_text(uri or "")

    def create_configured_webview(self, related=None):
        ucm = WebKit2.UserContentManager()
        try:
            light_style = WebKit2.UserStyleSheet(
                ":root { color-scheme: light only !important; }",
                WebKit2.UserContentInjectedFrames.ALL_FRAMES,
                WebKit2.UserStyleLevel.USER,
                None,
                None,
            )
            ucm.add_style_sheet(light_style)
        except Exception:
            pass

        if related is not None:
            wv = WebKit2.WebView.new_with_related_view(related)
        else:
            try:
                wv = WebKit2.WebView(web_context=self.ctx, user_content_manager=ucm)
            except Exception:
                wv = WebKit2.WebView.new_with_context(self.ctx)

        if hasattr(wv, "set_background_color"):
            wv.set_background_color(Gdk.RGBA(1.0, 1.0, 1.0, 1.0))

        st = wv.get_settings()
        st.set_enable_javascript(True)
        st.set_javascript_can_open_windows_automatically(True)
        st.set_enable_html5_local_storage(True)
        st.set_enable_html5_database(True)
        st.set_enable_webgl(False)
        st.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.NEVER)
        for attr, val in (
            ("set_allow_modal_dialogs", True),
            ("set_javascript_can_access_clipboard", True),
            ("set_enable_page_cache", True),
            ("set_enable_smooth_scrolling", True),
            ("set_enable_site_specific_quirks", True),
            ("set_enable_java", False),
            ("set_enable_plugins", False),
            ("set_enable_hyperlink_auditing", False),
            ("set_enable_dns_prefetching", False),
            ("set_allow_file_access_from_file_urls", False),
            ("set_allow_universal_access_from_file_urls", False),
            ("set_enable_developer_extras", False),
        ):
            if hasattr(st, attr):
                try:
                    getattr(st, attr)(val)
                except Exception:
                    pass
        st.set_user_agent(MODERN_DESKTOP_UA)
        wv.connect("decide-policy", self.on_decide_policy)
        wv.connect("load-failed", self.on_load_failed)
        wv.connect("web-process-terminated", self.on_web_process_terminated)
        return wv

    def on_decide_policy(self, webview, decision, decision_type):
        if decision_type in (
            WebKit2.PolicyDecisionType.NAVIGATION_ACTION,
            WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION,
        ):
            nav = decision.get_navigation_action()
            req = nav.get_request() if nav else None
            uri = req.get_uri() if req else ""
            if uri and not re.match(r'^(https?://|about:blank$|blob:)', uri, re.IGNORECASE):
                decision.ignore()
                return True
        return False

    def on_load_failed(self, webview, load_event, failing_uri, error):
        target = failing_uri if (isinstance(failing_uri, str) and failing_uri.startswith(("http://127.0.0.1", "http://localhost"))) else DEFAULT_HOME
        if isinstance(failing_uri, str) and (failing_uri.startswith("http://127.0.0.1") or failing_uri.startswith("http://localhost")):
            GLib.timeout_add(1000, lambda: self.retry_load(webview, target))
            return True
        return False

    def retry_load(self, webview, uri):
        if is_server_ready(BASE_URL, timeout=0.6):
            webview.load_uri(uri)
            return False
        GLib.timeout_add(500, lambda: self.retry_load(webview, uri))
        return False

    def on_web_process_terminated(self, webview, reason):
        GLib.timeout_add(500, lambda: self.retry_load(webview, DEFAULT_HOME))

    def add_tab(self, url=None, title="Nova Aba", related=None):
        if self.notebook.get_n_pages() >= 12 and url:
            self.safe_load(url)
            return None
        wv = self.create_configured_webview(related)
        tb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        lbl = Gtk.Label(label=title)
        bc = Gtk.Button(label="✕")
        bc.set_relief(Gtk.ReliefStyle.NONE)
        bc.connect("clicked", self.close_tab, wv)
        tb.pack_start(lbl, True, True, 0)
        tb.pack_start(bc, False, False, 0)
        tb.show_all()
        wv.connect("notify::title", lambda v, p, l: l.set_text((v.get_title() or "Nova Aba")[:24]), lbl)
        wv.connect("notify::uri", lambda v, p: self.update_address_bar(v.get_uri() or "") if v == self.current_webview() else None)
        wv.connect("create", self.on_create_window)
        idx = self.notebook.append_page(wv, tb)
        wv.show()
        self.notebook.set_current_page(idx)
        if url:
            wv.load_uri(url)
        else:
            self.update_address_bar("")
        return wv

    def on_create_window(self, webview, navigation_action):
        req = navigation_action.get_request() if navigation_action else None
        uri = req.get_uri() if req else None
        new_wv = self.add_tab(None, "Nova Aba", related=webview)
        if new_wv is not None and uri and re.match(r'^https?://', uri, re.IGNORECASE):
            GLib.idle_add(lambda: new_wv.load_uri(uri) and False)
        return new_wv

    def close_tab(self, btn, wv):
        if self.notebook.get_n_pages() > 1:
            self.notebook.remove_page(self.notebook.page_num(wv))
            wv.destroy()

    def on_url_enter(self, entry):
        t = entry.get_text().strip()
        if not t:
            return
        if re.match(r'^(javascript|data|vbscript|file):', t, re.IGNORECASE):
            return
        if " " not in t and URL_PATTERN.match(t):
            if t.startswith(("http://", "https://")):
                url = t
            elif re.match(r'^(localhost|127\.0\.0\.1|10\.|192\.168\.|[a-z0-9-]+:\d+)', t, re.IGNORECASE):
                url = "http://" + t
            else:
                url = "https://" + t
        else:
            url = BASE_URL + "/api/search?engine=xiqi&q=" + urllib.parse.quote_plus(t)
        self.safe_load(url)

    def on_switch_page(self, nb, page, num):
        self.update_address_bar(page.get_uri() or "")


if __name__ == "__main__":
    win = XiqiBrowser()
    Gtk.main()

