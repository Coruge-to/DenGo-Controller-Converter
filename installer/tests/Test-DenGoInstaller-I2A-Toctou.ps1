# I2-A TOCTOU contract tests (core level): conditional replace / delete with a displaced file, crash + restart recovery, several items, derived names,
# out-of-scope characterizations, static structure. Contract: i2a-toctou-contract.md 0A.1 / 0A.5 / 0A.6, plan: i2a-toctou-red-plan.md 8.7.
# RED stage: run WITHOUT -Contract (every assertion has a class and an expected reason; exit 0 only when nothing is UNEXPECTED).
# After the GREEN implementation: run WITH -Contract (plain PASS / FAIL, exit 1 on any FAIL).
param([switch]$Contract, [string]$EvidenceDir = '', [string]$PostLoad = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$corePath = Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1'
. $corePath
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2A.Toctou.TestSupport.ps1')
$script:TxContract = [bool]$Contract
$script:TxName = 'I2A-Toctou'
Install-I2AHarness
# validation hook: a script that is dot-sourced after the core (used to check the RED expectations against the approved contract's prototype)
if ($PostLoad.Length -gt 0) { . $PostLoad }

$script:tpPath = ''
$script:tpText = 'THIRD-PARTY-A'
$actWrite = { TP-Write $script:tpPath $script:tpText }
$actRename = { TP-Rename $script:tpPath $script:tpText }
$actDelete = { TP-Delete $script:tpPath }
function Obs-Live($C, [string]$DestText, [string]$Tp) {
    $r = $C.R
    if ($null -eq $r) { return 'other:exception' }
    if ($r.Succeeded -and ($DestText -cne $Tp)) { return 'silent-overwrite' }
    if ($r.Succeeded -and ($DestText -ceq $Tp)) { return 'other:succeeded-with-third-party-content' }
    return 'other:code=' + $r.Code + ' rb=' + $r.RollbackState
}
function Tamper-Case($Fx, [string]$Pattern, [string]$Path, [scriptblock]$Act, [string]$Text = 'THIRD-PARTY-A') {
    $script:tpPath = $Path; $script:tpText = $Text
    return (Invoke-TxCase $Fx ({ Add-TxInj $Pattern 1 $Act }))
}
function Marker-Retained($Fx) { return (Test-TxMarker $Fx) }
# Fixture-only normalisation of ONE derived name before a case builds a directory / reparse point there (a correct swap has already left the real displaced file at that name).
# It touches exactly the expected derived path, only inside the fixture root, never enters a reparse point, and removes nothing else.
function Reset-TxFixtureName($Fx, [string]$Path, [string]$Expected) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, [System.IO.Path]::GetFullPath($Expected), [System.StringComparison]::OrdinalIgnoreCase)) { throw ('fixture name is not the derived name: ' + $full) }
    $root = [System.IO.Path]::GetFullPath($Fx.Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { throw ('fixture name is outside the fixture root: ' + $full) }
    if ([System.IO.Directory]::Exists($full)) {
        if (([System.IO.File]::GetAttributes($full) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { [System.IO.Directory]::Delete($full) }
        else { Remove-I2ADirSafe $full }
    } elseif ([System.IO.File]::Exists($full)) {
        [System.IO.File]::SetAttributes($full, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($full)
    }
}

# =====================================================================================================================
# W  Apply Write / Replace  (a destination that exists)
# =====================================================================================================================
$fxW = New-TxFx 'w' @(@{ Rel = 'd\a.dll'; Op = 'Write'; Pre = 'old-A'; Post = 'new-A' })
$aDll = Join-Path $fxW.Dest 'd\a.dll'

# ---- W-01 unchanged replace
$c = Invoke-TxCase $fxW $null @{ Record = $true }
$r = $c.R; $L = @($c.Labels)
Add-TxEvidence @{ id = 'CENSUS-REPLACE-CORE'; all = $L.Count; labels = $L }
Assert-Tx 'W-01a-unchanged-replace-succeeds' 'GUARD' '' (($r.Succeeded -eq $true) -and ((Txt $aDll) -ceq 'new-A')) "succeeded=$($r.Succeeded) code=$($r.Code) dest=[$(Txt $aDll)]"
Assert-Tx 'W-01b-no-displaced-or-tmp-residue-and-no-marker-after-success' 'GUARD' '' ((@(Get-TxResidue $fxW).Count -eq 0) -and (@(Get-TxTmp $fxW).Count -eq 0) -and (-not (Test-TxMarker $fxW))) "residue=$(@(Get-TxResidue $fxW).Count) tmp=$(@(Get-TxTmp $fxW).Count)"
$iSha = Get-TxIdx $L '^before:Fs-Sha256:.*\.dengo\.old$'; $iDel = Get-TxIdx $L '^before:Fs-Delete:.*\.dengo\.old$'; $iApp = Get-TxIdx $L '^before:Journal:Applied#0$'
Assert-Tx 'W-01c-displaced-sha-is-measured-then-deleted-before-Applied' 'RED' 'no-point' (($iSha -ge 0) -and ($iDel -gt $iSha) -and ($iApp -gt $iDel)) $(if ($iSha -lt 0) { 'no-point' } else { 'other' }) "displacedSha@$iSha displacedDelete@$iDel Applied@$iApp"

# ---- W-02 a third party writes the destination between the last probe and the replacement
$c = Tamper-Case $fxW '^after:Fs-ProbeExclusive:a\.dll$' $aDll $actWrite
$r = $c.R; $dest = Txt $aDll; $obs = Obs-Live $c $dest 'THIRD-PARTY-A'
Assert-Tx 'W-02-0-injection-fired' 'GUARD' '' (Get-TxInjFired 0) 'the third-party write happened'
Assert-Tx 'W-02a-third-party-write-is-not-reported-as-success-PlanStale' 'RED' 'silent-overwrite' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'W-02b-third-party-content-is-preserved' 'RED' 'silent-overwrite' ($dest -ceq 'THIRD-PARTY-A') $obs "dest=[$dest]"
Assert-Tx 'W-02c-manual-check-required-and-marker-retained' 'RED' 'silent-overwrite' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxW)) $obs "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxW) rollback=$($r.RollbackState)"
Assert-Tx 'W-02d-no-displaced-or-tmp-residue' 'GUARD' '' ((@(Get-TxResidue $fxW).Count -eq 0) -and (@(Get-TxTmp $fxW).Count -eq 0)) "residue=$(@(Get-TxResidue $fxW).Count) tmp=$(@(Get-TxTmp $fxW).Count)"

# ---- W-03 the third party saves atomically (rename over the destination)
$c = Tamper-Case $fxW '^after:Fs-ProbeExclusive:a\.dll$' $aDll $actRename 'THIRD-PARTY-RENAMED'
$r = $c.R; $dest = Txt $aDll; $obs = Obs-Live $c $dest 'THIRD-PARTY-RENAMED'
Assert-Tx 'W-03-0-injection-fired' 'GUARD' '' (Get-TxInjFired 0) 'the rename-over happened'
Assert-Tx 'W-03a-rename-over-is-not-reported-as-success-PlanStale' 'RED' 'silent-overwrite' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'W-03b-renamed-in-content-is-preserved' 'RED' 'silent-overwrite' ($dest -ceq 'THIRD-PARTY-RENAMED') $obs "dest=[$dest]"
Assert-Tx 'W-03c-manual-check-required-and-marker-retained' 'RED' 'silent-overwrite' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxW)) $obs "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxW)"

# ---- W-04 the third party deletes the destination in the window (fail closed: nothing is recreated, no displaced file appears)
$c = Tamper-Case $fxW '^after:Fs-ProbeExclusive:a\.dll$' $aDll $actDelete
$r = $c.R
Assert-Tx 'W-04a-third-party-delete-is-not-success' 'GUARD' '' ($r.Succeeded -eq $false) "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'W-04b-destination-is-not-recreated-and-no-displaced-file-appears' 'GUARD' '' ((-not [System.IO.File]::Exists($aDll)) -and (@(Get-TxResidue $fxW).Count -eq 0)) "dest=[$(Txt $aDll)] residue=$(@(Get-TxResidue $fxW).Count)"
Assert-Tx 'W-04c-manual-check-required-and-marker-retained' 'GUARD' '' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxW)) "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxW) rollback=$($r.RollbackState)"

# ---- W-05 double modification: a second change while the first change is being put back -> both contents are kept
$script:tpPath = $aDll
$c = Invoke-TxCase $fxW ({
    Add-TxInj '^after:Fs-ProbeExclusive:a\.dll$' 1 { TP-Write $script:tpPath 'THIRD-PARTY-A' }
    Add-TxInj '^after:Fs-Sha256:.*\.dengo\.old$' 1 { TP-Write $script:tpPath 'THIRD-PARTY-B' }
})
$r = $c.R; $dest = Txt $aDll; $inj2 = Get-TxInjFired 1
$keptA = @(Get-TxResidue $fxW | Where-Object { [System.IO.File]::Exists($_) -and ((Txt $_) -ceq 'THIRD-PARTY-A') }).Count
$obs = $(if (-not $inj2) { 'no-point' } else { 'other:dest=' + $dest })
Assert-Tx 'W-05a-a-point-exists-where-the-displaced-file-has-been-measured' 'RED' 'no-point' $inj2 $obs "second injection (after the displaced SHA) fired=$inj2"
Assert-Tx 'W-05b-double-change-keeps-both-contents-and-asks-for-manual-check' 'RED' 'no-point' (($r.Succeeded -eq $false) -and ($dest -ceq 'THIRD-PARTY-B') -and ($keptA -eq 1) -and ($r.ManualCheckRequired -eq $true)) $obs "dest=[$dest] displacedHoldsA=$keptA manual=$($r.ManualCheckRequired) succeeded=$($r.Succeeded)"

# ---- W-06/07/08 the displaced name already exists (file / directory / reparse point): nothing is touched, nothing is replaced
$stray = Get-TxDisplaced $aDll 'T0001' 0
$c = Invoke-TxCase $fxW ({ [System.IO.File]::WriteAllText($stray, 'STRAY', $script:TxUtf8) })
$r = $c.R
Assert-Tx 'W-06a-existing-displaced-file-is-untouched' 'GUARD' '' ((Txt $stray) -ceq 'STRAY') "stray=[$(Txt $stray)]"
Assert-Tx 'W-06b-existing-displaced-file-stops-the-replacement' 'RED' 'displaced-not-checked' (($r.Succeeded -eq $false) -and ((Txt $aDll) -ceq 'old-A')) $(if ($r.Succeeded) { 'displaced-not-checked' } else { 'other' }) "succeeded=$($r.Succeeded) code=$($r.Code) dest=[$(Txt $aDll)]"

