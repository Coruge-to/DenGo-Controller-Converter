# Shared helpers for the I2-C (uninstall transaction) tests. ASCII only.
# Dot-source AFTER DenGoInstallerTransaction.ps1, DenGoInstallerProductApply.ps1 and DenGoUninstallerProductApply.ps1. Builds on I2B.TestSupport.ps1.
# Writes only below a sandbox under TEMP. Never touches product paths, the registry or any third-party application.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')

$script:BomUtf8 = New-Object System.Text.UTF8Encoding($true)

# ---------------------------------------------------------------- fixture: one installed generation
# P1 (nothing exists, LilyPad.ini exists), plus a user's RPCS3 profile (-> ReplacedExisting) and an old DenGo bridge (-> MigratedMatchingDenGoFile).
function New-I2CCase([string]$Name) {
    $L = New-I2BScenario $Name 'P1'
    [System.IO.File]::WriteAllText((Join-Path $L.Rpcs3Global 'Den-Go-Controller.yml'), 'user-original-yml', $script:Utf8)
    [System.IO.File]::WriteAllText((Join-Path $L.Product.CurrentExt 'DenGoVehicleSpec.BveEx.Bridge.dll'), 'old-bridge', $script:Utf8)
    return $L
}
function Install-I2CGeneration($L, [bool]$Shortcut = $true) {
    $plan = Get-I2BPlan $L 'P1' $true
    return (Invoke-I2BInstall $L $plan $Shortcut)
}
function Get-I2CPlatformPlan($L, [string[]]$Platforms) {
    $all = Get-I2BPlan $L 'P1' $true
    $keep = New-Object System.Collections.ArrayList
    foreach ($p in $all) { if ($Platforms -contains $p.Platform) { [void]$keep.Add($p) } }
    return , [object[]]@($keep)
}
function Get-I2COptions([bool]$IncludeProfiles = $true, [scriptblock]$ProcessGate = $null, [hashtable]$Extra = @{}) {
    $o = @{ IncludeInputProfiles = $IncludeProfiles }
    $o['ProcessGate'] = $(if ($null -ne $ProcessGate) { $ProcessGate } else { { } })
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    return $o
}
function Invoke-I2CUninstall($L, [bool]$IncludeProfiles = $true, [scriptblock]$ProcessGate = $null, [hashtable]$Extra = @{}) {
    return (Invoke-DenGoProductUninstall -Layout $L.Product -Options (Get-I2COptions $IncludeProfiles $ProcessGate $Extra))
}
function Get-I2CDryRun($L, [bool]$IncludeProfiles = $true, [hashtable]$Extra = @{}) {
    return (Get-DenGoUninstallDryRun -Layout $L.Product -Options (Get-I2COptions $IncludeProfiles $null $Extra))
}

