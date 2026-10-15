# DenGo installer product apply layer (I2-B). ASCII only. Functions only; no top-level side effects.
# Dot-source DenGoInstallerTransaction.ps1 FIRST. The product engine and the tests dot-source this file.
#
# Contract summary
#   - The common lock (DgLock-TryAcquire) is held from the first check to the last result mapping; it is released in finally.
#   - Order: lock -> process gate A -> recovery gate -> previous-state read -> shortcut staging -> plan conversion -> leaf gate -> freshness -> Begin -> Apply -> Commit.
#   - Every destination is registered in the journal by DgTx-Begin before anything is changed; the product leaf gate allows only fixed leaves.
#   - PCSX2 / LilyPad items are never part of the transaction (Deferred until I3); they are reported as Action='Deferred'.
#   - An old-format installing.json is never converted or deleted: LegacyMarkerUnsupported (RepairRequired).
#   - The ownership merge only adds fields (SchemaVersion stays 1); records that were not part of this plan are carried forward.

function Get-DenGoLockName { return 'Local\DenGoControllerConverter.Transaction' }   # provisional: Global/Local and DACL are decided in I2-D
function DgP-SetOrder { return @('Core','BVE5','BVE6','BveEX Current','AtsEX Legacy','RPCS3','Shortcut') }
function DgP-ShortcutFileName { return 'DenGo Controller Converter.lnk' }
function DgP-DefaultTxnIdPattern { return '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' }

# ---------------------------------------------------------------- small helpers (pure)
function DgP-Full { param([string]$Path) return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([char]92,[char]47)) }
function DgP-PathEq { param([string]$A,[string]$B) return (DgEqI (DgP-Full $A) (DgP-Full $B)) }
function DgP-Join { param([string]$A,[string]$B) return [System.IO.Path]::Combine($A,$B) }
function DgP-Gate { param([bool]$Allowed,[string]$GateReason) return [pscustomobject]@{ Allowed = $Allowed; Reason = $GateReason } }
function DgP-Reason { param([string]$Code,[string]$Detail,[int]$Item = -1) return [pscustomobject]@{ Code = $Code; Item = $Item; Detail = $Detail } }
function DgP-InSet { param([string]$Path,[string[]]$Set) foreach ($s in @($Set)) { if (DgP-PathEq $Path $s) { return $true } } return $false }
function DgP-ParseTag {
    param([string]$Tag)
    $parts = $Tag.Split([char]124)
    if ($parts.Length -ne 4) { return $null }
    return [pscustomobject]@{ Platform = $parts[0]; Component = $parts[1]; Role = $parts[2]; Root = $parts[3] }
}
function DgP-IsProfileComponent { param([string]$Component) return ((DgEq $Component 'InputProfile') -or (DgEq $Component 'EffectiveInputProfile')) }
# A root folder that is itself a junction or a symbolic link redirects every path below it elsewhere: it is never a root.
# A cloud-sync folder (the OneDrive folder carries a reparse point that is NOT a link, LinkType empty) is a normal root.
# An unreadable folder counts as a link (fail-closed). The paths BELOW the root are checked by the policy (any reparse point is refused).
function DgP-IsReparsePoint {
    param([string]$Path)
    try {
        if (-not [System.IO.Directory]::Exists($Path)) { return $false }
        if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
        return (([string](Get-Item -LiteralPath $Path -Force).LinkType).Length -gt 0)
    } catch { return $true }
}

# ---------------------------------------------------------------- layout
function Get-DenGoProductLayout {
    param([string]$LocalAppData,[string]$PublicRoot = 'C:\Users\Public',[string]$ShortcutPath = '',[string]$BackupRoot = '',[string]$TxnIdPattern = '')
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw (DgError 'PlanInvalid' 'LOCALAPPDATA is empty.') }
    $l = DgP-Full $LocalAppData
    $pub = DgP-Full $PublicRoot
    $programs = DgP-Join $l 'Programs'
    $appDir = DgP-Join $programs 'DenGo Controller Converter'
    $dataRoot = DgP-Join $l 'DenGo Controller Converter'
    $stateRoot = DgP-Join $dataRoot 'InstallerState'
    $backup = DgP-Join $dataRoot 'InstallerBackups'
    if ($BackupRoot.Length -gt 0) { $backup = DgP-Full $BackupRoot }
    $pattern = $TxnIdPattern
    if ($pattern.Length -eq 0) { $pattern = DgP-DefaultTxnIdPattern }
    $sc = ''
    if ($ShortcutPath.Length -gt 0) { $sc = DgP-Full $ShortcutPath }
    return [pscustomobject]@{
        LocalAppData = $l; ProgramsDir = $programs; AppDir = $appDir
        AppExe = (DgP-Join $appDir 'DenGoControllerConverter.exe'); AppIco = (DgP-Join $appDir 'DenGo-Controller-Converter.ico')
        DataRoot = $dataRoot; StateRoot = $stateRoot; BackupRoot = $backup; StatePath = (DgP-Join $stateRoot 'installed-state.json')
        PublicRoot = $pub
        CurrentExt = (DgP-Join $pub 'Documents\BveEx\2.0\Extensions'); LegacyExt = (DgP-Join $pub 'Documents\BveEx\Legacy\Extensions')
        ShortcutPath = $sc; TxnIdPattern = $pattern
    }
}

# ---------------------------------------------------------------- PE machine (read-only header probe)
function DgP-ReadHeader {
    param([string]$Path,[int]$Count)
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $buffer = New-Object byte[] $Count
        $n = $stream.Read($buffer,0,$Count)
        if ($n -lt $Count) { $trim = New-Object byte[] $n; [System.Array]::Copy($buffer,$trim,$n); return ,$trim }
        return ,$buffer
    } finally { $stream.Dispose() }
}
function DgP-PeMachine {
    param([string]$Path)
    try { $b = [byte[]](DgP-ReadHeader $Path 4096) } catch { return 'Unreadable' }
    if ($b.Length -lt 64) { return 'NotPE' }
    if ($b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return 'NotPE' }
    $off = [System.BitConverter]::ToInt32($b,0x3C)
    if ($off -lt 0 -or ($off + 6) -gt $b.Length) { return 'InvalidPE' }
    if ($b[$off] -ne 0x50 -or $b[$off + 1] -ne 0x45 -or $b[$off + 2] -ne 0 -or $b[$off + 3] -ne 0) { return 'InvalidPE' }
    $m = [System.BitConverter]::ToUInt16($b,$off + 4)
    if ($m -eq 0x014C) { return 'x86' }
    if ($m -eq 0x8664) { return 'x64' }
    return 'Other'
}

