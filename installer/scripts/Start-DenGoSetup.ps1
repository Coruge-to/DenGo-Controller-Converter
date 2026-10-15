param(
    [switch]$Elevated,
    [string]$ResultPath = '',
    [string]$RunId = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms

function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-ForegroundInformation {
    param([string]$Text,[string]$Caption)
    $form = New-Object System.Windows.Forms.Form
    try {
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.Size = New-Object System.Drawing.Size(1,1)
        $form.ShowInTaskbar = $false
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
        $form.TopMost = $true
        $form.Opacity = 0
        $form.Show()
        $form.Activate()
        [void][System.Windows.Forms.MessageBox]::Show($form,$Text,$Caption,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    } finally {
        $form.Close()
        $form.Dispose()
    }
}
function Join-NativeArguments {
    param([string[]]$Values)
    $parts = New-Object System.Collections.ArrayList
    foreach ($value in @($Values)) {
        $text = [string]$value
        if ($text.IndexOf([char]34) -ge 0) { throw 'A process argument contains a double quote.' }
        $trailing = 0
        for ($index = $text.Length - 1; $index -ge 0 -and $text[$index] -eq [char]92; $index--) { $trailing++ }
        $suffix = if ($trailing -gt 0) { [string][char]92 * $trailing } else { '' }
        [void]$parts.Add(([string][char]34 + $text + $suffix + [string][char]34))
    }
    return [string]::Join(' ',[string[]]@($parts))
}

function Test-UacCancellation {
    param([System.Exception]$Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception] -and [int]$current.NativeErrorCode -eq 1223) { return $true }
        if (([int64]$current.HResult -band 65535) -eq 1223) { return $true }
        $current = $current.InnerException
    }
    return $false
}
$gui = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\gui\DenGoInstallerGui.ps1'))
if (-not [System.IO.File]::Exists($gui)) { throw ('Installer GUI not found: ' + $gui) }

if (-not (Test-Administrator)) {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$MyInvocation.MyCommand.Path,'-Elevated')
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $arguments += @('-ResultPath',$ResultPath,'-RunId',$RunId) }
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'powershell.exe'
        $startInfo.Arguments = Join-NativeArguments $arguments
        $startInfo.Verb = 'runas'
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        exit $process.ExitCode
    } catch {
        if (Test-UacCancellation $_.Exception) {
            Show-ForegroundInformation 'セットアップを中止しました' 'DenGo Controller Converter セットアップ'
            exit 2
        }
        throw
    }
}

$guiArguments = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui)
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $guiArguments += @('-ResultPath',$ResultPath,'-RunId',$RunId) }
& powershell.exe @guiArguments
# Exit code contract: 0 = Completed, 2 = Cancelled, anything else (or no exit code at all) = Failed.
$guiExitCode = $null
$guiExitVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
if ($null -ne $guiExitVariable) { $guiExitCode = $guiExitVariable.Value }
if ($null -eq $guiExitCode) { exit 1 }
exit ([int]$guiExitCode)
