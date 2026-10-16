# I2-D lock tests (separate processes, Global-form throw-away name; plan section 5.3): X1 install <-> uninstall exclude each other (both directions), X2 install x install,
# X3 uninstall x uninstall, X4 a killed holder leaves only marker + journal, X5 an abandoned mutex (a waiter holds a handle when the holder is killed) decides nothing,
# X6 a DACL this user cannot open is refused as AnotherOperationRunning, X7 a holder with the contract DACL is HeldByOther (never AccessDenied), X8 a dry run ignores the lock,
# X9 the lock is released in every ending.
# The existing I2B-Lock / I2C-Lock suites run unchanged as the regression. The product lock name is never taken: the engine is pointed at Global\DenGoI2DTest-<guid>.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2D.TestSupport.ps1')
$childB = Join-Path $PSScriptRoot 'I2B.LockChild.ps1'     # product install child (I2-B)
$childC = Join-Path $PSScriptRoot 'I2C.Child.ps1'         # product uninstall / install child (I2-C)
$childD = Join-Path $PSScriptRoot 'I2D.LockChild.ps1'     # holder / prober / waiter / keeper (I2-D)
$lockName = New-I2DLockName
Set-I2BLockName $lockName                                  # the in-process engine calls use the same throw-away name as the children
$procs = New-Object System.Collections.ArrayList

function Start-Child([string]$Script, [hashtable]$Params) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
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
function Get-Succeeded([string]$Path) { $s = Read-Summary $Path; if ($null -eq $s) { return $false }; return [bool]$s.Succeeded }
function Stop-Children { foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } } }
# kill a child that is expected to be alive; one that already ended (a refused holder) must not abort the whole suite: the assertions that follow report it
function Stop-One($Process) { try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }; try { [void]$Process.WaitForExit(20000) } catch { } }
function New-Paths([string]$Root) {
    $t = [guid]::NewGuid().ToString('N').Substring(0, 6)
    return @{ Sig = (Join-Path $Root ('sig-' + $t + '.txt')); Rel = (Join-Path $Root ('rel-' + $t + '.txt')); Sig2 = (Join-Path $Root ('sig2-' + $t + '.txt')); Rel2 = (Join-Path $Root ('rel2-' + $t + '.txt')); Out = (Join-Path $Root ('out-' + $t + '.json')); Out2 = (Join-Path $Root ('out2-' + $t + '.json')) }
}
# every section gets its own throw-away name: a lock that one section leaks (a defect under test) can never poison the sections after it
function Use-FreshLockName { $script:lockName = New-I2DLockName; Set-I2BLockName $script:lockName }
function New-InstallCase([string]$Name, [string]$Scenario) { Use-FreshLockName; $L = New-I2BScenario $Name $Scenario; return @{ L = $L; P = (New-Paths $L.Root) } }
function New-GenCase([string]$Name) {
    Use-FreshLockName
    $L = New-I2CCase $Name
    $g = Install-I2CGeneration $L
    if (-not $g.Succeeded) { throw ('fixture install failed: ' + $g.ErrorCode) }
    return @{ L = $L; P = (New-Paths $L.Root) }
}
function Test-Refusal($R, [string]$Reason) {
    $msg = [string]$R.ErrorMessage
    return (($R.Succeeded -eq $false) -and ([string]$R.ErrorCode -eq 'AnotherOperationRunning') -and ($R.LockAcquired -eq $false) -and ((Cnt $R.Results) -eq 0) -and ($null -eq $R.Recovery) -and ([string]$R.RollbackState -eq 'NotStarted') -and ($R.ManualCheckRequired -eq $false) -and ($msg.IndexOf('(' + $Reason + ')', [System.StringComparison]::Ordinal) -ge 0))
}
# a refused run has no Recovery object; reading .Outcome from $null would abort the suite under StrictMode instead of reporting the failure
function Get-RecoveryOutcome($R) { if ($null -ne $R.Recovery) { return [string]$R.Recovery.Outcome }; return '' }
function Get-PlanItemCount($R) { if ($null -ne $R.Plan) { return @($R.Plan.FileDecisions).Count }; return -1 }
function Test-LockFree([string]$Label) { $t = DgLock-TryAcquire $lockName 'Explicit'; if ($t.Acquired) { [void](DgLock-Release $lockName) }; return ($t.Acquired -eq $true) }

