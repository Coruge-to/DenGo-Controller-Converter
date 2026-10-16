# I2-C fault-injection suite for the product uninstall (Invoke-DenGoProductUninstall): happy-path oracle, crash sweep (every mutating point),
# exception sweep (-FullThrow: every point), named cases (blocking classes, residuals that allow Completed, Diverged, ClosedRecords, PCSX2, Earlier[],
# recovery failures, AlreadyUninstalled, history), H-6 end-to-end (six cases), the "no old-generation backup" proof,
# the generation-2 sweeps with a previous uninstalled-state (crash + exception, every point) and the AlreadyUninstalled reconfirmation sweeps (section I).
# It hashes its own input files (input-sha256-before/after.txt, input-verify.txt in the evidence directory).
# Everything runs in sandboxes under %TEMP%; the real uninstaller, registry, BVE, PCSX2 and RPCS3 are never touched.
param([int]$Stride = 1, [string]$EvidenceDir = '', [switch]$SkipHeavy, [switch]$SkipSweeps, [switch]$FullThrow)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2C-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-i2c-fault.jsonl'
Write-Host ('Evidence directory: ' + $EvidenceDir)
# The result of this run is only valid for the exact input files below: they are hashed now and again at the end.
$faultStartedUtc = [DateTime]::UtcNow.ToString('o')
$inputBefore = Get-I2CInputManifest
Write-I2CInputManifest (Join-Path $EvidenceDir 'input-sha256-before.txt') $inputBefore 'before'
Use-I2BHarnessIds

function Get-Sample([int]$Count, [int]$Step) {
    $list = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Count; $i += [Math]::Max(1, $Step)) { [void]$list.Add($i) }
    if (($Count -gt 0) -and ($list[$list.Count - 1] -ne $Count)) { [void]$list.Add($Count) }
    return , @($list)
}

# ---------------------------------------------------------------- the world: one installed generation (T0), built BEFORE the harness is installed is not possible
# (the generation must carry harness ids), so the harness is installed first and the generation is installed under it.
$L = New-I2CCase 'i2c-fault'
Assert-I2AInsideSandbox $L.Root @($L.Local, $L.Public, $L.Bve5, $L.Bve6, $L.Rpcs3, $L.Pcsx2Inis, $L.Desktop, $L.Stage, $L.Product.StatePath)
$P = $L.Product
Install-I2AHarness
Reset-I2AFault; Reset-I2ACounters
$rInstall = Install-I2CGeneration $L
[void](Assert-I2A 'F00-generation-installed-under-the-harness' ($rInstall.Succeeded -eq $true) "install: succeeded=$($rInstall.Succeeded) code=$($rInstall.ErrorCode)")
$T0snap = Save-I2ATree $L.Root
$T0 = Get-I2CTree $L -NormalizeState
$T0full = Get-I2BFullTree $L
$ymlPath = Get-I2CLeafPath $L 'Den-Go-Controller.yml'
function Reset-World { Release-I2AHeld; Restore-I2ATree $L.Root $T0snap; Reset-I2AFault; $global:I2AFH.IdCounter = 1; $global:I2AFH.Tick = 100 }
function Run-Uninstall([bool]$Incl = $true, [scriptblock]$Gate = $null, [hashtable]$Extra = @{}) {
    try { return (Invoke-I2CUninstall $L $Incl $Gate $Extra) }
    catch { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = [string]$_.Exception.Message; RollbackState = 'NotStarted'; ManualCheckRequired = $false; Recovery = $null; Reasons = @(); Blocking = @(); ResidualFiles = @(); AlreadyUninstalled = $false; UninstalledState = $null; ReportPath = ''; TransactionId = ''; StateCommitted = $false } }
}
function Tree { return (Get-I2CTree $L -NormalizeState) }
function Marker { return [System.IO.File]::Exists((Get-I2CUmPath $L)) }
function Clean { return ((Cnt (Test-I2CLeftovers $L)) -eq 0) }

# ---------------------------------------------------------------- independent oracle for T1 (built from the fixture spec only)
$removedKeys = New-Object System.Collections.ArrayList
foreach ($s in (Get-I2BItemSpecs $L)) { if ($s.Pl -in @('Core', 'BVE5', 'BVE6', 'BveEX Current', 'AtsEX Legacy')) { [void]$removedKeys.Add('f:' + (Get-I2CRel $L $s.Dest)) } }
[void]$removedKeys.Add('f:' + (Get-I2CRel $L $P.ShortcutPath))
$ymlKey = 'f:' + (Get-I2CRel $L $ymlPath)
$ymlOriginalSha = Get-I2AContentSha 'user-original-yml'
function Test-T1Oracle($Pre, $Post) {
    $problems = New-Object System.Collections.ArrayList
    foreach ($d in @(Compare-I2ATree $Pre $Post)) {
        $kind = $d.Substring(0, 1); $key = $d.Substring(1)
        if ($key.StartsWith('d:')) { [void]$problems.Add('folder changed: ' + $key); continue }     # folders are never removed or created by an uninstall
        if ($key -eq 'x:is') { if (-not ($kind -eq '~' -and $Post[$key] -eq '<none>')) { [void]$problems.Add('installed-state not retired: ' + $d) }; continue }
        if ($key -eq 'x:us') { if (-not ($kind -eq '~' -and $Post[$key] -eq 'NEW')) { [void]$problems.Add('uninstalled-state not new: ' + $d) }; continue }
        if ($key -eq $ymlKey) { if (-not ($kind -eq '~' -and $Post[$key] -eq $ymlOriginalSha)) { [void]$problems.Add('profile is not the original: ' + $d) }; continue }
        if ($kind -eq '-' -and $removedKeys -contains $key) { continue }
        [void]$problems.Add('unexpected: ' + $d)
    }
    foreach ($k in $removedKeys) { if ($Post.ContainsKey($k)) { [void]$problems.Add('not removed: ' + $k) } }
    foreach ($k in @($Pre.Keys)) { if ($k -like 'f:pcsx2\*') { if (-not ($Post.ContainsKey($k) -and ($Post[$k] -eq $Pre[$k]))) { [void]$problems.Add('PCSX2 file changed: ' + $k) } } }
    foreach ($k in @($Pre.Keys)) { if ($k -like 'f:guard\*' -or $k -like 'f:src\*') { if (-not ($Post.ContainsKey($k) -and ($Post[$k] -eq $Pre[$k]))) { [void]$problems.Add('input file changed: ' + $k) } } }
    return , @($problems)
}

# ---------------------------------------------------------------- A. happy path
Reset-World
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = 1
$r = Run-Uninstall
$fh = $global:I2AFH
$MutN = [int]$fh.Mut; $AllN = [int]$fh.All; $MutLabels = @($fh.MutLabels)
$T1 = Tree
$problems = Test-T1Oracle $T0 $T1
[void](Assert-I2A 'A-happy-path' (($r.Succeeded -eq $true) -and (Clean) -and (-not (Marker))) "Succeeded=$($r.Succeeded) code=$($r.ErrorCode) msg=$($r.ErrorMessage) mutPoints=$MutN allPoints=$AllN")
[void](Assert-I2A 'A-oracle-T1' ($problems.Count -eq 0) ('expected-vs-actual: ' + [string]::Join('; ', [string[]]@($problems | Select-Object -First 5))))
$us = Get-I2CUs $L
$hist = @(Get-I2CHistoryFiles $L)
[void](Assert-I2A 'A-installed-state-archived-and-deleted' ((-not [System.IO.File]::Exists($P.StatePath)) -and (@($hist | Where-Object { $_ -like '*\installed-state.*.json' }).Count -eq 1) -and ((Get-I2AFileSha $us.ClosedGeneration.ArchivedStatePath) -eq $us.ClosedGeneration.ArchivedStateSha256.ToUpperInvariant())) 'one content-addressed archive; its SHA is the one recorded in ClosedGeneration')
[void](Assert-I2A 'A-journal-history' ((@(Get-I2CHistoryFiles $L 'txn-*.committed.jsonl').Count -eq 2) -and (@(Get-I2CHistoryFiles $L 'txn-*.rolledback.jsonl').Count -eq 0)) 'install + uninstall committed journals in history')
$regPaths = @(); $hj = @(Get-I2CHistoryFiles $L 'txn-T0002.committed.jsonl'); if ($hj.Count -eq 1) { $regPaths = @((DgJournal-Parse $hj[0]).Records | Where-Object { $_.stage -eq 'Register' } | ForEach-Object { [string]$_.path }) }
[void](Assert-I2A 'A-only-fixed-leaves-registered' (($regPaths.Count -ge 10) -and (@($regPaths | Where-Object { $_ -match 'Pcsx2|LilyPad|Uninstall\.exe|UninstallRollback|Other|g1\.txt' }).Count -eq 0)) "registered $($regPaths.Count) paths, none under PCSX2 / LilyPad / Uninstall.exe / neighbours")
[void](Assert-I2A 'A-installed-state-delete-is-the-last-item-and-archive-before-it' (($regPaths.Count -ge 2) -and ($regPaths[-1] -like '*installed-state.json') -and ($regPaths[-2] -like '*history\installed-state.*.json')) ('last two registered: ' + ($regPaths[-2..-1] -join ' , ')))
$usedOk = (@($us.UsedBackups).Count -eq 1) -and ($us.UsedBackups[0].Path -like '*\T0001\*')
[void](Assert-I2A 'A-restore-used-the-origin-of-this-generation' $usedOk 'the profile was restored from the generation''s own Origin backup')
Add-I2AEvidence @{ id = 'A-happy'; mutPoints = $MutN; allPoints = $AllN; tree = (Get-I2ATreeDigest $T1) }