$c = Invoke-TxCase $fxW ({ [System.IO.Directory]::CreateDirectory($stray) | Out-Null; [System.IO.File]::WriteAllText((Join-Path $stray 'inside.txt'), 'INSIDE', $script:TxUtf8) })
$r = $c.R
Assert-Tx 'W-07a-displaced-name-directory-is-untouched' 'GUARD' '' ([System.IO.Directory]::Exists($stray) -and ((Txt (Join-Path $stray 'inside.txt')) -ceq 'INSIDE')) "dir=$([System.IO.Directory]::Exists($stray))"
Assert-Tx 'W-07b-displaced-name-directory-stops-the-replacement' 'RED' 'displaced-not-checked' (($r.Succeeded -eq $false) -and ((Txt $aDll) -ceq 'old-A')) $(if ($r.Succeeded) { 'displaced-not-checked' } else { 'other' }) "succeeded=$($r.Succeeded) code=$($r.Code) dest=[$(Txt $aDll)]"

$tgt = Join-Path $fxW.Root 'Guard\tgt'
$c = Invoke-TxCase $fxW ({ New-TxJunction $stray $tgt; [System.IO.File]::WriteAllText((Join-Path $tgt 'canary.txt'), 'CANARY', $script:TxUtf8) })
$r = $c.R
Assert-Tx 'W-08a-reparse-point-at-the-displaced-name-and-its-target-are-untouched' 'GUARD' '' ([System.IO.Directory]::Exists($stray) -and ((Txt (Join-Path $tgt 'canary.txt')) -ceq 'CANARY')) "junction=$([System.IO.Directory]::Exists($stray)) canary=[$(Txt (Join-Path $tgt 'canary.txt'))]"
Assert-Tx 'W-08b-reparse-point-at-the-displaced-name-stops-the-replacement' 'RED' 'displaced-not-checked' (($r.Succeeded -eq $false) -and ((Txt $aDll) -ceq 'old-A')) $(if ($r.Succeeded) { 'displaced-not-checked' } else { 'other' }) "succeeded=$($r.Succeeded) code=$($r.Code) dest=[$(Txt $aDll)]"

# ---- W-09 DgFs-Replace: arguments omitted = today's behaviour; a displaced path = one physical replacement that leaves the old content there
Reset-TxFx $fxW
$s9 = New-I2ASandbox 'tx-w09'
try {
    $t1 = Join-Path $s9 't1.new'; $a1 = Join-Path $s9 'a1.dat'
    [System.IO.File]::WriteAllText($t1, 'NEW', $script:TxUtf8); [System.IO.File]::WriteAllText($a1, 'OLD', $script:TxUtf8)
    DgFs-Replace $t1 $a1
    Assert-Tx 'W-09a-arguments-omitted-behave-as-before' 'GUARD' '' (((Txt $a1) -ceq 'NEW') -and (-not [System.IO.File]::Exists($t1)) -and (@([System.IO.Directory]::GetFileSystemEntries($s9)).Count -eq 1)) "dest=[$(Txt $a1)] tmpConsumed=$(-not [System.IO.File]::Exists($t1)) entries=$(@([System.IO.Directory]::GetFileSystemEntries($s9)).Count)"
    $t2 = Join-Path $s9 't2.new'; $a2 = Join-Path $s9 'a2.dat'; $d2 = Join-Path $s9 'a2.old'
    [System.IO.File]::WriteAllText($t2, 'NEW', $script:TxUtf8); [System.IO.File]::WriteAllText($a2, 'OLD', $script:TxUtf8)
    $err9 = ''
    try { DgFs-Replace $t2 $a2 $d2 } catch { $err9 = $_.Exception.GetType().Name }
    $ok9 = (((Txt $a2) -ceq 'NEW') -and ((Txt $d2) -ceq 'OLD') -and (-not [System.IO.File]::Exists($t2)))
    Assert-Tx 'W-09b-a-displaced-path-receives-the-old-content-in-one-physical-replacement' 'RED' 'no-signature' $ok9 $(if ((Txt $d2) -ceq '<missing>') { 'no-signature' } else { 'other' }) "dest=[$(Txt $a2)] displaced=[$(Txt $d2)] error=[$err9]"
} finally { Remove-I2ASandbox $s9 }

# ---- W-14 the cleanup is refused by the OS because the displaced file is held by an explicit file handle (plain data file; no executable image involved)
#      Fixed subject: "the cleanup is refused and the run fails closed", not "a running EXE".
$fxE = New-TxFx 'e' @(@{ Rel = 'd\data.bin'; Op = 'Write'; Pre = 'placeholder-data'; Post = 'replacement-data' })
$dat = Join-Path $fxE.Dest 'd\data.bin'
$dispE = Get-TxDisplaced $dat 'T0001' 0
$preExeSha = Get-I2AFileSha $dat
$script:holdPath = $dispE
$script:holdStream = $null
try {
    $c = Invoke-TxCase $fxE ({
        Add-TxInj '^after:Fs-Replace:data\.bin$' 1 {
            # read-only handle that shares Read only: the displaced file stays readable (SHA checks work) but can be neither deleted nor replaced
            $script:holdStream = New-Object System.IO.FileStream($script:holdPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        }
    })
    $r = $c.R
    $resE = @(Get-TxResidue $fxE)
    $obs = $(if (($null -ne $r) -and $r.Succeeded -and ($resE.Count -eq 0)) { 'no-cleanup-contract' } else { 'other:rb=' + $(if ($null -ne $r) { $r.RollbackState } else { 'none' }) + ' residue=' + $resE.Count })
    Assert-Tx 'W-14-0-the-program-was-started-in-the-window' 'GUARD' '' (($null -ne $script:holdStream) -and (Get-TxInjFired 0)) "displaced file held by an explicit handle=$($null -ne $script:holdStream)"
    Assert-Tx 'W-14a-refused-cleanup-is-not-success' 'RED' 'no-cleanup-contract' (($null -ne $r) -and ($r.Succeeded -eq $false)) $obs "succeeded=$($r.Succeeded) code=$($r.Code) rollback=$($r.RollbackState)"
    Assert-Tx 'W-14b-refused-cleanup-is-RollbackIncomplete-with-manual-check-and-marker' 'RED' 'no-cleanup-contract' (($null -ne $r) -and (@('RollbackIncomplete', 'RepairRequired') -contains $r.RollbackState) -and ($r.ManualCheckRequired -eq $true) -and (Test-TxMarker $fxE)) $obs "rollback=$($r.RollbackState) manual=$($r.ManualCheckRequired) marker=$(Test-TxMarker $fxE)"
    Assert-Tx 'W-14c-the-displaced-old-image-is-retained-untouched' 'RED' 'no-cleanup-contract' (($resE.Count -eq 1) -and ((Get-I2AFileSha $resE[0]) -ceq $preExeSha)) $obs "residue=$($resE.Count)"
    $m1 = Get-TxMap $fxE
    $rA = Invoke-TxRecover $fxE
    $m2 = Get-TxMap $fxE
    Assert-Tx 'W-14d-recovery-while-the-refusal-lasts-fails-closed-and-changes-nothing' 'GUARD' '' (($rA.Outcome -ceq 'RollbackIncomplete') -and ($rA.ManualCheckRequired -eq $true) -and ((Get-TxChanged $m1 $m2) -eq 0) -and [System.IO.File]::Exists($dispE)) "outcome=$($rA.Outcome) changes=$(Get-TxChanged $m1 $m2)"
    if ($null -ne $script:holdStream) { $script:holdStream.Dispose(); $script:holdStream = $null }
    $rB = Invoke-TxRecover $fxE
    $rC = Invoke-TxRecover $fxE
    Assert-Tx 'W-14e-after-the-refusal-ends-recovery-completes-and-the-next-one-is-NotNeeded' 'GUARD' '' ((-not [System.IO.File]::Exists($dispE)) -and (-not (Test-TxMarker $fxE)) -and ($rC.Outcome -ceq 'NotNeeded') -and ((Txt $dat) -ceq 'placeholder-data')) "displaced=$([System.IO.File]::Exists($dispE)) marker=$(Test-TxMarker $fxE) outcome2=$($rB.Outcome) outcome3=$($rC.Outcome) dest=[$(Txt $dat)]"
} finally {
    if ($null -ne $script:holdStream) { try { $script:holdStream.Dispose() } catch { }; $script:holdStream = $null }
}

# =====================================================================================================================
# K  crash + restart on the Write / Replace path (frozen states; the displaced file is placed by hand at the derived name = the physical state after the swap)
# =====================================================================================================================
$disp0 = Get-TxDisplaced $aDll 'T0001' 0
$swapRx = '^after:Fs-Replace:a\.dll$'
# --- K-01 swap done, displaced file holds the planned pre-image, nothing verified yet
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ [System.IO.File]::WriteAllText($disp0, 'old-A', $script:TxUtf8) })
Assert-Tx 'K-00-state-built-swap-done-pre-image-displaced' 'GUARD' '' (($b.Fired.Length -gt 0) -and ((Txt $aDll) -ceq 'new-A') -and ((Txt $disp0) -ceq 'old-A') -and (Test-TxMarker $fxW)) "fired=$($b.Fired) dest=[$(Txt $aDll)]"
$x = Invoke-TxRecover2 $fxW
$res1 = @(Get-TxResidue $fxW).Count
Assert-Tx 'K-01a-restart-rolls-back-to-T0' 'GUARD' '' (($x.R1.Outcome -ceq 'RolledBack') -and ((Txt $aDll) -ceq 'old-A') -and (-not $x.Marker1)) "outcome=$($x.R1.Outcome) dest=[$(Txt $aDll)] marker=$($x.Marker1)"
Assert-Tx 'K-01b-restart-removes-the-owned-displaced-file-after-the-restore' 'RED' 'residue-orphan' ($res1 -eq 0) $(if ($res1 -gt 0) { 'residue-orphan' } else { 'other' }) "residue=$res1"
Assert-Tx 'K-01c-second-recovery-changes-nothing' 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2) outcome2=$($x.R2.Outcome)"

