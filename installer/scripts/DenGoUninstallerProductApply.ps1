# DenGo uninstaller product apply layer (I2-C). ASCII only. Functions only; no top-level side effects.
# Dot-source DenGoInstallerTransaction.ps1 and DenGoInstallerProductApply.ps1 FIRST (this layer reuses their helpers and never changes them).
#
# Contract summary
#   - One all-or-nothing transaction (Operation = Uninstall). The commit point is the atomic replace of uninstalled-state.json.
#   - installed-state.json is copied to history\installed-state.<sha256>.json and then deleted INSIDE the same transaction (the last item):
#     a failure before the commit point rolls everything back, a failure after it rolls forward. There is no marker-less "archive pending" window.
#   - Only fixed DenGo leaves below proven roots are ever touched. Anything that is not a DenGo leaf stops the run with zero changes.
#   - Restore uses the Origin backup only (Backup == Backups[0] for transaction backups); Backups[1..] are never a restore source;
#     the backup of a closed generation is never used by a newer generation.
#   - PCSX2 / LilyPad records are deferred (I3): never read, restored, deleted or moved to ClosedRecords. ClosedRecords are never applied.
#   - A user-owned file that is intentionally left behind is a residual (Completed is allowed). A DenGo-owned item that cannot be resolved
#     (unproven root, invalid Origin, contamination that blocks a restore, unknown ownership) fails the run with zero changes.
#   - A recovery that only succeeded (RolledBack / RolledForward) is never a completed uninstall: Failed + RecoveryCompletedOperationNotCompleted.

function DgU-SetOrder { return @('RPCS3','AtsEX Legacy','BveEX Current','BVE6','BVE5','Core') }
function DgU-OwnershipNames { return @('CreatedByInstaller','MigratedMatchingDenGoFile','ReplacedExisting','PreservedUserFile','NotInstalled','NotManaged') }
function DgU-ArchivePattern { return '^(installed|uninstalled)-state\.[0-9a-f]{64}\.json$' }
function DgU-IsHex64 { param([string]$Text) return ($Text -match '^[0-9A-Fa-f]{64}$') }
function DgU-HistoryDir { param([object]$Layout) return (DgP-Join $Layout.StateRoot 'history') }
function DgU-UninstalledStatePath { param([object]$Layout) return (DgP-Join $Layout.StateRoot 'uninstalled-state.json') }
function DgU-ArchiveName { param([string]$Kind,[string]$Sha) return ($Kind + '-state.' + $Sha.ToLowerInvariant() + '.json') }
function DgU-AsList {
    param([object]$Value)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Value) { return ,[object[]]@() }
    foreach ($v in @($Value)) { if ($null -ne $v) { [void]$out.Add($v) } }
    return ,[object[]]@($out)
}
function DgU-PathEqSafe {
    param([string]$A,[string]$B)
    try { if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }; return (DgP-PathEq $A $B) } catch { return $false }
}

# ---------------------------------------------------------------- roles and the leaf gate (uninstall side)
# StateDelete / StateArchive are uninstall-only roles. The install roles are reused as they are (Get-DenGoRoleSpec).
function Get-DenGoUninstallRoleSpec {
    param([object]$Layout,[string]$Role,[string]$Root = '')
    if (DgEq $Role 'StateDelete') {
        return [pscustomobject]@{ Ok = $true; Reason = ''; Role = $Role; PolicyRoot = [string]$Layout.LocalAppData; Dests = [string[]]@([string]$Layout.StatePath); Dirs = [string[]]@() }
    }
    if (DgEq $Role 'StateArchive') {
        if (-not ($Root -cmatch (DgU-ArchivePattern))) { return [pscustomobject]@{ Ok = $false; Reason = 'ArchiveNameInvalid'; Role = $Role; PolicyRoot = ''; Dests = [string[]]@(); Dirs = [string[]]@() } }
        $hist = DgU-HistoryDir $Layout
        return [pscustomobject]@{ Ok = $true; Reason = ''; Role = $Role; PolicyRoot = [string]$Layout.LocalAppData; Dests = [string[]]@((DgP-Join $hist $Root)); Dirs = [string[]]@($hist) }
    }
    return (Get-DenGoRoleSpec $Layout $Role $Root)
}
function DgU-InfraGate {
    param([object]$Layout,[string]$Full,[string]$TxnId)
    $s = $Layout.StateRoot; $b = $Layout.BackupRoot
    $us = DgU-UninstalledStatePath $Layout
    $exact = @($Layout.DataRoot,$s,(DgP-Join $s 'txn'),(DgP-Join $s 'history'),$b,$us,($us + '.tmp'),
        (DgP-Join $s 'installing.json'),(DgP-Join $s 'installing.json.tmp'),(DgP-Join $s 'uninstalling.json'),(DgP-Join $s 'uninstalling.json.tmp'))
    if (DgP-InSet $Full $exact) { return (DgP-Gate $true '') }
    $parent = [System.IO.Path]::GetDirectoryName($Full)
    if ([string]::IsNullOrEmpty($parent)) { return (DgP-Gate $false 'LeafNotAllowed') }
    $leaf = [System.IO.Path]::GetFileName($Full)
    $idOk = { param($id) return (($id -cmatch $Layout.TxnIdPattern) -and (($TxnId.Length -eq 0) -or (DgEq $id $TxnId))) }
    if (DgP-PathEq $parent (DgP-Join $s 'txn')) { if (& $idOk $leaf) { return (DgP-Gate $true '') } }
    $gp = [System.IO.Path]::GetDirectoryName($parent)
    if (-not [string]::IsNullOrEmpty($gp) -and (DgP-PathEq $gp (DgP-Join $s 'txn'))) {
        if ((& $idOk ([System.IO.Path]::GetFileName($parent))) -and ((DgEq $leaf 'journal.jsonl') -or (DgEq $leaf 'recovery-report.txt'))) { return (DgP-Gate $true '') }
    }
    if (DgP-PathEq $parent (DgP-Join $s 'history')) {
        $m = [System.Text.RegularExpressions.Regex]::Match($leaf,'^txn-(.+)\.(committed|rolledback)\.jsonl$')
        if ($m.Success -and (& $idOk $m.Groups[1].Value)) { return (DgP-Gate $true '') }
    }
    if (DgP-PathEq $parent $b) { if (& $idOk $leaf) { return (DgP-Gate $true '') } }
    return (DgP-Gate $false 'LeafNotAllowed')
}
# Kind: Dest | Tmp | Dir | Backup | Infra
function Test-DenGoUninstallLeafGate {
    param([object]$Layout,[string]$Role,[string]$Root,[string]$Path,[string]$Kind,[string]$TxnId = '')
    $c = DgPath-Check $Path
    if (-not $c.Ok) { return (DgP-Gate $false $c.Reason) }
    $full = DgP-Full $c.Normalized
    if (DgEq $Kind 'Infra') { return (DgU-InfraGate $Layout $full $TxnId) }
    if (DgEq $Kind 'Backup') { return (DgP-BackupGate $Layout $full $TxnId) }
    if (-not ((DgEq $Kind 'Dest') -or (DgEq $Kind 'Tmp') -or (DgEq $Kind 'Dir'))) { return (DgP-Gate $false 'KindUnknown') }
    $spec = Get-DenGoUninstallRoleSpec $Layout $Role $Root
    if (-not $spec.Ok) { return (DgP-Gate $false $spec.Reason) }
    if (DgEq $Kind 'Dest') { if (DgP-InSet $full $spec.Dests) { return (DgP-Gate $true '') } return (DgP-Gate $false 'LeafNotAllowed') }
    if (DgEq $Kind 'Dir') { if (DgP-InSet $full $spec.Dirs) { return (DgP-Gate $true '') } return (DgP-Gate $false 'LeafNotAllowed') }
    $suffix = DgConst-TmpSuffix
    if ($full.EndsWith($suffix,[System.StringComparison]::OrdinalIgnoreCase)) {
        $base = $full.Substring(0,$full.Length - $suffix.Length)
        if (DgP-InSet $base $spec.Dests) { return (DgP-Gate $true '') }
    }
    return (DgP-Gate $false 'LeafNotAllowed')
}
# Gate for the journaled facts of one item (BeginCheck and recovery). Returns the list of failures.
function Test-DenGoUninstallItemGate {
    param([object]$Layout,[string]$Tag,[string]$Norm,[string]$Tmp,[string[]]$Dirs,[string]$Backup,[string]$TxnId)
    $failures = New-Object System.Collections.ArrayList
    $t = DgP-ParseTag $Tag
    if ($null -eq $t) { [void]$failures.Add('TagInvalid: ' + $Tag); return ,[string[]]@($failures) }
    $g = Test-DenGoUninstallLeafGate $Layout $t.Role $t.Root $Norm 'Dest'
    if (-not $g.Allowed) { [void]$failures.Add('Dest ' + $g.Reason + ': ' + $Norm) }
    $g = Test-DenGoUninstallLeafGate $Layout $t.Role $t.Root $Tmp 'Tmp'
    if (-not $g.Allowed) { [void]$failures.Add('Tmp ' + $g.Reason + ': ' + $Tmp) }
    foreach ($d in @($Dirs)) {
        $g = Test-DenGoUninstallLeafGate $Layout $t.Role $t.Root $d 'Dir'
        if (-not $g.Allowed) { [void]$failures.Add('Dir ' + $g.Reason + ': ' + $d) }
    }
    if ($Backup.Length -gt 0) {
        $g = Test-DenGoUninstallLeafGate $Layout $t.Role $t.Root $Backup 'Backup' $TxnId
        if (-not $g.Allowed) { [void]$failures.Add('Backup ' + $g.Reason + ': ' + $Backup) }
    }
    return ,[string[]]@($failures)
}
# Read-only source gate for the Origin backup: a transaction backup (BackupRoot\<TxnId>\NNNN.bak) or a legacy backup
# (BackupRoot\<yyyyMMdd-HHmmss>\<32 hex>.bak). Nothing else, and never through a reparse point.
function Test-DenGoUninstallSourceGate {
    param([object]$Layout,[string]$Path)
    $r = [pscustomobject]@{ Allowed = $false; Reason = ''; Format = ''; TxnId = ''; Full = '' }
    $c = DgPath-Check $Path
    if (-not $c.Ok) { $r.Reason = $c.Reason; return $r }
    $full = DgP-Full $c.Normalized
    $r.Full = $full
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrEmpty($parent)) { $r.Reason = 'LeafNotAllowed'; return $r }
    $gp = [System.IO.Path]::GetDirectoryName($parent)
    if ([string]::IsNullOrEmpty($gp) -or -not (DgP-PathEq $gp $Layout.BackupRoot)) { $r.Reason = 'NotUnderBackupRoot'; return $r }
    $folder = [System.IO.Path]::GetFileName($parent)
    $leaf = [System.IO.Path]::GetFileName($full)
    if (($folder -cmatch $Layout.TxnIdPattern) -and ($leaf -cmatch '^[0-9]{4}\.bak$')) { $r.Format = 'Txn'; $r.TxnId = $folder }
    elseif (($folder -cmatch '^[0-9]{8}-[0-9]{6}$') -and ($leaf -cmatch '^[0-9A-Fa-f]{32}\.bak$')) { $r.Format = 'Legacy' }
    else { $r.Reason = 'LeafNotAllowed'; return $r }
    $rp = DgFs-GetReparseComponents $full $Layout.BackupRoot
    if (@($rp).Count -ne 0) { $r.Reason = 'PathReparse'; $r.Format = ''; return $r }
    $r.Allowed = $true
    return $r
}

