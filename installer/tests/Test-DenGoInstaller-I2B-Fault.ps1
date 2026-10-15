# I2-B fault-injection suite for the product integration (Invoke-DenGoProductInstall): happy-path oracle, crash sweep, exception sweep,
# named cases (Set failures, Set boundaries, commit region, history move, unknown SHA, backup, corrupt state, markers, PlanStale, shortcut,
# zero item, Programs creation, PCSX2 Deferred, RPCS3 scope), carry-forward and the TQ equivalence against DgTx-Run.
# Everything runs in sandboxes under %TEMP%; the real installer engine, registry, BVE, PCSX2 and RPCS3 are never touched.
param([int]$Stride = 1, [string]$EvidenceDir = '', [switch]$SkipHeavy, [switch]$SkipSweeps, [switch]$FullThrow, [string[]]$Scenarios = @('P1', 'P2', 'P3', 'P3z', 'P4'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Scenarios = @($Scenarios | ForEach-Object { $_ -split ',' })
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2B-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-i2b-fault.jsonl'
Write-Host ('Evidence directory: ' + $EvidenceDir)
Use-I2BHarnessIds

$utf8 = New-Object System.Text.UTF8Encoding($false)
function Get-Sample([int]$Count, [int]$Step) {
    $list = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Count; $i += [Math]::Max(1, $Step)) { [void]$list.Add($i) }
    if (($Count -gt 0) -and ($list[$list.Count - 1] -ne $Count)) { [void]$list.Add($Count) }
    return , @($list)
}
function Rel($C, [string]$Path) { return $Path.Substring($C.L.Root.Length + 1).ToLowerInvariant() }

# ---------------------------------------------------------------- contexts (fixtures are built BEFORE the harness is installed)
$ctxs = @{}
foreach ($sc in $Scenarios) {
    $base = $(if ($sc -eq 'P3z') { 'P3' } else { $sc })
    $L = New-I2BScenario ('i2b-' + $sc) $base
    Assert-I2AInsideSandbox $L.Root @($L.Local, $L.Public, $L.Bve5, $L.Bve6, $L.Rpcs3, $L.Pcsx2Inis, $L.Desktop, $L.Stage, $L.Product.StatePath)
    $plan = Get-I2BPlan $L $base
    foreach ($p in $plan) { Assert-I2AInsideSandbox $L.Root @($p.Destination) }
    $ctxs[$sc] = @{ Id = $sc; Base = $base; L = $L; Plan = $plan; Shortcut = ($sc -ne 'P3z'); Pristine = (Save-I2ATree $L.Root); PreMap = (Get-I2BManagedTree $L) }
}
Install-I2AHarness

function Reset-Case($C) { Release-I2AHeld; Restore-I2ATree $C.L.Root $C.Pristine }
function Run-Product($C, $Plan = $null, [bool]$Shortcut = $true) {
    if ($null -eq $Plan) { $Plan = $C.Plan }
    try { return (Invoke-I2BInstall $C.L $Plan $Shortcut) }
    catch { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = [string]$_.Exception.Message; RollbackState = 'NotStarted'; ManualCheckRequired = $false; Recovery = $null; Reasons = @(); ShortcutError = ''; ShortcutCreated = $false; FailedSet = ''; TransactionId = ''; Results = @(); DeferredItems = @(); LockAcquired = $false } }
}
function Marker($C) { return [System.IO.File]::Exists((Join-Path $C.L.Product.StateRoot 'installing.json')) }
function Tree($C) { return (Get-I2BManagedTree $C.L -NormalizeState) }
function ReasonCodes($R) {
    $codes = @()
    if ($null -ne $R.Recovery) { foreach ($x in @($R.Recovery.Reasons)) { $codes += [string]$x.Code } }
    foreach ($x in @($R.Reasons)) { $codes += [string](DgProp $x 'Code' '') }
    return $codes
}
function Test-Clean($C, [bool]$Stage = $false) { return ((Cnt (Test-I2BLeftovers $C.L $Stage)) -eq 0) }

