# I3 world I (PCSX2 1.6.0 / LilyPad.ini install with explicit consent): F-D2 formalized. Today the existing I3-Fault only RECORDS the TOCTOU-WINDOW
# (points between the end of the Origin backup copy and the replacement of LilyPad.ini); here every point of that window is asserted:
# a third-party change of LilyPad.ini injected at the point must never be overwritten and the run must not report success.
# RED stage: run WITHOUT -Contract. After the GREEN implementation: run WITH -Contract (plain PASS / FAIL).
param([switch]$Contract, [string]$EvidenceDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2A.Toctou.TestSupport.ps1')
$script:TxContract = [bool]$Contract
$script:TxName = 'I3-Toctou'
Use-I2BHarnessIds
$activeV1 = 'DENGO-ACTIVE-LILYPAD-V1'
$tamperText = 'CHANGED-BY-PCSX2-AFTER-THE-PLAN'

function New-Failure([string]$Message) { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = $Message; RollbackState = 'NotStarted'; ManualCheckRequired = $false; Recovery = $null; Reasons = @(); AlreadyUninstalled = $false; StateCommitted = $false; Results = @(); Blocking = @(); UsedBackups = @(); TransactionId = '' } }
function New-Plan($L, [bool]$Consent = $true) {
    $root = Split-Path $L.Pcsx2Inis -Parent
    $res = [pscustomobject]@{ Status = 'Resolved'; SelectedRoot = $root; Roots = @($root); Detected = @() }
    $us = Read-DenGoUninstalledState $L.Product
    return , [object[]](New-DenGoPcsx2PlanItems -Resolution $res -LilySource (Join-Path $L.Src 'lily.src') -ActiveSource (Join-Path $L.Src 'active.src') -ReplaceConsent $Consent -Previous (Read-DenGoPreviousState $L.Product) -Layout $L.Product -LastClosedTransactionId ([string]$us.LastClosedTransactionId))
}
function Run-Install($L, $Plan) { try { return (Invoke-I3Install $L ([object[]]$Plan)) } catch { return (New-Failure ([string]$_.Exception.Message)) } }

$L = New-I3Case 'toctou-i'
Assert-I2AInsideSandbox $L.Root @($L.Local, $L.Public, $L.Bve5, $L.Bve6, $L.Rpcs3, $L.Pcsx2Inis, $L.Desktop, $L.Stage, $L.Product.StatePath)
$snap = Save-I2ATree $L.Root
Install-I2AHarness
Reset-I2AFault; Reset-I2ACounters
$script:i3Tamper = Get-I3Dest $L 'LilyPad.ini'
function Reset-W { Release-I2AHeld; Restore-I2ATree $L.Root $snap; Reset-I2AFault; $global:I2AFH.IdCounter = 0; $global:I2AFH.Tick = 100 }

# ---- census of the clean install (labels come from the real primitives; no number is typed in)
Reset-W
$plan = New-Plan $L $true
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = 0
$r = Run-Install $L $plan
$fh = $global:I2AFH
$labels = @($fh.AllLabels); $mutN = [int]$fh.Mut; $allN = [int]$fh.All
Assert-Tx 'I3-00-clean-install-with-consent-succeeds-and-replaces-LilyPad.ini' 'GUARD' '' (($r.Succeeded -eq $true) -and ((Txt $script:i3Tamper) -ceq $activeV1)) "succeeded=$($r.Succeeded) code=$($r.ErrorCode) mutating=$mutN all=$allN LilyPad.ini=[$(Txt $script:i3Tamper)]"
$iBakBefore = Get-TxIdx $labels '^before:Fs-CopyFileDurable:[^:]*\.bak$'
$iBakAfter = Get-TxIdx $labels '^after:Fs-CopyFileDurable:[^:]*\.bak$'
$iSwap = Get-TxIdx $labels '^before:Fs-Replace:LilyPad\.ini$'
Assert-Tx 'I3-01-the-origin-backup-copy-and-the-replacement-are-in-the-census' 'GUARD' '' (($iBakBefore -ge 0) -and ($iBakAfter -gt $iBakBefore) -and ($iSwap -gt $iBakAfter)) "backup copy before@$($iBakBefore + 1) after@$($iBakAfter + 1), replacement@$($iSwap + 1) of $allN points"
$prefixTo = $iBakBefore + 1            # every point up to the START of the Origin backup copy (protected today)
$winFrom = $iBakAfter + 1              # the first point after the backup copy has read the file
$winTo = $iSwap + 1                    # the point right before the replacement
Add-TxEvidence @{ id = 'WINDOW-I3-REPLACE'; census = @{ mutating = $mutN; all = $allN }; protectedPrefixTo = $prefixTo; windowFrom = $winFrom; windowTo = $winTo; points = ($winTo - $winFrom + 1); windowLabels = @($labels[$iBakAfter..$iSwap]) }
if (-not $Contract) { Assert-Tx 'I3-WIN-census-HEAD-baseline-the-Replace-window-has-20-points-196-215' 'CHAR' '' ((($winTo - $winFrom + 1) -eq 20) -and ($winFrom -eq 196) -and ($winTo -eq 215) -and ($mutN -eq 60) -and ($allN -eq 280)) "window $winFrom..$winTo = $($winTo - $winFrom + 1) points; census mutating=$mutN all=$allN (HEAD baseline; changes after the fix, therefore skipped under -Contract)" } else { Write-Host ("DIAG | I3-WIN-census-current | HEAD baseline row skipped under -Contract (kept as history in the non-contract mode). Current observation: Replace window $winFrom..$winTo = $($winTo - $winFrom + 1) points; census mutating=$mutN all=$allN (HEAD baseline: 20 points 196..215; census 60/280)"); Add-TxEvidence @{ id = 'I3-WIN-census-current'; baselineHead = '20 points 196..215; 60/280'; observed = ('{0}..{1}={2} points; {3}/{4}' -f $winFrom, $winTo, ($winTo - $winFrom + 1), $mutN, $allN) } }

