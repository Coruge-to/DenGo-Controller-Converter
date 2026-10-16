# I2-C GUI test: the uninstaller GUI shows a residual notice on the completion page - only after a Completed run that left files behind
# (ResidualFileCount >= 1 or ManualCheckRequired = true), and names the report only when that file really exists.
# The I1 contract (exit codes 0 / 2 / 1, the result file, FormClosing, the commit check) is unchanged and is exercised by Test-DenGoInstaller-I1-Gui.ps1.
# Drives the real GUI script through UI Automation from a sandbox under TEMP with a fake engine; LOCALAPPDATA and TEMP point into the sandbox.
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')

$script:Sandboxes = New-Object System.Collections.ArrayList
$notice = U 0x4E00,0x90E8,0x306E,0x30D5,0x30A1,0x30A4,0x30EB,0x3092,0x5B89,0x5168,0x306E,0x305F,0x3081,0x6B8B,0x3057,0x307E,0x3057,0x305F
$fakeEngine = @'
param([switch]$DryRun,[switch]$Apply,[switch]$RealSystem,[string]$ConfirmRealApply='',[switch]$IncludeInputProfiles,[string]$OutputRoot='')
$ErrorActionPreference = 'Stop'
$sandbox = $env:DENGO_I1_SANDBOX
$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
$mode = [System.Environment]::GetEnvironmentVariable('DENGO_I2C_MODE'); if ([string]::IsNullOrEmpty($mode)) { $mode = 'clean' }
[System.IO.File]::WriteAllText((Join-Path $sandbox 'engine.pid'), [string]$PID)
$report = ''
if ($mode -eq 'residual-report') { $report = Join-Path $sandbox 'recovery-report.txt'; [System.IO.File]::WriteAllText($report, 'report') }
if ($mode -eq 'residual-fakereport') { $report = Join-Path $sandbox 'this-report-does-not-exist.txt' }
$count = 0; $manual = $false
if ($mode -like 'residual*') { $count = 2 }
if ($mode -eq 'manual') { $manual = $true }
if ($mode -eq 'fail') { $count = 3; $manual = $true }
$plan = [ordered]@{SchemaVersion=1;Succeeded=($mode -ne 'fail');ErrorCode='';ErrorMessage=$(if ($mode -eq 'fail') { 'fake uninstall failure' } else { '' });DryRun=[bool]$DryRun;Apply=[bool]$Apply;RealSystem=[bool]$RealSystem;Items=@();ApplyResults=@()}
if ($mode -ne 'legacy') { $plan['ResidualFileCount'] = $count; $plan['ManualCheckRequired'] = $manual; $plan['ReportPath'] = $report }
[System.IO.File]::WriteAllText((Join-Path $OutputRoot 'uninstall-plan.json'),(([pscustomobject]$plan) | ConvertTo-Json -Depth 6),(New-Object System.Text.UTF8Encoding($true)))
if ($mode -eq 'fail') { exit 1 }
[System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
$state = [pscustomobject]@{SchemaVersion=1;ProductVersion='2.0.0';State='Uninstalled';UninstalledAt=[System.DateTimeOffset]::Now.ToString('o')}
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'uninstalled-state.json'),($state | ConvertTo-Json -Depth 4),(New-Object System.Text.UTF8Encoding($true)))
exit 0
'@

