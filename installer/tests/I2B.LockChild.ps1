# Child process for the I2-B lock and kill tests: runs the product install in an existing sandbox.
#   GateMode: none | waitA | waitB | sleepA   (waitA/waitB signal, then wait for the release file; sleepA sleeps 3 seconds in phase A)
#   KillFaultB64: optional fault for the harness (Action = Kill: the child TerminateProcess-es itself at that point)
# The child writes a small JSON result file (ResultPath). A killed child writes nothing and exits abnormally.
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Mode = 'Install',     # Install | EmptyCore (the core runs an empty transaction under the I2-A fixture F4)
    [string]$Scenario = 'P2',
    [string]$LockName = '',
    [string]$GateMode = 'none',
    [string]$Signal = '',
    [string]$Release = '',
    [string]$StartBarrier = '',
    [string]$ResultPath = '',
    [string]$KillFaultB64 = '',
    [bool]$Shortcut = $true
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')
if ($LockName.Length -gt 0) { Set-I2BLockName $LockName }
if ($KillFaultB64.Length -gt 0) { Use-I2BHarnessIds }
$L = Get-I2BLayout $Root
if ($Mode -eq 'EmptyCore') {
    $layout = Get-I2ALayout $Root 'F4'
    Install-I2AHarness
    $spec = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($KillFaultB64)) | ConvertFrom-Json
    $fa = @{ Mode = [string]$spec.Mode; Action = 'Kill'; Pattern = [string]$spec.Pattern; Nth = [int]$spec.Nth }
    Reset-I2AFault @fa
    Reset-I2ACounters
    $factory = { param($c) return ,((New-Object System.Text.UTF8Encoding($false)).GetBytes('state-empty-v2')) }
    $null = DgTx-Run -StateRoot $layout.State -BackupRoot $layout.Backup -Operation 'Install' -Items @() -Policy $layout.Policy -NewStatePath $layout.StatePath -NewStateFactory $factory -AllowEmptyTransaction
    exit 7
}
if ($KillFaultB64.Length -gt 0) {
    Install-I2AHarness
    $spec = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($KillFaultB64)) | ConvertFrom-Json
    $fa = @{ Mode = [string]$spec.Mode; Action = 'Kill' }
    if ($null -ne $spec.PSObject.Properties['Pattern']) { $fa.Pattern = [string]$spec.Pattern }
    if ($null -ne $spec.PSObject.Properties['Nth']) { $fa.Nth = [int]$spec.Nth }
    Reset-I2AFault @fa
    Reset-I2ACounters
}
function Wait-File([string]$Path, [int]$Seconds) { for ($i = 0; $i -lt ($Seconds * 20); $i++) { if ([System.IO.File]::Exists($Path)) { return $true }; Start-Sleep -Milliseconds 50 }; return $false }
$gate = {
    param($phase)
    if ((($GateMode -eq 'waitA') -and ($phase -eq 'A')) -or (($GateMode -eq 'waitB') -and ($phase -eq 'B'))) {
        [System.IO.File]::WriteAllText($Signal, ('inside-gate-' + $phase))
        [void](Wait-File $Release 90)
    }
    if (($GateMode -eq 'sleepA') -and ($phase -eq 'A')) { Start-Sleep -Seconds 3 }
}
if ($StartBarrier.Length -gt 0) { [void](Wait-File $StartBarrier 60) }
$base = $(if ($Scenario -eq 'P3z') { 'P3' } else { $Scenario })
$plan = Get-I2BPlan $L $base
$options = @{ ShortcutRequested = $Shortcut; StageParent = $L.Stage; ProcessGate = $gate }
$r = Invoke-DenGoProductInstall -Layout $L.Product -Plan $plan -Options $options
$summary = [ordered]@{ Succeeded = [bool]$r.Succeeded; ErrorCode = [string]$r.ErrorCode; LockAcquired = [bool]$r.LockAcquired; TransactionId = [string]$r.TransactionId; RecoveryOutcome = $(if ($null -ne $r.Recovery) { [string]$r.Recovery.Outcome } else { '' }); Results = @($r.Results).Count }
if ($ResultPath.Length -gt 0) { [System.IO.File]::WriteAllText($ResultPath, ($summary | ConvertTo-Json -Compress)) }
exit 0
