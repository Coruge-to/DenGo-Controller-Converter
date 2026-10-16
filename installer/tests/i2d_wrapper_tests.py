"""I2-D wrapper contract tests (written RED first; plan i2d-implementation-plan.md sections 1.2, 3 (Stage D2) and 5.4).

Loads the Python modules that Build-DenGo-SetupExe-2.0.0.ps1 assembles (extracted by Test-DenGoInstaller-I2D-Static.ps1 /
Test-DenGoInstaller-I2D-Wrapper.ps1 with the PowerShell AST) and checks the post-step lock contract:

  static   <setup.py> <uninstall.py> <engine-lock-name>      structure checks with the Python ast (S9..S13, S16, S18, S19)
  behavior <setup.py> <uninstall.py> <lock-child.ps1>        main() driven against REAL Win32 mutexes with throw-away names (W0..W13)

Safety: every test takes only a throw-away name (Global\\DenGoI2DTest-<uuid>). The module's LOCK_NAME is replaced by that name before main()
runs; if the product lock name is held by any other module global the behaviour tests refuse to run. winreg, MessageBoxW, the self-delete
helper process and the engine PowerShell are all replaced; subprocess.Popen is replaced by a stub that fails the test when it is reached
(the tests themselves use the saved REAL_POPEN only for their own throw-away PowerShell probes). LOCALAPPDATA and TEMP must point at a sandbox.

Names bound by these tests are the ones fixed by plan section 1.2 / Stage D2: LOCK_NAME, LOCK_ACCESS, POST_STEP_LOCK_TIMEOUT_SECONDS,
POST_STEP_LOCK_POLL_SECONDS, acquire_post_step_lock, release_post_step_lock, verify_state_locked, the reasons PostStepLockTimeout and
PostStepStateChanged. The behaviour tests read LOCK_NAME / the two timing constants at call time (they patch the module globals).
"""
import ast
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import types
import uuid
from ctypes import wintypes

RESULTS = []
REAL_POPEN = subprocess.Popen
CONTRACT_LOCK_NAME = "Global\\DenGoControllerConverter.Transaction"
HELPER_SHA256 = "D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD"
SYNC_MODIFY = 0x00100001
EFFECT_NAMES = ("install_uninstaller", "register_uninstaller", "remove_registration", "schedule_self_delete")
GATE = {"Install": ["install_uninstaller", "register_uninstaller"], "Uninstall": ["remove_registration", "schedule_self_delete"]}
# I1 three-state contract: the source of these two functions must stay byte-identical (SHA-256 of the source segment, newlines normalised)
PIN_EVALUATE_OUTCOME = "D31AA6795CAF63D0DF510A7B3B9B4FD1398B8815ABCA6E0A86B974315549C701"
PIN_IS_CONTRACT_VIOLATION = "527E6FE38F7EFD4A654D09A7FAF57B71731D389A4E5EA9E3D30C319E14731578"


def check(test_id, condition, detail=""):
    RESULTS.append((bool(condition), test_id, str(detail).replace("\r", " ").replace("\n", " ")))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WATCHDOG_SECONDS = 90


def emit():
    passed = sum(1 for ok, _, _ in RESULTS if ok)
    for ok, test_id, detail in RESULTS:
        print("%s | %s | %s" % ("PASS" if ok else "FAIL", test_id, detail))
    print("PASS=%d FAIL=%d" % (passed, len(RESULTS) - passed))
    sys.stdout.flush()
    return len(RESULTS) - passed


def watchdog_abort(test_id):
    # a wrapper without a bounded wait would hang the scenario forever: report it as a failure and stop the whole run
    check("WATCHDOG-" + test_id, False, "scenario did not finish within %d s (an unbounded wait hangs here)" % WATCHDOG_SECONDS)
    emit()
    os._exit(1)


def guard(test_id, function, *args):
    timer = threading.Timer(WATCHDOG_SECONDS, watchdog_abort, args=(test_id,))
    timer.daemon = True
    timer.start()
    try:
        function(*args)
    except Exception as exc:  # a missing function / constant is a RED result, never a crash of the whole run
        check(test_id, False, "exception: %s: %s | %s" % (type(exc).__name__, exc, traceback.format_exc().strip().splitlines()[-3:]))
    finally:
        timer.cancel()


# =====================================================================================================================
# static mode
# =====================================================================================================================
def parents_of(tree):
    return {child: parent for parent in ast.walk(tree) for child in ast.iter_child_nodes(parent)}


def call_name(node):
    function = node.func
    if isinstance(function, ast.Name):
        return function.id
    if isinstance(function, ast.Attribute):
        return function.attr
    return None


def calls_in(node, names=None):
    return [n for n in ast.walk(node) if isinstance(n, ast.Call) and (names is None or call_name(n) in names)]


def module_constants(tree):
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and isinstance(node.value, ast.Constant):
            values[node.targets[0].id] = node.value.value
    return values


def functions_named(tree, name):
    return [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name]