# ---------------------------------------------------------------- state files
function Get-I2CUsPath($L) { return (Join-Path $L.Product.StateRoot 'uninstalled-state.json') }
function Get-I2CUmPath($L) { return (Join-Path $L.Product.StateRoot 'uninstalling.json') }
function Read-I2CJson([string]$Path) { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) }
function Write-I2CJson([string]$Path, $Object) { [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 9), $script:BomUtf8) }
function Get-I2CIs($L) { if ([System.IO.File]::Exists($L.Product.StatePath)) { return (Read-I2CJson $L.Product.StatePath) } return $null }
function Get-I2CUs($L) { if ([System.IO.File]::Exists((Get-I2CUsPath $L))) { return (Read-I2CJson (Get-I2CUsPath $L)) } return $null }
function Edit-I2CInstalledState($L, [scriptblock]$Mutator) {
    $o = Read-I2CJson $L.Product.StatePath
    & $Mutator $o
    Write-I2CJson $L.Product.StatePath $o
}
function Get-I2CRecord($State, [string]$Leaf, [string]$Platform = '') {
    foreach ($f in @($State.Files)) {
        if (([System.IO.Path]::GetFileName([string]$f.Destination) -eq $Leaf) -and (($Platform.Length -eq 0) -or ([string]$f.Platform -eq $Platform))) { return $f }
    }
    return $null
}
function Remove-I2CProperty($Object, [string]$Name) { if ($null -ne $Object.PSObject.Properties[$Name]) { [void]$Object.PSObject.Properties.Remove($Name) } }
function Set-I2CProperty($Object, [string]$Name, $Value) {
    if ($null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name = $Value } else { Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value }
}
# Turns the installed state into the old (pre-I2-B) format: no StateRevision, no per-record generation facts, no Backups[], no shortcut Facts.
# Origin backups are copied to the old layout (BackupRoot\yyyyMMdd-HHmmss\<32 hex>.bak) as the old installer wrote them.
function ConvertTo-I2CLegacyState($L) {
    Edit-I2CInstalledState $L {
        param($o)
        Remove-I2CProperty $o 'StateRevision'; Remove-I2CProperty $o 'TransactionId'; Remove-I2CProperty $o 'ClosedRecords'
        $n = 0
        foreach ($f in @($o.Files)) {
            foreach ($p in 'Presence', 'Observed', 'LastSeenTransactionId') { Remove-I2CProperty $f $p }
            $n++
            if ([string]$f.Backup -ne '') {
                $dir = Join-Path $L.Product.BackupRoot '20250101-000000'
                [System.IO.Directory]::CreateDirectory($dir) | Out-Null
                $legacy = Join-Path $dir (('{0:x32}' -f $n) + '.bak')
                [System.IO.File]::Copy([string]$f.Backup, $legacy, $true)
                $f.Backup = $legacy
            }
            Remove-I2CProperty $f 'Backups'
        }
        if ($null -ne $o.PSObject.Properties['Shortcut']) { foreach ($p in 'Facts', 'Observed', 'LastSeenTransactionId', 'Backups', 'Earlier') { Remove-I2CProperty $o.Shortcut $p } }
    }
}
# A minimal old-format uninstalled-state.json, as the old uninstaller wrote it (no ClosedGeneration).
function Write-I2CLegacyUninstalledState($L) {
    [System.IO.Directory]::CreateDirectory($L.Product.StateRoot) | Out-Null
    $o = [pscustomobject][ordered]@{ SchemaVersion = 1; ProductVersion = '2.0.0'; State = 'Uninstalled'; UninstalledAt = '2026-01-01T00:00:00.0000000+09:00'; InputProfilesPreserved = $true; RollbackRoot = (Join-Path $L.Local 'DenGo Controller Converter\UninstallRollback\20260101-000000'); Results = [object[]]@() }
    Write-I2CJson (Get-I2CUsPath $L) $o
}
# A record that this product cannot handle (used for unknown ownership, deferred platforms, ...).
function Add-I2CRecord($L, $Record) { Edit-I2CInstalledState $L { param($o) $o.Files = [object[]]@(@($o.Files) + @($Record)) } }
function New-I2CRecord([string]$Platform, [string]$Component, [string]$Destination, [string]$Ownership, [string]$After = '', [string]$Before = '', [string]$Backup = '', [bool]$Existed = $false) {
    return [pscustomobject][ordered]@{ Platform = $Platform; Component = $Component; Destination = $Destination; InstallAction = 'Add'; Ownership = $Ownership; ExistedBefore = $Existed; BeforeSHA256 = $Before; AfterSHA256 = $After; Backup = $Backup
        Presence = 'InPlan'; Observed = 'Present'; LastSeenTransactionId = 'T0001'; Backups = [object[]]@() }
}
function Get-I2CLeafPath($L, [string]$Leaf) {
    $hit = @(Get-I2BItemSpecs $L | Where-Object { [System.IO.Path]::GetFileName($_.Dest) -eq $Leaf })
    if ($hit.Count -eq 0) { throw ('No fixture item for ' + $Leaf) }
    return $hit[0].Dest
}

