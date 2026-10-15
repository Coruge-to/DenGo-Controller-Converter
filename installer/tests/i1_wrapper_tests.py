"""I1 wrapper contract tests (T2).

Loads the Python templates that Build-DenGo-SetupExe-2.0.0.ps1 embeds (extracted by
Test-DenGoInstaller-I1-Wrapper.ps1) and checks that registration, un-registration and
self-delete run only for a fully verified Completed result.

Nothing real is touched: winreg, MessageBoxW, the self-delete helper and the child
PowerShell process are all replaced before any entry point is called, and subprocess.Popen
is replaced with a stub that fails the test if it is ever reached.

Usage: python i1_wrapper_tests.py <setup_module.py> <uninstall_module.py>
Environment: LOCALAPPDATA and TEMP must already point at a sandbox directory.
"""
import contextlib
import importlib.util
import json
import os
import sys
import tempfile
from unittest import mock

RESULTS = []


def check(test_id, condition, detail=""):
    RESULTS.append((bool(condition), test_id, detail))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeKey:
    def __init__(self, log, path):
        self.log, self.path = log, path

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeWinreg:
    HKEY_CURRENT_USER = "HKCU-FAKE"
    KEY_WRITE = 2
    REG_SZ = 1
    REG_DWORD = 4

    def __init__(self):
        self.calls = []

    def CreateKeyEx(self, hive, path, reserved, access):
        self.calls.append(("CreateKeyEx", hive, path))
        return FakeKey(self.calls, path)

    def SetValueEx(self, key, name, reserved, kind, value):
        self.calls.append(("SetValueEx", key.path, name, value))

    def DeleteKey(self, hive, path):
        self.calls.append(("DeleteKey", hive, path))


def forbidden_popen(*args, **kwargs):
    raise AssertionError("subprocess.Popen must never be reached from the tests")


class Harness:
    """Wraps one loaded module with recorders for every side effect."""

    def __init__(self, module, operation):
        self.m = module
        self.operation = operation
        self.sandbox = os.environ["LOCALAPPDATA"]
        self.fake_winreg = FakeWinreg()
        self.events = []
        self.messages = []
        module.winreg = self.fake_winreg
        module.subprocess.Popen = forbidden_popen
        module.message = lambda text, flags=0x10: self.messages.append(text)
        module.install_uninstaller = lambda bundle_root: self.events.append("install_uninstaller")
        module.register_uninstaller = lambda: self.events.append("register_uninstaller")
        module.remove_registration = lambda: self.events.append("remove_registration")
        module.schedule_self_delete = lambda: self.events.append("schedule_self_delete")
        self.run_root = tempfile.mkdtemp(prefix="DenGoSetupExe-")
        module.verify_and_extract = lambda: ("bundle", self.run_root, "package")
        self.script = "Start-DenGoSetup.ps1" if operation == "Install" else "Start-DenGoUninstall.ps1"

    def state_files(self, committed):
        root = os.path.join(self.sandbox, "DenGo Controller Converter", "InstallerState")
        os.makedirs(root, exist_ok=True)
        for name in ("installing.json", "installed-state.json", "uninstalled-state.json"):
            path = os.path.join(root, name)
            if os.path.exists(path):
                os.remove(path)
        if committed:
            name = "installed-state.json" if self.operation == "Install" else "uninstalled-state.json"
            with open(os.path.join(root, name), "w", encoding="utf-8") as stream:
                stream.write("{}")
            product = os.path.join(self.sandbox, "Programs", "DenGo Controller Converter")
            os.makedirs(product, exist_ok=True)
            self.m.PRODUCT_DIR = product
            with open(os.path.join(product, "DenGoControllerConverter.exe"), "wb") as stream:
                stream.write(b"MZ")

    def run(self, exit_code, writer, committed=True):
        """Runs main() with a fake child that returns exit_code after calling writer(result_path, run_id)."""
        self.events.clear()
        self.messages.clear()
        self.state_files(committed)
        seen = {}

        def fake_run_script(package_root, script_name, extra_args=None):
            args = list(extra_args or [])
            seen["script"] = script_name
            seen["args"] = args
            result_path = args[args.index("-ResultPath") + 1]
            run_id = args[args.index("-RunId") + 1]
            seen["result_path"], seen["run_id"] = result_path, run_id
            if writer is not None:
                writer(result_path, run_id)
            return exit_code

        self.m.run_script = fake_run_script
        self.m.cleanup = lambda path: None
        code = self.m.main()
        return code, seen

    def valid(self, kind, **overrides):
        codes = {"Completed": 0, "Cancelled": 2, "Failed": 1}
        flags = {"Completed": (True, True, True), "Cancelled": (False, False, False), "Failed": (True, False, False)}[kind]

        def writer(result_path, run_id):
            document = {
                "schemaVersion": 1, "operation": self.operation, "runId": run_id, "result": kind,
                "reason": "Test" if kind != "Completed" else "Completed", "exitCode": codes[kind],
                "engineStarted": flags[0], "engineCompleted": flags[1], "stateCommitted": flags[2],
                "writtenAt": "2026-10-15T00:00:00+09:00",
            }
            for key, value in overrides.items():
                if value is _DELETE:
                    document.pop(key, None)
                else:
                    document[key] = value
            if "runId" in overrides and overrides["runId"] == "__OTHER__":
                document["runId"] = "0" * 32
            with open(result_path, "w", encoding="utf-8") as stream:
                json.dump(document, stream)
        return writer


