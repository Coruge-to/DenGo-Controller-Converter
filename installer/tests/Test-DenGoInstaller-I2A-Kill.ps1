# I2-A real-process kill tests (11 representative points) + cross-process mutex tests.
# Each kill case: (1) in-process simulated crash at point P -> full tree T1, (2) the same scenario in a child process that
# TerminateProcess-es itself at P -> full tree T2, (3) T1 == T2 (proves the snapshot method models a real kill), (4) recovery from T2.
param([string]$Scenario = 'F3', [string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2A-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-kill.jsonl'
$childScript = Join-Path $PSScriptRoot 'I2A.KillChild.ps1'

function Cnt($X) { if ($null -eq $X) { return 0 }; return @($X).Count }
function Same($A, $B) { return ((Cnt (Compare-I2ATree $A $B)) -eq 0) }
function Diff3($A, $B) { return ([string]::Join(' ', [string[]]@(Compare-I2ATree $A $B | Select-Object -First 3))) }
function Clean($Layout) { return ((Cnt (Test-I2ANoLeftovers $Layout)) -eq 0) }
function Get-Sha([byte[]]$Bytes) { $s = [System.Security.Cryptography.SHA256]::Create(); try { return ([System.BitConverter]::ToString($s.ComputeHash($Bytes))).Replace('-', '') } finally { $s.Dispose() } }

$exp = Get-I2AExpectedTrees $Scenario
$root = New-I2ASandbox ('kill-' + $Scenario)
$layout = New-I2AFixture $root $Scenario
Assert-I2AInsideSandbox $root @($layout.Dest, $layout.State, $layout.Backup)
$pristine = Save-I2ATree $root
$newSha = Get-Sha $layout.NewStateBytes
Install-I2AHarness

function Test-Forward($Map) { $k = 'f:state\installed-state.json'; return ($Map.ContainsKey($k) -and ($Map[$k] -eq $newSha)) }
function Start-Child([hashtable]$Params) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $childScript + '"'
    foreach ($k in $Params.Keys) { $argLine += ' -' + $k + ' "' + $Params[$k] + '"' }
    return (Start-Process powershell.exe -ArgumentList $argLine -PassThru -WindowStyle Hidden)
}
function Wait-Signal([string]$Path, [int]$Seconds = 40) {
    for ($i = 0; $i -lt ($Seconds * 10); $i++) { if ([System.IO.File]::Exists($Path)) { try { return [System.IO.File]::ReadAllText($Path) } catch { } }; Start-Sleep -Milliseconds 100 }
    return 'TIMEOUT'
}
function ConvertTo-B64($Object) { return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Compress))) }
function Test-NoOrphans([int]$ChildPid) {
    $alive = $null -ne (Get-Process -Id $ChildPid -ErrorAction SilentlyContinue)
    $kids = Cnt (Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $ChildPid) -ErrorAction SilentlyContinue)
    return (-not $alive) -and ($kids -eq 0)
}

# ---- census for ThrowTargets
Release-I2AHeld; Restore-I2ATree $root $pristine
Reset-I2AFault -Record $true; Reset-I2ACounters
$null = Invoke-I2ARun $layout
$allLabels = @($global:I2AFH.AllLabels)
$throwAt = ([array]::IndexOf($allLabels, 'before:Journal:Applied#5')) + 1
$lastId = @((Get-I2ASpec $Scenario)).Count - 1