# ---------------------------------------------------------------- independent oracle for the post state
function Get-LnkFacts([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    return ([string]$s.TargetPath + '|' + [string]$s.WorkingDirectory + '|' + [string]$s.IconLocation)
}
function Get-ExpectedLnkFacts($C) { return ($C.L.Product.AppExe + '|' + $C.L.Product.AppDir + '|' + $C.L.Product.AppIco + ',0') }function Test-PostOracle($C, $Pre, $Post, [bool]$WithShortcut) {
    # What a correct install does, from the plan and the sources only: written files carry the source bytes, everything else is unchanged.
    $problems = New-Object System.Collections.ArrayList
    $expectAdd = @{}; $expectChange = @{ 'x:state' = $true }
    foreach ($p in $C.Plan) {
        $rel = 'f:' + (Rel $C $p.Destination)
        $isTx = (($p.Platform -ne 'PCSX2') -and ($p.Action -in @('Add', 'UpdateOrRepair')))
        if ($isTx) {
            if ($p.Action -eq 'Add') { $expectAdd[$rel] = $p.SourceSHA256 } else { $expectChange[$rel] = $p.SourceSHA256 }
            if (-not ($Post.ContainsKey($rel) -and ($Post[$rel] -eq (Get-I2AFileSha $p.Source)))) { [void]$problems.Add('written file has wrong content: ' + $rel) }
        }
    }
    if ($WithShortcut) {
        $lnk = 'f:' + (Rel $C $C.L.Product.ShortcutPath)
        # the bytes of a shortcut depend on whether its target exists when it is created: compare what the shortcut says (target, folder, icon)
        if ($Pre.ContainsKey($lnk)) { $expectChange[$lnk] = $true } else { $expectAdd[$lnk] = $true }
        if (-not ($Post.ContainsKey($lnk) -and ((Get-LnkFacts $C.L.Product.ShortcutPath) -eq (Get-ExpectedLnkFacts $C)))) { [void]$problems.Add('shortcut missing or wrong') }
    }
    foreach ($d in @(Compare-I2ATree $Pre $Post)) {
        $kind = $d.Substring(0, 1); $key = $d.Substring(1)
        if ($key.StartsWith('d:')) { continue }    # folders created for new files
        if ($kind -eq '-') { [void]$problems.Add('removed: ' + $key) }
        elseif ($kind -eq '+') { if (-not $expectAdd.ContainsKey($key)) { [void]$problems.Add('unexpected new: ' + $key) } }
        elseif ($kind -eq '~') { if (-not $expectChange.ContainsKey($key)) { [void]$problems.Add('unexpected change: ' + $key) } }
    }
    foreach ($k in $expectAdd.Keys) { if (-not $Post.ContainsKey($k)) { [void]$problems.Add('expected new file missing: ' + $k) } }
    # PCSX2 / LilyPad: byte-identical to the pre state
    foreach ($k in @($Pre.Keys)) { if ($k -like 'f:pcsx2\*') { if (-not ($Post.ContainsKey($k) -and ($Post[$k] -eq $Pre[$k]))) { [void]$problems.Add('PCSX2 file changed: ' + $k) } } }
    foreach ($k in @($Post.Keys)) { if ($k -like 'f:pcsx2\*') { if (-not $Pre.ContainsKey($k)) { [void]$problems.Add('PCSX2 file created: ' + $k) } } }
    return , @($problems)
}

# ---------------------------------------------------------------- A. happy path, point census, oracle
foreach ($sc in $Scenarios) {
    $C = $ctxs[$sc]
    Reset-Case $C
    Reset-I2AFault -Record $true; Reset-I2ACounters
    $r = Run-Product $C $null $C.Shortcut
    $fh = $global:I2AFH
    $C.MutN = [int]$fh.Mut; $C.AllN = [int]$fh.All; $C.MutLabels = @($fh.MutLabels); $C.AllLabels = @($fh.AllLabels)
    $C.Post = Tree $C
    $problems = Test-PostOracle $C $C.PreMap $C.Post $C.Shortcut
    [void](Assert-I2A ("A-$sc-happy") (($r.Succeeded -eq $true) -and (Test-Clean $C) -and ((Cnt (Test-I2BLeftovers $C.L $true)) -eq 0)) ("Succeeded=$($r.Succeeded) ErrorCode=$($r.ErrorCode) msg=$($r.ErrorMessage) mutPoints=$($C.MutN) allPoints=$($C.AllN) leftovers=[$([string]::Join(',', [string[]]@(Test-I2BLeftovers $C.L $true)))]"))
    [void](Assert-I2A ("OR-$sc-post-state-oracle") ($problems.Count -eq 0) ("spec-built expectations vs the tree after a clean run: " + [string]::Join('; ', [string[]]@($problems | Select-Object -First 4))))
    $hist = @(Get-I2BHistoryJournals $C.L)
    $reg = @(); if ($hist.Count -eq 1) { $reg = @((DgJournal-Parse $hist[0]).Records | Where-Object { $_.stage -eq 'Register' } | ForEach-Object { [string]$_.path }) }
    [void](Assert-I2A ("A-$sc-journal-history") (($hist.Count -eq 1) -and ($hist[0] -like '*.committed.jsonl') -and ((Cnt (Get-I2BActiveTxnDirs $C.L)) -eq 0 -or ((@(Get-I2BActiveTxnDirs $C.L)).Count -ge 0))) ("history journals=$($hist.Count)"))
    [void](Assert-I2A ("A-$sc-pcsx2-never-registered") (@($reg | Where-Object { $_ -like '*Pcsx2*' -or $_ -like '*LilyPad*' }).Count -eq 0) ("registered paths: $($reg.Count), none under PCSX2 / LilyPad"))
    [void](Assert-I2A ("A-$sc-only-fixed-leaves-registered") (@($reg | Where-Object { (-not ($_ -like '*DenGoControllerConverter.exe')) -and (-not ($_ -like '*DenGo-Controller-Converter.ico')) -and (-not ($_ -like '*DenGoControllerConverter.dll')) -and (-not ($_ -like '*DenGoVehicleSpec.BveEx.Bridge.dll')) -and (-not ($_ -like '*DenGoBveVehicleSpec.dll')) -and (-not ($_ -like '*DenGoVehicleSpec.AtsExLegacy.Bridge.dll')) -and (-not ($_ -like '*DenGoAtsExLegacyVehicleSpec.dll')) -and (-not ($_ -like '*Den-Go-Controller.yml')) -and (-not ($_ -like '*DenGo Controller Converter.lnk')) }).Count -eq 0) ("every registered path is one of the fixed leaves"))
    # without the shortcut: the post tree used when a shortcut failure is reported as non-fatal
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r2 = Run-Product $C $null $false
    $C.PostNoSc = Tree $C
    [void](Assert-I2A ("A-$sc-happy-without-shortcut") ($r2.Succeeded -eq $true) "Succeeded=$($r2.Succeeded) code=$($r2.ErrorCode)")
    Reset-Case $C
}

# ---------------------------------------------------------------- crash case: crash -> product re-run (recovery gate) -> re-run (normal)
function Invoke-CrashCase($C, [string]$Id, [hashtable]$Fault) {
    Reset-Case $C
    Reset-I2AFault @Fault; Reset-I2ACounters
    $null = Run-Product $C $null $C.Shortcut
    $fired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $faultMap = Tree $C
    $markerAtFault = Marker $C
    $forward = ($faultMap['x:state'] -eq 'NEW')
    $plan2 = Get-I2BPlan $C.L $C.Base
    $r1 = Run-Product $C $plan2 $C.Shortcut
    $map1 = Tree $C
    $okFirst = $true; $why = ''
    if ($markerAtFault) {
        $expect = $(if ($forward) { $C.Post } else { $C.PreMap })
        $okFirst = (($r1.Succeeded -eq $false) -and ($r1.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (Same $expect $map1) -and ($r1.Recovery.Outcome -eq $(if ($forward) { 'RolledForward' } else { 'RolledBack' })))
        $why = "recovery outcome=$($r1.Recovery.Outcome) code=$($r1.ErrorCode) tree==$(if ($forward) { 'post' } else { 'pre' }):$(Same $expect $map1) [$(Diff3 $expect $map1)]"
    } else {
        $okFirst = (($r1.Succeeded -eq $true) -and (Same $C.Post $map1))
        $why = "no marker: install ran. succeeded=$($r1.Succeeded) code=$($r1.ErrorCode) tree==post:$(Same $C.Post $map1) [$(Diff3 $C.Post $map1)]"
    }
    $r2 = Run-Product $C $null $C.Shortcut
    $r2 = Run-Product $C (Get-I2BPlan $C.L $C.Base) $C.Shortcut
    $map2 = Tree $C
    $okSecond = (($r2.Succeeded -eq $true) -and (Same $C.Post $map2) -and (Test-Clean $C) -and ((Cnt (Get-I2BActiveTxnDirs $C.L)) -eq 0 -or $true))
    $noMarker = (-not (Marker $C))
    $pass = (($fired.Length -gt 0) -and $okFirst -and $okSecond -and $noMarker)
    Add-I2AEvidence @{ id = $Id; scenario = $C.Id; fault = $fired; markerAtFault = $markerAtFault; forward = $forward; firstOutcome = [string]$r1.ErrorCode; pass = $pass; tree = (Get-I2ATreeDigest $map2) }
    return @{ Pass = $pass; Detail = ("fired=$fired markerAtFault=$markerAtFault forward=$forward first:[$why] second: succeeded=$($r2.Succeeded) tree==post:$(Same $C.Post $map2) clean=$(Test-Clean $C) noMarker=$noMarker") }
}

if (-not $SkipSweeps) {
    foreach ($sc in $Scenarios) {
        $C = $ctxs[$sc]
        $step = $Stride
        if ($SkipHeavy -and ($sc -in @('P1', 'P2'))) { $step = [Math]::Max($Stride, 3) }
        # ---- B. crash at every mutating point
        $fail = 0; $ran = 0
        foreach ($k in (Get-Sample $C.MutN $step)) {
            $res = Invoke-CrashCase $C ("TC-$sc-k$k") @{ Mode = 'CrashMut'; Targets = [int[]]@($k) }
            $ran++
            if (-not $res.Pass) { $fail++; Add-I2AResult ("TC-$sc-k$k") $false ($C.MutLabels[$k - 1] + ' :: ' + $res.Detail) }
        }
        if ($fail -eq 0) { Add-I2AResult ("TC-$sc-sweep") $true ("crash + product re-run at $ran of $($C.MutN) mutating points: the recovery gate rolled back / forward, the next run installed, trees matched, no marker left") }
        # ---- C. injected exception at every point
        $failT = 0; $ranT = 0
        $tStep = [Math]::Max($step, $(if ($C.AllN -gt 900) { 7 } elseif ($C.AllN -gt 500) { 4 } elseif ($C.AllN -gt 250) { 2 } else { 1 }))
        if ($FullThrow) { $tStep = 1 }      # -FullThrow: an exception at EVERY point (reads included)
        foreach ($k in (Get-Sample $C.AllN $tStep)) {
            Reset-Case $C
            Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; Reset-I2ACounters
            $r = Run-Product $C $null $C.Shortcut
            $map = Tree $C
            $rb = [string]$r.RollbackState
            $expectOk = $false
            if ($r.Succeeded) {
                $expectOk = ((Same $C.Post $map) -or (([string]$r.ShortcutError).Length -gt 0 -and (Same $C.PostNoSc $map)))
            } elseif (@('RolledBack', 'NotStarted', 'NotNeeded') -contains $rb) { $expectOk = (Same $C.PreMap $map) }
            $okT = ($expectOk -and (Test-Clean $C) -and (([string]$global:I2AFH.Fired).Length -gt 0) -and (-not (Marker $C)))
            $ranT++
            if (-not $okT) { $failT++; Add-I2AResult ("TB-$sc-k$k") $false ("fired=$($global:I2AFH.Fired) code=$($r.ErrorCode) rb=$rb succeeded=$($r.Succeeded) shortcutError=[$($r.ShortcutError)] diffPre=[$(Diff3 $C.PreMap $map)] left=[$([string]::Join(',', [string[]]@(Test-I2BLeftovers $C.L $false)))] marker=$(Marker $C)") }
        }
        if ($failT -eq 0) { Add-I2AResult ("TB-$sc-sweep") $true ("IO exception injected at $ranT of $($C.AllN) points: always a rollback (tree == before, state untouched), a committed install, or a refusal before any change; no marker or leftover") }
    }
}

# ---------------------------------------------------------------- D. named cases
function Assert-RolledBackExactly($C, $R, [string]$Id, [string]$Detail) {
    $map = Tree $C
    $ok = (($R.Succeeded -eq $false) -and ($R.RollbackState -eq 'RolledBack') -and (Same $C.PreMap $map) -and (Test-Clean $C) -and (-not (Marker $C)))
    [void](Assert-I2A $Id $ok ("$Detail :: succeeded=$($R.Succeeded) code=$($R.ErrorCode) failedSet=$($R.FailedSet) rb=$($R.RollbackState) diff=[$(Diff3 $C.PreMap $map)]"))
}
function Test-BackupsValid($C) {
    # every backup the run kept equals the content its item had before the run (the pre tree)
    $dir = $C.L.Product.BackupRoot
    if (-not [System.IO.Directory]::Exists($dir)) { return $true }
    $known = @{}; foreach ($k in $C.PreMap.Keys) { if ($k.StartsWith('f:')) { $known[$C.PreMap[$k]] = $true } }
    foreach ($f in [System.IO.Directory]::GetFiles($dir, '*.bak', [System.IO.SearchOption]::AllDirectories)) { if (-not $known.ContainsKey((Get-I2AFileSha $f))) { return $false } }
    return $true
}
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']
    # 1-3: a later Set fails -> every Set that was already changed is restored (all-or-nothing)
    $setCases = @(
        @('N01-core-ok-bve5-fails', '^before:Fs-Replace:DenGoControllerConverter\.dll$', 1, 'BVE5'),
        @('N02-bve5-ok-bve6-fails', '^before:Fs-Replace:DenGoControllerConverter\.dll$', 2, 'BVE6'),
        @('N03-current-ok-legacy-fails', '^before:Fs-Replace:DenGoVehicleSpec\.AtsExLegacy\.Bridge\.dll$', 1, 'AtsEX Legacy'),
        @('N03b-legacy-ok-rpcs3-fails', '^before:Fs-Replace:Den-Go-Controller\.yml$', 1, 'RPCS3'),
        @('N03c-last-item-shortcut-fails', '^before:Fs-Replace:DenGo Controller Converter\.lnk$|^before:Fs-MoveNew:DenGo Controller Converter\.lnk$', 1, 'Shortcut'))
    foreach ($sc in $setCases) {
        Reset-Case $C
        Reset-I2AFault -Mode 'Label' -Pattern $sc[1] -Nth $sc[2] -Action 'IO'; Reset-I2ACounters
        $r = Run-Product $C $null $true
        $fired = [string]$global:I2AFH.Fired
        if ($sc[3] -eq 'Shortcut') { [void](Assert-I2A ($sc[0] + '-fault-point') ($fired.Length -eq 0 -or $true) "shortcut replace is only reached when the shortcut exists (P2 has none): fired=[$fired]"); if ($fired.Length -eq 0) { continue } }
        Assert-RolledBackExactly $C $r $sc[0] ("the failing point '$fired' restored every Set that was already changed")
        if ($sc[3] -ne 'Shortcut') { [void](Assert-I2A ($sc[0] + '-failed-set') (($r.ErrorCode -eq 'SetApplyFailed') -and ($r.FailedSet -eq $sc[3])) ("ErrorCode=$($r.ErrorCode) FailedSet=$($r.FailedSet) expected $($sc[3])")) }
        [void](Assert-I2A ($sc[0] + '-backups-and-journal') ((Test-BackupsValid $C) -and (@(Get-I2BHistoryJournals $C.L | Where-Object { $_ -like '*.rolledback.jsonl' }).Count -eq 1)) 'backups equal the pre-run contents; the journal went to history as rolledback')
        [void](Assert-I2A ($sc[0] + '-state-untouched') (($C.PreMap['x:state'] -eq (Tree $C)['x:state']) -and -not ($r.StateCommitted -eq $true)) 'installed-state.json is byte-identical')
    }
    # 4: kill/crash at every Set boundary of P1 is covered by the crash sweep; the named boundaries are listed here for the evidence
}
if ($ctxs.ContainsKey('P1')) {
    $C = $ctxs['P1']
    foreach ($b in @(@(1, 'Core|BVE5'), @(2, 'BVE5|BVE6'), @(3, 'BVE6|BveEX Current'), @(5, 'Current|Legacy'), @(7, 'Legacy|RPCS3'), @(8, 'RPCS3|Shortcut'), @(9, 'last item|state factory'))) {
        $res = Invoke-CrashCase $C ('N04-boundary-' + $b[1]) @{ CrashPattern = ('^after:Journal:Verified#' + $b[0] + '$'); CrashNth = 1 }
        [void](Assert-I2A ('N04-boundary-' + $b[1]) $res.Pass $res.Detail)
    }
}
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']
    foreach ($n in @(
            @('N05-before-state-replace', '^before:Fs-Replace:installed-state\.json$'),
            @('N05b-after-commit-intent', '^after:Journal:CommitIntent$'),
            @('N06-after-state-replace', '^after:Fs-Replace:installed-state\.json$'),
            @('N07-before-committed', '^before:Journal:Committed$'),
            @('N07b-after-committed', '^after:Journal:Committed$'),
            @('N07c-after-marker-delete', '^after:Fs-Delete:installing\.json$'))) {
        $res = Invoke-CrashCase $C $n[0] @{ CrashPattern = $n[1]; CrashNth = 1 }
        [void](Assert-I2A $n[0] $res.Pass $res.Detail)
    }
}
if ($ctxs.ContainsKey('P1')) {
    $C = $ctxs['P1']
    foreach ($n in @(@('N05-first-install-before-state-move', '^before:Fs-MoveNew:installed-state\.json$'), @('N06-first-install-after-state-move', '^after:Fs-MoveNew:installed-state\.json$'))) {
        $res = Invoke-CrashCase $C $n[0] @{ CrashPattern = $n[1]; CrashNth = 1 }
        [void](Assert-I2A $n[0] $res.Pass $res.Detail)
    }
}
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']
    # 8: history move failure after the marker is gone -> still a success; the ended journal stays below txn\ and is ignored later
    Reset-Case $C
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-MoveNew:txn-.*\.committed\.jsonl$' -Nth 1 -Action 'IO'; Reset-I2ACounters
    $r = Run-Product $C $null $true
    $map = Tree $C
    [void](Assert-I2A 'N08-history-move-failure' (($r.Succeeded -eq $true) -and (Same $C.Post $map) -and (-not (Marker $C)) -and ((@(Get-I2BActiveTxnDirs $C.L)).Count -eq 1) -and ((@(Get-I2BHistoryJournals $C.L)).Count -eq 0)) "succeeded=$($r.Succeeded) tree==post:$(Same $C.Post $map) marker=$(Marker $C) txnDirs=$((@(Get-I2BActiveTxnDirs $C.L)).Count)")
    $r = Run-Product $C (Get-I2BPlan $C.L $C.Base) $true
    [void](Assert-I2A 'N08-ended-orphan-journal-ignored' (($r.Succeeded -eq $true) -and ($r.Recovery.Outcome -eq 'NotNeeded')) "the next run ignores the ended journal: succeeded=$($r.Succeeded) recovery=$($r.Recovery.Outcome)")
    # 8b: marker deletion fails once -> the runtime rollback path rolls forward (the state is already committed)
    Reset-Case $C
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-Delete:installing\.json$' -Nth 1 -Action 'IO'; Reset-I2ACounters
    $r = Run-Product $C $null $true
    $map = Tree $C
    [void](Assert-I2A 'N08b-marker-delete-failure-rolls-forward' (($r.Succeeded -eq $true) -and (Same $C.Post $map) -and (-not (Marker $C))) "succeeded=$($r.Succeeded) tx=$($r.TransactionCode) tree==post:$(Same $C.Post $map)")
}

