#!/usr/bin/env python3
import os, urllib.parse
os.environ["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
os.environ["WEBKIT_FORCE_SANDBOX"] = "0"
os.environ["LIBGL_ALWAYS_SOFTWARE"] = "1"
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('WebKit2', '4.1')
from gi.repository import Gtk, WebKit2

class XiqiBrowser(Gtk.Window):
    def __init__(self):
        super().__init__(title="Navegador XIQI OS")
        self.set_default_size(1280, 800)
        self.maximize()
        self.connect("destroy", Gtk.main_quit)
        self.ctx = WebKit2.WebContext.new_ephemeral()
        self.ctx.set_tls_errors_policy(WebKit2.TLSErrorsPolicy.IGNORE)
        cm = self.ctx.get_cookie_manager()
        cm.set_accept_policy(WebKit2.CookieAcceptPolicy.NO_THIRD_PARTY)
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(vbox)
        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        toolbar.set_border_width(4)
        vbox.pack_start(toolbar, False, False, 0)
        for lbl, fn in [("◀ Voltar", lambda w: self.current_webview().go_back()), ("Avançar ▶", lambda w: self.current_webview().go_forward()), ("↻ Recarregar", lambda w: self.current_webview().reload()), ("⌂ Início", lambda w: self.current_webview().load_uri("https://xiqios/"))]:
            b = Gtk.Button(label=lbl)
            b.connect("clicked", fn)
            toolbar.pack_start(b, False, False, 0)
        self.url_entry = Gtk.Entry()
        self.url_entry.set_placeholder_text("Digite o endereço ou pesquise...")
        self.url_entry.connect("activate", self.on_url_enter)
        toolbar.pack_start(self.url_entry, True, True, 4)
        btn_new = Gtk.Button(label="+ Nova Aba")
        btn_new.connect("clicked", lambda w: self.add_tab("https://xiqios/", "XIQI OS"))
        toolbar.pack_start(btn_new, False, False, 0)
        self.notebook = Gtk.Notebook()
        self.notebook.set_scrollable(True)
        self.notebook.connect("switch-page", self.on_switch_page)
        vbox.pack_start(self.notebook, True, True, 0)
        self.add_tab("https://xiqios/", "XIQI OS")
        self.notebook.set_current_page(0)
        self.show_all()

    def current_webview(self):
        return self.notebook.get_nth_page(self.notebook.get_current_page())

    def create_configured_webview(self, related=None):
        wv = WebKit2.WebView.new_with_related_view(related) if related else WebKit2.WebView.new_with_context(self.ctx)
        st = wv.get_settings()
        st.set_enable_javascript(True)
        st.set_javascript_can_open_windows_automatically(True)
        st.set_enable_html5_local_storage(True)
        st.set_enable_html5_database(True)
        st.set_enable_webgl(False)
        st.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.NEVER)
        st.set_user_agent("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        return wv

    def add_tab(self, url=None, title="Nova Aba", related=None):
        if self.notebook.get_n_pages() >= 8 and url:
            self.current_webview().load_uri(url)
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
        return self.add_tab(None, "Autenticando...", related=webview)

    def close_tab(self, btn, wv):
        if self.notebook.get_n_pages() > 1:
            self.notebook.remove_page(self.notebook.page_num(wv))
            wv.destroy()

    def on_url_enter(self, entry):
        t = entry.get_text().strip()
        if not t: return
        url = ("https:" + chr(47)*2 + "xiqios" + chr(47) + "api" + chr(47) + "search?q=" + urllib.parse.quote_plus(t)) if (" " in t or "." not in t) else (t if t.startswith(("http://", "https://")) else "https://" + t)
        self.current_webview().load_uri(url)

    def on_switch_page(self, nb, page, num):
        self.url_entry.set_text(page.get_uri() or "")

if __name__ == "__main__":
    win = XiqiBrowser()
    Gtk.main()
