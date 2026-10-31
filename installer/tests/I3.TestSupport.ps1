# Shared helpers for the I3 (PCSX2 1.6.0 / LilyPad: detect, install, restore, generation, Deferred end) tests. ASCII only.
# Dot-source this file AFTER DenGoInstallerTransaction.ps1, DenGoInstallerProductApply.ps1 and DenGoUninstallerProductApply.ps1; it defines no product behaviour.
# Everything runs in sandboxes under TEMP. The real PCSX2 / LilyPad settings, the real Documents folder, the registry and every real process are never touched:
#   - Get-DenGoDocumentsRoot is redefined to a sandbox folder (the product must obtain the Documents folder through that function),
#   - the SHA-256 of a fixture exe / LilyPad.dll is answered by the redefined DgFs-Sha256 (the measured contract pair), never by a real PCSX2 file,
#   - a primitive call below the real Documents folder aborts the test (safety net).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')   # I2B / I2A support: Assert-I2A, sandboxes, tree maps, Get-I2BLayout, Cnt / Same / Diff3, I2C state helpers

$script:I3Repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
# ---- contract values (DE-I3-1): the MEASURED pair of the owner's PCSX2 1.6.0. They are RED / GREEN contract values only; the formal allow list is not confirmed.
$script:I3PairExeSha = 'E387C713005082A19DB33F4E163A7F48671C1F9EA06BFD76C6F120B246043E59'
$script:I3PairPluginSha = '637DEF94C71ED72A9F04F1541FBFFE4AB63F866461157E80EE90672FC380ADA1'
$script:I3OtherExeSha = 'B2' * 32
$script:I3OtherPluginSha = 'C3' * 32
$script:I3ActiveSha = '7D2AE3223EB5CDA8C5048091370BA28B9D65C3EC2BC3421EF618A84EED161DE0'   # DenGo-LilyPad-Active.ini (asset; I3 never changes it)
$script:I3LilySha = 'CD4993CAF9E4496A78A34F2FB590EB851057409128DB31A13ADA2ED0FA731795'     # DenGo-Controller-Converter.lily (asset)
$script:I3RealDocuments = [System.Environment]::GetFolderPath('MyDocuments')

# Invokes a script block and never throws: { Ok; Value; Error }. A missing product function shows up as Ok = $false with the command-not-found text.
function Invoke-I3([scriptblock]$Block) {
    try { $v = & $Block; return [pscustomobject]@{ Ok = $true; Value = $v; Error = '' } }
    catch { return [pscustomobject]@{ Ok = $false; Value = $null; Error = ([string]$_.Exception.GetType().Name + ': ' + [string]$_.Exception.Message) } }
}
function Get-I3Err($R) { if ($R.Ok) { return '' } return ' [' + $R.Error + ']' }
function Get-I3Prop($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}
function ConvertTo-I3Json($Value) { return (ConvertTo-Json -InputObject $Value -Depth 9 -Compress) }

