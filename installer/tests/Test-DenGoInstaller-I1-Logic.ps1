# I1 logic tests: handlers and functions are extracted from the real scripts with the PowerShell AST and run against mocks.
# Covers FormClosing for every CloseReason, result-file writing and invariants, committed-state checks, sticky Failed,
# and exit-code propagation of the Start scripts (T4). Writes only below a sandbox under TEMP.
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')
Add-Type -AssemblyName System.Windows.Forms

$installerGui = Join-Path $script:I1Repo 'installer\gui\DenGoInstallerGui.ps1'
$uninstallerGui = Join-Path $script:I1Repo 'installer\gui\DenGoUninstallerGui.ps1'
$sandbox = New-I1Sandbox 'logic'
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = (Join-Path $sandbox 'LocalAppData')

# ---- mocks used by the extracted handlers ----
$script:confirmCalls = 0; $script:confirmAnswer = $true; $script:stopCalls = 0
function Confirm-SetupCancel { $script:confirmCalls++; return $script:confirmAnswer }
function Confirm-Cancel { $script:confirmCalls++; return $script:confirmAnswer }

function Reset-State([string]$Result = 'Failed', [bool]$Applying = $false, [bool]$AllowClose = $false, [string]$Reason = 'NotCompleted') {
    $script:finalResult = $Result; $script:finalReason = $Reason
    $script:applyRunning = $Applying; $script:allowClose = $AllowClose
    $script:engineStarted = $false; $script:engineCompleted = $false; $script:stateCommitted = $false
    $script:applyStartedAt = [System.DateTimeOffset]::MinValue
    $script:confirmCalls = 0; $script:stopCalls = 0; $script:confirmAnswer = $true
    $script:errorShown = 0; $script:errorText = ''
}
function Test-Pristine { return ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'NotCompleted') }
function Show-GuiError { param([string]$Text) $script:errorShown++; $script:errorText = $Text }
function Invoke-Closing($Handler, [string]$Reason) {
    $e = [pscustomobject]@{ CloseReason = [System.Windows.Forms.CloseReason]$Reason; Cancel = $false }
    $e | ForEach-Object -Process $Handler | Out-Null
    return $e
}

$reasons = 'UserClosing', 'WindowsShutDown', 'TaskManagerClosing', 'ApplicationExitCall', 'FormOwnerClosing', 'MdiFormClosing', 'None'
$nonUser = @($reasons | Where-Object { $_ -ne 'UserClosing' })

