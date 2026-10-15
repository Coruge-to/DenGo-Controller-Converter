# I1 GUI contract tests (T3): drives the real installer/uninstaller GUI scripts through UI Automation.
# The GUI copies run from a sandbox under TEMP with fake engines; LOCALAPPDATA and TEMP point into the sandbox.
# No real installer/uninstaller engine, registry key, self-delete or product directory is touched.
param([ValidateSet('All', 'Installer', 'Uninstaller')][string]$Only = 'All')
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')

$script:UiText['Search'] = (U 0x8FFD, 0x52A0, 0x306E, 0x74B0, 0x5883, 0x3092, 0x691C, 0x7D22)
$script:Sandboxes = New-Object System.Collections.ArrayList

function New-Scenario([string]$Name, [string]$GuiName, [hashtable]$Environment, [switch]$UnwritableResult, [hashtable]$SandboxOptions = @{}) {
    $root = New-I1Sandbox $Name
    [void]$script:Sandboxes.Add($root)
    [void](Initialize-GuiSandbox -Root $root @SandboxOptions)
    $resultDir = Join-Path $root 'result'
    if (-not $UnwritableResult) { [System.IO.Directory]::CreateDirectory($resultDir) | Out-Null }
    $resultPath = Join-Path $resultDir 'result.json'
    $runId = [System.Guid]::NewGuid().ToString('N')
    $process = Start-GuiUnderTest -Root $root -GuiName $GuiName -Environment $Environment -ResultPath $resultPath -RunId $runId
    $window = Get-GuiMainWindow $process.Id
    return @{ Name = $Name; Root = $root; Process = $process; ResultPath = $resultPath; RunId = $runId; Window = $window }
}
function Invoke-Click($Ctx, [string]$Text, [int]$Timeout = 25) {
    $button = Wait-GuiButton $Ctx.Process.Id $Text $Timeout
    if ($null -eq $button) { return $false }
    Send-GuiClick $button
    return $true
}
function Wait-ButtonGone($Ctx, [string]$Text, [int]$Timeout = 8) {
    $deadline = [DateTime]::Now.AddSeconds($Timeout)
    while ([DateTime]::Now -lt $deadline) { if ($null -eq (Find-GuiButton $Ctx.Process.Id $Text)) { return $true }; Start-Sleep -Milliseconds 100 }
    return $false
}
function Wait-ExitCode($Ctx, [int]$Seconds = 25) {
    if ($Ctx.Process.WaitForExit($Seconds * 1000)) { return [int]$Ctx.Process.ExitCode }
    return $null
}
function Wait-EnginePid($Ctx, [int]$Seconds = 40) {
    $pidFile = Join-Path $Ctx.Root 'engine.pid'
    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        if ([System.IO.File]::Exists($pidFile)) {
            $text = ''
            try { $text = ([System.IO.File]::ReadAllText($pidFile)).Trim() } catch { }
            if ($text -match '^\d+$') { return [int]$text }
        }
        Start-Sleep -Milliseconds 150
    }
    return 0
}
function Test-ProcessAlive([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    return ($null -ne $p -and -not $p.HasExited)
}
function Read-ResultFile($Ctx) {
    if (-not [System.IO.File]::Exists($Ctx.ResultPath)) { return $null }
    return [System.IO.File]::ReadAllText($Ctx.ResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}
function Stop-Scenario($Ctx) {
    try {
        $pidFile = Join-Path $Ctx.Root 'engine.pid'
        if ([System.IO.File]::Exists($pidFile)) {
            $enginePid = 0; [void][int]::TryParse(([System.IO.File]::ReadAllText($pidFile)).Trim(), [ref]$enginePid)
            if ($enginePid -gt 0) {
                $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $enginePid) -ErrorAction SilentlyContinue
                if ($null -ne $cim -and ([string]$cim.CommandLine).IndexOf($Ctx.Root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Stop-Process -Id $enginePid -Force -ErrorAction SilentlyContinue }
            }
        }
    } catch { }
    try { if (-not $Ctx.Process.HasExited) { $Ctx.Process.Kill(); $Ctx.Process.WaitForExit(5000) | Out-Null } } catch { }
}
function Assert-Outcome([string]$Id, $Ctx, $Code, [int]$ExpectedCode, [string]$ExpectedResult, [string]$ExpectedReason, [bool[]]$Flags) {
    $result = $null
    try { $result = Read-ResultFile $Ctx } catch { }
    $detail = 'exit=' + [string]$Code
    $ok = ($null -ne $Code -and $Code -eq $ExpectedCode)
    if ($null -eq $result) { $ok = $false; $detail += ' resultFile=missing' }
    else {
        $detail += (' result={0} reason={1} flags={2}/{3}/{4} exitCode={5}' -f $result.result, $result.reason, $result.engineStarted, $result.engineCompleted, $result.stateCommitted, $result.exitCode)
        $checks = [ordered]@{
            result = ([string]$result.result -eq $ExpectedResult)
            exitCode = ([int]$result.exitCode -eq $ExpectedCode)
            runId = ([string]$result.runId -eq $Ctx.RunId)
        }
        if ($ExpectedReason) { $checks['reason'] = ([string]$result.reason -eq $ExpectedReason) }
        if ($null -ne $Flags) { $checks['flags'] = (([bool]$result.engineStarted -eq $Flags[0]) -and ([bool]$result.engineCompleted -eq $Flags[1]) -and ([bool]$result.stateCommitted -eq $Flags[2])) }
        foreach ($name in $checks.Keys) { if (-not $checks[$name]) { $ok = $false; $detail += (' MISMATCH:' + $name) } }
    }
    $leftover = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Ctx.ResultPath) -Filter '*.tmp' -ErrorAction SilentlyContinue).Count
    if ($leftover -ne 0) { $ok = $false; $detail += ' tmp-left-behind' }
    Add-I1Result $Id $ok $detail
}

