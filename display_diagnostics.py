"""Opt-in diagnostic log for the DenGo window / platform-view flicker analysis.

Disabled unless the environment variable DENGO_DIAG_LOG names a file. When disabled every method is a
cheap no-op, so the product behaves exactly as before. The log only records state *changes* and slow
sections (never per frame), and it never raises into the caller.

What it answers when the glitch is seen again:
  PLATFORM  the supported-process view the gate screen is built from (count + platform:pids), on change
  FLAP      several view changes in a short window (the "gate screen <-> normal layout" back and forth)
  RESIZE    set_mode is about to be called: wanted height, pygame surface height, REAL OS client height
  MISMATCH  surface height already equals the wanted height but the OS client height does not
  SLOW      a named section of the main loop (platform scan, ViGEm connect, HidHide setup ...) took long
  LOOPGAP   the whole main-loop iteration took long (the window could not be repainted in the meantime)
  MODE / JOY  mode switch and controller removal, which reset state
"""

import os
import threading
import time
from collections import deque
from contextlib import contextmanager
from datetime import datetime

ENV_VAR = "DENGO_DIAG_LOG"
MAX_BYTES = 2 * 1024 * 1024
MAX_WRITE_ERRORS = 3


def client_height(hwnd):
    """Real client-area height of a Win32 window (the OS view, not pygame's surface), or None."""
    try:
        import ctypes
        from ctypes import wintypes

        if not hwnd:
            return None
        rect = wintypes.RECT()
        if ctypes.windll.user32.GetClientRect(hwnd, ctypes.byref(rect)):
            return int(rect.bottom - rect.top)
    except Exception:
        pass
    return None


def describe_view(statuses):
    """'bve6:[1234],pcsx2:[55]' for the running platforms, '-' when none."""
    parts = []
    for status in statuses:
        if getattr(status, "running", False):
            pids = ",".join(str(p) for p in getattr(status, "process_ids", ()))
            parts.append("%s:[%s]" % (getattr(status, "platform_id", "?"), pids))
    return ",".join(parts) if parts else "-"


class DisplayDiagnostics:
    def __init__(self, path=None, clock=time.monotonic, wall=None, max_bytes=MAX_BYTES,
                 slow_ms=100.0, loop_gap_ms=500.0, flap_changes=4, flap_window_s=5.0):
        self._path = os.path.abspath(path) if path else None
        self._clock = clock
        self._wall = wall or datetime.now
        self._max_bytes = int(max_bytes)
        self._slow_s = float(slow_ms) / 1000.0
        self._loop_gap_s = float(loop_gap_ms) / 1000.0
        self._flap_changes = int(flap_changes)
        self._flap_window_s = float(flap_window_s)
        self._lock = threading.Lock()
        self._errors = 0
        self._t0 = clock()
        self._last_tick = None
        self._last_view = None
        self._changes = deque()
        self._last_flap_at = None
        self._last_mismatch = None

    @classmethod
    def from_environment(cls, environ=None, **kwargs):
        env = os.environ if environ is None else environ
        value = (env.get(ENV_VAR) or "").strip().strip('"')
        return cls(value or None, **kwargs)

    @property
    def enabled(self):
        return self._path is not None and self._errors < MAX_WRITE_ERRORS

    def log(self, tag, text=""):
        if not self.enabled:
            return
        try:
            line = "%s +%9.3f %-8s %s\n" % (
                self._wall().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3], self._clock() - self._t0, tag, text)
            with self._lock:
                try:
                    if os.path.getsize(self._path) > self._max_bytes:
                        os.replace(self._path, self._path + ".1")
                except OSError:
                    pass
                with open(self._path, "a", encoding="utf-8", newline="\n") as handle:
                    handle.write(line)
        except Exception:
            self._errors += 1

    def open_note(self, **fields):
        self.log("OPEN", " ".join("%s=%s" % (k, v) for k, v in fields.items()) + " pid=%d" % os.getpid())

    def event(self, tag, text=""):
        self.log(tag, text)

    def note_platform_view(self, statuses, count):
        """Log the supported-process view when it changes; flag a rapid series of changes as FLAP."""
        if not self.enabled:
            return
        key = (count, describe_view(statuses))
        if key == self._last_view:
            return
        previous = self._last_view
        self._last_view = key
        now = self._clock()
        self.log("PLATFORM", "count=%d view=%s%s" % (
            key[0], key[1], "" if previous is None else " (was count=%d view=%s)" % previous))
        self._changes.append(now)
        while self._changes and now - self._changes[0] > self._flap_window_s:
            self._changes.popleft()
        if len(self._changes) >= self._flap_changes and (
                self._last_flap_at is None or now - self._last_flap_at > self._flap_window_s):
            self._last_flap_at = now
            self.log("FLAP", "%d view changes within %.1fs" % (len(self._changes), self._flap_window_s))

    def note_resize(self, wanted_h, surface_h, os_h_fn):
        """Call when the visual state changed. Returns True when set_mode will be needed (caller decides)."""
        if not self.enabled:
            return
        os_h = os_h_fn() if os_h_fn else None
        if surface_h != wanted_h:
            self._last_mismatch = None
            self.log("RESIZE", "wanted=%s surface=%s os_client=%s" % (wanted_h, surface_h, os_h))
        elif os_h is not None and os_h != wanted_h:
            state = (wanted_h, surface_h, os_h)
            if state != self._last_mismatch:
                self._last_mismatch = state
                self.log("MISMATCH", "surface already %s but os_client=%s (wanted=%s)" % (surface_h, os_h, wanted_h))
        else:
            self._last_mismatch = None

    def note_resized(self, os_h_fn):
        if self.enabled:
            self.log("RESIZED", "os_client=%s" % (os_h_fn() if os_h_fn else None))

    @contextmanager
    def section(self, name):
        """Time a block; logs SLOW when it takes longer than slow_ms. Exceptions propagate unchanged."""
        if not self.enabled:
            yield
            return
        start = self._clock()
        try:
            yield
        finally:
            elapsed = self._clock() - start
            if elapsed >= self._slow_s:
                self.log("SLOW", "%s took %.0f ms" % (name, elapsed * 1000.0))

    def tick(self):
        """Call once per main-loop iteration; logs LOOPGAP when an iteration took long."""
        if not self.enabled:
            return
        now = self._clock()
        if self._last_tick is not None and now - self._last_tick >= self._loop_gap_s:
            self.log("LOOPGAP", "main loop iteration took %.0f ms" % ((now - self._last_tick) * 1000.0))
        self._last_tick = now
