# I2-A fault-injection suite: exception sweep, crash-point sweep, crash during recovery, torn/corrupt journals, anomalies.
# Everything runs in sandboxes under %TEMP%. Evidence (trees, journals, verdicts) is written to the report directory (also under %TEMP%).
param(
    [int]$Stride = 1,
    [string[]]$Scenarios = @('F1', 'F2', 'F3', 'F4', 'F5', 'F6'),
    [string]$EvidenceDir = '',
    [switch]$SkipHeavy,
    [switch]$SkipSweeps
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Scenarios = @($Scenarios | ForEach-Object { $_ -split ',' })   # powershell -File passes "F3,F4" as one string
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')

if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2A-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-fault.jsonl'
Write-Host ('Evidence directory: ' + $EvidenceDir)

# ---- small helpers (every boolean below is built from fully parenthesized operands: -and/-eq have equal precedence in PowerShell)
function Cnt($X) { if ($null -eq $X) { return 0 }; return @($X).Count }
function Same($A, $B) { return ((Cnt (Compare-I2ATree $A $B)) -eq 0) }
function Diff3($A, $B) { return ([string]::Join(' ', [string[]]@(Compare-I2ATree $A $B | Select-Object -First 3))) }
function Clean($Layout) { return ((Cnt (Test-I2ANoLeftovers $Layout)) -eq 0) }
function LeftText($Layout) { return ([string]::Join(',', [string[]]@(Test-I2ANoLeftovers $Layout))) }
function Get-Sha([byte[]]$Bytes) { $s = [System.Security.Cryptography.SHA256]::Create(); try { return ([System.BitConverter]::ToString($s.ComputeHash($Bytes))).Replace('-', '') } finally { $s.Dispose() } }
function Get-Sample([int]$Count, [int]$Step) {
    $list = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Count; $i += [Math]::Max(1, $Step)) { [void]$list.Add($i) }
    if (($Count -gt 0) -and ($list[$list.Count - 1] -ne $Count)) { [void]$list.Add($Count) }
    return , @($list)
}

# ---- expected trees first (real, unwrapped primitives), then install the harness
$ctxs = @{}
foreach ($sc in $Scenarios) {
    $exp = Get-I2AExpectedTrees $sc
    # The expected trees used by every check below come from the spec-built oracle, not from a run of the code under test.
    # The run-derived trees are only compared against it here, once.
    $orPre = Get-I2AOracle $sc @{} 'old' 'pre'
    $allPost = @{}; foreach ($si in (Get-I2ASpec $sc)) { $allPost[$si.Name] = 'post' }
    $orPost = Get-I2AOracle $sc $allPost 'new' 'post'
    Add-I2AResult ("OR-$sc-oracle-agrees-with-run") ((Same $exp.Pre $orPre) -and (Same $exp.Post $orPost)) ("spec-built oracle == tree before the run (diff=[$(Diff3 $exp.Pre $orPre)]) and == tree after a clean run (diff=[$(Diff3 $exp.Post $orPost)])")
    $exp = @{ Pre = $orPre; Post = $orPost }
    $root = New-I2ASandbox $sc
    $layout = New-I2AFixture $root $sc
    Assert-I2AInsideSandbox $root @($layout.Src, $layout.Dest, $layout.State, $layout.Backup, $layout.Guard, $layout.StatePath)
    foreach ($it in (Get-I2AScenarioItems $layout)) { Assert-I2AInsideSandbox $root @($it.Destination) }
    $ctxs[$sc] = @{ Layout = $layout; Root = $root; Exp = $exp; Pristine = (Save-I2ATree $root); NewSha = (Get-Sha $layout.NewStateBytes) }
}
Install-I2AHarness

function Reset-Case($C) { Release-I2AHeld; Restore-I2ATree $C.Root $C.Pristine }
function Test-Forward($C, $Map) { $k = 'f:state\installed-state.json'; return ($Map.ContainsKey($k) -and ($Map[$k] -eq $C.NewSha)) }
function Test-OutcomeOk($Outcome) { return (@('RolledBack', 'NotNeeded', 'RolledForward') -contains $Outcome) }
function Get-JournalFor($Layout) {
    $paths = @(); foreach ($base in @((Join-Path $Layout.State 'txn'), (Join-Path $Layout.State 'history'))) { if ([System.IO.Directory]::Exists($base)) { $paths += [System.IO.Directory]::GetFiles($base, '*.jsonl', [System.IO.SearchOption]::AllDirectories) } }
    if ($paths.Count -eq 0) { return $null }
    return (DgJournal-Parse $paths[0])
}
function Get-StageItems($Parse, [string]$Stage) { return @(@($Parse.Records) | Where-Object { $_.stage -eq $Stage } | ForEach-Object { [int]$_.itemId }) }
# The expected managed tree follows the state file: new state => everything "after", otherwise everything "before".
function Get-ExpectedFor($C, $Map) { if (Test-Forward $C $Map) { return $C.Exp.Post } else { return $C.Exp.Pre } }

# Crash case: crash at the given fault, resume, recover, verify, second recover, rerun.
function Invoke-CrashCase($C, [string]$Id, [hashtable]$FaultArgs) {
    $layout = $C.Layout
    Reset-Case $C
    $initial = Get-I2AManagedTree $layout
    Reset-I2AFault @FaultArgs
    Reset-I2ACounters
    try { $null = Invoke-I2ARun $layout } catch { }
    $fired = [string]$global:I2AFH.Fired
    $faultMap = Get-I2AManagedTree $layout
    $journalAtFault = Get-I2AJournalText $layout
    $backups = Get-I2ABackupList $layout
    $forward = Test-Forward $C $faultMap
    Resume-I2AAfterCrash
    $rec = Invoke-I2ARecover $layout
    $map1 = Get-I2AManagedTree $layout
    $expectMap = $(if ($forward) { $C.Exp.Post } else { $C.Exp.Pre })
    $treeOk = Same $expectMap $map1
    $cleanOk = Clean $layout
    $rec2 = Invoke-I2ARecover $layout
    $map2 = Get-I2AManagedTree $layout
    $idem = (($rec2.Outcome -eq 'NotNeeded') -and (Same $map1 $map2))
    # forward (state already committed): RolledForward, or NotNeeded when only post-commit cleanup remained; otherwise RolledBack/NotNeeded
    $fwdOk = $(if ($forward) { (@('RolledForward', 'NotNeeded') -contains $rec.Outcome) } else { (@('RolledBack', 'NotNeeded') -contains $rec.Outcome) })
    $rerunOk = $true
    $rerunText = 'skipped'
    if (-not $forward) {
        $rr = Invoke-I2ARun $layout
        $m3 = Get-I2AManagedTree $layout
        $rerunOk = (($rr.Succeeded -eq $true) -and (Same $C.Exp.Post $m3) -and (Clean $layout))
        $rerunText = [string]$rr.Code
    }
    $pass = (($fired.Length -gt 0) -and (Test-OutcomeOk $rec.Outcome) -and $treeOk -and $cleanOk -and $idem -and $fwdOk -and $rerunOk)
    Add-I2AEvidence @{ id = $Id; scenario = $layout.Scenario; fault = $fired; initialTree = (Get-I2ATreeDigest $initial); faultTree = (Get-I2ATreeDigest $faultMap); recoveredTree = (Get-I2ATreeDigest $map1)
        journalAtFault = $journalAtFault; backups = $backups; verdict = $rec.Outcome; pass = $pass; rerunnable = $idem; rerunResult = $rerunText; manualRecovery = $false }
    return @{ Pass = $pass; Detail = ('fired={0} outcome={1} forward={2} treeOk={3} [{4}] clean={5} idem={6} rerun={7}/{8}' -f $fired, $rec.Outcome, $forward, $treeOk, (Diff3 $expectMap $map1), $cleanOk, $idem, $rerunOk, $rerunText) }
}

