# Runs every I2-C suite (each in its own Windows PowerShell 5.1 process) and, optionally, the regression suites of I2-B, I2-A, I1, R1A, R1B and QA1.
# All output goes to a report directory under %TEMP%. Nothing is written to Downloads or to the repository.
#
# The report directory is also the evidence of the run:
#   input-sha256-before.txt / input-sha256-after.txt / input-verify.txt   the I2-C input files (size, SHA-256, last write) at the start and at the end;
#                                                                         a single change invalidates every result of the run
#   <suite>.stdout.txt / .stderr.txt / .exitcode.txt / .log               one set per suite
#   fault-normal\ and fault-fullthrow\                                    the evidence directories of the two Fault runs (cases-i2c-fault.jsonl, own input hashes)
#   summary.txt                                                           start / end time, exit code and PASS / FAIL of every suite
#   evidence-manifest.sha256                                              SHA-256 of every other file in this directory (the manifest is not part of itself)
# -FullThrow runs the Fault suite twice (normal and with an exception at every point) against the same input files.
param(
    [switch]$IncludeRegression,
    [switch]$SkipHeavy,
    [switch]$FullThrow,
    [switch]$RegressionOnly,
    [string]$ReportDir = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tests = $PSScriptRoot
$repo = [System.IO.Path]::GetFullPath((Join-Path $tests '..\..'))
. (Join-Path $tests 'I2C.TestSupport.ps1')
if ([string]::IsNullOrEmpty($ReportDir)) { $ReportDir = Join-Path $env:TEMP ('DenGoI2C-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($ReportDir) | Out-Null
Write-Host ('Report directory: ' + $ReportDir)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$runStartedUtc = [DateTime]::UtcNow.ToString('o')
$inputBefore = Get-I2CInputManifest
Write-I2CInputManifest (Join-Path $ReportDir 'input-sha256-before.txt') $inputBefore 'before'

function Invoke-Suite([string]$Name, [string]$Script, [string[]]$ExtraArgs = @(), [hashtable]$Env = @{}) {
    $log = Join-Path $ReportDir ($Name + '.log')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
    foreach ($a in $ExtraArgs) { $argLine += ' ' + $a }
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
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
    Write-Host ('{0,-20} exit={1} PASS={2} FAIL={3} ({4:N0}s) log={5}' -f $Name, $p.ExitCode, $pass, $fail, $sw.Elapsed.TotalSeconds, $log)
    if (-not $ok) { foreach ($l in @($out -split "`n" | Where-Object { $_ -match '^FAIL' } | Select-Object -First 15)) { Write-Host ('    ' + $l.Trim()) } }
    return [pscustomobject]@{ Name = $Name; ExitCode = $p.ExitCode; Pass = $pass; Fail = $fail; Ok = $ok; StartedUtc = $startedUtc; EndedUtc = $endedUtc; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

$results = New-Object System.Collections.ArrayList
$faultNormalDir = Join-Path $ReportDir 'fault-normal'
$faultFullDir = Join-Path $ReportDir 'fault-fullthrow'
[System.IO.Directory]::CreateDirectory($faultNormalDir) | Out-Null
$faultArgs = @('-EvidenceDir', ('"' + $faultNormalDir + '"'))
if ($SkipHeavy) { $faultArgs += '-SkipHeavy' }
$i2cSuites = @(
        @('I2C-Static', 'Test-DenGoInstaller-I2C-Static.ps1', @()),
        @('I2C-Unit', 'Test-DenGoInstaller-I2C-Unit.ps1', @()),
        @('I2C-Fault', 'Test-DenGoInstaller-I2C-Fault.ps1', $faultArgs))
if ($FullThrow) {
    [System.IO.Directory]::CreateDirectory($faultFullDir) | Out-Null
    $i2cSuites += , @('I2C-Fault-FullThrow', 'Test-DenGoInstaller-I2C-Fault.ps1', @('-FullThrow', '-EvidenceDir', ('"' + $faultFullDir + '"')))
}
$i2cSuites += , @('I2C-Kill', 'Test-DenGoInstaller-I2C-Kill.ps1', @('-EvidenceDir', ('"' + $ReportDir + '"')))
$i2cSuites += , @('I2C-Lock', 'Test-DenGoInstaller-I2C-Lock.ps1', @())
$i2cSuites += , @('I2C-EngineGlue', 'Test-DenGoInstaller-I2C-EngineGlue.ps1', @())
$i2cSuites += , @('I2C-Gui', 'Test-DenGoInstaller-I2C-Gui.ps1', @())
if (-not $RegressionOnly) { foreach ($s in $i2cSuites) { [void]$results.Add((Invoke-Suite $s[0] (Join-Path $tests $s[1]) $s[2])) } }
if ($IncludeRegression) {
    $a = @()
    if ($SkipHeavy) { $a = @('-SkipHeavy') }
    foreach ($s in @(
            @('I2B-Static', 'Test-DenGoInstaller-I2B-Static.ps1', @()), @('I2B-Unit', 'Test-DenGoInstaller-I2B-Unit.ps1', @()), @('I2B-Empty', 'Test-DenGoInstaller-I2B-Empty.ps1', @()),
            @('I2B-Fault', 'Test-DenGoInstaller-I2B-Fault.ps1', (@('-EvidenceDir', ('"' + $ReportDir + '"')) + $a)),
            @('I2B-Kill', 'Test-DenGoInstaller-I2B-Kill.ps1', @('-EvidenceDir', ('"' + $ReportDir + '"'))), @('I2B-Lock', 'Test-DenGoInstaller-I2B-Lock.ps1', @()),
            @('I2B-EngineGlue', 'Test-DenGoInstaller-I2B-EngineGlue.ps1', @()), @('I2B-Gui', 'Test-DenGoInstaller-I2B-Gui.ps1', @()),
            @('I2A-Static', 'Test-DenGoInstaller-I2A-Static.ps1', @()), @('I2A-Unit', 'Test-DenGoInstaller-I2A-Unit.ps1', @()),
            @('I2A-Fault', 'Test-DenGoInstaller-I2A-Fault.ps1', (@('-EvidenceDir', ('"' + $ReportDir + '"')) + $a)),
            @('I2A-Kill', 'Test-DenGoInstaller-I2A-Kill.ps1', @('-EvidenceDir', ('"' + $ReportDir + '"'))),
            @('I1-Static', 'Test-DenGoInstaller-I1-Static.ps1', @()), @('I1-Wrapper', 'Test-DenGoInstaller-I1-Wrapper.ps1', @()), @('I1-Logic', 'Test-DenGoInstaller-I1-Logic.ps1', @()),
            @('I1-Gui', 'Test-DenGoInstaller-I1-Gui.ps1', @()), @('R1A', 'Test-DenGoInstaller-R1A.ps1', @()), @('R1B', 'Test-DenGoInstaller-R1B.ps1', @()))) {
        [void]$results.Add((Invoke-Suite $s[0] (Join-Path $tests $s[1]) $s[2]))
    }
    # QA1 writes its report below the user profile Downloads folder: redirect USERPROFILE into a throw-away folder under TEMP.
    $fakeProfile = Join-Path $ReportDir 'qa1-profile'
    [System.IO.Directory]::CreateDirectory((Join-Path $fakeProfile 'Downloads')) | Out-Null
    [void]$results.Add((Invoke-Suite 'QA1' (Join-Path $tests 'Test-DenGoInstaller-QA1.ps1') @() @{ USERPROFILE = $fakeProfile }))
}

Write-Host ''
$total = 0; $failed = 0
foreach ($r in $results) { if ($r.Pass -gt 0) { $total += $r.Pass }; if (-not $r.Ok) { $failed++ } }
$runEndedUtc = [DateTime]::UtcNow.ToString('o')
$inputAfter = Get-I2CInputManifest
Write-I2CInputManifest (Join-Path $ReportDir 'input-sha256-after.txt') $inputAfter 'after'
$inputSame = Write-I2CInputVerify (Join-Path $ReportDir 'input-verify.txt') $inputBefore $inputAfter $runStartedUtc $runEndedUtc
Write-Host ('input files: ' + $(if ($inputSame) { 'UNCHANGED between the start and the end of the run (' + @($inputBefore).Count + ' files)' } else { 'CHANGED DURING THE RUN - the results of this run must not be used as evidence (see input-verify.txt)' }))
$gitLines = New-Object System.Collections.ArrayList
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git) {
    [void]$gitLines.Add('git HEAD:   ' + (& git -C $repo rev-parse HEAD))
    [void]$gitLines.Add('git diff --stat HEAD: [' + ((@(& git -C $repo diff --stat HEAD)) -join '; ') + ']')
    [void]$gitLines.Add('git status --short:')
    foreach ($l in @(& git -C $repo status --short)) { [void]$gitLines.Add('  ' + $l) }
}
foreach ($l in $gitLines) { Write-Host $l }

# summary.txt: start / end time, exit code and PASS / FAIL of every suite
$sum = New-Object System.Text.StringBuilder
[void]$sum.Append("# I2-C run summary`nrun started (UTC): $runStartedUtc`nrun ended (UTC):   $runEndedUtc`nreport directory:   $ReportDir`ninput files:        $(if ($inputSame) { 'UNCHANGED' } else { 'CHANGED' }) ($(@($inputBefore).Count) files, see input-verify.txt)`n")
[void]$sum.Append("# suite`texit`tPASS`tFAIL`tstarted (UTC)`tended (UTC)`tseconds`n")
foreach ($r in $results) { [void]$sum.Append(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`n" -f $r.Name, $r.ExitCode, $r.Pass, $r.Fail, $r.StartedUtc, $r.EndedUtc, $r.Seconds)) }
[void]$sum.Append("SUITES=$($results.Count) FAILED=$failed PASSED-ASSERTIONS=$total`n")
foreach ($l in $gitLines) { [void]$sum.Append($l + "`n") }
[System.IO.File]::WriteAllText((Join-Path $ReportDir 'summary.txt'), $sum.ToString(), $utf8)

# evidence manifest: SHA-256 of every file of the report directory except the manifest itself
$manifestPath = Join-Path $ReportDir 'evidence-manifest.sha256'
if ([System.IO.File]::Exists($manifestPath)) { [System.IO.File]::Delete($manifestPath) }
$em = New-Object System.Text.StringBuilder
$base = $ReportDir.TrimEnd('\') + '\'
foreach ($f in @([System.IO.Directory]::GetFiles($ReportDir, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)) {
    [void]$em.Append(("{0}  {1}  {2}`n" -f (Get-I2AFileSha $f), ([System.IO.FileInfo]$f).Length, $f.Substring($base.Length)))
}
[System.IO.File]::WriteAllText($manifestPath, $em.ToString(), $utf8)
Write-Host ('evidence manifest: ' + $manifestPath + ' (' + @([System.IO.Directory]::GetFiles($ReportDir, '*', [System.IO.SearchOption]::AllDirectories)).Count + ' files incl. itself)')

Write-Host ('SUITES={0} FAILED={1} PASSED-ASSERTIONS={2}' -f $results.Count, $failed, $total)
$totalFailed = $failed + $(if ($inputSame) { 0 } else { 1 })
Write-Host ('PASS={0} FAIL={1}' -f ($results.Count - $failed), $totalFailed)
if ($totalFailed -ne 0) { exit 1 }
exit 0