# ---------------------------------------------------------------- roles and the leaf gate
# A role spec lists the EXACT destinations and folders a role may touch. Nothing else is allowed (the policy roots are wider on purpose:
# the core requires every path, including folders to create, to be strictly below an allowed root).
function Get-DenGoRoleSpec {
    param([object]$Layout,[string]$Role,[string]$Root = '')
    $spec = [pscustomobject]@{ Ok = $false; Reason = ''; Role = $Role; PolicyRoot = ''; Dests = [string[]]@(); Dirs = [string[]]@() }
    if (DgEq $Role 'App') {
        $spec.PolicyRoot = $Layout.LocalAppData; $spec.Dests = [string[]]@($Layout.AppExe,$Layout.AppIco); $spec.Dirs = [string[]]@($Layout.ProgramsDir,$Layout.AppDir); $spec.Ok = $true
        return $spec
    }
    if ((DgEq $Role 'Bve5') -or (DgEq $Role 'Bve6')) {
        $c = DgPath-Check $Root
        if (-not $c.Ok) { $spec.Reason = 'RootInvalid'; return $spec }
        $r = DgP-Full $c.Normalized
        $exe = DgP-Join $r 'BveTs.exe'
        if (-not (DgFs-Exists $exe)) { $spec.Reason = 'BveRootHasNoExe'; return $spec }
        $want = $(if (DgEq $Role 'Bve5') { 'x86' } else { 'x64' })
        if (-not (DgEq (DgP-PeMachine $exe) $want)) { $spec.Reason = 'BveMachineMismatch'; return $spec }
        $inputDevices = DgP-Join $r 'Input Devices'
        $spec.PolicyRoot = $r; $spec.Dests = [string[]]@((DgP-Join $inputDevices 'DenGoControllerConverter.dll')); $spec.Dirs = [string[]]@($inputDevices); $spec.Ok = $true
        return $spec
    }
    if (DgEq $Role 'Current') {
        $spec.PolicyRoot = $Layout.CurrentExt; $spec.Dests = [string[]]@((DgP-Join $Layout.CurrentExt 'DenGoVehicleSpec.BveEx.Bridge.dll'),(DgP-Join $Layout.CurrentExt 'DenGoBveVehicleSpec.dll')); $spec.Ok = $true
        return $spec
    }
    if (DgEq $Role 'Legacy') {
        $spec.PolicyRoot = $Layout.LegacyExt; $spec.Dests = [string[]]@((DgP-Join $Layout.LegacyExt 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll'),(DgP-Join $Layout.LegacyExt 'DenGoAtsExLegacyVehicleSpec.dll')); $spec.Ok = $true
        return $spec
    }
    if (DgEq $Role 'Rpcs3') {
        $c = DgPath-Check $Root
        if (-not $c.Ok) { $spec.Reason = 'RootInvalid'; return $spec }
        $g = DgP-Full $c.Normalized
        if (-not $g.EndsWith('\config\input_configs\global',[System.StringComparison]::OrdinalIgnoreCase)) { $spec.Reason = 'Rpcs3RootInvalid'; return $spec }
        $x = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($g)))
        if ([string]::IsNullOrEmpty($x) -or -not (DgFs-Exists (DgP-Join $x 'rpcs3.exe'))) { $spec.Reason = 'Rpcs3RootHasNoExe'; return $spec }
        if (-not (DgFs-DirExists $g)) { $spec.Reason = 'Rpcs3RootMissing'; return $spec }
        $spec.PolicyRoot = $g; $spec.Dests = [string[]]@((DgP-Join $g 'Den-Go-Controller.yml')); $spec.Ok = $true
        return $spec
    }
    if (DgEq $Role 'Shortcut') {
        # The root (the Desktop folder of THIS transaction) travels in the journaled tag, like a BVE folder: a recovery never depends on
        # the shortcut option or the Desktop of the next run. The only destination is the fixed leaf directly below that root.
        if ($Root.Length -eq 0) { $spec.Reason = 'ShortcutNotConfigured'; return $spec }
        $c = DgPath-Check $Root
        if (-not $c.Ok) { $spec.Reason = 'RootInvalid'; return $spec }
        $r = DgP-Full $c.Normalized
        if (-not (DgEqI $r $Root) -or $r.Length -le 3) { $spec.Reason = 'ShortcutRootInvalid'; return $spec }   # the recorded root must be the normalized folder, never a drive root
        if (DgP-IsReparsePoint $r) { $spec.Reason = 'ShortcutRootReparse'; return $spec }
        $spec.PolicyRoot = $r; $spec.Dests = [string[]]@((DgP-Join $r (DgP-ShortcutFileName))); $spec.Ok = $true
        return $spec
    }
    $spec.Reason = 'RoleUnknown'
    return $spec
}
function DgP-InfraGate {
    param([object]$Layout,[string]$Full,[string]$TxnId)
    $s = $Layout.StateRoot; $b = $Layout.BackupRoot
    $exact = @($Layout.DataRoot,$s,(DgP-Join $s 'txn'),(DgP-Join $s 'history'),$b,$Layout.StatePath,($Layout.StatePath + '.tmp'),
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
function DgP-BackupGate {
    param([object]$Layout,[string]$Full,[string]$TxnId)
    $parent = [System.IO.Path]::GetDirectoryName($Full)
    if ([string]::IsNullOrEmpty($parent)) { return (DgP-Gate $false 'LeafNotAllowed') }
    $gp = [System.IO.Path]::GetDirectoryName($parent)
    if (-not [string]::IsNullOrEmpty($gp) -and (DgP-PathEq $gp $Layout.BackupRoot)) {
        $id = [System.IO.Path]::GetFileName($parent)
        $leaf = [System.IO.Path]::GetFileName($Full)
        if (($id -cmatch $Layout.TxnIdPattern) -and (($TxnId.Length -eq 0) -or (DgEq $id $TxnId)) -and ($leaf -cmatch '^[0-9]{4}\.bak$')) { return (DgP-Gate $true '') }
    }
    return (DgP-Gate $false 'LeafNotAllowed')
}
# Kind: Dest | Tmp | Dir | Backup | Infra
function Test-DenGoLeafGate {
    param([object]$Layout,[string]$Role,[string]$Root,[string]$Path,[string]$Kind,[string]$TxnId = '')
    $c = DgPath-Check $Path
    if (-not $c.Ok) { return (DgP-Gate $false $c.Reason) }
    $full = DgP-Full $c.Normalized
    if (DgEq $Kind 'Infra') { return (DgP-InfraGate $Layout $full $TxnId) }
    if (DgEq $Kind 'Backup') { return (DgP-BackupGate $Layout $full $TxnId) }
    if (-not ((DgEq $Kind 'Dest') -or (DgEq $Kind 'Tmp') -or (DgEq $Kind 'Dir'))) { return (DgP-Gate $false 'KindUnknown') }
    $spec = Get-DenGoRoleSpec $Layout $Role $Root
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
# Gate for the journaled facts of one item (used after Begin and before a recovery). Returns the list of failures.
function Test-DenGoItemGate {
    param([object]$Layout,[string]$Tag,[string]$Norm,[string]$Tmp,[string[]]$Dirs,[string]$Backup,[string]$TxnId)
    $failures = New-Object System.Collections.ArrayList
    $t = DgP-ParseTag $Tag
    if ($null -eq $t) { [void]$failures.Add('TagInvalid: ' + $Tag); return ,[string[]]@($failures) }
    $g = Test-DenGoLeafGate $Layout $t.Role $t.Root $Norm 'Dest'
    if (-not $g.Allowed) { [void]$failures.Add('Dest ' + $g.Reason + ': ' + $Norm) }
    $g = Test-DenGoLeafGate $Layout $t.Role $t.Root $Tmp 'Tmp'
    if (-not $g.Allowed) { [void]$failures.Add('Tmp ' + $g.Reason + ': ' + $Tmp) }
    foreach ($d in @($Dirs)) {
        $g = Test-DenGoLeafGate $Layout $t.Role $t.Root $d 'Dir'
        if (-not $g.Allowed) { [void]$failures.Add('Dir ' + $g.Reason + ': ' + $d) }
    }
    if ($Backup.Length -gt 0) {
        $g = Test-DenGoLeafGate $Layout $t.Role $t.Root $Backup 'Backup' $TxnId
        if (-not $g.Allowed) { [void]$failures.Add('Backup ' + $g.Reason + ': ' + $Backup) }
    }
    return ,[string[]]@($failures)
}
function Get-DenGoExpectedDirs {
    param([string]$Destination)
    $dirs = New-Object System.Collections.ArrayList
    $parent = [System.IO.Path]::GetDirectoryName((DgP-Full $Destination))
    $guard = 0
    while (-not [string]::IsNullOrEmpty($parent) -and -not (DgFs-DirExists $parent) -and $guard -lt 64) { $guard++; [void]$dirs.Add($parent); $parent = [System.IO.Path]::GetDirectoryName($parent) }
    $dirs.Reverse()
    return ,[string[]]@($dirs)
}
function New-DenGoPathPolicy {
    param([object]$Layout,[string[]]$ExtraRoots = @())
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add($Layout.LocalAppData)
    # a backup root outside LOCALAPPDATA (tests only) needs the root that contains it
    if (-not (DgP-Full $Layout.BackupRoot).StartsWith($Layout.LocalAppData + [string][char]92,[System.StringComparison]::OrdinalIgnoreCase)) { [void]$roots.Add([System.IO.Path]::GetDirectoryName((DgP-Full $Layout.BackupRoot))) }
    foreach ($r in @($ExtraRoots)) { if ($r.Length -gt 0 -and -not (DgP-InSet $r ([string[]]@($roots)))) { [void]$roots.Add($r) } }
    return (DgPolicy-New -AllowedRoots ([string[]]@($roots)) -ReparseMode 'Reject')
}

# ---------------------------------------------------------------- plan conversion
function DgP-MapPlatform {
    param([string]$Platform,[string]$Destination)
    if (DgEq $Platform 'Core') { return @{ Role = 'App'; Root = ''; Set = 'Core'; Deferred = $false } }
    if ((DgEq $Platform 'BVE5') -or (DgEq $Platform 'BVE6')) {
        $root = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName((DgP-Full $Destination)))
        return @{ Role = $(if (DgEq $Platform 'BVE5') { 'Bve5' } else { 'Bve6' }); Root = $root; Set = $Platform; Deferred = $false }
    }
    if (DgEq $Platform 'BveEX Current') { return @{ Role = 'Current'; Root = ''; Set = $Platform; Deferred = $false } }
    if (DgEq $Platform 'AtsEX Legacy') { return @{ Role = 'Legacy'; Root = ''; Set = $Platform; Deferred = $false } }
    if (DgEq $Platform 'RPCS3') { return @{ Role = 'Rpcs3'; Root = [System.IO.Path]::GetDirectoryName((DgP-Full $Destination)); Set = $Platform; Deferred = $false } }
    if (DgEq $Platform 'PCSX2') { return @{ Role = 'Deferred'; Root = ''; Set = $Platform; Deferred = $true } }
    throw (DgError 'PlanInvalid' ('Unsupported platform in the plan: ' + $Platform))
}
function Convert-DenGoPlanToEntries {
    param([object]$Layout,[object[]]$Plan,[object]$ShortcutStage = $null)
    $entries = New-Object System.Collections.ArrayList
    foreach ($p in @($Plan)) {
        $platform = [string]$p.Platform; $component = [string]$p.Component; $action = [string]$p.Action
        $dest = [string]$p.Destination
        if (-not ((DgEq $action 'Add') -or (DgEq $action 'UpdateOrRepair') -or (DgEq $action 'Unchanged') -or (DgEq $action 'PreserveUserModified') -or (DgEq $action 'NotInitialized'))) { throw (DgError 'PlanInvalid' ('Unsupported Apply action: ' + $action)) }
        $m = DgP-MapPlatform $platform $dest
        $isWrite = ((DgEq $action 'Add') -or (DgEq $action 'UpdateOrRepair'))
        [void]$entries.Add([pscustomobject]@{
            Kind = 'Plan'; Platform = $platform; Component = $component; Action = $action; Destination = $dest; Source = [string]$p.Source
            ExpectedDestSha = [string]$p.DestinationSHA256; ExpectedSourceSha = [string]$p.SourceSHA256
            Role = [string]$m.Role; Root = [string]$m.Root; Set = [string]$m.Set; Deferred = [bool]$m.Deferred; IsTx = ($isWrite -and -not [bool]$m.Deferred) })
    }
    if ($null -ne $ShortcutStage -and $ShortcutStage.Ok) {
        # Root = the normalized Desktop folder: it is journaled in the tag, so an interrupted transaction is recovered from the journal alone.
        # Unchanged / Diverged (the user edited our shortcut) never become items.
        $scAction = [string]$ShortcutStage.Action
        [void]$entries.Add([pscustomobject]@{
            Kind = 'Shortcut'; Platform = 'Shortcut'; Component = 'Desktop'; Action = $scAction; Destination = $Layout.ShortcutPath; Source = [string]$ShortcutStage.StagePath
            ExpectedDestSha = [string]$ShortcutStage.ExistingSha; ExpectedSourceSha = [string]$ShortcutStage.Sha
            Role = 'Shortcut'; Root = (DgP-Full ([System.IO.Path]::GetDirectoryName($Layout.ShortcutPath))); Set = 'Shortcut'; Deferred = $false
            IsTx = (-not ((DgEq $scAction 'Unchanged') -or (DgEq $scAction 'Diverged'))); ShortcutFacts = $ShortcutStage.Facts })
    }
    return ,[object[]]@($entries)
}
# Transaction items in apply order: Set order, plan order inside a Set (a stable order; Sort-Object is not stable).
function Get-DenGoTxItems {
    param([object[]]$Entries)
    $ordered = New-Object System.Collections.ArrayList
    foreach ($set in (DgP-SetOrder)) { foreach ($e in @($Entries)) { if ($e.IsTx -and (DgEq $e.Set $set)) { [void]$ordered.Add($e) } } }
    foreach ($e in @($Entries)) { if ($e.IsTx -and -not (DgP-InSet $e.Set ([string[]](DgP-SetOrder)))) { throw (DgError 'PlanInvalid' ('Unknown set: ' + $e.Set)) } }
    $items = New-Object System.Collections.ArrayList
    foreach ($e in $ordered) {
        [void]$items.Add(@{ Op = 'Write'; Source = $e.Source; Destination = $e.Destination; OwnershipCandidate = $e.Action; Tag = ($e.Platform + '|' + $e.Component + '|' + $e.Role + '|' + $e.Root) })
    }
    return [pscustomobject]@{ Items = [object[]]@($items); Ordered = [object[]]@($ordered) }
}

# ---------------------------------------------------------------- previous state
function Read-DenGoPreviousState {
    param([object]$Layout)
    $r = [pscustomobject]@{ Exists = $false; Sha = ''; State = $null; Files = [object[]]@() }
    if (-not (DgFs-Exists $Layout.StatePath)) { return $r }
    try {
        $bytes = [byte[]](DgFs-ReadAllBytesShared $Layout.StatePath)
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
        $obj = $text | ConvertFrom-Json
        if ($null -eq $obj) { throw 'empty' }
        if ([int](DgProp $obj 'SchemaVersion' 0) -ne 1) { throw 'schema' }
        $files = @(DgProp $obj 'Files' @())
        $seen = @{}
        foreach ($f in $files) {
            $d = [string](DgProp $f 'Destination' '')
            if ($d.Length -eq 0) { throw 'record without destination' }
            $k = $d.ToUpperInvariant()
            if ($seen.ContainsKey($k)) { throw (DgError 'InstalledStateAmbiguous' ('Duplicate destination in the installed state: ' + $d)) }
            $seen[$k] = $true
        }
        $r.Exists = $true; $r.Sha = (DgSha256-Bytes $bytes); $r.State = $obj; $r.Files = [object[]]$files
        return $r
    } catch {
        $code = DgError-Code $_.Exception
        if ($code.Length -eq 0) { $code = 'InstalledStateUnreadable' }
        throw (DgError $code ('The installed state cannot be used: ' + [string](DgError-Root $_.Exception).Message))
    }
}

# ---------------------------------------------------------------- freshness (PlanStale A and A')
function Test-DenGoPlanFresh {
    param([object[]]$Entries,[object]$Previous)
    foreach ($e in @($Entries)) {
        if ([bool]$e.Deferred) { continue }
        $curSha = ''
        if (DgFs-Exists $e.Destination) { $curSha = DgFs-Sha256 $e.Destination }
        if (-not (DgEq $curSha $e.ExpectedDestSha)) { return (DgP-Reason 'PlanStale' ('Destination changed since planning: ' + $e.Destination)) }
        if ($e.IsTx) {
            if (-not (DgFs-Exists $e.Source)) { return (DgP-Reason 'PlanStale' ('Source is missing: ' + $e.Source)) }
            if (-not (DgEq (DgFs-Sha256 $e.Source) $e.ExpectedSourceSha)) { return (DgP-Reason 'PlanStale' ('Source changed since planning: ' + $e.Source)) }
        }
    }
    return $null
}
# Runs right after Begin and before the first Intent: Begin's own measurement must agree with the plan.
function Test-DenGoBeginMatchesPlan {
    param([hashtable]$Ctx,[object[]]$Ordered,[object]$Previous,[object]$Layout)
    $items = @($Ctx.Items)
    if ($items.Count -ne @($Ordered).Count) { throw (DgError 'PlanStale' 'The registered item count differs from the plan.') }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]; $e = @($Ordered)[$i]
        $fails = Test-DenGoItemGate $Layout ([string]$it.Tag) ([string]$it.Norm) ([string]$it.Tmp) ([string[]]@($it.Dirs)) ([string]$it.Backup) ([string]$Ctx.TxnId)
        if ($fails.Count -ne 0) { throw (DgError 'PathRejected' ('Leaf gate: ' + [string]::Join('; ',$fails))) }
        if (-not (DgP-PathEq ([string]$it.Norm) ([string]$e.Destination))) { throw (DgError 'PlanStale' ('Registered destination differs from the plan: ' + $it.Norm)) }
        $expectExists = ($e.ExpectedDestSha.Length -gt 0)
        if (([bool]$it.PreExists -ne $expectExists) -or -not (DgEq ([string]$it.PreSha) $e.ExpectedDestSha)) { throw (DgError 'PlanStale' ('Destination changed between planning and Begin: ' + $it.Norm)) }
    }
    if (-not (DgEq ([string]$Ctx.OldStateSha) ([string]$Previous.Sha))) { throw (DgError 'PlanStale' 'The installed state changed since it was read.') }
}

