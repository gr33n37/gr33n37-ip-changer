"""Modern GTK 3 CSS for IP Changer (cards, motion, accent)."""

from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gdk, Gtk  # noqa: E402

# Tuned for Adwaita and most Gtk 3.20+ themes; @keyframes require a CSS-capable engine.
_CSS = """
@keyframes ipc-pulse {
  0% { opacity: 0.78; }
  50% { opacity: 1; }
  100% { opacity: 0.78; }
}

.ipc-window.background {
  background: linear-gradient(to bottom, alpha(@theme_base_color, 0.94), @theme_bg_color);
}

.ipc-scroll viewport {
  background: transparent;
}

.ipc-card {
  background-color: alpha(@theme_base_color, 0.55);
  border: 1px solid alpha(@theme_fg_color, 0.11);
  border-radius: 14px;
  padding: 18px 20px;
  margin: 0 2px;
  box-shadow: 0 2px 10px alpha(@theme_fg_color, 0.06);
}

.ipc-card:hover {
  border-color: alpha(@theme_selected_bg_color, 0.28);
  box-shadow: 0 4px 18px alpha(@theme_fg_color, 0.08);
  transition: border-color 220ms ease, box-shadow 220ms ease;
}

.ipc-section-label {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: alpha(@theme_fg_color, 0.5);
  margin-bottom: 4px;
}

.ipc-title {
  font-size: 19px;
  font-weight: 800;
  letter-spacing: -0.02em;
  color: @theme_fg_color;
}

.ipc-subtitle {
  font-size: 12px;
  color: alpha(@theme_fg_color, 0.55);
  margin-top: 2px;
}

.ipc-value-mono {
  font-family: Monospace;
  font-size: 15px;
  font-weight: 600;
  letter-spacing: 0.02em;
}

.ipc-circuit-mono {
  font-family: Monospace;
  font-size: 11px;
  opacity: 0.92;
}

.ipc-field-label {
  font-size: 12px;
  color: alpha(@theme_fg_color, 0.72);
}

.ipc-entry {
  border-radius: 10px;
  padding: 8px 12px;
  transition: box-shadow 180ms ease, border-color 180ms ease;
}

.ipc-entry:focus {
  box-shadow: 0 0 0 2px alpha(@theme_selected_bg_color, 0.35);
}

.ipc-flag-frame {
  border-radius: 12px;
  border: 1px solid alpha(@theme_fg_color, 0.12);
  background: alpha(@theme_base_color, 0.65);
  padding: 8px;
  box-shadow: inset 0 1px 0 alpha(@theme_fg_color, 0.06);
}

.ipc-stat-row {
  padding: 10px 6px;
  border-radius: 10px;
}

.ipc-stat-icon {
  opacity: 0.85;
}

.ipc-status-pill {
  font-size: 12px;
  font-weight: 700;
  padding: 4px 12px;
  border-radius: 999px;
  border: 1px solid alpha(@theme_fg_color, 0.1);
}

.ipc-pulse .ipc-status-pill {
  animation: ipc-pulse 1.35s ease-in-out infinite;
}

.ipc-banner {
  border-radius: 12px;
  padding: 12px 14px;
  border: 1px solid alpha(@theme_fg_color, 0.14);
  background: alpha(@theme_selected_bg_color, 0.1);
}

.ipc-banner label {
  color: shade(@theme_fg_color, 0.85);
  font-size: 12px;
  font-weight: 600;
}

.ipc-info {
  font-size: 11px;
  color: alpha(@theme_fg_color, 0.55);
  line-height: 1.45;
}

.ipc-accent-hero {
  min-height: 3px;
  border-radius: 3px;
  margin: 0 20px 10px 20px;
  background: linear-gradient(
    to right,
    alpha(@theme_selected_bg_color, 0.2),
    @theme_selected_bg_color,
    alpha(@theme_selected_bg_color, 0.2)
  );
}

button.ipc-btn-pill {
  border-radius: 999px;
  padding: 8px 22px;
  font-weight: 700;
}

.header-bar.ipc-header {
  background: alpha(@theme_bg_color, 0.92);
  border: none;
  box-shadow: 0 1px 0 alpha(@theme_fg_color, 0.08);
}

toolbar separator {
  background: alpha(@theme_fg_color, 0.12);
}

menu.ipc-tray-menu {
  border-radius: 12px;
  padding: 6px;
  border: 1px solid alpha(@theme_fg_color, 0.1);
}

menu.ipc-tray-menu menuitem {
  border-radius: 8px;
  padding: 8px 16px;
  transition: background 160ms ease;
}

menu.ipc-tray-menu menuitem:hover {
  background-color: alpha(@theme_selected_bg_color, 0.18);
}
"""


_theme_installed = False


def ensure_theme_installed() -> None:
    """Idempotent: load application CSS once (tray + settings)."""
    global _theme_installed
    if _theme_installed:
        return
    screen = Gdk.Screen.get_default()
    if screen is None:
        return
    try:
        install_for_screen(screen)
    except GLib.Error:
        return
    _theme_installed = True


def install_for_screen(screen: Gdk.Screen) -> Gtk.CssProvider:
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS.encode("utf-8"))
    Gtk.StyleContext.add_provider_for_screen(
        screen,
        provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )
    return provider
