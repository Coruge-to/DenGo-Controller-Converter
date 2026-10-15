# I2-B unit tests: product leaf gate, roles and policy, plan conversion, ownership merge (pure), previous state, recovery-gate decisions,
# failure mapping, staged shortcut, AllowEmptyTransaction in the core, lock helper. Sandboxes only (TEMP).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')

$L = New-I2BScenario 'unit' 'P1'
$P = $L.Product
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Gate($Role, $Root, $Path, $Kind, $Txn = '') { return (Test-DenGoLeafGate $P $Role $Root $Path $Kind $Txn) }
function Allowed($Id, $Gate, [string]$Detail) { [void](Assert-I2A $Id ([bool]$Gate.Allowed) ($Detail + ' => ' + $Gate.Reason)) }
function Denied($Id, $Gate, [string]$Detail, [string]$Reason = '') {
    $ok = (-not [bool]$Gate.Allowed)
    if ($ok -and $Reason.Length -gt 0) { $ok = ($Gate.Reason -eq $Reason) }
    [void](Assert-I2A $Id $ok ($Detail + ' => ' + $Gate.Reason))
}
try {
    # =================================================== U1 leaf gate
    $tx = 'T0001'
    $ok = $true
    Use-I2BHarnessIds
    $P = (Get-I2BLayout $L.Root).Product    # re-derive with the harness-id pattern for infra checks below
    # App
    Allowed 'U1-app-exe' (Gate 'App' '' $P.AppExe 'Dest') 'AppExe'
    Allowed 'U1-app-ico' (Gate 'App' '' $P.AppIco 'Dest') 'AppIco'
    Allowed 'U1-app-exe-tmp' (Gate 'App' '' ($P.AppExe + '.dengo.tmp') 'Tmp') 'AppExe tmp'
    Denied  'U1-app-uninstall-exe' (Gate 'App' '' (Join-Path $P.AppDir 'Uninstall.exe') 'Dest') 'Uninstall.exe belongs to the wrapper' 'LeafNotAllowed'
    Denied  'U1-app-uninstall-exe-tmp' (Gate 'App' '' (Join-Path $P.AppDir 'Uninstall.exe.dengo.tmp') 'Tmp') 'Uninstall.exe tmp'
    Denied  'U1-app-other-program' (Gate 'App' '' (Join-Path $P.ProgramsDir 'Other\x.txt') 'Dest') 'another program under Programs'
    Denied  'U1-app-sibling-file' (Gate 'App' '' (Join-Path $P.AppDir 'other.dll') 'Dest') 'another file in the app folder'
    Allowed 'U1-app-dir-programs' (Gate 'App' '' $P.ProgramsDir 'Dir') 'Programs may be created'
    Allowed 'U1-app-dir-appdir' (Gate 'App' '' $P.AppDir 'Dir') 'app folder may be created'
    Denied  'U1-app-dir-localappdata' (Gate 'App' '' $P.LocalAppData 'Dir') 'LOCALAPPDATA itself'
    Denied  'U1-app-dir-other' (Gate 'App' '' (Join-Path $P.LocalAppData 'Other') 'Dir') 'another folder'
    Denied  'U1-app-uninstallrollback' (Gate 'App' '' (Join-Path $P.DataRoot 'UninstallRollback') 'Infra') 'UninstallRollback is I2-C'
    Denied  'U1-app-uninstalled-state' (Gate 'App' '' (Join-Path $P.StateRoot 'uninstalled-state.json') 'Infra') 'uninstalled-state.json is I2-C'
    # Bve5 / Bve6
    $dll5 = Join-Path $L.Bve5 'Input Devices\DenGoControllerConverter.dll'
    $dll6 = Join-Path $L.Bve6 'Input Devices\DenGoControllerConverter.dll'
    Allowed 'U1-bve5-dll' (Gate 'Bve5' $L.Bve5 $dll5 'Dest') 'BVE5 caller (x86 BveTs.exe)'
    Allowed 'U1-bve6-dll' (Gate 'Bve6' $L.Bve6 $dll6 'Dest') 'BVE6 caller (x64 BveTs.exe)'
    Allowed 'U1-bve5-tmp' (Gate 'Bve5' $L.Bve5 ($dll5 + '.dengo.tmp') 'Tmp') 'BVE5 tmp'
    Allowed 'U1-bve5-dir' (Gate 'Bve5' $L.Bve5 (Join-Path $L.Bve5 'Input Devices') 'Dir') 'Input Devices may be created'
    Denied  'U1-bve5-machine' (Gate 'Bve5' $L.Bve6 $dll6 'Dest') 'x64 root for the BVE5 role' 'BveMachineMismatch'
    Denied  'U1-bve6-machine' (Gate 'Bve6' $L.Bve5 $dll5 'Dest') 'x86 root for the BVE6 role' 'BveMachineMismatch'
    Denied  'U1-bve-no-exe' (Gate 'Bve5' $L.Guard (Join-Path $L.Guard 'Input Devices\DenGoControllerConverter.dll') 'Dest') 'a folder without BveTs.exe' 'BveRootHasNoExe'
    Denied  'U1-bve-other-dll' (Gate 'Bve6' $L.Bve6 (Join-Path $L.Bve6 'Input Devices\other.dll') 'Dest') 'another device plug-in' 'LeafNotAllowed'
    Denied  'U1-bve-other-dir' (Gate 'Bve6' $L.Bve6 (Join-Path $L.Bve6 'Plugins') 'Dir') 'another folder in the BVE folder' 'LeafNotAllowed'
    Denied  'U1-bve-bvets-exe' (Gate 'Bve6' $L.Bve6 (Join-Path $L.Bve6 'BveTs.exe') 'Dest') 'BveTs.exe itself' 'LeafNotAllowed'
    Denied  'U1-bve-root-empty' (Gate 'Bve5' '' $dll5 'Dest') 'empty root' 'RootInvalid'
    Denied  'U1-bve-root-unc' (Gate 'Bve5' '\\server\share\Bve' '\\server\share\Bve\Input Devices\DenGoControllerConverter.dll' 'Dest') 'UNC root' 'PathUnc'
    # BveEX Current / AtsEX Legacy
    $cb = Join-Path $P.CurrentExt 'DenGoVehicleSpec.BveEx.Bridge.dll'; $cv = Join-Path $P.CurrentExt 'DenGoBveVehicleSpec.dll'
    $lb = Join-Path $P.LegacyExt 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll'; $lv = Join-Path $P.LegacyExt 'DenGoAtsExLegacyVehicleSpec.dll'
    Allowed 'U1-current-bridge' (Gate 'Current' '' $cb 'Dest') 'Current bridge'
    Allowed 'U1-current-spec' (Gate 'Current' '' $cv 'Dest') 'Current vehicle spec'
    Allowed 'U1-legacy-bridge' (Gate 'Legacy' '' $lb 'Dest') 'Legacy bridge'
    Allowed 'U1-legacy-spec' (Gate 'Legacy' '' $lv 'Dest') 'Legacy vehicle spec'
    Denied  'U1-current-wrong-role' (Gate 'Current' '' $lb 'Dest') 'a Legacy file with the Current role' 'LeafNotAllowed'
    Denied  'U1-current-other-dll' (Gate 'Current' '' (Join-Path $P.CurrentExt 'SomeOther.dll') 'Dest') 'another extension' 'LeafNotAllowed'
    Denied  'U1-current-dir' (Gate 'Current' '' $P.CurrentExt 'Dir') 'the Extensions folder (never created)' 'LeafNotAllowed'
    Denied  'U1-current-parent' (Gate 'Current' '' (Join-Path $P.PublicRoot 'Documents\BveEx\2.0') 'Dir') 'the parent folder' 'LeafNotAllowed'
    # RPCS3
    $yml = Join-Path $L.Rpcs3Global 'Den-Go-Controller.yml'
    Allowed 'U1-rpcs3-yml' (Gate 'Rpcs3' $L.Rpcs3Global $yml 'Dest') 'the DenGo profile'
    Allowed 'U1-rpcs3-yml-tmp' (Gate 'Rpcs3' $L.Rpcs3Global ($yml + '.dengo.tmp') 'Tmp') 'its tmp'
    Denied  'U1-rpcs3-other-yaml' (Gate 'Rpcs3' $L.Rpcs3Global (Join-Path $L.Rpcs3Global 'Other.yml') 'Dest') 'another YAML' 'LeafNotAllowed'
    Denied  'U1-rpcs3-parent-folder' (Gate 'Rpcs3' $L.Rpcs3Global (Join-Path $L.Rpcs3 'config\input_configs') 'Dir') 'an upper folder' 'LeafNotAllowed'
    Denied  'U1-rpcs3-upper-file' (Gate 'Rpcs3' $L.Rpcs3Global (Join-Path $L.Rpcs3 'config\input_configs\keep.txt') 'Dest') 'a file in an upper folder' 'LeafNotAllowed'
    Denied  'U1-rpcs3-wrong-root' (Gate 'Rpcs3' (Join-Path $L.Rpcs3 'config') (Join-Path $L.Rpcs3 'config\Den-Go-Controller.yml') 'Dest') 'a root that is not config\input_configs\global' 'Rpcs3RootInvalid'
    Denied  'U1-rpcs3-no-exe' (Gate 'Rpcs3' (Join-Path $L.Guard 'config\input_configs\global') (Join-Path $L.Guard 'config\input_configs\global\Den-Go-Controller.yml') 'Dest') 'no rpcs3.exe above' 'Rpcs3RootHasNoExe'
    Denied  'U1-rpcs3-dir' (Gate 'Rpcs3' $L.Rpcs3Global $L.Rpcs3Global 'Dir') 'no folder is ever created' 'LeafNotAllowed'
    # Shortcut (F1): the Desktop root comes from the journaled tag; the layout of the current run is irrelevant
    $deskRoot = DgP-Full $L.Desktop
    Allowed 'U1-shortcut' (Gate 'Shortcut' $deskRoot $P.ShortcutPath 'Dest') 'the Desktop shortcut (root from the tag)'
    Allowed 'U1-shortcut-tmp' (Gate 'Shortcut' $deskRoot ($P.ShortcutPath + '.dengo.tmp') 'Tmp') 'its tmp'
    Denied  'U1-shortcut-other' (Gate 'Shortcut' $deskRoot (Join-Path $L.Desktop 'Other.lnk') 'Dest') 'another shortcut' 'LeafNotAllowed'
    Denied  'U1-shortcut-other-folder' (Gate 'Shortcut' $deskRoot (Join-Path $L.Guard 'DenGo Controller Converter.lnk') 'Dest') 'the fixed leaf name in another folder' 'LeafNotAllowed'
    Denied  'U1-shortcut-upper-folder' (Gate 'Shortcut' $deskRoot $L.Root 'Dir') 'an upper folder' 'LeafNotAllowed'
    Denied  'U1-shortcut-root-dir' (Gate 'Shortcut' $deskRoot $deskRoot 'Dir') 'no folder is ever created' 'LeafNotAllowed'
    Denied  'U1-shortcut-unconfigured' (Gate 'Shortcut' '' $P.ShortcutPath 'Dest') 'a tag without a root' 'ShortcutNotConfigured'
    Denied  'U1-shortcut-root-relative' (Gate 'Shortcut' 'Desktop' $P.ShortcutPath 'Dest') 'a relative root' 'RootInvalid'
    Denied  'U1-shortcut-root-unc' (Gate 'Shortcut' '\\server\share\Desktop' '\\server\share\Desktop\DenGo Controller Converter.lnk' 'Dest') 'a UNC root (the UNC destination is refused first)' 'PathUnc'
    Denied  'U1-shortcut-root-unc-local-dest' (Gate 'Shortcut' '\\server\share\Desktop' $P.ShortcutPath 'Dest') 'a UNC root with a local destination' 'RootInvalid'
    Denied  'U1-shortcut-root-drive'(Gate 'Shortcut' 'C:\' 'C:\DenGo Controller Converter.lnk' 'Dest') 'a drive root' 'ShortcutRootInvalid'
    Denied  'U1-shortcut-root-not-normalized' (Gate 'Shortcut' ($deskRoot + '\') $P.ShortcutPath 'Dest') 'a root with a trailing separator is not the recorded normalized folder' 'ShortcutRootInvalid'
    Denied  'U1-shortcut-root-dotdot' (Gate 'Shortcut' ($L.Desktop + '\..\Desktop') $P.ShortcutPath 'Dest') 'dot-dot in the root' 'RootInvalid'
    $juncRoot = Join-Path $L.Root 'JuncDesk'
    New-Item -ItemType Junction -Path $juncRoot -Target $L.Guard | Out-Null
    try {
        Denied  'U1-shortcut-root-reparse' (Gate 'Shortcut' (DgP-Full $juncRoot) (Join-Path $juncRoot 'DenGo Controller Converter.lnk') 'Dest') 'a root that is a junction' 'ShortcutRootReparse'
    } finally { [System.IO.Directory]::Delete($juncRoot) }
    [void](Assert-I2A 'U1-shortcut-root-reparse-target-intact' ([System.IO.File]::Exists((Join-Path $L.Guard 'g1.txt')) -and -not [System.IO.Directory]::Exists($juncRoot)) 'removing the junction left its target alone')
    $noSc = Get-DenGoProductLayout -LocalAppData $L.Local -PublicRoot $L.Public
    Allowed 'U1-shortcut-independent-of-the-layout' (Test-DenGoLeafGate $noSc 'Shortcut' $deskRoot $P.ShortcutPath 'Dest') 'a layout without a ShortcutPath (the next GUI run did not ask for a shortcut) still gates the journaled shortcut'
    $otherDesk = Get-DenGoProductLayout -LocalAppData $L.Local -PublicRoot $L.Public -ShortcutPath (Join-Path $L.Guard 'DenGo Controller Converter.lnk')
    Allowed 'U1-shortcut-independent-of-another-desktop' (Test-DenGoLeafGate $otherDesk 'Shortcut' $deskRoot $P.ShortcutPath 'Dest') 'a layout that names another Desktop does not change the recorded root'
    # Infra / Backup
    $sr = $P.StateRoot
    Allowed 'U1-infra-staterooot' (Gate 'App' '' $sr 'Infra') 'StateRoot'
    Allowed 'U1-infra-state' (Gate 'App' '' $P.StatePath 'Infra') 'installed-state.json'
    Allowed 'U1-infra-state-tmp' (Gate 'App' '' ($P.StatePath + '.tmp') 'Infra') 'installed-state.json.tmp'
    Allowed 'U1-infra-marker' (Gate 'App' '' (Join-Path $sr 'installing.json') 'Infra') 'installing.json'
    Allowed 'U1-infra-txn-dir' (Gate 'App' '' (Join-Path $sr 'txn\T0001') 'Infra') 'txn\<id>'
    Allowed 'U1-infra-journal' (Gate 'App' '' (Join-Path $sr 'txn\T0001\journal.jsonl') 'Infra') 'journal.jsonl'
    Allowed 'U1-infra-report' (Gate 'App' '' (Join-Path $sr 'txn\T0001\recovery-report.txt') 'Infra') 'recovery-report.txt'
    Allowed 'U1-infra-history' (Gate 'App' '' (Join-Path $sr 'history\txn-T0001.committed.jsonl') 'Infra') 'history file'
    Denied  'U1-infra-history-bad-outcome' (Gate 'App' '' (Join-Path $sr 'history\txn-T0001.other.jsonl') 'Infra') 'history file with an unknown outcome' 'LeafNotAllowed'
    Denied  'U1-infra-foreign-file' (Gate 'App' '' (Join-Path $sr 'foo.json') 'Infra') 'another file in the state folder' 'LeafNotAllowed'
    Denied  'U1-infra-bad-id' (Gate 'App' '' (Join-Path $sr 'txn\evil') 'Infra') 'a txn folder with a bad id' 'LeafNotAllowed'
    Denied  'U1-infra-id-mismatch' (Gate 'App' '' (Join-Path $sr 'txn\T0002\journal.jsonl') 'Infra' 'T0001') 'another transaction id' 'LeafNotAllowed'
    Denied  'U1-infra-journal-wrong-name' (Gate 'App' '' (Join-Path $sr 'txn\T0001\other.jsonl') 'Infra') 'another file in the txn folder' 'LeafNotAllowed'
    Allowed 'U1-backup-file' (Gate 'App' '' (Join-Path $P.BackupRoot 'T0001\0003.bak') 'Backup' 'T0001') 'NNNN.bak'
    Denied  'U1-backup-name' (Gate 'App' '' (Join-Path $P.BackupRoot 'T0001\3.bak') 'Backup' 'T0001') 'a backup name that is not 4 digits' 'LeafNotAllowed'
    Denied  'U1-backup-other-ext' (Gate 'App' '' (Join-Path $P.BackupRoot 'T0001\0003.txt') 'Backup' 'T0001') 'a backup with another extension' 'LeafNotAllowed'
    Denied  'U1-backup-outside' (Gate 'App' '' (Join-Path $P.DataRoot 'UninstallRollback\T0001\0001.bak') 'Backup' 'T0001') 'a backup outside InstallerBackups' 'LeafNotAllowed'
    Denied  'U1-backup-id' (Gate 'App' '' (Join-Path $P.BackupRoot 'T0002\0003.bak') 'Backup' 'T0001') 'a backup of another transaction' 'LeafNotAllowed'
    # path forms
    Denied  'U1-form-relative' (Gate 'App' '' 'Programs\DenGo Controller Converter\DenGoControllerConverter.exe' 'Dest') 'relative path' 'PathNotAbsolute'
    Denied  'U1-form-dotdot' (Gate 'App' '' ($P.AppDir + '\..\DenGo Controller Converter\DenGoControllerConverter.exe') 'Dest') 'dot-dot' 'PathDotDot'
    Denied  'U1-form-stream' (Gate 'App' '' ($P.AppExe + ':stream') 'Dest') 'alternate data stream' 'PathStream'
    Denied  'U1-form-device' (Gate 'App' '' (Join-Path $P.AppDir 'NUL.dll') 'Dest') 'reserved device name' 'PathReservedName'
    Denied  'U1-form-unc' (Gate 'App' '' '\\server\share\DenGoControllerConverter.exe' 'Dest') 'UNC' 'PathUnc'
    Denied  'U1-form-empty' (Gate 'App' '' '' 'Dest') 'empty' 'PathEmpty'
    Denied  'U1-kind-unknown' (Gate 'App' '' $P.AppExe 'Whatever') 'unknown kind' 'KindUnknown'
    Denied  'U1-role-unknown' (Gate 'Deferred' '' $P.AppExe 'Dest') 'the Deferred pseudo role' 'RoleUnknown'
    Denied  'U1-role-pcsx2' (Gate 'Pcsx2' '' (Join-Path $L.Pcsx2Inis 'LilyPad.ini') 'Dest') 'PCSX2 / LilyPad is never allowed' 'RoleUnknown'
    # the item-level gate: every fact of one registered item
    $good = Test-DenGoItemGate $P 'Core|Application|App|' $P.AppExe ($P.AppExe + '.dengo.tmp') ([string[]]@($P.ProgramsDir, $P.AppDir)) '' $tx
    [void](Assert-I2A 'U1-itemgate-ok' ($good.Count -eq 0) ('failures=' + $good.Count))
    $bad = Test-DenGoItemGate $P 'Core|Application|App|' (Join-Path $P.AppDir 'Uninstall.exe') (Join-Path $P.AppDir 'Uninstall.exe.dengo.tmp') ([string[]]@()) '' $tx
    [void](Assert-I2A 'U1-itemgate-uninstall-exe' ($bad.Count -eq 2) ('failures=' + $bad.Count))
    $bad = Test-DenGoItemGate $P 'broken-tag' $P.AppExe ($P.AppExe + '.dengo.tmp') ([string[]]@()) '' $tx
    [void](Assert-I2A 'U1-itemgate-bad-tag' ($bad.Count -eq 1) ('failures=' + $bad.Count))
    $bad = Test-DenGoItemGate $P 'Core|Application|App|' $P.AppExe ($P.AppExe + '.dengo.tmp') ([string[]]@($P.LocalAppData)) '' $tx
    [void](Assert-I2A 'U1-itemgate-bad-dir' ($bad.Count -eq 1) ('failures=' + $bad.Count))
    $bad = Test-DenGoItemGate $P 'Core|Application|App|' $P.AppExe ($P.AppExe + '.dengo.tmp') ([string[]]@()) (Join-Path $P.BackupRoot 'T0009\0000.bak') $tx
    [void](Assert-I2A 'U1-itemgate-bad-backup' ($bad.Count -eq 1) ('failures=' + $bad.Count))
    $bad = Test-DenGoItemGate $P 'App|Application|Bve5|' $dll5 ($dll5 + '.dengo.tmp') ([string[]]@()) '' $tx
    [void](Assert-I2A 'U1-itemgate-role-without-root' ($bad.Count -ge 1) ('failures=' + $bad.Count))
    # F1: every fact of a journaled shortcut item is re-checked from the tag alone
    $scTag = 'Shortcut|Desktop|Shortcut|' + $deskRoot
    $good = Test-DenGoItemGate $P $scTag $P.ShortcutPath ($P.ShortcutPath + '.dengo.tmp') ([string[]]@()) (Join-Path $P.BackupRoot 'T0001\0004.bak') $tx
    [void](Assert-I2A 'U1-itemgate-shortcut-ok' ($good.Count -eq 0) ('failures=' + $good.Count + ' ' + ($good -join '; ')))
    $bad = Test-DenGoItemGate $P $scTag (Join-Path $L.Desktop 'Other.lnk') (Join-Path $L.Desktop 'Other.lnk.dengo.tmp') ([string[]]@()) '' $tx
    [void](Assert-I2A 'U1-itemgate-shortcut-other-name' ($bad.Count -eq 2) ('failures=' + $bad.Count))
    $bad = Test-DenGoItemGate $P ('Shortcut|Desktop|Shortcut|' + $L.Guard) $P.ShortcutPath ($P.ShortcutPath + '.dengo.tmp') ([string[]]@()) '' $tx
    [void](Assert-I2A 'U1-itemgate-shortcut-forged-root' ($bad.Count -eq 2) ('failures=' + $bad.Count + ': the destination is not the fixed leaf below the recorded root'))
    $bad = Test-DenGoItemGate $P 'Shortcut|Desktop|Shortcut|' $P.ShortcutPath ($P.ShortcutPath + '.dengo.tmp') ([string[]]@()) '' $tx
    [void](Assert-I2A 'U1-itemgate-shortcut-no-root' ($bad.Count -eq 2) ('failures=' + $bad.Count))
    $bad = Test-DenGoItemGate $P $scTag $P.ShortcutPath ($P.ShortcutPath + '.dengo.tmp') ([string[]]@($L.Desktop)) '' $tx
    [void](Assert-I2A 'U1-itemgate-shortcut-dir-refused' ($bad.Count -eq 1) ('failures=' + $bad.Count + ': a shortcut item never carries folders to create'))

    Use-I2BProductIds
    # =================================================== U2 policy
    $pol = New-DenGoPathPolicy $P ([string[]]@($L.Bve5))
    [void](Assert-I2A 'U2-policy-reject' ($pol.ReparseMode -eq 'Reject') ('ReparseMode=' + $pol.ReparseMode))
    [void](Assert-I2A 'U2-policy-roots' (($pol.AllowedRoots -contains (DgP-Full $P.LocalAppData)) -and ($pol.AllowedRoots -contains (DgP-Full $L.Bve5)) -and ($pol.AllowedRoots.Count -eq 2)) ('roots=' + ($pol.AllowedRoots -join ';')))
    $prodPol = New-DenGoPathPolicy (Get-DenGoProductLayout -LocalAppData $env:LOCALAPPDATA)
    $broad = $false
    foreach ($r in $prodPol.AllowedRoots) {
        foreach ($wide in @(($env:SystemDrive + '\'), $env:USERPROFILE, [System.Environment]::GetFolderPath('MyDocuments'), $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            $w = $wide.TrimEnd('\')
            if (($w -eq $r) -or $w.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $broad = $true }
        }
    }
    [void](Assert-I2A 'U2-policy-no-broad-root' ((-not $broad) -and ($prodPol.AllowedRoots.Count -eq 1)) ('production roots: ' + ($prodPol.AllowedRoots -join ';') + ' (none contains the drive root, the profile, Documents or Program Files)'))
    $thr = $false; try { [void](DgPolicy-New -AllowedRoots @($L.Local) -ReparseMode 'RecordOnlyX') } catch { $thr = $true }
    [void](Assert-I2A 'U2-policy-unknown-mode-throws' $thr 'an unknown ReparseMode throws (fail-closed)')

    # =================================================== U3 role spec on real fixtures (structure checks) and Tag
    $t = DgP-ParseTag 'BVE5|Caller|Bve5|C:\x\y'
    [void](Assert-I2A 'U3-tag-parse' (($null -ne $t) -and ($t.Platform -eq 'BVE5') -and ($t.Role -eq 'Bve5') -and ($t.Root -eq 'C:\x\y')) 'four fields')
    [void](Assert-I2A 'U3-tag-bad' (($null -eq (DgP-ParseTag 'a|b|c')) -and ($null -eq (DgP-ParseTag 'a|b|c|d|e'))) 'three or five fields are refused')

    # =================================================== U4 plan conversion
    $plan = Get-I2BPlan $L 'P1'
    $stageNone = $null
    $entries = Convert-DenGoPlanToEntries $P $plan $stageNone
    $txi = Get-DenGoTxItems $entries
    $order = @($txi.Ordered | ForEach-Object { $_.Platform })
    [void](Assert-I2A 'U4-set-order' (($order -join ',') -eq 'Core,Core,BVE5,BVE6,BveEX Current,BveEX Current,AtsEX Legacy,AtsEX Legacy,RPCS3') ('order=' + ($order -join ',')))
    [void](Assert-I2A 'U4-pcsx2-not-in-transaction' (@($txi.Items | Where-Object { $_.Tag.StartsWith('PCSX2') }).Count -eq 0) 'no PCSX2 item')
    [void](Assert-I2A 'U4-pcsx2-deferred-entries' (@($entries | Where-Object { $_.Deferred }).Count -eq 2) 'two Deferred entries')
    $swapped = @($plan[2], $plan[0], $plan[1], $plan[3]) + @($plan[4..($plan.Count - 1)])   # BVE5 first, then Core
    $e2 = Convert-DenGoPlanToEntries $P ([object[]]$swapped) $null
    $o2 = @((Get-DenGoTxItems $e2).Ordered | ForEach-Object { $_.Platform })
    [void](Assert-I2A 'U4-set-order-is-stable-and-by-set' ((($o2 -join ',').StartsWith('Core,Core,BVE5,BVE6'))) ('order=' + ($o2 -join ',')))
    $p3 = New-I2BScenario 'u4' 'P3'
    try { $unchangedPlan = Get-I2BPlan $p3 'P3' } finally { Remove-I2ASandbox $p3.Root }
    $e3 = Convert-DenGoPlanToEntries $P ([object[]]$unchangedPlan) $null
    [void](Assert-I2A 'U4-unchanged-not-tx' (@($e3 | Where-Object { $_.IsTx }).Count -eq 0) 'Unchanged, PreserveUserModified, NotInitialized never become items')
    $thr = ''; try { [void](Convert-DenGoPlanToEntries $P ([object[]]@([pscustomobject]@{ Platform = 'Unknown'; Component = 'x'; Action = 'Add'; Source = 's'; SourceSHA256 = ''; Destination = 'C:\x'; DestinationSHA256 = '' })) $null) } catch { $thr = DgError-Code $_.Exception }
    [void](Assert-I2A 'U4-unknown-platform' ($thr -eq 'PlanInvalid') "code=$thr")
    $thr = ''; try { [void](Convert-DenGoPlanToEntries $P ([object[]]@([pscustomobject]@{ Platform = 'Core'; Component = 'x'; Action = 'Delete'; Source = 's'; SourceSHA256 = ''; Destination = 'C:\x'; DestinationSHA256 = '' })) $null) } catch { $thr = DgError-Code $_.Exception }
    [void](Assert-I2A 'U4-unknown-action' ($thr -eq 'PlanInvalid') "code=$thr")
    $dirs = Get-DenGoExpectedDirs $P.AppExe
    [void](Assert-I2A 'U4-expected-dirs' (($dirs.Count -ge 1) -and ($dirs[$dirs.Count - 1] -eq (DgP-Full $P.AppDir))) ('dirs=' + ($dirs -join ';')))
    # F1: the shortcut item carries its normalized Desktop root in the tag; Unchanged / Diverged never become items
    $facts0 = [pscustomobject]@{ TargetPath = $P.AppExe; WorkingDirectory = $P.AppDir; IconLocation = ($P.AppIco + ',0') }
    $stAdd = [pscustomobject]@{ Ok = $true; Action = 'Add'; StagePath = 'C:\stage\x.lnk'; ExistingSha = ''; Sha = 'SS'; Facts = $facts0 }
    $eS = Convert-DenGoPlanToEntries $P $plan $stAdd
    $txS = Get-DenGoTxItems $eS
    $scItem = @($txS.Items | Where-Object { ([string]$_.Tag).StartsWith('Shortcut|') })
    [void](Assert-I2A 'U4-shortcut-tag-carries-the-root' (($scItem.Count -eq 1) -and ($scItem[0].Tag -eq ('Shortcut|Desktop|Shortcut|' + (DgP-Full $L.Desktop))) -and ($scItem[0].Destination -eq $P.ShortcutPath)) ('tag=' + $(if ($scItem.Count -eq 1) { $scItem[0].Tag })))
    [void](Assert-I2A 'U4-shortcut-is-the-last-item' (([string]$txS.Items[$txS.Items.Count - 1].Tag).StartsWith('Shortcut|')) 'Set order: the shortcut is applied last')
    foreach ($act in 'Unchanged', 'Diverged') {
        $stX = [pscustomobject]@{ Ok = $true; Action = $act; StagePath = 'C:\stage\x.lnk'; ExistingSha = 'EX'; Sha = 'SS'; Facts = $facts0 }
        $eX = Convert-DenGoPlanToEntries $P $plan $stX
        [void](Assert-I2A ('U4-shortcut-' + $act.ToLowerInvariant() + '-is-no-item') ((@((Get-DenGoTxItems $eX).Items | Where-Object { ([string]$_.Tag).StartsWith('Shortcut|') }).Count -eq 0) -and (@($eX | Where-Object { $_.Kind -eq 'Shortcut' }).Count -eq 1)) "the entry stays (for the state), no transaction item")
    }

    # =================================================== U5 ownership merge (pure; the probe is injected)
    $now = '2026-02-02T00:00:00.0000000+09:00'
    $disk = @{}
    $probe = { param($p) $k = $p.ToUpperInvariant(); if ($disk.ContainsKey($k)) { return [string]$disk[$k] }; return '' }
    function E($Pl, $Co, $Act, $Dest, $Tx = $true, $Deferred = $false) { return [pscustomobject]@{ Kind = 'Plan'; Platform = $Pl; Component = $Co; Action = $Act; Destination = $Dest; Source = 's'; ExpectedDestSha = ''; ExpectedSourceSha = ''; Role = 'App'; Root = ''; Set = $Pl; Deferred = $Deferred; IsTx = $Tx } }
    function Prev($Files, $Extra = @{}) {
        $o = [ordered]@{ SchemaVersion = 1; ProductVersion = '2.0.0'; PCSX2LegacyKeyboardInitialized = $true; InstalledAt = 'old'; BackupRoot = 'old'; Shortcut = [pscustomobject]@{ Requested = $false; Created = $false; Path = '' }; Files = [object[]]@($Files) }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        return [pscustomobject]@{ Exists = $true; Sha = 'X'; State = [pscustomobject]$o; Files = [object[]]@($Files) }
    }
    function Rec($Pl, $Co, $Dest, $Own, $After = 'AAAA', $Before = '', $Backup = '', $Existed = $false) { return [pscustomobject][ordered]@{ Platform = $Pl; Component = $Co; Destination = $Dest; InstallAction = 'Add'; Ownership = $Own; ExistedBefore = $Existed; BeforeSHA256 = $Before; AfterSHA256 = $After; Backup = $Backup } }
    function Merge($Prev, $Entries, $Tx = @{}, $Shortcut = $null) { return (Merge-DenGoInstalledState $Prev ([object[]]$Entries) $Tx 'T0001' 'C:\bk\T0001' $now $Shortcut $probe) }
    function RecOf($State, $Dest) { foreach ($f in @($State.Files)) { if ($f.Destination -eq $Dest) { return $f } }; return $null }
    $d1 = 'C:\m\a.dll'; $d2 = 'C:\m\b.dll'; $d3 = 'C:\m\c.ini'; $d4 = 'C:\m\p.lily'
    $disk[$d1.ToUpperInvariant()] = 'S1'; $disk[$d2.ToUpperInvariant()] = 'S2'; $disk[$d3.ToUpperInvariant()] = 'S3'; $disk[$d4.ToUpperInvariant()] = 'S4'
    # no previous state
    $s = Merge $null @((E 'Core' 'Application' 'Add' $d1))
    $r = RecOf $s $d1
    [void](Assert-I2A 'U5-add' (($r.Ownership -eq 'CreatedByInstaller') -and ($r.AfterSHA256 -eq 'S1') -and ($r.Presence -eq 'InPlan') -and ($r.Observed -eq 'Present') -and ($r.LastSeenTransactionId -eq 'T0001') -and ($r.ExistedBefore -eq $false)) "own=$($r.Ownership)")
    [void](Assert-I2A 'U5-schema-additive' (($s.SchemaVersion -eq 1) -and ($s.StateRevision -eq 2) -and ($s.TransactionId -eq 'T0001') -and ($s.InstalledAt -eq $now) -and ($s.BackupRoot -eq 'C:\bk\T0001')) 'SchemaVersion stays 1; StateRevision 2')
    $s = Merge $null @((E 'BVE5' 'Caller' 'UpdateOrRepair' $d1)) @{ $d1.ToUpperInvariant() = @{ Backup = 'C:\bk\T0001\0000.bak'; PreSha = 'OLD1' } }
    $r = RecOf $s $d1
    [void](Assert-I2A 'U5-update-nonprofile-no-prev' (($r.Ownership -eq 'MigratedMatchingDenGoFile') -and ($r.ExistedBefore -eq $false) -and ($r.Backup -eq '') -and (@($r.Backups).Count -eq 1) -and ($r.Backups[0].Path -eq 'C:\bk\T0001\0000.bak') -and ($r.Backups[0].SHA256 -eq 'OLD1')) "own=$($r.Ownership) backups=$(@($r.Backups).Count) (the backup is now recorded, M-2)")
    $s = Merge $null @((E 'PCSX2' 'EffectiveInputProfile' 'UpdateOrRepair' $d3)) @{ $d3.ToUpperInvariant() = @{ Backup = 'C:\bk\T0001\0001.bak'; PreSha = 'ORIG3' } }
    $r = RecOf $s $d3
    [void](Assert-I2A 'U5-update-profile-no-prev' (($r.Ownership -eq 'ReplacedExisting') -and ($r.ExistedBefore -eq $true) -and ($r.BeforeSHA256 -eq 'ORIG3') -and ($r.Backup -eq 'C:\bk\T0001\0001.bak')) "own=$($r.Ownership) before=$($r.BeforeSHA256)")
    $s = Merge $null @((E 'Core' 'Icon' 'Unchanged' $d2 $false))
    [void](Assert-I2A 'U5-unchanged-no-prev' ((RecOf $s $d2).Ownership -eq 'MigratedMatchingDenGoFile') 'unchanged without a record')
    $s = Merge $null @((E 'RPCS3' 'InputProfile' 'PreserveUserModified' $d4 $false))
    [void](Assert-I2A 'U5-preserve' ((RecOf $s $d4).Ownership -eq 'PreservedUserFile') 'PreservedUserFile')
    $s = Merge $null @((E 'BveEX Current' 'Bridge' 'NotInitialized' 'C:\m\none.dll' $false))
    [void](Assert-I2A 'U5-notinitialized-first-sighting' ((RecOf $s 'C:\m\none.dll').Ownership -eq 'NotInstalled') 'NotInstalled on first sight')
    # with previous state
    $pv = Prev @((Rec 'Core' 'Application' $d1 'ReplacedExisting' 'OLDAFTER' 'ORIG' 'C:\old\x.bak' $true))
    $s = Merge $pv @((E 'Core' 'Application' 'UpdateOrRepair' $d1)) @{ $d1.ToUpperInvariant() = @{ Backup = 'C:\bk\T0001\0000.bak'; PreSha = 'EDITED' } }
    $r = RecOf $s $d1
    [void](Assert-I2A 'U5-prev-replaced-nonprofile-becomes-migrated' (($r.Ownership -eq 'MigratedMatchingDenGoFile') -and ($r.Backup -eq '') -and ($r.BeforeSHA256 -eq '')) 'existing behaviour kept')
    $pv = Prev @((Rec 'PCSX2' 'EffectiveInputProfile' $d3 'ReplacedExisting' 'OLDAFTER' 'ORIG' 'C:\old\lily.bak' $true))
    $s = Merge $pv @((E 'RPCS3' 'EffectiveInputProfile' 'UpdateOrRepair' $d3)) @{ $d3.ToUpperInvariant() = @{ Backup = 'C:\bk\T0001\0002.bak'; PreSha = 'EDITED' } }
    $r = RecOf $s $d3
    [void](Assert-I2A 'U5-prev-profile-keeps-origin' (($r.Ownership -eq 'ReplacedExisting') -and ($r.BeforeSHA256 -eq 'ORIG') -and ($r.Backup -eq 'C:\old\lily.bak') -and ($r.ExistedBefore -eq $true) -and ($r.AfterSHA256 -eq 'S3') -and (@($r.Backups).Count -eq 1)) 'Origin fields untouched; the new backup is appended to Backups')
    $pv = Prev @((Rec 'BVE5' 'Caller' $d1 'CreatedByInstaller' 'S1'))
    $s = Merge $pv @((E 'BVE5' 'Caller' 'Unchanged' $d1 $false))
    [void](Assert-I2A 'U5-prev-unchanged-keeps' ((RecOf $s $d1).Ownership -eq 'CreatedByInstaller') 'Unchanged keeps the earlier ownership')
    $pv = Prev @((Rec 'BveEX Current' 'Bridge' $d2 'CreatedByInstaller' 'S2' '' '' $false))
    $s = Merge $pv @((E 'BveEX Current' 'Bridge' 'NotInitialized' $d2 $false))
    [void](Assert-I2A 'U5-prev-notinitialized-keeps' ((RecOf $s $d2).Ownership -eq 'CreatedByInstaller') 'H-4: NotInitialized no longer overwrites an earlier record')
    $s = Merge $pv @((E 'BveEX Current' 'Bridge' 'PreserveUserModified' $d2 $false))
    [void](Assert-I2A 'U5-prev-preserve' ((RecOf $s $d2).Ownership -eq 'PreservedUserFile') 'PreserveUserModified')
    # carried forward (H-4)
    $disk['C:\GONE\X.DLL'] = 'S5'
    $pv = Prev @((Rec 'BVE6' 'Caller' 'C:\gone\x.dll' 'CreatedByInstaller' 'S5'), (Rec 'BVE5' 'Caller' 'C:\gone\y.dll' 'CreatedByInstaller' 'S6'), (Rec 'BVE5' 'Caller' 'C:\gone\z.dll' 'MigratedMatchingDenGoFile' 'S7'))
    $disk['C:\GONE\Z.DLL'] = 'CHANGED'
    $s = Merge $pv @((E 'Core' 'Application' 'Add' $d1))
    $x = RecOf $s 'C:\gone\x.dll'; $y = RecOf $s 'C:\gone\y.dll'; $z = RecOf $s 'C:\gone\z.dll'
    [void](Assert-I2A 'U5-carried-present' (($x.Presence -eq 'NotDetectedThisRun') -and ($x.Observed -eq 'Present') -and ($x.Ownership -eq 'CreatedByInstaller') -and ($x.AfterSHA256 -eq 'S5') -and (-not ($x.PSObject.Properties.Name -contains 'LastSeenTransactionId'))) "presence=$($x.Presence) observed=$($x.Observed)")
    [void](Assert-I2A 'U5-carried-missing-owning-kept' (($y.Presence -eq 'NotDetectedThisRun') -and ($y.Observed -eq 'Missing') -and ($y.Ownership -eq 'CreatedByInstaller')) "observed=$($y.Observed): an owning record is never dropped because the file is missing")
    [void](Assert-I2A 'U5-carried-diverged' (($z.Observed -eq 'Diverged') -and ($z.Ownership -eq 'MigratedMatchingDenGoFile')) "observed=$($z.Observed)")
    # non-owning records outside the plan
    $disk['C:\NONOWN\HERE.INI'] = 'S9'
    $pv = Prev @((Rec 'RPCS3' 'InputProfile' 'C:\nonown\gone.yml' 'PreservedUserFile' ''), (Rec 'RPCS3' 'InputProfile' 'C:\nonown\here.ini' 'NotManaged' 'S9'), (Rec 'BVE5' 'Caller' 'C:\nonown\w.dll' 'NotInstalled' ''))
    $s = Merge $pv @((E 'Core' 'Application' 'Add' $d1))
    [void](Assert-I2A 'U5-closed-nonowning-missing' (($null -eq (RecOf $s 'C:\nonown\gone.yml')) -and (@($s.ClosedRecords).Count -eq 2) -and ($s.ClosedRecords[0].Reason -eq 'NoOwnershipAndMissing') -and ($s.ClosedRecords[0].Record.Destination -eq 'C:\nonown\gone.yml') -and ($s.ClosedRecords[0].ClosedTransactionId -eq 'T0001')) "closed=$(@($s.ClosedRecords).Count)")
    [void](Assert-I2A 'U5-nonowning-present-kept' ($null -ne (RecOf $s 'C:\nonown\here.ini')) 'a non-owning record whose file exists stays in Files')
    $pv2 = Prev @() @{ ClosedRecords = [object[]]@([pscustomobject]@{ Record = [pscustomobject]@{ Destination = 'C:\old' }; Reason = 'earlier' }) }
    $s = Merge $pv2 @((E 'Core' 'Application' 'Add' $d1))
    [void](Assert-I2A 'U5-closed-history-kept' ((@($s.ClosedRecords).Count -eq 1) -and ($s.ClosedRecords[0].Reason -eq 'earlier')) 'earlier ClosedRecords survive')
    # deferred (PCSX2)
    $pv = Prev @((Rec 'PCSX2' 'EffectiveInputProfile' $d3 'ReplacedExisting' 'S3' 'ORIG' 'C:\old\lily.bak' $true))
    $s = Merge $pv @((E 'PCSX2' 'EffectiveInputProfile' 'UpdateOrRepair' $d3 $false $true), (E 'Core' 'Application' 'Add' $d1))
    $r = RecOf $s $d3
    [void](Assert-I2A 'U5-deferred-previous-carried' (($r.Presence -eq 'DeferredThisRun') -and ($r.Ownership -eq 'ReplacedExisting') -and ($r.Backup -eq 'C:\old\lily.bak') -and ($r.BeforeSHA256 -eq 'ORIG')) 'a PCSX2 record is carried unchanged while PCSX2 is deferred')
    $s = Merge $null @((E 'PCSX2' 'InputProfile' 'Add' $d4 $false $true))
    [void](Assert-I2A 'U5-deferred-no-previous-no-record' ($null -eq (RecOf $s $d4)) 'a deferred item without an earlier record creates no record')
    # F4: ClosedRecords only for records that are outside the plan, own nothing, are gone, and are not deferred (I3) records
    $disk.Remove($d4.ToUpperInvariant())
    foreach ($own in 'NotInstalled', 'NotManaged', 'PreservedUserFile') {
        $pv = Prev @((Rec 'PCSX2' 'InputProfile' $d4 $own ''))
        $s = Merge $pv @((E 'PCSX2' 'InputProfile' 'UpdateOrRepair' $d4 $false $true), (E 'Core' 'Application' 'Add' $d1))
        $r = RecOf $s $d4
        [void](Assert-I2A ("U5-f4-deferred-in-plan-missing-$own-is-kept") (($null -ne $r) -and ($r.Presence -eq 'DeferredThisRun') -and ($r.Observed -eq 'Missing') -and ($r.Ownership -eq $own) -and (@($s.ClosedRecords).Count -eq 0)) "in the plan as Deferred and missing: kept in Files, not closed (ownership $own)")
        $s = Merge $pv @((E 'Core' 'Application' 'Add' $d1))
        $r = RecOf $s $d4
        [void](Assert-I2A ("U5-f4-pcsx2-not-in-plan-missing-$own-is-kept") (($null -ne $r) -and ($r.Presence -eq 'NotDetectedThisRun') -and (@($s.ClosedRecords).Count -eq 0)) "a PCSX2 record that I3 takes over is never closed, even outside this plan (ownership $own)")
    }
    $pv = Prev @((Rec 'RPCS3' 'InputProfile' 'C:\f4\planned.yml' 'NotInstalled' ''))
    $s = Merge $pv @((E 'RPCS3' 'InputProfile' 'NotInitialized' 'C:\f4\planned.yml' $false), (E 'Core' 'Application' 'Add' $d1))
    [void](Assert-I2A 'U5-f4-in-plan-notinstalled-is-kept' (($null -ne (RecOf $s 'C:\f4\planned.yml')) -and (@($s.ClosedRecords).Count -eq 0)) 'a non-owning record that is part of this plan is kept')
    $pv = Prev @((Rec 'RPCS3' 'InputProfile' 'C:\f4\outside.yml' 'PreservedUserFile' ''), (Rec 'PCSX2' 'EffectiveInputProfile' 'C:\f4\lily.ini' 'ReplacedExisting' 'S3' 'ORIG' 'C:\old\l.bak' $true), (Rec 'BVE5' 'Caller' 'C:\f4\owning.dll' 'CreatedByInstaller' 'S6'))
    $s = Merge $pv @((E 'Core' 'Application' 'Add' $d1))
    [void](Assert-I2A 'U5-f4-only-the-eligible-record-is-closed' ((@($s.ClosedRecords).Count -eq 1) -and ($s.ClosedRecords[0].Record.Destination -eq 'C:\f4\outside.yml') -and ($null -ne (RecOf $s 'C:\f4\lily.ini')) -and ($null -ne (RecOf $s 'C:\f4\owning.dll'))) "closed=$(@($s.ClosedRecords).Count): outside the plan + no ownership + missing + not deferred; the owning missing record and the PCSX2 record stay")
    # unknown properties of a carried record are preserved; the keyboard flag travels
    $rec = Rec 'BVE5' 'Caller' 'C:\gone\k.dll' 'CreatedByInstaller' 'S5'
    $rec | Add-Member -NotePropertyName 'Superseded' -NotePropertyValue ([object[]]@('keep-me'))
    $disk['C:\GONE\K.DLL'] = 'S5'
    $s = Merge (Prev @($rec)) @((E 'Core' 'Application' 'Add' $d1))
    [void](Assert-I2A 'U5-unknown-fields-preserved' ((RecOf $s 'C:\gone\k.dll').Superseded[0] -eq 'keep-me') 'fields written by a later schema survive')
    [void](Assert-I2A 'U5-keyboard-flag' ($s.PCSX2LegacyKeyboardInitialized -eq $true) 'PCSX2LegacyKeyboardInitialized is carried from the earlier state')
    # shortcut (F2): PreExisted = "existed before the CURRENT install generation began"; an earlier generation is the authority
    function SInfo($Action, $ExistedBeforeRun, $Backup = '', $BackupSha = '', $Facts = $null, $Requested = $true, $EntryPresent = $true) { return [pscustomobject]@{ Requested = $Requested; EntryPresent = $EntryPresent; Action = $Action; ExistedBeforeRun = $ExistedBeforeRun; Facts = $Facts; Backup = $Backup; BackupSha = $BackupSha; Path = 'C:\Desk\a.lnk' } }
    function SPrev($Sc) { return (Prev @() @{ Shortcut = [pscustomobject]$Sc }) }
    $fa = [pscustomobject]@{ TargetPath = 'C:\app\a.exe'; WorkingDirectory = 'C:\app'; IconLocation = 'C:\app\a.ico,0' }
    $fb = [pscustomobject]@{ TargetPath = 'C:\app\b.exe'; WorkingDirectory = 'C:\app'; IconLocation = 'C:\app\a.ico,0' }
    # 1 first install, no shortcut before: PreExisted=false
    $s = Merge $null @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'Add' $false '' '' $fa)
    [void](Assert-I2A 'U5-shortcut-new' (($s.Shortcut.Created -eq $true) -and ($s.Shortcut.Path -eq 'C:\Desk\a.lnk') -and ($s.Shortcut.PreExisted -eq $false) -and ($s.Shortcut.Backup -eq '') -and ($s.Shortcut.Facts.TargetPath -eq 'C:\app\a.exe') -and ($s.Shortcut.Observed -eq 'Present')) 'first install: PreExisted=false, the facts are recorded')
    $gen1 = $s.Shortcut
    # 2 reinstall over the shortcut this product created: the file exists now, PreExisted stays false
    $s = Merge (SPrev $gen1) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'Unchanged' $true '' '' $fa)
    [void](Assert-I2A 'U5-shortcut-reinstall-keeps-false' (($s.Shortcut.PreExisted -eq $false) -and ($s.Shortcut.Created -eq $true) -and ($s.Shortcut.Backup -eq '')) 'the file exists before the run, but not before the generation: PreExisted does not flip to true')
    $s = Merge (SPrev $gen1) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'UpdateOrRepair' $true 'C:\bk\T0002\0009.bak' 'OURLNK' $fb)
    [void](Assert-I2A 'U5-shortcut-update-keeps-false' (($s.Shortcut.PreExisted -eq $false) -and ($s.Shortcut.Backup -eq '') -and (@($s.Shortcut.Backups).Count -eq 1) -and ($s.Shortcut.Backups[0].Path -eq 'C:\bk\T0002\0009.bak') -and ($s.Shortcut.Facts.TargetPath -eq 'C:\app\b.exe')) 'our own shortcut updated: the backup of our old shortcut is only appended to Backups; the origin stays "none"')
    # 3 the user had a shortcut of that name before the first install: PreExisted=true, and it stays true
    $s = Merge $null @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'UpdateOrRepair' $true 'C:\bk\T0001\0009.bak' 'USERLNK' $fa)
    [void](Assert-I2A 'U5-shortcut-preexisting' (($s.Shortcut.PreExisted -eq $true) -and ($s.Shortcut.Backup -eq 'C:\bk\T0001\0009.bak') -and ($s.Shortcut.BackupSHA256 -eq 'USERLNK') -and (@($s.Shortcut.Backups).Count -eq 1)) 'the first sighting uses the real file that existed before the run')
    $gen2 = $s.Shortcut
    $s = Merge (SPrev $gen2) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'Unchanged' $true '' '' $fa)
    [void](Assert-I2A 'U5-shortcut-preexisting-stays-true' (($s.Shortcut.PreExisted -eq $true) -and ($s.Shortcut.Backup -eq 'C:\bk\T0001\0009.bak') -and ($s.Shortcut.BackupSHA256 -eq 'USERLNK')) 'reinstall: PreExisted and the origin backup are kept')
    $s = Merge (SPrev $gen2) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'UpdateOrRepair' $true 'C:\bk\T0002\0009.bak' 'OURLNK' $fb)
    [void](Assert-I2A 'U5-shortcut-preexisting-update-keeps-origin' (($s.Shortcut.PreExisted -eq $true) -and ($s.Shortcut.Backup -eq 'C:\bk\T0001\0009.bak') -and ($s.Shortcut.BackupSHA256 -eq 'USERLNK') -and (@($s.Shortcut.Backups).Count -eq 2)) 'the origin backup (the user''s shortcut) is not replaced by the newer backup of our shortcut; both are listed')
    # 4 not requested / staging failed or the item was dropped: the earlier record is kept, never overwritten with Created=false
    foreach ($case in @(@('U5-shortcut-not-requested', (SInfo '' $false '' '' $null $false $false)), @('U5-shortcut-stage-failed', (SInfo '' $false '' '' $null $true $false)))) {
        $s = Merge (SPrev $gen2) @((E 'Core' 'Application' 'Add' $d1)) @{} $case[1]
        [void](Assert-I2A $case[0] (($s.Shortcut.Created -eq $true) -and ($s.Shortcut.PreExisted -eq $true) -and ($s.Shortcut.Path -eq 'C:\Desk\a.lnk') -and ($s.Shortcut.Backup -eq 'C:\bk\T0001\0009.bak') -and ($s.Shortcut.Facts.TargetPath -eq 'C:\app\a.exe')) 'the earlier correct record is kept as it is')
    }
    $pvS = Prev @() @{ Shortcut = [pscustomobject]@{ Requested = $true; Created = $true; Path = 'C:\Desk\old.lnk' } }
    $s = Merge $pvS @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo '' $false '' '' $null $false $false)
    [void](Assert-I2A 'U5-shortcut-earlier-kept' (($s.Shortcut.Created -eq $true) -and ($s.Shortcut.Path -eq 'C:\Desk\old.lnk')) 'an earlier (old format) shortcut is not forgotten when none is requested')
    $s = Merge $null @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo '' $false '' '' $null $true $false)
    [void](Assert-I2A 'U5-shortcut-failed' (($s.Shortcut.Requested -eq $true) -and ($s.Shortcut.Created -eq $false) -and ($s.Shortcut.Path -eq '') -and ($s.Shortcut.PreExisted -eq $false)) 'requested but never created, nothing earlier: no shortcut recorded')
    # 5 an old-format earlier record (no PreExisted / Backup fields): this product created it, PreExisted=false
    $s = Merge $pvS @((E 'Core' 'Application' 'Add' $d1)) @{} ([pscustomobject]@{ Requested = $true; EntryPresent = $true; Action = 'UpdateOrRepair'; ExistedBeforeRun = $true; Facts = $fa; Backup = 'C:\bk\T0003\0009.bak'; BackupSha = 'X'; Path = 'C:\Desk\old.lnk' })
    [void](Assert-I2A 'U5-shortcut-old-format-record' (($s.Shortcut.PreExisted -eq $false) -and ($s.Shortcut.Backup -eq '') -and (@($s.Shortcut.Backups).Count -eq 1)) 'an old record without PreExisted is the authority for "created by this product"')
    # 6 the user edited our shortcut: Diverged, nothing is overwritten, the recorded facts and the origin stay
    $s = Merge (SPrev $gen1) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'Diverged' $true '' '' $fb)
    [void](Assert-I2A 'U5-shortcut-diverged' (($s.Shortcut.Observed -eq 'Diverged') -and ($s.Shortcut.Created -eq $true) -and ($s.Shortcut.PreExisted -eq $false) -and ($s.Shortcut.Facts.TargetPath -eq 'C:\app\a.exe') -and (@($s.Shortcut.Backups).Count -eq 0)) 'Diverged keeps what we recorded (not what the user edited it into)')
    # 7 a shortcut at another path: the earlier one is not forgotten
    $s = Merge (SPrev ([pscustomobject]@{ Requested = $true; Created = $true; Path = 'C:\Desk\elsewhere.lnk'; PreExisted = $true; Backup = 'C:\old.bak'; BackupSHA256 = 'O'; Backups = [object[]]@() })) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'Add' $false '' '' $fa)
    [void](Assert-I2A 'U5-shortcut-other-path-keeps-earlier' (($s.Shortcut.Path -eq 'C:\Desk\a.lnk') -and ($s.Shortcut.PreExisted -eq $false) -and (@($s.Shortcut.Earlier).Count -eq 1) -and ($s.Shortcut.Earlier[0].Path -eq 'C:\Desk\elsewhere.lnk') -and ($s.Shortcut.Earlier[0].PreExisted -eq $true)) 'the record of the other shortcut moves to Earlier[] with its own origin')
    # 8 unknown fields of an earlier record survive
    $sc9 = [pscustomobject]@{ Requested = $true; Created = $true; Path = 'C:\Desk\a.lnk'; PreExisted = $false; Backup = ''; BackupSHA256 = ''; FutureField = 'keep' }
    $s = Merge (SPrev $sc9) @((E 'Core' 'Application' 'Add' $d1)) @{} (SInfo 'Unchanged' $true '' '' $fa)
    [void](Assert-I2A 'U5-shortcut-unknown-fields-kept' ($s.Shortcut.FutureField -eq 'keep') 'fields written by a later schema survive the merge')
    $bytes = ConvertTo-DenGoStateBytes $s
    $parsed = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
    [void](Assert-I2A 'U5-state-bytes-roundtrip' (($bytes[0] -eq 0xEF) -and ([int]$parsed.SchemaVersion -eq 1) -and (@($parsed.Files).Count -eq 1)) 'UTF-8 with BOM, valid JSON, SchemaVersion 1')

    # =================================================== U6 previous state
    $sandbox2 = New-I2BScenario 'prev' 'P2'
    try {
        $lay = $sandbox2.Product
        $r = Read-DenGoPreviousState $lay
        [void](Assert-I2A 'U6-valid' (($r.Exists -eq $true) -and ($r.Sha.Length -eq 64) -and (@($r.Files).Count -ge 10)) ('files=' + @($r.Files).Count))
        $none = Read-DenGoPreviousState $L.Product
        [void](Assert-I2A 'U6-missing' (($none.Exists -eq $false) -and ($none.Sha -eq '') -and (@($none.Files).Count -eq 0)) 'no state file')
        function Try-Read($Layout) { try { [void](Read-DenGoPreviousState $Layout); return 'OK' } catch { return (DgError-Code $_.Exception) } }
        $sp = $lay.StatePath
        $orig = [System.IO.File]::ReadAllBytes($sp)
        [System.IO.File]::WriteAllText($sp, '{ not json', $utf8)
        [void](Assert-I2A 'U6-corrupt' ((Try-Read $lay) -eq 'InstalledStateUnreadable') 'corrupt JSON')
        [System.IO.File]::WriteAllText($sp, '{"SchemaVersion":2,"Files":[]}', $utf8)
        [void](Assert-I2A 'U6-schema' ((Try-Read $lay) -eq 'InstalledStateUnreadable') 'SchemaVersion 2')
        [System.IO.File]::WriteAllText($sp, '{"SchemaVersion":1,"Files":[{"Platform":"x"}]}', $utf8)
        [void](Assert-I2A 'U6-record-without-destination' ((Try-Read $lay) -eq 'InstalledStateUnreadable') 'record without Destination')
        [System.IO.File]::WriteAllText($sp, '{"SchemaVersion":1,"Files":[{"Destination":"C:\\a"},{"Destination":"c:\\A"}]}', $utf8)
        [void](Assert-I2A 'U6-duplicate-destination' ((Try-Read $lay) -eq 'InstalledStateAmbiguous') 'the same destination twice (case-insensitive)')
        [System.IO.File]::WriteAllBytes($sp, [byte[]]@())
        [void](Assert-I2A 'U6-empty-file' ((Try-Read $lay) -eq 'InstalledStateUnreadable') 'empty file')
        [System.IO.File]::WriteAllBytes($sp, $orig)
        [void](Assert-I2A 'U6-restored' ((Try-Read $lay) -eq 'OK') 'valid again')
    } finally { Remove-I2ASandbox $sandbox2.Root }

    # =================================================== U7 failure mapping
    function Map($Code, $Rb, $Failed = -1, $Reasons = @(), $Manual = $false) { return (ConvertTo-DenGoEngineFailure ([pscustomobject]@{ Code = $Code; Message = 'm'; RollbackState = $Rb; FailedItem = $Failed; Reasons = [object[]]@($Reasons); ManualCheckRequired = $Manual }) 'BVE5') }
    [void](Assert-I2A 'U7-plan-stale-a' ((Map 'PlanStale' 'RolledBack').ErrorCode -eq 'PlanStale') 'before any item')
    [void](Assert-I2A 'U7-plan-stale-b' ((Map 'PlanStale' 'RepairRequired' 3 @() $true).ErrorCode -eq 'DestinationChangedDuringApply') 'during apply')
    [void](Assert-I2A 'U7-rollback-changed' ((Map 'ApplyFailed' 'RollbackIncomplete' 2 @([pscustomobject]@{ Code = 'DestinationChangedAfterPreflight'; Item = 1; Detail = 'x' }) $true).ErrorCode -eq 'DestinationChangedDuringRollback') 'during rollback')
    [void](Assert-I2A 'U7-repair' ((Map 'ApplyFailed' 'RepairRequired' 2 @() $true).ErrorCode -eq 'RecoveryRequired') 'repair required')
    [void](Assert-I2A 'U7-apply-failed' (((Map 'ApplyFailed' 'RolledBack' 2).ErrorCode -eq 'SetApplyFailed') -and ((Map 'ApplyFailed' 'RolledBack' 2).RollbackSucceeded -eq $true) -and ((Map 'ApplyFailed' 'RolledBack' 2).FailedSet -eq 'BVE5')) 'legacy code kept')
    [void](Assert-I2A 'U7-commit-failed' (((Map 'CommitFailed' 'RepairRequired' -1).ErrorCode -eq 'RecoveryRequired') -and ((Map 'StateBuildFailed' 'RolledBack').ErrorCode -eq 'InstalledStateWriteFailed') -and ((Map 'StateBuildFailed' 'RolledBack').FailedSet -eq 'InstallerState')) 'state failures')
    [void](Assert-I2A 'U7-plan-invalid' (((Map 'PlanInvalid' 'NotStarted').ErrorCode -eq 'PlanInvalid') -and ((Map 'PathRejected' 'RolledBack').ErrorCode -eq 'PlanInvalid')) 'plan / path')
    [void](Assert-I2A 'U7-blocked' ((Map 'BlockedByRunningProcesses' 'RolledBack').ErrorCode -eq 'BlockedByRunningProcesses') 'process gate B keeps its code')
    [void](Assert-I2A 'U7-rollback-flags' (((Map 'ApplyFailed' 'RolledBack').RollbackAttempted -eq $true) -and ((Map 'PlanInvalid' 'NotStarted').RollbackAttempted -eq $false) -and ((Map 'ApplyFailed' 'RollbackIncomplete').RollbackSucceeded -eq $false)) 'RollbackAttempted / RollbackSucceeded')

    # =================================================== U8 recovery-gate decisions that need no journal
    $g = New-I2BScenario 'gate' 'P1'
    try {
        $lay = $g.Product
        [System.IO.Directory]::CreateDirectory($lay.StateRoot) | Out-Null
        $inst = Join-Path $lay.StateRoot 'installing.json'
        $unin = Join-Path $lay.StateRoot 'uninstalling.json'
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-no-marker' (($r.Proceed -eq $true) -and ($r.Outcome -eq 'NotNeeded')) 'nothing to recover')
        [System.IO.File]::WriteAllText($inst, '{"SchemaVersion":1,"ProductVersion":"2.0.0","State":"Installing","Started":"2026-01-01T00:00:00+09:00"}', $utf8)
        $before = Get-I2BFullTree $g
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-legacy-marker' (($r.Proceed -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.Reasons[0].Code -eq 'LegacyMarkerUnsupported') -and ($r.ManualCheckRequired -eq $true)) ('reason=' + $r.Reasons[0].Code))
        [void](Assert-I2A 'U8-legacy-marker-untouched' (Same $before (Get-I2BFullTree $g)) 'the old marker is neither deleted nor converted; nothing is written')
        [System.IO.File]::WriteAllText($inst, '{"State":"Installing"}', $utf8)
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-legacy-marker-minimal' ($r.Reasons[0].Code -eq 'LegacyMarkerUnsupported') 'a minimal old marker is also legacy')
        [System.IO.File]::WriteAllText($inst, 'not json at all', $utf8)
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-unreadable-marker' ($r.Reasons[0].Code -eq 'MarkerUnreadable') 'unreadable marker')
        [System.IO.File]::WriteAllText($inst, '{"TxnId":"not a valid id!","Operation":"Install","SchemaVersion":1}', $utf8)
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-marker-bad-id' ($r.Reasons[0].Code -eq 'MarkerUnreadable') 'a marker with an invalid transaction id')
        [System.IO.File]::WriteAllText($unin, '{}', $utf8)
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-multiple-markers' ($r.Reasons[0].Code -eq 'MultipleMarkers') 'both markers')
        [System.IO.File]::Delete($inst)
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-uninstalling-marker' ($r.Reasons[0].Code -eq 'ForeignOperationMarker') 'an install does not recover an uninstall')
        [System.IO.File]::Delete($unin)
        # a marker whose journal is missing: the core reports it, nothing is changed
        [System.IO.File]::WriteAllText($inst, '{"TxnId":"20261015T000000Z-aaaaaaaa","Operation":"Install","SchemaVersion":1,"State":"Installing","StateRoot":"x","BackupRoot":"y","JournalPath":"z"}', $utf8)
        $before = Get-I2BFullTree $g
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-marker-without-journal' (($r.Proceed -eq $false) -and ($r.ErrorCode -eq 'RecoveryRequired') -and ($r.Reasons.Count -ge 1)) ('reason=' + $r.Reasons[0].Code))
        [void](Assert-I2A 'U8-marker-without-journal-untouched' (Same $before (Get-I2BFullTree $g)) 'no change')
        $r = Get-DenGoRecoveryGate $lay 'DryRun'
        [void](Assert-I2A 'U8-dryrun-writes-nothing' (($r.Outcome -eq 'RepairRequired') -and (Same $before (Get-I2BFullTree $g))) 'the dry run reports and writes nothing')
        [System.IO.File]::Delete($inst)
        $r = Get-DenGoRecoveryGate $lay 'DryRun'
        [void](Assert-I2A 'U8-dryrun-clean' (($r.Outcome -eq 'NotNeeded') -and ($r.Proceed -eq $true)) 'dry run without a marker')
        # orphan marker temporaries are cleaned by the recovery gate (core behaviour), nothing else
        [System.IO.File]::WriteAllText((Join-Path $lay.StateRoot 'installing.json.tmp'), 'x', $utf8)
        $r = Get-DenGoRecoveryGate $lay 'Apply'
        [void](Assert-I2A 'U8-orphan-marker-tmp-cleaned' (($r.Proceed -eq $true) -and -not [System.IO.File]::Exists((Join-Path $lay.StateRoot 'installing.json.tmp'))) 'installing.json.tmp removed')
    } finally { Remove-I2ASandbox $g.Root }

    # =================================================== U9 staged shortcut
    $s1 = New-DenGoStagedShortcut $P $L.Stage
    $s2 = New-DenGoStagedShortcut $P $L.Stage
    [void](Assert-I2A 'U9-stage-ok' (($s1.Ok -eq $true) -and ($s1.Action -eq 'Add') -and [System.IO.File]::Exists($s1.StagePath)) ('error=' + $s1.Error))
    [void](Assert-I2A 'U9-stage-deterministic' (($s2.Ok -eq $true) -and ($s1.Sha -eq $s2.Sha) -and ($s1.StageDir -ne $s2.StageDir)) 'two stagings give identical bytes (so an existing equal shortcut is detected by SHA)')
    [void](Assert-I2A 'U9-stage-target-not-created' (-not [System.IO.Directory]::Exists($P.AppDir)) 'staging does not create the application folder')
    Remove-DenGoStagedShortcut $s1 $L.Stage; Remove-DenGoStagedShortcut $s2 $L.Stage
    [void](Assert-I2A 'U9-stage-cleaned' ((@(Test-I2BLeftovers $L)).Count -eq 0) 'stage folders removed')
    $foreign = Join-Path $L.Stage 'someone-elses-folder'
    [System.IO.Directory]::CreateDirectory($foreign) | Out-Null
    Remove-DenGoStagedShortcut ([pscustomobject]@{ StageDir = $foreign }) $L.Stage
    [void](Assert-I2A 'U9-stage-cleanup-guard' ([System.IO.Directory]::Exists($foreign)) 'a folder without the stage prefix is never removed')
    Remove-Item -LiteralPath $foreign -Force
    $outside = Join-Path $L.Guard 'DenGoShortcutStage-x'
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    Remove-DenGoStagedShortcut ([pscustomobject]@{ StageDir = $outside }) $L.Stage
    [void](Assert-I2A 'U9-stage-cleanup-parent-guard' ([System.IO.Directory]::Exists($outside)) 'a stage-named folder under another parent is never removed')
    Remove-Item -LiteralPath $outside -Force
    $nodesk = Get-DenGoProductLayout -LocalAppData $L.Local -PublicRoot $L.Public -ShortcutPath (Join-Path $L.Root 'NoDesktop\a.lnk')
    $s3 = New-DenGoStagedShortcut $nodesk $L.Stage
    [void](Assert-I2A 'U9-stage-folder-missing' (($s3.Ok -eq $false) -and ($s3.Error -eq 'ShortcutFolderMissing')) ('error=' + $s3.Error))
    $s4 = New-DenGoStagedShortcut (Get-DenGoProductLayout -LocalAppData $L.Local -PublicRoot $L.Public) $L.Stage
    [void](Assert-I2A 'U9-stage-unconfigured' (($s4.Ok -eq $false) -and ($s4.Error -eq 'ShortcutPathUnavailable')) ('error=' + $s4.Error))
    # an existing identical shortcut is "Unchanged"
    $s5 = New-DenGoStagedShortcut $P $L.Stage
    [System.IO.File]::Copy($s5.StagePath, $P.ShortcutPath, $true)
    $s6 = New-DenGoStagedShortcut $P $L.Stage
    [void](Assert-I2A 'U9-existing-equal-is-unchanged' (($s6.Ok -eq $true) -and ($s6.Action -eq 'Unchanged')) ('action=' + $s6.Action))
    [System.IO.File]::WriteAllText($P.ShortcutPath, 'someone elses shortcut', $utf8)
    $s7 = New-DenGoStagedShortcut $P $L.Stage
    [void](Assert-I2A 'U9-existing-different-is-update' (($s7.Ok -eq $true) -and ($s7.Action -eq 'UpdateOrRepair') -and ($s7.ExistingSha.Length -eq 64)) ('action=' + $s7.Action))
    foreach ($st in $s5, $s6, $s7) { Remove-DenGoStagedShortcut $st $L.Stage }
    [System.IO.File]::Delete($P.ShortcutPath)
    # a reparse point below the Desktop root rejects the shortcut (Reject contract); simulated through the primitive
    $origReparse = (Get-Command DgFs-GetReparseComponents -CommandType Function).ScriptBlock
    Set-Item -Path 'function:script:DgFs-GetReparseComponents' -Value { param([string]$Path, [string]$Root) return ,([string[]]@($Path)) }
    try { $s8 = New-DenGoStagedShortcut $P $L.Stage } finally { Set-Item -Path 'function:script:DgFs-GetReparseComponents' -Value $origReparse }
    [void](Assert-I2A 'U9-reparse-rejected' (($s8.Ok -eq $false) -and ($s8.Error -like 'ShortcutPathRejected*')) ('error=' + $s8.Error))
    [void](Assert-I2A 'U9-reparse-nothing-staged' ($s8.StageDir -eq '') 'nothing was created before the policy check')

    # an earlier install of this very shortcut (its target existed when it was saved) has other bytes but says the same: it is left alone
    [System.IO.Directory]::CreateDirectory($P.AppDir) | Out-Null
    [System.IO.File]::WriteAllText($P.AppExe, 'app', $utf8); [System.IO.File]::WriteAllText($P.AppIco, 'ico', $utf8)
    try {
        DgPFs-NewShortcutFile $P.ShortcutPath $P.AppExe $P.AppDir ($P.AppIco + ',0')
        $s9 = New-DenGoStagedShortcut $P $L.Stage
        [void](Assert-I2A 'U9-earlier-install-of-the-same-shortcut-is-unchanged' (($s9.Ok -eq $true) -and ($s9.Action -eq 'Unchanged')) ("action=$($s9.Action); bytes equal=$($s9.Sha -eq $s9.ExistingSha) (the bytes depend on whether the target existed when the shortcut was saved, so the content decides)"))
        Remove-DenGoStagedShortcut $s9 $L.Stage
        [System.IO.File]::Delete($P.ShortcutPath)
        DgPFs-NewShortcutFile $P.ShortcutPath (Join-Path $L.Guard 'g1.txt') $L.Guard ((Join-Path $L.Guard 'g1.txt') + ',0')
        $s10 = New-DenGoStagedShortcut $P $L.Stage
        [void](Assert-I2A 'U9-shortcut-to-another-target-is-replaced-with-a-backup' (($s10.Ok -eq $true) -and ($s10.Action -eq 'UpdateOrRepair')) ("action=$($s10.Action)"))
        Remove-DenGoStagedShortcut $s10 $L.Stage
        # F2: the staged shortcut says what it says (the identity that is recorded in the state)
        [void](Assert-I2A 'U9-staged-facts' (($s10.Facts.TargetPath -eq $P.AppExe) -and ($s10.Facts.WorkingDirectory -eq $P.AppDir) -and ($s10.Facts.IconLocation -eq ($P.AppIco + ',0'))) ('facts=' + $s10.Facts.TargetPath))
        # F2: a shortcut that this product created (recorded with its facts) and that now says something else was edited: Diverged, never replaced
        $oursFacts = [pscustomobject]@{ TargetPath = $P.AppExe; WorkingDirectory = $P.AppDir; IconLocation = ($P.AppIco + ',0') }
        function PrevSc($Sc) { return [pscustomobject]@{ Exists = $true; State = [pscustomobject]@{ Shortcut = [pscustomobject]$Sc } } }
        $sD = New-DenGoStagedShortcut $P $L.Stage (PrevSc @{ Created = $true; Path = $P.ShortcutPath; Facts = $oursFacts })
        [void](Assert-I2A 'U9-edited-shortcut-is-diverged' (($sD.Ok -eq $true) -and ($sD.Action -eq 'Diverged')) ("action=$($sD.Action): the lnk now points to another target than the one recorded"))
        Remove-DenGoStagedShortcut $sD $L.Stage
        $nowFacts = DgPFs-ReadShortcut $P.ShortcutPath
        $sS = New-DenGoStagedShortcut $P $L.Stage (PrevSc @{ Created = $true; Path = $P.ShortcutPath; Facts = $nowFacts })
        [void](Assert-I2A 'U9-our-older-shortcut-is-updated' (($sS.Ok -eq $true) -and ($sS.Action -eq 'UpdateOrRepair')) ("action=$($sS.Action): the lnk still says what we recorded, it is only older"))
        Remove-DenGoStagedShortcut $sS $L.Stage
        $sN = New-DenGoStagedShortcut $P $L.Stage (PrevSc @{ Created = $true; Path = $P.ShortcutPath })
        [void](Assert-I2A 'U9-record-without-facts-is-updated' (($sN.Ok -eq $true) -and ($sN.Action -eq 'UpdateOrRepair')) ("action=$($sN.Action): an old-format record cannot prove an edit"))
        Remove-DenGoStagedShortcut $sN $L.Stage
        $sP = New-DenGoStagedShortcut $P $L.Stage (PrevSc @{ Created = $true; Path = (Join-Path $L.Guard 'x.lnk'); Facts = $oursFacts })
        [void](Assert-I2A 'U9-record-of-another-path-is-no-authority' (($sP.Ok -eq $true) -and ($sP.Action -eq 'UpdateOrRepair')) ("action=$($sP.Action)"))
        Remove-DenGoStagedShortcut $sP $L.Stage
        $sC = New-DenGoStagedShortcut $P $L.Stage (PrevSc @{ Created = $false; Path = $P.ShortcutPath; Facts = $oursFacts })
        [void](Assert-I2A 'U9-record-without-creation-is-no-authority' (($sC.Ok -eq $true) -and ($sC.Action -eq 'UpdateOrRepair')) ("action=$($sC.Action)"))
        Remove-DenGoStagedShortcut $sC $L.Stage
        [System.IO.File]::WriteAllText($P.ShortcutPath, 'not a shortcut at all', $utf8)
        $sU = New-DenGoStagedShortcut $P $L.Stage (PrevSc @{ Created = $true; Path = $P.ShortcutPath; Facts = $oursFacts })
        [void](Assert-I2A 'U9-unreadable-edit-is-diverged' (($sU.Ok -eq $true) -and ($sU.Action -eq 'Diverged')) ("action=$($sU.Action)"))
        Remove-DenGoStagedShortcut $sU $L.Stage
        # F1: a Desktop folder that is a reparse point is refused before anything is staged
        $jDesk = Join-Path $L.Root 'JuncDesk2'
        New-Item -ItemType Junction -Path $jDesk -Target $L.Guard | Out-Null
        try {
            $jl = Get-DenGoProductLayout -LocalAppData $L.Local -PublicRoot $L.Public -ShortcutPath (Join-Path $jDesk 'DenGo Controller Converter.lnk')
            $sJ = New-DenGoStagedShortcut $jl $L.Stage
            [void](Assert-I2A 'U9-junction-desktop-is-rejected' (($sJ.Ok -eq $false) -and ($sJ.Error -eq 'ShortcutPathRejected: ShortcutRootReparse') -and ($sJ.StageDir -eq '')) ("error=$($sJ.Error)"))
        } finally { [System.IO.Directory]::Delete($jDesk) }
    } finally {
        foreach ($x in $P.ShortcutPath, $P.AppExe, $P.AppIco) { if ([System.IO.File]::Exists($x)) { [System.IO.File]::Delete($x) } }
        [System.IO.Directory]::Delete($P.AppDir)
    }
    # a backup root override (tests only) gets its own policy root; the default backup folder is then no longer allowed
    $ov = Get-DenGoProductLayout -LocalAppData $L.Local -PublicRoot $L.Public -BackupRoot (Join-Path $L.Root 'OtherBackups')
    $polO = New-DenGoPathPolicy $ov
    [void](Assert-I2A 'U9-backup-override-policy' ((DgPolicy-TestPath $polO $ov.BackupRoot).Allowed -and (DgPolicy-TestPath $polO $ov.StateRoot).Allowed -and ($polO.AllowedRoots.Count -eq 2)) ('roots=' + ($polO.AllowedRoots -join ';')))
    [void](Assert-I2A 'U9-backup-override-gate' ((Test-DenGoLeafGate $ov 'App' '' $ov.BackupRoot 'Infra').Allowed -and -not (Test-DenGoLeafGate $ov 'App' '' (Join-Path $ov.DataRoot 'InstallerBackups') 'Infra').Allowed) 'only the override is an allowed backup root')
    # =================================================== U10 AllowEmptyTransaction in the core
    $root = New-I2ASandbox 'empty-unit'
    try {
        $lay = New-I2AFixture $root 'F4'
        $items = @()
        $r = DgTx-Run -StateRoot $lay.State -BackupRoot $lay.Backup -Operation 'Install' -Items $items -Policy $lay.Policy -NewStatePath $lay.StatePath -NewStateBytes $lay.NewStateBytes
        [void](Assert-I2A 'U10-default-refuses-empty' (($r.Succeeded -eq $false) -and ($r.Code -eq 'PlanInvalid') -and ($r.Message -like '*No items*')) ("code=$($r.Code) msg=$($r.Message)"))
        $before = Get-I2ATreeMap $root
        [void](Assert-I2A 'U10-default-refusal-wrote-nothing' (-not [System.IO.Directory]::Exists((Join-Path $lay.State 'txn'))) 'no transaction folder was created')
        $r = DgTx-Run -StateRoot $lay.State -BackupRoot $lay.Backup -Operation 'Install' -Items $items -Policy $lay.Policy -NewStatePath $lay.StatePath -NewStateBytes $lay.NewStateBytes -AllowEmptyTransaction
        [void](Assert-I2A 'U10-flag-without-factory-refused' (($r.Succeeded -eq $false) -and ($r.Code -eq 'PlanInvalid') -and ($r.Message -like '*NewStateFactory*')) ("code=$($r.Code) msg=$($r.Message)"))
        [void](Assert-I2A 'U10-flag-without-factory-wrote-nothing' (Same $before (Get-I2ATreeMap $root)) 'nothing changed')
        $thr = ''; try { [void](DgTx-Begin $lay.State $lay.Backup 'Install' @() $lay.Policy $lay.StatePath) } catch { $thr = DgError-Code $_.Exception }
        [void](Assert-I2A 'U10-begin-default-refuses' ($thr -eq 'PlanInvalid') "code=$thr")
        $factory = { param($c) return ,((New-Object System.Text.UTF8Encoding($false)).GetBytes('state-empty-v2')) }
        $r = DgTx-Run -StateRoot $lay.State -BackupRoot $lay.Backup -Operation 'Install' -Items $items -Policy $lay.Policy -NewStatePath $lay.StatePath -NewStateFactory $factory -AllowEmptyTransaction
        [void](Assert-I2A 'U10-flag-with-factory-commits' (($r.Succeeded -eq $true) -and ([System.IO.File]::ReadAllText($lay.StatePath) -eq 'state-empty-v2') -and (@(Test-I2ANoLeftovers $lay).Count -eq 0)) ("code=$($r.Code); the state file is replaced atomically through the full commit"))
        $hist = @([System.IO.Directory]::GetFiles((Join-Path $lay.State 'history'), '*.committed.jsonl'))
        $stages = @((DgJournal-Parse $hist[0]).Records | ForEach-Object { $_.stage })
        [void](Assert-I2A 'U10-empty-journal-stages' (($stages -join ',') -eq 'Begin,CommitIntent,Committed') ('stages=' + ($stages -join ',')))
    } finally { Remove-I2ASandbox $root }

    # =================================================== U11 lock helper
    $name1 = Get-DenGoLockName
    [void](Assert-I2A 'U11-lock-name-is-common' ($name1.Length -gt 0) "name=$name1")
    $a = DgLock-TryAcquire (Get-DenGoLockName) 'Explicit'
    $dup = Invoke-I2BInstall $L $plan $false
    [void](Assert-I2A 'U11-second-acquire-in-process-is-busy' (($a.Acquired -eq $true) -and ($dup.Succeeded -eq $false) -and ($dup.ErrorCode -eq 'AnotherOperationRunning') -and ($dup.LockAcquired -eq $false)) ('code=' + $dup.ErrorCode))
    [void](Assert-I2A 'U11-busy-writes-nothing' (-not [System.IO.Directory]::Exists($P.StateRoot) -and -not [System.IO.Directory]::Exists((Join-Path $P.DataRoot 'InstallerBackups'))) 'no state, journal, marker or backup folder')
    [void](DgLock-Release (Get-DenGoLockName))
    $b = DgLock-TryAcquire (Get-DenGoLockName) 'Explicit'
    [void](Assert-I2A 'U11-released' ($b.Acquired -eq $true) 'the lock can be taken again after a release')
    [void](DgLock-Release (Get-DenGoLockName))
} finally {
    Remove-I2ASandbox $L.Root
}
Complete-I2ATests