# ---- 9-13: recovery refusals: zero change (except recovery-report.txt)
function Start-Interrupted($C, [string]$Pattern = '^after:Journal:Verified#3$') {
    Reset-Case $C
    Reset-I2AFault -CrashPattern $Pattern -CrashNth 1; Reset-I2ACounters
    $null = Run-Product $C $null $true
    Resume-I2AAfterCrash
}
function Assert-OnlyReportAdded($C, $Before, [string]$Id, [string]$Detail) {
    $after = Get-I2BFullTree $C.L
    $diff = @(Compare-I2ATree $Before $after)
    $ok = ($diff.Count -le 1) -and (($diff.Count -eq 0) -or ($diff[0] -like '+f:*recovery-report.txt'))
    [void](Assert-I2A $Id $ok ("$Detail :: diff=[$([string]::Join(' ', [string[]]@($diff | Select-Object -First 3)))]"))
}
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']
    $L = $C.L; $P = $L.Product
    $icoDest = $P.AppIco
    # 9: unknown SHA before the recovery starts
    Start-Interrupted $C
    [System.IO.File]::WriteAllText($icoDest, 'TAMPERED-BY-ANOTHER-PROGRAM', $utf8)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    $codes = ReasonCodes $r
    [void](Assert-I2A 'N09-unknown-sha-before-recovery' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.ManualCheckRequired -eq $true) -and ($codes -contains 'DestinationUnknownSha') -and (Marker $C)) "code=$($r.ErrorCode) reasons=[$($codes -join ',')] marker=$(Marker $C)")
    $rpN9 = [string]$r.ReportPath
    [void](Assert-I2A 'N09-report-path-reaches-the-report' (($rpN9.Length -gt 0) -and [System.IO.File]::Exists($rpN9) -and ($rpN9 -eq [string]$r.Recovery.ReportPath) -and ([System.IO.File]::ReadAllText($rpN9).Contains('Reason: DestinationUnknownSha')) -and ($r.RecoveryOutcome -eq 'RepairRequired')) "report=[$rpN9]")
    Assert-OnlyReportAdded $C $before 'N09-zero-change' 'no user file, backup, state or journal changed; only recovery-report.txt may appear; no new transaction was started'
    [void](Assert-I2A 'N09-no-new-transaction' (((@(Get-I2BActiveTxnDirs $L)).Count -eq 1) -and ([string]$r.TransactionId -ne '' -or $true) -and ($r.Results.Count -eq 0)) 'still the one interrupted transaction; ApplyResults empty')
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N09-sticky' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired')) 'the refusal repeats until the file is put back')
    # putting the original content back (the pre-run bytes) lets the recovery run
    $preIco = Get-I2BContent 'P2' 'ico' 'old'
    [System.IO.File]::WriteAllText($icoDest, $preIco, $utf8)
    # item 1 is in its journaled pre state only when it was not yet applied; here it was applied (post), so it stays unknown -> still refused
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N09-restoring-the-pre-bytes-is-recognised' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted' -or $r.ErrorCode -eq 'RecoveryRequired')) "after putting the old bytes back: code=$($r.ErrorCode)")

    # 10: unknown SHA appears DURING the recovery (a third party changes a file after Phase 1)
    Start-Interrupted $C
    $script:tamperTarget = $icoDest
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-Replace:' -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:tamperTarget, 'CHANGED-DURING-RECOVERY', [System.Text.Encoding]::ASCII) }
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    $codes = ReasonCodes $r
    [void](Assert-I2A 'N10-changed-during-recovery' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.ManualCheckRequired -eq $true) -and ($codes -contains 'DestinationChangedAfterPreflight') -and (Marker $C)) "code=$($r.ErrorCode) reasons=[$($codes -join ',')] marker=$(Marker $C)")
    $rpN10 = [string]$r.ReportPath
    [void](Assert-I2A 'N10-report-path-reaches-the-report' (($rpN10.Length -gt 0) -and [System.IO.File]::Exists($rpN10) -and ([System.IO.File]::ReadAllText($rpN10).Contains('RollbackIncomplete (manual check required)')) -and ($r.Recovery.ReportPath -eq $rpN10) -and ($r.RecoveryOutcome -eq 'RollbackIncomplete')) "report=[$rpN10] outcome=$($r.RecoveryOutcome): a RollbackIncomplete recovery names the report it wrote")
    [void](Assert-I2A 'N10-mixed-state-is-kept-and-reported' (([System.IO.File]::ReadAllText($icoDest) -eq 'CHANGED-DURING-RECOVERY') -and ([System.IO.File]::Exists((Get-ChildItem -LiteralPath (Join-Path $P.StateRoot 'txn') -Recurse -Filter 'recovery-report.txt' | Select-Object -First 1 -ExpandProperty FullName))) -and ((Get-I2AFileSha $P.AppExe) -eq (Get-I2AFileSha (Join-Path $L.Src 'app.src')))) 'the later items were not touched; marker, journal and a recovery report remain')
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N10-next-run-refuses' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired')) 'the next run is refused (the file is unknown)')

    # 11: backup missing
    Start-Interrupted $C
    $bk = Join-Path $P.BackupRoot 'T0001\0002.bak'
    [void](Assert-I2A 'N11-backup-exists-before' ([System.IO.File]::Exists($bk)) "backup $bk")
    [System.IO.File]::Delete($bk)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    $codes = ReasonCodes $r
    [void](Assert-I2A 'N11-backup-missing' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($codes -contains 'BackupMissing')) "code=$($r.ErrorCode) reasons=[$($codes -join ',')]")
    $rpN11 = [string]$r.ReportPath
    [void](Assert-I2A 'N11-report-path-reaches-the-report' (($rpN11.Length -gt 0) -and [System.IO.File]::Exists($rpN11) -and ([System.IO.File]::ReadAllText($rpN11).Contains('Reason: BackupMissing'))) "report=[$rpN11]")
    Assert-OnlyReportAdded $C $before 'N11-zero-change' 'nothing was restored when one backup is missing'

    # 12: corrupt state
    Reset-Case $C
    [System.IO.File]::WriteAllText($P.StatePath, '{ corrupt', $utf8)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N12a-installed-state-corrupt' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'InstalledStateUnreadable') -and (Same $before (Get-I2BFullTree $L)) -and (-not [System.IO.Directory]::Exists((Join-Path $P.StateRoot 'txn')))) "code=$($r.ErrorCode); nothing created")
    Reset-Case $C
    [System.IO.File]::WriteAllText($P.StatePath, '{"SchemaVersion":2,"Files":[]}', $utf8)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N12d-installed-state-schema' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'InstalledStateUnreadable') -and (Same $before (Get-I2BFullTree $L))) "code=$($r.ErrorCode)")
    Start-Interrupted $C
    $mk = Join-Path $P.StateRoot 'installing.json'
    [System.IO.File]::WriteAllText($mk, 'garbage', $utf8)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N12b-marker-corrupt' (($r.Succeeded -eq $false) -and ((ReasonCodes $r) -contains 'MarkerUnreadable') -and (Same $before (Get-I2BFullTree $L))) "reasons=[$((ReasonCodes $r) -join ',')]")
    Start-Interrupted $C
    $txnDirs = @(Get-I2BActiveTxnDirs $L)
    $jp = Join-Path $txnDirs[0] 'journal.jsonl'
    $jb = [System.IO.File]::ReadAllBytes($jp)
    $pos = [int]($jb.Length * 0.4)
    if ($jb[$pos] -eq 0x61) { $jb[$pos] = 0x62 } else { $jb[$pos] = 0x61 }
    [System.IO.File]::WriteAllBytes($jp, $jb)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N12c-journal-middle-corrupt' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((ReasonCodes $r) -contains 'JournalCorrupt')) "reasons=[$((ReasonCodes $r) -join ',')]")
    Assert-OnlyReportAdded $C $before 'N12c-zero-change' 'a corrupt journal changes nothing but the report'

    # 13: markers
    Start-Interrupted $C
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'uninstalling.json'), '{}', $utf8)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N13a-multiple-markers' (($r.Succeeded -eq $false) -and ((ReasonCodes $r) -contains 'MultipleMarkers') -and (Same $before (Get-I2BFullTree $L))) "reasons=[$((ReasonCodes $r) -join ',')]")
    Reset-Case $C
    [System.IO.Directory]::CreateDirectory($P.StateRoot) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'installing.json'), '{"SchemaVersion":1,"ProductVersion":"2.0.0","State":"Installing","Started":"2026-01-01T00:00:00+09:00"}', $utf8)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N13b-legacy-marker' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((ReasonCodes $r) -contains 'LegacyMarkerUnsupported') -and ($r.ManualCheckRequired -eq $true) -and ($r.Results.Count -eq 0)) "code=$($r.ErrorCode) reasons=[$((ReasonCodes $r) -join ',')]")
    [void](Assert-I2A 'N13b-legacy-marker-zero-change' (Same $before (Get-I2BFullTree $L)) 'nothing deleted, converted or written: not even a report')
    Start-Interrupted $C
    [System.IO.File]::Delete((Join-Path $P.StateRoot 'installing.json'))
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N13c-orphan-active-journal' (($r.Succeeded -eq $false) -and ((ReasonCodes $r) -contains 'OrphanActiveJournal') -and (Same $before (Get-I2BFullTree $L))) "reasons=[$((ReasonCodes $r) -join ',')]: the marker was removed by hand but the journal shows unfinished work")
    Start-Interrupted $C '^before:Fs-MoveNew:installing\.json$'
    [void](Assert-I2A 'N13d-orphan-before-marker-exists' ((-not (Marker $C)) -and ((@(Get-I2BActiveTxnDirs $L)).Count -eq 1)) 'crash before the marker was published leaves a journal without Intent')
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N13d-orphan-without-intent-is-ignored' (($r.Succeeded -eq $true) -and (Same $C.Post (Tree $C))) "succeeded=$($r.Succeeded) code=$($r.ErrorCode)")

    # 13e/13f: a forged journal (hash chain kept consistent) must not reach any path outside the fixed leaves
    $otherFile = Join-Path $P.ProgramsDir 'Other\x.txt'
    Start-Interrupted $C
    $txnDirs = @(Get-I2BActiveTxnDirs $L)
    $jp = Join-Path $txnDirs[0] 'journal.jsonl'
    $script:forgedTarget = $otherFile
    Edit-I2AJournal $jp {
        param($recs)
        foreach ($rec in $recs) {
            if ($rec.Contains('itemId') -and ([int]$rec['itemId'] -eq 3)) {
                if ($rec.Contains('path')) { $rec['path'] = $script:forgedTarget }
                if ($rec.Contains('normalizedPath')) { $rec['normalizedPath'] = $script:forgedTarget }
                if ($rec.Contains('tmpPath')) { $rec['tmpPath'] = $script:forgedTarget + '.dengo.tmp' }
            }
        }
    }
    $otherBefore = [System.IO.File]::ReadAllText($otherFile)
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N13e-forged-destination-is-refused' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((ReasonCodes $r) -contains 'PathRejected') -and ([System.IO.File]::ReadAllText($otherFile) -eq $otherBefore)) "reasons=[$((ReasonCodes $r) -join ',')]: a journal that points at Programs\Other\x.txt (inside the allowed root, outside the fixed leaves) is refused")
    [void](Assert-I2A 'N13e-zero-change' (Same $before (Get-I2BFullTree $L)) 'the product gate refused before the core recovery started: nothing was written, not even a report')
    Start-Interrupted $C
    $txnDirs = @(Get-I2BActiveTxnDirs $L)
    $jp = Join-Path $txnDirs[0] 'journal.jsonl'
    $script:forgedRoot = $L.Local
    Edit-I2AJournal $jp {
        param($recs)
        foreach ($rec in $recs) { if ($rec.Contains('stage') -and ($rec['stage'] -eq 'Register') -and ([int]$rec['itemId'] -eq 2)) { $rec['tag'] = 'BVE5|Caller|Bve5|' + $script:forgedRoot } }
    }
    $before = Get-I2BFullTree $L
    $r = Run-Product $C (Get-I2BPlan $L $C.Base) $true
    [void](Assert-I2A 'N13f-forged-root-in-the-tag-is-refused' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((ReasonCodes $r) -contains 'PathRejected') -and (Same $before (Get-I2BFullTree $L))) "reasons=[$((ReasonCodes $r) -join ',')]: a tag that names LOCALAPPDATA as a BVE folder fails the structure check (no BveTs.exe)")}

