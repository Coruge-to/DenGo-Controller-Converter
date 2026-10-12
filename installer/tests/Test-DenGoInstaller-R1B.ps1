$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$paths = @(
    (Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1')
    (Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1')
)
$pass=0
$fail=0
function Add-Result { param([string]$Id,[bool]$Ok);if($Ok){$script:pass++}else{$script:fail++};Write-Host (('{0} | {1}' -f $(if($Ok){'PASS'}else{'FAIL'}),$Id)) }
foreach($path in $paths){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Add-Result ('PARSE-' + [System.IO.Path]::GetFileName($path)) (@($errors).Count -eq 0)
    $text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
    Add-Result ('TITLE-' + [System.IO.Path]::GetFileName($path)) $text.Contains('対応ソフトが起動しています')
    Add-Result ('MESSAGE-' + [System.IO.Path]::GetFileName($path)) $text.Contains('対応ソフトをすべて終了してから「再試行」を押してください')
    Add-Result ('BVE6-' + [System.IO.Path]::GetFileName($path)) $text.Contains('BVE Trainsim 6')
    Add-Result ('BVE5-' + [System.IO.Path]::GetFileName($path)) $text.Contains('BVE Trainsim 5')
    Add-Result ('DENGO-' + [System.IO.Path]::GetFileName($path)) $text.Contains('DenGo Controller Converter')
    Add-Result ('RETRY-' + [System.IO.Path]::GetFileName($path)) $text.Contains('MessageBoxButtons]::RetryCancel')
}
$installer=Get-Content -LiteralPath $paths[0] -Raw -Encoding UTF8
$uninstaller=Get-Content -LiteralPath $paths[1] -Raw -Encoding UTF8
Add-Result 'INSTALLER-CANCEL-CONFIRM' $installer.Contains('if(Confirm-SetupCancel)')
Add-Result 'UNINSTALLER-GATE' $uninstaller.Contains('if (-not (Confirm-RunningProductsClosed))')
$installerEngine=Get-Content -LiteralPath (Join-Path $repo 'installer\scripts\Invoke-DenGoInstaller.ps1') -Raw -Encoding UTF8
$uninstallerEngine=Get-Content -LiteralPath (Join-Path $repo 'installer\scripts\Invoke-DenGoUninstaller.ps1') -Raw -Encoding UTF8
Add-Result 'INSTALLER-BUTTON-GATE' $installer.Contains('$next.Add_Click({if(-not(Confirm-RunningProductsClosed))')
Add-Result 'INSTALLER-APPLY-GATE' $installer.Contains('function Start-SandboxApply {') -and $installer.Contains('if(-not(Confirm-RunningProductsClosed)){if(Confirm-SetupCancel)')
Add-Result 'INSTALLER-ENGINE-GATE' $installerEngine.Contains('Assert-TargetProcessesStopped')
Add-Result 'UNINSTALLER-BUTTON-GATE' $uninstaller.Contains('$startButton.Add_Click({') -and $uninstaller.Contains('if (-not (Confirm-RunningProductsClosed))')
Add-Result 'UNINSTALLER-ENGINE-GATE' $uninstallerEngine.Contains('Assert-TargetProcessesStopped')
Write-Host (('PASS={0} FAIL={1}' -f $pass,$fail))
if($fail -ne 0){exit 1}
