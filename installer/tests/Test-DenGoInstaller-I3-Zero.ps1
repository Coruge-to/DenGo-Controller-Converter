# I3 zero-touch tests (written RED first): PCSX2 1.7 or later / 2.x, x64, arm64, an exe outside the allow list and every "version unknown" case must change NOTHING and must not even open a settings file.
# The proof has two halves, as the plan says (section 4.6 / audit section 14.2):
#   - the settings tree of every scenario is hashed before and after the detection, the plan and the install (tree equality),
#   - the primitive layer is wrapped (I3.TestSupport.ps1) and the calls are recorded: no settings file of an unsupported install is probed, read, hashed or written.
# The static half (no PCSX2.ini literal, no ReadAllText on settings) is in the Static suite. Direct .NET calls cannot be recorded, which is why both halves exist.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
Install-I3Overrides
$S = New-I3Sandbox 'zero'
$srcActive = Join-Path $S 'active.src'; $srcLily = Join-Path $S 'lily.src'
Write-I3Text $srcActive 'DENGO-ACTIVE-LILYPAD-V1'; Write-I3Text $srcLily 'DENGO-LILY-PROFILE-V1'
$settingsLeaves = '^(PCSX2\.ini|PCSX2_vm\.ini|PCSX2_ui\.ini|GSdx\.ini|LilyPad\.ini|portable\.ini|portable\.txt|DenGo-Controller-Converter\.lily)$'
$layout = New-I3Layout $S

function Scene([string]$Name) { $d = Join-Path $S $Name; [System.IO.Directory]::CreateDirectory($d) | Out-Null; Set-I3DocumentsRoot (Join-Path $d 'Documents'); return $d }
function Treemap([string[]]$Roots) { $m = @{}; foreach ($r in $Roots) { $t = Get-I2ATreeMap $r @(); foreach ($k in $t.Keys) { $m[$r + '|' + $k] = $t[$k] } }; return $m }
# Detection + plan (with consent and every source) for the candidates; returns the plan items, the resolution and the recorded calls
function Probe($Candidates, [bool]$Consent = $true) {
    Start-I3Record
    $g = Invoke-I3 { Group-DenGoPcsx2Candidates -Candidates $Candidates }
    $p = $(if ($g.Ok) { Invoke-I3 { New-DenGoPcsx2PlanItems -Resolution $g.Value -LilySource $srcLily -ActiveSource $srcActive -ReplaceConsent $Consent -Previous $null -Layout $layout -LastClosedTransactionId '' } } else { [pscustomobject]@{ Ok = $false; Value = $null; Error = $g.Error } })
    $recs = Stop-I3Record
    return [pscustomobject]@{ G = $g; P = $p; Recs = $recs; Items = @($(if ($p.Ok) { @($p.Value) } else { @() })) }
}
function RecDetail($Recs) { return ((@($Recs) | Select-Object -First 6) -join '; ') }
function Check-Unsupported([string]$Id, $Candidates, [string[]]$TreeRoots, [string[]]$ConfigRoots, [string]$ExpectStatus = 'None') {
    $before = Treemap $TreeRoots
    $x = Probe $Candidates
    $after = Treemap $TreeRoots
    $cfgRecs = Select-I3RecLeaf $x.Recs $settingsLeaves
    $inisRecs = Select-I3Rec $x.Recs @($ConfigRoots | ForEach-Object { Join-Path $_ 'inis' })
    [void](Assert-I2A ($Id + '-a-no-plan-item-even-with-consent') ($x.G.Ok -and $x.P.Ok -and ($x.Items.Count -eq 0) -and ([string]$x.G.Value.Status -ceq $ExpectStatus)) ("status=$(Get-I3Prop $x.G.Value 'Status' '?') items=$($x.Items.Count)" + (Get-I3Err $x.G) + (Get-I3Err $x.P)))
    [void](Assert-I2A ($Id + '-b-the-settings-tree-is-byte-identical') (Same $before $after) ('diff: ' + (Diff3 $before $after)))
    [void](Assert-I2A ($Id + '-c-no-settings-file-is-probed-read-hashed-or-written') ($x.G.Ok -and ($cfgRecs.Count -eq 0) -and ($inisRecs.Count -eq 0)) ("settings records: $($cfgRecs.Count) + below inis: $($inisRecs.Count): " + (RecDetail ($cfgRecs + $inisRecs))))
    return $x
}