# ---------------------------------------------------------------- shortcut staging (the only place that touches a temporary folder)
function DgPFs-NewStageDir { param([string]$Parent) $d = [System.IO.Path]::Combine($Parent,('DenGoShortcutStage-' + [System.Guid]::NewGuid().ToString('N'))); [System.IO.Directory]::CreateDirectory($d) | Out-Null; return $d }
function DgPFs-NewShortcutFile {
    param([string]$Path,[string]$Target,[string]$WorkingDirectory,[string]$IconLocation)
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    $s.TargetPath = $Target; $s.WorkingDirectory = $WorkingDirectory; $s.IconLocation = $IconLocation
    $s.Save()
}
function DgPFs-ReadShortcut {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    return [pscustomobject]@{ TargetPath = [string]$s.TargetPath; WorkingDirectory = [string]$s.WorkingDirectory; IconLocation = [string]$s.IconLocation }
}
function DgPFs-DeleteStageFile { param([string]$Path) [System.IO.File]::Delete($Path) }
function DgPFs-RemoveStageDir { param([string]$Path) if ([System.IO.Directory]::Exists($Path) -and @([System.IO.Directory]::GetFileSystemEntries($Path)).Count -eq 0) { [System.IO.Directory]::Delete($Path,$false) } }

# What a shortcut says (target, folder, icon): the identity of a shortcut. Never throws.
function DgP-FactsEqual {
    param([object]$A,[object]$B)
    try {
        return ((DgP-PathEq ([string](DgProp $A 'TargetPath' '')) ([string](DgProp $B 'TargetPath' ''))) -and (DgP-PathEq ([string](DgProp $A 'WorkingDirectory' '')) ([string](DgProp $B 'WorkingDirectory' ''))) -and (DgEqI ([string](DgProp $A 'IconLocation' '')) ([string](DgProp $B 'IconLocation' ''))))
    } catch { return $false }
}
# The shortcut record of the earlier generation when it is usable as the owner of the shortcut that exists now (else $null).
function DgP-PreviousShortcut {
    param([object]$Previous,[string]$Path)
    if ($null -eq $Previous -or -not [bool]$Previous.Exists -or $null -eq $Previous.State) { return $null }
    $sc = DgProp $Previous.State 'Shortcut' $null
    if ($null -eq $sc -or -not [bool](DgProp $sc 'Created' $false)) { return $null }
    if (-not (DgP-PathEq ([string](DgProp $sc 'Path' '')) $Path)) { return $null }
    return $sc
}

