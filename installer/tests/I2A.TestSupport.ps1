# Shared helpers for the I2-A (transaction core) tests. ASCII only. Dot-source AFTER DenGoInstallerTransaction.ps1.
# Writes only below a sandbox under TEMP. Never touches product paths, the registry or any third-party application.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:I2AResults = New-Object System.Collections.ArrayList
$script:I2ARepo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Add-I2AResult([string]$Id, [bool]$Passed, [string]$Detail) {
    [void]$script:I2AResults.Add([pscustomobject]@{ Id = $Id; Passed = $Passed; Detail = $Detail })
    Write-Host (('{0} | {1} | {2}' -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Id, $Detail))
}
function Complete-I2ATests {
    $passed = @($script:I2AResults | Where-Object { $_.Passed }).Count
    $failed = @($script:I2AResults | Where-Object { -not $_.Passed }).Count
    Write-Host ('PASS={0} FAIL={1}' -f $passed, $failed)
    if ($failed -ne 0) { exit 1 }
    exit 0
}
function Assert-I2A([string]$Id, [bool]$Condition, [string]$Detail) { Add-I2AResult $Id $Condition $Detail; return $Condition }

# ---------------------------------------------------------------- sandbox
function New-I2ASandbox([string]$Name) {
    $tempBase = [System.IO.Path]::GetFullPath($env:TEMP)
    $root = Join-Path $tempBase ('DenGoI2A-' + $Name + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 10))
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    return $root
}
function Remove-I2ASandbox([string]$Root) {
    $tempBase = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Root)
    if (-not $full.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or -not ([System.IO.Path]::GetFileName($full)).StartsWith('DenGoI2A-')) { throw ('Refusing to delete: ' + $full) }
    for ($i = 0; $i -lt 10; $i++) {
        try { if ([System.IO.Directory]::Exists($full)) { Remove-I2ADirSafe $full }; return } catch { Start-Sleep -Milliseconds 300 }
    }
}
function Assert-I2AInsideSandbox([string]$Root, [string[]]$Paths) {
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($p in $Paths) { if (-not ([System.IO.Path]::GetFullPath($p)).StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { throw ('Path outside sandbox: ' + $p) } }
}

# ---------------------------------------------------------------- fixture
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
function Get-I2AContent([string]$Scenario, [string]$Name, [string]$Version) {
    return ((($Scenario + '|' + $Name + '|' + $Version + '|') * (2 + ($Name.Length % 5))))
}
function New-I2ASpecItem([string]$Name, [string]$Rel, [string]$Pre, [string]$Post, [string]$Op = 'Write') {
    return @{ Name = $Name; Rel = $Rel; Pre = $(if ($Pre.Length -gt 0) { $Pre } else { $null }); Post = $(if ($Post.Length -gt 0) { $Post } else { $null }); Op = $Op }
}
function Get-I2ASpec([string]$Scenario) {
    switch ($Scenario) {
        'F1' { return @(
            (New-I2ASpecItem 'app' 'core\app.exe' '' 'new'), (New-I2ASpecItem 'ico' 'core\app.ico' '' 'new'),
            (New-I2ASpecItem 'c5' 'bve5\Input Devices\caller.dll' '' 'new'), (New-I2ASpecItem 'c6' 'bve6\Input Devices\caller.dll' '' 'new'),
            (New-I2ASpecItem 'b1' 'bveex\Extensions\bridge.dll' '' 'new'), (New-I2ASpecItem 'b2' 'bveex\Extensions\spec.dll' '' 'new'),
            (New-I2ASpecItem 'l1' 'legacy\Extensions\lbridge.dll' '' 'new'), (New-I2ASpecItem 'l2' 'legacy\Extensions\lspec.dll' '' 'new'),
            (New-I2ASpecItem 'p1' 'emuA\inis\profile.lily' '' 'new'), (New-I2ASpecItem 'p2' 'emuA\inis\LilyPad.ini' '' 'new'),
            (New-I2ASpecItem 'r1' 'emuB\config\global\Den-Go.yml' '' 'new'), (New-I2ASpecItem 'd1' 'deep\a\b\c\x.dll' '' 'new')) }
        'F2' { return @(
            (New-I2ASpecItem 'app' 'core\app.exe' 'old' 'new'), (New-I2ASpecItem 'ico' 'core\app.ico' 'old' 'new'),
            (New-I2ASpecItem 'c5' 'bve5\Input Devices\caller.dll' 'old' 'new'), (New-I2ASpecItem 'c6' 'bve6\Input Devices\caller.dll' '' 'new'),
            (New-I2ASpecItem 'b1' 'bveex\Extensions\bridge.dll' 'old' 'new'), (New-I2ASpecItem 'b2' 'bveex\Extensions\spec.dll' 'old' 'new'),
            (New-I2ASpecItem 'l1' 'legacy\Extensions\lbridge.dll' 'old' 'new'), (New-I2ASpecItem 'l2' 'legacy\Extensions\lspec.dll' 'old' 'new'),
            (New-I2ASpecItem 'p1' 'emuA\inis\profile.lily' 'old' 'new'), (New-I2ASpecItem 'p2' 'emuA\inis\LilyPad.ini' 'old' 'new'),
            (New-I2ASpecItem 'r1' 'emuB\config\global\Den-Go.yml' 'old' 'new'), (New-I2ASpecItem 'd1' 'deep\a\b\c\x.dll' '' 'new')) }
        'F3' { return @(
            (New-I2ASpecItem 'a1' 'm\a1.dll' 'old' 'new'), (New-I2ASpecItem 'a2' 'm\a2.dll' 'old' 'new'), (New-I2ASpecItem 'a3' 'm\a3.dll' 'old' 'new'),
            (New-I2ASpecItem 'a4' 'm\a4.dll' 'old' 'new'), (New-I2ASpecItem 'n1' 'm\n1.dll' '' 'new'), (New-I2ASpecItem 'n2' 'q\r\n2.dll' '' 'new'),
            (New-I2ASpecItem 'x1' 'm\x1.dll' 'old' '' 'Delete'), (New-I2ASpecItem 'x2' 'm\x2.dll' 'old' '' 'Delete'), (New-I2ASpecItem 'x3' 'k\x3.dll' 'old' '' 'Delete'),
            (New-I2ASpecItem 'w1' 'k\w1.dll' 'old' 'new')) }
        'F4' { return @(
            (New-I2ASpecItem 'n1' 'fresh\n1.dll' '' 'new'), (New-I2ASpecItem 'u1' 'keep\u1.dll' 'old' 'new'), (New-I2ASpecItem 'x1' 'keep\x1.dll' 'old' '' 'Delete')) }
        'F5' { return @(
            (New-I2ASpecItem 'x1' 'u\x1.dll' 'dengo' '' 'Delete'), (New-I2ASpecItem 'x2' 'u\x2.dll' 'dengo' '' 'Delete'), (New-I2ASpecItem 'x3' 'v\x3.dll' 'dengo' '' 'Delete'),
            (New-I2ASpecItem 'x4' 'v\x4.dll' 'dengo' '' 'Delete'), (New-I2ASpecItem 'r1' 'u\r1.ini' 'dengo' 'orig'), (New-I2ASpecItem 'r2' 'u\r2.ini' 'dengo' 'orig'),
            (New-I2ASpecItem 'r3' 'v\r3.ini' 'dengo' 'orig'), (New-I2ASpecItem 'r4' 'v\r4.ini' 'dengo' 'orig')) }
        'F6' { return @(
            (New-I2ASpecItem 'i1' 'z\i1.dll' 'old' 'new'), (New-I2ASpecItem 'i2' 'z\i2.dll' 'old' 'new'), (New-I2ASpecItem 'i3' 'z\i3.dll' 'old' 'new'), (New-I2ASpecItem 'i4' 'z\i4.dll' 'old' 'new')) }
    }
    throw ('Unknown scenario ' + $Scenario)
}
function Get-I2AOperation([string]$Scenario) { if ($Scenario -eq 'F5') { return 'Uninstall' } else { return 'Install' } }

function Get-I2ALayout([string]$Root, [string]$Scenario) {
    return [pscustomobject]@{
        Root = $Root; Scenario = $Scenario; Src = (Join-Path $Root 'Src'); Dest = (Join-Path $Root 'Dest'); State = (Join-Path $Root 'State')
        Backup = (Join-Path $Root 'Backup'); Guard = (Join-Path $Root 'Guard'); StatePath = (Join-Path $Root 'State\installed-state.json')
        Policy = (DgPolicy-New @($Root) 'Reject'); Operation = (Get-I2AOperation $Scenario)
        NewStateBytes = $script:Utf8.GetBytes('state-v2|' + $Scenario)
    }
}
function New-I2AFixture([string]$Root, [string]$Scenario) {
    $layout = Get-I2ALayout $Root $Scenario
    foreach ($d in 'Src', 'Dest', 'State', 'Backup', 'Guard') { [System.IO.Directory]::CreateDirectory((Join-Path $Root $d)) | Out-Null }
    foreach ($s in (Get-I2ASpec $Scenario)) {
        $dest = Join-Path $layout.Dest $s.Rel
        if ($null -ne $s.Pre) {
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dest)) | Out-Null
            [System.IO.File]::WriteAllText($dest, (Get-I2AContent $Scenario $s.Name $s.Pre), $script:Utf8)
            [System.IO.File]::WriteAllText((Join-Path ([System.IO.Path]::GetDirectoryName($dest)) 'neighbor.txt'), 'neighbor', $script:Utf8)
        }
        if ($s.Op -eq 'Write') { [System.IO.File]::WriteAllText((Join-Path $layout.Src ($s.Name + '.src')), (Get-I2AContent $Scenario $s.Name $s.Post), $script:Utf8) }
    }
    if ($Scenario -eq 'F1') { [System.IO.Directory]::CreateDirectory((Join-Path $layout.Dest 'bveex\Extensions')) | Out-Null; [System.IO.Directory]::CreateDirectory((Join-Path $layout.Dest 'emuA\inis')) | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $layout.Guard 'g1.txt'), 'guard-1', $script:Utf8)
    [System.IO.Directory]::CreateDirectory((Join-Path $layout.Guard 'sub')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $layout.Guard 'sub\g2.dll'), 'guard-2', $script:Utf8)
    if ($Scenario -ne 'F1') { [System.IO.File]::WriteAllText($layout.StatePath, ('state-v1|' + $Scenario), $script:Utf8) }
    return $layout
}
function Get-I2AScenarioItems($Layout) {
    $items = @()
    foreach ($s in (Get-I2ASpec $Layout.Scenario)) {
        $items += , @{ Op = $s.Op; Destination = (Join-Path $Layout.Dest $s.Rel); Source = $(if ($s.Op -eq 'Write') { Join-Path $Layout.Src ($s.Name + '.src') } else { '' }); OwnershipCandidate = 'CreatedByInstaller'; Tag = $s.Name }
    }
    return , $items
}
function Invoke-I2ARun($Layout, [string]$LockName = '') {
    $items = Get-I2AScenarioItems $Layout
    return (DgTx-Run -StateRoot $Layout.State -BackupRoot $Layout.Backup -Operation $Layout.Operation -Items $items -Policy $Layout.Policy -NewStatePath $Layout.StatePath -NewStateBytes $Layout.NewStateBytes -LockName $LockName)
}
function Invoke-I2ARecover($Layout) { return (DgTx-Recover -StateRoot $Layout.State -BackupRoot $Layout.Backup -Policy $Layout.Policy) }

