# Shared helpers for the I1 (installer result contract) tests. ASCII only; Japanese UI text is built from \u escapes.
# Dot-source this file; it defines no product behaviour and writes only below a sandbox under TEMP.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:I1Results = New-Object System.Collections.ArrayList
$script:I1Repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function J([string]$Escaped) { return [regex]::Unescape($Escaped) }
function U([int[]]$CodePoints) { return -join ($CodePoints | ForEach-Object { [string][char]$_ }) }
# UI strings used to find controls (WinForms Button.Text == UIA Name)
$script:UiText = @{
    Next      = (U 0x6B21,0x3078)
    Cancel    = (U 0x30AD,0x30E3,0x30F3,0x30BB,0x30EB)
    Finish    = (U 0x5B8C,0x4E86)
    Uninstall = (U 0x30A2,0x30F3,0x30A4,0x30F3,0x30B9,0x30C8,0x30FC,0x30EB)
    Yes       = (U 0x306F,0x3044)
    Ok        = 'OK'
}

function Add-I1Result([string]$Id, [bool]$Passed, [string]$Detail) {
    [void]$script:I1Results.Add([pscustomobject]@{ Id = $Id; Passed = $Passed; Detail = $Detail })
    Write-Host (('{0} | {1} | {2}' -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Id, $Detail))
}
function Complete-I1Tests {
    $passed = @($script:I1Results | Where-Object { $_.Passed }).Count
    $failed = @($script:I1Results | Where-Object { -not $_.Passed }).Count
    Write-Host ('PASS={0} FAIL={1}' -f $passed, $failed)
    if ($failed -ne 0) { exit 1 }
    exit 0
}

function New-I1Sandbox([string]$Name) {
    $tempBase = [System.IO.Path]::GetFullPath($env:TEMP)
    $root = Join-Path $tempBase ('DenGoI1-' + $Name + '-' + [System.Guid]::NewGuid().ToString('N'))
    foreach ($sub in 'LocalAppData', 'Temp', 'Profile\Downloads') { [System.IO.Directory]::CreateDirectory((Join-Path $root $sub)) | Out-Null }
    return $root
}
function Remove-I1Sandbox([string]$Root) {
    $tempBase = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Root)
    if (-not $full.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or -not ([System.IO.Path]::GetFileName($full)).StartsWith('DenGoI1-')) { throw ('Refusing to delete: ' + $full) }
    for ($i = 0; $i -lt 10; $i++) {
        try { if ([System.IO.Directory]::Exists($full)) { Remove-Item -LiteralPath $full -Recurse -Force }; return } catch { Start-Sleep -Milliseconds 300 }
    }
}