def string_constants(tree):
    found = [n for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    found.sort(key=lambda n: (n.lineno, n.col_offset))
    return found


def enclosing_function(parents, node):
    current = parents.get(node)
    while current is not None and not isinstance(current, ast.FunctionDef):
        current = parents.get(current)
    return current


def static_checks(kind, path, engine_name):
    with open(path, "r", encoding="ascii") as stream:
        text = stream.read()
    tree = ast.parse(text)
    parents = parents_of(tree)
    constants = module_constants(tree)
    tag = "[" + kind + "]"
    effects = GATE["Install" if kind == "setup" else "Uninstall"]

    # S9: the wrapper takes the name the engine takes (a difference between the two languages would silently split the exclusion)
    name = constants.get("LOCK_NAME")
    check("S9-wrapper-lock-name-is-the-contract-literal" + tag, name == CONTRACT_LOCK_NAME, "LOCK_NAME=%r" % (name,))
    check("S9-wrapper-lock-name-equals-the-engine-literal" + tag, name is not None and name == engine_name, "wrapper=%r engine=%r" % (name, engine_name))

    # S10: DACL literal: exactly two Allow ACEs, mask 0x100001, one of them BUILTIN\Administrators, the other the (runtime) current user SID
    candidates = [n.value for n in string_constants(tree) if "A;;" in n.value or n.value.startswith("D:")]
    blob = "\x00".join(candidates)
    aces = re.findall(r"\(([A-Za-z]);;([^;)]*);;;([^)]*)\)", blob)
    dynamic = [a for a in aces if (a[2] == "" or "\x00" in a[2] or "{" in a[2] or "%" in a[2])]
    fixed = [a for a in aces if a not in dynamic]
    masks_ok = len(aces) > 0 and all(a[1].lower() == "0x100001" for a in aces)
    only_allow = len(aces) > 0 and all(a[0] == "A" for a in aces) and "(D;" not in blob
    check("S10-wrapper-dacl-literal-is-user-and-administrators-only" + tag,
          len(aces) == 2 and masks_ok and only_allow and len(dynamic) == 1 and [a[2] for a in fixed] == ["BA"],
          "ACEs=%r" % (aces,))
    check("S10-wrapper-open-access-is-synchronize-modify" + tag, constants.get("LOCK_ACCESS") == SYNC_MODIFY, "LOCK_ACCESS=%r" % (constants.get("LOCK_ACCESS"),))

    # S11: the engine (run_script via execute_operation) is outside the lock region; every post-step action is inside it
    acquire_calls = calls_in(tree, ("acquire_post_step_lock",))
    acquire_defs = functions_named(tree, "acquire_post_step_lock")
    owner = None
    region = None
    detail = "no call to acquire_post_step_lock"
    if acquire_calls:
        owner = enclosing_function(parents, acquire_calls[0])
        tries = [t for t in ast.walk(owner) if isinstance(t, ast.Try) and any(calls_in(stmt, ("release_post_step_lock",)) for stmt in t.finalbody)] if owner is not None else []
        if tries:
            start = min(acquire_calls[0].lineno, min(t.lineno for t in tries))
            region = (start, max(t.end_lineno for t in tries))
            detail = "lock region lines %d-%d in %s()" % (region[0], region[1], owner.name)
        else:
            detail = "acquire_post_step_lock is not paired with a try/finally that releases it"
    engine_inside = []
    effects_outside = []
    effects_found = []
    if region is not None:
        engine_inside = [c for c in calls_in(owner, ("run_script", "execute_operation")) if region[0] <= c.lineno <= region[1]]
        effects_found = calls_in(owner, effects)
        effects_outside = [c for c in effects_found if not (region[0] <= c.lineno <= region[1])]
    check("S11-engine-run-is-outside-the-lock-region" + tag, region is not None and not engine_inside, detail + "; engine calls inside the region: %d" % len(engine_inside))
    check("S11-post-step-actions-are-inside-the-lock-region" + tag, region is not None and len(effects_found) == len(effects) and not effects_outside,
          "actions found in the locking function: %d (expected %s); outside the region: %d" % (len(effects_found), effects, len(effects_outside)))

    # S12: every release is in a finally
    releases = [c for c in calls_in(tree, ("release_post_step_lock",)) if enclosing_function(parents, c) is None or enclosing_function(parents, c).name != "release_post_step_lock"]
    in_finally = 0
    for c in releases:
        node = c
        while node is not None:
            parent = parents.get(node)
            if isinstance(parent, ast.Try) and node in parent.finalbody:
                in_finally += 1
                break
            node = parent
    check("S12-lock-is-released-in-finally" + tag, len(releases) >= 1 and in_finally == len(releases), "release calls=%d in finally=%d" % (len(releases), in_finally))

    # S13: OpenMutexW first (an existing object is opened with Synchronize|Modify; CreateMutexW demands ALL_ACCESS), then CreateMutexW, then a re-open on a creation race
    order = []
    if acquire_defs:
        for n in calls_in(acquire_defs[0], ("OpenMutexW", "CreateMutexW")):   # calls only: argtypes / restype assignments are not acquisitions
            order.append((n.lineno, n.col_offset, call_name(n)))
        order.sort()
    names_in_order = [o[2] for o in order]
    check("S13-open-before-create-then-reopen-on-race" + tag,
          bool(acquire_defs) and names_in_order[:1] == ["OpenMutexW"] and names_in_order.count("OpenMutexW") >= 2 and names_in_order.count("CreateMutexW") == 1,
          "acquire_post_step_lock defined=%s; API order=%s" % (bool(acquire_defs), names_in_order))

    # S16: bounded retry: 120 seconds, polled every 200 ms
    check("S16-bounded-retry-120-seconds-poll-200ms" + tag,
          constants.get("POST_STEP_LOCK_TIMEOUT_SECONDS") == 120 and constants.get("POST_STEP_LOCK_POLL_SECONDS") == 0.2,
          "timeout=%r poll=%r" % (constants.get("POST_STEP_LOCK_TIMEOUT_SECONDS"), constants.get("POST_STEP_LOCK_POLL_SECONDS")))

    # S18: the two new failure reasons exist as literals; the state check under the lock is its own function
    literals = {n.value for n in string_constants(tree)}
    check("S18-new-failure-reasons-are-defined" + tag, "PostStepLockTimeout" in literals and "PostStepStateChanged" in literals and bool(functions_named(tree, "verify_state_locked")),
          "PostStepLockTimeout=%s PostStepStateChanged=%s verify_state_locked=%s" % ("PostStepLockTimeout" in literals, "PostStepStateChanged" in literals, bool(functions_named(tree, "verify_state_locked"))))

    # S19: the I1 three-state contract is untouched (exit codes, schema version, evaluate_outcome / is_contract_violation byte-for-byte)
    def segment_sha(function_name):
        found = functions_named(tree, function_name)
        if len(found) != 1:
            return "<missing>"
        return hashlib.sha256(ast.get_source_segment(text, found[0]).replace("\r\n", "\n").encode("ascii")).hexdigest().upper()

    constants_ok = (constants.get("EXIT_COMPLETED") == 0 and constants.get("EXIT_FAILED") == 1 and constants.get("EXIT_CANCELLED") == 2 and constants.get("RESULT_SCHEMA_VERSION") == 1
                    and constants.get("RESULT_FILE_NAME") == "result.json")
    eo, icv = segment_sha("evaluate_outcome"), segment_sha("is_contract_violation")
    check("S19-i1-result-contract-is-unchanged" + tag, constants_ok and eo == PIN_EVALUATE_OUTCOME.upper() and icv == PIN_IS_CONTRACT_VIOLATION.upper(),
          "constants ok=%s evaluate_outcome=%s is_contract_violation=%s" % (constants_ok, eo[:12], icv[:12]))


def run_static(setup_path, uninstall_path, engine_name):
    static_checks("setup", setup_path, engine_name)
    static_checks("uninstall", uninstall_path, engine_name)


# =====================================================================================================================
# Win32 helpers (kernel32 / advapi32 through ctypes; every object is a throw-away name)
# =====================================================================================================================
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
adv = ctypes.WinDLL("advapi32", use_last_error=True)


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("nLength", wintypes.DWORD), ("lpSecurityDescriptor", ctypes.c_void_p), ("bInheritHandle", wintypes.BOOL)]