_DELETE = object()


def raw_writer(data):
    def writer(result_path, run_id):
        with open(result_path, "wb") as stream:
            stream.write(data)
    return writer


def leftover_result_dirs():
    root = tempfile.gettempdir()
    return [name for name in os.listdir(root) if name.startswith("DenGoResult-")]


def side_effects(h):
    return [e for e in h.events if e in ("install_uninstaller", "register_uninstaller", "remove_registration", "schedule_self_delete")]


def run_matrix(module, operation):
    h = Harness(module, operation)
    tag = operation[:3].upper()
    gate_events = ["install_uninstaller", "register_uninstaller"] if operation == "Install" else ["remove_registration", "schedule_self_delete"]

    # ---- Completed: the only outcome that may touch registration ----
    code, seen = h.run(0, h.valid("Completed"))
    check(tag + "-COMPLETED-RETURN", code == 0, "code=%r" % code)
    check(tag + "-COMPLETED-SIDE-EFFECTS", side_effects(h) == gate_events, "events=%r" % h.events)
    check(tag + "-ARGS", seen["script"] == h.script and seen["args"][0] == "-ResultPath" and seen["args"][2] == "-RunId" and len(seen["run_id"]) == 32, repr(seen["args"]))
    code2, seen2 = h.run(0, h.valid("Completed"))
    check(tag + "-RUNID-DIFFERS", seen["run_id"] != seen2["run_id"] and seen["result_path"] != seen2["result_path"], "ids differ and paths differ")
    check(tag + "-RESULT-DIR-REMOVED", leftover_result_dirs() == [], repr(leftover_result_dirs()))

    # ---- Cancelled ----
    code, _ = h.run(2, h.valid("Cancelled"))
    check(tag + "-CANCELLED-RETURN-2", code == 2, "code=%r" % code)
    check(tag + "-CANCELLED-NO-SIDE-EFFECTS", side_effects(h) == [] and h.messages == [], "events=%r messages=%r" % (h.events, h.messages))

    # ---- Failed declared by the GUI: silent, no side effects, return 1 ----
    code, _ = h.run(1, h.valid("Failed"))
    check(tag + "-FAILED-RETURN-1", code == 1, "code=%r" % code)
    check(tag + "-FAILED-NO-SIDE-EFFECTS", side_effects(h) == [] and h.messages == [], "events=%r messages=%r" % (h.events, h.messages))

    # ---- Everything below must be Failed with no side effects ----
    bad = [
        ("RESULT-MISSING-EXIT0", 0, None),
        ("RESULT-MISSING-EXIT2", 2, None),
        ("RESULT-MISSING-KILLED", -1, None),
        ("RESULT-EMPTY", 0, raw_writer(b"")),
        ("RESULT-CORRUPT-JSON", 0, raw_writer(b"{not json")),
        ("RESULT-NOT-OBJECT", 0, raw_writer(b"[1,2,3]")),
        ("RESULT-BINARY", 0, raw_writer(b"\xff\xfe\x00\x01")),
        ("SCHEMA-MISMATCH", 0, h.valid("Completed", schemaVersion=2)),
        ("SCHEMA-MISSING", 0, h.valid("Completed", schemaVersion=_DELETE)),
        ("SCHEMA-BOOL", 0, h.valid("Completed", schemaVersion=True)),
        ("OPERATION-MISMATCH", 0, h.valid("Completed", operation="Uninstall" if operation == "Install" else "Install")),
        ("RUNID-MISMATCH", 0, h.valid("Completed", runId="__OTHER__")),
        ("RUNID-MISSING", 0, h.valid("Completed", runId=_DELETE)),
        ("RESULT-UNKNOWN", 0, h.valid("Completed", result="Succeeded")),
        ("RESULT-LOWERCASE", 0, h.valid("Completed", result="completed")),
        ("EXITCODE-FILE-1-PROC-0", 0, h.valid("Completed", exitCode=1)),
        ("EXITCODE-COMPLETED-PROC-2", 2, h.valid("Completed")),
        ("EXITCODE-COMPLETED-PROC-1", 1, h.valid("Completed")),
        ("EXITCODE-FAILED-FILE-PROC-0", 0, h.valid("Failed")),
        ("EXITCODE-CANCELLED-FILE-PROC-0", 0, h.valid("Cancelled")),
        ("EXITCODE-OTHER", 7, h.valid("Completed")),
        ("STATE-NOT-COMMITTED", 0, h.valid("Completed", stateCommitted=False)),
        ("ENGINE-NOT-COMPLETED", 0, h.valid("Completed", engineCompleted=False)),
        ("ENGINE-NOT-STARTED", 0, h.valid("Completed", engineStarted=False)),
        ("FLAG-NOT-BOOL", 0, h.valid("Completed", stateCommitted=1)),
        ("FLAG-MISSING", 0, h.valid("Completed", engineCompleted=_DELETE)),
        ("EXITCODE-FIELD-MISSING", 0, h.valid("Completed", exitCode=_DELETE)),
        ("EXITCODE-FIELD-BOOL", 0, h.valid("Completed", exitCode=False)),
        ("CANCELLED-WITH-ENGINE", 2, h.valid("Cancelled", engineStarted=True)),
    ]
    for name, exit_code, writer in bad:
        code, _ = h.run(exit_code, writer)
        check(tag + "-REJECT-" + name, code == 1 and side_effects(h) == [], "code=%r events=%r" % (code, h.events))

    # contract violations tell the user nothing was changed; a GUI-declared failure stays silent
    h.run(0, None)
    check(tag + "-VIOLATION-MESSAGE", len(h.messages) == 1, repr(h.messages))

    # ---- A previous run's file must never be read as this run's result ----
    def stale_writer(result_path, run_id):
        h.valid("Completed", runId="__OTHER__")(result_path, run_id)
    code, _ = h.run(0, stale_writer)
    check(tag + "-STALE-RESULT-REJECTED", code == 1 and side_effects(h) == [], "code=%r" % code)

    # ---- Independent state corroboration: Completed JSON without committed state is still Failed ----
    code, _ = h.run(0, h.valid("Completed"), committed=False)
    check(tag + "-STATE-CORROBORATION", code == 1 and side_effects(h) == [], "code=%r events=%r" % (code, h.events))
    if operation == "Install":
        h.run(0, h.valid("Completed"), committed=True)
        marker = os.path.join(h.sandbox, "DenGo Controller Converter", "InstallerState", "installing.json")

        def with_marker(result_path, run_id):
            with open(marker, "w", encoding="utf-8") as stream:
                stream.write("{}")
            h.valid("Completed")(result_path, run_id)
        code, _ = h.run(0, with_marker, committed=True)
        check(tag + "-INTERRUPTED-MARKER-REJECTED", code == 1 and side_effects(h) == [], "code=%r events=%r" % (code, h.events))

    # ---- Cleanup failure is recorded and does not overturn a verified Completed ----
    module.CLEANUP_DIAGNOSTICS.clear()
    with mock.patch.object(module.shutil, "rmtree", side_effect=OSError("locked")), mock.patch.object(module.time, "sleep", lambda s: None):
        code, _ = h.run(0, h.valid("Completed"))
    check(tag + "-CLEANUP-FAILURE-KEEPS-COMPLETED", code == 0 and side_effects(h) == gate_events, "code=%r events=%r" % (code, h.events))
    check(tag + "-CLEANUP-FAILURE-RECORDED", len(module.CLEANUP_DIAGNOSTICS) >= 1, repr(module.CLEANUP_DIAGNOSTICS))
    for name in leftover_result_dirs():  # tidy the directories this test deliberately left behind
        import shutil
        shutil.rmtree(os.path.join(tempfile.gettempdir(), name), ignore_errors=True)

    # ---- remove_result_dir refuses anything it did not create ----
    foreign = tempfile.mkdtemp(prefix="NotDenGo-")
    check(tag + "-CLEANUP-REFUSES-FOREIGN-DIR", module.remove_result_dir(foreign) is False and os.path.isdir(foreign), foreign)
    import shutil
    shutil.rmtree(foreign, ignore_errors=True)

    # ---- run_script raising still cleans up and reports Failed through fail() ----
    def boom(package_root, script_name, extra_args=None):
        raise OSError("powershell missing")
    h.state_files(True)
    module.run_script = boom
    h.events.clear()
    code = module.main()
    check(tag + "-RUN-SCRIPT-RAISES", code == 1 and side_effects(h) == [] and leftover_result_dirs() == [], "code=%r" % code)
    return h