# ---------------------------------------------------------------- B/C. crash sweep and exception sweep
function Invoke-CrashCase([string]$Id, [hashtable]$Fault) {
    Reset-World
    Reset-I2AFault @Fault; $global:I2AFH.IdCounter = 1
    $null = Run-Uninstall
    $fired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $faultMap = Tree
    $markerAtFault = Marker
    $forward = ($faultMap['x:us'] -eq 'NEW')
    $isGone = (-not [System.IO.File]::Exists($P.StatePath))
    $r1 = Run-Uninstall
    $map1 = Tree
    $okFirst = $true; $why = ''
    if ($markerAtFault) {
        $expect = $(if ($forward) { $T1 } else { $T0 })
        $okFirst = (($r1.Succeeded -eq $false) -and ($r1.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (Same $expect $map1) -and ($r1.Recovery.Outcome -eq $(if ($forward) { 'RolledForward' } else { 'RolledBack' })))
        $why = "recovery outcome=$($r1.Recovery.Outcome) code=$($r1.ErrorCode) tree==$(if ($forward) { 'T1' } else { 'T0' }):$(Same $expect $map1) [$(Diff3 $expect $map1)]"
    } elseif ($forward -and $isGone) {
        $okFirst = (($r1.Succeeded -eq $true) -and ($r1.AlreadyUninstalled -eq $true) -and (Same $T1 $map1))
        $why = "state committed, no marker: AlreadyUninstalled succeeded=$($r1.Succeeded) already=$($r1.AlreadyUninstalled) code=$($r1.ErrorCode) tree==T1:$(Same $T1 $map1)"
    } else {
        $okFirst = (($r1.Succeeded -eq $true) -and (Same $T1 $map1))
        $why = "no marker, nothing committed: uninstall ran. succeeded=$($r1.Succeeded) code=$($r1.ErrorCode) tree==T1:$(Same $T1 $map1) [$(Diff3 $T1 $map1)]"
    }
    $r2 = Run-Uninstall
    $map2 = Tree
    $okSecond = (($r2.Succeeded -eq $true) -and (Same $T1 $map2) -and (Clean) -and (-not (Marker)))
    $usedOld = $false
    $usNow = Get-I2CUs $L
    if ($null -ne $usNow) { foreach ($u in @($usNow.UsedBackups)) { if ($u.Path -notlike '*\T0001\*') { $usedOld = $true } } }
    $pass = (($fired.Length -gt 0) -and $okFirst -and $okSecond -and (-not $usedOld))
    Add-I2AEvidence @{ id = $Id; fault = $fired; markerAtFault = $markerAtFault; forward = $forward; firstOutcome = [string]$r1.ErrorCode; pass = $pass; tree = (Get-I2ATreeDigest $map2) }
    return @{ Pass = $pass; Detail = ("fired=$fired markerAtFault=$markerAtFault forward=$forward first:[$why] second: succeeded=$($r2.Succeeded) already=$($r2.AlreadyUninstalled) tree==T1:$(Same $T1 $map2) clean=$(Clean) marker=$(Marker) usedOld=$usedOld") }
}
if (-not $SkipSweeps) {
    $step = $Stride
    if ($SkipHeavy) { $step = [Math]::Max($Stride, 3) }
    $fail = 0; $ran = 0
    foreach ($k in (Get-Sample $MutN $step)) {
        $res = Invoke-CrashCase ("TC-k$k") @{ Mode = 'CrashMut'; Targets = [int[]]@($k) }
        $ran++
        if (-not $res.Pass) { $fail++; Add-I2AResult ("TC-k$k") $false ($MutLabels[$k - 1] + ' :: ' + $res.Detail) }
    }
    if ($fail -eq 0) { Add-I2AResult 'TC-sweep' $true "crash + product re-run at $ran of $MutN mutating points: recovery rolled back / forward, the next run uninstalled (or re-confirmed), trees matched T0 / T1, no marker left, no old-generation backup used" }
    if ($step -eq 1) { [void](Assert-I2A 'TC-covers-every-mutating-point' ($ran -eq $MutN) "swept $ran of $MutN mutating points") }
    $failT = 0; $ranT = 0
    $tStep = [Math]::Max($step, $(if ($AllN -gt 900) { 7 } elseif ($AllN -gt 500) { 4 } elseif ($AllN -gt 250) { 2 } else { 1 }))
    if ($FullThrow) { $tStep = 1 }
    foreach ($k in (Get-Sample $AllN $tStep)) {
        Reset-World
        Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; $global:I2AFH.IdCounter = 1
        $r = Run-Uninstall
        $map = Tree
        $rb = [string]$r.RollbackState
        $expectOk = $false
        if ($r.Succeeded) { $expectOk = (Same $T1 $map) }
        elseif (@('RolledBack', 'NotStarted', 'NotNeeded') -contains $rb) { $expectOk = (Same $T0 $map) }
        $okT = ($expectOk -and (Clean) -and (([string]$global:I2AFH.Fired).Length -gt 0) -and (-not (Marker)))
        $ranT++
        if (-not $okT) { $failT++; Add-I2AResult ("TB-k$k") $false ("fired=$($global:I2AFH.Fired) code=$($r.ErrorCode) rb=$rb succeeded=$($r.Succeeded) diffT0=[$(Diff3 $T0 $map)] diffT1=[$(Diff3 $T1 $map)] left=[$([string]::Join(',', [string[]]@(Test-I2CLeftovers $L)))] marker=$(Marker)") }
    }
    if ($failT -eq 0) { Add-I2AResult 'TB-sweep' $true "IO exception injected at $ranT of $AllN points$(if ($FullThrow) { ' (FullThrow: every point)' }): always a rollback (tree == T0, state untouched), a committed uninstall (tree == T1) or a refusal before any change; no marker or leftover" }
    if ($FullThrow) { [void](Assert-I2A 'TB-fullthrow-covers-every-point' ($ranT -eq $AllN) "swept $ranT of $AllN exception points") }
    Add-I2AEvidence @{ id = 'SWEEP-COUNTS-main'; mutPoints = $MutN; crashSwept = $ran; allPoints = $AllN; throwSwept = $ranT; fullThrow = [bool]$FullThrow; stride = $Stride; skipHeavy = [bool]$SkipHeavy }
}

# ---------------------------------------------------------------- D. named cases
function Assert-ZeroChange([string]$Id, $R, [string]$Code, [string]$Detail) {
    $full = Get-I2BFullTree $L
    $same = Same $T0full $full
    [void](Assert-I2A $Id (($R.Succeeded -eq $false) -and ($R.ErrorCode -eq $Code) -and $same -and (-not (Marker))) ("$Detail :: succeeded=$($R.Succeeded) code=$($R.ErrorCode) msg=[$($R.ErrorMessage)] ZERO changes (every file, folder, journal, marker and backup): $same [$(Diff3 $T0full $full)]"))
}
function Test-NoUninstallStateWritten { return ((-not [System.IO.File]::Exists((Get-I2CUsPath $L))) -and ((Cnt (Get-I2CHistoryFiles $L 'installed-state.*.json')) -eq 0)) }

# --- blocking classes: zero changes, no marker / journal / backup (D-C4 a, D-C5, D-C6, D-C7)
$blockCases = @(
    @('N01-unknown-ownership', 'UnsafeOrUnknown', { Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'DenGoControllerConverter.exe' 'Core'; $r.Ownership = 'Mystery' } }),
    @('N02-owned-record-not-a-denGo-leaf', 'UnsafeOrUnknown', { Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'DenGoControllerConverter.exe' 'Core'; $r.Destination = (Join-Path $L.Guard 'g1.txt') } }),
    @('N03-owned-root-unproven-bve-exe-gone', 'OwnedRootUnverified', { [System.IO.File]::Delete((Join-Path $L.Bve5 'BveTs.exe')) }),
    @('N04-owned-volume-unavailable', 'OwnedRootUnverified', { $dr = Get-I2CFreeDriveLetter; Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'DenGoControllerConverter.dll' 'BVE6'; $r.Destination = ($dr + ':\Bve\Input Devices\DenGoControllerConverter.dll') } }),
    @('N05-origin-backup-missing', 'ReplacedExistingBackupInvalid', { $o = Get-I2CIs $L; [System.IO.File]::Delete((Get-I2CRecord $o 'Den-Go-Controller.yml').Backup) }),
    @('N06-origin-backup-tampered', 'ReplacedExistingBackupInvalid', { $o = Get-I2CIs $L; [System.IO.File]::WriteAllText((Get-I2CRecord $o 'Den-Go-Controller.yml').Backup, 'tampered', $script:Utf8) }),
    @('N07-origin-not-backups0', 'ReplacedExistingBackupInvalid', { Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'Den-Go-Controller.yml'; $r.Backups = [object[]]@() } }),
    @('N08-origin-sha-mismatch-record', 'ReplacedExistingBackupInvalid', { Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'Den-Go-Controller.yml'; $r.BeforeSHA256 = ('cd' * 32) } }),
    @('N09-origin-belongs-to-a-closed-generation', 'ReplacedExistingBackupInvalid', { $usOld = [pscustomobject][ordered]@{ SchemaVersion = 1; StateRevision = 2; State = 'Uninstalled'; UninstalledAt = '2026-01-01T00:00:00.0000000+09:00'; UninstallTransactionId = 'T9999'; ClosedGeneration = [pscustomobject]@{ GenerationId = ('ab' * 32); LastInstallTransactionId = 'T0005' } }; Write-I2CJson (Get-I2CUsPath $L) $usOld }),
    @('N10-contamination-blocks-a-needed-restore', 'ContaminationBlocksRestore', { Write-I2CLegacyUninstalledState $L }),
    @('N11-history-archive-collision', 'HistoryArchiveCollision', { $o = Get-I2CIs $L; $sha = (Get-I2AFileSha $P.StatePath).ToLowerInvariant(); [System.IO.Directory]::CreateDirectory((Join-Path $P.StateRoot 'history')) | Out-Null; [System.IO.File]::WriteAllText((Join-Path $P.StateRoot ('history\installed-state.' + $sha + '.json')), 'not the same', $script:Utf8) }),
    @('N12-shortcut-origin-invalid', 'ShortcutBackupInvalid', { Edit-I2CInstalledState $L { param($o) $o.Shortcut.PreExisted = $true; $o.Shortcut.Backup = (Join-Path $P.BackupRoot 'T0009\0000.bak'); $o.Shortcut.BackupSHA256 = ('ee' * 32) } }),
    @('N13-installed-state-ambiguous-duplicate', 'InstalledStateAmbiguous', { Edit-I2CInstalledState $L { param($o) $o.Files = [object[]]@(@($o.Files) + @($o.Files[0])) } }),
    @('N14-installed-state-corrupt', 'InstalledStateUnreadable', { [System.IO.File]::WriteAllText($P.StatePath, '{ not json', $script:Utf8) }),
    @('N15-installed-state-wrong-schema', 'InstalledStateUnreadable', { Edit-I2CInstalledState $L { param($o) $o.SchemaVersion = 7 } }),
    @('N16-install-marker-present-foreign', 'RecoveryRequired', { [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'installing.json'), '{"State":"Installing","TxnId":"T0007","Operation":"Install","SchemaVersion":1}', $script:Utf8) }))
foreach ($c in $blockCases) {
    Reset-World
    & $c[2]
    $beforeFull = Get-I2BFullTree $L
    $r = Run-Uninstall
    $afterFull = Get-I2BFullTree $L
    $zero = Same $beforeFull $afterFull
    $codes = Get-I2CReasonCodes $r
    [void](Assert-I2A ('D-' + $c[0]) (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq $c[1]) -and $zero) ("code=$($r.ErrorCode) (want $($c[1])) succeeded=$($r.Succeeded) zero-change=$zero [$(Diff3 $beforeFull $afterFull)] msg=[$($r.ErrorMessage)] reasons=[$($codes -join ',')]"))
    [void](Assert-I2A ('D-' + $c[0] + '-no-registration-signal') (($r.StateCommitted -ne $true) -and (@(Get-I2CHistoryFiles $L 'installed-state.*.json').Count -eq @($beforeFull.Keys | Where-Object { $_ -like '*\history\installed-state.*.json' }).Count) -and ((-not [System.IO.File]::Exists((Get-I2CUsPath $L))) -or ((Get-I2AFileSha (Get-I2CUsPath $L)) -eq $beforeFull['f:' + (Get-I2CRel $L (Get-I2CUsPath $L))]))) 'no uninstalled-state was committed and no installed-state archive was added: the wrapper must not unregister or self-delete')
    if ($c[0] -eq 'N16-install-marker-present-foreign') { [void](Assert-I2A 'D-N16-foreign-reason' (($codes -contains 'ForeignOperationMarker') -and ($r.ManualCheckRequired -eq $true) -and [System.IO.File]::Exists((Join-Path $P.StateRoot 'installing.json'))) "reasons=[$($codes -join ',')] marker kept") }
}
# the process gate (A and B)
Reset-World
$before = Get-I2BFullTree $L
$r = Run-Uninstall $true { param($phase) throw 'Close target processes before uninstall: DenGoControllerConverter.exe' }
[void](Assert-I2A 'D-N17-process-gate-A' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'BlockedByRunningProcesses') -and (Same $before (Get-I2BFullTree $L)) -and ($r.LockAcquired -eq $true)) "code=$($r.ErrorCode): refused before anything was read or written")
$t = DgLock-TryAcquire (Get-DenGoLockName) 'Explicit'
[void](Assert-I2A 'D-N17-lock-released-after-gate-A' ($t.Acquired -eq $true) 'the lock is free again')
[void](DgLock-Release (Get-DenGoLockName))
Reset-World
$r = Run-Uninstall $true { param($phase) if ($phase -eq 'B') { throw 'Close target processes before uninstall: BveTs.exe' } }
$map = Tree
[void](Assert-I2A 'D-N18-process-gate-B-rolls-everything-back' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'BlockedByRunningProcesses') -and ($r.RollbackState -eq 'RolledBack') -and (Same $T0 $map) -and (Clean) -and (Test-NoUninstallStateWritten)) "code=$($r.ErrorCode) rb=$($r.RollbackState) diff=[$(Diff3 $T0 $map)]")

