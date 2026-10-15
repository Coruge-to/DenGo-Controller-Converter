# Shared helpers for the I2-B (product transaction integration) tests. ASCII only.
# Dot-source AFTER DenGoInstallerTransaction.ps1 and DenGoInstallerProductApply.ps1. Builds on I2A.TestSupport.ps1 (fault harness, tree maps).
# Writes only below a sandbox under TEMP. Never touches product paths, the registry or any third-party application.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')

# A unique lock name per test process: the real product lock name is never used by the tests.
$script:I2BLockName = 'Local\DenGoI2BTest-' + [System.Guid]::NewGuid().ToString('N')
function Get-DenGoLockName { return $script:I2BLockName }
function Set-I2BLockName([string]$Name) { $script:I2BLockName = $Name }
# Production transaction ids by default; tests that install the fault harness (ids T0001...) switch the pattern.
$script:I2BTxnPattern = ''
function Use-I2BHarnessIds { $script:I2BTxnPattern = '^T[0-9]{4}$' }
function Use-I2BProductIds { $script:I2BTxnPattern = '' }

$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function New-I2BPeStub([string]$Path, [string]$Machine) {
    $b = New-Object byte[] 256
    $b[0] = 0x4D; $b[1] = 0x5A
    [System.BitConverter]::GetBytes([int]0x40).CopyTo($b, 0x3C)
    $b[0x40] = 0x50; $b[0x41] = 0x45; $b[0x42] = 0; $b[0x43] = 0
    $m = $(if ($Machine -eq 'x86') { 0x014C } else { 0x8664 })
    [System.BitConverter]::GetBytes([uint16]$m).CopyTo($b, 0x44)
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $b)
}