# Never throws: a failure only means "no shortcut item" and carries the reason.
# Previous = the earlier installed state (Read-DenGoPreviousState): a shortcut that this product created and that was edited afterwards
# is reported as Diverged and is never overwritten.
function New-DenGoStagedShortcut {
    param([object]$Layout,[string]$StageParent,[object]$Previous = $null)
    $r = [pscustomobject]@{ Ok = $false; Error = ''; StageDir = ''; StagePath = ''; Sha = ''; ExistingSha = ''; Action = ''; Unchanged = $false; Facts = $null }
    try {
        if ($Layout.ShortcutPath.Length -eq 0) { $r.Error = 'ShortcutPathUnavailable'; return $r }
        $dir = [System.IO.Path]::GetDirectoryName($Layout.ShortcutPath)
        if (-not (DgFs-DirExists $dir)) { $r.Error = 'ShortcutFolderMissing'; return $r }
        if (DgP-IsReparsePoint $dir) { $r.Error = 'ShortcutPathRejected: ShortcutRootReparse'; return $r }
        $policy = DgPolicy-New -AllowedRoots ([string[]]@($dir)) -ReparseMode 'Reject'
        foreach ($p in @($Layout.ShortcutPath,($Layout.ShortcutPath + (DgConst-TmpSuffix)))) {
            $t = DgPolicy-TestPath $policy $p
            if (-not $t.Allowed) { $r.Error = 'ShortcutPathRejected: ' + $t.Reason; return $r }
        }
        $r.StageDir = DgPFs-NewStageDir $StageParent
        $r.StagePath = DgP-Join $r.StageDir (DgP-ShortcutFileName)
        DgPFs-NewShortcutFile $r.StagePath $Layout.AppExe $Layout.AppDir ($Layout.AppIco + ',0')
        $v = DgPFs-ReadShortcut $r.StagePath
        if (-not (DgP-PathEq $v.TargetPath $Layout.AppExe) -or -not (DgP-PathEq $v.WorkingDirectory $Layout.AppDir) -or -not (DgP-PathEq ($v.IconLocation.Split(',')[0]) $Layout.AppIco)) { $r.Error = 'ShortcutVerificationFailed'; return $r }
        $r.Sha = DgFs-Sha256 $r.StagePath
        $r.Facts = [pscustomobject]@{ TargetPath = [string]$v.TargetPath; WorkingDirectory = [string]$v.WorkingDirectory; IconLocation = [string]$v.IconLocation }
        if (DgFs-Exists $Layout.ShortcutPath) {
            $r.ExistingSha = DgFs-Sha256 $Layout.ShortcutPath
            # The bytes of a shortcut depend on whether its target existed when it was saved, so an earlier install of this very
            # shortcut never matches by SHA. What it says (target, folder, icon) decides: an equal shortcut is left as it is.
            $same = $false; $e = $null
            if (DgEq $r.ExistingSha $r.Sha) { $same = $true }
            else {
                try {
                    $e = DgPFs-ReadShortcut $Layout.ShortcutPath
                    $same = ((DgP-PathEq $e.TargetPath $Layout.AppExe) -and (DgP-PathEq $e.WorkingDirectory $Layout.AppDir) -and (DgP-PathEq ($e.IconLocation.Split(',')[0]) $Layout.AppIco) -and ($e.IconLocation.EndsWith(',0',[System.StringComparison]::Ordinal)))
                } catch { $same = $false }
            }
            if ($same) { $r.Action = 'Unchanged' }
            else {
                # a shortcut this product created earlier (recorded with what it said) that now says something else was edited by the user
                $action = 'UpdateOrRepair'
                $prevSc = DgP-PreviousShortcut $Previous $Layout.ShortcutPath
                if ($null -ne $prevSc -and $null -ne (DgProp $prevSc 'Facts' $null)) {
                    if ($null -eq $e -or -not (DgP-FactsEqual $e (DgProp $prevSc 'Facts' $null))) { $action = 'Diverged' }
                }
                $r.Action = $action
            }
        } else { $r.Action = 'Add' }
        $r.Ok = $true
        return $r
    } catch {
        $r.Ok = $false
        $r.Error = 'ShortcutStagingFailed: ' + [string](DgError-Root $_.Exception).Message
        return $r
    }
}
# Removes only the one stage folder this process created (name prefix + parent check); never recursive.
function Remove-DenGoStagedShortcut {
    param([object]$Stage,[string]$StageParent)
    if ($null -eq $Stage -or [string]::IsNullOrEmpty([string]$Stage.StageDir)) { return }
    try {
        $dir = DgP-Full ([string]$Stage.StageDir)
        if (-not (DgP-PathEq ([System.IO.Path]::GetDirectoryName($dir)) $StageParent)) { return }
        if (-not ([System.IO.Path]::GetFileName($dir)).StartsWith('DenGoShortcutStage-',[System.StringComparison]::Ordinal)) { return }
        $file = DgP-Join $dir (DgP-ShortcutFileName)
        if (DgFs-Exists $file) { DgPFs-DeleteStageFile $file }
        DgPFs-RemoveStageDir $dir
    } catch { }
}