# --- K-02 mismatch handling: the displaced file holds somebody else's content
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ [System.IO.File]::WriteAllText($disp0, 'THIRD-PARTY-X', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxW
$obs = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'displaced-ignored' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'K-02a-before-the-put-back-restart-keeps-both-files-RepairRequired' 'RED' 'displaced-ignored' (($x.R1.Outcome -ceq 'RepairRequired') -and ($x.R1.ManualCheckRequired -eq $true)) $obs "outcome=$($x.R1.Outcome) manual=$($x.R1.ManualCheckRequired)"
Assert-Tx 'K-02b-before-the-put-back-nothing-is-changed' 'RED' 'displaced-ignored' ((Get-TxChanged $x.M0 $x.M1) -eq 0) $obs "changes=$(Get-TxChanged $x.M0 $x.M1) [$(Get-TxDiff $x.M0 $x.M1)]"
Assert-Tx 'K-02c-the-third-party-content-in-the-displaced-file-is-kept' 'GUARD' '' ((Txt $disp0) -ceq 'THIRD-PARTY-X') "displaced=[$(Txt $disp0)]"
Assert-Tx 'K-02d-second-recovery-changes-nothing' 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2)"
# after the put-back: the destination holds the third-party content, no displaced file
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ [System.IO.File]::WriteAllText($aDll, 'THIRD-PARTY-X', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxW
Assert-Tx 'K-02e-after-the-put-back-restart-is-RepairRequired-and-changes-nothing' 'GUARD' '' (($x.R1.Outcome -ceq 'RepairRequired') -and ((Get-TxChanged $x.M0 $x.M1) -eq 0) -and ((Txt $aDll) -ceq 'THIRD-PARTY-X')) "outcome=$($x.R1.Outcome) changes=$(Get-TxChanged $x.M0 $x.M1)"
Assert-Tx 'K-02f-second-recovery-is-the-same' 'GUARD' '' (($x.R2.Outcome -ceq 'RepairRequired') -and ((Get-TxChanged $x.M1 $x.M2) -eq 0)) "outcome2=$($x.R2.Outcome)"
# double modification: destination B, displaced A -> both kept
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ [System.IO.File]::WriteAllText($aDll, 'THIRD-PARTY-B', $script:TxUtf8); [System.IO.File]::WriteAllText($disp0, 'THIRD-PARTY-A', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxW
Assert-Tx 'K-02g-double-change-restart-keeps-both-RepairRequired' 'GUARD' '' (($x.R1.Outcome -ceq 'RepairRequired') -and ((Get-TxChanged $x.M0 $x.M1) -eq 0) -and ((Txt $aDll) -ceq 'THIRD-PARTY-B') -and ((Txt $disp0) -ceq 'THIRD-PARTY-A')) "outcome=$($x.R1.Outcome) changes=$(Get-TxChanged $x.M0 $x.M1)"

# --- K-03 cleanup interrupted / refused
$b = Build-TxFrozen $fxW $swapRx 1 $null $null
$x = Invoke-TxRecover2 $fxW
Assert-Tx 'K-03a-displaced-already-cleaned-before-Applied-rolls-back-to-T0' 'GUARD' '' (($x.R1.Outcome -ceq 'RolledBack') -and ((Txt $aDll) -ceq 'old-A') -and (-not $x.Marker1) -and (@(Get-TxResidue $fxW).Count -eq 0)) "outcome=$($x.R1.Outcome) dest=[$(Txt $aDll)]"
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ [System.IO.File]::WriteAllText($disp0, 'old-A', $script:TxUtf8); [System.IO.File]::SetAttributes($disp0, [System.IO.FileAttributes]::ReadOnly) })
$x = Invoke-TxRecover2 $fxW
$obsC = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'no-cleanup-contract' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'K-03b-refused-cleanup-at-restart-is-RollbackIncomplete-with-manual-check' 'RED' 'no-cleanup-contract' (($x.R1.Outcome -ceq 'RollbackIncomplete') -and ($x.R1.ManualCheckRequired -eq $true)) $obsC "outcome=$($x.R1.Outcome) manual=$($x.R1.ManualCheckRequired)"
Assert-Tx 'K-03c-refused-cleanup-keeps-the-marker' 'RED' 'no-cleanup-contract' ($x.Marker1 -eq $true) $obsC "marker=$($x.Marker1)"
Assert-Tx 'K-03d-refused-cleanup-keeps-the-displaced-file' 'GUARD' '' ([System.IO.File]::Exists($disp0) -and ((Txt $disp0) -ceq 'old-A')) "displaced=[$(Txt $disp0)]"
Assert-Tx 'K-03e-second-recovery-does-no-further-damage' 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2) outcome2=$($x.R2.Outcome)"
[System.IO.File]::SetAttributes($disp0, [System.IO.FileAttributes]::Normal)
$r3 = Invoke-TxRecover $fxW
Assert-Tx 'K-03f-after-the-refusal-ends-recovery-converges-and-removes-the-displaced-file' 'RED' 'residue-orphan' ((-not [System.IO.File]::Exists($disp0)) -and (-not (Test-TxMarker $fxW))) $(if ([System.IO.File]::Exists($disp0)) { 'residue-orphan' } else { 'other' }) "displaced=$([System.IO.File]::Exists($disp0)) marker=$(Test-TxMarker $fxW) outcome3=$($r3.Outcome)"