$NONE = @($false, $false, $false)
$ATTEMPTED = @($true, $false, $false)
$DONE = @($true, $true, $true)

# ---------- driving helpers for the setup wizard ----------
function Step-SetupToResultPage($Ctx) {
    if (-not (Invoke-Click $Ctx $script:UiText.Next)) { return $false }
    return ($null -ne (Wait-GuiButton $Ctx.Process.Id $script:UiText.Search 60))
}
function Step-SetupResultToFinish($Ctx) {
    if (-not (Invoke-Click $Ctx $script:UiText.Next)) { return $false }   # the result page "next" button
    return (Invoke-Click $Ctx $script:UiText.Finish)
}
function Step-StartSetup($Ctx) {
    # welcome page -> click next; wait until the welcome page is gone
    if (-not (Invoke-Click $Ctx $script:UiText.Next)) { return $false }
    return (Wait-ButtonGone $Ctx $script:UiText.Next)
}

# ---------- classification contract: Cancelled only from an explicit, confirmed pre-apply cancel ----------
function Test-ClassificationScenarios([string]$Kind) {
    $isInstaller = ($Kind -eq 'Installer')
    $gui = if ($isInstaller) { 'DenGoInstallerGui.ps1' } else { 'DenGoUninstallerGui.ps1' }
    $tag = $Kind.ToUpper()
    $trigger = if ($isInstaller) { $script:UiText.Next } else { $script:UiText.Uninstall }
    $no = U 0x3044, 0x3044, 0x3048

    # idle WindowsShutDown on a fresh run: allowed, and the result is Failed/NotCompleted (never Cancelled)
    $c = New-Scenario ('c01' + $Kind) $gui @{}
    try {
        $reply = Send-GuiQueryEndSession $c.Window
        $code = Wait-ExitCode $c 15
        Add-I1Result "$tag-CLASS-01-IDLE-WINDOWSSHUTDOWN-NOT-BLOCKED" ($reply -eq 1 -and $null -ne $code) ("queryEndSession reply=$reply guiExit=$code")
        Assert-Outcome "$tag-CLASS-01-IDLE-WINDOWSSHUTDOWN-IS-FAILED" $c $code 1 'Failed' 'NotCompleted' $NONE
    } finally { Stop-Scenario $c }

    # UserClosing + No: the window stays, nothing changes (a later OS shutdown still reports Failed/NotCompleted, not Cancelled)
    $c = New-Scenario ('c02' + $Kind) $gui @{}
    try {
        Send-GuiUserClose $c.Window
        $answered = Invoke-Click $c $no
        Start-Sleep -Milliseconds 1200
        $stillOpen = (-not $c.Process.HasExited) -and [I1Native]::IsWindow([IntPtr][int]$c.Window.Current.NativeWindowHandle) -and -not [System.IO.File]::Exists($c.ResultPath)
        Add-I1Result "$tag-CLASS-02-USERCLOSING-NO-KEEPS-WINDOW" ($answered -and $stillOpen) "answeredNo=$answered windowStillOpen=$stillOpen"
        [void](Send-GuiQueryEndSession $c.Window)
        Assert-Outcome "$tag-CLASS-02-USERCLOSING-NO-KEEPS-FAILED" $c (Wait-ExitCode $c 15) 1 'Failed' 'NotCompleted' $NONE
    } finally { Stop-Scenario $c }

    # unexpected exception in a pre-apply event handler (process listing throws): Failed, even though the user then closes with Yes
    $c = New-Scenario ('c03' + $Kind) $gui @{} -SandboxOptions @{ ThrowOnProcessListing = $true }
    try {
        $ok = (Invoke-Click $c $trigger) -and (Invoke-Click $c $script:UiText.Ok 20)
        Send-GuiUserClose $c.Window
        $ok = $ok -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome "$tag-CLASS-03-HANDLER-EXCEPTION-IS-FAILED" $c (Wait-ExitCode $c) 1 'Failed' 'UnhandledException' $NONE
        if (-not $ok) { Add-I1Result "$tag-CLASS-03-DRIVE" $false 'could not drive the GUI (error dialog / confirmation not found)' }
    } finally { Stop-Scenario $c }

    # initialization exception: the process ends with 1 and no result file (the wrapper reads that as Failed)
    $options = if ($isInstaller) { @{ CorruptWelcomeImage = $true } } else { @{} }
    $environment = if ($isInstaller) { @{} } else { @{ LOCALAPPDATA = '' } }
    $c = New-Scenario ('c04' + $Kind) $gui $environment -SandboxOptions $options
    try {
        $code = Wait-ExitCode $c 30
        Add-I1Result "$tag-CLASS-04-INITIALIZATION-EXCEPTION-IS-FAILED" ($null -ne $code -and $code -eq 1 -and -not [System.IO.File]::Exists($c.ResultPath)) ("exit=$code resultFile=" + [System.IO.File]::Exists($c.ResultPath))
    } finally { Stop-Scenario $c }

    # engine script missing
    $c = New-Scenario ('c05' + $Kind) $gui @{} -SandboxOptions @{ RemoveEngine = $Kind }
    try {
        if ($isInstaller) {
            $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
            Assert-Outcome "$tag-CLASS-05-ENGINE-MISSING-IS-FAILED" $c (Wait-ExitCode $c) 1 'Failed' 'DryRunNoResult' $NONE
        } else {
            $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 30)
            Send-GuiUserClose $c.Window
            $ok = $ok -and (Invoke-Click $c $script:UiText.Yes)
            Assert-Outcome "$tag-CLASS-05-ENGINE-MISSING-IS-FAILED" $c (Wait-ExitCode $c) 1 'Failed' 'EngineNotFound' $NONE
        }
        if (-not $ok) { Add-I1Result "$tag-CLASS-05-DRIVE" $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }
}