try {
    foreach ($gui in @(@{ Tag = 'INSTALLER'; Path = $installerGui }, @{ Tag = 'UNINSTALLER'; Path = $uninstallerGui })) {
        $tag = $gui.Tag
        . ([scriptblock]::Create((Get-FunctionText $gui.Path @('Set-RunFailed', 'Set-RunCancelled', 'Invoke-UnhandledGuiException'))))
        function Stop-CurrentProcess { $script:stopCalls++ }
        $handler = Get-EventHandlerBlock $gui.Path 'Add_FormClosing'

        # ---- Cancelled is reachable only from the pristine pre-apply state ----
        Reset-State
        Add-I1Result "$tag-INITIAL-STATE-IS-FAILED" ((Test-Pristine) -and $script:engineStarted -eq $false) 'a fresh run is Failed/NotCompleted until something proves otherwise'
        Set-RunCancelled
        Add-I1Result "$tag-SET-CANCELLED-FROM-PRISTINE" ($script:finalResult -eq 'Cancelled' -and $script:finalReason -eq 'UserCancelled') "result=$($script:finalResult)/$($script:finalReason)"
        foreach ($case in @(@('Failed', 'EngineFailed'), @('Failed', 'DryRunFailed'), @('Failed', 'UnhandledException'), @('Completed', 'Completed'))) {
            Reset-State $case[0] $false $false $case[1]
            Set-RunCancelled
            Add-I1Result "$tag-SET-CANCELLED-IGNORED-AFTER-$($case[0].ToUpper())-$($case[1].ToUpper())" ($script:finalResult -eq $case[0] -and $script:finalReason -eq $case[1]) "result=$($script:finalResult)/$($script:finalReason)"
        }
        Reset-State; $script:engineStarted = $true; Set-RunCancelled
        Add-I1Result "$tag-SET-CANCELLED-IGNORED-AFTER-ENGINE-START" ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'NotCompleted') "result=$($script:finalResult)/$($script:finalReason)"

        # ---- unexpected handler exceptions are Failed, and never downgrade a committed Completed ----
        Reset-State
        Invoke-UnhandledGuiException (New-Object System.InvalidOperationException('boom-detail'))
        Add-I1Result "$tag-UNHANDLED-EXCEPTION-IS-FAILED" ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'UnhandledException' -and $script:errorShown -eq 1 -and $script:errorText.Contains('boom-detail')) "result=$($script:finalResult)/$($script:finalReason) shown=$($script:errorShown)"
        Set-RunCancelled
        Add-I1Result "$tag-UNHANDLED-EXCEPTION-THEN-CANCEL-STAYS-FAILED" ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'UnhandledException') "result=$($script:finalResult)/$($script:finalReason)"
        Reset-State 'Completed' $false $false 'Completed'
        Invoke-UnhandledGuiException (New-Object System.InvalidOperationException('late'))
        Add-I1Result "$tag-UNHANDLED-EXCEPTION-KEEPS-COMPLETED" ($script:finalResult -eq 'Completed' -and $script:finalReason -eq 'Completed') "result=$($script:finalResult)/$($script:finalReason)"
        Reset-State 'Failed' $false $false 'EngineFailed'
        Invoke-UnhandledGuiException (New-Object System.InvalidOperationException('later'))
        Add-I1Result "$tag-UNHANDLED-EXCEPTION-KEEPS-SPECIFIC-REASON" ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'EngineFailed') "result=$($script:finalResult)/$($script:finalReason)"

        # ---- applying: only UserClosing is blocked, and nothing about the result changes ----
        Reset-State 'Failed' $true
        $e = Invoke-Closing $handler 'UserClosing'
        Add-I1Result "$tag-CLOSING-APPLYING-USERCLOSING-BLOCKED" ($e.Cancel -eq $true -and $script:confirmCalls -eq 0 -and $script:stopCalls -eq 0 -and (Test-Pristine)) "cancel=$($e.Cancel) confirm=$($script:confirmCalls) stop=$($script:stopCalls) result=$($script:finalResult)/$($script:finalReason)"
        Reset-State 'Completed' $true $false 'Initial'
        $e = Invoke-Closing $handler 'UserClosing'
        Add-I1Result "$tag-CLOSING-APPLYING-USERCLOSING-KEEPS-RESULT" ($e.Cancel -eq $true -and $script:finalResult -eq 'Completed' -and $script:finalReason -eq 'Initial') "result=$($script:finalResult)"
        foreach ($reason in $nonUser) {
            Reset-State 'Failed' $true
            $e = Invoke-Closing $handler $reason
            Add-I1Result "$tag-CLOSING-APPLYING-$($reason.ToUpper())-NOT-BLOCKED" ($e.Cancel -eq $false -and $script:confirmCalls -eq 0 -and $script:stopCalls -eq 0 -and $script:finalResult -eq 'Failed' -and $script:finalReason -eq 'GuiClosedDuringApply') "cancel=$($e.Cancel) confirm=$($script:confirmCalls) stop=$($script:stopCalls) result=$($script:finalResult)/$($script:finalReason)"
        }

        # ---- not applying: only a confirmed UserClosing cancels; every other reason leaves Failed/NotCompleted ----
        Reset-State; $script:confirmAnswer = $true
        $e = Invoke-Closing $handler 'UserClosing'
        Add-I1Result "$tag-CLOSING-IDLE-USERCLOSING-YES-IS-CANCELLED" ($script:confirmCalls -eq 1 -and $e.Cancel -eq $false -and $script:finalResult -eq 'Cancelled' -and $script:finalReason -eq 'UserCancelled') "cancel=$($e.Cancel) confirm=$($script:confirmCalls) result=$($script:finalResult)/$($script:finalReason)"
        Reset-State; $script:confirmAnswer = $false
        $e = Invoke-Closing $handler 'UserClosing'
        Add-I1Result "$tag-CLOSING-IDLE-USERCLOSING-NO-KEEPS-WINDOW-AND-FAILED" ($script:confirmCalls -eq 1 -and $e.Cancel -eq $true -and (Test-Pristine)) "cancel=$($e.Cancel) confirm=$($script:confirmCalls) result=$($script:finalResult)/$($script:finalReason)"
        foreach ($reason in $nonUser) {
            Reset-State
            $e = Invoke-Closing $handler $reason
            Add-I1Result "$tag-CLOSING-IDLE-$($reason.ToUpper())-NOT-BLOCKED-AND-NOT-CANCELLED" ($e.Cancel -eq $false -and $script:confirmCalls -eq 0 -and (Test-Pristine)) "cancel=$($e.Cancel) confirm=$($script:confirmCalls) result=$($script:finalResult)/$($script:finalReason)"
        }
        foreach ($answer in $true, $false) {
            Reset-State 'Failed' $false $false 'EngineFailed'; $script:confirmAnswer = $answer
            $e = Invoke-Closing $handler 'UserClosing'
            Add-I1Result "$tag-CLOSING-AFTER-FAILURE-CONFIRM-$answer-STAYS-FAILED" ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'EngineFailed' -and $e.Cancel -eq (-not $answer)) "cancel=$($e.Cancel) result=$($script:finalResult)/$($script:finalReason)"
        }
        Reset-State 'Completed' $false $false 'Completed'
        $e = Invoke-Closing $handler 'UserClosing'
        Add-I1Result "$tag-CLOSING-AFTER-SUCCESS-NO-PROMPT" ($e.Cancel -eq $false -and $script:confirmCalls -eq 0 -and $script:finalResult -eq 'Completed') "confirm=$($script:confirmCalls) result=$($script:finalResult)"
        Reset-State 'Failed' $false $true
        $e = Invoke-Closing $handler 'UserClosing'
        Add-I1Result "$tag-CLOSING-ALLOWCLOSE-PASSES" ($e.Cancel -eq $false -and $script:confirmCalls -eq 0 -and (Test-Pristine)) "confirm=$($script:confirmCalls) result=$($script:finalResult)/$($script:finalReason)"
    }

    # ---- real Stop-CurrentProcess must never touch the engine while applying ----
    . ([scriptblock]::Create((Get-FunctionText $installerGui @('Stop-CurrentProcess'))))
    $timer = [pscustomobject]@{}; Add-Member -InputObject $timer -MemberType ScriptMethod -Name Stop -Value { $script:timerStopped = $true }
    foreach ($applying in $true, $false) {
        $script:killed = $false
        $fake = [pscustomobject]@{ HasExited = $false }
        Add-Member -InputObject $fake -MemberType ScriptMethod -Name Kill -Value { $script:killed = $true; $this.HasExited = $true }
        Add-Member -InputObject $fake -MemberType ScriptMethod -Name WaitForExit -Value { }
        Add-Member -InputObject $fake -MemberType ScriptMethod -Name Dispose -Value { }
        $script:process = $fake; $script:applyRunning = $applying
        Stop-CurrentProcess
        Add-I1Result "INSTALLER-STOP-CURRENT-PROCESS-APPLYING-$applying" ($script:killed -eq (-not $applying)) "killed=$($script:killed)"
    }

    # ---- sticky Failed / Completed transitions (installer state machine) ----
    . ([scriptblock]::Create((Get-FunctionText $installerGui @('Set-RunFailed', 'Set-RunFailure', 'Set-RunCompleted', 'Set-RunCancelled'))))
    Reset-State
    Set-RunFailure $false 'Failed'
    $a = ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'DryRunFailed')
    Set-RunFailure $true 'Failed'
    $b = ($script:finalResult -eq 'Failed' -and $script:finalReason -eq 'EngineFailed')
    $script:engineStarted = $true; Set-RunCompleted
    $c = ($script:finalResult -eq 'Completed' -and $script:engineCompleted -and $script:stateCommitted)
    Set-RunFailure $false 'Failed'
    $d = ($script:finalResult -eq 'Completed' -and $script:engineCompleted -and $script:stateCommitted)   # a later failed search does not undo a committed install
    Set-RunFailure $true 'Failed'
    $f = ($script:finalResult -eq 'Failed' -and -not $script:engineCompleted -and -not $script:stateCommitted)
    Add-I1Result 'INSTALLER-STATE-MACHINE' ($a -and $b -and $c -and $d -and $f) "dryRunFail=$a applyFail=$b completed=$c searchFailKeepsCompleted=$d laterApplyFail=$f"

    # ---- committed-state checks ----
    $stateRoot = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
    [System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    foreach ($name in 'Test-ApplyCommitted', 'Test-UninstallCommitted') { }
    . ([scriptblock]::Create((Get-FunctionText $installerGui @('Test-ApplyCommitted'))))
    $good = [pscustomobject]@{ Succeeded = $true; Apply = $true; RealSystem = $true; ApplyResults = @([pscustomobject]@{ Platform = 'Core'; Component = 'Application' }) }
    function Set-InstalledState([string]$When, [bool]$Marker) {
        foreach ($f in 'installed-state.json', 'installing.json') { $p = Join-Path $stateRoot $f; if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) } }
        if ($When) { [System.IO.File]::WriteAllText((Join-Path $stateRoot 'installed-state.json'), ('{"SchemaVersion":1,"InstalledAt":"' + $When + '"}')) }
        if ($Marker) { [System.IO.File]::WriteAllText((Join-Path $stateRoot 'installing.json'), '{}') }
    }
    $script:applyStartedAt = [System.DateTimeOffset]::Now.AddSeconds(-5)
    $fresh = [System.DateTimeOffset]::Now.ToString('o'); $stale = [System.DateTimeOffset]::Now.AddMinutes(-30).ToString('o')
    Set-InstalledState $fresh $false
    Add-I1Result 'INSTALLER-COMMITTED-OK' ((Test-ApplyCommitted $good) -eq $true) 'fresh state, no marker'
    Set-InstalledState $fresh $true;  Add-I1Result 'INSTALLER-COMMITTED-REJECTS-MARKER' ((Test-ApplyCommitted $good) -eq $false) 'installing.json present'
    Set-InstalledState $stale $false; Add-I1Result 'INSTALLER-COMMITTED-REJECTS-STALE-STATE' ((Test-ApplyCommitted $good) -eq $false) 'InstalledAt older than apply start'
    Set-InstalledState '' $false;     Add-I1Result 'INSTALLER-COMMITTED-REJECTS-MISSING-STATE' ((Test-ApplyCommitted $good) -eq $false) 'no installed-state.json'
    Set-InstalledState $fresh $false
    $variants = [ordered]@{
        'NOT-SUCCEEDED' = [pscustomobject]@{ Succeeded = $false; Apply = $true; RealSystem = $true; ApplyResults = $good.ApplyResults }
        'DRYRUN-PLAN'   = [pscustomobject]@{ Succeeded = $true; Apply = $false; RealSystem = $false; ApplyResults = $good.ApplyResults }
        'NOT-REALSYSTEM' = [pscustomobject]@{ Succeeded = $true; Apply = $true; RealSystem = $false; ApplyResults = $good.ApplyResults }
        'NO-CORE-RESULT' = [pscustomobject]@{ Succeeded = $true; Apply = $true; RealSystem = $true; ApplyResults = @() }
        'MALFORMED'     = [pscustomobject]@{ Succeeded = $true }
    }
    foreach ($key in $variants.Keys) { Add-I1Result ('INSTALLER-COMMITTED-REJECTS-' + $key) ((Test-ApplyCommitted $variants[$key]) -eq $false) 'engine JSON does not prove a committed real apply' }

    . ([scriptblock]::Create((Get-FunctionText $uninstallerGui @('Test-UninstallCommitted'))))
    function Set-UninstalledState([string]$When, [string]$State) {
        $p = Join-Path $stateRoot 'uninstalled-state.json'; if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) }
        if ($When) { [System.IO.File]::WriteAllText($p, ('{"SchemaVersion":1,"State":"' + $State + '","UninstalledAt":"' + $When + '"}')) }
    }
    $uGood = [pscustomobject]@{ Succeeded = $true; Apply = $true; RealSystem = $true }
    Set-UninstalledState $fresh 'Uninstalled'; Add-I1Result 'UNINSTALLER-COMMITTED-OK' ((Test-UninstallCommitted $uGood 0) -eq $true) 'fresh uninstalled-state'
    Add-I1Result 'UNINSTALLER-COMMITTED-REJECTS-EXITCODE-1' ((Test-UninstallCommitted $uGood 1) -eq $false) 'engine exit code 1'
    Set-UninstalledState $stale 'Uninstalled'; Add-I1Result 'UNINSTALLER-COMMITTED-REJECTS-STALE' ((Test-UninstallCommitted $uGood 0) -eq $false) 'UninstalledAt older than apply start'
    Set-UninstalledState $fresh 'Other';        Add-I1Result 'UNINSTALLER-COMMITTED-REJECTS-WRONG-STATE' ((Test-UninstallCommitted $uGood 0) -eq $false) 'State is not Uninstalled'
    Set-UninstalledState '' '';                 Add-I1Result 'UNINSTALLER-COMMITTED-REJECTS-MISSING' ((Test-UninstallCommitted $uGood 0) -eq $false) 'no uninstalled-state.json'
    Set-UninstalledState $fresh 'Uninstalled'
    Add-I1Result 'UNINSTALLER-COMMITTED-REJECTS-NOT-SUCCEEDED' ((Test-UninstallCommitted ([pscustomobject]@{ Succeeded = $false; Apply = $true; RealSystem = $true }) 0) -eq $false) 'Succeeded=false'
    Add-I1Result 'UNINSTALLER-COMMITTED-REJECTS-DRYRUN' ((Test-UninstallCommitted ([pscustomobject]@{ Succeeded = $true; Apply = $false; RealSystem = $false }) 0) -eq $false) 'dry-run plan'

    # ---- Write-RunResult / Complete-Run for both GUIs ----
    foreach ($gui in @(@{ Tag = 'INSTALLER'; Path = $installerGui; Operation = 'Install' }, @{ Tag = 'UNINSTALLER'; Path = $uninstallerGui; Operation = 'Uninstall' })) {
        $tag = $gui.Tag
        . ([scriptblock]::Create((Get-FunctionText $gui.Path @('Write-RunResult', 'Complete-Run'))))
        $dir = Join-Path $sandbox ('rr-' + $tag); [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        $RunId = [System.Guid]::NewGuid().ToString('N')

        $ResultPath = ''; Reset-State 'Completed'; $script:engineStarted = $true; $script:engineCompleted = $true; $script:stateCommitted = $true
        Add-I1Result "$tag-RESULT-NO-PATH-NO-FILE" ((Complete-Run) -eq 0 -and @(Get-ChildItem -LiteralPath $dir).Count -eq 0) 'no -ResultPath: exit code only'

        $ResultPath = Join-Path $dir 'ok.json'
        $code = Complete-Run
        $doc = [System.IO.File]::ReadAllText($ResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $props = @($doc.PSObject.Properties.Name)
        $needed = 'schemaVersion', 'operation', 'runId', 'result', 'reason', 'exitCode', 'engineStarted', 'engineCompleted', 'stateCommitted', 'writtenAt'
        Add-I1Result "$tag-RESULT-COMPLETED-CONTENT" ($code -eq 0 -and $doc.schemaVersion -eq 1 -and $doc.operation -eq $gui.Operation -and $doc.runId -eq $RunId -and $doc.result -eq 'Completed' -and $doc.exitCode -eq 0 -and $doc.engineStarted -eq $true -and $doc.engineCompleted -eq $true -and $doc.stateCommitted -eq $true -and @($needed | Where-Object { $props -notcontains $_ }).Count -eq 0) "exit=$code props=$($props -join ',')"
        Add-I1Result "$tag-RESULT-ATOMIC-NO-TMP-LEFT" (@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp').Count -eq 0) 'temporary file was moved onto the final name'
        $bytes = [System.IO.File]::ReadAllBytes($ResultPath)
        Add-I1Result "$tag-RESULT-UTF8-NO-BOM" (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF)) 'written as UTF-8 without BOM'

        $before = [System.IO.File]::ReadAllText($ResultPath)
        $code = Complete-Run
        Add-I1Result "$tag-RESULT-EXISTING-FILE-NOT-OVERWRITTEN" ($code -eq 1 -and [System.IO.File]::ReadAllText($ResultPath) -eq $before) "exit=$code (a previous run's file is never reused or replaced)"

        $ResultPath = Join-Path $dir 'missing-dir\x.json'
        Add-I1Result "$tag-RESULT-MISSING-DIRECTORY-IS-FAILED" ((Complete-Run) -eq 1) 'cannot write -> exit 1'
        $ResultPath = Join-Path $dir 'blocked.json'; [System.IO.File]::WriteAllText($ResultPath + '.tmp', 'x')
        $blockedCode = Complete-Run
        Add-I1Result "$tag-RESULT-TMP-COLLISION-IS-FAILED" ($blockedCode -eq 1 -and -not [System.IO.File]::Exists($ResultPath)) "exit=$blockedCode"
        $ResultPath = Join-Path $dir 'norun.json'; $savedRunId = $RunId; $RunId = ''
        Add-I1Result "$tag-RESULT-EMPTY-RUNID-IS-FAILED" ((Complete-Run) -eq 1 -and -not [System.IO.File]::Exists($ResultPath)) 'no RunId -> exit 1'
        $RunId = $savedRunId

        $cases = @(
            @{ Name = 'COMPLETED-WITHOUT-COMMIT'; Result = 'Completed'; Flags = @($true, $true, $false); Code = 1; Expected = 'Failed'; Reason = 'InvariantViolation' },
            @{ Name = 'COMPLETED-WITHOUT-ENGINE'; Result = 'Completed'; Flags = @($true, $false, $true); Code = 1; Expected = 'Failed'; Reason = 'InvariantViolation' },
            @{ Name = 'COMPLETED-WITHOUT-START'; Result = 'Completed'; Flags = @($false, $true, $true); Code = 1; Expected = 'Failed'; Reason = 'InvariantViolation' },
            @{ Name = 'CANCELLED-CLEAN'; Result = 'Cancelled'; Flags = @($false, $false, $false); Code = 2; Expected = 'Cancelled'; Reason = 'NotCompleted' },
            @{ Name = 'CANCELLED-AFTER-ENGINE-START'; Result = 'Cancelled'; Flags = @($true, $false, $false); Code = 1; Expected = 'Failed'; Reason = 'InvariantViolation' },
            @{ Name = 'FAILED'; Result = 'Failed'; Flags = @($true, $false, $false); Code = 1; Expected = 'Failed'; Reason = 'NotCompleted' },
            @{ Name = 'PRISTINE-UNFINISHED-RUN'; Result = 'Failed'; Flags = @($false, $false, $false); Code = 1; Expected = 'Failed'; Reason = 'NotCompleted' }
        )
        foreach ($case in $cases) {
            Reset-State $case.Result; $script:engineStarted = $case.Flags[0]; $script:engineCompleted = $case.Flags[1]; $script:stateCommitted = $case.Flags[2]
            $ResultPath = Join-Path $dir ($case.Name + '.json')
            $code = Complete-Run
            $doc = [System.IO.File]::ReadAllText($ResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            Add-I1Result "$tag-COMPLETE-RUN-$($case.Name)" ($code -eq $case.Code -and $doc.result -eq $case.Expected -and $doc.reason -eq $case.Reason -and $doc.exitCode -eq $case.Code) "exit=$code result=$($doc.result) reason=$($doc.reason)"
        }
    }

    # ---- Start scripts (T4): exit code and argument propagation, UAC cancellation ----
    $startRoot = Join-Path $sandbox 'start'
    foreach ($pair in @(@{ Tag = 'SETUP'; Script = 'Start-DenGoSetup.ps1'; Gui = 'DenGoInstallerGui.ps1' }, @{ Tag = 'UNINSTALL'; Script = 'Start-DenGoUninstall.ps1'; Gui = 'DenGoUninstallerGui.ps1' })) {
        $tag = $pair.Tag
        $base = Join-Path $startRoot $tag
        foreach ($sub in 'installer\scripts', 'installer\gui') { [System.IO.Directory]::CreateDirectory((Join-Path $base $sub)) | Out-Null }
        $source = [System.IO.File]::ReadAllText((Join-Path $script:I1Repo ('installer\scripts\' + $pair.Script)), [System.Text.Encoding]::UTF8)
        $needle = 'return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)'
        $count = ([regex]::Matches($source, [regex]::Escape($needle))).Count
        Add-I1Result "$tag-START-ADMIN-CHECK-LOCATED" ($count -eq 1) 'the only edit made to the sandbox copy: the elevation check returns $true so no UAC prompt can appear'
        [System.IO.File]::WriteAllText((Join-Path $base ('installer\scripts\' + $pair.Script)), $source.Replace($needle, 'return $true'), (New-Object System.Text.UTF8Encoding($true)))
        $stub = @'
param([string]$ResultPath = '', [string]$RunId = '')
[System.IO.File]::WriteAllText((Join-Path $env:DENGO_I1_SANDBOX 'gui-args.txt'), ('ResultPath=' + $ResultPath + ';RunId=' + $RunId))
exit ([int]$env:DENGO_I1_STUB_EXIT)
'@
        [System.IO.File]::WriteAllText((Join-Path $base ('installer\gui\' + $pair.Gui)), $stub, (New-Object System.Text.UTF8Encoding($false)))
        $argsFile = Join-Path $base 'gui-args.txt'
        foreach ($expected in 0, 2, 1, 7, -1) {
            foreach ($withResult in $true, $false) {
                if ([System.IO.File]::Exists($argsFile)) { [System.IO.File]::Delete($argsFile) }
                $info = New-Object System.Diagnostics.ProcessStartInfo
                $info.FileName = 'powershell.exe'
                $extra = if ($withResult) { ' -ResultPath "C:\x y\result.json" -RunId abc123' } else { '' }
                $info.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"{1}' -f (Join-Path $base ('installer\scripts\' + $pair.Script)), $extra)
                $info.UseShellExecute = $false; $info.CreateNoWindow = $true
                $info.EnvironmentVariables['DENGO_I1_SANDBOX'] = $base
                $info.EnvironmentVariables['DENGO_I1_STUB_EXIT'] = [string]$expected
                $p = [System.Diagnostics.Process]::Start($info); [void]$p.WaitForExit(60000)
                $seen = if ([System.IO.File]::Exists($argsFile)) { [System.IO.File]::ReadAllText($argsFile) } else { '<none>' }
                $wantArgs = if ($withResult) { 'ResultPath=C:\x y\result.json;RunId=abc123' } else { 'ResultPath=;RunId=' }
                Add-I1Result "$tag-START-EXIT-$expected-ARGS-$withResult" ($p.ExitCode -eq $expected -and $seen -eq $wantArgs) "exit=$($p.ExitCode) args=$seen"
            }
        }
        # a GUI that is missing makes the Start script fail instead of reporting success
        Remove-Item -LiteralPath (Join-Path $base ('installer\gui\' + $pair.Gui)) -Force
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = 'powershell.exe'; $info.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $base ('installer\scripts\' + $pair.Script)))
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($info); [void]$p.StandardError.ReadToEnd(); [void]$p.WaitForExit(60000)
        Add-I1Result "$tag-START-MISSING-GUI-IS-NOT-SUCCESS" ($p.ExitCode -ne 0 -and $p.ExitCode -ne 2) "exit=$($p.ExitCode)"

        # UAC cancellation (Win32 error 1223) is Cancelled
        $scriptPath = Join-Path $script:I1Repo ('installer\scripts\' + $pair.Script)
        $ast = Get-ScriptAst $scriptPath
        $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $exitCodesInCatch = @($catches | ForEach-Object { $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true) } | ForEach-Object { $_.Pipeline.Extent.Text })
        Add-I1Result "$tag-START-UAC-CANCEL-EXITS-2" ($exitCodesInCatch -contains '2' -and $exitCodesInCatch -notcontains '0') ('exit statements inside catch blocks: ' + ($exitCodesInCatch -join ','))
        $allExits = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true) | ForEach-Object { $_.Pipeline.Extent.Text })
        Add-I1Result "$tag-START-NEVER-EXITS-0-LITERALLY" ($allExits -notcontains '0') ('all exit statements: ' + ($allExits -join ' | '))
    }
    . ([scriptblock]::Create((Get-FunctionText (Join-Path $script:I1Repo 'installer\scripts\Start-DenGoSetup.ps1') @('Test-UacCancellation'))))
    $uac = New-Object System.ComponentModel.Win32Exception(1223)
    $wrapped = New-Object System.Exception('outer', $uac)
    $other = New-Object System.ComponentModel.Win32Exception(5)
    Add-I1Result 'START-UAC-DETECTION' ((Test-UacCancellation $uac) -and (Test-UacCancellation $wrapped) -and -not (Test-UacCancellation $other)) 'Win32 error 1223 (also wrapped) is cancellation; error 5 is not'
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-I1Sandbox $sandbox
}
Complete-I1Tests
