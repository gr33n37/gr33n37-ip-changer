"""Read/write exit identity and rotation state JSON (mirrors macOS plists)."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import exit_identity_path, rotation_state_path


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_exit_identity() -> dict[str, Any]:
    path = exit_identity_path()
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_exit_identity(snap: dict[str, Any] | None) -> None:
    s = dict(snap or {})
    out: dict[str, Any] = {
        "ok": bool(s.get("ok")),
        "query": _str_or_empty(s.get("query")),
        "countryCode": _str_or_empty(s.get("countryCode")),
        "country": _str_or_empty(s.get("country")),
        "region": _str_or_empty(s.get("region")),
        "city": _str_or_empty(s.get("city")),
        "isp": _str_or_empty(s.get("isp")),
        "updated": _iso_now(),
    }
    tc = s.get("torCircuit")
    if isinstance(tc, str) and tc:
        out["torCircuit"] = tc
    path = exit_identity_path()
    path.write_text(json.dumps(out, indent=2), encoding="utf-8")


def read_rotation_active() -> bool:
    path = rotation_state_path()
    if not path.is_file():
        return False
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return False
        return bool(data.get("active"))
    except (OSError, json.JSONDecodeError):
        return False


def write_rotation_state(active: bool, circuit: str | None = None) -> None:
    d: dict[str, Any] = {
        "active": bool(active),
        "updated": _iso_now(),
    }
    if circuit:
        d["circuit"] = circuit
    rotation_state_path().write_text(json.dumps(d, indent=2), encoding="utf-8")


def _str_or_empty(v: Any) -> str:
    if isinstance(v, str):
        return v
    return ""
