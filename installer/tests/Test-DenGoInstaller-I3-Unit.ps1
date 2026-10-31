# I3 unit tests (written RED first; plan i3-implementation-plan.md section 4 and appendix C). Same process; the primitive layer is wrapped (I3.TestSupport.ps1).
#   C  classification of an exe (Get-DenGoPcsx2Identity): the 4 conditions of PCSX2 1.6.0 (name pcsx2.exe, x86, exe SHA-256, Plugins\LilyPad.dll SHA-256 as a PAIR)
#   R  settings root (Resolve-DenGoPcsx2Root / Test-DenGoPcsx2RootProof): portable.ini or -portable only, Documents otherwise, proof, no creation
#   A  grouping of candidates (Group-DenGoPcsx2Candidates): one candidate per root, Ambiguous for 2 proven roots, unsupported kinds never become writable
#   P  plan decisions and consent (New-DenGoPcsx2PlanItems)
#   M  ownership merge: Origin, Backups[], promotion, ClosedRecords (Merge-DenGoInstalledState)
#   G  the Pcsx2 role: DgP-MapPlatform, role spec, leaf gate, shape, entries
# The product functions that do not exist yet are called through Invoke-I3: a missing function is a FAIL with the command-not-found text (the expected RED reason).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
Install-I3Overrides
$S = New-I3Sandbox 'unit'

# known pairs seam: the allow list is a product function; a test may replace it (two pairs are needed to test "both sides of the SAME pair")
$script:I3PairsOrig = $null
function Set-I3KnownPairs($Pairs) {
    if ($null -eq $script:I3PairsOrig) { $c = Get-Command Get-DenGoPcsx2KnownPairs -CommandType Function -ErrorAction SilentlyContinue; $script:I3PairsOrig = $(if ($null -ne $c) { $c.ScriptBlock } else { 'none' }) }
    $global:I3Pairs = $Pairs
    Set-Item -Path 'function:script:Get-DenGoPcsx2KnownPairs' -Value ([scriptblock]::Create('return ,@($global:I3Pairs)'))
}
function Restore-I3KnownPairs {
    if ($null -eq $script:I3PairsOrig) { return }
    if ($script:I3PairsOrig -is [scriptblock]) { Set-Item -Path 'function:script:Get-DenGoPcsx2KnownPairs' -Value $script:I3PairsOrig }
    else { if (Test-Path 'function:script:Get-DenGoPcsx2KnownPairs') { Remove-Item 'function:script:Get-DenGoPcsx2KnownPairs' } }
    $script:I3PairsOrig = $null
}
function New-I3Pair([string]$Exe, [string]$Dll) { return [pscustomobject]@{ ExeSha256 = $Exe; LilyPadSha256 = $Dll } }

function Ident([string]$Exe) { return (Invoke-I3 { Get-DenGoPcsx2Identity -ExePath $Exe }) }
function ClassOf($R) { if (-not $R.Ok) { return '<error>' } return [string](Get-I3Prop $R.Value 'Class' '<none>') }
function IsClass($R, [string]$Class) { return ($R.Ok -and ((ClassOf $R) -ceq $Class)) }
function Dtl($R) { return ('class=' + (ClassOf $R) + (Get-I3Err $R)) }
function SceneDir([string]$Name) { $d = Join-Path $S $Name; [System.IO.Directory]::CreateDirectory($d) | Out-Null; return $d }
function PathEq2([string]$A, [string]$B) { if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false } return (DgP-PathEq $A $B) }

# ================================================================ C  classification
$r = Invoke-I3 { Get-DenGoPcsx2KnownPairs }
$pairs = @($(if ($r.Ok) { $r.Value } else { @() }))
$hasContract = (@($pairs | Where-Object { ([string](Get-I3Prop $_ 'ExeSha256' '')) -ieq $script:I3PairExeSha -and ([string](Get-I3Prop $_ 'LilyPadSha256' '')) -ieq $script:I3PairPluginSha }).Count -eq 1)
$wellFormed = (($pairs.Count -ge 1) -and (@($pairs | Where-Object { (DgU-IsHex64 ([string](Get-I3Prop $_ 'ExeSha256' ''))) -and (DgU-IsHex64 ([string](Get-I3Prop $_ 'LilyPadSha256' ''))) }).Count -eq $pairs.Count))
[void](Assert-I2A 'C-00a-known-pairs-contain-the-measured-contract-pair' ($r.Ok -and $hasContract) ("pairs=$($pairs.Count)" + (Get-I3Err $r)))
[void](Assert-I2A 'C-00b-every-known-entry-is-a-pair-of-two-hex64-values' ($r.Ok -and $wellFormed) ("pairs=$($pairs.Count): an exe SHA-256 and a LilyPad.dll SHA-256 per entry, never one side alone" + (Get-I3Err $r)))

$h = SceneDir 'c01'; $exe = New-I3Pcsx2Home $h
$r = Ident $exe
[void](Assert-I2A 'C-01-official-pair-is-Supported160' ((IsClass $r 'Supported160') -and ([string]$r.Value.Machine -ceq 'x86') -and ([string]$r.Value.ExeSha256 -ieq $script:I3PairExeSha) -and ([string]$r.Value.PluginSha256 -ieq $script:I3PairPluginSha)) (Dtl $r))
$h = SceneDir 'c01b'; $exe = New-I3Pcsx2Home $h -ExeName 'PCSX2.EXE'
$r = Ident $exe
[void](Assert-I2A 'C-01b-exe-name-is-case-insensitive' (IsClass $r 'Supported160') (Dtl $r))

# --- the exe SHA-256 is not in the list: Unverified, and nothing after the exe is opened (name -> PE -> exe SHA -> stop)
$h = SceneDir 'c02a'; $exe = New-I3Pcsx2Home $h -ExeSha $script:I3OtherExeSha
Start-I3Record; $r = Ident $exe; $recs = Stop-I3Record
[void](Assert-I2A 'C-02a-exe-sha-not-listed-is-Unverified' (IsClass $r 'Unverified') (Dtl $r))
[void](Assert-I2A 'C-02a2-nothing-below-Plugins-is-opened-after-an-exe-mismatch' ($r.Ok -and ((Cnt (Select-I3Rec $recs @((Join-Path $h 'Plugins')))) -eq 0)) ("records below Plugins: $(Cnt (Select-I3Rec $recs @((Join-Path $h 'Plugins'))))" + (Get-I3Err $r)))
$h = SceneDir 'c02b'; $exe = New-I3Pcsx2Home $h -PluginSha $script:I3OtherPluginSha
$r = Ident $exe
[void](Assert-I2A 'C-02b-lilypad-dll-sha-not-listed-is-Unverified' (IsClass $r 'Unverified') (Dtl $r))
$h = SceneDir 'c02c'; $exe = New-I3Pcsx2Home $h -Plugin $false
$r = Ident $exe
[void](Assert-I2A 'C-02c-lilypad-dll-missing-is-Unverified' (IsClass $r 'Unverified') (Dtl $r))
$h = SceneDir 'c02d'; $exe = New-I3Pcsx2Home $h -Plugin $false; [System.IO.Directory]::CreateDirectory((Join-Path $h 'Plugins')) | Out-Null
$r = Ident $exe
[void](Assert-I2A 'C-02d-empty-Plugins-folder-is-Unverified' (IsClass $r 'Unverified') (Dtl $r))
$h = SceneDir 'c02e'; $exe = New-I3Pcsx2Home $h -ExeSha ('e3' + $script:I3PairExeSha.Substring(2).ToLowerInvariant()) -PluginSha $script:I3PairPluginSha.ToLowerInvariant()
$r = Ident $exe
[void](Assert-I2A 'C-02e-sha-comparison-ignores-letter-case' (IsClass $r 'Supported160') (Dtl $r))
$h = SceneDir 'c02f'; $exe = New-I3Pcsx2Home $h -ExeSha ''
$r = Ident $exe
[void](Assert-I2A 'C-02f-a-real-synthetic-exe-is-never-on-the-default-list-fail-closed' (IsClass $r 'Unverified') ('without the faked SHA-256 the fixture is outside the allow list: ' + (Dtl $r)))

# --- the PAIR: both sides must come from the SAME entry
$pairA = New-I3Pair $script:I3PairExeSha $script:I3PairPluginSha
$pairB = New-I3Pair $script:I3OtherExeSha $script:I3OtherPluginSha
Set-I3KnownPairs @($pairA, $pairB)
$h = SceneDir 'c02g'; $exe = New-I3Pcsx2Home $h -ExeSha $script:I3PairExeSha -PluginSha $script:I3OtherPluginSha
$r = Ident $exe
[void](Assert-I2A 'C-02g-exe-of-pair-A-with-dll-of-pair-B-is-Unverified' (IsClass $r 'Unverified') ('each side is in the list but not in the same pair: ' + (Dtl $r)))
$h = SceneDir 'c02h'; $exe = New-I3Pcsx2Home $h -ExeSha $script:I3OtherExeSha -PluginSha $script:I3PairPluginSha
$r = Ident $exe
[void](Assert-I2A 'C-02h-exe-of-pair-B-with-dll-of-pair-A-is-Unverified' (IsClass $r 'Unverified') (Dtl $r))
$h = SceneDir 'c02i'; $exe = New-I3Pcsx2Home $h -ExeSha $script:I3OtherExeSha -PluginSha $script:I3OtherPluginSha
$r = Ident $exe
[void](Assert-I2A 'C-02i-second-listed-pair-is-Supported160' (IsClass $r 'Supported160') (Dtl $r))
Set-I3KnownPairs @()
$h = SceneDir 'c02j'; $exe = New-I3Pcsx2Home $h
$r = Ident $exe
[void](Assert-I2A 'C-02j-empty-allow-list-fails-closed' (IsClass $r 'Unverified') (Dtl $r))
Set-I3KnownPairs @([pscustomobject]@{ ExeSha256 = $script:I3PairExeSha }, [pscustomobject]@{ LilyPadSha256 = $script:I3PairPluginSha })
$h = SceneDir 'c02k'; $exe = New-I3Pcsx2Home $h
$r = Ident $exe
[void](Assert-I2A 'C-02k-one-sided-entries-never-match' (IsClass $r 'Unverified') (Dtl $r))
Restore-I3KnownPairs

