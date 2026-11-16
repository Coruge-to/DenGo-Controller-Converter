# I3-H search tests (written RED first): the -AdditionalSearch fixed-drive search (Add-FixedDriveExecutables in Invoke-DenGoInstaller.ps1).
# Contract under test (owner decision 2026-11-16, after the I3-E finding that a custom PCSX2 location was found only by an unbounded depth-first walk):
#   - breadth first: shallow installs are reported before deep ones, so the time cap cuts the deepest, least likely directories first
#   - depth limit 5 (the drive root is depth 0)
#   - never enters a reparse point (junction / symlink): no cycles, no walk into another volume or a user folder behind a link
#   - skips system trees: $Recycle.Bin, System Volume Information, WindowsApps, node_modules, .git at any depth; Windows, Recovery, PerfLogs directly below a root only
#   - installers / uninstallers / updaters named *pcsx2* are still not reported (existing behaviour, kept)
#   - the engine call uses a 60 s per-drive cap; the search start points are a seam (-Roots) so that the tests can use a sandbox under TEMP
# The function is taken from the engine script by AST (the engine script is not dot-sourceable); only the sandbox is touched. No process, no registry.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
$repo = $script:I3Repo
$engine = Join-Path $repo 'installer\scripts\Invoke-DenGoInstaller.ps1'
$tokens = $null; $perr = $null
$engineAst = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$perr)
$loaded = New-Object System.Collections.ArrayList
foreach ($n in 'Add-Executable', 'Get-Platform', 'Add-FixedDriveExecutables') {
    $found = @($engineAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($found.Count -eq 1) { . ([scriptblock]::Create($found[0].Extent.Text)); [void]$loaded.Add($n) }
}
[void](Assert-I2A 'X-00-the-three-functions-are-defined-exactly-once-in-the-engine' ($loaded.Count -eq 3) ('loaded: ' + ($loaded -join ',')))

$S = New-I2ASandbox 'search'
$links = New-Object System.Collections.ArrayList
function New-Exe([string]$Root, [string]$Rel) {
    $p = Join-Path $Root $Rel
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($p)) | Out-Null
    [System.IO.File]::WriteAllBytes($p, [byte[]](77, 90))
    return $p
}
function New-Scene([string]$Name) { $d = Join-Path $S $Name; [System.IO.Directory]::CreateDirectory($d) | Out-Null; return $d }
# runs the search over one root; never throws (a missing parameter is a result, not a crash of the suite)
function Invoke-Search([string]$Root, [int]$Seconds = 30) {
    $list = New-Object System.Collections.ArrayList
    $err = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # A simple function does NOT reject an unknown -Roots: the old code would silently walk the REAL fixed drives. Without the parameter the function is never called.
    $cmd = Get-Command Add-FixedDriveExecutables -ErrorAction SilentlyContinue
    if ($null -eq $cmd -or -not $cmd.Parameters.ContainsKey('Roots')) { return [pscustomobject]@{ Error = 'no -Roots parameter (the function would walk the real drives)'; Seconds = 0.0; List = @() } }
    try { Add-FixedDriveExecutables -List $list -MaxSecondsPerDrive $Seconds -Roots @($Root) } catch { $err = $_.Exception.Message }
    return [pscustomobject]@{ Error = $err; Seconds = $sw.Elapsed.TotalSeconds; List = @($list) }
}
function Rel([string]$Root, $Item) { return ([string]$Item.Executable).Substring($Root.Length).TrimStart('\') }
function Depth([string]$Root, $Item) { return @((Rel $Root $Item).Split('\')).Count - 1 }

try {
    # ---------------------------------------------------------------- X-01 a custom shallow location is found
    $r1 = New-Scene 'shallow'
    [void](New-Exe $r1 'Games\PS2\PCSX2 1.6.0\pcsx2.exe'); [void](New-Exe $r1 'Games\BVE\BveTs.exe'); [void](New-Exe $r1 'Tools\rpcs3.exe')
    $s1 = Invoke-Search $r1
    $byPlat = @($s1.List | ForEach-Object { $_.Platform } | Sort-Object)
    [void](Assert-I2A 'X-01-a-custom-PCSX2-BVE-and-RPCS3-location-is-found' (($s1.Error -eq '') -and (($byPlat -join ',') -eq 'BVE,PCSX2,RPCS3') -and (@($s1.List | Where-Object { ([string]$_.Source).StartsWith('AdditionalFixedDriveSearch:') }).Count -eq 3)) ("error='$($s1.Error)' platforms=$($byPlat -join ',')"))

    # ---------------------------------------------------------------- X-02 depth limit 5 (root = 0)
    $r2 = New-Scene 'depth'
    [void](New-Exe $r2 'a\b\c\d\e\pcsx2.exe'); [void](New-Exe $r2 'a\b\c\d\e\f\rpcs3.exe')
    $s2 = Invoke-Search $r2
    $rels2 = @($s2.List | ForEach-Object { Rel $r2 $_ })
    [void](Assert-I2A 'X-02-depth-5-is-searched-and-depth-6-is-not' (($s2.Error -eq '') -and ($rels2.Count -eq 1) -and ($rels2[0] -ieq 'a\b\c\d\e\pcsx2.exe')) ("error='$($s2.Error)' found: [$($rels2 -join ';')]"))

    # ---------------------------------------------------------------- X-03 breadth first: the shallow install comes first even when it sits in the alphabetically FIRST branch
    $r3 = New-Scene 'bfs'
    [void](New-Exe $r3 'z9\x\y\w\pcsx2.exe'); [void](New-Exe $r3 'a1\PCSX2\pcsx2.exe'); [void](New-Exe $r3 'm5\n\BveTs.exe')
    $s3 = Invoke-Search $r3
    $depths3 = @($s3.List | ForEach-Object { Depth $r3 $_ })
    $sorted3 = $true; for ($i = 1; $i -lt $depths3.Count; $i++) { if ($depths3[$i] -lt $depths3[$i - 1]) { $sorted3 = $false } }
    [void](Assert-I2A 'X-03-results-are-reported-shallow-first-breadth-first' (($s3.Error -eq '') -and ($depths3.Count -eq 3) -and $sorted3) ("error='$($s3.Error)' depths in report order: [$($depths3 -join ',')]"))

    # ---------------------------------------------------------------- X-04 system trees are skipped; a user folder that merely CALLS itself Windows below the root is not
    $r4 = New-Scene 'exclude'
    foreach ($rel in 'Windows\Sub\pcsx2.exe', 'Recovery\pcsx2.exe', 'PerfLogs\pcsx2.exe', '$Recycle.Bin\S-1-5-21\pcsx2.exe', 'System Volume Information\pcsx2.exe', 'WindowsApps\Emu\pcsx2.exe', 'Dev\node_modules\x\pcsx2.exe', 'Dev\repo\.git\pcsx2.exe') { [void](New-Exe $r4 $rel) }
    [void](New-Exe $r4 'Games\Windows\PCSX2\pcsx2.exe')
    $s4 = Invoke-Search $r4
    $rels4 = @($s4.List | ForEach-Object { Rel $r4 $_ })
    [void](Assert-I2A 'X-04-system-trees-are-skipped-and-a-nested-Windows-folder-is-not' (($s4.Error -eq '') -and ($rels4.Count -eq 1) -and ($rels4[0] -ieq 'Games\Windows\PCSX2\pcsx2.exe')) ("error='$($s4.Error)' found: [$($rels4 -join ';')]"))

    # ---------------------------------------------------------------- X-05 reparse points are never entered (no walk behind a link, no cycle)
    $r5 = New-Scene 'links'; $outside = New-Scene 'links-outside'
    [void](New-Exe $outside 'Deep\pcsx2.exe'); [void](New-Exe $r5 'Real\Emu\pcsx2.exe')
    $junction = Join-Path $r5 'Link'; $loop = Join-Path $r5 'Real\Loop'
    $made = $true
    try { [void](New-Item -ItemType Junction -Path $junction -Target $outside); [void]$links.Add($junction); [void](New-Item -ItemType Junction -Path $loop -Target $r5); [void]$links.Add($loop) } catch { $made = $false }
    $s5 = Invoke-Search $r5 20
    $rels5 = @($s5.List | ForEach-Object { Rel $r5 $_ })
    [void](Assert-I2A 'X-05-a-junction-is-not-entered-and-a-cycle-ends-fast' ($made -and ($s5.Error -eq '') -and ($rels5.Count -eq 1) -and ($rels5[0] -ieq 'Real\Emu\pcsx2.exe') -and ($s5.Seconds -lt 15)) ("junctions made: $made; error='$($s5.Error)' found: [$($rels5 -join ';')] in $([math]::Round($s5.Seconds, 1)) s"))

    # ---------------------------------------------------------------- X-06 installers, uninstallers and updaters are still not reported; the name match is case-insensitive
    $r6 = New-Scene 'names'
    foreach ($rel in 'x\pcsx2-uninstall.exe', 'x\pcsx2-setup.exe', 'x\PCSX2-installer.exe', 'x\pcsx2updater.exe', 'x\pcsx2.txt') { [void](New-Exe $r6 $rel) }
    [void](New-Exe $r6 'y\PCSX2-1.6.0.EXE')
    $s6 = Invoke-Search $r6
    $rels6 = @($s6.List | ForEach-Object { Rel $r6 $_ })
    [void](Assert-I2A 'X-06-installer-and-uninstaller-names-are-not-reported' (($s6.Error -eq '') -and ($rels6.Count -eq 1) -and ($rels6[0] -ieq 'y\PCSX2-1.6.0.EXE')) ("error='$($s6.Error)' found: [$($rels6 -join ';')]"))

    # ---------------------------------------------------------------- X-07 a zero second cap ends at once and does not throw
    $r7 = New-Scene 'cap'
    [void](New-Exe $r7 'a\pcsx2.exe')
    $s7 = Invoke-Search $r7 0
    [void](Assert-I2A 'X-07-a-zero-second-cap-returns-at-once-without-an-error' (($s7.Error -eq '') -and ($s7.Seconds -lt 5) -and ($s7.List.Count -eq 0)) ("error='$($s7.Error)' in $([math]::Round($s7.Seconds, 2)) s, found $($s7.List.Count)"))

    # ---------------------------------------------------------------- X-08 the engine call and the signature
    $calls = @($engineAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Add-FixedDriveExecutables' }, $true))
    $fnAst = @($engineAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Add-FixedDriveExecutables' }, $true))
    $secs = -1; $positional = 0
    if ($calls.Count -eq 1) { $els = @($calls[0].CommandElements); $positional = $els.Count; if ($els.Count -ge 3 -and $els[2] -is [System.Management.Automation.Language.ConstantExpressionAst]) { $secs = [int]$els[2].Value } }
    [void](Assert-I2A 'X-08a-the-engine-calls-the-search-once-with-a-60-second-cap-and-the-default-start-points' (($calls.Count -eq 1) -and ($secs -eq 60) -and ($positional -eq 3)) ("calls=$($calls.Count) seconds=$secs elements=$positional"))
    $paramNames = @(); if ($fnAst.Count -eq 1 -and $null -ne $fnAst[0].Body.ParamBlock) { $paramNames = @($fnAst[0].Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    [void](Assert-I2A 'X-08b-the-search-start-points-and-the-depth-are-parameters' (($paramNames -contains 'Roots') -and ($paramNames -contains 'MaxDepth')) ('parameters: ' + ($paramNames -join ',')))
} finally {
    foreach ($l in $links) { try { if ([System.IO.Directory]::Exists($l)) { [System.IO.Directory]::Delete($l) } } catch { } }
    Remove-I2ASandbox $S
}
Complete-I2ATests
