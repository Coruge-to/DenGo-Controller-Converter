param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$RealSystem,
    [string]$ConfirmRealApply = '',
    [switch]$IncludeInputProfiles,
    [string]$OutputRoot = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'DenGoUninstallerProductApply.ps1')
if ($DryRun -and $Apply) { throw 'Specify either -DryRun or -Apply, not both.' }
if (-not $DryRun -and -not $Apply) { throw 'Specify -DryRun or -Apply.' }
if ($Apply -and -not $RealSystem) { throw '-Apply requires -RealSystem.' }
if ($RealSystem -and -not $Apply) { throw '-RealSystem requires -Apply.' }
if ($Apply -and -not [string]::Equals($ConfirmRealApply,'UNINSTALL',[System.StringComparison]::Ordinal)) { throw 'Real uninstall requires -ConfirmRealApply UNINSTALL.' }

$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
$statePath = Join-Path $stateRoot 'installed-state.json'
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $env:TEMP 'DenGoUninstallerPreview'
} else {
    $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $OutputRoot.StartsWith($tempPrefix,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'OutputRoot must be under TEMP.' }
}
[System.IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$jsonOutput = Join-Path $OutputRoot 'uninstall-plan.json'
$textOutput = Join-Path $OutputRoot 'uninstall-plan.txt'

function Assert-TargetProcessesStopped {
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        [string]::Equals([string]$_.Name,'BveTs.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'rpcs3.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'DenGoControllerConverter.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.Name -match '(?i)\Apcsx2[^\\/]*[.]exe\z')
    })
    if (@($running).Count -ne 0) {
        $names = [string]::Join(', ',[string[]]@($running | ForEach-Object { [string]$_.Name } | Sort-Object -Unique))
        throw ("Close target processes before uninstall: {0}" -f $names)
    }
}

# I2-C: one all-or-nothing transaction (see DenGoUninstallerProductApply.ps1). The commit point is the atomic replace of uninstalled-state.json;
# installed-state.json is archived to history and deleted inside the same transaction. PCSX2 / LilyPad records are deferred to I3.
$productResult = $null
$productError = ''
try {
    $productLayout = Get-DenGoProductLayout -LocalAppData $env:LOCALAPPDATA -PublicRoot 'C:\Users\Public'
    $productOptions = @{ IncludeInputProfiles = [bool]$IncludeInputProfiles; ProcessGate = { Assert-TargetProcessesStopped } }
    if ($Apply -and $RealSystem) { $productResult = Invoke-DenGoProductUninstall -Layout $productLayout -Options $productOptions }
    else { $productResult = Get-DenGoUninstallDryRun -Layout $productLayout -Options $productOptions }
} catch {
    $productError = [string]$_.Exception.Message
}
if ($null -eq $productResult) {
    $productResult = DgU-NewResult
    $productResult.ErrorCode = 'ProductApplyFailed'
    $productResult.ErrorMessage = $productError
    $productResult.ManualCheckRequired = $true
}

$plan = $productResult.Plan
$itemRows = New-Object System.Collections.ArrayList
$shortcutRows = New-Object System.Collections.ArrayList
if ($null -ne $plan) {
    foreach ($d in @($plan.FileDecisions)) {
        [void]$itemRows.Add([pscustomobject][ordered]@{
            Platform=[string]$d.Platform; Component=[string]$d.Component; Destination=[string]$d.Destination; Ownership=[string]$d.Ownership
            Action=[string]$d.Decision; ReasonCode=[string]$d.ReasonCode; Exists=[bool]$d.Exists; CurrentSHA256=[string]$d.CurrentSha; InstalledSHA256=[string]$d.RecordedAfterSha
            BeforeSHA256=[string]$d.BeforeSha; Backup=[string]$d.Backup; Reason=[string]$d.Reason; Residual=[bool]$d.Residual })
    }
    foreach ($d in @($plan.ShortcutDecisions)) {
        [void]$shortcutRows.Add([pscustomobject][ordered]@{ Path=[string]$d.Destination; Action=[string]$d.Decision; Exists=[bool]$d.Exists; Source='InstalledState'; ReasonCode=[string]$d.ReasonCode; Role=[string]$d.Component })
    }
}
$planOnlyCodes = @('UnsafeOrUnknown','ContaminationBlocksRestore','ReplacedExistingBackupInvalid','ShortcutBackupInvalid','OwnedRootUnverified','HistoryArchiveCollision','RecoveryRequired','RecoveryCompletedOperationNotCompleted')
$succeeded = [bool]$productResult.Succeeded
$errorCode = [string]$productResult.ErrorCode
$errorMessage = [string]$productResult.ErrorMessage
if ($DryRun) {
    # a preview lists what would stop the uninstall; only a missing / unusable state is a failed preview
    $succeeded = ($errorCode.Length -eq 0) -or ($planOnlyCodes -contains $errorCode)
}
$reportPath = [string]$productResult.ReportPath
if ($reportPath.Length -gt 0 -and -not [System.IO.File]::Exists($reportPath)) { $reportPath = '' }
$counts = $productResult.Counts
$residual = [object[]]@($productResult.ResidualFiles)
$uninstalledState = $productResult.UninstalledState
$manualReasons = [string[]]@($productResult.ManualCheckReasons)
$transactionInfo = [pscustomobject][ordered]@{
    TransactionId=[string]$productResult.TransactionId; Code=[string]$productResult.TransactionCode; RollbackState=[string]$productResult.RollbackState; RecoveryOutcome=[string]$productResult.RecoveryOutcome
    FailedItem=[int]$productResult.FailedItem; StateCommitted=[bool]$productResult.StateCommitted; LockAcquired=[bool]$productResult.LockAcquired; Reasons=[object[]]@($productResult.Reasons) }