# --- x64 / arm64 / qt: unsupported (1.7 or later); the settings files are never involved
$h = SceneDir 'c03a'; $exe = New-I3Pcsx2Home $h -Machine 'x64'
Start-I3Record; $r = Ident $exe; $recs = Stop-I3Record
[void](Assert-I2A 'C-03a-x64-pcsx2-exe-is-Unsupported17Plus' ((IsClass $r 'Unsupported17Plus') -and ([string]$r.Value.Machine -ceq 'x64')) (Dtl $r))
[void](Assert-I2A 'C-03a2-x64-does-not-hash-the-exe-or-look-for-plugins' ($r.Ok -and ((Cnt (Select-I3RecLeaf $recs '^(Sha256)$')) -eq 0) -and (@($recs | Where-Object { $_ -like 'DgFs-Sha256|*' -or $_ -like '*Plugins*' }).Count -eq 0)) ("records: " + (@($recs) -join '; ')))
$h = SceneDir 'c03b'; $exe = New-I3Pcsx2Home $h -Machine 'arm64'
$r = Ident $exe
[void](Assert-I2A 'C-03b-arm64-pcsx2-exe-is-Unsupported17Plus' ((IsClass $r 'Unsupported17Plus') -and ([string]$r.Value.Machine -ceq 'arm64')) (Dtl $r))
$h = SceneDir 'c03c'; $exe = New-I3Pcsx2Home $h -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
Start-I3Record; $r = Ident $exe; $recs = Stop-I3Record
[void](Assert-I2A 'C-03c-pcsx2-qt-exe-is-Unsupported17Plus' (IsClass $r 'Unsupported17Plus') (Dtl $r))
[void](Assert-I2A 'C-03c2-pcsx2-qt-is-decided-by-its-name-no-file-primitive-is-called' ($r.Ok -and ($recs.Count -eq 0)) ("records: " + (@($recs) -join '; ')))
$h = SceneDir 'c03d'; $exe = New-I3Pcsx2Home $h -ExeName 'pcsx2-qt.exe' -Machine 'x86'
$r = Ident $exe
[void](Assert-I2A 'C-03d-pcsx2-qt-with-an-x86-header-is-still-Unsupported17Plus' (IsClass $r 'Unsupported17Plus') (Dtl $r))
$h = SceneDir 'c03e'; $exe = New-I3Pcsx2Home $h -ExeName 'pcsx2x64-avx2.exe' -Machine 'x64'
$r = Ident $exe
[void](Assert-I2A 'C-03e-renamed-x64-exe-is-Unsupported17Plus' (IsClass $r 'Unsupported17Plus') (Dtl $r))

# --- other machines, broken PE, fallback names: Unverified, never an exception
$h = SceneDir 'c04'; $exe = New-I3Pcsx2Home $h -Machine 'arm32'
$r = Ident $exe
[void](Assert-I2A 'C-04-other-machine-type-is-Unverified' (IsClass $r 'Unverified') (Dtl $r))
foreach ($kind in 'NotPE', 'InvalidPE', 'Empty') {
    $h = SceneDir ('c05-' + $kind); $exe = New-I3Pcsx2Home $h -Machine $kind
    $r = Ident $exe
    [void](Assert-I2A ('C-05-broken-pe-' + $kind + '-is-Unverified') (IsClass $r 'Unverified') (Dtl $r))
}
$r = Ident (Join-Path (SceneDir 'c05-missing') 'pcsx2.exe')
[void](Assert-I2A 'C-05-missing-exe-is-Unverified-not-an-exception' (IsClass $r 'Unverified') (Dtl $r))
$h = SceneDir 'c06a'; $exe = New-I3Pcsx2Home $h -ExeName 'pcsx2-r5875.exe'
$r = Ident $exe
[void](Assert-I2A 'C-06a-fallback-name-with-the-measured-hashes-is-Unverified' (IsClass $r 'Unverified') ('the name must be pcsx2.exe: ' + (Dtl $r)))

# --- determinism and independence from everything that is not the exe pair
$h = SceneDir 'c07'; $exe = New-I3Pcsx2Home $h
$r1 = Ident $exe; $r2 = Ident $exe
[void](Assert-I2A 'C-07a-same-exe-same-result' ($r1.Ok -and $r2.Ok -and ((ConvertTo-I3Json $r1.Value) -ceq (ConvertTo-I3Json $r2.Value))) 'the classification of one exe is deterministic')
function global:Get-CimInstance { param([string]$ClassName) return @([pscustomobject]@{ Name = 'pcsx2.exe'; ExecutablePath = 'x'; CommandLine = 'x' }, [pscustomobject]@{ Name = 'pcsx2-qt.exe'; ExecutablePath = 'y'; CommandLine = 'y' }) }
function global:Get-Process { param([string]$Name) return @([pscustomobject]@{ Name = 'pcsx2'; Id = 1 }) }
$r3 = Ident $exe
Remove-Item 'function:global:Get-CimInstance'; Remove-Item 'function:global:Get-Process'
[void](Assert-I2A 'C-07b-running-processes-never-decide-the-version' ($r3.Ok -and (IsClass $r3 'Supported160')) ('a running pcsx2 / pcsx2-qt process must not change the classification: ' + (Dtl $r3)))
$pa = Get-I2AScriptAst (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
$idFns = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -in @('Get-DenGoPcsx2Identity', 'Group-DenGoPcsx2Candidates', 'Resolve-DenGoPcsx2Root', 'Test-DenGoPcsx2RootProof', 'New-DenGoPcsx2PlanItems') }, $true))
$procCmds = 0
foreach ($f in $idFns) { $procCmds += @($f.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -in @('Get-CimInstance', 'Get-WmiObject', 'Get-Process', 'tasklist') }, $true)).Count }
[void](Assert-I2A 'C-07c-detection-functions-never-read-the-process-list' (($idFns.Count -eq 5) -and ($procCmds -eq 0)) ("detection functions found: $($idFns.Count) of 5; process-list commands inside them: $procCmds"))

# ================================================================ R  settings root
Set-I3DocumentsRoot (Join-Path $S 'Documents')
$docsPcsx2 = Join-Path $S 'Documents\PCSX2'
function Root([string]$Exe, [string]$Arguments = '') { return (Invoke-I3 { Resolve-DenGoPcsx2Root -ExePath $Exe -Arguments $Arguments }) }
$h = SceneDir 'r01'; $exe = New-I3Pcsx2Home $h -PortableIni $true
$r = Root $exe
[void](Assert-I2A 'R-01-portable-ini-selects-the-exe-folder' ($r.Ok -and ($r.Value.Portable -eq $true) -and (PathEq2 ([string]$r.Value.Root) $h) -and ([string]$r.Value.Mode -ceq 'Portable')) ("portable=$(Get-I3Prop $r.Value 'Portable' '?') root=$(Get-I3Prop $r.Value 'Root' '?')" + (Get-I3Err $r)))
$h = SceneDir 'r02'; $exe = New-I3Pcsx2Home $h
foreach ($case in @(@('-portable', $true), @('"C:\iso\game.iso" -portable', $true), @('-PORTABLE', $true), @('-nogui -portable -fullboot', $true), @('-portablex', $false), @('portable', $false), @('--portable', $false), @('', $false))) {
    $r = Root $exe $case[0]
    $want = [bool]$case[1]
    [void](Assert-I2A ('R-02-arguments-[' + $case[0] + ']-portable=' + $want) ($r.Ok -and ([bool]$r.Value.Portable -eq $want) -and ((PathEq2 ([string]$r.Value.Root) $h) -eq $want)) ("portable=$(Get-I3Prop $r.Value 'Portable' '?') root=$(Get-I3Prop $r.Value 'Root' '?')" + (Get-I3Err $r)))
}
$h = SceneDir 'r03'; $exe = New-I3Pcsx2Home $h -PortableTxt $true
Start-I3Record; $r = Root $exe; $recs = Stop-I3Record
[void](Assert-I2A 'R-03-portable-txt-alone-does-not-make-it-portable' ($r.Ok -and ($r.Value.Portable -eq $false) -and (PathEq2 ([string]$r.Value.Root) $docsPcsx2) -and ([string]$r.Value.Mode -ceq 'CentralConfiguration')) ("portable=$(Get-I3Prop $r.Value 'Portable' '?') root=$(Get-I3Prop $r.Value 'Root' '?')" + (Get-I3Err $r)))
[void](Assert-I2A 'R-03b-portable-txt-is-not-even-looked-at' ($r.Ok -and ((Cnt (Select-I3RecLeaf $recs '^portable\.txt$')) -eq 0)) ('records for portable.txt: ' + (Cnt (Select-I3RecLeaf $recs '^portable\.txt$'))))
$h = SceneDir 'r04'; $exe = New-I3Pcsx2Home $h
$r = Root $exe
[void](Assert-I2A 'R-04-no-marker-selects-Documents-PCSX2' ($r.Ok -and ($r.Value.Portable -eq $false) -and (PathEq2 ([string]$r.Value.Root) $docsPcsx2)) ("root=$(Get-I3Prop $r.Value 'Root' '?')" + (Get-I3Err $r)))
Set-I3DocumentsRoot (Join-Path $S 'OneDrive - Contoso\Documents')
$r = Root $exe
[void](Assert-I2A 'R-04b-redirected-Documents-is-followed-through-the-seam' ($r.Ok -and (PathEq2 ([string]$r.Value.Root) (Join-Path $S 'OneDrive - Contoso\Documents\PCSX2'))) ("root=$(Get-I3Prop $r.Value 'Root' '?')" + (Get-I3Err $r)))
Set-I3DocumentsRoot (Join-Path $S 'Documents')

# --- the proof of a settings root: inis, PCSX2_ui.ini, LilyPad.ini; nothing is ever created
function Proof([string]$RootPath) { return (Invoke-I3 { Test-DenGoPcsx2RootProof -Root $RootPath }) }
$root = Join-Path $S 'proof-ok'; $inis = New-I3Config $root
$r = Proof $root
[void](Assert-I2A 'R-05-complete-root-is-proven' ($r.Ok -and ($r.Value.Ok -eq $true) -and (PathEq2 ([string]$r.Value.InisDir) $inis) -and (PathEq2 ([string]$r.Value.LilyPadIni) (Join-Path $inis 'LilyPad.ini'))) ("ok=$(Get-I3Prop $r.Value 'Ok' '?') reason=$(Get-I3Prop $r.Value 'Reason' '?')" + (Get-I3Err $r)))
foreach ($case in @(
        @('inis-missing', 'InisMissing', { param($p) New-I3Config $p -HasInis $false }),
        @('ui-ini-missing', 'UiIniMissing', { param($p) New-I3Config $p -Ui $false }),
        @('lilypad-ini-missing', 'LilyPadIniMissing', { param($p) New-I3Config $p -LilyPadIni $false }))) {
    $root = Join-Path $S ('proof-' + $case[0]); [void](& $case[2] $root)
    $before = Get-I2ATreeMap $S @()
    $r = Proof $root
    $after = Get-I2ATreeMap $S @()
    [void](Assert-I2A ('R-06-' + $case[0] + '-is-refused-with-' + $case[1]) ($r.Ok -and ($r.Value.Ok -eq $false) -and ([string]$r.Value.Reason -ceq $case[1])) ("reason=$(Get-I3Prop $r.Value 'Reason' '?')" + (Get-I3Err $r)))
    [void](Assert-I2A ('R-06b-' + $case[0] + '-proof-creates-nothing') ($r.Ok -and (Same $before $after)) ('the proof only reads: ' + (Diff3 $before $after)))
}
$root = Join-Path $S 'proof-junction'; [void](New-I3Config $root -HasInis $false)
$real = Join-Path $S 'proof-junction-target\inis'; [void](New-I3Config (Join-Path $S 'proof-junction-target'))
New-I3Junction (Join-Path $root 'inis') $real
$r = Proof $root
[void](Assert-I2A 'R-07-inis-that-is-a-junction-is-refused' ($r.Ok -and ($r.Value.Ok -eq $false) -and ([string]$r.Value.Reason -ceq 'InisReparse')) ("reason=$(Get-I3Prop $r.Value 'Reason' '?')" + (Get-I3Err $r)))
Remove-I3Junction (Join-Path $root 'inis')

