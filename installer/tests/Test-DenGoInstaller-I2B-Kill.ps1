# I2-B real-process kill tests. Each case:
#   (1) in-process crash model at point P  -> tree T1 and journal stages S1
#   (2) the same scenario in a child process that TerminateProcess-es ITSELF at P -> T2, S2   (T1 == T2, S1 == S2 proves the model)
#   (3) recovery from the real kill state through the product install (recovery gate -> next run) and the expected end state
# Plus the empty (state-only) core transaction killed at four points. Sandboxes under TEMP only.
param([string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2B.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2B-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-i2b-kill.jsonl'
Use-I2BHarnessIds
$child = Join-Path $PSScriptRoot 'I2B.LockChild.ps1'
$lockName = Get-DenGoLockName
function ConvertTo-B64($Object) { return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Compress))) }
function Start-Child([hashtable]$Params) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $child + '"'
    foreach ($k in $Params.Keys) { $argLine += ' -' + $k + ' "' + $Params[$k] + '"' }
    return (Start-Process powershell.exe -ArgumentList $argLine -PassThru -WindowStyle Hidden)
}
function Test-NoOrphans([int]$ChildPid) {
    $alive = $null -ne (Get-Process -Id $ChildPid -ErrorAction SilentlyContinue)
    $kids = Cnt (Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $ChildPid) -ErrorAction SilentlyContinue)
    return ((-not $alive) -and ($kids -eq 0))
}
function Get-StageText($L) {
    $out = New-Object System.Collections.ArrayList
    foreach ($base in @((Join-Path $L.Product.StateRoot 'txn'), (Join-Path $L.Product.StateRoot 'history'))) {
        if ([System.IO.Directory]::Exists($base)) {
            foreach ($p in [System.IO.Directory]::GetFiles($base, '*.jsonl', [System.IO.SearchOption]::AllDirectories)) {
                $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try { $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
                [void]$out.Add(($p.Substring($L.Root.Length) + ': ' + (($text -split "`n" | Where-Object { $_.Length -gt 0 } | ForEach-Object { if ($_ -match '"stage":"(\w+)"') { $Matches[1] } else { '?' } }) -join ',')))
            }
        }
    }
    return [string]::Join(' | ', [string[]]@($out))
}

# ---------------------------------------------------------------- product install kill cases
$sandboxes = @{}
foreach ($sc in 'P1', 'P2') {
    $L = New-I2BScenario ('kill-' + $sc) $sc
    $sandboxes[$sc] = @{ L = $L; Pristine = (Save-I2ATree $L.Root); Plan = (Get-I2BPlan $L $sc); Pre = (Get-I2BManagedTree $L) }
}
Install-I2AHarness
function Reset-Box($B) { Release-I2AHeld; Restore-I2ATree $B.L.Root $B.Pristine }

# the clean-run post tree of each scenario (normalized state)
foreach ($sc in 'P1', 'P2') {
    $B = $sandboxes[$sc]
    Reset-Box $B; Reset-I2AFault -Record $true; Reset-I2ACounters
    $r = Invoke-I2BInstall $B.L $B.Plan $true
    $B.Post = Get-I2BManagedTree $B.L -NormalizeState
    $B.LastId = @($global:I2AFH.AllLabels | Where-Object { $_ -match '^after:Journal:Register#\d+$' }).Count - 1
    [void](Assert-I2A "K00-$sc-clean-run" ($r.Succeeded -eq $true) "succeeded=$($r.Succeeded) lastItemId=$($B.LastId)")
    Reset-Box $B
}
$p2last = $sandboxes['P2'].LastId
$cases = @(
    @{ Id = 'K01-register-last'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Register#' + $p2last + '$'); Nth = 1 } },
    @{ Id = 'K02-marker-published'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:installing\.json$'; Nth = 1 } },
    @{ Id = 'K03-intent'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Intent#0$'; Nth = 1 } },
    @{ Id = 'K04-after-replace'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:DenGoControllerConverter\.exe$'; Nth = 1 } },
    @{ Id = 'K05-applied'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Applied#2$'; Nth = 1 } },
    @{ Id = 'K06-set-boundary-bve6-current'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Verified#3$'; Nth = 1 } },
    @{ Id = 'K07-verified-last'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Verified#' + $p2last + '$'); Nth = 1 } },
    @{ Id = 'K08-commit-intent'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:CommitIntent$'; Nth = 1 } },
    @{ Id = 'K09-state-replaced'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:installed-state\.json$'; Nth = 1 } },
    @{ Id = 'K10-committed'; Sc = 'P2'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Committed$'; Nth = 1 } },
    @{ Id = 'K11-first-install-state-moved'; Sc = 'P1'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:installed-state\.json$'; Nth = 1 } },
    @{ Id = 'K12-recovery-mid'; Sc = 'P2'; Pre = @{ CrashPattern = '^after:Journal:Verified#3$' }; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:'; Nth = 2 } },
    # F1: the process is killed after the shortcut was applied; the next run asks for no shortcut and has no ShortcutPath (the default of the GUI)
    @{ Id = 'K13-shortcut-applied-recovered-without-the-shortcut-option'; Sc = 'P2'; NoShortcutRecovery = $true; Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Verified#' + $p2last + '$'); Nth = 1 } },
    @{ Id = 'K14-shortcut-registered-recovered-without-the-shortcut-option'; Sc = 'P2'; NoShortcutRecovery = $true; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Intent#0$'; Nth = 1 } })

foreach ($case in $cases) {
    $B = $sandboxes[$case.Sc]; $L = $B.L; $id = $case.Id
    # ---- (1) in-process crash model
    Reset-Box $B
    if ($case.ContainsKey('Pre')) {
        Reset-I2AFault -CrashPattern $case.Pre.CrashPattern; Reset-I2ACounters
        try { $null = Invoke-I2BInstall $L $B.Plan $true } catch { }
        Resume-I2AAfterCrash
        $preSnap = Save-I2ATree $L.Root
        $plan = Get-I2BPlan $L $case.Sc
    } else { $preSnap = $B.Pristine; $plan = $B.Plan }
    Reset-I2AFault -Mode $case.Fault.Mode -Pattern $case.Fault.Pattern -Nth $case.Fault.Nth -Action 'Crash'
    if (-not $case.ContainsKey('Pre')) { Reset-I2ACounters }
    try { $null = Invoke-I2BInstall $L $plan $true } catch { }
    $modelFired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $treeModel = Get-I2BManagedTree $L
    $stagesModel = Get-StageText $L
    # ---- (2) real kill
    Release-I2AHeld; Restore-I2ATree $L.Root $preSnap
    $params = @{ Root = $L.Root; Scenario = $case.Sc; LockName = $lockName; KillFaultB64 = (ConvertTo-B64 $case.Fault) }
    $p = Start-Child $params
    $exited = $p.WaitForExit(120000)
    $code = $(if ($exited) { $p.ExitCode } else { -999 })
    if (-not $exited) { try { $p.Kill() } catch { } }
    $orphanFree = Test-NoOrphans $p.Id
    $killed = ($exited -and ($code -ne 0))
    $treeKill = Get-I2BManagedTree $L
    $stagesKill = Get-StageText $L
    # the child used a fresh plan from the disk it found, exactly like the model run
    [void](Assert-I2A "TK-$id-killed" (($modelFired.Length -gt 0) -and $killed -and $orphanFree) "model fired at '$modelFired'; child exit code $code; no surviving child or grandchild")
    [void](Assert-I2A "TK-$id-equivalence" ((Same $treeModel $treeKill) -and ($stagesModel -eq $stagesKill)) "tree after TerminateProcess == tree of the in-process crash model ($(Diff3 $treeModel $treeKill)); journal stages equal: $($stagesModel -eq $stagesKill)")
    # ---- (3) recovery from the real kill state
    $forward = ((Get-I2BManagedTree $L -NormalizeState)['x:state'] -eq 'NEW')
    $markerThere = [System.IO.File]::Exists((Join-Path $L.Product.StateRoot 'installing.json'))
    if ($case.ContainsKey('NoShortcutRecovery')) {
        $layoutNoSc = $L.Product.PSObject.Copy(); $layoutNoSc.ShortcutPath = ''
        $r1 = Invoke-DenGoProductInstall -Layout $layoutNoSc -Plan (Get-I2BPlan $L $case.Sc) -Options (Get-I2BOptions $L $false)
    } else {
        $r1 = Invoke-I2BInstall $L (Get-I2BPlan $L $case.Sc) $true
    }
    $map1 = Get-I2BManagedTree $L -NormalizeState
    $expect1 = $(if ($forward) { $B.Post } else { $B.Pre })
    $ok1 = $true
    if ($markerThere) { $ok1 = (($r1.Succeeded -eq $false) -and ($r1.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (Same $expect1 $map1)) } else { $ok1 = (($r1.Succeeded -eq $true) -and (Same $B.Post $map1)) }
    $global:I2AFH.IdCounter = 100     # deterministic test ids must not collide with the ids used by the killed run
    $r2 = Invoke-I2BInstall $L (Get-I2BPlan $L $case.Sc) $true
    $map2 = Get-I2BManagedTree $L -NormalizeState
    $ok2 = (($r2.Succeeded -eq $true) -and (Same $B.Post $map2) -and ((Cnt (Test-I2BLeftovers $L $false)) -eq 0))
    [void](Assert-I2A "TK-$id-recovery" ($ok1 -and $ok2) "marker=$markerThere forward=$forward first: code=$($r1.ErrorCode) ok=$ok1 [$(if ($markerThere) { Diff3 $expect1 $map1 })]; second: succeeded=$($r2.Succeeded) tree==post:$(Same $B.Post $map2)")
    Add-I2AEvidence @{ id = "TK-$id"; scenario = $case.Sc; fault = $modelFired; forward = $forward; markerAfterKill = $markerThere; firstOutcome = [string]$r1.ErrorCode; pass = ($killed -and $ok1 -and $ok2) }
}
Uninstall-I2AHarness
foreach ($sc in $sandboxes.Keys) { Remove-I2ASandbox $sandboxes[$sc].L.Root }

# ---------------------------------------------------------------- empty (state-only) core transaction, killed
$root = New-I2ASandbox 'kill-empty'
try {
    $layout = New-I2AFixture $root 'F4'
    $pristine = Save-I2ATree $root
    $factory = { param($c) return ,((New-Object System.Text.UTF8Encoding($false)).GetBytes('state-empty-v2')) }
    function Invoke-EmptyRun($Layout) { return (DgTx-Run -StateRoot $Layout.State -BackupRoot $Layout.Backup -Operation 'Install' -Items @() -Policy $Layout.Policy -NewStatePath $Layout.StatePath -NewStateFactory $factory -AllowEmptyTransaction) }
    $preTree = Get-I2AFullTree $layout
    Install-I2AHarness
    Reset-I2AFault; Reset-I2ACounters
    $r = Invoke-EmptyRun $layout
    $postTree = Get-I2AFullTree $layout
    [void](Assert-I2A 'KE00-clean-run' (($r.Succeeded -eq $true) -and ([System.IO.File]::ReadAllText($layout.StatePath) -eq 'state-empty-v2')) "succeeded=$($r.Succeeded)")
    $emptyCases = @(
        @{ Id = 'KE01-marker-published'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:installing\.json$'; Nth = 1 }; Forward = $false },
        @{ Id = 'KE02-commit-intent'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:CommitIntent$'; Nth = 1 }; Forward = $false },
        @{ Id = 'KE03-state-replaced'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:installed-state\.json$'; Nth = 1 }; Forward = $true },
        @{ Id = 'KE04-committed'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Committed$'; Nth = 1 }; Forward = $true })
    foreach ($case in $emptyCases) {
        Release-I2AHeld; Restore-I2ATree $root $pristine
        Reset-I2AFault -Mode $case.Fault.Mode -Pattern $case.Fault.Pattern -Nth $case.Fault.Nth -Action 'Crash'; Reset-I2ACounters
        try { $null = Invoke-EmptyRun $layout } catch { }
        $fired = [string]$global:I2AFH.Fired
        Resume-I2AAfterCrash
        $treeModel = Get-I2AFullTree $layout
        Release-I2AHeld; Restore-I2ATree $root $pristine
        $p = Start-Child @{ Root = $root; Mode = 'EmptyCore'; KillFaultB64 = (ConvertTo-B64 $case.Fault) }
        $exited = $p.WaitForExit(90000); $code = $(if ($exited) { $p.ExitCode } else { -999 }); if (-not $exited) { try { $p.Kill() } catch { } }
        $treeKill = Get-I2AFullTree $layout
        [void](Assert-I2A "TK-$($case.Id)-killed-and-equal" (($fired.Length -gt 0) -and $exited -and ($code -ne 0) -and ($code -ne 7) -and (Same $treeModel $treeKill)) "model fired '$fired'; child exit $code; tree equal to the crash model ($(Diff3 $treeModel $treeKill))")
        $rec = DgTx-Recover -StateRoot $layout.State -BackupRoot $layout.Backup -Policy $layout.Policy
        $after = Get-I2AFullTree $layout
        $want = $(if ($case.Forward) { 'RolledForward' } else { 'RolledBack' })
        $expectTree = $(if ($case.Forward) { $postTree } else { $preTree })
        $rec2 = DgTx-Recover -StateRoot $layout.State -BackupRoot $layout.Backup -Policy $layout.Policy
        $cmp = @(Compare-I2ATree $expectTree $after | Where-Object { $_ -notmatch '\\(txn|history)(\\|$)' })
        [void](Assert-I2A "TK-$($case.Id)-recovery" ((($rec.Outcome -eq $want) -or ($case.Id -eq 'KE04-committed' -and $rec.Outcome -eq 'RolledForward')) -and ($cmp.Count -eq 0) -and ($rec2.Outcome -eq 'NotNeeded') -and ((Cnt (Test-I2ANoLeftovers $layout)) -eq 0)) "outcome=$($rec.Outcome) (want $want) tree diff=[$($cmp -join ' ')] second=$($rec2.Outcome)")
    }
    Uninstall-I2AHarness
} finally { Remove-I2ASandbox $root }
Complete-I2ATests
