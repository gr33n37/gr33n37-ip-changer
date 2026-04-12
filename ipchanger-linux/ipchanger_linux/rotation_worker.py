"""Background rotation loop (mirrors IPCTorRotationEngine on macOS)."""

from __future__ import annotations

import threading
import time

from . import state
from . import tor_engine


class RotationWorker:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    def is_running(self) -> bool:
        with self._lock:
            return self._thread is not None and self._thread.is_alive()

    def request_stop(self) -> None:
        self._stop.set()
        state.write_rotation_state(False, None)

    def run(self, interval_seconds: int, times: int) -> None:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            self._thread = threading.Thread(
                target=self._loop,
                args=(interval_seconds, times),
                name="ipchanger-rotation",
                daemon=True,
            )
            self._thread.start()

    def _loop(self, interval_seconds: int, times: int) -> None:
        ok, _err = tor_engine.ensure_tor_service_running()
        if not ok:
            state.write_rotation_state(False, None)
            return

        remaining = times
        unlimited = times == 0
        state.write_rotation_state(True, None)

        while not self._stop.is_set():
            ok_rot, _ = tor_engine.rotate_tor_circuit()
            if not ok_rot:
                if self._stop.is_set():
                    break
                time.sleep(2.0)
                continue

            time.sleep(1.0)
            circuit = tor_engine.tor_control_circuit_path_display_string()
            snap = tor_engine.capture_exit_identity_snapshot()
            merged = dict(snap)
            if circuit:
                merged["torCircuit"] = circuit
            state.write_exit_identity(merged)
            state.write_rotation_state(True, circuit or None)

            if not unlimited:
                remaining -= 1
                if remaining <= 0 or self._stop.is_set():
                    break

            sleep_sec = max(0, interval_seconds)
            if sleep_sec > 0:
                for _ in range(sleep_sec):
                    if self._stop.is_set():
                        break
                    time.sleep(1.0)
            if self._stop.is_set():
                break

        self._stop.set()
        state.write_rotation_state(False, None)
        with self._lock:
            self._thread = None
