#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot = "$env:USERPROFILE\Documents\Program\DenGo-Controller-Converter-Separate",
    [string]$ZipPath = "$env:USERPROFILE\Downloads\DenGo-Controller-Converter-Setup-2.0.0.zip",
    [string]$OutputRoot = "$env:USERPROFILE\Downloads\DenGo-SetupExe-Registered-v7"
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$stage = 'startup'
$expectedZipSha = '9868997F47B87D874F2687E808275C7BAD1462F0E0AFF0EC610726EDFA21887D'
$expectedSourceCommit = 'd8f5231a6b4fdffd804f5caf0c14756057a63e9a'
$workRoot = ''
try {
    $report = New-Object System.Collections.ArrayList
    function Add-Report { param([AllowEmptyString()][string]$Text) [void]$report.Add($Text) }
    function Invoke-ProcessChecked {
        param([string]$FilePath,[string]$ArgumentLine,[string]$Label,[string]$WorkingDirectory)
        $stdout = Join-Path $workRoot ($Label + '-stdout.txt')
        $stderr = Join-Path $workRoot ($Label + '-stderr.txt')
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentLine -WorkingDirectory $WorkingDirectory -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        Add-Report ($Label + '|ExitCode=' + [string]$process.ExitCode)
        if (Test-Path -LiteralPath $stdout -PathType Leaf) { foreach ($line in @(Get-Content -LiteralPath $stdout -Encoding UTF8)) { Add-Report ($Label + '|OUT|' + [string]$line) } }
        if (Test-Path -LiteralPath $stderr -PathType Leaf) { foreach ($line in @(Get-Content -LiteralPath $stderr -Encoding UTF8)) { Add-Report ($Label + '|ERR|' + [string]$line) } }
        if ($process.ExitCode -ne 0) { throw ($Label + ' failed. ExitCode=' + [string]$process.ExitCode) }
    }
    function Get-PeMachine {
        param([string]$Path)
        $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.BinaryReader($stream)
            if ($reader.ReadUInt16() -ne 0x5A4D) { return 'NotPE' }
            $stream.Position = 0x3C
            $offset = $reader.ReadInt32()
            if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { return 'InvalidPE' }
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x00004550) { return 'InvalidPE' }
            $machine = $reader.ReadUInt16()
            if ($machine -eq 0x014C) { return 'x86' }
            if ($machine -eq 0x8664) { return 'x64' }
            if ($machine -eq 0xAA64) { return 'arm64' }
            return ('0x{0:X4}' -f $machine)
        } finally { $stream.Dispose() }
    }

    $stage = 'preconditions'
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw ('Repository missing: ' + $RepositoryRoot) }
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw ('ZIP missing: ' + $ZipPath) }
    $zipSha = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($zipSha,$expectedZipSha,[System.StringComparison]::Ordinal)) { throw ('ZIP SHA256 mismatch. Actual=' + $zipSha) }
    $pythonExe = Join-Path $RepositoryRoot 'venv_exe\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) { throw ('Python missing: ' + $pythonExe) }
    $iconPath = Join-Path $RepositoryRoot 'installer\assets\images\DenGo-Controller-Converter.ico'
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw ('Icon missing: ' + $iconPath) }
    $workRoot = Join-Path $env:TEMP ('DenGo-SetupExe-Registered-v7-' + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($workRoot) | Out-Null
    $extractRoot = Join-Path $workRoot 'package-check'
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
    $packageRoots = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
    if (@($packageRoots).Count -ne 1) { throw ('ZIP top-level directory count was not 1. Count=' + [string]@($packageRoots).Count) }
    $packageRoot = $packageRoots[0].FullName
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals([string]$manifest.SourceCommit,$expectedSourceCommit,[System.StringComparison]::Ordinal)) { throw ('SourceCommit mismatch: ' + [string]$manifest.SourceCommit) }
    foreach ($entry in @($manifest.Files)) {
        $relative = ([string]$entry.Path).Replace('/',[System.IO.Path]::DirectorySeparatorChar)
        $full = Join-Path $packageRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw ('Manifest file missing: ' + [string]$entry.Path) }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if (-not [string]::Equals($actual,[string]$entry.SHA256,[System.StringComparison]::Ordinal)) { throw ('Manifest mismatch: ' + [string]$entry.Path) }
    }
    Add-Report ('InputZipSHA256=' + $zipSha)
    Add-Report ('SourceCommit=' + [string]$manifest.SourceCommit)
    Add-Report ('ManifestEntryCount=' + [string]@($manifest.Files).Count)

    $stage = 'prepare output'
    if (Test-Path -LiteralPath $OutputRoot -PathType Container) {
        $archiveRoot = $OutputRoot + '-previous-' + [System.DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $OutputRoot -Destination $archiveRoot
        Add-Report ('PreviousOutputArchive=' + $archiveRoot)
    }
    [System.IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    $payloadZip = Join-Path $workRoot 'DenGo-Controller-Converter-Setup-2.0.0.zip'
    Copy-Item -LiteralPath $ZipPath -Destination $payloadZip -Force

    $versionFile = Join-Path $workRoot 'version_info.txt'
    $versionContent = @'
VSVersionInfo(
  ffi=FixedFileInfo(filevers=(2,0,0,0), prodvers=(2,0,0,0), mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0,0)),
  kids=[StringFileInfo([StringTable('041104B0', [
    StringStruct('CompanyName', 'Coruge-to'),
    StringStruct('FileDescription', 'DenGo Controller Converter Setup'),
    StringStruct('FileVersion', '2.0.0.0'),
    StringStruct('InternalName', 'DenGoControllerConverterSetup'),
    StringStruct('LegalCopyright', 'Copyright (c) Coruge-to'),
    StringStruct('OriginalFilename', 'DenGo-Controller-Converter-Setup-2.0.0.exe'),
    StringStruct('ProductName', 'DenGo Controller Converter'),
    StringStruct('ProductVersion', '2.0.0.0')
  ])]), VarFileInfo([VarStruct('Translation', [1041, 1200])])]
)
'@
    [System.IO.File]::WriteAllText($versionFile,$versionContent,[System.Text.Encoding]::ASCII)

    $commonTemplate = @'
import ctypes
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

EXPECTED_ZIP_SHA256 = "__ZIP_SHA__"
EXPECTED_SOURCE_COMMIT = "__COMMIT__"
TITLE = "DenGo Controller Converter"
PRODUCT_DIR = os.path.join(os.environ["LOCALAPPDATA"], "Programs", "DenGo Controller Converter")
UNINSTALL_EXE = os.path.join(PRODUCT_DIR, "Uninstall.exe")
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\DenGoControllerConverter"

def message(text, flags=0x10):
    ctypes.windll.user32.MessageBoxW(None, text, TITLE, flags)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()

def fail(text):
    message(text)
    return 1

def verify_and_extract():
    bundle_root = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(sys.executable)))
    zip_path = os.path.join(bundle_root, "DenGo-Controller-Converter-Setup-2.0.0.zip")
    if not os.path.isfile(zip_path):
        raise RuntimeError("\u5185\u5305\u30D1\u30C3\u30B1\u30FC\u30B8\u304C\u898B\u3064\u304B\u308A\u307E\u305B\u3093\u3002")
    if sha256(zip_path) != EXPECTED_ZIP_SHA256:
        raise RuntimeError("\u5185\u5305\u30D1\u30C3\u30B1\u30FC\u30B8\u306ESHA-256\u304C\u4E00\u81F4\u3057\u307E\u305B\u3093\u3002")
    run_root = tempfile.mkdtemp(prefix="DenGoSetupExe-")
    with zipfile.ZipFile(zip_path, "r") as archive:
        archive.extractall(run_root)
    roots = [os.path.join(run_root, name) for name in os.listdir(run_root) if os.path.isdir(os.path.join(run_root, name))]
    if len(roots) != 1:
        raise RuntimeError("\u5C55\u958B\u5F8C\u306E\u30D1\u30C3\u30B1\u30FC\u30B8\u69CB\u9020\u304C\u4E0D\u6B63\u3067\u3059\u3002")
    package_root = roots[0]
    with open(os.path.join(package_root, "package-manifest.json"), "r", encoding="utf-8-sig") as stream:
        manifest = json.load(stream)
    if manifest.get("SourceCommit") != EXPECTED_SOURCE_COMMIT:
        raise RuntimeError("SourceCommit\u304C\u4E00\u81F4\u3057\u307E\u305B\u3093\u3002")
    for entry in manifest.get("Files", []):
        full = os.path.join(package_root, *entry["Path"].split("/"))
        if not os.path.isfile(full) or sha256(full) != entry["SHA256"]:
            raise RuntimeError("\u5185\u5305\u30D5\u30A1\u30A4\u30EB\u306E\u691C\u8A3C\u306B\u5931\u6557\u3057\u307E\u3057\u305F: " + entry["Path"])
    return bundle_root, run_root, package_root

