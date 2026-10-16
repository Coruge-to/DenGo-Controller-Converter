# I2-C engine glue test: runs the REAL Invoke-DenGoUninstaller.ps1 as a child process whose LOCALAPPDATA / TEMP point into a sandbox
# (only the process listing is stubbed, so the engine never sees the user's real BVE / RPCS3 / DenGo processes). The plan only contains sandbox
# paths (BveEX Current / Legacy are left out: their folders are fixed literals under C:\Users\Public). The real DenGo data folder is
# fingerprinted (names, sizes, times - never read) before and after as evidence that nothing real was touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$engine = Join-Path $repo 'installer\scripts\Invoke-DenGoUninstaller.ps1'
$guiPath = Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)
Use-I2BProductIds

$stubNone = @'
function global:Get-CimInstance { param([Parameter(Position=0)][string]$ClassName) return @() }
& '__ENGINE__' @args
exit $LASTEXITCODE
'@
$stubRpcs3 = @'
function global:Get-CimInstance { param([Parameter(Position=0)][string]$ClassName) return @([pscustomobject]@{ Name = 'rpcs3.exe'; ExecutablePath = 'C:\fake\rpcs3.exe' }) }
& '__ENGINE__' @args
exit $LASTEXITCODE
'@
function Invoke-Engine($L, [string[]]$EngineArgs, [string]$Stub = 'none', [string]$OutName = 'out') {
    $dir = Join-Path $L.Root 'glue'
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $out = Join-Path $L.Root ('Temp\' + $OutName + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $script = Join-Path $dir 'engine-stub.ps1'
    $text = $(if ($Stub -eq 'rpcs3') { $stubRpcs3 } else { $stubNone }).Replace('__ENGINE__', $engine)
    [System.IO.File]::WriteAllText($script, $text, (New-Object System.Text.UTF8Encoding($true)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" ' + ([string]::Join(' ', $EngineArgs)).Replace('__OUT__', '"' + $out + '"')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $L.Local
    $psi.EnvironmentVariables['TEMP'] = (Join-Path $L.Root 'Temp')
    $psi.EnvironmentVariables['TMP'] = (Join-Path $L.Root 'Temp')
    $psi.EnvironmentVariables['APPDATA'] = (Join-Path $L.Root 'Roaming')
    [System.IO.Directory]::CreateDirectory((Join-Path $L.Root 'Temp')) | Out-Null
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync(); $stdout = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    $json = $null
    $jp = Join-Path $out 'uninstall-plan.json'
    if ([System.IO.File]::Exists($jp)) { $json = [System.IO.File]::ReadAllText($jp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Json = $json; Out = $stdout; Err = [string]$errTask.Result; OutDir = $out; JsonPath = $jp }
}
function New-GlueCase([string]$Name, [bool]$Shortcut = $true) {
    $L = New-I2CCase $Name
    $plan = Get-I2CPlatformPlan $L @('Core', 'BVE5', 'BVE6', 'RPCS3')
    $r = Invoke-I2BInstall $L $plan $Shortcut
    if (-not $r.Succeeded) { throw ('fixture install failed: ' + $r.ErrorCode + ' ' + $r.ErrorMessage) }
    return $L
}
function Get-GlueTree($L) { return (Get-I2CTreeNoTemp $L) }
function Get-I2CTreeNoTemp($L) {
    $map = Get-I2ATreeMap $L.Root @('temp', 'glue', 'tempstage', 'local\microsoft', 'local\dengo controller converter')
    $map['x:is'] = $(if ([System.IO.File]::Exists($L.Product.StatePath)) { Get-I2AFileSha $L.Product.StatePath } else { '<none>' })
    $map['x:us'] = $(if ([System.IO.File]::Exists((Get-I2CUsPath $L))) { if (Test-I2CUsValid $L) { 'NEW' } else { 'OTHER' } } else { '<none>' })
    $map['x:um'] = $(if ([System.IO.File]::Exists((Get-I2CUmPath $L))) { 'PRESENT' } else { '<none>' })
    return $map
}
function Get-DataTree($L) { return (Get-I2BFullTree $L) }
function Strip-Glue($m) { $c = @{}; foreach ($k in $m.Keys) { if (-not ($k -like '?:temp*' -or $k -like '?:glue*' -or $k -like '?:local\microsoft*')) { $c[$k] = $m[$k] } }; return $c }
function Get-RealFingerprint {
    $root = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter'
    if (-not [System.IO.Directory]::Exists($root)) { return '<none>' }
    $rows = foreach ($e in [System.IO.Directory]::GetFileSystemEntries($root, '*', [System.IO.SearchOption]::AllDirectories)) {
        $i = Get-Item -LiteralPath $e -Force
        $e.Substring($root.Length) + '|' + $(if ($i.PSIsContainer) { 'D' } else { [string]$i.Length }) + '|' + $i.LastWriteTimeUtc.Ticks
    }
    return [string]::Join(';', [string[]]@($rows))
}
$realBefore = Get-RealFingerprint
$legacyFields = @('SchemaVersion', 'Generated', 'DryRun', 'Apply', 'RealSystem', 'Succeeded', 'ErrorCode', 'ErrorMessage', 'RollbackAttempted', 'RollbackSucceeded', 'RollbackError', 'RollbackRoot', 'IncludeInputProfiles', 'InstalledStatePath', 'ProductVersion', 'Items', 'Shortcuts', 'ApplyResults')
$addedFields = @('UninstalledStatePath', 'AlreadyUninstalled', 'ContaminationSuspect', 'ManualCheckRequired', 'ManualCheckReasons', 'ReportPath', 'ResidualFileCount', 'ResidualFiles', 'Counts', 'Blocking', 'DeferredRecords', 'Transaction', 'Recovery')
# the GUI's own commit check, extracted from the GUI script (AST) so the real code is exercised against the engine's real output
$ast = Get-I2AScriptAst $guiPath
$fd = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-UninstallCommitted' }, $true))
[void](Assert-I2A 'G0-gui-commit-check-found' ($fd.Count -eq 1) 'Test-UninstallCommitted found once in the GUI')
Invoke-Expression $fd[0].Extent.Text
function Test-GuiCommit($L, $Json, [int]$ExitCode, [System.DateTimeOffset]$StartedAt) {
    $saved = $env:LOCALAPPDATA
    try { $env:LOCALAPPDATA = $L.Local; $script:applyStartedAt = $StartedAt; return (Test-UninstallCommitted $Json $ExitCode) } finally { $env:LOCALAPPDATA = $saved }
}
$apply = @('-Apply', '-RealSystem', '-ConfirmRealApply', 'UNINSTALL', '-IncludeInputProfiles', '-OutputRoot', '__OUT__')

try {
    # =================================================== G1 dry run
    $L = New-GlueCase 'glue1'
    try {
        $pre = Get-GlueTree $L
        $r = Invoke-Engine $L @('-DryRun', '-IncludeInputProfiles', '-OutputRoot', '__OUT__')
        $j = $r.Json
        [void](Assert-I2A 'G1-ran' (($r.ExitCode -eq 0) -and ($null -ne $j) -and ($j.Succeeded -eq $true) -and ($j.DryRun -eq $true) -and ($j.Apply -eq $false)) "exit=$($r.ExitCode) err=[$($r.Err.Trim())]")
        if ($null -ne $j) {
            $names = @($j.PSObject.Properties.Name)
            [void](Assert-I2A 'G1-existing-json-fields-kept' ((@($legacyFields | Where-Object { $names -notcontains $_ }).Count -eq 0)) ('missing: ' + (@($legacyFields | Where-Object { $names -notcontains $_ }) -join ',')))
            [void](Assert-I2A 'G1-additive-json-fields' ((@($addedFields | Where-Object { $names -notcontains $_ }).Count -eq 0)) ('missing: ' + (@($addedFields | Where-Object { $names -notcontains $_ }) -join ',')))
            [void](Assert-I2A 'G1-plan-listed' ((@($j.Items).Count -eq 5) -and (@($j.Items | Where-Object { $_.Action -eq 'Remove' }).Count -eq 4) -and (@($j.Items | Where-Object { $_.Action -eq 'Restore' }).Count -eq 1) -and (@($j.Shortcuts).Count -eq 1) -and ($j.Recovery.Outcome -eq 'NotNeeded') -and (@($j.Blocking).Count -eq 0)) "items=$(@($j.Items).Count) shortcuts=$(@($j.Shortcuts).Count) recovery=$($j.Recovery.Outcome)")
            [void](Assert-I2A 'G1-item-fields-as-before' ((@($j.Items | Where-Object { $null -eq $_.PSObject.Properties['Destination'] -or $null -eq $_.PSObject.Properties['CurrentSHA256'] -or $null -eq $_.PSObject.Properties['InstalledSHA256'] -or $null -eq $_.PSObject.Properties['Backup'] -or $null -eq $_.PSObject.Properties['Reason'] }).Count -eq 0)) 'Platform, Component, Destination, Ownership, Action, Exists, CurrentSHA256, InstalledSHA256, BeforeSHA256, Backup, Reason')
        }
        [void](Assert-I2A 'G1-dryrun-wrote-nothing' ((Same $pre (Get-GlueTree $L)) -and ($r.Out -like '*Real system changes: NONE*')) "no installed file, state, backup or journal changed (diff=[$(Diff3 $pre (Get-GlueTree $L))])")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G2 apply success
    $L = New-GlueCase 'glue2'
    try {
        $started = [System.DateTimeOffset]::Now.AddSeconds(-2)
        $isShaBefore = Get-I2AFileSha $L.Product.StatePath
        $ymlPath = Get-I2CLeafPath $L 'Den-Go-Controller.yml'
        $r = Invoke-Engine $L $apply
        $j = $r.Json
        [void](Assert-I2A 'G2-ran' (($r.ExitCode -eq 0) -and ($null -ne $j) -and ($j.Succeeded -eq $true) -and ($j.ErrorCode -eq '') -and ($j.Apply -eq $true) -and ($j.RealSystem -eq $true)) "exit=$($r.ExitCode) code=$(if ($null -ne $j) { $j.ErrorCode }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G2-state-retired-and-archived' ((-not [System.IO.File]::Exists($L.Product.StatePath)) -and (Test-I2CUsValid $L) -and (@(Get-I2CHistoryFiles $L ('installed-state.' + $isShaBefore.ToLowerInvariant() + '.json')).Count -eq 1) -and (-not [System.IO.File]::Exists((Get-I2CUmPath $L)))) 'installed-state archived under its SHA-256, uninstalled-state committed, no marker')
        [void](Assert-I2A 'G2-files-removed-profile-restored' ((-not [System.IO.File]::Exists($L.Product.AppExe)) -and (-not [System.IO.File]::Exists((Join-Path $L.Bve5 'Input Devices\DenGoControllerConverter.dll'))) -and ([System.IO.File]::ReadAllText($ymlPath) -eq 'user-original-yml') -and (-not [System.IO.File]::Exists($L.Product.ShortcutPath))) 'DenGo files and the shortcut are gone; the user''s profile is back')
        if ($null -ne $j) {
            [void](Assert-I2A 'G2-gui-commit-check-passes' (Test-GuiCommit $L $j $r.ExitCode $started) 'the real Test-UninstallCommitted of the GUI accepts the engine''s output and the committed state')
            [void](Assert-I2A 'G2-json-details' (($j.RollbackRoot -like '*InstallerBackups*') -and ($j.Transaction.StateCommitted -eq $true) -and ($j.Transaction.LockAcquired -eq $true) -and ($j.ReportPath -eq '') -and ($j.ResidualFileCount -eq 0) -and ($j.ManualCheckRequired -eq $false) -and ($j.Counts.Removed -eq 5) -and ($j.Counts.Restored -eq 1) -and (@($j.ApplyResults).Count -ge 6)) "rollbackRoot=$($j.RollbackRoot) counts=$($j.Counts.Removed)/$($j.Counts.Restored)")
        }
        # AlreadyUninstalled through the engine (the wrapper crashed before unregistering)
        $r2 = Invoke-Engine $L $apply 'none' 'again'
        [void](Assert-I2A 'G2-again-already-uninstalled-completes' (($r2.ExitCode -eq 0) -and ($r2.Json.Succeeded -eq $true) -and ($r2.Json.AlreadyUninstalled -eq $true)) "exit=$($r2.ExitCode) already=$(if ($null -ne $r2.Json) { $r2.Json.AlreadyUninstalled })")
        [void](Assert-I2A 'G2-again-gui-commit-check-passes' (Test-GuiCommit $L $r2.Json $r2.ExitCode ([System.DateTimeOffset]::Now.AddSeconds(-30))) 'the reconfirmed state carries a fresh UninstalledAt')
        [void](Assert-I2A 'G2-again-state-valid' ((Test-I2CUsValid $L) -and ((Get-I2CUs $L).Reconfirmation.Reconfirmed -eq $true)) 'reconfirmed')
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G3 a target process is running (process gate A)
    $L = New-GlueCase 'glue3'
    try {
        $pre = Get-GlueTree $L
        $r = Invoke-Engine $L $apply 'rpcs3'
        $j = $r.Json
        [void](Assert-I2A 'G3-process-gate' (($r.ExitCode -eq 1) -and ($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'BlockedByRunningProcesses') -and ($j.ErrorMessage -like '*rpcs3.exe*') -and (Same $pre (Get-GlueTree $L))) "exit=$($r.ExitCode) code=$(if ($null -ne $j) { $j.ErrorCode }): a result file is written (no more EngineNoResult) and nothing changed")
        [void](Assert-I2A 'G3-no-uninstalled-state-no-commit' ((-not (Test-I2CUsValid $L)) -and (-not (Test-GuiCommit $L $j $r.ExitCode ([System.DateTimeOffset]::Now.AddMinutes(-5))))) 'the GUI''s commit check refuses')
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G4 a real failure (read-only application file): everything is rolled back
    $L = New-GlueCase 'glue4'
    try {
        $pre = Get-GlueTree $L
        [System.IO.File]::SetAttributes($L.Product.AppExe, [System.IO.FileAttributes]::ReadOnly)
        try { $r = Invoke-Engine $L $apply } finally { [System.IO.File]::SetAttributes($L.Product.AppExe, [System.IO.FileAttributes]::Normal) }
        $j = $r.Json
        $post = Get-GlueTree $L
        [void](Assert-I2A 'G4-real-failure-result' (($r.ExitCode -eq 1) -and ($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'SetApplyFailed') -and ($j.RollbackAttempted -eq $true) -and ($j.RollbackSucceeded -eq $true) -and ($j.Transaction.RollbackState -eq 'RolledBack')) "exit=$($r.ExitCode) code=$(if ($null -ne $j) { $j.ErrorCode }) rb=$(if ($null -ne $j) { $j.Transaction.RollbackState }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G4-everything-restored' ((Same $pre $post) -and (-not (Test-I2CUsValid $L)) -and (-not [System.IO.File]::Exists((Get-I2CUmPath $L)))) "tree equal to before (diff=[$(Diff3 $pre $post)]); installed-state kept; no marker")
        [void](Assert-I2A 'G4-gui-refuses' (-not (Test-GuiCommit $L $j $r.ExitCode ([System.DateTimeOffset]::Now.AddMinutes(-5)))) 'exit code 1 and Succeeded=false: never a Completed')
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G5 nothing installed
    $L = New-GlueCase 'glue5'
    try {
        [System.IO.File]::Delete($L.Product.StatePath)
        $pre = Get-GlueTree $L
        $r = Invoke-Engine $L $apply
        $j = $r.Json
        [void](Assert-I2A 'G5-not-installed' (($r.ExitCode -eq 1) -and ($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'NotInstalled') -and ($j.ManualCheckRequired -eq $true) -and (Same $pre (Get-GlueTree $L))) "exit=$($r.ExitCode) code=$(if ($null -ne $j) { $j.ErrorCode }): a result file instead of an exception (the old L19 throw)")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G6 residuals that allow Completed
    $L = New-GlueCase 'glue6'
    try {
        $dll5 = Join-Path $L.Bve5 'Input Devices\DenGoControllerConverter.dll'
        [System.IO.File]::WriteAllText($dll5, 'the user''s own build', $script:Utf8)
        $sha = Get-I2AFileSha $dll5
        $r = Invoke-Engine $L $apply
        $j = $r.Json
        [void](Assert-I2A 'G6-completed-with-a-residual' (($r.ExitCode -eq 0) -and ($j.Succeeded -eq $true) -and ($j.ResidualFileCount -eq 1) -and ($j.ManualCheckRequired -eq $true) -and ($j.ResidualFiles[0].Path -eq $dll5) -and ((Get-I2AFileSha $dll5) -eq $sha)) "exit=$($r.ExitCode) residual=$($j.ResidualFileCount) manual=$($j.ManualCheckRequired); the edited file is byte-identical")
        [void](Assert-I2A 'G6-report-path-only-when-real' (($j.ReportPath -eq '')) 'no report exists, so none is named')
        [void](Assert-I2A 'G6-gui-check-still-completed' (Test-GuiCommit $L $j $r.ExitCode ([System.DateTimeOffset]::Now.AddSeconds(-60))) 'a residual does not change the I1 result (Completed)')
    } finally { Remove-I2ASandbox $L.Root }
    $L = New-GlueCase 'glue6b'
    try {
        $r = Invoke-Engine $L @('-Apply', '-RealSystem', '-ConfirmRealApply', 'UNINSTALL', '-OutputRoot', '__OUT__')
        $j = $r.Json
        $yml = Get-I2CLeafPath $L 'Den-Go-Controller.yml'
        [void](Assert-I2A 'G6b-profile-kept-without-the-switch' (($r.ExitCode -eq 0) -and ($j.Succeeded -eq $true) -and ($j.IncludeInputProfiles -eq $false) -and ($j.ResidualFileCount -eq 1) -and ($j.ManualCheckRequired -eq $false) -and ($j.ResidualFiles[0].Disposition -eq 'KeepProfile') -and [System.IO.File]::Exists($yml)) "residual=$($j.ResidualFileCount) disposition=$($j.ResidualFiles[0].Disposition)")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G7 blocking classes through the engine: exit 1, a result file, zero change
    $L = New-GlueCase 'glue7'
    try {
        Edit-I2CInstalledState $L { param($o) $r = Get-I2CRecord $o 'DenGoControllerConverter.exe' 'Core'; $r.Ownership = 'Mystery' }
        $pre = Get-GlueTree $L
        $dataPre = Get-DataTree $L
        $r = Invoke-Engine $L $apply
        $j = $r.Json
        [void](Assert-I2A 'G7-unsafe-or-unknown' (($r.ExitCode -eq 1) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'UnsafeOrUnknown') -and (@($j.Blocking).Count -eq 1) -and ($j.Blocking[0].ReasonCode -eq 'UnsafeOrUnknown') -and ($j.ManualCheckRequired -eq $true) -and (Same $pre (Get-GlueTree $L)) -and (Same (Strip-Glue $dataPre) (Strip-Glue (Get-DataTree $L)))) "code=$($j.ErrorCode) blocking=$(@($j.Blocking).Count); no change (installed files, state, backups, journals, markers)")
    } finally { Remove-I2ASandbox $L.Root }
    $L = New-GlueCase 'glue7b'
    try {
        [System.IO.File]::Delete((Join-Path $L.Bve5 'BveTs.exe'))
        $pre = Get-GlueTree $L
        $dataPre = Get-DataTree $L
        $r = Invoke-Engine $L $apply
        $j = $r.Json
        [void](Assert-I2A 'G7b-owned-root-unverified' (($r.ExitCode -eq 1) -and ($j.ErrorCode -eq 'OwnedRootUnverified') -and (Same $pre (Get-GlueTree $L)) -and (Same (Strip-Glue $dataPre) (Strip-Glue (Get-DataTree $L))) -and (-not (Test-GuiCommit $L $j $r.ExitCode ([System.DateTimeOffset]::Now.AddMinutes(-5))))) "code=$($j.ErrorCode): DenGo-owned file at an unproven root => Failed, nothing changed")
        $r2 = Invoke-Engine $L @('-DryRun', '-IncludeInputProfiles', '-OutputRoot', '__OUT__')
        [void](Assert-I2A 'G7b-dryrun-lists-the-block-and-still-previews' (($r2.ExitCode -eq 0) -and ($r2.Json.Succeeded -eq $true) -and ($r2.Json.ErrorCode -eq 'OwnedRootUnverified') -and (@($r2.Json.Items | Where-Object { $_.Action -eq 'PreserveUnverified' }).Count -eq 1)) "dry run: exit=$($r2.ExitCode) code=$($r2.Json.ErrorCode)")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G8 argument guards stay as they were
    $L = New-GlueCase 'glue8'
    try {
        $pre = Get-GlueTree $L
        $cases = @(
            @('apply-without-realsystem', @('-Apply', '-ConfirmRealApply', 'UNINSTALL', '-OutputRoot', '__OUT__')),
            @('realsystem-without-apply', @('-RealSystem', '-DryRun', '-OutputRoot', '__OUT__')),
            @('dryrun-and-apply', @('-DryRun', '-Apply', '-OutputRoot', '__OUT__')),
            @('no-mode', @('-OutputRoot', '__OUT__')),
            @('no-confirmation', @('-Apply', '-RealSystem', '-OutputRoot', '__OUT__')),
            @('wrong-confirmation', @('-Apply', '-RealSystem', '-ConfirmRealApply', 'uninstall', '-OutputRoot', '__OUT__')),
            @('output-outside-temp', @('-DryRun', '-OutputRoot', ('"' + (Join-Path $L.Root 'NotTemp') + '"'))))
        foreach ($c in $cases) {
            $r = Invoke-Engine $L $c[1]
            [void](Assert-I2A ('G8-guard-' + $c[0]) (($r.ExitCode -ne 0) -and (Same $pre (Get-GlueTree $L))) "exit=$($r.ExitCode): refused, nothing changed")
        }
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G9 the real data folder was not touched
    $realAfter = Get-RealFingerprint
    [void](Assert-I2A 'G9-real-denGo-data-folder-untouched' ($realBefore -eq $realAfter) 'names, sizes and times of the real %LOCALAPPDATA%\DenGo Controller Converter tree are identical before and after (nothing was read or written)')
} finally { }
Complete-I2ATests
