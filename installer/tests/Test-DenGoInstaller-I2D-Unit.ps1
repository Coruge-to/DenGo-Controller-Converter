# I2-D unit tests (same process; plan section 5.2): the DACL contract (U1), acquire / release semantics (U2), invalid names (U3), the engine's refusal output for every
# acquire failure reason (U4 / U5), the abandoned mutex (U6 / U7), a dry run next to a held lock (U8).
# Throw-away names only: the engine is pointed at Global\DenGoI2DTest-<guid> (Set-I2BLockName); the product lock name is never taken. Sandboxes live under TEMP.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')    # overrides Get-DenGoLockName with a per-process throw-away name; builds on I2B / I2A support
. (Join-Path $PSScriptRoot 'I2D.TestSupport.ps1')
$lockName = New-I2DLockName
Set-I2BLockName $lockName

# ---------------------------------------------------------------- U1 the DACL contract (SDDL of DgLock-NewSecurity, then of a real mutex made with it)
$sddl = (DgLock-NewSecurity).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
$problems = Get-I2DAceProblems $sddl (Get-I2DExpectedSids) $script:I2DSyncModify
[void](Assert-I2A 'U1-dacl-sddl-is-user-and-administrators-synchronize-modify-allow' ($problems.Count -eq 0) ("SDDL=$sddl; problems: " + [string]::Join(' | ', [string[]]@($problems))))
$probeName = New-I2DLockName
$r = DgLock-TryAcquire $probeName 'Explicit'
$live = ''
if ($r.Acquired) { $live = (DgLock-Registry)[$probeName].GetAccessControl().GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access); [void](DgLock-Release $probeName) }
$liveProblems = $(if ($live.Length -gt 0) { Get-I2DAceProblems $live (Get-I2DExpectedSids) $script:I2DSyncModify } else { @('mutex was not created') })
[void](Assert-I2A 'U1-live-mutex-carries-the-contract-dacl' (($r.Acquired -eq $true) -and ($liveProblems.Count -eq 0)) ("live SDDL=$live; problems: " + [string]::Join(' | ', [string[]]@($liveProblems))))

# ---------------------------------------------------------------- U2 acquire / re-acquire / release
$n2 = New-I2DLockName
$a = DgLock-TryAcquire $n2 'Explicit'
$b = DgLock-TryAcquire $n2 'Explicit'
$rel = DgLock-Release $n2
$c = DgLock-TryAcquire $n2 'Explicit'
$rel2 = DgLock-Release $n2
$relNone = DgLock-Release $n2
[void](Assert-I2A 'U2-acquire-reacquire-release-cycle' (($a.Acquired -eq $true) -and ($a.Abandoned -eq $false) -and ($b.Acquired -eq $false) -and ($b.Reason -eq 'AlreadyHeldInProcess') -and ($rel -eq $true) -and ($c.Acquired -eq $true) -and ($rel2 -eq $true) -and ($relNone -eq $false)) "first=$($a.Acquired) again=$($b.Reason) released=$rel reacquired=$($c.Acquired) release-when-not-held=$relNone")

# ---------------------------------------------------------------- U3 invalid names: never acquired, always CreateFailed (measured at the RED run: all three throw inside the Mutex constructor)
foreach ($case in @(@('too-long', ('Global\DenGoI2DTest-' + ('x' * 300))), @('nested-path', ('Global\DenGoI2DTest-a\b-' + [guid]::NewGuid().ToString('N'))), @('unknown-namespace', ('Bogus\DenGoI2DTest-' + [guid]::NewGuid().ToString('N'))))) {
    $x = DgLock-TryAcquire $case[1] 'Explicit'
    if ($x.Acquired) { [void](DgLock-Release $x.Name) }
    [void](Assert-I2A ('U3-invalid-name-' + $case[0]) (($x.Acquired -eq $false) -and ($x.Reason -eq 'CreateFailed') -and ($x.Abandoned -eq $false)) "acquired=$($x.Acquired) reason=$($x.Reason)")
}