# ---------------------------------------------------------------- tree maps / snapshots (independent of the primitive layer)
function Get-I2AFileSha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)))).Replace('-', '') } finally { $sha.Dispose() }
}
function Get-I2ATreeMap([string]$Root, [string[]]$ExcludeRel = @()) {
    $map = @{}
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not [System.IO.Directory]::Exists($rootFull)) { return $map }
    $excluded = { param($rel) foreach ($ex in $ExcludeRel) { $e = $ex.ToLowerInvariant(); if ($rel -eq $e -or $rel.StartsWith($e + '\')) { return $true } }; return $false }
    foreach ($d in [System.IO.Directory]::GetDirectories($rootFull, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $d.Substring($rootFull.Length + 1).ToLowerInvariant()
        if (& $excluded $rel) { continue }
        $map['d:' + $rel] = 'DIR'
    }
    foreach ($f in [System.IO.Directory]::GetFiles($rootFull, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $f.Substring($rootFull.Length + 1).ToLowerInvariant()
        if (& $excluded $rel) { continue }
        $map['f:' + $rel] = Get-I2AFileSha $f
    }
    return $map
}
# "Managed" tree: everything that must be restored exactly. Backups, history and the (orphan) journal area are intentionally excluded.
function Get-I2AManagedTree($Layout) {
    return (Get-I2ATreeMap $Layout.Root @('backup', 'state\txn', 'state\history'))
}
# Everything except the recovery report (used for "zero change" assertions).
function Get-I2AFullTree($Layout) {
    return (Get-I2ATreeMap $Layout.Root @())
}
function Compare-I2ATree($A, $B) {
    $diff = New-Object System.Collections.ArrayList
    foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k)) { [void]$diff.Add('-' + $k) } elseif ($A[$k] -ne $B[$k]) { [void]$diff.Add('~' + $k) } }
    foreach ($k in $B.Keys) { if (-not $A.ContainsKey($k)) { [void]$diff.Add('+' + $k) } }
    foreach ($d in $diff) { $d }   # emits items; ALWAYS call as @(Compare-I2ATree ...)
}
function Get-I2ATreeDigest($Map) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $text = [string]::Join("`n", [string[]]@($Map.Keys | Sort-Object | ForEach-Object { $_ + '=' + $Map[$_] }))
        return ([System.BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($text)))).Replace('-', '').Substring(0, 16)
    } finally { $sha.Dispose() }
}
function Save-I2ATree([string]$Root) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $snap = @{ Dirs = New-Object System.Collections.ArrayList; Files = @{} }
    foreach ($d in [System.IO.Directory]::GetDirectories($rootFull, '*', [System.IO.SearchOption]::AllDirectories)) { [void]$snap.Dirs.Add($d.Substring($rootFull.Length + 1)) }
    foreach ($f in [System.IO.Directory]::GetFiles($rootFull, '*', [System.IO.SearchOption]::AllDirectories)) { $snap.Files[$f.Substring($rootFull.Length + 1)] = [System.IO.File]::ReadAllBytes($f) }
    return $snap
}
# Deletes a directory tree without ever following a junction/symlink: a reparse point is unlinked, never entered.
function Remove-I2ADirSafe([string]$Path) {
    foreach ($d in [System.IO.Directory]::GetDirectories($Path)) {
        if (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { [System.IO.Directory]::Delete($d) } else { Remove-I2ADirSafe $d }
    }
    foreach ($f in [System.IO.Directory]::GetFiles($Path)) { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal); [System.IO.File]::Delete($f) }
    [System.IO.Directory]::Delete($Path)
}
function Restore-I2ATree([string]$Root, $Snap) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($e in [System.IO.Directory]::GetFileSystemEntries($rootFull)) {
        if ([System.IO.Directory]::Exists($e)) {
            if (([System.IO.File]::GetAttributes($e) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { [System.IO.Directory]::Delete($e) } else { Remove-I2ADirSafe $e }
        } else { [System.IO.File]::Delete($e) }
    }
    foreach ($d in $Snap.Dirs) { [System.IO.Directory]::CreateDirectory((Join-Path $rootFull $d)) | Out-Null }
    foreach ($k in $Snap.Files.Keys) {
        $p = Join-Path $rootFull $k
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($p)) | Out-Null
        [System.IO.File]::WriteAllBytes($p, $Snap.Files[$k])
    }
}
function Get-I2AJournalText($Layout) {
    $paths = @()
    foreach ($base in @((Join-Path $Layout.State 'txn'), (Join-Path $Layout.State 'history'))) {
        if ([System.IO.Directory]::Exists($base)) { $paths += [System.IO.Directory]::GetFiles($base, '*.jsonl', [System.IO.SearchOption]::AllDirectories) }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $paths) {
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $text = (New-Object System.IO.StreamReader($fs, $script:Utf8)).ReadToEnd() } finally { $fs.Dispose() }
        [void]$out.Add(($p.Substring($Layout.Root.Length) + ': ' + (($text -split "`n" | Where-Object { $_.Length -gt 0 } | ForEach-Object { if ($_ -match '"stage":"(\w+)"') { $Matches[1] } else { '?' } }) -join ',')))
    }
    return [string]::Join(' | ', [string[]]@($out))
}
function Get-I2ABackupList($Layout) {
    if (-not [System.IO.Directory]::Exists($Layout.Backup)) { return '' }
    return [string]::Join(',', [string[]]@([System.IO.Directory]::GetFiles($Layout.Backup, '*', [System.IO.SearchOption]::AllDirectories) | ForEach-Object { $_.Substring($Layout.Backup.Length + 1) }))
}
function Test-I2ANoLeftovers($Layout) {
    # No marker, no *.dengo.tmp, no state tmp, no open active journal.
    $problems = New-Object System.Collections.ArrayList
    foreach ($m in 'installing.json', 'uninstalling.json', 'installing.json.tmp', 'uninstalling.json.tmp', 'installed-state.json.tmp') { if ([System.IO.File]::Exists((Join-Path $Layout.State $m))) { [void]$problems.Add($m) } }
    foreach ($f in [System.IO.Directory]::GetFiles($Layout.Root, '*.dengo.tmp', [System.IO.SearchOption]::AllDirectories)) { [void]$problems.Add($f.Substring($Layout.Root.Length)) }
    foreach ($p in $problems) { $p }   # emits items; ALWAYS call as @(Test-I2ANoLeftovers ...)
}

