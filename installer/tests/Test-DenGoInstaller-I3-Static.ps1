# I3 static tests (written RED first). Reads only; nothing is executed from the product. PowerShell AST, not regular expressions over code.
#   S-1x  files that I3 must not change (SHA-256 pins) and the absence of any new runtime file
#   S-2x  the fixed leaves: the Pcsx2 role has exactly the two leaves; no settings file name appears anywhere else
#   S-3x  the engine: detection goes through the classifier, no settings are read, PCSX2 is no longer deferred, the root derivation is the seam
#   S-4x  the allow list is a pair list inside ProductApply; process names are not an exe-name list any more
#   S-9x  hygiene of the I3 test files themselves (ASCII, syntax, no registry, no process start)
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
$repo = $script:I3Repo
$scripts = Join-Path $repo 'installer\scripts'
$guiDir = Join-Path $repo 'installer\gui'
$product = Join-Path $scripts 'DenGoInstallerProductApply.ps1'
$uninstallProduct = Join-Path $scripts 'DenGoUninstallerProductApply.ps1'
$core = Join-Path $scripts 'DenGoInstallerTransaction.ps1'
$engineI = Join-Path $scripts 'Invoke-DenGoInstaller.ps1'
$engineU = Join-Path $scripts 'Invoke-DenGoUninstaller.ps1'
$guiI = Join-Path $guiDir 'DenGoInstallerGui.ps1'
$guiU = Join-Path $guiDir 'DenGoUninstallerGui.ps1'
$AstNs = 'System.Management.Automation.Language'