function Test-InstallerScenarios {
    $gui = 'DenGoInstallerGui.ps1'

    # 1. cancel before applying
    $c = New-Scenario 'i01' $gui @{}
    try {
        $ok = (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'INSTALL-01-CANCEL-BEFORE-APPLY' $c (Wait-ExitCode $c) 2 'Cancelled' 'UserCancelled' $NONE
        if (-not $ok) { Add-I1Result 'INSTALL-01-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 2. upper-right X before applying
    $c = New-Scenario 'i02' $gui @{}
    try {
        Send-GuiUserClose $c.Window
        $ok = (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'INSTALL-02-X-BEFORE-APPLY' $c (Wait-ExitCode $c) 2 'Cancelled' 'UserCancelled' $NONE
    } finally { Stop-Scenario $c }

    # 3. normal completion
    $c = New-Scenario 'i03' $gui @{}
    try {
        $ok = (Step-StartSetup $c) -and ($null -ne (Wait-GuiButton $c.Process.Id $script:UiText.Search 60)) -and (Step-SetupResultToFinish $c)
        Assert-Outcome 'INSTALL-03-COMPLETED' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $ok) { Add-I1Result 'INSTALL-03-DRIVE' $false 'could not drive the GUI to the completion page' }
    } finally { Stop-Scenario $c }

    # 4. dry-run failure, then close: Failed stays Failed
    $c = New-Scenario 'i04' $gui @{ DENGO_I1_DRY = 'fail' }
    try {
        $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 40) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'INSTALL-04-DRYRUN-FAILURE' $c (Wait-ExitCode $c) 1 'Failed' 'DryRunFailed' $NONE
        if (-not $ok) { Add-I1Result 'INSTALL-04-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 4b. dry-run produced no JSON / corrupt JSON
    foreach ($mode in 'nojson', 'corrupt') {
        $reason = if ($mode -eq 'nojson') { 'DryRunNoResult' } else { 'DryRunResultCorrupt' }
        $c = New-Scenario ('i04' + $mode) $gui @{ DENGO_I1_DRY = $mode }
        try {
            $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 40)
            Send-GuiUserClose $c.Window
            $ok = $ok -and (Invoke-Click $c $script:UiText.Yes)
            Assert-Outcome ('INSTALL-04-DRYRUN-' + $mode.ToUpper()) $c (Wait-ExitCode $c) 1 'Failed' $reason $NONE
        } finally { Stop-Scenario $c }
    }

    # 5. failure before the apply produced anything (engine ends without a result file)
    $c = New-Scenario 'i05' $gui @{ DENGO_I1_APPLY = 'nojson' }
    try {
        $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'INSTALL-05-FAILURE-BEFORE-APPLY' $c (Wait-ExitCode $c) 1 'Failed' 'EngineNoResult' $ATTEMPTED
        if (-not $ok) { Add-I1Result 'INSTALL-05-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 6. engine failure during apply; close with X afterwards: still Failed
    $c = New-Scenario 'i06' $gui @{ DENGO_I1_APPLY = 'fail' }
    try {
        $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60)
        Send-GuiUserClose $c.Window
        $ok = $ok -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'INSTALL-06-ENGINE-FAILURE-THEN-CLOSE' $c (Wait-ExitCode $c) 1 'Failed' 'EngineFailed' $ATTEMPTED
        if (-not $ok) { Add-I1Result 'INSTALL-06-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 7. unexpected GUI end while the engine runs: no result file, no success code
    $c = New-Scenario 'i07' $gui @{ DENGO_I1_APPLY = 'slow' }
    try {
        $ok = (Step-StartSetup $c)
        $enginePid = Wait-EnginePid $c
        $c.Process.Kill(); $c.Process.WaitForExit(5000) | Out-Null
        $code = [int]$c.Process.ExitCode
        Add-I1Result 'INSTALL-07-GUI-UNEXPECTED-END' ($ok -and $enginePid -gt 0 -and $code -ne 0 -and $code -ne 2 -and -not [System.IO.File]::Exists($c.ResultPath)) ('exit=' + $code + ' resultFile=' + [System.IO.File]::Exists($c.ResultPath))
    } finally { Stop-Scenario $c }

    # 8. result file cannot be written: GUI must not report anything but Failed
    $c = New-Scenario 'i08' $gui @{} -UnwritableResult
    try {
        $ok = (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        $code = Wait-ExitCode $c
        Add-I1Result 'INSTALL-08-RESULT-NOT-WRITABLE' ($ok -and $code -eq 1 -and -not [System.IO.File]::Exists($c.ResultPath)) ('exit=' + [string]$code)
    } finally { Stop-Scenario $c }

    # 9. engine claims success but state was not committed (no state / stale state)
    foreach ($mode in 'nostate', 'stale-state') {
        $c = New-Scenario ('i09' + $mode) $gui @{ DENGO_I1_APPLY = $mode }
        try {
            $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
            Assert-Outcome ('INSTALL-09-STATE-NOT-COMMITTED-' + $mode.ToUpper()) $c (Wait-ExitCode $c) 1 'Failed' 'EngineStateNotCommitted' $ATTEMPTED
        } finally { Stop-Scenario $c }
    }

    # 10. UserClosing while applying: window stays, engine is not killed, no dialog; WindowsShutDown is not blocked
    $c = New-Scenario 'i10' $gui @{ DENGO_I1_APPLY = 'slow' }
    try {
        $ok = (Step-StartSetup $c)
        $enginePid = Wait-EnginePid $c
        Send-GuiUserClose $c.Window
        Start-Sleep -Milliseconds 1500
        $stillOpen = -not $c.Process.HasExited -and [I1Native]::IsWindow([IntPtr][int]$c.Window.Current.NativeWindowHandle)
        $noDialog = ($null -eq (Find-GuiButton $c.Process.Id $script:UiText.Yes)) -and ($null -eq (Find-GuiButton $c.Process.Id $script:UiText.Ok))
        $engineAlive = Test-ProcessAlive $enginePid
        Add-I1Result 'INSTALL-10-USERCLOSING-DURING-APPLY' ($ok -and $enginePid -gt 0 -and $stillOpen -and $noDialog -and $engineAlive) ('open={0} noDialog={1} engineAlive={2}' -f $stillOpen, $noDialog, $engineAlive)
        Send-GuiUserClose $c.Window
        Start-Sleep -Milliseconds 800
        Add-I1Result 'INSTALL-10-SECOND-USERCLOSING-STILL-BLOCKED' (-not $c.Process.HasExited -and (Test-ProcessAlive $enginePid)) 'second close request also ignored'
        [System.IO.File]::WriteAllText((Join-Path $c.Root 'release.flag'), '1')
        $reachedEnd = ($null -ne (Wait-GuiButton $c.Process.Id $script:UiText.Search 60)) -and (Step-SetupResultToFinish $c)
        Assert-Outcome 'INSTALL-10-COMPLETES-AFTER-RELEASE' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $reachedEnd) { Add-I1Result 'INSTALL-10-DRIVE' $false 'did not reach the completion page' }
    } finally { Stop-Scenario $c }

    # 10b. WindowsShutDown while applying is not blocked: the GUI may end, the engine is not killed, and the result is Failed
    $c = New-Scenario 'i10b' $gui @{ DENGO_I1_APPLY = 'slow' }
    try {
        $ok = (Step-StartSetup $c)
        $enginePid = Wait-EnginePid $c
        $reply = Send-GuiQueryEndSession $c.Window
        $code = Wait-ExitCode $c 15
        Add-I1Result 'INSTALL-10-WINDOWSSHUTDOWN-NOT-BLOCKED' ($ok -and $reply -eq 1 -and $null -ne $code) ('queryEndSession reply=' + $reply + ' (1 = allowed) guiExit=' + [string]$code)
        Add-I1Result 'INSTALL-10-WINDOWSSHUTDOWN-ENGINE-NOT-KILLED' (Test-ProcessAlive $enginePid) ('engine pid ' + $enginePid + ' alive after the GUI ended')
        Assert-Outcome 'INSTALL-10-WINDOWSSHUTDOWN-RESULT-IS-FAILED' $c $code 1 'Failed' 'GuiClosedDuringApply' $ATTEMPTED
    } finally { Stop-Scenario $c }

    # 11. Failed -> re-run failure stays Failed
    $c = New-Scenario 'i11' $gui @{ DENGO_I1_APPLY = 'fail' }
    try {
        $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60) -and (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'INSTALL-11-FAILED-RERUN-FAILED' $c (Wait-ExitCode $c) 1 'Failed' 'EngineFailed' $ATTEMPTED
        if (-not $ok) { Add-I1Result 'INSTALL-11-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 12. Failed -> re-run success + verified state -> Completed
    $c = New-Scenario 'i12' $gui @{ DENGO_I1_APPLY = 'fail-then-ok' }
    try {
        $ok = (Step-StartSetup $c) -and (Invoke-Click $c $script:UiText.Ok 60) -and (Step-StartSetup $c) -and ($null -ne (Wait-GuiButton $c.Process.Id $script:UiText.Search 60)) -and (Step-SetupResultToFinish $c)
        Assert-Outcome 'INSTALL-12-FAILED-THEN-RERUN-COMPLETED' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $ok) { Add-I1Result 'INSTALL-12-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 13. X on the result page after a committed install is Completed with no "cancel setup?" prompt
    $c = New-Scenario 'i13' $gui @{}
    try {
        $ok = (Step-StartSetup $c) -and ($null -ne (Wait-GuiButton $c.Process.Id $script:UiText.Search 60))
        Send-GuiUserClose $c.Window
        Assert-Outcome 'INSTALL-13-X-AFTER-SUCCESS-IS-COMPLETED' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $ok) { Add-I1Result 'INSTALL-13-DRIVE' $false 'could not reach the result page' }
    } finally { Stop-Scenario $c }
}

function Test-UninstallerScenarios {
    $gui = 'DenGoUninstallerGui.ps1'

    $c = New-Scenario 'u01' $gui @{}
    try {
        $ok = (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'UNINSTALL-01-CANCEL-AT-CONFIRMATION' $c (Wait-ExitCode $c) 2 'Cancelled' 'UserCancelled' $NONE
        if (-not $ok) { Add-I1Result 'UNINSTALL-01-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u02' $gui @{}
    try {
        Send-GuiUserClose $c.Window
        $ok = (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'UNINSTALL-02-X-BEFORE-APPLY' $c (Wait-ExitCode $c) 2 'Cancelled' 'UserCancelled' $NONE
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u03' $gui @{}
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Finish 40)
        Assert-Outcome 'UNINSTALL-03-COMPLETED' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $ok) { Add-I1Result 'UNINSTALL-03-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u04' $gui @{ DENGO_I1_UNINSTALL = 'fail' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'UNINSTALL-04-ENGINE-FAILURE' $c (Wait-ExitCode $c) 1 'Failed' 'EngineFailed' $ATTEMPTED
        if (-not $ok) { Add-I1Result 'UNINSTALL-04-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # 5. UnsafeOrUnknown stop before any change: engine ends without a result file; then X
    $c = New-Scenario 'u05' $gui @{ DENGO_I1_UNINSTALL = 'nojson' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40)
        Send-GuiUserClose $c.Window
        $ok = $ok -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'UNINSTALL-05-UNSAFEORUNKNOWN-STOP-THEN-X' $c (Wait-ExitCode $c) 1 'Failed' 'EngineNoResult' $ATTEMPTED
        if (-not $ok) { Add-I1Result 'UNINSTALL-05-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u07' $gui @{ DENGO_I1_UNINSTALL = 'slow' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall)
        $enginePid = Wait-EnginePid $c
        $c.Process.Kill(); $c.Process.WaitForExit(5000) | Out-Null
        $code = [int]$c.Process.ExitCode
        Add-I1Result 'UNINSTALL-07-GUI-UNEXPECTED-END' ($ok -and $enginePid -gt 0 -and $code -ne 0 -and $code -ne 2 -and -not [System.IO.File]::Exists($c.ResultPath)) ('exit=' + $code + ' resultFile=' + [System.IO.File]::Exists($c.ResultPath))
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u08' $gui @{} -UnwritableResult
    try {
        $ok = (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        $code = Wait-ExitCode $c
        Add-I1Result 'UNINSTALL-08-RESULT-NOT-WRITABLE' ($ok -and $code -eq 1 -and -not [System.IO.File]::Exists($c.ResultPath)) ('exit=' + [string]$code)
    } finally { Stop-Scenario $c }

    foreach ($mode in 'nostate', 'stale-state') {
        $c = New-Scenario ('u09' + $mode) $gui @{ DENGO_I1_UNINSTALL = $mode }
        try {
            $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
            Assert-Outcome ('UNINSTALL-09-STATE-NOT-COMMITTED-' + $mode.ToUpper()) $c (Wait-ExitCode $c) 1 'Failed' 'EngineStateNotCommitted' $ATTEMPTED
        } finally { Stop-Scenario $c }
    }

    # corrupt result JSON must neither hang the GUI nor read as success
    $c = New-Scenario 'u09corrupt' $gui @{ DENGO_I1_UNINSTALL = 'corrupt' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40)
        Send-GuiUserClose $c.Window
        $ok = $ok -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'UNINSTALL-09-RESULT-CORRUPT-GUI-NOT-STUCK' $c (Wait-ExitCode $c) 1 'Failed' 'EngineResultCorrupt' $ATTEMPTED
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u10' $gui @{ DENGO_I1_UNINSTALL = 'slow' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall)
        $enginePid = Wait-EnginePid $c
        Send-GuiUserClose $c.Window
        Start-Sleep -Milliseconds 1500
        $stillOpen = -not $c.Process.HasExited -and [I1Native]::IsWindow([IntPtr][int]$c.Window.Current.NativeWindowHandle)
        $noDialog = ($null -eq (Find-GuiButton $c.Process.Id $script:UiText.Yes)) -and ($null -eq (Find-GuiButton $c.Process.Id $script:UiText.Ok))
        $engineAlive = Test-ProcessAlive $enginePid
        Add-I1Result 'UNINSTALL-10-USERCLOSING-DURING-APPLY' ($ok -and $enginePid -gt 0 -and $stillOpen -and $noDialog -and $engineAlive) ('open={0} noDialog={1} engineAlive={2}' -f $stillOpen, $noDialog, $engineAlive)
        Send-GuiUserClose $c.Window
        Start-Sleep -Milliseconds 800
        Add-I1Result 'UNINSTALL-10-SECOND-USERCLOSING-STILL-BLOCKED' (-not $c.Process.HasExited -and (Test-ProcessAlive $enginePid)) 'second close request also ignored'
        [System.IO.File]::WriteAllText((Join-Path $c.Root 'release.flag'), '1')
        $reachedEnd = Invoke-Click $c $script:UiText.Finish 60
        Assert-Outcome 'UNINSTALL-10-COMPLETES-AFTER-RELEASE' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $reachedEnd) { Add-I1Result 'UNINSTALL-10-DRIVE' $false 'did not reach the completion page' }
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u10b' $gui @{ DENGO_I1_UNINSTALL = 'slow' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall)
        $enginePid = Wait-EnginePid $c
        $reply = Send-GuiQueryEndSession $c.Window
        $code = Wait-ExitCode $c 15
        Add-I1Result 'UNINSTALL-10-WINDOWSSHUTDOWN-NOT-BLOCKED' ($ok -and $reply -eq 1 -and $null -ne $code) ('queryEndSession reply=' + $reply + ' (1 = allowed) guiExit=' + [string]$code)
        Add-I1Result 'UNINSTALL-10-WINDOWSSHUTDOWN-ENGINE-NOT-KILLED' (Test-ProcessAlive $enginePid) ('engine pid ' + $enginePid + ' alive after the GUI ended')
        Assert-Outcome 'UNINSTALL-10-WINDOWSSHUTDOWN-RESULT-IS-FAILED' $c $code 1 'Failed' 'GuiClosedDuringApply' $ATTEMPTED
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u11' $gui @{ DENGO_I1_UNINSTALL = 'fail-then-ok' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40) -and (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Finish 40)
        Assert-Outcome 'UNINSTALL-11-FAILED-THEN-RERUN-COMPLETED' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $ok) { Add-I1Result 'UNINSTALL-11-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    $c = New-Scenario 'u12' $gui @{ DENGO_I1_UNINSTALL = 'fail' }
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40) -and (Invoke-Click $c $script:UiText.Uninstall) -and (Invoke-Click $c $script:UiText.Ok 40) -and (Invoke-Click $c $script:UiText.Cancel) -and (Invoke-Click $c $script:UiText.Yes)
        Assert-Outcome 'UNINSTALL-12-FAILED-RERUN-FAILED' $c (Wait-ExitCode $c) 1 'Failed' 'EngineFailed' $ATTEMPTED
        if (-not $ok) { Add-I1Result 'UNINSTALL-12-DRIVE' $false 'could not drive the GUI' }
    } finally { Stop-Scenario $c }

    # X on the completion page: Completed, with no "cancel uninstall?" prompt
    $c = New-Scenario 'u13' $gui @{}
    try {
        $ok = (Invoke-Click $c $script:UiText.Uninstall) -and ($null -ne (Wait-GuiButton $c.Process.Id $script:UiText.Finish 40))
        Send-GuiUserClose $c.Window
        Assert-Outcome 'UNINSTALL-13-X-AFTER-SUCCESS-IS-COMPLETED' $c (Wait-ExitCode $c) 0 'Completed' 'Completed' $DONE
        if (-not $ok) { Add-I1Result 'UNINSTALL-13-DRIVE' $false 'could not reach the completion page' }
    } finally { Stop-Scenario $c }
}

try {
    if ($Only -in 'All', 'Installer') { Test-InstallerScenarios; Test-ClassificationScenarios 'Installer' }
    if ($Only -in 'All', 'Uninstaller') { Test-UninstallerScenarios; Test-ClassificationScenarios 'Uninstaller' }
} finally {
    foreach ($root in $script:Sandboxes) { Remove-I1Sandbox $root }
}
Complete-I1Tests