# ---------------------------------------------------------------- U4 / U5 every acquire failure reason is the same refusal: AnotherOperationRunning, nothing created, nothing changed, the reason kept in the message
$Li = New-I2BScenario 'i2d-u4i' 'P2'
$Lu = New-I2CCase 'i2d-u4u'
$gen = Install-I2CGeneration $Lu
if (-not $gen.Succeeded) { throw ('fixture install failed: ' + $gen.ErrorCode) }
function Test-Refusal($R, [string]$Reason) {
    $msg = [string]$R.ErrorMessage
    return (($R.Succeeded -eq $false) -and ([string]$R.ErrorCode -eq 'AnotherOperationRunning') -and ($R.LockAcquired -eq $false) -and ((Cnt $R.Results) -eq 0) -and ($null -eq $R.Recovery) -and ([string]$R.RollbackState -eq 'NotStarted') -and ($R.ManualCheckRequired -eq $false) -and ($msg.IndexOf('(' + $Reason + ')', [System.StringComparison]::Ordinal) -ge 0))
}
$holders = New-Object System.Collections.ArrayList
try {
    foreach ($reason in 'HeldByOther', 'AlreadyHeldInProcess', 'AccessDenied', 'CreateFailed') {
        $name = New-I2DLockName
        $tidy = $null
        if ($reason -eq 'HeldByOther') { $hd = Start-I2DHolder $name (New-I2DSecurity 'Product') $true; [void]$holders.Add($hd); $tidy = { $hd.Release(); $hd.Dispose() } }
        elseif ($reason -eq 'AlreadyHeldInProcess') { $own = DgLock-TryAcquire $name 'Explicit'; if (-not $own.Acquired) { throw 'could not pre-take the in-process lock' }; $tidy = { [void](DgLock-Release $name) } }
        elseif ($reason -eq 'AccessDenied') { $hd = Start-I2DHolder $name (New-I2DSecurity 'SystemOnly') $true; [void]$holders.Add($hd); $tidy = { $hd.Release(); $hd.Dispose() } }
        else { $name = 'Global\DenGoI2DTest-' + ('y' * 300) }
        Set-I2BLockName $name
        try {
            $beforeI = Get-I2BFullTree $Li; $beforeU = Get-I2BFullTree $Lu
            $ri = Invoke-I2BInstall $Li (Get-I2BPlan $Li 'P2') $true
            $ru = Invoke-I2CUninstall $Lu
            $afterI = Get-I2BFullTree $Li; $afterU = Get-I2BFullTree $Lu
            [void](Assert-I2A ("U4-install-refusal-" + $reason) ((Test-Refusal $ri $reason) -and (Same $beforeI $afterI)) "code=$($ri.ErrorCode) lock=$($ri.LockAcquired) rb=$($ri.RollbackState) message=[$($ri.ErrorMessage)] diff=[$(Diff3 $beforeI $afterI)]")
            [void](Assert-I2A ("U4-uninstall-refusal-" + $reason) ((Test-Refusal $ru $reason) -and (Same $beforeU $afterU)) "code=$($ru.ErrorCode) lock=$($ru.LockAcquired) rb=$($ru.RollbackState) message=[$($ru.ErrorMessage)] diff=[$(Diff3 $beforeU $afterU)]")
            [void](Assert-I2A ("U5-refusal-creates-nothing-" + $reason) (((Cnt (Test-I2BLeftovers $Li $true)) -eq 0) -and (-not [System.IO.Directory]::Exists((Join-Path $Li.Product.StateRoot 'txn'))) -and ((@(Get-I2BActiveTxnDirs $Lu)).Count -eq 0)) 'no marker, journal, report, backup, txn folder or stage folder was created')
        } finally { if ($null -ne $tidy) { & $tidy } }
    }
} finally {
    foreach ($hd in $holders) { try { $hd.Dispose() } catch { } }
    Set-I2BLockName $lockName
}

# ---------------------------------------------------------------- U6 / U7 an abandoned mutex is acquired and recorded, and decides nothing
$n6 = New-I2DLockName
$ab = Start-I2DHolder $n6 (New-I2DSecurity 'Product') $true
$ab.Abandon()
$t6 = DgLock-TryAcquire $n6 'Explicit'
if ($t6.Acquired) { [void](DgLock-Release $n6) }
$ab.Dispose()
[void](Assert-I2A 'U6-abandoned-mutex-is-acquired-and-flagged' (($t6.Acquired -eq $true) -and ($t6.Abandoned -eq $true)) "acquired=$($t6.Acquired) abandoned=$($t6.Abandoned)")
$n7 = New-I2DLockName
Set-I2BLockName $n7
$ab2 = Start-I2DHolder $n7 (New-I2DSecurity 'Product') $true
$ab2.Abandon()
try {
    $r7 = Invoke-I2BInstall $Li (Get-I2BPlan $Li 'P2') $true
    [void](Assert-I2A 'U7-install-under-an-abandoned-lock-is-a-normal-install' (($r7.Succeeded -eq $true) -and ($r7.LockAcquired -eq $true) -and (Test-I2BStateValid $Li) -and ([string]$r7.RecoveryOutcome -notin @('RolledBack', 'RolledForward'))) "succeeded=$($r7.Succeeded) code=$($r7.ErrorCode) recovery=$($r7.RecoveryOutcome) (abandonment alone is not an interrupted run)")
} finally { $ab2.Dispose(); Set-I2BLockName $lockName }

# ---------------------------------------------------------------- U8 a dry run neither takes the lock nor writes anything, even while the lock is held
$n8 = New-I2DLockName
Set-I2BLockName $n8
$h8 = Start-I2DHolder $n8 (New-I2DSecurity 'Product') $true
try {
    $before = Get-I2BFullTree $Lu
    $d = Get-I2CDryRun $Lu
    $after = Get-I2BFullTree $Lu
    [void](Assert-I2A 'U8-uninstall-dryrun-runs-while-the-lock-is-held-and-writes-nothing' (($d.Succeeded -eq $true) -and ($d.LockAcquired -eq $false) -and (Same $before $after)) "succeeded=$($d.Succeeded) lock=$($d.LockAcquired) diff=[$(Diff3 $before $after)]")
} finally { $h8.Dispose(); Set-I2BLockName $lockName }

Remove-I2ASandbox $Li.Root
Remove-I2ASandbox $Lu.Root
Complete-I2ATests
