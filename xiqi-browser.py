#!/usr/bin/env python3
import os
import re
import time
import urllib.parse
import urllib.request

os.environ["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
os.environ["WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS"] = "1"
os.environ["LIBGL_ALWAYS_SOFTWARE"] = "1"
os.environ.setdefault("GDK_BACKEND", "x11")

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('WebKit2', '4.1')
from gi.repository import Gtk, Gdk, GLib, WebKit2

DEFAULT_HOME = os.environ.get("XIQI_URL", "http://127.0.0.1:3000").strip() or "http://127.0.0.1:3000"
BASE_URL = DEFAULT_HOME.rstrip("/")

URL_PATTERN = re.compile(
    r'^(https?://\S+|localhost(:\d+)?(/.*)?|xiqios(:\d+)?(/.*)?|[a-z0-9-]+:\d+(/.*)?|[a-z0-9-]+(\.[a-z0-9-]+)+([/:?#].*)?)$',
    re.IGNORECASE,
)


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

        self.is_fullscreen = os.environ.get("XIQI_FULLSCREEN", "1") == "1"

        self.ctx = WebKit2.WebContext.new_ephemeral()
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
        self.url_entry.connect("activate", self.on_url_enter)
        toolbar.pack_start(self.url_entry, True, True, 4)

        btn_new = Gtk.Button(label="+ Nova Aba")
        btn_new.connect("clicked", lambda w: self.add_tab(DEFAULT_HOME, "XIQI OS v1.0"))
        toolbar.pack_start(btn_new, False, False, 0)

        self.notebook = Gtk.Notebook()
        self.notebook.set_scrollable(True)
        self.notebook.connect("switch-page", self.on_switch_page)
        vbox.pack_start(self.notebook, True, True, 0)

        initial_wv = self.add_tab(None, "XIQI OS v1.0")
        self.notebook.set_current_page(0)
        self.show_all()
        if self.is_fullscreen:
            self.fullscreen()

        if initial_wv is not None:
            GLib.idle_add(lambda: self.load_when_ready(initial_wv, DEFAULT_HOME))

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

    def create_configured_webview(self, related=None):
        wv = (
            WebKit2.WebView.new_with_related_view(related)
            if related
            else WebKit2.WebView.new_with_context(self.ctx)
        )
        if hasattr(wv, "set_background_color"):
            wv.set_background_color(Gdk.RGBA(1.0, 1.0, 1.0, 1.0))

        st = wv.get_settings()
        st.set_enable_javascript(True)
        st.set_javascript_can_open_windows_automatically(False)
        st.set_enable_html5_local_storage(True)
        st.set_enable_html5_database(True)
        st.set_enable_webgl(False)
        st.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.NEVER)
        for attr in (
            "set_enable_java",
            "set_enable_plugins",
            "set_allow_file_access_from_file_urls",
            "set_allow_universal_access_from_file_urls",
            "set_enable_developer_extras",
        ):
            if hasattr(st, attr):
                getattr(st, attr)(False)
        st.set_user_agent(
            "XIQI-Browser/1.0 (XIQI OS v1.0; XIQI Core x86_64; Corporacao Engecema)"
        )
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
            if uri and not uri.lower().startswith("about:blank") and not re.match(r'^https?://', uri, re.IGNORECASE):
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
        wv.connect("notify::title", lambda v, p, l: l.set_text(v.get_title()[:24]) if v.get_title() else None, lbl)
        wv.connect("notify::uri", lambda v, p: self.url_entry.set_text(v.get_uri() or "") if v == self.current_webview() else None)
        wv.connect("create", self.on_create_window)
        idx = self.notebook.append_page(wv, tb)
        wv.show()
        self.notebook.set_current_page(idx)
        if url:
            wv.load_uri(url)
        return wv

    def on_create_window(self, webview, navigation_action):
        return self.add_tab(None, "Nova Aba", related=webview)

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
        self.url_entry.set_text(page.get_uri() or "")


if __name__ == "__main__":
    win = XiqiBrowser()
    Gtk.main()