def run_script(package_root, script_name, extra_args=None):
    script_path = os.path.join(package_root, "installer", "scripts", script_name)
    command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script_path] + list(extra_args or [])
    completed = subprocess.run(command, cwd=package_root, shell=False)
    return int(completed.returncode)

EXIT_COMPLETED = 0
EXIT_FAILED = 1
EXIT_CANCELLED = 2
RESULT_SCHEMA_VERSION = 1
RESULT_FILE_NAME = "result.json"
RESULT_DIR_PREFIX = "DenGoResult-"
CLEANUP_DIAGNOSTICS = []

def state_root():
    return os.path.join(os.environ["LOCALAPPDATA"], "DenGo Controller Converter", "InstallerState")

def new_result_channel():
    result_dir = tempfile.mkdtemp(prefix=RESULT_DIR_PREFIX)
    run_id = os.urandom(16).hex()
    return result_dir, os.path.join(result_dir, RESULT_FILE_NAME), run_id

def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)

def evaluate_outcome(exit_code, result_path, run_id, operation):
    # Returns (outcome, reason). Only an exact and fully consistent Completed record unlocks side effects.
    if not _is_int(exit_code):
        return "Failed", "ExitCodeInvalid"
    try:
        if not os.path.isfile(result_path):
            return "Failed", "ResultMissing"
        with open(result_path, "rb") as stream:
            document = json.loads(stream.read().decode("utf-8-sig"))
    except Exception:
        return "Failed", "ResultCorrupt"
    if not isinstance(document, dict):
        return "Failed", "ResultCorrupt"
    if not _is_int(document.get("schemaVersion")) or document["schemaVersion"] != RESULT_SCHEMA_VERSION:
        return "Failed", "ResultSchema"
    if document.get("operation") != operation:
        return "Failed", "ResultOperation"
    if not isinstance(document.get("runId"), str) or document["runId"] != run_id:
        return "Failed", "ResultRunId"
    expected_codes = {"Completed": EXIT_COMPLETED, "Cancelled": EXIT_CANCELLED, "Failed": EXIT_FAILED}
    result = document.get("result")
    if not isinstance(result, str) or result not in expected_codes:
        return "Failed", "ResultUnknown"
    declared = document.get("exitCode")
    flags = [document.get(name) for name in ("engineStarted", "engineCompleted", "stateCommitted")]
    if not _is_int(declared) or not all(isinstance(flag, bool) for flag in flags):
        return "Failed", "ResultCorrupt"
    if declared != expected_codes[result] or declared != exit_code:
        return "Failed", "ResultMismatch"
    started, completed, committed = flags
    if result == "Completed":
        if not (started and completed and committed):
            return "Failed", "ResultInvariant"
        return "Completed", "Completed"
    if result == "Cancelled":
        if started or completed or committed:
            return "Failed", "ResultInvariant"
        return "Cancelled", "Cancelled"
    reason = document.get("reason")
    return "Failed", reason if isinstance(reason, str) and reason else "Failed"