# ---------------------------------------------------------------- ownership merge (pure; the probe is injectable)
function DgP-DoProbe {
    param([scriptblock]$Probe,[string]$Path)
    if ($null -ne $Probe) { return [string](& $Probe $Path) }
    if (DgFs-Exists $Path) { return (DgFs-Sha256 $Path) }
    return ''
}
function DgP-CopyRecord {
    param([object]$Record)
    $o = [ordered]@{}
    foreach ($p in $Record.PSObject.Properties) { $o[$p.Name] = $p.Value }
    return $o
}
function Test-DenGoOwningOwnership { param([string]$Ownership) return ((DgEq $Ownership 'CreatedByInstaller') -or (DgEq $Ownership 'MigratedMatchingDenGoFile') -or (DgEq $Ownership 'ReplacedExisting')) }
# A record of a platform that is deferred (I3 takes it over) is never closed. Decided by the platform mapping only.
function DgP-IsDeferredRecord {
    param([object]$Record)
    try { return [bool](DgP-MapPlatform ([string](DgProp $Record 'Platform' '')) ([string](DgProp $Record 'Destination' ''))).Deferred } catch { return $false }
}
# Shortcut.PreExisted = "the target shortcut existed before the CURRENT install generation began".
#  - an earlier generation of the same shortcut (Created, same path) is the authority: PreExisted, Backup and BackupSHA256 are carried;
#    this run's own backup is only appended to Backups[]
#  - no earlier record: the file that existed right before this run decides (first sighting)
#  - not requested, or no shortcut item this run (staging failed / dropped): the earlier record is kept as it is
#  - a shortcut at another path: the earlier record moves to Earlier[] and is never forgotten
#  - Diverged (the user edited our shortcut): Created stays, the file is not overwritten, Observed = Diverged, the recorded Facts stay
function DgP-MergeShortcut {
    param([object]$Prev,[object]$Info,[string]$TxnId)
    $requested = ($null -ne $Info -and [bool](DgProp $Info 'Requested' $false))
    $present = ($requested -and [bool](DgProp $Info 'EntryPresent' $false))
    if (-not $present) {
        if ($null -ne $Prev) { return (DgP-CopyRecord $Prev) }
        if ($requested) { return ([ordered]@{ Requested = $true; Created = $false; Path = ''; PreExisted = $false; Backup = ''; BackupSHA256 = '' }) }
        return ([ordered]@{ Requested = $false; Created = $false; Path = '' })
    }
    $path = [string]$Info.Path
    $action = [string](DgProp $Info 'Action' '')
    $thisBackup = [string](DgProp $Info 'Backup' ''); $thisSha = [string](DgProp $Info 'BackupSha' '')
    $prevCreated = ($null -ne $Prev -and [bool](DgProp $Prev 'Created' $false))
    $sameGeneration = ($prevCreated -and (DgP-PathEq ([string](DgProp $Prev 'Path' '')) $path))
    $backups = New-Object System.Collections.ArrayList
    $earlier = New-Object System.Collections.ArrayList
    if ($null -ne $Prev) {
        foreach ($b in @(DgProp $Prev 'Backups' @())) { [void]$backups.Add($b) }
        foreach ($x in @(DgProp $Prev 'Earlier' @())) { [void]$earlier.Add($x) }
    }
    if ($sameGeneration) {
        $o = DgP-CopyRecord $Prev
        $preExisted = [bool](DgProp $Prev 'PreExisted' $false); $origBackup = [string](DgProp $Prev 'Backup' ''); $origSha = [string](DgProp $Prev 'BackupSHA256' '')
    } else {
        $o = [ordered]@{}
        $preExisted = [bool](DgProp $Info 'ExistedBeforeRun' $false); $origBackup = $thisBackup; $origSha = $thisSha
        if ($prevCreated) { [void]$earlier.Add([pscustomobject](DgP-CopyRecord $Prev)) }
        $backups = New-Object System.Collections.ArrayList
    }
    if ($thisBackup.Length -gt 0) { [void]$backups.Add([pscustomobject][ordered]@{ TransactionId = $TxnId; Path = $thisBackup; SHA256 = $thisSha }) }
    $facts = DgProp $Info 'Facts' $null
    $observed = 'Present'
    if (DgEq $action 'Diverged') { $observed = 'Diverged'; $facts = DgProp $Prev 'Facts' $null }
    $o['Requested'] = $true; $o['Created'] = $true; $o['Path'] = $path; $o['PreExisted'] = $preExisted; $o['Backup'] = $origBackup; $o['BackupSHA256'] = $origSha
    $o['Backups'] = [object[]]@($backups); $o['Facts'] = $facts; $o['Observed'] = $observed; $o['LastSeenTransactionId'] = $TxnId
    if ($earlier.Count -gt 0) { $o['Earlier'] = [object[]]@($earlier) }
    return $o
}
# TxByDest: UPPER(destination) -> @{ Backup = path or ''; PreSha = sha or '' } for the items the transaction wrote.
function Merge-DenGoInstalledState {
    param([object]$Previous,[object[]]$Entries,[hashtable]$TxByDest,[string]$TxnId,[string]$BackupTxnDir,[string]$Now,[object]$ShortcutInfo,[scriptblock]$Probe = $null)
    $prevFiles = @()
    $prevByDest = @{}
    $prevState = $null
    if ($null -ne $Previous -and [bool]$Previous.Exists) {
        $prevState = $Previous.State
        $prevFiles = @($Previous.Files)
        foreach ($f in $prevFiles) { $prevByDest[([string]$f.Destination).ToUpperInvariant()] = $f }
    }
    $records = New-Object System.Collections.ArrayList
    $entryKeys = @{}
    foreach ($e in @($Entries)) {
        if (DgEq $e.Kind 'Shortcut') { continue }
        $dest = [string]$e.Destination
        $key = $dest.ToUpperInvariant()
        $entryKeys[$key] = $e
        if ([bool]$e.Deferred) { continue }          # carried forward below (Presence = DeferredThisRun)
        $prev = $null
        if ($prevByDest.ContainsKey($key)) { $prev = $prevByDest[$key] }
        $action = [string]$e.Action
        $backup = ''; $preSha = ''
        if ($TxByDest.ContainsKey($key)) { $backup = [string]$TxByDest[$key].Backup; $preSha = [string]$TxByDest[$key].PreSha }
        $isProfile = DgP-IsProfileComponent ([string]$e.Component)
        $ownership = 'NotManaged'; $existedBefore = $false; $beforeSha = ''
        $newBackup = $backup
        if (DgEq $action 'Add') {
            $ownership = 'CreatedByInstaller'
        } elseif ((DgEq $action 'UpdateOrRepair') -or (DgEq $action 'Unchanged')) {
            if ($null -ne $prev) {
                $po = [string]$prev.Ownership
                if ((DgEq $po 'ReplacedExisting') -and -not $isProfile) {
                    $ownership = 'MigratedMatchingDenGoFile'; $existedBefore = $false; $beforeSha = ''; $newBackup = ''
                } else {
                    $ownership = $po; $existedBefore = [bool](DgProp $prev 'ExistedBefore' $false); $beforeSha = [string](DgProp $prev 'BeforeSHA256' ''); $newBackup = [string](DgProp $prev 'Backup' '')
                }
            } elseif (DgEq $action 'UpdateOrRepair') {
                if ($isProfile) { $ownership = 'ReplacedExisting'; $existedBefore = ($backup.Length -gt 0); if ($existedBefore) { $beforeSha = $preSha } }
                else { $ownership = 'MigratedMatchingDenGoFile'; $existedBefore = $false; $beforeSha = ''; $newBackup = '' }
            } else {
                $ownership = 'MigratedMatchingDenGoFile'
            }
        } elseif (DgEq $action 'PreserveUserModified') {
            $ownership = 'PreservedUserFile'
        } elseif (DgEq $action 'NotInitialized') {
            # H-4: an earlier record is kept as it was; only a first sighting is recorded as NotInstalled
            if ($null -ne $prev) { $ownership = [string]$prev.Ownership; $existedBefore = [bool](DgProp $prev 'ExistedBefore' $false); $beforeSha = [string](DgProp $prev 'BeforeSHA256' ''); $newBackup = [string](DgProp $prev 'Backup' '') }
            else { $ownership = 'NotInstalled' }
        }
        $afterSha = DgP-DoProbe $Probe $dest
        $backups = New-Object System.Collections.ArrayList
        if ($null -ne $prev) { foreach ($b in @(DgProp $prev 'Backups' @())) { [void]$backups.Add($b) } }
        if ($backup.Length -gt 0) { [void]$backups.Add([pscustomobject][ordered]@{ TransactionId = $TxnId; Path = $backup; SHA256 = $preSha }) }
        $rec = [ordered]@{
            Platform = [string]$e.Platform; Component = [string]$e.Component; Destination = $dest; InstallAction = $action; Ownership = $ownership
            ExistedBefore = $existedBefore; BeforeSHA256 = $beforeSha; AfterSHA256 = $afterSha; Backup = $newBackup
            Presence = 'InPlan'; Observed = $(if ($afterSha.Length -gt 0) { 'Present' } else { 'Missing' }); LastSeenTransactionId = $TxnId; Backups = [object[]]@($backups) }
        [void]$records.Add([pscustomobject]$rec)
    }
    # carried-forward records: everything that was recorded before and is not part of this transaction's plan
    $closed = New-Object System.Collections.ArrayList
    if ($null -ne $prevState) { foreach ($c in @(DgProp $prevState 'ClosedRecords' @())) { [void]$closed.Add($c) } }
    foreach ($f in $prevFiles) {
        $key = ([string]$f.Destination).ToUpperInvariant()
        if ($entryKeys.ContainsKey($key) -and -not [bool]$entryKeys[$key].Deferred) { continue }
        $copy = DgP-CopyRecord $f
        $presence = $(if ($entryKeys.ContainsKey($key)) { 'DeferredThisRun' } else { 'NotDetectedThisRun' })
        $cur = DgP-DoProbe $Probe ([string]$f.Destination)
        $observed = 'Present'
        if ($cur.Length -eq 0) { $observed = 'Missing' } elseif (-not (DgEq $cur ([string](DgProp $f 'AfterSHA256' '')))) { $observed = 'Diverged' }
        $copy['Presence'] = $presence; $copy['Observed'] = $observed
        # A record is closed only when it is outside this plan (no entry at all, Deferred or not), owns nothing, its file is gone and it is not
        # a record that I3 takes over (a deferred platform). Everything else stays in Files.
        $inPlan = $entryKeys.ContainsKey($key)
        if ((-not $inPlan) -and (-not (DgP-IsDeferredRecord $f)) -and (-not (Test-DenGoOwningOwnership ([string]$f.Ownership))) -and (DgEq $observed 'Missing')) {
            [void]$closed.Add([pscustomobject][ordered]@{ Record = [pscustomobject]$copy; ClosedAt = $Now; ClosedTransactionId = $TxnId; Reason = 'NoOwnershipAndMissing' })
            continue
        }
        [void]$records.Add([pscustomobject]$copy)
    }
    # shortcut: a generation contract (see DgP-MergeShortcut)
    $prevShortcut = $null
    if ($null -ne $prevState) { $prevShortcut = DgProp $prevState 'Shortcut' $null }
    $shortcut = DgP-MergeShortcut $prevShortcut $ShortcutInfo $TxnId
    $keyboard = $false
    if ($null -ne $prevState) { $keyboard = [bool](DgProp $prevState 'PCSX2LegacyKeyboardInitialized' $false) }
    $state = [pscustomobject][ordered]@{
        SchemaVersion = 1; StateRevision = 2; ProductVersion = '2.0.0'; PCSX2LegacyKeyboardInitialized = $keyboard
        InstalledAt = $Now; TransactionId = $TxnId; BackupRoot = $BackupTxnDir
        Shortcut = [pscustomobject]$shortcut; Files = [object[]]@($records); ClosedRecords = [object[]]@($closed) }
    return $state
}
function ConvertTo-DenGoStateBytes {
    param([object]$State)
    $json = ConvertTo-Json -InputObject $State -Depth 9
    $enc = New-Object System.Text.UTF8Encoding($true)
    $body = $enc.GetBytes($json)
    $pre = $enc.GetPreamble()
    $all = New-Object byte[] ($pre.Length + $body.Length)
    [System.Array]::Copy($pre,0,$all,0,$pre.Length)
    [System.Array]::Copy($body,0,$all,$pre.Length,$body.Length)
    return ,$all
}

