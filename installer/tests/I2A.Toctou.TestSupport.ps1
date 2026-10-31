# Shared helpers for the I2-A TOCTOU contract tests (RED / GUARD / CHAR). ASCII only. Dot-source AFTER DenGoInstallerTransaction.ps1 and I2A.TestSupport.ps1.
# Writes only below sandboxes under TEMP. Never touches product paths, the registry or any third-party application.
#
# Every assertion states the CONTRACT (what must hold after the TOCTOU fix) and carries a class:
#   RED    the contract is not implemented yet: the assertion FAILS on the current core, for the stated reason (ExpectReason). The observed reason is
#          computed from the real state; a failure with another reason is UNEXPECTED-REASON, an unexpected pass is UNEXPECTED-PASS.
#   GUARD  holds on the current core and must keep holding after the fix.
#   CHAR   characterizes a known limitation that is deliberately out of scope for this fix (Commit state replacement, RestoreItem Restore / RemoveNew,
#          the safe part of RestoreDeleted). Holds now and must keep holding.
# With -Contract the script prints plain PASS / FAIL for every assertion and exits non-zero on any FAIL (use this after the GREEN implementation).
$script:TxRows = New-Object System.Collections.ArrayList
$script:TxContract = $false
$script:TxEvidence = New-Object System.Collections.ArrayList
$script:TxRoots = New-Object System.Collections.ArrayList
function Remove-TxSandboxes { foreach ($r in @($script:TxRoots)) { try { Remove-I2ASandbox $r } catch { } } }
$script:TxUtf8 = New-Object System.Text.UTF8Encoding($false)

function Assert-Tx {
    param([string]$Id, [string]$Class, [string]$ExpectReason, [bool]$Cond, [string]$Obs, [string]$Detail)
    # GUARD / CHAR calls pass the detail text as the fifth argument (they have no observed reason)
    if (-not $PSBoundParameters.ContainsKey('Detail')) { $Detail = $Obs; $Obs = '' }
    $status = ''
    if ($Class -ceq 'RED') {
        if ($Cond) { $status = 'UNEXPECTED-PASS' }
        elseif ($Obs -ceq $ExpectReason) { $status = 'RED-CONFIRMED' }
        else { $status = 'UNEXPECTED-REASON' }
    } else {
        if ($Cond) { $status = 'OK' } else { $status = 'UNEXPECTED-FAIL' }
    }
    [void]$script:TxRows.Add([pscustomobject]@{ Id = $Id; Class = $Class; Expect = $ExpectReason; Cond = $Cond; Obs = $Obs; Status = $status; Detail = $Detail })
    if ($script:TxContract) { Write-Host (('{0} | {1} | {2}' -f $(if ($Cond) { 'PASS' } else { 'FAIL' }), $Id, $Detail)) }
    else { Write-Host (('{0} | {1} | {2} | exp={3} obs={4} | {5}' -f $status, $Id, $Class, $ExpectReason, $Obs, $Detail)) }
}
function Add-TxEvidence([hashtable]$Rec) { [void]$script:TxEvidence.Add([pscustomobject]$Rec) }
function Complete-TxTests {
    param([string]$EvidenceDir = '')
    $rows = @($script:TxRows)
    $red = @($rows | Where-Object { $_.Class -ceq 'RED' }); $guard = @($rows | Where-Object { $_.Class -ceq 'GUARD' }); $char = @($rows | Where-Object { $_.Class -ceq 'CHAR' })
    $bad = @($rows | Where-Object { $_.Status -like 'UNEXPECTED*' })
    Write-Host ''
    if ($script:TxContract) {
        $f = @($rows | Where-Object { -not $_.Cond }).Count
        Write-Host ('CONTRACT PASS={0} FAIL={1}' -f ($rows.Count - $f), $f)
        if ($EvidenceDir.Length -gt 0) { Save-TxEvidence $EvidenceDir }
        if ($f -ne 0) { exit 1 }; exit 0
    }
    Write-Host ('ASSERTIONS={0} RED={1} (confirmed={2}) GUARD={3} (ok={4}) CHAR={5} (ok={6}) UNEXPECTED={7}' -f $rows.Count, $red.Count, @($red | Where-Object { $_.Status -ceq 'RED-CONFIRMED' }).Count, $guard.Count, @($guard | Where-Object { $_.Status -ceq 'OK' }).Count, $char.Count, @($char | Where-Object { $_.Status -ceq 'OK' }).Count, $bad.Count)
    $reasons = @{}; foreach ($r in $red) { if ($r.Status -ceq 'RED-CONFIRMED') { if ($reasons.ContainsKey($r.Expect)) { $reasons[$r.Expect]++ } else { $reasons[$r.Expect] = 1 } } }
    Write-Host ('RED-BY-REASON ' + (($reasons.Keys | Sort-Object | ForEach-Object { $_ + '=' + $reasons[$_] }) -join ' '))
    if ($EvidenceDir.Length -gt 0) { Save-TxEvidence $EvidenceDir }
    if ($bad.Count -ne 0) { foreach ($b in $bad) { Write-Host ('UNEXPECTED ' + $b.Id + ' ' + $b.Status) }; exit 1 }
    exit 0
}
function Save-TxEvidence([string]$Dir) {
    [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.ScriptName)
    $p = Join-Path $Dir ('rows-' + $script:TxName + '.json')
    ConvertTo-Json -InputObject @($script:TxRows | ForEach-Object { [ordered]@{ id = $_.Id; cls = $_.Class; expect = $_.Expect; cond = $_.Cond; obs = $_.Obs; status = $_.Status; detail = $_.Detail } }) -Depth 4 | Set-Content -LiteralPath $p -Encoding UTF8
    $e = Join-Path $Dir ('evidence-' + $script:TxName + '.json')
    ConvertTo-Json -InputObject @($script:TxEvidence) -Depth 6 | Set-Content -LiteralPath $e -Encoding UTF8
}