# --- K-04 ownership: every condition broken on its own -> the file is not ours -> never touched (a name that is not the derived name is not even looked at)
foreach ($v in @(
    @{ Id = 'name-other-transaction'; Path = (Get-TxDisplaced $aDll 'T0009' 0) },
    @{ Id = 'name-other-item'; Path = (Get-TxDisplaced $aDll 'T0001' 7) },
    @{ Id = 'name-other-suffix'; Path = ($aDll + '.T0001.0000.dengo.olx') },
    @{ Id = 'location-other-directory'; Path = (Join-Path (Join-Path $fxW.Dest 'other') ([System.IO.Path]::GetFileName($disp0))) })) {
    $vp = $v.Path
    $b = Build-TxFrozen $fxW $swapRx 1 $null ({ [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($vp)) | Out-Null; [System.IO.File]::WriteAllText($vp, 'old-A', $script:TxUtf8) })
    $x = Invoke-TxRecover2 $fxW
    Assert-Tx ('K-04-own-' + $v.Id + '-is-never-touched') 'GUARD' '' ([System.IO.File]::Exists($vp) -and ((Txt $vp) -ceq 'old-A') -and ($x.R1.Outcome -ceq 'RolledBack') -and ((Txt $aDll) -ceq 'old-A')) "outcome=$($x.R1.Outcome) file=[$(Txt $vp)] dest=[$(Txt $aDll)]"
}
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ Reset-TxFixtureName $fxW $disp0 (Get-TxDisplaced $aDll 'T0001' 0); [System.IO.Directory]::CreateDirectory($disp0) | Out-Null; [System.IO.File]::WriteAllText((Join-Path $disp0 'inside.txt'), 'INSIDE', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxW
$obs = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'displaced-ignored' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'K-04-own-directory-at-the-derived-name-is-RepairRequired-and-untouched' 'RED' 'displaced-ignored' (($x.R1.Outcome -ceq 'RepairRequired') -and ((Get-TxChanged $x.M0 $x.M1) -eq 0)) $obs "outcome=$($x.R1.Outcome) changes=$(Get-TxChanged $x.M0 $x.M1)"
Assert-Tx 'K-04-own-directory-contents-are-kept' 'GUARD' '' ((Txt (Join-Path $disp0 'inside.txt')) -ceq 'INSIDE') "inside=[$(Txt (Join-Path $disp0 'inside.txt'))]"
$tgt2 = Join-Path $fxW.Root 'Guard\tgt2'
$b = Build-TxFrozen $fxW $swapRx 1 $null ({ Reset-TxFixtureName $fxW $disp0 (Get-TxDisplaced $aDll 'T0001' 0); New-TxJunction $disp0 $tgt2; [System.IO.File]::WriteAllText((Join-Path $tgt2 'canary.txt'), 'CANARY', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxW
$obs = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'displaced-ignored' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'K-04-own-reparse-point-at-the-derived-name-is-RepairRequired' 'RED' 'displaced-ignored' ($x.R1.Outcome -ceq 'RepairRequired') $obs "outcome=$($x.R1.Outcome)"
Assert-Tx 'K-04-own-reparse-point-and-its-target-are-kept' 'GUARD' '' ([System.IO.Directory]::Exists($disp0) -and ((Txt (Join-Path $tgt2 'canary.txt')) -ceq 'CANARY')) "junction=$([System.IO.Directory]::Exists($disp0))"
# no Intent for the item: a file with the derived name is not ours
$b = Build-TxFrozen $fxW '^before:Journal:Intent#0$' 1 $null ({ [System.IO.File]::WriteAllText($disp0, 'old-A', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxW
$obs = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'displaced-ignored' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'K-04-own-no-intent-for-the-item-is-RepairRequired-and-untouched' 'RED' 'displaced-ignored' (($x.R1.Outcome -ceq 'RepairRequired') -and ((Get-TxChanged $x.M0 $x.M1) -eq 0)) $obs "fired=$($b.Fired) outcome=$($x.R1.Outcome) changes=$(Get-TxChanged $x.M0 $x.M1)"
Assert-Tx 'K-04-own-no-intent-file-is-kept' 'GUARD' '' ((Txt $disp0) -ceq 'old-A') "file=[$(Txt $disp0)]"

# --- K-05 real crash points inside the conditional replacement (the labels exist only when the displaced file is measured / deleted)
$kPoints = @(
    @{ Id = 'K-05a-crash-right-after-the-swap-before-the-displaced-sha'; Rx = '^before:Fs-Sha256:.*\.dengo\.old$'; Tamper = $false },
    @{ Id = 'K-05b-crash-right-after-the-displaced-sha'; Rx = '^after:Fs-Sha256:.*\.dengo\.old$'; Tamper = $false },
    @{ Id = 'K-05c-crash-just-before-the-displaced-delete'; Rx = '^before:Fs-Delete:.*\.dengo\.old$'; Tamper = $false },
    @{ Id = 'K-05d-crash-just-after-the-displaced-delete-before-Applied'; Rx = '^after:Fs-Delete:.*\.dengo\.old$'; Tamper = $false },
    @{ Id = 'K-05e-crash-before-the-put-back-of-a-mismatch'; Rx = '^before:Fs-Replace:a\.dll$'; Tamper = $true; Nth = 2 },
    @{ Id = 'K-05f-crash-after-the-put-back-of-a-mismatch'; Rx = '^after:Fs-Replace:a\.dll$'; Tamper = $true; Nth = 2 })
foreach ($kp in $kPoints) {
    $nth = $(if ($kp.ContainsKey('Nth')) { [int]$kp.Nth } else { 1 })
    $script:tpPath = $aDll; $script:tpText = 'THIRD-PARTY-A'
    $setup = $(if ($kp.Tamper) { { Add-TxInj '^after:Fs-ProbeExclusive:a\.dll$' 1 { TP-Write $script:tpPath $script:tpText } } } else { $null })
    $b = Build-TxFrozen $fxW $kp.Rx $nth $setup $null
    $fired = ($b.Fired.Length -gt 0)
    Assert-Tx ($kp.Id + '-the-point-exists-and-fires') 'RED' 'no-point' $fired $(if ($fired) { 'other' } else { 'no-point' }) "fired=[$($b.Fired)]"
    if ($fired) {
        $x = Invoke-TxRecover2 $fxW
        $okT0 = ((-not $kp.Tamper) -and ($x.R1.Outcome -ceq 'RolledBack') -and ((Txt $aDll) -ceq 'old-A') -and (@(Get-TxResidue $fxW).Count -eq 0))
        $okKeep = ($kp.Tamper -and ($x.R1.Outcome -ceq 'RepairRequired') -and ((Get-TxChanged $x.M0 $x.M1) -eq 0))
        Assert-Tx ($kp.Id + '-restart-converges-to-the-contract-state') 'RED' 'no-point' ($okT0 -or $okKeep) 'other' "outcome=$($x.R1.Outcome) dest=[$(Txt $aDll)] residue=$(@(Get-TxResidue $fxW).Count)"
    } else {
        Assert-Tx ($kp.Id + '-restart-converges-to-the-contract-state') 'RED' 'no-point' $false 'no-point' 'the crash point does not exist, so no restart state can be built'
    }
}

# =====================================================================================================================
# D  Apply Delete
# =====================================================================================================================
$fxD = New-TxFx 'd' @(@{ Rel = 'd\x.dll'; Op = 'Delete'; Pre = 'old-X'; Post = $null }) 'Uninstall'
$xDll = Join-Path $fxD.Dest 'd\x.dll'
$dispX = Get-TxDisplaced $xDll 'T0001' 0

# ---- D-L4 unchanged delete
$c = Invoke-TxCase $fxD $null @{ Record = $true }
$r = $c.R; $L = @($c.Labels)
Add-TxEvidence @{ id = 'CENSUS-DELETE-CORE'; all = $L.Count; labels = $L }
Assert-Tx 'D-L4a-unchanged-delete-succeeds-and-leaves-nothing' 'GUARD' '' (($r.Succeeded -eq $true) -and (-not [System.IO.File]::Exists($xDll)) -and (@(Get-TxResidue $fxD).Count -eq 0) -and (-not (Test-TxMarker $fxD))) "succeeded=$($r.Succeeded) dest=[$(Txt $xDll)] residue=$(@(Get-TxResidue $fxD).Count)"
$iMove = Get-TxIdx $L '^before:Fs-MoveNew:.*\.dengo\.old$'; $iSha = Get-TxIdx $L '^before:Fs-Sha256:.*\.dengo\.old$' ($iMove + 1); $iApp = Get-TxIdx $L '^before:Journal:Applied#0$'
$iDel = Get-TxIdx $L '^before:Fs-Delete:.*\.dengo\.old$'; $iVer = Get-TxIdx $L '^before:Journal:Verified#0$'
Assert-Tx 'D-L4b-order-Move-aside-then-displaced-sha-then-Applied-then-cleanup-then-Verified' 'RED' 'no-point' (($iMove -ge 0) -and ($iSha -gt $iMove) -and ($iApp -gt $iSha) -and ($iDel -gt $iApp) -and ($iVer -gt $iDel)) $(if ($iMove -lt 0) { 'no-point' } else { 'other' }) "move@$iMove sha@$iSha Applied@$iApp delete@$iDel Verified@$iVer"
Assert-Tx 'D-L4c-the-destination-is-never-removed-with-a-plain-Delete' 'RED' 'no-point' ((Get-TxIdx $L '^before:Fs-Delete:x\.dll$') -lt 0) $(if ($iMove -lt 0) { 'no-point' } else { 'other' }) "plain destination delete present=$((Get-TxIdx $L '^before:Fs-Delete:x\.dll$') -ge 0)"

# ---- D-L1 third party deletes the destination after Intent, before the Move
$c = Tamper-Case $fxD '^after:Fs-ProbeExclusive:x\.dll$' $xDll $actDelete
$r = $c.R; $stateTxt = Txt $fxD.StatePath
$obs = $(if ($r.Succeeded) { 'silent-success' } else { 'other:code=' + $r.Code })
Assert-Tx 'D-L1-0-injection-fired' 'GUARD' '' (Get-TxInjFired 0) 'the third-party delete happened'
Assert-Tx 'D-L1a-third-party-delete-is-PlanStale-not-success' 'RED' 'silent-success' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'D-L1b-nothing-is-committed' 'RED' 'silent-success' ($stateTxt -ceq 'state-v1') $obs "state=[$stateTxt]"
Assert-Tx 'D-L1c-manual-check-required-and-marker-retained' 'RED' 'silent-success' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxD)) $obs "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxD)"
Assert-Tx 'D-L1d-the-deleted-file-is-not-recreated-and-no-displaced-file-appears' 'GUARD' '' ((-not [System.IO.File]::Exists($xDll)) -and (@(Get-TxResidue $fxD).Count -eq 0)) "dest=[$(Txt $xDll)] residue=$(@(Get-TxResidue $fxD).Count)"

# ---- D-L2 / D-L3 a third party writes / renames over the destination before the Move
foreach ($tc in @(@{ Id = 'D-L2'; Act = $actWrite; Text = 'THIRD-PARTY-A'; Kind = 'write' }, @{ Id = 'D-L3'; Act = $actRename; Text = 'THIRD-PARTY-RENAMED'; Kind = 'rename-over' })) {
    $c = Tamper-Case $fxD '^after:Fs-ProbeExclusive:x\.dll$' $xDll $tc.Act $tc.Text
    $r = $c.R; $dest = Txt $xDll
    $obs = $(if ($r.Succeeded -and ($dest -cne $tc.Text)) { 'silent-overwrite' } else { 'other:code=' + $r.Code })
    Assert-Tx ($tc.Id + 'a-third-party-' + $tc.Kind + '-is-PlanStale-not-success') 'RED' 'silent-overwrite' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
    Assert-Tx ($tc.Id + 'b-the-third-party-content-is-preserved') 'RED' 'silent-overwrite' ($dest -ceq $tc.Text) $obs "dest=[$dest]"
    Assert-Tx ($tc.Id + 'c-manual-check-required-and-marker-retained') 'RED' 'silent-overwrite' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxD)) $obs "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxD)"
}

# ---- D-H frozen states (the physical states the contract's observation rules A-D are about)
$aftI = '^after:Journal:Intent#0$'; $aftA = '^after:Journal:Applied#0$'
# H1 / H5: Destination missing, no displaced file, Intent, no Applied  (third-party delete, or the displaced file deleted by a third party before Applied)
foreach ($h in @(@{ Id = 'D-H1-third-party-delete-after-Intent'; Hand = { [System.IO.File]::Delete($xDll) } },
                 @{ Id = 'D-H5-displaced-file-deleted-by-a-third-party-before-Applied'; Hand = { [System.IO.File]::Move($xDll, $dispX); [System.IO.File]::Delete($dispX) } })) {
    $b = Build-TxFrozen $fxD $aftI 1 $null $h.Hand
    $x = Invoke-TxRecover2 $fxD
    $obs = $(if (($x.R1.Outcome -ceq 'RolledBack') -and [System.IO.File]::Exists($xDll)) { 'recreates-third-party-delete' } else { 'other:' + $x.R1.Outcome })
    Assert-Tx ($h.Id + '-a-restart-is-RepairRequired-with-manual-check') 'RED' 'recreates-third-party-delete' (($x.R1.Outcome -ceq 'RepairRequired') -and ($x.R1.ManualCheckRequired -eq $true)) $obs "outcome=$($x.R1.Outcome) manual=$($x.R1.ManualCheckRequired)"
    Assert-Tx ($h.Id + '-b-the-destination-is-not-recreated-and-nothing-else-changes') 'RED' 'recreates-third-party-delete' (((Get-TxChanged $x.M0 $x.M1) -eq 0) -and (-not [System.IO.File]::Exists($xDll))) $obs "changes=$(Get-TxChanged $x.M0 $x.M1) [$(Get-TxDiff $x.M0 $x.M1)]"
    Assert-Tx ($h.Id + '-c-second-recovery-changes-nothing') 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2) outcome2=$($x.R2.Outcome)"
}
# H2 (B): moved aside, stopped before Applied      H3 (C): Applied, cleanup not done
foreach ($h in @(@{ Id = 'D-H2-moved-aside-stopped-before-Applied'; Rx = $aftI; Hand = { [System.IO.File]::Move($xDll, $dispX) } },
                 @{ Id = 'D-H3-Applied-cleanup-not-done'; Rx = $aftA; Hand = { [System.IO.File]::WriteAllText($dispX, 'old-X', $script:TxUtf8) } })) {
    $b = Build-TxFrozen $fxD $h.Rx 1 $null $h.Hand
    Reset-I2AFault -Record $true
    $x = Invoke-TxRecover2 $fxD
    $lab = @($global:I2AFH.AllLabels)
    $obs = $(if ([System.IO.File]::Exists($dispX)) { 'residue-orphan' } else { 'other' })
    Assert-Tx ($h.Id + '-a-restart-rolls-back-and-restores-the-destination-from-the-backup') 'GUARD' '' (($x.R1.Outcome -ceq 'RolledBack') -and ((Txt $xDll) -ceq 'old-X') -and (-not $x.Marker1)) "outcome=$($x.R1.Outcome) dest=[$(Txt $xDll)]"
    Assert-Tx ($h.Id + '-b-the-owned-displaced-file-is-removed-after-the-restore') 'RED' 'residue-orphan' (-not [System.IO.File]::Exists($dispX)) $obs "displaced=$([System.IO.File]::Exists($dispX))"
    Assert-Tx ($h.Id + '-c-second-recovery-changes-nothing') 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2) outcome2=$($x.R2.Outcome)"
    $iCp = Get-TxIdx $lab '^after:Fs-CopyFileDurable:x\.dll\.dengo\.tmp$'; $iMv = Get-TxIdx $lab '^before:Fs-MoveNew:x\.dll$' ([Math]::Max($iCp, 0))
    Assert-Tx ($h.Id + '-d-the-destination-is-restored-from-the-backup-copy-never-moved-back-from-the-displaced-file') 'GUARD' '' (($iCp -ge 0) -and ($iMv -gt $iCp)) "backup copy to tmp@$iCp then MoveNew tmp to destination@$iMv"
    $iSh = Get-TxIdx $lab '^before:Fs-Sha256:.*\.dengo\.old$' ([Math]::Max($iMv, 0)); $iDl = Get-TxIdx $lab '^before:Fs-Delete:.*\.dengo\.old$' ([Math]::Max($iMv, 0)); $iRc = Get-TxIdx $lab '^before:Journal:RollbackComplete$'
    Assert-Tx ($h.Id + '-e-after-the-restore-the-displaced-file-is-re-measured-then-deleted-before-RollbackComplete') 'RED' 'no-point' (($iSh -gt $iMv) -and ($iDl -gt $iSh) -and ($iRc -gt $iDl)) $(if ($iSh -lt 0) { 'no-point' } else { 'other' }) "restore@$iMv displacedSha@$iSh displacedDelete@$iDl RollbackComplete@$iRc"
}
# H4 (D): cleanup done, Verified not written
$b = Build-TxFrozen $fxD $aftA 1 $null $null
$x = Invoke-TxRecover2 $fxD
Assert-Tx 'D-H4-cleanup-done-before-Verified-restart-rolls-back-and-restores' 'GUARD' '' (($x.R1.Outcome -ceq 'RolledBack') -and ((Txt $xDll) -ceq 'old-X') -and (-not $x.Marker1) -and (@(Get-TxResidue $fxD).Count -eq 0)) "outcome=$($x.R1.Outcome) dest=[$(Txt $xDll)]"
Assert-Tx 'D-H4-second-recovery-changes-nothing' 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2)"
# H6: the displaced file was changed by a third party after Applied
$b = Build-TxFrozen $fxD $aftA 1 $null ({ [System.IO.File]::WriteAllText($dispX, 'THIRD-PARTY-EDIT', $script:TxUtf8) })
$x = Invoke-TxRecover2 $fxD
$obs = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'displaced-ignored' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'D-H6-a-displaced-file-changed-after-Applied-is-RepairRequired' 'RED' 'displaced-ignored' (($x.R1.Outcome -ceq 'RepairRequired') -and ($x.R1.ManualCheckRequired -eq $true)) $obs "outcome=$($x.R1.Outcome)"
Assert-Tx 'D-H6-b-nothing-is-changed-and-the-edit-is-kept' 'RED' 'displaced-ignored' (((Get-TxChanged $x.M0 $x.M1) -eq 0) -and ((Txt $dispX) -ceq 'THIRD-PARTY-EDIT')) $obs "changes=$(Get-TxChanged $x.M0 $x.M1)"
Assert-Tx 'D-H6-c-the-edit-is-kept-in-the-displaced-file' 'GUARD' '' ((Txt $dispX) -ceq 'THIRD-PARTY-EDIT') "displaced=[$(Txt $dispX)]"
Assert-Tx 'D-H6-d-second-recovery-changes-nothing' 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2)"
# H7: cleanup refused (access denied) - several recoveries on the same stuck state, then the refusal ends
$b = Build-TxFrozen $fxD $aftA 1 $null ({ [System.IO.File]::WriteAllText($dispX, 'old-X', $script:TxUtf8); [System.IO.File]::SetAttributes($dispX, [System.IO.FileAttributes]::ReadOnly) })
$x = Invoke-TxRecover2 $fxD
$obs = $(if ($x.R1.Outcome -ceq 'RolledBack') { 'no-cleanup-contract' } else { 'other:' + $x.R1.Outcome })
Assert-Tx 'D-H7-a-refused-cleanup-is-RollbackIncomplete-with-manual-check' 'RED' 'no-cleanup-contract' (($x.R1.Outcome -ceq 'RollbackIncomplete') -and ($x.R1.ManualCheckRequired -eq $true)) $obs "outcome=$($x.R1.Outcome) manual=$($x.R1.ManualCheckRequired)"
Assert-Tx 'D-H7-b-the-marker-is-retained-and-the-run-is-not-complete-success' 'RED' 'no-cleanup-contract' ($x.Marker1 -eq $true) $obs "marker=$($x.Marker1)"
Assert-Tx 'D-H7-c-the-displaced-file-is-retained' 'GUARD' '' ([System.IO.File]::Exists($dispX) -and ((Txt $dispX) -ceq 'old-X')) "displaced=[$(Txt $dispX)]"
Assert-Tx 'D-H7-d-repeated-recovery-on-the-stuck-state-changes-nothing' 'GUARD' '' ((Get-TxChanged $x.M1 $x.M2) -eq 0) "changes=$(Get-TxChanged $x.M1 $x.M2) outcome2=$($x.R2.Outcome)"
[System.IO.File]::SetAttributes($dispX, [System.IO.FileAttributes]::Normal)
$r3 = Invoke-TxRecover $fxD; $r4 = Invoke-TxRecover $fxD
Assert-Tx 'D-H7-e-after-the-refusal-ends-recovery-completes-removes-the-displaced-file-and-then-reports-NotNeeded' 'RED' 'residue-orphan' ((-not [System.IO.File]::Exists($dispX)) -and (-not (Test-TxMarker $fxD)) -and ($r4.Outcome -ceq 'NotNeeded') -and ((Txt $xDll) -ceq 'old-X')) $(if ([System.IO.File]::Exists($dispX)) { 'residue-orphan' } else { 'other' }) "displaced=$([System.IO.File]::Exists($dispX)) marker=$(Test-TxMarker $fxD) outcome3=$($r3.Outcome) outcome4=$($r4.Outcome)"