k32.CreateMutexW.argtypes = [ctypes.POINTER(SECURITY_ATTRIBUTES), wintypes.BOOL, wintypes.LPCWSTR]
k32.CreateMutexW.restype = wintypes.HANDLE
k32.OpenMutexW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
k32.OpenMutexW.restype = wintypes.HANDLE
k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
k32.WaitForSingleObject.restype = wintypes.DWORD
k32.ReleaseMutex.argtypes = [wintypes.HANDLE]
k32.ReleaseMutex.restype = wintypes.BOOL
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.CloseHandle.restype = wintypes.BOOL
k32.LocalFree.argtypes = [ctypes.c_void_p]
k32.LocalFree.restype = ctypes.c_void_p
adv.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
adv.ConvertStringSecurityDescriptorToSecurityDescriptorW.restype = wintypes.BOOL
adv.GetKernelObjectSecurity.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
adv.GetKernelObjectSecurity.restype = wintypes.BOOL
adv.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
adv.ConvertSecurityDescriptorToStringSecurityDescriptorW.restype = wintypes.BOOL

SID_ALIASES = {"BA": "S-1-5-32-544", "SY": "S-1-5-18", "WD": "S-1-1-0", "AU": "S-1-5-11", "LS": "S-1-5-19", "NS": "S-1-5-20", "BU": "S-1-5-32-545", "IU": "S-1-5-4"}
_USER_SID = []


def run_capture(command, timeout=120):
    process = REAL_POPEN(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=False, creationflags=0x08000000)
    out, err = process.communicate(timeout=timeout)
    return process.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def current_user_sid():
    if not _USER_SID:
        code, out, _ = run_capture(["whoami.exe", "/user", "/fo", "csv", "/nh"], 30)
        _USER_SID.append(out.strip().split(",")[-1].strip().strip('"'))
    return _USER_SID[0]


