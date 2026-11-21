#!/usr/bin/env python3
import json
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

DEFAULT_HOME = os.environ.get("XIQI_URL", "http://127.0.0.1").strip() or "http://127.0.0.1"
DEFAULT_HOME = re.sub(r'/admin(?:[/?#].*)?$', '', DEFAULT_HOME, flags=re.IGNORECASE)
BASE_URL = DEFAULT_HOME.rstrip("/")

MODERN_DESKTOP_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

URL_PATTERN = re.compile(
    r'^(https?://\S+|localhost(:\d+)?([/?#]\S*)?|xiqios(\.local)?(:\d+)?([/?#]\S*)?|[a-z0-9-]+:\d+([/?#]\S*)?|[^\s./]+(\.[^\s./]+)+([:/?#]\S*)?)$',
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
.xiqi-taskbar-win {
  background-color: #ffffff;
  border-top: 1px solid #cbd5e1;
}
.xiqi-restore-btn {
  background-color: #2563eb;
  color: #ffffff;
  border: 1px solid #1d4ed8;
  border-radius: 6px;
  font-weight: 600;
  padding: 4px 10px;
}
.xiqi-restore-btn:hover {
  background-color: #1d4ed8;
}
.xiqi-pin-add {
  background-color: #eff6ff;
  color: #1d4ed8;
  border: 1px solid #bfdbfe;
  border-radius: 6px;
  font-weight: 600;
  padding: 4px 10px;
}
.xiqi-pin-add:hover {
  background-color: #dbeafe;
}
.xiqi-pin-chip {
  background-color: #f8fafc;
  border: 1px solid #cbd5e1;
  border-radius: 6px;
  padding: 0 2px;
}
.xiqi-pin-open {
  background-color: transparent;
  border: none;
  color: #0f172a;
  font-weight: 500;
  padding: 3px 6px;
}
.xiqi-pin-open:hover {
  background-color: #e2e8f0;
}
.xiqi-pin-del {
  background-color: transparent;
  border: none;
  color: #64748b;
  padding: 2px 5px;
}
.xiqi-pin-del:hover {
  background-color: #fee2e2;
  color: #dc2626;
}
.xiqi-task-done label {
  color: #64748b;
}
.xiqi-clock-time {
  font-size: 13px;
  font-weight: 700;
  color: #0f172a;
}
.xiqi-clock-date {
  font-size: 11px;
  font-weight: 500;
  color: #475569;
}
.xiqi-dots-btn {
  background-color: #f8fafc;
  border: 1px solid #cbd5e1;
  border-radius: 8px;
  padding: 4px 6px;
}
.xiqi-dots-btn:hover {
  background-color: #eff6ff;
  border-color: #bfdbfe;
}
.xiqi-dots-menu {
  background-color: #ffffff;
  border: 1px solid #cbd5e1;
  border-radius: 10px;
}
.xiqi-win-ctrl {
  min-width: 30px;
  padding: 2px 8px;
  font-weight: 600;
}
.xiqi-win-close:hover {
  background-color: #fee2e2;
  border-color: #fecaca;
  color: #dc2626;
}
.xiqi-addr-wrap {
  background-color: #ffffff;
  border: 1px solid #cbd5e1;
  border-radius: 9999px;
  padding: 1px 4px 1px 10px;
}
.xiqi-addr-entry, .xiqi-addr-entry:focus {
  border: none;
  box-shadow: none;
  background-color: transparent;
}
.xiqi-addr-ai-btn {
  background-color: #f8fafc;
  color: #475569;
  border: 1px solid #e2e8f0;
  border-radius: 9999px;
  padding: 2px 10px;
  font-size: 12px;
  font-weight: 600;
}
.xiqi-addr-ai-btn:hover {
  background-color: #eff6ff;
  border-color: #bfdbfe;
  color: #1d4ed8;
}
.xiqi-addr-ai-active {
  background-color: #eff6ff;
  border-color: #bfdbfe;
  color: #2563eb;
}
"""

TASKBAR_APPS = [
    ("ai", "✨", "Modo IA"),
    ("notes", "📝", "Notas"),
    ("calc", "🧮", "Cálculo"),
    ("term", ">_", "Terminal"),
    ("files", "📁", "Arquivos"),
    ("sys", "🖥️", "Sistema"),
    ("cal", "📅", "Data"),
    ("settings", "⚙️", "Configurações"),
]
APP_ICON_MAP = {aid: ico for aid, ico, _ in TASKBAR_APPS}
APP_ICON_MAP.setdefault("about", "⚙️")
PT_BR_WEEKDAYS = ("seg.", "ter.", "qua.", "qui.", "sex.", "sáb.", "dom.")


def format_clock_text():
    lt = time.localtime()
    hhmm = time.strftime("%H:%M", lt)
    wd = PT_BR_WEEKDAYS[lt.tm_wday] if 0 <= lt.tm_wday < 7 else ""
    date_str = f"{wd}, {lt.tm_mday:02d}/{lt.tm_mon:02d}/{lt.tm_year:04d}".strip(", ")
    return hhmm, date_str


def normalize_http_url(raw_url):
    s = str(raw_url or "").strip()
    if not s:
        return ""
    if s.startswith("://"):
        s = "https://" + s.lstrip(":/")
    if re.match(r'^(javascript|data|vbscript|file):', s, re.IGNORECASE):
        return ""
    if not re.match(r'^https?://', s, re.IGNORECASE):
        if re.match(r'^(?:localhost(?::\d+)?|127\.0\.0\.1(?::\d+)?|10\.\d+\.\d+\.\d+(?::\d+)?|192\.168\.\d+\.\d+(?::\d+)?|[a-z0-9-]+:\d+)(?:[/:?#]|$)', s, re.IGNORECASE):
            s = "http://" + s
        else:
            s = "https://" + s
    try:
        parsed = urllib.parse.urlparse(s)
        if parsed.scheme.lower() in ("http", "https") and parsed.netloc:
            return s[:2000]
    except Exception:
        pass
    return ""


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


class XiqiRestoreBar(Gtk.Window):
    def __init__(self, browser):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.browser = browser
        self.set_title("XIQI OS — Barra de Tarefas")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()
        self.get_style_context().add_class("xiqi-taskbar-win")

        self.user_token = ""
        self.last_session = None
        self.cache_path = os.path.join(os.path.expanduser("~"), ".config", "xiqi-taskbar-cache.json")
        self.pins = self._default_pins()
        self.dots_popup = None

        outer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        outer.set_margin_start(10)
        outer.set_margin_end(12)
        outer.set_margin_top(6)
        outer.set_margin_bottom(6)
        self.add(outer)

        self.dots_btn = Gtk.Button()
        self.dots_btn.get_style_context().add_class("xiqi-dots-btn")
        self.dots_btn.set_tooltip_text("Menu Rápido XIQI OS")
        dots_icon = Gtk.DrawingArea()
        dots_icon.set_size_request(20, 20)
        dots_icon.connect("draw", self._draw_four_dots)
        self.dots_btn.add(dots_icon)
        self.dots_btn.connect("clicked", lambda _w: self.toggle_dots_menu())
        outer.pack_start(self.dots_btn, False, False, 0)

        self.restore_btn = Gtk.Button(label="🖥 Restaurar XIQI OS")
        self.restore_btn.get_style_context().add_class("xiqi-restore-btn")
        self.restore_btn.set_tooltip_text("Clique para restaurar o navegador XIQI OS")
        self.restore_btn.connect("clicked", lambda _w: self.browser.restore_from_minimize())
        outer.pack_start(self.restore_btn, False, False, 0)

        self.add_pin_btn = Gtk.Button(label="+ Fixar")
        self.add_pin_btn.get_style_context().add_class("xiqi-pin-add")
        self.add_pin_btn.set_tooltip_text("Fixar aplicativo, tarefa ou site na barra")
        self.add_pin_btn.connect("clicked", lambda _w: self.open_pin_dialog())
        outer.pack_start(self.add_pin_btn, False, False, 0)

        self.pins_scroll = Gtk.ScrolledWindow()
        self.pins_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        self.pins_scroll.set_shadow_type(Gtk.ShadowType.NONE)
        self.pins_scroll.set_hexpand(True)
        self.pins_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.pins_scroll.add(self.pins_box)
        outer.pack_start(self.pins_scroll, True, True, 0)

        clock_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        clock_box.set_valign(Gtk.Align.CENTER)
        hhmm, date_str = format_clock_text()
        self.clock_time_lbl = Gtk.Label(label=hhmm)
        self.clock_time_lbl.get_style_context().add_class("xiqi-clock-time")
        self.clock_time_lbl.set_xalign(1.0)
        self.clock_date_lbl = Gtk.Label(label=date_str)
        self.clock_date_lbl.get_style_context().add_class("xiqi-clock-date")
        self.clock_date_lbl.set_xalign(1.0)
        clock_box.pack_start(self.clock_time_lbl, False, False, 0)
        clock_box.pack_start(self.clock_date_lbl, False, False, 0)
        outer.pack_end(clock_box, False, False, 2)

        GLib.timeout_add_seconds(15, self._refresh_clock)

    def _draw_four_dots(self, _widget, cr):
        import math
        dots = (
            (5.5, 5.5, 0.145, 0.388, 0.922),
            (14.5, 5.5, 0.086, 0.639, 0.290),
            (5.5, 14.5, 0.086, 0.639, 0.290),
            (14.5, 14.5, 0.145, 0.388, 0.922),
        )
        for cx, cy, r, g, b in dots:
            cr.set_source_rgb(r, g, b)
            cr.arc(cx, cy, 2.8, 0, 2 * math.pi)
            cr.fill()
        return False

    def hide_dots_menu(self):
        if self.dots_popup is not None:
            try:
                self.dots_popup.destroy()
            except Exception:
                pass
            self.dots_popup = None

    def toggle_dots_menu(self):
        if self.dots_popup is not None and self.dots_popup.get_visible():
            self.hide_dots_menu()
            return
        self.hide_dots_menu()

        pop = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        pop.set_decorated(False)
        pop.set_resizable(False)
        pop.set_keep_above(True)
        pop.set_skip_taskbar_hint(True)
        pop.set_skip_pager_hint(True)
        pop.set_transient_for(self)
        pop.get_style_context().add_class("xiqi-dots-menu")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_border_width(12)
        pop.add(box)

        hdr = Gtk.Label(label="XIQI OS — Acesso Rápido")
        hdr.set_xalign(0)
        box.pack_start(hdr, False, False, 0)

        grid = Gtk.Grid()
        grid.set_row_spacing(6)
        grid.set_column_spacing(6)
        grid.set_column_homogeneous(True)

        menu_apps = [
            ("search", "🔍 Pesquisa"),
            ("notes", "📝 Notas"),
            ("term", ">_ Terminal / Software"),
            ("ai", "✨ Modo IA"),
            ("calc", "🧮 Cálculo"),
            ("files", "📁 Arquivos"),
            ("cal", "📅 Data"),
            ("sys", "🖥️ Sistema"),
            ("settings", "⚙️ Configurações"),
        ]

        def on_app_click(_b, aid):
            self.hide_dots_menu()
            if aid == "search":
                self.browser.restore_and_go_home(focus_search=True)
            elif aid == "settings":
                self.browser.restore_and_open_settings()
            else:
                self.browser.restore_and_launch_app(aid)

        for idx, (aid, lbl) in enumerate(menu_apps):
            btn = Gtk.Button(label=lbl)
            btn.connect("clicked", on_app_click, aid)
            grid.attach(btn, idx % 3, idx // 3, 1, 1)
        box.pack_start(grid, False, False, 0)

        sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        box.pack_start(sep, False, False, 2)

        sys_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        for action, label in (
            ("update", "↻ Atualizar"),
            ("reboot", "⟳ Reiniciar"),
            ("shutdown", "⏻ Desligar"),
        ):
            sb = Gtk.Button(label=label)
            if action == "shutdown":
                sb.get_style_context().add_class("xiqi-win-close")
            sb.connect("clicked", self._on_dots_system_action, action)
            sys_row.pack_start(sb, True, True, 0)
        box.pack_start(sys_row, False, False, 0)

        pop.connect("focus-out-event", lambda _w, _e: self.hide_dots_menu())
        pop.connect("key-press-event", lambda _w, ev: self.hide_dots_menu() if ev.keyval == Gdk.KEY_Escape else False)

        pop.show_all()
        try:
            display = Gdk.Display.get_default()
            monitor = display.get_primary_monitor() if display else None
            if monitor is not None:
                geom = monitor.get_geometry()
                sh, sx, sy = geom.height, geom.x, geom.y
            else:
                screen = Gdk.Screen.get_default()
                sh = screen.get_height() if screen else 768
                sx, sy = 0, 0
            alloc = pop.get_allocation()
            mh = max(alloc.height, 220)
            pop.move(sx + 10, sy + max(0, sh - 50 - mh - 8))
        except Exception:
            pass
        pop.present()
        self.dots_popup = pop

    def _on_dots_system_action(self, _btn, action):
        self.hide_dots_menu()
        titles = {
            "update": ("Atualizar Sistema — XIQI OS", "Executar a atualização oficial do XIQI OS e reiniciar o ambiente?"),
            "reboot": ("Reiniciar Computador", "Confirma a reinicialização imediata do computador?"),
            "shutdown": ("Desligar Computador", "Confirma o desligamento imediato do computador?"),
        }
        title, text = titles.get(action, ("Sistema", "Confirmar ação?"))
        dlg = Gtk.MessageDialog(
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text=title,
        )
        dlg.format_secondary_text(text)
        resp = dlg.run()
        dlg.destroy()
        if resp != Gtk.ResponseType.YES:
            return
        try:
            req = urllib.request.Request(
                f"{BASE_URL}/api/system/{action}",
                data=b"{}",
                headers={"Content-Type": "application/json", "X-Xiqi-Action": "1"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=8.0) as _r:
                pass
        except Exception:
            pass

    def _default_pins(self):
        return [
            {"id": "pin-ai", "kind": "app", "appId": "ai", "name": "Modo IA"},
            {"id": "pin-notes", "kind": "app", "appId": "notes", "name": "Notas"},
            {"id": "pin-calc", "kind": "app", "appId": "calc", "name": "Cálculo"},
        ]

    def set_user_token(self, token):
        self.user_token = str(token or "").strip()

    def _api_headers(self, json_body=False):
        headers = {}
        if json_body:
            headers["Content-Type"] = "application/json"
        if self.user_token:
            headers["x-user-token"] = self.user_token
        return headers

    def _read_cache(self):
        try:
            with open(self.cache_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
                if isinstance(data, list):
                    return data
        except Exception:
            pass
        return None

    def _write_cache(self, pins):
        try:
            os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
            with open(self.cache_path, "w", encoding="utf-8") as fh:
                json.dump(pins, fh, ensure_ascii=False)
        except Exception:
            pass

    def load_pins(self):
        loaded = None
        try:
            req = urllib.request.Request(BASE_URL + "/api/store", headers=self._api_headers())
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                if resp.status == 200:
                    payload = json.loads(resp.read().decode("utf-8"))
                    sess = payload.get("session")
                    if isinstance(sess, dict):
                        self.last_session = sess
                        raw_pins = sess.get("taskbarPins")
                        if isinstance(raw_pins, list):
                            loaded = raw_pins
        except Exception:
            pass
        if loaded is None:
            cached = self._read_cache()
            loaded = cached if isinstance(cached, list) else self._default_pins()
        else:
            self._write_cache(loaded)
        self.pins = loaded
        return self.pins

    def save_pins(self):
        self._write_cache(self.pins)
        sess = dict(self.last_session) if isinstance(self.last_session, dict) else {}
        sess["taskbarPins"] = self.pins
        self.last_session = sess
        try:
            body = json.dumps({"session": sess}).encode("utf-8")
            req = urllib.request.Request(
                BASE_URL + "/api/store",
                data=body,
                headers=self._api_headers(json_body=True),
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=1.5) as _resp:
                pass
        except Exception:
            pass

    def refresh_pins(self):
        self.load_pins()
        self.render_pins()

    def render_pins(self):
        for child in list(self.pins_box.get_children()):
            self.pins_box.remove(child)
            child.destroy()

        for pin in self.pins:
            if not isinstance(pin, dict):
                continue
            kind = pin.get("kind", "app")
            name = str(pin.get("name", "")).strip()
            if not name:
                continue
            done = bool(pin.get("done", False))
            if kind == "app":
                icon = APP_ICON_MAP.get(pin.get("appId", ""), "🧩")
            elif kind == "task":
                icon = "✅" if done else "☑"
            else:
                icon = "🌐"

            chip = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
            chip.get_style_context().add_class("xiqi-pin-chip")
            if kind == "task" and done:
                chip.get_style_context().add_class("xiqi-task-done")

            open_btn = Gtk.Button(label=f"{icon} {name[:26]}")
            open_btn.get_style_context().add_class("xiqi-pin-open")
            open_btn.set_relief(Gtk.ReliefStyle.NONE)
            open_btn.set_tooltip_text(str(pin.get("url") or name))
            open_btn.connect("clicked", self._on_pin_clicked, pin)

            del_btn = Gtk.Button(label="×")
            del_btn.get_style_context().add_class("xiqi-pin-del")
            del_btn.set_relief(Gtk.ReliefStyle.NONE)
            del_btn.set_tooltip_text("Remover da barra de tarefas")
            del_btn.connect("clicked", self._on_pin_remove, pin.get("id"))

            chip.pack_start(open_btn, False, False, 0)
            chip.pack_start(del_btn, False, False, 0)
            self.pins_box.pack_start(chip, False, False, 0)

        self.pins_box.show_all()

    def _on_pin_clicked(self, _btn, pin):
        kind = pin.get("kind", "app")
        if kind == "app":
            self.browser.restore_and_launch_app(pin.get("appId", ""))
        elif kind == "site":
            url = normalize_http_url(pin.get("url", ""))
            if url:
                self.browser.restore_and_open_url(url)
        else:
            self.open_task_detail_dialog(pin)

    def _on_pin_remove(self, _btn, pin_id):
        self.pins = [p for p in self.pins if p.get("id") != pin_id]
        self.save_pins()
        self.render_pins()

    def open_task_detail_dialog(self, pin):
        dlg = Gtk.Dialog(
            title="Tarefa Fixada — XIQI OS",
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL,
        )
        dlg.set_default_size(380, 170)
        area = dlg.get_content_area()
        area.set_border_width(14)
        area.set_spacing(10)

        title_lbl = Gtk.Label(label=str(pin.get("name", "Tarefa")))
        title_lbl.set_xalign(0)
        title_lbl.set_line_wrap(True)
        area.pack_start(title_lbl, False, False, 0)

        done = bool(pin.get("done", False))
        status_lbl = Gtk.Label(label="Status: Concluída" if done else "Status: Pendente")
        status_lbl.set_xalign(0)
        area.pack_start(status_lbl, False, False, 0)

        opt_url = normalize_http_url(pin.get("url", ""))
        if opt_url:
            url_lbl = Gtk.Label(label="Link: " + opt_url)
            url_lbl.set_xalign(0)
            url_lbl.set_line_wrap(True)
            area.pack_start(url_lbl, False, False, 0)

        dlg.add_button("Reabrir Tarefa" if done else "Concluir Tarefa", 1)
        if opt_url:
            dlg.add_button("Abrir Link", 2)
        dlg.add_button("Remover", 3)
        dlg.add_button("Fechar", Gtk.ResponseType.CLOSE)

        def on_resp(d, resp_id):
            if resp_id == 1:
                for p in self.pins:
                    if p.get("id") == pin.get("id"):
                        p["done"] = not bool(p.get("done", False))
                self.save_pins()
                self.render_pins()
            elif resp_id == 2 and opt_url:
                d.destroy()
                self.browser.restore_and_open_url(opt_url)
                return
            elif resp_id == 3:
                self.pins = [p for p in self.pins if p.get("id") != pin.get("id")]
                self.save_pins()
                self.render_pins()
            d.destroy()

        dlg.connect("response", on_resp)
        dlg.show_all()

    def open_pin_dialog(self):
        dlg = Gtk.Dialog(
            title="Fixar na Barra de Tarefas — XIQI OS",
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL,
        )
        dlg.set_default_size(460, 420)
        area = dlg.get_content_area()
        area.set_border_width(14)
        area.set_spacing(10)

        apps_hdr = Gtk.Label(label="Aplicativos do XIQI OS (clique para fixar ou remover):")
        apps_hdr.set_xalign(0)
        area.pack_start(apps_hdr, False, False, 0)

        apps_grid = Gtk.Grid()
        apps_grid.set_row_spacing(6)
        apps_grid.set_column_spacing(6)
        apps_grid.set_column_homogeneous(True)

        def rebuild_apps_grid():
            for ch in list(apps_grid.get_children()):
                apps_grid.remove(ch)
                ch.destroy()
            pinned_ids = {p.get("appId") for p in self.pins if p.get("kind") == "app"}
            for idx, (aid, ico, label) in enumerate(TASKBAR_APPS):
                is_pinned = aid in pinned_ids
                btn = Gtk.Button(label=f"{ico} {label} {'✓' if is_pinned else '+'}")
                btn.connect("clicked", lambda _b, app_id=aid, app_name=label, active=is_pinned: toggle_app(app_id, app_name, active))
                apps_grid.attach(btn, idx % 2, idx // 2, 1, 1)
            apps_grid.show_all()

        def toggle_app(app_id, app_name, active):
            if active:
                self.pins = [p for p in self.pins if not (p.get("kind") == "app" and p.get("appId") == app_id)]
            else:
                self.pins.append({"id": f"pin-{app_id}-{int(time.time() * 1000)}", "kind": "app", "appId": app_id, "name": app_name})
            self.save_pins()
            self.render_pins()
            rebuild_apps_grid()

        rebuild_apps_grid()
        area.pack_start(apps_grid, False, False, 0)

        sep1 = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        area.pack_start(sep1, False, False, 4)

        site_hdr = Gtk.Label(label="Fixar Site de Interesse:")
        site_hdr.set_xalign(0)
        area.pack_start(site_hdr, False, False, 0)

        site_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        site_name_entry = Gtk.Entry()
        site_name_entry.set_placeholder_text("Nome do site")
        site_url_entry = Gtk.Entry()
        site_url_entry.set_placeholder_text("https://...")
        site_add_btn = Gtk.Button(label="Fixar Site")
        site_box.pack_start(site_name_entry, True, True, 0)
        site_box.pack_start(site_url_entry, True, True, 0)
        site_box.pack_start(site_add_btn, False, False, 0)
        area.pack_start(site_box, False, False, 0)

        sep2 = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        area.pack_start(sep2, False, False, 4)

        task_hdr = Gtk.Label(label="Fixar Tarefa Rápida:")
        task_hdr.set_xalign(0)
        area.pack_start(task_hdr, False, False, 0)

        task_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        task_name_entry = Gtk.Entry()
        task_name_entry.set_placeholder_text("Nome da tarefa")
        task_url_entry = Gtk.Entry()
        task_url_entry.set_placeholder_text("Link opcional (https://...)")
        task_add_btn = Gtk.Button(label="Fixar Tarefa")
        task_box.pack_start(task_name_entry, True, True, 0)
        task_box.pack_start(task_url_entry, True, True, 0)
        task_box.pack_start(task_add_btn, False, False, 0)
        area.pack_start(task_box, False, False, 0)

        err_lbl = Gtk.Label(label="")
        err_lbl.set_xalign(0)
        area.pack_start(err_lbl, False, False, 0)

        def on_add_site(_b):
            name = site_name_entry.get_text().strip()[:60]
            url = normalize_http_url(site_url_entry.get_text())
            if not name or not url:
                err_lbl.set_text("Informe nome e URL válidos para o site.")
                return
            self.pins.append({"id": f"pin-site-{int(time.time() * 1000)}", "kind": "site", "name": name, "url": url})
            self.save_pins()
            self.render_pins()
            site_name_entry.set_text("")
            site_url_entry.set_text("")
            err_lbl.set_text("Site fixado na barra de tarefas.")

        def on_add_task(_b):
            name = task_name_entry.get_text().strip()[:60]
            raw_url = task_url_entry.get_text().strip()
            if not name:
                err_lbl.set_text("Informe o nome da tarefa.")
                return
            opt_url = ""
            if raw_url:
                opt_url = normalize_http_url(raw_url)
                if not opt_url:
                    err_lbl.set_text("Link opcional inválido para a tarefa.")
                    return
            self.pins.append({"id": f"pin-task-{int(time.time() * 1000)}", "kind": "task", "name": name, "url": opt_url, "done": False})
            self.save_pins()
            self.render_pins()
            task_name_entry.set_text("")
            task_url_entry.set_text("")
            err_lbl.set_text("Tarefa fixada na barra de tarefas.")

        site_add_btn.connect("clicked", on_add_site)
        task_add_btn.connect("clicked", on_add_task)

        dlg.add_button("Fechar", Gtk.ResponseType.CLOSE)
        dlg.connect("response", lambda d, _r: d.destroy())
        dlg.show_all()

    def _refresh_clock(self):
        try:
            hhmm, date_str = format_clock_text()
            self.clock_time_lbl.set_text(hhmm)
            self.clock_date_lbl.set_text(date_str)
        except Exception:
            pass
        return True

    def position_bottom_bar(self):
        try:
            display = Gdk.Display.get_default()
            monitor = display.get_primary_monitor() if display else None
            if monitor is not None:
                geom = monitor.get_geometry()
                sw, sh, sx, sy = geom.width, geom.height, geom.x, geom.y
            else:
                screen = Gdk.Screen.get_default()
                sw = screen.get_width() if screen else 1024
                sh = screen.get_height() if screen else 768
                sx, sy = 0, 0
            bar_h = 50
            self.set_size_request(sw, bar_h)
            self.resize(sw, bar_h)
            self.move(sx, sy + max(0, sh - bar_h))
        except Exception:
            pass


class XiqiBrowser(Gtk.Window):
    def __init__(self):
        super().__init__(title="Navegador XIQI OS v1.0")
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
        self.was_fullscreen_before_min = self.is_fullscreen
        self.is_adjusted_window = False
        self.is_iconified = False
        self.external_retries = {}
        self.restore_bar = XiqiRestoreBar(self)

        self.ctx = self._build_web_context()
        cm = self.ctx.get_cookie_manager()
        cm.set_accept_policy(WebKit2.CookieAcceptPolicy.ALWAYS)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(vbox)

        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        toolbar.set_border_width(4)
        vbox.pack_start(toolbar, False, False, 0)

        for lbl, tip, fn in [
            ("◀", "Voltar", lambda w: self.safe_nav("go_back")),
            ("▶", "Avançar", lambda w: self.safe_nav("go_forward")),
            ("↻", "Recarregar página", lambda w: self.safe_nav("reload")),
            ("⌂", "Página inicial do XIQI OS", lambda w: self.safe_load(DEFAULT_HOME)),
        ]:
            b = Gtk.Button(label=lbl)
            b.set_tooltip_text(tip)
            b.connect("clicked", fn)
            toolbar.pack_start(b, False, False, 0)

        addr_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        addr_box.get_style_context().add_class("xiqi-addr-wrap")
        self.url_entry = Gtk.Entry()
        self.url_entry.set_has_frame(False)
        self.url_entry.get_style_context().add_class("xiqi-addr-entry")
        self.url_entry.set_placeholder_text("Pesquisar ou digitar endereço URL...")
        self.url_entry.connect("activate", self.on_url_enter)
        addr_box.pack_start(self.url_entry, True, True, 0)

        self.btn_addr_ai = Gtk.Button(label="✨ Modo IA")
        self.btn_addr_ai.get_style_context().add_class("xiqi-addr-ai-btn")
        self.btn_addr_ai.set_tooltip_text("Ativar Modo IA dentro da aba de endereços")
        self.btn_addr_ai.connect("clicked", lambda w: self.toggle_addr_ai_mode())
        addr_box.pack_start(self.btn_addr_ai, False, False, 0)
        toolbar.pack_start(addr_box, True, True, 4)

        btn_new = Gtk.Button(label="+ Aba")
        btn_new.set_tooltip_text("Abrir nova aba")
        btn_new.connect("clicked", lambda w: self.add_tab(DEFAULT_HOME, "XIQI OS v1.0"))
        toolbar.pack_start(btn_new, False, False, 0)

        btn_ext = Gtk.Button(label="🧩 Extensões")
        btn_ext.set_tooltip_text("Gerenciar extensões do navegador")
        btn_ext.connect("clicked", lambda w: self.open_inpage_helper("xiqiOpenExtensions"))
        toolbar.pack_start(btn_ext, False, False, 0)

        btn_pref = Gtk.Button(label="🎛 Preferências")
        btn_pref.set_tooltip_text("Preferências de navegação e pesquisa")
        btn_pref.connect("clicked", lambda w: self.open_inpage_helper("xiqiOpenPreferences"))
        toolbar.pack_start(btn_pref, False, False, 0)

        btn_cfg = Gtk.Button(label="⚙ Config.")
        btn_cfg.set_tooltip_text("Configurações do XIQI OS")
        btn_cfg.connect("clicked", lambda w: self.open_inpage_helper("xiqiOpenSettings"))
        toolbar.pack_start(btn_cfg, False, False, 0)

        btn_kbd = Gtk.Button(label="⌨ ABNT2")
        btn_kbd.set_tooltip_text("Configurar layout de teclado (Alt+Shift+K)")
        btn_kbd.connect("clicked", lambda w: self.open_keyboard_dialog())
        toolbar.pack_start(btn_kbd, False, False, 0)

        win_ctrl_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)
        btn_min = Gtk.Button(label="_")
        btn_min.get_style_context().add_class("xiqi-win-ctrl")
        btn_min.set_tooltip_text("Minimizar janela (restaurável com 1 clique na barra inferior)")
        btn_min.connect("clicked", lambda w: self.minimize_window())

        self.btn_resize = Gtk.Button(label="❐")
        self.btn_resize.get_style_context().add_class("xiqi-win-ctrl")
        self.btn_resize.set_tooltip_text("Ajustar / Restaurar tamanho da janela")
        self.btn_resize.connect("clicked", lambda w: self.toggle_window_size())

        btn_close = Gtk.Button(label="✕")
        btn_close.get_style_context().add_class("xiqi-win-ctrl")
        btn_close.get_style_context().add_class("xiqi-win-close")
        btn_close.set_tooltip_text("Fechar página ou aba atual com segurança")
        btn_close.connect("clicked", lambda w: self.safe_close_current())

        win_ctrl_box.pack_start(btn_min, False, False, 0)
        win_ctrl_box.pack_start(self.btn_resize, False, False, 0)
        win_ctrl_box.pack_start(btn_close, False, False, 0)
        toolbar.pack_end(win_ctrl_box, False, False, 2)

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

    def _find_home_webview(self):
        for idx in range(self.notebook.get_n_pages()):
            wv = self.notebook.get_nth_page(idx)
            if wv is not None and is_home_uri(wv.get_uri()):
                return idx, wv
        return -1, None

    def _sync_token_from_home(self):
        _idx, home_wv = self._find_home_webview()
        if home_wv is None:
            self.restore_bar.set_user_token("")
            return
        try:
            def on_js_done(wv, res, _data):
                tok = ""
                try:
                    js_res = wv.run_javascript_finish(res)
                    val = js_res.get_js_value() if js_res else None
                    if val is not None and val.is_string():
                        tok = val.to_string() or ""
                except Exception:
                    tok = ""
                self.restore_bar.set_user_token(tok)
                self.restore_bar.refresh_pins()

            home_wv.run_javascript("sessionStorage.getItem('xiqi_user_token') || ''", None, on_js_done, None)
        except Exception:
            pass

    def show_restore_bar(self):
        try:
            subprocess.run(["xsetroot", "-solid", "#f1f5f9"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
        except Exception:
            pass
        self.restore_bar._refresh_clock()
        self.restore_bar.refresh_pins()
        self.restore_bar.show_all()
        self.restore_bar.position_bottom_bar()
        self.restore_bar.present()
        self._sync_token_from_home()

    def hide_restore_bar(self):
        try:
            self.restore_bar.hide_dots_menu()
            self.restore_bar.hide()
        except Exception:
            pass

    def _apply_adjusted_window_geometry(self):
        try:
            display = Gdk.Display.get_default()
            monitor = display.get_primary_monitor() if display else None
            if monitor is not None:
                geom = monitor.get_geometry()
                sw, sh, sx, sy = geom.width, geom.height, geom.x, geom.y
            else:
                screen = Gdk.Screen.get_default()
                sw = screen.get_width() if screen else 1280
                sh = screen.get_height() if screen else 800
                sx, sy = 0, 0
            w = min(1140, max(820, int(sw * 0.84)))
            h = min(720, max(540, int(sh * 0.82)))
            self.resize(w, h)
            self.move(sx + max(0, (sw - w) // 2), sy + max(0, (sh - h) // 2))
        except Exception:
            self.resize(1060, 680)

    def toggle_window_size(self):
        if not self.is_adjusted_window:
            self.is_adjusted_window = True
            if self.is_fullscreen:
                self.unfullscreen()
                self.is_fullscreen = False
            self.unmaximize()
            GLib.idle_add(self._apply_adjusted_window_geometry)
            if hasattr(self, "btn_resize"):
                self.btn_resize.set_tooltip_text("Maximizar / Tela Cheia")
        else:
            self.is_adjusted_window = False
            self.maximize()
            if os.environ.get("XIQI_FULLSCREEN", "1") == "1":
                self.fullscreen()
                self.is_fullscreen = True
            if hasattr(self, "btn_resize"):
                self.btn_resize.set_tooltip_text("Ajustar / Restaurar tamanho da janela")

    def safe_close_current(self):
        if self.notebook.get_n_pages() > 1:
            wv = self.current_webview()
            if wv is not None:
                self.close_tab(None, wv)
            return
        wv = self.current_webview()
        if wv is not None:
            uri = wv.get_uri() or ""
            if not is_home_uri(uri):
                wv.load_uri(DEFAULT_HOME)
                return
            try:
                wv.run_javascript("if (window.xiqiCloseTopOverlay) window.xiqiCloseTopOverlay();", None, None, None)
            except Exception:
                pass

    def restore_from_minimize(self):
        self.hide_restore_bar()
        self.deiconify()
        self.show()
        if self.is_adjusted_window:
            self.unfullscreen()
            self.unmaximize()
            self.is_fullscreen = False
            GLib.idle_add(self._apply_adjusted_window_geometry)
        elif self.was_fullscreen_before_min:
            self.fullscreen()
            self.is_fullscreen = True
        else:
            self.maximize()
        self.present()
        _idx, home_wv = self._find_home_webview()
        if home_wv is not None:
            try:
                home_wv.run_javascript("if (window.xiqiRefreshStore) window.xiqiRefreshStore();", None, None, None)
            except Exception:
                pass

    def restore_and_go_home(self, focus_search=True):
        self.restore_from_minimize()
        js_code = "setTimeout(function(){var b=document.getElementById('backToHomeBtn');if(b)b.click();" + ("var s=document.getElementById('searchInput');if(s){s.focus();}" if focus_search else "") + "},100);"
        idx, home_wv = self._find_home_webview()
        if home_wv is not None and idx >= 0:
            self.notebook.set_current_page(idx)
            try:
                home_wv.run_javascript(js_code, None, None, None)
            except Exception:
                pass
            return
        self.add_tab(DEFAULT_HOME, "XIQI OS v1.0")

    def restore_and_open_url(self, url):
        safe_url = normalize_http_url(url)
        self.restore_from_minimize()
        if not safe_url:
            return
        self.add_tab(safe_url, "Carregando...")

    def _run_on_home(self, js_code):
        idx, home_wv = self._find_home_webview()
        if home_wv is not None and idx >= 0:
            self.notebook.set_current_page(idx)
            try:
                home_wv.run_javascript(js_code, None, None, None)
            except Exception:
                pass
            return
        new_wv = self.add_tab(DEFAULT_HOME, "XIQI OS v1.0")
        if new_wv is not None:
            def on_home_loaded(wv, load_event):
                if load_event == WebKit2.LoadEvent.FINISHED:
                    try:
                        wv.disconnect_by_func(on_home_loaded)
                    except Exception:
                        pass
                    try:
                        wv.run_javascript(js_code, None, None, None)
                    except Exception:
                        pass
            new_wv.connect("load-changed", on_home_loaded)

    def open_inpage_helper(self, fn_name):
        safe_fn = re.sub(r'[^a-zA-Z0-9_]', '', str(fn_name or ''))
        if not safe_fn:
            return
        self._run_on_home(f"setTimeout(function(){{if(window.{safe_fn})window.{safe_fn}();}},100);")

    def restore_and_open_settings(self):
        self.restore_from_minimize()
        self.open_inpage_helper("xiqiOpenSettings")

    def toggle_addr_ai_mode(self):
        q = self.url_entry.get_text().strip()
        if q and not is_home_uri(q):
            js = (
                "setTimeout(function(){"
                "var b=document.getElementById('topAddrAiBtn');"
                "if(b&&b.getAttribute('aria-pressed')!=='true')b.click();"
                "var i=document.getElementById('topAddressInput')||document.getElementById('searchInput');"
                "if(i){i.value=" + json.dumps(q) + ";i.focus();}"
                "},120);"
            )
            self._run_on_home(js)
        else:
            self._run_on_home("setTimeout(function(){var b=document.getElementById('topAddrAiBtn')||document.getElementById('aiModeToggleBtn');if(b)b.click();},100);")

    def restore_and_launch_app(self, app_id):
        self.restore_from_minimize()
        if app_id == "settings":
            self.open_inpage_helper("xiqiOpenSettings")
            return
        if app_id not in APP_ICON_MAP:
            return
        if app_id == "about":
            js_code = (
                "setTimeout(function(){"
                "var wn=document.getElementById('xiqiWin'),wt=document.getElementById('xiqiWT'),wb=document.getElementById('xiqiWB');"
                "if(wn&&wt&&wb){wt.textContent='Sobre o Sistema';wb.textContent='XIQI OS v1.0 — Núcleo XIQI Core x86_64';wn.style.display='flex';}"
                "},120);"
            )
        else:
            js_code = (
                "setTimeout(function(){var el=document.querySelector('.xapp[data-a="
                + json.dumps(str(app_id))
                + "]');if(el)el.click();},120);"
            )
        self._run_on_home(js_code)

    def on_window_state_event(self, widget, event):
        iconified = bool(event.new_window_state & Gdk.WindowState.ICONIFIED)
        self.is_iconified = iconified
        if iconified:
            self.show_restore_bar()
        else:
            self.hide_restore_bar()
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
        if self.is_iconified:
            self.restore_bar.position_bottom_bar()
        else:
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
            cm.set_accept_policy(WebKit2.CookieAcceptPolicy.ALWAYS)
            cm.set_persistent_storage(
                os.path.join(base_data, "cookies.sqlite"),
                WebKit2.CookiePersistentStorage.SQLITE,
            )
            return ctx
        except Exception:
            return WebKit2.WebContext.new_ephemeral()

    def minimize_window(self):
        self.was_fullscreen_before_min = self.is_fullscreen
        if self.is_fullscreen:
            self.unfullscreen()
            self.is_fullscreen = False
        self.show_restore_bar()
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
        if is_server_ready(BASE_URL, timeout=0.2):
            webview.load_uri(uri)
            return False
        GLib.timeout_add(100, lambda: self.load_when_ready(webview, uri))
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

    def on_window_action_message(self, _ucm, js_result):
        try:
            val = js_result.get_js_value() if hasattr(js_result, "get_js_value") else None
            act = val.to_string() if val is not None and val.is_string() else ""
        except Exception:
            act = ""
        if act == "minimize":
            self.minimize_window()
        elif act == "toggle_size":
            self.toggle_window_size()
        elif act == "close":
            self.safe_close_current()

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
        try:
            native_script = WebKit2.UserScript(
                "window.__XIQI_NATIVE_BROWSER__ = true;",
                WebKit2.UserContentInjectedFrames.TOP_FRAME,
                WebKit2.UserScriptInjectionTime.START,
                None,
                None,
            )
            ucm.add_script(native_script)
            ucm.register_script_message_handler("xiqiWindowAction")
            ucm.connect("script-message-received::xiqiWindowAction", self.on_window_action_message)
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
        st.set_enable_webgl(True)
        st.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.ON_DEMAND)
        for attr, val in (
            ("set_enable_accelerated_2d_canvas", True),
            ("set_enable_javascript_markup", True),
            ("set_enable_mediasource", True),
            ("set_allow_modal_dialogs", True),
            ("set_javascript_can_access_clipboard", True),
            ("set_enable_page_cache", True),
            ("set_enable_smooth_scrolling", True),
            ("set_enable_site_specific_quirks", True),
            ("set_enable_java", False),
            ("set_enable_plugins", False),
            ("set_enable_hyperlink_auditing", False),
            ("set_enable_dns_prefetching", True),
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
            uri = (req.get_uri() if req else "") or ""
            if not uri:
                return False
            if re.match(r'^(https?://|about:blank$|blob:)', uri, re.IGNORECASE):
                decision.use()
                return True
            decision.ignore()
            return True
        return False

    def on_load_failed(self, webview, load_event, failing_uri, error):
        target = failing_uri if (isinstance(failing_uri, str) and failing_uri.startswith(("http://127.0.0.1", "http://localhost"))) else DEFAULT_HOME
        if isinstance(failing_uri, str) and (failing_uri.startswith("http://127.0.0.1") or failing_uri.startswith("http://localhost")):
            GLib.timeout_add(300, lambda: self.retry_load(webview, target))
            return True
        if isinstance(failing_uri, str) and failing_uri.startswith("://"):
            fixed_uri = "https://" + failing_uri.lstrip(":/")
            GLib.idle_add(lambda: webview.load_uri(fixed_uri))
            return True
        if isinstance(failing_uri, str) and re.match(r'^https?://', failing_uri, re.IGNORECASE):
            err_msg = str(error.message if hasattr(error, "message") else error).lower()
            if ("resolving" in err_msg or "try again" in err_msg or "name" in err_msg) and self.external_retries.get(failing_uri, 0) < 1:
                self.external_retries[failing_uri] = self.external_retries.get(failing_uri, 0) + 1
                GLib.timeout_add(1200, lambda: (webview.load_uri(failing_uri), False)[1])
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
        wv.connect("load-changed", lambda v, ev: self.update_address_bar(v.get_uri() or "") if v == self.current_webview() else None)
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
        new_wv = self.add_tab(None, "Carregando...", related=webview)
        return new_wv

    def close_tab(self, btn, wv):
        if self.notebook.get_n_pages() > 1:
            self.notebook.remove_page(self.notebook.page_num(wv))
            wv.destroy()

    def on_url_enter(self, entry):
        t = entry.get_text().strip()
        if not t:
            return
        if t.startswith("://"):
            t = "https://" + t.lstrip(":/")
        if re.match(r'^(javascript|data|vbscript|file):', t, re.IGNORECASE):
            return
        if " " not in t and URL_PATTERN.match(t):
            if re.match(r'^https?://', t, re.IGNORECASE):
                url = t
            elif re.match(r'^(?:localhost(?::\d+)?|127\.0\.0\.1(?::\d+)?|10\.\d+\.\d+\.\d+(?::\d+)?|192\.168\.\d+\.\d+(?::\d+)?|[a-z0-9-]+:\d+)(?:[/:?#]|$)', t, re.IGNORECASE):
                url = "http://" + t
            else:
                url = "https://" + t
        else:
            url = BASE_URL + "/api/search?engine=xiqi&q=" + urllib.parse.quote_plus(t)
        wv = self.current_webview()
        if wv is not None:
            self.external_retries.pop(url, None)
            wv.load_uri(url)
        else:
            self.add_tab(url, "Carregando...")

    def on_switch_page(self, nb, page, num):
        self.update_address_bar(page.get_uri() or "")


if __name__ == "__main__":
    win = XiqiBrowser()
    Gtk.main()

