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
  WINDOW    (background thread, also while the main thread is blocked in a message box) a window of this process
            appeared (+), changed size / position / DPI (~) or went away (-)
  MONITORS  the monitor layout and each monitor's DPI, at start and whenever it changes
  DIALOG    the controller-not-found retry dialog was shown / answered
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


_AWARENESS_NAMES = {0: "unaware", 1: "system", 2: "permonitor"}


def process_dpi_awareness():
    """DPI awareness of the calling thread: 'unaware' / 'system' / 'permonitor' (or 'unknown')."""
    try:
        import ctypes

        user32 = ctypes.WinDLL("user32")
        user32.GetThreadDpiAwarenessContext.restype = ctypes.c_void_p
        user32.GetAwarenessFromDpiAwarenessContext.argtypes = [ctypes.c_void_p]
        value = int(user32.GetAwarenessFromDpiAwarenessContext(user32.GetThreadDpiAwarenessContext()))
        return _AWARENESS_NAMES.get(value, "unknown(%d)" % value)
    except Exception:
        return "unknown"


def win32_snapshot(pid=None):
    """(windows, monitors) for this process. windows = {hwnd: (class, client_w, client_h, outer_w, outer_h, x, y,
    window_dpi, monitor_dpi, awareness)}; monitors = ((left, top, right, bottom, dpi), ...). Read-only, never raises."""
    windows, monitors = {}, []
    try:
        import ctypes
        from ctypes import wintypes

        pid = os.getpid() if pid is None else pid
        user32 = ctypes.WinDLL("user32")            # private handle: does not touch the prototypes other code uses
        try:
            shcore = ctypes.WinDLL("shcore")
        except OSError:
            shcore = None
        user32.IsWindowVisible.argtypes = [wintypes.HWND]
        user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        user32.MonitorFromWindow.argtypes = [wintypes.HWND, wintypes.DWORD]
        user32.MonitorFromWindow.restype = ctypes.c_void_p
        get_window_dpi = getattr(user32, "GetDpiForWindow", None)
        if get_window_dpi:
            get_window_dpi.argtypes = [wintypes.HWND]
        get_window_ctx = getattr(user32, "GetWindowDpiAwarenessContext", None)
        get_aware = getattr(user32, "GetAwarenessFromDpiAwarenessContext", None)
        if get_window_ctx and get_aware:
            get_window_ctx.argtypes = [wintypes.HWND]
            get_window_ctx.restype = ctypes.c_void_p
            get_aware.argtypes = [ctypes.c_void_p]
        if shcore:
            shcore.GetDpiForMonitor.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]

        def monitor_dpi(handle):
            try:
                if shcore and handle:
                    x, y = ctypes.c_uint(0), ctypes.c_uint(0)
                    if shcore.GetDpiForMonitor(handle, 0, ctypes.byref(x), ctypes.byref(y)) == 0:
                        return int(x.value)
            except Exception:
                pass
            return None

        enum_windows = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

        def on_window(hwnd, _):
            try:
                if not user32.IsWindowVisible(hwnd):
                    return True
                owner = wintypes.DWORD(0)
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
                if int(owner.value) != pid:
                    return True
                name = ctypes.create_unicode_buffer(128)
                user32.GetClassNameW(hwnd, name, 128)
                client, outer = wintypes.RECT(), wintypes.RECT()
                user32.GetClientRect(hwnd, ctypes.byref(client))
                user32.GetWindowRect(hwnd, ctypes.byref(outer))
                window_dpi = int(get_window_dpi(hwnd)) if get_window_dpi else None
                awareness = int(get_aware(get_window_ctx(hwnd))) if (get_window_ctx and get_aware) else None
                windows[int(hwnd)] = (name.value, client.right - client.left, client.bottom - client.top,
                                      outer.right - outer.left, outer.bottom - outer.top, outer.left, outer.top,
                                      window_dpi, monitor_dpi(user32.MonitorFromWindow(hwnd, 2)), awareness)
            except Exception:
                pass
            return True

        user32.EnumWindows(enum_windows(on_window), 0)

        enum_monitors = ctypes.WINFUNCTYPE(wintypes.BOOL, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

        def on_monitor(handle, dc, rect, _):
            try:
                monitors.append((rect.contents.left, rect.contents.top, rect.contents.right, rect.contents.bottom, monitor_dpi(handle)))
            except Exception:
                pass
            return True

        user32.EnumDisplayMonitors.argtypes = [ctypes.c_void_p, ctypes.c_void_p, enum_monitors, wintypes.LPARAM]
        user32.EnumDisplayMonitors(None, None, enum_monitors(on_monitor), 0)
    except Exception:
        pass
    return windows, tuple(monitors)


def _describe_window(w):
    return "class=%s client=%dx%d outer=%dx%d pos=%d,%d dpi=%s mon_dpi=%s aware=%s" % w


def _window_changes(old, new):
    names = ("class", "client", "outer", "pos", "dpi", "mon_dpi", "aware")
    pairs = ((old[0], new[0]), ("%dx%d" % old[1:3], "%dx%d" % new[1:3]), ("%dx%d" % old[3:5], "%dx%d" % new[3:5]),
             ("%d,%d" % old[5:7], "%d,%d" % new[5:7]), (old[7], new[7]), (old[8], new[8]), (old[9], new[9]))
    return " ".join("%s %s->%s" % (n, a, b) for n, (a, b) in zip(names, pairs) if a != b)


class WindowWatcher:
    """Polls this process's visible top-level windows (including a modal message box the main thread is blocked in)
    and the monitor layout / DPI, and logs only the CHANGES: WINDOW (+ new, ~ changed, - gone), MONITORS."""

    def __init__(self, diag, interval_s=0.25, snapshot_fn=None, clock=time.monotonic, flood_lines=60, flood_window_s=10.0):
        self._diag = diag
        self._interval = float(interval_s)
        self._snapshot = snapshot_fn or win32_snapshot
        self._clock = clock
        self._prev = None
        self._monitors = None
        self._flood_lines = int(flood_lines)
        self._flood_window = float(flood_window_s)
        self._recent = deque()
        self._flood_reported_at = None
        self._stop = threading.Event()
        self._thread = None

    def _emit(self, text):
        now = self._clock()
        self._recent.append(now)
        while self._recent and now - self._recent[0] > self._flood_window:
            self._recent.popleft()
        if len(self._recent) > self._flood_lines:
            if self._flood_reported_at is None or now - self._flood_reported_at > self._flood_window:
                self._flood_reported_at = now
                self._diag.log("WINFLOOD", "more than %d WINDOW changes within %.0fs; further lines are skipped" % (self._flood_lines, self._flood_window))
            return
        self._diag.log("WINDOW", text)

    def poll(self):
        windows, monitors = self._snapshot()
        if monitors != self._monitors:
            self._diag.log("MONITORS", "n=%d %s%s" % (
                len(monitors), " ".join("[%d,%d,%d,%d dpi=%s]" % m for m in monitors),
                "" if self._monitors is None else " (was n=%d)" % len(self._monitors)))
            self._monitors = monitors
        previous = self._prev if self._prev is not None else {}
        for hwnd in sorted(windows):
            if hwnd not in previous:
                self._emit("+ hwnd=0x%X %s" % (hwnd, _describe_window(windows[hwnd])))
            elif windows[hwnd] != previous[hwnd]:
                self._emit("~ hwnd=0x%X %s" % (hwnd, _window_changes(previous[hwnd], windows[hwnd])))
        for hwnd in sorted(set(previous) - set(windows)):
            self._emit("- hwnd=0x%X class=%s" % (hwnd, previous[hwnd][0]))
        self._prev = windows

    def _run(self):
        failures = 0
        while True:
            try:
                self.poll()
            except Exception:
                failures += 1
                if failures >= 5:
                    return
            if self._stop.wait(self._interval):
                return

    def start(self):
        if self._thread is None and self._diag.enabled:
            self._thread = threading.Thread(target=self._run, name="dengo-diag-windows", daemon=True)
            self._thread.start()

    def stop(self):
        self._stop.set()


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

    def start_window_watcher(self, interval_s=0.25, snapshot_fn=None):
        """Start the background window / monitor watcher (a no-op unless diagnostics are enabled)."""
        if not self.enabled or getattr(self, "_watcher", None) is not None:
            return None
        self._watcher = WindowWatcher(self, interval_s=interval_s, snapshot_fn=snapshot_fn)
        self._watcher.start()
        return self._watcher

    def stop_window_watcher(self):
        watcher = getattr(self, "_watcher", None)
        if watcher is not None:
            watcher.stop()

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