# ---------------------------------------------------------------- fault harness (redefines the primitive layer in this script scope)
$global:I2AFH = $null
$global:I2AOrig = @{}
$script:I2APrimitives = @(
    @('DgFs-Exists', $false), @('DgFs-DirExists', $false), @('DgFs-Sha256', $false), @('DgFs-ReadAllBytesShared', $false), @('DgFs-ProbeExclusive', $false), @('DgFs-GetReparseComponents', $false),
    @('DgFs-CreateFileDurable', $true), @('DgFs-WriteTextFile', $true), @('DgFs-CopyFileDurable', $true), @('DgFs-Replace', $true), @('DgFs-MoveNew', $true), @('DgFs-Delete', $true),
    @('DgFs-CreateDir', $true), @('DgFs-RemoveDirIfEmpty', $true), @('DgJournal-Open', $true), @('DgJournal-OpenTruncate', $true), @('DgJournal-Append', $true), @('DgJournal-Close', $false))

function global:New-I2ACrash { $e = New-Object System.Exception('I2A simulated crash'); $e.Data['I2ACrash'] = $true; return $e }
function global:Get-I2ALabel([string]$Name, [object[]]$CallArgs) {
    $short = $Name.Substring(2)
    if ($Name -eq 'DgJournal-Append') {
        $txt = [System.Text.Encoding]::UTF8.GetString([byte[]]$CallArgs[1])
        $stage = '?'; $id = ''
        if ($txt -match '"stage":"(\w+)"') { $stage = $Matches[1] }
        if ($txt -match '"itemId":(\d+)') { $id = '#' + $Matches[1] }
        return ('Journal:' + $stage + $id)
    }
    $pick = 0
    if (@('DgFs-CopyFileDurable', 'DgFs-Replace', 'DgFs-MoveNew') -contains $Name) { $pick = 1 }
    if ($CallArgs.Count -gt $pick -and $CallArgs[$pick] -is [string]) { return ($short + ':' + [System.IO.Path]::GetFileName([string]$CallArgs[$pick])) }
    return $short
}
function global:Invoke-I2APoint([string]$Name, [string]$Label, [bool]$Mut) {
    $fh = $global:I2AFH
    $fh.All++
    if ($Mut) { $fh.Mut++ }
    if ($fh.Record) { [void]$fh.AllLabels.Add($Label); if ($Mut) { [void]$fh.MutLabels.Add($Label); [void]$fh.MutAllIdx.Add($fh.All) } }
    if ($fh.CrashPattern.Length -gt 0 -and $Label -match $fh.CrashPattern) {
        $fh.CrashMatches++
        if ($fh.CrashMatches -eq $fh.CrashNth) { $fh.Fired = $Label; $fh.Dead = $true; throw (New-I2ACrash) }
    }
    $fire = $false
    if (@($fh.ThrowTargets) -contains $fh.All) { $fh.Fired = $Label; throw (New-Object System.IO.IOException('I2A injected IO error (ThrowTargets)')) }
    if ($fh.Mode -eq 'ThrowAll') { if (@($fh.Targets) -contains $fh.All) { $fire = $true } }
    elseif ($fh.Mode -eq 'CrashMut' -or $fh.Mode -eq 'KillMut') { if ($Mut -and @($fh.Targets) -contains $fh.Mut) { $fire = $true } }
    elseif ($fh.Mode -eq 'Label') {
        if ($Label -match $fh.Pattern) { $fh.Matches++; if ($fh.Matches -eq $fh.Nth) { $fire = $true } }
    }
    if (-not $fire) { return }
    $fh.Fired = $Label
    $action = $fh.Action
    if ($fh.Mode -eq 'CrashMut') { $action = 'Crash' }
    if ($fh.Mode -eq 'KillMut') { $action = 'Kill' }
    if ($action -eq 'Callback') { & $fh.Callback $fh.LastArgs; return }   # arbitrary test-side mutation; must use plain .NET calls only
    if ($action -eq 'CorruptDest') { [System.IO.File]::WriteAllText([string]$fh.LastArgs[1], 'CORRUPTED-BY-I2A-HARNESS', [System.Text.Encoding]::ASCII); return }
    if ($action -eq 'Hold') { [void]$fh.Held.Add((New-Object System.IO.FileStream([string]$fh.HoldPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read))); return }
    if ($action -eq 'Crash') { $fh.Dead = $true; throw (New-I2ACrash) }
    if ($action -eq 'Kill') { [System.Diagnostics.Process]::GetCurrentProcess().Kill(); Start-Sleep -Seconds 30 }
    if ($action -eq 'Unauthorized') { throw (New-Object System.UnauthorizedAccessException('I2A injected access denied')) }
    if ($action -eq 'InUse') { throw (DgError 'InUse' 'I2A injected in-use') }
    throw (New-Object System.IO.IOException('I2A injected IO error'))
}
function Reset-I2AFault {
    param([string]$Mode = 'None', [int[]]$Targets = @(), [string]$Pattern = '', [int]$Nth = 1, [string]$Action = 'IO', [bool]$Record = $false, [string]$CrashPattern = '', [int]$CrashNth = 1, [string]$HoldPath = '', [int[]]$ThrowTargets = @(), [scriptblock]$Callback = $null)
    $old = $global:I2AFH
    $global:I2AFH = @{ Callback = $Callback; Mode = $Mode; Targets = $Targets; Pattern = $Pattern; Nth = $Nth; Action = $Action; Record = $Record; Matches = 0; All = 0; Mut = 0; Dead = $false; Fired = ''
        CrashPattern = $CrashPattern; CrashNth = $CrashNth; CrashMatches = 0; HoldPath = $HoldPath; LastArgs = @(); ThrowTargets = $ThrowTargets
        AllLabels = (New-Object System.Collections.ArrayList); MutLabels = (New-Object System.Collections.ArrayList); MutAllIdx = (New-Object System.Collections.ArrayList)
        Streams = (New-Object System.Collections.ArrayList); Held = (New-Object System.Collections.ArrayList)
        Tick = $(if ($null -ne $old) { $old.Tick } else { 0 }); IdCounter = $(if ($null -ne $old) { $old.IdCounter } else { 0 }) }
    if ($null -ne $old) { foreach ($s in $old.Streams) { try { $s.Dispose() } catch {} }; foreach ($s in $old.Held) { try { $s.Dispose() } catch {} } }
}
function Release-I2AHeld {
    $fh = $global:I2AFH
    foreach ($s in $fh.Held) { try { $s.Dispose() } catch {} }; $fh.Held.Clear()
    foreach ($s in $fh.Streams) { try { $s.Dispose() } catch {} }; $fh.Streams.Clear()   # journal handles leaked by an exception injected after the primitive returned
}
function Reset-I2ACounters { $global:I2AFH.Tick = 0; $global:I2AFH.IdCounter = 0 }
# After a simulated crash: release leaked handles (the OS does this for a real crash) and become alive again.
function Resume-I2AAfterCrash {
    $fh = $global:I2AFH
    foreach ($s in $fh.Streams) { try { $s.Dispose() } catch {} }
    $fh.Streams.Clear()
    $fh.Dead = $false; $fh.Mode = 'None'; $fh.Targets = @()
}
function Install-I2AHarness {
    if ($null -eq $global:I2AFH) { Reset-I2AFault }
    foreach ($p in $script:I2APrimitives) {
        $name = $p[0]; $mut = $p[1]
        if (-not $global:I2AOrig.ContainsKey($name)) { $global:I2AOrig[$name] = (Get-Command $name -CommandType Function).ScriptBlock }
        $text = @"
`$fh = `$global:I2AFH
if (`$fh.Dead) { if ('$name' -eq 'DgJournal-Close') { return }; throw (New-I2ACrash) }
`$label = Get-I2ALabel '$name' `$args
`$fh.LastArgs = `$args
Invoke-I2APoint '$name' ('before:' + `$label) `$$mut
`$r = & (`$global:I2AOrig['$name']) @args
if ('$name' -like 'DgJournal-Open*') { [void]`$fh.Streams.Add(`$r) }
Invoke-I2APoint '$name' ('after:' + `$label) `$$mut
if (`$null -ne `$r) { if (`$r -is [array]) { return ,`$r }; return `$r }
"@
        Set-Item -Path ('function:script:' + $name) -Value ([scriptblock]::Create($text))
    }
    Set-Item -Path 'function:script:DgClock-Now' -Value ([scriptblock]::Create('$fh = $global:I2AFH; $fh.Tick++; return (''2026-01-01T00:00:00.{0:D6}Z'' -f $fh.Tick)'))
    Set-Item -Path 'function:script:DgId-New' -Value ([scriptblock]::Create('param([string]$Kind) $fh = $global:I2AFH; $fh.IdCounter++; return (''T{0:D4}'' -f $fh.IdCounter)'))
}
function Uninstall-I2AHarness {
    foreach ($name in @($global:I2AOrig.Keys)) { Set-Item -Path ('function:script:' + $name) -Value $global:I2AOrig[$name] }
    $global:I2AOrig = @{}
}

