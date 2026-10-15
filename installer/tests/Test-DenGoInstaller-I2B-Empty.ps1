# I2-B: fault-injection suite for the empty (state-only) core transaction (DgTx-Run -AllowEmptyTransaction).
# Same method as the I2-A fault suite: crash at every mutating point -> DgTx-Recover; exception at every point -> runtime rollback.
# The state must be committed through the factory, CommitIntent and the atomic replace even though there are no items.
param([int]$Stride = 1, [string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')
function Cnt($X) { if ($null -eq $X) { return 0 }; return @($X).Count }
function Same($A, $B) { return ((Cnt (Compare-I2ATree $A $B)) -eq 0) }
function Diff3($A, $B) { return ([string]::Join(' ', [string[]]@(Compare-I2ATree $A $B | Select-Object -First 3))) }
function Get-Sample([int]$Count, [int]$Step) {
    $list = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Count; $i += [Math]::Max(1, $Step)) { [void]$list.Add($i) }
    if (($Count -gt 0) -and ($list[$list.Count - 1] -ne $Count)) { [void]$list.Add($Count) }
    return , @($list)
}
$newBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes('state-empty-v2')
$factory = { param($c) return ,$newBytes }
function Invoke-Empty($Layout) { return (DgTx-Run -StateRoot $Layout.State -BackupRoot $Layout.Backup -Operation 'Install' -Items @() -Policy $Layout.Policy -NewStatePath $Layout.StatePath -NewStateFactory $factory -AllowEmptyTransaction) }
function Test-Committed($Layout) { return ([System.IO.File]::Exists($Layout.StatePath) -and ([System.IO.File]::ReadAllText($Layout.StatePath) -eq 'state-empty-v2')) }

$ctx = @{}
foreach ($sc in 'F4', 'F1') {      # F4: a state file exists (atomic Replace); F1: none yet (atomic Move)
    $root = New-I2ASandbox ('empty-' + $sc)
    $layout = New-I2AFixture $root $sc
    $ctx[$sc] = @{ Root = $root; Layout = $layout; Pristine = (Save-I2ATree $root); Pre = (Get-I2AManagedTree $layout) }
}
Install-I2AHarness
try {
    foreach ($sc in 'F4', 'F1') {
        $c = $ctx[$sc]; $layout = $c.Layout
        $reset = { Release-I2AHeld; Restore-I2ATree $c.Root $c.Pristine }
        & $reset
        Reset-I2AFault -Record $true; Reset-I2ACounters
        $r = Invoke-Empty $layout
        $fh = $global:I2AFH
        $mutN = [int]$fh.Mut; $allN = [int]$fh.All
        $c.Post = Get-I2AManagedTree $layout
        $stages = @(((Get-I2AJournalText $layout) -split ': ')[1])
        [void](Assert-I2A "EC-$sc-clean-run" (($r.Succeeded -eq $true) -and (Test-Committed $layout) -and ((Cnt (Test-I2ANoLeftovers $layout)) -eq 0) -and ($stages[0] -eq 'Begin,CommitIntent,Committed')) "succeeded=$($r.Succeeded) stages=$($stages[0]) mutPoints=$mutN allPoints=$allN")
        [void](Assert-I2A "EC-$sc-only-the-state-differs" (@(Compare-I2ATree $c.Pre $c.Post | Where-Object { $_ -notlike '*d:*' }).Count -le 1) ("diff=[$(Diff3 $c.Pre $c.Post)]"))
        # the factory is mandatory and no commit happens without it
        & $reset
        Reset-I2AFault; Reset-I2ACounters
        $nf = DgTx-Run -StateRoot $layout.State -BackupRoot $layout.Backup -Operation 'Install' -Items @() -Policy $layout.Policy -NewStatePath $layout.StatePath -NewStateBytes $newBytes -AllowEmptyTransaction
        [void](Assert-I2A "EC-$sc-factory-mandatory" (($nf.Succeeded -eq $false) -and ($nf.Code -eq 'PlanInvalid') -and (Same $c.Pre (Get-I2AManagedTree $layout)) -and (-not [System.IO.Directory]::Exists((Join-Path $layout.State 'txn')) -or (@([System.IO.Directory]::GetDirectories((Join-Path $layout.State 'txn'))).Count -eq 0))) "code=$($nf.Code): state bytes alone are refused")
        # crash sweep
        $fail = 0; $ran = 0
        foreach ($k in (Get-Sample $mutN $Stride)) {
            & $reset
            Reset-I2AFault -Mode 'CrashMut' -Targets ([int[]]@($k)); Reset-I2ACounters
            try { $null = Invoke-Empty $layout } catch { }
            $fired = [string]$global:I2AFH.Fired
            Resume-I2AAfterCrash
            $forward = Test-Committed $layout
            $rec = DgTx-Recover -StateRoot $layout.State -BackupRoot $layout.Backup -Policy $layout.Policy
            $map = Get-I2AManagedTree $layout
            $rec2 = DgTx-Recover -StateRoot $layout.State -BackupRoot $layout.Backup -Policy $layout.Policy
            $want = $(if ($forward) { $c.Post } else { $c.Pre })
            $okOutcome = $(if ($forward) { @('RolledForward', 'NotNeeded') -contains $rec.Outcome } else { @('RolledBack', 'NotNeeded') -contains $rec.Outcome })
            $ok = (($fired.Length -gt 0) -and $okOutcome -and (Same $want $map) -and ($rec2.Outcome -eq 'NotNeeded') -and ((Cnt (Test-I2ANoLeftovers $layout)) -eq 0))
            # and the next empty run works from whatever the recovery left
            if ($ok -and -not $forward) { $global:I2AFH.IdCounter = 100; $again = Invoke-Empty $layout; $ok = (($again.Succeeded -eq $true) -and (Test-Committed $layout)) }
            $ran++
            if (-not $ok) { $fail++; Add-I2AResult "EC-$sc-crash-k$k" $false ("fired=$fired outcome=$($rec.Outcome) forward=$forward diff=[$(Diff3 $want $map)] second=$($rec2.Outcome)") }
        }
        if ($fail -eq 0) { Add-I2AResult "EC-$sc-crash-sweep" $true "crash at $ran of $mutN mutating points: recovery ended in the old state (before the atomic replace) or the new state (after it); idempotent; the next run works" }
        # exception sweep
        $failT = 0; $ranT = 0
        foreach ($k in (Get-Sample $allN $Stride)) {
            & $reset
            Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; Reset-I2ACounters
            $r = Invoke-Empty $layout
            $map = Get-I2AManagedTree $layout
            $rb = [string]$r.RollbackState
            $okT = $false
            if ($r.Succeeded) { $okT = ((Same $c.Post $map) -and (Test-Committed $layout)) } elseif (@('RolledBack', 'NotStarted') -contains $rb) { $okT = ((Same $c.Pre $map) -and -not (Test-Committed $layout)) }
            $okT = ($okT -and ((Cnt (Test-I2ANoLeftovers $layout)) -eq 0) -and (([string]$global:I2AFH.Fired).Length -gt 0))
            $ranT++
            if (-not $okT) { $failT++; Add-I2AResult "EC-$sc-throw-k$k" $false ("fired=$($global:I2AFH.Fired) code=$($r.Code) rb=$rb succeeded=$($r.Succeeded) diff=[$(Diff3 $c.Pre $map)]") }
        }
        if ($failT -eq 0) { Add-I2AResult "EC-$sc-throw-sweep" $true "IO exception at $ranT of $allN points: always rolled back to the old state, or committed to the new one; nothing left behind" }
    }
} finally {
    Uninstall-I2AHarness
    foreach ($sc in $ctx.Keys) { Remove-I2ASandbox $ctx[$sc].Root }
}
Complete-I2ATests