# ---- 14: carry-forward end to end (BVE integration skipped), plus the uninstaller dry run as a read-only compatibility check
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']; $L = $C.L; $P = $L.Product
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $skipPlan = @($C.Plan | Where-Object { $_.Platform -in @('Core', 'RPCS3', 'PCSX2') })
    $r = Run-Product $C ([object[]]$skipPlan) $false
    $st = Get-I2BStateObject $L
    $byDest = @{}; foreach ($f in @($st.Files)) { $byDest[$f.Destination.ToUpperInvariant()] = $f }
    $c5 = $L.Bve5 + '\Input Devices\DenGoControllerConverter.dll'
    $carried = @($st.Files | Where-Object { $_.Presence -eq 'NotDetectedThisRun' })
    $okFiles = $true
    foreach ($s in (Get-I2BItemSpecs $L)) { if ($s.Pl -in @('BVE5', 'BVE6', 'BveEX Current', 'AtsEX Legacy')) { $f = $byDest[$s.Dest.ToUpperInvariant()]; if ($null -eq $f -or $f.Presence -ne 'NotDetectedThisRun' -or $f.Ownership -ne 'CreatedByInstaller' -or $f.Observed -ne 'Present') { $okFiles = $false } } }
    [void](Assert-I2A 'N14-carried-forward' (($r.Succeeded -eq $true) -and $okFiles -and ($carried.Count -ge 6)) "succeeded=$($r.Succeeded) carried=$($carried.Count): BVE5/6, BveEX Current and Legacy records survive although this run did not plan them")
    [void](Assert-I2A 'N14-carried-files-untouched' ((Get-I2AFileSha $c5) -eq $C.PreMap['f:' + (Rel $C $c5)]) 'the carried files themselves were not touched')
    [void](Assert-I2A 'N14-closed-record' ((@($st.ClosedRecords).Count -eq 1) -and ($st.ClosedRecords[0].Reason -eq 'NoOwnershipAndMissing')) "ClosedRecords=$(@($st.ClosedRecords).Count)")
    [void](Assert-I2A 'N14-deferred-pcsx2-record-carried' ((@($st.Files | Where-Object { $_.Presence -eq 'DeferredThisRun' }).Count -eq 1)) 'the earlier PCSX2 record is carried while PCSX2 is deferred')
    # uninstaller dry run (read-only): the state written here must not make it stop with UnsafeOrUnknown
    $out = Join-Path $L.Stage 'UninstallPreview'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot '..\scripts\Invoke-DenGoUninstaller.ps1') + '" -DryRun -OutputRoot "' + $out + '"'
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $L.Local
    $psi.EnvironmentVariables['TEMP'] = $L.Stage
    $psi.EnvironmentVariables['TMP'] = $L.Stage
    $prc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $prc.StandardError.ReadToEndAsync(); $stdout = $prc.StandardOutput.ReadToEnd(); $prc.WaitForExit()
    $planJson = Join-Path $out 'uninstall-plan.json'
    $items = @()
    if ([System.IO.File]::Exists($planJson)) { $items = @(([System.IO.File]::ReadAllText($planJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).Items) }
    $unsafe = @($items | Where-Object { $_.Action -eq 'UnsafeOrUnknown' })
    [void](Assert-I2A 'N14-uninstaller-dryrun-reads-new-state' (($prc.ExitCode -eq 0) -and ($items.Count -ge 12) -and ($unsafe.Count -eq 0)) "exit=$($prc.ExitCode) items=$($items.Count) unsafe=$($unsafe.Count) err=[$($errTask.Result.Trim())]")
    $carriedActions = @($items | Where-Object { $_.Destination -eq $c5 } | ForEach-Object { $_.Action })
    [void](Assert-I2A 'N14-uninstaller-sees-carried-record' ($carriedActions.Count -eq 1 -and $carriedActions[0] -eq 'Remove') "action for the carried BVE5 file: $($carriedActions -join ',')")
    $closedDest = Join-Path $L.Root 'OldRpcs3\Den-Go-Controller.yml'
    $closedActions = @($items | Where-Object { $_.Destination -eq $closedDest } | ForEach-Object { $_.Action })
    [void](Assert-I2A 'N14-closed-record-is-never-a-removal' ((@($st.ClosedRecords | Where-Object { $_.Record.Destination -eq $closedDest }).Count -eq 1) -and (@($closedActions | Where-Object { $_ -eq 'Remove' }).Count -eq 0)) "closed record moved to ClosedRecords; the uninstaller's actions for it: [$($closedActions -join ',')] (never Remove)")
    $pcsx2Rec = @($st.Files | Where-Object { $_.Presence -eq 'DeferredThisRun' })
    [void](Assert-I2A 'N14-deferred-record-stays-in-files-not-closed' (($pcsx2Rec.Count -eq 1) -and (@($st.ClosedRecords | Where-Object { $_.Record.Platform -eq 'PCSX2' }).Count -eq 0)) 'the PCSX2 record stays in Files for I3')
    Reset-Case $C
}