# ---------------------------------------------------------------- journal tampering with a consistent hash chain (for forged-journal tests)
function Edit-I2AJournal([string]$Path, [scriptblock]$Mutator, [scriptblock]$SequenceMap = $null) {
    $lines = @([System.IO.File]::ReadAllText($Path) -split "`n" | Where-Object { $_.Length -gt 0 })
    $recs = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $o = $l | ConvertFrom-Json
        $d = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($p in $o.PSObject.Properties) { if ($p.Name -ne 'previousHash' -and $p.Name -ne 'recordHash') { $d.Add($p.Name, $p.Value) } }
        [void]$recs.Add($d)
    }
    & $Mutator $recs
    $prev = DgConst-ZeroHash
    $sb = New-Object System.Text.StringBuilder
    $seq = 0
    foreach ($d in $recs) {
        $seq++
        $d['sequence'] = $(if ($null -ne $SequenceMap) { [int](& $SequenceMap $seq) } else { $seq })
        $f = DgJournal-FormatRecord $d $prev
        [void]$sb.Append($f.Line + "`n")
        $prev = $f.Hash
    }
    [System.IO.File]::WriteAllBytes($Path, $script:Utf8.GetBytes($sb.ToString()))
}
function Get-I2AActiveJournalPath($Layout) {
    $dirs = @()
    $base = Join-Path $Layout.State 'txn'
    if ([System.IO.Directory]::Exists($base)) { $dirs = [System.IO.Directory]::GetDirectories($base) }
    if ($dirs.Count -ne 1) { return '' }
    return (Join-Path $dirs[0] 'journal.jsonl')
}

