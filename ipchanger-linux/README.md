# IP Changer (Linux)

GTK **system tray** indicator and **settings window** for Tor exit IP, geo, flags, and rotation — analogous to **IPChangerMenuBar** and the macOS preference pane in this repository.

## Dependencies

- Python 3.10+
- `tor`, `curl`, `systemctl` (typical distro Tor package)
- PyGObject GTK 3 and Ayatana AppIndicator (or classic AppIndicator)

**Debian / Ubuntu**

```bash
sudo apt install tor curl python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1
```

**Fedora**

```bash
sudo dnf install tor curl python3-gobject gtk3 libayatana-appindicator-gtk3
```

Optional (better tray emoji fallback):

```bash
pip install --user Pillow
```

## Tor control port (recommended)

To rotate without `systemctl reload tor` (and to show **Tor circuit** text), add to `/etc/tor/torrc` (or your distro’s `torrc`), then restart Tor:

```text
ControlPort 9051
CookieAuthentication 1
```

The control cookie is often `/var/lib/tor/control_auth_cookie` and readable only by root. To use **NEWNYM** as your user, either:

- add your user to the `debian-tor` group (Debian/Ubuntu) and ensure group read on the cookie, or  
- set `CookieAuthFile` in `torrc` to a path under your home directory and readable by your user.

Without a readable cookie, rotation falls back to `systemctl reload tor.service`, which usually requires appropriate privileges.

## Run

From this directory:

```bash
chmod +x ipchanger-gtk
./ipchanger-gtk
```

Or:

```bash
PYTHONPATH=. python3 -m ipchanger_linux
```

- The **tray icon** shows the exit country flag (PNG over Tor from [flagcdn.com](https://flagcdn.com), with emoji fallback when Pillow/fonts allow).
- **Open IP Changer Settings…** opens the main window (rotation controls, exit identity, connection status).
- Shared state is stored under `$XDG_DATA_HOME/ipchanger/` (default `~/.local/share/ipchanger/`) as `exit-identity.json` and `rotation-state.json`.

## Desktop entry

Adjust `Exec=` in `data/com.philodi.ipchanger.linux.desktop` to the full path of `ipchanger-gtk`, then copy the file to `~/.local/share/applications/`.