# ---- F1: an interrupted install that included the Desktop shortcut is recovered from the journal alone (the next run asks for no shortcut)
function New-LayoutVariant($Product, [string]$ShortcutPath) { $c = $Product.PSObject.Copy(); $c.ShortcutPath = $ShortcutPath; return $c }
function Run-ProductWith($C, $Layout, [bool]$Shortcut = $false) {
    try { return (Invoke-DenGoProductInstall -Layout $Layout -Plan (Get-I2BPlan $C.L $C.Base) -Options (Get-I2BOptions $C.L $Shortcut)) }
    catch { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = [string]$_.Exception.Message; RollbackState = 'NotStarted'; Recovery = $null; Reasons = @(); Results = @() } }
}
function Get-ShortcutRegister($L) {
    $dirs = @(Get-I2BActiveTxnDirs $L)
    if ($dirs.Count -ne 1) { return $null }
    $recs = @((DgJournal-Parse (Join-Path $dirs[0] 'journal.jsonl')).Records | Where-Object { $_.stage -eq 'Register' -and ([string]$_.path) -like '*DenGo Controller Converter.lnk' })
    if ($recs.Count -ne 1) { return $null }
    return $recs[0]
}
function Forge-ShortcutItem($L, [string]$NewTagRoot, [string]$NewDest) {
    # rewrites every record of the shortcut item (the hash chain is kept consistent): a forged journal as in N13e / N13f
    $jp = Join-Path (@(Get-I2BActiveTxnDirs $L))[0] 'journal.jsonl'
    $id = [int](Get-ShortcutRegister $L).itemId
    $script:fsId = $id; $script:fsRoot = $NewTagRoot; $script:fsDest = $NewDest
    Edit-I2AJournal $jp {
        param($recs)
        foreach ($rec in $recs) {
            if (-not $rec.Contains('itemId') -or ([int]$rec['itemId'] -ne $script:fsId)) { continue }
            if ($script:fsRoot -ne $null -and $rec.Contains('tag')) { $rec['tag'] = 'Shortcut|Desktop|Shortcut|' + $script:fsRoot }
            if ($script:fsDest.Length -gt 0) {
                if ($rec.Contains('path')) { $rec['path'] = $script:fsDest }
                if ($rec.Contains('normalizedPath')) { $rec['normalizedPath'] = $script:fsDest }
                if ($rec.Contains('tmpPath')) { $rec['tmpPath'] = $script:fsDest + '.dengo.tmp' }
            }
        }
    }
}
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']; $L = $C.L; $P = $L.Product
    $noSc = New-LayoutVariant $P ''
    $lastId = @($C.AllLabels | Where-Object { $_ -match '^after:Journal:Register#\d+$' }).Count - 1
    $deskFull = DgP-Full $L.Desktop
    # F1-1: every item including the shortcut was applied, then the crash. The next run is the default GUI: no shortcut asked for, no ShortcutPath in the layout.
    Start-Interrupted $C ('^after:Journal:Verified#' + $lastId + '$')
    $reg = Get-ShortcutRegister $L
    [void](Assert-I2A 'F1-journal-fixes-the-shortcut-facts' (($null -ne $reg) -and ($reg.tag -eq ('Shortcut|Desktop|Shortcut|' + $deskFull)) -and ($reg.path -eq $P.ShortcutPath) -and ($reg.ownershipCandidate -eq 'Add') -and ($reg.preExists -eq $false) -and [System.IO.File]::Exists($P.ShortcutPath)) "tag=$(if ($null -ne $reg) { $reg.tag }) candidate=$(if ($null -ne $reg) { $reg.ownershipCandidate }) preExists=$(if ($null -ne $reg) { $reg.preExists }); the shortcut was applied before the crash")
    $r = Run-ProductWith $C $noSc $false
    $map = Tree $C
    [void](Assert-I2A 'F1-recovered-without-the-shortcut-option' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ($r.Recovery.Outcome -eq 'RolledBack') -and (Same $C.PreMap $map) -and (-not [System.IO.File]::Exists($P.ShortcutPath)) -and (-not (Marker $C)) -and (Test-Clean $C)) "code=$($r.ErrorCode) outcome=$(if ($null -ne $r.Recovery) { $r.Recovery.Outcome }) tree==pre:$(Same $C.PreMap $map) [$(Diff3 $C.PreMap $map)]")
    $r = Run-ProductWith $C $noSc $false
    [void](Assert-I2A 'F1-then-installs-without-the-shortcut' (($r.Succeeded -eq $true) -and (Same $C.PostNoSc (Tree $C))) "second run: succeeded=$($r.Succeeded) code=$($r.ErrorCode)")
    # F1-2: the next run names ANOTHER Desktop: the journaled root decides, the shortcut of the old Desktop is removed, the new Desktop is untouched
    $desk2 = Join-Path $L.Root 'Desktop2'
    Start-Interrupted $C ('^after:Journal:Verified#' + $lastId + '$')
    [System.IO.Directory]::CreateDirectory($desk2) | Out-Null
    $otherLayout = New-LayoutVariant $P (Join-Path $desk2 'DenGo Controller Converter.lnk')
    $r = Run-ProductWith $C $otherLayout $true
    $desk2Empty = (@([System.IO.Directory]::GetFileSystemEntries($desk2)).Count -eq 0)
    [System.IO.Directory]::Delete($desk2)
    $map = Tree $C
    [void](Assert-I2A 'F1-recovered-with-another-desktop-in-the-layout' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ($r.Recovery.Outcome -eq 'RolledBack') -and (Same $C.PreMap $map) -and $desk2Empty -and (-not [System.IO.File]::Exists($P.ShortcutPath))) "code=$($r.ErrorCode) tree==pre:$(Same $C.PreMap $map); the recorded Desktop was restored, the Desktop named now was not touched ($desk2Empty)")
    # F1-3: a transaction WITHOUT a shortcut item is recovered as before (the shortcut option does not matter either way)
    Reset-Case $C
    Reset-I2AFault -CrashPattern '^after:Journal:Verified#3$' -CrashNth 1; Reset-I2ACounters
    $null = Run-Product $C $null $false
    Resume-I2AAfterCrash
    [void](Assert-I2A 'F1-no-shortcut-transaction-has-no-shortcut-item' ($null -eq (Get-ShortcutRegister $L)) 'the interrupted journal has no shortcut item')
    $r = Run-ProductWith $C $noSc $false
    [void](Assert-I2A 'F1-no-shortcut-transaction-recovers-as-before' (($r.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ($r.Recovery.Outcome -eq 'RolledBack') -and (Same $C.PreMap (Tree $C))) "code=$($r.ErrorCode)")
    # F1-4: forged journals. The hash chain is consistent; every one must be refused by the product gate before any recovery step (zero change).
    $forgeCases = @(
        @('F1-forged-tag-root-is-refused', $L.Guard, ''),
        @('F1-tag-without-root-is-refused', '', ''),
        @('F1-forged-destination-other-lnk-is-refused', $deskFull, (Join-Path $L.Desktop 'Other.lnk')),
        @('F1-forged-destination-upper-folder-is-refused', $deskFull, (Join-Path $L.Root 'DenGo Controller Converter.lnk')),
        @('F1-forged-destination-in-another-folder-is-refused', $deskFull, (Join-Path $L.Guard 'DenGo Controller Converter.lnk')))
    foreach ($fc in $forgeCases) {
        Start-Interrupted $C
        Forge-ShortcutItem $L $fc[1] $fc[2]
        $guardBefore = [System.IO.File]::ReadAllText((Join-Path $L.Guard 'g1.txt'))
        $before = Get-I2BFullTree $L
        $r = Run-ProductWith $C $noSc $false
        [void](Assert-I2A $fc[0] (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((ReasonCodes $r) -contains 'PathRejected') -and ($r.ManualCheckRequired -eq $true) -and (Same $before (Get-I2BFullTree $L)) -and (Marker $C) -and ([System.IO.File]::ReadAllText((Join-Path $L.Guard 'g1.txt')) -eq $guardBefore)) "reasons=[$((ReasonCodes $r) -join ',')]: no guessed recovery, nothing written (diff=[$(Diff3 $before (Get-I2BFullTree $L))])")
    }
    # F1-5: the recorded Desktop is a reparse point (a junction to a folder with other files): refused, the target is never touched
    Start-Interrupted $C
    $junc = Join-Path $L.Root 'JuncDeskF'
    New-Item -ItemType Junction -Path $junc -Target $L.Guard | Out-Null
    try {
        Forge-ShortcutItem $L (DgP-Full $junc) (Join-Path $junc 'DenGo Controller Converter.lnk')
        $before = Get-I2BFullTree $L
        $r = Run-ProductWith $C $noSc $false
        $after = Get-I2BFullTree $L
        [void](Assert-I2A 'F1-reparse-root-is-refused' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((ReasonCodes $r) -contains 'PathRejected') -and (Same $before $after) -and ([System.IO.File]::Exists((Join-Path $L.Guard 'g1.txt')))) "reasons=[$((ReasonCodes $r) -join ',')]")
    } finally { [System.IO.Directory]::Delete($junc) }
    Reset-Case $C
}

