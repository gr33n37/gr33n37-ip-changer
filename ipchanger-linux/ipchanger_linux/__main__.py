"""Entry: GTK application with tray icon and settings window."""

from __future__ import annotations

import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, Gtk  # noqa: E402

from .rotation_worker import RotationWorker
from .settings_window import SettingsWindow
from .tray_app import TrayApp
from .ui_theme import ensure_theme_installed


class IPChangerApplication(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(
            application_id="com.philodi.ipchanger.linux",
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )
        self.worker = RotationWorker()
        self._tray: TrayApp | None = None
        self._settings: SettingsWindow | None = None

    def do_startup(self) -> None:
        Gtk.Application.do_startup(self)
        ensure_theme_installed()
        self._tray = TrayApp(self, self.worker)
        self._tray.set_settings_opener(self._present_settings)
        self.hold()

    def do_activate(self) -> None:
        self._present_settings()

    def _present_settings(self) -> None:
        if self._settings is None:
            self._settings = SettingsWindow(application=self, worker=self.worker)
            self._settings.connect("delete-event", self._on_settings_delete)
        self._settings.present()
        self._settings.deiconify()

    def _on_settings_delete(self, window: Gtk.Widget, _event) -> bool:
        window.hide()
        return True

    def do_shutdown(self) -> None:
        if self._tray is not None:
            self._tray.shutdown()
        Gio.Application.do_shutdown(self)


def main() -> None:
    app = IPChangerApplication()
    sys.exit(app.run(sys.argv))


if __name__ == "__main__":
    main()