# ---------------------------------------------------------------- trees and checks
function Test-I2CUsValid($L) {
    if (-not [System.IO.File]::Exists((Get-I2CUsPath $L))) { return $false }
    try {
        $o = Read-I2CJson (Get-I2CUsPath $L)
        return (([int]$o.SchemaVersion -eq 1) -and ([string]$o.State -eq 'Uninstalled') -and ([int](DgProp $o 'StateRevision' 0) -eq 2) -and ($null -ne (DgProp $o 'ClosedGeneration' $null)))
    } catch { return $false }
}
# The managed tree (everything that must be restored exactly). The installed state, the uninstalled state and both markers are explicit entries;
# a uninstalled-state.json written by this product is compared as 'NEW' (its timestamps and ids differ from run to run).
function Get-I2CTree($L, [switch]$NormalizeState) {
    $map = Get-I2BManagedTree $L
    [void]$map.Remove('x:state')
    $sr = $L.Product.StateRoot
    $map['x:is'] = $(if ([System.IO.File]::Exists($L.Product.StatePath)) { Get-I2AFileSha $L.Product.StatePath } else { '<none>' })
    $map['x:us'] = $(if ([System.IO.File]::Exists((Get-I2CUsPath $L))) { if ($NormalizeState -and (Test-I2CUsValid $L)) { 'NEW' } else { Get-I2AFileSha (Get-I2CUsPath $L) } } else { '<none>' })
    $map['x:um'] = $(if ([System.IO.File]::Exists((Get-I2CUmPath $L))) { 'PRESENT' } else { '<none>' })
    $map['x:im'] = $(if ([System.IO.File]::Exists((Join-Path $sr 'installing.json'))) { 'PRESENT' } else { '<none>' })
    return $map
}
function Test-I2CLeftovers($L) {
    $problems = New-Object System.Collections.ArrayList
    $sr = $L.Product.StateRoot
    foreach ($m in 'installing.json', 'uninstalling.json', 'installing.json.tmp', 'uninstalling.json.tmp', 'uninstalled-state.json.tmp', 'installed-state.json.tmp') { if ([System.IO.File]::Exists((Join-Path $sr $m))) { [void]$problems.Add($m) } }
    foreach ($f in [System.IO.Directory]::GetFiles($L.Root, '*.dengo.tmp', [System.IO.SearchOption]::AllDirectories)) { [void]$problems.Add($f.Substring($L.Root.Length)) }
    foreach ($p in $problems) { $p }   # ALWAYS call as @(Test-I2CLeftovers ...)
}
function Get-I2CHistoryFiles($L, [string]$Filter = '*') {
    $dir = Join-Path $L.Product.StateRoot 'history'
    if (-not [System.IO.Directory]::Exists($dir)) { return @() }
    return @([System.IO.Directory]::GetFiles($dir, $Filter))
}
# Every state file / backup the product keeps (used to prove "no backup was deleted").
function Get-I2CBackupFiles($L) {
    if (-not [System.IO.Directory]::Exists($L.Product.BackupRoot)) { return @() }
    return @([System.IO.Directory]::GetFiles($L.Product.BackupRoot, '*', [System.IO.SearchOption]::AllDirectories))
}
function Get-I2CRel($L, [string]$Path) { return $Path.Substring($L.Root.Length + 1).ToLowerInvariant() }
function Get-I2CLnkFacts([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    return [pscustomobject]@{ TargetPath = [string]$s.TargetPath; WorkingDirectory = [string]$s.WorkingDirectory; IconLocation = [string]$s.IconLocation }
}
function Get-I2CFreeDriveLetter {
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    foreach ($c in 'Z', 'Y', 'X', 'W', 'V', 'U', 'T') { if ($used -notcontains $c) { return $c } }
    throw 'No free drive letter'
}
function Get-I2CReasonCodes($R) {
    $codes = @()
    if ($null -ne $R.Recovery) { foreach ($x in @($R.Recovery.Reasons)) { $codes += [string](DgProp $x 'Code' '') } }
    foreach ($x in @($R.Reasons)) { $codes += [string](DgProp $x 'Code' '') }
    return $codes
}
function Test-I2CNoChange($L, $Before) {
    $after = Get-I2CTree $L
    return ((Cnt (Compare-I2ATree $Before $after)) -eq 0)
}

# An unfinished (active) journal with a valid hash chain: Begin + CommitIntent, no marker. Used to prove that an orphan journal is never ignored.
function New-I2CForgedActiveJournal($L, [string]$TxnId = '20261016T000060Z-00000060', [string]$Operation = 'Uninstall') {
    $dir = Join-Path $L.Product.StateRoot ('txn\' + $TxnId)
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $prev = DgConst-ZeroHash
    $sb = New-Object System.Text.StringBuilder
    $seq = 0
    foreach ($stage in 'Begin', 'CommitIntent') {
        $seq++
        $d = New-Object System.Collections.Specialized.OrderedDictionary
        $d.Add('schemaVersion', 1); $d.Add('transactionId', $TxnId); $d.Add('operation', $Operation); $d.Add('sequence', $seq); $d.Add('timestamp', '2026-10-16T00:00:00.0000000Z'); $d.Add('stage', $stage)
        if ($stage -eq 'Begin') { $d.Add('stateRoot', $L.Product.StateRoot); $d.Add('backupRoot', $L.Product.BackupRoot); $d.Add('oldStateSha', ''); $d.Add('newStatePath', (Get-I2CUsPath $L)); $d.Add('newStateTmp', ((Get-I2CUsPath $L) + '.tmp')); $d.Add('itemCount', 0) }
        else { $d.Add('newStatePath', (Get-I2CUsPath $L)); $d.Add('newStateTmp', ((Get-I2CUsPath $L) + '.tmp')); $d.Add('newStateSha', ('ab' * 32)) }
        $f = DgJournal-FormatRecord $d $prev
        [void]$sb.Append($f.Line + "`n")
        $prev = $f.Hash
    }
    [System.IO.File]::WriteAllBytes((Join-Path $dir 'journal.jsonl'), $script:Utf8.GetBytes($sb.ToString()))
    return (Join-Path $dir 'journal.jsonl')
}
# ---------------------------------------------------------------- input SHA-256 manifest (ties a test result to the exact files it ran against)
$script:I2CTestsDir = $PSScriptRoot
# The 16 files of the I2-C change set (group 'I2C') and the unchanged files the tests are built on (group 'Base').
function Get-I2CInputFileList {
    $i2c = @(
        'installer/build/Build-DenGo-SetupPackage.ps1', 'installer/gui/DenGoUninstallerGui.ps1', 'installer/scripts/Invoke-DenGoUninstaller.ps1', 'installer/scripts/DenGoUninstallerProductApply.ps1',
        'installer/tests/I2C.Child.ps1', 'installer/tests/I2C.TestSupport.ps1', 'installer/tests/Test-DenGoInstaller-I2B-Fault.ps1', 'installer/tests/Test-DenGoInstaller-I2B-Static.ps1',
        'installer/tests/Test-DenGoInstaller-I2C-All.ps1', 'installer/tests/Test-DenGoInstaller-I2C-EngineGlue.ps1', 'installer/tests/Test-DenGoInstaller-I2C-Fault.ps1', 'installer/tests/Test-DenGoInstaller-I2C-Gui.ps1',
        'installer/tests/Test-DenGoInstaller-I2C-Kill.ps1', 'installer/tests/Test-DenGoInstaller-I2C-Lock.ps1', 'installer/tests/Test-DenGoInstaller-I2C-Static.ps1', 'installer/tests/Test-DenGoInstaller-I2C-Unit.ps1')
    $base = @(
        'installer/scripts/DenGoInstallerTransaction.ps1', 'installer/scripts/DenGoInstallerProductApply.ps1',
        'installer/tests/I1.TestSupport.ps1', 'installer/tests/I2A.TestSupport.ps1', 'installer/tests/I2B.TestSupport.ps1')
    $rows = New-Object System.Collections.ArrayList
    foreach ($r in $i2c) { [void]$rows.Add([pscustomobject]@{ Group = 'I2C'; Rel = $r }) }
    foreach ($r in $base) { [void]$rows.Add([pscustomobject]@{ Group = 'Base'; Rel = $r }) }
    return , @($rows)
}
function Get-I2CInputManifest {
    $repo = [System.IO.Path]::GetFullPath((Join-Path $script:I2CTestsDir '..\..'))
    $rows = New-Object System.Collections.ArrayList
    foreach ($f in (Get-I2CInputFileList)) {
        $abs = [System.IO.Path]::GetFullPath((Join-Path $repo ($f.Rel.Replace('/', '\'))))
        $row = [ordered]@{ Group = $f.Group; Rel = $f.Rel; Abs = $abs; Size = -1; Sha256 = '<missing>'; LastWriteUtc = '<missing>' }
        if ([System.IO.File]::Exists($abs)) {
            $row.Size = ([System.IO.FileInfo]$abs).Length
            $row.Sha256 = Get-I2AFileSha $abs
            $row.LastWriteUtc = [System.IO.File]::GetLastWriteTimeUtc($abs).ToString('o')
        }
        [void]$rows.Add([pscustomobject]$row)
    }
    return , @($rows)
}
function Write-I2CInputManifest([string]$Path, $Rows, [string]$Label) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# I2-C input SHA-256 manifest ($Label) generated $([DateTime]::UtcNow.ToString('o'))`n")
    [void]$sb.Append("# Group`tSize`tSHA256`tLastWriteUtc`tRelativePath`tAbsolutePath`n")
    foreach ($r in $Rows) { [void]$sb.Append(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`n" -f $r.Group, $r.Size, $r.Sha256, $r.LastWriteUtc, $r.Rel, $r.Abs)) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
# Returns the list of differences (empty = identical in size, SHA-256 and last-write time).
function Compare-I2CInputManifest($Before, $After) {
    $diff = New-Object System.Collections.ArrayList
    if (@($Before).Count -ne @($After).Count) { [void]$diff.Add("row count $(@($Before).Count) -> $(@($After).Count)") }
    for ($i = 0; $i -lt [Math]::Min(@($Before).Count, @($After).Count); $i++) {
        $b = @($Before)[$i]; $a = @($After)[$i]
        if ($b.Rel -ne $a.Rel) { [void]$diff.Add("order differs at $i"); continue }
        if ($b.Sha256 -ne $a.Sha256) { [void]$diff.Add("$($b.Rel): SHA-256 $($b.Sha256) -> $($a.Sha256)") }
        if ($b.Size -ne $a.Size) { [void]$diff.Add("$($b.Rel): size $($b.Size) -> $($a.Size)") }
        if ($b.LastWriteUtc -ne $a.LastWriteUtc) { [void]$diff.Add("$($b.Rel): last write $($b.LastWriteUtc) -> $($a.LastWriteUtc)") }
    }
    return , @($diff)
}
function Write-I2CInputVerify([string]$Path, $Before, $After, [string]$StartedUtc, [string]$EndedUtc) {
    $diff = Compare-I2CInputManifest $Before $After
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# I2-C input verification`n")
    [void]$sb.Append("started (UTC): $StartedUtc`nended (UTC):   $EndedUtc`n")
    for ($i = 0; $i -lt @($Before).Count; $i++) {
        $b = @($Before)[$i]; $a = @($After)[$i]
        $same = ($b.Sha256 -eq $a.Sha256) -and ($b.Size -eq $a.Size) -and ($b.LastWriteUtc -eq $a.LastWriteUtc)
        [void]$sb.Append(("{0}`t{1}`t{2}`tbefore={3}`tafter={4}`n" -f $(if ($same) { 'MATCH' } else { 'CHANGED' }), $b.Group, $b.Rel, $b.Sha256, $a.Sha256))
    }
    foreach ($d in $diff) { [void]$sb.Append("DIFF: $d`n") }
    [void]$sb.Append("RESULT: $(if ($diff.Count -eq 0) { 'UNCHANGED' } else { 'CHANGED' }) files=$(@($Before).Count) differences=$($diff.Count)`n")
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return ($diff.Count -eq 0)
}