def is_contract_violation(reason):
    return reason == "ExitCodeInvalid" or reason.startswith("Result")

def verify_committed_state(operation):
    try:
        root = state_root()
        if operation == "Install":
            if os.path.isfile(os.path.join(root, "installing.json")):
                return False, "ResultStateInterrupted"
            if not os.path.isfile(os.path.join(root, "installed-state.json")):
                return False, "ResultStateMissing"
            if not os.path.isfile(os.path.join(PRODUCT_DIR, "DenGoControllerConverter.exe")):
                return False, "ResultStateMissing"
            return True, "Completed"
        if not os.path.isfile(os.path.join(root, "uninstalled-state.json")):
            return False, "ResultStateMissing"
        return True, "Completed"
    except Exception:
        return False, "ResultStateMissing"

def record_cleanup_failure(path, detail):
    entry = "{} | {} | {}".format(time.strftime("%Y-%m-%dT%H:%M:%S"), path, detail)
    CLEANUP_DIAGNOSTICS.append(entry)
    try:
        with open(os.path.join(tempfile.gettempdir(), "DenGo-ResultCleanup-{}.txt".format(os.getpid())), "a", encoding="utf-8") as stream:
            stream.write(entry + "\n")
    except Exception:
        pass

def remove_result_dir(result_dir):
    # Deletes only a directory this process created under TEMP; a failure is recorded and never changes the verified outcome.
    try:
        full = os.path.abspath(result_dir)
        temp_root = os.path.abspath(tempfile.gettempdir())
        if os.path.normcase(os.path.dirname(full)) != os.path.normcase(temp_root) or not os.path.basename(full).startswith(RESULT_DIR_PREFIX) or os.path.islink(full):
            raise RuntimeError("Refusing to delete an unexpected result directory.")
        last_error = ""
        for _ in range(10):
            try:
                shutil.rmtree(full)
                return True
            except FileNotFoundError:
                return True
            except Exception as exc:
                last_error = str(exc)
                time.sleep(0.2)
        raise RuntimeError(last_error)
    except Exception as exc:
        record_cleanup_failure(result_dir, str(exc))
        return False

def execute_operation(operation, script_name, package_root):
    result_dir, result_path, run_id = new_result_channel()
    try:
        code = run_script(package_root, script_name, ["-ResultPath", result_path, "-RunId", run_id])
        outcome, reason = evaluate_outcome(code, result_path, run_id, operation)
        if outcome == "Completed":
            committed, why = verify_committed_state(operation)
            if not committed:
                outcome, reason = "Failed", why
    finally:
        remove_result_dir(result_dir)
    return outcome, reason

def cleanup(path):
    for _ in range(10):
        try:
            shutil.rmtree(path)
            return
        except Exception:
            time.sleep(0.2)
'@

    $uninstallMain = @'
import winreg

def remove_registration():
    try:
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY)
    except FileNotFoundError:
        pass