# ---------------------------------------------------------------- recovery gate
function DgP-GateResult {
    param([bool]$Proceed,[string]$Outcome,[string]$Code,[string]$Detail,[object[]]$Reasons = @(),[string]$Region = '',[string]$TxnId = '',[string]$ReportPath = '',[bool]$Manual = $false)
    return [pscustomobject]@{ Proceed = $Proceed; Outcome = $Outcome; ErrorCode = $Code; Detail = $Detail; Reasons = [object[]]@($Reasons); Region = $Region; TransactionId = $TxnId; ReportPath = $ReportPath; ManualCheckRequired = $Manual }
}
function DgP-Repair {
    param([string]$Code,[string]$Detail,[string]$TxnId = '')
    return (DgP-GateResult $false 'RepairRequired' 'RecoveryRequired' $Detail @((DgP-Reason $Code $Detail)) '' $TxnId '' $true)
}
function DgP-ReadMarker {
    param([object]$Layout,[string]$Path)
    try {
        $bytes = [byte[]](DgFs-ReadAllBytesShared $Path)
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
        $obj = $text | ConvertFrom-Json
    } catch { return [pscustomobject]@{ Kind = 'Unreadable'; TxnId = '' } }
    if ($null -eq $obj) { return [pscustomobject]@{ Kind = 'Unreadable'; TxnId = '' } }
    $id = [string](DgProp $obj 'TxnId' '')
    if ($id.Length -eq 0) { return [pscustomobject]@{ Kind = 'Legacy'; TxnId = '' } }
    if (-not ($id -cmatch $Layout.TxnIdPattern)) { return [pscustomobject]@{ Kind = 'Unreadable'; TxnId = '' } }
    return [pscustomobject]@{ Kind = 'Ok'; TxnId = $id }
}
# Builds the policy for a recovery from the journaled tags. Returns @{ Policy; Rejected }.
function DgP-RecoveryPolicy {
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
                    $spec = Get-DenGoRoleSpec $Layout $t.Role $t.Root
                    if (-not $spec.Ok) { return @{ Policy = $null; Rejected = ('Item ' + $it.Id + ': ' + $spec.Reason) } }
                    $fails = Test-DenGoItemGate $Layout ([string]$it.Tag) ([string]$it.Norm) ([string]$it.Tmp) ([string[]]@($it.Dirs)) ([string]$it.Backup) $TxnId
                    if ($fails.Count -ne 0) { return @{ Policy = $null; Rejected = ('Item ' + $it.Id + ': ' + [string]::Join('; ',$fails)) } }
                    [void]$extra.Add([string]$spec.PolicyRoot)
                }
            }
        }
    }
    try { $policy = New-DenGoPathPolicy $Layout ([string[]]@($extra)) } catch { return @{ Policy = $null; Rejected = ('Policy: ' + [string](DgError-Root $_.Exception).Message) } }
    return @{ Policy = $policy; Rejected = '' }
}
# An unfinished journal without a marker (the marker was removed by hand) must not be ignored.
function DgP-FindActiveOrphan {
    param([object]$Layout)
    $base = DgP-Join $Layout.StateRoot 'txn'
    if (-not (DgFs-DirExists $base)) { return $null }
    foreach ($dir in [System.IO.Directory]::GetDirectories($base)) {
        $jp = DgP-Join $dir 'journal.jsonl'
        if (-not (DgFs-Exists $jp)) { continue }
        $parse = DgJournal-Parse $jp
        if ($parse.Corrupt) { return (DgP-Reason 'OrphanJournalUnreadable' $jp) }
        $sum = DgJournal-Summarize $parse
        if (-not $sum.Ok) { if (@($parse.Records).Count -eq 0) { continue }; return (DgP-Reason 'OrphanJournalUnreadable' ($jp + ' (' + $sum.Reason + ')')) }
        if ($sum.Committed -or $sum.RollbackComplete) { continue }
        $active = ($null -ne $sum.CommitIntent) -or $sum.RollbackBegin
        foreach ($it in @($sum.Items)) { if ($it.HasIntent) { $active = $true } }
        if ($active) { return (DgP-Reason 'OrphanActiveJournal' $jp) }
    }
    return $null
}
function Get-DenGoRecoveryGate {
    param([object]$Layout,[string]$Mode = 'Apply')
    $staticPolicy = $null
    try { $staticPolicy = New-DenGoPathPolicy $Layout } catch { return (DgP-Repair 'PathRejected' ('Policy: ' + [string](DgError-Root $_.Exception).Message)) }
    foreach ($pair in @(@('StateRoot',$Layout.StateRoot),@('BackupRoot',$Layout.BackupRoot))) {
        $t = DgPolicy-TestPath $staticPolicy $pair[1]
        if (-not $t.Allowed) { return (DgP-Repair 'PathRejected' ($pair[0] + ' is rejected by the path policy: ' + $t.Reason)) }
    }
    $instPath = DgP-Join $Layout.StateRoot 'installing.json'
    $uninPath = DgP-Join $Layout.StateRoot 'uninstalling.json'
    $hasInst = DgFs-Exists $instPath
    $hasUnin = DgFs-Exists $uninPath
    if ($hasInst -and $hasUnin) { return (DgP-Repair 'MultipleMarkers' 'Both installing.json and uninstalling.json exist.') }
    if ($hasUnin) { return (DgP-Repair 'ForeignOperationMarker' 'uninstalling.json exists; an install does not recover an uninstall.') }
    if ($hasInst) {
        $marker = DgP-ReadMarker $Layout $instPath
        if (DgEq $marker.Kind 'Unreadable') { return (DgP-Repair 'MarkerUnreadable' 'installing.json cannot be read.') }
        if (DgEq $marker.Kind 'Legacy') { return (DgP-Repair 'LegacyMarkerUnsupported' 'installing.json has the old format and is neither converted nor deleted.') }
        $rp = DgP-RecoveryPolicy $Layout $marker.TxnId
        if ([string]$rp.Rejected -ne '') { return (DgP-Repair 'PathRejected' ([string]$rp.Rejected) $marker.TxnId) }
        if (DgEq $Mode 'DryRun') {
            $pf = DgTx-Preflight $Layout.StateRoot $Layout.BackupRoot $rp.Policy
            $reasons = [object[]]@($pf.Reasons)
            if ($pf.Ok) { return (DgP-GateResult $false 'RecoveryPending' '' 'An interrupted install can be recovered automatically.' @() $pf.Region $marker.TxnId '' $false) }
            return (DgP-GateResult $false 'RepairRequired' 'RecoveryRequired' 'Recovery is not possible automatically.' $reasons $pf.Region $marker.TxnId '' $true)
        }
        $rec = DgTx-Recover $Layout.StateRoot $Layout.BackupRoot $rp.Policy
        if ($rec.Outcome -eq 'RolledBack' -or $rec.Outcome -eq 'RolledForward') {
            return (DgP-GateResult $false $rec.Outcome 'RecoveryCompletedOperationNotCompleted' ('An interrupted install was recovered (' + $rec.Outcome + '); this operation was not started.') $rec.Reasons $rec.Region $rec.TransactionId '' $false)
        }
        if ($rec.Outcome -eq 'NotNeeded') { return (DgP-GateResult $true 'NotNeeded' '' '' @() 'NoMarker' '' '' $false) }
        return (DgP-GateResult $false $rec.Outcome 'RecoveryRequired' ('Automatic recovery is not possible (' + $rec.Outcome + ').') $rec.Reasons $rec.Region $rec.TransactionId ([string]$rec.ReportPath) ([bool]$rec.ManualCheckRequired))
    }
    $orphan = DgP-FindActiveOrphan $Layout
    if ($null -ne $orphan) { return (DgP-Repair $orphan.Code $orphan.Detail) }
    if (DgEq $Mode 'DryRun') { return (DgP-GateResult $true 'NotNeeded' '' '' @() 'NoMarker' '' '' $false) }
    $rec = DgTx-Recover $Layout.StateRoot $Layout.BackupRoot $staticPolicy
    if ($rec.Outcome -eq 'NotNeeded') { return (DgP-GateResult $true 'NotNeeded' '' '' @() 'NoMarker' '' '' $false) }
    return (DgP-GateResult $false $rec.Outcome 'RecoveryRequired' ('Unexpected recovery outcome: ' + $rec.Outcome) $rec.Reasons $rec.Region $rec.TransactionId ([string]$rec.ReportPath) $true)
}

