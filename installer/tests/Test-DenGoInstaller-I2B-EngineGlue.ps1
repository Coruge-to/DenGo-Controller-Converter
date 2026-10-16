# I2-B engine glue test: runs the REAL statements of Invoke-DenGoInstaller.ps1 that follow the plan (the apply / dry-run if-chain and the result object),
# extracted from the script by its syntax tree, in a child process whose LOCALAPPDATA / TEMP point into a sandbox. The detection part of the engine
# (which scans the user's disks) is not run, and the plan only contains sandbox paths (BveEX Current / Legacy are left out: their folders are fixed
# literals under C:\Users\Public). The real installed-state.json is hashed before and after as evidence that nothing real was touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$engine = Join-Path $repo 'installer\scripts\Invoke-DenGoInstaller.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)
Use-I2BProductIds     # no harness here: the real id generator runs

# ---- pull the glue out of the engine
$ast = Get-I2AScriptAst $engine
$src = [System.IO.File]::ReadAllText($engine, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$top = @($ast.EndBlock.Statements)
$first = @($top | Where-Object { $_.Extent.Text.StartsWith('$applyResults = [object[]]@()', [System.StringComparison]::Ordinal) })
$resultStmt = @($top | Where-Object { $_.Extent.Text.StartsWith('$result=[pscustomobject]@{SchemaVersion=9;', [System.StringComparison]::Ordinal) })
[void](Assert-I2A 'G0-glue-statements-found' (($first.Count -eq 1) -and ($resultStmt.Count -eq 1)) "first=$($first.Count) result=$($resultStmt.Count)")
$glue = $src.Substring($first[0].Extent.StartOffset, $resultStmt[0].Extent.EndOffset - $first[0].Extent.StartOffset)
$functions = New-Object System.Text.StringBuilder
foreach ($name in 'Get-RunningTargetProducts', 'Assert-TargetProcessesStopped', 'Resolve-DesktopShortcutPath') {
    $fd = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))
    [void](Assert-I2A "G0-function-$name" ($fd.Count -eq 1) 'found once in the engine')
    [void]$functions.AppendLine($fd[0].Extent.Text)
}
$template = @'
param([string]$ArgsFile, [string]$OutFile)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. '__CORE__'
. '__PRODUCT__'
if ($env:DENGO_TEST_TXN_PATTERN) {      # G6 / G7 only: a journal written by the fault harness carries test transaction ids; everything else is the real product layer
    $script:origLayoutFn = ${function:Get-DenGoProductLayout}
    function Get-DenGoProductLayout { param([string]$LocalAppData,[string]$PublicRoot = 'C:\Users\Public',[string]$ShortcutPath = '',[string]$BackupRoot = '',[string]$TxnIdPattern = '') return (& $script:origLayoutFn -LocalAppData $LocalAppData -PublicRoot $PublicRoot -ShortcutPath $ShortcutPath -BackupRoot $BackupRoot -TxnIdPattern $env:DENGO_TEST_TXN_PATTERN) }
}
__FUNCTIONS__
function global:Get-CimInstance { param([Parameter(Position=0)][string]$ClassName) return @() }
$cfg = [System.IO.File]::ReadAllText($ArgsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$Apply = [bool]$cfg.Apply; $RealSystem = [bool]$cfg.RealSystem; $DryRun = [bool]$cfg.DryRun
$CreateDesktopShortcut = [bool]$cfg.Shortcut; $ShortcutPathOverride = [string]$cfg.ShortcutPath; $BackupRootOverride = ''
$TestRoot = ''; $SkipBveIntegration = $false; $AdditionalSearch = $false; $ReplaceModifiedPCSX2Profile = $false; $ReplaceModifiedRPCS3Profile = $true
$interruptedInstallDetected = $false; $bveExCurrentInstalled = $false; $bveExLegacyInstalled = $false; $outputRoot = 'unused'
$detected = [object[]]@()
$plan = [object[]]@($cfg.Plan)
__GLUE__
[System.IO.File]::WriteAllText($OutFile, ($result | ConvertTo-Json -Depth 9), (New-Object System.Text.UTF8Encoding($false)))
'@
$childText = $template.Replace('__CORE__', (Join-Path $repo 'installer\scripts\DenGoInstallerTransaction.ps1')).Replace('__PRODUCT__', (Join-Path $repo 'installer\scripts\DenGoInstallerProductApply.ps1')).Replace('__FUNCTIONS__', $functions.ToString()).Replace('__GLUE__', $glue)

$realStatePath = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState\installed-state.json'
$realBefore = $(if ([System.IO.File]::Exists($realStatePath)) { Get-I2AFileSha $realStatePath } else { '<none>' })
$realRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter'
$realListBefore = $(if ([System.IO.Directory]::Exists($realRoot)) { [string]::Join('|', [string[]]@([System.IO.Directory]::GetFileSystemEntries($realRoot, '*', [System.IO.SearchOption]::AllDirectories))) } else { '<none>' })

function Get-GluePlan($L, [string]$Scenario) {
    # the plan the engine would build for sandbox paths: no BveEX Current / Legacy items
    return , [object[]]@((Get-I2BPlan $L $Scenario) | Where-Object { $_.Platform -notin @('BveEX Current', 'AtsEX Legacy') })
}
function Invoke-Glue($L, [hashtable]$Cfg, [string]$TxnPattern = '') {
    $dir = Join-Path $L.Root 'glue'
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $script = Join-Path $dir 'glue.ps1'
    [System.IO.File]::WriteAllText($script, $childText, (New-Object System.Text.UTF8Encoding($true)))
    $argsFile = Join-Path $dir 'args.json'; $out = Join-Path $dir 'result.json'
    if ([System.IO.File]::Exists($out)) { [System.IO.File]::Delete($out) }
    [System.IO.File]::WriteAllText($argsFile, (ConvertTo-Json -InputObject $Cfg -Depth 6), $utf8)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -ArgsFile "' + $argsFile + '" -OutFile "' + $out + '"'
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $L.Local
    $psi.EnvironmentVariables['TEMP'] = (Join-Path $L.Root 'Temp')
    $psi.EnvironmentVariables['TMP'] = (Join-Path $L.Root 'Temp')
    $psi.EnvironmentVariables['APPDATA'] = (Join-Path $L.Root 'Roaming')
    if ($TxnPattern.Length -gt 0) { $psi.EnvironmentVariables['DENGO_TEST_TXN_PATTERN'] = $TxnPattern }
    [System.IO.Directory]::CreateDirectory((Join-Path $L.Root 'Temp')) | Out-Null
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync(); $stdout = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    $json = $null
    if ([System.IO.File]::Exists($out)) { $json = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Json = $json; Err = [string]$errTask.Result }
}
function New-GlueCase([string]$Name, [string]$Scenario) {
    $L = New-I2BScenario $Name $Scenario
    # the child's TEMP is <root>\Temp (the stage folder lives there); keep the tree comparison independent of it
    return $L
}
$legacyFields = @('SchemaVersion', 'Generated', 'InterruptedInstallDetected', 'Succeeded', 'ErrorCode', 'ErrorMessage', 'FailedSet', 'RollbackAttempted', 'RollbackSucceeded', 'RollbackError', 'ShortcutRequested', 'ShortcutCreated', 'ShortcutPath', 'ShortcutError', 'DryRun', 'Apply', 'RealSystem', 'AdditionalSearch', 'BveExCurrentInstalled', 'BveExLegacyInstalled', 'BveIntegrationSkipped', 'TestRoot', 'OutputRoot', 'BackupRoot', 'ReplacementDecisions', 'Detected', 'Plan', 'ApplyResults')
function Get-GlueTree($L) { $m = Get-I2ATreeMap $L.Root @('local\dengo controller converter', 'local\microsoft', 'temp', 'glue'); return $m }

try {
    # =================================================== G1 a real-system apply through the engine glue
    $L = New-GlueCase 'glue1' 'P1'
    try {
        $scPath = Join-Path $L.Root 'Temp\DenGo Controller Converter.lnk'
        [System.IO.Directory]::CreateDirectory((Join-Path $L.Root 'Temp')) | Out-Null
        $plan = Get-GluePlan $L 'P1'
        $pre = Get-GlueTree $L
        $r = Invoke-Glue $L @{ Apply = $true; RealSystem = $true; DryRun = $false; Shortcut = $true; ShortcutPath = $scPath; Plan = $plan }
        $j = $r.Json
        [void](Assert-I2A 'G1-ran' (($r.ExitCode -eq 0) -and ($null -ne $j)) "exit=$($r.ExitCode) err=[$($r.Err.Trim())]")
        if ($null -ne $j) {
            $names = @($j.PSObject.Properties.Name)
            $missing = @($legacyFields | Where-Object { $names -notcontains $_ })
            [void](Assert-I2A 'G1-existing-json-fields-kept' ($missing.Count -eq 0) ('missing: ' + ($missing -join ',')))
            [void](Assert-I2A 'G1-additive-json-fields' (($names -contains 'Transaction') -and ($names -contains 'Recovery') -and ($names -contains 'DeferredItems')) ('fields: Transaction, Recovery, DeferredItems'))
            [void](Assert-I2A 'G1-succeeded' (($j.Succeeded -eq $true) -and ($j.ErrorCode -eq '') -and ($j.Transaction.StateCommitted -eq $true) -and ($j.Transaction.LockAcquired -eq $true) -and ($j.Recovery.Outcome -eq 'NotNeeded')) "Succeeded=$($j.Succeeded) code=[$($j.ErrorCode)] tx=$($j.Transaction.TransactionId)")
            $deferred = @($j.ApplyResults | Where-Object { $_.Action -eq 'Deferred' })
            [void](Assert-I2A 'G1-pcsx2-deferred-in-apply-results' (($deferred.Count -eq 2) -and ($j.DeferredItems.Count -eq 2) -and (@($j.ApplyResults | Where-Object { $_.Platform -eq 'Core' -and $_.Component -eq 'Application' }).Count -eq 1)) "deferred rows=$($deferred.Count); one Core/Application row")
            [void](Assert-I2A 'G1-shortcut-and-backup-fields' (($j.ShortcutRequested -eq $true) -and ($j.ShortcutCreated -eq $true) -and ($j.ShortcutPath -eq $scPath) -and ([System.IO.File]::Exists($scPath)) -and ($j.BackupRoot -like '*InstallerBackups*')) "shortcut=$($j.ShortcutCreated) path=$($j.ShortcutPath) backupRoot=$($j.BackupRoot)")
            $stateOk = $false; $stateObj = $null
            if ([System.IO.File]::Exists($L.Product.StatePath)) { $stateObj = [System.IO.File]::ReadAllText($L.Product.StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json; $stateOk = (($stateObj.SchemaVersion -eq 1) -and ($stateObj.StateRevision -eq 2) -and ($stateObj.TransactionId -eq $j.Transaction.TransactionId)) }
            # the exact conditions the GUI checks for a committed install (DenGoInstallerGui.ps1 Test-ApplyCommitted)
            $guiOk = ($stateOk -and (-not [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json'))) -and ([System.DateTimeOffset]::Parse([string]$stateObj.InstalledAt, [System.Globalization.CultureInfo]::InvariantCulture) -ge [System.DateTimeOffset]::Parse([string]$j.Generated, [System.Globalization.CultureInfo]::InvariantCulture).AddMinutes(-5)))
            [void](Assert-I2A 'G1-state-satisfies-the-gui-commit-check' $guiOk 'SchemaVersion 1, StateRevision 2, no marker, InstalledAt set')
        }
        $post = Get-GlueTree $L
        $changed = @(Compare-I2ATree $pre $post | Where-Object { $_ -notlike '*d:*' })
        [void](Assert-I2A 'G1-pcsx2-files-untouched' (@(Compare-I2ATree $pre $post | Where-Object { $_ -match 'pcsx2' }).Count -eq 0) 'no PCSX2 / LilyPad file was created or changed')
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G2 a REAL failure (read-only destination, no fault harness): everything is restored
    $L = New-GlueCase 'glue2' 'P2'
    try {
        $scPath = Join-Path $L.Root 'Temp\DenGo Controller Converter.lnk'
        [System.IO.Directory]::CreateDirectory((Join-Path $L.Root 'Temp')) | Out-Null
        $plan = Get-GluePlan $L 'P2'
        $bve6 = Join-Path $L.Bve6 'Input Devices\DenGoControllerConverter.dll'
        [System.IO.File]::SetAttributes($bve6, [System.IO.FileAttributes]::ReadOnly)
        try {
            $pre = Get-GlueTree $L
            $stateBefore = Get-I2AFileSha $L.Product.StatePath
            $r = Invoke-Glue $L @{ Apply = $true; RealSystem = $true; DryRun = $false; Shortcut = $true; ShortcutPath = $scPath; Plan = $plan }
            $j = $r.Json
            $post = Get-GlueTree $L
        } finally { [System.IO.File]::SetAttributes($bve6, [System.IO.FileAttributes]::Normal) }
        [void](Assert-I2A 'G2-real-failure-result' (($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'SetApplyFailed') -and ($j.FailedSet -eq 'BVE6') -and ($j.RollbackAttempted -eq $true) -and ($j.RollbackSucceeded -eq $true) -and ($j.Transaction.RollbackState -eq 'RolledBack')) "code=$(if ($null -ne $j) { $j.ErrorCode }) failedSet=$(if ($null -ne $j) { $j.FailedSet }) rb=$(if ($null -ne $j) { $j.Transaction.RollbackState }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G2-everything-restored' ((Same $pre $post) -and ((Get-I2AFileSha $L.Product.StatePath) -eq $stateBefore) -and (-not [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json')))) "tree equal to before (diff=[$(Diff3 $pre $post)]); state untouched; no marker")
        [void](Assert-I2A 'G2-apply-results-have-no-committed-rows' (($null -ne $j) -and (@($j.ApplyResults).Count -eq 1) -and ($j.ApplyResults[0].Action -eq 'Failed')) 'the failure replaces the result rows, as before')
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G3 the lock is held by another operation: nothing is written
    $L = New-GlueCase 'glue3' 'P2'
    try {
        $plan = Get-GluePlan $L 'P2'
        $prodHold = DgLock-TryAcquire 'Global\DenGoControllerConverter.Transaction' 'Explicit'      # the I2-D contract name (the engine child process takes the product name, not the per-process test name)
        try {
            $pre = Get-I2BFullTree $L
            $r = Invoke-Glue $L @{ Apply = $true; RealSystem = $true; DryRun = $false; Shortcut = $false; ShortcutPath = ''; Plan = $plan }
            $j = $r.Json
            $post = Get-I2BFullTree $L
        } finally { [void](DgLock-Release 'Global\DenGoControllerConverter.Transaction') }
        $glueDiff = @(Compare-I2ATree $pre $post | Where-Object { $_ -notlike '*glue*' -and $_ -notlike '*temp*' -and $_ -notlike '*local\microsoft*' })
        [void](Assert-I2A 'G3-busy-result' (($prodHold.Acquired -eq $true) -and ($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'AnotherOperationRunning') -and ($j.Transaction.LockAcquired -eq $false)) "code=$(if ($null -ne $j) { $j.ErrorCode }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G3-busy-writes-nothing' ($glueDiff.Count -eq 0) "no journal, marker, report, backup or state change (diff=[$($glueDiff -join ' ')])")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G4 an old-format installing.json: RepairRequired, nothing touched
    $L = New-GlueCase 'glue4' 'P2'
    try {
        $plan = Get-GluePlan $L 'P2'
        [System.IO.File]::WriteAllText((Join-Path $L.Product.StateRoot 'installing.json'), '{"SchemaVersion":1,"ProductVersion":"2.0.0","State":"Installing","Started":"2026-01-01T00:00:00+09:00"}', $utf8)
        $pre = Get-I2BFullTree $L
        $r = Invoke-Glue $L @{ Apply = $true; RealSystem = $true; DryRun = $false; Shortcut = $true; ShortcutPath = (Join-Path $L.Root 'Temp\x.lnk'); Plan = $plan }
        $j = $r.Json
        $post = Get-I2BFullTree $L
        $glueDiff = @(Compare-I2ATree $pre $post | Where-Object { $_ -notlike '*glue*' -and $_ -notlike '*temp*' -and $_ -notlike '*local\microsoft*' })
        [void](Assert-I2A 'G4-legacy-marker' (($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'RecoveryRequired') -and ($j.Recovery.Reasons[0].Code -eq 'LegacyMarkerUnsupported') -and ($j.Transaction.ManualCheckRequired -eq $true) -and (@($j.ApplyResults).Count -eq 0)) "code=$(if ($null -ne $j) { $j.ErrorCode }) reason=$(if ($null -ne $j) { $j.Recovery.Reasons[0].Code })")
        [void](Assert-I2A 'G4-nothing-touched' (($glueDiff.Count -eq 0) -and [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json'))) "the old marker stays; diff=[$($glueDiff -join ' ')]")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G5 the dry-run branch: a read-only report, no lock, no write
    $L = New-GlueCase 'glue5' 'P2'
    try {
        $plan = Get-GluePlan $L 'P2'
        $pre = Get-I2BFullTree $L
        $r = Invoke-Glue $L @{ Apply = $false; RealSystem = $false; DryRun = $true; Shortcut = $false; ShortcutPath = ''; Plan = $plan }
        $j = $r.Json
        $post = Get-I2BFullTree $L
        $glueDiff = @(Compare-I2ATree $pre $post | Where-Object { $_ -notlike '*glue*' -and $_ -notlike '*temp*' -and $_ -notlike '*local\microsoft*' })
        [void](Assert-I2A 'G5-dryrun-recovery-report' (($null -ne $j) -and ($j.Recovery.Outcome -eq 'NotNeeded') -and ($j.Succeeded -eq $true) -and ($j.Apply -eq $false)) "outcome=$(if ($null -ne $j) { $j.Recovery.Outcome }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G5-dryrun-writes-nothing' ($glueDiff.Count -eq 0) "diff=[$($glueDiff -join ' ')]")
    } finally { Remove-I2ASandbox $L.Root }

    # =================================================== G6 / G7 the real engine statements recover an interrupted install that included the Desktop shortcut,
    # although this run asks for no shortcut (the default of the GUI: -CreateDesktopShortcut is absent, the layout has no ShortcutPath).
    # The interruption is made in this process with the fault harness (test transaction ids); the engine runs in a child process.
    function New-InterruptedShortcutInstall([string]$Name) {
        Use-I2BHarnessIds
        $Lx = New-GlueCase $Name 'P2'
        $planX = Get-GluePlan $Lx 'P2'
        $preX = Get-I2ATreeMap $Lx.Root @('local\dengo controller converter', 'tempstage', 'temp', 'glue', 'local\microsoft')
        $stateX = Get-I2AFileSha $Lx.Product.StatePath
        Install-I2AHarness
        try {
            Reset-I2AFault -CrashPattern '^after:Journal:Verified#3$' -CrashNth 1; Reset-I2ACounters
            try { $null = Invoke-I2BInstall $Lx $planX $true } catch { }
            Resume-I2AAfterCrash
        } finally { Uninstall-I2AHarness; Use-I2BProductIds }
        return [pscustomobject]@{ L = $Lx; Plan = $planX; Pre = $preX; State = $stateX }
    }
    function Get-GlueTree2($Lx) { return (Get-I2ATreeMap $Lx.Root @('local\dengo controller converter', 'tempstage', 'temp', 'glue', 'local\microsoft')) }
    $g6 = New-InterruptedShortcutInstall 'glue6'
    try {
        $L = $g6.L; $P = $L.Product
        $jrnl = @(Get-ChildItem -LiteralPath (Join-Path $P.StateRoot 'txn') -Recurse -Filter 'journal.jsonl')
        $scReg = @((DgJournal-Parse $jrnl[0].FullName).Records | Where-Object { $_.stage -eq 'Register' -and ([string]$_.path) -like '*.lnk' })
        [void](Assert-I2A 'G6-the-interrupted-journal-has-a-shortcut-item' (($jrnl.Count -eq 1) -and ($scReg.Count -eq 1) -and ($scReg[0].tag -eq ('Shortcut|Desktop|Shortcut|' + (DgP-Full $L.Desktop))) -and [System.IO.File]::Exists((Join-Path $P.StateRoot 'installing.json'))) "marker + journal; tag=$(if ($scReg.Count -eq 1) { $scReg[0].tag })")
        $r = Invoke-Glue $L @{ Apply = $true; RealSystem = $true; DryRun = $false; Shortcut = $false; ShortcutPath = ''; Plan = $g6.Plan } '^T[0-9]{4}$'
        $j = $r.Json
        $post = Get-GlueTree2 $L
        [void](Assert-I2A 'G6-recovered-without-the-shortcut-option' (($r.ExitCode -eq 0) -and ($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and ($j.Recovery.Outcome -eq 'RolledBack') -and ($j.Transaction.RecoveryOutcome -eq 'RolledBack') -and ($j.ShortcutRequested -eq $false)) "exit=$($r.ExitCode) code=$(if ($null -ne $j) { $j.ErrorCode }) outcome=$(if ($null -ne $j) { $j.Recovery.Outcome }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G6-back-to-the-tree-before-the-install' ((Same $g6.Pre $post) -and ((Get-I2AFileSha $P.StatePath) -eq $g6.State) -and (-not [System.IO.File]::Exists((Join-Path $P.StateRoot 'installing.json'))) -and (-not [System.IO.File]::Exists($P.ShortcutPath))) "tree equal to before the install (diff=[$(Diff3 $g6.Pre $post)]); the applied shortcut is gone; state untouched; no marker")
    } finally { Remove-I2ASandbox $g6.L.Root }
    $g7 = New-InterruptedShortcutInstall 'glue7'
    try {
        $L = $g7.L; $P = $L.Product
        [System.IO.File]::WriteAllText($P.AppIco, 'TAMPERED-BY-ANOTHER-PROGRAM', $utf8)
        $before = Get-I2BFullTree $L
        $r = Invoke-Glue $L @{ Apply = $true; RealSystem = $true; DryRun = $false; Shortcut = $false; ShortcutPath = ''; Plan = $g7.Plan } '^T[0-9]{4}$'
        $j = $r.Json
        $after = Get-I2BFullTree $L
        $diff = @(Compare-I2ATree $before $after | Where-Object { $_ -notlike '*glue*' -and $_ -notlike '*temp*' -and $_ -notlike '*local\microsoft*' })
        $rp = $(if ($null -ne $j) { [string]$j.Transaction.ReportPath } else { '' })
        $codes = @(); if ($null -ne $j) { $codes = @($j.Transaction.Reasons | ForEach-Object { [string]$_.Code }) }
        [void](Assert-I2A 'G7-engine-json-keeps-every-recovery-fact' (($null -ne $j) -and ($j.Succeeded -eq $false) -and ($j.ErrorCode -eq 'RecoveryRequired') -and ($j.Transaction.ManualCheckRequired -eq $true) -and ($j.Transaction.RecoveryOutcome -eq 'RepairRequired') -and ($j.Recovery.Outcome -eq 'RepairRequired') -and ($codes -contains 'DestinationUnknownSha') -and ([string]$j.Transaction.TransactionId -eq 'T0001') -and ($j.Transaction.RollbackState -eq 'NotStarted')) "code=$(if ($null -ne $j) { $j.ErrorCode }) outcome=$(if ($null -ne $j) { $j.Transaction.RecoveryOutcome }) reasons=[$($codes -join ',')] tx=$(if ($null -ne $j) { $j.Transaction.TransactionId }) err=[$($r.Err.Trim())]")
        [void](Assert-I2A 'G7-engine-json-report-path-reaches-the-report' (($rp.Length -gt 0) -and [System.IO.File]::Exists($rp) -and ($rp -eq [string]$j.Recovery.ReportPath) -and ($rp -eq (Join-Path $P.StateRoot 'txn\T0001\recovery-report.txt')) -and ([System.IO.File]::ReadAllText($rp).Contains('TransactionId: T0001')) -and ([System.IO.File]::ReadAllText($rp).Contains('Reason: DestinationUnknownSha'))) "ReportPath in the JSON = [$rp]")
        [void](Assert-I2A 'G7-only-the-report-was-written' (($diff.Count -eq 1) -and ($diff[0] -like '+f:*recovery-report.txt') -and [System.IO.File]::Exists((Join-Path $P.StateRoot 'installing.json'))) "diff=[$($diff -join ' ')]: nothing but recovery-report.txt, the marker and the journal remain")
    } finally { Remove-I2ASandbox $g7.L.Root }
} finally {
    $realAfter = $(if ([System.IO.File]::Exists($realStatePath)) { Get-I2AFileSha $realStatePath } else { '<none>' })
    $realListAfter = $(if ([System.IO.Directory]::Exists($realRoot)) { [string]::Join('|', [string[]]@([System.IO.Directory]::GetFileSystemEntries($realRoot, '*', [System.IO.SearchOption]::AllDirectories))) } else { '<none>' })
    [void](Assert-I2A 'G9-the-real-installer-state-was-not-touched' (($realBefore -eq $realAfter) -and ($realListBefore -eq $realListAfter)) "real installed-state.json: $realBefore -> $realAfter; the real DenGo data folder listing is unchanged: $($realListBefore -eq $realListAfter)")
}
Complete-I2ATests