# ---------------------------------------------------------------- several third-party injections on top of the I2A fault harness (the harness itself is not modified)
$global:TxInj = @()
$global:TxOrigPoint = (Get-Command Invoke-I2APoint -CommandType Function).ScriptBlock
function global:Invoke-I2APoint([string]$Name, [string]$Label, [bool]$Mut) {
    foreach ($j in @($global:TxInj)) {
        if (-not $j.Done -and $Label -match $j.Pattern) {
            $j.Seen++
            if ($j.Seen -eq $j.Nth) { $j.Done = $true; $j.FiredAt = $Label; & $j.Action }
        }
    }
    & $global:TxOrigPoint $Name $Label $Mut
}
function Add-TxInj([string]$Pattern, [int]$Nth, [scriptblock]$Action) { $global:TxInj = @($global:TxInj) + @(@{ Pattern = $Pattern; Nth = $Nth; Action = $Action; Seen = 0; Done = $false; FiredAt = '' }) }
function Clear-TxInj { $global:TxInj = @() }
function Get-TxInjFired([int]$Index) { return [bool]@($global:TxInj)[$Index].Done }

# ---------------------------------------------------------------- third-party actions (plain .NET only; they run inside the fault harness)
function TP-Write([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, [System.Text.Encoding]::ASCII) }
function TP-Delete([string]$Path) { [System.IO.File]::Delete($Path) }
function TP-Rename([string]$Path, [string]$Text) {
    $o = $Path + '.tp-other'
    [System.IO.File]::WriteAllText($o, $Text, [System.Text.Encoding]::ASCII)
    [System.IO.File]::Replace($o, $Path, [System.Management.Automation.Language.NullString]::Value)
}
function Txt([string]$Path) { if ([System.IO.File]::Exists($Path)) { return [System.IO.File]::ReadAllText($Path) }; return '<missing>' }

# ---------------------------------------------------------------- the displaced-file name ORACLE (the contract's derivation inputs: normalized destination, transaction id, item id, dedicated suffix)
# The final string is chosen at implementation time (contract 0A.5). This is the single place a test needs to know it: if the implementation picks another
# layout, change THIS function (and nothing else). Every other assertion is role-based.
function Get-TxDisplaced([string]$Norm, [string]$TxnId, [int]$ItemId) { return ($Norm + '.' + $TxnId + '.' + ('{0:D4}' -f $ItemId) + '.dengo.old') }

