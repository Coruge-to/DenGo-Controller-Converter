"""HidHide requirement on the PCSX2 route: RED-first tests.

Design under test (owner, 2026-11-18): when PCSX2 is the single running platform, DenGo needs ViGEmBus (existing blocking dialog) and,
checked right after it, HidHide. A missing HidHide is shown with the SAME kind of blocking dialog as ViGEmBus ("... is available" /
DenGo cannot start); starting DenGo with PCSX2 is a clear intent. The dialog is never shown on any other route (BVE / JRETS /
RUNNING TRAIN / RPCS3). Only "HidHide is not installed" blocks; any other HidHide failure keeps the existing
record-and-continue behaviour. The names below are the planned API of hidhide_pcsx2.py / main.py; until they exist these tests are RED.
"""

import contextlib
import io
import os
import re
import tempfile
import unittest
from pathlib import Path

import hidhide_pcsx2 as hh

ROOT = Path(__file__).resolve().parent
MAIN_SOURCE = (ROOT / "main.py").read_text(encoding="utf-8")


def make_cli(program_files, *, x64):
    base = Path(program_files) / "Nefarius Software Solutions" / "HidHide"
    folder = base / "x64" if x64 else base
    folder.mkdir(parents=True, exist_ok=True)
    cli = folder / "HidHideCLI.exe"
    cli.write_bytes(b"MZ")
    return cli


@contextlib.contextmanager
def program_files_env(path):
    old = os.environ.get("ProgramFiles")
    os.environ["ProgramFiles"] = path
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("ProgramFiles", None)
        else:
            os.environ["ProgramFiles"] = old


def function_body(name):
    match = re.search(r"def " + re.escape(name) + r"\([^)]*\):(?P<body>.*?)(?=\ndef |\Z)", MAIN_SOURCE, re.S)
    return None if match is None else match.group("body")


class FindHidHideCliTests(unittest.TestCase):
    def test_returns_none_when_not_installed(self):
        with tempfile.TemporaryDirectory() as pf:
            self.assertIsNone(hh.find_hidhide_cli(pf))

    def test_finds_the_cli_in_the_base_folder(self):
        with tempfile.TemporaryDirectory() as pf:
            cli = make_cli(pf, x64=False)
            self.assertEqual(Path(hh.find_hidhide_cli(pf)), cli)

    def test_finds_the_cli_in_the_x64_folder(self):
        with tempfile.TemporaryDirectory() as pf:
            cli = make_cli(pf, x64=True)
            self.assertEqual(Path(hh.find_hidhide_cli(pf)), cli)

    def test_a_directory_named_like_the_cli_is_not_a_cli(self):
        with tempfile.TemporaryDirectory() as pf:
            (Path(pf) / "Nefarius Software Solutions" / "HidHide" / "HidHideCLI.exe").mkdir(parents=True)
            self.assertIsNone(hh.find_hidhide_cli(pf))

    def test_default_program_files_comes_from_the_environment(self):
        with tempfile.TemporaryDirectory() as pf:
            cli = make_cli(pf, x64=False)
            with program_files_env(pf):
                self.assertEqual(Path(hh.find_hidhide_cli()), cli)


class DistributionUrlTests(unittest.TestCase):
    def test_url_points_to_the_hidhide_releases_page(self):
        self.assertEqual(hh.HIDHIDE_RELEASES_URL, "https://github.com/nefarius/HidHide/releases")


class RequireInstalledTests(unittest.TestCase):
    def test_the_error_is_a_runtime_error_with_a_stable_message(self):
        self.assertTrue(issubclass(hh.HidHideNotInstalledError, RuntimeError))
        self.assertIn("HidHideCLI.exe was not found", str(hh.HidHideNotInstalledError("HidHideCLI.exe was not found")))

    def test_configurator_raises_when_hidhide_is_not_installed(self):
        with tempfile.TemporaryDirectory() as pf, program_files_env(pf):
            with self.assertRaises(hh.HidHideNotInstalledError):
                hh.HidHidePcsx2Configurator().require_installed()

    def test_configurator_returns_the_cli_when_hidhide_is_installed(self):
        with tempfile.TemporaryDirectory() as pf, program_files_env(pf):
            cli = make_cli(pf, x64=True)
            self.assertEqual(Path(hh.HidHidePcsx2Configurator().require_installed()), cli)

    def test_it_raises_every_time_and_has_no_once_only_latch(self):
        with tempfile.TemporaryDirectory() as pf, program_files_env(pf):
            configurator = hh.HidHidePcsx2Configurator()
            for _ in range(3):
                with self.assertRaises(hh.HidHideNotInstalledError):
                    configurator.require_installed()

    def test_it_does_not_touch_the_configuration_state(self):
        with tempfile.TemporaryDirectory() as pf, program_files_env(pf):
            make_cli(pf, x64=False)
            configurator = hh.HidHidePcsx2Configurator()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                configurator.require_installed()
            self.assertEqual(out.getvalue(), "")