# ---------------------------------------------------------------- sandbox
function New-I3Sandbox([string]$Name) { return (New-I2ASandbox ('i3-' + $Name)) }
function Write-I3Bytes([string]$Path, [byte[]]$Bytes) {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}
function Write-I3Text([string]$Path, [string]$Text) {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-I3Sha([string]$Path) { return (Get-I2AFileSha $Path) }
function Get-I3TextSha([string]$Text) { return (DgSha256-Bytes ([byte[]](New-Object System.Text.UTF8Encoding($false)).GetBytes($Text))) }

# ---------------------------------------------------------------- PE stubs (real bytes; DgP-PeMachine reads them)
function New-I3PeBytes([string]$Machine, [string]$Tag = '') {
    $b = New-Object byte[] 256
    $kind = $Machine
    if ($kind -in @('x86', 'x64', 'arm64', 'arm32')) {
        $b[0] = 0x4D; $b[1] = 0x5A
        [System.BitConverter]::GetBytes([int]0x40).CopyTo($b, 0x3C)
        $b[0x40] = 0x50; $b[0x41] = 0x45; $b[0x42] = 0; $b[0x43] = 0
        $m = switch ($kind) { 'x86' { 0x014C } 'x64' { 0x8664 } 'arm64' { 0xAA64 } default { 0x01C4 } }
        [System.BitConverter]::GetBytes([uint16]$m).CopyTo($b, 0x44)
    } elseif ($kind -eq 'InvalidPE') {
        $b[0] = 0x4D; $b[1] = 0x5A
        [System.BitConverter]::GetBytes([int]0x7FFFFFF0).CopyTo($b, 0x3C)
    } elseif ($kind -eq 'NotPE') {
        for ($i = 0; $i -lt 128; $i++) { $b[$i] = 0x41 }
    } elseif ($kind -eq 'Empty') {
        return ,(New-Object byte[] 0)
    }
    $t = [System.Text.Encoding]::ASCII.GetBytes($Tag)
    for ($i = 0; $i -lt [Math]::Min($t.Length, 32); $i++) { $b[0xC0 + $i] = $t[$i] }
    return ,$b
}

# ---------------------------------------------------------------- fake SHA-256 / call recording (primitive layer)
$global:I3ShaMap = @{}
$global:I3Rec = $null
$global:I3Orig = @{}
$global:I3SafetyRoot = ''
function Set-I3FakeSha([string]$Path, [string]$Sha) { $global:I3ShaMap[[System.IO.Path]::GetFullPath($Path).ToUpperInvariant()] = $Sha }
function Clear-I3FakeSha { $global:I3ShaMap = @{} }
function Start-I3Record { $global:I3Rec = New-Object System.Collections.ArrayList }
function Stop-I3Record { $r = $global:I3Rec; $global:I3Rec = $null; if ($null -eq $r) { return , @() } return , @($r) }
# Records are 'Kind|full path' (the first path argument). Returns the records whose path is below (or equal to) one of the given roots.
function Select-I3Rec($Records, [string[]]$Roots) {
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @($Records)) {
        $p = ([string]$r).Substring(([string]$r).IndexOf('|') + 1)
        foreach ($root in @($Roots)) {
            $x = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
            if ($p.Equals($x, [System.StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($x + '\', [System.StringComparison]::OrdinalIgnoreCase)) { [void]$out.Add([string]$r); break }
        }
    }
    return , @($out)
}
function Select-I3RecLeaf($Records, [string]$LeafPattern) {
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @($Records)) { $p = ([string]$r).Substring(([string]$r).IndexOf('|') + 1); if ([System.IO.Path]::GetFileName($p) -imatch $LeafPattern) { [void]$out.Add([string]$r) } }
    return , @($out)
}
$script:I3Wrapped = @('DgFs-Exists', 'DgFs-DirExists', 'DgFs-Sha256', 'DgFs-ReadAllBytesShared', 'DgFs-GetReparseComponents', 'DgFs-ProbeExclusive', 'DgFs-CreateFileDurable', 'DgFs-WriteTextFile',
    'DgFs-CopyFileDurable', 'DgFs-Replace', 'DgFs-MoveNew', 'DgFs-Delete', 'DgFs-CreateDir', 'DgFs-RemoveDirIfEmpty', 'DgP-ReadHeader')
# Installs the recording / fake-SHA wrappers over the primitive layer (call AFTER every product file has been dot-sourced).
function Install-I3Overrides {
    foreach ($name in $script:I3Wrapped) {
        if (-not $global:I3Orig.ContainsKey($name)) { $global:I3Orig[$name] = (Get-Command $name -CommandType Function).ScriptBlock }
        $isSha = $(if ($name -eq 'DgFs-Sha256') { '$true' } else { '$false' })
        $text = @"
`$p0 = ''
if (`$args.Count -gt 0 -and `$args[0] -is [string] -and `$args[0].Length -gt 0) { try { `$p0 = [System.IO.Path]::GetFullPath([string]`$args[0]) } catch { `$p0 = [string]`$args[0] } }
if (`$global:I3SafetyRoot.Length -gt 0 -and `$p0.Length -gt 0 -and (`$p0.Equals(`$global:I3SafetyRoot, [System.StringComparison]::OrdinalIgnoreCase) -or `$p0.StartsWith(`$global:I3SafetyRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))) { throw 'I3 TEST SAFETY: the real Documents folder was touched through ' + '$name' + ': ' + `$p0 }
if (`$null -ne `$global:I3Rec -and `$p0.Length -gt 0) { [void]`$global:I3Rec.Add('$name' + '|' + `$p0) }
if ($isSha -and `$p0.Length -gt 0 -and `$global:I3ShaMap.ContainsKey(`$p0.ToUpperInvariant())) { return `$global:I3ShaMap[`$p0.ToUpperInvariant()] }
`$r = & (`$global:I3Orig['$name']) @args
if (`$null -ne `$r) { if (`$r -is [array]) { return ,`$r }; return `$r }
"@
        Set-Item -Path ('function:script:' + $name) -Value ([scriptblock]::Create($text))
    }
    $global:I3SafetyRoot = [System.IO.Path]::GetFullPath($script:I3RealDocuments).TrimEnd('\')
}
function Uninstall-I3Overrides {
    foreach ($name in @($global:I3Orig.Keys)) { Set-Item -Path ('function:script:' + $name) -Value $global:I3Orig[$name] }
    $global:I3Orig = @{}; $global:I3ShaMap = @{}; $global:I3Rec = $null; $global:I3SafetyRoot = ''
}
# The Documents folder is a seam: the product asks Get-DenGoDocumentsRoot (redefined here); a product that bypasses it trips the safety net above.
$global:I3Docs = ''
function Set-I3DocumentsRoot([string]$Path) {
    $global:I3Docs = $Path
    Set-Item -Path 'function:script:Get-DenGoDocumentsRoot' -Value ([scriptblock]::Create('return $global:I3Docs'))
}

# ---------------------------------------------------------------- fixtures
# An install folder of PCSX2 (exe, optional Plugins\LilyPad.dll, optional portable markers). The exe / dll SHA-256 are answered by the fake-SHA map.
function New-I3Pcsx2Home {
    param([string]$Dir, [string]$ExeName = 'pcsx2.exe', [string]$Machine = 'x86', [bool]$Plugin = $true, [string]$ExeSha = 'PAIR', [string]$PluginSha = 'PAIR', [bool]$PortableIni = $false, [bool]$PortableTxt = $false)
    $exe = Join-Path $Dir $ExeName
    Write-I3Bytes $exe (New-I3PeBytes $Machine ($ExeName + '|' + $Dir))
    if ($ExeSha -eq 'PAIR') { $ExeSha = $script:I3PairExeSha }
    if ($ExeSha.Length -gt 0) { Set-I3FakeSha $exe $ExeSha }
    if ($Plugin) {
        $dll = Join-Path $Dir 'Plugins\LilyPad.dll'
        Write-I3Bytes $dll (New-I3PeBytes 'x86' ('LilyPad|' + $Dir))
        if ($PluginSha -eq 'PAIR') { $PluginSha = $script:I3PairPluginSha }
        if ($PluginSha.Length -gt 0) { Set-I3FakeSha $dll $PluginSha }
    }
    if ($PortableIni) { Write-I3Text (Join-Path $Dir 'portable.ini') '' }
    if ($PortableTxt) { Write-I3Text (Join-Path $Dir 'portable.txt') '' }
    return $exe
}
# A settings root: <Root>\inis\{PCSX2_ui.ini, LilyPad.ini, ...}. Every switch can be turned off to build a broken root.
function New-I3Config {
    param([string]$Root, [bool]$HasInis = $true, [bool]$Ui = $true, [bool]$LilyPadIni = $true, [bool]$Pcsx2Ini = $false, [bool]$Lily = $false, [string]$LilyPadContent = 'USER-LILYPAD-ORIGINAL', [string]$LilyContent = 'USER-LILY-PROFILE')
    $inis = Join-Path $Root 'inis'
    if ($HasInis) { [System.IO.Directory]::CreateDirectory($inis) | Out-Null } else { [System.IO.Directory]::CreateDirectory($Root) | Out-Null; return $inis }
    if ($Ui) { Write-I3Text (Join-Path $inis 'PCSX2_ui.ini') "[Filenames]`r`nPAD=Plugins\LilyPad.dll" }
    Write-I3Text (Join-Path $inis 'PCSX2_vm.ini') 'vm-settings'
    Write-I3Text (Join-Path $inis 'GSdx.ini') 'gsdx-settings'
    if ($LilyPadIni) { Write-I3Text (Join-Path $inis 'LilyPad.ini') $LilyPadContent }
    if ($Pcsx2Ini) { Write-I3Text (Join-Path $inis 'PCSX2.ini') "[InputSources]`r`nKeyboard = true`r`n[Pad]`r`n[Pad1]`r`nType = DualShock2" }
    if ($Lily) { Write-I3Text (Join-Path $inis 'DenGo-Controller-Converter.lily') $LilyContent }
    return $inis
}
function New-I3Candidate([string]$Exe, [string]$Arguments = '', [string]$Source = 'DefaultLocation') {
    return [pscustomobject]@{ Platform = 'PCSX2'; Executable = $Exe; Arguments = $Arguments; Source = $Source }
}
function New-I3Junction([string]$Link, [string]$Target) {
    [System.IO.Directory]::CreateDirectory($Target) | Out-Null
    $out = & cmd.exe /c ('mklink /J "' + $Link + '" "' + $Target + '"') 2>&1
    if (-not [System.IO.Directory]::Exists($Link)) { throw ('junction was not created: ' + [string]$out) }
}
function Remove-I3Junction([string]$Link) { if ([System.IO.Directory]::Exists($Link)) { [System.IO.Directory]::Delete($Link) } }

# ---------------------------------------------------------------- plan items / records for the product layer
function New-I3PlanItem {
    param([string]$Component, [string]$Destination, [string]$Source, [string]$Action)
    $srcSha = Get-I3Sha $Source
    $dstSha = ''
    if ([System.IO.File]::Exists($Destination)) { $dstSha = Get-I3Sha $Destination }
    return [pscustomobject]@{ Platform = 'PCSX2'; Component = $Component; Action = $Action; Source = $Source; SourceSHA256 = $srcSha; Destination = $Destination; DestinationSHA256 = $dstSha }
}
function New-I3Layout([string]$Root) { return (Get-DenGoProductLayout -LocalAppData (Join-Path $Root 'Local') -PublicRoot (Join-Path $Root 'Public') -ShortcutPath '') }
function New-I3Prev($Files, $ExtraState = $null) {
    $o = [ordered]@{ SchemaVersion = 1; StateRevision = 2; ProductVersion = '2.0.0'; PCSX2LegacyKeyboardInitialized = $false; InstalledAt = '2026-10-01T00:00:00.0000000+09:00'; TransactionId = '20261001T000000Z-aaaaaaaa'; BackupRoot = ''
        Shortcut = [pscustomobject]@{ Requested = $false; Created = $false; Path = '' }; Files = [object[]]@($Files); ClosedRecords = [object[]]@() }
    return [pscustomobject]@{ Exists = $true; Sha = ('AB' * 32); State = ([pscustomobject]$o); Files = [object[]]@($Files) }
}
function New-I3Record {
    param([string]$Component, [string]$Destination, [string]$Ownership, [string]$After = '', [string]$Before = '', [string]$Backup = '', [bool]$Existed = $false, [object[]]$Backups = @(), [string]$Presence = 'InPlan', [string]$Observed = 'Present')
    $o = [ordered]@{ Platform = 'PCSX2'; Component = $Component; Destination = $Destination; InstallAction = 'UpdateOrRepair'; Ownership = $Ownership; ExistedBefore = $Existed; BeforeSHA256 = $Before; AfterSHA256 = $After; Backup = $Backup }
    if ($Presence.Length -gt 0) { $o['Presence'] = $Presence; $o['Observed'] = $Observed; $o['LastSeenTransactionId'] = '20261001T000000Z-aaaaaaaa'; $o['Backups'] = [object[]]@($Backups) }
    return [pscustomobject]$o
}
function Get-I3Rec1($State, [string]$Leaf) {
    foreach ($f in @($State.Files)) { if ([System.IO.Path]::GetFileName([string]$f.Destination) -ieq $Leaf) { return $f } }
    return $null
}
# A transaction backup as the product writes it: BackupRoot\<TxnId>\0001.bak (content = the user's original), plus the Backups[] entry for it.
function New-I3OriginBackup($Layout, [string]$TxnId, [string]$Content) {
    $dir = Join-Path $Layout.BackupRoot $TxnId
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $path = Join-Path $dir '0001.bak'
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    $sha = Get-I3Sha $path
    return [pscustomobject]@{ Path = $path; Sha = $sha; TxnId = $TxnId; Entry = [pscustomobject][ordered]@{ TransactionId = $TxnId; Path = $path; SHA256 = $sha } }
}

# ---------------------------------------------------------------- sandbox used by the engine / uninstall tests (the I2-B layout plus a PCSX2 settings root with a UI ini)
$script:I3UserOrigin = 'USER-LILYPAD-ORIGINAL-CONTENT'
function New-I3Case([string]$Name, [bool]$Ui = $true) {
    $L = New-I2BScenario ('i3-' + $Name) 'P1'
    $lily = Join-Path $L.Pcsx2Inis 'LilyPad.ini'
    [System.IO.File]::WriteAllText($lily, $script:I3UserOrigin, $script:Utf8)
    if ($Ui) { [System.IO.File]::WriteAllText((Join-Path $L.Pcsx2Inis 'PCSX2_ui.ini'), 'ui-settings', $script:Utf8) }
    [System.IO.File]::WriteAllText((Join-Path $L.Src 'active.src'), 'DENGO-ACTIVE-LILYPAD-V1', $script:Utf8)
    [System.IO.File]::WriteAllText((Join-Path $L.Src 'lily.src'), 'DENGO-LILY-PROFILE-V1', $script:Utf8)
    return $L
}
function Get-I3Dest($L, [string]$Leaf) { return (Join-Path $L.Pcsx2Inis $Leaf) }
function Get-I3Plan($L, [string]$LilyPadAction, [string]$LilyAction = 'Add') {
    return , [object[]]@(
        (New-I3PlanItem 'InputProfile' (Get-I3Dest $L 'DenGo-Controller-Converter.lily') (Join-Path $L.Src 'lily.src') $LilyAction),
        (New-I3PlanItem 'EffectiveInputProfile' (Get-I3Dest $L 'LilyPad.ini') (Join-Path $L.Src 'active.src') $LilyPadAction))
}
function Invoke-I3Install($L, $Plan, [scriptblock]$ProcessGate = $null) { return (Invoke-I2BInstall $L $Plan $false $ProcessGate) }
function Get-I3PcsxTree($L) { return (Get-I2ATreeMap (Split-Path $L.Pcsx2Inis -Parent) @()) }

# ---------------------------------------------------------------- input SHA-256 manifest (ties a result to the exact files it ran against)
function Get-I3NewFileList {
    return @(
        'installer/tests/I3.TestSupport.ps1', 'installer/tests/Test-DenGoInstaller-I3-Static.ps1', 'installer/tests/Test-DenGoInstaller-I3-Unit.ps1', 'installer/tests/Test-DenGoInstaller-I3-Zero.ps1',
        'installer/tests/Test-DenGoInstaller-I3-Gate.ps1', 'installer/tests/Test-DenGoInstaller-I3-Engine.ps1', 'installer/tests/Test-DenGoInstaller-I3-Uninstall.ps1',
        'installer/tests/Test-DenGoInstaller-I3-Gui.ps1', 'installer/tests/Test-DenGoInstaller-I3-All.ps1',
        'installer/tests/Test-DenGoInstaller-I3-Fault.ps1', 'installer/tests/Test-DenGoInstaller-I3-Toctou.ps1')
}
function Get-I3ProductFileList {
    return @(
        'installer/scripts/DenGoInstallerTransaction.ps1', 'installer/scripts/DenGoInstallerProductApply.ps1', 'installer/scripts/DenGoUninstallerProductApply.ps1', 'installer/scripts/Invoke-DenGoInstaller.ps1',
        'installer/scripts/Invoke-DenGoUninstaller.ps1', 'installer/scripts/Start-DenGoSetup.ps1', 'installer/scripts/Start-DenGoUninstall.ps1', 'installer/gui/DenGoInstallerGui.ps1', 'installer/gui/DenGoUninstallerGui.ps1',
        'installer/Build-DenGo-SetupExe-2.0.0.ps1', 'installer/build/Build-DenGo-SetupPackage.ps1',
        'installer/assets/input-profiles/pcsx2/DenGo-LilyPad-Active.ini', 'installer/assets/input-profiles/pcsx2/DenGo-Controller-Converter.lily')
}
function Get-I3InputManifest {
    $rows = New-Object System.Collections.ArrayList
    foreach ($group in @(@('New', (Get-I3NewFileList)), @('Product', (Get-I3ProductFileList)))) {
        foreach ($rel in $group[1]) {
            $abs = [System.IO.Path]::GetFullPath((Join-Path $script:I3Repo ($rel.Replace('/', '\'))))
            $row = [ordered]@{ Group = $group[0]; Rel = $rel; Abs = $abs; Size = -1; Sha256 = '<missing>' }
            if ([System.IO.File]::Exists($abs)) { $row.Size = ([System.IO.FileInfo]$abs).Length; $row.Sha256 = Get-I2AFileSha $abs }
            [void]$rows.Add([pscustomobject]$row)
        }
    }
    return , @($rows)
}
function Write-I3InputManifest([string]$Path, $Rows, [string]$Label) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# I3 input SHA-256 manifest ($Label) generated $([DateTime]::UtcNow.ToString('o'))`n# Group`tSize`tSHA256`tRelativePath`n")
    foreach ($r in $Rows) { [void]$sb.Append(("{0}`t{1}`t{2}`t{3}`n" -f $r.Group, $r.Size, $r.Sha256, $r.Rel)) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