def schedule_self_delete():
    import base64
    exe_path = os.path.abspath(sys.executable)
    parent = os.path.dirname(exe_path)
    target_pid = os.getpid()
    helper_bytes = base64.b64decode("77u/I3JlcXVpcmVzIC1WZXJzaW9uIDUuMQ0KW0NtZGxldEJpbmRpbmcoKV0NCnBhcmFtKA0KICAgIFtQYXJhbWV0ZXIoTWFuZGF0b3J5PSR0cnVlKV1baW50XSRUYXJnZXRQaWQsDQogICAgW1BhcmFtZXRlcihNYW5kYXRvcnk9JHRydWUpXVtzdHJpbmddJFRhcmdldFBhdGgsDQogICAgW1BhcmFtZXRlcihNYW5kYXRvcnk9JHRydWUpXVtzdHJpbmddJFBhcmVudFBhdGgsDQogICAgW1BhcmFtZXRlcihNYW5kYXRvcnk9JHRydWUpXVtzdHJpbmddJExvZ1BhdGgsDQogICAgW1BhcmFtZXRlcihNYW5kYXRvcnk9JHRydWUpXVtzdHJpbmddJEhlbHBlclBhdGgNCikNClNldC1TdHJpY3RNb2RlIC1WZXJzaW9uIDIuMA0KJEVycm9yQWN0aW9uUHJlZmVyZW5jZSA9ICdDb250aW51ZScNCiRyZWNvcmQgPSBbb3JkZXJlZF1Aew0KICAgIFRhcmdldFBpZCA9ICRUYXJnZXRQaWQNCiAgICBUYXJnZXRQYXRoID0gJFRhcmdldFBhdGgNCiAgICBQYXJlbnRQYXRoID0gJFBhcmVudFBhdGgNCiAgICBTdGFydGVkID0gKEdldC1EYXRlKS5Ub1N0cmluZygnbycpDQogICAgUHJvY2Vzc1ByZXNlbnRBdFN0YXJ0ID0gJGZhbHNlDQogICAgUHJpbWFyeVdhaXQgPSAnJw0KICAgIE1hdGNoaW5nUHJvY2Vzc1dhaXRzID0gMA0KICAgIEZpcnN0RGVsZXRlU3VjY2VlZGVkID0gJGZhbHNlDQogICAgUmV0cnlDb3VudCA9IDANCiAgICBEZWxldGVkID0gJGZhbHNlDQogICAgRGlyZWN0b3J5UmVtb3ZlZCA9ICRmYWxzZQ0KICAgIEVycm9ycyA9IEAoKQ0KICAgIENvbXBsZXRlZCA9ICcnDQogICAgSGVscGVyRGVsZXRlZCA9ICRmYWxzZQ0KfQ0KZnVuY3Rpb24gV3JpdGUtUmVjb3JkIHsNCiAgICAkcmVjb3JkLkNvbXBsZXRlZCA9IChHZXQtRGF0ZSkuVG9TdHJpbmcoJ28nKQ0KICAgICRqc29uID0gJHJlY29yZCB8IENvbnZlcnRUby1Kc29uIC1EZXB0aCA2DQogICAgJHRlbXBMb2cgPSAkTG9nUGF0aCArICcudG1wJw0KICAgICRqc29uIHwgT3V0LUZpbGUgLUxpdGVyYWxQYXRoICR0ZW1wTG9nIC1FbmNvZGluZyBVVEY4IC1Gb3JjZQ0KICAgIE1vdmUtSXRlbSAtTGl0ZXJhbFBhdGggJHRlbXBMb2cgLURlc3RpbmF0aW9uICRMb2dQYXRoIC1Gb3JjZQ0KfQ0KdHJ5IHsNCiAgICAkdGFyZ2V0UHJvY2VzcyA9IEAoR2V0LVByb2Nlc3MgLUlkICRUYXJnZXRQaWQgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpDQogICAgaWYgKEAoJHRhcmdldFByb2Nlc3MpLkNvdW50IC1lcSAxKSB7DQogICAgICAgICRyZWNvcmQuUHJvY2Vzc1ByZXNlbnRBdFN0YXJ0ID0gJHRydWUNCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIFdhaXQtUHJvY2VzcyAtSWQgJFRhcmdldFBpZCAtVGltZW91dCAzMCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICAgICAgICAgJHJlY29yZC5QcmltYXJ5V2FpdCA9ICdXYWl0ZWRGb3JFeGl0Jw0KICAgICAgICB9IGNhdGNoIHsNCiAgICAgICAgICAgICRyZWNvcmQuUHJpbWFyeVdhaXQgPSAnV2FpdEZhaWxlZCcNCiAgICAgICAgICAgICRyZWNvcmQuRXJyb3JzICs9IFtzdHJpbmddJF8uRXhjZXB0aW9uLk1lc3NhZ2UNCiAgICAgICAgfQ0KICAgIH0gZWxzZSB7DQogICAgICAgICRyZWNvcmQuUHJpbWFyeVdhaXQgPSAnQWxyZWFkeUV4aXRlZCcNCiAgICB9DQogICAgaWYgKCRyZWNvcmQuUHJpbWFyeVdhaXQgLWluIEAoJ1dhaXRlZEZvckV4aXQnLCdBbHJlYWR5RXhpdGVkJykpIHsNCiAgICAgICAgZm9yICgkc2NhbiA9IDA7ICRzY2FuIC1sdCA2MDsgJHNjYW4rKykgew0KICAgICAgICAgICAgJG1hdGNoaW5nID0gQCgNCiAgICAgICAgICAgICAgICBHZXQtQ2ltSW5zdGFuY2UgV2luMzJfUHJvY2VzcyAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSB8DQogICAgICAgICAgICAgICAgICAgIFdoZXJlLU9iamVjdCB7DQogICAgICAgICAgICAgICAgICAgICAgICAtbm90IFtzdHJpbmddOjpJc051bGxPcldoaXRlU3BhY2UoW3N0cmluZ10kXy5FeGVjdXRhYmxlUGF0aCkgLWFuZA0KICAgICAgICAgICAgICAgICAgICAgICAgW3N0cmluZ106OkVxdWFscyhbc3RyaW5nXSRfLkV4ZWN1dGFibGVQYXRoLCRUYXJnZXRQYXRoLFtTeXN0ZW0uU3RyaW5nQ29tcGFyaXNvbl06Ok9yZGluYWxJZ25vcmVDYXNlKQ0KICAgICAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICApDQogICAgICAgICAgICBpZiAoQCgkbWF0Y2hpbmcpLkNvdW50IC1lcSAwKSB7IGJyZWFrIH0NCiAgICAgICAgICAgICRyZWNvcmQuTWF0Y2hpbmdQcm9jZXNzV2FpdHMrKw0KICAgICAgICAgICAgU3RhcnQtU2xlZXAgLU1pbGxpc2Vjb25kcyAyNTANCiAgICAgICAgfQ0KICAgICAgICAkcmVtYWluaW5nID0gQCgNCiAgICAgICAgICAgIEdldC1DaW1JbnN0YW5jZSBXaW4zMl9Qcm9jZXNzIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlIHwNCiAgICAgICAgICAgICAgICBXaGVyZS1PYmplY3Qgew0KICAgICAgICAgICAgICAgICAgICAtbm90IFtzdHJpbmddOjpJc051bGxPcldoaXRlU3BhY2UoW3N0cmluZ10kXy5FeGVjdXRhYmxlUGF0aCkgLWFuZA0KICAgICAgICAgICAgICAgICAgICBbc3RyaW5nXTo6RXF1YWxzKFtzdHJpbmddJF8uRXhlY3V0YWJsZVBhdGgsJFRhcmdldFBhdGgsW1N5c3RlbS5TdHJpbmdDb21wYXJpc29uXTo6T3JkaW5hbElnbm9yZUNhc2UpDQogICAgICAgICAgICAgICAgfQ0KICAgICAgICApDQogICAgICAgIGlmIChAKCRyZW1haW5pbmcpLkNvdW50IC1uZSAwKSB7DQogICAgICAgICAgICAkcmVjb3JkLkVycm9ycyArPSAnTWF0Y2hpbmcgZXhlY3V0YWJsZSBwcm9jZXNzIHJlbWFpbmVkIGFmdGVyIHdhaXQgZGVhZGxpbmUuJw0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgICAgICBSZW1vdmUtSXRlbSAtTGl0ZXJhbFBhdGggJFRhcmdldFBhdGggLUZvcmNlIC1FcnJvckFjdGlvbiBTdG9wDQogICAgICAgICAgICAgICAgJHJlY29yZC5GaXJzdERlbGV0ZVN1Y2NlZWRlZCA9ICR0cnVlDQogICAgICAgICAgICB9IGNhdGNoIHsNCiAgICAgICAgICAgICAgICAkcmVjb3JkLkVycm9ycyArPSBbc3RyaW5nXSRfLkV4Y2VwdGlvbi5NZXNzYWdlDQogICAgICAgICAgICB9DQogICAgICAgICAgICBpZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkVGFyZ2V0UGF0aCAtUGF0aFR5cGUgTGVhZikpIHsNCiAgICAgICAgICAgICAgICAkcmVjb3JkLkRlbGV0ZWQgPSAkdHJ1ZQ0KICAgICAgICAgICAgfSBlbHNlIHsNCiAgICAgICAgICAgICAgICBmb3IgKCRhdHRlbXB0ID0gMTsgJGF0dGVtcHQgLWxlIDU7ICRhdHRlbXB0KyspIHsNCiAgICAgICAgICAgICAgICAgICAgJHJlY29yZC5SZXRyeUNvdW50ID0gJGF0dGVtcHQNCiAgICAgICAgICAgICAgICAgICAgU3RhcnQtU2xlZXAgLU1pbGxpc2Vjb25kcyAyNTANCiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgUmVtb3ZlLUl0ZW0gLUxpdGVyYWxQYXRoICRUYXJnZXRQYXRoIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU3RvcCB9IGNhdGNoIHsgJHJlY29yZC5FcnJvcnMgKz0gW3N0cmluZ10kXy5FeGNlcHRpb24uTWVzc2FnZSB9DQogICAgICAgICAgICAgICAgICAgIGlmICgtbm90IChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRUYXJnZXRQYXRoIC1QYXRoVHlwZSBMZWFmKSkgeyAkcmVjb3JkLkRlbGV0ZWQgPSAkdHJ1ZTsgYnJlYWsgfQ0KICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIGlmICgkcmVjb3JkLkRlbGV0ZWQpIHsNCiAgICAgICAgICAgICAgICB0cnkgeyBSZW1vdmUtSXRlbSAtTGl0ZXJhbFBhdGggJFBhcmVudFBhdGggLUZvcmNlIC1FcnJvckFjdGlvbiBTdG9wIH0gY2F0Y2ggeyAkcmVjb3JkLkVycm9ycyArPSBbc3RyaW5nXSRfLkV4Y2VwdGlvbi5NZXNzYWdlIH0NCiAgICAgICAgICAgICAgICAkcmVjb3JkLkRpcmVjdG9yeVJlbW92ZWQgPSAtbm90IChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRQYXJlbnRQYXRoIC1QYXRoVHlwZSBDb250YWluZXIpDQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICB9DQp9IGZpbmFsbHkgew0KICAgIFdyaXRlLVJlY29yZA0KICAgIHRyeSB7DQogICAgICAgIFJlbW92ZS1JdGVtIC1MaXRlcmFsUGF0aCAkSGVscGVyUGF0aCAtRm9yY2UgLUVycm9yQWN0aW9uIFN0b3ANCiAgICAgICAgJHJlY29yZC5IZWxwZXJEZWxldGVkID0gLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkSGVscGVyUGF0aCAtUGF0aFR5cGUgTGVhZikNCiAgICB9IGNhdGNoIHsNCiAgICAgICAgJHJlY29yZC5FcnJvcnMgKz0gW3N0cmluZ10kXy5FeGNlcHRpb24uTWVzc2FnZQ0KICAgIH0NCiAgICBXcml0ZS1SZWNvcmQNCn0=")
    if hashlib.sha256(helper_bytes).hexdigest().upper() != "D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD":
        raise RuntimeError("Self-delete helper embedded SHA-256 mismatch.")
    helper_path = os.path.join(tempfile.gettempdir(), "DenGo-SelfDelete-Helper-{}.ps1".format(target_pid))
    log_path = os.path.join(tempfile.gettempdir(), "DenGo-Uninstall-SelfDelete-{}.json".format(target_pid))
    temporary_path = helper_path + ".tmp"
    with open(temporary_path, "wb") as stream:
        stream.write(helper_bytes)
        stream.flush()
        os.fsync(stream.fileno())
    if sha256(temporary_path) != "D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD":
        raise RuntimeError("Self-delete helper written SHA-256 mismatch.")
    os.replace(temporary_path, helper_path)
    if sha256(helper_path) != "D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD":
        raise RuntimeError("Self-delete helper final SHA-256 mismatch.")
    flags = 0x00000200 | 0x08000000
    helper_process = subprocess.Popen([
        "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", helper_path,
        "-TargetPid", str(target_pid),
        "-TargetPath", exe_path,
        "-ParentPath", parent,
        "-LogPath", log_path,
        "-HelperPath", helper_path,
    ], creationflags=flags, close_fds=True, shell=False)
    receipt_path = os.path.join(tempfile.gettempdir(), "DenGo-Uninstall-SelfDelete-Launch-{}.json".format(target_pid))
    receipt = {
        "TargetPid": target_pid,
        "HelperPid": helper_process.pid,
        "TargetPath": exe_path,
        "ParentPath": parent,
        "HelperPath": helper_path,
        "LogPath": log_path,
        "HelperSHA256": "D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD",
    }
    with open(receipt_path, "w", encoding="utf-8") as stream:
        json.dump(receipt, stream, ensure_ascii=True, indent=2)