function Get-I2AScriptAst([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw ('Parse errors in ' + $Path) }
    return $ast
}

# ---------------------------------------------------------------- independent oracle
# Builds the expected managed tree purely from the scenario SPEC (never from a run of the code under test).
# ItemStates: item Name -> 'pre' | 'post' (default 'pre').  State: 'old' | 'new'.  Dirs: 'pre' | 'post' (directories created for new files stay until the rollback cleanup phase).
function Get-I2AContentSha([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($Text)))).Replace('-', '') } finally { $sha.Dispose() }
}
function Get-I2AOracle([string]$Scenario, [hashtable]$ItemStates = @{}, [string]$State = 'old', [string]$Dirs = 'pre') {
    $map = @{}
    foreach ($d in 'dest', 'src', 'state', 'guard', 'guard\sub') { $map['d:' + $d] = 'DIR' }
    $map['f:guard\g1.txt'] = Get-I2AContentSha 'guard-1'
    $map['f:guard\sub\g2.dll'] = Get-I2AContentSha 'guard-2'
    if ($State -eq 'new') { $map['f:state\installed-state.json'] = Get-I2AContentSha ('state-v2|' + $Scenario) }
    elseif ($Scenario -ne 'F1') { $map['f:state\installed-state.json'] = Get-I2AContentSha ('state-v1|' + $Scenario) }
    if ($Scenario -eq 'F1') { $map['d:dest\bveex\extensions'] = 'DIR'; $map['d:dest\emua\inis'] = 'DIR'; $map['d:dest\bveex'] = 'DIR'; $map['d:dest\emua'] = 'DIR' }
    $addAncestors = {
        param($rel)
        $parts = $rel.ToLowerInvariant().Split('\')
        $acc = 'dest'
        for ($i = 0; $i -lt ($parts.Length - 1); $i++) { $acc = $acc + '\' + $parts[$i]; $map['d:' + $acc] = 'DIR' }
    }
    foreach ($s in (Get-I2ASpec $Scenario)) {
        $rel = $s.Rel.ToLowerInvariant()
        if ($s.Op -eq 'Write') { $map['f:src\' + $s.Name.ToLowerInvariant() + '.src'] = Get-I2AContentSha (Get-I2AContent $Scenario $s.Name $s.Post) }
        if ($null -ne $s.Pre) {
            # the fixture drops a neighbor.txt next to every file that exists before the install
            & $addAncestors $s.Rel
            $dir = [System.IO.Path]::GetDirectoryName($s.Rel).ToLowerInvariant()
            $map['f:dest\' + $dir + '\neighbor.txt'] = Get-I2AContentSha 'neighbor'
        }
        $st = 'pre'; if ($ItemStates.ContainsKey($s.Name)) { $st = [string]$ItemStates[$s.Name] }
        if ($st -eq 'post') {
            if ($s.Op -eq 'Write') { $map['f:dest\' + $rel] = Get-I2AContentSha (Get-I2AContent $Scenario $s.Name $s.Post); & $addAncestors $s.Rel }
        } elseif ($null -ne $s.Pre) { $map['f:dest\' + $rel] = Get-I2AContentSha (Get-I2AContent $Scenario $s.Name $s.Pre) }
        if ($Dirs -eq 'post' -and $s.Op -eq 'Write') { & $addAncestors $s.Rel }
    }
    return $map
}

# ---------------------------------------------------------------- evidence
$global:I2AEvidencePath = ''
function Add-I2AEvidence([hashtable]$Case) {
    if ([string]::IsNullOrEmpty($global:I2AEvidencePath)) { return }
    $json = ConvertTo-Json -InputObject $Case -Compress -Depth 6
    [System.IO.File]::AppendAllText($global:I2AEvidencePath, $json + "`n", $script:Utf8)
}
function Get-I2AExpectedTrees([string]$Scenario) {
    # Builds the scenario in a throw-away sandbox with the real (unwrapped) primitives to learn the expected pre/post managed trees.
    $root = New-I2ASandbox ('exp-' + $Scenario)
    try {
        $layout = New-I2AFixture $root $Scenario
        $pre = Get-I2AManagedTree $layout
        $r = Invoke-I2ARun $layout
        if (-not $r.Succeeded) { throw ('Expected-tree run failed: ' + $r.Code + ' ' + $r.Message) }
        $post = Get-I2AManagedTree $layout
        return @{ Pre = $pre; Post = $post }
    } finally { Remove-I2ASandbox $root }
}