def new_lock_name():
    return "Global\\DenGoI2DTest-" + uuid.uuid4().hex


def engine_sddl():
    sid = current_user_sid()
    return "D:(A;;0x100001;;;%s)(A;;0x100001;;;BA)" % sid


SYSTEM_ONLY_SDDL = "D:(A;;GA;;;SY)"


class Holder:
    """A thread that owns a real named mutex (a mutex is owned per thread, so the wrapper's thread sees it held)."""

    def __init__(self, name, sddl=None, acquire=True):
        self.name, self.sddl, self.acquire = name, sddl, acquire
        self.ready, self.command = threading.Event(), threading.Event()
        self.action, self.handle, self.error, self.acquired = "", None, "", False
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        if not self.ready.wait(20) or self.error:
            raise RuntimeError("holder failed: " + (self.error or "timeout"))

    def _run(self):
        descriptor = ctypes.c_void_p()
        try:
            attributes = None
            if self.sddl:
                if not adv.ConvertStringSecurityDescriptorToSecurityDescriptorW(self.sddl, 1, ctypes.byref(descriptor), None):
                    raise OSError("SDDL conversion failed: %d" % ctypes.get_last_error())
                attributes = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), descriptor, False)
            handle = k32.CreateMutexW(ctypes.byref(attributes) if attributes is not None else None, False, self.name)
            if not handle:
                raise OSError("CreateMutexW failed: %d" % ctypes.get_last_error())
            self.handle = handle
            if self.acquire:
                self.acquired = k32.WaitForSingleObject(handle, 0) in (0, 0x80)
        except Exception as exc:
            self.error = "%s: %s" % (type(exc).__name__, exc)
        finally:
            if descriptor.value:
                k32.LocalFree(descriptor)
        self.ready.set()
        if not self.handle:
            return
        self.command.wait()
        if self.action == "release" and self.acquired:
            k32.ReleaseMutex(self.handle)
            self.acquired = False
        # "abandon": the thread ends while it owns the mutex; the handle stays open so the object survives as abandoned

    def _send(self, what):
        self.action = what
        self.command.set()
        self.thread.join(20)

    def release(self):
        self._send("release")

    def abandon(self):
        self._send("abandon")

    def close(self):
        if self.thread.is_alive():
            self.release()
        if self.handle:
            k32.CloseHandle(self.handle)
            self.handle = None


def probe(name):
    """ABSENT (no such object) | FREE (could be taken, released at once) | HELD | DENIED. Runs on its own thread: the mutex of the calling thread would be re-entrant."""
    out = {}

    def run():
        handle = k32.OpenMutexW(SYNC_MODIFY, False, name)
        if not handle:
            error = ctypes.get_last_error()
            out["v"] = "ABSENT" if error == 2 else ("DENIED" if error == 5 else "ERR%d" % error)
            return
        result = k32.WaitForSingleObject(handle, 0)
        if result in (0, 0x80):
            out["v"] = "FREE"
            k32.ReleaseMutex(handle)
        elif result == 0x102:
            out["v"] = "HELD"
        else:
            out["v"] = "WAIT%d" % result
        k32.CloseHandle(handle)

    thread = threading.Thread(target=run)
    thread.start()
    thread.join(10)
    return out.get("v", "TIMEOUT")


def dacl_of(name):
    """The DACL of a live mutex as a list of (type, rights, sid) or None when it cannot be read / does not exist."""
    holder = {}

    def run():
        handle = k32.OpenMutexW(0x00020000, False, name)   # READ_CONTROL
        if not handle:
            return
        try:
            needed = wintypes.DWORD(0)
            adv.GetKernelObjectSecurity(handle, 4, None, 0, ctypes.byref(needed))
            buffer = ctypes.create_string_buffer(needed.value)
            if not adv.GetKernelObjectSecurity(handle, 4, buffer, needed.value, ctypes.byref(needed)):
                return
            text = ctypes.c_void_p()
            if not adv.ConvertSecurityDescriptorToStringSecurityDescriptorW(buffer, 1, 4, ctypes.byref(text), None):
                return
            holder["sddl"] = ctypes.wstring_at(text.value)
            k32.LocalFree(text)
        finally:
            k32.CloseHandle(handle)

    thread = threading.Thread(target=run)
    thread.start()
    thread.join(10)
    if "sddl" not in holder:
        return None
    result = []
    for ace in re.findall(r"\(([^)]*)\)", holder["sddl"]):
        fields = ace.split(";")
        rights = int(fields[2], 0) if fields[2].lower().startswith("0x") else fields[2]
        result.append((fields[0], rights, SID_ALIASES.get(fields[5], fields[5])))
    return result


# =====================================================================================================================
# behaviour mode
# =====================================================================================================================
class FakeKey:
    def __init__(self, path):
        self.path = path

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
        return FakeKey(path)

    def SetValueEx(self, key, name, reserved, kind, value):
        self.calls.append(("SetValueEx", key.path, name, value))

    def DeleteKey(self, hive, path):
        self.calls.append(("DeleteKey", hive, path))


