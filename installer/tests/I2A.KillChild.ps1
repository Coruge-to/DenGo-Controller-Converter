# Child process for the I2-A kill tests. It runs the transaction core under the fault harness and kills ITSELF
# (Process.Kill = TerminateProcess: no finally blocks, no handle cleanup by PowerShell) at the requested point.
# Exit codes: 7 = the requested fault point was never reached (the child survived), 0 = lock modes finished normally. A killed child exits abnormally.
param(
    [Parameter(Mandatory = $true)][ValidateSet('Run', 'Recover', 'HoldLock', 'LockedRun', 'GcProbe')][string]$Mode,
    [string]$Root = '',
    [string]$Scenario = 'F3',
    [string]$FaultB64 = '',
    [string]$LockName = '',
    [string]$LockSecurity = 'Explicit',
    [string]$Signal = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')

if ($Mode -eq 'HoldLock') {
    $l = DgLock-TryAcquire $LockName $LockSecurity
    [System.IO.File]::WriteAllText($Signal, ('acquired=' + $l.Acquired + ' reason=' + $l.Reason))
    Start-Sleep -Seconds 120
    exit 0
}
if ($Mode -eq 'GcProbe') {
    # The lock is taken inside a function that returns nothing, then the GC runs: the registry must keep the mutex alive.
    function Take-Lock { $l = DgLock-TryAcquire $LockName $LockSecurity; return $l.Acquired }
    $got = Take-Lock
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
    [System.IO.File]::WriteAllText($Signal, ('acquired=' + $got + ' gc=done'))
    Start-Sleep -Seconds 120
    exit 0
}

$layout = Get-I2ALayout $Root $Scenario
Install-I2AHarness
$spec = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($FaultB64)) | ConvertFrom-Json
$faultArgs = @{ Mode = [string]$spec.Mode; Action = 'Kill' }
if ($null -ne $spec.PSObject.Properties['Pattern']) { $faultArgs.Pattern = [string]$spec.Pattern }
if ($null -ne $spec.PSObject.Properties['Nth']) { $faultArgs.Nth = [int]$spec.Nth }
if ($null -ne $spec.PSObject.Properties['Targets']) { $faultArgs.Targets = [int[]]@($spec.Targets) }
if ($null -ne $spec.PSObject.Properties['ThrowTargets']) { $faultArgs.ThrowTargets = [int[]]@($spec.ThrowTargets) }
Reset-I2AFault @faultArgs
Reset-I2ACounters
if ($Mode -eq 'Run') { $null = Invoke-I2ARun $layout }
elseif ($Mode -eq 'Recover') { $null = Invoke-I2ARecover $layout }
elseif ($Mode -eq 'LockedRun') { $null = Invoke-I2ARun $layout $LockName }
# Reaching this line means the fault point was never hit.
exit 7
