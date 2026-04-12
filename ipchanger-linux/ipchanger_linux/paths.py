"""XDG data paths for shared exit identity and rotation state (Linux)."""

from __future__ import annotations

import os
from pathlib import Path


def xdg_data_home() -> Path:
    base = os.environ.get("XDG_DATA_HOME", "").strip()
    if base:
        return Path(base).expanduser()
    return Path.home() / ".local" / "share"


def ipchanger_data_dir() -> Path:
    d = xdg_data_home() / "ipchanger"
    d.mkdir(parents=True, exist_ok=True)
    return d


def exit_identity_path() -> Path:
    return ipchanger_data_dir() / "exit-identity.json"


def rotation_state_path() -> Path:
    return ipchanger_data_dir() / "rotation-state.json"
