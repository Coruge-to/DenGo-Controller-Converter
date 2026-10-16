# Shared helpers for the I2-D (final lock contract: Global name, explicit DACL, wrapper post-step lock) tests. ASCII only.
# Dot-source this file; it defines no product behaviour. Tests only ever take throw-away names (Global\DenGoI2DTest-<guid>);
# the real product lock name is only compared as a literal and is never created, opened or held by any test.
# Writes only below a sandbox under TEMP. Never touches product paths, the registry or any third-party application.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')   # Assert-I2A / Complete-I2ATests / tree helpers

$script:I2DRepo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:I2DProductLockName = 'Global\DenGoControllerConverter.Transaction'   # contract literal (D-D1); compared, never taken
$script:I2DHelperSha256 = 'D67E7F282E6288AF6D92CE8EA48AA82EBE1DBB54C714857AABB472541CD8FDDD'   # self-delete helper (D-D4 / O1: unchanged)
$script:I2DSyncModify = 0x100001   # SYNCHRONIZE | MUTEX_MODIFY_STATE

# ---------------------------------------------------------------- names, SIDs, security objects
function New-I2DLockName { return ('Global\DenGoI2DTest-' + [System.Guid]::NewGuid().ToString('N')) }
function Get-I2DUserSid { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User }
function Get-I2DAdminSid { return (New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)) }
function Get-I2DSystemSid { return (New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)) }
function Get-I2DExpectedSids { return @((Get-I2DUserSid).Value, (Get-I2DAdminSid).Value) }