# ---- D-WIN the Delete window: every point between "the Origin copy is done" and "the file is moved aside / deleted" must be protected
$c = Invoke-TxCase $fxD $null @{ Record = $true }
$L = @($c.Labels)
$iBak = Get-TxIdx $L '^after:Fs-CopyFileDurable:0000\.bak$'
$iSwap = Get-TxIdx $L '^before:Fs-(Delete:x\.dll|MoveNew:x\.dll\..*\.dengo\.old)$'
$iMarker = Get-TxIdx $L '^after:Fs-MoveNew:uninstalling\.json$'
$winFrom = $iBak + 1; $winTo = $iSwap + 1
$winCount = $winTo - $winFrom + 1
Add-TxEvidence @{ id = 'WINDOW-DELETE-CORE'; fromPoint = $winFrom; toPoint = $winTo; points = $winCount; fromLabel = $L[$iBak]; toLabel = $L[$iSwap]; windowLabels = @($L[$iBak..$iSwap]) }
if (-not $Contract) { Assert-Tx 'D-WIN-census-HEAD-baseline-the-Delete-window-has-10-points' 'CHAR' '' ($winCount -eq 10) "window points $winFrom..$winTo = $winCount (HEAD baseline; changes after the fix, therefore skipped under -Contract)" } else { Write-Host ("DIAG | D-WIN-census-current | HEAD baseline row skipped under -Contract (kept as history in the non-contract mode). Current observation: Delete window $winFrom..$winTo = $winCount points (HEAD baseline: 10)"); Add-TxEvidence @{ id = 'D-WIN-census-current'; baselineHead = 10; observed = $winCount; from = $winFrom; to = $winTo } }
$script:tpPath = $xDll; $script:tpText = 'THIRD-PARTY-WIN'
$winRed = 0
for ($k = $winFrom; $k -le $winTo; $k++) {
    $c = Invoke-TxCase $fxD $null @{ Mode = 'ThrowAll'; Targets = [int[]]@($k); Action = 'Callback'; Callback = { TP-Write $script:tpPath $script:tpText } }
    $r = $c.R; $dest = Txt $xDll
    $obs = $(if ($null -eq $r) { 'other:exception' } elseif ($r.Succeeded -and ($dest -cne 'THIRD-PARTY-WIN')) { 'silent-overwrite' } else { 'other:code=' + $r.Code })
    Assert-Tx ('D-WIN-k{0:D2}-point{1}-third-party-write-is-protected' -f ($k - $winFrom + 1), $k) 'RED' 'silent-overwrite' (($c.Fired.Length -gt 0) -and ($r.Succeeded -eq $false) -and ($dest -ceq 'THIRD-PARTY-WIN')) $obs ("label=$($L[$k - 1]) fired=[$($c.Fired)] succeeded=$($r.Succeeded) code=$($r.Code) dest=[$dest]")
}
# the points before the window (once the transaction exists) are protected today and must stay protected
$prefFrom = $iMarker + 2; $prefTo = $winFrom - 1
$prefBad = New-Object System.Collections.ArrayList
for ($k = $prefFrom; $k -le $prefTo; $k++) {
    $c = Invoke-TxCase $fxD $null @{ Mode = 'ThrowAll'; Targets = [int[]]@($k); Action = 'Callback'; Callback = { TP-Write $script:tpPath $script:tpText } }
    $r = $c.R; $dest = Txt $xDll
    if (-not (($c.Fired.Length -gt 0) -and ($r.Succeeded -eq $false) -and ($dest -ceq 'THIRD-PARTY-WIN'))) { [void]$prefBad.Add(('{0}:{1}' -f $k, $L[$k - 1])) }
}
Assert-Tx 'D-PREFIX-points-before-the-window-stay-protected' 'GUARD' '' ($prefBad.Count -eq 0) ("points $prefFrom..$prefTo (" + ($prefTo - $prefFrom + 1) + ") unprotected: " + (($prefBad | Select-Object -First 4) -join ' '))