function Get-FunctionAst($Ast, [string]$Name) {
    $found = @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return $null }
    return $found[0]
}
# string literals that are VALUES (a bare hashtable key such as "Deferred = $false" or a member name such as $x.Deferred is a property name, not a literal that names a role or a file)
function Get-Strings($Ast) {
    $out = New-Object System.Collections.ArrayList
    foreach ($s in @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $x -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
        $isKey = $false
        $par = $s.Parent
        if ($par -is [System.Management.Automation.Language.HashtableAst]) { foreach ($kv in $par.KeyValuePairs) { if ([object]::ReferenceEquals($kv.Item1, $s)) { $isKey = $true } } }
        if ($par -is [System.Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($par.Member, $s)) { $isKey = $true }
        if ($isKey) { continue }
        [void]$out.Add([string]$s.Value)
    }
    return , @($out)
}
function Get-CommandNodes($Ast, [string]$Name) {
    return , @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $Name }, $true))
}
function Get-OwnerFunctionName($Node) {
    $f = $Node.Parent
    while ($null -ne $f -and -not ($f -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $f = $f.Parent }
    if ($null -eq $f) { return '' }
    return $f.Name
}
function Parse-Quiet([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return [pscustomobject]@{ Ast = $ast; Errors = @($errors).Count }
}
function Count-NonAscii([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
    $n = 0
    for ($i = $start; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $n++ } }
    return $n
}

$pa = Parse-Quiet $product; $ua = Parse-Quiet $uninstallProduct; $ia = Parse-Quiet $engineI; $ea = Parse-Quiet $engineU; $ga = Parse-Quiet $guiI; $gua = Parse-Quiet $guiU
$all6 = @($pa, $ua, $ia, $ea, $ga, $gua)

# ================================================================ S-1x unchanged files and no new runtime file
[void](Assert-I2A 'S-10-every-product-script-and-GUI-parses' ((@($all6 | Where-Object { $_.Errors -ne 0 }).Count -eq 0)) ('parse errors: ' + (($all6 | ForEach-Object { $_.Errors }) -join ',')))
$nonAscii = @(@($product, $uninstallProduct, $engineI, $engineU) | ForEach-Object { Count-NonAscii $_ })
[void](Assert-I2A 'S-11-the-four-engine-scripts-stay-ASCII-only' (($nonAscii | Measure-Object -Sum).Sum -eq 0) ('non-ASCII bytes (after the BOM): ' + ($nonAscii -join ',')))
$pins = @(
    # the core is pinned to the approved I2-A TOCTOU core (F-D2 GREEN, local close 2026-10-31); I3 itself still does not touch it, and any further change of the core fails this pin
    @('installer/scripts/DenGoInstallerTransaction.ps1', '24BD327A05504F397B770ECC4FE07AE871A1FDBA4CF5C675B2E861B28B6D0F27'),
    @('installer/scripts/Start-DenGoSetup.ps1', '30482824C51C78B346CD6D29624F889CE3798F159F17CF7267155960AE679C76'),
    @('installer/scripts/Start-DenGoUninstall.ps1', '77F3FDC70235C9B41076CA7F34A84808A2C2814B4321A71BAA163310E4ED3829'),
    @('installer/build/Build-DenGo-SetupPackage.ps1', 'B6715329A211F73CD9C3576169217AE80E6D9A408898DBDB79D98E4212EB6462'),
    @('installer/Build-DenGo-SetupExe-2.0.0.ps1', '01953FA179C83FEEA14B3CA6729CE488430BCCAE1D3628973FD261B1B70EC16D'),
    @('installer/assets/input-profiles/pcsx2/DenGo-LilyPad-Active.ini', '7D2AE3223EB5CDA8C5048091370BA28B9D65C3EC2BC3421EF618A84EED161DE0'),
    @('installer/assets/input-profiles/pcsx2/DenGo-Controller-Converter.lily', 'CD4993CAF9E4496A78A34F2FB590EB851057409128DB31A13ADA2ED0FA731795'),
    @('installer/assets/input-profiles/rpcs3/Den-Go-Controller.yml', 'AB560A5E27D462DE66C05C1552B70BC5011D50A9BF098778AF8AFE346288456D'))
foreach ($p in $pins) {
    $abs = Join-Path $repo ($p[0].Replace('/', '\'))
    $sha = $(if ([System.IO.File]::Exists($abs)) { Get-I2AFileSha $abs } else { '<missing>' })
    [void](Assert-I2A ('S-12-unchanged-by-I3-' + $p[0]) ($sha -ceq $p[1]) ("sha=$sha"))
}
$txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($core))
[void](Assert-I2A 'S-13-the-transaction-core-has-no-PCSX2-or-LilyPad-knowledge' (($txt.IndexOf('PCSX2', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -and ($txt.IndexOf('LilyPad', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) 'the core stays platform-neutral')
$expectedRuntime = @('Build-DenGo-SetupExe-2.0.0.ps1', 'assets\images\DenGo-Controller-Converter.ico', 'assets\images\DenGo-Controller-Converter2.png', 'assets\input-profiles\README.md', 'assets\input-profiles\pcsx2\DenGo-Controller-Converter.lily',
    'assets\input-profiles\pcsx2\DenGo-LilyPad-Active.ini', 'assets\input-profiles\rpcs3\Den-Go-Controller.yml', 'build\Build-DenGo-SetupPackage.ps1', 'gui\DenGoInstallerGui.ps1', 'gui\DenGoUninstallerGui.ps1',
    'scripts\DenGoInstallerProductApply.ps1', 'scripts\DenGoInstallerTransaction.ps1', 'scripts\DenGoUninstallerProductApply.ps1', 'scripts\Invoke-DenGoInstaller.ps1', 'scripts\Invoke-DenGoUninstaller.ps1', 'scripts\Start-DenGoSetup.ps1', 'scripts\Start-DenGoUninstall.ps1')
$installerRoot = Join-Path $repo 'installer'
$actual = @([System.IO.Directory]::GetFiles($installerRoot, '*', [System.IO.SearchOption]::AllDirectories) | ForEach-Object { $_.Substring($installerRoot.Length + 1) } | Where-Object { -not $_.StartsWith('tests\') -and -not $_.StartsWith('build\payload\') } | Sort-Object)
$missing = @($expectedRuntime | Where-Object { $actual -notcontains $_ }); $extra = @($actual | Where-Object { $expectedRuntime -notcontains $_ })
[void](Assert-I2A 'S-14-I3-adds-no-runtime-file-outside-installer-tests' (($missing.Count -eq 0) -and ($extra.Count -eq 0)) ("missing: [$($missing -join ',')] extra: [$($extra -join ',')] (the allow list is a constant in ProductApply, so requiredFiles stays)"))

# ================================================================ S-2x the fixed leaves
$roleFn = Get-FunctionAst $pa.Ast 'Get-DenGoRoleSpec'
$roleStrings = @($(if ($null -ne $roleFn) { Get-Strings $roleFn } else { @() }))
$pcsxStrings = @($roleStrings | Where-Object { $_ -cmatch '^Pcsx2$' })
$leafStrings = @($roleStrings | Where-Object { $_ -imatch '\.(ini|lily|dll|exe)$' })
[void](Assert-I2A 'S-20-the-role-spec-has-a-Pcsx2-role' ($null -ne $roleFn -and $pcsxStrings.Count -ge 1) ("Pcsx2 literals in Get-DenGoRoleSpec: $($pcsxStrings.Count)"))
[void](Assert-I2A 'S-21-the-Pcsx2-role-names-exactly-the-two-leaves-and-no-other-file' (($null -ne $roleFn) -and (@($leafStrings | Where-Object { $_ -ceq 'LilyPad.ini' }).Count -eq 1) -and (@($leafStrings | Where-Object { $_ -ceq 'DenGo-Controller-Converter.lily' }).Count -eq 1) -and (@($leafStrings | Where-Object { $_ -in @('LilyPad.ini', 'DenGo-Controller-Converter.lily', 'BveTs.exe', 'rpcs3.exe', 'DenGoControllerConverter.dll', 'DenGoVehicleSpec.BveEx.Bridge.dll', 'DenGoBveVehicleSpec.dll', 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll', 'DenGoAtsExLegacyVehicleSpec.dll', 'Den-Go-Controller.yml') }).Count -eq $leafStrings.Count)) ('file-name literals in the role spec: ' + ($leafStrings -join ', ')))
$settingsNames = @('PCSX2.ini', 'PCSX2_vm.ini', 'GSdx.ini', 'portable.txt')
$hits = New-Object System.Collections.ArrayList
foreach ($f in @(@('ProductApply', $pa), @('UninstallerProductApply', $ua), @('InstallerEngine', $ia), @('UninstallerEngine', $ea), @('InstallerGui', $ga), @('UninstallerGui', $gua))) {
    foreach ($s in (Get-Strings $f[1].Ast)) { foreach ($n in $settingsNames) { if ($s.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$hits.Add($f[0] + ':' + $n) } } }
}
[void](Assert-I2A 'S-22-no-script-names-PCSX2.ini-PCSX2_vm.ini-GSdx.ini-or-portable.txt' ($hits.Count -eq 0) ('string literals naming a settings file that PCSX2 owns: ' + (($hits | Select-Object -Unique) -join ', ')))
$uiHits = New-Object System.Collections.ArrayList
foreach ($f in @(@('ProductApply', $pa), @('UninstallerProductApply', $ua), @('InstallerEngine', $ia), @('UninstallerEngine', $ea))) {
    foreach ($node in @($f[1].Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ([string]$x.Value).IndexOf('PCSX2_ui', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }, $true))) { [void]$uiHits.Add($f[0] + ':' + (Get-OwnerFunctionName $node)) }
}
[void](Assert-I2A 'S-23-PCSX2_ui.ini-is-named-only-by-the-root-proof' (($uiHits.Count -ge 1) -and (@($uiHits | Where-Object { $_ -cne 'ProductApply:Test-DenGoPcsx2RootProof' }).Count -eq 0)) ('PCSX2_ui literals in: ' + (($uiHits | Select-Object -Unique) -join ', ')))
$lily = Get-CommandNodes $ia.Ast 'New-NormalizedLegacyLilyPadFile'
$lilyAny = 0
foreach ($f in $all6) { $lilyAny += (Get-CommandNodes $f.Ast 'New-NormalizedLegacyLilyPadFile').Count }
[void](Assert-I2A 'S-24-control-the-LilyPad.ini-rewrite-has-no-call-site-nothing-converts-Active.ini-or-the-lily-profile' ($lilyAny -eq 0) "call sites of New-NormalizedLegacyLilyPadFile: $lilyAny (definition only)")

# ================================================================ S-3x the engine
$gIdx = (Get-CommandNodes $ia.Ast 'Group-DenGoPcsx2Candidates').Count
$pIdx = (Get-CommandNodes $ia.Ast 'New-DenGoPcsx2PlanItems').Count
[void](Assert-I2A 'S-30-the-engine-classifies-and-groups-through-Group-DenGoPcsx2Candidates' ($gIdx -eq 1) "call sites: $gIdx")
[void](Assert-I2A 'S-31-the-engine-plans-PCSX2-through-New-DenGoPcsx2PlanItems' ($pIdx -eq 1) "call sites: $pIdx")
$oldPlan = @((Get-CommandNodes $ia.Ast 'New-PlanItem') | Where-Object { $_.CommandElements.Count -ge 2 -and ($_.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ([string]$_.CommandElements[1].Value -ceq 'PCSX2') })
[void](Assert-I2A 'S-32-the-engine-no-longer-builds-PCSX2-plan-items-itself' ($oldPlan.Count -eq 0) "New-PlanItem 'PCSX2' calls: $($oldPlan.Count)")
$engineStr = Get-Strings $ia.Ast
[void](Assert-I2A 'S-33-the-engine-does-not-look-for-the-modern-input-sections' (@($engineStr | Where-Object { $_ -match '\[InputSources\]|\[Pad\]|\[Pad1\]' }).Count -eq 0) 'no [InputSources] / [Pad] / [Pad1] literal: a settings file of a 2.x install is never read')
$joinPcsx2 = @((Get-CommandNodes $ia.Ast 'Join-Path') | Where-Object { $_.CommandElements.Count -ge 3 -and ($_.CommandElements[2] -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ([string]$_.CommandElements[2].Value -ceq 'PCSX2') })
[void](Assert-I2A 'S-34-the-engine-does-not-derive-the-PCSX2-settings-root-itself' ($joinPcsx2.Count -eq 0) "Join-Path ... 'PCSX2' in the engine: $($joinPcsx2.Count) (the seam is Get-DenGoDocumentsRoot in ProductApply)")
$docsFn = Get-FunctionAst $pa.Ast 'Get-DenGoDocumentsRoot'
[void](Assert-I2A 'S-35-Get-DenGoDocumentsRoot-is-the-only-Documents-seam-in-ProductApply' (($null -ne $docsFn) -and (@($pa.Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$x.Member.Value -eq 'GetFolderPath' }, $true) | Where-Object { (Get-OwnerFunctionName $_) -cne 'Get-DenGoDocumentsRoot' }).Count -eq 0)) ("function exists: $($null -ne $docsFn)"))
$mapFn = Get-FunctionAst $pa.Ast 'DgP-MapPlatform'
$mapDeferred = $(if ($null -ne $mapFn) { @(Get-Strings $mapFn | Where-Object { $_ -ceq 'Deferred' }).Count } else { -1 })
[void](Assert-I2A 'S-36-PCSX2-is-no-longer-mapped-to-the-Deferred-pseudo-role' ($mapDeferred -eq 0) "'Deferred' literals in DgP-MapPlatform: $mapDeferred")
$shapeFn = Get-FunctionAst $ua.Ast 'Get-DenGoUninstallShape'; $decFn = Get-FunctionAst $ua.Ast 'Get-DenGoUninstallFileDecision'
$defShape = $(if ($null -ne $shapeFn) { @(Get-Strings $shapeFn | Where-Object { $_ -ceq 'Deferred' }).Count } else { -1 })
$defDec = $(if ($null -ne $decFn) { @(Get-Strings $decFn | Where-Object { $_ -ceq 'Deferred' -or $_ -ceq 'DeferredToI3' }).Count } else { -1 })
[void](Assert-I2A 'S-37-the-uninstall-shape-and-decision-no-longer-defer-PCSX2' (($defShape -eq 0) -and ($defDec -eq 0)) "Deferred literals: shape=$defShape decision=$defDec")
$closeFn = Get-FunctionAst $pa.Ast 'Merge-DenGoInstalledState'
$mergeText = $(if ($null -ne $closeFn) { $closeFn.Extent.Text } else { '' })
[void](Assert-I2A 'S-38-the-close-rule-excludes-PCSX2-by-platform-name-not-by-deferral' (($null -ne (Get-FunctionAst $pa.Ast 'DgP-IsPcsx2Record')) -and ($mergeText.IndexOf('DgP-IsPcsx2Record', [System.StringComparison]::Ordinal) -ge 0) -and ($mergeText.IndexOf('DgP-IsDeferredRecord', [System.StringComparison]::Ordinal) -lt 0)) 'Merge-DenGoInstalledState uses DgP-IsPcsx2Record')

# ================================================================ S-4x the allow list and the process names
$pairsFn = Get-FunctionAst $pa.Ast 'Get-DenGoPcsx2KnownPairs'
$hex = @($(if ($null -ne $pairsFn) { @(Get-Strings $pairsFn | Where-Object { $_ -cmatch '^[0-9A-F]{64}$' }) } else { @() }))
[void](Assert-I2A 'S-40-the-allow-list-is-a-constant-pair-list-inside-ProductApply' (($null -ne $pairsFn) -and ($hex.Count -ge 2) -and (($hex.Count % 2) -eq 0) -and ($hex -ccontains $script:I3PairExeSha) -and ($hex -ccontains $script:I3PairPluginSha)) ("hex64 literals in Get-DenGoPcsx2KnownPairs: $($hex.Count)"))
$otherHex = 0
foreach ($f in @($ua, $ia, $ea, $ga, $gua)) { foreach ($s in (Get-Strings $f.Ast)) { if ($s -imatch '^(E387C713|637DEF94)') { $otherHex++ } } }
[void](Assert-I2A 'S-41-the-allow-list-values-exist-only-in-ProductApply' ($otherHex -eq 0) "allow-list hashes elsewhere: $otherHex")
$fh = (Get-CommandNodes $pa.Ast 'Get-FileHash').Count
[void](Assert-I2A 'S-42-control-ProductApply-hashes-only-through-the-primitive-layer' ($fh -eq 0) "Get-FileHash calls in ProductApply: $fh")
$gateBad = New-Object System.Collections.ArrayList
foreach ($g in @(@('InstallerEngine', $ia, 'Get-RunningTargetProducts'), @('InstallerGui', $ga, 'Get-RunningProductNames'), @('UninstallerGui', $gua, 'Get-RunningProductNames'))) {
    $fn = Get-FunctionAst $g[1].Ast $g[2]
    if ($null -eq $fn) { [void]$gateBad.Add($g[0] + ':missing'); continue }
    foreach ($s in (Get-Strings $fn)) { if ($s -ieq 'pcsx2.exe' -or $s -ieq 'pcsx2-qt.exe') { [void]$gateBad.Add($g[0] + ':' + $s) } }
}
[void](Assert-I2A 'S-43-process-gates-do-not-list-pcsx2.exe-and-pcsx2-qt.exe-by-exact-name' ($gateBad.Count -eq 0) ('exact-name literals: ' + (($gateBad | Select-Object -Unique) -join ', ')))
$procFns = 0
foreach ($n in 'Get-DenGoPcsx2Identity', 'Group-DenGoPcsx2Candidates', 'Resolve-DenGoPcsx2Root', 'Test-DenGoPcsx2RootProof', 'New-DenGoPcsx2PlanItems', 'Get-DenGoPcsx2KnownPairs') { if ($null -ne (Get-FunctionAst $pa.Ast $n)) { $procFns++ } }
[void](Assert-I2A 'S-44-the-six-detection-functions-exist-once-in-ProductApply' ($procFns -eq 6) "found $procFns of 6")

# ================================================================ S-9x hygiene of the I3 test files
$tests = Join-Path $repo 'installer\tests'
$mine = @(Get-I3NewFileList | ForEach-Object { Join-Path $repo ($_.Replace('/', '\')) })
$bad = New-Object System.Collections.ArrayList
foreach ($f in $mine) {
    if (-not [System.IO.File]::Exists($f)) { [void]$bad.Add([System.IO.Path]::GetFileName($f) + ':missing'); continue }
    if ((Count-NonAscii $f) -ne 0) { [void]$bad.Add([System.IO.Path]::GetFileName($f) + ':non-ascii') }
    $pq = Parse-Quiet $f
    if ($pq.Errors -ne 0) { [void]$bad.Add([System.IO.Path]::GetFileName($f) + ':parse') }
    foreach ($s in (Get-Strings $pq.Ast)) { if ($s -match '^(HK[A-Z]{2,3}:|Registry::)' -or $s -imatch 'C:\\Users\\[^\\]+\\(Documents|AppData)') { [void]$bad.Add([System.IO.Path]::GetFileName($f) + ':real-path-or-registry') } }
    foreach ($n in 'Start-Process', 'Stop-Process', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Invoke-WebRequest', 'Set-Content') {
        $c = (Get-CommandNodes $pq.Ast $n).Count
        if ($c -gt 0 -and -not ([System.IO.Path]::GetFileName($f) -in @('Test-DenGoInstaller-I3-All.ps1'))) { [void]$bad.Add([System.IO.Path]::GetFileName($f) + ':' + $n) }
    }
}
[void](Assert-I2A 'S-90-the-I3-test-files-exist-are-ASCII-parse-and-touch-no-registry-no-real-path-no-process' ($bad.Count -eq 0) ('problems: ' + (($bad | Select-Object -Unique) -join ', ')))
# ================================================================ S-91 / S-92 the All runners register every suite exactly once (a missing or doubled registration is a failure, not a silent gap)
function Get-AllRegistrations([string]$AllFile, [string]$SuiteGlob, [string[]]$NotSuites) {
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($AllFile)).Replace("`r`n", "`n")
    $onDisk = @([System.IO.Directory]::GetFiles($tests, $SuiteGlob) | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { $NotSuites -notcontains $_ } | Sort-Object)
    $rows = @([regex]::Matches($text, "@\('([A-Za-z0-9-]+)',\s*'(Test-DenGoInstaller-[A-Za-z0-9-]+\.ps1)'(?:,\s*(@\([^\n]*?\)|\$\w+))?\)") | ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; File = $_.Groups[2].Value; Args = $_.Groups[3].Value } })
    $perFile = @{}
    foreach ($r in $rows) { if ($perFile.ContainsKey($r.File)) { $perFile[$r.File]++ } else { $perFile[$r.File] = 1 } }
    $perName = @{}
    foreach ($r in $rows) { if ($perName.ContainsKey($r.Name)) { $perName[$r.Name]++ } else { $perName[$r.Name] = 1 } }
    $missing = @($onDisk | Where-Object { -not $perFile.ContainsKey($_) })
    $doubled = @($perFile.Keys | Where-Object { $perFile[$_] -gt 1 }) + @($perName.Keys | Where-Object { $perName[$_] -gt 1 })
    return [pscustomobject]@{ Text = $text; OnDisk = $onDisk; Rows = $rows; Missing = $missing; Doubled = @($doubled | Sort-Object -Unique) }
}
$i3all = Get-AllRegistrations (Join-Path $tests 'Test-DenGoInstaller-I3-All.ps1') 'Test-DenGoInstaller-I3-*.ps1' @('Test-DenGoInstaller-I3-All.ps1')
$i3Toctou = @($i3all.Rows | Where-Object { $_.File -ceq 'Test-DenGoInstaller-I3-Toctou.ps1' })
$i3Fault = @($i3all.Rows | Where-Object { $_.File -ceq 'Test-DenGoInstaller-I3-Fault.ps1' })
[void](Assert-I2A 'S-91-I3-All-registers-every-I3-suite-file-exactly-once' (($i3all.Missing.Count -eq 0) -and ($i3all.Doubled.Count -eq 0) -and ($i3all.OnDisk.Count -ge 9)) ("suite files on disk: $($i3all.OnDisk.Count); not registered: [$($i3all.Missing -join ',')]; registered twice: [$($i3all.Doubled -join ',')]"))
[void](Assert-I2A 'S-91b-I3-Toctou-runs-in-contract-mode-and-I3-Fault-is-registered-with-its-sweeps-switch' (($i3Toctou.Count -eq 1) -and ($i3Toctou[0].Args -match '-Contract') -and ($i3Fault.Count -eq 1) -and ($i3all.Text.Contains('[switch]$SkipSweeps')) -and ($i3all.Text.Contains('$faultArgs += ''-SkipSweeps''')) -and ($i3all.Text.Contains('Test-DenGoInstaller-I3-Fault.ps1'))) ("I3-Toctou rows: $($i3Toctou.Count) args=[$(if ($i3Toctou.Count) { $i3Toctou[0].Args })]; I3-Fault rows: $($i3Fault.Count)"))
$i2aall = Get-AllRegistrations (Join-Path $tests 'Test-DenGoInstaller-I2A-All.ps1') 'Test-DenGoInstaller-I2A-*.ps1' @('Test-DenGoInstaller-I2A-All.ps1')
$i2aTox = @($i2aall.Rows | Where-Object { $_.File -ceq 'Test-DenGoInstaller-I2A-Toctou.ps1' })
$i2aToxKill = @($i2aall.Rows | Where-Object { $_.File -ceq 'Test-DenGoInstaller-I2A-ToctouKill.ps1' })
$helpers = @('I2A.Toctou.TestSupport.ps1', 'I2A.ToctouKill.TestSupport.ps1', 'I2A.ToctouKillChild.ps1')
$helperAsSuite = @($helpers | Where-Object { $i2aall.Text.IndexOf("'" + $_ + "'") -ge 0 })
[void](Assert-I2A 'S-92-I2A-All-registers-the-TOCTOU-suites-once-the-helpers-are-not-suites' (($i2aall.Missing.Count -eq 0) -and ($i2aall.Doubled.Count -eq 0) -and ($i2aTox.Count -eq 1) -and ($i2aTox[0].Args -match '-Contract') -and ($i2aToxKill.Count -eq 1) -and ($helperAsSuite.Count -eq 0) -and (@($helpers | Where-Object { -not [System.IO.File]::Exists((Join-Path $tests $_)) })).Count -eq 0) ("not registered: [$($i2aall.Missing -join ',')]; registered twice: [$($i2aall.Doubled -join ',')]; Toctou rows $($i2aTox.Count) (contract mode: $(if ($i2aTox.Count) { $i2aTox[0].Args -match '-Contract' })); ToctouKill rows $($i2aToxKill.Count); helpers listed as suites: [$($helperAsSuite -join ',')]"))
# ================================================================ S-93 the three HEAD-baseline CHAR rows are kept as history (never a pass criterion of the contract mode), and the current observation is recorded next to them
# Pre-fix HEAD values: Delete window 10 points; Replace window 196..215 = 20 points with census 60/280; classes DestinationChangedDuringApply=80, PlanStale=101, RecoveryRequired=14.
# They are asserted only outside -Contract; under -Contract a DIAG line (and an evidence record) with the CURRENT observation takes their place. None of the nine safety CHAR rows is guarded like this.
$baseRows = @(
    @('Test-DenGoInstaller-I2A-Toctou.ps1', 'D-WIN-census-HEAD-baseline-the-Delete-window-has-10-points', '($winCount -eq 10)', 'D-WIN-census-current'),
    @('Test-DenGoInstaller-I3-Toctou.ps1', 'I3-WIN-census-HEAD-baseline-the-Replace-window-has-20-points-196-215', '($winFrom -eq 196) -and ($winTo -eq 215) -and ($mutN -eq 60) -and ($allN -eq 280)', 'I3-WIN-census-current'),
    @('Test-DenGoInstaller-I3-Toctou.ps1', 'I3-PREFIX-classes-are-the-same-as-today', "`$classText -ceq 'DestinationChangedDuringApply=80, PlanStale=101, RecoveryRequired=14'", 'I3-PREFIX-classes-current'))
$baseProblems = New-Object System.Collections.ArrayList
foreach ($br in $baseRows) {
    $txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $tests $br[0]))).Replace("`r`n", "`n")
    $line = @($txt.Split("`n") | Where-Object { $_.Contains("'" + $br[1] + "'") })
    if ($line.Count -ne 1) { [void]$baseProblems.Add($br[1] + ':rows=' + $line.Count); continue }
    $ln = $line[0].TrimStart()
    if (-not $ln.StartsWith('if (-not $Contract) { Assert-Tx ')) { [void]$baseProblems.Add($br[1] + ':not-guarded-by-not-Contract') }
    if (-not $ln.Contains($br[2])) { [void]$baseProblems.Add($br[1] + ':history-value-changed') }
    if (-not ($ln.Contains('else { Write-Host ("DIAG | ' + $br[3]) -and $ln.Contains("id = '" + $br[3] + "'"))) { [void]$baseProblems.Add($br[1] + ':no-current-observation-record') }
}
[void](Assert-I2A 'S-93-the-three-HEAD-baseline-CHAR-rows-keep-their-ids-and-history-values-are-outside-the-contract-mode-with-a-current-observation-record' ($baseProblems.Count -eq 0) ("rows checked: 3; problems: [$($baseProblems -join ', ')]"))
Complete-I2ATests
