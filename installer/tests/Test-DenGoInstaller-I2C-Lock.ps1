# I2-C lock tests (same session, same elevation context): the loser is refused with AnotherOperationRunning and writes nothing, the winner's
# transaction is never touched, the lock is released in every ending, a killed holder leaves only the marker and journal, an install and an
# uninstall exclude each other, and a dry run neither takes the lock nor writes anything.
# Global / Local, the DACL and elevated <-> non-elevated acquisition are decided in I2-D (not tested here).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')
$child = Join-Path $PSScriptRoot 'I2C.Child.ps1'
$lockName = Get-DenGoLockName     # unique per test process (I2B.TestSupport); the children receive it
$procs = New-Object System.Collections.ArrayList
function Start-LockChild([hashtable]$Params) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $child + '"'
    foreach ($k in $Params.Keys) { $argLine += ' -' + $k + ' "' + $Params[$k] + '"' }
    $p = Start-Process powershell.exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
    [void]$procs.Add($p)
    return $p
}
function Wait-Signal([string]$Path, [int]$Seconds = 90) {
    for ($i = 0; $i -lt ($Seconds * 10); $i++) { if ([System.IO.File]::Exists($Path)) { try { return [System.IO.File]::ReadAllText($Path) } catch { } }; Start-Sleep -Milliseconds 100 }
    return 'TIMEOUT'
}
function Read-Summary([string]$Path) { if ([System.IO.File]::Exists($Path)) { return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) } return $null }
function New-Case([string]$Name) {
    $L = New-I2CCase $Name
    $g = Install-I2CGeneration $L
    if (-not $g.Succeeded) { throw ('fixture install failed: ' + $g.ErrorCode) }
    $sig = Join-Path $L.Root ('sig-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $rel = Join-Path $L.Root ('rel-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    return @{ L = $L; Sig = $sig; Rel = $rel; Pristine = (Save-I2ATree $L.Root) }
}
function Stop-Children { foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } } }
function Get-ActiveTxnDirs($L) { return @(Get-I2BActiveTxnDirs $L) }