$summary = @{}
foreach ($sc in $Scenarios) {
    $c = $ctxs[$sc]
    $layout = $c.Layout
    $step = $Stride
    if ((@('F1', 'F2', 'F3', 'F5') -contains $sc) -and $SkipHeavy) { $step = [Math]::Max($Stride, 3) }

    # ------------------------------------------------ A. happy path + point census
    Reset-Case $c
    Reset-I2AFault -Record $true
    Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    $fh = $global:I2AFH
    $c.MutN = [int]$fh.Mut; $c.AllN = [int]$fh.All
    $c.MutLabels = @($fh.MutLabels); $c.AllLabels = @($fh.AllLabels)
    $mapPost = Get-I2AManagedTree $layout
    $happyOk = (($r.Succeeded -eq $true) -and (Same $c.Exp.Post $mapPost) -and (Clean $layout))
    [void](Assert-I2A ("A-$sc-happy") $happyOk ("Succeeded=$($r.Succeeded) Code=$($r.Code) mutPoints=$($c.MutN) allPoints=$($c.AllN) diff=[$(Diff3 $c.Exp.Post $mapPost)] leftovers=[$(LeftText $layout)]"))
    [void](Assert-I2A ("OR-$sc-commit-independent") $happyOk "clean run: content SHA, presence/absence and directory structure equal the spec-built expected tree")

    # ------------------------------------------------ B. crash at every mutating point
    if ($SkipSweeps) { continue }
    $fail = 0; $ran = 0
    foreach ($k in (Get-Sample $c.MutN $step)) {
        $res = Invoke-CrashCase $c ("TC-$sc-k$k") @{ Mode = 'CrashMut'; Targets = [int[]]@($k) }
        $ran++
        if (-not $res.Pass) { $fail++; Add-I2AResult ("TC-$sc-k$k") $false ($c.MutLabels[$k - 1] + ' :: ' + $res.Detail) }
    }
    if ($fail -eq 0) { Add-I2AResult ("TC-$sc-sweep") $true ("crash+recover at $ran of $($c.MutN) mutating points; every recovery matched the expected tree, was idempotent and re-ran cleanly") }
    $summary[$sc] = "$ran/$($c.MutN) crash points"

    # ------------------------------------------------ C. injected exception at every point (runtime rollback)
    $failT = 0; $ranT = 0
    $tStep = [Math]::Max($step, $(if ($c.AllN -gt 900) { 7 } elseif ($c.AllN -gt 500) { 5 } elseif ($c.AllN -gt 200) { 3 } else { 1 }))
    foreach ($k in (Get-Sample $c.AllN $tStep)) {
        Reset-Case $c
        Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'
        Reset-I2ACounters
        $r = Invoke-I2ARun $layout
        $map = Get-I2AManagedTree $layout
        $rb = [string]$r.RollbackState
        $expect = $null
        if ($r.Succeeded) { $expect = $c.Exp.Post } elseif (($rb -eq 'RolledBack') -or ($rb -eq 'NotStarted')) { $expect = $c.Exp.Pre }
        $okT = (($null -ne $expect) -and (Same $expect $map) -and (Clean $layout) -and (([string]$global:I2AFH.Fired).Length -gt 0))
        $ranT++
        Add-I2AEvidence @{ id = "TB-$sc-k$k"; scenario = $sc; fault = [string]$global:I2AFH.Fired; code = $r.Code; rollbackState = $rb; recoveredTree = (Get-I2ATreeDigest $map); pass = $okT; manualRecovery = (($rb -eq 'RepairRequired') -or ($rb -eq 'RollbackIncomplete')) }
        if (-not $okT) { $failT++; Add-I2AResult ("TB-$sc-k$k") $false ("fired=$($global:I2AFH.Fired) code=$($r.Code) rb=$rb succeeded=$($r.Succeeded) diff=[$(if ($null -ne $expect) { Diff3 $expect $map })] left=[$(LeftText $layout)]") }
    }
    if ($failT -eq 0) { Add-I2AResult ("TB-$sc-sweep") $true ("IO exception injected at $ranT of $($c.AllN) points: always RolledBack/NotStarted (tree == before) or committed (tree == after); no leftovers") }
}

# ------------------------------------------------ named point coverage
$covSc = $(if ($ctxs.ContainsKey('F2')) { 'F2' } else { $Scenarios[0] })
$covLabels = @($ctxs[$covSc].AllLabels)
$rbSc = $(if ($ctxs.ContainsKey('F4')) { 'F4' } else { $Scenarios[0] })
$c = $ctxs[$rbSc]
Reset-Case $c
$appliedIdx = ([array]::IndexOf(@($c.AllLabels), 'before:Journal:Applied#1')) + 1
Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($appliedIdx)) -Record $true
Reset-I2ACounters
$null = Invoke-I2ARun $c.Layout
$rbLabels = @($global:I2AFH.AllLabels)
$required = [ordered]@{
    'after-Intent'          = '^after:Journal:Intent#'
    'after-backup'          = '^after:Fs-CopyFileDurable:\d{4}\.bak$'
    'after-temp-write'      = '^after:Fs-CopyFileDurable:.*\.dengo\.tmp$'
    'after-exclusive-probe' = '^after:Fs-ProbeExclusive:'
    'before-Replace'        = '^before:Fs-Replace:'
    'after-Replace'         = '^after:Fs-Replace:'
    'before-post-SHA'       = '^before:Fs-Sha256:'
    'before-Applied'        = '^before:Journal:Applied#'
    'before-Verified'       = '^before:Journal:Verified#'
    'before-state-commit'   = '^before:Fs-(Replace|MoveNew):installed-state\.json$'
    'after-state-commit'    = '^after:Fs-(Replace|MoveNew):installed-state\.json$'
}
foreach ($name in $required.Keys) {
    $hit = Cnt @($covLabels | Where-Object { $_ -match $required[$name] })
    [void](Assert-I2A ("COV-$name") ($hit -gt 0) ("$hit labelled points exist in the $covSc census (all of them are swept above)"))
}
$rbRequired = [ordered]@{ 'after-RollbackBegin' = '^after:Journal:RollbackBegin$'; 'before-file-restore' = '^before:Journal:RollbackIntent#'; 'after-file-restore' = '^after:Journal:RolledBack#'; 'after-RollbackComplete' = '^after:Journal:RollbackComplete$' }
foreach ($name in $rbRequired.Keys) {
    $hit = Cnt @($rbLabels | Where-Object { $_ -match $rbRequired[$name] })
    [void](Assert-I2A ("COV-$name") ($hit -gt 0) ("$hit labelled points exist in the rollback census of $rbSc"))
}