# ---- Z-01 pcsx2-qt.exe (x64, 2.x) with a modern PCSX2.ini and an old LilyPad.ini next to it
$d = Scene 'z01'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs -Pcsx2Ini $true -LilyPadContent 'OLD-LILYPAD-OF-AN-EARLIER-1.6')
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
[void](New-I3Config (Join-Path $d 'Qt') -Pcsx2Ini $true)
$x = Check-Unsupported 'Z-01-qt-build' @((New-I3Candidate $qt)) @($docs, (Join-Path $d 'Qt')) @($docs, (Join-Path $d 'Qt'))
[void](Assert-I2A 'Z-01d-the-qt-build-is-reported-detected-but-unsupported' ($x.G.Ok -and ([string]$x.G.Value.Detected[0].SupportStatus -ceq 'UnsupportedCurrent') -and ([string]$x.G.Value.Detected[0].State -ceq 'Detected')) ("entry=" + $(if ($x.G.Ok) { ConvertTo-I3Json $x.G.Value.Detected[0] } else { '?' })))
# an old LilyPad.ini next to a qt build must not make it "supported" (the old detection looked at the file, not at the exe)
[void](Assert-I2A 'Z-01e-an-old-LilyPad.ini-does-not-make-a-qt-build-supported' ($x.G.Ok -and ([string]$x.G.Value.Detected[0].SupportStatus -cne 'Supported') -and ([string]$x.G.Value.Detected[0].Mode -cnotmatch 'LegacyLilyPad')) ("mode=[$(if ($x.G.Ok) { $x.G.Value.Detected[0].Mode } else { '?' })]"))

# ---- Z-02 x64 pcsx2.exe
$d = Scene 'z02'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs -Pcsx2Ini $true)
$exe = New-I3Pcsx2Home (Join-Path $d 'App') -Machine 'x64' -ExeSha $script:I3PairExeSha
[void](Check-Unsupported 'Z-02-x64-pcsx2-exe' @((New-I3Candidate $exe)) @($docs) @($docs))
# ---- Z-03 arm64
$d = Scene 'z03'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs)
$exe = New-I3Pcsx2Home (Join-Path $d 'App') -Machine 'arm64'
[void](Check-Unsupported 'Z-03-arm64-pcsx2-exe' @((New-I3Candidate $exe)) @($docs) @($docs))
# ---- Z-04 x86 exe that is not on the allow list (an unknown 1.x / a repack): version unknown
$d = Scene 'z04'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs)
$exe = New-I3Pcsx2Home (Join-Path $d 'App') -ExeSha $script:I3OtherExeSha
$x = Check-Unsupported 'Z-04-x86-exe-outside-the-allow-list' @((New-I3Candidate $exe)) @($docs) @($docs)
[void](Assert-I2A 'Z-04d-it-is-reported-as-version-unknown-not-as-unsupported-current' ($x.G.Ok -and ([string]$x.G.Value.Detected[0].SupportStatus -ceq 'UnsupportedUnverified')) ("status=$(if ($x.G.Ok) { $x.G.Value.Detected[0].SupportStatus } else { '?' })"))
# ---- Z-05 the exe is on the list but the LilyPad.dll is not (or is missing)
$d = Scene 'z05'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs)
$exe = New-I3Pcsx2Home (Join-Path $d 'App') -PluginSha $script:I3OtherPluginSha
[void](Check-Unsupported 'Z-05-lilypad-dll-outside-the-allow-list' @((New-I3Candidate $exe)) @($docs) @($docs))
$d = Scene 'z05b'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs)
$exe = New-I3Pcsx2Home (Join-Path $d 'App') -Plugin $false
[void](Check-Unsupported 'Z-05b-lilypad-dll-missing' @((New-I3Candidate $exe)) @($docs) @($docs))
# ---- Z-06 a pcsx2.exe with a broken PE header
$d = Scene 'z06'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs)
$exe = New-I3Pcsx2Home (Join-Path $d 'App') -Machine 'InvalidPE'
[void](Check-Unsupported 'Z-06-broken-pe-header' @((New-I3Candidate $exe)) @($docs) @($docs))
# ---- Z-07 portable.txt only: not portable, so the settings inside the exe folder are never looked at
$d = Scene 'z07'; $docs = Join-Path $d 'Documents\PCSX2'; $app = Join-Path $d 'App'
$exe = New-I3Pcsx2Home $app -PortableTxt $true
[void](New-I3Config $app)
$before = Treemap @($app)
$x = Probe @((New-I3Candidate $exe))
$after = Treemap @($app)
$appRecs = Select-I3Rec $x.Recs @((Join-Path $app 'inis'))
[void](Assert-I2A 'Z-07a-portable-txt-only-resolves-nothing-the-central-root-is-not-initialised' ($x.G.Ok -and $x.P.Ok -and ($x.Items.Count -eq 0) -and ([string]$x.G.Value.Status -ceq 'None') -and ([string]$x.G.Value.Detected[0].State -ceq 'DetectedButNotInitialized')) ("status=$(Get-I3Prop $x.G.Value 'Status' '?') items=$($x.Items.Count) state=$(if ($x.G.Ok) { $x.G.Value.Detected[0].State } else { '?' })" + (Get-I3Err $x.G)))
[void](Assert-I2A 'Z-07b-the-settings-inside-the-exe-folder-are-never-opened-and-portable-txt-is-never-looked-at' ($x.G.Ok -and ($appRecs.Count -eq 0) -and ((Cnt (Select-I3RecLeaf $x.Recs '^portable\.txt$')) -eq 0) -and (Same $before $after)) ("records below the exe folder inis: $($appRecs.Count)"))
# ---- Z-08 a RunningProcess / arguments never rescue an unsupported exe
$d = Scene 'z08'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs -Pcsx2Ini $true)
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
[void](Check-Unsupported 'Z-08-qt-build-found-as-a-running-process-with--portable' @((New-I3Candidate $qt '-portable' 'RunningProcess')) @($docs, (Join-Path $d 'Qt')) @($docs, (Join-Path $d 'Qt')))