def main():
    run_root = None
    try:
        _, run_root, package_root = verify_and_extract()
        outcome, reason = execute_operation("Uninstall", "Start-DenGoUninstall.ps1", package_root)
        if outcome == "Cancelled":
            return EXIT_CANCELLED
        if outcome != "Completed":
            if is_contract_violation(reason):
                message("\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u306E\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002\n\u767B\u9332\u3068\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30E9\u30FC\u306F\u5909\u66F4\u3057\u3066\u3044\u307E\u305B\u3093\u3002")
            return EXIT_FAILED
        remove_registration()
        schedule_self_delete()
        return EXIT_COMPLETED
    except Exception as exc:
        return fail("\u51E6\u7406\u4E2D\u306B\u30A8\u30E9\u30FC\u304C\u767A\u751F\u3057\u307E\u3057\u305F\u3002\n" + str(exc))
    finally:
        if run_root:
            cleanup(run_root)

if __name__ == "__main__":
    sys.exit(main())
'@
    $uninstallSource = $commonTemplate.Replace('__ZIP_SHA__',$expectedZipSha).Replace('__COMMIT__',$expectedSourceCommit) + [System.Environment]::NewLine + $uninstallMain
    $uninstallPy = Join-Path $workRoot 'dengo_uninstall_registered.py'
    [System.IO.File]::WriteAllText($uninstallPy,$uninstallSource,[System.Text.Encoding]::ASCII)

    $stage = 'compile uninstall source'
    Invoke-ProcessChecked $pythonExe ('-m py_compile "' + $uninstallPy + '"') 'PY-COMPILE-UNINSTALL' $workRoot

    $stage = 'build uninstall exe'
    $uninstallDist = Join-Path $workRoot 'dist-uninstall'
    $uninstallBuild = Join-Path $workRoot 'build-uninstall'
    $uninstallSpec = Join-Path $workRoot 'spec-uninstall'
    [System.IO.Directory]::CreateDirectory($uninstallSpec) | Out-Null
    $uninstallArgs = '-m PyInstaller --noconfirm --clean --onefile --windowed --uac-admin --name "DenGo-Controller-Converter-Uninstall-2.0.0" --icon "' + $iconPath + '" --version-file "' + $versionFile + '" --add-data "' + $payloadZip + ';." --distpath "' + $uninstallDist + '" --workpath "' + $uninstallBuild + '" --specpath "' + $uninstallSpec + '" "' + $uninstallPy + '"'
    Invoke-ProcessChecked $pythonExe $uninstallArgs 'PYINSTALLER-UNINSTALL' $workRoot
    $builtUninstall = Join-Path $uninstallDist 'DenGo-Controller-Converter-Uninstall-2.0.0.exe'
    if (-not (Test-Path -LiteralPath $builtUninstall -PathType Leaf)) { throw 'Built uninstall EXE missing.' }
    $uninstallSha = (Get-FileHash -LiteralPath $builtUninstall -Algorithm SHA256).Hash

    $setupMain = @'