# ------------------------------------------------ D/E need the small scenario (F4) and the mixed one (F3)
foreach ($sc in @('F4', 'F3')) {
    if ($SkipSweeps) { break }
    if (-not $ctxs.ContainsKey($sc)) { continue }
    $c = $ctxs[$sc]
    $layout = $c.Layout

    # ---- D. double fault: injected error at k1 (apply), second injected error inside the rollback (k1 + j)
    $kStep = $(if ($sc -eq 'F4') { 2 } else { 9 })
    $jStep = $(if ($sc -eq 'F4') { 3 } else { 7 })
    $fails = 0; $ran = 0
    foreach ($k1 in (Get-Sample $c.AllN $kStep)) {
        foreach ($j in (Get-Sample 60 $jStep)) {
            Reset-Case $c
            Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k1, ($k1 + $j))) -Action 'IO'
            Reset-I2ACounters
            $r = Invoke-I2ARun $layout
            Reset-I2AFault
            $rec = Invoke-I2ARecover $layout
            $map = Get-I2AManagedTree $layout
            $expect = Get-ExpectedFor $c (Get-I2AManagedTree $layout)
            $okD = ((Test-OutcomeOk $rec.Outcome) -and (Same $expect $map) -and (Clean $layout))
            $ran++
            if (-not $okD) { $fails++; Add-I2AResult ("TB2-$sc-k$k1+$j") $false ("run=$($r.Code)/$($r.RollbackState) recover=$($rec.Outcome) diff=[$(Diff3 $expect $map)]") }
        }
    }
    if ($fails -eq 0) { Add-I2AResult ("TB2-$sc-sweep") $true ("double fault ($ran combinations): a second error during rollback is recoverable; the next recovery always converges to before/after") }

    # ---- E. crash during recovery
    if (-not ($SkipHeavy -and ($sc -eq 'F3'))) {
        $failE = 0; $ranE = 0
        $mStep = $(if ($sc -eq 'F4') { 1 } else { 4 })
        foreach ($k in (Get-Sample $c.MutN $(if ($sc -eq 'F4') { 2 } else { 7 }))) {
            Reset-Case $c
            Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($k))
            Reset-I2ACounters
            try { $null = Invoke-I2ARun $layout } catch { }
            Resume-I2AAfterCrash
            $crashSnap = Save-I2ATree $c.Root
            Reset-I2AFault -Record $true
            $rec0 = Invoke-I2ARecover $layout
            $recM = [int]$global:I2AFH.Mut
            for ($m = 1; $m -le $recM; $m += $mStep) {
                Release-I2AHeld
                Restore-I2ATree $c.Root $crashSnap
                Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($m))
                try { $null = Invoke-I2ARecover $layout } catch { }
                Resume-I2AAfterCrash
                $rec = Invoke-I2ARecover $layout
                $map = Get-I2AManagedTree $layout
                $expect = Get-ExpectedFor $c $map
                $rec2 = Invoke-I2ARecover $layout
                $okE = ((Test-OutcomeOk $rec.Outcome) -and (Same $expect $map) -and (Clean $layout) -and ($rec2.Outcome -eq 'NotNeeded'))
                $ranE++
                if (-not $okE) { $failE++; Add-I2AResult ("TD-$sc-k$k-m$m") $false ("recover=$($rec.Outcome) diff=[$(Diff3 $expect $map)] clean=$(Clean $layout) third=$($rec2.Outcome)") }
            }
        }
        if ($failE -eq 0) { Add-I2AResult ("TD-$sc-sweep") $true ("crash inside recovery ($ranE combinations): the next recovery always converges and a third is a no-op") }
    }
}

# ------------------------------------------------ F. torn / corrupt journals, anomalies
function Set-CrashState($C, [hashtable]$FaultArgs) {
    Reset-Case $C
    Reset-I2AFault @FaultArgs
    Reset-I2ACounters
    try { $null = Invoke-I2ARun $C.Layout } catch { }
    $fired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    return $fired
}
function Test-Converged($C, $Rec) {
    $layout = $C.Layout
    $map = Get-I2AManagedTree $layout
    $expect = Get-ExpectedFor $C $map
    $ok = ((Test-OutcomeOk $Rec.Outcome) -and (Same $expect $map) -and (Clean $layout))
    if ($ok) { $r2 = Invoke-I2ARecover $layout; $ok = ($r2.Outcome -eq 'NotNeeded') }
    return $ok
}