# Item spec: Name, Platform, Component, destination, CreateParent, PreserveModified
function Get-I2BLayout([string]$Root) {
    $local = Join-Path $Root 'Local'
    $pub = Join-Path $Root 'Public'
    $desktop = Join-Path $Root 'Desktop'
    $layout = Get-DenGoProductLayout -LocalAppData $local -PublicRoot $pub -ShortcutPath (Join-Path $desktop 'DenGo Controller Converter.lnk') -TxnIdPattern $script:I2BTxnPattern
    return [pscustomobject]@{
        Root = $Root; Product = $layout; Local = $local; Public = $pub; Desktop = $desktop; Src = (Join-Path $Root 'Src'); Guard = (Join-Path $Root 'Guard'); Stage = (Join-Path $Root 'TempStage')
        Bve5 = (Join-Path $Root 'Bve5'); Bve6 = (Join-Path $Root 'Bve6'); Rpcs3 = (Join-Path $Root 'Rpcs3'); Rpcs3Global = (Join-Path $Root 'Rpcs3\config\input_configs\global'); Pcsx2Inis = (Join-Path $Root 'Pcsx2\inis')
    }
}
function Get-I2BItemSpecs($L) {
    $p = $L.Product
    return @(
        @{ N = 'app'; Pl = 'Core'; Co = 'Application'; Dest = $p.AppExe; Cp = $true; Pm = $false },
        @{ N = 'ico'; Pl = 'Core'; Co = 'Icon'; Dest = $p.AppIco; Cp = $true; Pm = $false },
        @{ N = 'c5'; Pl = 'BVE5'; Co = 'Caller'; Dest = (Join-Path $L.Bve5 'Input Devices\DenGoControllerConverter.dll'); Cp = $true; Pm = $false },
        @{ N = 'c6'; Pl = 'BVE6'; Co = 'Caller'; Dest = (Join-Path $L.Bve6 'Input Devices\DenGoControllerConverter.dll'); Cp = $true; Pm = $false },
        @{ N = 'cb'; Pl = 'BveEX Current'; Co = 'Bridge'; Dest = (Join-Path $p.CurrentExt 'DenGoVehicleSpec.BveEx.Bridge.dll'); Cp = $false; Pm = $false },
        @{ N = 'cv'; Pl = 'BveEX Current'; Co = 'VehicleSpec'; Dest = (Join-Path $p.CurrentExt 'DenGoBveVehicleSpec.dll'); Cp = $false; Pm = $false },
        @{ N = 'lb'; Pl = 'AtsEX Legacy'; Co = 'Bridge'; Dest = (Join-Path $p.LegacyExt 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll'); Cp = $false; Pm = $false },
        @{ N = 'lv'; Pl = 'AtsEX Legacy'; Co = 'VehicleSpec'; Dest = (Join-Path $p.LegacyExt 'DenGoAtsExLegacyVehicleSpec.dll'); Cp = $false; Pm = $false },
        @{ N = 'r3'; Pl = 'RPCS3'; Co = 'InputProfile'; Dest = (Join-Path $L.Rpcs3Global 'Den-Go-Controller.yml'); Cp = $false; Pm = $true },
        @{ N = 'p1'; Pl = 'PCSX2'; Co = 'InputProfile'; Dest = (Join-Path $L.Pcsx2Inis 'DenGo-Controller-Converter.lily'); Cp = $true; Pm = $false },
        @{ N = 'p2'; Pl = 'PCSX2'; Co = 'EffectiveInputProfile'; Dest = (Join-Path $L.Pcsx2Inis 'LilyPad.ini'); Cp = $true; Pm = $false })
}
function Get-I2BContent([string]$Scenario, [string]$Name, [string]$Version) { return (($Scenario + '|' + $Name + '|' + $Version + '|') * (2 + ($Name.Length % 4))) }
# Pre-state per scenario: 'none' | 'old' | 'same'
function Get-I2BPre([string]$Scenario, [string]$Name) {
    if ($Scenario -in @('P1', 'P4')) { if ($Name -eq 'p2') { return 'old' }; return 'none' }
    if ($Scenario -eq 'P2') { return 'old' }
    if ($Scenario -eq 'P3') { if ($Name -in @('p1', 'p2')) { return 'old' }; return 'same' }
    throw ('Unknown scenario ' + $Scenario)
}
function New-I2BFixture([string]$Root, [string]$Scenario) {
    $L = Get-I2BLayout $Root
    foreach ($d in $L.Src, $L.Guard, $L.Stage, $L.Desktop, $L.Local, $L.Public) { [System.IO.Directory]::CreateDirectory($d) | Out-Null }
    New-I2BPeStub (Join-Path $L.Bve5 'BveTs.exe') 'x86'
    New-I2BPeStub (Join-Path $L.Bve6 'BveTs.exe') 'x64'
    New-I2BPeStub (Join-Path $L.Rpcs3 'rpcs3.exe') 'x64'
    foreach ($d in $L.Product.CurrentExt, $L.Product.LegacyExt, $L.Rpcs3Global, $L.Pcsx2Inis) { [System.IO.Directory]::CreateDirectory($d) | Out-Null }
    foreach ($s in (Get-I2BItemSpecs $L)) {
        [System.IO.File]::WriteAllText((Join-Path $L.Src ($s.N + '.src')), (Get-I2BContent $Scenario $s.N 'new'), $script:Utf8)
        $pre = Get-I2BPre $Scenario $s.N
        if ($pre -ne 'none') {
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($s.Dest)) | Out-Null
            [System.IO.File]::WriteAllText($s.Dest, $(if ($pre -eq 'same') { Get-I2BContent $Scenario $s.N 'new' } else { Get-I2BContent $Scenario $s.N 'old' }), $script:Utf8)
        }
    }
    # neighbours and guards: files the installer must never touch
    [System.IO.File]::WriteAllText((Join-Path $L.Rpcs3Global 'Other.yml'), 'other-yaml', $script:Utf8)
    [System.IO.File]::WriteAllText((Join-Path $L.Rpcs3 'config\input_configs\keep.txt'), 'keep', $script:Utf8)
    [System.IO.File]::WriteAllText((Join-Path $L.Pcsx2Inis 'PCSX2.ini'), 'pcsx2-ini', $script:Utf8)
    [System.IO.File]::WriteAllText((Join-Path $L.Guard 'g1.txt'), 'guard-1', $script:Utf8)
    # P4: like P1 but Programs does not exist at all (it is created by the transaction and removed again by a rollback)
    if ($Scenario -ne 'P4') {
        [System.IO.Directory]::CreateDirectory((Join-Path $L.Local 'Programs\Other')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $L.Local 'Programs\Other\x.txt'), 'other-program', $script:Utf8)
    }
    if ($Scenario -in @('P1', 'P4')) {
        # Programs\DenGo Controller Converter is missing (created by the transaction); Bve6 has Input Devices, Bve5 does not
        [System.IO.Directory]::CreateDirectory((Join-Path $L.Bve6 'Input Devices')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $L.Bve6 'Input Devices\other.dll'), 'other-device', $script:Utf8)
    }
    return $L
}
function New-I2BPlanItem($L, $Spec, [string]$Scenario, [bool]$ReplaceRpcs3) {
    $source = Join-Path $L.Src ($Spec.N + '.src')
    $sourceSha = Get-I2AFileSha $source
    $destSha = ''
    if ([System.IO.File]::Exists($Spec.Dest)) {
        $destSha = Get-I2AFileSha $Spec.Dest
        if ($sourceSha -eq $destSha) { $action = 'Unchanged' } elseif ($Spec.Pm) { $action = 'PreserveUserModified' } else { $action = 'UpdateOrRepair' }
    } else {
        $parent = [System.IO.Path]::GetDirectoryName($Spec.Dest)
        if ([System.IO.Directory]::Exists($parent) -or $Spec.Cp) { $action = 'Add' } else { $action = 'NotInitialized' }
    }
    if ($action -eq 'PreserveUserModified' -and $Spec.Pl -eq 'RPCS3' -and $ReplaceRpcs3) { $action = 'UpdateOrRepair' }
    return [pscustomobject]@{ Platform = $Spec.Pl; Component = $Spec.Co; Action = $action; Source = $source; SourceSHA256 = $sourceSha; Destination = $Spec.Dest; DestinationSHA256 = $destSha }
}
function Get-I2BPlan($L, [string]$Scenario, [bool]$ReplaceRpcs3 = $true) {
    $plan = New-Object System.Collections.ArrayList
    foreach ($s in (Get-I2BItemSpecs $L)) { [void]$plan.Add((New-I2BPlanItem $L $s $Scenario $ReplaceRpcs3)) }
    return , [object[]]@($plan)
}

