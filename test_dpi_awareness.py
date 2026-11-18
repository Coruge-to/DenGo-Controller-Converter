import ctypes
import unittest

from display_diagnostics import process_dpi_awareness
from dpi_awareness import force_unaware_for_this_thread

PER_MONITOR_V2 = -4
SYSTEM_AWARE = -2


def set_thread_context(value):
    function = ctypes.WinDLL("user32").SetThreadDpiAwarenessContext
    function.restype = ctypes.c_void_p
    function.argtypes = [ctypes.c_void_p]
    return function(ctypes.c_void_p(value))


class DpiAwarenessTests(unittest.TestCase):
    def setUp(self):
        self.original = set_thread_context(SYSTEM_AWARE)    # remember the real context (returned) and start from a known one
        self.addCleanup(set_thread_context, self.original if self.original else -1)

    def test_thread_that_inherited_per_monitor_awareness_is_pinned_to_unaware(self):
        # what a DenGo started by BveTs.exe with the HIGHDPIAWARE compatibility flag looks like
        set_thread_context(PER_MONITOR_V2)
        self.assertEqual(process_dpi_awareness(), "permonitor")
        self.assertEqual(force_unaware_for_this_thread(), "applied")
        self.assertEqual(process_dpi_awareness(), "unaware")

    def test_system_aware_thread_is_pinned_to_unaware(self):
        set_thread_context(SYSTEM_AWARE)
        self.assertEqual(process_dpi_awareness(), "system")
        self.assertEqual(force_unaware_for_this_thread(), "applied")
        self.assertEqual(process_dpi_awareness(), "unaware")

    def test_already_unaware_thread_stays_unaware_and_calling_twice_is_harmless(self):
        self.assertEqual(force_unaware_for_this_thread(), "applied")
        self.assertEqual(force_unaware_for_this_thread(), "applied")
        self.assertEqual(process_dpi_awareness(), "unaware")


if __name__ == "__main__":
    unittest.main(verbosity=2)
