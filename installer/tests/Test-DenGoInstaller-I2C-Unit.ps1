# I2-C unit tests: uninstall role specs and leaf gates, source gate, ownership decisions (all six ownership kinds x current state x backups),
# Origin rule (R1-R7), shortcut contract (A-F, Earlier[]), generation / contamination, AlreadyUninstalled, archive plan, state builder,
# recovery gate decisions, failure mapping. Sandboxes only (TEMP).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')

$L = New-I2CCase 'unit'
$P = $L.Product
$r0 = Install-I2CGeneration $L
$pristine = Save-I2ATree $L.Root
function Reset-Case { Restore-I2ATree $L.Root $pristine }
function Cl($Object) { return ($Object | ConvertTo-Json -Depth 9 | ConvertFrom-Json) }
function Rec([string]$Leaf, [string]$Platform = '') { return (Cl (Get-I2CRecord (Get-I2CIs $L) $Leaf $Platform)) }
$gen0 = [pscustomobject]@{ ContaminationSuspect = $false; LastClosedTransactionId = '' }
$genC = [pscustomobject]@{ ContaminationSuspect = $true; LastClosedTransactionId = '' }
function Dec($Rec, [bool]$Incl = $true, $Gen = $null) { if ($null -eq $Gen) { $Gen = $gen0 }; return (Get-DenGoUninstallFileDecision $P $Rec $Gen $Incl) }
function Is($Id, $D, [string]$Decision, [string]$Code = '', [string]$Detail = '') {
    $ok = ($D.Decision -eq $Decision)
    if ($ok -and $Code.Length -gt 0) { $ok = ($D.ReasonCode -eq $Code) }
    [void](Assert-I2A $Id $ok ($Detail + " => decision=$($D.Decision) code=$($D.ReasonCode) blocking=$($D.Blocking) reason=[$($D.Reason)]"))
}
function Blocked($Id, $D, [string]$Code, [string]$Detail = '') {
    [void](Assert-I2A $Id (($D.Blocking -eq $true) -and ($D.BlockCode -eq $Code) -and ($D.Op.Length -eq 0)) ($Detail + " => blocking=$($D.Blocking) code=$($D.BlockCode) op=[$($D.Op)] reason=[$($D.Reason)]"))
}
[void](Assert-I2A 'UC00-fixture-installed' ($r0.Succeeded -eq $true) "install succeeded=$($r0.Succeeded) code=$($r0.ErrorCode)")

