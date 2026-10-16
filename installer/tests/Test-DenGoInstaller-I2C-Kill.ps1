# I2-C real-process kill tests for the product uninstall. Each case:
#   (1) in-process crash model at point P  -> tree T1 and journal stages S1
#   (2) the same scenario in a child process that TerminateProcess-es ITSELF at P -> T2, S2   (T1 == T2, S1 == S2 proves the model)
#   (3) recovery from the real kill state through the product uninstall (recovery gate -> next run) and the expected end state
# Sandboxes under TEMP only. The real uninstaller, registry, BVE, PCSX2 and RPCS3 are never touched.
param([string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I2C.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2C-Report-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-i2c-kill.jsonl'
Use-I2BHarnessIds
$child = Join-Path $PSScriptRoot 'I2C.Child.ps1'
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

$L = New-I2CCase 'i2c-kill'
Install-I2AHarness
Reset-I2AFault; Reset-I2ACounters
$g = Install-I2CGeneration $L
[void](Assert-I2A 'K00-generation-installed' ($g.Succeeded -eq $true) "install succeeded=$($g.Succeeded)")
$snap = Save-I2ATree $L.Root
$T0 = Get-I2CTree $L -NormalizeState
function Reset-World { Release-I2AHeld; Restore-I2ATree $L.Root $snap; Reset-I2AFault; $global:I2AFH.IdCounter = 1; $global:I2AFH.Tick = 100 }
Reset-World
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = 1
$r = Invoke-I2CUninstall $L
$T1 = Get-I2CTree $L -NormalizeState
$lastId = @($global:I2AFH.AllLabels | Where-Object { $_ -match '^after:Journal:Register#\d+$' }).Count - 1
[void](Assert-I2A 'K00-clean-run' ($r.Succeeded -eq $true) "succeeded=$($r.Succeeded) lastItemId=$lastId")
Reset-World

$cases = @(
    @{ Id = 'K01-register-last'; Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Register#' + $lastId + '$'); Nth = 1 } },
    @{ Id = 'K02-marker-published'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:uninstalling\.json$'; Nth = 1 } },
    @{ Id = 'K03-intent-first-item'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Intent#0$'; Nth = 1 } },
    @{ Id = 'K04-first-delete-done'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Delete:'; Nth = 1 } },
    @{ Id = 'K05-profile-restored'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Replace:Den-Go-Controller\.yml$'; Nth = 1 } },
    @{ Id = 'K06-set-boundary'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Verified#3$'; Nth = 1 } },
    @{ Id = 'K07-core-exe-deleted'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Delete:DenGoControllerConverter\.exe$'; Nth = 1 } },
    @{ Id = 'K08-history-archive-written'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:installed-state\.[0-9a-f]{64}\.json$'; Nth = 1 } },
    @{ Id = 'K09-installed-state-deleted'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Delete:installed-state\.json$'; Nth = 1 } },
    @{ Id = 'K10-verified-last'; Fault = @{ Mode = 'Label'; Pattern = ('^after:Journal:Verified#' + $lastId + '$'); Nth = 1 } },
    @{ Id = 'K11-commit-intent'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:CommitIntent$'; Nth = 1 } },
    @{ Id = 'K12-uninstalled-state-moved'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:uninstalled-state\.json$'; Nth = 1 } },
    @{ Id = 'K13-committed'; Fault = @{ Mode = 'Label'; Pattern = '^after:Journal:Committed$'; Nth = 1 } },
    @{ Id = 'K14-marker-deleted'; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-Delete:uninstalling\.json$'; Nth = 1 } },
    @{ Id = 'K15-recovery-mid'; Pre = @{ CrashPattern = '^after:Journal:Verified#3$' }; Fault = @{ Mode = 'Label'; Pattern = '^after:Fs-MoveNew:'; Nth = 2 } })

foreach ($case in $cases) {
    $id = $case.Id
    # ---- (1) in-process crash model
    Reset-World
    if ($case.ContainsKey('Pre')) {
        Reset-I2AFault -CrashPattern $case.Pre.CrashPattern; $global:I2AFH.IdCounter = 1
        try { $null = Invoke-I2CUninstall $L } catch { }
        Resume-I2AAfterCrash
        $preSnap = Save-I2ATree $L.Root
    } else { $preSnap = $snap }
    Reset-I2AFault -Mode $case.Fault.Mode -Pattern $case.Fault.Pattern -Nth $case.Fault.Nth -Action 'Crash'
    $global:I2AFH.IdCounter = 1
    try { $null = Invoke-I2CUninstall $L } catch { }
    $modelFired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $treeModel = Get-I2CTree $L -NormalizeState
    $stagesModel = Get-StageText $L
    # ---- (2) real kill
    Release-I2AHeld; Restore-I2ATree $L.Root $preSnap
    $params = @{ Root = $L.Root; Mode = 'Uninstall'; LockName = $lockName; KillFaultB64 = (ConvertTo-B64 $case.Fault); IdStart = 1 }
    $p = Start-Child $params
    $exited = $p.WaitForExit(180000)
    $code = $(if ($exited) { $p.ExitCode } else { -999 })
    if (-not $exited) { try { $p.Kill() } catch { } }
    $orphanFree = Test-NoOrphans $p.Id
    $killed = ($exited -and ($code -ne 0))
    $treeKill = Get-I2CTree $L -NormalizeState
    $stagesKill = Get-StageText $L
    [void](Assert-I2A "TK-$id-killed" (($modelFired.Length -gt 0) -and $killed -and $orphanFree) "model fired at '$modelFired'; child exit code $code; no surviving child or grandchild")
    [void](Assert-I2A "TK-$id-equivalence" ((Same $treeModel $treeKill) -and ($stagesModel -eq $stagesKill)) "tree after TerminateProcess == tree of the in-process crash model ($(Diff3 $treeModel $treeKill)); journal stages equal: $($stagesModel -eq $stagesKill)")
    # ---- (3) recovery from the real kill state
    $forward = ((Get-I2CTree $L -NormalizeState)['x:us'] -eq 'NEW')
    $markerThere = [System.IO.File]::Exists((Get-I2CUmPath $L))
    $isGone = (-not [System.IO.File]::Exists($L.Product.StatePath))
    $r1 = Invoke-I2CUninstall $L
    $map1 = Get-I2CTree $L -NormalizeState
    $ok1 = $true
    if ($markerThere) {
        $expect1 = $(if ($forward) { $T1 } else { $T0 })
        $ok1 = (($r1.Succeeded -eq $false) -and ($r1.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (Same $expect1 $map1))
    } elseif ($forward -and $isGone) { $ok1 = (($r1.Succeeded -eq $true) -and ($r1.AlreadyUninstalled -eq $true) -and (Same $T1 $map1)) }
    else { $ok1 = (($r1.Succeeded -eq $true) -and (Same $T1 $map1)) }
    $global:I2AFH.IdCounter = 100     # deterministic test ids must not collide with the ids used by the killed run
    $r2 = Invoke-I2CUninstall $L
    $map2 = Get-I2CTree $L -NormalizeState
    $ok2 = (($r2.Succeeded -eq $true) -and (Same $T1 $map2) -and ((Cnt (Test-I2CLeftovers $L)) -eq 0))
    $usNow = Get-I2CUs $L
    $oldUsed = $false
    foreach ($u in @($usNow.UsedBackups)) { if ($u.Path -notlike '*\T0001\*') { $oldUsed = $true } }
    [void](Assert-I2A "TK-$id-recovery" ($ok1 -and $ok2 -and (-not $oldUsed)) "marker=$markerThere forward=$forward first: code=$($r1.ErrorCode) ok=$ok1; second: succeeded=$($r2.Succeeded) tree==T1:$(Same $T1 $map2); only generation-1 backups used: $(-not $oldUsed)")
    [void](Assert-I2A "TK-$id-registration-gate" (($markerThere -eq $false) -or (($r1.Succeeded -eq $false) -and ($r1.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted'))) 'a recovery that only succeeded is never reported as a completed uninstall (no registration removal, no self-delete)')
    Add-I2AEvidence @{ id = "TK-$id"; fault = $modelFired; forward = $forward; markerAfterKill = $markerThere; firstOutcome = [string]$r1.ErrorCode; pass = ($killed -and $ok1 -and $ok2) }
}
Uninstall-I2AHarness
Remove-I2ASandbox $L.Root
Complete-I2ATests
