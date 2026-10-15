# I2-B GUI test: a Deferred PCSX2 result is shown as "not changed this time" - not as set up, not as failed - and the I1 outcome is unchanged
# (Completed, exit code 0). The real installer GUI script runs from a sandbox under TEMP with a fake engine; LOCALAPPDATA and TEMP point into the sandbox.
# Controls: 'ok' (PCSX2 applied) and 'fail' (no PCSX2 result) keep their old rows. Nothing real is installed, no registry key is touched.
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')

$script:UiText['Search'] = (U 0x8FFD, 0x52A0, 0x306E, 0x74B0, 0x5883, 0x3092, 0x691C, 0x7D22)
$deferredText = 'PCSX2' + (U 0x306E, 0x5165, 0x529B, 0x8A2D, 0x5B9A, 0x306F, 0x4ECA, 0x56DE, 0x306F, 0x5909, 0x66F4, 0x3057, 0x3066, 0x3044, 0x307E, 0x305B, 0x3093)
$okText = U 0x8A2D, 0x5B9A, 0x6E08, 0x307F, 0x30FB, 0x5229, 0x7528, 0x53EF, 0x80FD
$failText = U 0x5165, 0x529B, 0x8A2D, 0x5B9A, 0x306E, 0x8FFD, 0x52A0, 0x306B, 0x5931, 0x6557, 0x3057, 0x307E, 0x3057, 0x305F
$keepText = U 0x65E2, 0x5B58, 0x306E, 0x8A2D, 0x5B9A, 0x3092, 0x4F7F, 0x7528, 0x3057, 0x307E, 0x3059

$fakeInstaller = @'
param([switch]$DryRun,[switch]$Apply,[switch]$RealSystem,[string]$ConfirmRealApply='',[string]$OutputRoot='',[switch]$AdditionalSearch,[switch]$CreateDesktopShortcut,[switch]$SkipBveIntegration,[switch]$ReplaceModifiedPCSX2Profile,[switch]$ReplaceModifiedRPCS3Profile)
$ErrorActionPreference = 'Stop'
$sandbox = $env:DENGO_I1_SANDBOX
$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
$mode = [System.Environment]::GetEnvironmentVariable('DENGO_I2B_PCSX2'); if ([string]::IsNullOrEmpty($mode)) { $mode = 'deferred' }
function Row($Platform, $Component, $Action) { return [pscustomobject]@{Set=$Platform;Platform=$Platform;Component=$Component;Action=$Action;Destination='x';Applied=($Action -eq 'Add');Backup='';Succeeded=$true;ErrorCode=''} }
function Write-Plan([bool]$IsApply) {
    $status = 'Supported'; $pmode = 'CentralConfiguration-LegacyLilyPad'
    if ($mode -eq 'unsupported') { $status = 'UnsupportedCurrent'; $pmode = 'CentralConfiguration-CurrentIntegrated' }
    $detected = @([pscustomobject]@{Platform='PCSX2';Executable='x';State='Detected';Mode=$pmode;SupportStatus=$status;InputDevices='';ProfileDirectory='';EffectiveInputProfile='';DetectionSource='test'})
    $apply = @()
    if ($IsApply) {
        $apply = @((Row 'Core' 'Application' 'Add'))
        if ($mode -eq 'deferred') { $apply += (Row 'PCSX2' 'InputProfile' 'Deferred'); $apply += (Row 'PCSX2' 'EffectiveInputProfile' 'Deferred') }
        if ($mode -eq 'ok') { $apply += (Row 'PCSX2' 'InputProfile' 'Add'); $apply += (Row 'PCSX2' 'EffectiveInputProfile' 'UpdateOrRepair') }
        if ($mode -eq 'keep') { $apply += (Row 'PCSX2' 'InputProfile' 'PreserveUserModified') }
    }
    $plan = [pscustomobject]@{SchemaVersion=9;Succeeded=$true;ErrorCode='';ErrorMessage='';DryRun=[bool]$DryRun;Apply=[bool]$Apply;RealSystem=[bool]$RealSystem;Detected=$detected;Plan=@();ApplyResults=$apply;BveExCurrentInstalled=$true}
    [System.IO.File]::WriteAllText((Join-Path $OutputRoot 'install-plan.json'),($plan | ConvertTo-Json -Depth 8),(New-Object System.Text.UTF8Encoding($true)))
}
if ($DryRun) { Write-Plan $false; exit 0 }
[System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $sandbox 'engine.pid'), [string]$PID)
$state = [pscustomobject]@{SchemaVersion=1;StateRevision=2;ProductVersion='2.0.0';InstalledAt=[System.DateTimeOffset]::Now.ToString('o');Files=@()}
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'installed-state.json'),($state | ConvertTo-Json -Depth 4),(New-Object System.Text.UTF8Encoding($true)))
Write-Plan $true
exit 0
'@

