import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path


class HidHidePcsx2Configurator:
    def __init__(self, retry_seconds=15.0):
        self._retry_seconds = float(retry_seconds)
        self._lock = threading.Lock()
        self._configured_path = None
        self._retry_at = 0.0

    def ensure_configured(self, pcsx2_executable):
        path = os.path.abspath(str(pcsx2_executable or ""))
        if not path or not os.path.isfile(path):
            return False
        with self._lock:
            if self._configured_path and os.path.normcase(self._configured_path) == os.path.normcase(path):
                return False
            now = time.monotonic()
            if now < self._retry_at:
                return False
            try:
                self._apply(path)
            except Exception as exc:
                self._retry_at = now + self._retry_seconds
                print(f"HIDHIDE=FAILED ERROR={exc}", flush=True)
                return False
            self._configured_path = path
            self._retry_at = 0.0
            print(f"HIDHIDE=CONFIGURED PCSX2={path}", flush=True)
            return True

    @staticmethod
    def _apply(pcsx2_executable):
        program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
        candidates = (
            Path(program_files) / "Nefarius Software Solutions" / "HidHide" / "HidHideCLI.exe",
            Path(program_files) / "Nefarius Software Solutions" / "HidHide" / "x64" / "HidHideCLI.exe",
        )
        cli = next((candidate for candidate in candidates if candidate.is_file()), None)
        if cli is None:
            raise RuntimeError("HidHideCLI.exe was not found")

        script = r'''$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$pcsx2 = [System.IO.Path]::GetFullPath($env:DENGO_PCSX2_EXE)
$cli = [System.IO.Path]::GetFullPath($env:DENGO_HIDHIDE_CLI)
if (@(Get-Process -Name 'HidHideClient' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Close HidHide Configuration Client.' }
function Get-ParentId { param([string]$Id) return [string](Get-PnpDeviceProperty -InstanceId $Id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data }
$all = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
$base = @($all | Where-Object { [string]::Equals([string]$_.Class,'XnaComposite',[System.StringComparison]::OrdinalIgnoreCase) -and ([string]$_.InstanceId -match '(?i)\AUSB\\VID_045E&PID_028E\\') })
if (@($base).Count -ne 1) { throw ('Expected one virtual Xbox 360 base device, found: ' + @($base).Count) }
$baseId = [string]$base[0].InstanceId
$interfaces = New-Object System.Collections.ArrayList
foreach ($device in $all) { $id=[string]$device.InstanceId; if ($id -match '(?i)\AUSB\\VID_045E&PID_028E&IG_[0-9A-F]{2}\\') { if ([string]::Equals((Get-ParentId $id),$baseId,[System.StringComparison]::OrdinalIgnoreCase)) { [void]$interfaces.Add($id) } } }
$hids = New-Object System.Collections.ArrayList
foreach ($device in $all) { $id=[string]$device.InstanceId; if ($id -match '(?i)\AHID\\VID_045E&PID_028E&IG_[0-9A-F]{2}\\') { $parent=Get-ParentId $id; if (@($interfaces | Where-Object { [string]::Equals([string]$_,$parent,[System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 1) { [void]$hids.Add($id) } } }
if (@($interfaces).Count -eq 0 -or @($hids).Count -eq 0) { throw 'Virtual Xbox 360 child nodes were not resolved.' }
$args = New-Object System.Collections.ArrayList
[void]$args.Add('--app-reg'); [void]$args.Add($pcsx2)
[void]$args.Add('--dev-hide'); [void]$args.Add($baseId)
foreach ($id in @($interfaces | Sort-Object -Unique)) { [void]$args.Add('--dev-hide'); [void]$args.Add([string]$id) }
foreach ($id in @($hids | Sort-Object -Unique)) { [void]$args.Add('--dev-hide'); [void]$args.Add([string]$id) }
[void]$args.Add('--inv-off'); [void]$args.Add('--cloak-on')
& $cli @args
if ($LASTEXITCODE -ne 0) { throw ('HidHide CLI failed: ' + $LASTEXITCODE) }
'''
        env = os.environ.copy()
        env["DENGO_PCSX2_EXE"] = pcsx2_executable
        env["DENGO_HIDHIDE_CLI"] = str(cli)
        fd, script_path = tempfile.mkstemp(prefix="dengo-hidhide-", suffix=".ps1")
        os.close(fd)
        try:
            Path(script_path).write_text(script, encoding="ascii")
            completed = subprocess.run(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            if completed.returncode != 0:
                detail = (completed.stderr or completed.stdout or "unknown error").strip()
                raise RuntimeError(detail)
        finally:
            try:
                os.remove(script_path)
            except OSError:
                pass