# =====================================================================================================================
# M  several items in one transaction
# =====================================================================================================================
$fxM = New-TxFx 'm' @(
    @{ Rel = 'd\a.dll'; Op = 'Write'; Pre = 'old-A'; Post = 'new-A' },
    @{ Rel = 'd\b.dll'; Op = 'Write'; Pre = 'old-B'; Post = 'new-B' },
    @{ Rel = 'd\c.dll'; Op = 'Write'; Pre = 'old-C'; Post = 'new-C' })
$mA = Join-Path $fxM.Dest 'd\a.dll'; $mB = Join-Path $fxM.Dest 'd\b.dll'; $mC = Join-Path $fxM.Dest 'd\c.dll'
$c = Invoke-TxCase $fxM $null @{ Record = $true }
$r = $c.R; $L = @($c.Labels)
Assert-Tx 'M-1a-three-items-succeed' 'GUARD' '' (($r.Succeeded -eq $true) -and ((Txt $mA) -ceq 'new-A') -and ((Txt $mB) -ceq 'new-B') -and ((Txt $mC) -ceq 'new-C') -and (@(Get-TxResidue $fxM).Count -eq 0)) "succeeded=$($r.Succeeded) code=$($r.Code)"
$dispLeaves = @($L | Where-Object { $_ -match '^before:Fs-Sha256:.*\.dengo\.old$' } | ForEach-Object { $_ } | Select-Object -Unique)
Assert-Tx 'M-1b-each-item-measures-its-own-unique-displaced-file' 'RED' 'no-point' ($dispLeaves.Count -eq 3) $(if ($dispLeaves.Count -eq 0) { 'no-point' } else { 'other' }) "distinct displaced sha labels=$($dispLeaves.Count)"
# M-2: the middle item is changed by a third party in its window
$script:tpPath = $mB
$c = Tamper-Case $fxM '^after:Fs-ProbeExclusive:b\.dll$' $mB $actWrite
$r = $c.R; $obs = $(if ($r.Succeeded) { 'silent-overwrite' } else { 'other:code=' + $r.Code })
Assert-Tx 'M-2a-the-changed-item-is-PlanStale' 'RED' 'silent-overwrite' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'M-2b-the-third-party-content-of-the-changed-item-is-kept' 'RED' 'silent-overwrite' ((Txt $mB) -ceq 'THIRD-PARTY-A') $obs "b=[$(Txt $mB)]"
Assert-Tx 'M-2c-the-item-applied-before-stays-applied-no-automatic-T0' 'GUARD' '' ((Txt $mA) -ceq 'new-A') "a=[$(Txt $mA)]"
Assert-Tx 'M-2d-the-item-after-it-is-not-applied' 'RED' 'silent-overwrite' ((Txt $mC) -ceq 'old-C') $obs "c=[$(Txt $mC)]"
Assert-Tx 'M-2e-only-the-changed-item-asks-for-manual-check-marker-retained-no-residue' 'RED' 'silent-overwrite' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxM) -and (@(Get-TxResidue $fxM).Count -eq 0)) $obs "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxM) residue=$(@(Get-TxResidue $fxM).Count)"
# M-3: the same item changed EARLY (before its own entry check) - protected today, same outcome required
$c = Tamper-Case $fxM '^after:Journal:Verified#0$' $mB $actWrite
$r = $c.R
Assert-Tx 'M-3a-early-change-is-PlanStale' 'GUARD' '' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'M-3b-early-change-keeps-the-third-party-content-and-the-applied-item-and-skips-the-later-one' 'GUARD' '' (((Txt $mB) -ceq 'THIRD-PARTY-A') -and ((Txt $mA) -ceq 'new-A') -and ((Txt $mC) -ceq 'old-C')) "a=[$(Txt $mA)] b=[$(Txt $mB)] c=[$(Txt $mC)]"
Assert-Tx 'M-3c-early-change-asks-for-manual-check-and-retains-the-marker' 'GUARD' '' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxM)) "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxM)"
# M-4: a Write item and a Delete item; the Delete item is changed in its window
$fxX = New-TxFx 'mx' @(@{ Rel = 'd\a.dll'; Op = 'Write'; Pre = 'old-A'; Post = 'new-A' }, @{ Rel = 'd\b.dll'; Op = 'Delete'; Pre = 'old-B'; Post = $null }) 'Uninstall'
$xA = Join-Path $fxX.Dest 'd\a.dll'; $xB = Join-Path $fxX.Dest 'd\b.dll'
$c = Tamper-Case $fxX '^after:Fs-ProbeExclusive:b\.dll$' $xB $actWrite
$r = $c.R; $obs = $(if ($r.Succeeded) { 'silent-overwrite' } else { 'other:code=' + $r.Code })
Assert-Tx 'M-4a-changed-delete-item-is-PlanStale' 'RED' 'silent-overwrite' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanStale')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'M-4b-changed-delete-item-keeps-the-third-party-content' 'RED' 'silent-overwrite' ((Txt $xB) -ceq 'THIRD-PARTY-A') $obs "b=[$(Txt $xB)]"
Assert-Tx 'M-4c-write-item-before-it-stays-applied' 'GUARD' '' ((Txt $xA) -ceq 'new-A') "a=[$(Txt $xA)]"
Assert-Tx 'M-4d-manual-check-and-marker-retained' 'RED' 'silent-overwrite' (($r.ManualCheckRequired -eq $true) -and (Marker-Retained $fxX)) $obs "manual=$($r.ManualCheckRequired) marker=$(Marker-Retained $fxX)"

