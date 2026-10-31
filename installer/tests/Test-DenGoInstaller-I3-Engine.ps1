# I3 engine tests (written RED first): the real product install / uninstall functions (Invoke-DenGoProductInstall / Invoke-DenGoProductUninstall) run in sandboxes under TEMP.
#   E-01..E-04  consented replacement, no consent, equal file, plan stale
#   E-05        a file that changes after the plan or while the transaction runs is never overwritten (fault harness; runs last)
#   E-06        only the two fixed leaves can be written
#   E-08        update inside a generation: Origin and Backups[0] stay, Backups[1..] only grow
#   E-09..E-12  generations (H-6): the five scenarios of the audit (section 12), through install -> uninstall -> install -> uninstall
#   E-13        the old-format state of the owner's machine: promotion, then the uninstall stops (contamination) with nothing changed
#   E-14        the closed generation's DeferredRecords / Origin: never promoted, never used, only reported
#   E-15        running PCSX2: refused before any write, nothing changed
# The PCSX2 plan items are written by hand (same shape as the engine's New-PlanItem output): the engine's detection is covered by the Unit / Zero / Static suites.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')

function RunInstall($L, $Plan, [scriptblock]$Gate = $null) { return (Invoke-I3 { Invoke-I3Install $L $Plan $Gate }) }
function RunUninstall($L, [bool]$Incl = $false, [scriptblock]$Gate = $null) { return (Invoke-I3 { Invoke-I2CUninstall $L $Incl $Gate }) }
function Succ($R) { return ($R.Ok -and ($R.Value.Succeeded -eq $true)) }
function CodeOf($R) { if ($R.Ok) { return [string]$R.Value.ErrorCode } return ('<exception: ' + $R.Error + '>') }
function Rec($L, [string]$Leaf) { $st = Get-I2BStateObject $L; if ($null -eq $st) { return $null } return (Get-I3Rec1 $st $Leaf) }
function Txt([string]$Path) { if (-not [System.IO.File]::Exists($Path)) { return '<missing>' } return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function PathEq2Safe([string]$A, [string]$B) { if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false } return (DgP-PathEq $A $B) }
function RowsOf($R, [string]$Action) { if (-not $R.Ok) { return @() } return @($R.Value.Results | Where-Object { [string]$_.Platform -ceq 'PCSX2' -and [string]$_.Action -ceq $Action }) }
$activeV1 = 'DENGO-ACTIVE-LILYPAD-V1'; $lilyV1 = 'DENGO-LILY-PROFILE-V1'

# ================================================================ E-01 consented replacement: Origin, backup, state
$L = New-I3Case 'e01'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$pre = Get-I2ATreeMap $L.Pcsx2Inis @()
$originSha = Get-I3Sha $dLilyPad
$r = RunInstall $L (Get-I3Plan $L 'UpdateOrRepair' 'Add')
$rec = $(if (Succ $r) { Rec $L 'LilyPad.ini' } else { $null })
$recLily = $(if (Succ $r) { Rec $L 'DenGo-Controller-Converter.lily' } else { $null })
[void](Assert-I2A 'E-01a-consented-install-succeeds-and-nothing-is-deferred' ((Succ $r) -and ((Cnt (RowsOf $r 'Deferred')) -eq 0) -and ((Cnt $r.Value.DeferredItems) -eq 0) -and ((Cnt (RowsOf $r 'UpdateOrRepair')) -eq 1) -and ((Cnt (RowsOf $r 'Add')) -eq 1)) ("succeeded=$(Succ $r) code=$(CodeOf $r) deferred=$(Cnt (RowsOf $r 'Deferred')) rows=" + $(if ($r.Ok) { @($r.Value.Results | ForEach-Object { $_.Component + ':' + $_.Action }) -join ',' } else { '?' })))
[void](Assert-I2A 'E-01b-LilyPad.ini-and-the-profile-hold-the-DenGo-content' (((Txt $dLilyPad) -ceq $activeV1) -and ((Txt $dLily) -ceq $lilyV1)) ("LilyPad.ini=[$(Txt $dLilyPad)] lily=[$(Txt $dLily)]"))
$bkOk = ($null -ne $rec) -and ([string]$rec.Backup).Length -gt 0 -and [System.IO.File]::Exists([string]$rec.Backup) -and ((Get-I3Sha ([string]$rec.Backup)) -ceq $originSha)
[void](Assert-I2A 'E-01c-the-Origin-is-the-measured-content-right-before-the-replacement-and-is-backed-up' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ($rec.ExistedBefore -eq $true) -and ([string]$rec.BeforeSHA256 -ceq $originSha) -and $bkOk -and ([string]$rec.AfterSHA256 -ceq (Get-I3TextSha $activeV1))) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + " origin=$originSha"))
$bk0 = $(if ($null -ne $rec -and @($rec.Backups).Count -ge 1) { $rec.Backups[0] } else { $null })
$st = Get-I2BStateObject $L
[void](Assert-I2A 'E-01d-Backups-0-is-the-Origin-in-this-transaction' (($null -ne $bk0) -and (@($rec.Backups).Count -eq 1) -and ([string]$bk0.Path -ceq [string]$rec.Backup) -and ([string]$bk0.SHA256 -ceq $originSha) -and ($null -ne $st) -and ([string]$bk0.TransactionId -ceq [string]$st.TransactionId)) ("backups=" + $(if ($null -ne $rec) { ConvertTo-I3Json @($rec.Backups) } else { '<none>' })))
[void](Assert-I2A 'E-01e-the-lily-profile-is-recorded-as-created' (($null -ne $recLily) -and ([string]$recLily.Ownership -ceq 'CreatedByInstaller') -and ([string]$recLily.Backup -ceq '')) ("rec=" + $(if ($null -ne $recLily) { ConvertTo-I3Json $recLily } else { '<none>' })))
$post = Get-I2ATreeMap $L.Pcsx2Inis @()
$changed = @(Compare-I2ATree $pre $post | Where-Object { $_ -notmatch 'lilypad\.ini$' -and $_ -notmatch 'dengo-controller-converter\.lily$' })
[void](Assert-I2A 'E-01f-no-other-PCSX2-file-is-touched' ((Succ $r) -and ($changed.Count -eq 0) -and ((Get-I3Sha (Get-I3Dest $L 'PCSX2.ini')) -ceq (Get-I3TextSha 'pcsx2-ini')) -and ((Txt (Get-I3Dest $L 'PCSX2_ui.ini')) -ceq 'ui-settings')) ("other changes: " + ($changed -join ' ')))
[void](Assert-I2A 'E-01g-no-marker-no-temporary-no-leftover' ((Succ $r) -and (Test-I2BStateValid $L) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) ("leftovers: " + ((Test-I2BLeftovers $L $true) -join ',')))