# ---------------------------------------------------------------- transaction runner (the lock is held by the caller)
# Mirrors the body of DgTx-Run (without its lock) and adds ONE hook between Begin and Apply. The TQ tests prove the two agree.
function Invoke-DenGoTransaction {
    param([string]$StateRoot,[string]$BackupRoot,[string]$Operation,[object[]]$Items,[object]$Policy,[string]$NewStatePath,[scriptblock]$NewStateFactory,[object]$FactoryArgument = $null,[scriptblock]$BeginCheck = $null,[switch]$AllowEmptyTransaction)
    $result = [pscustomobject]@{ Succeeded = $false; Code = ''; Message = ''; TransactionId = ''; RollbackState = 'NotStarted'; FailedItem = -1; Reasons = [object[]]@(); ManualCheckRequired = $false; ReportPath = ''; RecoveryOutcome = ''; Ctx = $null }
    $ctx = $null
    try {
        if (@($Items).Count -eq 0 -and $AllowEmptyTransaction -and $null -eq $NewStateFactory) { throw (DgError 'PlanInvalid' 'An empty transaction requires NewStateFactory.') }
        $ctx = DgTx-Begin $StateRoot $BackupRoot $Operation $Items $Policy $NewStatePath -AllowEmptyTransaction:$AllowEmptyTransaction
        $result.TransactionId = $ctx.TxnId
        $result.Ctx = $ctx
        if ($null -ne $BeginCheck) { & $BeginCheck $ctx $FactoryArgument }
        DgTx-Apply $ctx
        $bytes = $null
        if ($null -ne $NewStateFactory) { $bytes = [byte[]](& $NewStateFactory $ctx $FactoryArgument) }
        if ($null -eq $bytes) { throw (DgError 'PlanInvalid' 'No state bytes or factory.') }
        DgTx-Commit $ctx $bytes
        $result.Succeeded = $true; $result.Code = 'OK'; $result.RollbackState = 'NotNeeded'
    } catch {
        $code = DgError-Code $_.Exception
        if ($code.Length -eq 0) { $code = 'ApplyFailed' }
        $result.Code = $code
        $result.Message = [string](DgError-Root $_.Exception).Message
        if ($null -ne $ctx -and -not $ctx.Closed) {
            if ($ctx.ContainsKey('FailedItem')) { $result.FailedItem = [int]$ctx.FailedItem }
            $markerThere = $true
            try { $markerThere = DgFs-Exists $ctx.MarkerPath } catch {}
            if ($markerThere) {
                try { $rb = DgTx-Rollback $ctx $code }
                catch { $rb = [pscustomobject]@{ Outcome = 'RollbackIncomplete'; Reasons = [object[]]@(); TransactionId = $ctx.TxnId; ReportPath = ''; Error = [string]$_.Exception.Message; ManualCheckRequired = $false } }
                $result.RollbackState = $rb.Outcome
                $result.RecoveryOutcome = [string]$rb.Outcome
                $result.Reasons = [object[]]@($rb.Reasons)
                $result.ManualCheckRequired = (($rb.Outcome -eq 'RepairRequired') -or [bool](DgProp $rb 'ManualCheckRequired' $false))
                $result.ReportPath = [string](DgProp $rb 'ReportPath' '')      # only a report that was really written is named; never a guessed path
                if ($rb.Outcome -eq 'RolledForward') { $result.Succeeded = $true; $result.Code = 'OK'; $result.Message = ('Committed (rolled forward after: ' + $code + ')') }
            } elseif ($ctx.StateCommitted) {
                $result.Succeeded = $true; $result.Code = 'OK'; $result.RollbackState = 'NotNeeded'; $result.Message = 'Committed; post-commit cleanup incomplete.'
            } else { $result.RollbackState = 'NotStarted' }
        }
    }
    return $result
}

# ---------------------------------------------------------------- result mapping
function ConvertTo-DenGoEngineFailure {
    param([object]$Tx,[string]$FailedSet)
    $code = [string]$Tx.Code
    $rs = [string]$Tx.RollbackState
    $reasonCodes = @()
    foreach ($r in @($Tx.Reasons)) { $reasonCodes += [string](DgProp $r 'Code' '') }
    $engine = $code
    if (DgEq $code 'PlanStale') { $engine = $(if ([int]$Tx.FailedItem -ge 0) { 'DestinationChangedDuringApply' } else { 'PlanStale' }) }
    elseif (($rs -eq 'RollbackIncomplete') -and ($reasonCodes -contains 'DestinationChangedAfterPreflight')) { $engine = 'DestinationChangedDuringRollback' }
    elseif (($rs -eq 'RepairRequired') -or ($rs -eq 'RollbackIncomplete')) { $engine = 'RecoveryRequired' }
    elseif (@('ApplyFailed','InUse','AccessDenied','PostShaMismatch','TmpVerifyFailed','BackupVerifyFailed','JournalBroken') -contains $code) { $engine = 'SetApplyFailed' }
    elseif (@('CommitFailed','StateBuildFailed') -contains $code) { $engine = 'InstalledStateWriteFailed' }
    elseif (@('PlanInvalid','PathRejected','PolicyInvalid') -contains $code) { $engine = 'PlanInvalid' }
    $set = $FailedSet
    if (@('CommitFailed','StateBuildFailed') -contains $code) { $set = 'InstallerState' }
    $attempted = (($rs -ne 'NotStarted') -and ($rs -ne 'NotNeeded'))
    $rbOk = (($rs -eq 'RolledBack') -or ($rs -eq 'NotStarted') -or ($rs -eq 'NotNeeded') -or ($rs -eq 'RolledForward'))
    $manual = [bool]$Tx.ManualCheckRequired
    return [pscustomobject]@{
        ErrorCode = $engine; ErrorMessage = [string]$Tx.Message; FailedSet = $set; RollbackAttempted = $attempted; RollbackSucceeded = $rbOk
        RollbackError = $(if ($rbOk) { '' } else { ('Rollback state: ' + $rs) }); ManualCheckRequired = $manual }
}
function DgP-NewResult {
    return [pscustomobject]@{
        Succeeded = $false; ErrorCode = ''; ErrorMessage = ''; FailedSet = ''; RollbackAttempted = $false; RollbackSucceeded = $true; RollbackError = ''
        TransactionId = ''; TransactionCode = ''; RollbackState = 'NotStarted'; RecoveryOutcome = ''; FailedItem = -1; ManualCheckRequired = $false; Recovery = $null; Reasons = [object[]]@(); ReportPath = ''
        BackupRoot = ''; Results = [object[]]@(); DeferredItems = [object[]]@(); StateCommitted = $false; LockAcquired = $false
        ShortcutRequested = $false; ShortcutCreated = $false; ShortcutPath = ''; ShortcutError = '' }
}
function DgP-InvokeProcessGate {
    param([hashtable]$Options,[string]$Phase)
    if ($null -ne $Options -and $Options.ContainsKey('ProcessGate') -and $null -ne $Options['ProcessGate']) { & $Options['ProcessGate'] $Phase }
}
function New-DenGoApplyResults {
    param([object[]]$Entries,[object]$Ctx,[bool]$Succeeded)
    $list = New-Object System.Collections.ArrayList
    $backupByDest = @{}
    if ($null -ne $Ctx) { foreach ($it in @($Ctx.Items)) { $backupByDest[([string]$it.Norm).ToUpperInvariant()] = [string]$it.Backup } }
    foreach ($e in @($Entries)) {
        if (DgEq $e.Kind 'Shortcut') { continue }
        if ([bool]$e.Deferred) {
            [void]$list.Add([pscustomobject]@{ Set = $e.Set; Platform = $e.Platform; Component = $e.Component; Action = 'Deferred'; Destination = $e.Destination; Applied = $false; Backup = ''; Succeeded = $true; ErrorCode = ''; Reason = 'DeferredToI3' })
            continue
        }
        $applied = ($e.IsTx -and $Succeeded)
        $backup = ''
        if ($applied -and $backupByDest.ContainsKey(([string]$e.Destination).ToUpperInvariant())) { $backup = $backupByDest[([string]$e.Destination).ToUpperInvariant()] }
        [void]$list.Add([pscustomobject]@{ Set = $e.Set; Platform = $e.Platform; Component = $e.Component; Action = $e.Action; Destination = $e.Destination; Applied = $applied; Backup = $backup; Succeeded = $true; ErrorCode = '' })
    }
    return ,[object[]]@($list)
}

