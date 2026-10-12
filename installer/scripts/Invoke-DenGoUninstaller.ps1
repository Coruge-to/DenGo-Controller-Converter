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
if ($DryRun -and $Apply) { throw 'Specify either -DryRun or -Apply, not both.' }
if (-not $DryRun -and -not $Apply) { throw 'Specify -DryRun or -Apply.' }
if ($Apply -and -not $RealSystem) { throw '-Apply requires -RealSystem.' }
if ($RealSystem -and -not $Apply) { throw '-RealSystem requires -Apply.' }
if ($Apply -and -not [string]::Equals($ConfirmRealApply,'UNINSTALL',[System.StringComparison]::Ordinal)) { throw 'Real uninstall requires -ConfirmRealApply UNINSTALL.' }

$stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
$statePath = Join-Path $stateRoot 'installed-state.json'
if (-not [System.IO.File]::Exists($statePath)) { throw ('Installed state was not found: ' + $statePath) }
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

function Get-Sha256 {
    param([string]$Path)
    return ([string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
}

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
function Copy-Checked {
    param([string]$Source,[string]$Destination)
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Destination)) | Out-Null
    [System.IO.File]::Copy($Source,$Destination,$true)
    if (-not [string]::Equals((Get-Sha256 $Source),(Get-Sha256 $Destination),[System.StringComparison]::Ordinal)) { throw ('Copy SHA256 mismatch: ' + $Destination) }
}