# ---------------------------------------------------------------- fixtures
# Spec items: @{ Rel = 'd\a.dll'; Op = 'Write'|'Delete'; Pre = 'text'|$null; Post = 'text'|$null }
function New-TxFx {
    param([string]$Name, [object[]]$Spec, [string]$Operation = 'Install')
    $root = New-I2ASandbox ('tx-' + $Name)
    [void]$script:TxRoots.Add($root)
    foreach ($d in 'Src', 'Dest', 'State', 'Backup') { [System.IO.Directory]::CreateDirectory((Join-Path $root $d)) | Out-Null }
    $items = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($s in $Spec) {
        $dest = Join-Path (Join-Path $root 'Dest') $s.Rel
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dest)) | Out-Null
        if ($null -ne $s.Pre) { [System.IO.File]::WriteAllText($dest, [string]$s.Pre, $script:TxUtf8) }
        $src = ''
        if ($s.Op -ceq 'Write') { $src = Join-Path $root ('Src\{0}.src' -f $i); [System.IO.File]::WriteAllText($src, [string]$s.Post, $script:TxUtf8) }
        [void]$items.Add(@{ Op = $s.Op; Destination = $dest; Source = $src; OwnershipCandidate = 'CreatedByInstaller'; Tag = ('i' + $i) })
        $i++
    }
    $statePath = Join-Path $root 'State\installed-state.json'
    [System.IO.File]::WriteAllText($statePath, 'state-v1', $script:TxUtf8)
    return [pscustomobject]@{
        Root = $root; Dest = (Join-Path $root 'Dest'); State = (Join-Path $root 'State'); Backup = (Join-Path $root 'Backup'); StatePath = $statePath
        Policy = (DgPolicy-New @($root) 'Reject'); Items = @($items.ToArray()); Operation = $Operation; Pristine = (Save-I2ATree $root)
    }
}
function Reset-TxFx($Fx) { Release-I2AHeld; Clear-TxInj; Restore-I2ATree $Fx.Root $Fx.Pristine; Reset-I2AFault; Reset-I2ACounters }
function Invoke-TxRun($Fx, [object[]]$Items = $null) {
    $it = $(if ($null -ne $Items) { $Items } else { $Fx.Items })
    return (DgTx-Run -StateRoot $Fx.State -BackupRoot $Fx.Backup -Operation $Fx.Operation -Items $it -Policy $Fx.Policy -NewStatePath $Fx.StatePath -NewStateBytes ($script:TxUtf8.GetBytes('state-v2')))
}
function Invoke-TxRecover($Fx) { return (DgTx-Recover -StateRoot $Fx.State -BackupRoot $Fx.Backup -Policy $Fx.Policy) }
# One apply run with optional injections (set up by $Setup after the reset) and fault arguments for the harness.
function Invoke-TxCase {
    param($Fx, [scriptblock]$Setup = $null, [hashtable]$Fault = @{})
    Reset-TxFx $Fx
    if ($null -ne $Setup) { & $Setup }
    Reset-I2AFault @Fault
    Reset-I2ACounters
    $r = $null; $err = ''
    try { $r = Invoke-TxRun $Fx } catch { $err = [string]$_.Exception.Message }
    return @{ R = $r; Err = $err; Fired = [string]$global:I2AFH.Fired; Labels = @($global:I2AFH.AllLabels) }
}
# A frozen state: a simulated crash at the first label matching $CrashPattern, then the process "dies" (handles released), then the hand edits $Hand.
function Build-TxFrozen {
    param($Fx, [string]$CrashPattern, [int]$Nth = 1, [scriptblock]$Setup = $null, [scriptblock]$Hand = $null)
    Reset-TxFx $Fx
    if ($null -ne $Setup) { & $Setup }
    Reset-I2AFault -Mode 'Label' -Pattern $CrashPattern -Nth $Nth -Action 'Crash'
    Reset-I2ACounters
    try { $null = Invoke-TxRun $Fx } catch { }
    $fired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $injFired = @($global:TxInj | ForEach-Object { [bool]$_.Done })
    Clear-TxInj
    if ($null -ne $Hand -and $fired.Length -gt 0) { & $Hand }
    return @{ Fired = $fired; InjFired = $injFired }
}

# ---------------------------------------------------------------- observations
function Test-TxMarker($Fx) { return ([System.IO.File]::Exists((Join-Path $Fx.State 'installing.json')) -or [System.IO.File]::Exists((Join-Path $Fx.State 'uninstalling.json'))) }
function Get-TxResidue($Fx) { return @([System.IO.Directory]::GetFileSystemEntries($Fx.Dest, '*.dengo.old', [System.IO.SearchOption]::AllDirectories)) }
function Get-TxTmp($Fx) { return @([System.IO.Directory]::GetFiles($Fx.Dest, '*.dengo.tmp', [System.IO.SearchOption]::AllDirectories)) }
function Get-TxMap($Fx) { return (Get-I2ATreeMap $Fx.Root @('state\txn', 'state\history')) }
function Get-TxChanged($A, $B) { return @(Compare-I2ATree $A $B).Count }
function Get-TxDiff($A, $B) { return ([string]::Join(' ', [string[]]@(Compare-I2ATree $A $B | Select-Object -First 4))) }
function Get-TxIdx([string[]]$Labels, [string]$Rx, [int]$From = 0) { for ($i = $From; $i -lt $Labels.Count; $i++) { if ($Labels[$i] -match $Rx) { return $i } }; return -1 }
function Invoke-TxRecover2($Fx) {
    $m0 = Get-TxMap $Fx
    $r1 = Invoke-TxRecover $Fx
    $m1 = Get-TxMap $Fx; $marker1 = Test-TxMarker $Fx
    $r2 = Invoke-TxRecover $Fx
    $m2 = Get-TxMap $Fx
    return @{ R1 = $r1; R2 = $r2; M0 = $m0; M1 = $m1; M2 = $m2; Marker1 = $marker1 }
}
function New-TxJunction([string]$Link, [string]$Target) {
    [System.IO.Directory]::CreateDirectory($Target) | Out-Null
    $null = & cmd.exe /c ('mklink /J "' + $Link + '" "' + $Target + '"')
    if (-not [System.IO.Directory]::Exists($Link)) { throw ('junction not created: ' + $Link) }
}
function Get-TextSha([string]$Text) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($s.ComputeHash($script:TxUtf8.GetBytes($Text.Replace("`r`n", "`n"))))).Replace('-', '') } finally { $s.Dispose() }
}