function Get-GuiTexts([int]$ProcessId) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $names = New-Object System.Collections.ArrayList
    foreach ($w in (Get-GuiWindows $ProcessId)) { foreach ($e in @($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))) { [void]$names.Add([string]$e.Current.Name) } }
    return , [string[]]@($names)
}
function Invoke-Click($Ctx, [string]$Text, [int]$Timeout = 25) {
    $b = Wait-GuiButton $Ctx.Process.Id $Text $Timeout
    if ($null -eq $b) { return $false }
    Send-GuiClick $b
    return $true
}
function Run-Scenario([string]$Mode) {
    $root = New-I1Sandbox ('i2bgui-' + $Mode)
    try {
        [void](Initialize-GuiSandbox -Root $root)
        [System.IO.File]::WriteAllText((Join-Path $root 'installer\scripts\Invoke-DenGoInstaller.ps1'), $fakeInstaller, (New-Object System.Text.UTF8Encoding($false)))
        $resultDir = Join-Path $root 'result'; [System.IO.Directory]::CreateDirectory($resultDir) | Out-Null
        $resultPath = Join-Path $resultDir 'result.json'
        $runId = [System.Guid]::NewGuid().ToString('N')
        $proc = Start-GuiUnderTest -Root $root -GuiName 'DenGoInstallerGui.ps1' -Environment @{ DENGO_I2B_PCSX2 = $Mode } -ResultPath $resultPath -RunId $runId
        $ctx = @{ Process = $proc; Window = (Get-GuiMainWindow $proc.Id) }
        $out = @{ Reached = $false; Texts = @(); ExitCode = $null; Result = $null; Finished = $false }
        try {
            $ok = (Invoke-Click $ctx $script:UiText.Next)
            $out.Reached = ($ok -and ($null -ne (Wait-GuiButton $proc.Id $script:UiText.Search 90)))
            if ($out.Reached) {
                $out.Texts = Get-GuiTexts $proc.Id
                $out.Finished = ((Invoke-Click $ctx $script:UiText.Next) -and (Invoke-Click $ctx $script:UiText.Finish))
            }
            if ($proc.WaitForExit(30000)) { $out.ExitCode = [int]$proc.ExitCode }
            if ([System.IO.File]::Exists($resultPath)) { $out.Result = [System.IO.File]::ReadAllText($resultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
        } finally { try { if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } } catch { } }
        $out.RunId = $runId
        return $out
    } finally { Remove-I1Sandbox $root }
}

# ---------------------------------------------------------------- Deferred: the row says "not changed this time"
$d = Run-Scenario 'deferred'
Add-I1Result 'GUI-DEFERRED-01-result-page-reached' $d.Reached 'the wizard ran the dry run and the (fake) apply and showed the result page'
$hasDeferred = ($d.Texts -contains $deferredText)
Add-I1Result 'GUI-DEFERRED-02-row-text' $hasDeferred ("texts: " + ($d.Texts -join ' / '))
Add-I1Result 'GUI-DEFERRED-03-not-shown-as-set-up-and-not-as-failed' ((-not ($d.Texts -contains $okText)) -and (-not ($d.Texts -contains $failText))) 'neither "set up / usable" nor "failed to add"'
Add-I1Result 'GUI-DEFERRED-04-install-still-completed' (($d.ExitCode -eq 0) -and ($null -ne $d.Result) -and ($d.Result.result -eq 'Completed') -and ($d.Result.exitCode -eq 0) -and ($d.Result.engineStarted -eq $true) -and ($d.Result.engineCompleted -eq $true) -and ($d.Result.stateCommitted -eq $true) -and ($d.Result.runId -eq $d.RunId)) ("exit=$($d.ExitCode) result=$(if ($null -ne $d.Result) { $d.Result.result } else { 'none' }) flags=$(if ($null -ne $d.Result) { '' + $d.Result.engineStarted + '/' + $d.Result.engineCompleted + '/' + $d.Result.stateCommitted }): a Deferred PCSX2 does not fail the install and does not change the I1 outcome")
# the text must fit its cell (Windows Forms clips instead of wrapping inside a 26 px row): column 3 is 270 px wide minus 7 + 5 px padding
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)
$width = [System.Windows.Forms.TextRenderer]::MeasureText($deferredText, $font).Width
Add-I1Result 'GUI-DEFERRED-05-text-fits-the-cell' ($width -le 258) ("measured width $width px (cell text area 258 px)")

# ---------------------------------------------------------------- controls: the old rows are unchanged
$o = Run-Scenario 'ok'
Add-I1Result 'GUI-DEFERRED-06-control-applied-still-ok-row' ($o.Reached -and ($o.Texts -contains $okText) -and (-not ($o.Texts -contains $deferredText)) -and ($o.ExitCode -eq 0)) 'an applied PCSX2 still reads "set up / usable"'
$f = Run-Scenario 'fail'
Add-I1Result 'GUI-DEFERRED-07-control-missing-result-still-fail-row' ($f.Reached -and ($f.Texts -contains $failText) -and (-not ($f.Texts -contains $deferredText))) ("reached=$($f.Reached) texts: " + ($f.Texts -join ' / '))
$k = Run-Scenario 'keep'
Add-I1Result 'GUI-DEFERRED-08-control-preserved-still-warn-row' ($k.Reached -and ($k.Texts -contains $keepText) -and (-not ($k.Texts -contains $deferredText))) 'a preserved user profile still reads "using the existing setting"'
Complete-I1Tests