# --- Completed with intentional residuals (D-C7 allowed classes)
Reset-World
$edited = Get-I2CLeafPath $L 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll'
[System.IO.File]::WriteAllText($edited, 'the user replaced this file', $script:Utf8)
$editedSha = Get-I2AFileSha $edited
$r = Run-Uninstall
$map = Tree
$us = Get-I2CUs $L
$diverged = @($us.ResidualFiles | Where-Object { $_.Path -eq $edited })
[void](Assert-I2A 'D-N20-diverged-file-never-changed' (($r.Succeeded -eq $true) -and ([System.IO.File]::Exists($edited)) -and ((Get-I2AFileSha $edited) -eq $editedSha) -and ($diverged.Count -eq 1) -and ($diverged[0].Disposition -eq 'PreserveModified') -and ($diverged[0].ReviewRecommended -eq $true)) "Succeeded=$($r.Succeeded) edited file kept byte-identical; recorded as a residual with a reason ($($diverged.Count))")
[void](Assert-I2A 'D-N20-manual-check-recorded-completed-kept' (($us.ManualCheckRequired -eq $true) -and ($r.ManualCheckRequired -eq $true) -and (@($us.ManualCheckReasons) -contains 'ResidualFilesNeedReview') -and ($r.ResidualFiles.Count -ge 1)) 'ManualCheckRequired is recorded; the run is still a success (no fourth state)')
[void](Assert-I2A 'D-N20-everything-else-removed' ((-not [System.IO.File]::Exists($P.AppExe)) -and (-not [System.IO.File]::Exists($P.StatePath)) -and (Test-I2CUsValid $L)) 'the rest of the generation was removed and the state retired')
# user-owned records (PreservedUserFile / NotManaged / NotInstalled): the file at the destination is never touched, even with -IncludeInputProfiles
foreach ($own in 'PreservedUserFile', 'NotManaged', 'NotInstalled') {
    Reset-World
    $shaBefore = Get-I2AFileSha $ymlPath
    Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'Den-Go-Controller.yml'; $r.Ownership = $own }
    $r = Run-Uninstall
    $us = Get-I2CUs $L
    $res = @($us.ResidualFiles | Where-Object { $_.Path -eq $ymlPath })
    $wantDisp = $(if ($own -eq 'PreservedUserFile') { 'PreserveUserFile' } else { 'PreserveNotOwned' })
    [void](Assert-I2A ('D-N22-' + $own + '-never-touched') (($r.Succeeded -eq $true) -and [System.IO.File]::Exists($ymlPath) -and ((Get-I2AFileSha $ymlPath) -eq $shaBefore) -and ($res.Count -eq 1) -and ($res[0].Disposition -eq $wantDisp) -and (@($us.Items | Where-Object { $_.Destination -eq $ymlPath -and $_.Decision -in @('Remove', 'Restore') }).Count -eq 0) -and ($us.ManualCheckRequired -eq $false)) "Completed; the file is byte-identical; residual '$wantDisp' recorded; no manual check")
}# kept profile (no -IncludeInputProfiles): a residual, Completed
Reset-World
$r = Run-Uninstall $false
$us = Get-I2CUs $L
$ymlBefore = 'x'
[void](Assert-I2A 'D-N24-profile-kept-by-default' (($r.Succeeded -eq $true) -and ([System.IO.File]::Exists($ymlPath)) -and (@($us.ResidualFiles | Where-Object { $_.Disposition -eq 'KeepProfile' }).Count -eq 1) -and ($us.InputProfilesPreserved -eq $true) -and ($us.ManualCheckRequired -eq $false)) 'InputProfile kept: Completed, residual recorded, no manual check')
[void](Assert-I2A 'D-N24-kept-profile-is-still-the-denGo-profile-and-origin-not-used' (($us.UsedBackups.Count -eq 0) -and (@($us.UnusedBackups | Where-Object { $_.Destination -eq $ymlPath }).Count -ge 1)) 'no backup was used; the Origin is listed as unused')
# ClosedRecords: never applied
Reset-World
$closedFile = Join-Path $L.Guard 'closed-target.dll'
[System.IO.File]::WriteAllText($closedFile, 'a real file at a closed record', $script:Utf8)
Edit-I2CInstalledState $L { param($o) Set-I2CProperty $o 'ClosedRecords' ([object[]]@([pscustomobject]@{ Record = (New-I2CRecord 'BVE6' 'Caller' $closedFile 'CreatedByInstaller' ('34' * 32)); ClosedAt = '2026-01-01T00:00:00.0000000+09:00'; ClosedTransactionId = 'T0001'; Reason = 'NoOwnershipAndMissing' })) }
$closedSha = Get-I2AFileSha $closedFile
$r = Run-Uninstall
$us = Get-I2CUs $L
[void](Assert-I2A 'D-N25-closed-records-untouched' (($r.Succeeded -eq $true) -and ((Get-I2AFileSha $closedFile) -eq $closedSha) -and (@($us.ClosedRecords).Count -eq 1) -and ($us.ClosedRecords[0].Record.Destination -eq $closedFile) -and (@($us.Items | Where-Object { $_.Destination -eq $closedFile }).Count -eq 0)) 'a closed record is history only: the file is unchanged and is not an item; the record is carried into the uninstalled state')
# PCSX2 / LilyPad: deferred, never touched
Reset-World
$lily = Join-Path $L.Pcsx2Inis 'LilyPad.ini'
$lilyBak = Join-Path $P.BackupRoot 'T0001\0099.bak'
[System.IO.File]::WriteAllText($lilyBak, 'old lilypad', $script:Utf8)
Add-I2CRecord $L (New-I2CRecord 'PCSX2' 'EffectiveInputProfile' $lily 'ReplacedExisting' (Get-I2AFileSha $lily) (Get-I2AFileSha $lilyBak) $lilyBak $true)
Add-I2CRecord $L (New-I2CRecord 'PCSX2' 'InputProfile' (Join-Path $L.Pcsx2Inis 'DenGo-Controller-Converter.lily') 'CreatedByInstaller' ('56' * 32))
$pcsx2Pre = @{}; foreach ($f in [System.IO.Directory]::GetFiles($L.Pcsx2Inis)) { $pcsx2Pre[$f] = Get-I2AFileSha $f }
$r = Run-Uninstall
$us = Get-I2CUs $L
$pcsx2Same = $true; foreach ($f in $pcsx2Pre.Keys) { if (-not ([System.IO.File]::Exists($f) -and (Get-I2AFileSha $f) -eq $pcsx2Pre[$f])) { $pcsx2Same = $false } }
[void](Assert-I2A 'D-N26-pcsx2-lilypad-untouched' (($r.Succeeded -eq $true) -and $pcsx2Same -and ([System.IO.File]::Exists($lilyBak)) -and (@($us.DeferredRecords).Count -eq 2) -and (@($us.ClosedRecords).Count -eq 0) -and ($us.Counts.Deferred -eq 2)) "Completed; every PCSX2 file byte-identical; both records in DeferredRecords, none in ClosedRecords")
$regs = @(); $hj = @(Get-I2CHistoryFiles $L 'txn-T0002.committed.jsonl'); if ($hj.Count -eq 1) { $regs = @((DgJournal-Parse $hj[0]).Records | Where-Object { $_.stage -eq 'Register' } | ForEach-Object { [string]$_.path }) }
[void](Assert-I2A 'D-N26-pcsx2-never-registered-or-restored' (($regs.Count -gt 0) -and (@($regs | Where-Object { $_ -match 'Pcsx2|LilyPad' }).Count -eq 0)) 'no PCSX2 path was registered in the journal: no PCSX2 allowed root exists')
# a PCSX2 record alone never stops the uninstall (and a garbage PCSX2 record neither)
Reset-World
Add-I2CRecord $L (New-I2CRecord 'PCSX2' 'InputProfile' 'garbage' 'WhatIsThis' 'zz')
$r = Run-Uninstall
[void](Assert-I2A 'D-N27-garbage-pcsx2-record-does-not-fail-the-uninstall' ($r.Succeeded -eq $true) "code=$($r.ErrorCode)")

# --- shortcut contract through the whole run
Reset-World
[System.IO.File]::Delete($P.ShortcutPath)
$r = Run-Uninstall
[void](Assert-I2A 'D-N30-shortcut-already-gone' (($r.Succeeded -eq $true) -and (-not [System.IO.File]::Exists($P.ShortcutPath))) 'a missing shortcut is not recreated and does not stop the uninstall')
Reset-World
$shell = New-Object -ComObject WScript.Shell
$sl = $shell.CreateShortcut($P.ShortcutPath); $sl.TargetPath = 'C:\Windows\System32\notepad.exe'; $sl.Save()
$editedSc = Get-I2AFileSha $P.ShortcutPath
$r = Run-Uninstall
$us = Get-I2CUs $L
[void](Assert-I2A 'D-N31-edited-shortcut-diverged-never-deleted' (($r.Succeeded -eq $true) -and ([System.IO.File]::Exists($P.ShortcutPath)) -and ((Get-I2AFileSha $P.ShortcutPath) -eq $editedSc) -and (@($us.Shortcuts | Where-Object { $_.Decision -eq 'Diverged' }).Count -eq 1) -and (@($us.ResidualFiles | Where-Object { $_.Kind -eq 'Shortcut' }).Count -eq 1)) 'the user-edited shortcut is untouched and reported')
# old default Desktop shortcut that merely points at the app is NOT deleted when the record does not own it
Reset-World
Edit-I2CInstalledState $L { param($o) $o.Shortcut.Created = $false }
$r = Run-Uninstall
[void](Assert-I2A 'D-N32-unowned-default-shortcut-is-not-deleted' (($r.Succeeded -eq $true) -and ([System.IO.File]::Exists($P.ShortcutPath))) 'the old "delete the Desktop shortcut that points at the app" behaviour is gone')
# E. Earlier[]
Reset-World
$oldDesktop = Join-Path $L.Root 'DesktopOld'
[System.IO.Directory]::CreateDirectory($oldDesktop) | Out-Null
$earlierPath = Join-Path $oldDesktop 'DenGo Controller Converter.lnk'
[System.IO.File]::Copy($P.ShortcutPath, $earlierPath, $true)
Edit-I2CInstalledState $L { param($o) $e = (Get-Content -Raw -LiteralPath $P.StatePath | ConvertFrom-Json).Shortcut; $e.Path = $earlierPath; Set-I2CProperty $o.Shortcut 'Earlier' ([object[]]@($e)) }
$r = Run-Uninstall
[void](Assert-I2A 'D-N33-earlier-desktop-shortcut-removed' (($r.Succeeded -eq $true) -and (-not [System.IO.File]::Exists($earlierPath)) -and (-not [System.IO.File]::Exists($P.ShortcutPath))) 'an Earlier[] shortcut whose Facts match is removed like the current one')
Reset-World
[System.IO.Directory]::CreateDirectory($oldDesktop) | Out-Null
[System.IO.File]::Copy($P.ShortcutPath, $earlierPath, $true)
$sl = $shell.CreateShortcut($earlierPath); $sl.TargetPath = 'C:\Windows\System32\notepad.exe'; $sl.Save()
$earlierSha = Get-I2AFileSha $earlierPath
Edit-I2CInstalledState $L { param($o) $e = (Get-Content -Raw -LiteralPath $P.StatePath | ConvertFrom-Json).Shortcut; $e.Path = $earlierPath; Set-I2CProperty $o.Shortcut 'Earlier' ([object[]]@($e)) }
$r = Run-Uninstall
[void](Assert-I2A 'D-N34-earlier-edited-shortcut-left-alone' (($r.Succeeded -eq $true) -and ([System.IO.File]::Exists($earlierPath)) -and ((Get-I2AFileSha $earlierPath) -eq $earlierSha) -and (-not [System.IO.File]::Exists($P.ShortcutPath))) 'an edited Earlier[] shortcut is Diverged and untouched; the current one is removed')
Reset-World
$drv = Get-I2CFreeDriveLetter
Edit-I2CInstalledState $L { param($o) $e = (Get-Content -Raw -LiteralPath $P.StatePath | ConvertFrom-Json).Shortcut; $e.Path = ($drv + ':\Users\Public\Desktop\DenGo Controller Converter.lnk'); Set-I2CProperty $o.Shortcut 'Earlier' ([object[]]@($e)) }
$beforeFull = Get-I2BFullTree $L
$r = Run-Uninstall
[void](Assert-I2A 'D-N35-earlier-on-an-unplugged-drive-fails-with-zero-change' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'OwnedRootUnverified') -and (Same $beforeFull (Get-I2BFullTree $L))) "code=$($r.ErrorCode): a DenGo-created shortcut that cannot be checked is not forgotten (reconnect the drive and run again)")
# B. a shortcut that existed before: restore the user's original (the lnk bytes of the backup)
Reset-World
$origLnk = Join-Path $L.Root 'UsersOriginal.lnk'
$o1 = $shell.CreateShortcut($origLnk); $o1.TargetPath = (Join-Path $L.Root 'UserTool.exe'); $o1.WorkingDirectory = $L.Root; $o1.Save()
$bkd = Join-Path $P.BackupRoot 'T0001'
$bkl = Join-Path $bkd '0098.bak'
[System.IO.File]::Copy($origLnk, $bkl, $true)
$bkSha = Get-I2AFileSha $bkl
Edit-I2CInstalledState $L { param($o) $o.Shortcut.PreExisted = $true; $o.Shortcut.Backup = $bkl; $o.Shortcut.BackupSHA256 = $bkSha; Set-I2CProperty $o.Shortcut 'Backups' ([object[]]@([pscustomobject]@{ TransactionId = 'T0001'; Path = $bkl; SHA256 = $bkSha })) }
$r = Run-Uninstall
[void](Assert-I2A 'D-N36-preexisting-shortcut-restored-from-origin' (($r.Succeeded -eq $true) -and [System.IO.File]::Exists($P.ShortcutPath) -and ((Get-I2AFileSha $P.ShortcutPath) -eq $bkSha)) 'PreExisted + proven Origin + unedited: the user''s original shortcut is back')