def forbidden_popen(*args, **kwargs):
    raise AssertionError("subprocess.Popen must never be reached from the tests")


class Harness:
    def __init__(self, module, operation, child_script):
        self.m, self.operation, self.child = module, operation, child_script
        self.sandbox = os.environ["LOCALAPPDATA"]
        self.fake_winreg = FakeWinreg()
        self.events, self.messages = [], []
        self.engine_done = threading.Event()
        self.lock_name = ""
        self.raise_on = set()
        self.dacl_at_first_effect = "unset"
        self.ps_probe_at_first_effect = False
        self.ps_probe_result = None
        self.elapsed = 0.0
        self.original_schedule_self_delete = getattr(module, "schedule_self_delete", None)
        module.winreg = self.fake_winreg
        module.subprocess.Popen = forbidden_popen
        module.message = lambda text, flags=0x10: self.messages.append(text)
        module.install_uninstaller = lambda bundle_root: self._effect("install_uninstaller")
        module.register_uninstaller = lambda: self._effect("register_uninstaller")
        module.remove_registration = lambda: self._effect("remove_registration")
        module.schedule_self_delete = lambda: self._effect("schedule_self_delete")
        self.run_root = tempfile.mkdtemp(prefix="DenGoSetupExe-")
        module.verify_and_extract = lambda: ("bundle", self.run_root, "package")
        module.cleanup = lambda path: None
        self.script = "Start-DenGoSetup.ps1" if operation == "Install" else "Start-DenGoUninstall.ps1"

    # -- recording stubs ---------------------------------------------------------------------------------------------
    def _effect(self, name):
        self.events.append((name, probe(self.lock_name), time.monotonic()))
        if self.dacl_at_first_effect == "unset":
            self.dacl_at_first_effect = dacl_of(self.lock_name)
        if self.ps_probe_at_first_effect and self.ps_probe_result is None:
            self.ps_probe_result = ps_probe(self.child, self.lock_name)
        if name in self.raise_on:
            raise RuntimeError("injected failure in " + name)

    # -- sandbox state -----------------------------------------------------------------------------------------------
    def paths(self):
        root = os.path.join(self.sandbox, "DenGo Controller Converter", "InstallerState")
        product = os.path.join(self.sandbox, "Programs", "DenGo Controller Converter")
        return {"root": root, "product": product, "exe": os.path.join(product, "DenGoControllerConverter.exe"),
                "installing": os.path.join(root, "installing.json"), "uninstalling": os.path.join(root, "uninstalling.json"),
                "installed": os.path.join(root, "installed-state.json"), "uninstalled": os.path.join(root, "uninstalled-state.json")}

    def reset_state(self):
        p = self.paths()
        os.makedirs(p["root"], exist_ok=True)
        os.makedirs(p["product"], exist_ok=True)
        for key in ("installing", "uninstalling", "installed", "uninstalled", "exe"):
            if os.path.exists(p[key]):
                os.remove(p[key])
        self.m.PRODUCT_DIR = p["product"]
        self.m.UNINSTALL_EXE = os.path.join(p["product"], "Uninstall.exe")
        if self.operation == "Install":
            self.write(p["installed"])
            with open(p["exe"], "wb") as stream:
                stream.write(b"MZ")
        else:
            self.write(p["uninstalled"])
        return p

    @staticmethod
    def write(path, text="{}"):
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(text)

    def valid_result(self, kind="Completed"):
        codes = {"Completed": 0, "Cancelled": 2, "Failed": 1}
        flags = {"Completed": (True, True, True), "Cancelled": (False, False, False), "Failed": (True, False, False)}[kind]

        def writer(result_path, run_id):
            document = {"schemaVersion": 1, "operation": self.operation, "runId": run_id, "result": kind, "reason": "Test" if kind != "Completed" else "Completed",
                        "exitCode": codes[kind], "engineStarted": flags[0], "engineCompleted": flags[1], "stateCommitted": flags[2], "writtenAt": "2026-10-16T00:00:00+09:00"}
            with open(result_path, "w", encoding="utf-8") as stream:
                json.dump(document, stream)
        return writer

    # -- one run of main() -------------------------------------------------------------------------------------------
    def run(self, exit_code=0, writer=None, lock_name=None, timeout=5.0, poll=0.05):
        self.events.clear()
        self.messages.clear()
        self.fake_winreg.calls.clear()
        self.engine_done.clear()
        self.dacl_at_first_effect = "unset"
        self.ps_probe_result = None
        self.lock_name = lock_name or new_lock_name()
        self.m.LOCK_NAME = self.lock_name
        self.m.POST_STEP_LOCK_TIMEOUT_SECONDS = timeout
        self.m.POST_STEP_LOCK_POLL_SECONDS = poll
        self.reset_state()
        if writer is None and exit_code == 0:
            writer = self.valid_result("Completed")

        def fake_run_script(package_root, script_name, extra_args=None):
            args = list(extra_args or [])
            result_path = args[args.index("-ResultPath") + 1]
            run_id = args[args.index("-RunId") + 1]
            self.events.append(("run_script", probe(self.lock_name), time.monotonic()))
            if writer is not None:
                writer(result_path, run_id)
            self.engine_done.set()
            return exit_code

        self.m.run_script = fake_run_script
        started = time.monotonic()
        code = self.m.main()
        self.elapsed = time.monotonic() - started
        return code

    def effects(self):
        return [e for e in self.events if e[0] in EFFECT_NAMES]


