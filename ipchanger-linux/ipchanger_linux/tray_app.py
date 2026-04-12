"""System tray indicator and menu (menu bar analogue on Linux)."""

from __future__ import annotations

import os
import threading
from pathlib import Path
from typing import Any

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402


def _load_appindicator():  # type: ignore[no-untyped-def]
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as appindicator  # noqa: E402

        return appindicator
    except ValueError:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as appindicator  # noqa: E402

        return appindicator


from . import state
from . import tor_engine
from .icons import emoji_pixbuf, flag_emoji_from_iso, pixbuf_from_png_bytes, write_temp_png
from .rotation_worker import RotationWorker


class TrayApp:
    def __init__(self, application: Gtk.Application, worker: RotationWorker) -> None:
        self.application = application
        self.worker = worker
        self._appindicator = _load_appindicator()
        self._indicator = self._appindicator.Indicator.new(
            "ipchanger-linux",
            "emblem-web",
            self._appindicator.IndicatorCategory.APPLICATION_STATUS,
        )
        self._indicator.set_title("IP Changer")
        self._indicator.set_status(self._appindicator.IndicatorStatus.ACTIVE)

        self._menu = Gtk.Menu()
        self._menu.get_style_context().add_class("ipc-tray-menu")
        self._ip_item = Gtk.MenuItem(label="IP: —")
        self._ip_item.set_sensitive(False)
        self._detail_item = Gtk.MenuItem(label="")
        self._detail_item.set_sensitive(False)
        self._detail_item.set_no_show_all(True)
        self._menu.append(self._ip_item)
        self._menu.append(self._detail_item)

        self._menu.append(Gtk.SeparatorMenuItem())

        reload_item = Gtk.MenuItem(label="Reload from IP Changer")
        reload_item.connect("activate", lambda *_: self.reload_from_shared_state())
        self._menu.append(reload_item)

        settings_item = Gtk.MenuItem(label="Open IP Changer Settings…")
        settings_item.connect("activate", lambda *_: self.open_settings())
        self._menu.append(settings_item)

        self._menu.append(Gtk.SeparatorMenuItem())

        self._stop_item = Gtk.MenuItem(label="Stop rotation")
        self._stop_item.connect("activate", lambda *_: self._stop_rotation())
        self._stop_item.set_sensitive(False)
        self._menu.append(self._stop_item)

        quit_item = Gtk.MenuItem(label="Quit IP Changer")
        quit_item.connect("activate", lambda *_: self.application.quit())
        self._menu.append(quit_item)

        self._menu.show_all()
        self._indicator.set_menu(self._menu)

        self._last_flag_path: str | None = None
        self._flag_fetch_gen = 0
        self._resolved_cc: str | None = None

        self.open_settings_callback = lambda: None

        self.reload_from_shared_state()
        GLib.timeout_add_seconds(2, self._poll_timer, None)

    def _poll_timer(self, _data: object) -> bool:
        self.reload_from_shared_state()
        return True

    def set_settings_opener(self, fn) -> None:  # type: ignore[no-untyped-def]
        self.open_settings_callback = fn

    def open_settings(self) -> None:
        self.open_settings_callback()

    def reload_from_shared_state(self) -> None:
        plist = state.read_exit_identity()
        ip = str(plist.get("query") or "")
        cc_raw = str(plist.get("countryCode") or "")
        cc_norm = cc_raw.upper() if len(cc_raw) == 2 else ""
        country = str(plist.get("country") or "")
        city = str(plist.get("city") or "")
        ok = bool(plist.get("ok"))

        if ok and len(cc_norm) == 2:
            if cc_norm == self._resolved_cc and self._last_flag_path and Path(self._last_flag_path).is_file():
                pass
            else:
                self._flag_fetch_gen += 1
                gen = self._flag_fetch_gen
                em = flag_emoji_from_iso(cc_norm) or "🌐"
                self._set_icon_emoji_interim(em)

                def fetch():
                    png = tor_engine.curl_socks(f"https://flagcdn.com/w80/{cc_norm.lower()}.png", as_text=False)
                    GLib.idle_add(self._apply_flag_fetch_result, gen, cc_norm, png)

                threading.Thread(target=fetch, name="ipchanger-flag", daemon=True).start()
        else:
            self._resolved_cc = None
            self._flag_fetch_gen += 1
            self._clear_icon_file()
            self._set_icon_emoji_interim("🌐")

        self._ip_item.set_label(f"IP: {ip}" if ip else "IP: —")

        detail_parts: list[str] = []
        if city and country:
            detail_parts.append(f"{city}, {country}")
        elif country:
            detail_parts.append(country)
        elif not ok and ip:
            detail_parts.append("Geo unavailable (check Tor SOCKS in IP Changer)")
        if detail_parts:
            self._detail_item.set_label(detail_parts[0])
            self._detail_item.show()
        else:
            self._detail_item.set_label("")
            self._detail_item.hide()

        self._indicator.set_label("", "")

        active = state.read_rotation_active()
        self._stop_item.set_sensitive(active)

    def _apply_flag_fetch_result(self, gen: int, cc_upper: str, png: Any) -> None:
        if gen != self._flag_fetch_gen:
            return
        self._resolved_cc = cc_upper
        pb = None
        if isinstance(png, (bytes, bytearray)) and len(png) > 24:
            pb = pixbuf_from_png_bytes(bytes(png))
        if pb:
            path = write_temp_png(pb)
            if path:
                self._clear_icon_file()
                self._last_flag_path = path
                self._indicator.set_icon_full("ipchanger-flag", path)
            return
        em = flag_emoji_from_iso(cc_upper) or "🌐"
        self._set_icon_emoji_final(em)

    def _set_icon_emoji_interim(self, emoji: str) -> None:
        pb = emoji_pixbuf(emoji)
        if pb:
            path = write_temp_png(pb)
            if path:
                self._clear_icon_file()
                self._last_flag_path = path
                self._indicator.set_icon_full("ipchanger-flag", path)
                return
        self._indicator.set_icon("emblem-web")

    def _set_icon_emoji_final(self, emoji: str) -> None:
        self._set_icon_emoji_interim(emoji)

    def _clear_icon_file(self) -> None:
        if self._last_flag_path:
            try:
                os.unlink(self._last_flag_path)
            except OSError:
                pass
            self._last_flag_path = None

    def _stop_rotation(self) -> None:
        self.worker.request_stop()

    def shutdown(self) -> None:
        self._clear_icon_file()
