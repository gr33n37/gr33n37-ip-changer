# gr33n37-ip-changer

Rotate your public IP using **Tor**: a cross‑platform **Bash** script and a **macOS System Settings** preference pane (**IP Changer**) that show exit IP, location-style info, and (on macOS) your Tor circuit when the control port is enabled.

![gp](https://github.com/gr33n37/gr33n37-ip-changer/assets/30112537/34e1c4e2-ec79-4ef3-b0a2-e99eee48bb4b)

## Repository contents

| Component | Platform | Description |
|-----------|----------|-------------|
| [`ip-changer.sh`](ip-changer.sh) | Linux & macOS | Interactive script: start Tor, restart/reload for new exits, optional intervals and repeat counts. |
| [`ipchanger/`](ipchanger/) | macOS only | Xcode project builds `ipchanger.prefPane` — **IP Changer** in System Settings: rotation controls, live exit identity, flags, ISP/region/city/country, Tor path (guard → middle → exit). |
| **`IPChangerMenuBar`** (same Xcode project) | macOS only | Optional **menu bar extra** (`NSStatusItem`): **country flag** (same PNG source as the pane: [flagcdn.com](https://flagcdn.com)), **IP and location in the menu**; mirrors the pane’s Tor exit identity via a shared plist. No Dock icon (`LSUIElement`). The **preference pane cannot** add a persistent bar item by itself. |

---

## Installation

### Clone the repository

```shell
git clone https://github.com/philodi-dev/gr33n37-ip-changer.git
cd gr33n37-ip-changer
```

### Or download only the script

```shell
curl -O 'https://raw.githubusercontent.com/philodi-dev/gr33n37-ip-changer/main/ip-changer.sh'
chmod +x ip-changer.sh
```

---

## Usage: `ip-changer.sh`

### Linux

Run with root privileges (package install / `systemctl`):

```shell
sudo ./ip-changer.sh
```

### macOS

No `sudo` required; uses Homebrew and `brew services`:

```shell
./ip-changer.sh
```

### Script behaviour

- **Interval** and **repeat count** are read interactively.
- If **either** interval **or** count is **0**, the script runs **indefinite** IP changes (with a random 10–20s delay on macOS in that mode).
- On macOS the script uses **`brew services restart tor`** each change (see the pref pane below for **NEWNYM** without full restarts).

### Requirements

- **macOS:** [Homebrew](https://brew.sh/); Tor and `curl` are installed if missing.
- **Linux:** `curl` and `tor`; the script tries `apt`, `yum`, or `pacman` as appropriate.

---

## macOS preference pane (IP Changer)

### Build and install

From the **`ipchanger`** directory (the one that contains `ipchanger.xcodeproj`):

```shell
cd ipchanger
chmod +x ipchanger/install_prefpane.sh
./ipchanger/install_prefpane.sh
```

- Do **not** run the installer as **root**; signing uses your login keychain. The pane is installed to **`~/Library/PreferencePanes/`**. **`install_prefpane.sh`** also builds **`IPChangerMenuBar.app`** and copies it to **`/Applications/`** when possible (otherwise **`~/Applications/`** — Finder’s top-level **Applications** folder vs **Home → Applications**).
- Or open **`ipchanger.xcodeproj`** in Xcode, select the **ipchanger** scheme, **Product → Build** (⌘B). If your scheme has a post-build copy action, it may install the signed pane automatically.
- After installing, **quit System Settings fully** (⌘Q), reopen, and search for **IP Changer** or **ipchanger**.

### What the pane shows

- **Rotation:** interval (seconds; `0` = no extra wait between steps), number of changes (`0` = unlimited), **Start** / **Stop** (Stop ends the rotation loop only; it does not stop the Tor service).
- **Exit identity:** exit **IPv4**, **country**, **region**, **city**, **ISP** (from ip-api over SOCKS), **flag** (flag image loaded over Tor from [flagcdn.com](https://flagcdn.com)), and **Tor circuit** names when available.
- **Connection status:** internet path, Tor process, SOCKS **9050**, rotation state.

### Tor control port (recommended on macOS)

IP rotation prefers **`SIGNAL NEWNYM`** on **`127.0.0.1:9051`** so Tor keeps running. Circuit names and NEWNYM need a control port. Add to your **`torrc`** (typical Homebrew paths: `/opt/homebrew/etc/tor/torrc` or `/usr/local/etc/tor/torrc`), then restart Tor once:

```text
ControlPort 9051
CookieAuthentication 1
```

Without **9051**, the pane falls back to **`brew services restart tor`** for each rotation, and the **Tor circuit** line may stay **—**.

### Menu bar helper (`IPChangerMenuBar.app`)

System Settings plug-ins do not run in the background, so a **separate tiny app** adds the status item (like other menu bar tools).

1. Open **`ipchanger/ipchanger.xcodeproj`** in Xcode.
2. Select the **`IPChangerMenuBar`** scheme.
3. **Product → Run** (⌘R). The flag appears in the menu bar; **Quit** from its menu stops it.
4. To **keep it across logins:** add the built app to **System Settings → General → Login Items** (or drag `IPChangerMenuBar.app` from the **Products** folder in Xcode’s Report navigator after a build).

**Behaviour**

- **Exit identity** matches the preference pane: the pane writes **`~/Library/Application Support/IPChanger/exit-identity.plist`** whenever it updates geo over Tor SOCKS; the menu bar reads that file and refreshes on a short timer plus a distributed notification when the pane updates.
- **Status item:** **flag image only** (PNG from flagcdn, same URL pattern as the pane; emoji raster fallback if the download fails). **IP, city, and country** appear in the **menu** when you click the icon (not in the title).
- **Open IP Changer Settings…** opens the **IP Changer** preference pane in System Settings (`.prefPane` bundle or `x-apple.systempreferences:` URL; the pane’s `Info.plist` enables the URL scheme).
- The menu bar does **not** run its own Tor SOCKS lookups for display; open **IP Changer** at least once so the shared plist is populated (Tor running, SOCKS up, as for the pane).

---

## Important: your apps must use Tor

Traffic is anonymised only when it goes through the Tor SOCKS proxy **`127.0.0.1:9050`**. Most apps do not use it by default.

**Firefox**

- Settings → General → Network Settings → **Manual proxy configuration**
- **SOCKS Host:** `127.0.0.1` **Port:** `9050`, **SOCKS v5**, enable **Proxy DNS when using SOCKS v5**

**Chrome / Chromium**

```shell
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --proxy-server="socks5://127.0.0.1:9050"
```

**macOS system proxy**

- System Settings → Network → your interface → Details → Proxies → **SOCKS proxy** `127.0.0.1` **9050**

### iCloud Private Relay & VPNs

If an IP lookup still shows **iCloud Private Relay** or your VPN, that traffic is **not** the Tor exit. Turn off **Private Relay** (Apple ID → iCloud → Private Relay) and disconnect other VPNs while testing Tor.

### IPv6 leaks

Tor often exits over **IPv4** only. If the browser uses **IPv6**, your real address can leak. Restrict IPv6 for the interface you use with Tor, or force IPv4 in the browser where possible.

### Verify Tor SOCKS

```shell
curl -s --socks5-hostname 127.0.0.1:9050 https://checkip.amazonaws.com
```

You should see a Tor exit IP, not your home or relay IP.

---

## Privacy: ISPs, trackers, and real IP

This project helps you **rotate Tor exit IPs** and see **exit** geo data; it is **not** a guarantee of anonymity.

**Websites and ad trackers**  
When a browser or app sends traffic **only** through Tor SOCKS (`127.0.0.1:9050`, with DNS handled correctly for that stack), those services normally see the **Tor exit relay’s IP** and geo for **that** IP—not your home IP. Changing exits changes that visible IP.

**Your ISP (or network operator)**  
They can typically tell that you are **using Tor** (connections to Tor relays). They do not see your HTTPS page contents the way a normal proxy might. They still see you as a subscriber and may see **volume and timing** metadata.

**Things that can still identify or link you**

- **Signing in** (Google, Apple, email, etc.) ties activity to **you**, regardless of exit IP.
- **Browser fingerprinting** (canvas, fonts, WebGL, behaviour) can track or correlate without a stable IP.
- **Leaks:** traffic that bypasses Tor (**WebRTC**, **IPv6**, wrong app, misconfigured proxy) can expose your **real** IP or location.
- **Apps** that do not use the SOCKS proxy are **not** protected.

For **strong browser-focused anonymity**, [Tor Browser](https://www.torproject.org/download/) is purpose-built; SOCKS + a normal browser is easier to misconfigure than Tor Browser.

---

## Security notes

- Do not commit **certificates**, **`.p12`**, **`.mobileprovision`**, **AuthKey `*.p8`**, or **`.env`** secrets; this repo’s **`.gitignore`** tries to exclude common Apple signing and key patterns.
- The pref pane runs **`brew`** and **`curl`** to manage Tor and query exit info; use only builds you trust.

---

## License / attribution

Project structure and behaviour may evolve; see git history for authors. Third-party services (**ip-api**, **flagcdn**) have their own terms and rate limits; use is subject to those services’ policies.

If you route application traffic correctly through Tor and avoid leaks, the address **those applications** show to sites should be a **Tor exit**, not your normal ISP IP—subject to the limits in **Privacy: ISPs, trackers, and real IP** above.
