import os
import re
import tempfile
import unittest
from datetime import datetime
from types import SimpleNamespace

from display_diagnostics import DisplayDiagnostics, describe_view, ENV_VAR


class FakeClock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def status(platform_id, running, *pids):
    return SimpleNamespace(platform_id=platform_id, running=running, process_ids=tuple(pids))


class DiagTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "diag.log")
        self.clock = FakeClock()

    def make(self, **kw):
        return DisplayDiagnostics(self.path, clock=self.clock, wall=lambda: datetime(2026, 11, 18, 5, 0, 0), **kw)

    def lines(self):
        if not os.path.exists(self.path):
            return []
        with open(self.path, encoding="utf-8") as handle:
            return handle.read().splitlines()

    def tags(self):
        return [re.search(r"\+\s*[\d.]+\s+(\w+)", line).group(1) for line in self.lines()]

    def test_disabled_without_path_does_nothing_and_never_raises(self):
        diag = DisplayDiagnostics(None, clock=self.clock)
        self.assertFalse(diag.enabled)
        diag.open_note(version="1")
        diag.event("MODE", "x")
        diag.note_platform_view([status("bve6", True, 1)], 1)
        diag.note_resize(260, 590, lambda: 590)
        diag.note_resized(lambda: 1)
        diag.tick()
        with diag.section("x"):
            pass
        self.assertEqual(self.lines(), [])

    def test_from_environment(self):
        self.assertFalse(DisplayDiagnostics.from_environment({}).enabled)
        self.assertFalse(DisplayDiagnostics.from_environment({ENV_VAR: "  "}).enabled)
        self.assertTrue(DisplayDiagnostics.from_environment({ENV_VAR: '"%s"' % self.path}).enabled)

    def test_describe_view_lists_only_running_platforms(self):
        self.assertEqual(describe_view([status("bve6", True, 5, 6), status("pcsx2", False), status("rpcs3", True, 9)]),
                         "bve6:[5,6],rpcs3:[9]")
        self.assertEqual(describe_view([status("bve6", False)]), "-")

    def test_platform_view_logged_only_on_change(self):
        diag = self.make()
        view = [status("bve6", True, 1), status("pcsx2", True, 2)]
        diag.note_platform_view(view, 2)
        diag.note_platform_view(view, 2)
        self.clock.advance(1)
        diag.note_platform_view([status("bve6", True, 1)], 1)
        lines = self.lines()
        self.assertEqual(self.tags(), ["PLATFORM", "PLATFORM"])
        self.assertIn("count=2 view=bve6:[1],pcsx2:[2]", lines[0])
        self.assertIn("count=1 view=bve6:[1] (was count=2 view=bve6:[1],pcsx2:[2])", lines[1])

    def test_flap_reported_for_rapid_changes_and_rate_limited(self):
        diag = self.make(flap_changes=4, flap_window_s=5.0)
        a, b = [status("bve6", True, 1)], [status("bve6", True, 1), status("pcsx2", True, 2)]
        for i in range(8):
            diag.note_platform_view(a if i % 2 == 0 else b, 1 if i % 2 == 0 else 2)
            self.clock.advance(0.2)
        self.assertEqual(self.tags().count("FLAP"), 1)

    def test_slow_changes_are_not_flap(self):
        diag = self.make(flap_changes=4, flap_window_s=5.0)
        a, b = [status("bve6", True, 1)], [status("bve6", True, 1), status("pcsx2", True, 2)]
        for i in range(8):
            diag.note_platform_view(a if i % 2 == 0 else b, 1 if i % 2 == 0 else 2)
            self.clock.advance(10)
        self.assertNotIn("FLAP", self.tags())

    def test_section_logs_only_when_slow_and_propagates_exceptions(self):
        diag = self.make(slow_ms=100)
        with diag.section("fast"):
            self.clock.advance(0.05)
        with diag.section("hidhide"):
            self.clock.advance(0.5)
        self.assertEqual(self.tags(), ["SLOW"])
        self.assertIn("hidhide took 500 ms", self.lines()[0])
        with self.assertRaises(ValueError):
            with diag.section("boom"):
                self.clock.advance(0.3)
                raise ValueError("x")
        self.assertEqual(self.tags(), ["SLOW", "SLOW"])

    def test_loop_gap(self):
        diag = self.make(loop_gap_ms=500)
        diag.tick()
        self.clock.advance(0.1)
        diag.tick()
        self.clock.advance(0.9)
        diag.tick()
        self.assertEqual(self.tags(), ["LOOPGAP"])
        self.assertIn("900 ms", self.lines()[0])

    def test_resize_logs_real_os_height_and_mismatch(self):
        diag = self.make()
        diag.note_resize(590, 260, lambda: 260)      # about to set_mode
        diag.note_resize(590, 590, lambda: 260)      # surface says OK, OS window is still the gate height (screenshot 4985)
        diag.note_resize(590, 590, lambda: 260)      # same mismatch again -> not repeated
        diag.note_resize(590, 590, lambda: 590)      # fine -> nothing
        self.assertEqual(self.tags(), ["RESIZE", "MISMATCH"])
        self.assertIn("wanted=590 surface=260 os_client=260", self.lines()[0])
        self.assertIn("surface already 590 but os_client=260", self.lines()[1])

    def test_unknown_os_height_is_not_a_mismatch(self):
        diag = self.make()
        diag.note_resize(590, 590, lambda: None)
        self.assertEqual(self.lines(), [])

    def test_rotation_keeps_one_previous_file(self):
        diag = self.make(max_bytes=200)
        for i in range(10):
            diag.event("MODE", "x" * 50)
        self.assertTrue(os.path.exists(self.path + ".1"))
        self.assertLess(os.path.getsize(self.path), 400)

    def test_unwritable_path_disables_after_repeated_errors_without_raising(self):
        bad = DisplayDiagnostics(os.path.join(self.dir.name, "no-such-dir", "x.log"), clock=self.clock)
        for _ in range(5):
            bad.event("MODE", "x")
        self.assertFalse(bad.enabled)


if __name__ == "__main__":
    unittest.main(verbosity=2)