# A valid installed-state.json (as the old engine would have written it) for P2 / P3, with records that this plan does not contain.
function Write-I2BPreviousState($L, [string]$Scenario) {
    $files = New-Object System.Collections.ArrayList
    foreach ($s in (Get-I2BItemSpecs $L)) {
        if ($s.Pl -eq 'PCSX2' -and $s.N -eq 'p1') { continue }
        if (-not [System.IO.File]::Exists($s.Dest)) { continue }
        $own = $(if ($s.Pl -eq 'PCSX2' -or $s.Pl -eq 'RPCS3') { 'ReplacedExisting' } else { 'CreatedByInstaller' })
        $backup = ''; $before = ''
        if ($own -eq 'ReplacedExisting') { $backup = Join-Path $L.Root ('OldBackups\' + $s.N + '.bak'); [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($backup)) | Out-Null; [System.IO.File]::WriteAllText($backup, ('origin-' + $s.N), $script:Utf8); $before = Get-I2AFileSha $backup }
        [void]$files.Add([pscustomobject][ordered]@{ Platform = $s.Pl; Component = $s.Co; Destination = $s.Dest; InstallAction = 'Add'; Ownership = $own; ExistedBefore = ($own -eq 'ReplacedExisting'); BeforeSHA256 = $before; AfterSHA256 = (Get-I2AFileSha $s.Dest); Backup = $backup })
    }
    # records outside this plan: an owning one for a BVE5 install that is not detected now, and two non-owning ones
    $gone = Join-Path $L.Root 'OldBve\Input Devices\DenGoControllerConverter.dll'
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($gone)) | Out-Null
    [System.IO.File]::WriteAllText($gone, 'old-bve-caller', $script:Utf8)
    [void]$files.Add([pscustomobject][ordered]@{ Platform = 'BVE5'; Component = 'Caller'; Destination = $gone; InstallAction = 'Add'; Ownership = 'CreatedByInstaller'; ExistedBefore = $false; BeforeSHA256 = ''; AfterSHA256 = (Get-I2AFileSha $gone); Backup = '' })
    $missingOwning = Join-Path $L.Root 'OldBve2\Input Devices\DenGoControllerConverter.dll'
    [void]$files.Add([pscustomobject][ordered]@{ Platform = 'BVE6'; Component = 'Caller'; Destination = $missingOwning; InstallAction = 'Add'; Ownership = 'CreatedByInstaller'; ExistedBefore = $false; BeforeSHA256 = ''; AfterSHA256 = ('A' * 64); Backup = '' })
    $missingNon = Join-Path $L.Root 'OldRpcs3\Den-Go-Controller.yml'
    [void]$files.Add([pscustomobject][ordered]@{ Platform = 'RPCS3'; Component = 'InputProfile'; Destination = $missingNon; InstallAction = 'PreserveUserModified'; Ownership = 'PreservedUserFile'; ExistedBefore = $false; BeforeSHA256 = ''; AfterSHA256 = ''; Backup = '' })
    $state = [pscustomobject][ordered]@{ SchemaVersion = 1; ProductVersion = '2.0.0'; PCSX2LegacyKeyboardInitialized = $true; InstalledAt = '2026-01-01T00:00:00.0000000+09:00'; BackupRoot = (Join-Path $L.Root 'OldBackups')
        Shortcut = [pscustomobject][ordered]@{ Requested = $true; Created = $true; Path = $L.Product.ShortcutPath }; Files = [object[]]@($files) }
    [System.IO.Directory]::CreateDirectory($L.Product.StateRoot) | Out-Null
    [System.IO.File]::WriteAllText($L.Product.StatePath, ($state | ConvertTo-Json -Depth 7), (New-Object System.Text.UTF8Encoding($true)))
}
function New-I2BScenario([string]$Name, [string]$Scenario) {
    $root = New-I2ASandbox $Name
    $L = New-I2BFixture $root $Scenario
    if ($Scenario -in @('P2', 'P3')) { Write-I2BPreviousState $L $Scenario }
    return $L
}
function Get-I2BOptions($L, [bool]$Shortcut = $true, [scriptblock]$ProcessGate = $null) {
    $o = @{ ShortcutRequested = $Shortcut; StageParent = $L.Stage }
    $o['ProcessGate'] = $(if ($null -ne $ProcessGate) { $ProcessGate } else { { } })
    return $o
}
function Invoke-I2BInstall($L, $Plan, [bool]$Shortcut = $true, [scriptblock]$ProcessGate = $null) {
    return (Invoke-DenGoProductInstall -Layout $L.Product -Plan $Plan -Options (Get-I2BOptions $L $Shortcut $ProcessGate))
}

# ---------------------------------------------------------------- trees
function Test-I2BStateValid($L) {
    if (-not [System.IO.File]::Exists($L.Product.StatePath)) { return $false }
    try {
        $o = [System.IO.File]::ReadAllText($L.Product.StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return (([int]$o.SchemaVersion -eq 1) -and ([int](DgProp $o 'StateRevision' 0) -eq 2))
    } catch { return $false }
}
function Get-I2BManagedTree($L, [switch]$NormalizeState) {
    # Everything except backups, the transaction folders and the whole DenGo state tree (infrastructure that is allowed to remain);
    # the state file and the marker are added back as explicit entries. The stage folder is excluded (a real crash leaves it behind in TEMP).
    # -NormalizeState: a state written by this product (StateRevision 2) is compared as 'NEW' (its timestamps and ids differ from run to run).
    $map = Get-I2ATreeMap $L.Root @('local\dengo controller converter', 'tempstage')
    $sr = $L.Product.StateRoot
    # a shortcut's bytes depend on whether its target existed (and on the target's size / time) when it was saved: a real shortcut is compared by what it says
    if ($L.Product.ShortcutPath.Length -gt 0 -and [System.IO.File]::Exists($L.Product.ShortcutPath)) {
        $lnkKey = 'f:' + $L.Product.ShortcutPath.Substring($L.Root.Length + 1).ToLowerInvariant()
        $head = [System.IO.File]::ReadAllBytes($L.Product.ShortcutPath)
        if ($head.Length -ge 4 -and $head[0] -eq 0x4C -and $head[1] -eq 0 -and $head[2] -eq 0 -and $head[3] -eq 0) {
            $shell = New-Object -ComObject WScript.Shell
            $s = $shell.CreateShortcut($L.Product.ShortcutPath)
            $map[$lnkKey] = 'LNK|' + [string]$s.TargetPath + '|' + [string]$s.WorkingDirectory + '|' + [string]$s.IconLocation
        }
    }
    $map['x:state'] = $(if ([System.IO.File]::Exists($L.Product.StatePath)) { if ($NormalizeState -and (Test-I2BStateValid $L)) { 'NEW' } else { Get-I2AFileSha $L.Product.StatePath } } else { '<none>' })
    $map['x:marker'] = $(if ([System.IO.File]::Exists((Join-Path $sr 'installing.json'))) { 'PRESENT' } else { '<none>' })
    return $map
}
function Test-I2BLeftovers($L, [bool]$IncludeStage = $true) {
    $problems = New-Object System.Collections.ArrayList
    $sr = $L.Product.StateRoot
    foreach ($m in 'installing.json', 'uninstalling.json', 'installing.json.tmp', 'uninstalling.json.tmp', 'installed-state.json.tmp') { if ([System.IO.File]::Exists((Join-Path $sr $m))) { [void]$problems.Add($m) } }
    foreach ($f in [System.IO.Directory]::GetFiles($L.Root, '*.dengo.tmp', [System.IO.SearchOption]::AllDirectories)) { [void]$problems.Add($f.Substring($L.Root.Length)) }
    if ($IncludeStage -and [System.IO.Directory]::Exists($L.Stage)) { foreach ($e in [System.IO.Directory]::GetFileSystemEntries($L.Stage)) { [void]$problems.Add('stage:' + [System.IO.Path]::GetFileName($e)) } }
    foreach ($p in $problems) { $p }   # ALWAYS call as @(Test-I2BLeftovers ...)
}

# ---------------------------------------------------------------- small shared helpers (every boolean is built from parenthesized operands: -and/-eq have equal precedence)
function Cnt($X) { if ($null -eq $X) { return 0 }; return @($X).Count }
function Same($A, $B) { return ((Cnt (Compare-I2ATree $A $B)) -eq 0) }
function Diff3($A, $B) { return ([string]::Join(' ', [string[]]@(Compare-I2ATree $A $B | Select-Object -First 3))) }
function Get-I2BShareSha([string]$Path) {
    # shared read: a live transaction keeps its journal open for writing (FileShare.Read), so the plain I2A helper cannot hash it
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { $sha = [System.Security.Cryptography.SHA256]::Create(); try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') } finally { $sha.Dispose() } } finally { $fs.Dispose() }
}
function Get-I2BFullTree($L) {
    $rootFull = [System.IO.Path]::GetFullPath($L.Root).TrimEnd('\')
    $map = @{}
    foreach ($d in [System.IO.Directory]::GetDirectories($rootFull, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $d.Substring($rootFull.Length + 1).ToLowerInvariant()
        if ($rel -eq 'tempstage' -or $rel.StartsWith('tempstage\')) { continue }
        $map['d:' + $rel] = 'DIR'
    }
    foreach ($f in [System.IO.Directory]::GetFiles($rootFull, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $f.Substring($rootFull.Length + 1).ToLowerInvariant()
        if ($rel -eq 'tempstage' -or $rel.StartsWith('tempstage\')) { continue }
        $map['f:' + $rel] = Get-I2BShareSha $f
    }
    return $map
}
function Get-I2BHistoryJournals($L) {
    $dir = Join-Path $L.Product.StateRoot 'history'
    if (-not [System.IO.Directory]::Exists($dir)) { return @() }
    return @([System.IO.Directory]::GetFiles($dir, '*.jsonl'))
}
function Get-I2BActiveTxnDirs($L) {
    $dir = Join-Path $L.Product.StateRoot 'txn'
    if (-not [System.IO.Directory]::Exists($dir)) { return @() }
    return @([System.IO.Directory]::GetDirectories($dir))
}
function Get-I2BStateObject($L) {
    if (-not [System.IO.File]::Exists($L.Product.StatePath)) { return $null }
    return ([System.IO.File]::ReadAllText($L.Product.StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}
# expected post-state facts, built from the scenario spec and the sources only (never from a run of the code under test)
function Get-I2BExpectedPostSha($L, $Spec, [string]$Scenario) { return (Get-I2AFileSha (Join-Path $L.Src ($Spec.N + '.src'))) }