function Invoke-Tamper([int]$K) {
    Reset-W
    $p = New-Plan $L $true
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($K)) -Action 'Callback' -Callback { [System.IO.File]::WriteAllText($script:i3Tamper, 'CHANGED-BY-PCSX2-AFTER-THE-PLAN', [System.Text.Encoding]::ASCII) }
    $global:I2AFH.IdCounter = 0
    $res = Run-Install $L $p
    return @{ R = $res; Fired = [string]$global:I2AFH.Fired; Now = (Txt $script:i3Tamper) }
}
function Test-Protected($T) {
    $res = $T.R; $cls = [string]$res.ErrorCode
    $ok = ($T.Fired.Length -gt 0) -and ($T.Now -ceq $tamperText) -and ($res.Succeeded -eq $false) -and (($cls -eq 'PlanStale') -or ($res.ManualCheckRequired -eq $true))
    if ($cls -eq 'PlanStale') { $ok = $ok -and (-not [System.IO.File]::Exists((Get-I3Dest $L 'DenGo-Controller-Converter.lily'))) -and (-not [System.IO.File]::Exists($L.Product.StatePath)) }
    return $ok
}

# ---- the protected prefix (195 points today): never overwritten, never success - and the same classes as today
$bad = New-Object System.Collections.ArrayList; $classes = @{}
for ($k = 1; $k -le $prefixTo; $k++) {
    $t = Invoke-Tamper $k
    $cls = [string]$t.R.ErrorCode
    if ($classes.ContainsKey($cls)) { $classes[$cls]++ } else { $classes[$cls] = 1 }
    if (-not (Test-Protected $t)) { [void]$bad.Add(('{0}:{1}' -f $k, $labels[$k - 1])) }
}
$classText = (($classes.Keys | Sort-Object | ForEach-Object { $_ + '=' + $classes[$_] }) -join ', ')
Assert-Tx 'I3-PREFIX-the-points-up-to-the-start-of-the-origin-backup-copy-stay-protected' 'GUARD' '' ($bad.Count -eq 0) "points 1..$prefixTo unprotected: $($bad.Count) $(($bad | Select-Object -First 3) -join ' ')"
if (-not $Contract) { Assert-Tx 'I3-PREFIX-classes-are-the-same-as-today' 'CHAR' '' ($classText -ceq 'DestinationChangedDuringApply=80, PlanStale=101, RecoveryRequired=14') "classes: $classText (HEAD baseline; the split may change after the fix, therefore skipped under -Contract)" } else { Write-Host ("DIAG | I3-PREFIX-classes-current | HEAD baseline row skipped under -Contract (kept as history in the non-contract mode). Current observation: classes $classText (HEAD baseline: DestinationChangedDuringApply=80, PlanStale=101, RecoveryRequired=14)"); Add-TxEvidence @{ id = 'I3-PREFIX-classes-current'; baselineHead = 'DestinationChangedDuringApply=80, PlanStale=101, RecoveryRequired=14'; observed = $classText } }

# ---- F-D2: every point of the window must be protected (RED today: 20 of 20 overwritten)
for ($k = $winFrom; $k -le $winTo; $k++) {
    $t = Invoke-Tamper $k
    $res = $t.R; $now = $t.Now
    $obs = $(if ($res.Succeeded -and ($now -cne $tamperText)) { 'silent-overwrite' } else { 'other:code=' + $res.ErrorCode })
    Assert-Tx ('I3-WIN-k{0:D2}-point{1}-LilyPad.ini-change-is-never-overwritten' -f ($k - $winFrom + 1), $k) 'RED' 'silent-overwrite' (Test-Protected $t) $obs ("label=$($labels[$k - 1]) fired=[$($t.Fired)] succeeded=$($res.Succeeded) code=$($res.ErrorCode) LilyPad.ini=[$now]")
}

Uninstall-I2AHarness
try { Remove-I2ASandbox $L.Root } catch { }
Complete-TxTests $EvidenceDir