# ---- Z-09 1.6.0 and a qt build share Documents\PCSX2: only the two fixed leaves of the 1.6.0 root change; PCSX2.ini and the rest of the 2.x files never
$d = Scene 'z09'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs -Pcsx2Ini $true -LilyPadContent 'USER-LILYPAD-OF-THE-1.6-USER')
$app = New-I3Pcsx2Home (Join-Path $d 'App16')
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
$pcsx2IniSha = Get-I3Sha (Join-Path $docs 'inis\PCSX2.ini'); $vmSha = Get-I3Sha (Join-Path $docs 'inis\PCSX2_vm.ini'); $uiSha = Get-I3Sha (Join-Path $docs 'inis\PCSX2_ui.ini'); $gsSha = Get-I3Sha (Join-Path $docs 'inis\GSdx.ini')
$before = Treemap @($docs)
$x = Probe @((New-I3Candidate $qt), (New-I3Candidate $app))
$leafRecs = Select-I3RecLeaf $x.Recs '^(PCSX2\.ini|PCSX2_vm\.ini|GSdx\.ini)$'
[void](Assert-I2A 'Z-09a-coexistence-plans-exactly-the-two-fixed-leaves' ($x.G.Ok -and $x.P.Ok -and ($x.Items.Count -eq 2) -and (@($x.Items | Where-Object { (Split-Path ([string]$_.Destination) -Leaf) -in @('LilyPad.ini', 'DenGo-Controller-Converter.lily') }).Count -eq 2)) ("items=$($x.Items.Count): " + (@($x.Items | ForEach-Object { $_.Destination }) -join ' ; ') + (Get-I3Err $x.G) + (Get-I3Err $x.P)))
[void](Assert-I2A 'Z-09b-planning-never-touches-PCSX2.ini-PCSX2_vm.ini-or-GSdx.ini' ($x.G.Ok -and ($leafRecs.Count -eq 0)) ("records: " + (RecDetail $leafRecs)))
$opts = @{ ShortcutRequested = $false; StageParent = $S; ProcessGate = { } }
$res = Invoke-I3 { Invoke-DenGoProductInstall -Layout $layout -Plan ([object[]]@($x.Items)) -Options $opts }
$after = Treemap @($docs)
$changed = @(Compare-I2ATree $before $after | ForEach-Object { ([string]$_).Substring(1).Split('|')[1] } | Sort-Object)
[void](Assert-I2A 'Z-09c-the-install-writes-only-LilyPad.ini-and-the-lily-profile' ($res.Ok -and ($res.Value.Succeeded -eq $true) -and ($changed.Count -eq 2) -and ($changed -contains 'f:inis\lilypad.ini') -and ($changed -contains 'f:inis\dengo-controller-converter.lily')) ("succeeded=$(Get-I3Prop $res.Value 'Succeeded' '?') code=$(Get-I3Prop $res.Value 'ErrorCode' '?') changed: $($changed -join ', ')" + (Get-I3Err $res)))
[void](Assert-I2A 'Z-09d-every-2.x-file-and-the-UI-ini-are-byte-identical' (((Get-I3Sha (Join-Path $docs 'inis\PCSX2.ini')) -ceq $pcsx2IniSha) -and ((Get-I3Sha (Join-Path $docs 'inis\PCSX2_vm.ini')) -ceq $vmSha) -and ((Get-I3Sha (Join-Path $docs 'inis\PCSX2_ui.ini')) -ceq $uiSha) -and ((Get-I3Sha (Join-Path $docs 'inis\GSdx.ini')) -ceq $gsSha)) 'PCSX2.ini, PCSX2_vm.ini, PCSX2_ui.ini, GSdx.ini unchanged')

# ---- Z-10 the install of an unsupported-only plan: nothing at all happens to the PCSX2 trees
$d = Scene 'z10'; $docs = Join-Path $d 'Documents\PCSX2'
[void](New-I3Config $docs -Pcsx2Ini $true)
$qt = New-I3Pcsx2Home (Join-Path $d 'Qt') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
$before = Treemap @($docs)
$x = Probe @((New-I3Candidate $qt))
Start-I3Record
$res = Invoke-I3 { Invoke-DenGoProductInstall -Layout $layout -Plan ([object[]]@($x.Items)) -Options $opts }
$recs = Stop-I3Record
$after = Treemap @($docs)
[void](Assert-I2A 'Z-10-installing-with-an-unsupported-only-detection-leaves-the-PCSX2-tree-and-calls-untouched' ($x.G.Ok -and $x.P.Ok -and $res.Ok -and (Same $before $after) -and ((Cnt (Select-I3Rec $recs @($docs))) -eq 0)) ("diff=[$(Diff3 $before $after)] primitive calls below the settings root: $(Cnt (Select-I3Rec $recs @($docs)))" + (Get-I3Err $res)))

Uninstall-I3Overrides
Remove-I2ASandbox $S
Complete-I2ATests
