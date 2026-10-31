# I3 GUI contract test (written RED first; owner decision DE-I3-5). The product GUI is NOT changed by the RED stage: this test fixes what the installer GUI must show for the four PCSX2 states.
#   supported                      PCSX2 1.6.0 (4 conditions): "set up / usable" (unchanged behaviour)
#   unsupported (1.7 or later/2.x) detected but not supported
#   unverified (x86, not on the allow list): the version cannot be confirmed, so it is not supported
#   ambiguous (several settings roots): several candidates, none can be chosen
# The real installer GUI script runs from a sandbox under TEMP with a fake engine (LOCALAPPDATA and TEMP point into the sandbox, process listing is hidden). Nothing real is installed.
# A version is never guessed: the unverified and ambiguous texts name no detected version (the supported version 1.6.0 may be named).
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')

$script:UiText['Search'] = (U 0x8FFD, 0x52A0, 0x306E, 0x74B0, 0x5883, 0x3092, 0x691C, 0x7D22)
$skipText = U 0x8A2D, 0x5B9A, 0x3092, 0x30B9, 0x30AD, 0x30C3, 0x30D7
$okText = U 0x8A2D, 0x5B9A, 0x6E08, 0x307F, 0x30FB, 0x5229, 0x7528, 0x53EF, 0x80FD
$failText = U 0x5165, 0x529B, 0x8A2D, 0x5B9A, 0x306E, 0x8FFD, 0x52A0, 0x306B, 0x5931, 0x6557, 0x3057, 0x307E, 0x3057, 0x305F
$noneText = U 0x898B, 0x3064, 0x304B, 0x308A, 0x307E, 0x305B, 0x3093, 0x3067, 0x3057, 0x305F
$wNotSupported = U 0x975E, 0x5BFE, 0x5FDC          # not supported
$wConfirm = U 0x78BA, 0x8A8D                        # confirm
$wSeveral = U 0x8907, 0x6570                        # several
$wChoose = U 0x9078, 0x629E                         # choose / select
$wLater = U 0x4EE5, 0x964D                          # "or later"