# Kinds: Engine = the I2-D contract DACL built here independently of the product (current user + BUILTIN\Administrators, Synchronize|Modify, Allow only)
#        SystemOnly = only SYSTEM (nobody else, including this user, can open it)
#        Product = whatever the product's DgLock-NewSecurity returns (needs DenGoInstallerTransaction.ps1 to be loaded)
function New-I2DSecurity([string]$Kind) {
    if ($Kind -eq 'Product') { return (DgLock-NewSecurity) }
    $sec = New-Object System.Security.AccessControl.MutexSecurity
    if ($Kind -eq 'Engine') {
        $rights = [System.Security.AccessControl.MutexRights]([int][System.Security.AccessControl.MutexRights]::Synchronize -bor [int][System.Security.AccessControl.MutexRights]::Modify)
        foreach ($sid in @((Get-I2DUserSid), (Get-I2DAdminSid))) {
            $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($sid, $rights, [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        return $sec
    }
    if ($Kind -eq 'SystemOnly') {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule((Get-I2DSystemSid), [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
        return $sec
    }
    throw ('Unknown security kind: ' + $Kind)
}

# ---------------------------------------------------------------- SDDL parsing (no regular expressions over the DACL: the DACL is parsed as a security descriptor)
function ConvertTo-I2DAceList([string]$Sddl) {
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor($Sddl)
    $list = New-Object System.Collections.ArrayList
    if ($null -ne $sd.DiscretionaryAcl) {
        foreach ($ace in $sd.DiscretionaryAcl) {
            [void]$list.Add([pscustomobject]@{ Type = [string]$ace.AceType; Mask = [int]$ace.AccessMask; Sid = [string]$ace.SecurityIdentifier.Value })
        }
    }
    return , @($list)
}
# Returns the list of problems (empty = the DACL is exactly: one Allow ACE per expected SID, all with the given mask, nothing else).
function Get-I2DAceProblems([string]$Sddl, [string[]]$ExpectedSids, [int]$Mask) {
    $problems = New-Object System.Collections.ArrayList
    $aces = ConvertTo-I2DAceList $Sddl
    if ($aces.Count -ne @($ExpectedSids).Count) { [void]$problems.Add('ACE count ' + $aces.Count + ' (expected ' + @($ExpectedSids).Count + ')') }
    foreach ($a in $aces) {
        if ($a.Type -ne 'AccessAllowed') { [void]$problems.Add('ACE type ' + $a.Type + ' for ' + $a.Sid) }
        if ($a.Mask -ne $Mask) { [void]$problems.Add(('mask 0x{0:X} for {1} (expected 0x{2:X})' -f $a.Mask, $a.Sid, $Mask)) }
        if (@($ExpectedSids) -notcontains $a.Sid) { [void]$problems.Add('unexpected SID ' + $a.Sid) }
    }
    foreach ($s in @($ExpectedSids)) { if (@($aces | Where-Object { $_.Sid -eq $s }).Count -ne 1) { [void]$problems.Add('SID ' + $s + ' is not present exactly once') } }
    return , @($problems)
}
function Get-I2DMutexSddl([string]$Name) {
    $m = [System.Threading.Mutex]::OpenExisting($Name, [System.Security.AccessControl.MutexRights]::ReadPermissions)
    try { return $m.GetAccessControl().GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access) } finally { $m.Dispose() }
}

# ---------------------------------------------------------------- in-process holder: a separate THREAD owns the mutex (a mutex is owned per thread, so the main thread sees HeldByOther)
if (-not ('DenGoI2DLockHolder' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Security.AccessControl;
using System.Threading;
public sealed class DenGoI2DLockHolder : IDisposable
{
    private Thread thread;
    private Mutex mutex;
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private readonly ManualResetEvent command = new ManualResetEvent(false);
    private string pending = "";
    public bool Acquired;
    public string Error = "";
    public static DenGoI2DLockHolder Start(string name, MutexSecurity security, bool acquire)
    {
        DenGoI2DLockHolder h = new DenGoI2DLockHolder();
        h.thread = new Thread(delegate() { h.Run(name, security, acquire); });
        h.thread.IsBackground = true;
        h.thread.Start();
        if (!h.ready.WaitOne(20000)) { h.Error = "holder start timeout"; }
        return h;
    }
    private void Run(string name, MutexSecurity security, bool acquire)
    {
        try
        {
            bool created;
            if (security == null) { mutex = new Mutex(false, name, out created); }
            else { mutex = new Mutex(false, name, out created, security); }
            if (acquire) { Acquired = mutex.WaitOne(0); }
        }
        catch (Exception ex) { Error = ex.GetType().Name + ": " + ex.Message; }
        ready.Set();
        if (mutex == null) { return; }
        command.WaitOne();
        if (pending == "release")
        {
            if (Acquired) { try { mutex.ReleaseMutex(); } catch (Exception) { } }
            Acquired = false;
        }
        // "abandon": the thread simply ends while it owns the mutex; the handle stays open, so the object survives as an abandoned mutex
    }
    private void Send(string what)
    {
        pending = what;
        command.Set();
        if (thread != null) { thread.Join(20000); }
    }
    public void Release() { Send("release"); }
    public void Abandon() { Send("abandon"); }
    public void Dispose()
    {
        if (thread != null && thread.IsAlive) { Send("release"); }
        if (mutex != null) { try { mutex.Dispose(); } catch (Exception) { } mutex = null; }
    }
}
'@
}
function Start-I2DHolder([string]$Name, $Security = $null, [bool]$Acquire = $true) {
    $h = [DenGoI2DLockHolder]::Start($Name, $Security, $Acquire)
    if ($h.Error.Length -gt 0) { throw ('holder failed: ' + $h.Error) }
    return $h
}

# ---------------------------------------------------------------- Python (wrapper tests) and the builder templates
function Get-I2DPython {
    $venv = Join-Path $script:I2DRepo 'venv_exe\Scripts\python.exe'
    if ([System.IO.File]::Exists($venv)) { return $venv }
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw 'No Python interpreter was found (venv_exe or PATH).' }
    return $command.Source
}
# The Python modules exactly as Build-DenGo-SetupExe-2.0.0.ps1 would assemble them (same extraction as the I1 wrapper tests; placeholder hashes only).
function Get-I2DBuilderTemplates {
    $path = Join-Path $script:I2DRepo 'installer\Build-DenGo-SetupExe-2.0.0.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw ('Parse errors in ' + $path) }
    $assignments = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$commonTemplate', '$uninstallMain', '$setupMain') }, $true)
    $map = @{}
    foreach ($a in $assignments) { $map[$a.Left.Extent.Text] = [string]$a.Right.Expression.Value }
    foreach ($k in '$commonTemplate', '$uninstallMain', '$setupMain') { if (-not $map.ContainsKey($k)) { throw ('Template not found: ' + $k) } }
    $zip = '0' * 64; $commit = '0' * 40
    $common = $map['$commonTemplate'].Replace('__ZIP_SHA__', $zip).Replace('__COMMIT__', $commit)
    return @{
        Setup     = $common + [System.Environment]::NewLine + $map['$setupMain'].Replace('__UNINSTALL_SHA__', $zip)
        Uninstall = $common + [System.Environment]::NewLine + $map['$uninstallMain']
    }
}
function Invoke-I2DPython([string]$Python, [string[]]$Arguments, [hashtable]$Environment = @{}, [string]$WorkingDirectory = '', [int]$TimeoutMs = 240000) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Python
    $info.Arguments = ([string]::Join(' ', @($Arguments | ForEach-Object { '"' + $_ + '"' })))
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
    if ($WorkingDirectory.Length -gt 0) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($k in $Environment.Keys) { $info.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($info)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; throw 'Python run timed out.' }
    [void]$p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out; Stderr = $errTask.Result }
}
# Feeds "PASS | id | detail" lines printed by the Python tests into the PowerShell result list.
function Import-I2DPythonResults([string]$Stdout, [string]$Prefix = '') {
    $count = 0
    foreach ($line in ($Stdout -split "`r?`n")) {
        if ($line -match '^(PASS|FAIL) \| ([^|]+) \| ?(.*)$') { [void](Assert-I2A ($Prefix + $Matches[2].Trim()) ($Matches[1] -eq 'PASS') $Matches[3]); $count++ }
    }
    return $count
}

# ---------------------------------------------------------------- input SHA-256 manifest (ties a result to the exact files it ran against)
function Get-I2DNewFileList {
    return @(
        'installer/tests/I2D.TestSupport.ps1', 'installer/tests/I2D.LockChild.ps1',
        'installer/tests/Test-DenGoInstaller-I2D-Static.ps1', 'installer/tests/Test-DenGoInstaller-I2D-Unit.ps1', 'installer/tests/Test-DenGoInstaller-I2D-Lock.ps1',
        'installer/tests/Test-DenGoInstaller-I2D-Wrapper.ps1', 'installer/tests/Test-DenGoInstaller-I2D-All.ps1', 'installer/tests/i2d_wrapper_tests.py')
}
function Get-I2DProductFileList {
    return @(
        'installer/Build-DenGo-SetupExe-2.0.0.ps1', 'installer/scripts/DenGoInstallerTransaction.ps1', 'installer/scripts/DenGoInstallerProductApply.ps1', 'installer/scripts/DenGoUninstallerProductApply.ps1',
        'installer/scripts/Invoke-DenGoInstaller.ps1', 'installer/scripts/Invoke-DenGoUninstaller.ps1', 'installer/scripts/Start-DenGoSetup.ps1', 'installer/scripts/Start-DenGoUninstall.ps1',
        'installer/gui/DenGoInstallerGui.ps1', 'installer/gui/DenGoUninstallerGui.ps1', 'installer/build/Build-DenGo-SetupPackage.ps1')
}
function Get-I2DInputManifest {
    $rows = New-Object System.Collections.ArrayList
    foreach ($group in @(@('New', (Get-I2DNewFileList)), @('Product', (Get-I2DProductFileList)))) {
        foreach ($rel in $group[1]) {
            $abs = [System.IO.Path]::GetFullPath((Join-Path $script:I2DRepo ($rel.Replace('/', '\'))))
            $row = [ordered]@{ Group = $group[0]; Rel = $rel; Abs = $abs; Size = -1; Sha256 = '<missing>' }
            if ([System.IO.File]::Exists($abs)) { $row.Size = ([System.IO.FileInfo]$abs).Length; $row.Sha256 = Get-I2AFileSha $abs }
            [void]$rows.Add([pscustomobject]$row)
        }
    }
    return , @($rows)
}
function Write-I2DInputManifest([string]$Path, $Rows, [string]$Label) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# I2-D input SHA-256 manifest ($Label) generated $([DateTime]::UtcNow.ToString('o'))`n# Group`tSize`tSHA256`tRelativePath`n")
    foreach ($r in $Rows) { [void]$sb.Append(("{0}`t{1}`t{2}`t{3}`n" -f $r.Group, $r.Size, $r.Sha256, $r.Rel)) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