# ---------------------------------------------------------------- recovery gate (uninstall side)
function DgU-RecoveryPolicy {
    param([object]$Layout,[string]$TxnId)
    $extra = New-Object System.Collections.ArrayList
    $journal = DgP-Join (DgP-Join (DgP-Join $Layout.StateRoot 'txn') $TxnId) 'journal.jsonl'
    if (DgFs-Exists $journal) {
        $parse = DgJournal-Parse $journal
        if (-not $parse.Corrupt) {
            $sum = DgJournal-Summarize $parse
            if ($sum.Ok) {
                foreach ($it in @($sum.Items)) {
                    $t = DgP-ParseTag ([string]$it.Tag)
                    if ($null -eq $t) { return @{ Policy = $null; Rejected = ('Item ' + $it.Id + ': the tag is invalid.') } }
                    $spec = Get-DenGoUninstallRoleSpec $Layout $t.Role $t.Root
                    if (-not $spec.Ok) { return @{ Policy = $null; Rejected = ('Item ' + $it.Id + ': ' + $spec.Reason) } }
                    $fails = Test-DenGoUninstallItemGate $Layout ([string]$it.Tag) ([string]$it.Norm) ([string]$it.Tmp) ([string[]]@($it.Dirs)) ([string]$it.Backup) $TxnId
                    if ($fails.Count -ne 0) { return @{ Policy = $null; Rejected = ('Item ' + $it.Id + ': ' + [string]::Join('; ',$fails)) } }
                    [void]$extra.Add([string]$spec.PolicyRoot)
                }
            }
        }
    }
    try { $policy = New-DenGoPathPolicy $Layout ([string[]]@($extra)) } catch { return @{ Policy = $null; Rejected = ('Policy: ' + [string](DgError-Root $_.Exception).Message) } }
    return @{ Policy = $policy; Rejected = '' }
}
# Read-only evidence for a manual recovery: journal facts joined with the files as they are now. Never throws, never writes.
function Get-DenGoUninstallEvidence {
    param([object]$Layout,[string]$TxnId)
    $out = New-Object System.Collections.ArrayList
    try {
        if ([string]::IsNullOrEmpty($TxnId)) { return ,[object[]]@() }
        $journal = DgP-Join (DgP-Join (DgP-Join $Layout.StateRoot 'txn') $TxnId) 'journal.jsonl'
        if (-not (DgFs-Exists $journal)) { return ,[object[]]@() }
        $parse = DgJournal-Parse $journal
        if ($parse.Corrupt) { return ,[object[]]@([pscustomobject]@{ ItemId = -1; Path = $journal; Note = ('JournalCorrupt: ' + $parse.CorruptReason) }) }
        $sum = DgJournal-Summarize $parse
        if (-not $sum.Ok) { return ,[object[]]@([pscustomobject]@{ ItemId = -1; Path = $journal; Note = ('JournalUnusable: ' + $sum.Reason) }) }
        foreach ($it in @($sum.Items)) {
            $cur = ''
            try { if (DgFs-Exists $it.Norm) { $cur = DgFs-Sha256 $it.Norm } } catch { $cur = '<unreadable>' }
            $bsha = ''
            try { if ($it.Backup.Length -gt 0 -and (DgFs-Exists $it.Backup)) { $bsha = DgFs-Sha256 $it.Backup } elseif ($it.Backup.Length -gt 0) { $bsha = '<missing>' } } catch { $bsha = '<unreadable>' }
            $progress = 'Registered'
            if ($it.HasIntent) { $progress = 'Intent' }
            if ($it.HasApplied) { $progress = 'Applied' }
            if ($it.HasVerified) { $progress = 'Verified' }
            if ($it.HasRollbackIntent) { $progress = 'RollbackIntent' }
            if ($it.HasRolledBack) { $progress = 'RolledBack' }
            [void]$out.Add([pscustomobject]@{ ItemId = [int]$it.Id; Op = [string]$it.Op; Path = [string]$it.Norm; Tag = [string]$it.Tag; ExpectedPreSha = [string]$it.PreSha; ExpectedPostSha = [string]$it.PostSha
                CurrentSha = $cur; BackupPath = [string]$it.Backup; RecordedBackupSha = [string]$it.BackupSha; ActualBackupSha = $bsha; Progress = $progress; Note = '' })
        }
    } catch { }
    return ,[object[]]@($out)
}
function DgU-WithEvidence {
    param([object]$Gate,[object]$Layout)
    $ev = [object[]]@()
    if (-not [bool]$Gate.Proceed -and (@('RepairRequired','RollbackIncomplete','RecoveryPending') -contains [string]$Gate.Outcome)) { $ev = Get-DenGoUninstallEvidence $Layout ([string]$Gate.TransactionId) }
    $Gate | Add-Member -NotePropertyName Evidence -NotePropertyValue ([object[]]@($ev)) -Force
    return $Gate
}
function Get-DenGoUninstallRecoveryGate {
    param([object]$Layout,[string]$Mode = 'Apply')
    $staticPolicy = $null
    try { $staticPolicy = New-DenGoPathPolicy $Layout } catch { return (DgU-WithEvidence (DgP-Repair 'PathRejected' ('Policy: ' + [string](DgError-Root $_.Exception).Message)) $Layout) }
    foreach ($pair in @(@('StateRoot',$Layout.StateRoot),@('BackupRoot',$Layout.BackupRoot))) {
        $t = DgPolicy-TestPath $staticPolicy $pair[1]
        if (-not $t.Allowed) { return (DgU-WithEvidence (DgP-Repair 'PathRejected' ($pair[0] + ' is rejected by the path policy: ' + $t.Reason)) $Layout) }
    }
    $instPath = DgP-Join $Layout.StateRoot 'installing.json'
    $uninPath = DgP-Join $Layout.StateRoot 'uninstalling.json'
    $hasInst = DgFs-Exists $instPath
    $hasUnin = DgFs-Exists $uninPath
    if ($hasInst -and $hasUnin) { return (DgU-WithEvidence (DgP-Repair 'MultipleMarkers' 'Both installing.json and uninstalling.json exist.') $Layout) }
    # an uninstall never recovers an install (the setup does): nothing is deleted, converted or started
    if ($hasInst) { return (DgU-WithEvidence (DgP-Repair 'ForeignOperationMarker' 'installing.json exists; an uninstall does not recover an install. Run the setup to recover it.') $Layout) }
    if ($hasUnin) {
        $marker = DgP-ReadMarker $Layout $uninPath
        if (DgEq $marker.Kind 'Unreadable') { return (DgU-WithEvidence (DgP-Repair 'MarkerUnreadable' 'uninstalling.json cannot be read.') $Layout) }
        if (DgEq $marker.Kind 'Legacy') { return (DgU-WithEvidence (DgP-Repair 'LegacyMarkerUnsupported' 'uninstalling.json has the old format and is neither converted nor deleted.') $Layout) }
        $rp = DgU-RecoveryPolicy $Layout $marker.TxnId
        if ([string]$rp.Rejected -ne '') { return (DgU-WithEvidence (DgP-Repair 'PathRejected' ([string]$rp.Rejected) $marker.TxnId) $Layout) }
        if (DgEq $Mode 'DryRun') {
            $pf = DgTx-Preflight $Layout.StateRoot $Layout.BackupRoot $rp.Policy
            $reasons = [object[]]@($pf.Reasons)
            if ($pf.Ok) { return (DgU-WithEvidence (DgP-GateResult $false 'RecoveryPending' '' 'An interrupted uninstall can be recovered automatically.' @() $pf.Region $marker.TxnId '' $false) $Layout) }
            return (DgU-WithEvidence (DgP-GateResult $false 'RepairRequired' 'RecoveryRequired' 'Recovery is not possible automatically.' $reasons $pf.Region $marker.TxnId '' $true) $Layout)
        }
        $rec = DgTx-Recover $Layout.StateRoot $Layout.BackupRoot $rp.Policy
        if ($rec.Outcome -eq 'RolledBack' -or $rec.Outcome -eq 'RolledForward') {
            return (DgU-WithEvidence (DgP-GateResult $false $rec.Outcome 'RecoveryCompletedOperationNotCompleted' ('An interrupted uninstall was recovered (' + $rec.Outcome + '); this operation was not started.') $rec.Reasons $rec.Region $rec.TransactionId '' $false) $Layout)
        }
        if ($rec.Outcome -eq 'NotNeeded') { return (DgU-WithEvidence (DgP-GateResult $true 'NotNeeded' '' '' @() 'NoMarker' '' '' $false) $Layout) }
        return (DgU-WithEvidence (DgP-GateResult $false $rec.Outcome 'RecoveryRequired' ('Automatic recovery is not possible (' + $rec.Outcome + ').') $rec.Reasons $rec.Region $rec.TransactionId ([string]$rec.ReportPath) ([bool]$rec.ManualCheckRequired)) $Layout)
    }
    $orphan = DgP-FindActiveOrphan $Layout
    if ($null -ne $orphan) { return (DgU-WithEvidence (DgP-Repair $orphan.Code $orphan.Detail) $Layout) }
    if (DgEq $Mode 'DryRun') { return (DgU-WithEvidence (DgP-GateResult $true 'NotNeeded' '' '' @() 'NoMarker' '' '' $false) $Layout) }
    $rec = DgTx-Recover $Layout.StateRoot $Layout.BackupRoot $staticPolicy
    if ($rec.Outcome -eq 'NotNeeded') { return (DgU-WithEvidence (DgP-GateResult $true 'NotNeeded' '' '' @() 'NoMarker' '' '' $false) $Layout) }
    return (DgU-WithEvidence (DgP-GateResult $false $rec.Outcome 'RecoveryRequired' ('Unexpected recovery outcome: ' + $rec.Outcome) $rec.Reasons $rec.Region $rec.TransactionId ([string]$rec.ReportPath) $true) $Layout)
}