import winreg

EXPECTED_UNINSTALL_SHA256 = "__UNINSTALL_SHA__"

def install_uninstaller(bundle_root):
    source = os.path.join(bundle_root, "DenGo-Controller-Converter-Uninstall-2.0.0.exe")
    if not os.path.isfile(source) or sha256(source) != EXPECTED_UNINSTALL_SHA256:
        raise RuntimeError("\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30E9\u30FC\u306E\u691C\u8A3C\u306B\u5931\u6557\u3057\u307E\u3057\u305F\u3002")
    os.makedirs(PRODUCT_DIR, exist_ok=True)
    temporary = UNINSTALL_EXE + ".tmp"
    shutil.copy2(source, temporary)
    if sha256(temporary) != EXPECTED_UNINSTALL_SHA256:
        raise RuntimeError("\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30E9\u30FC\u306E\u8907\u88FD\u691C\u8A3C\u306B\u5931\u6557\u3057\u307E\u3057\u305F\u3002")
    os.replace(temporary, UNINSTALL_EXE)

def register_uninstaller():
    app_exe = os.path.join(PRODUCT_DIR, "DenGoControllerConverter.exe")
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY, 0, winreg.KEY_WRITE) as key:
        winreg.SetValueEx(key, "DisplayName", 0, winreg.REG_SZ, "DenGo Controller Converter")
        winreg.SetValueEx(key, "DisplayVersion", 0, winreg.REG_SZ, "2.0.0")
        winreg.SetValueEx(key, "Publisher", 0, winreg.REG_SZ, "Coruge-to")
        winreg.SetValueEx(key, "InstallLocation", 0, winreg.REG_SZ, PRODUCT_DIR)
        winreg.SetValueEx(key, "DisplayIcon", 0, winreg.REG_SZ, app_exe)
        winreg.SetValueEx(key, "UninstallString", 0, winreg.REG_SZ, '"' + UNINSTALL_EXE + '"')
        winreg.SetValueEx(key, "QuietUninstallString", 0, winreg.REG_SZ, '"' + UNINSTALL_EXE + '"')
        winreg.SetValueEx(key, "NoModify", 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(key, "NoRepair", 0, winreg.REG_DWORD, 1)

def main():
    run_root = None
    try:
        bundle_root, run_root, package_root = verify_and_extract()
        outcome, reason = execute_operation("Install", "Start-DenGoSetup.ps1", package_root)
        if outcome == "Cancelled":
            return EXIT_CANCELLED
        if outcome != "Completed":
            if is_contract_violation(reason):
                message("\u30BB\u30C3\u30C8\u30A2\u30C3\u30D7\u306E\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002\n\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30E9\u30FC\u306E\u767B\u9332\u306F\u884C\u3044\u307E\u305B\u3093\u3002")
            return EXIT_FAILED
        install_uninstaller(bundle_root)
        register_uninstaller()
        return EXIT_COMPLETED
    except Exception as exc:
        return fail("\u51E6\u7406\u4E2D\u306B\u30A8\u30E9\u30FC\u304C\u767A\u751F\u3057\u307E\u3057\u305F\u3002\n" + str(exc))
    finally:
        if run_root:
            cleanup(run_root)

if __name__ == "__main__":
    sys.exit(main())
'@
    $setupSource = $commonTemplate.Replace('__ZIP_SHA__',$expectedZipSha).Replace('__COMMIT__',$expectedSourceCommit) + [System.Environment]::NewLine + $setupMain.Replace('__UNINSTALL_SHA__',$uninstallSha)
    $setupPy = Join-Path $workRoot 'dengo_setup_registered.py'
    [System.IO.File]::WriteAllText($setupPy,$setupSource,[System.Text.Encoding]::ASCII)

    $stage = 'compile setup source'
    Invoke-ProcessChecked $pythonExe ('-m py_compile "' + $setupPy + '"') 'PY-COMPILE-SETUP' $workRoot

    $stage = 'build setup exe'
    $setupDist = Join-Path $workRoot 'dist-setup'
    $setupBuild = Join-Path $workRoot 'build-setup'
    $setupSpec = Join-Path $workRoot 'spec-setup'
    [System.IO.Directory]::CreateDirectory($setupSpec) | Out-Null
    $setupArgs = '-m PyInstaller --noconfirm --clean --onefile --windowed --uac-admin --name "DenGo-Controller-Converter-Setup-2.0.0" --icon "' + $iconPath + '" --version-file "' + $versionFile + '" --add-data "' + $payloadZip + ';." --add-data "' + $builtUninstall + ';." --distpath "' + $setupDist + '" --workpath "' + $setupBuild + '" --specpath "' + $setupSpec + '" "' + $setupPy + '"'
    Invoke-ProcessChecked $pythonExe $setupArgs 'PYINSTALLER-SETUP' $workRoot

    $stage = 'verify outputs'
    $builtSetup = Join-Path $setupDist 'DenGo-Controller-Converter-Setup-2.0.0.exe'
    foreach ($path in @($builtSetup,$builtUninstall)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Built EXE missing: ' + $path) }
        if (-not [string]::Equals((Get-PeMachine $path),'x64',[System.StringComparison]::Ordinal)) { throw ('Built EXE is not x64: ' + $path) }
    }
    $setupOutput = Join-Path $OutputRoot 'DenGo-Controller-Converter-Setup-2.0.0.exe'
    $uninstallOutput = Join-Path $OutputRoot 'DenGo-Controller-Converter-Uninstall-2.0.0.exe'
    Copy-Item -LiteralPath $builtSetup -Destination $setupOutput -Force
    Copy-Item -LiteralPath $builtUninstall -Destination $uninstallOutput -Force
    $setupSha = (Get-FileHash -LiteralPath $setupOutput -Algorithm SHA256).Hash
    $finalUninstallSha = (Get-FileHash -LiteralPath $uninstallOutput -Algorithm SHA256).Hash
    if (-not [string]::Equals($finalUninstallSha,$uninstallSha,[System.StringComparison]::Ordinal)) { throw 'Uninstall EXE SHA256 changed after copy.' }
    Add-Report ('SetupExe=' + $setupOutput)
    Add-Report ('SetupExeBytes=' + [string](Get-Item -LiteralPath $setupOutput).Length)
    Add-Report ('SetupExeSHA256=' + $setupSha)
    Add-Report ('SetupExeMachine=x64')
    Add-Report ('EmbeddedUninstallSHA256=' + $uninstallSha)
    Add-Report ('UninstallExe=' + $uninstallOutput)
    Add-Report ('UninstallExeBytes=' + [string](Get-Item -LiteralPath $uninstallOutput).Length)
    Add-Report ('UninstallExeSHA256=' + $finalUninstallSha)
    Add-Report ('UninstallExeMachine=x64')
    Add-Report 'RegistryScope=HKCU'
    Add-Report 'RegistryKey=Software\Microsoft\Windows\CurrentVersion\Uninstall\DenGoControllerConverter'
    Add-Report 'InstalledUninstaller=%LOCALAPPDATA%\Programs\DenGo Controller Converter\Uninstall.exe'
    Add-Report 'SelfDelete=validated UTF-8 BOM PowerShell file helper with named parameters and one-file-safe process flags'
    Add-Report 'SelfDeleteHelperSHA256=D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD'
    Add-Report 'SelfDeleteHelperLaunchReceipt=%TEMP%\DenGo-Uninstall-SelfDelete-Launch-<PID>.json'
    Add-Report 'SelfDeleteCreationFlags=CREATE_NEW_PROCESS_GROUP|CREATE_NO_WINDOW (0x08000200)'
    Add-Report 'RepositoryModified=False'
    Add-Report 'InputZipModified=False'
    Add-Report 'RESULT=SUCCESS'
    $reportPath = Join-Path $OutputRoot 'DenGo-SetupExe-Registered-v7.txt'
    $report | Out-File -LiteralPath $reportPath -Encoding UTF8 -Force
    Write-Host 'RESULT: SUCCESS'
    Write-Host ('SetupExe: ' + $setupOutput)
    Write-Host ('SetupExeSHA256: ' + $setupSha)
    Write-Host ('UninstallExe: ' + $uninstallOutput)
    Write-Host ('UninstallExeSHA256: ' + $finalUninstallSha)
    Write-Host ('Report: ' + $reportPath)
    Write-Host 'Repository and input ZIP modified: NONE'
} catch {
    Write-Host 'RESULT: FAILED'
    Write-Host ('Stage: ' + $stage)
    Write-Host ('Message: ' + [string]$_.Exception.Message)
    Write-Host ('Position: ' + [string]$_.InvocationInfo.PositionMessage)
    Write-Host 'Repository and input ZIP modified: NONE'
    exit 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace($workRoot) -and (Test-Path -LiteralPath $workRoot -PathType Container)) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