$fakeInstaller = @'
param([switch]$DryRun,[switch]$Apply,[switch]$RealSystem,[string]$ConfirmRealApply='',[string]$OutputRoot='',[switch]$AdditionalSearch,[switch]$CreateDesktopShortcut,[switch]$SkipBveIntegration,[switch]$ReplaceModifiedPCSX2Profile,[switch]$ReplaceModifiedRPCS3Profile)
$ErrorActionPreference = 'Stop'
$sandbox = $env:DENGO_I1_SANDBOX
$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
$mode = [System.Environment]::GetEnvironmentVariable('DENGO_I3_PCSX2'); if ([string]::IsNullOrEmpty($mode)) { $mode = 'supported' }
function Row($Platform, $Component, $Action) { return [pscustomobject]@{Set=$Platform;Platform=$Platform;Component=$Component;Action=$Action;Destination='x';Applied=($Action -eq 'Add');Backup='';Succeeded=$true;ErrorCode=''} }
function Det($Status, $State, $ModeText) { return [pscustomobject]@{Platform='PCSX2';Executable='x';State=$State;Mode=$ModeText;SupportStatus=$Status;InputDevices='';ProfileDirectory='';EffectiveInputProfile='';DetectionSource='test'} }
function Write-Plan([bool]$IsApply) {
    $detected = @()
    $resolution = $null
    if ($mode -eq 'supported') { $detected = @((Det 'Supported' 'Detected' 'Portable-LegacyLilyPad')) }
    if ($mode -eq 'unsupported') { $detected = @((Det 'UnsupportedCurrent' 'Detected' '')) }
    if ($mode -eq 'unverified') { $detected = @((Det 'UnsupportedUnverified' 'Detected' '')) }
    if ($mode -eq 'ambiguous') { $detected = @((Det 'Ambiguous' 'Detected' 'Portable-LegacyLilyPad'), (Det 'Ambiguous' 'Detected' 'CentralConfiguration-LegacyLilyPad')); $resolution = [pscustomobject]@{Status='Ambiguous';SelectedRoot='';Roots=@('A','B')} }
    $apply = @()
    if ($IsApply) {
        $apply = @((Row 'Core' 'Application' 'Add'))
        if ($mode -eq 'supported') { $apply += (Row 'PCSX2' 'InputProfile' 'Add'); $apply += (Row 'PCSX2' 'EffectiveInputProfile' 'UpdateOrRepair') }
    }
    $plan = [pscustomobject]@{SchemaVersion=9;Succeeded=$true;ErrorCode='';ErrorMessage='';DryRun=[bool]$DryRun;Apply=[bool]$Apply;RealSystem=[bool]$RealSystem;Detected=$detected;Plan=@();ApplyResults=$apply;BveExCurrentInstalled=$true;Pcsx2Resolution=$resolution}
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
    $root = New-I1Sandbox ('i3gui-' + $Mode)
    try {
        [void](Initialize-GuiSandbox -Root $root)
        [System.IO.File]::WriteAllText((Join-Path $root 'installer\scripts\Invoke-DenGoInstaller.ps1'), $fakeInstaller, (New-Object System.Text.UTF8Encoding($false)))
        $resultDir = Join-Path $root 'result'; [System.IO.Directory]::CreateDirectory($resultDir) | Out-Null
        $resultPath = Join-Path $resultDir 'result.json'
        $runId = [System.Guid]::NewGuid().ToString('N')
        $proc = Start-GuiUnderTest -Root $root -GuiName 'DenGoInstallerGui.ps1' -Environment @{ DENGO_I3_PCSX2 = $Mode } -ResultPath $resultPath -RunId $runId
        $ctx = @{ Process = $proc; Window = (Get-GuiMainWindow $proc.Id) }
        $out = @{ Reached = $false; Texts = @(); DialogTexts = @(); DialogSeen = $false; ExitCode = $null; Result = $null; Finished = $false; RunId = $runId }
        try {
            $ok = (Invoke-Click $ctx $script:UiText.Next)
            # a dialog (dependency warning) may open before the result page: its texts are collected, then the "skip" button closes it
            $deadline = [DateTime]::Now.AddSeconds(90)
            while ($ok -and [DateTime]::Now -lt $deadline) {
                if ($null -ne (Find-GuiButton $proc.Id $script:UiText.Search)) { $out.Reached = $true; break }
                $skip = Find-GuiButton $proc.Id $skipText
                if ($null -ne $skip) { $out.DialogSeen = $true; $out.DialogTexts = Get-GuiTexts $proc.Id; Send-GuiClick $skip; Start-Sleep -Milliseconds 400; continue }
                Start-Sleep -Milliseconds 200
            }
            if ($out.Reached) {
                $out.Texts = Get-GuiTexts $proc.Id
                $out.Finished = ((Invoke-Click $ctx $script:UiText.Next) -and (Invoke-Click $ctx $script:UiText.Finish))
            }
            if ($proc.WaitForExit(30000)) { $out.ExitCode = [int]$proc.ExitCode }
            if ([System.IO.File]::Exists($resultPath)) { $out.Result = [System.IO.File]::ReadAllText($resultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
        } finally { try { if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } } catch { } }
        return $out
    } finally { Remove-I1Sandbox $root }
}
# The state text of the PCSX2 row: the text right after the software name 'PCSX2'.
function Get-RowText($Texts) {
    $t = @($Texts)
    for ($i = 0; $i -lt $t.Count - 1; $i++) { if ($t[$i] -ceq 'PCSX2') { return [string]$t[$i + 1] } }
    return ''
}
function Test-Completed($S) { return (($S.ExitCode -eq 0) -and ($null -ne $S.Result) -and ($S.Result.result -eq 'Completed') -and ($S.Result.exitCode -eq 0) -and ($S.Result.runId -eq $S.RunId)) }
$guess = '1\.7|2\.\d|2\.x|[vV]er\s*2|' + $wLater

$sup = Run-Scenario 'supported'
$uns = Run-Scenario 'unsupported'
$unv = Run-Scenario 'unverified'
$amb = Run-Scenario 'ambiguous'
$rSup = Get-RowText $sup.Texts; $rUns = Get-RowText $uns.Texts; $rUnv = Get-RowText $unv.Texts; $rAmb = Get-RowText $amb.Texts

# I3-D (owner decision DE-I3-5): a supported PCSX2 1.6.0 reads "PCSX2 1.6.0 supported"; the former "set up / usable" is retired for the PCSX2 row
$supportedRow = 'PCSX2 1.6.0' + (U 0x5BFE, 0x5FDC)
Add-I1Result 'GUI-I3-01-supported-1.6.0-reads-set-up-and-usable' ($sup.Reached -and ($rSup -ceq $supportedRow) -and ($rSup -cne $okText) -and (Test-Completed $sup)) ("reached=$($sup.Reached) row=[$rSup]")
Add-I1Result 'GUI-I3-02-1.7-or-later-is-detected-but-not-supported' ($uns.Reached -and ($rUns.Length -gt 0) -and ($rUns -cne $failText) -and ($rUns -cne $noneText) -and $rUns.Contains($wNotSupported) -and (-not $rUns.Contains($wConfirm)) -and (-not $rUns.Contains($wSeveral))) ("reached=$($uns.Reached) row=[$rUns] dialog=$($uns.DialogSeen)")
Add-I1Result 'GUI-I3-03-an-unverified-x86-says-the-version-cannot-be-confirmed-so-it-is-not-supported' ($unv.Reached -and ($rUnv.Length -gt 0) -and ($rUnv -cne $failText) -and ($rUnv -cne $noneText) -and $rUnv.Contains($wConfirm) -and $rUnv.Contains($wNotSupported) -and (-not $rUnv.Contains($wSeveral))) ("reached=$($unv.Reached) row=[$rUnv] dialog=$($unv.DialogSeen)")
Add-I1Result 'GUI-I3-04-several-settings-roots-say-several-candidates-and-that-none-can-be-chosen' ($amb.Reached -and ($rAmb.Length -gt 0) -and ($rAmb -cne $failText) -and ($rAmb -cne $noneText) -and $rAmb.Contains($wSeveral) -and $rAmb.Contains($wChoose) -and (-not $rAmb.Contains($wConfirm))) ("reached=$($amb.Reached) row=[$rAmb] dialog=$($amb.DialogSeen)")
$rows = @($rSup, $rUns, $rUnv, $rAmb)
Add-I1Result 'GUI-I3-05-the-four-states-read-differently' (($rows | Where-Object { $_.Length -gt 0 } | Select-Object -Unique).Count -eq 4) ("rows: [" + ($rows -join '] [') + "]")
$unvTexts = @($unv.Texts) + @($unv.DialogTexts); $ambTexts = @($amb.Texts) + @($amb.DialogTexts)
$unvGuess = @($unvTexts | Where-Object { $_ -cmatch $guess }); $ambGuess = @($ambTexts | Where-Object { $_ -cmatch $guess })
Add-I1Result 'GUI-I3-06-no-version-is-guessed-for-an-unverified-or-ambiguous-PCSX2' ($unv.Reached -and $amb.Reached -and ($rUnv -cne $failText) -and ($rAmb -cne $failText) -and ($rUnv.Length -gt 0) -and ($rAmb.Length -gt 0) -and ($unvGuess.Count -eq 0) -and ($ambGuess.Count -eq 0)) ("guessing texts: unverified=[" + ($unvGuess -join ' / ') + "] ambiguous=[" + ($ambGuess -join ' / ') + "]")
Add-I1Result 'GUI-I3-07-an-unsupported-detection-never-fails-the-install' ((Test-Completed $uns) -and (Test-Completed $unv) -and (Test-Completed $amb)) ("exit codes: unsupported=$($uns.ExitCode) unverified=$($unv.ExitCode) ambiguous=$($amb.ExitCode)")
# the text must fit its cell (Windows Forms clips instead of wrapping inside a 26 px row): column 3 is 270 px wide minus 7 + 5 px padding
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)
$widths = @($rUns, $rUnv, $rAmb | Where-Object { $_.Length -gt 0 } | ForEach-Object { [System.Windows.Forms.TextRenderer]::MeasureText($_, $font).Width })
Add-I1Result 'GUI-I3-08-the-new-row-texts-fit-the-cell' (($widths.Count -eq 3) -and (@($rUns, $rUnv, $rAmb | Where-Object { $_ -ceq $failText }).Count -eq 0) -and (@($widths | Where-Object { $_ -gt 258 }).Count -eq 0)) ("measured widths: " + ($widths -join ',') + " px (cell text area 258 px)")