# =====================================================================================================================
# N  derived names: uniqueness, length, collisions, duplicates
# =====================================================================================================================
$fxN1 = New-TxFx 'n1' @(@{ Rel = ('d\' + ('f' * 100)); Op = 'Write'; Pre = 'o'; Post = 'n' })
$c = Invoke-TxCase $fxN1
Assert-Tx 'N-1-a-100-character-leaf-is-accepted' 'GUARD' '' ($c.R.Succeeded -eq $true) "succeeded=$($c.R.Succeeded) code=$($c.R.Code)"
$leaf245 = 'f' * 245
$fxN2 = New-TxFx 'n2' @(@{ Rel = ('d\' + $leaf245); Op = 'Write'; Pre = 'o'; Post = 'n' })
$n2 = Join-Path $fxN2.Dest ('d\' + $leaf245)
$c = Invoke-TxCase $fxN2
$r = $c.R
$obs = $(if ($r.Succeeded) { 'begin-accepts' } else { 'other:code=' + $r.Code })
Assert-Tx 'N-2a-a-leaf-whose-displaced-name-exceeds-255-characters-is-refused-at-planning' 'RED' 'begin-accepts' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanInvalid')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
Assert-Tx 'N-2b-and-nothing-is-changed' 'RED' 'begin-accepts' (((Txt $n2) -ceq 'o') -and (-not (Test-TxMarker $fxN2))) $obs "dest=[$(Txt $n2)] marker=$(Test-TxMarker $fxN2)"
# a Destination that is literally another item's displaced name
$fxN3 = New-TxFx 'n3' @(@{ Rel = 'd\a.dll'; Op = 'Write'; Pre = 'old-A'; Post = 'new-A' })
$n3a = Join-Path $fxN3.Dest 'd\a.dll'
$src3 = Join-Path $fxN3.Root 'Src\evil.src'; [System.IO.File]::WriteAllText($src3, 'EVIL', $script:TxUtf8); $fxN3.Pristine = Save-I2ATree $fxN3.Root
$evilItems = @($fxN3.Items[0], @{ Op = 'Write'; Destination = (Get-TxDisplaced $n3a 'T0001' 0); Source = $src3; OwnershipCandidate = 'CreatedByInstaller'; Tag = 'evil' })
Reset-TxFx $fxN3
Reset-I2AFault; Reset-I2ACounters
$r = Invoke-TxRun $fxN3 $evilItems
$obs = $(if ($r.Succeeded) { 'begin-accepts' } else { 'other:code=' + $r.Code })
Assert-Tx 'N-3-a-destination-equal-to-another-items-displaced-name-is-refused-at-planning' 'RED' 'begin-accepts' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanInvalid') -and ($r.Message -notlike '*source is missing*')) $obs "succeeded=$($r.Succeeded) code=$($r.Code)"
# duplicates (today's rule must stay): same path in a different case / with forward slashes
foreach ($d in @(@{ Id = 'N-4a-duplicate-destination-in-another-case'; Path = $n3a.ToUpperInvariant() }, @{ Id = 'N-4b-duplicate-destination-with-forward-slashes'; Path = ($n3a -replace '\\', '/') })) {
    Reset-TxFx $fxN3
    $r = Invoke-TxRun $fxN3 @($fxN3.Items[0], @{ Op = 'Write'; Destination = $d.Path; Source = $src3; OwnershipCandidate = 'CreatedByInstaller'; Tag = 'dup' })
    Assert-Tx $d.Id 'GUARD' '' (($r.Succeeded -eq $false) -and ($r.Code -ceq 'PlanInvalid') -and ($r.Message -like '*duplicate destination*') -and ((Txt $n3a) -ceq 'old-A')) "code=$($r.Message) dest=[$(Txt $n3a)]"
}

# =====================================================================================================================
# C  characterizations: known limitations that stay out of scope (Commit state replacement, RestoreItem Restore / RemoveNew, RestoreDeleted)
# =====================================================================================================================
function Invoke-CharCase($Fx, [string]$FailRx, [scriptblock]$FindK2, [scriptblock]$Act) {
    $c1 = Invoke-TxCase $Fx $null @{ Record = $true }
    $kFail = (Get-TxIdx @($c1.Labels) $FailRx) + 1
    $c2 = Invoke-TxCase $Fx $null @{ Record = $true; ThrowTargets = [int[]]@($kFail) }
    $k2 = & $FindK2 @($c2.Labels)
    $c3 = Invoke-TxCase $Fx $null @{ Mode = 'ThrowAll'; Targets = [int[]]@($k2); Action = 'Callback'; Callback = $Act; ThrowTargets = [int[]]@($kFail) }
    return @{ C2 = $c2; C3 = $c3; KFail = $kFail; K2 = $k2 }
}
# C-1 Commit: the state file is changed between its last probe and its replacement -> overwritten (known limitation)
$fxC1 = New-TxFx 'c1' @(@{ Rel = 'd\n.dll'; Op = 'Write'; Pre = $null; Post = 'new-N' })
$script:tpPath = $fxC1.StatePath; $script:tpText = 'STATE-TAMPER'
$c = Tamper-Case $fxC1 '^after:Fs-ProbeExclusive:installed-state\.json$' $fxC1.StatePath $actWrite 'STATE-TAMPER'
Assert-Tx 'C-1-Commit-state-replacement-window-is-a-known-limitation' 'CHAR' '' (($c.R.Succeeded -eq $true) -and ((Txt $fxC1.StatePath) -ceq 'state-v2') -and (Get-TxInjFired 0)) "succeeded=$($c.R.Succeeded) state=[$(Txt $fxC1.StatePath)] fired=$(Get-TxInjFired 0)"
# C-2 RestoreItem.Restore: a change after the re-check is overwritten by the restore (known limitation)
$fxC2 = New-TxFx 'c2' @(@{ Rel = 'd\a.dll'; Op = 'Write'; Pre = 'old-A'; Post = 'new-A' }, @{ Rel = 'd\b.dll'; Op = 'Write'; Pre = 'old-B'; Post = 'new-B' })
$c2A = Join-Path $fxC2.Dest 'd\a.dll'
$script:tpPath = $c2A; $script:tpText = 'THIRD-PARTY-RESTORE'
$cc = Invoke-CharCase $fxC2 '^before:Fs-CopyFileDurable:b\.dll\.dengo\.tmp$' { param($labels) $i = Get-TxIdx $labels '^before:Fs-Replace:a\.dll$'; $j = Get-TxIdx $labels '^before:Fs-Replace:a\.dll$' ($i + 1); return ($j + 1) } $actWrite
Assert-Tx 'C-2-RestoreItem-Restore-window-is-a-known-limitation-a-change-after-the-re-check-is-overwritten' 'CHAR' '' (($cc.K2 -gt 0) -and ((Txt $c2A) -ceq 'old-A') -and ($cc.C3.R.Succeeded -eq $false) -and ($cc.C3.R.RollbackState -ceq 'RolledBack')) "k2=$($cc.K2) a=[$(Txt $c2A)] rollback=$($cc.C3.R.RollbackState)"
# C-3 RestoreItem.RemoveNew: a change after the re-check is deleted with the added file (known limitation)
$fxC3 = New-TxFx 'c3' @(@{ Rel = 'd\a.dll'; Op = 'Write'; Pre = $null; Post = 'new-A' }, @{ Rel = 'd\b.dll'; Op = 'Write'; Pre = 'old-B'; Post = 'new-B' })
$c3A = Join-Path $fxC3.Dest 'd\a.dll'
$script:tpPath = $c3A; $script:tpText = 'THIRD-PARTY-REMOVE'
$cc = Invoke-CharCase $fxC3 '^before:Fs-CopyFileDurable:b\.dll\.dengo\.tmp$' { param($labels) return ((Get-TxIdx $labels '^before:Fs-Delete:a\.dll$') + 1) } $actWrite
Assert-Tx 'C-3-RestoreItem-RemoveNew-window-is-a-known-limitation-a-change-after-the-re-check-is-deleted' 'CHAR' '' (($cc.K2 -gt 0) -and (-not [System.IO.File]::Exists($c3A)) -and ($cc.C3.R.RollbackState -ceq 'RolledBack')) "k2=$($cc.K2) a=[$(Txt $c3A)] rollback=$($cc.C3.R.RollbackState)"
# C-4 RestoreDeleted: the move never overwrites, so a file created in the gap is kept and the rollback stops (the safe part of today's rule)
$fxC4 = New-TxFx 'c4' @(@{ Rel = 'd\a.dll'; Op = 'Delete'; Pre = 'old-A'; Post = $null }, @{ Rel = 'd\b.dll'; Op = 'Write'; Pre = 'old-B'; Post = 'new-B' }) 'Uninstall'
$c4A = Join-Path $fxC4.Dest 'd\a.dll'
$script:tpPath = $c4A; $script:tpText = 'THIRD-PARTY-CREATED'
$cc = Invoke-CharCase $fxC4 '^before:Fs-CopyFileDurable:b\.dll\.dengo\.tmp$' { param($labels) return ((Get-TxIdx $labels '^before:Fs-MoveNew:a\.dll$') + 1) } $actWrite
Assert-Tx 'C-4-RestoreDeleted-never-overwrites-a-file-created-in-the-gap' 'CHAR' '' (($cc.K2 -gt 0) -and ((Txt $c4A) -ceq 'THIRD-PARTY-CREATED') -and ($cc.C3.R.RollbackState -ceq 'RollbackIncomplete')) "k2=$($cc.K2) a=[$(Txt $c4A)] rollback=$($cc.C3.R.RollbackState)"

# =====================================================================================================================
# X  ownership and re-measurement contracts that the other sections do not pin (post-fix guards; added in the GREEN stage)
#    X-1 a reparse point at the displaced name is never "owned"          (a file symlink needs privilege, so the reparse probe is overridden for one call)
#    X-2 recovery: the displaced file changes between Phase 1 and the cleanup -> kept, RollbackIncomplete + manual check
#    X-3 live path: the displaced file changes between its verification and its cleanup -> kept, no success
# =====================================================================================================================
$sx = New-I2ASandbox 'tx-x1'
try {
    $px = Join-Path $sx 'a.dll.T0001.0000.dengo.old'
    [System.IO.File]::WriteAllText($px, 'old-A', $script:TxUtf8)
    $itemX = @{ Displaced = $px; PreSha = (Get-TextSha 'old-A') }
    $plainX = DgTx-DisplacedInspect $itemX $true
    Assert-Tx 'X-1a-a-regular-file-with-the-planned-content-and-an-Intent-is-owned' 'GUARD' '' ($plainX.State -ceq 'Owned') "state=$($plainX.State) reason=$($plainX.Reason)"
    $realRp = (Get-Command DgFs-GetReparseComponents -CommandType Function).ScriptBlock
    Set-Item -Path 'function:script:DgFs-GetReparseComponents' -Value ([scriptblock]::Create('param([string]$Path,[string]$Root) return ,([string[]]@($Path))'))
    try { $rpX = DgTx-DisplacedInspect $itemX $true } finally { Set-Item -Path 'function:script:DgFs-GetReparseComponents' -Value $realRp }
    Assert-Tx 'X-1b-a-reparse-point-at-the-displaced-name-is-not-owned' 'GUARD' '' (($rpX.State -ceq 'NotOwned') -and ($rpX.Reason -ceq 'ReparsePoint')) "state=$($rpX.State) reason=$($rpX.Reason)"
    $niX = DgTx-DisplacedInspect $itemX $false
    Assert-Tx 'X-1c-without-an-Intent-the-same-file-is-not-owned' 'GUARD' '' (($niX.State -ceq 'NotOwned') -and ($niX.Reason -ceq 'NoIntent')) "state=$($niX.State) reason=$($niX.Reason)"
} finally { Remove-I2ASandbox $sx }

$fxX2 = New-TxFx 'x2' @(@{ Rel = 'd\x.dll'; Op = 'Delete'; Pre = 'old-X'; Post = $null }) 'Uninstall'
$x2Dll = Join-Path $fxX2.Dest 'd\x.dll'
$x2Disp = Get-TxDisplaced $x2Dll 'T0001' 0
$b = Build-TxFrozen $fxX2 '^after:Journal:Applied#0$' 1 $null ({ [System.IO.File]::WriteAllText($x2Disp, 'old-X', $script:TxUtf8) })
$script:tpPath = $x2Disp; $script:tpText = 'THIRD-PARTY-LATE-EDIT'
Add-TxInj '^before:Fs-Sha256:.*\.dengo\.old$' 2 $actWrite
$rX2 = Invoke-TxRecover $fxX2
Assert-Tx 'X-2-0-the-late-edit-happened-at-the-cleanup-measurement' 'GUARD' '' (Get-TxInjFired 0) 'injection fired at the second displaced measurement (the cleanup one)'
Assert-Tx 'X-2a-a-displaced-file-edited-before-the-cleanup-is-kept' 'GUARD' '' ((Txt $x2Disp) -ceq 'THIRD-PARTY-LATE-EDIT') "displaced=[$(Txt $x2Disp)]"
Assert-Tx 'X-2b-recovery-is-RollbackIncomplete-with-manual-check-and-keeps-the-marker' 'GUARD' '' (($rX2.Outcome -ceq 'RollbackIncomplete') -and ($rX2.ManualCheckRequired -eq $true) -and (Test-TxMarker $fxX2)) "outcome=$($rX2.Outcome) manual=$($rX2.ManualCheckRequired) marker=$(Test-TxMarker $fxX2)"
Assert-Tx 'X-2c-the-destination-was-restored-from-the-backup' 'GUARD' '' ((Txt $x2Dll) -ceq 'old-X') "dest=[$(Txt $x2Dll)]"

$fxX3 = New-TxFx 'x3' @(@{ Rel = 'd\a.dll'; Op = 'Write'; Pre = 'old-A'; Post = 'new-A' })
$x3Dll = Join-Path $fxX3.Dest 'd\a.dll'
$x3Disp = Get-TxDisplaced $x3Dll 'T0001' 0
$script:tpPath = $x3Disp; $script:tpText = 'THIRD-PARTY-LATE-A'
$cX3 = Invoke-TxCase $fxX3 ({ Add-TxInj '^after:Fs-Sha256:.*\.dengo\.old$' 1 $actWrite })
Assert-Tx 'X-3-0-the-late-edit-happened-after-the-verification-measurement' 'GUARD' '' (Get-TxInjFired 0) 'injection fired after the first displaced measurement'
Assert-Tx 'X-3a-the-run-is-not-reported-as-success' 'GUARD' '' ($cX3.R.Succeeded -eq $false) "succeeded=$($cX3.R.Succeeded) code=$($cX3.R.Code)"
Assert-Tx 'X-3b-the-edited-displaced-file-is-kept' 'GUARD' '' ((Txt $x3Disp) -ceq 'THIRD-PARTY-LATE-A') "displaced=[$(Txt $x3Disp)]"
Assert-Tx 'X-3c-manual-check-required-and-marker-retained' 'GUARD' '' (($cX3.R.ManualCheckRequired -eq $true) -and (Test-TxMarker $fxX3)) "manual=$($cX3.R.ManualCheckRequired) marker=$(Test-TxMarker $fxX3)"

# =====================================================================================================================
# TS  static structure of the core
# =====================================================================================================================
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $corePath).Path, [ref]$tokens, [ref]$errs)
$fn = @{}
foreach ($f in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $fn[$f.Name] = $f.Extent.Text }
function Get-Adds([string]$Name) { return ((@([regex]::Matches($fn[$Name], "\.Add\('(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) -join ',') }
$apply = $fn['DgTx-ApplyItem']
$known = @('Dest', 'Tmp', 'Backup', 'Dir', 'Infra', 'Policy')
function Get-NewKindCalls([string]$Text, [string]$CallRx) {
    $hits = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, $CallRx + '[^\r\n]*')) {
        foreach ($t in [regex]::Matches($m.Value, "'(\w+)'")) { if ($known -cnotcontains $t.Groups[1].Value -and $t.Groups[1].Value -cnotin @('Intent', 'Applied', 'Verified')) { [void]$hits.Add(@{ Pos = $m.Index; Call = $m.Value; Kind = $t.Groups[1].Value }) } }
    }
    return , @($hits)
}
$dispCalls = Get-NewKindCalls $apply 'DgG-(Delete|MoveNew|Replace)'
$litCount = @($tokens | Where-Object { ($_.Kind -in @('StringLiteral', 'StringExpandable')) -and ($_.Value -like '*.dengo.old*') }).Count
Assert-Tx 'TS-01-one-pure-derivation-holds-the-dedicated-suffix-literal-exactly-once' 'RED' 'no-derivation' ($litCount -eq 1) $(if ($litCount -eq 0) { 'no-derivation' } else { 'other' }) "string literals containing .dengo.old: $litCount"
$allowedKeys = [regex]::Match($fn['DgTx-NewAllowed'], '(?m)\$a = @\{(.*)\}[ \t]*\r?$').Groups[1].Value
$keyCount = @([regex]::Matches($allowedKeys, '(\w+) = @\{\}')).Count
Assert-Tx 'TS-02-the-allowed-table-has-a-dedicated-displaced-kind' 'RED' 'no-displaced-kind' ($keyCount -ge 6) $(if ($keyCount -le 5) { 'no-displaced-kind' } else { 'other' }) "allowed-table kinds: $keyCount"
Assert-Tx 'TS-03-no-new-DgFs-primitive' 'GUARD' '' ((((@($fn.Keys | Where-Object { $_ -like 'DgFs-*' } | Sort-Object)) -join ',')) -ceq 'DgFs-CopyFileDurable,DgFs-CreateDir,DgFs-CreateFileDurable,DgFs-Delete,DgFs-DirExists,DgFs-Exists,DgFs-GetReparseComponents,DgFs-MoveNew,DgFs-ProbeExclusive,DgFs-ReadAllBytesShared,DgFs-RemoveDirIfEmpty,DgFs-Replace,DgFs-Sha256,DgFs-WriteTextFile') 'the set of DgFs-* functions is the 14 of today'
$rp = $fn['DgFs-Replace']
Assert-Tx 'TS-04-DgFs-Replace-keeps-NullString-and-never-passes-a-bare-null' 'GUARD' '' (($rp.IndexOf('[System.Management.Automation.Language.NullString]::Value') -ge 0) -and ($rp -notmatch 'Replace\([^)]*\$null')) 'File.Replace is called with NullString.Value or a path, never $null'
$otherCalls = @([regex]::Matches($rp, '(DgFs|DgG|DgTx|DgJournal)-\w+') | ForEach-Object { $_.Value } | Where-Object { $_ -cne 'DgFs-Replace' } | Sort-Object -Unique)
Assert-Tx 'TS-05-DgFs-Replace-is-one-physical-operation-not-a-composite' 'GUARD' '' ($otherCalls.Count -eq 0) "other Dg* calls inside DgFs-Replace: $($otherCalls -join ',')"
Assert-Tx 'TS-06-the-12-journal-stages-are-unchanged' 'GUARD' '' ((@(DgConst-Stages) -join ',') -ceq 'Begin,Register,Intent,Applied,Verified,CommitIntent,Committed,RollbackBegin,RollbackIntent,RolledBack,RollbackIncomplete,RollbackComplete') 'DgConst-Stages'
$adds = @{ 'DgTx-Begin' = 'backupPath,backupRoot,dirsToCreate,expectedPostSha,itemCount,newStatePath,newStateTmp,oldStateSha,op,ownershipCandidate,preExists,preSha,reparsePoints,sourcePath,sourceSha,stateRoot,tag,tmpPath'; 'DgTx-ApplyItem' = 'backupCreated,backupPath,backupSha,expectedPostSha,observedPostSha,preSha,verifiedSha'; 'DgTx-ExecuteRecovery' = 'code,detail,itemId,normalizedPath,path'; 'DgTx-RestoreItem' = 'action,resultSha' }
$addBad = @($adds.Keys | Where-Object { (Get-Adds $_) -cne $adds[$_] })
Assert-Tx 'TS-07-journal-record-fields-are-unchanged-no-journal-format-change' 'GUARD' '' ($addBad.Count -eq 0) "functions whose journal fields changed: $($addBad -join ',')"
$codes = (@([regex]::Matches((Get-Content -LiteralPath (Resolve-Path $corePath).Path -Raw), "DgError '(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) -join ','
Assert-Tx 'TS-08-no-new-public-error-code' 'GUARD' '' ($codes -ceq 'BackupVerifyFailed,CommitFailed,DestinationChangedAfterPreflight,JournalBroken,JournalChangedAfterRead,JournalFormat,MarkerExists,PathNotRegistered,PathRejected,PlanInvalid,PlanStale,PolicyInvalid,PostShaMismatch,RestoreVerifyFailed,TmpVerifyFailed,TxnExists') "DgError codes: $codes"
$pfMut = @([regex]::Matches($fn['DgTx-Preflight'], 'DgFs-(Replace|MoveNew|Delete|CreateFileDurable|WriteTextFile|CopyFileDurable|CreateDir|RemoveDirIfEmpty)|DgG-')).Count
Assert-Tx 'TS-09-Phase-1-Preflight-stays-read-only' 'GUARD' '' ($pfMut -eq 0) "mutating calls in DgTx-Preflight: $pfMut"
$iProbe = $apply.IndexOf('DgFs-ProbeExclusive'); $iRep = $apply.IndexOf('DgG-Replace'); $iIntent = $apply.IndexOf("'Intent'"); $iMv = $apply.IndexOf('DgG-MoveNew'); $iDl = $apply.IndexOf('DgG-Delete')
Assert-Tx 'TS-10-ProbeExclusive-precedes-the-swap-and-Intent-precedes-every-mutation' 'GUARD' '' (($iProbe -ge 0) -and ($iProbe -lt $iRep) -and ($iIntent -ge 0) -and ($iIntent -lt $iRep) -and ($iIntent -lt $iMv) -and ($iIntent -lt $iDl)) "probe@$iProbe Intent@$iIntent replace@$iRep move@$iMv delete@$iDl"
$firstDisp = $(if ($dispCalls.Count -gt 0) { [int]$dispCalls[0].Pos } else { -1 })
Assert-Tx 'TS-12-ApplyItem-performs-the-displaced-file-operations-itself-after-Intent' 'RED' 'no-displaced-ops' (($dispCalls.Count -gt 0) -and ($firstDisp -gt $iIntent)) $(if ($dispCalls.Count -eq 0) { 'no-displaced-ops' } else { 'other' }) "displaced-kind mutating calls in DgTx-ApplyItem: $($dispCalls.Count)"
$rec = $fn['DgTx-ExecuteRecovery']
$recCalls = Get-NewKindCalls $rec 'DgG-(Delete|MoveNew|Replace)'
$iRbc = $rec.IndexOf("'RollbackComplete'")
Assert-Tx 'TS-15-recovery-cleans-the-owned-displaced-file-before-RollbackComplete-and-the-marker-removal' 'RED' 'no-displaced-ops' (($recCalls.Count -gt 0) -and ([int]$recCalls[0].Pos -lt $iRbc)) $(if ($recCalls.Count -eq 0) { 'no-displaced-ops' } else { 'other' }) "displaced-kind mutating calls in DgTx-ExecuteRecovery: $($recCalls.Count)"
$itemState = $fn['DgTx-ItemState']
$uncond = ($itemState -match "if \(DgEq \`$Item\.Op 'Delete'\) \{ return @\{ State = 'post'; Sha = '' \} \}")
Assert-Tx 'TS-16-ItemState-no-longer-calls-every-missing-Delete-destination-post' 'RED' 'itemstate-post' (-not $uncond) $(if ($uncond) { 'itemstate-post' } else { 'other' }) "unconditional Delete+missing => post present=$uncond"
# out of scope: these functions must not change in this fix
$charFns = @{ 'DgTx-RestoreItem' = 'BD1F234D660FCC3A5B9B3F1FA8419DA484BF8035EBAF4611933D1F8938722CE7'; 'DgTx-Commit' = 'D8551B286014842CF2B7373AEC273C2D82AEB2A882DA3886AFEC854F9CC0D605'; 'DgTx-AssertUnchangedSincePreflight' = '303A35D389D20522DF092686A3D3E0B1CA119B63A17DF09B1A567DA961F4D7C0'; 'DgFs-MoveNew' = 'FB580EE866071D338FDA1BB36DBE0FEB4BC819F6353F7149CBA331F87A8B50CC'; 'DgFs-Delete' = 'FC4B299EACD4DE49E458E0C59FCF20948A6D4D6B555DD54809C23EDEEEAEFC82' }
foreach ($n in @($charFns.Keys | Sort-Object)) { Assert-Tx ('TS-17-out-of-scope-' + $n + '-is-unchanged') 'CHAR' '' ((Get-TextSha $fn[$n]) -ceq $charFns[$n]) ("sha=" + (Get-TextSha $fn[$n]).Substring(0, 12)) }

Uninstall-I2AHarness
Remove-TxSandboxes
Complete-TxTests $EvidenceDir
