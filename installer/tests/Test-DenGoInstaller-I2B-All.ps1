# Runs every I2-B suite (each in its own Windows PowerShell 5.1 process) and, optionally, the regression suites of I1, I2-A, R1A, R1B and QA1.
# All output goes to a report directory under %TEMP%. Nothing is written to Downloads or to the repository.
param(
    [switch]$IncludeRegression,
    [switch]$SkipHeavy,
    [string]$ReportDir = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tests = $PSScriptRoot
$repo = [System.IO.Path]::GetFullPath((Join-Path $tests '..\..'))
if ([string]::IsNullOrEmpty($ReportDir)) { $ReportDir = Join-Path $env:TEMP ('DenGoI2B-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($ReportDir) | Out-Null
Write-Host ('Report directory: ' + $ReportDir)

function Invoke-Suite([string]$Name, [string]$Script, [string[]]$ExtraArgs = @(), [hashtable]$Env = @{}) {
    $log = Join-Path $ReportDir ($Name + '.log')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
    foreach ($a in $ExtraArgs) { $argLine += ' ' + $a }
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    [System.IO.File]::WriteAllText($log, $out + "`r`n--- stderr ---`r`n" + $errTask.Result)
    $m = [regex]::Match($out, 'PASS=(\d+) FAIL=(\d+)')
    $pass = $(if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }); $fail = $(if ($m.Success) { [int]$m.Groups[2].Value } else { -1 })
    $ok = ($p.ExitCode -eq 0) -and $m.Success -and ($fail -eq 0)
    Write-Host ('{0,-16} exit={1} PASS={2} FAIL={3} ({4:N0}s) log={5}' -f $Name, $p.ExitCode, $pass, $fail, $sw.Elapsed.TotalSeconds, $log)
    if (-not $ok) { foreach ($l in @($out -split "`n" | Where-Object { $_ -match '^FAIL' } | Select-Object -First 15)) { Write-Host ('    ' + $l.Trim()) } }
    return [pscustomobject]@{ Name = $Name; ExitCode = $p.ExitCode; Pass = $pass; Fail = $fail; Ok = $ok }
}

$results = New-Object System.Collections.ArrayList
$faultArgs = @('-EvidenceDir', ('"' + $ReportDir + '"'))
if ($SkipHeavy) { $faultArgs += '-SkipHeavy' }
foreach ($s in @(
        @('I2B-Static', 'Test-DenGoInstaller-I2B-Static.ps1', @()),
        @('I2B-Unit', 'Test-DenGoInstaller-I2B-Unit.ps1', @()),
        @('I2B-Empty', 'Test-DenGoInstaller-I2B-Empty.ps1', @()),
        @('I2B-Fault', 'Test-DenGoInstaller-I2B-Fault.ps1', $faultArgs),
        @('I2B-Kill', 'Test-DenGoInstaller-I2B-Kill.ps1', @('-EvidenceDir', ('"' + $ReportDir + '"'))),
        @('I2B-Lock', 'Test-DenGoInstaller-I2B-Lock.ps1', @()),
        @('I2B-EngineGlue', 'Test-DenGoInstaller-I2B-EngineGlue.ps1', @()),
        @('I2B-Gui', 'Test-DenGoInstaller-I2B-Gui.ps1', @()))) {
    [void]$results.Add((Invoke-Suite $s[0] (Join-Path $tests $s[1]) $s[2]))
}
if ($IncludeRegression) {
    $a = @()
    if ($SkipHeavy) { $a = @('-SkipHeavy') }
    foreach ($s in @(
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
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git) {
    Write-Host ('git HEAD:   ' + (& git -C $repo rev-parse HEAD))
    Write-Host ('git diff --stat HEAD: [' + ((@(& git -C $repo diff --stat HEAD)) -join '; ') + ']')
    Write-Host 'git status --short:'; foreach ($l in @(& git -C $repo status --short)) { Write-Host ('  ' + $l) }
}
Write-Host ('SUITES={0} FAILED={1} PASSED-ASSERTIONS={2}' -f $results.Count, $failed, $total)
Write-Host ('PASS={0} FAIL={1}' -f ($results.Count - $failed), $failed)
if ($failed -ne 0) { exit 1 }
exit 0
