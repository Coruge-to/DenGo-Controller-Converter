# Runs every I3 suite (each in its own Windows PowerShell 5.1 process) and writes the evidence of the run to a report directory under %TEMP%. Nothing is written to Downloads or to the repository.
#   input-sha256-before.txt / input-sha256-after.txt / input-verify.txt   the I3 test files and the product files under test (size, SHA-256) at the start and at the end;
#                                                                         a single change invalidates every result of the run
#   <suite>.stdout.txt / .stderr.txt / .exitcode.txt / .log               one set per suite
#   summary.txt                                                           start / end time, exit code and PASS / FAIL of every suite
#   evidence-manifest.sha256                                              SHA-256 of every other file in this directory (the manifest is not part of itself)
# -SkipGui leaves the GUI suite out (it drives a hidden window through UI Automation).
# -SkipSweeps runs I3-Fault without its sweeps (the named contracts, F2 included, still run).
param(
    [switch]$SkipGui,
    [switch]$SkipSweeps,
    [string]$ReportDir = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tests = $PSScriptRoot
$repo = [System.IO.Path]::GetFullPath((Join-Path $tests '..\..'))
. (Join-Path $tests 'I3.TestSupport.ps1')
if ([string]::IsNullOrEmpty($ReportDir)) { $ReportDir = Join-Path $env:TEMP ('DenGoI3-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($ReportDir) | Out-Null
Write-Host ('Report directory: ' + $ReportDir)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$runStartedUtc = [DateTime]::UtcNow.ToString('o')
$inputBefore = Get-I3InputManifest
Write-I3InputManifest (Join-Path $ReportDir 'input-sha256-before.txt') $inputBefore 'before'

function Invoke-Suite([string]$Name, [string]$Script, [string[]]$ExtraArgs = @()) {
    $log = Join-Path $ReportDir ($Name + '.log')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'; foreach ($a in $ExtraArgs) { $psi.Arguments += ' ' + $a }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $err = $errTask.Result
    $endedUtc = [DateTime]::UtcNow.ToString('o')
    [System.IO.File]::WriteAllText($log, $out + "`r`n--- stderr ---`r`n" + $err)
    [System.IO.File]::WriteAllText((Join-Path $ReportDir ($Name + '.stdout.txt')), $out, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $ReportDir ($Name + '.stderr.txt')), $err, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $ReportDir ($Name + '.exitcode.txt')), ([string]$p.ExitCode + "`n"), $utf8)
    $m = [regex]::Match($out, 'PASS=(\d+) FAIL=(\d+)')
    $pass = $(if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }); $fail = $(if ($m.Success) { [int]$m.Groups[2].Value } else { -1 })
    $ok = ($p.ExitCode -eq 0) -and $m.Success -and ($fail -eq 0)
    Write-Host ('{0,-14} exit={1} PASS={2} FAIL={3} ({4:N0}s) log={5}' -f $Name, $p.ExitCode, $pass, $fail, $sw.Elapsed.TotalSeconds, $log)
    return [pscustomobject]@{ Name = $Name; ExitCode = $p.ExitCode; Pass = $pass; Fail = $fail; Ok = $ok; StartedUtc = $startedUtc; EndedUtc = $endedUtc; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
$suites = @(@('I3-Static', 'Test-DenGoInstaller-I3-Static.ps1'), @('I3-Unit', 'Test-DenGoInstaller-I3-Unit.ps1'), @('I3-Zero', 'Test-DenGoInstaller-I3-Zero.ps1'), @('I3-Gate', 'Test-DenGoInstaller-I3-Gate.ps1'),
    @('I3-Engine', 'Test-DenGoInstaller-I3-Engine.ps1'), @('I3-Uninstall', 'Test-DenGoInstaller-I3-Uninstall.ps1'), @('I3-Search', 'Test-DenGoInstaller-I3-Search.ps1'))
if (-not $SkipGui) { $suites += , @('I3-Gui', 'Test-DenGoInstaller-I3-Gui.ps1') }
# the TOCTOU contract of the shared core as seen through the I3 world (contract mode; I2A.Toctou.TestSupport.ps1 is a helper, not a suite), and the I3 fault tests (formal F2 contract of the candidate grouping included)
$suites += , @('I3-Toctou', 'Test-DenGoInstaller-I3-Toctou.ps1', @('-Contract'))
$faultArgs = @('-EvidenceDir', ('"' + (Join-Path $ReportDir 'fault-evidence') + '"'))
if ($SkipSweeps) { $faultArgs += '-SkipSweeps' }
$suites += , @('I3-Fault', 'Test-DenGoInstaller-I3-Fault.ps1', $faultArgs)
$results = New-Object System.Collections.ArrayList
foreach ($s in $suites) { [void]$results.Add((Invoke-Suite $s[0] (Join-Path $tests $s[1]) $(if ($s.Count -gt 2) { [string[]]$s[2] } else { [string[]]@() }))) }

Write-Host ''
$total = 0; $failed = 0
foreach ($r in $results) { if ($r.Pass -gt 0) { $total += $r.Pass }; if (-not $r.Ok) { $failed++ } }
$runEndedUtc = [DateTime]::UtcNow.ToString('o')
$inputAfter = Get-I3InputManifest
Write-I3InputManifest (Join-Path $ReportDir 'input-sha256-after.txt') $inputAfter 'after'
$diff = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt @($inputBefore).Count; $i++) { $b = @($inputBefore)[$i]; $a = @($inputAfter)[$i]; if (($b.Sha256 -ne $a.Sha256) -or ($b.Size -ne $a.Size)) { [void]$diff.Add($b.Rel) } }
$inputSame = ($diff.Count -eq 0)
$verify = New-Object System.Text.StringBuilder
[void]$verify.Append("# I3 input verification`nstarted (UTC): $runStartedUtc`nended (UTC):   $runEndedUtc`n")
foreach ($d in $diff) { [void]$verify.Append("CHANGED: $d`n") }
[void]$verify.Append("RESULT: $(if ($inputSame) { 'UNCHANGED' } else { 'CHANGED' }) files=$(@($inputBefore).Count) differences=$($diff.Count)`n")
[System.IO.File]::WriteAllText((Join-Path $ReportDir 'input-verify.txt'), $verify.ToString(), $utf8)
Write-Host ('input files: ' + $(if ($inputSame) { 'UNCHANGED between the start and the end of the run (' + @($inputBefore).Count + ' files)' } else { 'CHANGED DURING THE RUN - the results of this run must not be used as evidence (see input-verify.txt)' }))

$sum = New-Object System.Text.StringBuilder
[void]$sum.Append("# I3 run summary`nrun started (UTC): $runStartedUtc`nrun ended (UTC):   $runEndedUtc`nreport directory:   $ReportDir`ninput files:        $(if ($inputSame) { 'UNCHANGED' } else { 'CHANGED' }) ($(@($inputBefore).Count) files, see input-verify.txt)`n")
[void]$sum.Append("# suite`texit`tPASS`tFAIL`tstarted (UTC)`tended (UTC)`tseconds`n")
foreach ($r in $results) { [void]$sum.Append(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`n" -f $r.Name, $r.ExitCode, $r.Pass, $r.Fail, $r.StartedUtc, $r.EndedUtc, $r.Seconds)) }
[void]$sum.Append("SUITES=$($results.Count) FAILED=$failed PASSED-ASSERTIONS=$total`n")
[System.IO.File]::WriteAllText((Join-Path $ReportDir 'summary.txt'), $sum.ToString(), $utf8)

$manifestPath = Join-Path $ReportDir 'evidence-manifest.sha256'
if ([System.IO.File]::Exists($manifestPath)) { [System.IO.File]::Delete($manifestPath) }
$em = New-Object System.Text.StringBuilder
$base = $ReportDir.TrimEnd('\') + '\'
foreach ($f in @([System.IO.Directory]::GetFiles($ReportDir, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)) {
    [void]$em.Append(("{0}  {1}  {2}`n" -f (Get-I2AFileSha $f), ([System.IO.FileInfo]$f).Length, $f.Substring($base.Length)))
}
[System.IO.File]::WriteAllText($manifestPath, $em.ToString(), $utf8)
Write-Host ('evidence manifest: ' + $manifestPath)
Write-Host ('SUITES={0} FAILED={1} PASSED-ASSERTIONS={2}' -f $results.Count, $failed, $total)
$totalFailed = $failed + $(if ($inputSame) { 0 } else { 1 })
Write-Host ('PASS={0} FAIL={1}' -f ($results.Count - $failed), $totalFailed)
if ($totalFailed -ne 0) { exit 1 }
exit 0