try {
    # =================================================== L1 the winner holds the lock at process gate A; the loser is refused and writes nothing
    $c = New-Case 'lock1'
    try {
        $L = $c.L
        $out1 = Join-Path $L.Root 'winner1.json'
        $w = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitA'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $out1 }
        $sig = Wait-Signal $c.Sig
        [void](Assert-I2A 'L1-winner-holds-the-lock' ($sig -eq 'inside-gate-A') "signal=$sig")
        $before = Get-I2BFullTree $L
        $r = Invoke-I2CUninstall $L
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'L1-loser-is-refused' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'AnotherOperationRunning') -and ($r.LockAcquired -eq $false) -and ($r.Results.Count -eq 0) -and ($null -eq $r.Recovery)) "code=$($r.ErrorCode) lock=$($r.LockAcquired)")
        [void](Assert-I2A 'L1-loser-writes-nothing' ((Same $before $after) -and (@(Get-ActiveTxnDirs $L).Count -eq 0) -and (-not [System.IO.File]::Exists((Get-I2CUmPath $L)))) "no journal, marker, report, backup, archive or txn folder (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go')
        [void]$w.WaitForExit(180000)
        $s1 = Read-Summary $out1
        [void](Assert-I2A 'L1-winner-completes' (($null -ne $s1) -and ($s1.Succeeded -eq $true) -and ($s1.LockAcquired -eq $true) -and (Test-I2CUsValid $L)) "winner: $(if ($null -ne $s1) { $s1.Succeeded } else { 'no result' })")
        [void](Assert-I2A 'L1-winner-transaction-intact' ((@(Get-I2CHistoryFiles $L 'txn-*.committed.jsonl').Count -eq 2) -and (@(Get-I2CHistoryFiles $L 'txn-*.rolledback.jsonl').Count -eq 0) -and (-not [System.IO.File]::Exists($L.Product.StatePath)) -and (-not [System.IO.File]::Exists((Get-I2CUmPath $L)))) 'install + uninstall committed journals, no rolled-back one, installed-state retired')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L2 the winner is in the middle of its transaction (applied, not yet committed): the loser must not even look at it
    $c = New-Case 'lock2'
    try {
        $L = $c.L
        $out2 = Join-Path $L.Root 'winner2.json'
        $w = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitB'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $out2 }
        $sig = Wait-Signal $c.Sig
        [void](Assert-I2A 'L2-winner-is-mid-transaction' (($sig -eq 'inside-gate-B') -and [System.IO.File]::Exists((Get-I2CUmPath $L))) "signal=$sig; uninstalling.json present")
        $before = Get-I2BFullTree $L
        $r = Invoke-I2CUninstall $L
        $after = Get-I2BFullTree $L
        $reports = @(Get-ChildItem -LiteralPath $L.Product.StateRoot -Recurse -Filter 'recovery-report.txt' -ErrorAction SilentlyContinue)
        [void](Assert-I2A 'L2-loser-is-refused-before-the-recovery-gate' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'AnotherOperationRunning') -and ($null -eq $r.Recovery)) "code=$($r.ErrorCode) recovery=$($r.Recovery): the live marker was not treated as an interrupted uninstall")
        [void](Assert-I2A 'L2-winner-transaction-untouched' ((Same $before $after) -and ($reports.Count -eq 0) -and (@(Get-ActiveTxnDirs $L).Count -eq 1)) "journal, marker, backups and items are byte-identical; recovery reports=$($reports.Count) (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go')
        [void]$w.WaitForExit(180000)
        $s2 = Read-Summary $out2
        [void](Assert-I2A 'L2-winner-commits-after-the-loser-was-refused' (($null -ne $s2) -and ($s2.Succeeded -eq $true) -and (Test-I2CUsValid $L) -and (-not [System.IO.File]::Exists((Get-I2CUmPath $L)))) 'the winner committed normally')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L3 the holder is killed in the middle: the lock vanishes, the marker and journal remain and decide
    $c = New-Case 'lock3'
    try {
        $L = $c.L
        $preTree = Get-I2CTree $L -NormalizeState
        $w = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitB'; Signal = $c.Sig; Release = $c.Rel }
        $sig = Wait-Signal $c.Sig
        $w.Kill(); [void]$w.WaitForExit(20000)
        if ([System.IO.File]::Exists($c.Sig)) { [System.IO.File]::Delete($c.Sig) }
        $markerLeft = [System.IO.File]::Exists((Get-I2CUmPath $L))
        $probe = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L3-lock-vanishes-with-the-killed-holder' (($sig -eq 'inside-gate-B') -and $markerLeft -and ($probe.Acquired -eq $true) -and ($probe.Abandoned -eq $false)) "marker left=$markerLeft; acquired=$($probe.Acquired) abandoned=$($probe.Abandoned) (an abandoned mutex is never used as evidence)")
        [void](DgLock-Release $lockName)
        $r = Invoke-I2CUninstall $L
        $post = Get-I2CTree $L -NormalizeState
        [void](Assert-I2A 'L3-next-run-recovers-from-marker-and-journal' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ($r.Recovery.Outcome -eq 'RolledBack') -and (Same $preTree $post)) "code=$($r.ErrorCode) recovery=$($r.Recovery.Outcome) diff=[$(Diff3 $preTree $post)]")
        $r2 = Invoke-I2CUninstall $L
        [void](Assert-I2A 'L3-and-then-uninstalls' (($r2.Succeeded -eq $true) -and (Test-I2CUsValid $L)) "second run: $($r2.ErrorCode)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L4 two simultaneous uninstalls: exactly one transaction
    $c = New-Case 'lock4'
    try {
        $L = $c.L
        $barrier = Join-Path $L.Root 'start.txt'
        $o1 = Join-Path $L.Root 'racer1.json'; $o2 = Join-Path $L.Root 'racer2.json'
        $a = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o1 }
        $b = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o2 }
        Start-Sleep -Seconds 6
        [System.IO.File]::WriteAllText($barrier, 'go')
        [void]$a.WaitForExit(240000); [void]$b.WaitForExit(240000)
        $ra = Read-Summary $o1; $rb = Read-Summary $o2
        $winners = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $true })
        $losers = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $false })
        [void](Assert-I2A 'L4-exactly-one-winner' (($winners.Count -eq 1) -and ($losers.Count -eq 1) -and ($losers[0].ErrorCode -eq 'AnotherOperationRunning') -and ($losers[0].LockAcquired -eq $false)) "winners=$($winners.Count) losers=$($losers.Count) loserCode=$(if ($losers.Count -gt 0) { $losers[0].ErrorCode })")
        [void](Assert-I2A 'L4-one-uninstall-transaction-no-double-apply' ((@(Get-I2CHistoryFiles $L 'txn-*.committed.jsonl').Count -eq 2) -and (@(Get-I2CHistoryFiles $L 'txn-*.rolledback.jsonl').Count -eq 0) -and (@(Get-ActiveTxnDirs $L).Count -eq 0) -and (Test-I2CUsValid $L) -and ((Cnt (Test-I2CLeftovers $L)) -eq 0) -and (@(Get-I2CHistoryFiles $L 'installed-state.*.json').Count -eq 1)) 'install + one uninstall in history; one archive; no orphan transaction folder, marker or tmp')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L5 install and uninstall exclude each other (both directions)
    $c = New-Case 'lock5'
    try {
        $L = $c.L
        # (a) an uninstall holds the lock: the install is refused
        $o5 = Join-Path $L.Root 'winner5.json'
        $w = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitA'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $o5 }
        $sig = Wait-Signal $c.Sig
        $before = Get-I2BFullTree $L
        $ri = Invoke-I2BInstall $L (Get-I2BPlan $L 'P1') $true
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'L5a-install-refused-while-an-uninstall-holds-the-lock' (($sig -eq 'inside-gate-A') -and ($ri.Succeeded -eq $false) -and ($ri.ErrorCode -eq 'AnotherOperationRunning') -and (Same $before $after)) "code=$($ri.ErrorCode); nothing written (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go'); [void]$w.WaitForExit(180000)
        [void](Assert-I2A 'L5a-the-uninstall-completes' ((Read-Summary $o5).Succeeded -eq $true) 'winner finished')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
    $c = New-Case 'lock5b'
    try {
        $L = $c.L
        # (b) an install holds the lock: the uninstall is refused
        $o6 = Join-Path $L.Root 'winner6.json'
        $w = Start-LockChild @{ Root = $L.Root; Mode = 'Install'; LockName = $lockName; GateMode = 'waitA'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $o6 }
        $sig = Wait-Signal $c.Sig
        $before = Get-I2BFullTree $L
        $ru = Invoke-I2CUninstall $L
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'L5b-uninstall-refused-while-an-install-holds-the-lock' (($sig -eq 'inside-gate-A') -and ($ru.Succeeded -eq $false) -and ($ru.ErrorCode -eq 'AnotherOperationRunning') -and ($null -eq $ru.Recovery) -and (Same $before $after)) "code=$($ru.ErrorCode); nothing written (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go'); [void]$w.WaitForExit(180000)
        [void](Assert-I2A 'L5b-the-install-completes' ((Read-Summary $o6).Succeeded -eq $true) 'winner finished')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L6 the lock is released in every ending
    $c = New-Case 'lock6'
    try {
        $L = $c.L
        $thrown = ''
        $ra = Invoke-I2CUninstall $L $true { param($phase) throw 'Close target processes before uninstall: BveTs.exe' }
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L6a-lock-released-after-process-gate-A' (($ra.ErrorCode -eq 'BlockedByRunningProcesses') -and ($t.Acquired -eq $true) -and (@(Get-ActiveTxnDirs $L).Count -eq 0)) "code=$($ra.ErrorCode) acquired=$($t.Acquired); nothing was written")
        [void](DgLock-Release $lockName)
        $rb = Invoke-I2CUninstall $L $true { param($phase) if ($phase -eq 'B') { throw 'Close target processes before uninstall: rpcs3.exe' } }
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L6b-lock-released-after-rollback' (($rb.Succeeded -eq $false) -and ($rb.ErrorCode -eq 'BlockedByRunningProcesses') -and ($rb.RollbackState -eq 'RolledBack') -and ($t.Acquired -eq $true) -and (-not [System.IO.File]::Exists((Get-I2CUmPath $L)))) "code=$($rb.ErrorCode) rb=$($rb.RollbackState) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
        [System.IO.File]::WriteAllText((Join-Path $L.Product.StateRoot 'installing.json'), '{"State":"Installing"}', $script:Utf8)
        $rd = Invoke-I2CUninstall $L
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L6c-lock-released-after-a-recovery-refusal' (($rd.Succeeded -eq $false) -and ($rd.ErrorCode -eq 'RecoveryRequired') -and ($t.Acquired -eq $true)) "code=$($rd.ErrorCode) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
        [System.IO.File]::Delete((Join-Path $L.Product.StateRoot 'installing.json'))
        Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'DenGoControllerConverter.exe' 'Core'; $r.Ownership = 'Mystery' }
        $re = Invoke-I2CUninstall $L
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L6d-lock-released-after-a-blocking-refusal' (($re.Succeeded -eq $false) -and ($re.ErrorCode -eq 'UnsafeOrUnknown') -and ($t.Acquired -eq $true)) "code=$($re.ErrorCode) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
        Restore-I2ATree $L.Root $c.Pristine
        $rf = Invoke-I2CUninstall $L
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L6e-lock-released-after-success' (($rf.Succeeded -eq $true) -and ($t.Acquired -eq $true)) "succeeded=$($rf.Succeeded) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L7 a dry run neither takes the lock nor writes anything
    $c = New-Case 'lock7'
    try {
        $L = $c.L
        $o7 = Join-Path $L.Root 'winner7.json'
        $w = Start-LockChild @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitA'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $o7 }
        $sig = Wait-Signal $c.Sig
        $before = Get-I2BFullTree $L
        $d = Get-I2CDryRun $L
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'L7-dryrun-runs-while-the-lock-is-held-and-writes-nothing' (($sig -eq 'inside-gate-A') -and ($d.Succeeded -eq $true) -and ($d.ErrorCode -eq '') -and ($d.LockAcquired -eq $false) -and (@($d.Plan.FileDecisions).Count -ge 8) -and (Same $before $after)) "plan items=$(@($d.Plan.FileDecisions).Count); nothing written (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go'); [void]$w.WaitForExit(180000)
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
} finally {
    Stop-Children
}
Complete-I2ATests