class ConfiguratorRegressionTests(unittest.TestCase):
    """Existing behaviour that the change must keep: other failures are a recorded failure, never an exception."""

    def test_ensure_configured_without_hidhide_records_a_failure_and_returns_false(self):
        with tempfile.TemporaryDirectory() as pf, tempfile.TemporaryDirectory() as app, program_files_env(pf):
            exe = Path(app) / "pcsx2.exe"
            exe.write_bytes(b"MZ")
            configurator = hh.HidHidePcsx2Configurator()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertFalse(configurator.ensure_configured(str(exe)))
            self.assertIn("HIDHIDE=FAILED", out.getvalue())
            self.assertIn("HidHideCLI.exe was not found", out.getvalue())


class MainWiringTests(unittest.TestCase):
    """Source-text guards for main.py (main() itself cannot run in a unit test)."""

    def test_the_hidhide_dialog_function_exists_and_uses_the_hidhide_page(self):
        body = function_body("show_hidhide_unavailable")
        self.assertIsNotNone(body, "show_hidhide_unavailable() is not defined in main.py")
        self.assertIn("HIDHIDE_RELEASES_URL", body)

    def test_the_hidhide_dialog_text_matches_the_vigembus_dialog_wording(self):
        self.assertIn("HidHideが見つかりませんでした。", MAIN_SOURCE)                     # HidHide was not found.
        self.assertIn("HidHideをインストールしてWindowsを再起動してください。", MAIN_SOURCE)  # install HidHide and restart Windows.
        self.assertIn("HidHideが利用可能になるまで、", MAIN_SOURCE)                            # until HidHide is available,
        self.assertGreaterEqual(MAIN_SOURCE.count("DenGo Controller Converterは起動できません。"), 2)   # DenGo cannot start (ViGEmBus + HidHide)

    def test_the_hidhide_dialog_is_blocking_like_vigembus_there_is_no_continue_button(self):
        self.assertNotIn("このまま続ける", MAIN_SOURCE)

    def test_both_dialogs_share_one_task_dialog_implementation_that_opens_the_given_page(self):
        self.assertEqual(MAIN_SOURCE.count("TaskDialogIndirect"), 1)
        self.assertIn("webbrowser.open(", MAIN_SOURCE)
        self.assertNotIn("webbrowser.open(VIGEMBUS_RELEASES_URL)", MAIN_SOURCE)

    def test_hidhide_is_required_inside_the_pcsx2_block_only_after_vigem_connects_and_before_configuration(self):
        self.assertEqual(MAIN_SOURCE.count(".require_installed("), 1)
        start = MAIN_SOURCE.index("virtual_gamepad_required = can_send_input and game_mode == \"PCSX2\"")
        block_end = MAIN_SOURCE.index("\n        else:\n            if virtual_gamepad_backend.connected:", start)
        block = MAIN_SOURCE[start:block_end]
        self.assertIn(".require_installed(", block)
        connect = block.index("virtual_gamepad_backend.connect()")
        require = block.index(".require_installed(")
        configure = block.index("hidhide_configurator.ensure_configured(")
        self.assertLess(connect, require)
        self.assertLess(require, configure)

    def test_the_loop_handles_the_hidhide_error_before_the_generic_runtime_error_and_stops_without_retry(self):
        start = MAIN_SOURCE.index("virtual_gamepad_required = can_send_input and game_mode == \"PCSX2\"")
        block = MAIN_SOURCE[start:]
        hidhide_except = block.index("except HidHideNotInstalledError")
        generic_except = block.index("except RuntimeError as exc:")
        self.assertLess(hidhide_except, generic_except)
        handler = block[hidhide_except:generic_except]
        self.assertIn("show_hidhide_unavailable()", handler)
        self.assertIn("running = False", handler)

    def test_main_imports_the_error_class(self):
        self.assertRegex(MAIN_SOURCE, r"from hidhide_pcsx2 import [^\n]*HidHideNotInstalledError")

    def test_the_existing_vigembus_dialog_text_and_call_are_unchanged(self):
        self.assertIn("ViGEmBusをインストールしてWindowsを再起動してください。", MAIN_SOURCE)
        self.assertIn("ViGEmBusが利用可能になるまで、", MAIN_SOURCE)
        self.assertIn("仮想ゲームパッドを開始できませんでした。", MAIN_SOURCE)
        self.assertIn("VIGEMBUS_RELEASES_URL = \"https://github.com/nefarius/ViGEmBus/releases\"", MAIN_SOURCE)
        self.assertIn("action = show_virtual_gamepad_unavailable(exc)", MAIN_SOURCE)


if __name__ == "__main__":
    unittest.main()
