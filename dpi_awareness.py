"""Pin the DenGo windows to a fixed, predictable DPI mode.

DenGo's exe manifest declares no DPI awareness, so a standalone DenGo is DPI-UNAWARE (Windows bitmap-scales the window and message boxes, and the
window never sees a DPI change). But a process that is started by another program can inherit that program's Windows compatibility flag: BVE's
BveTs.exe is commonly set to HIGHDPIAWARE (high-DPI scaling override = application), and the DenGo that the BVE plug-in starts then becomes
DPI-AWARE. A DPI-aware pygame window is created at 800x620 *logical* units but shows up smaller (e.g. 533x413 at 150%), and message boxes grow / stay
half laid out when the display scale changes. The DPI awareness of a window is decided by the DPI context of the thread that creates it, so calling this
function at the very start of the main thread (before pygame.init() and before any message box) makes every DenGo window DPI-unaware, however the
process was started.
"""

import ctypes

DPI_AWARENESS_CONTEXT_UNAWARE = -1


def force_unaware_for_this_thread():
    """Returns 'applied', 'unavailable' (Windows older than 10 1607) or 'failed'. Never raises."""
    try:
        function = ctypes.WinDLL("user32").SetThreadDpiAwarenessContext
    except (AttributeError, OSError):
        return "unavailable"
    try:
        function.restype = ctypes.c_void_p
        function.argtypes = [ctypes.c_void_p]
        previous = function(ctypes.c_void_p(DPI_AWARENESS_CONTEXT_UNAWARE))
        return "applied" if previous else "failed"
    except Exception:
        return "failed"