def ps_probe(child_script, name):
    result_path = os.path.join(tempfile.mkdtemp(prefix="DenGoI2DProbe-"), "probe.json")
    command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", child_script, "-LockName", name, "-Mode", "Probe", "-ResultPath", result_path]
    code, out, err = run_capture(command, 120)
    if not os.path.isfile(result_path):
        return {"error": "no result file; exit=%s %s" % (code, err.strip()[:200])}
    with open(result_path, "r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def with_holder(h, mode, action=None, lock_name=None, timeout=5.0, hold_after_engine=0.5, finish="release", exit_code=0, writer=None):
    """Runs main() while a holder thread owns the lock. mode: engine | system | free-object. finish: release | abandon | none (never)."""
    name = lock_name or new_lock_name()
    sddl = SYSTEM_ONLY_SDDL if mode == "system" else engine_sddl()
    holder = Holder(name, sddl, acquire=(mode != "free-object"))
    control = {}

    def controller():
        if not h.engine_done.wait(30):
            return
        time.sleep(hold_after_engine)
        if action is not None:
            action()
        control["released_at"] = time.monotonic()
        if finish == "release":
            holder.release()
        elif finish == "abandon":
            holder.abandon()

    thread = threading.Thread(target=controller, daemon=True)
    thread.start()
    try:
        code = h.run(exit_code, writer, lock_name=name, timeout=timeout)
    finally:
        if finish == "none":
            h.engine_done.set()
        thread.join(30)
        control["after_probe"] = probe(name)
        holder.close()
    return code, control, name


def no_side_effects(h):
    return h.effects() == [] and h.fake_winreg.calls == []


def scenario_w1(h):
    op = h.operation
    code = h.run()
    eff = h.effects()
    run = [e for e in h.events if e[0] == "run_script"]
    check("W1-%s-post-step-runs-in-order" % op, code == 0 and [e[0] for e in eff] == GATE[op], "code=%r events=%r" % (code, [e[:2] for e in h.events]))
    check("W1-%s-lock-held-during-every-post-step-action" % op, len(eff) == 2 and all(e[1] == "HELD" for e in eff), "lock state at each action: %r" % ([e[:2] for e in eff],))
    check("W6-%s-engine-runs-without-the-wrapper-lock" % op, len(run) == 1 and run[0][1] in ("ABSENT", "FREE"), "lock state while the engine runs: %r" % ([e[:2] for e in run],))
    check("W1-%s-lock-released-after-main" % op, probe(h.lock_name) in ("ABSENT", "FREE"), "lock state after main: %s" % probe(h.lock_name))


def scenario_w2(h):
    op = h.operation
    code, control, name = with_holder(h, "engine", finish="none", timeout=1.0)
    check("W2-%s-times-out-failed-without-side-effects" % op, code == 1 and no_side_effects(h), "code=%r effects=%r winreg=%r" % (code, h.effects(), h.fake_winreg.calls))
    check("W2-%s-wait-is-bounded-by-the-timeout" % op, 0.8 <= h.elapsed <= 8.0, "elapsed=%.2fs (timeout patched to 1.0s)" % h.elapsed)
    check("W2-%s-user-is-told-why" % op, len(h.messages) >= 1, "messages=%r" % (h.messages,))
    check("W2-%s-holder-keeps-the-lock" % op, control.get("after_probe") == "HELD", "lock state after the failed wait: %r (the wrapper must never steal or release a lock it does not own)" % (control.get("after_probe"),))


def scenario_w3(h):
    op = h.operation
    code, control, name = with_holder(h, "engine", finish="release")
    eff = h.effects()
    released = control.get("released_at", 0.0)
    check("W3-%s-waits-for-the-holder-then-proceeds" % op,
          code == 0 and [e[0] for e in eff] == GATE[op] and len(eff) == 2 and all(e[2] >= released - 0.02 for e in eff) and all(e[1] == "HELD" for e in eff),
          "code=%r actions=%r release at %.3f; first action at %s" % (code, [e[:2] for e in eff], released, ("%.3f" % eff[0][2]) if eff else "-"))
    check("W3-%s-wrapper-gives-the-lock-back-when-done" % op, control.get("after_probe") in ("FREE", "ABSENT"), "lock state after main: %r (the wrapper must release exactly what it took)" % (control.get("after_probe"),))


def scenario_w4(h):
    op = h.operation
    code, control, name = with_holder(h, "engine", finish="abandon")
    eff = h.effects()
    abandoned_at = control.get("released_at", 0.0)
    check("W4-%s-abandoned-mutex-counts-as-acquired" % op,
          code == 0 and [e[0] for e in eff] == GATE[op] and all(e[1] == "HELD" for e in eff) and all(e[2] >= abandoned_at - 0.02 for e in eff),
          "code=%r actions=%r holder abandoned at %.3f, first action at %s (an abandoned lock is taken like any other, after the wait)" % (code, [e[:2] for e in eff], abandoned_at, ("%.3f" % eff[0][2]) if eff else "-"))
    check("W4-%s-abandoned-lock-is-released-exactly-once" % op, control.get("after_probe") in ("FREE", "ABSENT"), "lock state after main: %r (taking an abandoned lock and then not releasing it leaves it owned)" % (control.get("after_probe"),))
    p = h.paths()
    mutate = (lambda: h.write(p["installing"])) if op == "Install" else (lambda: h.write(p["installed"]))
    code, control, name = with_holder(h, "engine", action=mutate, finish="abandon")
    check("W4-%s-abandonment-is-no-evidence-the-state-decides" % op, code == 1 and no_side_effects(h),
          "code=%r effects=%r (abandoned + changed state is Failed because of the state, not the abandonment)" % (code, h.effects()))


def scenario_w5(h):
    op = h.operation
    p = h.paths()
    if op == "Install":
        variants = [("installing-marker-appeared", lambda: h.write(p["installing"])),
                    ("uninstalling-marker-appeared", lambda: h.write(p["uninstalling"])),
                    ("installed-state-vanished", lambda: os.remove(p["installed"])),
                    ("app-exe-vanished", lambda: os.remove(p["exe"]))]
    else:
        variants = [("installed-state-came-back", lambda: h.write(p["installed"])),
                    ("uninstalling-marker-appeared", lambda: h.write(p["uninstalling"])),
                    ("uninstalled-state-vanished", lambda: os.remove(p["uninstalled"]))]
    code, control, name = with_holder(h, "engine", finish="release")
    eff = h.effects()
    released = control.get("released_at", 0.0)
    check("W5-%s-control-waiting-without-a-change-completes" % op, code == 0 and [e[0] for e in eff] == GATE[op] and all(e[2] >= released - 0.02 for e in eff),
          "code=%r actions=%r (after the holder released at %.3f)" % (code, [e[0] for e in eff], released))
    for label, mutator in variants:
        code, control, name = with_holder(h, "engine", action=mutator, finish="release")
        check("W5-%s-state-changed-during-the-wait-%s" % (op, label), code == 1 and no_side_effects(h) and len(h.messages) >= 1,
              "code=%r effects=%r winreg=%r messages=%d" % (code, h.effects(), h.fake_winreg.calls, len(h.messages)))


def scenario_w7(h):
    op = h.operation
    for name in GATE[op]:
        h.raise_on = {name}
        code = h.run()
        eff = h.effects()
        later = GATE[op][GATE[op].index(name) + 1:]
        raised = [e for e in eff if e[0] == name]
        check("W7-%s-failure-in-%s-happens-under-the-lock-and-releases-it" % (op, name),
              code == 1 and len(raised) == 1 and raised[0][1] == "HELD" and not [e for e in eff if e[0] in later] and probe(h.lock_name) in ("ABSENT", "FREE") and len(h.messages) >= 1,
              "code=%r lock at the failing action=%r later actions=%r lock after main=%s messages=%d" % (code, [e[1] for e in raised], [e[0] for e in eff if e[0] in later], probe(h.lock_name), len(h.messages)))
    h.raise_on = set()


def scenario_w8(h):
    op = h.operation
    code, control, name = with_holder(h, "free-object", finish="release")
    eff = h.effects()
    check("W8-%s-opens-an-existing-synchronize-modify-object" % op, code == 0 and [e[0] for e in eff] == GATE[op] and all(e[1] == "HELD" for e in eff),
          "code=%r actions=%r (an existing object whose DACL grants only Synchronize|Modify must be opened, not re-created)" % (code, [e[:2] for e in eff]))
    code = h.run()
    aces = h.dacl_at_first_effect
    expected = sorted([current_user_sid(), "S-1-5-32-544"])
    ok = isinstance(aces, list) and len(aces) == 2 and all(a[0] == "A" and a[1] == SYNC_MODIFY for a in aces) and sorted(a[2] for a in aces) == expected
    check("W9-%s-created-object-has-the-contract-dacl" % op, code == 0 and ok, "DACL of the wrapper-created lock: %r (expected Allow 0x100001 for %r)" % (aces, expected))
    code, control, name = with_holder(h, "system", finish="none", timeout=1.0)
    check("W8-%s-unopenable-object-fails-closed-and-bounded" % op, code == 1 and no_side_effects(h) and h.elapsed <= 8.0, "code=%r effects=%r elapsed=%.2fs (a DACL that denies this user must never let the post step run)" % (code, h.effects(), h.elapsed))


def scenario_w9_cross_engine(h):
    op = h.operation
    h.ps_probe_at_first_effect = True
    code = h.run()
    r = h.ps_probe_result
    check("W9-%s-engine-cannot-take-the-lock-while-the-wrapper-holds-it" % op, code == 0 and isinstance(r, dict) and r.get("Acquired") is False and r.get("Reason") == "HeldByOther",
          "wrapper holds the lock, PowerShell engine DgLock-TryAcquire says %r" % (r,))
    h.ps_probe_at_first_effect = False
    name = new_lock_name()
    work = tempfile.mkdtemp(prefix="DenGoI2DHold-")
    signal, release, result = os.path.join(work, "sig.txt"), os.path.join(work, "rel.txt"), os.path.join(work, "res.json")
    command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", h.child, "-LockName", name, "-Mode", "Hold", "-Security", "Product", "-Signal", signal, "-Release", release, "-ResultPath", result]
    holder = REAL_POPEN(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=0x08000000)
    try:
        deadline = time.monotonic() + 90
        while not os.path.isfile(signal) and time.monotonic() < deadline:
            time.sleep(0.1)
        state = open(signal).read() if os.path.isfile(signal) else "TIMEOUT"
        code1 = h.run(0, None, lock_name=name, timeout=1.0)
        refused = (code1 == 1 and no_side_effects(h))
        check("W9-%s-wrapper-sees-the-engine-lock-and-fails-closed" % op, state == "held" and refused, "engine child state=%s; wrapper code=%r effects=%r" % (state, code1, h.effects()))
        with open(release, "w") as stream:
            stream.write("go")
        holder.wait(60)
        code2 = h.run(0, None, lock_name=name, timeout=5.0)
        check("W9-%s-wrapper-proceeds-once-the-engine-released-it" % op, code2 == 0 and [e[0] for e in h.effects()] == GATE[op], "code=%r actions=%r" % (code2, [e[0] for e in h.effects()]))
    finally:
        if holder.poll() is None:
            holder.kill()


def scenario_w10(h):
    op = h.operation
    name = new_lock_name()
    holder = Holder(name, engine_sddl())
    try:
        cases = [("cancelled", 2, h.valid_result("Cancelled"), 2), ("failed", 1, h.valid_result("Failed"), 1), ("result-missing", 0, (lambda result_path, run_id: None), 1)]
        for label, exit_code, writer, expected in cases:
            code = h.run(exit_code, writer, lock_name=name, timeout=5.0)
            check("W10-%s-%s-never-waits-for-the-lock" % (op, label), code == expected and no_side_effects(h) and h.elapsed < 2.0, "code=%r (expected %r) effects=%r elapsed=%.2fs with the lock held by someone else" % (code, expected, h.effects(), h.elapsed))
    finally:
        holder.close()


def scenario_w13(h):
    # the real schedule_self_delete: the helper process must be started under the lock; the helper bytes are the pinned ones
    launches = []
    sha_found = []

    def recorder(command, *args, **kwargs):
        launches.append((probe(h.lock_name), list(command)))
        helper = command[command.index("-File") + 1]
        with open(helper, "rb") as stream:
            sha_found.append(hashlib.sha256(stream.read()).hexdigest().upper())
        return types.SimpleNamespace(pid=4242)

    h.m.schedule_self_delete = h.original_schedule_self_delete
    h.m.subprocess.Popen = recorder
    try:
        code = h.run()
    finally:
        h.m.subprocess.Popen = forbidden_popen
        h.m.schedule_self_delete = lambda: h._effect("schedule_self_delete")
    check("W13-uninstall-helper-process-starts-under-the-lock", code == 0 and len(launches) == 1 and launches[0][0] == "HELD", "code=%r helper launches=%d lock state at Popen=%r" % (code, len(launches), [l[0] for l in launches]))
    check("W13-uninstall-helper-bytes-are-the-pinned-helper", sha_found == [HELPER_SHA256], "SHA-256 of the helper file handed to Popen: %r" % (sha_found,))


def run_behavior(setup_path, uninstall_path, child_script):
    for kind, path in (("Install", setup_path), ("Uninstall", uninstall_path)):
        module = load(path, "dengo_%s_i2d" % kind.lower())
        hidden = [n for n, v in vars(module).items() if isinstance(v, str) and "DenGoControllerConverter.Transaction" in v and n != "LOCK_NAME"]
        check("W0-%s-no-hidden-product-lock-name" % kind, not hidden, "module globals that hold the product lock name besides LOCK_NAME: %r (they could not be patched to a throw-away name)" % (hidden,))
        if hidden:
            continue
        h = Harness(module, kind, child_script)
        scenarios = [("W1", scenario_w1), ("W2", scenario_w2), ("W3", scenario_w3), ("W4", scenario_w4), ("W5", scenario_w5), ("W7", scenario_w7), ("W8", scenario_w8), ("W9x", scenario_w9_cross_engine), ("W10", scenario_w10)]
        if kind == "Uninstall":
            scenarios.append(("W13", scenario_w13))
        for label, function in scenarios:
            guard("%s-%s-scenario-crashed" % (label, kind), function, h)


def main():
    mode = sys.argv[1]
    if mode == "static":
        run_static(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == "behavior":
        run_behavior(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print("unknown mode " + mode)
        return 2
    return 0 if emit() == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