# --- recovery failures: sticky, zero change, evidence, a real report
function New-CrashedAt([string]$Pattern, [int]$Nth = 1) {
    Reset-World
    Reset-I2AFault -Mode 'Label' -Pattern $Pattern -Nth $Nth -Action 'Crash'; $global:I2AFH.IdCounter = 1
    $null = Run-Uninstall
    Resume-I2AAfterCrash
}
New-CrashedAt '^after:Journal:Verified#2$'
$crashTree = Get-I2BFullTree $L
$markerThere = Marker
$bakDir = Join-Path $P.BackupRoot 'T0002'
$bak0 = Join-Path $bakDir '0000.bak'
$bak0Bytes = [System.IO.File]::ReadAllBytes($bak0)
[System.IO.File]::Delete($bak0)
function Strip-Report($m) { $c = @{}; foreach ($k in $m.Keys) { if (-not $k.EndsWith('recovery-report.txt')) { $c[$k] = $m[$k] } }; return $c }
$beforeRec = Strip-Report (Get-I2BFullTree $L)
$r = Run-Uninstall
$reasons = Get-I2CReasonCodes $r
[void](Assert-I2A 'D-N40-recovery-backup-missing-repair-required' (($markerThere -eq $true) -and ($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.ManualCheckRequired -eq $true) -and (Same $beforeRec (Strip-Report (Get-I2BFullTree $L))) -and (Marker) -and ($reasons -contains 'BackupMissing')) "code=$($r.ErrorCode) reasons=[$($reasons -join ',')] marker kept")
$report = [string]$r.ReportPath
[void](Assert-I2A 'D-N40-report-path-is-real' (($report.Length -gt 0) -and [System.IO.File]::Exists($report) -and ($report -like '*recovery-report.txt')) "ReportPath=[$report] exists=$(if ($report.Length -gt 0) { [System.IO.File]::Exists($report) })")
$ev = @($r.Recovery.Evidence)
[void](Assert-I2A 'D-N40-manual-recovery-evidence' (($ev.Count -ge 3) -and (@($ev | Where-Object { $_.Path -and $_.ExpectedPreSha -ne $null -and $_.BackupPath -ne $null -and $_.Progress }).Count -eq $ev.Count) -and (@($ev | Where-Object { $_.ActualBackupSha -eq '<missing>' }).Count -ge 1)) "evidence rows=$($ev.Count): path, expected SHAs, current SHA, backup path / recorded / actual SHA, progress")
$r2 = Run-Uninstall
[void](Assert-I2A 'D-N40-repair-required-is-sticky-and-changes-nothing' (($r2.Succeeded -eq $false) -and ($r2.ErrorCode -eq 'RecoveryRequired') -and (Marker)) 'a second run refuses again; nothing was deleted or guessed')
[System.IO.File]::WriteAllBytes($bak0, $bak0Bytes)       # the operator restored the backup: automatic recovery resumes
$r3 = Run-Uninstall
[void](Assert-I2A 'D-N40-restoring-the-evidence-lets-recovery-resume' (($r3.Succeeded -eq $false) -and ($r3.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (-not (Marker)) -and (Same $T0 (Tree))) "code=$($r3.ErrorCode): recovery completed, tree == T0")
# tampered backup
New-CrashedAt '^after:Journal:Verified#2$'
[System.IO.File]::WriteAllText((Join-Path $P.BackupRoot 'T0002\0000.bak'), 'tampered', $script:Utf8)
$r = Run-Uninstall
[void](Assert-I2A 'D-N41-recovery-backup-sha-mismatch' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((Get-I2CReasonCodes $r) -contains 'BackupShaMismatch') -and ($r.ManualCheckRequired -eq $true) -and (Marker)) "reasons=[$((Get-I2CReasonCodes $r) -join ',')]")
# a destination that is neither pre nor post
New-CrashedAt '^after:Journal:Verified#2$'
$firstItem = @((DgJournal-Parse (Join-Path $P.StateRoot 'txn\T0002\journal.jsonl')).Records | Where-Object { $_.stage -eq 'Register' })[0].normalizedPath
[System.IO.File]::WriteAllText($firstItem, 'somebody recreated this file with other content', $script:Utf8)
$r = Run-Uninstall
[void](Assert-I2A 'D-N42-destination-unknown-sha-repair-required' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ((Get-I2CReasonCodes $r) -contains 'DestinationUnknownSha') -and ([System.IO.File]::ReadAllText($firstItem) -like 'somebody recreated*') -and (Marker)) 'the unknown file is neither deleted nor overwritten')
# the rollback itself is interrupted by a third party (RollbackIncomplete)
New-CrashedAt '^after:Journal:Verified#3$'
$bveDll = Get-I2CLeafPath $L 'DenGoControllerConverter.dll'
$victim = $L.Guard
Reset-I2AFault -Mode 'Label' -Pattern '^before:Fs-MoveNew:' -Nth 2 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:I2CVictim, 'changed by a third party after the preflight', [System.Text.Encoding]::UTF8) }
$ids = @((DgJournal-Parse (Join-Path $P.StateRoot 'txn\T0002\journal.jsonl')).Records | Where-Object { $_.stage -eq 'Register' } | ForEach-Object { [string]$_.normalizedPath })
$script:I2CVictim = $ids[0]
$r = Run-Uninstall
$rb = [string]$r.RollbackState
[void](Assert-I2A 'D-N43-rollback-incomplete-keeps-marker-and-evidence' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.ManualCheckRequired -eq $true) -and (Marker)) "code=$($r.ErrorCode) recovery=$($r.Recovery.Outcome) reasons=[$((Get-I2CReasonCodes $r) -join ',')]")
Reset-I2AFault
# an interrupted install is not recovered by the uninstaller (D-C2) - covered above (N16); also an unreadable journal
New-CrashedAt '^after:Journal:Verified#2$'
$jp = Join-Path $P.StateRoot 'txn\T0002\journal.jsonl'
$jb = [System.IO.File]::ReadAllBytes($jp); $jb[40] = [byte]($jb[40] -bxor 0x20); [System.IO.File]::WriteAllBytes($jp, $jb)
$r = Run-Uninstall
[void](Assert-I2A 'D-N44-corrupt-journal-repair-required' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and (Marker) -and ($r.ManualCheckRequired -eq $true)) "reasons=[$((Get-I2CReasonCodes $r) -join ',')]")

# --- AlreadyUninstalled (full runs)
Reset-World
$r = Run-Uninstall
$us1 = Get-I2CUs $L
$usSha1 = Get-I2AFileSha (Get-I2CUsPath $L)
$tree1 = Tree
$global:I2AFH.Tick += 50
$r2 = Run-Uninstall
$us2 = Get-I2CUs $L
$tree2 = Tree
[void](Assert-I2A 'D-N50-reconfirm-after-completed' (($r.Succeeded -eq $true) -and ($r2.Succeeded -eq $true) -and ($r2.AlreadyUninstalled -eq $true) -and (Same $tree1 $tree2)) "second run: succeeded=$($r2.Succeeded) already=$($r2.AlreadyUninstalled) code=$($r2.ErrorCode)")
[void](Assert-I2A 'D-N50-reconfirm-new-time-and-lineage' (($us2.Reconfirmation.Reconfirmed -eq $true) -and ($us2.UninstallTransactionId -ne $us1.UninstallTransactionId) -and ($us2.Reconfirmation.FromUninstallTransactionId -eq $us1.UninstallTransactionId) -and ($us2.UninstalledAt -ne $us1.UninstalledAt) -and ($us2.ClosedGeneration.GenerationId -eq $us1.ClosedGeneration.GenerationId)) 'a new UninstalledAt / transaction; the closed generation is carried over unchanged')
[void](Assert-I2A 'D-N50-old-uninstalled-state-archived' ((Test-Path (Join-Path $P.StateRoot ('history\uninstalled-state.' + $usSha1.ToLowerInvariant() + '.json'))) -and ($us2.PreviousUninstalledState.Exists -eq $true) -and ($us2.PreviousUninstalledState.Sha256 -eq $usSha1.ToLowerInvariant())) 'the previous uninstalled-state moved to history (content-addressed)')
$r3 = Run-Uninstall
[void](Assert-I2A 'D-N50-reconfirm-is-repeatable' (($r3.Succeeded -eq $true) -and ($r3.AlreadyUninstalled -eq $true)) 'a third run reconfirms again')
# residuals survive the reconfirmation (a Completed-with-residual stays visible)
Reset-World
[System.IO.File]::WriteAllText($edited, 'user file', $script:Utf8)
$r = Run-Uninstall
$r2 = Run-Uninstall
[void](Assert-I2A 'D-N51-reconfirm-carries-residuals' (($r2.AlreadyUninstalled -eq $true) -and ($r2.ResidualFiles.Count -ge 1) -and ($r2.ManualCheckRequired -eq $true)) "residuals=$($r2.ResidualFiles.Count) manual=$($r2.ManualCheckRequired): the GUI can warn again")
# ambiguous states never become AlreadyUninstalled
Reset-World
[System.IO.File]::Delete($P.StatePath)
$before = Get-I2BFullTree $L
$r = Run-Uninstall
[void](Assert-I2A 'D-N52-no-state-at-all' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'NotInstalled') -and (Same $before (Get-I2BFullTree $L))) "code=$($r.ErrorCode)")
Write-I2CLegacyUninstalledState $L
$before = Get-I2BFullTree $L
$r = Run-Uninstall
[void](Assert-I2A 'D-N53-legacy-uninstalled-state-without-installed-state' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'UninstalledStateNotReconfirmable') -and (Same $before (Get-I2BFullTree $L))) "code=$($r.ErrorCode): ambiguous, not guessed")
Reset-World
$r = Run-Uninstall
$usj = Get-I2CUs $L
$usj.ClosedGeneration.ArchivedStateSha256 = ('ef' * 32)
Write-I2CJson (Get-I2CUsPath $L) $usj
$before = Get-I2BFullTree $L
$r = Run-Uninstall
[void](Assert-I2A 'D-N54-archive-sha-mismatch-is-ambiguous' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'UninstalledStateNotReconfirmable') -and (Same $before (Get-I2BFullTree $L))) "code=$($r.ErrorCode)")

# --- history folder missing before the run: a failure removes what the transaction created
Reset-World
$histDir = Join-Path $P.StateRoot 'history'
Remove-I2ADirSafe $histDir
$T0noHist = Get-I2BFullTree $L
Reset-I2AFault -Mode 'Label' -Pattern '^after:Fs-MoveNew:installed-state\.[0-9a-f]{64}\.json' -Nth 1 -Action 'IO'; $global:I2AFH.IdCounter = 1
$r = Run-Uninstall
$afterHist = @(Get-I2CHistoryFiles $L 'installed-state.*.json')
[void](Assert-I2A 'D-N60-failure-after-archive-removes-it' (($r.Succeeded -eq $false) -and ($afterHist.Count -eq 0) -and [System.IO.File]::Exists($P.StatePath) -and (Same $T0 (Tree))) "code=$($r.ErrorCode) rb=$($r.RollbackState): no archive, installed-state back")
Reset-World
Remove-I2ADirSafe $histDir
$r = Run-Uninstall
[void](Assert-I2A 'D-N61-history-folder-created-by-the-transaction' (($r.Succeeded -eq $true) -and (@(Get-I2CHistoryFiles $L 'installed-state.*.json').Count -eq 1)) "code=$($r.ErrorCode)")