$state = [System.IO.File]::ReadAllText($statePath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
if ([int]$state.SchemaVersion -ne 1) { throw 'Unsupported installed-state schema.' }
$items = New-Object System.Collections.ArrayList
foreach ($file in @($state.Files)) {
    $platform = [string]$file.Platform
    $component = [string]$file.Component
    $destination = [string]$file.Destination
    $ownership = [string]$file.Ownership
    $afterSha = [string]$file.AfterSHA256
    $beforeSha = [string]$file.BeforeSHA256
    $backup = [string]$file.Backup
    $isProfile = [string]::Equals($component,'InputProfile',[System.StringComparison]::Ordinal)
    $exists = [System.IO.File]::Exists($destination)
    $currentSha = ''
    if ($exists) { $currentSha = Get-Sha256 $destination }
    $action = 'UnsafeOrUnknown'
    $reason = ''

    if ($isProfile -and -not $IncludeInputProfiles) {
        $action = 'KeepProfile'
        $reason = 'Input profiles are preserved by default.'
    } elseif (-not $exists) {
        if ($ownership -in @('CreatedByInstaller','MigratedMatchingDenGoFile')) {
            $action = 'AlreadyMissing'
            $reason = 'The installer-managed file is already absent.'
        } else {
            $action = 'UnsafeOrUnknown'
            $reason = 'The destination is missing; no file will be recreated automatically.'
        }
    } elseif (-not [string]::Equals($currentSha,$afterSha,[System.StringComparison]::Ordinal)) {
        $action = 'PreserveModified'
        $reason = 'The current SHA256 differs from the installed SHA256.'
    } elseif ($ownership -in @('CreatedByInstaller','MigratedMatchingDenGoFile')) {
        $action = 'Remove'
        $reason = 'The current file matches the installer-managed SHA256.'
    } elseif ([string]::Equals($ownership,'ReplacedExisting',[System.StringComparison]::Ordinal)) {
        if ([string]::IsNullOrWhiteSpace($backup) -or -not [System.IO.File]::Exists($backup)) {
            $action = 'UnsafeOrUnknown'
            $reason = 'The original backup is missing.'
        } else {
            $backupSha = Get-Sha256 $backup
            if ([string]::Equals($backupSha,$beforeSha,[System.StringComparison]::Ordinal)) {
                $action = 'Restore'
                $reason = 'The current file matches the installed SHA256 and the original backup is valid.'
            } else {
                $action = 'UnsafeOrUnknown'
                $reason = 'The original backup SHA256 does not match the recorded SHA256.'
            }
        }
    } elseif ([string]::Equals($ownership,'PreservedUserFile',[System.StringComparison]::Ordinal)) {
        $action = 'PreserveModified'
        $reason = 'The installer explicitly preserved this user file.'
    } elseif ([string]::Equals($ownership,'NotInstalled',[System.StringComparison]::Ordinal) -or [string]::Equals($ownership,'NotManaged',[System.StringComparison]::Ordinal)) {
        $action = 'AlreadyMissing'
        $reason = 'The installer did not manage this item.'
    } else {
        $action = 'UnsafeOrUnknown'
        $reason = 'The ownership value is not recognized.'
    }

    [void]$items.Add([pscustomobject][ordered]@{
        Platform=$platform
        Component=$component
        Destination=$destination
        Ownership=$ownership
        Action=$action
        Exists=$exists
        CurrentSHA256=$currentSha
        InstalledSHA256=$afterSha
        BeforeSHA256=$beforeSha
        Backup=$backup
        Reason=$reason
    })
}

$shortcutItems = New-Object System.Collections.ArrayList
if ($null -ne $state.Shortcut -and [bool]$state.Shortcut.Created -and -not [string]::IsNullOrWhiteSpace([string]$state.Shortcut.Path)) {
    $shortcutPath = [string]$state.Shortcut.Path
    $shortcutExists = [System.IO.File]::Exists($shortcutPath)
    $shortcutAction = if ($shortcutExists) { 'Remove' } else { 'AlreadyMissing' }
    [void]$shortcutItems.Add([pscustomobject][ordered]@{Path=$shortcutPath;Action=$shortcutAction;Exists=$shortcutExists;Source='InstalledState'})
}
$coreItems = @($items | Where-Object {
    [string]::Equals([string]$_.Platform,'Core',[System.StringComparison]::Ordinal) -and
    [string]::Equals([string]$_.Component,'Application',[System.StringComparison]::Ordinal)
})
if (@($coreItems).Count -eq 1) {
    $desktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
    $defaultShortcutPath = Join-Path $desktopPath 'DenGo Controller Converter.lnk'
    $alreadyRecorded = @($shortcutItems | Where-Object { [string]::Equals([string]$_.Path,$defaultShortcutPath,[System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if (-not $alreadyRecorded -and [System.IO.File]::Exists($defaultShortcutPath)) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($defaultShortcutPath)
            $shortcutTarget = [System.IO.Path]::GetFullPath([string]$shortcut.TargetPath)
            $coreDestination = [System.IO.Path]::GetFullPath([string]$coreItems[0].Destination)
            if ([string]::Equals($shortcutTarget,$coreDestination,[System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$shortcutItems.Add([pscustomobject][ordered]@{Path=$defaultShortcutPath;Action='Remove';Exists=$true;Source='MatchingDefaultDesktopShortcut'})
            }
        } catch {
        }
    }
}

$applyResults = New-Object System.Collections.ArrayList
$rollbackRoot = ''
$succeeded = $true
$errorCode = ''
$errorMessage = ''
$rollbackAttempted = $false
$rollbackSucceeded = $true
$rollbackError = ''
if ($Apply -and $RealSystem) {
    Assert-TargetProcessesStopped
    $unsafe = @($items | Where-Object { [string]::Equals([string]$_.Action,'UnsafeOrUnknown',[System.StringComparison]::Ordinal) })
    if (@($unsafe).Count -ne 0) { throw 'UnsafeOrUnknown items were found. No uninstall changes were made.' }
    $rollbackRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\UninstallRollback') ([System.DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
    [System.IO.Directory]::CreateDirectory($rollbackRoot) | Out-Null
    $changed = New-Object System.Collections.ArrayList
    try {
        $orderedItems = @($items | Sort-Object @{Expression={if ([string]::Equals([string]$_.Platform,'Core',[System.StringComparison]::Ordinal)) { 1 } else { 0 }}},Platform,Component)
        foreach ($item in @($orderedItems)) {
            $action = [string]$item.Action
            $destination = [string]$item.Destination
            if ($action -in @('KeepProfile','PreserveModified','AlreadyMissing')) {
                [void]$applyResults.Add([pscustomobject]@{Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$destination;Changed=$false;Succeeded=$true})
                continue
            }
            if ([string]::Equals($action,'Remove',[System.StringComparison]::Ordinal)) {
                if (-not [System.IO.File]::Exists($destination)) { throw ('Remove target missing: ' + $destination) }
                $currentSha = Get-Sha256 $destination
                if (-not [string]::Equals($currentSha,[string]$item.InstalledSHA256,[System.StringComparison]::Ordinal)) { throw ('Remove SHA256 mismatch: ' + $destination) }
                $rollback = Join-Path $rollbackRoot ([System.Guid]::NewGuid().ToString('N') + '.bak')
                Copy-Checked $destination $rollback
                [System.IO.File]::Delete($destination)
                if ([System.IO.File]::Exists($destination)) { throw ('Remove verification failed: ' + $destination) }
                [void]$changed.Add([pscustomobject]@{Destination=$destination;Rollback=$rollback;ExpectedSHA256=$currentSha})
                [void]$applyResults.Add([pscustomobject]@{Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$destination;Changed=$true;Succeeded=$true;Rollback=$rollback})
                continue
            }
            if ([string]::Equals($action,'Restore',[System.StringComparison]::Ordinal)) {
                if (-not [System.IO.File]::Exists([string]$item.Backup)) { throw ('Restore backup missing: ' + [string]$item.Backup) }
                if (-not [string]::Equals((Get-Sha256 ([string]$item.Backup)),[string]$item.BeforeSHA256,[System.StringComparison]::Ordinal)) { throw ('Restore backup SHA256 mismatch: ' + [string]$item.Backup) }
                if (-not [System.IO.File]::Exists($destination)) { throw ('Restore target missing: ' + $destination) }
                if (-not [string]::Equals((Get-Sha256 $destination),[string]$item.InstalledSHA256,[System.StringComparison]::Ordinal)) { throw ('Restore target SHA256 mismatch: ' + $destination) }
                $rollback = Join-Path $rollbackRoot ([System.Guid]::NewGuid().ToString('N') + '.bak')
                Copy-Checked $destination $rollback
                Copy-Checked ([string]$item.Backup) $destination
                [void]$changed.Add([pscustomobject]@{Destination=$destination;Rollback=$rollback;ExpectedSHA256=(Get-Sha256 $rollback)})
                [void]$applyResults.Add([pscustomobject]@{Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$destination;Changed=$true;Succeeded=$true;Rollback=$rollback})
                continue
            }
            throw ('Unsupported real uninstall action: ' + $action)
        }
        foreach ($shortcut in @($shortcutItems)) {
            if ([string]::Equals([string]$shortcut.Action,'Remove',[System.StringComparison]::Ordinal) -and [System.IO.File]::Exists([string]$shortcut.Path)) { [System.IO.File]::Delete([string]$shortcut.Path) }
        }
        $completedState = [pscustomobject][ordered]@{SchemaVersion=1;ProductVersion=[string]$state.ProductVersion;State='Uninstalled';UninstalledAt=[System.DateTimeOffset]::Now.ToString('o');InputProfilesPreserved=(-not [bool]$IncludeInputProfiles);RollbackRoot=$rollbackRoot;Results=[object[]]@($applyResults)}
        $completedPath = Join-Path $stateRoot 'uninstalled-state.json'
        [System.IO.File]::WriteAllText($completedPath,($completedState | ConvertTo-Json -Depth 7),(New-Object System.Text.UTF8Encoding($true)))
    } catch {
        $succeeded = $false
        $errorCode = 'UninstallApplyFailed'
        $errorMessage = [string]$_.Exception.Message
        $rollbackAttempted = @($changed).Count -ne 0
        try {
            foreach ($change in @($changed | Sort-Object Destination -Descending)) { Copy-Checked ([string]$change.Rollback) ([string]$change.Destination) }
        } catch {
            $rollbackSucceeded = $false
            $rollbackError = [string]$_.Exception.Message
        }
    }
}

$result = [pscustomobject][ordered]@{
    SchemaVersion=1
    Generated=[System.DateTimeOffset]::Now.ToString('o')
    DryRun=[bool]$DryRun
    Apply=[bool]$Apply
    RealSystem=[bool]$RealSystem
    Succeeded=$succeeded
    ErrorCode=$errorCode
    ErrorMessage=$errorMessage
    RollbackAttempted=$rollbackAttempted
    RollbackSucceeded=$rollbackSucceeded
    RollbackError=$rollbackError
    RollbackRoot=$rollbackRoot
    IncludeInputProfiles=[bool]$IncludeInputProfiles
    InstalledStatePath=$statePath
    ProductVersion=[string]$state.ProductVersion
    Items=[object[]]@($items)
    Shortcuts=[object[]]@($shortcutItems)
    ApplyResults=[object[]]@($applyResults)
}
[System.IO.File]::WriteAllText($jsonOutput,($result | ConvertTo-Json -Depth 8),(New-Object System.Text.UTF8Encoding($true)))
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('DenGo uninstaller preview plan')
[void]$lines.Add(('Generated: ' + $result.Generated))
foreach ($item in @($items)) {
    [void]$lines.Add(("{0,-18} | {1,-12} | {2,-18} | {3}" -f $item.Platform,$item.Component,$item.Action,$item.Destination))
}
foreach ($shortcut in @($shortcutItems)) {
    [void]$lines.Add(("{0,-18} | {1,-12} | {2,-18} | {3}" -f 'Shortcut','Desktop',$shortcut.Action,$shortcut.Path))
}
if ($Apply) { [void]$lines.Add(('Real uninstall succeeded: ' + [string]$succeeded)) } else { [void]$lines.Add('No installed file, profile, shortcut, or backup was changed.') }
[System.IO.File]::WriteAllLines($textOutput,[string[]]@($lines),(New-Object System.Text.UTF8Encoding($true)))
Write-Host 'RESULT: SUCCESS'
Write-Host ('Plan items: ' + [string]@($items).Count)
Write-Host ('JSON: ' + $jsonOutput)
Write-Host ('Text: ' + $textOutput)
if ($Apply) { Write-Host ('Real uninstall succeeded: ' + [string]$succeeded); if (-not $succeeded) { exit 1 } } else { Write-Host 'Real system changes: NONE' }