# ================================================================ I3-D: the agreed wording (DE-I3-5, owner decision) is exact, and no guessed version is shown on any display surface
#   Supported "PCSX2 1.6.0 supported" | UnsupportedCurrent "the detected PCSX2 is not supported" | UnsupportedUnverified "not supported because the version cannot be confirmed" | Ambiguous "several candidates, cannot be chosen"
#   forbidden words: ver1.7, 1.7, 2.x, ver2 and the Japanese "or later"
$wRowUnsupported = (U 0x691C, 0x51FA, 0x3057, 0x305F) + 'PCSX2' + (U 0x306F, 0x975E, 0x5BFE, 0x5FDC)
$wRowUnverified = U 0x7248, 0x3092, 0x78BA, 0x8A8D, 0x3067, 0x304D, 0x306A, 0x3044, 0x305F, 0x3081, 0x975E, 0x5BFE, 0x5FDC
$wRowAmbiguous = U 0x8907, 0x6570, 0x5019, 0x88DC, 0x306E, 0x305F, 0x3081, 0x9078, 0x629E, 0x3067, 0x304D, 0x306A, 0x3044
$wSupportedName = 'PCSX2 1.6.0' + (U 0x5BFE, 0x5FDC)
$forbiddenWords = 'ver1\.7|1\.7|2\.x|ver2|' + $wLater
Add-I1Result 'GUI-I3-09-the-three-result-rows-are-the-agreed-wording-exactly' ($sup.Reached -and ($rSup -ceq $wSupportedName) -and $uns.Reached -and $unv.Reached -and $amb.Reached -and ($rUns -ceq $wRowUnsupported) -and ($rUnv -ceq $wRowUnverified) -and ($rAmb -ceq $wRowAmbiguous)) ("rows: unsupported=[$rUns] unverified=[$rUnv] ambiguous=[$rAmb]")
$dlg = @($uns.DialogTexts | Where-Object { $_.Contains($wRowUnsupported) -and $_.Contains($wSupportedName) })
Add-I1Result 'GUI-I3-10-the-unsupported-dialog-says-the-detected-PCSX2-is-not-supported-and-that-1.6.0-is' ($uns.DialogSeen -and ($dlg.Count -ge 1)) ("dialog seen=$($uns.DialogSeen) texts=[" + (@($uns.DialogTexts) -join ' / ') + "]")
$everything = @(); foreach ($s in $sup, $uns, $unv, $amb) { $everything += @($s.Texts); $everything += @($s.DialogTexts) }
$guessAll = @($everything | Where-Object { $_ -cmatch $guess })
Add-I1Result 'GUI-I3-11-no-guessed-version-word-appears-in-any-of-the-four-states-row-or-dialog' ($sup.Reached -and $uns.Reached -and $unv.Reached -and $amb.Reached -and ($everything.Count -gt 10) -and ($guessAll.Count -eq 0)) ("texts checked: $($everything.Count); guessing texts: [" + ($guessAll -join ' / ') + "]")
# negative control: the detector itself. The retired wordings (row, dialog line, a bare version) must be caught, the agreed wordings must not.
$oldRow = 'ver1.7' + $wLater + (U 0x30FB) + (U 0x975E, 0x5BFE, 0x5FDC)
$oldDialog = 'PCSX2 ver1.7' + $wLater + (U 0x306E, 0x65B0, 0x3057, 0x3044, 0x5165, 0x529B, 0x8A2D, 0x5B9A, 0x65B9, 0x5F0F)
$mustCatch = @($oldRow, $oldDialog, '1.7', 'ver2', '2.x', 'PCSX2 2.0', $wLater)
$mustPass = @($wRowUnsupported, $wRowUnverified, $wRowAmbiguous, $wSupportedName, ($wRowUnsupported + "`r`n" + $wSupportedName))
$missedOld = @($mustCatch | Where-Object { $_ -cnotmatch $guess }); $falseHits = @($mustPass | Where-Object { $_ -cmatch $guess })
Add-I1Result 'GUI-I3-12-negative-control-a-reintroduced-version-word-is-detected-and-the-agreed-wording-is-not-flagged' (($missedOld.Count -eq 0) -and ($falseHits.Count -eq 0)) ("retired wordings not caught: $($missedOld.Count); agreed wordings wrongly flagged: $($falseHits.Count)")
# the same words must not exist anywhere in the source of either GUI script (a hidden or never-shown string would come back one day)
$srcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$srcHits = New-Object System.Collections.ArrayList
foreach ($rel in 'installer\gui\DenGoInstallerGui.ps1', 'installer\gui\DenGoUninstallerGui.ps1') {
    $txt = [System.IO.File]::ReadAllText((Join-Path $srcRoot $rel), [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($txt, $forbiddenWords)) { [void]$srcHits.Add($rel + ':' + $m.Value) }
}
$insTxt = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'installer\gui\DenGoInstallerGui.ps1'), [System.Text.Encoding]::UTF8)
$agreedPresent = @(@($wRowUnsupported, $wRowUnverified, $wRowAmbiguous, $wSupportedName) | Where-Object { $insTxt.IndexOf($_, [System.StringComparison]::Ordinal) -lt 0 }).Count -eq 0
Add-I1Result 'GUI-I3-13-the-GUI-sources-hold-the-agreed-wording-and-no-guessed-version-word' (($srcHits.Count -eq 0) -and $agreedPresent) ("forbidden words in the sources: [" + ($srcHits -join ', ') + "]; agreed wording present: $agreedPresent")
Complete-I1Tests