# ---- AST helpers (no regular expressions over code) ----
function Get-ScriptAst([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw ('Parse errors in ' + $Path) }
    return $ast
}
function Get-EventHandlerBlock([string]$Path, [string]$EventMethod) {
    $ast = Get-ScriptAst $Path
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq $EventMethod }, $true))
    if ($calls.Count -ne 1) { throw ('Expected exactly one ' + $EventMethod + ' in ' + $Path + ', found ' + $calls.Count) }
    $arg = @($calls[0].Arguments | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] })
    if ($arg.Count -ne 1) { throw 'Handler script block not found.' }
    return $arg[0].ScriptBlock.GetScriptBlock()
}
function Get-FunctionText([string]$Path, [string[]]$Names) {
    $ast = Get-ScriptAst $Path
    $parts = New-Object System.Collections.ArrayList
    foreach ($name in $Names) {
        $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))
        if ($defs.Count -ne 1) { throw ('Function ' + $name + ' expected once in ' + $Path + ', found ' + $defs.Count) }
        [void]$parts.Add($defs[0].Extent.Text)
    }
    return [string]::Join([System.Environment]::NewLine, [string[]]@($parts))
}
function Get-BuilderTemplates {
    $path = Join-Path $script:I1Repo 'installer\Build-DenGo-SetupExe-2.0.0.ps1'
    $ast = Get-ScriptAst $path
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

# ---- sandboxed GUI runs ----
function Initialize-GuiSandbox {
    # Options only shape the sandbox COPY: a process listing that throws (simulates a WMI failure), a corrupt welcome image
    # (initialization exception), or a missing engine script. The product scripts themselves are copied unchanged.
    param([string]$Root, [switch]$ThrowOnProcessListing, [switch]$CorruptWelcomeImage, [string]$RemoveEngine = '')
    $gui = Join-Path $Root 'installer'
    foreach ($sub in 'gui', 'scripts', 'assets\images') { [System.IO.Directory]::CreateDirectory((Join-Path $gui $sub)) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $script:I1Repo 'installer\gui\DenGoInstallerGui.ps1') -Destination (Join-Path $gui 'gui') -Force
    Copy-Item -LiteralPath (Join-Path $script:I1Repo 'installer\gui\DenGoUninstallerGui.ps1') -Destination (Join-Path $gui 'gui') -Force
    Copy-Item -Path (Join-Path $script:I1Repo 'installer\assets\images\*') -Destination (Join-Path $gui 'assets\images') -Force
    $fakeInstaller = @'
param([switch]$DryRun,[switch]$Apply,[switch]$RealSystem,[string]$ConfirmRealApply='',[string]$OutputRoot='',[switch]$AdditionalSearch,[switch]$CreateDesktopShortcut,[switch]$SkipBveIntegration,[switch]$ReplaceModifiedPCSX2Profile,[switch]$ReplaceModifiedRPCS3Profile)
$ErrorActionPreference = 'Stop'
$sandbox = $env:DENGO_I1_SANDBOX
$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
function Get-Mode([string]$Name) { $v = [System.Environment]::GetEnvironmentVariable($Name); if ([string]::IsNullOrEmpty($v)) { return 'ok' }; return $v }
function Write-Plan([bool]$Succeeded,[string]$Message,[bool]$IsApply) {
    $core = @(); if ($Succeeded -and $IsApply) { $core = @([pscustomobject]@{Set='Core';Platform='Core';Component='Application';Action='Add';Destination='x';Applied=$true;Backup='';Succeeded=$true;ErrorCode=''}) }
    $plan = [pscustomobject]@{SchemaVersion=9;Succeeded=$Succeeded;ErrorCode='';ErrorMessage=$Message;DryRun=[bool]$DryRun;Apply=[bool]$Apply;RealSystem=[bool]$RealSystem;Detected=@();Plan=@();ApplyResults=$core;BveExCurrentInstalled=$false}
    [System.IO.File]::WriteAllText((Join-Path $OutputRoot 'install-plan.json'),($plan | ConvertTo-Json -Depth 8),(New-Object System.Text.UTF8Encoding($true)))
}
if ($DryRun) {
    $mode = Get-Mode 'DENGO_I1_DRY'
    if ($mode -eq 'nojson') { exit 1 }
    if ($mode -eq 'fail') { Write-Plan $false 'fake dry-run failure' $false; exit 0 }
    if ($mode -eq 'corrupt') { [System.IO.File]::WriteAllText((Join-Path $OutputRoot 'install-plan.json'),'{ not json'); exit 0 }
    Write-Plan $true '' $false; exit 0
}
$mode = Get-Mode 'DENGO_I1_APPLY'
if ($mode -eq 'fail-then-ok') {
    $counter = Join-Path $sandbox 'apply-count.txt'
    $n = 0; if ([System.IO.File]::Exists($counter)) { $n = [int][System.IO.File]::ReadAllText($counter) }
    [System.IO.File]::WriteAllText($counter, [string]($n + 1))
    if ($n -eq 0) { $mode = 'fail' } else { $mode = 'ok' }
}
[System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
$marker = Join-Path $stateRoot 'installing.json'
[System.IO.File]::WriteAllText($marker, '{"State":"Installing"}')
[System.IO.File]::WriteAllText((Join-Path $sandbox 'engine.pid'), [string]$PID)
if ($mode -eq 'nojson') { throw 'BlockedByRunningProcesses|RunningProducts=Fake' }
if ($mode -eq 'fail') { Write-Plan $false 'fake apply failure' $true; exit 0 }
if ($mode -eq 'slow') {
    $release = Join-Path $sandbox 'release.flag'
    for ($i = 0; $i -lt 360 -and -not [System.IO.File]::Exists($release); $i++) { Start-Sleep -Milliseconds 250 }
    $mode = 'ok'
}
if ($mode -eq 'nostate') { Write-Plan $true '' $true; [System.IO.File]::Delete($marker); exit 0 }
if ($mode -eq 'stale-state') {
    [System.IO.File]::WriteAllText((Join-Path $stateRoot 'installed-state.json'),'{"SchemaVersion":1,"InstalledAt":"2001-01-01T00:00:00.0000000+09:00","Files":[]}')
    [System.IO.File]::Delete($marker); Write-Plan $true '' $true; exit 0
}
$state = [pscustomobject]@{SchemaVersion=1;ProductVersion='2.0.0';InstalledAt=[System.DateTimeOffset]::Now.ToString('o');Files=@()}
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'installed-state.json'),($state | ConvertTo-Json -Depth 4),(New-Object System.Text.UTF8Encoding($true)))
[System.IO.File]::Delete($marker)
Write-Plan $true '' $true
exit 0
'@
    $fakeUninstaller = @'
param([switch]$DryRun,[switch]$Apply,[switch]$RealSystem,[string]$ConfirmRealApply='',[switch]$IncludeInputProfiles,[string]$OutputRoot='')
$ErrorActionPreference = 'Stop'
$sandbox = $env:DENGO_I1_SANDBOX
$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
$mode = [System.Environment]::GetEnvironmentVariable('DENGO_I1_UNINSTALL'); if ([string]::IsNullOrEmpty($mode)) { $mode = 'ok' }
if ($mode -eq 'fail-then-ok') {
    $counter = Join-Path $sandbox 'uninstall-count.txt'
    $n = 0; if ([System.IO.File]::Exists($counter)) { $n = [int][System.IO.File]::ReadAllText($counter) }
    [System.IO.File]::WriteAllText($counter, [string]($n + 1))
    if ($n -eq 0) { $mode = 'fail' } else { $mode = 'ok' }
}
[System.IO.File]::WriteAllText((Join-Path $sandbox 'engine.pid'), [string]$PID)
function Write-Plan([bool]$Succeeded,[string]$Message) {
    $plan = [pscustomobject]@{SchemaVersion=1;Succeeded=$Succeeded;ErrorCode='';ErrorMessage=$Message;DryRun=[bool]$DryRun;Apply=[bool]$Apply;RealSystem=[bool]$RealSystem;Items=@();ApplyResults=@()}
    [System.IO.File]::WriteAllText((Join-Path $OutputRoot 'uninstall-plan.json'),($plan | ConvertTo-Json -Depth 6),(New-Object System.Text.UTF8Encoding($true)))
}
if ($mode -eq 'nojson') { throw 'UnsafeOrUnknown items were found. No uninstall changes were made.' }
if ($mode -eq 'corrupt') { [System.IO.File]::WriteAllText((Join-Path $OutputRoot 'uninstall-plan.json'),'{ not json'); exit 0 }
if ($mode -eq 'fail') { Write-Plan $false 'fake uninstall failure'; exit 1 }
if ($mode -eq 'slow') {
    $release = Join-Path $sandbox 'release.flag'
    for ($i = 0; $i -lt 360 -and -not [System.IO.File]::Exists($release); $i++) { Start-Sleep -Milliseconds 250 }
    $mode = 'ok'
}
[System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
if ($mode -eq 'nostate') { Write-Plan $true ''; exit 0 }
$when = [System.DateTimeOffset]::Now.ToString('o')
if ($mode -eq 'stale-state') { $when = '2001-01-01T00:00:00.0000000+09:00' }
$state = [pscustomobject]@{SchemaVersion=1;ProductVersion='2.0.0';State='Uninstalled';UninstalledAt=$when}
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'uninstalled-state.json'),($state | ConvertTo-Json -Depth 4),(New-Object System.Text.UTF8Encoding($true)))
Write-Plan $true ''
exit 0
'@
    $launcher = @'