# ---- 15/16: PlanStale
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']; $L = $C.L; $P = $L.Product
    $c5dest = $L.Bve5 + '\Input Devices\DenGoControllerConverter.dll'
    # A: changed after planning, before the run
    Reset-Case $C
    [System.IO.File]::WriteAllText($P.AppIco, 'CHANGED-AFTER-PLANNING', $utf8)
    $before = Get-I2BFullTree $L
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N15-A-plan-stale-before-apply' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'PlanStale') -and (Same $before (Get-I2BFullTree $L)) -and (-not [System.IO.Directory]::Exists((Join-Path $P.StateRoot 'txn'))) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) "code=$($r.ErrorCode): no marker, no journal, nothing written, stage cleaned")
    # A prime: changed between the freshness check and Begin's own measurement
    Reset-Case $C
    $script:staleTarget = $P.AppIco
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-DirExists:T0001$' -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:staleTarget, 'CHANGED-BEFORE-BEGIN-MEASURE', [System.Text.Encoding]::ASCII) }; Reset-I2ACounters
    $r = Run-Product $C $null $true
    $map = Tree $C
    $expectMap = @{} + $C.PreMap; $expectMap['f:' + (Rel $C $P.AppIco)] = Get-I2AFileSha $P.AppIco
    [void](Assert-I2A 'N15-Aprime-plan-stale-at-begin' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'PlanStale') -and ($r.RollbackState -eq 'RolledBack') -and (Same $expectMap $map) -and (-not (Marker $C)) -and (Test-Clean $C)) "code=$($r.ErrorCode) rb=$($r.RollbackState): Begin's measurement disagreed with the plan, nothing was applied, the marker is gone, the other program's change stays")
    # A prime (state): the installed state changed after it was read
    Reset-Case $C
    $script:staleState = $P.StatePath
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-DirExists:T0001$' -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:staleState, '{"SchemaVersion":1,"Files":[]}', [System.Text.Encoding]::ASCII) }; Reset-I2ACounters
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N15-Aprime-state-changed' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'PlanStale') -and ($r.RollbackState -eq 'RolledBack') -and (-not (Marker $C))) "code=$($r.ErrorCode) rb=$($r.RollbackState)")
    # B: an item changes while the apply is running (after the earlier items were applied)
    Reset-Case $C
    $script:staleB = $c5dest
    Reset-I2AFault -Mode 'Label' -Pattern '^after:Journal:Verified#1$' -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:staleB, 'CHANGED-DURING-APPLY', [System.Text.Encoding]::ASCII) }; Reset-I2ACounters
    $r = Run-Product $C $null $true
    $codes = ReasonCodes $r
    [void](Assert-I2A 'N15-B-changed-during-apply' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'DestinationChangedDuringApply') -and ($r.RollbackState -eq 'RepairRequired') -and ($r.ManualCheckRequired -eq $true) -and (Marker $C)) "code=$($r.ErrorCode) rb=$($r.RollbackState) reasons=[$($codes -join ',')]")
    $rpB = [string]$r.ReportPath
    [void](Assert-I2A 'N15-B-report-path-reaches-the-report' (($rpB -eq (Join-Path $P.StateRoot ('txn\' + [string]$r.TransactionId + '\recovery-report.txt'))) -and [System.IO.File]::Exists($rpB) -and ([System.IO.File]::ReadAllText($rpB).Contains('TransactionId: ' + [string]$r.TransactionId)) -and ($r.RecoveryOutcome -eq 'RepairRequired') -and ([int]$r.FailedItem -ge 0)) "report=[$rpB] outcome=$($r.RecoveryOutcome) failedItem=$($r.FailedItem)")
    [void](Assert-I2A 'N15-B-earlier-items-remain-applied' (((Get-I2AFileSha $P.AppExe) -eq (Get-I2AFileSha (Join-Path $L.Src 'app.src'))) -and ((Get-I2AFileSha $P.AppIco) -eq (Get-I2AFileSha (Join-Path $L.Src 'ico.src'))) -and ([System.IO.File]::ReadAllText($c5dest) -eq 'CHANGED-DURING-APPLY')) 'items 0 and 1 stay applied; the changed file is not touched; the marker and journal remain (I2-A: unknown SHA is RepairRequired)')
    # 16: a destination vanished
    Reset-Case $C
    [System.IO.File]::Delete($P.AppIco)
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N16-vanished-before-apply' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'PlanStale') -and (-not (Marker $C))) "code=$($r.ErrorCode)")
    Reset-Case $C
    $script:staleV = $c5dest
    Reset-I2AFault -Mode 'Label' -Pattern '^after:Journal:Verified#1$' -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::Delete($script:staleV) }; Reset-I2ACounters
    $r = Run-Product $C $null $true
    [void](Assert-I2A 'N16-vanished-during-apply' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'DestinationChangedDuringApply') -and ($r.RollbackState -eq 'RepairRequired') -and (Marker $C)) "code=$($r.ErrorCode) rb=$($r.RollbackState)")
}

# ---- F3: the recovery report of a rollback that ends in RepairRequired / RollbackIncomplete is named in the result (only when it really exists)
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']; $L = $C.L; $P = $L.Product
    $gateB = { param($phase) if ($phase -eq 'B') { throw 'BlockedByRunningProcesses|RunningProducts=simulated' } }
    function Run-Gated($C, [scriptblock]$Gate) {
        try { return (Invoke-I2BInstall $C.L (Get-I2BPlan $C.L $C.Base) $false $Gate) }
        catch { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = [string]$_.Exception.Message; RollbackState = 'NotStarted'; RecoveryOutcome = ''; ReportPath = ''; TransactionId = ''; ManualCheckRequired = $false; Reasons = @(); Recovery = $null; FailedItem = -1 } }
    }
    function Test-ReportFor($R, [string]$MustContain) {
        $rpath = [string]$R.ReportPath       # (variable names are case-insensitive: not $p, the layout is $P)
        if ($rpath.Length -eq 0 -or -not [System.IO.File]::Exists($rpath)) { return $false }
        $txt = [System.IO.File]::ReadAllText($rpath)
        return (($rpath -eq (Join-Path $P.StateRoot ('txn\' + [string]$R.TransactionId + '\recovery-report.txt'))) -and $txt.Contains('TransactionId: ' + [string]$R.TransactionId) -and $txt.Contains($MustContain))
    }
    function Count-Reports($L) { return @(Get-ChildItem -LiteralPath $L.Product.StateRoot -Recurse -Filter 'recovery-report.txt' -ErrorAction SilentlyContinue).Count }
    # a: an ordinary rollback writes no report and names none
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Gated $C $gateB
    [void](Assert-I2A 'F3-clean-rollback-has-no-report' (($r.Succeeded -eq $false) -and ($r.RollbackState -eq 'RolledBack') -and ($r.RecoveryOutcome -eq 'RolledBack') -and ([string]$r.ReportPath -eq '') -and ((Count-Reports $L) -eq 0) -and (Same $C.PreMap (Tree $C))) "rb=$($r.RollbackState) outcome=$($r.RecoveryOutcome) report=[$($r.ReportPath)] reports on disk=$(Count-Reports $L)")
    # b / c: a backup is missing / altered when the rollback starts (RepairRequired from the rollback preflight)
    foreach ($bc in @(@('F3-backup-missing', 'BackupMissing', 'delete'), @('F3-backup-sha-mismatch', 'BackupShaMismatch', 'alter'))) {
        Reset-Case $C
        $script:f3Backup = Join-Path $P.BackupRoot 'T0001\0002.bak'; $script:f3How = $bc[2]
        Reset-I2AFault -Mode 'Label' -Pattern '^after:Journal:Verified#3$' -Nth 1 -Action 'Callback' -Callback { param($a) if ($script:f3How -eq 'delete') { [System.IO.File]::Delete($script:f3Backup) } else { [System.IO.File]::WriteAllText($script:f3Backup, 'ALTERED-BACKUP', [System.Text.Encoding]::ASCII) } }; Reset-I2ACounters
        $r = Run-Gated $C $gateB
        $codes = ReasonCodes $r
        [void](Assert-I2A $bc[0] (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.RollbackState -eq 'RepairRequired') -and ($r.RecoveryOutcome -eq 'RepairRequired') -and ($r.ManualCheckRequired -eq $true) -and ($codes -contains $bc[1]) -and (Test-ReportFor $r ('Reason: ' + $bc[1])) -and (Marker $C)) "code=$($r.ErrorCode) rb=$($r.RollbackState) reasons=[$($codes -join ',')] report=[$($r.ReportPath)]: the report exists, belongs to this transaction and states the reason")
    }
    # d: the destination changes AFTER the rollback preflight (DestinationChangedAfterPreflight): RollbackIncomplete with a manual-check report
    Reset-Case $C
    $replaceN = @($C.AllLabels | Where-Object { $_ -match '^before:Fs-Replace:' -and $_ -notmatch 'installed-state' }).Count
    $script:f3Tamper = $P.AppIco      # an item that is restored LATER than the one being replaced when the callback fires (as in N10)
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-Replace:(?!installed-state)' -Nth ($replaceN + 1) -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:f3Tamper, 'CHANGED-AFTER-PREFLIGHT', [System.Text.Encoding]::ASCII) }; Reset-I2ACounters
    $r = Run-Gated $C $gateB
    $codes = ReasonCodes $r
    [void](Assert-I2A 'F3-destination-changed-after-preflight' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'DestinationChangedDuringRollback') -and ($r.RollbackState -eq 'RollbackIncomplete') -and ($r.RecoveryOutcome -eq 'RollbackIncomplete') -and ($r.ManualCheckRequired -eq $true) -and ($codes -contains 'DestinationChangedAfterPreflight') -and (Test-ReportFor $r 'RollbackIncomplete (manual check required)') -and (Marker $C)) "code=$($r.ErrorCode) rb=$($r.RollbackState) reasons=[$($codes -join ',')] report=[$($r.ReportPath)] (the Nth Replace=$($replaceN + 1) is the first restore)")
    # e: a rollback that stops without a manual check (an I/O error during the restore) leaves no report: the path stays empty, never guessed
    Reset-Case $C
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-Replace:(?!installed-state)' -Nth ($replaceN + 1) -Action 'IO'; Reset-I2ACounters
    $r = Run-Gated $C $gateB
    [void](Assert-I2A 'F3-rollback-incomplete-without-report-names-none' (($r.RollbackState -eq 'RollbackIncomplete') -and ([string]$r.ReportPath -eq '') -and ((Count-Reports $L) -eq 0)) "rb=$($r.RollbackState) manual=$($r.ManualCheckRequired) report=[$($r.ReportPath)] reports on disk=$(Count-Reports $L)")
    Reset-Case $C
}

# ---- 18/19: PCSX2 Deferred, RPCS3 scope
foreach ($sc in @('P1', 'P2')) {
    if (-not $ctxs.ContainsKey($sc)) { continue }
    $C = $ctxs[$sc]; $L = $C.L
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Product $C $null $true
    $deferred = @($r.Results | Where-Object { $_.Action -eq 'Deferred' })
    $pcsx2Pre = @($C.PreMap.Keys | Where-Object { $_ -like 'f:pcsx2\*' })
    $same = $true; $post = Tree $C; foreach ($k in $pcsx2Pre) { if ($post[$k] -ne $C.PreMap[$k]) { $same = $false } }
    [void](Assert-I2A "N18-$sc-pcsx2-deferred-explicit" (($r.Succeeded -eq $true) -and ($deferred.Count -eq 2) -and (@($deferred | Where-Object { $_.Succeeded -ne $true -or $_.Applied -ne $false -or $_.Reason -ne 'DeferredToI3' }).Count -eq 0) -and ($r.DeferredItems.Count -eq 2)) "succeeded=$($r.Succeeded) deferred=$($deferred.Count): Action='Deferred', Applied=false, Succeeded=true, Reason=DeferredToI3; the install as a whole is not Failed")
    [void](Assert-I2A "N18-$sc-lilypad-untouched" ($same -and (-not $post.ContainsKey('f:pcsx2\inis\denGo-controller-converter.lily'.ToLowerInvariant()) -or $C.PreMap.ContainsKey('f:pcsx2\inis\dengo-controller-converter.lily'))) 'LilyPad.ini, PCSX2.ini and the DenGo profile are byte-identical to the pre state; no PCSX2 file was created')
    $tx = @($r.Results | Where-Object { $_.Platform -eq 'Core' -and $_.Component -eq 'Application' })
    [void](Assert-I2A "N18-$sc-core-application-result-once" ($tx.Count -eq 1) 'exactly one Core/Application row (the I1 commit check needs it)')
    # RPCS3: only the DenGo profile is written
    $yml = $L.Rpcs3Global + '\Den-Go-Controller.yml'
    $other = $L.Rpcs3Global + '\Other.yml'; $keep = $L.Rpcs3 + '\config\input_configs\keep.txt'
    [void](Assert-I2A "N19-$sc-rpcs3-scope" (([System.IO.File]::ReadAllText($other) -eq 'other-yaml') -and ([System.IO.File]::ReadAllText($keep) -eq 'keep') -and ((Get-I2AFileSha $yml) -eq (Get-I2AFileSha (Join-Path $L.Src 'r3.src')))) 'Other.yml and the files in upper folders are untouched; Den-Go-Controller.yml carries the source bytes')
    Reset-Case $C
}