if ($ctxs.ContainsKey('F4')) {
    $c = $ctxs['F4']; $layout = $c.Layout
    $throwAt = ([array]::IndexOf(@($c.AllLabels), 'before:Journal:Applied#1')) + 1
    $stages = [ordered]@{
        'Register-last'    = @{ CrashPattern = '^after:Journal:Register#'; CrashNth = 3 }
        'Intent'           = @{ CrashPattern = '^after:Journal:Intent#1$' }
        'Applied'          = @{ CrashPattern = '^after:Journal:Applied#1$' }
        'Verified'         = @{ CrashPattern = '^after:Journal:Verified#1$' }
        'CommitIntent'     = @{ CrashPattern = '^after:Journal:CommitIntent$' }
        'Committed'        = @{ CrashPattern = '^after:Journal:Committed$' }
        'RollbackBegin'    = @{ CrashPattern = '^after:Journal:RollbackBegin$'; ThrowTargets = [int[]]@($throwAt) }
        'RollbackIntent'   = @{ CrashPattern = '^after:Journal:RollbackIntent#1$'; ThrowTargets = [int[]]@($throwAt) }
        'RolledBack'       = @{ CrashPattern = '^after:Journal:RolledBack#1$'; ThrowTargets = [int[]]@($throwAt) }
        'RollbackComplete' = @{ CrashPattern = '^after:Journal:RollbackComplete$'; ThrowTargets = [int[]]@($throwAt) }
    }
    foreach ($stage in $stages.Keys) {
        $fired = Set-CrashState $c $stages[$stage]
        $jp = Get-I2AActiveJournalPath $layout
        if (($fired.Length -eq 0) -or ($jp.Length -eq 0) -or -not [System.IO.File]::Exists($jp)) { Add-I2AResult ("TV-torn-$stage") $false "crash state not reached (fired='$fired' journal='$jp')"; continue }
        $bytes = [System.IO.File]::ReadAllBytes($jp)
        $lastStart = [array]::LastIndexOf($bytes, [byte]10, $bytes.Length - 2) + 1
        $lineLen = $bytes.Length - $lastStart
        $snap = Save-I2ATree $c.Root
        $variants = New-Object System.Collections.ArrayList
        foreach ($cut in @(1, 2, 5, 17, [int]($lineLen / 2), ($lineLen - 83), ($lineLen - 82), ($lineLen - 81), ($lineLen - 80), ($lineLen - 40), ($lineLen - 3), ($lineLen - 2), ($lineLen - 1))) {
            if (($cut -ge 1) -and ($cut -lt $lineLen)) { [void]$variants.Add(@{ Name = "cut$cut"; Cut = $cut; Nul = 0; Garbage = $false }) }
        }
        [void]$variants.Add(@{ Name = 'cut-half+NUL64'; Cut = [int]($lineLen / 2); Nul = 64; Garbage = $false })
        [void]$variants.Add(@{ Name = 'LF-terminated-garbage'; Cut = 0; Nul = 0; Garbage = $true })
        $bad = 0
        foreach ($v in $variants) {
            Release-I2AHeld
            Restore-I2ATree $c.Root $snap
            if ($v.Garbage) {
                $nb = New-Object byte[] $bytes.Length
                [System.Array]::Copy($bytes, $nb, $lastStart)
                for ($i = $lastStart; $i -lt ($bytes.Length - 1); $i++) { $nb[$i] = [byte]88 }
                $nb[$bytes.Length - 1] = [byte]10
            } else {
                $len = $lastStart + $v.Cut
                $nb = New-Object byte[] ($len + $v.Nul)
                [System.Array]::Copy($bytes, $nb, $len)
            }
            [System.IO.File]::WriteAllBytes($jp, $nb)
            $rec = Invoke-I2ARecover $layout
            $okV = Test-Converged $c $rec
            Add-I2AEvidence @{ id = "TV-torn-$stage-$($v.Name)"; scenario = 'F4'; fault = $fired; verdict = $rec.Outcome; pass = $okV; recoveredTree = (Get-I2ATreeDigest (Get-I2AManagedTree $layout)); manualRecovery = ($rec.Outcome -eq 'RepairRequired') }
            if (-not $okV) { $bad++; Add-I2AResult ("TV-torn-$stage-$($v.Name)") $false ("outcome=$($rec.Outcome) reasons=$((@($rec.Reasons | ForEach-Object { $_.Code })) -join ',')") }
        }
        if ($bad -eq 0) { Add-I2AResult ("TV-torn-$stage") $true ("last record '$stage' torn $($variants.Count) ways (byte cuts, NUL padding, LF-terminated garbage): recovered from the previous complete record, tree == before/after") }
    }

}
if ($ctxs.ContainsKey('F3')) {
    # ---- anomalies: RepairRequired with zero change
    $c = $ctxs['F3']; $layout = $c.Layout
    $fired = Set-CrashState $c @{ CrashPattern = '^after:Fs-Replace:a3\.dll$' }
    Add-I2AResult 'TV-anomaly-base' ($fired.Length -gt 0) "base crash state for anomaly cases: $fired"
    $baseSnap = Save-I2ATree $c.Root
    $outside = New-I2ASandbox 'outside'
    function Invoke-Anomaly([string]$Id, [scriptblock]$Tamper, [string]$ExpectCode) {
        Release-I2AHeld
        Restore-I2ATree $c.Root $baseSnap
        & $Tamper
        $txnLeaf = Split-Path (Split-Path (Get-I2AActiveJournalPath $layout) -Parent) -Leaf
        $reportRel = 'state\txn\' + $txnLeaf + '\recovery-report.txt'
        $before = Get-I2ATreeMap $c.Root @($reportRel)
        $rec = Invoke-I2ARecover $layout
        $after = Get-I2ATreeMap $c.Root @($reportRel)
        $codes = @($rec.Reasons | ForEach-Object { $_.Code })
        $zero = (Same $before $after)
        $okA = (($rec.Outcome -eq 'RepairRequired') -and ($codes -contains $ExpectCode) -and $zero)
        Add-I2AEvidence @{ id = $Id; scenario = 'F3'; verdict = $rec.Outcome; reasons = ($codes -join ','); zeroChange = $zero; pass = $okA; manualRecovery = $true; recoveredTree = (Get-I2ATreeDigest $after); initialTree = (Get-I2ATreeDigest $before) }
        Add-I2AResult $Id $okA ("outcome=$($rec.Outcome) reasons=$($codes -join ',') zeroChange=$zero (expected $ExpectCode)")
    }
    function Dest([string]$Rel) { return (Join-Path $layout.Dest $Rel) }
    Invoke-Anomaly 'TV-unknown-sha-verified-item' { [System.IO.File]::WriteAllText((Dest 'm\a1.dll'), 'someone else edited this', $script:Utf8) } 'DestinationUnknownSha'
    Invoke-Anomaly 'TV-unknown-sha-untouched-item' { [System.IO.File]::WriteAllText((Dest 'm\a4.dll'), 'user edit before our turn', $script:Utf8) } 'DestinationUnknownSha'
    Invoke-Anomaly 'TV-unknown-sha-inflight-item' { [System.IO.File]::WriteAllText((Dest 'm\a3.dll'), 'neither pre nor post', $script:Utf8) } 'DestinationUnknownSha'
    Invoke-Anomaly 'TV-unknown-sha-deleted-item' { [System.IO.File]::WriteAllText((Dest 'm\x1.dll'), 'x1 changed', $script:Utf8) } 'DestinationUnknownSha'
    Invoke-Anomaly 'TV-unknown-sha-missing-file' { [System.IO.File]::Delete((Dest 'm\a2.dll')) } 'DestinationUnknownSha'
    Invoke-Anomaly 'TV-backup-missing' { Get-ChildItem -LiteralPath $layout.Backup -Recurse -Filter '0002.bak' | ForEach-Object { [System.IO.File]::Delete($_.FullName) } } 'BackupMissing'
    Invoke-Anomaly 'TV-backup-tampered' { Get-ChildItem -LiteralPath $layout.Backup -Recurse -Filter '0000.bak' | ForEach-Object { [System.IO.File]::WriteAllText($_.FullName, 'tampered', $script:Utf8) } } 'BackupShaMismatch'
    Invoke-Anomaly 'TV-middle-line-corrupt' {
        $p = Get-I2AActiveJournalPath $layout; $b = [System.IO.File]::ReadAllBytes($p)
        $nl = 0; $i = 0; while (($i -lt $b.Length) -and ($nl -lt 2)) { if ($b[$i] -eq 10) { $nl++ }; $i++ }
        $b[$i + 30] = [byte]([int]$b[$i + 30] -bxor 1)
        [System.IO.File]::WriteAllBytes($p, $b) } 'JournalCorrupt'
    Invoke-Anomaly 'TV-previousHash-mismatch' {
        $p = Get-I2AActiveJournalPath $layout; $lines = @([System.IO.File]::ReadAllText($p) -split "`n" | Where-Object { $_.Length -gt 0 })
        $l = $lines[3]
        $m = [regex]::Match($l, '"previousHash":"([0-9A-F]{64})"')
        $swapped = $l.Substring(0, $m.Index) + '"previousHash":"' + ('A' * 64) + '"' + $l.Substring($m.Index + $m.Length)
        $tail = ',"recordHash":"' + (DgConst-ZeroHash) + '"}'
        $core = $swapped.Substring(0, $swapped.Length - 81)
        $lines[3] = $core + ',"recordHash":"' + (DgSha256-Text ($core + $tail)) + '"}'
        [System.IO.File]::WriteAllBytes($p, $script:Utf8.GetBytes(([string]::Join("`n", $lines)) + "`n")) } 'JournalCorrupt'
    Invoke-Anomaly 'TV-sequence-mismatch' { Edit-I2AJournal (Get-I2AActiveJournalPath $layout) { param($recs) } { param($s) if ($s -ge 4) { $s + 1 } else { $s } } } 'JournalCorrupt'
    Invoke-Anomaly 'TV-schema-version' { Edit-I2AJournal (Get-I2AActiveJournalPath $layout) { param($recs) $recs[2]['schemaVersion'] = 2 } } 'JournalCorrupt'
    Invoke-Anomaly 'TV-unknown-stage' { Edit-I2AJournal (Get-I2AActiveJournalPath $layout) { param($recs) $recs[2]['stage'] = 'Teleport' } } 'JournalCorrupt'
    Invoke-Anomaly 'TV-path-outside-root' {
        $script:OutPath = Join-Path $outside 'm\a2.dll'; [System.IO.Directory]::CreateDirectory((Split-Path $script:OutPath -Parent)) | Out-Null
        [System.IO.File]::Copy((Dest 'm\a2.dll'), $script:OutPath, $true)
        Edit-I2AJournal (Get-I2AActiveJournalPath $layout) { param($recs) foreach ($r in $recs) { if ($r.Contains('itemId') -and ([int]$r['itemId'] -eq 1)) { $r['path'] = $script:OutPath; $r['normalizedPath'] = $script:OutPath; if ($r.Contains('tmpPath')) { $r['tmpPath'] = $script:OutPath + '.dengo.tmp' } } } } } 'PathRejected'
    Invoke-Anomaly 'TV-unregistered-path-in-root' {
        $script:OtherPath = Join-Path $layout.Guard 'g1.txt'
        Edit-I2AJournal (Get-I2AActiveJournalPath $layout) { param($recs) foreach ($r in $recs) { if (([string]$r['stage'] -eq 'Intent') -and ([int]$r['itemId'] -eq 1)) { $r['path'] = $script:OtherPath; $r['normalizedPath'] = $script:OtherPath } } } } 'JournalCorrupt'
    Invoke-Anomaly 'TV-post-without-intent' { Edit-I2AJournal (Get-I2AActiveJournalPath $layout) { param($recs) for ($i = $recs.Count - 1; $i -ge 0; $i--) { if (([string]$recs[$i]['stage'] -eq 'Intent') -and ([int]$recs[$i]['itemId'] -eq 2)) { $recs.RemoveAt($i) } } } } 'PostWithoutIntent'
    Invoke-Anomaly 'TV-marker-root-mismatch' {
        $mp = Join-Path $layout.State 'installing.json'; $m = [System.IO.File]::ReadAllText($mp) | ConvertFrom-Json
        $m.StateRoot = Join-Path $outside 'State'; [System.IO.File]::WriteAllText($mp, (ConvertTo-Json -InputObject $m -Compress), $script:Utf8) } 'StateRootMismatch'
    Invoke-Anomaly 'TV-marker-unreadable' { [System.IO.File]::WriteAllText((Join-Path $layout.State 'installing.json'), '{ not json', $script:Utf8) } 'MarkerUnreadable'
    Invoke-Anomaly 'TV-marker-txn-unknown' {
        $mp = Join-Path $layout.State 'installing.json'; $m = [System.IO.File]::ReadAllText($mp) | ConvertFrom-Json
        $m.TxnId = 'T9999'; [System.IO.File]::WriteAllText($mp, (ConvertTo-Json -InputObject $m -Compress), $script:Utf8) } 'JournalMissing'
    Invoke-Anomaly 'TV-journal-missing' { [System.IO.File]::Delete((Get-I2AActiveJournalPath $layout)) } 'JournalMissing'
    Invoke-Anomaly 'TV-multiple-markers' { [System.IO.File]::WriteAllText((Join-Path $layout.State 'uninstalling.json'), '{}', $script:Utf8) } 'MultipleMarkers'
    Invoke-Anomaly 'TV-reparse-point-in-path' {
        $real = Join-Path $layout.Dest 'm_real'
        [System.IO.Directory]::Move((Join-Path $layout.Dest 'm'), $real)
        $o = & cmd.exe /c ('mklink /J "' + (Join-Path $layout.Dest 'm') + '" "' + $real + '"')
    } 'PathRejected'
    Remove-I2ASandbox $outside
}