# ---------------------------------------------------------------- the whole install (called by the engine)
function Invoke-DenGoProductInstall {
    param([object]$Layout,[object[]]$Plan,[hashtable]$Options = @{})
    $res = DgP-NewResult
    $res.ShortcutRequested = ($Options.ContainsKey('ShortcutRequested') -and [bool]$Options['ShortcutRequested'])
    $stageParent = $env:TEMP
    if ($Options.ContainsKey('StageParent') -and ([string]$Options['StageParent']).Length -gt 0) { $stageParent = [string]$Options['StageParent'] }
    $lockName = Get-DenGoLockName
    $acquired = $false
    $stage = $null
    try {
        # (1) the common lock comes first: a loser creates nothing (no journal, no marker, no report)
        $lock = $null
        try { $lock = DgLock-TryAcquire $lockName 'Explicit' } catch { $res.ErrorCode = 'AnotherOperationRunning'; $res.ErrorMessage = 'The operation lock could not be taken: ' + [string](DgError-Root $_.Exception).Message; return $res }
        if (-not $lock.Acquired) {
            $res.ErrorCode = 'AnotherOperationRunning'
            $res.ErrorMessage = 'Another DenGo setup or uninstall operation is running (' + [string]$lock.Reason + ').'
            return $res
        }
        $acquired = $true
        $res.LockAcquired = $true
        # (2) process gate A (a thrown BlockedByRunningProcesses is kept as it is today)
        DgP-InvokeProcessGate $Options 'A'
        try {
        # (3) interrupted state first: nothing new starts unless the recovery gate says NotNeeded
        $gate = Get-DenGoRecoveryGate $Layout 'Apply'
        $res.Recovery = $gate
        if (-not $gate.Proceed) {
            $res.ErrorCode = [string]$gate.ErrorCode
            $res.ErrorMessage = [string]$gate.Detail
            $res.ManualCheckRequired = [bool]$gate.ManualCheckRequired
            $res.Reasons = [object[]]@($gate.Reasons)
            $res.ReportPath = [string]$gate.ReportPath
            $res.TransactionId = [string]$gate.TransactionId
            $res.RecoveryOutcome = [string]$gate.Outcome
            return $res
        }
        # (4) previous state (never swallowed)
        $prev = $null
        try { $prev = Read-DenGoPreviousState $Layout } catch { $res.ErrorCode = (DgError-Code $_.Exception); $res.ErrorMessage = [string](DgError-Root $_.Exception).Message; return $res }
        # (5) shortcut staging (non-fatal)
        if ($res.ShortcutRequested) {
            $stage = New-DenGoStagedShortcut $Layout $stageParent $prev
            if (-not $stage.Ok) { $res.ShortcutError = [string]$stage.Error }
        }
        # (6) plan -> entries -> items, policy, leaf gate, freshness
        $entries = $null; $tx = $null; $policy = $null
        try {
            $entries = Convert-DenGoPlanToEntries $Layout $Plan $stage
            $tx = Get-DenGoTxItems $entries
            $extra = New-Object System.Collections.ArrayList
            foreach ($e in $tx.Ordered) {
                $spec = Get-DenGoRoleSpec $Layout $e.Role $e.Root
                if (-not $spec.Ok) { throw (DgError 'PlanInvalid' ('Role ' + $e.Role + ' rejected for ' + $e.Destination + ': ' + $spec.Reason)) }
                [void]$extra.Add([string]$spec.PolicyRoot)
                foreach ($kind in @(@('Dest',$e.Destination),@('Tmp',($e.Destination + (DgConst-TmpSuffix))))) {
                    $g = Test-DenGoLeafGate $Layout $e.Role $e.Root $kind[1] $kind[0]
                    if (-not $g.Allowed) { throw (DgError 'PlanInvalid' ('Leaf gate (' + $kind[0] + ' ' + $g.Reason + '): ' + $kind[1])) }
                }
                foreach ($d in (Get-DenGoExpectedDirs $e.Destination)) {
                    $g = Test-DenGoLeafGate $Layout $e.Role $e.Root $d 'Dir'
                    if (-not $g.Allowed) { throw (DgError 'PlanInvalid' ('Leaf gate (Dir ' + $g.Reason + '): ' + $d)) }
                }
            }
            $policy = New-DenGoPathPolicy $Layout ([string[]]@($extra))
        } catch {
            $res.ErrorCode = 'PlanInvalid'; $res.ErrorMessage = [string](DgError-Root $_.Exception).Message
            $c = DgError-Code $_.Exception
            if ($c.Length -gt 0 -and $c -ne 'PlanInvalid') { $res.TransactionCode = $c }
            return $res
        }
        $res.DeferredItems = [object[]]@(@($entries | Where-Object { [bool]$_.Deferred }) | ForEach-Object { [pscustomobject]@{ Platform = $_.Platform; Component = $_.Component; Destination = $_.Destination; Reason = 'DeferredToI3' } })
        $stale = Test-DenGoPlanFresh $entries $prev
        if ($null -ne $stale) { $res.ErrorCode = 'PlanStale'; $res.TransactionCode = 'PlanStale'; $res.ErrorMessage = [string]$stale.Detail; return $res }
        # (7) Begin -> check -> Apply -> factory -> Commit
        $fx = @{ Layout = $Layout; Entries = $entries; Ordered = $tx.Ordered; Previous = $prev; Options = $Options; Stage = $stage }
        $beginCheck = { param($c,$a) Test-DenGoBeginMatchesPlan $c $a.Ordered $a.Previous $a.Layout }
        $factory = {
            param($c,$a)
            try {
                DgP-InvokeProcessGate $a.Options 'B'
            } catch { throw (DgError 'BlockedByRunningProcesses' ([string]$_.Exception.Message) $_.Exception) }
            try {
                $txByDest = @{}
                foreach ($it in @($c.Items)) { $txByDest[([string]$it.Norm).ToUpperInvariant()] = @{ Backup = [string]$it.Backup; PreSha = [string]$it.PreSha } }
                $sc = $null
                foreach ($e in @($a.Entries)) { if (DgEq $e.Kind 'Shortcut') { $sc = $e } }
                $info = [pscustomobject]@{ Requested = [bool]$a.Options['ShortcutRequested']; EntryPresent = ($null -ne $sc); Action = $(if ($null -ne $sc) { [string]$sc.Action } else { '' }); ExistedBeforeRun = ($null -ne $sc -and $sc.ExpectedDestSha.Length -gt 0)
                    Facts = $(if ($null -ne $sc) { $sc.ShortcutFacts } else { $null }); Backup = ''; BackupSha = ''; Path = $a.Layout.ShortcutPath }
                if ($null -ne $sc -and $txByDest.ContainsKey(([string]$sc.Destination).ToUpperInvariant())) { $info.Backup = $txByDest[([string]$sc.Destination).ToUpperInvariant()].Backup; $info.BackupSha = $txByDest[([string]$sc.Destination).ToUpperInvariant()].PreSha }
                $now = DgClock-Now
                $state = Merge-DenGoInstalledState $a.Previous $a.Entries $txByDest ([string]$c.TxnId) ([string]$c.BackupTxnDir) $now $info
                return (ConvertTo-DenGoStateBytes $state)
            } catch { throw (DgError 'StateBuildFailed' ([string]$_.Exception.Message) $_.Exception) }
        }
        $empty = (@($tx.Items).Count -eq 0)
        $txResult = Invoke-DenGoTransaction -StateRoot $Layout.StateRoot -BackupRoot $Layout.BackupRoot -Operation 'Install' -Items $tx.Items -Policy $policy -NewStatePath $Layout.StatePath -NewStateFactory $factory -FactoryArgument $fx -BeginCheck $beginCheck -AllowEmptyTransaction:$empty
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
        $res.Results = New-DenGoApplyResults $entries $ctx $res.Succeeded
        $sc = $null
        foreach ($e in @($entries)) { if (DgEq $e.Kind 'Shortcut') { $sc = $e } }
        if ($res.Succeeded) {
            $res.ErrorCode = ''; $res.ErrorMessage = ''
            if ($null -ne $sc -and (DgEq ([string]$sc.Action) 'Diverged')) {
                # the user edited the shortcut this product created: it is left as it is (not overwritten, no item)
                $res.ShortcutCreated = $false; $res.ShortcutPath = $Layout.ShortcutPath
                $res.ShortcutError = 'ShortcutDiverged: the existing shortcut was edited and was left as it is.'
            } elseif ($null -ne $sc) {
                $res.ShortcutCreated = $true; $res.ShortcutPath = $Layout.ShortcutPath
                try {
                    $finalSha = $(if ($sc.IsTx) { $sc.ExpectedSourceSha } else { $sc.ExpectedDestSha })
                    if (-not ((DgFs-Exists $Layout.ShortcutPath) -and (DgEq (DgFs-Sha256 $Layout.ShortcutPath) $finalSha))) { $res.ShortcutCreated = $false; $res.ShortcutError = 'The shortcut could not be verified after the commit.' }
                } catch { $res.ShortcutCreated = $false; $res.ShortcutError = 'The shortcut could not be verified after the commit.' }
            }
        } else {
            $failedSet = ''
            if ($null -ne $ctx -and [int]$txResult.FailedItem -ge 0 -and [int]$txResult.FailedItem -lt @($ctx.Items).Count) {
                $tag = DgP-ParseTag ([string]@($ctx.Items)[[int]$txResult.FailedItem].Tag)
                if ($null -ne $tag) { $failedSet = $tag.Platform }
            }
            $f = ConvertTo-DenGoEngineFailure $txResult $failedSet
            $res.ErrorCode = $f.ErrorCode; $res.ErrorMessage = $f.ErrorMessage; $res.FailedSet = $f.FailedSet
            $res.RollbackAttempted = $f.RollbackAttempted; $res.RollbackSucceeded = $f.RollbackSucceeded; $res.RollbackError = $f.RollbackError; $res.ManualCheckRequired = $f.ManualCheckRequired
            $res.Results = [object[]]@([pscustomobject]@{ Set = $f.FailedSet; Platform = $f.FailedSet; Component = 'Set'; Action = 'Failed'; Destination = ''; Applied = $false; Backup = ''; Succeeded = $false; ErrorCode = $f.ErrorCode; ErrorMessage = $f.ErrorMessage; RollbackAttempted = $f.RollbackAttempted; RollbackSucceeded = $f.RollbackSucceeded; RollbackError = $f.RollbackError })
            if ($res.ShortcutRequested -and $res.ShortcutError.Length -eq 0) { $res.ShortcutError = 'Shortcut was not created because the install did not succeed.' }
        }
        return $res
        } catch {
            # fail closed: an unexpected error before or around the transaction never escapes as an exception (the process gate is the only exception)
            # (after a committed state the install stays a success: only the reporting around it failed)
            if (-not $res.StateCommitted) {
                $res.Succeeded = $false
                if ($res.ErrorCode.Length -eq 0) { $res.ErrorCode = 'ProductApplyFailed' }
                $res.ErrorMessage = [string](DgError-Root $_.Exception).Message
            }
            return $res
        }
    } finally {
        Remove-DenGoStagedShortcut $stage $stageParent
        if ($acquired) { [void](DgLock-Release $lockName) }
    }
}