# ================================================================ A  grouping of candidates
function Scene([string]$Name) {
    $d = SceneDir $Name
    Set-I3DocumentsRoot (Join-Path $d 'Documents')
    return $d
}
function Grp($Candidates) { return (Invoke-I3 { Group-DenGoPcsx2Candidates -Candidates $Candidates }) }
function EntryOf($R, [string]$Exe) { foreach ($e in @($R.Value.Detected)) { if (PathEq2 ([string]$e.Executable) $Exe) { return $e } } return $null }
function Roots($R) { return ,@(@($R.Value.Roots) | ForEach-Object { ([string]$_).TrimEnd('\').ToUpperInvariant() } | Sort-Object) }

$d = Scene 'a01'; $exe = New-I3Pcsx2Home (Join-Path $d 'App'); [void](New-I3Config (Join-Path $d 'Documents\PCSX2'))
$r = Grp @((New-I3Candidate $exe))
$e = $(if ($r.Ok) { EntryOf $r $exe } else { $null })
[void](Assert-I2A 'A-01-single-central-1.6.0-is-Resolved' ($r.Ok -and ([string]$r.Value.Status -ceq 'Resolved') -and (PathEq2 ([string]$r.Value.SelectedRoot) (Join-Path $d 'Documents\PCSX2')) -and ((Roots $r).Count -eq 1)) ("status=$(Get-I3Prop $r.Value 'Status' '?') selected=$(Get-I3Prop $r.Value 'SelectedRoot' '?')" + (Get-I3Err $r)))
[void](Assert-I2A 'A-01b-entry-shape-Supported-Detected-legacy-mode-and-paths' (($null -ne $e) -and ([string]$e.SupportStatus -ceq 'Supported') -and ([string]$e.State -ceq 'Detected') -and ([string]$e.Mode -cmatch '^(Portable|CentralConfiguration)-LegacyLilyPad$') -and (PathEq2 ([string]$e.ProfileDirectory) (Join-Path $d 'Documents\PCSX2\inis')) -and (PathEq2 ([string]$e.EffectiveInputProfile) (Join-Path $d 'Documents\PCSX2\inis\LilyPad.ini')) -and ([string]$e.Platform -ceq 'PCSX2')) ("entry=" + $(if ($null -ne $e) { ConvertTo-I3Json $e } else { '<none>' }) + (Get-I3Err $r)))

$d = Scene 'a02'; $exe = New-I3Pcsx2Home (Join-Path $d 'App'); [void](New-I3Config (Join-Path $d 'Documents\PCSX2'))
$r = Grp @((New-I3Candidate $exe '' 'DefaultLocation'), (New-I3Candidate $exe.ToUpperInvariant() '' 'RunningProcess'), (New-I3Candidate ($exe.Replace('\', '/')) '-nogui' 'CommonRoot'))
[void](Assert-I2A 'A-02-the-same-exe-found-three-ways-is-one-entry' ($r.Ok -and (@($r.Value.Detected).Count -eq 1) -and ([string]$r.Value.Status -ceq 'Resolved')) ("entries=$(@(Get-I3Prop $r.Value 'Detected' @()).Count)" + (Get-I3Err $r)))

$d = Scene 'a03'; $docs = Join-Path $d 'Documents\PCSX2'
$e1 = New-I3Pcsx2Home (Join-Path $d 'App1'); $e2 = New-I3Pcsx2Home (Join-Path $d 'App2'); $e3 = New-I3Pcsx2Home $docs -PortableIni $true; [void](New-I3Config $docs)
$r = Grp @((New-I3Candidate $e1), (New-I3Candidate $e2), (New-I3Candidate $e3.ToLowerInvariant()))
[void](Assert-I2A 'A-03-exes-sharing-one-settings-root-are-one-candidate' ($r.Ok -and ([string]$r.Value.Status -ceq 'Resolved') -and ((Roots $r).Count -eq 1) -and (PathEq2 ([string]$r.Value.SelectedRoot) $docs)) ("status=$(Get-I3Prop $r.Value 'Status' '?') roots=$(if ($r.Ok) { (Roots $r) -join ',' } else { '?' })" + (Get-I3Err $r)))
[void](Assert-I2A 'A-03b-every-exe-is-still-reported-as-Supported' ($r.Ok -and (@($r.Value.Detected).Count -eq 3) -and (@($r.Value.Detected | Where-Object { [string]$_.SupportStatus -ceq 'Supported' }).Count -eq 3)) ("entries: " + $(if ($r.Ok) { (@($r.Value.Detected | ForEach-Object { [string]$_.SupportStatus }) -join ',') } else { '?' })))

$d = Scene 'a04'
$ea = New-I3Pcsx2Home (Join-Path $d 'A') -PortableIni $true; [void](New-I3Config (Join-Path $d 'A'))
$eb = New-I3Pcsx2Home (Join-Path $d 'B') -PortableIni $true; [void](New-I3Config (Join-Path $d 'B'))
$r = Grp @((New-I3Candidate $ea), (New-I3Candidate $eb))
[void](Assert-I2A 'A-04-two-proven-roots-are-Ambiguous' ($r.Ok -and ([string]$r.Value.Status -ceq 'Ambiguous') -and ((Roots $r).Count -eq 2) -and ([string](Get-I3Prop $r.Value 'SelectedRoot' 'x') -ceq '')) ("status=$(Get-I3Prop $r.Value 'Status' '?') selected=[$(Get-I3Prop $r.Value 'SelectedRoot' '?')]" + (Get-I3Err $r)))
[void](Assert-I2A 'A-04b-every-candidate-of-an-ambiguous-set-says-Ambiguous' ($r.Ok -and (@($r.Value.Detected | Where-Object { [string]$_.SupportStatus -ceq 'Ambiguous' }).Count -eq 2)) ("status values: " + $(if ($r.Ok) { (@($r.Value.Detected | ForEach-Object { [string]$_.SupportStatus }) -join ',') } else { '?' })))
$plan = Invoke-I3 { New-DenGoPcsx2PlanItems -Resolution $r.Value -LilySource (Join-Path $S 'x.lily') -ActiveSource (Join-Path $S 'x.ini') -ReplaceConsent $true -Previous $null -Layout $null -LastClosedTransactionId '' }
[void](Assert-I2A 'A-04c-ambiguous-produces-no-plan-item-even-with-consent' ($r.Ok -and $plan.Ok -and (Cnt $plan.Value) -eq 0) ("items=$(Cnt $plan.Value)" + (Get-I3Err $plan)))
$r2 = Grp @((New-I3Candidate $eb '' 'DefaultLocation'), (New-I3Candidate $ea '' 'RunningProcess'))
[void](Assert-I2A 'A-04d-order-and-source-never-pick-a-root' ($r2.Ok -and ([string]$r2.Value.Status -ceq 'Ambiguous') -and ([string](Get-I3Prop $r2.Value 'SelectedRoot' 'x') -ceq '') -and ($r.Ok -and ((Roots $r) -join ',') -ceq ((Roots $r2) -join ','))) ("status=$(Get-I3Prop $r2.Value 'Status' '?') selected=[$(Get-I3Prop $r2.Value 'SelectedRoot' '?')]" + (Get-I3Err $r2)))

$d = Scene 'a05'; $docs = Join-Path $d 'Documents\PCSX2'
$exe = New-I3Pcsx2Home (Join-Path $d 'App'); [void](New-I3Config $docs -Pcsx2Ini $true)
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
$r = Grp @((New-I3Candidate $qt), (New-I3Candidate $exe))
$eq = $(if ($r.Ok) { EntryOf $r $qt } else { $null }); $e160 = $(if ($r.Ok) { EntryOf $r $exe } else { $null })
[void](Assert-I2A 'A-05-1.6.0-next-to-a-qt-build-is-Resolved' ($r.Ok -and ([string]$r.Value.Status -ceq 'Resolved') -and (PathEq2 ([string]$r.Value.SelectedRoot) $docs) -and ($null -ne $e160) -and ([string]$e160.SupportStatus -ceq 'Supported')) ("status=$(Get-I3Prop $r.Value 'Status' '?')" + (Get-I3Err $r)))
[void](Assert-I2A 'A-05b-the-qt-build-is-reported-as-detected-but-unsupported-without-a-root' (($null -ne $eq) -and ([string]$eq.SupportStatus -ceq 'UnsupportedCurrent') -and ([string]$eq.State -ceq 'Detected') -and ([string]$eq.ConfigRoot -ceq '') -and ([string]$eq.EffectiveInputProfile -ceq '')) ("entry=" + $(if ($null -ne $eq) { ConvertTo-I3Json $eq } else { '<none>' })))

$d = Scene 'a06'; [void](New-I3Config (Join-Path $d 'Documents\PCSX2') -Pcsx2Ini $true)
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
$r = Grp @((New-I3Candidate $qt))
[void](Assert-I2A 'A-06-qt-alone-resolves-nothing' ($r.Ok -and ([string]$r.Value.Status -ceq 'None') -and (@($r.Value.Detected).Count -eq 1) -and ([string]$r.Value.Detected[0].SupportStatus -ceq 'UnsupportedCurrent')) ("status=$(Get-I3Prop $r.Value 'Status' '?')" + (Get-I3Err $r)))
$d = Scene 'a07'; [void](New-I3Config (Join-Path $d 'Documents\PCSX2'))
$unv = New-I3Pcsx2Home (Join-Path $d 'Unk') -ExeSha $script:I3OtherExeSha
$r = Grp @((New-I3Candidate $unv))
[void](Assert-I2A 'A-07-unverified-alone-resolves-nothing-and-says-so' ($r.Ok -and ([string]$r.Value.Status -ceq 'None') -and ([string]$r.Value.Detected[0].SupportStatus -ceq 'UnsupportedUnverified') -and ([string]$r.Value.Detected[0].State -ceq 'Detected') -and ([string]$r.Value.Detected[0].Mode -ceq '')) ("entry=" + $(if ($r.Ok) { ConvertTo-I3Json $r.Value.Detected[0] } else { '?' }) + (Get-I3Err $r)))
$d = Scene 'a08'
$ea = New-I3Pcsx2Home (Join-Path $d 'A') -PortableIni $true; [void](New-I3Config (Join-Path $d 'A') -LilyPadIni $false)
$eb = New-I3Pcsx2Home (Join-Path $d 'B') -PortableIni $true; [void](New-I3Config (Join-Path $d 'B'))
$r = Grp @((New-I3Candidate $ea), (New-I3Candidate $eb))
$xa = $(if ($r.Ok) { EntryOf $r $ea } else { $null })
[void](Assert-I2A 'A-08-an-unproven-root-is-not-a-candidate-so-the-proven-one-is-not-ambiguous' ($r.Ok -and ([string]$r.Value.Status -ceq 'Resolved') -and (PathEq2 ([string]$r.Value.SelectedRoot) (Join-Path $d 'B')) -and ($null -ne $xa) -and ([string]$xa.State -ceq 'DetectedButNotInitialized') -and ([string]$xa.SupportStatus -cne 'Supported') -and ([string]$xa.SupportStatus -cne 'Ambiguous')) ("status=$(Get-I3Prop $r.Value 'Status' '?') unprovenState=$(Get-I3Prop $xa 'State' '?')" + (Get-I3Err $r)))
$d = Scene 'a09'
$r = Grp @()
[void](Assert-I2A 'A-09-no-candidate-is-None' ($r.Ok -and ([string]$r.Value.Status -ceq 'None') -and (@($r.Value.Detected).Count -eq 0)) ("status=$(Get-I3Prop $r.Value 'Status' '?')" + (Get-I3Err $r)))
$d = Scene 'a10'; $docs = Join-Path $d 'Documents\PCSX2'
$exe = New-I3Pcsx2Home (Join-Path $d 'App'); [void](New-I3Config $docs)
$ea = New-I3Pcsx2Home (Join-Path $d 'A') -PortableIni $true; [void](New-I3Config (Join-Path $d 'A'))
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
$r = Grp @((New-I3Candidate $exe), (New-I3Candidate $ea), (New-I3Candidate $qt))
[void](Assert-I2A 'A-10-central-plus-portable-plus-qt-is-Ambiguous-and-qt-stays-unsupported' ($r.Ok -and ([string]$r.Value.Status -ceq 'Ambiguous') -and (@($r.Value.Detected | Where-Object { [string]$_.SupportStatus -ceq 'UnsupportedCurrent' }).Count -eq 1)) ("status=$(Get-I3Prop $r.Value 'Status' '?')" + (Get-I3Err $r)))
$d = Scene 'a11'; $docs = Join-Path $d 'Documents\PCSX2'
$exe = New-I3Pcsx2Home (Join-Path $d 'App'); [void](New-I3Config $docs)
$r1 = Grp @((New-I3Candidate $exe '' 'DefaultLocation'))
$r2 = Grp @((New-I3Candidate $exe '' 'RunningProcess'))
[void](Assert-I2A 'A-11-the-source-of-a-candidate-never-changes-the-classification' ($r1.Ok -and $r2.Ok -and ([string]$r1.Value.Detected[0].SupportStatus -ceq [string]$r2.Value.Detected[0].SupportStatus) -and ([string]$r1.Value.Status -ceq [string]$r2.Value.Status)) 'DefaultLocation and RunningProcess give the same result')

# ================================================================ P  plan decisions and consent
$P = SceneDir 'plan'
Set-I3DocumentsRoot (Join-Path $P 'Documents')
$home1 = Join-Path $P 'Home'; $exeP = New-I3Pcsx2Home $home1 -PortableIni $true
$inisP = New-I3Config $home1
$lilyPadP = Join-Path $inisP 'LilyPad.ini'; $lilyP = Join-Path $inisP 'DenGo-Controller-Converter.lily'
$srcActive = Join-Path $P 'active.src'; $srcLily = Join-Path $P 'lily.src'
Write-I3Text $srcActive 'DENGO-ACTIVE-LILYPAD-V1'; Write-I3Text $srcLily 'DENGO-LILY-PROFILE-V1'
$resP = Grp @((New-I3Candidate $exeP))
$layoutP = New-I3Layout $P
function Plan($Consent, $Prev = $null, [string]$LastClosed = '', $Resolution = $null) {
    if ($null -eq $Resolution) { $Resolution = $resP.Value }
    return (Invoke-I3 { New-DenGoPcsx2PlanItems -Resolution $Resolution -LilySource $srcLily -ActiveSource $srcActive -ReplaceConsent $Consent -Previous $Prev -Layout $layoutP -LastClosedTransactionId $LastClosed })
}
function ItemOf($R, [string]$Component) { foreach ($i in @($R.Value)) { if ([string]$i.Component -ceq $Component) { return $i } } return $null }
function ActOf($R, [string]$Component) { $i = ItemOf $R $Component; if ($null -eq $i) { return '<none>' } return [string]$i.Action }

Write-I3Text $lilyPadP 'DENGO-ACTIVE-LILYPAD-V1'
$r = Plan $false
[void](Assert-I2A 'P-01-current-equal-to-Active-is-Unchanged-and-writes-nothing' ($resP.Ok -and $r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'Unchanged')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
[void](Assert-I2A 'P-01b-absent-lily-profile-is-Add-and-component-order-is-profile-first' ($r.Ok -and ((ActOf $r 'InputProfile') -ceq 'Add') -and ([string]@($r.Value)[0].Component -ceq 'InputProfile') -and ([string]@($r.Value)[1].Component -ceq 'EffectiveInputProfile') -and ([string]@($r.Value)[0].Platform -ceq 'PCSX2')) ("actions: " + $(if ($r.Ok) { (@($r.Value | ForEach-Object { $_.Component + '=' + $_.Action }) -join ',') } else { '?' }) + (Get-I3Err $r)))
[void](Assert-I2A 'P-01c-items-carry-the-measured-sources-and-destinations' ($r.Ok -and ([string](ItemOf $r 'EffectiveInputProfile').SourceSHA256 -ceq (Get-I3Sha $srcActive)) -and ([string](ItemOf $r 'EffectiveInputProfile').DestinationSHA256 -ceq (Get-I3Sha $lilyPadP)) -and (PathEq2 ([string](ItemOf $r 'EffectiveInputProfile').Destination) $lilyPadP) -and (PathEq2 ([string](ItemOf $r 'InputProfile').Destination) $lilyP) -and ([string](ItemOf $r 'InputProfile').DestinationSHA256 -ceq '')) 'SHA-256 and destination paths are those of the files')

Write-I3Text $lilyPadP 'USER-EDITED-LILYPAD'
$r = Plan $false
[void](Assert-I2A 'P-02-different-first-time-without-consent-is-PreserveUserModified' ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveUserModified')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
$r = Plan $true
[void](Assert-I2A 'P-03-same-with-explicit-consent-is-UpdateOrRepair' ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'UpdateOrRepair')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
Write-I3Text $lilyP 'USER-OWN-LILY-PROFILE'
$r = Plan $false
[void](Assert-I2A 'P-03b-a-different-lily-profile-without-consent-is-PreserveUserModified' ($r.Ok -and ((ActOf $r 'InputProfile') -ceq 'PreserveUserModified')) ("lily=$(if ($r.Ok) { ActOf $r 'InputProfile' } else { '?' })" + (Get-I3Err $r)))
$r = Plan $true
[void](Assert-I2A 'P-03c-the-same-consent-applies-to-the-lily-profile' ($r.Ok -and ((ActOf $r 'InputProfile') -ceq 'UpdateOrRepair')) ("lily=$(if ($r.Ok) { ActOf $r 'InputProfile' } else { '?' })" + (Get-I3Err $r)))
Write-I3Text $lilyP 'DENGO-LILY-PROFILE-V1'
$r = Plan $true
[void](Assert-I2A 'P-03d-an-equal-lily-profile-is-Unchanged-even-with-consent' ($r.Ok -and ((ActOf $r 'InputProfile') -ceq 'Unchanged')) ("lily=$(if ($r.Ok) { ActOf $r 'InputProfile' } else { '?' })" + (Get-I3Err $r)))
[System.IO.File]::Delete($lilyP)

# --- an earlier record of the same generation
Write-I3Text $lilyPadP 'DENGO-OLD-VERSION'
$oldSha = Get-I3Sha $lilyPadP
$bk = New-I3OriginBackup $layoutP '20261001T000000Z-bbbbbbbb' 'USER-ORIGINAL-OF-GEN1'
$recOk = New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bk.Sha $bk.Path $true @($bk.Entry)
$r = Plan $false (New-I3Prev @($recOk))
[void](Assert-I2A 'P-04-a-DenGo-version-update-needs-no-consent-when-the-Origin-is-valid' ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'UpdateOrRepair')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
$recMig = New-I3Record 'EffectiveInputProfile' $lilyPadP 'MigratedMatchingDenGoFile' $oldSha '' '' $false @()
$r = Plan $false (New-I3Prev @($recMig))
[void](Assert-I2A 'P-04b-an-update-without-an-Origin-record-needs-no-consent-either' ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'UpdateOrRepair')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
Write-I3Text $lilyPadP 'USER-EDITED-AFTER-INSTALL'
$r = Plan $false (New-I3Prev @($recOk))
[void](Assert-I2A 'P-05-edited-after-install-without-consent-is-PreserveUserModified' ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveUserModified')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
$r = Plan $true (New-I3Prev @($recOk))
[void](Assert-I2A 'P-05b-edited-after-install-with-consent-is-UpdateOrRepair' ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'UpdateOrRepair')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))

# --- an earlier Origin that is no longer valid: nothing is written, even with consent (the damage is not fixed in place)
Write-I3Text $lilyPadP 'DENGO-OLD-VERSION'
$bkMiss = New-I3OriginBackup $layoutP '20261001T000000Z-dddddddd' 'ORIGIN-MISSING'
[System.IO.File]::Delete($bkMiss.Path)
$bkBad = New-I3OriginBackup $layoutP '20261001T000000Z-eeeeeeee' 'ORIGIN-ALTERED'
[System.IO.File]::WriteAllText($bkBad.Path, 'ALTERED', $script:Utf8)
$bkClosed = New-I3OriginBackup $layoutP '20261001T000000Z-ffffffff' 'ORIGIN-OF-CLOSED-GENERATION'
foreach ($case in @(
        @('backup-file-missing', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkMiss.Sha $bkMiss.Path $true @($bkMiss.Entry)), ''),
        @('backup-sha-mismatch', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkBad.Sha $bkBad.Path $true @($bkBad.Entry)), ''),
        @('backup-of-a-closed-generation', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkClosed.Sha $bkClosed.Path $true @($bkClosed.Entry)), '20261001T000000Z-ffffffff'),
        @('origin-fields-empty', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha '' '' $true @()), ''))) {
    foreach ($consent in $false, $true) {
        $r = Plan $consent (New-I3Prev @($case[1])) $case[2]
        [void](Assert-I2A ('P-06-' + $case[0] + '-consent-' + $consent + '-is-PreserveOriginInvalid') ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
    }
}

# --- I3-D (formal test of the I3-C behaviour): an invalid Origin beats consent also when the file was EDITED since the install (not only when it is still the DenGo version)
Write-I3Text $lilyPadP 'USER-EDITED-AFTER-INSTALL'
foreach ($case in @(
        @('backup-file-missing', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkMiss.Sha $bkMiss.Path $true @($bkMiss.Entry)), ''),
        @('backup-sha-mismatch', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkBad.Sha $bkBad.Path $true @($bkBad.Entry)), ''),
        @('backup-of-a-closed-generation', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkClosed.Sha $bkClosed.Path $true @($bkClosed.Entry)), '20261001T000000Z-ffffffff'),
        @('origin-fields-empty', (New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha '' '' $true @()), ''))) {
    foreach ($consent in $false, $true) {
        $r = Plan $consent (New-I3Prev @($case[1])) $case[2]
        [void](Assert-I2A ('P-06e-edited-file-' + $case[0] + '-consent-' + $consent + '-is-PreserveOriginInvalid-and-never-PreserveUserModified-or-UpdateOrRepair') ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid') -and ([string](ItemOf $r 'EffectiveInputProfile').Reason -ceq 'OriginInvalid')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
    }
}
# controls: with a VALID Origin the same edited file is PreserveUserModified without consent and UpdateOrRepair with consent (the invalid Origin is the only difference)
$bkValidE = New-I3OriginBackup $layoutP '20261001T000000Z-abababab' 'ORIGIN-VALID-FOR-EDITED'
$recValidE = New-I3Record 'EffectiveInputProfile' $lilyPadP 'ReplacedExisting' $oldSha $bkValidE.Sha $bkValidE.Path $true @($bkValidE.Entry)
$r = Plan $false (New-I3Prev @($recValidE)); $r2 = Plan $true (New-I3Prev @($recValidE))
[void](Assert-I2A 'P-06f-control-a-valid-Origin-with-an-edited-file-needs-consent' ($r.Ok -and $r2.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveUserModified') -and ((ActOf $r2 'EffectiveInputProfile') -ceq 'UpdateOrRepair')) ("no consent=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' }) consent=$(if ($r2.Ok) { ActOf $r2 'EffectiveInputProfile' } else { '?' })"))
# an invalid PreviousOrigin (the Origin a KEPT user file set aside) beats consent exactly like an invalid Origin of a ReplacedExisting record: nothing is written, with or without consent
function New-KeptWithPreviousOrigin($Bk) {
    $kept = New-I3Record 'EffectiveInputProfile' $lilyPadP 'PreservedUserFile' (Get-I3Sha $lilyPadP) '' '' $false @($Bk.Entry)
    Add-Member -InputObject $kept -NotePropertyName 'PreviousOrigin' -NotePropertyValue ([pscustomobject][ordered]@{ Ownership = 'ReplacedExisting'; ExistedBefore = $true; BeforeSHA256 = $Bk.Sha; Backup = $Bk.Path })
    return $kept
}
$keptCases = @(
    @('backup-file-missing', (New-KeptWithPreviousOrigin $bkMiss), ''),
    @('backup-sha-mismatch', (New-KeptWithPreviousOrigin $bkBad), ''),
    @('backup-of-a-closed-generation', (New-KeptWithPreviousOrigin $bkClosed), '20261001T000000Z-ffffffff'))
$emptyPo = New-I3Record 'EffectiveInputProfile' $lilyPadP 'PreservedUserFile' (Get-I3Sha $lilyPadP) '' '' $false @()
Add-Member -InputObject $emptyPo -NotePropertyName 'PreviousOrigin' -NotePropertyValue ([pscustomobject][ordered]@{ Ownership = 'ReplacedExisting'; ExistedBefore = $true; BeforeSHA256 = ''; Backup = '' })
$keptCases += , @('origin-fields-empty', $emptyPo, '')
foreach ($case in $keptCases) {
    foreach ($consent in $false, $true) {
        $r = Plan $consent (New-I3Prev @($case[1])) $case[2]
        [void](Assert-I2A ('P-06h-kept-file-with-an-invalid-PreviousOrigin-' + $case[0] + '-consent-' + $consent + '-is-PreserveOriginInvalid') ($r.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveOriginInvalid') -and ([string](ItemOf $r 'EffectiveInputProfile').Reason -ceq 'OriginInvalid')) ("LilyPad=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' })" + (Get-I3Err $r)))
    }
}
$bkKeptOk = New-I3OriginBackup $layoutP '20261001T000000Z-cdcdcdcd' 'ORIGIN-VALID-OF-A-KEPT-FILE'
$keptOk = New-KeptWithPreviousOrigin $bkKeptOk
$r = Plan $false (New-I3Prev @($keptOk)); $r2 = Plan $true (New-I3Prev @($keptOk))
[void](Assert-I2A 'P-06i-control-kept-file-with-a-VALID-PreviousOrigin-needs-consent-and-then-replaces' ($r.Ok -and $r2.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveUserModified') -and ((ActOf $r2 'EffectiveInputProfile') -ceq 'UpdateOrRepair') -and ([string](ItemOf $r2 'EffectiveInputProfile').Reason -ceq 'ConsentGiven')) ("no consent=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' }) consent=$(if ($r2.Ok) { ActOf $r2 'EffectiveInputProfile' } else { '?' })"))
# a user file that was kept earlier (PreservedUserFile) is a first sighting again: explicit consent replaces it, no consent keeps it
$recKept = New-I3Record 'EffectiveInputProfile' $lilyPadP 'PreservedUserFile' (Get-I3Sha $lilyPadP)
$r = Plan $false (New-I3Prev @($recKept)); $r2 = Plan $true (New-I3Prev @($recKept))
[void](Assert-I2A 'P-06g-a-file-kept-earlier-is-replaced-only-by-a-later-explicit-consent' ($r.Ok -and $r2.Ok -and ((ActOf $r 'EffectiveInputProfile') -ceq 'PreserveUserModified') -and ((ActOf $r2 'EffectiveInputProfile') -ceq 'UpdateOrRepair') -and ([string](ItemOf $r2 'EffectiveInputProfile').Reason -ceq 'ConsentGiven')) ("no consent=$(if ($r.Ok) { ActOf $r 'EffectiveInputProfile' } else { '?' }) consent=$(if ($r2.Ok) { ActOf $r2 'EffectiveInputProfile' } else { '?' })"))

# --- unresolved: never a plan item
$r = Plan $true $null '' ([pscustomobject]@{ Status = 'Ambiguous'; SelectedRoot = ''; Roots = @('a', 'b'); Detected = @() })
[void](Assert-I2A 'P-08a-Ambiguous-resolution-gives-no-items' ($r.Ok -and ((Cnt $r.Value) -eq 0)) ("items=$(Cnt $r.Value)" + (Get-I3Err $r)))
$r = Plan $true $null '' ([pscustomobject]@{ Status = 'None'; SelectedRoot = ''; Roots = @(); Detected = @() })
[void](Assert-I2A 'P-08b-None-resolution-gives-no-items' ($r.Ok -and ((Cnt $r.Value) -eq 0)) ("items=$(Cnt $r.Value)" + (Get-I3Err $r)))
# --- the plan only reads
Write-I3Text $lilyPadP 'USER-EDITED-LILYPAD'
Start-I3Record; $r = Plan $true (New-I3Prev @($recOk)); $recs = Stop-I3Record
$writes = @($recs | Where-Object { $_ -match '^DgFs-(CreateFileDurable|WriteTextFile|CopyFileDurable|Replace|MoveNew|Delete|CreateDir|RemoveDirIfEmpty)\|' })
[void](Assert-I2A 'P-10-planning-never-writes' ($r.Ok -and ($writes.Count -eq 0)) ("write primitives called while planning: $($writes.Count)" + (Get-I3Err $r)))

# ================================================================ M  ownership merge
$ML = New-I3Layout (SceneDir 'merge')
$mLilyPad = Join-Path $ML.LocalAppData 'x\pcsx2\inis\LilyPad.ini'
$mLily = Join-Path $ML.LocalAppData 'x\pcsx2\inis\DenGo-Controller-Converter.lily'
$mTxn = '20261002T000000Z-cccccccc'
function PI([string]$Component, [string]$Dest, [string]$Action) { return [pscustomobject]@{ Platform = 'PCSX2'; Component = $Component; Action = $Action; Source = 's'; SourceSHA256 = ('11' * 32); Destination = $Dest; DestinationSHA256 = '' } }
function Entries($Plan) { return (Invoke-I3 { Convert-DenGoPlanToEntries $ML $Plan }) }
function Merge($Prev, $Plan, [hashtable]$Tx = @{}, [hashtable]$Probe = @{}) {
    $en = Entries $Plan
    if (-not $en.Ok) { return $en }
    $pf = { param($p) $k = ([string]$p).ToUpperInvariant(); if ($Probe.ContainsKey($k)) { return [string]$Probe[$k] } return '' }.GetNewClosure()
    return (Invoke-I3 { Merge-DenGoInstalledState $Prev $en.Value $Tx $mTxn 'C:\bk\cccc' '2026-10-02T00:00:00.0000000Z' $null $pf })
}
function TxOf([string]$Dest, [string]$Backup, [string]$PreSha) { return @{ $Dest.ToUpperInvariant() = @{ Backup = $Backup; PreSha = $PreSha } } }
$origSha = ('0A' * 32); $afterSha = ('0B' * 32)
$bkPath = Join-Path $ML.BackupRoot '20261001T000000Z-bbbbbbbb\0001.bak'
$b0 = [pscustomobject][ordered]@{ TransactionId = '20261001T000000Z-bbbbbbbb'; Path = $bkPath; SHA256 = $origSha }

# M-01 first replacement: the Origin is the content right before the replacement
$m = Merge $null @((PI 'EffectiveInputProfile' $mLilyPad 'UpdateOrRepair')) (TxOf $mLilyPad 'C:\bk\cccc\0001.bak' $origSha) @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-01-first-consented-replacement-records-the-Origin' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ($rec.ExistedBefore -eq $true) -and ([string]$rec.BeforeSHA256 -ceq $origSha) -and ([string]$rec.Backup -ceq 'C:\bk\cccc\0001.bak') -and (@($rec.Backups).Count -eq 1) -and ([string]$rec.Backups[0].Path -ceq [string]$rec.Backup) -and ([string]$rec.Backups[0].SHA256 -ceq $origSha) -and ([string]$rec.AfterSHA256 -ceq $afterSha)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
$mu = Merge $null @((PI 'EffectiveInputProfile' $mLilyPad 'Unchanged')) @{} @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$recu = $(if ($mu.Ok) { Get-I3Rec1 $mu.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-01b-first-sighting-of-an-equal-file-has-no-Origin' (($null -ne $recu) -and ([string]$recu.Ownership -ceq 'MigratedMatchingDenGoFile') -and ($recu.ExistedBefore -eq $false) -and ([string]$recu.BeforeSHA256 -ceq '') -and ([string]$recu.Backup -ceq '')) ("rec=" + $(if ($null -ne $recu) { ConvertTo-I3Json $recu } else { '<none>' }) + (Get-I3Err $mu)))
$mp = Merge $null @((PI 'EffectiveInputProfile' $mLilyPad 'PreserveUserModified')) @{} @{ $mLilyPad.ToUpperInvariant() = ('0C' * 32) }
$recp = $(if ($mp.Ok) { Get-I3Rec1 $mp.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-01c-an-unconsented-different-file-is-recorded-as-PreservedUserFile-with-no-backup' (($null -ne $recp) -and ([string]$recp.Ownership -ceq 'PreservedUserFile') -and ([string]$recp.Backup -ceq '') -and (@($recp.Backups).Count -eq 0)) ("rec=" + $(if ($null -ne $recp) { ConvertTo-I3Json $recp } else { '<none>' }) + (Get-I3Err $mp)))

# M-02 / M-03 updates inside the generation: the Origin never moves, Backups[0] never changes, Backups[1..] only grow
$prev = New-I3Prev @((New-I3Record 'EffectiveInputProfile' $mLilyPad 'ReplacedExisting' $afterSha $origSha $bkPath $true @($b0)))
$b0Json = ConvertTo-I3Json $b0
$cur = $prev
$stable = $true; $detail = ''
for ($i = 1; $i -le 3; $i++) {
    $newAfter = ('{0:X2}' -f (0x20 + $i)) * 32
    $m = Merge $cur @((PI 'EffectiveInputProfile' $mLilyPad 'UpdateOrRepair')) (TxOf $mLilyPad ('C:\bk\u' + $i + '\0001.bak') $afterSha) @{ $mLilyPad.ToUpperInvariant() = $newAfter }
    $rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
    if ($null -eq $rec) { $stable = $false; $detail = 'no record' + (Get-I3Err $m); break }
    if (-not (([string]$rec.Ownership -ceq 'ReplacedExisting') -and ([string]$rec.Backup -ceq $bkPath) -and ([string]$rec.BeforeSHA256 -ceq $origSha) -and ($rec.ExistedBefore -eq $true) -and ((ConvertTo-I3Json $rec.Backups[0]) -ceq $b0Json) -and (@($rec.Backups).Count -eq ($i + 1)))) { $stable = $false; $detail = "round $i : " + (ConvertTo-I3Json $rec); break }
    $cur = New-I3Prev @($rec)
    $afterSha = $newAfter
}
[void](Assert-I2A 'M-02-three-updates-keep-the-Origin-and-Backups-0-and-append-update-backups' $stable $detail)
$afterSha = ('0B' * 32)

# M-04 an edited file: the Origin is moved to PreviousOrigin, Backups[] is kept verbatim
$b1 = [pscustomobject][ordered]@{ TransactionId = '20261001T000100Z-99999999'; Path = 'C:\bk\update1\0001.bak'; SHA256 = ('0D' * 32) }
$prevE = New-I3Prev @((New-I3Record 'EffectiveInputProfile' $mLilyPad 'ReplacedExisting' $afterSha $origSha $bkPath $true @($b0, $b1)))
$m = Merge $prevE @((PI 'EffectiveInputProfile' $mLilyPad 'PreserveUserModified')) @{} @{ $mLilyPad.ToUpperInvariant() = ('0E' * 32) }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
$po = Get-I3Prop $rec 'PreviousOrigin' $null
[void](Assert-I2A 'M-04-PreserveUserModified-moves-the-Origin-to-PreviousOrigin' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'PreservedUserFile') -and ($null -ne $po) -and ([string](Get-I3Prop $po 'Ownership' '') -ceq 'ReplacedExisting') -and ([string](Get-I3Prop $po 'BeforeSHA256' '') -ceq $origSha) -and ([string](Get-I3Prop $po 'Backup' '') -ceq $bkPath) -and ((Get-I3Prop $po 'ExistedBefore' $false) -eq $true)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
[void](Assert-I2A 'M-04b-Backups-are-kept-verbatim-and-the-Origin-is-never-rewritten' (($null -ne $rec) -and ((ConvertTo-I3Json @($rec.Backups)) -ceq (ConvertTo-I3Json @($b0, $b1))) -and ([string]$rec.AfterSHA256 -ceq ('0E' * 32))) ("backups=" + $(if ($null -ne $rec) { ConvertTo-I3Json @($rec.Backups) } else { '<none>' })))
$m = Merge $prevE @((PI 'EffectiveInputProfile' $mLilyPad 'PreserveOriginInvalid')) @{} @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-05-PreserveOriginInvalid-keeps-the-whole-earlier-record' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ([string]$rec.BeforeSHA256 -ceq $origSha) -and ([string]$rec.Backup -ceq $bkPath) -and ((ConvertTo-I3Json @($rec.Backups)) -ceq (ConvertTo-I3Json @($b0, $b1)))) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
$m = Merge $prevE @((PI 'EffectiveInputProfile' $mLilyPad 'NotInitialized')) @{} @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-06-NotInitialized-keeps-the-earlier-Origin-for-PCSX2' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ([string]$rec.BeforeSHA256 -ceq $origSha) -and ([string]$rec.Backup -ceq $bkPath)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))

# M-10..M-13 (I3-D, formal test of the I3-C behaviour): a user file that was kept earlier and is replaced by a LATER explicit consent becomes ReplacedExisting.
#   The Origin is the one that was set aside (PreviousOrigin) when it is valid; otherwise it is the backup of this very replacement. Backups[0] never moves and a later backup never becomes the Origin.
$poFields = [pscustomobject][ordered]@{ Ownership = 'ReplacedExisting'; ExistedBefore = $true; BeforeSHA256 = $origSha; Backup = $bkPath }
$recKeptWithPo = New-I3Record 'EffectiveInputProfile' $mLilyPad 'PreservedUserFile' ('0E' * 32) '' '' $false @($b0, $b1)
Add-Member -InputObject $recKeptWithPo -NotePropertyName 'PreviousOrigin' -NotePropertyValue $poFields
$m = Merge (New-I3Prev @($recKeptWithPo)) @((PI 'EffectiveInputProfile' $mLilyPad 'PreserveUserModified')) @{} @{ $mLilyPad.ToUpperInvariant() = ('0E' * 32) }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-10-a-second-PreserveUserModified-keeps-the-set-aside-Origin-and-never-replaces-it' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'PreservedUserFile') -and ((ConvertTo-I3Json (Get-I3Prop $rec 'PreviousOrigin' $null)) -ceq (ConvertTo-I3Json $poFields)) -and ((ConvertTo-I3Json @($rec.Backups)) -ceq (ConvertTo-I3Json @($b0, $b1)))) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
# M-10b: PreserveOriginInvalid / NotInitialized over a kept user file keep the set-aside Origin and Backups[] whole (nothing is dropped when nothing is written)
foreach ($act in 'PreserveOriginInvalid', 'NotInitialized') {
    $m = Merge (New-I3Prev @($recKeptWithPo)) @((PI 'EffectiveInputProfile' $mLilyPad $act)) @{} @{ $mLilyPad.ToUpperInvariant() = ('0E' * 32) }
    $rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
    [void](Assert-I2A ('M-10b-' + $act + '-keeps-the-set-aside-Origin-and-Backups-of-a-kept-file') (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'PreservedUserFile') -and ((ConvertTo-I3Json (Get-I3Prop $rec 'PreviousOrigin' $null)) -ceq (ConvertTo-I3Json $poFields)) -and ((ConvertTo-I3Json @($rec.Backups)) -ceq (ConvertTo-I3Json @($b0, $b1)))) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
}
$newBk = 'C:\bk\cccc\0001.bak'; $editSha = ('1E' * 32)
$m = Merge (New-I3Prev @($recKeptWithPo)) @((PI 'EffectiveInputProfile' $mLilyPad 'UpdateOrRepair')) (TxOf $mLilyPad $newBk $editSha) @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-11a-consent-after-keeping-makes-the-record-ReplacedExisting-with-the-set-aside-Origin' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ($rec.ExistedBefore -eq $true) -and ([string]$rec.BeforeSHA256 -ceq $origSha) -and ([string]$rec.Backup -ceq $bkPath) -and ([string]$rec.AfterSHA256 -ceq $afterSha)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
[void](Assert-I2A 'M-11b-Backups-0-does-not-move-and-the-new-backup-is-appended-as-Backups-2' (($null -ne $rec) -and (@($rec.Backups).Count -eq 3) -and ((ConvertTo-I3Json $rec.Backups[0]) -ceq (ConvertTo-I3Json $b0)) -and ((ConvertTo-I3Json $rec.Backups[1]) -ceq (ConvertTo-I3Json $b1)) -and ([string]$rec.Backups[2].Path -ceq $newBk) -and ([string]$rec.Backups[2].SHA256 -ceq $editSha)) ("backups=" + $(if ($null -ne $rec) { ConvertTo-I3Json @($rec.Backups) } else { '<none>' })))
[void](Assert-I2A 'M-11c-no-later-backup-becomes-the-Origin' (($null -ne $rec) -and (@($rec.Backups | Select-Object -Skip 1 | Where-Object { [string]$_.Path -ceq [string]$rec.Backup -or [string]$_.SHA256 -ceq [string]$rec.BeforeSHA256 }).Count -eq 0) -and ([string]$rec.Backup -ceq [string]$rec.Backups[0].Path) -and ([string]$rec.BeforeSHA256 -ceq [string]$rec.Backups[0].SHA256)) 'Backup and BeforeSHA256 equal Backups[0]; no Backups[1..] entry has the Origin path or SHA-256')
[void](Assert-I2A 'M-11d-the-set-aside-Origin-is-not-carried-into-the-replaced-record' (($null -ne $rec) -and ($null -eq (Get-I3Prop $rec 'PreviousOrigin' $null))) 'PreviousOrigin exists only on a record that is the user file')
$recKeptNoPo = New-I3Record 'EffectiveInputProfile' $mLilyPad 'PreservedUserFile' ('0E' * 32)
$m = Merge (New-I3Prev @($recKeptNoPo)) @((PI 'EffectiveInputProfile' $mLilyPad 'UpdateOrRepair')) (TxOf $mLilyPad $newBk $editSha) @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
[void](Assert-I2A 'M-12-consent-after-keeping-without-a-set-aside-Origin-takes-this-replacements-backup-as-the-Origin' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ($rec.ExistedBefore -eq $true) -and ([string]$rec.BeforeSHA256 -ceq $editSha) -and ([string]$rec.Backup -ceq $newBk) -and (@($rec.Backups).Count -eq 1) -and ([string]$rec.Backups[0].Path -ceq $newBk)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
# M-13 control: only PCSX2's LilyPad profile gets this rule; the same sequence for the .lily profile of another platform is not changed (existing behaviour)
$recKeptRpcs3 = New-I3Record 'InputProfile' $mLilyPad 'PreservedUserFile' ('0E' * 32); $recKeptRpcs3.Platform = 'RPCS3'
$rpcs3Entry = [pscustomobject]@{ Platform = 'RPCS3'; Component = 'InputProfile'; Action = 'UpdateOrRepair'; Source = 's'; SourceSHA256 = ('11' * 32); Destination = (Join-Path $ML.LocalAppData 'x\rpcs3\config\input_configs\global\Den-Go-Controller.yml'); DestinationSHA256 = '' }
$recKeptRpcs3.Destination = $rpcs3Entry.Destination
$m13 = Invoke-I3 { Merge-DenGoInstalledState (New-I3Prev @($recKeptRpcs3)) @([pscustomobject]@{ Kind = 'Plan'; Platform = 'RPCS3'; Component = 'InputProfile'; Action = 'UpdateOrRepair'; Destination = $rpcs3Entry.Destination; Source = 's'; ExpectedDestSha = ''; ExpectedSourceSha = ''; Role = 'Rpcs3'; Root = ''; Set = 'RPCS3'; Deferred = $false; IsTx = $true }) (TxOf $rpcs3Entry.Destination $newBk $editSha) $mTxn 'C:\bk\cccc' '2026-10-02T00:00:00.0000000Z' $null { param($p) return ('0B' * 32) } }
$rec13 = $(if ($m13.Ok) { Get-I3Rec1 $m13.Value 'Den-Go-Controller.yml' } else { $null })
[void](Assert-I2A 'M-13-control-the-rule-is-PCSX2-only-another-platform-keeps-its-existing-ownership-behaviour' (($null -ne $rec13) -and ([string]$rec13.Ownership -ceq 'PreservedUserFile')) ("rec=" + $(if ($null -ne $rec13) { ConvertTo-I3Json $rec13 } else { '<none>' }) + (Get-I3Err $m13)))

# M-07 promotion of the records that I2-B / I2-C carried (legacy, no Presence; or Presence = DeferredThisRun / NotDetectedThisRun): only in the current generation, additive only
$legacyRec = New-I3Record 'EffectiveInputProfile' $mLilyPad 'ReplacedExisting' $afterSha $origSha 'C:\old\legacy.bak' $true @() ''
$prevL = New-I3Prev @($legacyRec)
$m = Merge $prevL @((PI 'EffectiveInputProfile' $mLilyPad 'Unchanged')) @{} @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
$pr = Get-I3Prop $rec 'Promoted' $null
[void](Assert-I2A 'M-07a-a-legacy-record-in-the-plan-is-promoted' (($null -ne $rec) -and ([string]$rec.Presence -ceq 'InPlan') -and ($null -ne $pr) -and ([string](Get-I3Prop $pr 'FromFormat' '') -ceq 'Legacy') -and ([string](Get-I3Prop $pr 'AtTransactionId' '') -ceq $mTxn)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
[void](Assert-I2A 'M-07b-promotion-never-rewrites-the-Origin' (($null -ne $rec) -and ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ($rec.ExistedBefore -eq $true) -and ([string]$rec.BeforeSHA256 -ceq $origSha) -and ([string]$rec.Backup -ceq 'C:\old\legacy.bak') -and (@(Get-I3Prop $rec 'Backups' @()).Count -eq 0)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' })))
$i2bRec = New-I3Record 'EffectiveInputProfile' $mLilyPad 'ReplacedExisting' $afterSha $origSha $bkPath $true @($b0) 'DeferredThisRun' 'Present'
$m = Merge (New-I3Prev @($i2bRec)) @((PI 'EffectiveInputProfile' $mLilyPad 'Unchanged')) @{} @{ $mLilyPad.ToUpperInvariant() = $afterSha }
$rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
$pr = Get-I3Prop $rec 'Promoted' $null
[void](Assert-I2A 'M-07c-an-I2B-DeferredThisRun-record-is-promoted-and-says-so' (($null -ne $rec) -and ([string]$rec.Presence -ceq 'InPlan') -and ($null -ne $pr) -and ([string](Get-I3Prop $pr 'FromPresence' '') -ceq 'DeferredThisRun') -and ([string](Get-I3Prop $pr 'FromFormat' '') -ceq 'I2B') -and ((ConvertTo-I3Json @(Get-I3Prop $rec 'Backups' @())) -ceq (ConvertTo-I3Json @($b0)))) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
# blocked: the record stays in Files, with the reason, never closed (these are records outside this plan, so the plan does not touch them)
$other = PI 'Application' (Join-Path $ML.LocalAppData 'x\core\app.exe') 'Add'
$other.Platform = 'Core'
foreach ($case in @(
        @('not-a-fixed-leaf', 'DestinationNotFixedLeaf', (New-I3Record 'EffectiveInputProfile' (Join-Path $ML.LocalAppData 'x\pcsx2\inis\PCSX2.ini') 'ReplacedExisting' $afterSha $origSha $bkPath $true @($b0) '')),
        @('unknown-ownership', 'OwnershipUnknown', (New-I3Record 'EffectiveInputProfile' $mLilyPad 'SomethingElse' $afterSha '' '' $false @() '')),
        @('origin-not-recorded', 'OriginInvalid', (New-I3Record 'EffectiveInputProfile' $mLilyPad 'ReplacedExisting' $afterSha '' '' $false @() '')))) {
    $m = Merge (New-I3Prev @($case[2])) @($other) @{} @{}
    $rec = $(if ($m.Ok) { Get-I3Rec1 $m.Value ([System.IO.Path]::GetFileName([string]$case[2].Destination)) } else { $null })
    [void](Assert-I2A ('M-08-promotion-blocked-' + $case[0]) (($null -ne $rec) -and ([string](Get-I3Prop $rec 'PromotionBlocked' '') -ceq $case[1]) -and ($null -eq (Get-I3Prop $rec 'Promoted' $null)) -and (@($m.Value.ClosedRecords).Count -eq 0)) ("rec=" + $(if ($null -ne $rec) { ConvertTo-I3Json $rec } else { '<none>' }) + (Get-I3Err $m)))
}

# M-09 a PCSX2 record is never moved to ClosedRecords: every ownership x every observation x in the plan or not
$obsMap = @{ Missing = ''; Present = $afterSha; Diverged = ('0F' * 32) }
$allClear = $true
foreach ($own in 'CreatedByInstaller', 'MigratedMatchingDenGoFile', 'ReplacedExisting', 'PreservedUserFile', 'NotInstalled', 'NotManaged') {
    foreach ($obs in 'Missing', 'Present', 'Diverged') {
        foreach ($inPlan in $true, $false) {
            $rec0 = New-I3Record 'EffectiveInputProfile' $mLilyPad $own $afterSha $(if ($own -eq 'ReplacedExisting') { $origSha } else { '' }) $(if ($own -eq 'ReplacedExisting') { $bkPath } else { '' }) ($own -eq 'ReplacedExisting') @($(if ($own -eq 'ReplacedExisting') { $b0 } else { })) 'InPlan' $obs
            $plan = $(if ($inPlan) { @((PI 'EffectiveInputProfile' $mLilyPad 'Unchanged')) } else { @($other) })
            $m = Merge (New-I3Prev @($rec0)) $plan @{} @{ $mLilyPad.ToUpperInvariant() = [string]$obsMap[$obs] }
            $kept = $(if ($m.Ok) { Get-I3Rec1 $m.Value 'LilyPad.ini' } else { $null })
            $ok = ($m.Ok -and ($null -ne $kept) -and (@($m.Value.ClosedRecords | Where-Object { [string]$_.Record.Platform -ceq 'PCSX2' }).Count -eq 0))
            [void](Assert-I2A ('M-09-never-closed-' + $own + '-' + $obs + '-inplan-' + $inPlan) $ok ("kept=$($null -ne $kept) closed=$(if ($m.Ok) { @($m.Value.ClosedRecords).Count } else { '?' })" + (Get-I3Err $m)))
        }
    }
}
# control (existing rule, unchanged): another platform's non-owning record that is missing and outside the plan IS closed
$rp = [pscustomobject][ordered]@{ Platform = 'RPCS3'; Component = 'InputProfile'; Destination = (Join-Path $ML.LocalAppData 'x\rpcs3\Den-Go-Controller.yml'); InstallAction = 'PreserveUserModified'; Ownership = 'PreservedUserFile'; ExistedBefore = $false; BeforeSHA256 = ''; AfterSHA256 = ''; Backup = ''; Presence = 'InPlan'; Observed = 'Present'; LastSeenTransactionId = 'T'; Backups = @() }
$m = Merge (New-I3Prev @($rp)) @($other) @{} @{}
[void](Assert-I2A 'M-09b-control-a-missing-non-owning-RPCS3-record-outside-the-plan-is-still-closed' ($m.Ok -and (@($m.Value.ClosedRecords).Count -eq 1) -and ([string]$m.Value.ClosedRecords[0].Record.Platform -ceq 'RPCS3')) ("closed=$(if ($m.Ok) { @($m.Value.ClosedRecords).Count } else { '?' })" + (Get-I3Err $m)))

# ================================================================ G  the Pcsx2 role
$GL = New-I3Layout (SceneDir 'role')
$gInis = Join-Path (SceneDir 'role-pcsx2') 'inis'
[void](New-I3Config (Split-Path $gInis -Parent))
$gLilyPad = Join-Path $gInis 'LilyPad.ini'; $gLily = Join-Path $gInis 'DenGo-Controller-Converter.lily'
$mp = Invoke-I3 { DgP-MapPlatform 'PCSX2' $gLilyPad }
[void](Assert-I2A 'G-01-PCSX2-maps-to-the-real-Pcsx2-role-and-is-not-deferred' ($mp.Ok -and ([string]$mp.Value.Role -ceq 'Pcsx2') -and ([bool]$mp.Value.Deferred -eq $false) -and ([string]$mp.Value.Set -ceq 'PCSX2') -and (PathEq2 ([string]$mp.Value.Root) $gInis)) ("map=" + $(if ($mp.Ok) { ConvertTo-I3Json $mp.Value } else { '?' }) + (Get-I3Err $mp)))
$so = [string[]](DgP-SetOrder)
[void](Assert-I2A 'G-02-PCSX2-is-a-set-after-RPCS3-and-before-the-shortcut' (($so -ccontains 'PCSX2') -and ([array]::IndexOf($so, 'PCSX2') -gt [array]::IndexOf($so, 'RPCS3')) -and ([array]::IndexOf($so, 'PCSX2') -lt [array]::IndexOf($so, 'Shortcut'))) ('install order: ' + ($so -join ',')))
$uo = [string[]](DgU-SetOrder)
[void](Assert-I2A 'G-02b-uninstall-order-contains-PCSX2' ($uo -ccontains 'PCSX2') ('uninstall order: ' + ($uo -join ',')))
$rs = Invoke-I3 { Get-DenGoRoleSpec $GL 'Pcsx2' $gInis }
$dests = @($(if ($rs.Ok) { @($rs.Value.Dests | ForEach-Object { [System.IO.Path]::GetFileName([string]$_).ToLowerInvariant() } | Sort-Object) } else { @() }))
[void](Assert-I2A 'G-03-role-spec-allows-exactly-the-two-fixed-leaves' ($rs.Ok -and ($rs.Value.Ok -eq $true) -and (PathEq2 ([string]$rs.Value.PolicyRoot) $gInis) -and ($dests.Count -eq 2) -and ($dests[0] -ceq 'dengo-controller-converter.lily') -and ($dests[1] -ceq 'lilypad.ini') -and (@($rs.Value.Dirs).Count -eq 0)) ("dests=$($dests -join ',') policyRoot=$(Get-I3Prop $rs.Value 'PolicyRoot' '?')" + (Get-I3Err $rs)))
$wrongName = Join-Path (Split-Path $gInis -Parent) 'config'; [System.IO.Directory]::CreateDirectory($wrongName) | Out-Null
$junctionRoot = Join-Path (SceneDir 'role-junction') 'inis'; New-I3Junction $junctionRoot $gInis
foreach ($case in @(@('root-not-named-inis', $wrongName), @('inis-folder-missing', (Join-Path (SceneDir 'role-none') 'inis')), @('inis-is-a-junction', $junctionRoot), @('empty-root', ''), @('relative-root', 'inis'))) {
    $x = Invoke-I3 { Get-DenGoRoleSpec $GL 'Pcsx2' $case[1] }
    [void](Assert-I2A ('G-04-role-spec-refuses-' + $case[0]) ($x.Ok -and ($x.Value.Ok -eq $false)) ("ok=$(Get-I3Prop $x.Value 'Ok' '?') reason=$(Get-I3Prop $x.Value 'Reason' '?')" + (Get-I3Err $x)))
}
Remove-I3Junction $junctionRoot
function Gate([string]$Path, [string]$Kind = 'Dest') { return (Invoke-I3 { Test-DenGoLeafGate $GL 'Pcsx2' $gInis $Path $Kind }) }
foreach ($leaf in @($gLilyPad, $gLily)) {
    $x = Gate $leaf
    [void](Assert-I2A ('G-05-leaf-gate-allows-' + [System.IO.Path]::GetFileName($leaf)) ($x.Ok -and ($x.Value.Allowed -eq $true)) ("allowed=$(Get-I3Prop $x.Value 'Allowed' '?') reason=$(Get-I3Prop $x.Value 'Reason' '?')" + (Get-I3Err $x)))
    $x = Gate ($leaf + (DgConst-TmpSuffix)) 'Tmp'
    [void](Assert-I2A ('G-05b-leaf-gate-allows-the-temporary-of-' + [System.IO.Path]::GetFileName($leaf)) ($x.Ok -and ($x.Value.Allowed -eq $true)) ("allowed=$(Get-I3Prop $x.Value 'Allowed' '?')" + (Get-I3Err $x)))
}
$homeDir = Split-Path $gInis -Parent
$forbidden = @(
    @('PCSX2.ini', (Join-Path $gInis 'PCSX2.ini')), @('PCSX2_ui.ini', (Join-Path $gInis 'PCSX2_ui.ini')), @('PCSX2_vm.ini', (Join-Path $gInis 'PCSX2_vm.ini')), @('GSdx.ini', (Join-Path $gInis 'GSdx.ini')),
    @('sub-folder-LilyPad', (Join-Path $gInis 'sub\LilyPad.ini')), @('LilyPad-bak', (Join-Path $gInis 'LilyPad.ini.bak')), @('plugin-dll', (Join-Path $homeDir 'Plugins\LilyPad.dll')),
    @('pcsx2-exe', (Join-Path $homeDir 'pcsx2.exe')), @('root-level-LilyPad', (Join-Path $homeDir 'LilyPad.ini')), @('portable-ini', (Join-Path $homeDir 'portable.ini')), @('uppercase-neighbour', (Join-Path $gInis 'LILYPAD2.INI')))
foreach ($f in $forbidden) {
    $x = Gate $f[1]
    [void](Assert-I2A ('G-05c-leaf-gate-refuses-' + $f[0]) ($x.Ok -and ($x.Value.Allowed -eq $false)) ("allowed=$(Get-I3Prop $x.Value 'Allowed' '?') reason=$(Get-I3Prop $x.Value 'Reason' '?')" + (Get-I3Err $x)))
}
foreach ($f in @(@('tmp-of-PCSX2.ini', (Join-Path $gInis 'PCSX2.ini.dengo.tmp'), 'Tmp'), @('inis-as-a-Dir', $gInis, 'Dir'), @('traversal', ($gInis + '\..\inis\PCSX2.ini'), 'Dest'))) {
    $x = Gate $f[1] $f[2]
    [void](Assert-I2A ('G-05d-leaf-gate-refuses-' + $f[0]) ($x.Ok -and ($x.Value.Allowed -eq $false)) ("allowed=$(Get-I3Prop $x.Value 'Allowed' '?') reason=$(Get-I3Prop $x.Value 'Reason' '?')" + (Get-I3Err $x)))
}
$tag = 'PCSX2|EffectiveInputProfile|Pcsx2|' + $gInis
$bk1 = Join-Path $GL.BackupRoot '20261003T000000Z-12345678\0001.bak'
$fl = Invoke-I3 { Test-DenGoItemGate $GL $tag $gLilyPad ($gLilyPad + (DgConst-TmpSuffix)) @() $bk1 '20261003T000000Z-12345678' }
[void](Assert-I2A 'G-06-item-gate-accepts-the-journaled-facts-of-LilyPad.ini' ($fl.Ok -and (@($fl.Value).Count -eq 0)) ("failures: " + $(if ($fl.Ok) { @($fl.Value) -join ' | ' } else { '?' }) + (Get-I3Err $fl)))
$fl = Invoke-I3 { Test-DenGoItemGate $GL $tag (Join-Path $gInis 'PCSX2.ini') ((Join-Path $gInis 'PCSX2.ini') + (DgConst-TmpSuffix)) @() $bk1 '20261003T000000Z-12345678' }
[void](Assert-I2A 'G-06b-item-gate-rejects-the-journaled-facts-of-PCSX2.ini' ($fl.Ok -and (@($fl.Value).Count -gt 0)) ("failures: " + $(if ($fl.Ok) { @($fl.Value).Count } else { '?' }) + (Get-I3Err $fl)))
# the uninstall side sees the same role
$us = Invoke-I3 { Get-DenGoUninstallRoleSpec $GL 'Pcsx2' $gInis }
[void](Assert-I2A 'G-07a-uninstall-role-spec-has-the-same-two-leaves' ($us.Ok -and ($us.Value.Ok -eq $true) -and (@($us.Value.Dests).Count -eq 2)) ("ok=$(Get-I3Prop $us.Value 'Ok' '?')" + (Get-I3Err $us)))
foreach ($f in @(@('LilyPad.ini', $gLilyPad, $true), @('lily', $gLily, $true), @('PCSX2.ini', (Join-Path $gInis 'PCSX2.ini'), $false), @('PCSX2_ui.ini', (Join-Path $gInis 'PCSX2_ui.ini'), $false), @('Plugins-dll', (Join-Path $homeDir 'Plugins\LilyPad.dll'), $false))) {
    $x = Invoke-I3 { Get-DenGoUninstallShape $GL 'PCSX2' $f[1] }
    $ok = ($x.Ok -and ($x.Value.Ok -eq $f[2]) -and ([bool]$x.Value.Deferred -eq $false) -and ((-not $f[2]) -or ([string]$x.Value.Role -ceq 'Pcsx2')))
    [void](Assert-I2A ('G-07b-uninstall-shape-' + $f[0] + '-ok-' + $f[2]) $ok ("shape=" + $(if ($x.Ok) { ConvertTo-I3Json $x.Value } else { '?' }) + (Get-I3Err $x)))
}
# plan entries
$en = Invoke-I3 { Convert-DenGoPlanToEntries $GL @((PI 'InputProfile' $gLily 'Add'), (PI 'EffectiveInputProfile' $gLilyPad 'UpdateOrRepair'), (PI 'EffectiveInputProfile' $gLilyPad 'PreserveOriginInvalid')) }
[void](Assert-I2A 'G-08-write-actions-are-transaction-items-and-never-deferred' ($en.Ok -and (@($en.Value).Count -eq 3) -and ($en.Value[0].IsTx -eq $true) -and ($en.Value[1].IsTx -eq $true) -and (@($en.Value | Where-Object { $_.Deferred }).Count -eq 0) -and ([string]$en.Value[0].Role -ceq 'Pcsx2')) ("entries=" + $(if ($en.Ok) { ConvertTo-I3Json @($en.Value | ForEach-Object { @{ Role = $_.Role; Tx = $_.IsTx; Deferred = $_.Deferred } }) } else { '?' }) + (Get-I3Err $en)))
[void](Assert-I2A 'G-08b-PreserveOriginInvalid-is-an-accepted-action-and-never-a-write' ($en.Ok -and ($en.Value[2].IsTx -eq $false) -and ([string]$en.Value[2].Action -ceq 'PreserveOriginInvalid')) ("entries ok=$($en.Ok)" + (Get-I3Err $en)))
$bad = Invoke-I3 { Convert-DenGoPlanToEntries $GL @((PI 'EffectiveInputProfile' $gLilyPad 'Overwrite')) }
[void](Assert-I2A 'G-08c-control-an-unknown-action-is-still-rejected' (-not $bad.Ok) 'Unsupported Apply action (existing behaviour)')
$tx = Invoke-I3 { $e = Convert-DenGoPlanToEntries $GL @((PI 'InputProfile' $gLily 'Add'), (PI 'EffectiveInputProfile' $gLilyPad 'UpdateOrRepair')); Get-DenGoTxItems $e }
[void](Assert-I2A 'G-09-transaction-items-carry-the-Pcsx2-tag-with-the-inis-root' ($tx.Ok -and (@($tx.Value.Items).Count -eq 2) -and ([string]$tx.Value.Items[0].Tag -ceq ('PCSX2|InputProfile|Pcsx2|' + $gInis)) -and ([string]$tx.Value.Items[1].Tag -ceq ('PCSX2|EffectiveInputProfile|Pcsx2|' + $gInis))) ("tags: " + $(if ($tx.Ok) { (@($tx.Value.Items | ForEach-Object { $_.Tag }) -join ' ; ') } else { '?' }) + (Get-I3Err $tx)))

Uninstall-I3Overrides
Remove-I2ASandbox $S
Complete-I2ATests