# ---------------------------------------------------------------- E-08 an update inside the generation (DenGo version V2 over our own V1, no consent)
$firstBackup = $(if ($null -ne $rec) { [string]$rec.Backup } else { '' })
[System.IO.File]::WriteAllText((Join-Path $L.Src 'active.src'), 'DENGO-ACTIVE-LILYPAD-V2', $script:Utf8)
$plan2 = @((New-I3PlanItem 'InputProfile' $dLily (Join-Path $L.Src 'lily.src') 'Unchanged'), (New-I3PlanItem 'EffectiveInputProfile' $dLilyPad (Join-Path $L.Src 'active.src') 'UpdateOrRepair'))
$r2 = RunInstall $L $plan2
$rec2 = $(if (Succ $r2) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-08a-update-writes-the-new-DenGo-version' ((Succ $r2) -and ((Txt $dLilyPad) -ceq 'DENGO-ACTIVE-LILYPAD-V2')) ("succeeded=$(Succ $r2) code=$(CodeOf $r2) LilyPad.ini=[$(Txt $dLilyPad)]"))
[void](Assert-I2A 'E-08b-the-Origin-and-Backups-0-do-not-move' (($null -ne $rec2) -and ([string]$rec2.Ownership -ceq 'ReplacedExisting') -and ([string]$rec2.BeforeSHA256 -ceq $originSha) -and ([string]$rec2.Backup -ceq $firstBackup) -and (@($rec2.Backups).Count -eq 2) -and ((ConvertTo-I3Json @($rec2.Backups[0])) -ceq (ConvertTo-I3Json @($rec.Backups[0])))) ("backups=" + $(if ($null -ne $rec2) { ConvertTo-I3Json @($rec2.Backups) } else { '<none>' })))
$b1ok = ($null -ne $rec2) -and (@($rec2.Backups).Count -eq 2) -and ([string]$rec2.Backups[1].SHA256 -ceq (Get-I3TextSha $activeV1)) -and [System.IO.File]::Exists([string]$rec2.Backups[1].Path) -and ((Txt ([string]$rec2.Backups[1].Path)) -ceq $activeV1)
[void](Assert-I2A 'E-08c-Backups-1-holds-our-previous-version-and-is-not-the-Origin' ($b1ok -and ([string]$rec2.Backups[1].Path -cne [string]$rec2.Backup)) ("backups=" + $(if ($null -ne $rec2) { ConvertTo-I3Json @($rec2.Backups) } else { '<none>' })))
# ---------------------------------------------------------------- E-12 the uninstall restores the Origin, never the update backup
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'E-12a-uninstall-restores-the-Origin-without-IncludeInputProfiles' ((Succ $u) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin)) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
[void](Assert-I2A 'E-12b-the-profile-is-kept-by-default' (((Txt $dLily) -ceq $lilyV1)) ("lily=[$(Txt $dLily)]"))
[void](Assert-I2A 'E-12c-the-state-records-the-restore-and-no-deferred-record' (($null -ne $us) -and (@($us.UsedBackups | Where-Object { [string]$_.Path -ceq $firstBackup }).Count -eq 1) -and (@($us.DeferredRecords).Count -eq 0) -and (@($us.ClosedRecords | Where-Object { [string]$_.Record.Platform -ceq 'PCSX2' }).Count -eq 0) -and ($us.Counts.Restored -ge 1) -and ($us.Counts.Deferred -eq 0)) ("used=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UsedBackups) } else { '<none>' }) + " counts=" + $(if ($null -ne $us) { ConvertTo-I3Json $us.Counts } else { '?' })))
[void](Assert-I2A 'E-12d-the-update-backup-is-reported-as-unused' (($null -ne $us) -and (@($us.UnusedBackups | Where-Object { [string]$_.Reason -ceq 'UpdateBackup' -and [string]$_.SHA256 -ceq (Get-I3TextSha $activeV1) }).Count -eq 1)) ("unused=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UnusedBackups) } else { '<none>' })))
Remove-I2ASandbox $L.Root

# ================================================================ E-02 no consent: not written, recorded as the user's file
$L = New-I3Case 'e02'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$r = RunInstall $L (Get-I3Plan $L 'PreserveUserModified' 'Add')
$rec = $(if (Succ $r) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-02a-without-consent-LilyPad.ini-is-never-written' ((Succ $r) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin) -and ((Cnt (RowsOf $r 'Deferred')) -eq 0)) ("succeeded=$(Succ $r) code=$(CodeOf $r) LilyPad.ini=[$(Txt $dLilyPad)]"))
[void](Assert-I2A 'E-02b-the-user-file-is-recorded-without-an-Origin-and-no-backup-exists' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'PreservedUserFile') -and ([string]$rec.Backup -ceq '') -and (@($rec.Backups).Count -eq 0) -and ((Cnt (Get-I2CBackupFiles $L)) -eq 0)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + " backups=$(Cnt (Get-I2CBackupFiles $L))"))
[void](Assert-I2A 'E-02c-the-same-install-still-creates-the-absent-profile-only' ((Succ $r) -and ((Txt $dLily) -ceq $lilyV1)) ("lily=[$(Txt $dLily)]"))
$u = RunUninstall $L $false
[void](Assert-I2A 'E-02d-uninstall-leaves-a-preserved-user-file-alone' ((Succ $u) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin)) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
Remove-I2ASandbox $L.Root

# ================================================================ E-03 equal file: nothing to write, no Origin
$L = New-I3Case 'e03'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
[System.IO.File]::WriteAllText($dLilyPad, $activeV1, $script:Utf8)
$r = RunInstall $L (Get-I3Plan $L 'Unchanged' 'Add')
$rec = $(if (Succ $r) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-03-an-equal-LilyPad.ini-is-not-written-and-has-no-Origin' ((Succ $r) -and ((Txt $dLilyPad) -ceq $activeV1) -and ($null -ne $rec) -and ([string]$rec.Ownership -ceq 'MigratedMatchingDenGoFile') -and ([string]$rec.Backup -ceq '') -and ([string]$rec.BeforeSHA256 -ceq '') -and ($rec.ExistedBefore -eq $false) -and (@($rec.Backups).Count -eq 0) -and ((Cnt (RowsOf $r 'Deferred')) -eq 0)) ("succeeded=$(Succ $r) code=$(CodeOf $r) rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' })))
Remove-I2ASandbox $L.Root

# ================================================================ E-04 the file changed after the plan: the plan is stale, nothing is written
$L = New-I3Case 'e04'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$plan = Get-I3Plan $L 'UpdateOrRepair' 'Add'
[System.IO.File]::WriteAllText($dLilyPad, 'CHANGED-BY-PCSX2-AFTER-PLANNING', $script:Utf8)
$before = Get-I2BFullTree $L
$r = RunInstall $L $plan
[void](Assert-I2A 'E-04-a-change-after-planning-gives-PlanStale-and-zero-change' ((-not (Succ $r)) -and ((CodeOf $r) -ceq 'PlanStale') -and ((Txt $dLilyPad) -ceq 'CHANGED-BY-PCSX2-AFTER-PLANNING') -and (-not [System.IO.File]::Exists($dLily)) -and (Same $before (Get-I2BFullTree $L)) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) ("succeeded=$(Succ $r) code=$(CodeOf $r) diff=[$(Diff3 $before (Get-I2BFullTree $L))]"))
Remove-I2ASandbox $L.Root