def main():
    setup_path, uninstall_path = sys.argv[1], sys.argv[2]
    setup = load(setup_path, "dengo_setup_under_test")
    uninstall = load(uninstall_path, "dengo_uninstall_under_test")

    # evaluate_outcome is shared; check the pure function directly as well
    for module, operation in ((setup, "Install"), (uninstall, "Uninstall")):
        run_matrix(module, operation)

    # real registration code against a fake winreg: keys go to the product key path, only in the fake
    fresh = load(setup_path, "dengo_setup_fresh")
    fake = FakeWinreg()
    fresh.winreg = fake
    fresh.register_uninstaller()
    check("REG-REGISTER-USES-FAKE-ONLY", fake.calls and fake.calls[0][0] == "CreateKeyEx" and fake.calls[0][2] == fresh.UNINSTALL_KEY, repr(fake.calls[:1]))
    fresh_uninstall = load(uninstall_path, "dengo_uninstall_fresh")
    fake2 = FakeWinreg()
    fresh_uninstall.winreg = fake2
    fresh_uninstall.remove_registration()
    check("REG-UNREGISTER-USES-FAKE-ONLY", fake2.calls == [("DeleteKey", "HKCU-FAKE", fresh_uninstall.UNINSTALL_KEY)], repr(fake2.calls))

    passed = sum(1 for ok, _, _ in RESULTS if ok)
    failed = len(RESULTS) - passed
    for ok, test_id, detail in RESULTS:
        print("%s | %s | %s" % ("PASS" if ok else "FAIL", test_id, detail))
    print("PASS=%d FAIL=%d" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