try {
    # =================================================== UC1 roles and gates
    $archSha = ('ab' * 32)
    $archName = 'installed-state.' + $archSha + '.json'
    $sd = Get-DenGoUninstallRoleSpec $P 'StateDelete' ''
    [void](Assert-I2A 'UC1-statedelete-spec' (($sd.Ok -eq $true) -and ($sd.Dests.Count -eq 1) -and ($sd.Dests[0] -eq $P.StatePath) -and ($sd.Dirs.Count -eq 0)) 'StateDelete allows installed-state.json only')
    $sa = Get-DenGoUninstallRoleSpec $P 'StateArchive' $archName
    [void](Assert-I2A 'UC1-statearchive-spec' (($sa.Ok -eq $true) -and ($sa.Dests[0] -eq (Join-Path $P.StateRoot ('history\' + $archName))) -and ($sa.Dirs[0] -eq (Join-Path $P.StateRoot 'history'))) 'StateArchive allows the one history leaf named in the tag')
    foreach ($bad in @('installed-state.json', ('installed-state.' + ('AB' * 32) + '.json'), ('installed-state.' + ('ab' * 31) + '.json'), ('..\' + $archName), ('x|' + $archName), ('other-state.' + $archSha + '.json'), '')) {
        $s = Get-DenGoUninstallRoleSpec $P 'StateArchive' $bad
        [void](Assert-I2A ('UC1-statearchive-bad-name-' + $bad.Length + '-' + [Math]::Abs($bad.GetHashCode() % 1000)) ($s.Ok -eq $false) ("rejected archive name [$bad]"))
    }
    $g = Test-DenGoUninstallLeafGate $P 'StateDelete' '' $P.StatePath 'Dest'
    [void](Assert-I2A 'UC1-statedelete-dest' ($g.Allowed -eq $true) 'installed-state.json is a StateDelete destination')
    $g = Test-DenGoUninstallLeafGate $P 'StateDelete' '' ($P.StatePath + '.dengo.tmp') 'Tmp'
    [void](Assert-I2A 'UC1-statedelete-tmp' ($g.Allowed -eq $true) 'its temporary leaf')
    $g = Test-DenGoUninstallLeafGate $P 'StateDelete' '' (Join-Path $P.StateRoot 'other.json') 'Dest'
    [void](Assert-I2A 'UC1-statedelete-other-denied' (($g.Allowed -eq $false) -and ($g.Reason -eq 'LeafNotAllowed')) 'another file in the state folder is denied')
    $g = Test-DenGoUninstallLeafGate $P 'StateDelete' '' (Join-Path $P.StateRoot 'uninstalled-state.json') 'Dest'
    [void](Assert-I2A 'UC1-statedelete-uninstalled-state-not-a-dest' ($g.Allowed -eq $false) 'uninstalled-state.json is never a delete destination')
    $g = Test-DenGoUninstallLeafGate $P 'StateArchive' $archName (Join-Path $P.StateRoot ('history\' + $archName)) 'Dest'
    [void](Assert-I2A 'UC1-statearchive-dest' ($g.Allowed -eq $true) 'the archive leaf')
    $g = Test-DenGoUninstallLeafGate $P 'StateArchive' $archName (Join-Path $P.StateRoot ('history\' + $archName + '.dengo.tmp')) 'Tmp'
    [void](Assert-I2A 'UC1-statearchive-tmp' ($g.Allowed -eq $true) 'its tmp')
    $g = Test-DenGoUninstallLeafGate $P 'StateArchive' $archName (Join-Path $P.StateRoot 'history') 'Dir'
    [void](Assert-I2A 'UC1-statearchive-dir' ($g.Allowed -eq $true) 'the history folder may be created')
    $g = Test-DenGoUninstallLeafGate $P 'StateArchive' $archName (Join-Path $P.StateRoot ('history\installed-state.' + ('cd' * 32) + '.json')) 'Dest'
    [void](Assert-I2A 'UC1-statearchive-other-leaf-denied' ($g.Allowed -eq $false) 'a different archive leaf is denied')
    $txnPattern = $P.TxnIdPattern
    $okId = '20261016T000000Z-0123abcd'
    foreach ($case in @(@('us', (Join-Path $P.StateRoot 'uninstalled-state.json'), $true), @('us-tmp', (Join-Path $P.StateRoot 'uninstalled-state.json.tmp'), $true), @('um', (Join-Path $P.StateRoot 'uninstalling.json'), $true),
            @('im', (Join-Path $P.StateRoot 'installing.json'), $true), @('journal', (Join-Path $P.StateRoot ('txn\' + $okId + '\journal.jsonl')), $true), @('history-txn', (Join-Path $P.StateRoot ('history\txn-' + $okId + '.committed.jsonl')), $true),
            @('is-as-infra', $P.StatePath, $false), @('rollback', (Join-Path $P.DataRoot 'UninstallRollback'), $false), @('rollback-file', (Join-Path $P.DataRoot 'UninstallRollback\20260101-000000\x.bak'), $false), @('random', (Join-Path $P.StateRoot 'random.txt'), $false))) {
        $g = Test-DenGoUninstallLeafGate $P 'App' '' $case[1] 'Infra'
        [void](Assert-I2A ('UC1-infra-' + $case[0]) ($g.Allowed -eq $case[2]) ('Infra gate for ' + $case[0] + ' => ' + $g.Reason))
    }
    $g = Test-DenGoLeafGate $P 'App' '' (Join-Path $P.StateRoot 'uninstalled-state.json') 'Infra'
    [void](Assert-I2A 'UC1-install-gate-unchanged-uninstalled-state' ($g.Allowed -eq $false) 'the Install leaf gate still denies uninstalled-state.json (I2B-U1)')
    $g = Test-DenGoLeafGate $P 'App' '' (Join-Path $P.DataRoot 'UninstallRollback') 'Infra'
    [void](Assert-I2A 'UC1-install-gate-unchanged-uninstallrollback' ($g.Allowed -eq $false) 'the Install leaf gate still denies UninstallRollback')
    $g = Test-DenGoUninstallLeafGate $P 'App' '' (Join-Path $P.AppDir 'Uninstall.exe') 'Dest'
    [void](Assert-I2A 'UC1-uninstall-exe-never-a-dest' ($g.Allowed -eq $false) 'Uninstall.exe belongs to the wrapper')
    $dll5 = Join-Path $L.Bve5 'Input Devices\DenGoControllerConverter.dll'
    $g = Test-DenGoUninstallLeafGate $P 'Bve5' $L.Bve5 $dll5 'Dest'
    [void](Assert-I2A 'UC1-install-roles-reused-bve5' ($g.Allowed -eq $true) 'install roles are reused as they are')
    $g = Test-DenGoUninstallLeafGate $P 'Bve5' $L.Bve6 (Join-Path $L.Bve6 'Input Devices\DenGoControllerConverter.dll') 'Dest'
    [void](Assert-I2A 'UC1-bve-machine-mismatch' ($g.Allowed -eq $false) 'x64 root for the BVE5 role')
    # Test-DenGoUninstallItemGate
    $f = Test-DenGoUninstallItemGate $P 'InstallerState|InstalledState|StateDelete|' $P.StatePath ($P.StatePath + '.dengo.tmp') @() (Join-Path $P.BackupRoot ($okId + '\0001.bak')) $okId
    [void](Assert-I2A 'UC1-itemgate-state-delete' ($f.Count -eq 0) ('failures: ' + [string]::Join(';', $f)))
    $f = Test-DenGoUninstallItemGate $P 'InstallerState|InstalledState|StateDelete|' (Join-Path $P.StateRoot 'other.json') (Join-Path $P.StateRoot 'other.json.dengo.tmp') @() '' $okId
    [void](Assert-I2A 'UC1-itemgate-rejects-other' ($f.Count -ge 1) 'a forged tag cannot reach another file')
    $f = Test-DenGoUninstallItemGate $P 'garbage' $P.StatePath ($P.StatePath + '.dengo.tmp') @() '' $okId
    [void](Assert-I2A 'UC1-itemgate-bad-tag' (($f.Count -eq 1) -and ($f[0] -like 'TagInvalid*')) 'a malformed tag')

    # =================================================== UC2 source gate (Origin backups)
    $newBak = Join-Path $P.BackupRoot ($okId + '\0003.bak')
    $legBak = Join-Path $P.BackupRoot '20250101-000000\0123456789abcdef0123456789abcdef.bak'
    $sg = Test-DenGoUninstallSourceGate $P $newBak
    [void](Assert-I2A 'UC2-source-new-format' (($sg.Allowed -eq $true) -and ($sg.Format -eq 'Txn') -and ($sg.TxnId -eq $okId)) "format=$($sg.Format)")
    $sg = Test-DenGoUninstallSourceGate $P $legBak
    [void](Assert-I2A 'UC2-source-legacy-format' (($sg.Allowed -eq $true) -and ($sg.Format -eq 'Legacy')) "format=$($sg.Format)")
    foreach ($case in @(@('outside-root', (Join-Path $L.Root 'OldBackups\x.bak')), @('wrong-leaf', (Join-Path $P.BackupRoot ($okId + '\notes.txt'))), @('wrong-folder', (Join-Path $P.BackupRoot 'folder\0001.bak')), @('too-deep', (Join-Path $P.BackupRoot ($okId + '\sub\0001.bak'))), @('relative', 'x\0001.bak'), @('dotdot', (Join-Path $P.BackupRoot ($okId + '\..\0001.bak'))))) {
        $sg = Test-DenGoUninstallSourceGate $P $case[1]
        [void](Assert-I2A ('UC2-source-denied-' + $case[0]) ($sg.Allowed -eq $false) ("reason=$($sg.Reason)"))
    }
    $jTarget = Join-Path $L.Root 'JunctionTarget'
    [System.IO.Directory]::CreateDirectory($jTarget) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $jTarget '0001.bak'), 'x', $script:Utf8)
    [System.IO.Directory]::CreateDirectory($P.BackupRoot) | Out-Null
    $jLink = Join-Path $P.BackupRoot '20261016T000001Z-deadbeef'
    & cmd.exe /c ('mklink /J "' + $jLink + '" "' + $jTarget + '"') | Out-Null
    $sg = Test-DenGoUninstallSourceGate $P (Join-Path $jLink '0001.bak')
    [void](Assert-I2A 'UC2-source-denied-through-a-junction' (($sg.Allowed -eq $false) -and ($sg.Reason -eq 'PathReparse')) "reason=$($sg.Reason)")
    [System.IO.Directory]::Delete($jLink)
    Reset-Case

    # =================================================== UC3 ownership decisions
    $recExe = Rec 'DenGoControllerConverter.exe' 'Core'
    $recC6 = Rec 'DenGoControllerConverter.dll' 'BVE6'
    $recC5 = Rec 'DenGoControllerConverter.dll' 'BVE5'
    $recMig = Rec 'DenGoVehicleSpec.BveEx.Bridge.dll'
    $recRep = Rec 'Den-Go-Controller.yml'
    [void](Assert-I2A 'UC3-fixture-ownerships' (($recExe.Ownership -eq 'CreatedByInstaller') -and ($recMig.Ownership -eq 'MigratedMatchingDenGoFile') -and ($recRep.Ownership -eq 'ReplacedExisting') -and ($recRep.Backups.Count -ge 1)) "Created=$($recExe.Ownership) Migrated=$($recMig.Ownership) Replaced=$($recRep.Ownership)")
    # --- CreatedByInstaller
    Is 'UC3-created-match-remove' (Dec $recExe) 'Remove' 'Remove' 'file == installed SHA'
    $d = Dec $recExe; [void](Assert-I2A 'UC3-created-remove-is-delete-item' (($d.Op -eq 'Delete') -and ($d.Source -eq '')) 'a Delete item, no source')
    [System.IO.File]::WriteAllText($P.AppExe, 'user edited', $script:Utf8)
    $d = Dec $recExe; Is 'UC3-created-modified-preserved' $d 'PreserveModified' 'ModifiedByUser' 'file != installed SHA'
    [void](Assert-I2A 'UC3-created-modified-flags' (($d.Residual -eq $true) -and ($d.ReviewRecommended -eq $true) -and ($d.Op -eq '') -and ($d.Blocking -eq $false)) 'residual, review recommended, no item, not blocking (Completed is allowed)')
    Reset-Case
    [System.IO.File]::Delete($P.AppExe)
    Is 'UC3-created-missing' (Dec $recExe) 'AlreadyMissing' 'AlreadyMissing' 'file absent'
    Reset-Case
    # unknown ownership / incomplete record / shape / reparse
    $x = Cl $recExe; $x.Ownership = 'SomethingNew'
    Blocked 'UC3-unknown-ownership-blocks' (Dec $x) 'UnsafeOrUnknown' 'unknown ownership'
    $x = Cl $recExe; $x.AfterSHA256 = ''
    Blocked 'UC3-owned-record-without-sha-blocks' (Dec $x) 'UnsafeOrUnknown' 'AfterSHA256 missing'
    $x = Cl $recExe; $x.AfterSHA256 = 'not-a-sha'
    Blocked 'UC3-owned-record-malformed-sha-blocks' (Dec $x) 'UnsafeOrUnknown' 'AfterSHA256 malformed'
    $x = Cl $recExe; $x.Destination = (Join-Path $L.Guard 'g1.txt')
    Blocked 'UC3-owned-record-not-a-denGo-leaf-blocks' (Dec $x) 'UnsafeOrUnknown' 'destination is a guard file, not a DenGo leaf'
    $x = Cl $recC5; $x.Destination = (Join-Path $L.Bve5 'Input Devices\other.dll')
    Blocked 'UC3-bve-other-dll-blocks' (Dec $x) 'UnsafeOrUnknown' 'another plug-in in Input Devices'
    $x = Cl $recExe; $x.Destination = 'relative\app.exe'
    Blocked 'UC3-relative-path-blocks' (Dec $x) 'UnsafeOrUnknown' 'relative path'
    $x = Cl $recExe; $x.Platform = 'Unheard'
    Blocked 'UC3-unsupported-platform-blocks' (Dec $x) 'UnsafeOrUnknown' 'unsupported platform'
    $x = Cl $recExe; $x.Destination = ($P.AppDir + '\..\Programs\DenGo Controller Converter\DenGoControllerConverter.exe')
    Blocked 'UC3-dotdot-blocks' (Dec $x) 'UnsafeOrUnknown' 'parent traversal'
    # reparse point on the way to a fixed leaf
    $realDir = Join-Path $L.Root 'RealInputDevices'
    [System.IO.Directory]::CreateDirectory($realDir) | Out-Null
    [System.IO.File]::Copy($P.AppExe, (Join-Path $realDir 'DenGoControllerConverter.dll'), $true)
    $bveRoot = Join-Path $L.Root 'BveJ'
    New-I2BPeStub (Join-Path $bveRoot 'BveTs.exe') 'x86'
    & cmd.exe /c ('mklink /J "' + (Join-Path $bveRoot 'Input Devices') + '" "' + $realDir + '"') | Out-Null
    $x = Cl $recC5; $x.Destination = (Join-Path $bveRoot 'Input Devices\DenGoControllerConverter.dll')
    $d = Dec $x
    Blocked 'UC3-junction-on-the-way-blocks' $d 'UnsafeOrUnknown' 'Input Devices is a junction'
    [System.IO.Directory]::Delete((Join-Path $bveRoot 'Input Devices'))
    Reset-Case
    # --- ownership value is compared case-sensitively
    $x = Cl $recExe; $x.Ownership = 'createdbyinstaller'
    Blocked 'UC3-ownership-is-case-sensitive' (Dec $x) 'UnsafeOrUnknown' 'wrong case is unknown'
    # --- root proof / volume (A. PreserveUnverified fails for owned files, B. missing is AlreadyMissing)
    [System.IO.File]::Delete((Join-Path $L.Bve5 'BveTs.exe'))
    $d = Dec $recC5
    Blocked 'UC3-owned-root-unproven-blocks' $d 'OwnedRootUnverified' 'BveTs.exe is gone but the DenGo dll remains'
    [void](Assert-I2A 'UC3-owned-root-unproven-decision' (($d.Decision -eq 'PreserveUnverified') -and ($d.Residual -eq $false)) 'decision PreserveUnverified (reported as blocking, not as a Completed residual)')
    [System.IO.File]::Delete($dll5)
    Is 'UC3-bve-exe-and-dll-gone-already-missing' (Dec $recC5) 'AlreadyMissing' 'AlreadyMissing' 'nothing there: safely absent'
    Reset-Case
    New-I2BPeStub (Join-Path $L.Bve5 'BveTs.exe') 'x64'
    Blocked 'UC3-owned-root-wrong-machine-blocks' (Dec $recC5) 'OwnedRootUnverified' 'BveTs.exe has the wrong machine type'
    Reset-Case
    $drive = Get-I2CFreeDriveLetter
    $x = Cl $recC5; $x.Destination = ($drive + ':\Bve\Input Devices\DenGoControllerConverter.dll')
    $d = Dec $x
    Blocked 'UC3-owned-volume-unavailable-blocks' $d 'OwnedRootUnverified' ('drive ' + $drive + ': is not connected')
    Reset-Case
    # --- MigratedMatchingDenGoFile
    Is 'UC3-migrated-match-remove' (Dec $recMig) 'Remove' 'Remove' 'migrated file == installed SHA'
    $d = Dec $recMig; [void](Assert-I2A 'UC3-migrated-never-restores-old-content' (($d.Op -eq 'Delete') -and ($d.UsedBackup -eq $false) -and ($d.Source -eq '')) 'Backups[] of a migrated file are history only, never a restore source')
    [System.IO.File]::WriteAllText((Get-I2CLeafPath $L 'DenGoVehicleSpec.BveEx.Bridge.dll'), 'newer dengo build', $script:Utf8)
    Is 'UC3-migrated-modified-preserved' (Dec $recMig) 'PreserveModified' 'ModifiedByUser' 'migrated file != installed SHA'
    Reset-Case
    # --- ReplacedExisting
    $d = Dec $recRep
    Is 'UC3-replaced-restore' $d 'Restore' 'RestoreOrigin' 'file == installed SHA, Origin proven'
    [void](Assert-I2A 'UC3-replaced-restore-uses-Backups0' (($d.Op -eq 'Write') -and ($d.Source -eq $recRep.Backups[0].Path) -and ($d.UsedBackup -eq $true) -and ($d.SourceSha -eq $recRep.BeforeSHA256)) "source=$($d.Source)")
    [void](Assert-I2A 'UC3-replaced-origin-content' ([System.IO.File]::ReadAllText($d.Source) -eq 'user-original-yml') 'the Origin backup holds the user''s original')
    $ymlPath = Get-I2CLeafPath $L 'Den-Go-Controller.yml'
    [System.IO.File]::WriteAllText($ymlPath, 'user edited after the install', $script:Utf8)
    Is 'UC3-replaced-modified-preserved' (Dec $recRep) 'PreserveModified' 'ModifiedByUser' 'user edited the profile after the install'
    $x = Cl $recRep; $x.Backup = (Join-Path $P.BackupRoot '20261016T000009Z-00000000\0001.bak')
    Is 'UC3-replaced-modified-with-broken-backup-still-preserved' (Dec $x) 'PreserveModified' '' 'a modified file is never restored, whatever the backup state (no stop)'
    Reset-Case
    [System.IO.File]::Delete($ymlPath)
    Is 'UC3-replaced-missing-already-missing' (Dec $recRep) 'AlreadyMissing' 'AlreadyMissing' 'D-C6: missing is not recreated and does not stop the uninstall'
    Reset-Case
    # AfterSHA == BeforeSHA -> nothing to restore
    $x = Cl $recRep; $x.BeforeSHA256 = $x.AfterSHA256
    Is 'UC3-replaced-already-original' (Dec $x) 'AlreadyOriginal' 'AlreadyOriginal' 'installed content equals the original'
    # --- Origin rule R1-R7
    $bk = [string]$recRep.Backups[0].Path
    $mut = @(
        @('R1a-existedbefore-false', { param($r) $r.ExistedBefore = $false }),
        @('R1b-before-sha-empty', { param($r) $r.BeforeSHA256 = '' }),
        @('R1c-before-sha-malformed', { param($r) $r.BeforeSHA256 = 'zz' }),
        @('R1d-backup-empty', { param($r) $r.Backup = '' }),
        @('R2a-backup-outside-backuproot', { param($r) $r.Backup = (Join-Path $L.Root 'OldBackups\x.bak') }),
        @('R2b-backup-not-a-backup-leaf', { param($r) $r.Backup = (Join-Path $P.BackupRoot 'readme.txt') }),
        @('R3a-backups-empty', { param($r) $r.Backups = [object[]]@() }),
        @('R3b-backup0-path-differs', { param($r) $r.Backups[0].Path = (Join-Path $P.BackupRoot '20261016T000009Z-00000000\0001.bak') }),
        @('R3c-backup0-sha-differs', { param($r) $r.Backups[0].SHA256 = ('11' * 32) }),
        @('R3d-backup0-txn-differs', { param($r) $r.Backups[0].TransactionId = '20261016T000009Z-00000000' }),
        @('R3e-origin-is-not-Backups0', { param($r) $first = $r.Backups[0]; $r.Backups = [object[]]@([pscustomobject]@{ TransactionId = '20261016T000009Z-00000000'; Path = (Join-Path $P.BackupRoot '20261016T000009Z-00000000\0001.bak'); SHA256 = ('22' * 32) }, $first) }),
        @('R4a-backup-file-missing', { param($r) [System.IO.File]::Delete($bk) }),
        @('R4b-backup-file-tampered', { param($r) [System.IO.File]::WriteAllText($bk, 'tampered', [System.Text.Encoding]::UTF8) }),
        @('R7-generation-mismatch', { param($r) $r | Add-Member -NotePropertyName '__lastClosed' -NotePropertyValue (([string]$r.Backups[0].TransactionId) + 'z') -Force }))
    foreach ($m in $mut) {
        Reset-Case
        $x = Cl $recRep
        & $m[1] $x
        $gen = $gen0
        if ($m[0] -eq 'R7-generation-mismatch') { $gen = [pscustomobject]@{ ContaminationSuspect = $false; LastClosedTransactionId = [string]$x.__lastClosed } }
        $d = Dec $x $true $gen
        Blocked ('UC3-origin-' + $m[0]) $d 'ReplacedExistingBackupInvalid' ('Origin rule violated => stop with zero changes')
        [void](Assert-I2A ('UC3-origin-' + $m[0] + '-decision') ($d.Decision -eq 'UnsafeOrUnknown') ('decision ' + $d.Decision))
    }
    Reset-Case
    # Backups[1..] is never an Origin: a record whose Backups[0] is the Origin plus later update backups still resolves to Backups[0]
    $x = Cl $recRep
    $extra = [pscustomobject]@{ TransactionId = '20261016T000009Z-00000009'; Path = (Join-Path $P.BackupRoot '20261016T000009Z-00000009\0001.bak'); SHA256 = ('33' * 32) }
    $x.Backups = [object[]]@($x.Backups[0], $extra)
    $d = Dec $x
    Is 'UC3-origin-ignores-later-backups' $d 'Restore' 'RestoreOrigin' 'Backups[1..] are not consulted'
    [void](Assert-I2A 'UC3-origin-source-is-backups0' ($d.Source -eq $recRep.Backups[0].Path) 'the source is Backups[0]')
    # a later update backup must never be chosen even if it is the newest / last: make Backups[0] invalid and the last one valid
    $x = Cl $recRep
    $lastGood = Join-Path $P.BackupRoot '20261016T000009Z-00000009\0001.bak'
    [System.IO.Directory]::CreateDirectory((Split-Path $lastGood)) | Out-Null
    [System.IO.File]::WriteAllText($lastGood, 'user-original-yml', $script:Utf8)
    $x.Backups = [object[]]@([pscustomobject]@{ TransactionId = $x.Backups[0].TransactionId; Path = $x.Backups[0].Path; SHA256 = ('44' * 32) }, [pscustomobject]@{ TransactionId = '20261016T000009Z-00000009'; Path = $lastGood; SHA256 = $recRep.BeforeSHA256 })
    Blocked 'UC3-origin-never-last-or-latest' (Dec $x) 'ReplacedExistingBackupInvalid' 'the last backup has the right content but is not Backups[0]: not used'
    Reset-Case
    # legacy-format Origin
    ConvertTo-I2CLegacyState $L
    $recLeg = Rec 'Den-Go-Controller.yml'
    $legGen = Get-DenGoUninstallGeneration (Read-DenGoPreviousState $P) (Read-DenGoUninstalledState $P)
    $d = Dec $recLeg $true $legGen
    Is 'UC3-origin-legacy-format-proven' $d 'Restore' 'RestoreOrigin' 'an old-format Origin (BackupRoot\yyyyMMdd-HHmmss\<32hex>.bak) with a matching SHA is a candidate when nothing is contaminated'
    [void](Assert-I2A 'UC3-origin-legacy-source' (($d.Origin.Format -eq 'Legacy') -and ($d.Source -like '*20250101-000000*')) "format=$($d.Origin.Format)")
    $x = Cl $recLeg; Set-I2CProperty $x 'Backups' ([object[]]@([pscustomobject]@{ TransactionId = 'x'; Path = $x.Backup; SHA256 = $x.BeforeSHA256 }))
    Blocked 'UC3-origin-legacy-in-Backups-confusion' (Dec $x $true $legGen) 'ReplacedExistingBackupInvalid' 'a legacy path must not appear in Backups[]'
    $genAfterClosed = [pscustomobject]@{ ContaminationSuspect = $false; LastClosedTransactionId = '20261016T000000Z-00000001' }
    Blocked 'UC3-origin-legacy-after-a-closed-generation' (Dec $recLeg $true $genAfterClosed) 'ReplacedExistingBackupInvalid' 'a legacy backup cannot belong to a generation that follows a closed one'
    Reset-Case
    # contamination: no restore, Remove only when the SHA matches
    $d = Dec $recRep $true $genC
    Blocked 'UC3-contamination-blocks-a-needed-restore' $d 'ContaminationBlocksRestore' 'ContaminationSuspect + ReplacedExisting that needs a restore'
    [void](Assert-I2A 'UC3-contamination-decision' ($d.Decision -eq 'PreserveSuspect') 'decision PreserveSuspect')
    Is 'UC3-contamination-created-match-still-removed' (Dec $recExe $true $genC) 'Remove' 'Remove' 'Created + SHA match is removable even when contaminated'
    Is 'UC3-contamination-migrated-match-still-removed' (Dec $recMig $true $genC) 'Remove' 'Remove' 'Migrated + SHA match is removable'
    [System.IO.File]::WriteAllText($P.AppExe, 'user edited', $script:Utf8)
    Is 'UC3-contamination-created-modified-preserved' (Dec $recExe $true $genC) 'PreserveModified' 'ModifiedByUser' 'SHA mismatch is preserved'
    Reset-Case
    [System.IO.File]::WriteAllText($ymlPath, 'edited', $script:Utf8)
    Is 'UC3-contamination-replaced-modified-preserved' (Dec $recRep $true $genC) 'PreserveModified' '' 'a modified file is preserved without blocking'
    Reset-Case
    $x = Cl $recRep; $x.BeforeSHA256 = $x.AfterSHA256
    Is 'UC3-contamination-already-original-needs-no-restore' (Dec $x $true $genC) 'AlreadyOriginal' '' 'no restore is needed, so contamination does not block'
    # --- PreservedUserFile / NotInstalled / NotManaged: never touched
    $note = Join-Path $L.Rpcs3Global 'Den-Go-Controller.yml'
    foreach ($own in 'PreservedUserFile', 'NotInstalled', 'NotManaged') {
        $x = Cl $recRep; $x.Ownership = $own
        $d = Dec $x
        [void](Assert-I2A ("UC3-$own-exists-preserved") (($d.Decision -in @('PreserveUserFile', 'PreserveNotOwned')) -and ($d.Op -eq '') -and ($d.Residual -eq $true) -and ($d.Blocking -eq $false)) "decision=$($d.Decision): residual, no item, not blocking")
        $x2 = Cl $x; $x2.AfterSHA256 = ('55' * 32)
        $d = Dec $x2
        [void](Assert-I2A ("UC3-$own-modified-preserved") (($d.Op -eq '') -and ($d.Blocking -eq $false) -and ($d.Residual -eq $true)) "decision=$($d.Decision)")
        [System.IO.File]::Delete($note)
        Is ("UC3-$own-missing") (Dec $x) 'AlreadyMissing' '' 'absent'
        Restore-I2ATree $L.Root $pristine
        $x4 = Cl $x; $x4.Destination = ($drive + ':\Rpcs3\config\input_configs\global\Den-Go-Controller.yml')
        $d = Dec $x4
        [void](Assert-I2A ("UC3-$own-unavailable-volume-completed-allowed") (($d.Decision -eq 'PreserveUnverified') -and ($d.Blocking -eq $false) -and ($d.Residual -eq $true)) "user-owned on an unavailable volume: preserved, not blocking")
        $x5 = Cl $x; $x5.Destination = (Join-Path $L.Guard 'g1.txt'); $x5.Platform = 'RPCS3'
        $d = Dec $x5
        [void](Assert-I2A ("UC3-$own-bad-shape-reported-only") (($d.Decision -eq 'PreserveNotOwned') -and ($d.ReasonCode -eq 'ShapeNotVerified') -and ($d.Blocking -eq $false) -and ($d.Op -eq '')) "a record that is not a DenGo leaf is never touched and does not stop an uninstall: $($d.ReasonCode)")
    }
    # --- profiles
    $x = Cl $recRep
    Is 'UC3-input-profile-kept-by-default' (Dec $x $false) 'KeepProfile' 'ProfileKept' 'InputProfile without -IncludeInputProfiles'
    $x = Cl $recRep; $x.Backup = ''
    $d = Dec $x $false
    [void](Assert-I2A 'UC3-input-profile-kept-even-with-a-broken-origin' (($d.Decision -eq 'KeepProfile') -and ($d.Blocking -eq $false) -and ($d.Residual -eq $true) -and ($d.Op -eq '')) 'P-1: a kept profile has no restore duty, so a broken Origin does not stop the uninstall')
    $x = Cl $recRep; $x.Component = 'EffectiveInputProfile'; $x.Backup = ''
    $d = Dec $x $false
    [void](Assert-I2A 'UC3-effective-profile-kept-by-default-no-stop' (($d.Decision -eq 'KeepProfile') -and ($d.Blocking -eq $false)) 'P-1: EffectiveInputProfile that is only kept never stops the uninstall')
    $d = Dec $x $true
    Blocked 'UC3-effective-profile-explicit-restore-needs-origin' $d 'ReplacedExistingBackupInvalid' 'P-1/D-C5: explicitly in the restore scope (-IncludeInputProfiles) and the Origin rule fails'
    $x = Cl $recRep; $x.Component = 'EffectiveInputProfile'
    Is 'UC3-effective-profile-explicit-restore-proven' (Dec $x $true) 'Restore' 'RestoreOrigin' 'explicit restore with a proven Origin'
    $x = Cl $recExe; $x.Platform = 'RPCS3'; $x.Component = 'EffectiveInputProfile'; $x.Destination = $ymlPath; $x.AfterSHA256 = (Get-I2AFileSha $ymlPath)
    $d = Dec $x $true
    [void](Assert-I2A 'UC3-effective-profile-never-removed' (($d.Op -eq '') -and ($d.Decision -eq 'PreserveModified') -and ($d.ReasonCode -eq 'EffectiveProfileNeverRemoved')) "decision=$($d.Decision)/$($d.ReasonCode)")
    $x = Cl $recRep; $x.Component = 'EffectiveInputProfile'; [System.IO.File]::WriteAllText($ymlPath, 'edited', $script:Utf8)
    Is 'UC3-effective-profile-modified-is-user-change' (Dec $x $true) 'PreserveModified' '' 'a changed effective profile is a user change'
    Reset-Case
    # --- PCSX2 / LilyPad: deferred, never read
    foreach ($case in @(@('pcsx2-lily', 'InputProfile'), @('pcsx2-effective', 'EffectiveInputProfile'))) {
        $x = New-I2CRecord 'PCSX2' $case[1] (Join-Path $L.Pcsx2Inis 'LilyPad.ini') 'ReplacedExisting' ('66' * 32) ('77' * 32) (Join-Path $P.BackupRoot 'nope\0001.bak') $true
        $d = Dec $x $true
        [void](Assert-I2A ('UC3-' + $case[0] + '-deferred') (($d.Decision -eq 'Deferred') -and ($d.Op -eq '') -and ($d.Blocking -eq $false) -and ($d.Origin -eq $null) -and ($d.CurrentSha -eq '')) "deferred: no SHA measured, no Origin, no item")
    }
    $x = New-I2CRecord 'PCSX2' 'InputProfile' (Join-Path $L.Pcsx2Inis 'DenGo-Controller-Converter.lily') 'SomethingUnknown' 'garbage'
    Is 'UC3-pcsx2-deferred-even-with-garbage' (Dec $x $true) 'Deferred' 'DeferredToI3' 'a PCSX2 record is deferred before any other check'

    # =================================================== UC4 shortcuts
    $stateNow = Get-I2CIs $L
    $sc = Cl $stateNow.Shortcut
    [void](Assert-I2A 'UC4-fixture-shortcut-record' (($sc.Created -eq $true) -and ($sc.PreExisted -eq $false) -and ($null -ne $sc.Facts) -and ([System.IO.File]::Exists($sc.Path))) "created=$($sc.Created) preExisted=$($sc.PreExisted) path=$($sc.Path)")
    function ScDec($Rec, [scriptblock]$Reader = $null, $Gen = $null) {
        if ($null -eq $Gen) { $Gen = $gen0 }
        if ($null -eq $Reader) { $Reader = { param($sp) DgPFs-ReadShortcut $sp } }
        return (Get-DenGoUninstallShortcutDecision $P $Rec $Gen 'Current' $Reader)
    }
    $d = ScDec $sc
    Is 'UC4-A-created-unedited-remove' $d 'Remove' 'Remove' 'Created + not pre-existing + Facts equal'
    [void](Assert-I2A 'UC4-A-is-a-delete-item' (($d.Op -eq 'Delete') -and ($d.Role -eq 'Shortcut')) 'Delete item')
    $edited = { param($sp) [pscustomobject]@{ TargetPath = 'C:\Other\thing.exe'; WorkingDirectory = $P.AppDir; IconLocation = ($P.AppIco + ',0') } }
    $d = ScDec $sc $edited
    Is 'UC4-C-user-edited-diverged' $d 'Diverged' 'ShortcutEdited' 'Facts differ'
    [void](Assert-I2A 'UC4-C-diverged-never-touched' (($d.Op -eq '') -and ($d.Residual -eq $true) -and ($d.Blocking -eq $false) -and ($d.ReviewRecommended -eq $true)) 'no item, residual, Completed allowed')
    $unreadable = { param($sp) throw 'cannot read' }
    $d = ScDec $sc $unreadable
    Is 'UC4-unreadable-shortcut-left-as-it-is' $d 'Diverged' 'ShortcutUnreadable' 'an unreadable lnk is not touched'
    $x = Cl $sc; $x.Created = $false
    $dd = Get-DenGoUninstallShortcutDecisions $P (Cl $stateNow | ForEach-Object { $_.Shortcut = $x; $_ }) $gen0 { param($sp) DgPFs-ReadShortcut $sp }
    [void](Assert-I2A 'UC4-D-not-created-no-decision' (@($dd).Count -eq 0) 'Created=false: the shortcut is not ours; the old "default Desktop shortcut that points at the app" deletion is gone')
    # not created by the record but a matching shortcut exists on the default Desktop: never touched (no decision, no item)
    $x = Cl $sc; $x.Path = ''
    $dd = Get-DenGoUninstallShortcutDecisions $P (Cl $stateNow | ForEach-Object { $_.Shortcut = $x; $_ }) $gen0 { param($sp) DgPFs-ReadShortcut $sp }
    [void](Assert-I2A 'UC4-D-empty-path-no-decision' (@($dd).Count -eq 0) 'no recorded path: nothing is deleted')
    $x = Cl $sc; $x.Path = (Join-Path $L.Desktop 'Other.lnk')
    $d = ScDec $x
    Blocked 'UC4-wrong-leaf-blocks' $d 'UnsafeOrUnknown' 'shortcut leaf is not the fixed name'
    # missing shortcut / unavailable volume
    $keep = Get-I2AFileSha $P.ShortcutPath
    [System.IO.File]::Delete($P.ShortcutPath)
    Is 'UC4-missing-already-missing' (ScDec $sc) 'AlreadyMissing' 'AlreadyMissing' 'the shortcut is gone'
    Reset-Case
    $x = Cl $sc; $x.Path = ($drive + ':\Users\Public\Desktop\DenGo Controller Converter.lnk')
    Blocked 'UC4-owned-volume-unavailable-blocks' (ScDec $x) 'OwnedRootUnverified' 'drive not connected'
    # B. pre-existing shortcut replaced by DenGo: restore from the Origin backup
    $origLnk = Join-Path $L.Root 'OriginalShortcut.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $o = $shell.CreateShortcut($origLnk); $o.TargetPath = (Join-Path $L.Root 'UserTool.exe'); $o.WorkingDirectory = $L.Root; $o.Save()
    $bkDir = Join-Path $P.BackupRoot '20261016T000010Z-00000010'
    [System.IO.Directory]::CreateDirectory($bkDir) | Out-Null
    $bkLnk = Join-Path $bkDir '0000.bak'
    [System.IO.File]::Copy($origLnk, $bkLnk, $true)
    $bkSha = Get-I2AFileSha $bkLnk
    $b = Cl $sc; $b.PreExisted = $true; $b.Backup = $bkLnk; $b.BackupSHA256 = $bkSha
    $b | Add-Member -NotePropertyName Backups -NotePropertyValue ([object[]]@([pscustomobject]@{ TransactionId = '20261016T000010Z-00000010'; Path = $bkLnk; SHA256 = $bkSha })) -Force
    $d = ScDec $b
    Is 'UC4-B-preexisting-replaced-restore' $d 'Restore' 'RestoreOrigin' 'PreExisted + valid Origin + Facts equal'
    [void](Assert-I2A 'UC4-B-write-item-from-origin' (($d.Op -eq 'Write') -and ($d.Source -eq $bkLnk) -and ($d.UsedBackup -eq $true)) 'a Write item whose source is the Origin backup')
    # F. backup missing / SHA mismatch / not Backups[0] -> restore needed but unprovable -> stop
    foreach ($case in @(
            @('F-backup-missing', { param($r) [System.IO.File]::Delete($r.Backup) }),
            @('F-sha-mismatch', { param($r) $r.BackupSHA256 = ('88' * 32) }),
            @('F-not-backups0', { param($r) $r.Backups = [object[]]@() }),
            @('F-backup-path-outside', { param($r) $r.Backup = (Join-Path $L.Root 'elsewhere.lnk') }))) {
        $x = Cl $b
        if ($case[0] -eq 'F-backup-missing') { $keepBk = [System.IO.File]::ReadAllBytes($bkLnk) }
        & $case[1] $x
        $d = ScDec $x
        Blocked ('UC4-' + $case[0] + '-blocks') $d 'ShortcutBackupInvalid' 'a needed restore that cannot be proven is never guessed'
        if ($case[0] -eq 'F-backup-missing') { [System.IO.File]::WriteAllBytes($bkLnk, $keepBk) }
    }
    $x = Cl $b
    $dEdited = ScDec $x $edited
    Is 'UC4-F-edited-shortcut-needs-no-restore-even-with-broken-backup' (ScDec (Cl $b | ForEach-Object { $_.BackupSHA256 = ('99' * 32); $_ }) $edited) 'Diverged' '' 'a user-edited shortcut is Diverged whatever the backup state'
    $x = Cl $b; $x.Backup = ''; $x.BackupSHA256 = ''
    $d = ScDec $x
    [void](Assert-I2A 'UC4-preexisted-unchanged-left-alone' (($d.Decision -eq 'PreserveUserFile') -and ($d.Op -eq '') -and ($d.Blocking -eq $false)) 'PreExisted with no backup: the shortcut already had this content; it is the user''s')
    Blocked 'UC4-contamination-blocks-a-needed-shortcut-restore' (ScDec $b $null $genC) 'ContaminationBlocksRestore' 'no PreExisted shortcut restore when contaminated'
    Is 'UC4-contamination-created-shortcut-still-removed' (ScDec $sc $null $genC) 'Remove' 'Remove' 'Created + Facts equal is removable'
    # old-format record (no Facts)
    $leg = Cl $sc; Remove-I2CProperty $leg 'Facts'; Remove-I2CProperty $leg 'PreExisted'
    Is 'UC4-old-format-points-at-the-app-remove' (ScDec $leg) 'Remove' 'Remove' 'old record without Facts: target == app exe'
    Is 'UC4-old-format-other-target-left-alone' (ScDec $leg { param($sp) [pscustomobject]@{ TargetPath = 'C:\Other\thing.exe'; WorkingDirectory = ''; IconLocation = '' } }) 'Diverged' 'ShortcutNotRecognized' 'old record whose target is not the app: not proven to be ours'
    # E. Earlier[]: evaluated like the current record, never ignored; duplicates are not applied twice
    $other = Join-Path $L.Root 'DesktopOld'
    [System.IO.Directory]::CreateDirectory($other) | Out-Null
    $oldLnk = Join-Path $other 'DenGo Controller Converter.lnk'
    [System.IO.File]::Copy($P.ShortcutPath, $oldLnk, $true)
    $earlier = Cl $sc; $earlier.Path = $oldLnk
    $st = Cl $stateNow
    Set-I2CProperty $st.Shortcut 'Earlier' ([object[]]@($earlier))
    $dd = Get-DenGoUninstallShortcutDecisions $P $st $gen0 { param($sp) DgPFs-ReadShortcut $sp }
    [void](Assert-I2A 'UC4-E-earlier-is-evaluated' ((@($dd).Count -eq 2) -and ($dd[0].Component -eq 'Current') -and ($dd[1].Component -eq 'Earlier') -and ($dd[1].Decision -eq 'Remove') -and ($dd[1].Destination -eq $oldLnk)) "decisions: $(@($dd | ForEach-Object { $_.Component + ':' + $_.Decision }) -join ',')")
    $dd2 = Get-DenGoUninstallShortcutDecisions $P $st $gen0 { param($sp) [pscustomobject]@{ TargetPath = 'C:\Other\thing.exe'; WorkingDirectory = ''; IconLocation = '' } }
    [void](Assert-I2A 'UC4-E-earlier-edited-is-diverged-not-deleted' ((@($dd2 | Where-Object { $_.Decision -eq 'Diverged' }).Count -eq 2) -and (@($dd2 | Where-Object { $_.Op.Length -gt 0 }).Count -eq 0)) 'both edited: nothing deleted')
    $earlier2 = Cl $sc
    Set-I2CProperty $st.Shortcut 'Earlier' ([object[]]@($earlier2))
    $dd3 = Get-DenGoUninstallShortcutDecisions $P $st $gen0 { param($sp) DgPFs-ReadShortcut $sp }
    [void](Assert-I2A 'UC4-E-same-path-twice-applied-once' ((@($dd3).Count -eq 2) -and ($dd3[1].Decision -eq 'SupersededByCurrent') -and (@($dd3 | Where-Object { $_.Op.Length -gt 0 }).Count -eq 1)) 'the same path in Earlier[] is not planned twice')
    $earlier4 = Cl $sc; $earlier4.Path = ($drive + ':\Users\Public\Desktop\DenGo Controller Converter.lnk')
    Set-I2CProperty $st.Shortcut 'Earlier' ([object[]]@($earlier4))
    $dd4 = Get-DenGoUninstallShortcutDecisions $P $st $gen0 { param($sp) DgPFs-ReadShortcut $sp }
    [void](Assert-I2A 'UC4-E-earlier-on-an-unavailable-volume-blocks' ((@($dd4 | Where-Object { $_.Blocking -and $_.BlockCode -eq 'OwnedRootUnverified' }).Count -eq 1) -and ($dd4[0].Decision -eq 'Remove')) 'a DenGo-created shortcut on an unplugged drive is not forgotten')
    Reset-Case

    # =================================================== UC5 generation / contamination
    $prev = Read-DenGoPreviousState $P
    $usNone = Read-DenGoUninstalledState $P
    $g1 = Get-DenGoUninstallGeneration $prev $usNone
    [void](Assert-I2A 'UC5-clean-generation' (($g1.ContaminationSuspect -eq $false) -and ($g1.LegacyFormat -eq $false) -and ($g1.GenerationId -eq $prev.Sha.ToLowerInvariant()) -and ($g1.StateRevision -eq 2) -and ($g1.LastInstallTransactionId -eq (Get-I2CIs $L).TransactionId)) "GenerationId == lower-case SHA-256 of installed-state.json")
    Write-I2CLegacyUninstalledState $L
    $usLeg = Read-DenGoUninstalledState $P
    $g2 = Get-DenGoUninstallGeneration $prev $usLeg
    [void](Assert-I2A 'UC5-B-i2b-state-with-legacy-uninstalled-state-is-suspect' (($g2.ContaminationSuspect -eq $true) -and ($g2.LegacyFormat -eq $false) -and ($g2.UninstalledLegacy -eq $true) -and (@($g2.ContaminationReasons).Count -eq 1)) "P-2 (2): I2-B installed-state + legacy uninstalled-state => $($g2.ContaminationReasons -join ';')")
    ConvertTo-I2CLegacyState $L
    $prevLeg = Read-DenGoPreviousState $P
    $g3 = Get-DenGoUninstallGeneration $prevLeg $usLeg
    [void](Assert-I2A 'UC5-A-legacy-with-legacy-is-suspect' (($g3.ContaminationSuspect -eq $true) -and ($g3.LegacyFormat -eq $true) -and ($g3.UninstalledLegacy -eq $true)) "P-2 (1): $($g3.ContaminationReasons -join ';')")
    $g4 = Get-DenGoUninstallGeneration $prevLeg $usNone
    [void](Assert-I2A 'UC5-legacy-state-alone-is-not-suspect' (($g4.ContaminationSuspect -eq $false) -and ($g4.LegacyFormat -eq $true)) 'a legacy installed-state with no uninstalled-state is a fresh legacy generation')
    [System.IO.File]::Delete((Get-I2CUsPath $L))
    Reset-Case
    # a corrupt uninstalled-state counts as legacy (conservative)
    [System.IO.File]::WriteAllText((Get-I2CUsPath $L), '{ not json', $script:Utf8)
    $usBad = Read-DenGoUninstalledState $P
    $g5 = Get-DenGoUninstallGeneration $prev $usBad
    [void](Assert-I2A 'UC5-corrupt-uninstalled-state-is-suspect' (($usBad.Valid -eq $false) -and ($g5.ContaminationSuspect -eq $true)) 'an unreadable uninstalled-state next to an installed-state is suspect')
    Reset-Case

    # =================================================== UC6 archive plan and items
    $us0 = Read-DenGoUninstalledState $P
    $plan = Get-DenGoUninstallPlan $P $prev $us0 (Get-I2COptions $true)
    [void](Assert-I2A 'UC6-plan-clean' ((@($plan.Blocking).Count -eq 0) -and ($plan.ArchiveCollision -eq '') -and ($plan.Generation.ContaminationSuspect -eq $false)) 'no blocking item in the clean fixture')
    $isName = 'installed-state.' + $prev.Sha.ToLowerInvariant() + '.json'
    [void](Assert-I2A 'UC6-archive-name-is-content-addressed' (($plan.Archive.IS.Name -ceq $isName) -and ($plan.Archive.IS.Path -eq (Join-Path $P.StateRoot ('history\' + $isName))) -and ($plan.Archive.US -eq $null) -and ($plan.Archive.IS.Skip -eq $false)) "name=$($plan.Archive.IS.Name)")
    $built = Convert-DenGoUninstallPlanToItems $P $plan $true
    $ops = @($built.Items | ForEach-Object { $_.Op + ':' + (Split-Path $_.Destination -Leaf) })
    [void](Assert-I2A 'UC6-items-end-with-archive-then-delete-of-installed-state' ((@($built.Items).Count -eq @($built.Metas).Count) -and ($ops[-1] -eq 'Delete:installed-state.json') -and ($ops[-2] -eq ('Write:' + $isName))) ('last items: ' + ($ops[-2..-1] -join ' | ')))
    $firstKinds = @($built.Metas | Select-Object -First 1 | ForEach-Object { $_.Kind })
    [void](Assert-I2A 'UC6-shortcut-first-core-last-among-product-items' (($firstKinds[0] -eq 'Shortcut') -and (@($built.Metas | Where-Object { $_.Kind -eq 'File' } | Select-Object -Last 1 | ForEach-Object { $_.Decision.Platform })[0] -eq 'Core')) 'Install order reversed: shortcut first, Core last')
    $order = @($built.Metas | Where-Object { $_.Kind -eq 'File' } | ForEach-Object { $_.Decision.Platform })
    $sets = @(); foreach ($o in $order) { if ($sets.Count -eq 0 -or $sets[-1] -ne $o) { $sets += $o } }
    [void](Assert-I2A 'UC6-set-order-is-the-reverse-of-install' (([string]::Join(',', $sets)) -eq 'RPCS3,AtsEX Legacy,BveEX Current,BVE6,BVE5,Core') ('sets: ' + [string]::Join(',', $sets)))
    [void](Assert-I2A 'UC6-no-item-for-classes-that-are-not-touched' (@($built.Metas | Where-Object { $_.Kind -eq 'File' -and $_.Decision.Decision -notin @('Remove', 'Restore') }).Count -eq 0) 'only Remove / Restore decisions become items')
    # collision
    [System.IO.Directory]::CreateDirectory((Join-Path $P.StateRoot 'history')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot ('history\' + $isName)), 'a different file', $script:Utf8)
    $planC = Get-DenGoUninstallPlan $P $prev $us0 (Get-I2COptions $true)
    [void](Assert-I2A 'UC6-archive-collision-detected' (($planC.ArchiveCollision -ne '') -and ((Get-DenGoUninstallBlockingCode $planC) -eq 'HistoryArchiveCollision')) "collision=[$($planC.ArchiveCollision)]")
    [System.IO.File]::Copy($P.StatePath, (Join-Path $P.StateRoot ('history\' + $isName)), $true)
    $planS = Get-DenGoUninstallPlan $P $prev $us0 (Get-I2COptions $true)
    $builtS = Convert-DenGoUninstallPlanToItems $P $planS $true
    [void](Assert-I2A 'UC6-identical-archive-is-reused-not-rewritten' (($planS.Archive.IS.Skip -eq $true) -and ($planS.ArchiveCollision -eq '') -and (@($builtS.Items | Where-Object { $_.OwnershipCandidate -eq 'ArchiveInstalledState' }).Count -eq 0) -and (@($builtS.Items | Where-Object { $_.OwnershipCandidate -eq 'RemoveInstalledState' }).Count -eq 1)) 'same name + same SHA: no second copy, the delete still happens')
    Reset-Case
    # code ranking
    $fake = [pscustomobject]@{ Blocking = @([pscustomobject]@{ BlockCode = 'OwnedRootUnverified' }, [pscustomobject]@{ BlockCode = 'ReplacedExistingBackupInvalid' }, [pscustomobject]@{ BlockCode = 'UnsafeOrUnknown' }); ArchiveCollision = '' }
    [void](Assert-I2A 'UC6-blocking-code-ranking' ((Get-DenGoUninstallBlockingCode $fake) -eq 'UnsafeOrUnknown') 'the most specific safety code wins')
    $fake.Blocking = @([pscustomobject]@{ BlockCode = 'OwnedRootUnverified' }, [pscustomobject]@{ BlockCode = 'ReplacedExistingBackupInvalid' })
    [void](Assert-I2A 'UC6-blocking-code-ranking-2' ((Get-DenGoUninstallBlockingCode $fake) -eq 'ReplacedExistingBackupInvalid') 'backup beats root')

    # =================================================== UC7 uninstalled-state builder (pure)
    $ctxFake = @{ TxnId = '20261016T000020Z-00000020'; BackupTxnDir = (Join-Path $P.BackupRoot '20261016T000020Z-00000020'); Items = @(@{ Backup = (Join-Path $P.BackupRoot '20261016T000020Z-00000020\0000.bak'); PreSha = ('aa' * 32); Norm = $P.AppExe }) }
    $now = '2026-10-16T12:00:00.0000000+09:00'
    $state = New-DenGoUninstalledState $plan $prev $us0 $ctxFake $now $P
    $json = ConvertTo-Json -InputObject $state -Depth 9
    $back = $json | ConvertFrom-Json
    [void](Assert-I2A 'UC7-gui-required-fields' (([int]$back.SchemaVersion -eq 1) -and ($back.State -ceq 'Uninstalled') -and ([System.DateTimeOffset]::Parse([string]$back.UninstalledAt, [System.Globalization.CultureInfo]::InvariantCulture) -eq [System.DateTimeOffset]::Parse($now, [System.Globalization.CultureInfo]::InvariantCulture))) 'SchemaVersion 1, State, UninstalledAt as the GUI check requires')
    [void](Assert-I2A 'UC7-new-format-markers' (([int]$back.StateRevision -eq 2) -and ($back.UninstallTransactionId -eq $ctxFake.TxnId) -and ($back.Reconfirmation.Reconfirmed -eq $false) -and ($back.RollbackRoot -eq $ctxFake.BackupTxnDir)) 'StateRevision 2, UninstallTransactionId, RollbackRoot (legacy name)')
    $cg = $back.ClosedGeneration
    [void](Assert-I2A 'UC7-closed-generation' (($cg.GenerationId -ceq $prev.Sha.ToLowerInvariant()) -and ($cg.InstalledStateSha256 -ceq $cg.GenerationId) -and ($cg.ArchivedStateSha256 -ceq $cg.GenerationId) -and ($cg.ArchivedStatePath -eq $plan.Archive.IS.Path) -and ($cg.LastInstallTransactionId -eq (Get-I2CIs $L).TransactionId) -and ([int]$cg.StateRevision -eq 2) -and ($cg.LegacyFormat -eq $false) -and ($cg.ContaminationSuspect -eq $false) -and ([string]$cg.InstalledAt -eq [string](Get-I2CIs $L).InstalledAt)) 'state SHA, history path, history SHA, InstalledAt, LastInstallTransactionId, StateRevision')
    [void](Assert-I2A 'UC7-counts-and-lists' (($back.Counts.Removed -ge 8) -and ($back.Counts.Restored -eq 1) -and (@($back.Items).Count -eq @($plan.FileDecisions).Count) -and (@($back.UsedBackups).Count -eq 1) -and ($back.UsedBackups[0].Purpose -eq 'RestoreOrigin') -and (@($back.UninstallBackups).Count -eq 1)) "Removed=$($back.Counts.Removed) Restored=$($back.Counts.Restored)")
    [void](Assert-I2A 'UC7-unused-backups-recorded' (@($back.UnusedBackups | Where-Object { $_.Reason -eq 'NotOrigin' }).Count -ge 1) 'the migrated bridge''s update backup is listed as unused')
    [void](Assert-I2A 'UC7-clean-run-has-no-manual-check' (($back.ManualCheckRequired -eq $false) -and (@($back.ResidualFiles).Count -eq 0)) 'no residual, no manual check')
    [void](Assert-I2A 'UC7-closed-records-carried-as-history' (@($back.ClosedRecords).Count -eq @((DgU-AsList (DgProp (Get-I2CIs $L) 'ClosedRecords' @()))).Count) 'ClosedRecords are copied, not applied')
    [void](Assert-I2A 'UC7-directories-are-reported-not-removed' (@($back.ResidualDirectories).Count -ge 1) 'folders are left and listed')
    # residual + manual flags from a plan with preserved records
    $x1 = Cl $recExe; $x1.AfterSHA256 = ('ab' * 32)
    $stM = Cl (Get-I2CIs $L); $stM.Files = [object[]]@($x1, (Cl $recRep))
    $prevM = [pscustomobject]@{ Exists = $true; Sha = $prev.Sha; State = $stM; Files = [object[]]@($stM.Files) }
    $planM = Get-DenGoUninstallPlan $P $prevM $us0 (Get-I2COptions $false)
    $stateM = New-DenGoUninstalledState $planM $prevM $us0 $ctxFake $now $P
    [void](Assert-I2A 'UC7-residuals-are-recorded-with-reasons' ((@($stateM.ResidualFiles).Count -eq 2) -and (@($stateM.ResidualFiles | Where-Object { $_.Disposition -eq 'PreserveModified' -and $_.ReviewRecommended }).Count -eq 1) -and (@($stateM.ResidualFiles | Where-Object { $_.Disposition -eq 'KeepProfile' }).Count -eq 1)) "residuals: $(@($stateM.ResidualFiles | ForEach-Object { $_.Disposition }) -join ',')")
    [void](Assert-I2A 'UC7-manual-check-follows-review-recommended' (($stateM.ManualCheckRequired -eq $true) -and (@($stateM.ManualCheckReasons) -contains 'ResidualFilesNeedReview') -and ($stateM.Counts.Diverged -eq 1) -and ($stateM.Counts.Preserved -eq 2)) 'a changed DenGo file is a residual that suggests a review; Completed is unaffected')
    $stateK = New-DenGoUninstalledState (Get-DenGoUninstallPlan $P ([pscustomobject]@{ Exists = $true; Sha = $prev.Sha; State = (Cl (Get-I2CIs $L) | ForEach-Object { $_.Files = [object[]]@((Cl $recRep)); $_ }); Files = [object[]]@((Cl $recRep)) }) $us0 (Get-I2COptions $false)) $prev $us0 $ctxFake $now $P
    [void](Assert-I2A 'UC7-kept-profile-alone-needs-no-manual-check' (($stateK.ManualCheckRequired -eq $false) -and (@($stateK.ResidualFiles).Count -eq 1)) 'an intentionally kept profile is a residual (GUI notice) but not a manual check')
    # contamination fields
    $planG = [pscustomobject]@{ Generation = $g2; FileDecisions = $plan.FileDecisions; ShortcutDecisions = $plan.ShortcutDecisions; Archive = $plan.Archive; Blocking = @(); ArchiveCollision = ''; DeferredRecords = @(); IncludeInputProfiles = $true; ProductVersion = '2.0.0' }
    $stateG = New-DenGoUninstalledState $planG $prev $us0 $ctxFake $now $P
    [void](Assert-I2A 'UC7-contamination-evidence-recorded' (($stateG.ClosedGeneration.ContaminationSuspect -eq $true) -and (@($stateG.ClosedGeneration.ContaminationReasons).Count -eq 1) -and ($stateG.ManualCheckRequired -eq $true) -and (@($stateG.ManualCheckReasons) -contains 'ContaminationSuspect')) 'the grounds for the suspicion are recorded')
    # deferred records
    $stP = Cl (Get-I2CIs $L); $pcsx = New-I2CRecord 'PCSX2' 'InputProfile' (Join-Path $L.Pcsx2Inis 'DenGo-Controller-Converter.lily') 'ReplacedExisting' ('66' * 32) ('77' * 32) '' $true
    $stP.Files = [object[]]@($pcsx)
    $prevP = [pscustomobject]@{ Exists = $true; Sha = $prev.Sha; State = $stP; Files = [object[]]@($pcsx) }
    $planP = Get-DenGoUninstallPlan $P $prevP $us0 (Get-I2COptions $true)
    $stateP = New-DenGoUninstalledState $planP $prevP $us0 $ctxFake $now $P
    [void](Assert-I2A 'UC7-deferred-records-kept-for-i3' ((@($stateP.DeferredRecords).Count -eq 1) -and ($stateP.DeferredRecords[0].Reason -eq 'DeferredToI3') -and ($stateP.DeferredRecords[0].Record.Platform -eq 'PCSX2') -and ($stateP.Counts.Deferred -eq 1) -and (@($stateP.ClosedRecords).Count -eq 0) -and (@($stateP.ResidualFiles | Where-Object { $_.Disposition -eq 'Deferred' }).Count -eq 1)) 'verbatim record, not in ClosedRecords, counted, listed as residual')
    [void](Assert-I2A 'UC7-deferred-records-never-block' ((@($planP.Blocking).Count -eq 0)) 'a PCSX2 record alone does not fail the uninstall')

    # =================================================== UC8 AlreadyUninstalled
    $r = Invoke-I2CUninstall $L
    [void](Assert-I2A 'UC8-fixture-uninstalled' ($r.Succeeded -eq $true) "uninstall: succeeded=$($r.Succeeded) code=$($r.ErrorCode) msg=$($r.ErrorMessage)")
    $afterTree = Save-I2ATree $L.Root
    function Chk() { $pv = Read-DenGoPreviousState $P; $uv = Read-DenGoUninstalledState $P; return (Test-DenGoAlreadyUninstalled $P $pv $uv) }
    $c = Chk
    [void](Assert-I2A 'UC8-all-conditions-met' ($c.Ok -eq $true) "ok=$($c.Ok) code=$($c.Code) reason=$($c.Reason)")
    $usOrig = [System.IO.File]::ReadAllBytes((Get-I2CUsPath $L))
    function Restore-AfterTree { Restore-I2ATree $L.Root $afterTree }
    $neg = @(
        @('installed-state-exists', { Copy-Item (Join-Path $P.StateRoot ('history\' + (Split-Path ((Get-I2CUs $L).ClosedGeneration.ArchivedStatePath) -Leaf))) $P.StatePath }, 'AlreadyUninstalledNotApplicable'),
        @('no-uninstalled-state', { [System.IO.File]::Delete((Get-I2CUsPath $L)) }, 'NotInstalled'),
        @('uninstalling-marker', { [System.IO.File]::WriteAllText((Get-I2CUmPath $L), '{"TxnId":"x"}', $script:Utf8) }, 'UninstalledStateNotReconfirmable'),
        @('installing-marker', { [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'installing.json'), '{"TxnId":"x"}', $script:Utf8) }, 'UninstalledStateNotReconfirmable'),
        @('corrupt-uninstalled-state', { [System.IO.File]::WriteAllText((Get-I2CUsPath $L), '{ nope', $script:Utf8) }, 'UninstalledStateNotReconfirmable'),
        @('state-field-wrong', { $o = Get-I2CUs $L; $o.State = 'Installed'; Write-I2CJson (Get-I2CUsPath $L) $o }, 'UninstalledStateNotReconfirmable'),
        @('schema-wrong', { $o = Get-I2CUs $L; $o.SchemaVersion = 2; Write-I2CJson (Get-I2CUsPath $L) $o }, 'UninstalledStateNotReconfirmable'),
        @('uninstalledat-invalid', { $o = Get-I2CUs $L; $o.UninstalledAt = 'yesterday-ish'; Write-I2CJson (Get-I2CUsPath $L) $o }, 'UninstalledStateNotReconfirmable'),
        @('legacy-format', { Write-I2CLegacyUninstalledState $L }, 'UninstalledStateNotReconfirmable'),
        @('no-closed-generation', { $o = Get-I2CUs $L; Remove-I2CProperty $o 'ClosedGeneration'; Write-I2CJson (Get-I2CUsPath $L) $o }, 'UninstalledStateNotReconfirmable'),
        @('revision-1', { $o = Get-I2CUs $L; $o.StateRevision = 1; Write-I2CJson (Get-I2CUsPath $L) $o }, 'UninstalledStateNotReconfirmable'),
        @('archive-missing', { [System.IO.File]::Delete((Get-I2CUs $L).ClosedGeneration.ArchivedStatePath) }, 'UninstalledStateNotReconfirmable'),
        @('archive-sha-mismatch', { [System.IO.File]::WriteAllText((Get-I2CUs $L).ClosedGeneration.ArchivedStatePath, 'tampered', $script:Utf8) }, 'UninstalledStateNotReconfirmable'),
        @('archive-path-elsewhere', { $o = Get-I2CUs $L; $o.ClosedGeneration.ArchivedStatePath = (Join-Path $L.Guard 'g1.txt'); Write-I2CJson (Get-I2CUsPath $L) $o }, 'UninstalledStateNotReconfirmable'),
        @('unfinished-journal', { [void](New-I2CForgedActiveJournal $L) }, 'UninstalledStateNotReconfirmable'))
    foreach ($n in $neg) {
        Restore-AfterTree
        & $n[1]
        $c = Chk
        [void](Assert-I2A ('UC8-not-reconfirmable-' + $n[0]) (($c.Ok -eq $false) -and ($c.Code -eq $n[2])) "ok=$($c.Ok) code=$($c.Code) reason=[$($c.Reason)]")
    }
    Restore-AfterTree

    # =================================================== UC9 recovery gate (read-only decisions)
    function Gate([string]$Mode = 'Apply') { return (Get-DenGoUninstallRecoveryGate $P $Mode) }
    Restore-AfterTree
    $g = Gate; [void](Assert-I2A 'UC9-no-marker-proceeds' (($g.Proceed -eq $true) -and ($g.Outcome -eq 'NotNeeded')) "outcome=$($g.Outcome)")
    $g = Gate 'DryRun'; [void](Assert-I2A 'UC9-dryrun-no-marker-proceeds' (($g.Proceed -eq $true) -and ($g.Outcome -eq 'NotNeeded')) "outcome=$($g.Outcome)")
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'installing.json'), '{"State":"Installing","TxnId":"20261016T000040Z-00000040","Operation":"Install"}', $script:Utf8)
    $before = Get-I2CTree $L
    $g = Gate
    [void](Assert-I2A 'UC9-D-C2-foreign-marker-refused' (($g.Proceed -eq $false) -and ($g.ErrorCode -eq 'RecoveryRequired') -and ((@($g.Reasons | ForEach-Object { $_.Code }) -contains 'ForeignOperationMarker')) -and ($g.ManualCheckRequired -eq $true) -and ($g.Outcome -eq 'RepairRequired')) "code=$($g.ErrorCode) reasons=$(@($g.Reasons | ForEach-Object { $_.Code }) -join ',')")
    [void](Assert-I2A 'UC9-D-C2-foreign-marker-untouched' ((Test-I2CNoChange $L $before) -and [System.IO.File]::Exists((Join-Path $P.StateRoot 'installing.json'))) 'the install marker is neither recovered, deleted nor converted; nothing else changed')
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'uninstalling.json'), '{"TxnId":"20261016T000041Z-00000041"}', $script:Utf8)
    $g = Gate; [void](Assert-I2A 'UC9-multiple-markers' ((@($g.Reasons | ForEach-Object { $_.Code }) -contains 'MultipleMarkers') -and ($g.Proceed -eq $false)) "reasons=$(@($g.Reasons | ForEach-Object { $_.Code }) -join ',')")
    [System.IO.File]::Delete((Join-Path $P.StateRoot 'installing.json'))
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'uninstalling.json'), '{"State":"Uninstalling"}', $script:Utf8)
    $g = Gate; [void](Assert-I2A 'UC9-legacy-marker-unsupported' ((@($g.Reasons | ForEach-Object { $_.Code }) -contains 'LegacyMarkerUnsupported') -and ($g.Proceed -eq $false) -and [System.IO.File]::Exists((Join-Path $P.StateRoot 'uninstalling.json'))) "reasons=$(@($g.Reasons | ForEach-Object { $_.Code }) -join ',') (never deleted or converted)")
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'uninstalling.json'), '{ nope', $script:Utf8)
    $g = Gate; [void](Assert-I2A 'UC9-unreadable-marker' ((@($g.Reasons | ForEach-Object { $_.Code }) -contains 'MarkerUnreadable') -and ($g.Proceed -eq $false)) "reasons=$(@($g.Reasons | ForEach-Object { $_.Code }) -join ',')")
    [System.IO.File]::WriteAllText((Join-Path $P.StateRoot 'uninstalling.json'), '{"TxnId":"20261016T000050Z-00000050","Operation":"Uninstall","SchemaVersion":1,"State":"Uninstalling"}', $script:Utf8)
    $g = Gate 'DryRun'; [void](Assert-I2A 'UC9-marker-without-journal-is-repair-required' (($g.Proceed -eq $false) -and ($g.Outcome -eq 'RepairRequired') -and ($g.ErrorCode -eq 'RecoveryRequired') -and ($g.ManualCheckRequired -eq $true)) "outcome=$($g.Outcome)")
    [void](Assert-I2A 'UC9-gate-result-has-evidence-property' ($null -ne $g.PSObject.Properties['Evidence']) 'the manual-recovery evidence list is always present')
    Restore-AfterTree
    # orphan journal (marker removed by hand)
    [void](New-I2CForgedActiveJournal $L)
    $g = Gate; [void](Assert-I2A 'UC9-orphan-journal-refused' (($g.Proceed -eq $false) -and ($g.ErrorCode -eq 'RecoveryRequired')) "reasons=$(@($g.Reasons | ForEach-Object { $_.Code }) -join ',')")
    Restore-AfterTree

    # =================================================== UC10 failure mapping
    $tx = [pscustomobject]@{ Code = 'CommitFailed'; RollbackState = 'RolledBack'; FailedItem = -1; Reasons = @(); ManualCheckRequired = $false; Message = 'm' }
    $f = ConvertTo-DenGoUninstallFailure $tx ''
    [void](Assert-I2A 'UC10-commit-failure-vocabulary' (($f.ErrorCode -eq 'UninstalledStateWriteFailed') -and ($f.FailedSet -eq 'UninstalledState')) "code=$($f.ErrorCode) set=$($f.FailedSet)")
    $tx.Code = 'ApplyFailed'; $f = ConvertTo-DenGoUninstallFailure $tx 'BVE5'
    [void](Assert-I2A 'UC10-apply-failure-vocabulary' (($f.ErrorCode -eq 'SetApplyFailed') -and ($f.FailedSet -eq 'BVE5') -and ($f.RollbackSucceeded -eq $true)) "code=$($f.ErrorCode)")
    $tx.Code = 'ApplyFailed'; $tx.RollbackState = 'RollbackIncomplete'
    $f = ConvertTo-DenGoUninstallFailure $tx 'BVE5'
    [void](Assert-I2A 'UC10-rollback-incomplete-needs-recovery' (($f.ErrorCode -eq 'RecoveryRequired') -and ($f.RollbackSucceeded -eq $false)) "code=$($f.ErrorCode)")
} finally {
    Remove-I2ASandbox $L.Root
}
Complete-I2ATests