# ================================================================ E-06 only the two fixed leaves can be written
$L = New-I3Case 'e06'
$pluginsDir = Join-Path (Split-Path $L.Pcsx2Inis -Parent) 'Plugins'
[void][System.IO.Directory]::CreateDirectory($pluginsDir)
[System.IO.File]::WriteAllText((Join-Path $pluginsDir 'LilyPad.dll'), 'plugin-bytes', $script:Utf8)
[System.IO.File]::WriteAllText((Join-Path $L.Pcsx2Inis 'sub.txt'), 'x', $script:Utf8)
[void][System.IO.Directory]::CreateDirectory((Join-Path $L.Pcsx2Inis 'sub'))
foreach ($case in @(
        @('PCSX2.ini', (Get-I3Dest $L 'PCSX2.ini')), @('PCSX2_ui.ini', (Get-I3Dest $L 'PCSX2_ui.ini')), @('Plugins-LilyPad.dll', (Join-Path $pluginsDir 'LilyPad.dll')),
        @('sub-folder-LilyPad.ini', (Join-Path $L.Pcsx2Inis 'sub\LilyPad.ini')), @('new-neighbour', (Get-I3Dest $L 'Other.ini')))) {
    $item = New-I3PlanItem 'InputProfile' $case[1] (Join-Path $L.Src 'lily.src') $(if ([System.IO.File]::Exists($case[1])) { 'UpdateOrRepair' } else { 'Add' })
    $before = Get-I2BFullTree $L
    $r = RunInstall $L @($item)
    [void](Assert-I2A ('E-06-a-plan-item-for-' + $case[0] + '-is-refused-with-zero-change') ((-not (Succ $r)) -and ((CodeOf $r) -ceq 'PlanInvalid') -and (Same $before (Get-I2BFullTree $L))) ("succeeded=$(Succ $r) code=$(CodeOf $r) diff=[$(Diff3 $before (Get-I2BFullTree $L))]"))
}
$r = RunInstall $L (Get-I3Plan $L 'PreserveUserModified' 'Add')
[void](Assert-I2A 'E-06z-control-the-two-fixed-leaves-are-accepted' (Succ $r) ("succeeded=$(Succ $r) code=$(CodeOf $r)"))
Remove-I2ASandbox $L.Root

