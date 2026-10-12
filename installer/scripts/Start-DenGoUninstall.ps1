param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

$gui = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\gui\DenGoUninstallerGui.ps1'))
if (-not [System.IO.File]::Exists($gui)) { throw ('Uninstaller GUI not found: ' + $gui) }

if (-not (Test-Administrator)) {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$MyInvocation.MyCommand.Path,'-Elevated')
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = [string]::Join(' ',[string[]]@($arguments | ForEach-Object { if ([string]$_ -match '[" ]') { '"' + ([string]$_).Replace('"','\"') + '"' } else { [string]$_ } }))
    $startInfo.Verb = 'runas'
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        exit $process.ExitCode
    } catch [System.ComponentModel.Win32Exception] {
        if ([int]$_.Exception.NativeErrorCode -eq 1223) {
            Show-ForegroundInformation 'アンインストールを中止しました' 'DenGo Controller Converter アンインストール'
            exit 0
        }
        throw
    }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $gui
exit $LASTEXITCODE