# --- every backup is kept (D-C8) and nothing is garbage-collected
Reset-World
$bakBefore = @(Get-I2CBackupFiles $L)
$r = Run-Uninstall
$bakAfter = @(Get-I2CBackupFiles $L)
[void](Assert-I2A 'D-N62-no-backup-gc' (($r.Succeeded -eq $true) -and (@($bakBefore | Where-Object { $bakAfter -notcontains $_ }).Count -eq 0) -and ($bakAfter.Count -gt $bakBefore.Count)) "backups before=$($bakBefore.Count) after=$($bakAfter.Count): none deleted; the uninstall added its own")
[void](Assert-I2A 'D-N62-no-uninstall-rollback-folder' (-not [System.IO.Directory]::Exists((Join-Path $P.DataRoot 'UninstallRollback'))) 'UninstallRollback is never created')

# --- somebody changes an installed file between planning and the first change (I2-A E1: the core never guesses; the run stops for a manual check)
Reset-World
$script:I2CExe = $P.AppExe
$exeBytes = [System.IO.File]::ReadAllBytes($P.AppExe)
Reset-I2AFault -Mode 'Label' -Pattern '^before:Journal:Begin$' -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:I2CExe, 'changed by a third party after planning', [System.Text.Encoding]::UTF8) }
$global:I2AFH.IdCounter = 1
$r = Run-Uninstall
Reset-I2AFault
[void](Assert-I2A 'D-N70-third-party-change-stops-for-a-manual-check' (($r.Succeeded -eq $false) -and ($r.ErrorCode -eq 'DestinationChangedDuringApply') -and ($r.RollbackState -eq 'RepairRequired') -and ($r.ManualCheckRequired -eq $true) -and (Marker) -and ([System.IO.File]::ReadAllText($P.AppExe) -like 'changed by a third party*') -and (-not (Test-I2CUsValid $L)) -and (-not [System.IO.File]::Exists((Get-I2CUsPath $L)))) "code=$($r.ErrorCode) rb=$($r.RollbackState) manual=$($r.ManualCheckRequired): the third party's file is neither deleted nor overwritten; the marker and journal stay as the evidence")
$r2 = Run-Uninstall
[void](Assert-I2A 'D-N70-stays-failed-until-the-evidence-is-fixed' (($r2.Succeeded -eq $false) -and ($r2.ErrorCode -eq 'RecoveryRequired') -and ((Get-I2CReasonCodes $r2) -contains 'DestinationUnknownSha') -and (Marker)) "second run: $($r2.ErrorCode) reasons=[$((Get-I2CReasonCodes $r2) -join ',')] - registration and Uninstall.exe stay")
[System.IO.File]::WriteAllBytes($P.AppExe, $exeBytes)
$r3 = Run-Uninstall
[void](Assert-I2A 'D-N70-restoring-the-file-lets-recovery-finish' (($r3.Succeeded -eq $false) -and ($r3.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (-not (Marker)) -and (Same $T0 (Tree))) "third run: $($r3.ErrorCode); tree == T0: $(Same $T0 (Tree))")
# ---------------------------------------------------------------- H-6 end to end (six cases)
Uninstall-I2AHarness
$H = New-I2CCase 'i2c-h6'
$HP = $H.Product
Use-I2BHarnessIds
Install-I2AHarness
Reset-I2AFault; Reset-I2ACounters
$hyml = Get-I2CLeafPath $H 'Den-Go-Controller.yml'
function Run-HUninstall { try { return (Invoke-I2CUninstall $H $true) } catch { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = [string]$_.Exception.Message; AlreadyUninstalled = $false } } }
# H6-1 generation 1: install (Origin = the user's original), uninstall -> original back, installed-state retired
$g1 = Install-I2CGeneration $H
$gen1State = Get-I2CIs $H
$gen1Backup = [string](Get-I2CRecord $gen1State 'Den-Go-Controller.yml').Backup
$u1 = Run-HUninstall
[void](Assert-I2A 'H6-1-generation-1-uninstalled-origin-restored' (($g1.Succeeded -eq $true) -and ($u1.Succeeded -eq $true) -and ([System.IO.File]::ReadAllText($hyml) -eq 'user-original-yml') -and (-not [System.IO.File]::Exists($HP.StatePath)) -and (@(Get-I2CHistoryFiles $H 'installed-state.*.json').Count -eq 1)) "g1=$($g1.Succeeded) u1=$($u1.Succeeded)/$($u1.ErrorCode)")
# H6-2 the user edits the profile after the uninstall
[System.IO.File]::WriteAllText($hyml, 'user-edited-after-uninstall', $script:Utf8)
$editedSha2 = Get-I2AFileSha $hyml
# H6-3 reinstall (generation 2): starts from an absent installed-state; its Origin is the edited profile, in the new generation's own backup
$g2 = Install-I2CGeneration $H
$gen2State = Get-I2CIs $H
$rec2 = Get-I2CRecord $gen2State 'Den-Go-Controller.yml'
$bk2sha = Get-I2AFileSha $rec2.Backup
[void](Assert-I2A 'H6-3-reinstall-starts-a-new-generation' (($g2.Succeeded -eq $true) -and ($rec2.Ownership -eq 'ReplacedExisting') -and ($rec2.Backup -ne $gen1Backup) -and ($bk2sha -eq $editedSha2) -and ($rec2.Backups[0].Path -eq $rec2.Backup) -and ($rec2.Backups[0].TransactionId -ne $gen1State.TransactionId)) "gen2 Origin backup=$($rec2.Backup) holds the edited profile; it is not gen1's backup")
[void](Assert-I2A 'H6-3-gen1-backup-still-kept' ([System.IO.File]::Exists($gen1Backup)) 'D-C8: the closed generation''s backup is kept, but nothing refers to it')
# H6-5 (run before the good uninstall): generation 2's state is tampered to point at generation 1's backup -> zero change, no overwrite
$gen2Backup = Get-I2AFileSha $hyml
$snapBeforeTamper = Save-I2ATree $H.Root
Edit-I2CInstalledState $H { param($o) $r = Get-I2CRecord $o 'Den-Go-Controller.yml'; $r.Backup = $gen1Backup; $r.BeforeSHA256 = $gen1State.Files[0].BeforeSHA256; $b = (Get-I2CRecord $gen1State 'Den-Go-Controller.yml').Backups[0]; $r.Backups = [object[]]@($b); $r.BeforeSHA256 = $b.SHA256 }
$h6fullBefore = Get-I2BFullTree $H
$h6ymlBefore = Get-I2AFileSha $hyml
$u5 = Run-HUninstall
[void](Assert-I2A 'H6-5-old-generation-backup-is-never-used' (($u5.Succeeded -eq $false) -and ($u5.ErrorCode -eq 'ReplacedExistingBackupInvalid') -and (Same $h6fullBefore (Get-I2BFullTree $H)) -and ((Get-I2AFileSha $hyml) -eq $h6ymlBefore) -and ([System.IO.File]::ReadAllText($hyml) -ne 'user-original-yml')) "code=$($u5.ErrorCode): zero change; the profile was not overwritten with generation 1's content")
Restore-I2ATree $H.Root $snapBeforeTamper
# H6-4 the good uninstall of generation 2 restores ITS Origin (the edited profile), never generation 1's
$u4 = Run-HUninstall
$hus = Get-I2CUs $H
[void](Assert-I2A 'H6-4-generation-2-uninstall-restores-its-own-origin' (($u4.Succeeded -eq $true) -and ((Get-I2AFileSha $hyml) -eq $editedSha2) -and ([System.IO.File]::ReadAllText($hyml) -eq 'user-edited-after-uninstall') -and (@($hus.UsedBackups).Count -eq 1) -and ($hus.UsedBackups[0].Path -eq $rec2.Backup) -and ($hus.UsedBackups[0].Path -ne $gen1Backup)) "restored content: [$([System.IO.File]::ReadAllText($hyml))]; used backup is generation 2's")
[void](Assert-I2A 'H6-4-lineage-recorded' (($hus.PreviousUninstalledState.Exists -eq $true) -and (Test-Path $hus.PreviousUninstalledState.ArchivedPath) -and (@(Get-I2CHistoryFiles $H 'installed-state.*.json').Count -eq 2) -and ($hus.ClosedGeneration.GenerationId -ne $u1.GetType().Name)) 'generation 1''s uninstalled-state and both closed installed-states are in history')
[void](Assert-I2A 'H6-4-no-old-generation-backup-in-used-list' (@($hus.UsedBackups | Where-Object { $_.Path -like ('*' + [string]$gen1State.TransactionId + '*') -or $_.Path -eq $gen1Backup }).Count -eq 0) 'UsedBackups never names a closed generation''s backup')
# H6-6 the legacy H-6 state: old installed-state kept by the old uninstaller + its old uninstalled-state, then (here) a restore would be needed
Uninstall-I2AHarness
$HL = New-I2CCase 'i2c-h6-legacy'
Install-I2AHarness; Reset-I2AFault; Reset-I2ACounters
$gl = Install-I2CGeneration $HL
ConvertTo-I2CLegacyState $HL
Write-I2CLegacyUninstalledState $HL
$hlyml = Get-I2CLeafPath $HL 'Den-Go-Controller.yml'
$hlBefore = Get-I2BFullTree $HL
$ul = Invoke-I2CUninstall $HL $true
$hlCodes = $ul.ErrorCode
[void](Assert-I2A 'H6-6-legacy-contaminated-state-blocks-a-needed-restore' (($gl.Succeeded -eq $true) -and ($ul.Succeeded -eq $false) -and ($ul.ErrorCode -eq 'ContaminationBlocksRestore') -and ($ul.ContaminationSuspect -eq $true) -and (Same $hlBefore (Get-I2BFullTree $HL))) "code=${hlCodes}; zero change (the profile is not overwritten)")
# ... and with the restore not needed (profile kept), the Created files are removed by SHA match and the suspicion is recorded
$ul2 = Invoke-I2CUninstall $HL $false
$usl = Get-I2CUs $HL
[void](Assert-I2A 'H6-6-contaminated-state-without-a-restore-completes' (($ul2.Succeeded -eq $true) -and ($usl.ClosedGeneration.ContaminationSuspect -eq $true) -and (@($usl.ClosedGeneration.ContaminationReasons).Count -eq 1) -and ($usl.ManualCheckRequired -eq $true) -and ([System.IO.File]::Exists($hlyml)) -and (-not [System.IO.File]::Exists((Get-I2CLeafPath $HL 'DenGoControllerConverter.exe'))) -and (@($usl.UnusedBackups | Where-Object { $_.Reason -eq 'ContaminationSuspect' }).Count -ge 1)) "Completed; Created files removed; the profile kept; suspicion + unused backups recorded; ManualCheckRequired=$($usl.ManualCheckRequired)")
Uninstall-I2AHarness
# ---------------------------------------------------------------- I. generation 2 with the previous generation's uninstalled-state (crash + exception sweeps)
#    and the AlreadyUninstalled reconfirmation (crash + exception sweeps, with and without a pre-existing history copy).
# The number of points of every sweep is measured from the product's own primitives (a recorded run), never typed in.
if (-not $SkipSweeps) {
    $stepG = $Stride
    if ($SkipHeavy) { $stepG = [Math]::Max($Stride, 3) }
    $GS = New-I2CCase 'i2c-gen2'
    $GP = $GS.Product
    Use-I2BHarnessIds
    Install-I2AHarness
    Reset-I2AFault; Reset-I2ACounters
    function New-GFailure([string]$Message) { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = $Message; RollbackState = 'NotStarted'; ManualCheckRequired = $false; Recovery = $null; Reasons = @(); Blocking = @(); ResidualFiles = @(); AlreadyUninstalled = $false; UninstalledState = $null; ReportPath = ''; TransactionId = ''; StateCommitted = $false } }
    function Invoke-GRun { try { return (Invoke-I2CUninstall $GS $true) } catch { return (New-GFailure ([string]$_.Exception.Message)) } }
    function Get-GMarker { return [System.IO.File]::Exists((Get-I2CUmPath $GS)) }
    function Get-GUsSha { if ([System.IO.File]::Exists((Get-I2CUsPath $GS))) { return (Get-I2AFileSha (Get-I2CUsPath $GS)).ToLowerInvariant() } return '<none>' }
    function Test-GBytesEqual([string]$Path, [byte[]]$Expected) {
        if (-not [System.IO.File]::Exists($Path)) { return $false }
        $a = [System.IO.File]::ReadAllBytes($Path)
        if ($a.Length -ne $Expected.Length) { return $false }
        for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $Expected[$i]) { return $false } }
        return $true
    }
    function Get-GUsArchivePath([string]$Sha) { return (Join-Path $GP.StateRoot ('history\uninstalled-state.' + $Sha + '.json')) }
    function Get-GClosedJson($Us) { return (ConvertTo-Json -InputObject $Us.ClosedGeneration -Depth 9) }
    # Every history copy of a state file is named by the SHA-256 of its content (content-addressed).
    function Test-GArchivesContentAddressed {
        foreach ($f in (@(Get-I2CHistoryFiles $GS 'installed-state.*.json') + @(Get-I2CHistoryFiles $GS 'uninstalled-state.*.json'))) {
            $m = [regex]::Match([System.IO.Path]::GetFileName($f), '^(installed|uninstalled)-state\.([0-9a-f]{64})\.json$')
            if (-not $m.Success) { return $false }
            if ((Get-I2AFileSha $f).ToLowerInvariant() -ne $m.Groups[2].Value) { return $false }
        }
        return $true
    }
    function Get-GRegisterPaths([string]$TransactionId) {
        $j = Join-Path $GP.StateRoot ('history\txn-' + $TransactionId + '.committed.jsonl')
        if (-not [System.IO.File]::Exists($j)) { return , @() }
        return , @((DgJournal-Parse $j).Records | Where-Object { $_.stage -eq 'Register' } | ForEach-Object { [string]$_.path })
    }
    # Boundary classes that the sweeps must cover with a point BEFORE and a point AFTER the primitive (measured from the recorded labels).
    function Get-GBoundaryGaps($Labels, $Required) {
        $gaps = New-Object System.Collections.ArrayList
        foreach ($b in $Required) {
            $pre = @($Labels | Where-Object { $_ -match ('^before:' + $b[1]) }).Count
            $post = @($Labels | Where-Object { $_ -match ('^after:' + $b[1]) }).Count
            if (($pre -lt 1) -or ($post -lt 1)) { [void]$gaps.Add("$($b[0]) before=$pre after=$post") }
        }
        return , @($gaps)
    }

    # ---- setup: generation 1 installed and uninstalled (its uninstalled-state stays), generation 2 installed next to it
    $gA = Install-I2CGeneration $GS
    $gen1Is = Get-I2CIs $GS
    $gen1Backup = [string](Get-I2CRecord $gen1Is 'Den-Go-Controller.yml').Backup
    $uA = Invoke-GRun
    $us1Path = Get-I2CUsPath $GS
    $us1Bytes = [System.IO.File]::ReadAllBytes($us1Path)
    $us1Sha = Get-GUsSha
    $us1Closed = Get-GClosedJson (Get-I2CUs $GS)
    $gB = Install-I2CGeneration $GS
    $gen2Is = Get-I2CIs $GS
    $gen2Backup = [string](Get-I2CRecord $gen2Is 'Den-Go-Controller.yml').Backup
    $gen2Sha = (Get-I2AFileSha $GP.StatePath).ToLowerInvariant()
    [void](Assert-I2A 'GEN00-setup-previous-uninstalled-state-next-to-a-new-generation' (($gA.Succeeded -eq $true) -and ($uA.Succeeded -eq $true) -and ($gB.Succeeded -eq $true) -and (Test-I2CUsValid $GS) -and [System.IO.File]::Exists($GP.StatePath) -and ($gen1Backup -ne $gen2Backup) -and [System.IO.File]::Exists($gen1Backup) -and [System.IO.File]::Exists($gen2Backup) -and ((Get-GUsSha) -eq $us1Sha) -and ((Cnt (Get-I2CHistoryFiles $GS 'uninstalled-state.*.json')) -eq 0)) "g1=$($gA.Succeeded) u1=$($uA.Succeeded) g2=$($gB.Succeeded); generation 1 and 2 Origin backups differ; generation 1's uninstalled-state is valid and still the only one")
    $gIdBase = [int]$global:I2AFH.IdCounter; $gTickBase = [int]$global:I2AFH.Tick
    $snapG = Save-I2ATree $GS.Root
    function Reset-G { Release-I2AHeld; Restore-I2ATree $GS.Root $snapG; Reset-I2AFault; $global:I2AFH.IdCounter = $gIdBase; $global:I2AFH.Tick = $gTickBase }
    Reset-G
    $T0g = Get-I2CTree $GS
    $bakBeforeG = @(Get-I2CBackupFiles $GS)

    # ---- the final state of a generation-2 uninstall (shared by the happy path and every sweep)
    function Get-GFinalProblems {
        $p = New-Object System.Collections.ArrayList
        $T1 = Get-I2CTree $GS -NormalizeState
        $oracle = Test-T1Oracle $T0g $T1
        foreach ($x in $oracle) { [void]$p.Add('oracle: ' + $x) }
        if (-not (Test-I2CUsValid $GS)) { [void]$p.Add('uninstalled-state invalid'); return , @($p) }
        $us = Get-I2CUs $GS
        if ([System.IO.File]::Exists($GP.StatePath)) { [void]$p.Add('installed-state still active') }
        $cg = $us.ClosedGeneration
        if (([string]$cg.GenerationId).ToLowerInvariant() -ne $gen2Sha) { [void]$p.Add('ClosedGeneration is not generation 2') }
        if (([string]$cg.LastInstallTransactionId) -ne [string]$gen2Is.TransactionId) { [void]$p.Add('LastInstallTransactionId is not generation 2') }
        if (-not ([System.IO.File]::Exists([string]$cg.ArchivedStatePath) -and ((Get-I2AFileSha ([string]$cg.ArchivedStatePath)).ToLowerInvariant() -eq $gen2Sha))) { [void]$p.Add('generation 2 archive missing or its SHA differs') }
        if (@(Get-I2CHistoryFiles $GS 'installed-state.*.json').Count -ne 2) { [void]$p.Add('installed-state archives != 2') }
        $arch = Get-GUsArchivePath $us1Sha
        if (-not (Test-GBytesEqual $arch $us1Bytes)) { [void]$p.Add('previous uninstalled-state is not archived byte-identical') }
        else { if ((Get-GClosedJson (Read-I2CJson $arch)) -ne $us1Closed) { [void]$p.Add('previous ClosedGeneration changed') } }
        if (-not (Test-GArchivesContentAddressed)) { [void]$p.Add('a history copy is not named by its content SHA') }
        $used = @($us.UsedBackups)
        if (($used.Count -ne 1) -or ([string]$used[0].Path -ne $gen2Backup) -or ([string]$used[0].Path -eq $gen1Backup)) { [void]$p.Add('UsedBackups is not exactly generation 2''s Origin backup') }
        foreach ($b in $bakBeforeG) { if (-not [System.IO.File]::Exists($b)) { [void]$p.Add('a backup was deleted: ' + $b) } }
        if ((Cnt (Test-I2CLeftovers $GS)) -ne 0) { [void]$p.Add('leftovers: ' + [string]::Join(',', [string[]]@(Test-I2CLeftovers $GS))) }
        if (Get-GMarker) { [void]$p.Add('marker left') }
        if ($null -ne (DgP-FindActiveOrphan $GP)) { [void]$p.Add('an unfinished journal is left') }
        return , @($p)
    }

    # ---- happy path of generation 2 (recorded: the point count comes from here)
    Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = $gIdBase
    $rG = Invoke-GRun
    $gMut = [int]$global:I2AFH.Mut; $gAll = [int]$global:I2AFH.All; $gLabels = @($global:I2AFH.MutLabels)
    $gClosedHappy = ''
    if (Test-I2CUsValid $GS) { $gClosedHappy = Get-GClosedJson (Get-I2CUs $GS) }
    $fp = Get-GFinalProblems
    [void](Assert-I2A 'GEN01-uninstall-with-a-previous-uninstalled-state' (($rG.Succeeded -eq $true) -and ($rG.AlreadyUninstalled -ne $true) -and ($fp.Count -eq 0)) "succeeded=$($rG.Succeeded) code=$($rG.ErrorCode) mutPoints=$gMut allPoints=$gAll problems=[$([string]::Join('; ', [string[]]@($fp | Select-Object -First 4)))]")
    $usG = Get-I2CUs $GS
    [void](Assert-I2A 'GEN02-previous-uninstalled-state-archived-inside-the-transaction' (($usG.PreviousUninstalledState.Exists -eq $true) -and (([string]$usG.PreviousUninstalledState.Sha256).ToLowerInvariant() -eq $us1Sha) -and (Test-GBytesEqual (Get-GUsArchivePath $us1Sha) $us1Bytes)) 'history copy of generation 1''s uninstalled-state is byte-identical and recorded as PreviousUninstalledState')
    $regG = Get-GRegisterPaths ([string]$rG.TransactionId)
    $iUs = -1; $iIs = -1; $iDel = -1
    for ($i = 0; $i -lt $regG.Count; $i++) {
        if ($regG[$i] -like ('*history\uninstalled-state.' + $us1Sha + '.json')) { $iUs = $i }
        elseif ($regG[$i] -like ('*history\installed-state.' + $gen2Sha + '.json')) { $iIs = $i }
        elseif ($regG[$i] -like '*\installed-state.json') { $iDel = $i }
    }
    [void](Assert-I2A 'GEN03-archive-previous-state-then-archive-installed-state-then-delete-last' (($iUs -ge 0) -and ($iUs -lt $iIs) -and ($iIs -lt $iDel) -and ($iDel -eq ($regG.Count - 1))) "register order: previous-uninstalled-state archive=#$iUs, installed-state archive=#$iIs, installed-state delete=#$iDel of $($regG.Count)")
    $gRequired = @(
        @('first Intent', 'Journal:Intent#0$'), @('previous uninstalled-state archive copy', 'Fs-CopyFileDurable:uninstalled-state\.[0-9a-f]{64}\.json\.dengo\.tmp$'), @('previous uninstalled-state archive move', 'Fs-MoveNew:uninstalled-state\.[0-9a-f]{64}\.json$'),
        @('installed-state archive move', 'Fs-MoveNew:installed-state\.[0-9a-f]{64}\.json$'), @('installed-state Delete', 'Fs-Delete:installed-state\.json$'), @('CommitIntent', 'Journal:CommitIntent$'),
        @('uninstalled-state replace', 'Fs-Replace:uninstalled-state\.json$'), @('Committed', 'Journal:Committed$'), @('uninstalling.json delete', 'Fs-Delete:uninstalling\.json$'), @('transaction history move', 'Fs-MoveNew:txn-[^:]+\.committed\.jsonl$'))
    $gaps = Get-GBoundaryGaps $gLabels $gRequired
    [void](Assert-I2A 'GEN04-sweep-covers-every-required-boundary' ($gaps.Count -eq 0) ("each boundary has a point before and after the primitive among $gMut mutating points" + $(if ($gaps.Count -gt 0) { ': missing ' + ($gaps -join '; ') } else { '' })))
    [void](Assert-I2A 'GEN05-backups-of-both-generations-kept' ([System.IO.File]::Exists($gen1Backup) -and [System.IO.File]::Exists($gen2Backup) -and (@($bakBeforeG | Where-Object { -not [System.IO.File]::Exists($_) }).Count -eq 0)) 'D-C8: nothing is garbage-collected, and only generation 2''s Origin is used (GEN01)')
    Add-I2AEvidence @{ id = 'GEN-happy'; mutPoints = $gMut; allPoints = $gAll; previousUsSha = $us1Sha; generation2Sha = $gen2Sha }

    # ---- crash sweep: every mutating point, then the product re-run until it is done
    function Invoke-GCrashCase([int]$k) {
        Reset-G
        Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($k)); $global:I2AFH.IdCounter = $gIdBase
        $null = Invoke-GRun
        $fired = [string]$global:I2AFH.Fired
        Resume-I2AAfterCrash
        $usNow = Get-GUsSha
        $markerAtFault = Get-GMarker
        $committed = ($usNow -ne $us1Sha) -and ($usNow -ne '<none>')
        $why = New-Object System.Collections.ArrayList
        if ($fired.Length -eq 0) { [void]$why.Add('the crash did not fire') }
        $r1 = Invoke-GRun
        if ($markerAtFault) {
            if (($r1.Succeeded -ne $false) -or ($r1.ErrorCode -ne 'RecoveryCompletedOperationNotCompleted')) { [void]$why.Add("recovery-only run was not Failed/RecoveryCompletedOperationNotCompleted: succeeded=$($r1.Succeeded) code=$($r1.ErrorCode)") }
            if ($committed) {
                if ($r1.Recovery.Outcome -ne 'RolledForward') { [void]$why.Add("after the commit point recovery was $($r1.Recovery.Outcome), not RolledForward") }
                $orc = Test-T1Oracle $T0g (Get-I2CTree $GS -NormalizeState)
                if ($orc.Count -ne 0) { [void]$why.Add('after roll-forward the tree is not T1') }
            } else {
                if ($r1.Recovery.Outcome -ne 'RolledBack') { [void]$why.Add("before the commit point recovery was $($r1.Recovery.Outcome), not RolledBack") }
                if (-not (Test-GBytesEqual (Get-I2CUsPath $GS) $us1Bytes)) { [void]$why.Add('the original uninstalled-state was not restored byte-identical') }
                if (-not (Same $T0g (Get-I2CTree $GS))) { [void]$why.Add("tree is not T0 [$(Diff3 $T0g (Get-I2CTree $GS))]") }
                if ((Cnt (Get-I2CHistoryFiles $GS 'uninstalled-state.*.json')) -ne 0) { [void]$why.Add('a history copy of the previous uninstalled-state survived the rollback') }
                if ((Get-I2AFileSha $GP.StatePath).ToLowerInvariant() -ne $gen2Sha) { [void]$why.Add('installed-state is not generation 2''s') }
                if (@(Get-I2CHistoryFiles $GS 'installed-state.*.json').Count -ne 1) { [void]$why.Add('an installed-state archive survived the rollback') }
            }
            # recovery is idempotent: a second recovery pass has nothing to do and changes nothing
            $fb = Get-I2BFullTree $GS
            $gate = Get-DenGoUninstallRecoveryGate $GP 'Apply'
            if (($gate.Outcome -ne 'NotNeeded') -or ($gate.Proceed -ne $true) -or (-not (Same $fb (Get-I2BFullTree $GS)))) { [void]$why.Add("second recovery pass: outcome=$($gate.Outcome) proceed=$($gate.Proceed)") }
        } else {
            if ($r1.Succeeded -ne $true) { [void]$why.Add("no marker: the run did not complete: code=$($r1.ErrorCode)") }
            if ($r1.AlreadyUninstalled -ne $committed) { [void]$why.Add("AlreadyUninstalled=$($r1.AlreadyUninstalled) but committed=$committed") }
        }
        $rj = $r1
        if ($r1.Succeeded -ne $true) {
            for ($j = 0; $j -lt 3; $j++) { $rj = Invoke-GRun; if ($rj.Succeeded) { break } }
            if (-not $rj.Succeeded) { [void]$why.Add("never completed: $($rj.ErrorCode)") }
        }
        foreach ($x in (Get-GFinalProblems)) { [void]$why.Add($x) }
        if ((Test-I2CUsValid $GS) -and ((Get-GClosedJson (Get-I2CUs $GS)) -ne $gClosedHappy)) { [void]$why.Add('ClosedGeneration differs from the uninterrupted run') }
        $pass = ($why.Count -eq 0)
        Add-I2AEvidence @{ id = "GEN-crash-k$k"; fault = $fired; markerAtFault = $markerAtFault; committedAtFault = $committed; firstOutcome = [string]$r1.ErrorCode; pass = $pass }
        return @{ Pass = $pass; Detail = ("fired=$fired marker=$markerAtFault committed=$committed :: " + [string]::Join('; ', [string[]]@($why | Select-Object -First 5))) }
    }
    $failG = 0; $ranG = 0
    foreach ($k in (Get-Sample $gMut $stepG)) {
        try { $res = Invoke-GCrashCase $k } catch { $res = @{ Pass = $false; Detail = ("EXCEPTION " + [string]$_.Exception.Message) } }
        $ranG++
        if (-not $res.Pass) { $failG++; Add-I2AResult ("GEN-crash-k$k") $false ($gLabels[$k - 1] + ' :: ' + $res.Detail) }
    }
    if ($failG -eq 0) { Add-I2AResult 'GEN-crash-sweep-with-previous-uninstalled-state' $true "crash at $ranG of $gMut mutating points while generation 1's uninstalled-state exists: before the commit point the original uninstalled-state is restored byte-identical and the tree is T0; afterwards the uninstall rolls forward; a second recovery pass changes nothing; the previous uninstalled-state is archived byte-identical, its ClosedGeneration is untouched, only generation 2's Origin backup is used" }
    if ($stepG -eq 1) { [void](Assert-I2A 'GEN-crash-covers-every-mutating-point' ($ranG -eq $gMut) "swept $ranG of $gMut") }

    # ---- exception sweep (every point with -FullThrow)
    $tStepG = [Math]::Max($stepG, $(if ($gAll -gt 900) { 7 } elseif ($gAll -gt 500) { 4 } elseif ($gAll -gt 250) { 2 } else { 1 }))
    if ($FullThrow) { $tStepG = 1 }
    $failTG = 0; $ranTG = 0
    foreach ($k in (Get-Sample $gAll $tStepG)) {
        Reset-G
        Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; $global:I2AFH.IdCounter = $gIdBase
        $r = Invoke-GRun
        $rb = [string]$r.RollbackState
        $why = New-Object System.Collections.ArrayList
        if ($r.Succeeded) { foreach ($x in (Get-GFinalProblems)) { [void]$why.Add($x) } }
        elseif (@('RolledBack', 'NotStarted', 'NotNeeded') -contains $rb) {
            if (-not (Test-GBytesEqual (Get-I2CUsPath $GS) $us1Bytes)) { [void]$why.Add('the original uninstalled-state is not intact') }
            if (-not (Same $T0g (Get-I2CTree $GS))) { [void]$why.Add("tree is not T0 [$(Diff3 $T0g (Get-I2CTree $GS))]") }
            if ((Cnt (Test-I2CLeftovers $GS)) -ne 0) { [void]$why.Add('leftovers') }
        } else { [void]$why.Add("neither completed nor rolled back: rb=$rb code=$($r.ErrorCode)") }
        if (([string]$global:I2AFH.Fired).Length -eq 0) { [void]$why.Add('the exception did not fire') }
        if (Get-GMarker) { [void]$why.Add('marker left') }
        $ranTG++
        if ($why.Count -gt 0) { $failTG++; Add-I2AResult ("GEN-throw-k$k") $false ("fired=$($global:I2AFH.Fired) code=$($r.ErrorCode) rb=$rb :: " + [string]::Join('; ', [string[]]@($why | Select-Object -First 4))) }
    }
    if ($failTG -eq 0) { Add-I2AResult 'GEN-throw-sweep-with-previous-uninstalled-state' $true "IO exception at $ranTG of $gAll points$(if ($FullThrow) { ' (FullThrow: every point)' }): always a rollback (original uninstalled-state intact, tree == T0) or a completed uninstall with the final state of GEN01" }
    if ($FullThrow) { [void](Assert-I2A 'GEN-throw-covers-every-point' ($ranTG -eq $gAll) "swept $ranTG of $gAll") }
    Add-I2AEvidence @{ id = 'SWEEP-COUNTS-previous-uninstalled-state'; mutPoints = $gMut; crashSwept = $ranG; allPoints = $gAll; throwSwept = $ranTG; fullThrow = [bool]$FullThrow }

    # ---- AlreadyUninstalled reconfirmation (D-C3): generation 2 is uninstalled; the next run reconfirms it with an explicit transaction
    Reset-G
    $rDone = Invoke-GRun
    $us2Path = Get-I2CUsPath $GS
    $us2Bytes = [System.IO.File]::ReadAllBytes($us2Path)
    $us2Sha = Get-GUsSha
    $us2Closed = Get-GClosedJson (Get-I2CUs $GS)
    $us2TxnId = [string](Get-I2CUs $GS).UninstallTransactionId
    $snapB = Save-I2ATree $GS.Root
    [System.IO.File]::Copy($us2Path, (Get-GUsArchivePath $us2Sha), $false)
    $snapB0 = Save-I2ATree $GS.Root
    $bIdBase = [int]$global:I2AFH.IdCounter; $bTickBase = [int]$global:I2AFH.Tick
    [void](Assert-I2A 'AU00-setup-generation-2-uninstalled' (($rDone.Succeeded -eq $true) -and (Test-I2CUsValid $GS) -and (-not [System.IO.File]::Exists($GP.StatePath)) -and (-not (Get-GMarker))) "uninstall: succeeded=$($rDone.Succeeded) code=$($rDone.ErrorCode)")
    $bRequired = @(
        @('uninstalled-state archive move', 'Fs-MoveNew:uninstalled-state\.[0-9a-f]{64}\.json$'), @('CommitIntent', 'Journal:CommitIntent$'), @('uninstalled-state replace', 'Fs-Replace:uninstalled-state\.json$'),
        @('Committed', 'Journal:Committed$'), @('uninstalling.json delete', 'Fs-Delete:uninstalling\.json$'), @('transaction history move', 'Fs-MoveNew:txn-[^:]+\.committed\.jsonl$'))
    foreach ($variant in @('archive-absent', 'archive-present')) {
        $snapCur = $(if ($variant -eq 'archive-absent') { $snapB } else { $snapB0 })
                function Reset-B { Release-I2AHeld; Restore-I2ATree $GS.Root $snapCur; Reset-I2AFault; $global:I2AFH.IdCounter = $bIdBase; $global:I2AFH.Tick = $bTickBase }
        Reset-B
        $archiveBase = Cnt (Get-I2CHistoryFiles $GS 'uninstalled-state.*.json')
        $T0b = Get-I2CTree $GS
        $T1b = Get-I2CTree $GS -NormalizeState
        function Get-BFinalProblems {
            $p = New-Object System.Collections.ArrayList
            if (-not (Same $T1b (Get-I2CTree $GS -NormalizeState))) { [void]$p.Add("tree changed [$(Diff3 $T1b (Get-I2CTree $GS -NormalizeState))]") }
            if (-not (Test-I2CUsValid $GS)) { [void]$p.Add('uninstalled-state invalid'); return , @($p) }
            $us = Get-I2CUs $GS
            if ($us.Reconfirmation.Reconfirmed -ne $true) { [void]$p.Add('not reconfirmed') }
            if ((Get-GClosedJson $us) -ne $us2Closed) { [void]$p.Add('ClosedGeneration changed') }
            if (-not (Test-GBytesEqual (Get-GUsArchivePath $us2Sha) $us2Bytes)) { [void]$p.Add('the reconfirmed state was not archived byte-identical') }
            if ([System.IO.File]::Exists($GP.StatePath)) { [void]$p.Add('installed-state exists') }
            if (-not (Test-GArchivesContentAddressed)) { [void]$p.Add('a history copy is not named by its content SHA') }
            if ((Cnt (Test-I2CLeftovers $GS)) -ne 0) { [void]$p.Add('leftovers') }
            if (Get-GMarker) { [void]$p.Add('marker left') }
            if ($null -ne (DgP-FindActiveOrphan $GP)) { [void]$p.Add('an unfinished journal is left') }
            if (@(Get-I2CHistoryFiles $GS 'installed-state.*.json').Count -ne 2) { [void]$p.Add('installed-state archives != 2') }
            return , @($p)
        }
        # happy reconfirmation (recorded)
        Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = $bIdBase
        $rr = Invoke-GRun
        $bMut = [int]$global:I2AFH.Mut; $bAll = [int]$global:I2AFH.All; $bLabels = @($global:I2AFH.MutLabels)
        $bp = Get-BFinalProblems
        [void](Assert-I2A "AU01-reconfirm-happy-$variant" (($rr.Succeeded -eq $true) -and ($rr.AlreadyUninstalled -eq $true) -and ($bp.Count -eq 0)) "succeeded=$($rr.Succeeded) already=$($rr.AlreadyUninstalled) code=$($rr.ErrorCode) mutPoints=$bMut allPoints=$bAll problems=[$([string]::Join('; ', [string[]]@($bp | Select-Object -First 3)))]")
        $usR = Get-I2CUs $GS
        [void](Assert-I2A "AU02-reconfirm-new-state-and-previous-recorded-$variant" ((([string]$usR.PreviousUninstalledState.Sha256).ToLowerInvariant() -eq $us2Sha) -and ($usR.UninstallTransactionId -ne $us2TxnId) -and ($usR.Reconfirmation.FromUninstallTransactionId -eq $us2TxnId)) 'a new transaction and a new uninstalled-state; the reconfirmed one is recorded as the previous state')
        $regB = Get-GRegisterPaths ([string]$rr.TransactionId)
        if ($variant -eq 'archive-absent') {
            [void](Assert-I2A "AU03-explicit-transaction-archives-the-state-only-$variant" (($regB.Count -eq 1) -and ($regB[0] -like ('*history\uninstalled-state.' + $us2Sha + '.json'))) "registered: $($regB -join ', ')")
            $req = $bRequired
        } else {
            [void](Assert-I2A "AU03-explicit-empty-transaction-$variant" ($regB.Count -eq 0) "the history copy already exists: the transaction has $($regB.Count) items and still commits the new state atomically")
            $req = @($bRequired | Where-Object { $_[0] -ne 'uninstalled-state archive move' })
        }
        $bgaps = Get-GBoundaryGaps $bLabels $req
        [void](Assert-I2A "AU04-sweep-covers-every-required-boundary-$variant" ($bgaps.Count -eq 0) ("each boundary has a point before and after the primitive among $bMut mutating points" + $(if ($bgaps.Count -gt 0) { ': missing ' + ($bgaps -join '; ') } else { '' })))

        # crash sweep
        $failB = 0; $ranB = 0
        foreach ($k in (Get-Sample $bMut $stepG)) {
            Reset-B
            Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($k)); $global:I2AFH.IdCounter = $bIdBase
            $null = Invoke-GRun
            $fired = [string]$global:I2AFH.Fired
            Resume-I2AAfterCrash
            $usNow = Get-GUsSha
            $markerAtFault = Get-GMarker
            $committed = ($usNow -ne $us2Sha)
            $why = New-Object System.Collections.ArrayList
            if ($fired.Length -eq 0) { [void]$why.Add('the crash did not fire') }
            $r1 = Invoke-GRun
            if ($markerAtFault) {
                if (($r1.Succeeded -ne $false) -or ($r1.ErrorCode -ne 'RecoveryCompletedOperationNotCompleted')) { [void]$why.Add("recovery-only run was not Failed/RecoveryCompletedOperationNotCompleted: succeeded=$($r1.Succeeded) code=$($r1.ErrorCode)") }
                if ($committed) {
                    if ($r1.Recovery.Outcome -ne 'RolledForward') { [void]$why.Add("after the commit point recovery was $($r1.Recovery.Outcome)") }
                    if ((Get-GUsSha) -eq $us2Sha) { [void]$why.Add('the new state is gone') }
                } else {
                    if ($r1.Recovery.Outcome -ne 'RolledBack') { [void]$why.Add("before the commit point recovery was $($r1.Recovery.Outcome)") }
                    if (-not (Test-GBytesEqual (Get-I2CUsPath $GS) $us2Bytes)) { [void]$why.Add('the original uninstalled-state was not restored byte-identical') }
                    if (-not (Same $T0b (Get-I2CTree $GS))) { [void]$why.Add("tree is not the original [$(Diff3 $T0b (Get-I2CTree $GS))]") }
                    if ((Cnt (Get-I2CHistoryFiles $GS 'uninstalled-state.*.json')) -ne $archiveBase) { [void]$why.Add('history copy count changed by the rollback') }
                }
                $fb = Get-I2BFullTree $GS
                $gate = Get-DenGoUninstallRecoveryGate $GP 'Apply'
                if (($gate.Outcome -ne 'NotNeeded') -or ($gate.Proceed -ne $true) -or (-not (Same $fb (Get-I2BFullTree $GS)))) { [void]$why.Add("second recovery pass: outcome=$($gate.Outcome) proceed=$($gate.Proceed)") }
            } else {
                if (($r1.Succeeded -ne $true) -or ($r1.AlreadyUninstalled -ne $true)) { [void]$why.Add("no marker: the reconfirmation did not complete: succeeded=$($r1.Succeeded) already=$($r1.AlreadyUninstalled) code=$($r1.ErrorCode)") }
            }
            $rj = $r1
            if ($r1.Succeeded -ne $true) {
                for ($j = 0; $j -lt 3; $j++) { $rj = Invoke-GRun; if ($rj.Succeeded -and $rj.AlreadyUninstalled) { break } }
                if (-not ($rj.Succeeded -and $rj.AlreadyUninstalled)) { [void]$why.Add("never reconfirmed: $($rj.ErrorCode)") }
            }
            foreach ($x in (Get-BFinalProblems)) { [void]$why.Add($x) }
            $ranB++
            if ($why.Count -gt 0) { $failB++; Add-I2AResult ("AU-crash-$variant-k$k") $false ($bLabels[$k - 1] + ' :: ' + "fired=$fired marker=$markerAtFault committed=$committed :: " + [string]::Join('; ', [string[]]@($why | Select-Object -First 5))) }
        }
        if ($failB -eq 0) { Add-I2AResult "AU-reconfirm-crash-sweep-$variant" $true "crash at $ranB of $bMut mutating points of the AlreadyUninstalled reconfirmation: a recovery-only run is never Completed; before the commit point the original uninstalled-state is restored byte-identical (tree unchanged); afterwards it rolls forward; the reconfirmation then completes; the previous state is archived byte-identical; the closed generation is unchanged; a second recovery pass changes nothing" }
        if ($stepG -eq 1) { [void](Assert-I2A "AU-crash-covers-every-mutating-point-$variant" ($ranB -eq $bMut) "swept $ranB of $bMut") }

        # exception sweep
        $tStepB = [Math]::Max($stepG, $(if ($bAll -gt 900) { 7 } elseif ($bAll -gt 500) { 4 } elseif ($bAll -gt 250) { 2 } else { 1 }))
        if ($FullThrow) { $tStepB = 1 }
        $failTB = 0; $ranTB = 0
        foreach ($k in (Get-Sample $bAll $tStepB)) {
            Reset-B
            Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; $global:I2AFH.IdCounter = $bIdBase
            $r = Invoke-GRun
            $rb = [string]$r.RollbackState
            $why = New-Object System.Collections.ArrayList
            if ($r.Succeeded) {
                if ($r.AlreadyUninstalled -ne $true) { [void]$why.Add('completed but not as a reconfirmation') }
                foreach ($x in (Get-BFinalProblems)) { [void]$why.Add($x) }
            } elseif (@('RolledBack', 'NotStarted', 'NotNeeded') -contains $rb) {
                if (-not (Test-GBytesEqual (Get-I2CUsPath $GS) $us2Bytes)) { [void]$why.Add('the original uninstalled-state is not intact') }
                if (-not (Same $T0b (Get-I2CTree $GS))) { [void]$why.Add("tree is not the original [$(Diff3 $T0b (Get-I2CTree $GS))]") }
                if ((Cnt (Test-I2CLeftovers $GS)) -ne 0) { [void]$why.Add('leftovers') }
            } else { [void]$why.Add("neither completed nor rolled back: rb=$rb code=$($r.ErrorCode)") }
            if (([string]$global:I2AFH.Fired).Length -eq 0) { [void]$why.Add('the exception did not fire') }
            if (Get-GMarker) { [void]$why.Add('marker left') }
            $ranTB++
            if ($why.Count -gt 0) { $failTB++; Add-I2AResult ("AU-throw-$variant-k$k") $false ("fired=$($global:I2AFH.Fired) code=$($r.ErrorCode) rb=$rb :: " + [string]::Join('; ', [string[]]@($why | Select-Object -First 4))) }
        }
        if ($failTB -eq 0) { Add-I2AResult "AU-reconfirm-throw-sweep-$variant" $true "IO exception at $ranTB of $bAll points$(if ($FullThrow) { ' (FullThrow: every point)' }) of the reconfirmation: always a rollback to the original uninstalled-state or a completed reconfirmation" }
        if ($FullThrow) { [void](Assert-I2A "AU-throw-covers-every-point-$variant" ($ranTB -eq $bAll) "swept $ranTB of $bAll") }
        Add-I2AEvidence @{ id = "SWEEP-COUNTS-reconfirm-$variant"; mutPoints = $bMut; crashSwept = $ranB; allPoints = $bAll; throwSwept = $ranTB; fullThrow = [bool]$FullThrow }
    }

    # ---- ambiguous states are never guessed into AlreadyUninstalled (engine level: Failed, nothing committed, nothing changed).
    # The predicate itself (every single condition) is covered by I2C-Unit UC8; D-N52..D-N54 cover three engine paths. These are the remaining engine paths.
    $ambiguous = @(
        @('state-field-wrong', { $o = Get-I2CUs $GS; $o.State = 'Installed'; Write-I2CJson (Get-I2CUsPath $GS) $o }, @('UninstalledStateNotReconfirmable')),
        @('uninstalledat-invalid', { $o = Get-I2CUs $GS; $o.UninstalledAt = 'yesterday-ish'; Write-I2CJson (Get-I2CUsPath $GS) $o }, @('UninstalledStateNotReconfirmable')),
        @('no-closed-generation', { $o = Get-I2CUs $GS; Remove-I2CProperty $o 'ClosedGeneration'; Write-I2CJson (Get-I2CUsPath $GS) $o }, @('UninstalledStateNotReconfirmable')),
        @('archive-missing', { [System.IO.File]::Delete((Get-I2CUs $GS).ClosedGeneration.ArchivedStatePath) }, @('UninstalledStateNotReconfirmable')),
        @('archive-path-elsewhere', { $o = Get-I2CUs $GS; $o.ClosedGeneration.ArchivedStatePath = (Join-Path $GS.Guard 'g1.txt'); Write-I2CJson (Get-I2CUsPath $GS) $o }, @('UninstalledStateNotReconfirmable')),
        @('unfinished-journal', { [void](New-I2CForgedActiveJournal $GS) }, @('RecoveryRequired', 'UninstalledStateNotReconfirmable')),
        @('uninstalling-marker-without-journal', { [System.IO.File]::WriteAllText((Get-I2CUmPath $GS), '{"State":"Uninstalling","TxnId":"T0777","Operation":"Uninstall","SchemaVersion":1}', $script:Utf8) }, @('RecoveryRequired')),
        @('installing-marker', { [System.IO.File]::WriteAllText((Join-Path $GP.StateRoot 'installing.json'), '{"State":"Installing","TxnId":"T0778","Operation":"Install","SchemaVersion":1}', $script:Utf8) }, @('RecoveryRequired')))
    foreach ($a in $ambiguous) {
        Restore-I2ATree $GS.Root $snapB
        Release-I2AHeld; Reset-I2AFault; $global:I2AFH.IdCounter = $bIdBase; $global:I2AFH.Tick = $bTickBase
        & $a[1]
        $beforeFull = Get-I2BFullTree $GS
        $r = Invoke-GRun
        [void](Assert-I2A ('AU-ambiguous-' + $a[0] + '-never-completed') (($r.Succeeded -eq $false) -and ($r.AlreadyUninstalled -ne $true) -and ($r.StateCommitted -ne $true) -and ($a[2] -contains [string]$r.ErrorCode) -and (Same $beforeFull (Get-I2BFullTree $GS))) "code=$($r.ErrorCode) (want one of $($a[2] -join '/')) succeeded=$($r.Succeeded) reasons=[$((Get-I2CReasonCodes $r) -join ',')]: nothing changed, so the wrapper must not unregister or self-delete")
    }
    Uninstall-I2AHarness
    Remove-I2ASandbox $GS.Root
}

Remove-I2ASandbox $H.Root
Remove-I2ASandbox $HL.Root
Remove-I2ASandbox $L.Root
$faultEndedUtc = [DateTime]::UtcNow.ToString('o')
$inputAfter = Get-I2CInputManifest
Write-I2CInputManifest (Join-Path $EvidenceDir 'input-sha256-after.txt') $inputAfter 'after'
$inputSame = Write-I2CInputVerify (Join-Path $EvidenceDir 'input-verify.txt') $inputBefore $inputAfter $faultStartedUtc $faultEndedUtc
[void](Assert-I2A 'INPUT-sha256-unchanged-during-this-run' $inputSame "$(@($inputBefore).Count) input files hashed at the start and at the end (input-verify.txt); a changed input invalidates this run as commit evidence")
Complete-I2ATests