param([string]$Gui,[string]$ResultPath,[string]$RunId)
# Test launcher: hides real running products from the GUI's process check, then runs the GUI copy under test.
function global:Get-CimInstance { param([Parameter(Position=0)][string]$ClassName) return @() }
$arguments = @{}
if (-not [string]::IsNullOrEmpty($ResultPath)) { $arguments = @{ ResultPath = $ResultPath; RunId = $RunId } }
& $Gui @arguments
exit $LASTEXITCODE
'@
    # The setup wizard offers to launch the installed app on the completion page. The sandbox LOCALAPPDATA gets a harmless
    # stand-in (a copy of hostname.exe) so that path can be exercised without ever starting the real application.
    $standInDirectory = Join-Path $Root 'LocalAppData\Programs\DenGo Controller Converter'
    [System.IO.Directory]::CreateDirectory($standInDirectory) | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\hostname.exe') -Destination (Join-Path $standInDirectory 'DenGoControllerConverter.exe') -Force
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $gui 'scripts\Invoke-DenGoInstaller.ps1'), $fakeInstaller, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $gui 'scripts\Invoke-DenGoUninstaller.ps1'), $fakeUninstaller, $utf8)
    if ($ThrowOnProcessListing) {
        $replaced = $launcher.Replace('return @() }', "throw 'I1 test: process listing unavailable' }")
        if ($replaced -eq $launcher) { throw 'Launcher shim text was not found.' }
        $launcher = $replaced
    }
    [System.IO.File]::WriteAllText((Join-Path $Root 'launcher.ps1'), $launcher, $utf8)
    if ($CorruptWelcomeImage) {
        [System.IO.File]::WriteAllBytes((Join-Path $gui 'assets\images\DenGo-Controller-Converter2.png'), [byte[]](1..64))
    }
    if ($RemoveEngine -eq 'Installer') { Remove-Item -LiteralPath (Join-Path $gui 'scripts\Invoke-DenGoInstaller.ps1') -Force }
    if ($RemoveEngine -eq 'Uninstaller') { Remove-Item -LiteralPath (Join-Path $gui 'scripts\Invoke-DenGoUninstaller.ps1') -Force }
    return $gui
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class I1Native {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
}
'@
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Get-GuiWindows([int]$ProcessId) {
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    return @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition))
}
function Find-GuiButton([int]$ProcessId, [string]$NamePrefix) {
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($window in (Get-GuiWindows $ProcessId)) {
        foreach ($button in @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition))) {
            $name = [string]$button.Current.Name
            if ($name.StartsWith($NamePrefix, [System.StringComparison]::Ordinal) -and -not $button.Current.IsOffscreen -and $button.Current.IsEnabled) { return $button }
        }
    }
    return $null
}
function Wait-GuiButton([int]$ProcessId, [string]$NamePrefix, [int]$TimeoutSeconds = 25) {
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSeconds)
    while ([DateTime]::Now -lt $deadline) {
        $button = Find-GuiButton $ProcessId $NamePrefix
        if ($null -ne $button) { return $button }
        Start-Sleep -Milliseconds 150
    }
    return $null
}
function Send-GuiClick($Button) {
    # BM_CLICK is posted, so a click that opens a modal MessageBox does not block the test.
    [void][I1Native]::PostMessage([IntPtr][int]$Button.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
}
function Get-GuiMainWindow([int]$ProcessId) {
    $deadline = [DateTime]::Now.AddSeconds(25)
    while ([DateTime]::Now -lt $deadline) {
        foreach ($window in (Get-GuiWindows $ProcessId)) { if ($window.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $window.Current.NativeWindowHandle -ne 0 -and $window.Current.Name -match 'DenGo') { return $window } }
        Start-Sleep -Milliseconds 150
    }
    return $null
}
function Send-GuiUserClose($Window) {
    # SC_CLOSE through WM_SYSCOMMAND is what the title-bar X, Alt+F4 and the system menu send: CloseReason.UserClosing.
    [void][I1Native]::PostMessage([IntPtr][int]$Window.Current.NativeWindowHandle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)
}
function Send-GuiQueryEndSession($Window) {
    # WM_QUERYENDSESSION raises FormClosing(CloseReason.WindowsShutDown); the reply is 1 when the handler allows it and 0 when it cancels.
    $reply = [IntPtr]::Zero
    $sent = [I1Native]::SendMessageTimeout([IntPtr][int]$Window.Current.NativeWindowHandle, 0x0011, [IntPtr]::Zero, [IntPtr]::Zero, 2, 8000, [ref]$reply)
    if ($sent -eq [IntPtr]::Zero) { return -1 }
    return [int]$reply
}
function Start-GuiUnderTest {
    param([string]$Root, [string]$GuiName, [hashtable]$Environment, [string]$ResultPath, [string]$RunId)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $guiPath = Join-Path $Root ('installer\gui\' + $GuiName)
    $launcher = Join-Path $Root 'launcher.ps1'
    $startInfo.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Gui "{1}" -ResultPath "{2}" -RunId "{3}"' -f $launcher, $guiPath, $ResultPath, $RunId)
    $startInfo.UseShellExecute = $false
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $Root 'LocalAppData')
    $startInfo.EnvironmentVariables['TEMP'] = (Join-Path $Root 'Temp')
    $startInfo.EnvironmentVariables['TMP'] = (Join-Path $Root 'Temp')
    $startInfo.EnvironmentVariables['DENGO_I1_SANDBOX'] = $Root
    foreach ($key in $Environment.Keys) { $startInfo.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    return [System.Diagnostics.Process]::Start($startInfo)
}