$cases = @(
    @{ Id = 'K01-register-last';  Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Register#' + $lastId + '$'); Nth = 1 } },
    @{ Id = 'K02-marker-published'; Mode = 'Run';   Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:installing\.json$'; Nth = 1 } },
    @{ Id = 'K03-intent';         Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Intent#0$'; Nth = 1 } },
    @{ Id = 'K04-after-replace';  Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:a1\.dll$'; Nth = 1 } },
    @{ Id = 'K05-applied';        Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Applied#0$'; Nth = 1 } },
    @{ Id = 'K06-verified-last';  Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Verified#' + $lastId + '$'); Nth = 1 } },
    @{ Id = 'K07-commit-intent';  Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:CommitIntent$'; Nth = 1 } },
    @{ Id = 'K08-state-replaced'; Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:installed-state\.json$'; Nth = 1 } },
    @{ Id = 'K09-committed';      Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Committed$'; Nth = 1 } },
    @{ Id = 'K10-rollback-mid';   Mode = 'Run';     Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:a4\.dll$'; Nth = 2; ThrowTargets = @($throwAt) } },
    @{ Id = 'K11-recovery-mid';   Mode = 'Recover'; Pre = @{ CrashPattern = ('^after:Journal:Verified#' + $lastId + '$') }; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:w1\.dll$'; Nth = 1 } }
)

foreach ($case in $cases) {
    $id = $case.Id
    # ---- (1) in-process crash model
    Release-I2AHeld; Restore-I2ATree $root $pristine
    if ($case.ContainsKey('Pre')) {
        Reset-I2AFault -CrashPattern $case.Pre.CrashPattern; Reset-I2ACounters
        try { $null = Invoke-I2ARun $layout } catch { }
        Resume-I2AAfterCrash
        $preSnap = Save-I2ATree $root
    } else { $preSnap = $pristine }
    $fa = @{ Mode = $case.Fault.Mode; Pattern = $case.Fault.Pattern; Nth = $case.Fault.Nth; Action = 'Crash' }
    if ($case.Fault.ContainsKey('ThrowTargets')) { $fa.ThrowTargets = [int[]]@($case.Fault.ThrowTargets) }
    Reset-I2AFault @fa; Reset-I2ACounters
    $modelFired = ''
    try { if ($case.Mode -eq 'Run') { $null = Invoke-I2ARun $layout } else { $null = Invoke-I2ARecover $layout } } catch { }
    $modelFired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $treeModel = Get-I2AFullTree $layout

    # ---- (2) real kill in a child process
    Release-I2AHeld; Restore-I2ATree $root $preSnap
    $p = Start-Child @{ Mode = $case.Mode; Root = $root; Scenario = $Scenario; FaultB64 = (ConvertTo-B64 $case.Fault) }
    $exited = $p.WaitForExit(90000)
    $code = $(if ($exited) { $p.ExitCode } else { -999 })
    if (-not $exited) { try { $p.Kill() } catch { } }
    $orphanFree = Test-NoOrphans $p.Id
    $treeKill = Get-I2AFullTree $layout
    $killed = ($exited -and ($code -ne 7) -and ($code -ne 0))
    $equal = Same $treeModel $treeKill
    [void](Assert-I2A "TK-$id-killed" (($modelFired.Length -gt 0) -and $killed -and $orphanFree) "model fired at '$modelFired'; child exit code $code; no surviving child or grandchild")
    [void](Assert-I2A "TK-$id-equivalence" $equal "tree after TerminateProcess == tree of the in-process crash model ($(Diff3 $treeModel $treeKill))")

    # ---- (3) recovery from the real kill state
    $mapKill = Get-I2AManagedTree $layout
    $forward = Test-Forward $mapKill
    $rec = Invoke-I2ARecover $layout
    $map1 = Get-I2AManagedTree $layout
    $expect = $(if ($forward) { $exp.Post } else { $exp.Pre })
    $rec2 = Invoke-I2ARecover $layout
    $idem = (($rec2.Outcome -eq 'NotNeeded') -and (Same $map1 (Get-I2AManagedTree $layout)))
    $rerun = 'skipped'; $rerunOk = $true
    $global:I2AFH.IdCounter = 100   # deterministic test ids must not collide with the ids used by the killed runs
    if (-not $forward) { $rr = Invoke-I2ARun $layout; $rerun = [string]$rr.Code; $rerunOk = (($rr.Succeeded -eq $true) -and (Same $exp.Post (Get-I2AManagedTree $layout))) }
    $okOutcome = $(if ($forward) { (@('RolledForward', 'NotNeeded') -contains $rec.Outcome) } else { (@('RolledBack', 'NotNeeded') -contains $rec.Outcome) })
    $okRec = ($okOutcome -and (Same $expect $map1) -and (Clean $layout) -and $idem -and $rerunOk)
    [void](Assert-I2A "TK-$id-recovery" $okRec "outcome=$($rec.Outcome) forward=$forward tree==expected:$(Same $expect $map1) second=$($rec2.Outcome) rerun=$rerun clean=$(Clean $layout)")
    Add-I2AEvidence @{ id = "TK-$id"; scenario = $Scenario; fault = $modelFired; initialTree = (Get-I2ATreeDigest $exp.Pre); faultTree = (Get-I2ATreeDigest $mapKill); recoveredTree = (Get-I2ATreeDigest $map1)
        journalAtFault = (Get-I2AJournalText $layout); backups = (Get-I2ABackupList $layout); verdict = $rec.Outcome; pass = ($killed -and $equal -and $okRec -and $orphanFree); rerunnable = $idem; manualRecovery = $false; childExit = $code }
}

# ---- cross-process mutex tests ("simultaneous acquisition")
foreach ($cfg in @(@('Global', 'Explicit'), @('Global', 'Default'), @('Local', 'Explicit'), @('Local', 'Default'))) {
    $name = $cfg[0] + '\DenGoI2ATest-' + [guid]::NewGuid().ToString('N')
    $sig = Join-Path $root ('lock-' + [guid]::NewGuid().ToString('N') + '.txt')
    $h = Start-Child @{ Mode = 'HoldLock'; LockName = $name; LockSecurity = $cfg[1]; Signal = $sig }
    try {
        $s = Wait-Signal $sig
        [void](Assert-I2A "TM-$($cfg[0])-$($cfg[1])-holder" ($s -eq 'acquired=True reason=') "holder child: $s")
        Release-I2AHeld; Restore-I2ATree $root $pristine
        $before = Get-I2AFullTree $layout
        $try = DgLock-TryAcquire $name $cfg[1]
        [void](Assert-I2A "TM-$($cfg[0])-$($cfg[1])-contended" ((-not $try.Acquired) -and ($try.Reason -eq 'HeldByOther')) "second process: Acquired=$($try.Acquired) Reason=$($try.Reason) (never waits)")
        Reset-I2AFault; Reset-I2ACounters
        $run = Invoke-I2ARun $layout $name
        $after = Get-I2AFullTree $layout
        [void](Assert-I2A "TM-$($cfg[0])-$($cfg[1])-run-refused" ((-not $run.Succeeded) -and ($run.Code -eq 'AnotherOperationRunning') -and (Same $before $after)) "DgTx-Run refused with $($run.Code); the fixture is byte-identical (zero change)")
        # the lock says Busy even though a stale marker could exist; with the lock free the marker alone says Interrupted
        $cls = DgTx-Classify $layout.State $true
        [void](Assert-I2A "TM-$($cfg[0])-$($cfg[1])-classify-busy" ($cls.State -eq 'Busy') "classification while the lock is held: $($cls.State)")
        $h.Kill(); [void]$h.WaitForExit(10000)
        $try2 = DgLock-TryAcquire $name $cfg[1]
        [void](Assert-I2A "TM-$($cfg[0])-$($cfg[1])-after-kill" ($try2.Acquired -and (-not $try2.Abandoned)) "after the holder was killed: Acquired=$($try2.Acquired) Abandoned=$($try2.Abandoned) (no AbandonedMutexException: abandonment is NOT an interruption signal)")
        [void](DgLock-Release $name)
    } finally { try { if (-not $h.HasExited) { $h.Kill() } } catch { }; [System.IO.File]::Delete($sig) }
}
# same-process re-acquisition is refused (a Mutex is recursive for its own thread; the registry prevents false success)
$n = 'Local\DenGoI2ATest-' + [guid]::NewGuid().ToString('N')
$a = DgLock-TryAcquire $n 'Default'; $b = DgLock-TryAcquire $n 'Default'; [void](DgLock-Release $n); $c2 = DgLock-TryAcquire $n 'Default'; [void](DgLock-Release $n)
[void](Assert-I2A 'TM-same-process' ($a.Acquired -and (-not $b.Acquired) -and ($b.Reason -eq 'AlreadyHeldInProcess') -and $c2.Acquired) 'second acquisition in the same process is refused; after Release it succeeds')
# reference retention across GC
$name = 'Local\DenGoI2ATest-' + [guid]::NewGuid().ToString('N'); $sig = Join-Path $root 'gc.txt'
$g = Start-Child @{ Mode = 'GcProbe'; LockName = $name; LockSecurity = 'Default'; Signal = $sig }
try {
    $s = Wait-Signal $sig
    $try = DgLock-TryAcquire $name 'Default'
    [void](Assert-I2A 'TM-gc-retention' (($s -eq 'acquired=True gc=done') -and (-not $try.Acquired)) "the lock taken inside a function survives GC in the holder ($s); contender: Acquired=$($try.Acquired)")
} finally { try { $g.Kill() } catch { }; [System.IO.File]::Delete($sig) }
# elevated <-> non-elevated access is NOT tested here (needs UAC); it stays an open item for the I2-D prerequisite smoke.
Add-I2AResult 'TM-elevation-open-item' $true 'NOT TESTED by design: elevated vs non-elevated mutex access needs a UAC prompt; carried over to the I2-D prerequisite smoke'

Release-I2AHeld
Remove-I2ASandbox $root
Uninstall-I2AHarness
Write-Host ('Evidence: ' + $global:I2AEvidencePath)
Complete-I2ATests