# ---------------------------------------------------------------- uninstalled state (read) and generation
function Read-DenGoUninstalledState {
    param([object]$Layout)
    $path = DgU-UninstalledStatePath $Layout
    $r = [pscustomobject]@{ Exists = $false; Path = $path; Sha = ''; State = $null; Valid = $false; NewFormat = $false; HasClosedGeneration = $false; Reason = ''; UninstalledAt = ''; UninstallTransactionId = ''; LastClosedTransactionId = '' }
    if (-not (DgFs-Exists $path)) { return $r }
    $r.Exists = $true
    try {
        $bytes = [byte[]](DgFs-ReadAllBytesShared $path)
        $r.Sha = DgSha256-Bytes $bytes
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
        $obj = $text | ConvertFrom-Json
        if ($null -eq $obj) { $r.Reason = 'Empty'; return $r }
        $r.State = $obj
        if ([int](DgProp $obj 'SchemaVersion' 0) -ne 1) { $r.Reason = 'SchemaVersion'; return $r }
        if (-not (DgEq ([string](DgProp $obj 'State' '')) 'Uninstalled')) { $r.Reason = 'StateValue'; return $r }
        $at = [System.DateTimeOffset]::MinValue
        if (-not [System.DateTimeOffset]::TryParse([string](DgProp $obj 'UninstalledAt' ''),[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::None,[ref]$at)) { $r.Reason = 'UninstalledAt'; return $r }
        $r.Valid = $true
        $r.UninstalledAt = [string](DgProp $obj 'UninstalledAt' '')
        $cg = DgProp $obj 'ClosedGeneration' $null
        if ($null -ne $cg) {
            $r.HasClosedGeneration = $true
            $r.LastClosedTransactionId = [string](DgProp $cg 'LastInstallTransactionId' '')
        }
        $r.UninstallTransactionId = [string](DgProp $obj 'UninstallTransactionId' '')
        if (($null -ne $cg) -and ([int](DgProp $obj 'StateRevision' 0) -ge 2) -and ($r.UninstallTransactionId -cmatch $Layout.TxnIdPattern) -and (DgU-IsHex64 ([string](DgProp $cg 'GenerationId' ''))) -and (-not [string]::IsNullOrEmpty([string](DgProp $cg 'ArchivedStatePath' ''))) -and (DgU-IsHex64 ([string](DgProp $cg 'ArchivedStateSha256' '')))) { $r.NewFormat = $true }
    } catch {
        $r.Valid = $false
        if ($r.Reason.Length -eq 0) { $r.Reason = 'Unreadable' }
    }
    return $r
}
# The generation that is being closed and whether it is contaminated (P-2 / D-C6):
#   (1) a legacy installed-state (no StateRevision) next to a legacy uninstalled-state (no ClosedGeneration), or
#   (2) an I2-B installed-state next to a legacy uninstalled-state: the generation may have been re-created after a legacy uninstall.
function Get-DenGoUninstallGeneration {
    param([object]$Prev,[object]$Us)
    $g = [pscustomobject]@{ GenerationId = ''; InstalledAt = ''; LastInstallTransactionId = ''; StateRevision = 0; LegacyFormat = $false; UninstalledLegacy = $false
        ContaminationSuspect = $false; ContaminationReasons = [string[]]@(); LastClosedTransactionId = '' }
    if ($null -ne $Prev -and [bool]$Prev.Exists) {
        $st = $Prev.State
        $g.GenerationId = ([string]$Prev.Sha).ToLowerInvariant()
        $g.InstalledAt = [string](DgProp $st 'InstalledAt' '')
        $g.LastInstallTransactionId = [string](DgProp $st 'TransactionId' '')
        $g.StateRevision = [int](DgProp $st 'StateRevision' 0)
        $g.LegacyFormat = ($null -eq $st.PSObject.Properties['StateRevision'])
    }
    if ($null -ne $Us -and [bool]$Us.Exists) {
        $g.UninstalledLegacy = (-not [bool]$Us.HasClosedGeneration)
        $g.LastClosedTransactionId = [string]$Us.LastClosedTransactionId
    }
    $reasons = New-Object System.Collections.ArrayList
    if ($g.UninstalledLegacy -and $null -ne $Prev -and [bool]$Prev.Exists) {
        if ($g.LegacyFormat) { [void]$reasons.Add('LegacyInstalledStateWithLegacyUninstalledState') }
        else { [void]$reasons.Add('InstalledStateWithLegacyUninstalledState: the generation may have been re-created after a legacy uninstall') }
    }
    $g.ContaminationReasons = [string[]]@($reasons)
    $g.ContaminationSuspect = ($reasons.Count -gt 0)
    return $g
}
# AlreadyUninstalled (D-C3): every condition must hold, otherwise the state is ambiguous and nothing is guessed.
function Test-DenGoAlreadyUninstalled {
    param([object]$Layout,[object]$Prev,[object]$Us)
    $r = [pscustomobject]@{ Ok = $false; Code = 'NotInstalled'; Reason = '' }
    if ($null -ne $Prev -and [bool]$Prev.Exists) { $r.Code = 'AlreadyUninstalledNotApplicable'; $r.Reason = 'installed-state.json exists.'; return $r }
    if (-not [bool]$Us.Exists) { $r.Code = 'NotInstalled'; $r.Reason = 'Neither installed-state.json nor uninstalled-state.json exists.'; return $r }
    $r.Code = 'UninstalledStateNotReconfirmable'
    foreach ($m in 'uninstalling.json','installing.json') { if (DgFs-Exists (DgP-Join $Layout.StateRoot $m)) { $r.Reason = ($m + ' exists.'); return $r } }
    $orphan = DgP-FindActiveOrphan $Layout
    if ($null -ne $orphan) { $r.Reason = ('An unfinished transaction journal exists (' + $orphan.Code + ').'); return $r }
    if (-not [bool]$Us.Valid) { $r.Reason = ('uninstalled-state.json is not valid (' + $Us.Reason + ').'); return $r }
    if (-not [bool]$Us.NewFormat) { $r.Reason = 'uninstalled-state.json is not a current-format state of this product (legacy or incomplete).'; return $r }
    $cg = DgProp $Us.State 'ClosedGeneration' $null
    $arch = [string](DgProp $cg 'ArchivedStatePath' '')
    $archSha = [string](DgProp $cg 'ArchivedStateSha256' '')
    $hist = DgU-HistoryDir $Layout
    $expectedName = DgU-ArchiveName 'installed' $archSha
    if (-not (DgU-PathEqSafe $arch (DgP-Join $hist $expectedName))) { $r.Reason = 'The archived installed-state path is not the expected history leaf.'; return $r }
    if (-not (DgFs-Exists $arch)) { $r.Reason = 'The archived installed-state is missing.'; return $r }
    if (-not (DgEqI (DgFs-Sha256 $arch) $archSha)) { $r.Reason = 'The archived installed-state SHA-256 does not match.'; return $r }
    $r.Ok = $true; $r.Code = ''; $r.Reason = ''
    return $r
}

# ---------------------------------------------------------------- shape / volume / root proof
function Test-DenGoVolumeAvailable {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ([string]::IsNullOrEmpty($root)) { return $false }
        return [System.IO.Directory]::Exists($root)
    } catch { return $false }
}
# Static check (gate a): the record must name a fixed DenGo leaf of a known platform with no reparse point on the way.
function Get-DenGoUninstallShape {
    param([object]$Layout,[string]$Platform,[string]$Destination)
    $r = [pscustomobject]@{ Ok = $false; Reason = ''; Role = ''; Root = ''; Set = ''; Deferred = $false; Full = '' }
    # a PCSX2 / LilyPad record is deferred whatever else it says: it is never read, so even a malformed one cannot stop an uninstall
    if (DgEq $Platform 'PCSX2') { $r.Role = 'Deferred'; $r.Set = 'PCSX2'; $r.Deferred = $true; $r.Ok = $true; return $r }
    $c = DgPath-Check $Destination
    if (-not $c.Ok) { $r.Reason = 'Path:' + $c.Reason; return $r }
    $full = DgP-Full $c.Normalized
    $r.Full = $full
    $m = $null
    try { $m = DgP-MapPlatform $Platform $full } catch { $r.Reason = 'PlatformUnsupported'; return $r }
    $r.Role = [string]$m.Role; $r.Root = [string]$m.Root; $r.Set = [string]$m.Set; $r.Deferred = [bool]$m.Deferred
    if ($r.Deferred) { $r.Ok = $true; return $r }
    $leaf = [System.IO.Path]::GetFileName($full)
    $parent = [System.IO.Path]::GetDirectoryName($full)
    $fixedRoot = ''
    if (DgEq $r.Role 'App') {
        if (-not (DgP-InSet $full ([string[]]@($Layout.AppExe,$Layout.AppIco)))) { $r.Reason = 'LeafNotFixed'; return $r }
        $fixedRoot = [string]$Layout.LocalAppData
    } elseif ((DgEq $r.Role 'Bve5') -or (DgEq $r.Role 'Bve6')) {
        if (-not ((DgEqI $leaf 'DenGoControllerConverter.dll') -and (DgEqI ([System.IO.Path]::GetFileName($parent)) 'Input Devices'))) { $r.Reason = 'LeafNotFixed'; return $r }
        if ([string]::IsNullOrEmpty($r.Root) -or $r.Root.Length -le 3) { $r.Reason = 'RootInvalid'; return $r }
        $fixedRoot = $r.Root
    } elseif (DgEq $r.Role 'Current') {
        if (-not (DgP-InSet $full ([string[]]@((DgP-Join $Layout.CurrentExt 'DenGoVehicleSpec.BveEx.Bridge.dll'),(DgP-Join $Layout.CurrentExt 'DenGoBveVehicleSpec.dll'))))) { $r.Reason = 'LeafNotFixed'; return $r }
        $fixedRoot = [string]$Layout.CurrentExt
    } elseif (DgEq $r.Role 'Legacy') {
        if (-not (DgP-InSet $full ([string[]]@((DgP-Join $Layout.LegacyExt 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll'),(DgP-Join $Layout.LegacyExt 'DenGoAtsExLegacyVehicleSpec.dll'))))) { $r.Reason = 'LeafNotFixed'; return $r }
        $fixedRoot = [string]$Layout.LegacyExt
    } elseif (DgEq $r.Role 'Rpcs3') {
        if (-not ((DgEqI $leaf 'Den-Go-Controller.yml') -and $parent.EndsWith('\config\input_configs\global',[System.StringComparison]::OrdinalIgnoreCase))) { $r.Reason = 'LeafNotFixed'; return $r }
        $fixedRoot = $parent
    } else { $r.Reason = 'RoleUnsupported'; return $r }
    $rp = DgFs-GetReparseComponents $full $fixedRoot
    if (@($rp).Count -ne 0) { $r.Reason = 'PathReparse'; return $r }
    $r.Ok = $true
    return $r
}

# ---------------------------------------------------------------- Origin backup (R1-R7)
function Resolve-DenGoOriginBackup {
    param([object]$Layout,[bool]$ExistedBefore,[string]$BeforeSha,[string]$Backup,[object]$Backups,[bool]$Contaminated,[string]$LastClosedTxn,[string]$FailCode = 'ReplacedExistingBackupInvalid')
    $r = [pscustomobject]@{ Ok = $false; Code = $FailCode; Reason = ''; Path = ''; Sha = ''; Format = ''; TxnId = '' }
    if ($Contaminated) { $r.Code = 'ContaminationBlocksRestore'; $r.Reason = 'ContaminationSuspect: a restore is not performed.'; return $r }
    if (-not $ExistedBefore) { $r.Reason = 'R1: the record does not say that the file existed before.'; return $r }
    if (-not (DgU-IsHex64 $BeforeSha)) { $r.Reason = 'R1: the recorded original SHA-256 is missing or malformed.'; return $r }
    if ([string]::IsNullOrWhiteSpace($Backup)) { $r.Reason = 'R1: the recorded backup path is empty.'; return $r }
    $g = Test-DenGoUninstallSourceGate $Layout $Backup
    if (-not $g.Allowed) { $r.Reason = ('R2: the backup path is not an allowed backup leaf (' + $g.Reason + ').'); return $r }
    $list = DgU-AsList $Backups
    if (DgEq $g.Format 'Txn') {
        if ($list.Count -eq 0) { $r.Reason = 'R3: Backups[] is empty.'; return $r }
        $b0 = $list[0]
        if (-not (DgU-PathEqSafe ([string](DgProp $b0 'Path' '')) $Backup)) { $r.Reason = 'R3: Backup does not equal Backups[0].Path.'; return $r }
        if (-not (DgEqI ([string](DgProp $b0 'SHA256' '')) $BeforeSha)) { $r.Reason = 'R3: Backups[0].SHA256 does not equal the original SHA-256.'; return $r }
        if (-not (DgEq ([string](DgProp $b0 'TransactionId' '')) $g.TxnId)) { $r.Reason = 'R3: Backups[0].TransactionId does not equal the backup folder transaction.'; return $r }
        if ($LastClosedTxn.Length -gt 0 -and [string]::CompareOrdinal($g.TxnId,$LastClosedTxn) -le 0) { $r.Reason = 'R7: the backup belongs to a generation that was already closed.'; return $r }
    } else {
        if ($LastClosedTxn.Length -gt 0) { $r.Reason = 'R7: a legacy backup cannot belong to a generation that follows a closed generation.'; return $r }
        foreach ($b in $list) { if (DgU-PathEqSafe ([string](DgProp $b 'Path' '')) $Backup) { $r.Reason = 'R3: a legacy backup path must not appear in Backups[].'; return $r } }
    }
    $full = [string]$g.Full
    if (-not (DgFs-Exists $full)) { $r.Reason = 'R4: the backup file is missing.'; return $r }
    $actual = ''
    try { $actual = DgFs-Sha256 $full } catch { $r.Reason = 'R4: the backup file cannot be read.'; return $r }
    if (-not (DgEqI $actual $BeforeSha)) { $r.Reason = 'R4: the backup file SHA-256 does not match the recorded original SHA-256.'; return $r }
    $r.Ok = $true; $r.Code = ''; $r.Path = $full; $r.Sha = $actual; $r.Format = [string]$g.Format; $r.TxnId = [string]$g.TxnId
    return $r
}

# ---------------------------------------------------------------- decisions
function DgU-NewDecision {
    param([string]$Kind,[string]$Platform,[string]$Component,[string]$Destination,[string]$Ownership)
    return [pscustomobject]@{
        Kind = $Kind; Platform = $Platform; Component = $Component; Destination = $Destination; Ownership = $Ownership
        Decision = ''; ReasonCode = ''; Reason = ''; Blocking = $false; BlockCode = ''
        Exists = $false; CurrentSha = ''; RecordedAfterSha = ''; BeforeSha = ''
        Role = ''; Root = ''; Set = ''; Op = ''; Source = ''; SourceSha = ''
        Origin = $null; ReviewRecommended = $false; Residual = $false; Presence = ''; Observed = ''; Applied = $false; FinalSha = ''
        Backups = [object[]]@(); Backup = ''; UsedBackup = $false }
}
function DgU-Set {
    param([object]$D,[string]$Decision,[string]$Code,[string]$Reason)
    $D.Decision = $Decision; $D.ReasonCode = $Code; $D.Reason = $Reason
    return $D
}
function DgU-Block {
    param([object]$D,[string]$Decision,[string]$Code,[string]$Reason)
    $D.Decision = $Decision; $D.ReasonCode = $Code; $D.Reason = $Reason; $D.Blocking = $true; $D.BlockCode = $Code
    return $D
}
function DgU-Leave {
    param([object]$D,[string]$Decision,[string]$Code,[string]$Reason,[bool]$Review = $false)
    $D.Decision = $Decision; $D.ReasonCode = $Code; $D.Reason = $Reason; $D.Residual = $true; $D.ReviewRecommended = $Review
    return $D
}

function Get-DenGoUninstallFileDecision {
    param([object]$Layout,[object]$Rec,[object]$Gen,[bool]$IncludeProfiles)
    $platform = [string](DgProp $Rec 'Platform' '')
    $component = [string](DgProp $Rec 'Component' '')
    $dest = [string](DgProp $Rec 'Destination' '')
    $own = [string](DgProp $Rec 'Ownership' '')
    $d = DgU-NewDecision 'File' $platform $component $dest $own
    $d.RecordedAfterSha = [string](DgProp $Rec 'AfterSHA256' '')
    $d.BeforeSha = [string](DgProp $Rec 'BeforeSHA256' '')
    $d.Backup = [string](DgProp $Rec 'Backup' '')
    $d.Backups = DgU-AsList (DgProp $Rec 'Backups' @())
    $d.Presence = [string](DgProp $Rec 'Presence' '')
    $d.Observed = [string](DgProp $Rec 'Observed' '')
    try {
        $shape = Get-DenGoUninstallShape $Layout $platform $dest
        $d.Role = $shape.Role; $d.Root = $shape.Root; $d.Set = $shape.Set
        if ($shape.Deferred) { return (DgU-Leave $d 'Deferred' 'DeferredToI3' 'PCSX2 / LilyPad records are deferred to I3 and are not touched.') }
        $isProfile = DgEq $component 'InputProfile'
        $isEffective = DgEq $component 'EffectiveInputProfile'
        $known = (DgU-OwnershipNames) -ccontains $own
        $owning = Test-DenGoOwningOwnership $own
        if (($isProfile -or $isEffective) -and -not $IncludeProfiles -and $known) { return (DgU-Leave $d 'KeepProfile' 'ProfileKept' 'Input profiles are preserved by default.') }
        if (-not $known) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' 'The ownership value is not recognized.') }
        if (-not $owning) {
            # a user-owned or not-managed record is never touched: a record that is not a DenGo leaf is only reported
            $exists = $false
            if ($shape.Ok) { $exists = DgFs-Exists $shape.Full }
            $d.Exists = $exists
            if (-not $shape.Ok) { return (DgU-Leave $d 'PreserveNotOwned' 'ShapeNotVerified' ('The record is not a DenGo leaf and is not touched (' + $shape.Reason + ').')) }
            if (-not $exists) {
                if (Test-DenGoVolumeAvailable $shape.Full) { return (DgU-Set $d 'AlreadyMissing' 'AlreadyMissing' 'The file is not present.') }
                return (DgU-Leave $d 'PreserveUnverified' 'VolumeUnavailable' 'The volume is not available; the file cannot be checked and is not touched.')
            }
            $d.CurrentSha = DgFs-Sha256 $shape.Full
            if ((DgEq $own 'PreservedUserFile')) { return (DgU-Leave $d 'PreserveUserFile' 'PreservedUserFile' 'The installer explicitly preserved this user file.') }
            if ($d.RecordedAfterSha.Length -gt 0 -and -not (DgEqI $d.CurrentSha $d.RecordedAfterSha)) { return (DgU-Leave $d 'PreserveModified' 'ModifiedByUser' 'The file differs from the recorded SHA-256 and is not owned.') }
            return (DgU-Leave $d 'PreserveNotOwned' 'NotOwned' 'The installer did not manage this item.')
        }
        # ---- a DenGo-owned record from here on
        if (-not $shape.Ok) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' ('The record is not a fixed DenGo leaf (' + $shape.Reason + ').')) }
        $exists = DgFs-Exists $shape.Full
        $d.Exists = $exists
        if (-not $exists) {
            if (Test-DenGoVolumeAvailable $shape.Full) { return (DgU-Set $d 'AlreadyMissing' 'AlreadyMissing' 'The file is not present; nothing is recreated.') }
            return (DgU-Block $d 'PreserveUnverified' 'OwnedRootUnverified' 'The volume of a DenGo-owned file is not available; reconnect it and run the uninstall again.')
        }
        $proof = Get-DenGoRoleSpec $Layout $shape.Role $shape.Root
        if (-not $proof.Ok) { return (DgU-Block $d 'PreserveUnverified' 'OwnedRootUnverified' ('The root of a DenGo-owned file cannot be proven (' + $proof.Reason + '); reconnect it and run the uninstall again.')) }
        foreach ($kind in 'Dest','Tmp') {
            $p = $(if ($kind -eq 'Tmp') { $shape.Full + (DgConst-TmpSuffix) } else { $shape.Full })
            $g = Test-DenGoUninstallLeafGate $Layout $shape.Role $shape.Root $p $kind
            if (-not $g.Allowed) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' ('Leaf gate (' + $kind + ' ' + $g.Reason + ').')) }
        }
        $d.CurrentSha = DgFs-Sha256 $shape.Full
        if (-not (DgU-IsHex64 $d.RecordedAfterSha)) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' 'The recorded SHA-256 of the installed file is missing or malformed.') }
        if (-not (DgEqI $d.CurrentSha $d.RecordedAfterSha)) {
            return (DgU-Leave $d 'PreserveModified' 'ModifiedByUser' 'The current SHA-256 differs from the installed SHA-256; the file is preserved.' $true)
        }
        if (DgEq $own 'ReplacedExisting') {
            if ((DgU-IsHex64 $d.BeforeSha) -and (DgEqI $d.BeforeSha $d.RecordedAfterSha)) { return (DgU-Set $d 'AlreadyOriginal' 'AlreadyOriginal' 'The installed file equals the original content.') }
            $o = Resolve-DenGoOriginBackup $Layout ([bool](DgProp $Rec 'ExistedBefore' $false)) $d.BeforeSha $d.Backup $d.Backups ([bool]$Gen.ContaminationSuspect) ([string]$Gen.LastClosedTransactionId)
            $d.Origin = $o
            if (-not $o.Ok) {
                $decision = $(if (DgEq $o.Code 'ContaminationBlocksRestore') { 'PreserveSuspect' } else { 'UnsafeOrUnknown' })
                return (DgU-Block $d $decision $o.Code $o.Reason)
            }
            $d.Op = 'Write'; $d.Source = $o.Path; $d.SourceSha = $o.Sha; $d.UsedBackup = $true
            return (DgU-Set $d 'Restore' 'RestoreOrigin' 'The current file matches the installed SHA-256 and the Origin backup is proven.')
        }
        # CreatedByInstaller / MigratedMatchingDenGoFile
        if ($isEffective) { return (DgU-Leave $d 'PreserveModified' 'EffectiveProfileNeverRemoved' 'An effective input profile is never removed.' $true) }
        $d.Op = 'Delete'
        return (DgU-Set $d 'Remove' 'Remove' 'The current file matches the installer-managed SHA-256.')
    } catch {
        return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' ('The record could not be evaluated: ' + [string](DgError-Root $_.Exception).Message))
    }
}

# One shortcut record (the current one or one of Earlier[]). Identity = Facts (target / folder / icon); the bytes of a lnk are not stable.
function Get-DenGoUninstallShortcutDecision {
    param([object]$Layout,[object]$Rec,[object]$Gen,[string]$Role,[scriptblock]$Reader)
    $path = [string](DgProp $Rec 'Path' '')
    $d = DgU-NewDecision 'Shortcut' 'Shortcut' $Role $path 'ShortcutCreatedByInstaller'
    $d.Role = 'Shortcut'; $d.Set = 'Shortcut'
    $d.Backup = [string](DgProp $Rec 'Backup' '')
    $d.BeforeSha = [string](DgProp $Rec 'BackupSHA256' '')
    $d.Backups = DgU-AsList (DgProp $Rec 'Backups' @())
    $d.Observed = [string](DgProp $Rec 'Observed' '')
    try {
        $c = DgPath-Check $path
        if (-not $c.Ok) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' ('The shortcut path is not valid (' + $c.Reason + ').')) }
        $full = DgP-Full $c.Normalized
        $d.Destination = $full
        if (-not (DgEqI ([System.IO.Path]::GetFileName($full)) (DgP-ShortcutFileName))) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' 'The shortcut leaf is not the fixed DenGo shortcut name.') }
        $root = DgP-Full ([System.IO.Path]::GetDirectoryName($full))
        $d.Root = $root
        $exists = DgFs-Exists $full
        $d.Exists = $exists
        if (-not $exists) {
            if (Test-DenGoVolumeAvailable $full) { return (DgU-Set $d 'AlreadyMissing' 'AlreadyMissing' 'The shortcut is not present; nothing is recreated.') }
            return (DgU-Block $d 'PreserveUnverified' 'OwnedRootUnverified' 'The volume of a DenGo-created shortcut is not available; reconnect it and run the uninstall again.')
        }
        $spec = Get-DenGoRoleSpec $Layout 'Shortcut' $root
        if (-not $spec.Ok) {
            $bad = @('RootInvalid','ShortcutRootInvalid','ShortcutRootReparse','ShortcutNotConfigured')
            if ($bad -contains [string]$spec.Reason) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' ('The shortcut root is not acceptable (' + $spec.Reason + ').')) }
            return (DgU-Block $d 'PreserveUnverified' 'OwnedRootUnverified' ('The shortcut root cannot be proven (' + $spec.Reason + ').'))
        }
        $rp = DgFs-GetReparseComponents $full $root
        if (@($rp).Count -ne 0) { return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' 'A reparse point lies on the way to the shortcut.') }
        $d.CurrentSha = DgFs-Sha256 $full
        $cur = $null
        try { $cur = & $Reader $full } catch { $cur = $null }
        if ($null -eq $cur) { return (DgU-Leave $d 'Diverged' 'ShortcutUnreadable' 'The shortcut cannot be read; it is left as it is.' $true) }
        $facts = DgProp $Rec 'Facts' $null
        $preExisted = [bool](DgProp $Rec 'PreExisted' $false)
        if ($null -eq $facts) {
            # an old-format record: only a shortcut that points at the installed application is ours
            if ((-not $preExisted) -and (DgU-PathEqSafe ([string](DgProp $cur 'TargetPath' '')) $Layout.AppExe)) { $d.Op = 'Delete'; return (DgU-Set $d 'Remove' 'Remove' 'The old-format shortcut record points at the installed application.') }
            return (DgU-Leave $d 'Diverged' 'ShortcutNotRecognized' 'The old-format shortcut record cannot be proven to be ours; it is left as it is.' $true)
        }
        if (-not (DgP-FactsEqual $cur $facts)) { return (DgU-Leave $d 'Diverged' 'ShortcutEdited' 'The shortcut was edited after the install; it is neither deleted nor overwritten.' $true) }
        if (-not $preExisted) { $d.Op = 'Delete'; return (DgU-Set $d 'Remove' 'Remove' 'The shortcut was created by the installer and is unedited.') }
        if ([string]::IsNullOrWhiteSpace($d.Backup)) { return (DgU-Leave $d 'PreserveUserFile' 'PreExistedUnchanged' 'The shortcut existed before with the same content; it is the user''s and is left as it is.') }
        $o = Resolve-DenGoOriginBackup $Layout $true $d.BeforeSha $d.Backup $d.Backups ([bool]$Gen.ContaminationSuspect) ([string]$Gen.LastClosedTransactionId) 'ShortcutBackupInvalid'
        $d.Origin = $o
        if (-not $o.Ok) {
            $decision = $(if (DgEq $o.Code 'ContaminationBlocksRestore') { 'PreserveSuspect' } else { 'UnsafeOrUnknown' })
            return (DgU-Block $d $decision $o.Code $o.Reason)
        }
        if (DgEqI $d.CurrentSha $o.Sha) { return (DgU-Set $d 'AlreadyOriginal' 'AlreadyOriginal' 'The shortcut already equals the original.') }
        $d.Op = 'Write'; $d.Source = $o.Path; $d.SourceSha = $o.Sha; $d.UsedBackup = $true
        return (DgU-Set $d 'Restore' 'RestoreOrigin' 'The shortcut is unedited and the Origin backup is proven.')
    } catch {
        return (DgU-Block $d 'UnsafeOrUnknown' 'UnsafeOrUnknown' ('The shortcut record could not be evaluated: ' + [string](DgError-Root $_.Exception).Message))
    }
}
function Get-DenGoUninstallShortcutDecisions {
    param([object]$Layout,[object]$State,[object]$Gen,[scriptblock]$Reader)
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    $sc = DgProp $State 'Shortcut' $null
    $entries = New-Object System.Collections.ArrayList
    if ($null -ne $sc) { [void]$entries.Add(@{ Rec = $sc; Role = 'Current' }) }
    if ($null -ne $sc) { foreach ($e in (DgU-AsList (DgProp $sc 'Earlier' @()))) { [void]$entries.Add(@{ Rec = $e; Role = 'Earlier' }) } }
    foreach ($en in $entries) {
        $rec = $en.Rec
        if (-not [bool](DgProp $rec 'Created' $false)) { continue }
        $p = [string](DgProp $rec 'Path' '')
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $key = ''
        try { $key = (DgP-Full $p).ToUpperInvariant() } catch { $key = $p.ToUpperInvariant() }
        if ($seen.ContainsKey($key)) {
            $dup = DgU-NewDecision 'Shortcut' 'Shortcut' $en.Role $p 'ShortcutCreatedByInstaller'
            [void](DgU-Set $dup 'SupersededByCurrent' 'SupersededByCurrent' 'The same path was already evaluated.')
            [void]$out.Add($dup)
            continue
        }
        $seen[$key] = $true
        [void]$out.Add((Get-DenGoUninstallShortcutDecision $Layout $rec $Gen $en.Role $Reader))
    }
    return ,[object[]]@($out)
}

# ---------------------------------------------------------------- archive (history) plan
function Get-DenGoUninstallArchivePlan {
    param([object]$Layout,[object]$Prev,[object]$Us)
    $plan = [pscustomobject]@{ IS = $null; US = $null; Collision = ''; }
    $hist = DgU-HistoryDir $Layout
    $one = {
        param($Kind,$Source,$Sha)
        $name = DgU-ArchiveName $Kind $Sha
        $path = DgP-Join $hist $name
        $o = [pscustomobject]@{ Kind = $Kind; Name = $name; Path = $path; Source = $Source; Sha = $Sha; Skip = $false; Collision = $false }
        if (DgFs-Exists $path) {
            if (DgEqI (DgFs-Sha256 $path) $Sha) { $o.Skip = $true } else { $o.Collision = $true }
        }
        return $o
    }
    if ($null -ne $Prev -and [bool]$Prev.Exists) { $plan.IS = & $one 'installed' $Layout.StatePath ([string]$Prev.Sha) }
    if ($null -ne $Us -and [bool]$Us.Exists) { $plan.US = & $one 'uninstalled' $Us.Path ([string]$Us.Sha) }
    foreach ($a in @($plan.IS,$plan.US)) { if ($null -ne $a -and $a.Collision) { $plan.Collision = ('A different file already exists at ' + $a.Path) } }
    return $plan
}

# ---------------------------------------------------------------- plan
function Get-DenGoUninstallPlan {
    param([object]$Layout,[object]$Prev,[object]$Us,[hashtable]$Options = @{})
    $incl = [bool](DgProp $Options 'IncludeInputProfiles' $false)
    $reader = DgProp $Options 'ShortcutReader' $null
    if ($null -eq $reader) { $reader = { param($p) DgPFs-ReadShortcut $p } }
    $gen = Get-DenGoUninstallGeneration $Prev $Us
    $state = $Prev.State
    $records = DgU-AsList $Prev.Files
    # apply order = the reverse of the install: Set order reversed, and the reverse of the record order inside a Set
    $mapped = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $records.Count; $i++) {
        $set = ''
        try { $m = DgP-MapPlatform ([string](DgProp $records[$i] 'Platform' '')) ([string](DgProp $records[$i] 'Destination' '')); $set = [string]$m.Set } catch { $set = '' }
        $mapped.Add(@{ Index = $i; Set = $set })
    }
    $order = New-Object System.Collections.ArrayList
    foreach ($set in (DgU-SetOrder)) { for ($i = $mapped.Count - 1; $i -ge 0; $i--) { if (DgEq $mapped[$i].Set $set) { [void]$order.Add($mapped[$i].Index) } } }
    for ($i = 0; $i -lt $mapped.Count; $i++) { if (-not ((DgU-SetOrder) -ccontains $mapped[$i].Set)) { [void]$order.Add($i) } }
    $fileDecisions = New-Object System.Collections.ArrayList
    foreach ($idx in $order) { [void]$fileDecisions.Add((Get-DenGoUninstallFileDecision $Layout $records[$idx] $gen $incl)) }
    $shortcutDecisions = Get-DenGoUninstallShortcutDecisions $Layout $state $gen $reader
    $archive = Get-DenGoUninstallArchivePlan $Layout $Prev $Us
    $blocking = New-Object System.Collections.ArrayList
    foreach ($d in @($shortcutDecisions) + @($fileDecisions)) { if ($d.Blocking) { [void]$blocking.Add($d) } }
    $collision = ''
    if ($null -ne $archive -and [string]$archive.Collision -ne '') { $collision = [string]$archive.Collision }
    $deferred = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $order.Count; $k++) { if ($fileDecisions[$k].Decision -eq 'Deferred') { [void]$deferred.Add([pscustomobject][ordered]@{ Record = $records[[int]$order[$k]]; Reason = 'DeferredToI3' }) } }
    return [pscustomobject]@{
        Generation = $gen; FileDecisions = [object[]]@($fileDecisions); ShortcutDecisions = [object[]]@($shortcutDecisions); Archive = $archive
        Blocking = [object[]]@($blocking); ArchiveCollision = $collision; DeferredRecords = [object[]]@($deferred); IncludeInputProfiles = $incl; ProductVersion = [string](DgProp $state 'ProductVersion' '') }
}
# The failure that explains a blocked plan (the most specific first).
function Get-DenGoUninstallBlockingCode {
    param([object]$Plan)
    $codes = New-Object System.Collections.ArrayList
    foreach ($b in @($Plan.Blocking)) { [void]$codes.Add([string]$b.BlockCode) }
    if ([string]$Plan.ArchiveCollision -ne '') { [void]$codes.Add('HistoryArchiveCollision') }
    foreach ($c in 'UnsafeOrUnknown','ContaminationBlocksRestore','ReplacedExistingBackupInvalid','ShortcutBackupInvalid','OwnedRootUnverified','HistoryArchiveCollision') { if ($codes -contains $c) { return $c } }
    if ($codes.Count -gt 0) { return [string]$codes[0] }
    return ''
}

# ---------------------------------------------------------------- items
function Convert-DenGoUninstallPlanToItems {
    param([object]$Layout,[object]$Plan,[bool]$CloseInstalledState)
    $items = New-Object System.Collections.ArrayList
    $metas = New-Object System.Collections.ArrayList
    $add = {
        param($Item,$Meta)
        [void]$items.Add($Item); [void]$metas.Add($Meta)
    }
    foreach ($d in @($Plan.ShortcutDecisions) + @($Plan.FileDecisions)) {
        if ($d.Op.Length -eq 0) { continue }
        $tag = $d.Platform + '|' + $d.Component + '|' + $d.Role + '|' + $d.Root
        if ($d.Kind -eq 'Shortcut') { $tag = 'Shortcut|Desktop|Shortcut|' + $d.Root }
        $own = $(if ($d.Kind -eq 'Shortcut') { $(if ($d.Op -eq 'Delete') { 'RemoveShortcut' } else { 'RestoreShortcut' }) } else { $(if ($d.Op -eq 'Delete') { 'Remove' } else { 'Restore' }) })
        $dest = [string]$d.Destination
        $item = @{ Op = $d.Op; Destination = $dest; OwnershipCandidate = $own; Tag = $tag }
        if ($d.Op -eq 'Write') { $item['Source'] = $d.Source }
        & $add $item ([pscustomobject]@{ Kind = $d.Kind; Destination = $dest; ExpectedDestSha = [string]$d.CurrentSha; Source = [string]$d.Source; ExpectedSourceSha = [string]$d.SourceSha; Role = [string]$(if ($d.Kind -eq 'Shortcut') { 'Shortcut' } else { $d.Role }); Root = [string]$d.Root; Decision = $d; Tag = $tag })
    }
    $arch = $Plan.Archive
    if ($null -ne $arch.US -and -not $arch.US.Skip) {
        $tag = 'InstallerState|UninstalledState|StateArchive|' + $arch.US.Name
        & $add @{ Op = 'Write'; Destination = $arch.US.Path; Source = $arch.US.Source; OwnershipCandidate = 'ArchiveUninstalledState'; Tag = $tag } ([pscustomobject]@{ Kind = 'ArchiveUS'; Destination = $arch.US.Path; ExpectedDestSha = ''; Source = $arch.US.Source; ExpectedSourceSha = $arch.US.Sha; Role = 'StateArchive'; Root = $arch.US.Name; Decision = $null; Tag = $tag })
    }
    if ($CloseInstalledState -and $null -ne $arch.IS) {
        if (-not $arch.IS.Skip) {
            $tag = 'InstallerState|InstalledState|StateArchive|' + $arch.IS.Name
            & $add @{ Op = 'Write'; Destination = $arch.IS.Path; Source = $arch.IS.Source; OwnershipCandidate = 'ArchiveInstalledState'; Tag = $tag } ([pscustomobject]@{ Kind = 'ArchiveIS'; Destination = $arch.IS.Path; ExpectedDestSha = ''; Source = $arch.IS.Source; ExpectedSourceSha = $arch.IS.Sha; Role = 'StateArchive'; Root = $arch.IS.Name; Decision = $null; Tag = $tag })
        }
        $tag = 'InstallerState|InstalledState|StateDelete|'
        & $add @{ Op = 'Delete'; Destination = [string]$Layout.StatePath; OwnershipCandidate = 'RemoveInstalledState'; Tag = $tag } ([pscustomobject]@{ Kind = 'DeleteIS'; Destination = [string]$Layout.StatePath; ExpectedDestSha = $arch.IS.Sha; Source = ''; ExpectedSourceSha = ''; Role = 'StateDelete'; Root = ''; Decision = $null; Tag = $tag })
    }
    return [pscustomobject]@{ Items = [object[]]@($items); Metas = [object[]]@($metas) }
}
function Test-DenGoUninstallPlanFresh {
    param([object[]]$Metas,[object]$Prev,[object]$Us,[object]$Layout)
    foreach ($m in @($Metas)) {
        $cur = ''
        if (DgFs-Exists $m.Destination) { $cur = DgFs-Sha256 $m.Destination }
        if (-not (DgEqI $cur ([string]$m.ExpectedDestSha))) { return (DgP-Reason 'PlanStale' ('Destination changed since planning: ' + $m.Destination)) }
        if ([string]$m.Source -ne '') {
            if (-not (DgFs-Exists $m.Source)) { return (DgP-Reason 'PlanStale' ('Source is missing: ' + $m.Source)) }
            if (-not (DgEqI (DgFs-Sha256 $m.Source) ([string]$m.ExpectedSourceSha))) { return (DgP-Reason 'PlanStale' ('Source changed since planning: ' + $m.Source)) }
        }
    }
    if ($null -ne $Prev -and [bool]$Prev.Exists) {
        if (-not (DgFs-Exists $Layout.StatePath) -or -not (DgEqI (DgFs-Sha256 $Layout.StatePath) ([string]$Prev.Sha))) { return (DgP-Reason 'PlanStale' 'installed-state.json changed since it was read.') }
    }
    $usNow = ''
    if (DgFs-Exists (DgU-UninstalledStatePath $Layout)) { $usNow = DgFs-Sha256 (DgU-UninstalledStatePath $Layout) }
    if (-not (DgEqI $usNow ([string]$Us.Sha))) { return (DgP-Reason 'PlanStale' 'uninstalled-state.json changed since it was read.') }
    return $null
}
function Test-DenGoUninstallBeginMatchesPlan {
    param([hashtable]$Ctx,[object[]]$Metas,[object]$Layout,[string]$ExpectedOldStateSha)
    $items = @($Ctx.Items)
    if ($items.Count -ne @($Metas).Count) { throw (DgError 'PlanStale' 'The registered item count differs from the plan.') }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]; $m = @($Metas)[$i]
        $fails = Test-DenGoUninstallItemGate $Layout ([string]$it.Tag) ([string]$it.Norm) ([string]$it.Tmp) ([string[]]@($it.Dirs)) ([string]$it.Backup) ([string]$Ctx.TxnId)
        if ($fails.Count -ne 0) { throw (DgError 'PathRejected' ('Leaf gate: ' + [string]::Join('; ',$fails))) }
        if (-not (DgP-PathEq ([string]$it.Norm) ([string]$m.Destination))) { throw (DgError 'PlanStale' ('Registered destination differs from the plan: ' + $it.Norm)) }
        $expectExists = ([string]$m.ExpectedDestSha).Length -gt 0
        if (([bool]$it.PreExists -ne $expectExists) -or -not (DgEqI ([string]$it.PreSha) ([string]$m.ExpectedDestSha))) { throw (DgError 'PlanStale' ('Destination changed between planning and Begin: ' + $it.Norm)) }
        if ([string]$m.Source -ne '' -and -not (DgEqI ([string]$it.SourceSha) ([string]$m.ExpectedSourceSha))) { throw (DgError 'PlanStale' ('Source changed between planning and Begin: ' + $it.Source)) }
    }
    if (-not (DgEqI ([string]$Ctx.OldStateSha) $ExpectedOldStateSha)) { throw (DgError 'PlanStale' 'uninstalled-state.json changed since it was read.') }
}

# ---------------------------------------------------------------- uninstalled-state.json (pure)
function DgU-ItemSummary {
    param([object]$D)
    return [pscustomobject][ordered]@{
        Platform = $D.Platform; Component = $D.Component; Destination = $D.Destination; Ownership = $D.Ownership; Decision = $D.Decision; ReasonCode = $D.ReasonCode; Reason = $D.Reason
        RecordedAfterSHA256 = $D.RecordedAfterSha; CurrentSHA256Before = $D.CurrentSha; Applied = [bool]$D.Applied; Presence = $D.Presence; Observed = $D.Observed }
}
function DgU-ResidualEntry {
    param([object]$D)
    $kind = $(if ($D.Kind -eq 'Shortcut') { 'Shortcut' } else { 'File' })
    return [pscustomobject][ordered]@{
        Kind = $kind; Path = $D.Destination; Platform = $D.Platform; Component = $D.Component; Ownership = $D.Ownership; Disposition = $D.Decision; ReasonCode = $D.ReasonCode
        CurrentSHA256 = $D.CurrentSha; RecordedSHA256 = $D.RecordedAfterSha; ReviewRecommended = [bool]$D.ReviewRecommended }
}
function Get-DenGoUninstallCounts {
    param([object[]]$Decisions)
    $c = [ordered]@{ Removed = 0; Restored = 0; Preserved = 0; AlreadyMissing = 0; Diverged = 0; Deferred = 0; Unverified = 0 }
    foreach ($d in @($Decisions)) {
        switch ([string]$d.Decision) {
            'Remove' { $c.Removed++ }
            'Restore' { $c.Restored++ }
            'AlreadyMissing' { $c.AlreadyMissing++ }
            'AlreadyOriginal' { $c.AlreadyMissing++ }
            'Deferred' { $c.Deferred++ }
            'PreserveUnverified' { $c.Unverified++ }
            'Diverged' { $c.Diverged++; $c.Preserved++ }
            'PreserveModified' { $c.Diverged++; $c.Preserved++ }
            'PreserveUserFile' { $c.Preserved++ }
            'PreserveNotOwned' { $c.Preserved++ }
            'KeepProfile' { $c.Preserved++ }
            default { }
        }
    }
    return [pscustomobject]$c
}
function Get-DenGoUnusedBackups {
    param([object]$Plan)
    $out = New-Object System.Collections.ArrayList
    foreach ($d in @($Plan.ShortcutDecisions) + @($Plan.FileDecisions)) {
        if ($d.Decision -eq 'Deferred') { continue }
        $usedPath = $(if ($d.UsedBackup -and $null -ne $d.Origin) { [string]$d.Origin.Path } else { '' })
        $idx = 0
        $listed = @{}
        foreach ($b in @($d.Backups)) {
            $p = [string](DgProp $b 'Path' '')
            $reason = $(if ($idx -ge 1) { 'UpdateBackup' } elseif ($Plan.Generation.ContaminationSuspect) { 'ContaminationSuspect' } elseif ($d.Decision -eq 'Remove') { 'NotOrigin' } else { 'FilePreserved' })
            $listed[$p.ToUpperInvariant()] = $true
            if (-not ($usedPath -ne '' -and (DgU-PathEqSafe $p $usedPath))) {
                [void]$out.Add([pscustomobject][ordered]@{ Path = $p; SHA256 = [string](DgProp $b 'SHA256' ''); TransactionId = [string](DgProp $b 'TransactionId' ''); Reason = $reason; Destination = $d.Destination })
            }
            $idx++
        }
        $bp = [string]$d.Backup
        if ($bp.Length -gt 0 -and -not $listed.ContainsKey($bp.ToUpperInvariant()) -and -not ($usedPath -ne '' -and (DgU-PathEqSafe $bp $usedPath))) {
            $reason = $(if ($Plan.Generation.ContaminationSuspect) { 'ContaminationSuspect' } else { 'FilePreserved' })
            [void]$out.Add([pscustomobject][ordered]@{ Path = $bp; SHA256 = [string]$d.BeforeSha; TransactionId = ''; Reason = $reason; Destination = $d.Destination })
        }
    }
    return ,[object[]]@($out)
}
function New-DenGoUninstalledState {
    param([object]$Plan,[object]$Prev,[object]$Us,[hashtable]$Ctx,[string]$Now,[object]$Layout)
    $gen = $Plan.Generation
    $st = $Prev.State
    $all = @($Plan.ShortcutDecisions) + @($Plan.FileDecisions)
    foreach ($d in $all) { if ($d.Op.Length -gt 0) { $d.Applied = $true } }
    $residual = New-Object System.Collections.ArrayList
    foreach ($d in $all) { if ($d.Residual -and $d.Decision -ne 'SupersededByCurrent') { [void]$residual.Add((DgU-ResidualEntry $d)) } }
    $review = @($residual | Where-Object { $_.ReviewRecommended }).Count
    $unverified = @($residual | Where-Object { $_.Disposition -eq 'PreserveUnverified' }).Count
    $manualReasons = New-Object System.Collections.ArrayList
    if ($gen.ContaminationSuspect) { [void]$manualReasons.Add('ContaminationSuspect') }
    if ($review -gt 0) { [void]$manualReasons.Add('ResidualFilesNeedReview') }
    if ($unverified -gt 0) { [void]$manualReasons.Add('PreserveUnverified') }
    $used = New-Object System.Collections.ArrayList
    foreach ($d in $all) { if ($d.UsedBackup -and $null -ne $d.Origin) { [void]$used.Add([pscustomobject][ordered]@{ Path = [string]$d.Origin.Path; SHA256 = [string]$d.Origin.Sha; Purpose = 'RestoreOrigin'; Destination = $d.Destination }) } }
    $created = New-Object System.Collections.ArrayList
    foreach ($it in @($Ctx.Items)) { if (([string]$it.Backup).Length -gt 0) { [void]$created.Add([pscustomobject][ordered]@{ Path = [string]$it.Backup; SHA256 = [string]$it.PreSha; Destination = [string]$it.Norm }) } }
    $dirs = New-Object System.Collections.ArrayList
    $seenDir = @{}
    foreach ($d in $all) {
        if ($d.Op -eq 'Delete' -and $d.Kind -eq 'File') {
            $dir = [System.IO.Path]::GetDirectoryName([string]$d.Destination)
            if ($dir.Length -gt 0 -and -not $seenDir.ContainsKey($dir.ToUpperInvariant()) -and (DgFs-DirExists $dir)) { $seenDir[$dir.ToUpperInvariant()] = $true; [void]$dirs.Add([pscustomobject][ordered]@{ Path = $dir; Reason = 'DirectoriesAreNeverRemoved' }) }
        }
    }
    $archIS = $Plan.Archive.IS
    $archUS = $Plan.Archive.US
    $cg = [pscustomobject][ordered]@{
        GenerationId = $gen.GenerationId; InstalledStateSha256 = ([string]$Prev.Sha).ToLowerInvariant(); ArchivedStatePath = [string]$archIS.Path; ArchivedStateSha256 = ([string]$archIS.Sha).ToLowerInvariant()
        InstalledAt = $gen.InstalledAt; LastInstallTransactionId = $gen.LastInstallTransactionId; StateRevision = [int]$gen.StateRevision; LegacyFormat = [bool]$gen.LegacyFormat
        ContaminationSuspect = [bool]$gen.ContaminationSuspect; ContaminationReasons = [string[]]@($gen.ContaminationReasons) }
    $prevUs = [pscustomobject][ordered]@{ Exists = $false; ArchivedPath = ''; Sha256 = ''; UninstalledAt = ''; UninstallTransactionId = ''; LegacyFormat = $false }
    if ($null -ne $archUS) { $prevUs = [pscustomobject][ordered]@{ Exists = $true; ArchivedPath = [string]$archUS.Path; Sha256 = ([string]$archUS.Sha).ToLowerInvariant(); UninstalledAt = [string]$Us.UninstalledAt; UninstallTransactionId = [string]$Us.UninstallTransactionId; LegacyFormat = [bool]$gen.UninstalledLegacy } }
    $results = New-Object System.Collections.ArrayList
    foreach ($d in $all) { if ($d.Decision -ne 'SupersededByCurrent') { [void]$results.Add([pscustomobject][ordered]@{ Platform = $d.Platform; Component = $d.Component; Action = $d.Decision; Destination = $d.Destination; Changed = [bool]($d.Op.Length -gt 0); Succeeded = $true }) } }
    $shortcutOut = New-Object System.Collections.ArrayList
    foreach ($d in @($Plan.ShortcutDecisions)) {
        [void]$shortcutOut.Add([pscustomobject][ordered]@{ Role = $d.Component; Path = $d.Destination; Decision = $d.Decision; ReasonCode = $d.ReasonCode; Applied = [bool]$d.Applied })
    }
    $closedList = DgU-AsList (DgProp $st 'ClosedRecords' @())
    $state = [pscustomobject][ordered]@{
        SchemaVersion = 1; StateRevision = 2; ProductVersion = [string](DgProp $st 'ProductVersion' ''); State = 'Uninstalled'; UninstalledAt = $Now
        UninstallTransactionId = [string]$Ctx.TxnId; InputProfilesPreserved = (-not [bool]$Plan.IncludeInputProfiles); IncludeInputProfiles = [bool]$Plan.IncludeInputProfiles
        RollbackRoot = [string]$Ctx.BackupTxnDir; Results = [object[]]@($results)
        ClosedGeneration = $cg; PreviousUninstalledState = $prevUs
        Counts = (Get-DenGoUninstallCounts $all)
        Items = [object[]]@($Plan.FileDecisions | ForEach-Object { DgU-ItemSummary $_ })
        Shortcuts = [object[]]@($shortcutOut)
        ResidualFiles = [object[]]@($residual)
        UsedBackups = [object[]]@($used); UnusedBackups = (Get-DenGoUnusedBackups $Plan); UninstallBackups = [object[]]@($created)
        ManualCheckRequired = ($manualReasons.Count -gt 0); ManualCheckReasons = [string[]]@($manualReasons)
        ClosedRecords = [object[]]@($closedList)
        DeferredRecords = [object[]]@($Plan.DeferredRecords)
        ResidualDirectories = [object[]]@($dirs)
        Reconfirmation = [pscustomobject][ordered]@{ Reconfirmed = $false }
    }
    return $state
}
# AlreadyUninstalled: the earlier uninstall record is carried over unchanged; only the time, the transaction and the lineage are new.
function New-DenGoReconfirmedState {
    param([object]$Us,[object]$Archive,[hashtable]$Ctx,[string]$Now)
    $old = $Us.State
    $o = [ordered]@{}
    foreach ($p in $old.PSObject.Properties) { $o[$p.Name] = $p.Value }
    $o['UninstalledAt'] = $Now
    $o['UninstallTransactionId'] = [string]$Ctx.TxnId
    $o['PreviousUninstalledState'] = [pscustomobject][ordered]@{ Exists = $true; ArchivedPath = [string]$Archive.US.Path; Sha256 = ([string]$Archive.US.Sha).ToLowerInvariant(); UninstalledAt = [string]$Us.UninstalledAt; UninstallTransactionId = [string]$Us.UninstallTransactionId; LegacyFormat = $false }
    $o['Reconfirmation'] = [pscustomobject][ordered]@{ Reconfirmed = $true; FromUninstallTransactionId = [string]$Us.UninstallTransactionId; FromUninstalledAt = [string]$Us.UninstalledAt; PreviousUninstalledStateSha256 = ([string]$Archive.US.Sha).ToLowerInvariant(); PreviousArchivedPath = [string]$Archive.US.Path }
    return [pscustomobject]$o
}

# ---------------------------------------------------------------- result
function ConvertTo-DenGoUninstallFailure {
    param([object]$Tx,[string]$FailedSet)
    $f = ConvertTo-DenGoEngineFailure $Tx $FailedSet
    if (DgEq ([string]$f.ErrorCode) 'InstalledStateWriteFailed') { $f.ErrorCode = 'UninstalledStateWriteFailed' }
    if (DgEq ([string]$f.FailedSet) 'InstallerState') { $f.FailedSet = 'UninstalledState' }
    return $f
}
function DgU-NewResult {
    $r = DgP-NewResult
    foreach ($p in @(@('Plan',$null),@('Blocking',[object[]]@()),@('AlreadyUninstalled',$false),@('Reconfirmed',$false),@('UninstalledState',$null),@('ResidualFiles',[object[]]@()),@('Counts',$null),@('DeferredRecords',[object[]]@()),@('ContaminationSuspect',$false),@('ContaminationReasons',[string[]]@()),@('ManualCheckReasons',[string[]]@()),@('Generation',$null))) {
        $r | Add-Member -NotePropertyName $p[0] -NotePropertyValue $p[1] -Force
    }
    return $r
}
function DgU-Fail {
    param([object]$Res,[string]$Code,[string]$Message,[bool]$Manual)
    $Res.Succeeded = $false; $Res.ErrorCode = $Code; $Res.ErrorMessage = $Message; $Res.ManualCheckRequired = $Manual
    return $Res
}
function DgU-ApplyPlanToResult {
    param([object]$Res,[object]$Plan)
    $Res.Plan = $Plan
    $Res.Blocking = [object[]]@($Plan.Blocking)
    $Res.ContaminationSuspect = [bool]$Plan.Generation.ContaminationSuspect
    $Res.ContaminationReasons = [string[]]@($Plan.Generation.ContaminationReasons)
    $Res.Generation = $Plan.Generation
    $Res.DeferredRecords = [object[]]@($Plan.DeferredRecords)
    $all = @($Plan.ShortcutDecisions) + @($Plan.FileDecisions)
    $Res.ResidualFiles = [object[]]@($all | Where-Object { $_.Residual -and $_.Decision -ne 'SupersededByCurrent' } | ForEach-Object { DgU-ResidualEntry $_ })
    $Res.Counts = Get-DenGoUninstallCounts $all
    return $Res
}

# ---------------------------------------------------------------- the whole uninstall (called by the engine)
function Invoke-DenGoProductUninstall {
    param([object]$Layout,[hashtable]$Options = @{})
    $res = DgU-NewResult
    $lockName = Get-DenGoLockName
    $acquired = $false
    try {
        # (1) the common lock comes first: a loser creates nothing
        $lock = $null
        try { $lock = DgLock-TryAcquire $lockName 'Explicit' } catch { return (DgU-Fail $res 'AnotherOperationRunning' ('The operation lock could not be taken: ' + [string](DgError-Root $_.Exception).Message) $false) }
        if (-not $lock.Acquired) { return (DgU-Fail $res 'AnotherOperationRunning' ('Another DenGo setup or uninstall operation is running (' + [string]$lock.Reason + ').') $false) }
        $acquired = $true
        $res.LockAcquired = $true
        # (2) process gate A (the engine keeps Assert-TargetProcessesStopped)
        try { DgP-InvokeProcessGate $Options 'A' } catch { return (DgU-Fail $res 'BlockedByRunningProcesses' ([string]$_.Exception.Message) $false) }
        try {
            # (3) interrupted state first: nothing new starts unless the recovery gate says NotNeeded
            $gate = Get-DenGoUninstallRecoveryGate $Layout 'Apply'
            $res.Recovery = $gate
            if (-not $gate.Proceed) {
                $res.ErrorCode = [string]$gate.ErrorCode; $res.ErrorMessage = [string]$gate.Detail; $res.ManualCheckRequired = [bool]$gate.ManualCheckRequired
                $res.Reasons = [object[]]@($gate.Reasons); $res.ReportPath = [string]$gate.ReportPath; $res.TransactionId = [string]$gate.TransactionId; $res.RecoveryOutcome = [string]$gate.Outcome
                return $res
            }
            # (4) the states (never swallowed)
            $prev = $null
            try { $prev = Read-DenGoPreviousState $Layout } catch { return (DgU-Fail $res (DgError-Code $_.Exception) ([string](DgError-Root $_.Exception).Message) $true) }
            $us = Read-DenGoUninstalledState $Layout
            $now = $null
            $closeIS = [bool]$prev.Exists
            $plan = $null
            if ($prev.Exists) {
                $plan = Get-DenGoUninstallPlan $Layout $prev $us $Options
                [void](DgU-ApplyPlanToResult $res $plan)
                if (@($plan.Blocking).Count -gt 0 -or [string]$plan.ArchiveCollision -ne '') {
                    $code = Get-DenGoUninstallBlockingCode $plan
                    $first = @($plan.Blocking | Select-Object -First 1)
                    $msg = $(if ($first.Count -gt 0) { [string]$first[0].Reason + ' (' + [string]$first[0].Destination + ')' } else { [string]$plan.ArchiveCollision })
                    return (DgU-Fail $res $code ('No change was made: ' + $msg) $true)
                }
            } else {
                $chk = Test-DenGoAlreadyUninstalled $Layout $prev $us
                if (-not $chk.Ok) { return (DgU-Fail $res ([string]$chk.Code) ([string]$chk.Reason) $true) }
                $res.AlreadyUninstalled = $true
                $arch = Get-DenGoUninstallArchivePlan $Layout $prev $us
                if ([string]$arch.Collision -ne '') { return (DgU-Fail $res 'HistoryArchiveCollision' ([string]$arch.Collision) $true) }
                $plan = [pscustomobject]@{ Generation = (Get-DenGoUninstallGeneration $prev $us); FileDecisions = [object[]]@(); ShortcutDecisions = [object[]]@(); Archive = $arch; Blocking = [object[]]@(); ArchiveCollision = ''; DeferredRecords = [object[]]@(); IncludeInputProfiles = [bool](DgProp $Options 'IncludeInputProfiles' $false); ProductVersion = [string](DgProp (DgProp $us 'State' $null) 'ProductVersion' '') }
                $res.Plan = $plan
            }
            # (5) items, policy, leaf gate, freshness
            $built = $null; $policy = $null
            try {
                $built = Convert-DenGoUninstallPlanToItems $Layout $plan $closeIS
                $extra = New-Object System.Collections.ArrayList
                foreach ($m in @($built.Metas)) {
                    $spec = Get-DenGoUninstallRoleSpec $Layout $m.Role $m.Root
                    if (-not $spec.Ok) { throw (DgError 'PlanInvalid' ('Role ' + $m.Role + ' rejected for ' + $m.Destination + ': ' + $spec.Reason)) }
                    [void]$extra.Add([string]$spec.PolicyRoot)
                    foreach ($kind in @(@('Dest',$m.Destination),@('Tmp',($m.Destination + (DgConst-TmpSuffix))))) {
                        $g = Test-DenGoUninstallLeafGate $Layout $m.Role $m.Root $kind[1] $kind[0]
                        if (-not $g.Allowed) { throw (DgError 'PlanInvalid' ('Leaf gate (' + $kind[0] + ' ' + $g.Reason + '): ' + $kind[1])) }
                    }
                    foreach ($dir in (Get-DenGoExpectedDirs $m.Destination)) {
                        $g = Test-DenGoUninstallLeafGate $Layout $m.Role $m.Root $dir 'Dir'
                        if (-not $g.Allowed) { throw (DgError 'PlanInvalid' ('Leaf gate (Dir ' + $g.Reason + '): ' + $dir)) }
                    }
                    if ([string]$m.Source -ne '' -and ($m.Kind -eq 'File' -or $m.Kind -eq 'Shortcut')) {
                        $sg = Test-DenGoUninstallSourceGate $Layout $m.Source
                        if (-not $sg.Allowed) { throw (DgError 'PlanInvalid' ('Source gate (' + $sg.Reason + '): ' + $m.Source)) }
                    }
                }
                $policy = New-DenGoPathPolicy $Layout ([string[]]@($extra))
            } catch {
                return (DgU-Fail $res 'PlanInvalid' ([string](DgError-Root $_.Exception).Message) $false)
            }
            $stale = Test-DenGoUninstallPlanFresh $built.Metas $prev $us $Layout
            if ($null -ne $stale) { $res.TransactionCode = 'PlanStale'; return (DgU-Fail $res 'PlanStale' ([string]$stale.Detail) $false) }
            # (6) Begin -> check -> Apply -> factory -> Commit
            $fx = @{ Layout = $Layout; Plan = $plan; Prev = $prev; Us = $us; Metas = $built.Metas; Options = $Options; Reconfirm = $res.AlreadyUninstalled; OldUsSha = [string]$us.Sha; State = $null }
            $beginCheck = { param($c,$a) Test-DenGoUninstallBeginMatchesPlan $c $a.Metas $a.Layout $a.OldUsSha }
            $factory = {
                param($c,$a)
                try { DgP-InvokeProcessGate $a.Options 'B' } catch { throw (DgError 'BlockedByRunningProcesses' ([string]$_.Exception.Message) $_.Exception) }
                try {
                    $now = DgClock-Now
                    if ($a.Reconfirm) { $state = New-DenGoReconfirmedState $a.Us $a.Plan.Archive $c $now }
                    else { $state = New-DenGoUninstalledState $a.Plan $a.Prev $a.Us $c $now $a.Layout }
                    $a['State'] = $state
                    return (ConvertTo-DenGoStateBytes $state)
                } catch { throw (DgError 'StateBuildFailed' ([string]$_.Exception.Message) $_.Exception) }
            }
            $empty = (@($built.Items).Count -eq 0)
            $txResult = Invoke-DenGoTransaction -StateRoot $Layout.StateRoot -BackupRoot $Layout.BackupRoot -Operation 'Uninstall' -Items $built.Items -Policy $policy -NewStatePath (DgU-UninstalledStatePath $Layout) -NewStateFactory $factory -FactoryArgument $fx -BeginCheck $beginCheck -AllowEmptyTransaction:$empty
            $ctx = $txResult.Ctx
            $res.TransactionId = [string]$txResult.TransactionId
            $res.TransactionCode = [string]$txResult.Code
            $res.RollbackState = [string]$txResult.RollbackState
            $res.RecoveryOutcome = [string]$txResult.RecoveryOutcome
            $res.FailedItem = [int]$txResult.FailedItem
            $res.ReportPath = [string]$txResult.ReportPath
            $res.Reasons = [object[]]@($txResult.Reasons)
            $res.Succeeded = [bool]$txResult.Succeeded
            $res.StateCommitted = [bool]$txResult.Succeeded
            if ($null -ne $ctx) { $res.BackupRoot = [string]$ctx.BackupTxnDir }
            if ($res.Succeeded) {
                $res.ErrorCode = ''; $res.ErrorMessage = ''
                if ($null -ne $fx['State']) {
                    $res.UninstalledState = $fx['State']
                    # a reconfirmation carries the earlier uninstall record over, so its residuals and manual-check flag are reported again
                    $src = $res.UninstalledState
                    $resList = DgU-AsList (DgProp $src 'ResidualFiles' @())
                    $res.ResidualFiles = [object[]]@($resList)
                    $res.ManualCheckRequired = [bool](DgProp $src 'ManualCheckRequired' $false)
                    $res.ManualCheckReasons = [string[]]@(DgProp $src 'ManualCheckReasons' @())
                    $res.Counts = DgProp $src 'Counts' $null
                }
                $res.Results = [object[]]@(@($plan.ShortcutDecisions) + @($plan.FileDecisions) | Where-Object { $_.Decision -ne 'SupersededByCurrent' } | ForEach-Object { [pscustomobject]@{ Platform = $_.Platform; Component = $_.Component; Action = $_.Decision; Destination = $_.Destination; Changed = [bool]($_.Op.Length -gt 0); Succeeded = $true; Backup = '' } })
            } else {
                $failedSet = ''
                if ($null -ne $ctx -and [int]$txResult.FailedItem -ge 0 -and [int]$txResult.FailedItem -lt @($ctx.Items).Count) {
                    $tag = DgP-ParseTag ([string]@($ctx.Items)[[int]$txResult.FailedItem].Tag)
                    if ($null -ne $tag) { $failedSet = $tag.Platform }
                }
                $f = ConvertTo-DenGoUninstallFailure $txResult $failedSet
                $res.ErrorCode = $f.ErrorCode; $res.ErrorMessage = $f.ErrorMessage; $res.FailedSet = $f.FailedSet
                $res.RollbackAttempted = $f.RollbackAttempted; $res.RollbackSucceeded = $f.RollbackSucceeded; $res.RollbackError = $f.RollbackError; $res.ManualCheckRequired = $f.ManualCheckRequired
                $res.Results = [object[]]@([pscustomobject]@{ Platform = $f.FailedSet; Component = 'Set'; Action = 'Failed'; Destination = ''; Changed = $false; Succeeded = $false; ErrorCode = $f.ErrorCode; ErrorMessage = $f.ErrorMessage })
            }
            return $res
        } catch {
            # fail closed: an unexpected error before or around the transaction never escapes as an exception
            # (after a committed state the uninstall stays a success: only the reporting around it failed)
            if (-not $res.StateCommitted) {
                $res.Succeeded = $false
                if ($res.ErrorCode.Length -eq 0) { $res.ErrorCode = 'ProductApplyFailed' }
                $res.ErrorMessage = [string](DgError-Root $_.Exception).Message
                $res.ManualCheckRequired = $true
            }
            return $res
        }
    } finally {
        if ($acquired) { [void](DgLock-Release $lockName) }
    }
}

# ---------------------------------------------------------------- dry run: no lock, nothing written, nothing recovered
function Get-DenGoUninstallDryRun {
    param([object]$Layout,[hashtable]$Options = @{})
    $res = DgU-NewResult
    $res.Succeeded = $true
    try {
        $gate = Get-DenGoUninstallRecoveryGate $Layout 'DryRun'
        $res.Recovery = $gate
        $res.ManualCheckRequired = [bool]$gate.ManualCheckRequired
        $res.Reasons = [object[]]@($gate.Reasons)
        $res.TransactionId = [string]$gate.TransactionId
        if (-not $gate.Proceed) { $res.ErrorCode = [string]$gate.ErrorCode; $res.ErrorMessage = [string]$gate.Detail; return $res }
        $prev = $null
        try { $prev = Read-DenGoPreviousState $Layout } catch { $res.ErrorCode = (DgError-Code $_.Exception); $res.ErrorMessage = [string](DgError-Root $_.Exception).Message; return $res }
        $us = Read-DenGoUninstalledState $Layout
        if (-not $prev.Exists) {
            $chk = Test-DenGoAlreadyUninstalled $Layout $prev $us
            if ($chk.Ok) { $res.AlreadyUninstalled = $true; return $res }
            $res.ErrorCode = [string]$chk.Code; $res.ErrorMessage = [string]$chk.Reason
            return $res
        }
        $plan = Get-DenGoUninstallPlan $Layout $prev $us $Options
        [void](DgU-ApplyPlanToResult $res $plan)
        if (@($plan.Blocking).Count -gt 0 -or [string]$plan.ArchiveCollision -ne '') { $res.ErrorCode = Get-DenGoUninstallBlockingCode $plan }
    } catch {
        $res.ErrorCode = 'ProductApplyFailed'; $res.ErrorMessage = [string](DgError-Root $_.Exception).Message
    }
    return $res
}