try {
    # =================================================== X1 install <-> uninstall exclude each other (both directions); the loser changes nothing
    $c = New-GenCase 'x1a'
    try {
        $L = $c.L; $p = $c.P
        $w = Start-Child $childC @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitA'; Signal = $p.Sig; Release = $p.Rel; ResultPath = $p.Out }
        $sig = Wait-Signal $p.Sig
        $before = Get-I2BFullTree $L
        $ri = Invoke-I2BInstall $L (Get-I2BPlan $L 'P1') $true
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'X1a-install-refused-while-an-uninstall-holds-the-lock' (($sig -eq 'inside-gate-A') -and ($ri.Succeeded -eq $false) -and ($ri.ErrorCode -eq 'AnotherOperationRunning') -and ($ri.LockAcquired -eq $false) -and ((Cnt $ri.Results) -eq 0) -and (Same $before $after)) "code=$($ri.ErrorCode) lock=$($ri.LockAcquired); nothing written (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($p.Rel, 'go'); [void]$w.WaitForExit(180000)
        [void](Assert-I2A 'X1a-the-uninstall-completes' ((Get-Succeeded $p.Out) -eq $true) 'winner finished')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
    $c = New-GenCase 'x1b'
    try {
        $L = $c.L; $p = $c.P
        $w = Start-Child $childC @{ Root = $L.Root; Mode = 'Install'; LockName = $lockName; GateMode = 'waitA'; Signal = $p.Sig; Release = $p.Rel; ResultPath = $p.Out }
        $sig = Wait-Signal $p.Sig
        $before = Get-I2BFullTree $L
        $ru = Invoke-I2CUninstall $L
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'X1b-uninstall-refused-while-an-install-holds-the-lock' (($sig -eq 'inside-gate-A') -and ($ru.Succeeded -eq $false) -and ($ru.ErrorCode -eq 'AnotherOperationRunning') -and ($ru.LockAcquired -eq $false) -and ($null -eq $ru.Recovery) -and (Same $before $after)) "code=$($ru.ErrorCode) lock=$($ru.LockAcquired); nothing written (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($p.Rel, 'go'); [void]$w.WaitForExit(180000)
        [void](Assert-I2A 'X1b-the-install-completes' ((Get-Succeeded $p.Out) -eq $true) 'winner finished')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== X2 two simultaneous installs (the Setup x Setup path): exactly one transaction
    $c = New-InstallCase 'x2' 'P1'
    try {
        $L = $c.L
        $barrier = Join-Path $L.Root 'start.txt'
        $o1 = Join-Path $L.Root 'racer1.json'; $o2 = Join-Path $L.Root 'racer2.json'
        $a = Start-Child $childB @{ Root = $L.Root; Scenario = 'P1'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o1 }
        $b = Start-Child $childB @{ Root = $L.Root; Scenario = 'P1'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o2 }
        Start-Sleep -Seconds 4
        [System.IO.File]::WriteAllText($barrier, 'go')
        [void]$a.WaitForExit(180000); [void]$b.WaitForExit(180000)
        $ra = Read-Summary $o1; $rb = Read-Summary $o2
        $winners = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $true })
        $losers = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $false })
        [void](Assert-I2A 'X2-install-x-install-exactly-one-winner' (($winners.Count -eq 1) -and ($losers.Count -eq 1) -and ($losers[0].ErrorCode -eq 'AnotherOperationRunning') -and ($losers[0].LockAcquired -eq $false)) "winners=$($winners.Count) losers=$($losers.Count) loserCode=$(if ($losers.Count -gt 0) { $losers[0].ErrorCode })")
        $hist = @(Get-I2BHistoryJournals $L)
        [void](Assert-I2A 'X2-install-x-install-one-transaction-no-double-apply' (($hist.Count -eq 1) -and ($hist[0] -like '*.committed.jsonl') -and ((@(Get-I2BActiveTxnDirs $L)).Count -eq 0) -and (Test-I2BStateValid $L) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) "history journals=$($hist.Count)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== X3 two simultaneous uninstalls: exactly one transaction
    $c = New-GenCase 'x3'
    try {
        $L = $c.L
        $barrier = Join-Path $L.Root 'start.txt'
        $o1 = Join-Path $L.Root 'racer1.json'; $o2 = Join-Path $L.Root 'racer2.json'
        $a = Start-Child $childC @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o1 }
        $b = Start-Child $childC @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'sleepA'; StartBarrier = $barrier; ResultPath = $o2 }
        Start-Sleep -Seconds 6
        [System.IO.File]::WriteAllText($barrier, 'go')
        [void]$a.WaitForExit(240000); [void]$b.WaitForExit(240000)
        $ra = Read-Summary $o1; $rb = Read-Summary $o2
        $winners = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $true })
        $losers = @($ra, $rb | Where-Object { $null -ne $_ -and $_.Succeeded -eq $false })
        [void](Assert-I2A 'X3-uninstall-x-uninstall-exactly-one-winner' (($winners.Count -eq 1) -and ($losers.Count -eq 1) -and ($losers[0].ErrorCode -eq 'AnotherOperationRunning') -and ($losers[0].LockAcquired -eq $false)) "winners=$($winners.Count) losers=$($losers.Count) loserCode=$(if ($losers.Count -gt 0) { $losers[0].ErrorCode })")
        [void](Assert-I2A 'X3-uninstall-x-uninstall-one-transaction' ((@(Get-I2CHistoryFiles $L 'txn-*.committed.jsonl').Count -eq 2) -and (@(Get-I2CHistoryFiles $L 'txn-*.rolledback.jsonl').Count -eq 0) -and (@(Get-I2BActiveTxnDirs $L).Count -eq 0) -and (Test-I2CUsValid $L) -and ((Cnt (Test-I2CLeftovers $L)) -eq 0)) 'install + one uninstall in history; no orphan transaction folder, marker or tmp')
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== X4 the holder is killed in the middle: the lock vanishes, marker + journal remain and decide (install, then uninstall)
    $c = New-InstallCase 'x4i' 'P2'
    try {
        $L = $c.L; $p = $c.P
        $preTree = Get-I2BManagedTree $L
        $w = Start-Child $childB @{ Root = $L.Root; Scenario = 'P2'; LockName = $lockName; GateMode = 'waitB'; Signal = $p.Sig; Release = $p.Rel }
        $sig = Wait-Signal $p.Sig
        Stop-One $w
        if ([System.IO.File]::Exists($p.Sig)) { [System.IO.File]::Delete($p.Sig) }
        $markerLeft = [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json'))
        $probe = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'X4i-lock-vanishes-with-the-killed-holder' (($sig -eq 'inside-gate-B') -and $markerLeft -and ($probe.Acquired -eq $true) -and ($probe.Abandoned -eq $false)) "marker left=$markerLeft acquired=$($probe.Acquired) abandoned=$($probe.Abandoned)")
        [void](DgLock-Release $lockName)
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        $post = Get-I2BManagedTree $L
        [void](Assert-I2A 'X4i-next-run-recovers-from-marker-and-journal' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ((Get-RecoveryOutcome $r) -eq 'RolledBack') -and (Same $preTree $post)) "code=$($r.ErrorCode) recovery=$((Get-RecoveryOutcome $r)) diff=[$(Diff3 $preTree $post)]")
        $r2 = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        [void](Assert-I2A 'X4i-and-then-installs' (($r2.Succeeded -eq $true) -and (Test-I2BStateValid $L)) "second run: $($r2.ErrorCode)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
    $c = New-GenCase 'x4u'
    try {
        $L = $c.L; $p = $c.P
        $preTree = Get-I2CTree $L -NormalizeState
        $w = Start-Child $childC @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitB'; Signal = $p.Sig; Release = $p.Rel }
        $sig = Wait-Signal $p.Sig
        Stop-One $w
        if ([System.IO.File]::Exists($p.Sig)) { [System.IO.File]::Delete($p.Sig) }
        $markerLeft = [System.IO.File]::Exists((Get-I2CUmPath $L))
        $probe = DgLock-TryAcquire $lockName 'Explicit'
        [void](Assert-I2A 'X4u-lock-vanishes-with-the-killed-holder' (($sig -eq 'inside-gate-B') -and $markerLeft -and ($probe.Acquired -eq $true) -and ($probe.Abandoned -eq $false)) "marker left=$markerLeft acquired=$($probe.Acquired) abandoned=$($probe.Abandoned)")
        [void](DgLock-Release $lockName)
        $r = Invoke-I2CUninstall $L
        $post = Get-I2CTree $L -NormalizeState
        [void](Assert-I2A 'X4u-next-run-recovers-from-marker-and-journal' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ((Get-RecoveryOutcome $r) -eq 'RolledBack') -and (Same $preTree $post)) "code=$($r.ErrorCode) recovery=$((Get-RecoveryOutcome $r)) diff=[$(Diff3 $preTree $post)]")
        $r2 = Invoke-I2CUninstall $L
        [void](Assert-I2A 'X4u-and-then-uninstalls' (($r2.Succeeded -eq $true) -and (Test-I2CUsValid $L)) "second run: $($r2.ErrorCode)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== X5 a waiter holds a handle while the holder is killed: the abandoned mutex is acquired, and the engine still decides from marker + journal only
    $c = New-InstallCase 'x5a' 'P2'
    try {
        $L = $c.L; $p = $c.P
        $w = Start-Child $childB @{ Root = $L.Root; Scenario = 'P2'; LockName = $lockName; GateMode = 'waitB'; Signal = $p.Sig; Release = $p.Rel }
        $sig = Wait-Signal $p.Sig
        $waiter = Start-Child $childD @{ LockName = $lockName; Mode = 'Wait'; Signal = $p.Sig2; ResultPath = $p.Out2 }
        $wsig = Wait-Signal $p.Sig2
        Stop-One $w
        [void]$waiter.WaitForExit(60000)
        $rw = Read-Summary $p.Out2
        [void](Assert-I2A 'X5a-waiter-acquires-the-abandoned-mutex' (($sig -eq 'inside-gate-B') -and ($wsig -eq 'waiting') -and ($null -ne $rw) -and ($rw.Abandoned -eq $true)) "holder signal=$sig waiter signal=$wsig abandoned=$(if ($null -ne $rw) { $rw.Abandoned } else { 'no result' })")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
    $c = New-InstallCase 'x5b' 'P2'
    try {
        $L = $c.L; $p = $c.P
        $preTree = Get-I2BManagedTree $L
        $w = Start-Child $childB @{ Root = $L.Root; Scenario = 'P2'; LockName = $lockName; GateMode = 'waitB'; Signal = $p.Sig; Release = $p.Rel }
        $sig = Wait-Signal $p.Sig
        $keeper = Start-Child $childD @{ LockName = $lockName; Mode = 'Keep'; Signal = $p.Sig2; Release = $p.Rel2; ResultPath = $p.Out2 }
        $ksig = Wait-Signal $p.Sig2
        Stop-One $w
        foreach ($signalFile in @($p.Sig, $p.Sig2)) { if ([System.IO.File]::Exists($signalFile)) { [System.IO.File]::Delete($signalFile) } }   # the test's own signal files are not part of the product tree
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true      # the object survives (the keeper's handle): this acquire sees an abandoned mutex
        $post = Get-I2BManagedTree $L
        [void](Assert-I2A 'X5b-engine-decides-from-marker-and-journal-not-from-abandonment' (($ksig -eq 'kept') -and ($r.LockAcquired -eq $true) -and ($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ((Get-RecoveryOutcome $r) -eq 'RolledBack') -and (Same $preTree $post)) "keeper=$ksig lock=$($r.LockAcquired) code=$($r.ErrorCode) recovery=$((Get-RecoveryOutcome $r)) diff=[$(Diff3 $preTree $post)]")
        $r2 = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        [void](Assert-I2A 'X5b-and-then-installs' (($r2.Succeeded -eq $true) -and (Test-I2BStateValid $L)) "second run: $($r2.ErrorCode)")
        [System.IO.File]::WriteAllText($p.Rel2, 'go'); [void]$keeper.WaitForExit(60000)
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== X6 a DACL this user cannot open: refused as AnotherOperationRunning (reason AccessDenied), nothing changed
    $ci = New-InstallCase 'x6i' 'P2'
    $cu = New-GenCase 'x6u'
    try {
        $p = $ci.P
        $h = Start-Child $childD @{ LockName = $lockName; Mode = 'Hold'; Security = 'SystemOnly'; Signal = $p.Sig; Release = $p.Rel; ResultPath = $p.Out }
        $sig = Wait-Signal $p.Sig
        $beforeI = Get-I2BFullTree $ci.L; $beforeU = Get-I2BFullTree $cu.L
        $ri = Invoke-I2BInstall $ci.L (Get-I2BPlan $ci.L 'P2') $true
        $ru = Invoke-I2CUninstall $cu.L
        $afterI = Get-I2BFullTree $ci.L; $afterU = Get-I2BFullTree $cu.L
        [void](Assert-I2A 'X6-install-access-denied-is-refused-and-writes-nothing' (($sig -eq 'held') -and (Test-Refusal $ri 'AccessDenied') -and (Same $beforeI $afterI)) "holder=$sig code=$($ri.ErrorCode) message=[$($ri.ErrorMessage)] diff=[$(Diff3 $beforeI $afterI)]")
        [void](Assert-I2A 'X6-uninstall-access-denied-is-refused-and-writes-nothing' (($sig -eq 'held') -and (Test-Refusal $ru 'AccessDenied') -and (Same $beforeU $afterU)) "code=$($ru.ErrorCode) message=[$($ru.ErrorMessage)] diff=[$(Diff3 $beforeU $afterU)]")
        [System.IO.File]::WriteAllText($p.Rel, 'go'); [void]$h.WaitForExit(60000)
    } finally { Stop-Children; Remove-I2ASandbox $ci.L.Root; Remove-I2ASandbox $cu.L.Root }

    # =================================================== X7 a holder with the contract DACL (product DACL, and the test-built Synchronize|Modify DACL): another process sees HeldByOther, never AccessDenied
    foreach ($kind in 'Product', 'Engine') {
        $ci = New-InstallCase ('x7' + $kind.ToLowerInvariant()) 'P2'
        try {
            $p = $ci.P
            $h = Start-Child $childD @{ LockName = $lockName; Mode = 'Hold'; Security = $kind; Signal = $p.Sig; Release = $p.Rel; ResultPath = $p.Out }
            $sig = Wait-Signal $p.Sig
            $before = Get-I2BFullTree $ci.L
            $ri = Invoke-I2BInstall $ci.L (Get-I2BPlan $ci.L 'P2') $true
            $after = Get-I2BFullTree $ci.L
            $pr = Join-Path $ci.L.Root 'probe.json'
            $pc = Start-Child $childD @{ LockName = $lockName; Mode = 'Probe'; ResultPath = $pr }
            [void]$pc.WaitForExit(120000)
            $probeResult = Read-Summary $pr
            [void](Assert-I2A ('X7-' + $kind.ToLowerInvariant() + '-dacl-holder-is-held-by-other-not-access-denied') (($sig -eq 'held') -and (Test-Refusal $ri 'HeldByOther') -and (Same $before $after) -and ($null -ne $probeResult) -and ($probeResult.Acquired -eq $false) -and ($probeResult.Reason -eq 'HeldByOther')) "holder=$sig engine message=[$($ri.ErrorMessage)] separate-process probe: $(if ($null -ne $probeResult) { $probeResult.Reason } else { 'no result' }) diff=[$(Diff3 $before $after)]")
            [System.IO.File]::WriteAllText($p.Rel, 'go'); [void]$h.WaitForExit(60000)
        } finally { Stop-Children; Remove-I2ASandbox $ci.L.Root }
    }

    # =================================================== X8 a dry run neither takes the lock nor writes anything, even while another process holds it
    $c = New-GenCase 'x8'
    try {
        $L = $c.L; $p = $c.P
        $w = Start-Child $childC @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; GateMode = 'waitA'; Signal = $p.Sig; Release = $p.Rel; ResultPath = $p.Out }
        $sig = Wait-Signal $p.Sig
        $before = Get-I2BFullTree $L
        $d = Get-I2CDryRun $L
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'X8-dryrun-runs-while-the-lock-is-held-and-writes-nothing' (($sig -eq 'inside-gate-A') -and ($d.Succeeded -eq $true) -and ($d.ErrorCode -eq '') -and ($d.LockAcquired -eq $false) -and ((Get-PlanItemCount $d) -ge 8) -and (Same $before $after)) "plan items=$(Get-PlanItemCount $d); nothing written (diff=[$(Diff3 $before $after)])")
        [System.IO.File]::WriteAllText($p.Rel, 'go'); [void]$w.WaitForExit(180000)
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }

    # =================================================== X9 the lock is released in every ending (install, then uninstall)
    $c = New-InstallCase 'x9i' 'P2'
    try {
        $L = $c.L
        $thrown = ''
        try { [void](Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true { throw 'BlockedByRunningProcesses|RunningProducts=BVE Trainsim' }) } catch { $thrown = [string]$_.Exception.Message }
        [void](Assert-I2A 'X9i-released-after-a-process-gate-A-exception' (($thrown -like 'BlockedByRunningProcesses*') -and (Test-LockFree 'a')) "thrown=[$thrown]")
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true { param($phase) if ($phase -eq 'B') { throw 'BlockedByRunningProcesses|RunningProducts=PCSX2' } }
        [void](Assert-I2A 'X9i-released-after-a-rollback' (($r.Succeeded -eq $false) -and ($r.RollbackState -eq 'RolledBack') -and (Test-LockFree 'b')) "code=$($r.ErrorCode) rb=$($r.RollbackState)")
        [System.IO.File]::WriteAllText((Join-Path $L.Product.StateRoot 'installing.json'), '{"State":"Installing"}', (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        [void](Assert-I2A 'X9i-released-after-a-recovery-refusal' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and (Test-LockFree 'c')) "code=$($r.ErrorCode)")
        [System.IO.File]::Delete((Join-Path $L.Product.StateRoot 'installing.json'))
        $r = Invoke-I2BInstall $L (Get-I2BPlan $L 'P2') $true
        [void](Assert-I2A 'X9i-released-after-success' (($r.Succeeded -eq $true) -and (Test-LockFree 'd')) "succeeded=$($r.Succeeded) code=$($r.ErrorCode)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
    $c = New-GenCase 'x9u'
    try {
        $L = $c.L
        $pristine = Save-I2ATree $L.Root
        $ra = Invoke-I2CUninstall $L $true { param($phase) throw 'Close target processes before uninstall: BveTs.exe' }
        [void](Assert-I2A 'X9u-released-after-process-gate-A' (($ra.ErrorCode -eq 'BlockedByRunningProcesses') -and (Test-LockFree 'e')) "code=$($ra.ErrorCode)")
        $rb = Invoke-I2CUninstall $L $true { param($phase) if ($phase -eq 'B') { throw 'Close target processes before uninstall: rpcs3.exe' } }
        [void](Assert-I2A 'X9u-released-after-a-rollback' (($rb.Succeeded -eq $false) -and ($rb.RollbackState -eq 'RolledBack') -and (Test-LockFree 'f')) "code=$($rb.ErrorCode) rb=$($rb.RollbackState)")
        [System.IO.File]::WriteAllText((Join-Path $L.Product.StateRoot 'installing.json'), '{"State":"Installing"}', $script:Utf8)
        $rd = Invoke-I2CUninstall $L
        [void](Assert-I2A 'X9u-released-after-a-recovery-refusal' (($rd.Succeeded -eq $false) -and ($rd.ErrorCode -eq 'RecoveryRequired') -and (Test-LockFree 'g')) "code=$($rd.ErrorCode)")
        [System.IO.File]::Delete((Join-Path $L.Product.StateRoot 'installing.json'))
        Edit-I2CInstalledState $L { param($o) $x = Get-I2CRecord $o 'DenGoControllerConverter.exe' 'Core'; $x.Ownership = 'Mystery' }
        $re = Invoke-I2CUninstall $L
        [void](Assert-I2A 'X9u-released-after-a-blocking-refusal' (($re.Succeeded -eq $false) -and ($re.ErrorCode -eq 'UnsafeOrUnknown') -and (Test-LockFree 'h')) "code=$($re.ErrorCode)")
        Restore-I2ATree $L.Root $pristine
        $rf = Invoke-I2CUninstall $L
        [void](Assert-I2A 'X9u-released-after-success' (($rf.Succeeded -eq $true) -and (Test-LockFree 'i')) "succeeded=$($rf.Succeeded) code=$($rf.ErrorCode)")
    } finally { Stop-Children; Remove-I2ASandbox $c.L.Root }
} finally {
    Stop-Children
}
Complete-I2ATests
