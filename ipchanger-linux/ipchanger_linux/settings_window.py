"""GTK settings window — modern card layout, motion, header bar."""

from __future__ import annotations

import threading

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

from . import state
from . import tor_engine
from .icons import flag_emoji_from_iso, pixbuf_from_png_bytes
from .rotation_worker import RotationWorker
from .ui_theme import ensure_theme_installed


def _card(title: str, *body_widgets: Gtk.Widget) -> Gtk.Box:
    card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
    ctx = card.get_style_context()
    ctx.add_class("ipc-card")
    t = Gtk.Label(label=title, xalign=0.0)
    t.get_style_context().add_class("ipc-section-label")
    card.pack_start(t, False, False, 0)
    for w in body_widgets:
        card.pack_start(w, False, False, 0)
    return card


class SettingsWindow(Gtk.ApplicationWindow):
    def __init__(self, *, application: Gtk.Application, worker: RotationWorker) -> None:
        ensure_theme_installed()
        super().__init__(application=application, title="IP Changer")
        self.set_default_size(540, 700)
        self.set_border_width(0)
        self.worker = worker
        self.get_style_context().add_class("ipc-window")

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.get_style_context().add_class("ipc-header")
        title_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title_col.set_margin_top(4)
        title_col.set_margin_bottom(4)
        tit = Gtk.Label(label="IP Changer", xalign=0.0)
        tit.get_style_context().add_class("ipc-title")
        sub = Gtk.Label(label="Tor exit identity · SOCKS 127.0.0.1:9050", xalign=0.0)
        sub.get_style_context().add_class("ipc-subtitle")
        title_col.pack_start(tit, False, False, 0)
        title_col.pack_start(sub, False, False, 0)
        header.set_custom_title(title_col)
        self.set_titlebar(header)

        hero = Gtk.Box()
        hero.set_size_request(-1, 3)
        hero.get_style_context().add_class("ipc-accent-hero")

        # —— Rotation ——
        self._interval = Gtk.Entry()
        self._interval.set_width_chars(10)
        self._interval.set_placeholder_text("0")
        self._interval.get_style_context().add_class("ipc-entry")

        self._times = Gtk.Entry()
        self._times.set_width_chars(10)
        self._times.set_placeholder_text("0")
        self._times.get_style_context().add_class("ipc-entry")

        rot_grid = Gtk.Grid()
        rot_grid.set_row_spacing(12)
        rot_grid.set_column_spacing(14)
        lab1 = Gtk.Label(label="Interval in seconds (0 = no wait)", xalign=0.0)
        lab2 = Gtk.Label(label="Times to change IP (0 = unlimited)", xalign=0.0)
        for lab in (lab1, lab2):
            lab.get_style_context().add_class("ipc-field-label")
        rot_grid.attach(lab1, 0, 0, 1, 1)
        rot_grid.attach(self._interval, 1, 0, 1, 1)
        rot_grid.attach(lab2, 0, 1, 1, 1)
        rot_grid.attach(self._times, 1, 1, 1, 1)

        self._start = Gtk.Button.new_with_label("Start rotation")
        self._start.connect("clicked", self._on_start)
        self._start.get_style_context().add_class("suggested-action")
        self._start.get_style_context().add_class("ipc-btn-pill")

        self._stop = Gtk.Button.new_with_label("Stop")
        self._stop.set_sensitive(False)
        self._stop.connect("clicked", self._on_stop)
        self._stop.get_style_context().add_class("destructive-action")
        self._stop.get_style_context().add_class("ipc-btn-pill")

        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_row.pack_start(self._start, False, False, 0)
        btn_row.pack_start(self._stop, False, False, 0)

        rot_card = _card("Rotation", rot_grid, btn_row)

        # —— Exit identity ——
        self._ip = Gtk.Label(label="—", xalign=0.0)
        self._ip.get_style_context().add_class("ipc-value-mono")

        self._flag = Gtk.Image()
        self._flag.set_size_request(56, 40)
        flag_wrap = Gtk.Box()
        flag_wrap.get_style_context().add_class("ipc-flag-frame")
        flag_wrap.pack_start(self._flag, False, False, 0)

        self._country = Gtk.Label(label="—", xalign=0.0)
        self._region = Gtk.Label(label="—", xalign=0.0)
        self._city = Gtk.Label(label="—", xalign=0.0)
        self._isp = Gtk.Label(label="—", xalign=0.0)
        self._isp.set_line_wrap(True)
        self._circuit = Gtk.Label(label="—", xalign=0.0)
        self._circuit.set_line_wrap(True)
        self._circuit.get_style_context().add_class("ipc-circuit-mono")

        txt_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for hdr, w in (
            ("Country", self._country),
            ("Region", self._region),
            ("City", self._city),
            ("ISP", self._isp),
        ):
            h = Gtk.Label(label=hdr, xalign=0.0)
            h.get_style_context().add_class("ipc-section-label")
            txt_col.pack_start(h, False, False, 0)
            txt_col.pack_start(w, False, False, 0)

        flag_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
        flag_row.pack_start(flag_wrap, False, False, 0)
        flag_row.pack_start(txt_col, True, True, 0)

        ip_caption = Gtk.Label(label="Exit IP address", xalign=0.0)
        ip_caption.get_style_context().add_class("ipc-section-label")

        exit_inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        exit_inner.pack_start(ip_caption, False, False, 0)
        exit_inner.pack_start(self._ip, False, False, 0)
        exit_inner.pack_start(flag_row, False, False, 0)
        c_l = Gtk.Label(label="Tor circuit (guard → middle → exit)", xalign=0.0)
        c_l.get_style_context().add_class("ipc-section-label")
        exit_inner.pack_start(c_l, False, False, 0)
        exit_inner.pack_start(self._circuit, False, False, 0)

        exit_card = _card("Exit identity", exit_inner)

        # —— Connection ——
        self._stat_inet = Gtk.Label(xalign=1.0)
        self._stat_tor = Gtk.Label(xalign=1.0)
        self._stat_socks = Gtk.Label(xalign=1.0)
        self._stat_rot = Gtk.Label(xalign=1.0)
        for lab in (self._stat_inet, self._stat_tor, self._stat_socks, self._stat_rot):
            lab.get_style_context().add_class("ipc-status-pill")

        self._rot_spinner = Gtk.Spinner()
        self._rot_spinner.set_size_request(22, 22)
        self._rot_row_outer = Gtk.Box()
        rot_row_inner = self._build_stat_row(
            "view-refresh-symbolic",
            "IP rotation",
            self._stat_rot,
            extra_end=self._rot_spinner,
        )
        self._rot_row_outer.pack_start(rot_row_inner, True, True, 0)

        stat_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        stat_col.pack_start(
            self._build_stat_row("network-wireless-symbolic", "Internet", self._stat_inet),
            False,
            False,
            0,
        )
        stat_col.pack_start(
            self._build_stat_row("security-high-symbolic", "Tor process", self._stat_tor),
            False,
            False,
            0,
        )
        stat_col.pack_start(
            self._build_stat_row(
                "network-transmit-receive-symbolic",
                "SOCKS port 9050",
                self._stat_socks,
            ),
            False,
            False,
            0,
        )
        stat_col.pack_start(self._rot_row_outer, False, False, 0)

        stat_card = _card("Connection status", stat_col)

        # —— Hints / info ——
        self._hint = Gtk.Label(xalign=0.0)
        self._hint.set_line_wrap(True)
        self._hint.set_margin_top(2)
        self._hint.set_margin_bottom(2)

        hint_inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        hint_inner.get_style_context().add_class("ipc-banner")
        hint_inner.pack_start(self._hint, False, False, 0)

        self._hint_revealer = Gtk.Revealer()
        self._hint_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        self._hint_revealer.set_transition_duration(280)
        self._hint_revealer.add(hint_inner)
        self._hint_revealer.set_reveal_child(False)

        info = Gtk.Label(
            label=(
                "Route traffic through Tor SOCKS at 127.0.0.1:9050. "
                "For rotation without reloading the daemon, enable ControlPort 9051 and a readable cookie in torrc."
            ),
            xalign=0.0,
        )
        info.set_line_wrap(True)
        info.get_style_context().add_class("ipc-info")

        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        inner.set_margin_start(20)
        inner.set_margin_end(20)
        inner.set_margin_top(16)
        inner.set_margin_bottom(24)
        inner.pack_start(hero, False, False, 0)
        inner.pack_start(rot_card, False, False, 0)
        inner.pack_start(exit_card, False, False, 0)
        inner.pack_start(stat_card, False, False, 0)
        inner.pack_start(info, False, False, 0)
        inner.pack_start(self._hint_revealer, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        if hasattr(scroll, "set_propagate_natural_height"):
            scroll.set_propagate_natural_height(True)
        scroll.get_style_context().add_class("ipc-scroll")
        scroll.add(inner)
        self.add(scroll)

        GLib.timeout_add_seconds(3, self._tick_refresh, None)
        self._refresh_all_async()

    def _build_stat_row(
        self,
        icon_name: str,
        title: str,
        value: Gtk.Label,
        *,
        extra_end: Gtk.Widget | None = None,
    ) -> Gtk.Box:
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        row.get_style_context().add_class("ipc-stat-row")
        icon = Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
        icon.get_style_context().add_class("ipc-stat-icon")
        tl = Gtk.Label(label=title, xalign=0.0)
        tl.get_style_context().add_class("ipc-field-label")
        row.pack_start(icon, False, False, 0)
        row.pack_start(tl, False, False, 0)
        row.pack_start(Gtk.Label(), True, True, 0)
        end = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        if extra_end is not None:
            end.pack_start(extra_end, False, False, 0)
        end.pack_start(value, False, False, 0)
        row.pack_end(end, False, False, 0)
        return row

    def _set_hint(self, text: str) -> None:
        self._hint.set_text(text)
        self._hint_revealer.set_reveal_child(bool(text))

    def _on_start(self, _btn: Gtk.Button) -> None:
        self._set_hint("")
        if self.worker.is_running():
            self._set_hint("Rotation is already running. Use Stop to end.")
            return
        try:
            interval = int(self._interval.get_text() or "0")
            times = int(self._times.get_text() or "0")
        except ValueError:
            self._set_hint("Interval and times must be whole numbers.")
            return
        if interval < 0:
            self._set_hint("Interval cannot be negative. Use 0 for no pause between changes.")
            return
        if times < 0:
            self._set_hint("Times cannot be negative. Use 0 for unlimited.")
            return

        self.worker.run(interval, times)
        self._set_hint("Rotation runs in the background. Close this window anytime — stop from here or the tray menu.")
        GLib.timeout_add(350, lambda: (self._refresh_stats() or False))

    def _on_stop(self, _btn: Gtk.Button) -> None:
        self.worker.request_stop()
        self._set_hint("")
        self._refresh_stats()

    def _tick_refresh(self, _data: object) -> bool:
        self._refresh_all_async()
        return True

    def _refresh_all_async(self) -> None:
        def work():
            circuit = tor_engine.tor_control_circuit_path_display_string()
            snap = tor_engine.capture_exit_identity_snapshot()
            inet = tor_engine.is_internet_reachable()
            tor = tor_engine.is_tor_process_running()
            socks = tor_engine.is_port_open(tor_engine.TOR_SOCKS_HOST, tor_engine.TOR_SOCKS_PORT)
            rotating = state.read_rotation_active()
            GLib.idle_add(
                self._apply_refs,
                circuit,
                snap,
                inet,
                tor,
                socks,
                rotating,
            )

        threading.Thread(target=work, name="ipchanger-refresh", daemon=True).start()

    def _apply_refs(
        self,
        circuit: str | None,
        snap: dict,
        inet: bool,
        tor: bool,
        socks: bool,
        rotating: bool,
    ) -> None:
        self._circuit.set_text(circuit if circuit else "—")
        sdict = snap if isinstance(snap, dict) else {}
        self._apply_snapshot(sdict)
        merged = dict(sdict)
        if circuit:
            merged["torCircuit"] = circuit
        state.write_exit_identity(merged)

        if rotating and not (tor and socks):
            self.worker.request_stop()
            rotating = False
            if not self._hint.get_text():
                self._set_hint("Tor or SOCKS went down during rotation; the loop was stopped.")

        c_ok = "#2e7d32"
        c_bad = "#c62828"
        c_warn = "#ef6c00"
        c_rot = "#1565c0"
        c_idle = "#666666"
        self._stat_inet.set_markup(f'<span foreground="{c_ok if inet else c_bad}">{_yes(inet)}</span>')
        self._stat_tor.set_markup(f'<span foreground="{c_ok if tor else c_warn}">{"Running" if tor else "Stopped"}</span>')
        self._stat_socks.set_markup(f'<span foreground="{c_ok if socks else c_bad}">{"Reachable" if socks else "Closed"}</span>')
        self._stat_rot.set_markup(
            f'<span foreground="{c_rot if rotating else c_idle}">{"Active" if rotating else "Idle"}</span>'
        )

        ctx = self._rot_row_outer.get_style_context()
        if rotating:
            ctx.add_class("ipc-pulse")
            self._rot_spinner.start()
            self._rot_spinner.show()
        else:
            ctx.remove_class("ipc-pulse")
            self._rot_spinner.stop()
            self._rot_spinner.hide()

        self._start.set_sensitive(not rotating)
        self._stop.set_sensitive(rotating)
        self.show_all()

    def _apply_snapshot(self, s: dict) -> None:
        ok = bool(s.get("ok"))
        if ok:
            self._ip.set_text(str(s.get("query") or "—"))
            self._country.set_text(str(s.get("country") or "—"))
            self._region.set_text(str(s.get("region") or "—"))
            self._city.set_text(str(s.get("city") or "—"))
            self._isp.set_text(str(s.get("isp") or "—"))
            cc = str(s.get("countryCode") or "")
            png = s.get("flagPNG")
            pb = None
            if isinstance(png, (bytes, bytearray)):
                pb = pixbuf_from_png_bytes(bytes(png))
            if pb:
                self._flag.set_from_pixbuf(pb)
            else:
                em = flag_emoji_from_iso(cc) or "🌐"
                self._flag.set_from_icon_name("emblem-web", Gtk.IconSize.DIALOG)
                self._flag.set_tooltip_text(em)
        else:
            ip = str(s.get("query") or "")
            if ip:
                self._ip.set_text(ip)
                self._country.set_text("(Geo lookup failed — is Tor SOCKS up?)")
            else:
                self._ip.set_text("—")
                self._country.set_text("—")
            self._region.set_text("—")
            self._city.set_text("—")
            self._isp.set_text("—")
            self._flag.set_from_icon_name("emblem-web", Gtk.IconSize.DIALOG)

    def _refresh_stats(self) -> None:
        rotating = state.read_rotation_active()
        tor = tor_engine.is_tor_process_running()
        socks = tor_engine.is_port_open(tor_engine.TOR_SOCKS_HOST, tor_engine.TOR_SOCKS_PORT)
        self._start.set_sensitive(not rotating)
        self._stop.set_sensitive(rotating)
        if rotating and not (tor and socks):
            self.worker.request_stop()


def _yes(b: bool) -> str:
    return "Reachable" if b else "Offline"
