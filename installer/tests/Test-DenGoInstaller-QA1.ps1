$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$enginePath = Join-Path $repo 'installer\scripts\Invoke-DenGoInstaller.ps1'
$guiPath = Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1'
$reportPath = Join-Path $env:USERPROFILE 'Downloads\DenGo-QA1-ContractTests-v1.txt'
$results = New-Object System.Collections.ArrayList

function Add-TestResult {
    param([string]$Id,[string]$Name,[bool]$Passed,[string]$Detail)
    [void]$results.Add([pscustomobject]@{Id=$Id;Name=$Name;Passed=$Passed;Detail=$Detail})
}
function Get-IndexOrdinal {
    param([string]$Text,[string]$Value)
    return $Text.IndexOf($Value,[System.StringComparison]::Ordinal)
}

try {
    foreach ($path in @($enginePath,$guiPath)) {
        if (-not [System.IO.File]::Exists($path)) { throw ('Required file not found: ' + $path) }
        $tokens=$null
        $errors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Add-TestResult ('PARSE-' + [System.IO.Path]::GetFileName($path)) 'PowerShell parser' (@($errors).Count -eq 0) ('ParseErrorCount=' + [string]@($errors).Count)
    }

    $engine = [System.IO.File]::ReadAllText($enginePath,[System.Text.Encoding]::UTF8)
    $gui = [System.IO.File]::ReadAllText($guiPath,[System.Text.Encoding]::UTF8)

    $legacyDetection = Get-IndexOrdinal $engine "inis\LilyPad.ini"
    Add-TestResult 'PCSX2-L01' 'Legacy LilyPad detection remains' ($legacyDetection -ge 0) ('Index=' + [string]$legacyDetection)

    $currentIni = Get-IndexOrdinal $engine "inis\PCSX2.ini"
    $currentInputSources = Get-IndexOrdinal $engine '[InputSources]'
    $currentPad1 = Get-IndexOrdinal $engine '[Pad1]'
    Add-TestResult 'PCSX2-C01' 'Current PCSX2.ini detection exists' ($currentIni -ge 0 -and $currentInputSources -ge 0 -and $currentPad1 -ge 0) (("Ini={0};InputSources={1};Pad1={2}" -f $currentIni,$currentInputSources,$currentPad1))

    $qtExact = Get-IndexOrdinal $engine "pcsx2-qt.exe"
    $classicExact = Get-IndexOrdinal $engine "pcsx2.exe"
    $fallbackContains = Get-IndexOrdinal $engine "-match '(?i)pcsx2'"
    $fallbackExclusions = Get-IndexOrdinal $engine "(uninst|installer|setup|update)"
    Add-TestResult 'PCSX2-C02' 'Known names and safe fallback candidates exist' ($qtExact -ge 0 -and $classicExact -ge 0 -and $fallbackContains -ge 0 -and $fallbackExclusions -ge 0) (("Qt={0};Classic={1};Fallback={2};Exclusions={3}" -f $qtExact,$classicExact,$fallbackContains,$fallbackExclusions))

    $priorityNames = Get-IndexOrdinal $engine '$exactPCSX2Names = @(''pcsx2-qt.exe'',''pcsx2.exe'')'
    $priorityCandidates = Get-IndexOrdinal $engine '$exactPCSX2Candidates = @($candidates | Where-Object {'
    Add-TestResult 'PCSX2-C03' 'Exact PCSX2 names outrank fallback names' ($priorityNames -ge 0 -and $priorityCandidates -ge 0) (("Names={0};Candidates={1}" -f $priorityNames,$priorityCandidates))
    $uninstExclusion = Get-IndexOrdinal $engine '(uninst|installer|setup|update)'
    Add-TestResult 'PCSX2-C04' 'Installer uninstaller and updater names are excluded' ($uninstExclusion -ge 0) ('Index=' + [string]$uninstExclusion)
      $unsupportedMode = Get-IndexOrdinal $engine "CurrentIntegrated"
      $unsupportedStatus = Get-IndexOrdinal $engine "UnsupportedCurrent"
      $supportedList = Get-IndexOrdinal $engine '$supportedPcsx2 = @($pcsx2 | Where-Object {'
      Add-TestResult 'PCSX2-S01' 'Current PCSX2 is detected but unsupported' ($unsupportedMode -ge 0 -and $unsupportedStatus -ge 0) (("Mode={0};Status={1}" -f $unsupportedMode,$unsupportedStatus))
      Add-TestResult 'PCSX2-S02' 'Only supported legacy PCSX2 enters the plan' ($supportedList -ge 0) ('Index=' + [string]$supportedList)
      $message1 = Get-IndexOrdinal $gui 'PCSX2 ver1.7以降の新しい入力設定方式が検出されました'
      $message2 = Get-IndexOrdinal $gui '正式対応しているPCSX2はver1.6.0です'
      $message3 = Get-IndexOrdinal $gui '検出したPCSX2には対応していません'
      $openText = Get-IndexOrdinal $gui '配布ページを開く'
      $skipText = Get-IndexOrdinal $gui '設定をスキップ'
      $legacyUrl = Get-IndexOrdinal $gui 'https://forums.pcsx2.net/Thread-PCSX2-1-6-0-Standalone-Installer'
      Add-TestResult 'GUI-PCSX2-01' 'Unsupported PCSX2 message is exact' ($message1 -ge 0 -and $message2 -ge 0 -and $message3 -ge 0) (("Line1={0};Line2={1};Line3={2}" -f $message1,$message2,$message3))
      Add-TestResult 'GUI-PCSX2-02' 'Download and skip actions exist' ($openText -ge 0 -and $skipText -ge 0 -and $legacyUrl -ge 0) (("Open={0};Skip={1};Url={2}" -f $openText,$skipText,$legacyUrl))
      $unsupportedPreview = Get-IndexOrdinal $gui "PCSX2Unsupported"
      Add-TestResult 'GUI-PCSX2-03' 'Unsupported PCSX2 preview exists' ($unsupportedPreview -ge 0) ('Index=' + [string]$unsupportedPreview)
      $normalUnsupportedCall = Get-IndexOrdinal $gui 'if(-not$script:unsupportedPCSX2Shown-and(Has-UnsupportedCurrentPCSX2))'
      Add-TestResult 'GUI-PCSX2-04' 'Unsupported PCSX2 dialog is connected to normal detection flow' ($normalUnsupportedCall -ge 0) ('Index=' + [string]$normalUnsupportedCall)
      $bveMissingMessage1 = Get-IndexOrdinal $gui 'BveEXが見つかりません'
      $bveMissingMessage2 = Get-IndexOrdinal $gui 'BveEXを導入してからセットアップを再実行するか、'
      $bveMissingMessage3 = Get-IndexOrdinal $gui '設定をスキップしてください'
      $bveDownloadUrl = Get-IndexOrdinal $gui 'https://bveex.okaoka-depot.com/download'
      $bveMissingPreview = Get-IndexOrdinal $gui 'BveEXMissing'
      Add-TestResult 'GUI-BVEEX-01' 'Missing BveEX message is exact' ($bveMissingMessage1 -ge 0 -and $bveMissingMessage2 -ge 0 -and $bveMissingMessage3 -ge 0) (("Line1={0};Line2={1};Line3={2}" -f $bveMissingMessage1,$bveMissingMessage2,$bveMissingMessage3))
      Add-TestResult 'GUI-BVEEX-02' 'BveEX distribution and skip actions exist' ($bveDownloadUrl -ge 0 -and $openText -ge 0 -and $skipText -ge 0) (("Url={0};Open={1};Skip={2}" -f $bveDownloadUrl,$openText,$skipText))
      Add-TestResult 'GUI-BVEEX-03' 'Missing BveEX preview exists' ($bveMissingPreview -ge 0) ('Index=' + [string]$bveMissingPreview)
      $dependencyDialog = Get-IndexOrdinal $gui 'function Show-DependencyWarningDialog {'
      $taskDialogCall = Get-IndexOrdinal $gui 'TaskDialogIndirect'
      Add-TestResult 'GUI-DEPENDENCY-01' 'Dependency warnings use managed Windows Forms dialog' ($dependencyDialog -ge 0 -and $taskDialogCall -lt 0) (("Dialog={0};TaskDialog={1}" -f $dependencyDialog,$taskDialogCall))
      $skipSwitch = Get-IndexOrdinal $engine '[switch]$SkipBveIntegration'
      $currentFlag = Get-IndexOrdinal $engine 'BveExCurrentInstalled=[bool]$bveExCurrentInstalled'
      $correctLegacy = Get-IndexOrdinal $engine "C:\Users\Public\Documents\BveEx\Legacy\Extensions"
      $wrongLegacy = Get-IndexOrdinal $engine "C:\Users\Public\Documents\AtsEx\1.0\Extensions"
      Add-TestResult 'ENGINE-BVEEX-01' 'BVE integration can be skipped explicitly' ($skipSwitch -ge 0 -and $currentFlag -ge 0) (("Switch={0};Flag={1}" -f $skipSwitch,$currentFlag))
      Add-TestResult 'ENGINE-BVEEX-02' 'Legacy path is correct and old path is absent' ($correctLegacy -ge 0 -and $wrongLegacy -lt 0) (("Correct={0};Wrong={1}" -f $correctLegacy,$wrongLegacy))
    $assertIndex = Get-IndexOrdinal $engine 'Assert-TargetProcessesStopped'
    $gateOrder = & (Join-Path $PSScriptRoot 'QA1.ProcessGateOrder.ps1') -RepoRoot $repo
    Add-TestResult 'PROC-01' 'Process gate precedes the transaction Begin and the first disk change' ($assertIndex -ge 0 -and [bool]$gateOrder.Ok) (("Assert={0};{1}" -f $assertIndex,$gateOrder.Detail))

    $blockedCode = Get-IndexOrdinal $engine 'BlockedByRunningProcesses'
    $blockedProducts = Get-IndexOrdinal $engine 'RunningProducts='
    Add-TestResult 'PROC-02' 'Structured running-product result exists' ($blockedCode -ge 0 -and $blockedProducts -ge 0) (("Code={0};Products={1}" -f $blockedCode,$blockedProducts))

    $titleText = Get-IndexOrdinal $gui '対応ソフトが起動しています'
    $instructionText = Get-IndexOrdinal $gui '対応ソフトをすべて終了してから「再試行」を押してください'
    $productHeading = Get-IndexOrdinal $gui '起動中の対応ソフト：'
    Add-TestResult 'GUI-01' 'Friendly running-product message exists' ($titleText -ge 0 -and $instructionText -ge 0 -and $productHeading -ge 0) (("Title={0};Instruction={1};Heading={2}" -f $titleText,$instructionText,$productHeading))

    $retryCancel = Get-IndexOrdinal $gui 'MessageBoxButtons]::RetryCancel'
    $retryResult = Get-IndexOrdinal $gui 'DialogResult]::Retry'
    Add-TestResult 'GUI-02' 'Retry and cancel controls exist' ($retryCancel -ge 0 -and $retryResult -ge 0) (("RetryCancel={0};RetryResult={1}" -f $retryCancel,$retryResult))

    $productMapChecks = @(
        @('PCSX2','PCSX2'),
        @('DenGoControllerConverter.exe','DenGo Controller Converter'),
        @('BveTs.exe','BVE Trainsim'),
        @('rpcs3.exe','RPCS3')
    )
    $missingMaps = New-Object System.Collections.ArrayList
    foreach ($pair in $productMapChecks) {
        if ((Get-IndexOrdinal $engine ([string]$pair[0])) -lt 0 -or (Get-IndexOrdinal $engine ([string]$pair[1])) -lt 0) { [void]$missingMaps.Add([string]$pair[1]) }
    }
    Add-TestResult 'PROC-03' 'Process names map to product names' (@($missingMaps).Count -eq 0) ('Missing=' + [string]::Join(',', [string[]]@($missingMaps)))

    $passed = @($results | Where-Object { $_.Passed }).Count
    $failed = @($results | Where-Object { -not $_.Passed }).Count
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('DenGo QA1 contract tests')
    [void]$lines.Add('HEAD: ' + ([string](& git.exe -C $repo rev-parse HEAD)).Trim())
    [void]$lines.Add(("PASS={0} FAIL={1}" -f $passed,$failed))
    foreach ($result in $results) {
        $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
        [void]$lines.Add(("{0} | {1} | {2} | {3}" -f $status,$result.Id,$result.Name,$result.Detail))
    }
    [System.IO.File]::WriteAllLines($reportPath,[string[]]@($lines),(New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("PASS={0} FAIL={1}" -f $passed,$failed)
    Write-Host ('Report: ' + $reportPath)
    if ($failed -ne 0) { exit 2 }
    exit 0
} catch {
    Write-Host 'RESULT: ERROR'
    Write-Host ('Message: ' + [string]$_.Exception.Message)
    Write-Host ($_ | Out-String)
    exit 3
}