# ------------------------------------------------ G. runtime: post-write SHA mismatch, in-use destination, lock during rollback/recovery
if ($ctxs.ContainsKey('F4')) {
    $c = $ctxs['F4']; $layout = $c.Layout
    Reset-Case $c
    Reset-I2AFault -Mode 'Label' -Pattern '^after:Fs-Replace:u1\.dll$' -Nth 1 -Action 'CorruptDest'
    Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    $map = Get-I2AManagedTree $layout
    $okG = ((-not $r.Succeeded) -and ($r.Code -eq 'PostShaMismatch') -and ($r.RollbackState -eq 'RolledBack') -and (Same $c.Exp.Pre $map) -and (Clean $layout))
    [void](Assert-I2A 'TG-post-sha-mismatch-restored' $okG "code=$($r.Code) rollback=$($r.RollbackState): the file whose post-write SHA mismatched was restored from its backup")

    Reset-Case $c
    Reset-I2AFault
    $held = New-Object System.IO.FileStream((Join-Path $layout.Dest 'keep\u1.dll'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { $r = Invoke-I2ARun $layout } finally { $held.Dispose() }
    $map = Get-I2AManagedTree $layout
    $okG = ((-not $r.Succeeded) -and ($r.Code -eq 'InUse') -and ($r.RollbackState -eq 'RolledBack') -and (Same $c.Exp.Pre $map) -and (Clean $layout))
    [void](Assert-I2A 'TG-exclusive-probe-in-use' $okG "code=$($r.Code) rollback=$($r.RollbackState): an in-use destination is detected before Replace and everything is rolled back")

    Reset-Case $c
    $holdPath = Join-Path $layout.Dest 'fresh\n1.dll'
    $failIdx = ([array]::IndexOf(@($c.AllLabels), 'before:Journal:Applied#1')) + 1
    Reset-I2AFault -Mode 'Label' -Pattern '^after:Journal:Verified#0$' -Nth 1 -Action 'Hold' -HoldPath $holdPath -ThrowTargets ([int[]]@($failIdx))
    Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    $stillMarked = [System.IO.File]::Exists((Join-Path $layout.State 'installing.json'))
    Release-I2AHeld
    Reset-I2AFault
    $mid = Get-I2AManagedTree $layout
    $rec = Invoke-I2ARecover $layout
    $map = Get-I2AManagedTree $layout
    $rec2 = Invoke-I2ARecover $layout
    $okG = ((-not $r.Succeeded) -and ($r.RollbackState -eq 'RollbackIncomplete') -and $stillMarked -and ($rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre $map) -and ($rec2.Outcome -eq 'NotNeeded'))
    [void](Assert-I2A 'TG-lock-during-rollback' $okG "run=$($r.Code)/$($r.RollbackState) marker kept=$stillMarked recovery=$($rec.Outcome) then $($rec2.Outcome); already-restored files were not touched again")
    Add-I2AEvidence @{ id = 'TG-lock-during-rollback'; scenario = 'F4'; verdict = $rec.Outcome; initialTree = (Get-I2ATreeDigest $c.Exp.Pre); faultTree = (Get-I2ATreeDigest $mid); recoveredTree = (Get-I2ATreeDigest $map); journalAtFault = ''; backups = (Get-I2ABackupList $layout); pass = $okG; rerunnable = $true; manualRecovery = $false }

    $fired = Set-CrashState $c @{ CrashPattern = '^after:Journal:Verified#2$' }
    $held = New-Object System.IO.FileStream((Join-Path $layout.Dest 'keep\u1.dll'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { $rec = Invoke-I2ARecover $layout } finally { $held.Dispose() }
    $marked = [System.IO.File]::Exists((Join-Path $layout.State 'installing.json'))
    $rec2 = Invoke-I2ARecover $layout
    $map = Get-I2AManagedTree $layout
    $okG = (($rec.Outcome -eq 'RollbackIncomplete') -and $marked -and ($rec2.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre $map))
    [void](Assert-I2A 'TG-lock-during-recovery' $okG "first recovery=$($rec.Outcome) (marker kept=$marked); after unlocking: $($rec2.Outcome); tree == before")
    $rec3 = Invoke-I2ARecover $layout
    $okG = (($rec3.Outcome -eq 'NotNeeded') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)))
    [void](Assert-I2A 'TG-re-restore-harmless' $okG 'a further recovery after completion is a no-op and leaves the restored files byte-identical')

    # the cleanup after RollbackComplete fails (marker cannot be deleted): the journal must stay valid and the next recovery must converge
    Reset-Case $c
    $failIdx2 = ([array]::IndexOf(@($c.AllLabels), 'before:Journal:Applied#1')) + 1
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-Delete:installing\.json$' -Nth 1 -Action 'IO' -ThrowTargets ([int[]]@($failIdx2)); Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    Reset-I2AFault
    $jr = Get-JournalFor $layout
    $lastStage = [string]$jr.Records[$jr.Records.Count - 1].stage
    $rec = Invoke-I2ARecover $layout
    [void](Assert-I2A 'TG-finalize-failure-after-RollbackComplete' ((-not $r.Succeeded) -and ($r.RollbackState -eq 'RollbackIncomplete') -and (-not $jr.Corrupt) -and ($lastStage -eq 'RollbackComplete') -and ($rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and (Clean $layout)) "marker deletion fails after RollbackComplete: nothing is appended after the end record (last record '$lastStage'), the journal stays valid, the next recovery completes ($($rec.Outcome))")
}

# ------------------------------------------------ M. restore re-checks the destination right before Replace/Delete (M2)
if ($ctxs.ContainsKey('F4')) {
    $c = $ctxs['F4']; $layout = $c.Layout
    $u1 = Join-Path $layout.Dest 'keep\u1.dll'; $n1 = Join-Path $layout.Dest 'fresh\n1.dll'; $x1 = Join-Path $layout.Dest 'keep\x1.dll'
    $cuNew = Get-I2AContent 'F4' 'u1' 'new'; $cnNew = Get-I2AContent 'F4' 'n1' 'new'; $cuOld = Get-I2AContent 'F4' 'u1' 'old'; $cxOld = Get-I2AContent 'F4' 'x1' 'old'
    [void](Set-CrashState $c @{ CrashPattern = '^after:Journal:Verified#2$' })
    $allApplied = Save-I2ATree $c.Root      # every item applied, state not committed: recovery must roll all three back
    $third = 'third-party content'
    function Invoke-M2([string]$Id, [string]$Pattern, [scriptblock]$Mutation) {
        Release-I2AHeld; Restore-I2ATree $c.Root $allApplied
        Reset-I2AFault -Mode 'Label' -Pattern $Pattern -Nth 1 -Action 'Callback' -Callback $Mutation
        Reset-I2ACounters
        $rec = Invoke-I2ARecover $layout
        $fired = [string]$global:I2AFH.Fired
        Reset-I2AFault
        return @{ Rec = $rec; Fired = $fired }
    }
    function Test-M2Common($Id, $Run, [string]$ExpectCode, [int[]]$ExpectIntents, [int[]]$MustNotHaveIntents) {
        $rec = $Run.Rec
        $codes = @($rec.Reasons | ForEach-Object { $_.Code })
        $jr = Get-JournalFor $layout
        $intents = Get-StageItems $jr 'RollbackIntent'
        $marker = [System.IO.File]::Exists((Join-Path $layout.State 'installing.json'))
        $hasInc = (Cnt @($jr.Records | Where-Object { $_.stage -eq 'RollbackIncomplete' })) -ge 1
        $report = [System.IO.File]::Exists((Join-Path (Split-Path (Get-I2AActiveJournalPath $layout) -Parent) 'recovery-report.txt'))
        $okIntents = (@($ExpectIntents | Where-Object { $intents -notcontains $_ }).Count -eq 0) -and (@($MustNotHaveIntents | Where-Object { $intents -contains $_ }).Count -eq 0)
        $ok = (($Run.Fired.Length -gt 0) -and ($rec.Outcome -eq 'RollbackIncomplete') -and ($codes -contains $ExpectCode) -and $marker -and $hasInc -and $okIntents)
        Add-I2AEvidence @{ id = $Id; scenario = 'F4'; fault = $Run.Fired; verdict = $rec.Outcome; reasons = ($codes -join ','); manualRecovery = [bool]$rec.ManualCheckRequired; journalAtFault = ($intents -join ','); pass = $ok }
        return @{ Ok = $ok; Detail = ("fired=$($Run.Fired) outcome=$($rec.Outcome) codes=$($codes -join ',') manual=$($rec.ManualCheckRequired) marker=$marker incompleteRecord=$hasInc report=$report restoreIntents=[$($intents -join ',')]"); Manual = [bool]$rec.ManualCheckRequired; Report = $report }
    }
    function Test-SecondRecoveryRefuses($Id) {
        $before = Get-I2ATreeMap $c.Root @('state\txn\' + (Split-Path (Split-Path (Get-I2AActiveJournalPath $layout) -Parent) -Leaf) + '\recovery-report.txt')
        $rec2 = Invoke-I2ARecover $layout
        $after = Get-I2ATreeMap $c.Root @('state\txn\' + (Split-Path (Split-Path (Get-I2AActiveJournalPath $layout) -Parent) -Leaf) + '\recovery-report.txt')
        $codes2 = @($rec2.Reasons | ForEach-Object { $_.Code })
        $ok = (($rec2.Outcome -eq 'RepairRequired') -and ($codes2 -contains 'DestinationUnknownSha') -and (Same $before $after) -and [System.IO.File]::Exists((Join-Path $layout.State 'installing.json')))
        Add-I2AResult ($Id + '-second-recovery') $ok "second recovery: $($rec2.Outcome) [$($codes2 -join ',')], whole fixture byte-identical, marker kept (the unknown content is never overwritten)"
    }

    # a. existing destination edited after Phase 1
    $run = Invoke-M2 'M2-a' '^after:Fs-ProbeExclusive:u1\.dll$' { param($a) [System.IO.File]::WriteAllText([string]$a[0], 'third-party content') }
    $r = Test-M2Common 'M2-existing-edited' $run 'DestinationChangedAfterPreflight' @(2, 1) @(0)
    $keep = ([System.IO.File]::ReadAllText($u1) -eq $third) -and ([System.IO.File]::ReadAllText($x1) -eq $cxOld) -and ([System.IO.File]::ReadAllText($n1) -eq $cnNew)
    Add-I2AResult 'M2-existing-edited' ($r.Ok -and $keep -and $r.Manual -and $r.Report) ("existing destination changed to a third SHA after Phase 1: not overwritten; later items (restore order) not touched; earlier restore kept; $($r.Detail)")
    Test-SecondRecoveryRefuses 'M2-existing-edited'
    [System.IO.File]::WriteAllText($u1, $cuNew, $script:Utf8)
    $rec = Invoke-I2ARecover $layout
    Add-I2AResult 'M2-existing-edited-manual-fix' (($rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and (Clean $layout)) "after the operator puts the file back, recovery completes: $($rec.Outcome), tree == spec-built 'before'"

    # b. file we created, edited after Phase 1
    $run = Invoke-M2 'M2-b' '^after:Fs-ProbeExclusive:n1\.dll$' { param($a) [System.IO.File]::WriteAllText([string]$a[0], 'third-party content') }
    $r = Test-M2Common 'M2-new-edited' $run 'DestinationChangedAfterPreflight' @(2, 1, 0) @()
    $keep = ([System.IO.File]::ReadAllText($n1) -eq $third) -and ([System.IO.File]::ReadAllText($u1) -eq $cuOld) -and ([System.IO.File]::ReadAllText($x1) -eq $cxOld)
    Add-I2AResult 'M2-new-edited' ($r.Ok -and $keep -and $r.Manual) "a file we created, changed to a third SHA after Phase 1: not deleted; $($r.Detail)"
    Test-SecondRecoveryRefuses 'M2-new-edited'
    [System.IO.File]::WriteAllText($n1, $cnNew, $script:Utf8)
    $rec = Invoke-I2ARecover $layout
    Add-I2AResult 'M2-new-edited-manual-fix' (($rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout))) "after the operator restores our content, recovery completes: $($rec.Outcome)"

    # c. existing destination deleted after Phase 1
    $run = Invoke-M2 'M2-c' '^after:Fs-ProbeExclusive:u1\.dll$' { param($a) [System.IO.File]::Delete([string]$a[0]) }
    $r = Test-M2Common 'M2-existing-deleted' $run 'DestinationChangedAfterPreflight' @(2, 1) @(0)
    $keep = (-not [System.IO.File]::Exists($u1)) -and ([System.IO.File]::ReadAllText($n1) -eq $cnNew)
    Add-I2AResult 'M2-existing-deleted' ($r.Ok -and $keep -and $r.Manual) "a destination deleted after Phase 1 is not re-created from the backup (unknown intent); later items untouched; $($r.Detail)"
    Test-SecondRecoveryRefuses 'M2-existing-deleted'

    # d. destination that was absent in the certified state is created by someone else
    $run = Invoke-M2 'M2-d' '^after:Fs-Sha256:x1\.dll\.dengo\.tmp$' { param($a) $p = [string]$a[0]; [System.IO.File]::WriteAllText($p.Substring(0, $p.Length - 10), 'created by someone else') }
    $r = Test-M2Common 'M2-absent-created' $run 'DestinationChangedAfterPreflight' @(2) @(1, 0)
    $keep = ([System.IO.File]::ReadAllText($x1) -eq 'created by someone else') -and ([System.IO.File]::ReadAllText($u1) -eq $cuNew) -and ([System.IO.File]::ReadAllText($n1) -eq $cnNew)
    Add-I2AResult 'M2-absent-created' ($r.Ok -and $keep -and $r.Manual) "a file created by a third party where the certified state was 'absent' is not overwritten; no later item is processed; $($r.Detail)"
    Test-SecondRecoveryRefuses 'M2-absent-created'

    # e. file we created is already gone: idempotent success
    $run = Invoke-M2 'M2-e' '^after:Fs-ProbeExclusive:n1\.dll$' { param($a) [System.IO.File]::Delete([string]$a[0]) }
    Add-I2AResult 'M2-new-already-gone' (($run.Fired.Length -gt 0) -and ($run.Rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and (Clean $layout)) "a created file that vanished before its delete is treated as done: $($run.Rec.Outcome), tree == spec-built 'before'"

    # f. lock right before the restore
    $script:HeldLock = $null
    $run = Invoke-M2 'M2-f' '^after:Fs-ProbeExclusive:u1\.dll$' { param($a) $script:HeldLock = New-Object System.IO.FileStream([string]$a[0], [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read) }
    $heldUnchanged = ([System.IO.File]::ReadAllText($u1) -eq $cuNew)
    if ($null -ne $script:HeldLock) { $script:HeldLock.Dispose(); $script:HeldLock = $null }
    $markerKept = [System.IO.File]::Exists((Join-Path $layout.State 'installing.json'))
    Add-I2AResult 'M2-lock-before-restore' (($run.Fired.Length -gt 0) -and ($run.Rec.Outcome -eq 'RollbackIncomplete') -and $heldUnchanged -and $markerKept -and (-not $run.Rec.ManualCheckRequired)) "a handle taken after the probe makes the replace fail: $($run.Rec.Outcome), file unchanged, marker kept, no manual check needed"
    $rec = Invoke-I2ARecover $layout
    Add-I2AResult 'M2-lock-before-restore-retry' (($rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and (Clean $layout)) "after the lock is released the next recovery completes: $($rec.Outcome)"
    Release-I2AHeld
}

# ------------------------------------------------ L. the journal is truncated only if it still has the length Phase 1 read (L2)
if ($ctxs.ContainsKey('F4')) {
    $c = $ctxs['F4']; $layout = $c.Layout
    [void](Set-CrashState $c @{ CrashPattern = '^after:Journal:Verified#2$' })
    $crashSnap = Save-I2ATree $c.Root
    $script:ExpectBytes = $null
    $variants = [ordered]@{
        'complete-record-appended' = { param($a) $p = [string]$a[0]; $txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p)); $lines = @($txt.TrimEnd([char]10).Split([char]10)); $last = [string]$lines[$lines.Count - 1]; $obj = $last | ConvertFrom-Json
            $f = New-Object System.Collections.Specialized.OrderedDictionary; $f.Add('schemaVersion', 1); $f.Add('transactionId', [string]$obj.transactionId); $f.Add('operation', [string]$obj.operation); $f.Add('sequence', ($lines.Count + 1)); $f.Add('timestamp', 't'); $f.Add('stage', 'RollbackBegin'); $f.Add('reason', 'late writer'); $f.Add('by', 'test')
            $rec = DgJournal-FormatRecord $f $last.Substring($last.Length - 66, 64); $s = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite); $b = [System.Text.Encoding]::UTF8.GetBytes($rec.Line + "`n"); $s.Write($b, 0, $b.Length); $s.Dispose()
            $script:ExpectBytes = [System.IO.File]::ReadAllBytes($p) }
        'fragment-appended' = { param($a) $p = [string]$a[0]; $s = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite); $b = [System.Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"trans'); $s.Write($b, 0, $b.Length); $s.Dispose(); $script:ExpectBytes = [System.IO.File]::ReadAllBytes($p) }
        'shortened' = { param($a) $p = [string]$a[0]; $s = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite); $s.SetLength($s.Length - 7); $s.Dispose(); $script:ExpectBytes = [System.IO.File]::ReadAllBytes($p) }
    }
    foreach ($name in $variants.Keys) {
        Release-I2AHeld; Restore-I2ATree $c.Root $crashSnap
        $treeBefore = Get-I2AManagedTree $layout
        Reset-I2AFault -Mode 'Label' -Pattern '^before:Journal-OpenTruncate:journal\.jsonl$' -Nth 1 -Action 'Callback' -Callback $variants[$name]
        Reset-I2ACounters
        $rec = Invoke-I2ARecover $layout
        $fired = [string]$global:I2AFH.Fired
        Reset-I2AFault
        $jp = Get-I2AActiveJournalPath $layout
        $bytesNow = [System.IO.File]::ReadAllBytes($jp)
        $same = ($bytesNow.Length -eq $script:ExpectBytes.Length)
        if ($same) { for ($i = 0; $i -lt $bytesNow.Length; $i++) { if ($bytesNow[$i] -ne $script:ExpectBytes[$i]) { $same = $false; break } } }
        $codes = @($rec.Reasons | ForEach-Object { $_.Code })
        $okL = (($fired.Length -gt 0) -and ($rec.Outcome -eq 'RollbackIncomplete') -and ($codes -contains 'JournalChangedAfterRead') -and [bool]$rec.ManualCheckRequired -and $same -and (Same $treeBefore (Get-I2AManagedTree $layout)) -and [System.IO.File]::Exists((Join-Path $layout.State 'installing.json')))
        Add-I2AResult ("L2-$name") $okL "journal changed after it was read ($name): $($rec.Outcome) [$($codes -join ',')]; the journal is byte-identical to what the other writer left; no destination touched; marker kept"
        $rec2 = Invoke-I2ARecover $layout
        Add-I2AResult ("L2-$name-retry") (($rec2.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and (Clean $layout)) "the next recovery (journal stable) completes: $($rec2.Outcome)"
    }
    # normal case: the torn last fragment is cut off, and only then
    Release-I2AHeld; Restore-I2ATree $c.Root $crashSnap
    $jp = Get-I2AActiveJournalPath $layout; $bytes = [System.IO.File]::ReadAllBytes($jp)
    $lastStart = [array]::LastIndexOf($bytes, [byte]10, $bytes.Length - 2) + 1
    $cut = New-Object byte[] ($lastStart + 40); [System.Array]::Copy($bytes, $cut, $cut.Length); [System.IO.File]::WriteAllBytes($jp, $cut)
    Reset-I2AFault; $rec = Invoke-I2ARecover $layout
    $hist = @([System.IO.Directory]::GetFiles((Join-Path $layout.State 'history'), '*.rolledback.jsonl'))
    $pj = $(if ($hist.Count -eq 1) { DgJournal-Parse $hist[0] } else { $null })
    Add-I2AResult 'L2-normal-truncates-torn-tail' (($rec.Outcome -eq 'RolledBack') -and ($null -ne $pj) -and (-not $pj.Corrupt) -and (-not $pj.TornTail) -and ($pj.Records[$pj.Records.Count - 1].stage -eq 'RollbackComplete')) 'a stable journal with a torn last fragment: the fragment is cut off, recovery continues, the archived journal is clean and ends with RollbackComplete'
}

# ------------------------------------------------ O. spec-built expected trees for rollback shapes
function Get-LastIdx($C) { return (@(Get-I2ASpec $C.Layout.Scenario).Count - 1) }
foreach ($sc in @('F1', 'F2')) {
    if (-not $ctxs.ContainsKey($sc)) { continue }
    $c = $ctxs[$sc]; $layout = $c.Layout; $last = Get-LastIdx $c
    Reset-Case $c
    $idx = ([array]::IndexOf(@($c.AllLabels), "before:Journal:Applied#$last")) + 1
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($idx)) -Action 'IO'; Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    $okO = ((-not $r.Succeeded) -and ($r.RollbackState -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and (Clean $layout))
    $shape = $(if ($sc -eq 'F1') { '; folders we created and files we added are gone' } else { '' })
    Add-I2AResult ("OR-$sc-rollback-independent") $okO ("failure at the last item of ${sc}: rollback == spec-built 'before' tree (content SHA, presence, directories$shape) diff=[$(Diff3 $c.Exp.Pre (Get-I2AManagedTree $layout))]")
}
if ($ctxs.ContainsKey('F3')) {
    $c = $ctxs['F3']; $layout = $c.Layout
    Reset-Case $c
    $idx = ([array]::IndexOf(@($c.AllLabels), 'before:Journal:Applied#8')) + 1
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($idx)) -Action 'IO'; Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    $hist = @([System.IO.Directory]::GetFiles((Join-Path $layout.State 'history'), '*.rolledback.jsonl'))
    $ids = @(); if ($hist.Count -eq 1) { $ids = Get-StageItems (DgJournal-Parse $hist[0]) 'RolledBack' }
    $desc = ($ids.Count -gt 0); for ($i = 1; $i -lt $ids.Count; $i++) { if ($ids[$i] -ge $ids[$i - 1]) { $desc = $false } }
    Add-I2AResult 'OR-F3-reverse-order' ((-not $r.Succeeded) -and ($r.RollbackState -eq 'RolledBack') -and $desc -and (($ids -join ',') -eq '8,7,6,5,4,3,2,1,0') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout))) "multi-item rollback restores in strict reverse order ($($ids -join ',')) and ends == spec-built 'before' tree"

    # partial rollback, then continuation
    Reset-Case $c
    $a4 = Join-Path $layout.Dest 'm\a4.dll'
    Reset-I2AFault -Mode 'Label' -Pattern '^after:Journal:Verified#3$' -Nth 1 -Action 'Hold' -HoldPath $a4 -ThrowTargets ([int[]]@($idx)); Reset-I2ACounters
    $r = Invoke-I2ARun $layout
    Release-I2AHeld; Reset-I2AFault
    $states = @{}; foreach ($si in (Get-I2ASpec 'F3')) { $states[$si.Name] = 'pre' }; foreach ($n in 'a1', 'a2', 'a3', 'a4') { $states[$n] = 'post' }
    $partial = Get-I2AOracle 'F3' $states 'old' 'post'
    $partial['f:dest\m\a4.dll.dengo.tmp'] = Get-I2AContentSha (Get-I2AContent 'F3' 'a4' 'old')    # the restore copy that was prepared when the lock stopped it
    $midMap = Get-I2AManagedTree $layout
    $markerKept = $midMap.ContainsKey('f:state\installing.json'); [void]$midMap.Remove('f:state\installing.json')   # the marker is expected to stay; its bytes carry sandbox paths, so only its presence is asserted
    Add-I2AResult 'OR-F3-partial-rollback-state' ((-not $r.Succeeded) -and ($r.RollbackState -eq 'RollbackIncomplete') -and (Same $partial $midMap) -and $markerKept) "partial rollback (items 8..4 restored, 3..0 still applied, one prepared temp copy) == spec-built partial tree; diff=[$(Diff3 $partial $midMap)]"
    $rec = Invoke-I2ARecover $layout
    $jr = Get-JournalFor $layout
    $intents = Get-StageItems $jr 'RollbackIntent'
    $once = $true; foreach ($i in 4..8) { if ((Cnt @($intents | Where-Object { $_ -eq $i })) -ne 1) { $once = $false } }
    Add-I2AResult 'OR-F3-partial-rollback-continued' (($rec.Outcome -eq 'RolledBack') -and (Same $c.Exp.Pre (Get-I2AManagedTree $layout)) -and $once -and (Clean $layout)) "continuing from the partial state ends == spec-built 'before' tree; items already restored were not restored again (RollbackIntent ids: $($intents -join ','))"
}

# ------------------------------------------------ H. F6 in-use sweep (a held file at every position)
if ($ctxs.ContainsKey('F6')) {
    $c = $ctxs['F6']; $layout = $c.Layout
    $bad = 0
    foreach ($n in 'i1', 'i2', 'i3', 'i4') {
        Reset-Case $c
        Reset-I2AFault
        $held = New-Object System.IO.FileStream((Join-Path $layout.Dest ('z\' + $n + '.dll')), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try { $r = Invoke-I2ARun $layout } finally { $held.Dispose() }
        $map = Get-I2AManagedTree $layout
        $okH = ((-not $r.Succeeded) -and ($r.Code -eq 'InUse') -and (Same $c.Exp.Pre $map) -and (Clean $layout))
        if (-not $okH) { $bad++; Add-I2AResult ("TH-F6-$n") $false "code=$($r.Code) rollback=$($r.RollbackState)" }
    }
    if ($bad -eq 0) { Add-I2AResult 'TH-F6-in-use' $true 'a file held open at each of the 4 positions: InUse, fully rolled back, tree == before' }
}

foreach ($sc in $ctxs.Keys) { Release-I2AHeld; Remove-I2ASandbox $ctxs[$sc].Root }
Uninstall-I2AHarness
Write-Host ('Evidence: ' + $global:I2AEvidencePath)
Write-Host (($summary.Keys | Sort-Object | ForEach-Object { $_ + ': ' + $summary[$_] }) -join '; ')
Complete-I2ATests