function New-Scenario([string]$Name, [hashtable]$Environment) {
    $root = New-I1Sandbox $Name
    [void]$script:Sandboxes.Add($root)
    $gui = Initialize-GuiSandbox -Root $root
    [System.IO.File]::WriteAllText((Join-Path $root 'installer\scripts\Invoke-DenGoUninstaller.ps1'), $fakeEngine, (New-Object System.Text.UTF8Encoding($false)))
    $resultDir = Join-Path $root 'result'
    [System.IO.Directory]::CreateDirectory($resultDir) | Out-Null
    $resultPath = Join-Path $resultDir 'result.json'
    $runId = [System.Guid]::NewGuid().ToString('N')
    $process = Start-GuiUnderTest -Root $root -GuiName 'DenGoUninstallerGui.ps1' -Environment $Environment -ResultPath $resultPath -RunId $runId
    $window = Get-GuiMainWindow $process.Id
    return @{ Name = $Name; Root = $root; Process = $process; ResultPath = $resultPath; RunId = $runId; Window = $window }
}
function Invoke-Click($Ctx, [string]$Text, [int]$Timeout = 25) {
    $button = Wait-GuiButton $Ctx.Process.Id $Text $Timeout
    if ($null -eq $button) { return $false }
    Send-GuiClick $button
    return $true
}
function Wait-ExitCode($Ctx, [int]$Seconds = 25) { if ($Ctx.Process.WaitForExit($Seconds * 1000)) { return [int]$Ctx.Process.ExitCode }; return $null }
function Stop-Scenario($Ctx) { try { if (-not $Ctx.Process.HasExited) { $Ctx.Process.Kill(); $Ctx.Process.WaitForExit(5000) | Out-Null } } catch { } }
function Get-GuiTexts([int]$ProcessId) {
    $textCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $names = New-Object System.Collections.ArrayList
    foreach ($window in (Get-GuiWindows $ProcessId)) {
        foreach ($t in @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition))) {
            if (-not $t.Current.IsOffscreen) { [void]$names.Add([string]$t.Current.Name) }
        }
    }
    return , @($names)
}
function Read-ResultFile($Ctx) { if (-not [System.IO.File]::Exists($Ctx.ResultPath)) { return $null }; return ([System.IO.File]::ReadAllText($Ctx.ResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) }

try {
    $cases = @(
        @('clean', 'clean', $false, $false, 'no residual, no manual check: no notice'),
        @('legacy', 'legacy', $false, $false, 'an engine result without the new fields (the I1 fake): no notice'),
        @('residual', 'residual', $true, $false, 'ResidualFileCount >= 1: notice, no report path'),
        @('manual', 'manual', $true, $false, 'ManualCheckRequired alone: notice'),
        @('residual-report', 'residual-report', $true, $true, 'a real report: the notice names it'),
        @('residual-fakereport', 'residual-fakereport', $true, $false, 'a ReportPath that does not exist is never displayed'))
    foreach ($case in $cases) {
        $c = New-Scenario ('c-' + $case[0]) @{ DENGO_I2C_MODE = $case[1] }
        try {
            $ok = (Invoke-Click $c $script:UiText.Uninstall) -and ($null -ne (Wait-GuiButton $c.Process.Id $script:UiText.Finish 60))
            $deadline = [DateTime]::Now.AddSeconds($(if ($case[2]) { 8 } else { 2 }))
            Start-Sleep -Milliseconds 1200
            do { Start-Sleep -Milliseconds 300; $texts = Get-GuiTexts $c.Process.Id; $hit = @($texts | Where-Object { $_ -like ('*' + $notice + '*') }) } while (($hit.Count -eq 0) -and ([DateTime]::Now -lt $deadline))
            $reportShown = @($texts | Where-Object { $_ -like '*recovery-report.txt*' }).Count -gt 0
            $fakeShown = @($texts | Where-Object { $_ -like '*this-report-does-not-exist*' }).Count -gt 0
            Add-I1Result ('GUI-' + $case[0] + '-notice') ($ok -and (($hit.Count -gt 0) -eq $case[2])) ("reached the completion page=$ok; notice shown=$($hit.Count -gt 0) (want $($case[2])): " + $case[4] + " texts=[" + ([string]::Join(" | ", [string[]]@($texts))) + "]")
            Add-I1Result ('GUI-' + $case[0] + '-report-path') (($reportShown -eq $case[3]) -and (-not $fakeShown)) "real report named=$reportShown (want $($case[3])); non-existent path shown=$fakeShown (want False)"
            $clicked = Invoke-Click $c $script:UiText.Finish 25
            $code = Wait-ExitCode $c
            $res = Read-ResultFile $c
            Add-I1Result ('GUI-' + $case[0] + '-i1-contract-unchanged') ($clicked -and ($code -eq 0) -and ($null -ne $res) -and ($res.result -eq 'Completed') -and ($res.exitCode -eq 0) -and ($res.engineStarted -eq $true) -and ($res.engineCompleted -eq $true) -and ($res.stateCommitted -eq $true)) "exit=$code result=$(if ($null -ne $res) { $res.result }): a residual notice does not change Completed / exit code 0 / the result file"
        } finally { Stop-Scenario $c }
    }
    # a Failed run never shows the notice and stays Failed (exit 1)
    $c = New-Scenario 'c-fail' @{ DENGO_I2C_MODE = 'fail' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40)
        $texts = Get-GuiTexts $c.Process.Id
        $hit = @($texts | Where-Object { $_ -like ('*' + $notice + '*') })
        Add-I1Result 'GUI-fail-no-notice' ($ok -and ($hit.Count -eq 0)) "the failure message box was acknowledged=$ok; notice shown=$($hit.Count -gt 0) texts=[" + ([string]::Join(" | ", [string[]]@($texts))) + "]"
        $ok2 = (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        $code = Wait-ExitCode $c
        $res = Read-ResultFile $c
        Add-I1Result 'GUI-fail-stays-failed' ($ok2 -and ($code -eq 1) -and ($null -ne $res) -and ($res.result -eq 'Failed') -and ($res.reason -eq 'EngineFailed') -and ($res.stateCommitted -eq $false)) "exit=$code result=$(if ($null -ne $res) { $res.result + '/' + $res.reason })"
    } finally { Stop-Scenario $c }
} finally {
    foreach ($root in $script:Sandboxes) { Remove-I1Sandbox $root }
}
Complete-I1Tests