$result = [pscustomobject][ordered]@{
    SchemaVersion=1
    Generated=[System.DateTimeOffset]::Now.ToString('o')
    DryRun=[bool]$DryRun
    Apply=[bool]$Apply
    RealSystem=[bool]$RealSystem
    Succeeded=$succeeded
    ErrorCode=$errorCode
    ErrorMessage=$errorMessage
    RollbackAttempted=[bool]$productResult.RollbackAttempted
    RollbackSucceeded=[bool]$productResult.RollbackSucceeded
    RollbackError=[string]$productResult.RollbackError
    RollbackRoot=[string]$productResult.BackupRoot
    IncludeInputProfiles=[bool]$IncludeInputProfiles
    InstalledStatePath=$statePath
    UninstalledStatePath=(Join-Path $stateRoot 'uninstalled-state.json')
    ProductVersion=$(if ($null -ne $plan) { [string](DgProp $plan 'ProductVersion' '') } else { '' })
    AlreadyUninstalled=[bool]$productResult.AlreadyUninstalled
    ContaminationSuspect=[bool]$productResult.ContaminationSuspect
    ContaminationReasons=[string[]]@($productResult.ContaminationReasons)
    ManualCheckRequired=[bool]$productResult.ManualCheckRequired
    ManualCheckReasons=$manualReasons
    ReportPath=$reportPath
    ResidualFileCount=@($residual).Count
    ResidualFiles=$residual
    Counts=$counts
    Blocking=[object[]]@($productResult.Blocking | ForEach-Object { [pscustomobject][ordered]@{ Platform=[string]$_.Platform; Component=[string]$_.Component; Destination=[string]$_.Destination; Ownership=[string]$_.Ownership; Decision=[string]$_.Decision; ReasonCode=[string]$_.BlockCode; Reason=[string]$_.Reason; CurrentSHA256=[string]$_.CurrentSha; InstalledSHA256=[string]$_.RecordedAfterSha } })
    DeferredRecords=[object[]]@($productResult.DeferredRecords)
    Transaction=$transactionInfo
    Recovery=$productResult.Recovery
    Items=[object[]]@($itemRows)
    Shortcuts=[object[]]@($shortcutRows)
    ApplyResults=[object[]]@($productResult.Results)
}
[System.IO.File]::WriteAllText($jsonOutput,($result | ConvertTo-Json -Depth 9),(New-Object System.Text.UTF8Encoding($true)))
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('DenGo uninstaller preview plan')
[void]$lines.Add(('Generated: ' + $result.Generated))
foreach ($row in @($itemRows)) {
    [void]$lines.Add(("{0,-18} | {1,-12} | {2,-18} | {3}" -f $row.Platform,$row.Component,$row.Action,$row.Destination))
}
foreach ($row in @($shortcutRows)) {
    [void]$lines.Add(("{0,-18} | {1,-12} | {2,-18} | {3}" -f 'Shortcut','Desktop',$row.Action,$row.Path))
}
if ($errorCode.Length -gt 0) { [void]$lines.Add(('Result code: ' + $errorCode + ' ' + $errorMessage)) }
if ($Apply) { [void]$lines.Add(('Real uninstall succeeded: ' + [string]$succeeded)) } else { [void]$lines.Add('No installed file, profile, shortcut, or backup was changed.') }
[System.IO.File]::WriteAllLines($textOutput,[string[]]@($lines),(New-Object System.Text.UTF8Encoding($true)))
if ($succeeded) { Write-Host 'RESULT: SUCCESS' } else { Write-Host 'RESULT: FAILED' }
Write-Host ('Plan items: ' + [string]@($itemRows).Count)
Write-Host ('JSON: ' + $jsonOutput)
Write-Host ('Text: ' + $textOutput)
if ($Apply) { Write-Host ('Real uninstall succeeded: ' + [string]$succeeded); if (-not $succeeded) { exit 1 } } else { Write-Host 'Real system changes: NONE'; if (-not $succeeded) { exit 1 } }
