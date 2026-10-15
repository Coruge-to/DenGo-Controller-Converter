# I2-B lock tests (same session, same elevation context): the loser is refused with AnotherOperationRunning and writes nothing,
# the winner's transaction is never touched, the lock is released in every ending, a killed holder leaves only the marker and journal.
# Global / Local, the DACL and elevated <-> non-elevated acquisition are decided in I2-D (not tested here).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')
$child = Join-Path $PSScriptRoot 'I2B.LockChild.ps1'
$lockName = Get-DenGoLockName     # unique per test process (I2B.TestSupport); the children receive it
$procs = New-Object System.Collections.ArrayList

function Start-LockChild([hashtable]$Params) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $child + '"'
    foreach ($k in $Params.Keys) { $argLine += ' -' + $k + ' "' + $Params[$k] + '"' }
    $p = Start-Process powershell.exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
    [void]$procs.Add($p)
    return $p
}
function Wait-Signal([string]$Path, [int]$Seconds = 60) {
    for ($i = 0; $i -lt ($Seconds * 10); $i++) { if ([System.IO.File]::Exists($Path)) { try { return [System.IO.File]::ReadAllText($Path) } catch { } }; Start-Sleep -Milliseconds 100 }
    return 'TIMEOUT'
}
function Read-Summary([string]$Path) { if ([System.IO.File]::Exists($Path)) { return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) } return $null }
function New-Case([string]$Name, [string]$Scenario) {
    $L = New-I2BScenario $Name $Scenario
    $sig = Join-Path $L.Root ('sig-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $rel = Join-Path $L.Root ('rel-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    return @{ L = $L; Sig = $sig; Rel = $rel; Pristine = (Save-I2ATree $L.Root) }
}
function Stop-Children { foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } } }

try {
    # =================================================== L1 the winner holds the lock at process gate A; the loser is refused
    $c = New-Case 'lock1' 'P2'
    try {
        $L = $c.L
        $pre = Get-I2BFullTree $L
        $out1 = Join-Path $L.Root 'winner1.json'
        $w = Start-LockChild @{ Root = $L.Root; Scenario = 'P2'; LockName = $lockName; GateMode = 'waitA'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $out1 }
        $sig = Wait-Signal $c.Sig
        [void](Assert-I2A 'L1-winner-holds-the-lock' ($sig -eq 'inside-gate-A') "signal=$sig")
        $before = Get-I2BFullTree $L
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'L1-loser-is-refused' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'AnotherOperationRunning') -and ($r.LockAcquired -eq $false) -and ($r.Results.Count -eq 0) -and ($r.Recovery -eq $null)) "code=$($r.ErrorCode) lock=$($r.LockAcquired)")
        [void](Assert-I2A 'L1-loser-writes-nothing' ((Same $before $after) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0) -and (-not [System.IO.Directory]::Exists((Join-Path $L.Product.StateRoot 'txn'))) -and (-not [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json')))) "no journal, marker, report, backup, txn folder or stage folder (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go')
        [void]$w.WaitForExit(120000)
        $s1 = Read-Summary $out1
        [void](Assert-I2A 'L1-winner-completes' (($null -ne $s1) -and ($s1.Succeeded -eq $true) -and ($s1.LockAcquired -eq $true)) "winner: $(if ($null -ne $s1) { $s1.Succeeded } else { 'no result' })")
        [void](Assert-I2A 'L1-winner-transaction-intact' ((@(Get-I2BHistoryJournals $L | Where-Object { $_ -like '*.committed.jsonl' }).Count -eq 1) -and (@(Get-I2BHistoryJournals $L | Where-Object { $_ -like '*.rolledback.jsonl' }).Count -eq 0) -and (Test-I2BStateValid $L) -and (-not [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json')))) 'exactly one committed journal, no rolled-back one, a valid new state')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L2 the winner is in the middle of its transaction (applied, not yet committed); the loser must not even look at it
    $c = New-Case 'lock2' 'P2'
    try {
        $L = $c.L
        $out2 = Join-Path $L.Root 'winner2.json'
        $w = Start-LockChild @{ Root = $L.Root; Scenario = 'P2'; LockName = $lockName; GateMode = 'waitB'; Signal = $c.Sig; Release = $c.Rel; ResultPath = $out2 }
        $sig = Wait-Signal $c.Sig
        [void](Assert-I2A 'L2-winner-is-mid-transaction' (($sig -eq 'inside-gate-B') -and [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json'))) "signal=$sig; marker present")
        $before = Get-I2BFullTree $L
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        $after = Get-I2BFullTree $L
        $reports = @(Get-ChildItem -LiteralPath $L.Product.StateRoot -Recurse -Filter 'recovery-report.txt' -ErrorAction SilentlyContinue)
        [void](Assert-I2A 'L2-loser-is-refused-before-the-recovery-gate' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'AnotherOperationRunning') -and ($null -eq $r.Recovery)) "code=$($r.ErrorCode) recovery=$($r.Recovery): the live marker was not treated as an interrupted install")
        [void](Assert-I2A 'L2-winner-transaction-untouched' ((Same $before $after) -and ($reports.Count -eq 0) -and ((@(Get-I2BActiveTxnDirs $L)).Count -eq 1)) "journal, marker, backups and items are byte-identical; recovery reports=$($reports.Count) (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($c.Rel, 'go')
        [void]$w.WaitForExit(120000)
        $s2 = Read-Summary $out2
        [void](Assert-I2A 'L2-winner-commits-after-the-loser-was-refused' (($null -ne $s2) -and ($s2.Succeeded -eq $true) -and (Test-I2BStateValid $L) -and (-not [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json')))) 'the winner committed normally')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L3 the holder is killed in the middle: the lock vanishes, the marker and journal remain and decide
    $c = New-Case 'lock3' 'P2'
    try {
        $L = $c.L
        $preTree = Get-I2BManagedTree $L
        $w = Start-LockChild @{ Root = $L.Root; Scenario = 'P2'; LockName = $lockName; GateMode = 'waitB'; Signal = $c.Sig; Release = $c.Rel }
        $sig = Wait-Signal $c.Sig
        $w.Kill(); [void]$w.WaitForExit(20000)
        if ([System.IO.File]::Exists($c.Sig)) { [System.IO.File]::Delete($c.Sig) }   # the test's own signal file is not part of the product tree
        $markerLeft = [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json'))
        $probe = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L3-lock-vanishes-with-the-killed-holder' (($sig -eq 'inside-gate-B') -and $markerLeft -and ($probe.Acquired -eq $true) -and ($probe.Abandoned -eq $false)) "marker left=$markerLeft; acquired=$($probe.Acquired) abandoned=$($probe.Abandoned) (no abandoned-mutex exception: it is never used as evidence)")
        [void](DgLock-Release $lockName)
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        $post = Get-I2BManagedTree $L
        [void](Assert-I2A 'L3-next-run-recovers-from-marker-and-journal' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ($r.Recovery.Outcome -eq 'RolledBack') -and (Same $preTree $post)) "code=$($r.ErrorCode) recovery=$($r.Recovery.Outcome) diff=[$(Diff3 $preTree $post)]")
        $r2 = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        [void](Assert-I2A 'L3-and-then-installs' (($r2.Succeeded -eq $true) -and (Test-I2BStateValid $L)) "second run: $($r2.ErrorCode)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L4 two simultaneous starts: exactly one transaction
    $c = New-Case 'lock4' 'P1'
    try {
        $L = $c.L
        $barrier = Join-Path $L.Root 'start.txt'
        $o1 = Join-Path $L.Root 'racer1.json'; $o2 = Join-Path $L.Root 'racer2.json'
        $a = Start-LockChild @{ Root = $L.Root; Scenario = 'P1'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o1 }
        $b = Start-LockChild @{ Root = $L.Root; Scenario = 'P1'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o2 }
        Start-Sleep -Seconds 4     # both are waiting at the barrier (module loading takes a while)
        [System.IO.File]::WriteAllText($barrier, 'go')
        [void]$a.WaitForExit(180000); [void]$b.WaitForExit(180000)
        $ra = Read-Summary $o1; $rb = Read-Summary $o2
        $winners = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $true })
        $losers = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $false })
        [void](Assert-I2A 'L4-exactly-one-winner' (($winners.Count -eq 1) -and ($losers.Count -eq 1) -and ($losers[0].ErrorCode -eq 'AnotherOperationRunning') -and ($losers[0].LockAcquired -eq $false)) "winners=$($winners.Count) losers=$($losers.Count) loserCode=$(if ($losers.Count -gt 0) { $losers[0].ErrorCode })")
        $hist = @(Get-I2BHistoryJournals $L)
        [void](Assert-I2A 'L4-one-transaction-no-double-apply' (($hist.Count -eq 1) -and ($hist[0] -like '*.committed.jsonl') -and ((@(Get-I2BActiveTxnDirs $L)).Count -eq 0) -and (Test-I2BStateValid $L) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) "history journals=$($hist.Count); no orphan transaction folder, marker, tmp or stage folder")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== L5 the lock is released in every ending of the install function
    $c = New-Case 'lock5' 'P2'
    try {
        $L = $c.L
        # (a) the process gate throws (BlockedByRunningProcesses): the exception propagates as before, the lock is released
        $thrown = ''
        try { [void](Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true { throw 'BlockedByRunningProcesses|RunningProducts=BVE Trainsim' }) } catch { $thrown = [string]$_.Exception.Message }
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L5a-lock-released-after-process-gate-exception' (($thrown -like 'BlockedByRunningProcesses*') -and ($t.Acquired -eq $true) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0) -and (-not [System.IO.Directory]::Exists((Join-Path $L.Product.StateRoot 'txn')))) "thrown=[$thrown] acquired=$($t.Acquired); nothing was written")
        [void](DgLock-Release $lockName)
        # (b) the process gate B throws after the items were applied: rolled back, lock released
        $n = 0
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true { param($phase) if ($phase -eq 'B') { throw 'BlockedByRunningProcesses|RunningProducts=PCSX2' } }
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L5b-lock-released-after-rollback' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'BlockedByRunningProcesses') -and ($r.RollbackState -eq 'RolledBack') -and ($t.Acquired -eq $true) -and (-not [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json')))) "code=$($r.ErrorCode) rb=$($r.RollbackState) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
        # (c) success
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L5c-lock-released-after-success' (($r.Succeeded -eq $true) -and ($t.Acquired -eq $true)) "succeeded=$($r.Succeeded) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
        # (d) a recovery refusal returns a result and releases the lock
        [System.IO.File]::WriteAllText((Join-Path $L.Product.StateRoot 'installing.json'), '{"State":"Installing"}', (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        $t = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'L5d-lock-released-after-a-recovery-refusal' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($t.Acquired -eq $true)) "code=$($r.ErrorCode) acquired=$($t.Acquired)")
        [void](DgLock-Release $lockName)
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
} finally {
    Stop-Children
}
Complete-I2ATests