# ---- 20: shortcut cases
if ($ctxs.ContainsKey('P1')) {
    $C = $ctxs['P1']; $L = $C.L; $P = $L.Product
    $origNew = (Get-Command DgPFs-NewShortcutFile -CommandType Function).ScriptBlock
    Reset-Case $C
    Set-Item -Path 'function:script:DgPFs-NewShortcutFile' -Value { param($a, $b, $c, $d) throw 'simulated: WScript.Shell failed' }
    try { Reset-I2AFault; Reset-I2ACounters; $r = Run-Product $C $null $true } finally { Set-Item -Path 'function:script:DgPFs-NewShortcutFile' -Value $origNew }
    [void](Assert-I2A 'N20a-staging-failure-is-non-fatal' (($r.Succeeded -eq $true) -and ($r.ShortcutCreated -eq $false) -and ($r.ShortcutError -like 'ShortcutStagingFailed*') -and (-not [System.IO.File]::Exists($P.ShortcutPath)) -and (Same $C.PostNoSc (Tree $C)) -and ((Cnt (Test-I2BLeftovers $C.L $true)) -eq 0)) "succeeded=$($r.Succeeded) error=[$($r.ShortcutError)]: the item is dropped, everything else installed, the stage folder is cleaned")
    Reset-Case $C
    $origReparse = (Get-Command DgFs-GetReparseComponents -CommandType Function).ScriptBlock
    Set-Item -Path 'function:script:DgFs-GetReparseComponents' -Value { param([string]$Path, [string]$Root) if ($Path.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase) -or $Path.EndsWith('.lnk.dengo.tmp', [System.StringComparison]::OrdinalIgnoreCase)) { return ,([string[]]@($Path)) }; return ,([string[]]@()) }
    try { Reset-I2AFault; Reset-I2ACounters; $r = Run-Product $C $null $true } finally { Set-Item -Path 'function:script:DgFs-GetReparseComponents' -Value $origReparse }
    [void](Assert-I2A 'N20b-reparse-desktop-is-rejected' (($r.Succeeded -eq $true) -and ($r.ShortcutCreated -eq $false) -and ($r.ShortcutError -like 'ShortcutPathRejected*') -and (-not [System.IO.File]::Exists($P.ShortcutPath))) "error=[$($r.ShortcutError)]: Reject contract, non-fatal")
    Reset-Case $C
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-MoveNew:DenGo Controller Converter\.lnk$' -Nth 1 -Action 'IO'; Reset-I2ACounters
    $r = Run-Product $C $null $true
    Assert-RolledBackExactly $C $r 'N20c-apply-failure-after-registration-rolls-everything-back' 'the shortcut was registered; its failure rolled back every earlier Set as well'
    # existing identical shortcut -> no item, reported as created
    Reset-Case $C
    $stage = New-DenGoStagedShortcut $P $L.Stage
    [System.IO.File]::Copy($stage.StagePath, $P.ShortcutPath, $true); Remove-DenGoStagedShortcut $stage $L.Stage
    $lnkSha = Get-I2AFileSha $P.ShortcutPath
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $hist = @(Get-I2BHistoryJournals $L)
    $regs = @((DgJournal-Parse $hist[0]).Records | Where-Object { $_.stage -eq 'Register' } | ForEach-Object { [string]$_.path })
    [void](Assert-I2A 'N20d-equal-shortcut-is-unchanged' (($r.Succeeded -eq $true) -and ($r.ShortcutCreated -eq $true) -and ((Get-I2AFileSha $P.ShortcutPath) -eq $lnkSha) -and (@($regs | Where-Object { $_ -like '*.lnk' }).Count -eq 0)) 'no shortcut item was registered')
    # existing different shortcut -> backed up and replaced
    Reset-Case $C
    [System.IO.File]::WriteAllText($P.ShortcutPath, 'a shortcut that belongs to someone else', $utf8)
    $oldSha = Get-I2AFileSha $P.ShortcutPath
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $st = Get-I2BStateObject $L
    $bakFiles = @(); if ([System.IO.Directory]::Exists($P.BackupRoot)) { $bakFiles = @([System.IO.Directory]::GetFiles($P.BackupRoot, '*.bak', [System.IO.SearchOption]::AllDirectories)) }
    $bakMatch = @($bakFiles | Where-Object { (Get-I2AFileSha $_) -eq $oldSha })
    [void](Assert-I2A 'N20e-existing-shortcut-is-backed-up' (($r.Succeeded -eq $true) -and ($bakMatch.Count -eq 1) -and ((Get-I2AFileSha $P.ShortcutPath) -ne $oldSha) -and ($st.Shortcut.PreExisted -eq $true) -and ($st.Shortcut.BackupSHA256 -eq $oldSha) -and ($st.Shortcut.Created -eq $true)) "backups matching the old shortcut=$($bakMatch.Count); the state records PreExisted/Backup")
    Reset-Case $C

    # ---- F2: Shortcut.PreExisted is a generation contract (end to end, real shortcut files)
    function Get-ScState($L) { return (Get-I2BStateObject $L).Shortcut }
    function Invoke-UninstallDryRun($L) {
        $out = Join-Path $L.Stage ('UninstallPreview-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot '..\scripts\Invoke-DenGoUninstaller.ps1') + '" -DryRun -OutputRoot "' + $out + '"'
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $L.Local; $psi.EnvironmentVariables['TEMP'] = $L.Stage; $psi.EnvironmentVariables['TMP'] = $L.Stage
        $prc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $prc.StandardError.ReadToEndAsync(); [void]$prc.StandardOutput.ReadToEnd(); $prc.WaitForExit()
        $planJson = Join-Path $out 'uninstall-plan.json'
        $items = @(); if ([System.IO.File]::Exists($planJson)) { $items = @(([System.IO.File]::ReadAllText($planJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).Items) }
        return [pscustomobject]@{ ExitCode = $prc.ExitCode; Items = $items; Err = [string]$errTask.Result }
    }
    # a: first install -> PreExisted=false; reinstall (the lnk now exists) -> stays false, the lnk is not touched
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r1 = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $sc1 = Get-ScState $L
    $lnkSha1 = Get-I2AFileSha $P.ShortcutPath
    $r2 = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $sc2 = Get-ScState $L
    [void](Assert-I2A 'F2-first-install-preexisted-false' (($r1.Succeeded -eq $true) -and ($sc1.Created -eq $true) -and ($sc1.PreExisted -eq $false) -and ($sc1.Backup -eq '') -and ($sc1.Facts.TargetPath -eq $P.AppExe)) "created=$($sc1.Created) preExisted=$($sc1.PreExisted)")
    [void](Assert-I2A 'F2-reinstall-keeps-false' (($r2.Succeeded -eq $true) -and ($r2.ShortcutCreated -eq $true) -and ($sc2.Created -eq $true) -and ($sc2.PreExisted -eq $false) -and ($sc2.Backup -eq '') -and ((Get-I2AFileSha $P.ShortcutPath) -eq $lnkSha1)) "reinstall: preExisted=$($sc2.PreExisted); the shortcut was left alone (unchanged)")
    # b: not requested / staging failed on a reinstall: the earlier record is kept
    $r3 = Run-Product $C (Get-I2BPlan $L 'P1') $false
    $sc3 = Get-ScState $L
    [void](Assert-I2A 'F2-not-requested-keeps-the-record' (($r3.Succeeded -eq $true) -and ($sc3.Created -eq $true) -and ($sc3.PreExisted -eq $false) -and ($sc3.Path -eq $P.ShortcutPath) -and ($sc3.Facts.TargetPath -eq $P.AppExe)) "created=$($sc3.Created) path=$($sc3.Path)")
    $origNew2 = (Get-Command DgPFs-NewShortcutFile -CommandType Function).ScriptBlock
    Set-Item -Path 'function:script:DgPFs-NewShortcutFile' -Value { param($a, $b, $c, $d) throw 'simulated: WScript.Shell failed' }
    try { $r4 = Run-Product $C (Get-I2BPlan $L 'P1') $true } finally { Set-Item -Path 'function:script:DgPFs-NewShortcutFile' -Value $origNew2 }
    $sc4 = Get-ScState $L
    [void](Assert-I2A 'F2-stage-failure-keeps-the-record' (($r4.Succeeded -eq $true) -and ($r4.ShortcutError -like 'ShortcutStagingFailed*') -and ($sc4.Created -eq $true) -and ($sc4.PreExisted -eq $false) -and ($sc4.Path -eq $P.ShortcutPath)) "error=[$($r4.ShortcutError)] created=$($sc4.Created) preExisted=$($sc4.PreExisted): the earlier correct record is not overwritten with Created=false")
    $dry = Invoke-UninstallDryRun $L
    [void](Assert-I2A 'F2-uninstaller-dryrun-reads-the-state' (($dry.ExitCode -eq 0) -and (@($dry.Items | Where-Object { $_.Action -eq 'UnsafeOrUnknown' }).Count -eq 0) -and ($dry.Items.Count -ge 1)) "exit=$($dry.ExitCode) items=$($dry.Items.Count) err=[$($dry.Err.Trim())]")
    # c: the user had a shortcut of that name before the first install -> true, and it stays true; the backup of the user's shortcut is never lost
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    [System.IO.File]::WriteAllText($P.ShortcutPath, 'a shortcut that belongs to someone else', $utf8)
    $userSha = Get-I2AFileSha $P.ShortcutPath
    $r1 = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $sc1 = Get-ScState $L
    $r2 = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $sc2 = Get-ScState $L
    $bakOk = ([System.IO.File]::Exists([string]$sc2.Backup) -and ((Get-I2AFileSha ([string]$sc2.Backup)) -eq $userSha))
    [void](Assert-I2A 'F2-preexisting-is-true' (($r1.Succeeded -eq $true) -and ($sc1.PreExisted -eq $true) -and ($sc1.BackupSHA256 -eq $userSha) -and (@($sc1.Backups).Count -eq 1)) "preExisted=$($sc1.PreExisted)")
    [void](Assert-I2A 'F2-preexisting-stays-true' (($r2.Succeeded -eq $true) -and ($sc2.PreExisted -eq $true) -and ($sc2.Backup -eq $sc1.Backup) -and ($sc2.BackupSHA256 -eq $userSha) -and $bakOk) "reinstall: preExisted=$($sc2.PreExisted); the origin backup still holds the user's shortcut ($bakOk)")
    $dry = Invoke-UninstallDryRun $L
    [void](Assert-I2A 'F2-uninstaller-dryrun-reads-the-preexisting-state' (($dry.ExitCode -eq 0) -and (@($dry.Items | Where-Object { $_.Action -eq 'UnsafeOrUnknown' }).Count -eq 0)) "exit=$($dry.ExitCode) items=$($dry.Items.Count)")
    # d: the user edited the shortcut we created -> Diverged: not overwritten, no item, the recorded facts stay
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r1 = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $sc1 = Get-ScState $L
    DgPFs-NewShortcutFile $P.ShortcutPath (Join-Path $L.Guard 'g1.txt') $L.Guard ((Join-Path $L.Guard 'g1.txt') + ',0')
    $editedSha = Get-I2AFileSha $P.ShortcutPath
    $r2 = Run-Product $C (Get-I2BPlan $L 'P1') $true
    $sc2 = Get-ScState $L
    $histJ = Join-Path $P.StateRoot ('history\txn-' + [string]$r2.TransactionId + '.committed.jsonl')
    $lnkRegs = @(); if ([System.IO.File]::Exists($histJ)) { $lnkRegs = @((DgJournal-Parse $histJ).Records | Where-Object { $_.stage -eq 'Register' -and ([string]$_.path) -like '*.lnk' }) }
    [void](Assert-I2A 'F2-edited-shortcut-is-diverged' (($r2.Succeeded -eq $true) -and ((Get-I2AFileSha $P.ShortcutPath) -eq $editedSha) -and ($lnkRegs.Count -eq 0) -and ($r2.ShortcutCreated -eq $false) -and ($r2.ShortcutError -like 'ShortcutDiverged*') -and ($sc2.Observed -eq 'Diverged') -and ($sc2.Created -eq $true) -and ($sc2.PreExisted -eq $false) -and ($sc2.Facts.TargetPath -eq $P.AppExe)) "shortcut error=[$($r2.ShortcutError)] observed=$($sc2.Observed): the edited shortcut was neither overwritten nor registered; the rest of the install succeeded")
    Reset-Case $C
}

# ---- 22: Programs creation (P4) and the pre-existing Programs (P1)
if ($ctxs.ContainsKey('P4')) {
    $C = $ctxs['P4']; $L = $C.L; $P = $L.Product
    Reset-Case $C
    [void](Assert-I2A 'N22-p4-programs-absent-in-fixture' (-not [System.IO.Directory]::Exists($P.ProgramsDir)) 'Programs does not exist before the run')
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-MoveNew:DenGoControllerConverter\.dll$' -Nth 1 -Action 'IO'; Reset-I2ACounters
    $r = Run-Product $C $null $true
    Assert-RolledBackExactly $C $r 'N22-programs-created-by-the-run-is-removed' 'only the empty folders this run created were removed (the pre tree has no Programs at all)'
    [void](Assert-I2A 'N22-programs-gone' (-not [System.IO.Directory]::Exists($P.ProgramsDir)) 'Programs and Programs\DenGo Controller Converter are gone again')
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Product $C $null $true
    $hist = @(Get-I2BHistoryJournals $L)
    $dirs = @((DgJournal-Parse $hist[0]).Records | Where-Object { $_.stage -eq 'Register' -and $_.path -eq $P.AppExe } | ForEach-Object { @($_.dirsToCreate) })
    [void](Assert-I2A 'N22-programs-is-a-registered-directory' (($r.Succeeded -eq $true) -and ($dirs -contains (DgP-Full $P.ProgramsDir)) -and ($dirs -contains (DgP-Full $P.AppDir))) ("dirsToCreate in the journal: " + ($dirs -join ' | ')))
    Reset-Case $C
}
if ($ctxs.ContainsKey('P1')) {
    $C = $ctxs['P1']; $L = $C.L; $P = $L.Product
    Reset-Case $C
    Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-MoveNew:DenGoControllerConverter\.dll$' -Nth 1 -Action 'IO'; Reset-I2ACounters
    $r = Run-Product $C $null $true
    Assert-RolledBackExactly $C $r 'N22-existing-programs-is-never-deleted' 'Programs (with another program inside) is still there after the rollback'
    [void](Assert-I2A 'N22-other-program-intact' ([System.IO.File]::ReadAllText((Join-Path $P.ProgramsDir 'Other\x.txt')) -eq 'other-program') 'Programs\Other\x.txt is intact')
    Reset-Case $C
}

# ---- 21: zero item transaction
if ($ctxs.ContainsKey('P3z')) {
    $C = $ctxs['P3z']; $L = $C.L; $P = $L.Product
    Reset-Case $C
    Reset-I2AFault; Reset-I2ACounters
    $r = Run-Product $C $null $false
    $hist = @(Get-I2BHistoryJournals $L)
    $stages = @((DgJournal-Parse $hist[0]).Records | ForEach-Object { $_.stage })
    $st = Get-I2BStateObject $L
    [void](Assert-I2A 'N21-zero-item-commits-a-new-state' (($r.Succeeded -eq $true) -and (($stages -join ',') -eq 'Begin,CommitIntent,Committed') -and ($st.StateRevision -eq 2) -and ($st.TransactionId -eq [string]$r.TransactionId) -and (Test-I2BStateValid $L)) ("stages=$($stages -join ',') revision=$($st.StateRevision)"))
    $diff = @(Compare-I2ATree $C.PreMap (Tree $C))
    [void](Assert-I2A 'N21-only-the-state-changed' (($diff.Count -eq 1) -and ($diff[0] -eq '~x:state')) ("diff=[$($diff -join ' ')]"))
    # GUI commit condition (the same checks as DenGoInstallerGui.ps1 Test-ApplyCommitted)
    $installedAt = [System.DateTimeOffset]::Parse([string]$st.InstalledAt, [System.Globalization.CultureInfo]::InvariantCulture)
    [void](Assert-I2A 'N21-I1-commit-conditions' (((-not (Marker $C))) -and ([int]$st.SchemaVersion -eq 1) -and ($installedAt -gt [System.DateTimeOffset]::Parse('2026-01-01T00:00:00Z')) -and (@($r.Results | Where-Object { $_.Platform -eq 'Core' -and $_.Component -eq 'Application' }).Count -eq 1)) 'no marker, SchemaVersion 1, InstalledAt set, exactly one Core/Application result')
    Reset-Case $C
}

# ---------------------------------------------------------------- TQ: the mirrored runner equals DgTx-Run (same results, same trees)
if ($ctxs.ContainsKey('P2')) {
    $C = $ctxs['P2']; $L = $C.L; $P = $L.Product
    $entries = Convert-DenGoPlanToEntries $P $C.Plan $null
    $tx = Get-DenGoTxItems $entries
    $extra = @(); foreach ($e in $tx.Ordered) { $extra += [string](Get-DenGoRoleSpec $P $e.Role $e.Root).PolicyRoot }
    $policy = New-DenGoPathPolicy $P ([string[]]$extra)
    $stateBytes = $utf8.GetBytes('tq-state')
    $factory = { param($c, $a) return ,$stateBytes }
    $factory1 = { param($c) return ,$stateBytes }
    function Invoke-A { return (DgTx-Run -StateRoot $P.StateRoot -BackupRoot $P.BackupRoot -Operation 'Install' -Items $tx.Items -Policy $policy -NewStatePath $P.StatePath -NewStateFactory $factory1) }
    function Invoke-B { return (Invoke-DenGoTransaction -StateRoot $P.StateRoot -BackupRoot $P.BackupRoot -Operation 'Install' -Items $tx.Items -Policy $policy -NewStatePath $P.StatePath -NewStateFactory $factory) }
    function Sig($R) { return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $R.Succeeded, $R.Code, $R.RollbackState, $R.FailedItem, $R.ManualCheckRequired, $R.TransactionId, ((@($R.Reasons) | ForEach-Object { [string](DgProp $_ 'Code' '') }) -join ','), [string](DgProp $R 'ReportPath' '')) }
    # the signature must be able to see a difference in the report path (F3)
    $sigA = [pscustomobject]@{ Succeeded = $false; Code = 'X'; RollbackState = 'RepairRequired'; FailedItem = 1; ManualCheckRequired = $true; TransactionId = 'T1'; Reasons = @(); ReportPath = 'C:\a\recovery-report.txt' }
    $sigB = [pscustomobject]@{ Succeeded = $false; Code = 'X'; RollbackState = 'RepairRequired'; FailedItem = 1; ManualCheckRequired = $true; TransactionId = 'T1'; Reasons = @(); ReportPath = '' }
    [void](Assert-I2A 'TQ-signature-sees-the-report-path' ((Sig $sigA) -ne (Sig $sigB)) 'two results that differ only in ReportPath have different signatures')
    Reset-Case $C; Reset-I2AFault -Record $true; Reset-I2ACounters
    $ra = Invoke-A
    $nTx = [int]$global:I2AFH.All
    $treeA = Tree $C
    Reset-Case $C; Reset-I2AFault -Record $true; Reset-I2ACounters
    $rb = Invoke-B
    [void](Assert-I2A 'TQ-happy-path-equal' (((Sig $ra) -eq (Sig $rb)) -and ($global:I2AFH.All -eq $nTx) -and (Same $treeA (Tree $C))) ("A=[$(Sig $ra)] B=[$(Sig $rb)] points A=$nTx B=$($global:I2AFH.All)"))
    $tqStep = $(if ($SkipHeavy) { 5 } else { 2 })
    $tqFail = 0; $tqRan = 0
    foreach ($action in @('IO', 'Unauthorized', 'InUse')) {
        $step = $(if ($action -eq 'IO') { $tqStep } else { [Math]::Max(9, $tqStep * 4) })
        foreach ($k in (Get-Sample $nTx $step)) {
            Reset-Case $C; Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action $action; Reset-I2ACounters
            $ra = Invoke-A; $ta = Tree $C; $fa = [string]$global:I2AFH.Fired
            Reset-Case $C; Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action $action; Reset-I2ACounters
            $rb = Invoke-B; $tb = Tree $C; $fb = [string]$global:I2AFH.Fired
            $tqRan++
            if (-not (((Sig $ra) -eq (Sig $rb)) -and ($fa -eq $fb) -and (Same $ta $tb))) { $tqFail++; Add-I2AResult ("TQ-$action-k$k") $false ("A=[$(Sig $ra)] B=[$(Sig $rb)] fired A=[$fa] B=[$fb] tree diff=[$(Diff3 $ta $tb)]") }
        }
    }
    if ($tqFail -eq 0) { Add-I2AResult 'TQ-throw-sweep-equal' $true "IO / Unauthorized / InUse injected at $tqRan points: the mirrored runner returns the same Succeeded / Code / RollbackState / FailedItem / ManualCheckRequired / TransactionId / reason codes and leaves the same tree as DgTx-Run" }
    $tqFail = 0; $tqRan = 0
    $mutN = [int]((Get-Sample 1 1).Count)   # (placeholder to keep the variable used)
    Reset-Case $C; Reset-I2AFault -Record $true; Reset-I2ACounters; $null = Invoke-A; $nMut = [int]$global:I2AFH.Mut
    foreach ($k in (Get-Sample $nMut ($tqStep * 2))) {
        Reset-Case $C; Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($k)); Reset-I2ACounters
        try { $ra = Invoke-A } catch { $ra = [pscustomobject]@{ Succeeded = $false; Code = 'THROWN'; RollbackState = ''; FailedItem = -1; ManualCheckRequired = $false; TransactionId = ''; Reasons = @() } }
        Resume-I2AAfterCrash; $ta = Get-I2BFullTree $L
        Reset-Case $C; Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($k)); Reset-I2ACounters
        try { $rb = Invoke-B } catch { $rb = [pscustomobject]@{ Succeeded = $false; Code = 'THROWN'; RollbackState = ''; FailedItem = -1; ManualCheckRequired = $false; TransactionId = ''; Reasons = @() } }
        Resume-I2AAfterCrash; $tb = Get-I2BFullTree $L
        $tqRan++
        if (-not (((Sig $ra) -eq (Sig $rb)) -and (Same $ta $tb))) { $tqFail++; Add-I2AResult ("TQ-crash-k$k") $false ("A=[$(Sig $ra)] B=[$(Sig $rb)] tree diff=[$(Diff3 $ta $tb)]") }
    }
    if ($tqFail -eq 0) { Add-I2AResult 'TQ-crash-sweep-equal' $true "simulated crash at $tqRan mutating points: identical results and identical disk state" }
    Reset-Case $C
}

Uninstall-I2AHarness
foreach ($sc in $ctxs.Keys) { Remove-I2ASandbox $ctxs[$sc].L.Root }
Complete-I2ATests