# ================================================================ E-09 generations (H-6), scenario 1: install -> uninstall -> user edit -> install -> uninstall
$L = New-I3Case 'e09'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$r1 = RunInstall $L (Get-I3Plan $L 'UpdateOrRepair' 'Add')
$gen1 = $(if (Succ $r1) { Rec $L 'LilyPad.ini' } else { $null })
$gen1Backup = $(if ($null -ne $gen1) { [string]$gen1.Backup } else { '' })
$u1 = RunUninstall $L $false
[void](Assert-I2A 'E-09a-generation-1-uninstall-restores-the-first-Origin' ((Succ $r1) -and (Succ $u1) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin)) ("install=$(CodeOf $r1) uninstall=$(CodeOf $u1) LilyPad.ini=[$(Txt $dLilyPad)]"))
$edited = 'USER-EDITED-ORIGIN-FOR-GENERATION-2'
[System.IO.File]::WriteAllText($dLilyPad, $edited, $script:Utf8)
Start-Sleep -Milliseconds 1300   # the generation boundary compares transaction ids, which carry a one-second timestamp
$r2 = RunInstall $L @((New-I3PlanItem 'InputProfile' $dLily (Join-Path $L.Src 'lily.src') 'Unchanged'), (New-I3PlanItem 'EffectiveInputProfile' $dLilyPad (Join-Path $L.Src 'active.src') 'UpdateOrRepair'))
$gen2 = $(if (Succ $r2) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-09b-generation-2-has-a-new-Origin-taken-right-before-its-replacement' ((Succ $r2) -and ($null -ne $gen2) -and ([string]$gen2.BeforeSHA256 -ceq (Get-I3TextSha $edited)) -and ([string]$gen2.Backup -cne $gen1Backup) -and (@($gen2.Backups).Count -eq 1) -and ([string]$gen2.Backups[0].Path -ceq [string]$gen2.Backup) -and ((Txt ([string]$gen2.Backup)) -ceq $edited)) ("install=$(CodeOf $r2) gen2=" + $(if ($null -ne $gen2) { ConvertTo-I3Json $gen2 } else { '<none>' })))
$u2 = RunUninstall $L $false
$us2 = $(if (Succ $u2) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'E-09c-generation-2-uninstall-restores-the-edited-content-never-generation-1s-Origin' ((Succ $u2) -and ((Txt $dLilyPad) -ceq $edited)) ("uninstall=$(CodeOf $u2) LilyPad.ini=[$(Txt $dLilyPad)]"))
[void](Assert-I2A 'E-09d-the-closed-generation-backup-is-neither-used-nor-deleted' (($null -ne $us2) -and ($gen1Backup.Length -gt 0) -and [System.IO.File]::Exists($gen1Backup) -and (@($us2.UsedBackups | Where-Object { [string]$_.Path -ceq $gen1Backup }).Count -eq 0) -and (@($us2.UsedBackups | Where-Object { [string]$_.Path -ceq [string]$gen2.Backup }).Count -eq 1)) ("used=" + $(if ($null -ne $us2) { ConvertTo-I3Json @($us2.UsedBackups) } else { '<none>' })))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- E-10 scenario 2: edited after install -> the edit is kept, the Origin stays unused
$L = New-I3Case 'e10'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
$r1 = RunInstall $L (Get-I3Plan $L 'UpdateOrRepair' 'Add')
$rec = $(if (Succ $r1) { Rec $L 'LilyPad.ini' } else { $null })
[System.IO.File]::WriteAllText($dLilyPad, 'USER-EDITED-AFTER-INSTALL', $script:Utf8)
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'E-10a-an-edited-LilyPad.ini-is-preserved' ((Succ $u) -and ((Txt $dLilyPad) -ceq 'USER-EDITED-AFTER-INSTALL') -and ($null -ne $us) -and (@($us.UsedBackups).Count -eq 0)) ("uninstall=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
$resid = @($(if ($null -ne $us) { @($us.ResidualFiles | Where-Object { ([string]$_.Path) -like '*LilyPad.ini' }) } else { @() }))
[void](Assert-I2A 'E-10b-it-is-reported-as-a-modified-residual-and-the-Origin-as-unused' (($resid.Count -eq 1) -and ([string]$resid[0].Disposition -ceq 'PreserveModified') -and ([string]$resid[0].ReasonCode -ceq 'ModifiedByUser') -and ($null -ne $rec) -and (@($us.UnusedBackups | Where-Object { [string]$_.Path -ceq [string]$rec.Backup -and [string]$_.Reason -ceq 'FilePreserved' }).Count -eq 1)) ("residual=$($resid.Count) unused=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UnusedBackups) } else { '<none>' })))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- E-11 scenario 3: an equal file has no Origin, so nothing is restored, now or in the next generation
$L = New-I3Case 'e11'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
[System.IO.File]::WriteAllText($dLilyPad, $activeV1, $script:Utf8)
$r1 = RunInstall $L (Get-I3Plan $L 'Unchanged' 'Add')
$u1 = RunUninstall $L $false
$us1 = $(if (Succ $u1) { Get-I2CUs $L } else { $null })
$item = @($(if ($null -ne $us1) { @($us1.Items | Where-Object { ([string]$_.Destination) -like '*LilyPad.ini' }) } else { @() }))
[void](Assert-I2A 'E-11a-without-an-Origin-the-uninstall-keeps-LilyPad.ini' ((Succ $r1) -and (Succ $u1) -and ((Txt $dLilyPad) -ceq $activeV1) -and ($item.Count -eq 1) -and ([string]$item[0].Decision -ceq 'KeepProfile')) ("install=$(CodeOf $r1) uninstall=$(CodeOf $u1) decision=" + $(if ($item.Count -eq 1) { [string]$item[0].Decision } else { '?' })))
Start-Sleep -Milliseconds 1300
$r2 = RunInstall $L @((New-I3PlanItem 'InputProfile' $dLily (Join-Path $L.Src 'lily.src') 'Unchanged'), (New-I3PlanItem 'EffectiveInputProfile' $dLilyPad (Join-Path $L.Src 'active.src') 'Unchanged'))
$gen2 = $(if (Succ $r2) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-11b-the-next-generation-starts-without-an-Origin-and-uses-no-earlier-one' ((Succ $r2) -and ($null -ne $gen2) -and ([string]$gen2.Ownership -ceq 'MigratedMatchingDenGoFile') -and ([string]$gen2.Backup -ceq '') -and ((Cnt (Get-I3Prop $r2.Value 'ClosedGenerationPcsx2Origins' @())) -eq 0)) ("install=$(CodeOf $r2) rec=" + $(if ($null -ne $gen2) { ConvertTo-I3Json $gen2 } else { '<none>' })))
$u2 = RunUninstall $L $false
[void](Assert-I2A 'E-11c-the-second-uninstall-still-keeps-the-file' ((Succ $u2) -and ((Txt $dLilyPad) -ceq $activeV1)) ("uninstall=$(CodeOf $u2) LilyPad.ini=[$(Txt $dLilyPad)]"))
Remove-I2ASandbox $L.Root

# ================================================================ E-13 the old-format state of the owner's machine (old installed-state + old uninstalled-state)
function New-I3LegacyMachine([string]$Name) {
    $L = New-I3Case $Name
    $dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
    [System.IO.File]::WriteAllText($dLilyPad, $activeV1, $script:Utf8)
    [System.IO.File]::WriteAllText($dLily, $lilyV1, $script:Utf8)
    $legacyDir = Join-Path $L.Product.BackupRoot '20261014-045719'
    [void][System.IO.Directory]::CreateDirectory($legacyDir)
    $legacyBackup = Join-Path $legacyDir '312661c0537d4f4b88f18ed055b43202.bak'
    [System.IO.File]::WriteAllText($legacyBackup, $script:I3UserOrigin, $script:Utf8)
    $files = @(
        [pscustomobject][ordered]@{ Platform = 'PCSX2'; Component = 'InputProfile'; Destination = $dLily; InstallAction = 'UpdateOrRepair'; Ownership = 'MigratedMatchingDenGoFile'; ExistedBefore = $false; BeforeSHA256 = ''; AfterSHA256 = (Get-I3TextSha $lilyV1); Backup = '' },
        [pscustomobject][ordered]@{ Platform = 'PCSX2'; Component = 'EffectiveInputProfile'; Destination = $dLilyPad; InstallAction = 'UpdateOrRepair'; Ownership = 'ReplacedExisting'; ExistedBefore = $true; BeforeSHA256 = (Get-I3Sha $legacyBackup); AfterSHA256 = (Get-I3TextSha $activeV1); Backup = $legacyBackup })
    $state = [pscustomobject][ordered]@{ SchemaVersion = 1; ProductVersion = '2.0.0'; PCSX2LegacyKeyboardInitialized = $true; InstalledAt = '2026-10-14T04:57:19.0000000+09:00'; BackupRoot = $legacyDir
        Shortcut = [pscustomobject][ordered]@{ Requested = $false; Created = $false; Path = '' }; Files = [object[]]$files }
    [void][System.IO.Directory]::CreateDirectory($L.Product.StateRoot)
    Write-I2CJson $L.Product.StatePath $state
    Write-I2CLegacyUninstalledState $L
    return [pscustomobject]@{ L = $L; Backup = $legacyBackup; LilyPad = $dLilyPad; Lily = $dLily }
}
$m = New-I3LegacyMachine 'e13u'
$before = Get-I2CTree $m.L
$u = RunUninstall $m.L $false
$blk = @($(if ($u.Ok) { @($u.Value.Blocking) } else { @() }))
[void](Assert-I2A 'E-13a-old-plus-old-state-stops-the-uninstall-with-ContaminationBlocksRestore' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ContaminationBlocksRestore') -and ($u.Value.ContaminationSuspect -eq $true) -and (Test-I2CNoChange $m.L $before)) ("succeeded=$(Succ $u) code=$(CodeOf $u)"))
[void](Assert-I2A 'E-13b-the-blocking-decision-names-the-Origin-backup-for-a-manual-restore' (($blk.Count -ge 1) -and ([string]$blk[0].Backup -ceq $m.Backup) -and ([string]$blk[0].Decision -ceq 'PreserveSuspect')) ("blocking=$($blk.Count) backup=" + $(if ($blk.Count -ge 1) { [string]$blk[0].Backup } else { '?' })))
Remove-I2ASandbox $m.L.Root
$m = New-I3LegacyMachine 'e13i'
$legacyBefore = Get-I3Rec1 (Get-I2BStateObject $m.L) 'LilyPad.ini'
$ri = RunInstall $m.L @((New-I3PlanItem 'InputProfile' $m.Lily (Join-Path $m.L.Src 'lily.src') 'Unchanged'), (New-I3PlanItem 'EffectiveInputProfile' $m.LilyPad (Join-Path $m.L.Src 'active.src') 'Unchanged'))
$recN = $(if (Succ $ri) { Rec $m.L 'LilyPad.ini' } else { $null })
$prm = Get-I3Prop $recN 'Promoted' $null
[void](Assert-I2A 'E-13c-the-old-records-are-promoted-in-the-current-generation' ((Succ $ri) -and ($null -ne $recN) -and ([string]$recN.Presence -ceq 'InPlan') -and ($null -ne $prm) -and ([string](Get-I3Prop $prm 'FromFormat' '') -ceq 'Legacy')) ("install=$(CodeOf $ri) rec=" + $(if ($null -ne $recN) { ConvertTo-I3Json $recN } else { '<none>' })))
[void](Assert-I2A 'E-13d-promotion-keeps-the-old-Origin-byte-for-byte' (($null -ne $recN) -and ([string]$recN.Ownership -ceq 'ReplacedExisting') -and ($recN.ExistedBefore -eq $true) -and ([string]$recN.BeforeSHA256 -ceq [string]$legacyBefore.BeforeSHA256) -and ([string]$recN.Backup -ceq $m.Backup) -and (@(Get-I3Prop $recN 'Backups' @()).Count -eq 0)) ("rec=" + $(if ($null -ne $recN) { ConvertTo-I3Json $recN } else { '<none>' })))
$beforeU = Get-I2CTree $m.L
$u = RunUninstall $m.L $false
[void](Assert-I2A 'E-13e-after-the-install-the-uninstall-still-stops-for-contamination-with-zero-change' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ContaminationBlocksRestore') -and (Test-I2CNoChange $m.L $beforeU) -and ((Txt $m.LilyPad) -ceq $activeV1) -and [System.IO.File]::Exists($m.Backup)) ("succeeded=$(Succ $u) code=$(CodeOf $u)"))
Remove-I2ASandbox $m.L.Root

# ================================================================ E-14 the closed generation's Origin: reported only
$L = New-I3Case 'e14'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$corePlan = Get-I2CPlatformPlan $L @('Core')
$g1 = Invoke-I3 { Invoke-I2BInstall $L $corePlan $false }
$gu = RunUninstall $L $false
$closedDir = Join-Path $L.Product.BackupRoot '20250101-000000'
[void][System.IO.Directory]::CreateDirectory($closedDir)
$closedBackup = Join-Path $closedDir 'aaaaaaaabbbbbbbbccccccccdddddddd.bak'
[System.IO.File]::WriteAllText($closedBackup, 'ORIGIN-OF-THE-CLOSED-GENERATION', $script:Utf8)
$closedRec = [pscustomobject][ordered]@{ Platform = 'PCSX2'; Component = 'EffectiveInputProfile'; Destination = $dLilyPad; InstallAction = 'UpdateOrRepair'; Ownership = 'ReplacedExisting'; ExistedBefore = $true; BeforeSHA256 = (Get-I3Sha $closedBackup); AfterSHA256 = (Get-I3TextSha $activeV1); Backup = $closedBackup }
$usObj = Get-I2CUs $L
Set-I2CProperty $usObj 'DeferredRecords' ([object[]]@([pscustomobject][ordered]@{ Record = $closedRec; Reason = 'DeferredToI3' }))
Write-I2CJson (Get-I2CUsPath $L) $usObj
$usShaBefore = Get-I3Sha (Get-I2CUsPath $L)
Start-Sleep -Milliseconds 1300
$r = RunInstall $L (Get-I3Plan $L 'UpdateOrRepair' 'Add')
$st = $(if (Succ $r) { Get-I2BStateObject $L } else { $null })
$pcsxRecs = @($(if ($null -ne $st) { @($st.Files | Where-Object { [string]$_.Platform -ceq 'PCSX2' }) } else { @() }))
$cur = $(if ($null -ne $st) { Get-I3Rec1 $st 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-14a-the-new-generation-has-exactly-its-own-two-PCSX2-records-and-none-from-the-closed-one' ((Succ $g1) -and (Succ $gu) -and (Succ $r) -and ($pcsxRecs.Count -eq 2) -and ($null -ne $cur) -and ($null -eq (Get-I3Prop $cur 'Promoted' $null)) -and ([string]$cur.BeforeSHA256 -ceq (Get-I3TextSha $script:I3UserOrigin)) -and ([string]$cur.Backup -cne $closedBackup) -and (@($cur.Backups | Where-Object { [string]$_.Path -ceq $closedBackup }).Count -eq 0)) ("core=$(CodeOf $g1) uninstall=$(CodeOf $gu) install=$(CodeOf $r) pcsx2 records=$($pcsxRecs.Count) cur=" + $(if ($null -ne $cur) { ConvertTo-I3Json $cur } else { '<none>' })))
[void](Assert-I2A 'E-14b-the-closed-uninstalled-state-and-its-backup-are-left-byte-identical' (((Get-I3Sha (Get-I2CUsPath $L)) -ceq $usShaBefore) -and [System.IO.File]::Exists($closedBackup) -and ((Txt $closedBackup) -ceq 'ORIGIN-OF-THE-CLOSED-GENERATION')) ("uninstalled-state unchanged=$((Get-I3Sha (Get-I2CUsPath $L)) -ceq $usShaBefore)"))
[void](Assert-I2A 'E-14b2-the-new-generation-install-writes-LilyPad.ini-from-the-current-user-content' ((Succ $r) -and ((Txt $dLilyPad) -ceq $activeV1)) ("succeeded=$(Succ $r) LilyPad.ini=[$(Txt $dLilyPad)]"))
$info = @($(if ($r.Ok) { @(Get-I3Prop $r.Value 'ClosedGenerationPcsx2Origins' @()) } else { @() }))
[void](Assert-I2A 'E-14c-the-closed-generation-Origin-is-only-reported-for-information' (($info.Count -eq 1) -and ([string](Get-I3Prop $info[0] 'Path' '') -ceq $closedBackup) -and ([string](Get-I3Prop $info[0] 'Source' '') -ceq 'DeferredRecords') -and (PathEq2Safe ([string](Get-I3Prop $info[0] 'Destination' '')) $dLilyPad)) ("info=" + (ConvertTo-I3Json $info)))
# ... and it is not used by the uninstall of the new generation either (the new Origin is)
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'E-14d-the-new-generation-uninstall-restores-its-own-Origin-and-keeps-the-closed-DeferredRecords' ((Succ $u) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin) -and ($null -ne $us) -and (@($us.UsedBackups | Where-Object { [string]$_.Path -ceq $closedBackup }).Count -eq 0) -and (@($us.DeferredRecords).Count -eq 0)) ("uninstall=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
Remove-I2ASandbox $L.Root

# ================================================================ E-15 running PCSX2: refused before any write, nothing changed
$L = New-I3Case 'e15'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
$plan = Get-I3Plan $L 'UpdateOrRepair' 'Add'
$before = Get-I2BFullTree $L
$r = RunInstall $L $plan { param($phase) if ($phase -eq 'A') { throw 'BlockedByRunningProcesses|RunningProducts=PCSX2' } }
[void](Assert-I2A 'E-15a-gate-A-refuses-before-anything-is-created' ((-not (Succ $r)) -and ($r.Error -like '*BlockedByRunningProcesses*') -and (Same $before (Get-I2BFullTree $L)) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin)) ("ok=$($r.Ok) error=$($r.Error)"))
$r = RunInstall $L $plan { param($phase) if ($phase -eq 'B') { throw 'BlockedByRunningProcesses|RunningProducts=PCSX2' } }
[void](Assert-I2A 'E-15b-gate-B-refuses-after-the-writes-and-everything-is-rolled-back' ((-not (Succ $r)) -and ((CodeOf $r) -ceq 'BlockedByRunningProcesses') -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin) -and (-not [System.IO.File]::Exists((Get-I3Dest $L 'DenGo-Controller-Converter.lily'))) -and (-not [System.IO.File]::Exists($L.Product.StatePath)) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) ("code=$(CodeOf $r) LilyPad.ini=[$(Txt $dLilyPad)] state=$([System.IO.File]::Exists($L.Product.StatePath))"))
Remove-I2ASandbox $L.Root

# ================================================================ E-16..E-19 (I3-D: formal tests of the I3-C behaviour that no earlier suite covered)
#   E-16 a file KEPT in one run is replaced by an explicit consent of a LATER run: ReplacedExisting, Origin = the backup of that replacement, the uninstall restores it
#   E-17 the Origin that was set aside (PreviousOrigin) survives keep -> consent: Backups[0] does not move, the uninstall restores THAT Origin and never a later backup
#   E-18 an invalid Origin beats consent (edited file, no consent and consent alike): nothing is written, the record is kept whole, the uninstall stops with zero change
#   E-19 Backups[1..] are never an Origin: with the real Origin gone the uninstall stops and does not fall back to a valid update backup
# The plans come from the REAL planner (New-DenGoPcsx2PlanItems) with the real previous state, so that the whole chain plan -> install -> state -> plan -> install -> uninstall is exercised.
function PlanReal($L, [bool]$Consent) {
    $res = [pscustomobject]@{ Status = 'Resolved'; SelectedRoot = (Split-Path $L.Pcsx2Inis -Parent); Roots = @((Split-Path $L.Pcsx2Inis -Parent)); Detected = @() }
    return (Invoke-I3 {
            $us = Read-DenGoUninstalledState $L.Product
            New-DenGoPcsx2PlanItems -Resolution $res -LilySource (Join-Path $L.Src 'lily.src') -ActiveSource (Join-Path $L.Src 'active.src') -ReplaceConsent $Consent -Previous (Read-DenGoPreviousState $L.Product) -Layout $L.Product -LastClosedTransactionId ([string]$us.LastClosedTransactionId)
        })
}
function ActsOf($P) { if (-not $P.Ok) { return ('<exception: ' + $P.Error + '>') } return (@($P.Value | ForEach-Object { [string]$_.Component + '=' + [string]$_.Action + '/' + [string]$_.Reason }) -join ',') }
function ActOfPlan($P, [string]$Component) { if (-not $P.Ok) { return '<exception>' } foreach ($i in @($P.Value)) { if ([string]$i.Component -ceq $Component) { return [string]$i.Action } } return '<none>' }
function ReasonOfPlan($P, [string]$Component) { if (-not $P.Ok) { return '<exception>' } foreach ($i in @($P.Value)) { if ([string]$i.Component -ceq $Component) { return [string]$i.Reason } } return '<none>' }
function RunPlanned($L, $P) { if (-not $P.Ok) { return $P } return (RunInstall $L ([object[]]@($P.Value))) }

# ---------------------------------------------------------------- E-16 keep, then a later explicit consent
$L = New-I3Case 'e16'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'; $dLily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$p1 = PlanReal $L $false
$r1 = RunPlanned $L $p1
$rec1 = $(if (Succ $r1) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-16a-run-1-without-consent-keeps-the-file-and-records-it-as-the-users-without-an-Origin' (((ActOfPlan $p1 'EffectiveInputProfile') -ceq 'PreserveUserModified') -and (Succ $r1) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin) -and ($null -ne $rec1) -and ([string]$rec1.Ownership -ceq 'PreservedUserFile') -and ([string]$rec1.Backup -ceq '') -and (@($rec1.Backups).Count -eq 0) -and ((Cnt (Get-I2CBackupFiles $L)) -eq 0)) ("plan=$(ActsOf $p1) install=$(CodeOf $r1) rec=" + $(if ($null -ne $rec1) { ConvertTo-I3Json $rec1 } else { '<none>' })))
$p2 = PlanReal $L $true
$r2 = RunPlanned $L $p2
$rec2 = $(if (Succ $r2) { Rec $L 'LilyPad.ini' } else { $null })
$bkTxt = $(if ($null -ne $rec2 -and @($rec2.Backups).Count -ge 1) { Txt ([string]$rec2.Backups[0].Path) } else { '<none>' })
[void](Assert-I2A 'E-16b-the-later-run-with-explicit-consent-replaces-the-file-and-the-record-becomes-ReplacedExisting' (((ActOfPlan $p2 'EffectiveInputProfile') -ceq 'UpdateOrRepair') -and ((ReasonOfPlan $p2 'EffectiveInputProfile') -ceq 'ConsentGiven') -and (Succ $r2) -and ((Txt $dLilyPad) -ceq $activeV1) -and ($null -ne $rec2) -and ([string]$rec2.Ownership -ceq 'ReplacedExisting') -and ($rec2.ExistedBefore -eq $true)) ("plan=$(ActsOf $p2) install=$(CodeOf $r2) LilyPad.ini=[$(Txt $dLilyPad)] rec=" + $(if ($null -ne $rec2) { ConvertTo-I3Json $rec2 } else { '<none>' })))
[void](Assert-I2A 'E-16c-its-Origin-is-the-measured-content-right-before-that-replacement-and-it-is-Backups-0' (($null -ne $rec2) -and ([string]$rec2.BeforeSHA256 -ceq (Get-I3TextSha $script:I3UserOrigin)) -and (@($rec2.Backups).Count -eq 1) -and ([string]$rec2.Backup -ceq [string]$rec2.Backups[0].Path) -and ([string]$rec2.Backups[0].SHA256 -ceq [string]$rec2.BeforeSHA256) -and ($bkTxt -ceq $script:I3UserOrigin) -and ($null -eq (Get-I3Prop $rec2 'PreviousOrigin' $null))) ("backups=" + $(if ($null -ne $rec2) { ConvertTo-I3Json @($rec2.Backups) } else { '<none>' }) + " backup text=[$bkTxt]"))
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'E-16d-the-uninstall-restores-the-users-content-from-that-Origin' ((Succ $u) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin) -and ($null -ne $us) -and ($null -ne $rec2) -and (@($us.UsedBackups | Where-Object { [string]$_.Path -ceq [string]$rec2.Backup }).Count -eq 1) -and ($us.Counts.Restored -eq 1)) ("uninstall=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)] used=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UsedBackups) } else { '<none>' })))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- E-17 the set-aside Origin survives keep -> consent; the update backup is never the Origin
$L = New-I3Case 'e17'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
$pa = PlanReal $L $true
$ra = RunPlanned $L $pa
$o1 = $(if (Succ $ra) { Rec $L 'LilyPad.ini' } else { $null })
$o1Json = $(if ($null -ne $o1) { ConvertTo-I3Json @($o1.Backups[0]) } else { '' })
$edited = 'USER-EDIT-AFTER-THE-GENERATION-STARTED'
[System.IO.File]::WriteAllText($dLilyPad, $edited, $script:Utf8)
$pb = PlanReal $L $false
$rb = RunPlanned $L $pb
$kept = $(if (Succ $rb) { Rec $L 'LilyPad.ini' } else { $null })
$po = Get-I3Prop $kept 'PreviousOrigin' $null
[void](Assert-I2A 'E-17a-keeping-an-edited-file-sets-the-Origin-aside-as-PreviousOrigin-and-keeps-Backups-verbatim' (((ActOfPlan $pb 'EffectiveInputProfile') -ceq 'PreserveUserModified') -and (Succ $rb) -and ((Txt $dLilyPad) -ceq $edited) -and ($null -ne $kept) -and ([string]$kept.Ownership -ceq 'PreservedUserFile') -and ($null -ne $po) -and ([string](Get-I3Prop $po 'Backup' '') -ceq [string]$o1.Backup) -and ([string](Get-I3Prop $po 'BeforeSHA256' '') -ceq [string]$o1.BeforeSHA256) -and ((Get-I3Prop $po 'ExistedBefore' $false) -eq $true) -and ((ConvertTo-I3Json @($kept.Backups)) -ceq (ConvertTo-I3Json @($o1.Backups)))) ("plan=$(ActsOf $pb) keep=$(CodeOf $rb) rec=" + $(if ($null -ne $kept) { ConvertTo-I3Json $kept } else { '<none>' })))
$pc = PlanReal $L $true
$rc = RunPlanned $L $pc
$fin = $(if (Succ $rc) { Rec $L 'LilyPad.ini' } else { $null })
$editSha = Get-I3TextSha $edited
[void](Assert-I2A 'E-17b-the-later-consent-keeps-the-set-aside-Origin-and-does-not-move-Backups-0' (((ActOfPlan $pc 'EffectiveInputProfile') -ceq 'UpdateOrRepair') -and (Succ $rc) -and ((Txt $dLilyPad) -ceq $activeV1) -and ($null -ne $fin) -and ([string]$fin.Ownership -ceq 'ReplacedExisting') -and ([string]$fin.Backup -ceq [string]$o1.Backup) -and ([string]$fin.BeforeSHA256 -ceq [string]$o1.BeforeSHA256) -and ($fin.ExistedBefore -eq $true) -and ((ConvertTo-I3Json @($fin.Backups[0])) -ceq $o1Json)) ("plan=$(ActsOf $pc) install=$(CodeOf $rc) rec=" + $(if ($null -ne $fin) { ConvertTo-I3Json $fin } else { '<none>' })))
$b1ok = ($null -ne $fin) -and (@($fin.Backups).Count -eq 2) -and ([string]$fin.Backups[1].SHA256 -ceq $editSha) -and ((Txt ([string]$fin.Backups[1].Path)) -ceq $edited) -and ([string]$fin.Backups[1].Path -cne [string]$fin.Backup) -and ([string]$fin.Backups[1].SHA256 -cne [string]$fin.BeforeSHA256)
[void](Assert-I2A 'E-17c-the-content-that-was-replaced-is-Backups-1-and-is-not-the-Origin' $b1ok ("backups=" + $(if ($null -ne $fin) { ConvertTo-I3Json @($fin.Backups) } else { '<none>' })))
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'E-17d-the-uninstall-restores-the-users-ORIGINAL-content-never-the-edited-one' ((Succ $u) -and ((Txt $dLilyPad) -ceq $script:I3UserOrigin) -and ((Txt $dLilyPad) -cne $edited)) ("uninstall=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
[void](Assert-I2A 'E-17e-only-the-Origin-is-recorded-as-used-and-Backups-1-is-reported-unused-and-kept' (($null -ne $us) -and ($null -ne $fin) -and (@($us.UsedBackups).Count -eq 1) -and ([string]$us.UsedBackups[0].Path -ceq [string]$fin.Backup) -and (@($us.UnusedBackups | Where-Object { [string]$_.Path -ceq [string]$fin.Backups[1].Path -and [string]$_.Reason -ceq 'UpdateBackup' }).Count -eq 1) -and [System.IO.File]::Exists([string]$fin.Backups[1].Path)) ("used=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UsedBackups) } else { '<none>' }) + " unused=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UnusedBackups) } else { '<none>' })))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- E-18 an invalid Origin beats consent
$L = New-I3Case 'e18'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
$pa = PlanReal $L $true
$ra = RunPlanned $L $pa
$o1 = $(if (Succ $ra) { Rec $L 'LilyPad.ini' } else { $null })
$edited = 'USER-EDIT-WHILE-THE-ORIGIN-IS-GONE'
[System.IO.File]::WriteAllText($dLilyPad, $edited, $script:Utf8)
if ($null -ne $o1) { [System.IO.File]::Delete([string]$o1.Backup) }
$stateBefore = $(if (Succ $ra) { Get-I3Rec1 (Get-I2BStateObject $L) 'LilyPad.ini' } else { $null })
$pn = PlanReal $L $false; $py = PlanReal $L $true
[void](Assert-I2A 'E-18a-edited-file-and-an-invalid-Origin-is-PreserveOriginInvalid-with-and-without-consent' (((ActOfPlan $pn 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid') -and ((ActOfPlan $py 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid') -and ((ReasonOfPlan $py 'EffectiveInputProfile') -ceq 'OriginInvalid')) ("no consent: $(ActsOf $pn) | consent: $(ActsOf $py)"))
$filesBefore = Cnt (Get-I2CBackupFiles $L)
foreach ($mode in @(@('no-consent', $pn), @('consent', $py))) {
    $rr = RunPlanned $L $mode[1]
    $recNow = $(if (Succ $rr) { Get-I3Rec1 (Get-I2BStateObject $L) 'LilyPad.ini' } else { $null })
    [void](Assert-I2A ('E-18b-' + $mode[0] + '-nothing-is-written-no-backup-is-made-and-the-earlier-record-is-kept-whole') ((Succ $rr) -and ((Txt $dLilyPad) -ceq $edited) -and ((Cnt (Get-I2CBackupFiles $L)) -eq $filesBefore) -and ($null -ne $recNow) -and ($null -ne $stateBefore) -and ([string]$recNow.Ownership -ceq 'ReplacedExisting') -and ([string]$recNow.Backup -ceq [string]$stateBefore.Backup) -and ([string]$recNow.BeforeSHA256 -ceq [string]$stateBefore.BeforeSHA256) -and ((ConvertTo-I3Json @($recNow.Backups)) -ceq (ConvertTo-I3Json @($stateBefore.Backups))) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) ("install=$(CodeOf $rr) LilyPad.ini=[$(Txt $dLilyPad)] backup files $filesBefore -> $(Cnt (Get-I2CBackupFiles $L)) rec=" + $(if ($null -ne $recNow) { ConvertTo-I3Json $recNow } else { '<none>' })))
}
$beforeU = Get-I2CTree $L
$u = RunUninstall $L $false
[void](Assert-I2A 'E-18c-the-uninstall-stops-on-the-invalid-Origin-with-zero-change' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ReplacedExistingBackupInvalid') -and (Test-I2CNoChange $L $beforeU) -and ((Txt $dLilyPad) -ceq $edited)) ("uninstall succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- E-19 Backups[1..] never replace a lost Origin
$L = New-I3Case 'e19'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
$pa = PlanReal $L $true
$ra = RunPlanned $L $pa
$o1 = $(if (Succ $ra) { Rec $L 'LilyPad.ini' } else { $null })
[System.IO.File]::WriteAllText((Join-Path $L.Src 'active.src'), 'DENGO-ACTIVE-LILYPAD-V2', $script:Utf8)
$pu = PlanReal $L $false
$ru = RunPlanned $L $pu
$upd = $(if (Succ $ru) { Rec $L 'LilyPad.ini' } else { $null })
$b1 = $(if ($null -ne $upd -and @($upd.Backups).Count -ge 2) { $upd.Backups[1] } else { $null })
[void](Assert-I2A 'E-19a-an-update-inside-the-generation-leaves-a-valid-update-backup-as-Backups-1' (((ActOfPlan $pu 'EffectiveInputProfile') -ceq 'UpdateOrRepair') -and (Succ $ru) -and ((Txt $dLilyPad) -ceq 'DENGO-ACTIVE-LILYPAD-V2') -and ($null -ne $b1) -and ([string]$b1.SHA256 -ceq (Get-I3TextSha $activeV1)) -and ((Txt ([string]$b1.Path)) -ceq $activeV1) -and ([string]$upd.Backup -ceq [string]$o1.Backup)) ("plan=$(ActsOf $pu) update=$(CodeOf $ru) backups=" + $(if ($null -ne $upd) { ConvertTo-I3Json @($upd.Backups) } else { '<none>' })))
if ($null -ne $o1) { [System.IO.File]::Delete([string]$o1.Backup) }
$beforeU = Get-I2CTree $L
$u = RunUninstall $L $false
[void](Assert-I2A 'E-19b-with-the-Origin-gone-the-uninstall-stops-and-does-not-fall-back-to-the-valid-update-backup' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ReplacedExistingBackupInvalid') -and (Test-I2CNoChange $L $beforeU) -and ((Txt $dLilyPad) -ceq 'DENGO-ACTIVE-LILYPAD-V2') -and ($null -ne $b1) -and [System.IO.File]::Exists([string]$b1.Path)) ("uninstall succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
$ud = Invoke-I3 { Get-DenGoUninstallDryRun -Layout $L.Product -Options (Get-I2COptions $false) }
$dryBlock = @($(if ($ud.Ok) { @($ud.Value.Blocking | Where-Object { ([string]$_.Destination) -like '*LilyPad.ini' }) } else { @() }))
[void](Assert-I2A 'E-19c-the-dry-run-reports-the-same-stop-and-plans-no-restore' ($ud.Ok -and ([string]$ud.Value.ErrorCode -ceq 'ReplacedExistingBackupInvalid') -and ($dryBlock.Count -eq 1) -and ([string]$dryBlock[0].Decision -ceq 'UnsafeOrUnknown') -and ([string]$dryBlock[0].Op -ceq '') -and (Test-I2CNoChange $L $beforeU)) ("dry run ok=$($ud.Ok) code=$(if ($ud.Ok) { $ud.Value.ErrorCode } else { '?' }) blocking entries for LilyPad.ini=$($dryBlock.Count)" + (Get-I3Err $ud)))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- E-20 an invalid PreviousOrigin beats consent (owner decision: no write, no replacement, no backup update)
$L = New-I3Case 'e20'
$dLilyPad = Get-I3Dest $L 'LilyPad.ini'
$pa = PlanReal $L $true
$ra = RunPlanned $L $pa
$o1 = $(if (Succ $ra) { Rec $L 'LilyPad.ini' } else { $null })
$edited = 'USER-EDIT-BEFORE-THE-SET-ASIDE-ORIGIN-IS-LOST'
[System.IO.File]::WriteAllText($dLilyPad, $edited, $script:Utf8)
$pk = PlanReal $L $false
$rk = RunPlanned $L $pk
$kept = $(if (Succ $rk) { Rec $L 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'E-20a-setup-the-edited-file-is-kept-and-its-Origin-is-set-aside' ((Succ $ra) -and (Succ $rk) -and ($null -ne $kept) -and ([string]$kept.Ownership -ceq 'PreservedUserFile') -and ($null -ne (Get-I3Prop $kept 'PreviousOrigin' $null))) ("origin run=$(CodeOf $ra) keep run=$(CodeOf $rk)"))
if ($null -ne $o1) { [System.IO.File]::Delete([string]$o1.Backup) }
$keptJson = $(if ($null -ne $kept) { ConvertTo-I3Json $kept } else { '' })
$pn = PlanReal $L $false; $py = PlanReal $L $true
[void](Assert-I2A 'E-20b-with-the-set-aside-Origin-gone-the-plan-is-PreserveOriginInvalid-with-and-without-consent' (((ActOfPlan $pn 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid') -and ((ActOfPlan $py 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid') -and ((ReasonOfPlan $py 'EffectiveInputProfile') -ceq 'OriginInvalid')) ("no consent: $(ActsOf $pn) | consent: $(ActsOf $py)"))
$filesBefore = Cnt (Get-I2CBackupFiles $L)
foreach ($mode in @(@('no-consent', $pn), @('consent', $py))) {
    $rr = RunPlanned $L $mode[1]
    $recNow = $(if (Succ $rr) { Rec $L 'LilyPad.ini' } else { $null })
    [void](Assert-I2A ('E-20c-' + $mode[0] + '-nothing-is-written-replaced-or-backed-up-and-the-kept-record-is-whole') ((Succ $rr) -and ((Txt $dLilyPad) -ceq $edited) -and ((Cnt (Get-I2CBackupFiles $L)) -eq $filesBefore) -and ($null -ne $recNow) -and ([string]$recNow.Ownership -ceq 'PreservedUserFile') -and ((ConvertTo-I3Json (Get-I3Prop $recNow 'PreviousOrigin' $null)) -ceq (ConvertTo-I3Json (Get-I3Prop $kept 'PreviousOrigin' $null))) -and ((ConvertTo-I3Json @($recNow.Backups)) -ceq (ConvertTo-I3Json @($kept.Backups))) -and ((Cnt (Test-I2BLeftovers $L $true)) -eq 0)) ("install=$(CodeOf $rr) LilyPad.ini=[$(Txt $dLilyPad)] backup files $filesBefore -> $(Cnt (Get-I2CBackupFiles $L)) rec=" + $(if ($null -ne $recNow) { ConvertTo-I3Json $recNow } else { '<none>' })))
}
$u = RunUninstall $L $false
[void](Assert-I2A 'E-20d-the-uninstall-leaves-the-kept-users-file-alone' ((Succ $u) -and ((Txt $dLilyPad) -ceq $edited)) ("uninstall=$(CodeOf $u) LilyPad.ini=[$(Txt $dLilyPad)]"))
Remove-I2ASandbox $L.Root

# ================================================================ E-05 (last: the fault harness replaces the primitive layer) a change between the plan and the write is never overwritten
function Invoke-I3HarnessCase([string]$Name, [string]$Pattern, [string]$Tampered) {
    Use-I2BHarnessIds
    $L = New-I3Case $Name
    $script:i3Tamper = Get-I3Dest $L 'LilyPad.ini'
    $script:i3TamperText = $Tampered
    $plan = Get-I3Plan $L 'UpdateOrRepair' 'Add'
    Install-I2AHarness
    try {
        Reset-I2AFault -Mode 'Label' -Pattern $Pattern -Nth 1 -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:i3Tamper, $script:i3TamperText, [System.Text.Encoding]::ASCII) }; Reset-I2ACounters
        $r = RunInstall $L $plan
        Release-I2AHeld
    } finally { Uninstall-I2AHarness; Use-I2BProductIds }
    return [pscustomobject]@{ L = $L; R = $r }
}
$c = Invoke-I3HarnessCase 'e05a' '^after:Journal:Verified#0$' 'CHANGED-DURING-APPLY-BY-PCSX2'
[void](Assert-I2A 'E-05a-a-change-during-apply-is-not-overwritten-and-needs-a-manual-check' ((-not (Succ $c.R)) -and ((CodeOf $c.R) -ceq 'DestinationChangedDuringApply') -and ($c.R.Value.ManualCheckRequired -eq $true) -and ((Txt (Get-I3Dest $c.L 'LilyPad.ini')) -ceq 'CHANGED-DURING-APPLY-BY-PCSX2')) ("succeeded=$(Succ $c.R) code=$(CodeOf $c.R) LilyPad.ini=[$(Txt (Get-I3Dest $c.L 'LilyPad.ini'))]"))
Remove-I2ASandbox $c.L.Root
$c = Invoke-I3HarnessCase 'e05b' '^before:Fs-DirExists:T0001$' 'CHANGED-BEFORE-BEGIN-MEASURE'
[void](Assert-I2A 'E-05b-a-change-before-Begin-is-PlanStale-and-the-file-is-never-overwritten' ((-not (Succ $c.R)) -and ((CodeOf $c.R) -ceq 'PlanStale') -and ((Txt (Get-I3Dest $c.L 'LilyPad.ini')) -ceq 'CHANGED-BEFORE-BEGIN-MEASURE') -and (-not [System.IO.File]::Exists((Get-I3Dest $c.L 'DenGo-Controller-Converter.lily')))) ("succeeded=$(Succ $c.R) code=$(CodeOf $c.R) LilyPad.ini=[$(Txt (Get-I3Dest $c.L 'LilyPad.ini'))]"))
Remove-I2ASandbox $c.L.Root
Complete-I2ATests
