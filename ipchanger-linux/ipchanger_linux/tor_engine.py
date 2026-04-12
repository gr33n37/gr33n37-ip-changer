"""Tor control port, SOCKS curl, and exit identity snapshot (Linux)."""

from __future__ import annotations

import json
import re
import socket
import subprocess
from pathlib import Path
from typing import Any

TOR_SOCKS_HOST = "127.0.0.1"
TOR_SOCKS_PORT = 9050
TOR_CONTROL_HOST = "127.0.0.1"
TOR_CONTROL_PORT = 9051


def _cookie_paths() -> list[Path]:
    home = Path.home()
    return [
        Path("/var/lib/tor/control_auth_cookie"),
        Path("/run/tor/control.authcookie"),
        home / ".tor" / "control_auth_cookie",
        Path("/var/run/tor/control.authcookie"),
    ]


def _read_cookie_hex() -> str | None:
    for p in _cookie_paths():
        try:
            raw = p.read_bytes()
        except OSError:
            continue
        if raw:
            return raw.hex()
    return None


def _tor_control_exchange(payload: str) -> str | None:
    try:
        sock = socket.create_connection((TOR_CONTROL_HOST, TOR_CONTROL_PORT), timeout=8.0)
    except OSError:
        return None
    try:
        sock.settimeout(8.0)
        sock.sendall(payload.encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            try:
                data = sock.recv(8192)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
        return b"".join(chunks).decode("utf-8", errors="replace")
    finally:
        sock.close()


def _control_payload_with_auth(extra: str) -> str:
    cookie = _read_cookie_hex()
    if cookie:
        auth = f"AUTHENTICATE {cookie}\r\n"
    else:
        auth = 'AUTHENTICATE ""\r\n'
    return auth + extra


def tor_control_circuit_path_display_string() -> str | None:
    payload = _control_payload_with_auth("GETINFO circuit-status\r\nQUIT\r\n")
    reply = _tor_control_exchange(payload)
    if not reply:
        return None
    if "515 Authentication failed" in reply or "514 Authentication required" in reply:
        return None
    return _parse_circuit_path(reply)


def _parse_circuit_path(all_text: str) -> str | None:
    chosen: str | None = None
    for line in all_text.splitlines():
        t = line.strip()
        if " BUILT " in t and "purpose=GENERAL" in t:
            chosen = t
    if not chosen:
        for line in all_text.splitlines():
            t = line.strip()
            if " BUILT " in t:
                chosen = t
                break
    if not chosen:
        return None

    tokens = [p for p in re.split(r"\s+", chosen) if p]
    past_built = False
    names: list[str] = []
    for tok in tokens:
        if not past_built:
            if tok == "BUILT":
                past_built = True
            continue
        if tok.startswith("purpose=") or tok.startswith("TIME_CREATED=") or tok.startswith("REASON="):
            break
        if "=" in tok and not tok.startswith("$") and "~" not in tok:
            idx = tok.index("=")
            if idx > 0 and not tok.startswith("$"):
                break

        disp = tok
        if "=" in tok:
            idx = tok.index("=")
            if idx + 1 < len(tok):
                disp = tok[idx + 1 :]
        elif "~" in tok:
            idx = tok.index("~")
            if idx + 1 < len(tok):
                disp = tok[idx + 1 :]
        elif tok.startswith("$") and len(tok) > 8:
            disp = tok[1:13] + "…"
        if disp:
            names.append(disp)
    if not names:
        return None
    return " → ".join(names)


def send_tor_newnym() -> tuple[bool, str | None]:
    payload = _control_payload_with_auth("SIGNAL NEWNYM\r\nQUIT\r\n")
    reply = _tor_control_exchange(payload)
    if reply is None:
        return False, "Tor control port not reachable (127.0.0.1:9051)."
    if "515 Authentication failed" in reply or "514 Authentication required" in reply:
        return False, "Tor control rejected authentication (check cookie readable by your user, or CookieAuthFile)."
    if "553" in reply:
        return False, "Tor rate-limits NEWNYM; wait or use a longer interval."
    if "552" in reply or "Unrecognized signal" in reply:
        return False, "Tor rejected SIGNAL NEWNYM."
    ok_count = reply.count("250 OK")
    if ok_count >= 2:
        return True, None
    return False, reply.strip() or "No usable reply from Tor control port."


def rotate_tor_circuit() -> tuple[bool, str | None]:
    ok, err = send_tor_newnym()
    if ok:
        return True, None
    code, out = _run(["systemctl", "reload", "tor.service"])
    if code == 0:
        return True, None
    msg = err or ""
    if msg:
        msg += " "
    msg += f"(systemctl reload fallback failed: {out.strip() or code})"
    return False, msg.strip()


def curl_socks(url: str, *, as_text: bool = True) -> str | bytes | None:
    args = [
        "curl",
        "-s",
        "--connect-timeout",
        "6",
        "-m",
        "12",
        "--socks5-hostname",
        f"{TOR_SOCKS_HOST}:{TOR_SOCKS_PORT}",
        url,
    ]
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            timeout=14,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    data = proc.stdout or b""
    if as_text:
        return data.decode("utf-8", errors="replace")
    return data


def capture_exit_identity_snapshot() -> dict[str, Any]:
    json_raw = curl_socks(
        "http://ip-api.com/json/?fields=status,message,query,country,countryCode,city,regionName,isp",
        as_text=True,
    )
    if isinstance(json_raw, str) and json_raw:
        try:
            d = json.loads(json_raw)
        except json.JSONDecodeError:
            d = None
        if isinstance(d, dict) and d.get("status") == "success":
            cc = d.get("countryCode") if isinstance(d.get("countryCode"), str) else ""
            snap: dict[str, Any] = {
                "query": d.get("query") or "",
                "country": d.get("country") or "",
                "region": d.get("regionName") or "",
                "city": d.get("city") or "",
                "isp": d.get("isp") or "",
                "countryCode": cc,
                "ok": True,
            }
            if isinstance(cc, str) and len(cc) == 2:
                png = curl_socks(f"https://flagcdn.com/w80/{cc.lower()}.png", as_text=False)
                if isinstance(png, (bytes, bytearray)) and len(png) > 24:
                    snap["flagPNG"] = bytes(png)
            return snap

    snap = {"ok": False}
    plain = curl_socks("https://checkip.amazonaws.com", as_text=True)
    if isinstance(plain, str):
        ip = plain.strip()
        if ip:
            snap["query"] = ip
    return snap


def is_tor_process_running() -> bool:
    code, _ = _run(["bash", "-lc", "pgrep -x tor >/dev/null 2>&1"])
    return code == 0


def is_port_open(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def is_internet_reachable() -> bool:
    try:
        proc = subprocess.run(
            [
                "curl",
                "-s",
                "--connect-timeout",
                "3",
                "-m",
                "5",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "https://example.com",
            ],
            capture_output=True,
            timeout=8,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    code = (proc.stdout or b"").decode("ascii", errors="replace").strip()
    return len(code) == 3 and (code.startswith("2") or code.startswith("3"))


def ensure_tor_service_running() -> tuple[bool, str | None]:
    code, out = _run(["systemctl", "is-active", "--quiet", "tor.service"])
    if code == 0:
        return True, None
    code, out = _run(["systemctl", "start", "tor.service"])
    if code == 0:
        return True, None
    return False, out.strip() or "Could not start tor.service (try: sudo systemctl start tor)."


def _run(argv: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return -1, str(e)
    err = (proc.stderr or "").strip()
    out = (proc.stdout or "").strip()
    return proc.returncode, err or out
