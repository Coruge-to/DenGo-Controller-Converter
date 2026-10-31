# I3 fault-injection suite (PCSX2 1.6.0 / LilyPad): the same sweep method as I2-B / I2-C (a recorded run counts the REAL primitives, the sweeps are built from that census - no number is typed in).
#   World I  install with an explicit consent (Origin backup, LilyPad.ini replacement, commit)          crash at every mutating point, exception at every point, named boundary cases
#   World P  promotion of an I2-B format PCSX2 record (DeferredThisRun -> Promoted) by an install        crash / exception sweeps, named boundary cases (before / after the state publication)
#   World U  uninstall of generation 2 (a CLOSED generation 1 with its own backup exists)                 crash / exception sweeps, restore before / after, generation end, no closed-generation backup, Origin bytes
#   World E  uninstall when the user EDITED LilyPad.ini after the install                                   the edited file is never touched at any point
#   Tamper   a change of LilyPad.ini between the plan and the write (every point before the replacement)  the file is never overwritten
#   Zero     unsupported / unverified / ambiguous PCSX2 under an exception at every read point                no write, no settings file is opened, never a silent choice of one root
# Principle checked everywhere: before the state is published the tree returns to T0 (Origin untouched); after it the tree moves forward to T1; Backups[0] is the only restore source; recovery is idempotent.
# Everything runs in sandboxes under %TEMP%. The real PCSX2, LilyPad.ini, Documents folder, registry and processes are never touched.
param([int]$Stride = 1, [string]$EvidenceDir = '', [switch]$SkipSweeps, [switch]$FullThrow)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI3-Fault-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-i3-fault.jsonl'
Write-Host ('Evidence directory: ' + $EvidenceDir)
Use-I2BHarnessIds
$activeV1 = 'DENGO-ACTIVE-LILYPAD-V1'; $lilyV1 = 'DENGO-LILY-PROFILE-V1'

function Get-Sample([int]$Count, [int]$Step) {
    $list = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Count; $i += [Math]::Max(1, $Step)) { [void]$list.Add($i) }
    if (($Count -gt 0) -and ($list[$list.Count - 1] -ne $Count)) { [void]$list.Add($Count) }
    return , @($list)
}
function Txt([string]$Path) { if (-not [System.IO.File]::Exists($Path)) { return '<missing>' } return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function New-Failure([string]$Message) { return [pscustomobject]@{ Succeeded = $false; ErrorCode = 'EXCEPTION'; ErrorMessage = $Message; RollbackState = 'NotStarted'; ManualCheckRequired = $false; Recovery = $null; Reasons = @(); AlreadyUninstalled = $false; StateCommitted = $false; Results = @(); Blocking = @(); UsedBackups = @(); TransactionId = '' } }

# ---------------------------------------------------------------- plans (the REAL planner, read-only, built OUTSIDE the fault window)
function New-Plan($L, [bool]$Consent = $true) {
    $root = Split-Path $L.Pcsx2Inis -Parent
    $res = [pscustomobject]@{ Status = 'Resolved'; SelectedRoot = $root; Roots = @($root); Detected = @() }
    $us = Read-DenGoUninstalledState $L.Product
    return , [object[]](New-DenGoPcsx2PlanItems -Resolution $res -LilySource (Join-Path $L.Src 'lily.src') -ActiveSource (Join-Path $L.Src 'active.src') -ReplaceConsent $Consent -Previous (Read-DenGoPreviousState $L.Product) -Layout $L.Product -LastClosedTransactionId ([string]$us.LastClosedTransactionId))
}
function Run-Install($L, $Plan) { try { return (Invoke-I3Install $L ([object[]]$Plan)) } catch { return (New-Failure ([string]$_.Exception.Message)) } }
function Run-Uninstall($L) { try { return (Invoke-I2CUninstall $L $false) } catch { return (New-Failure ([string]$_.Exception.Message)) } }

# ---------------------------------------------------------------- trees: the managed tree plus a signature of the PCSX2 records (a state is 'NEW' either way, so T0 and T1 of a promotion differ only here)
function Get-Sig($L, [bool]$KeepPromoted = $true) {
    $st = Get-I2BStateObject $L
    if ($null -eq $st) { return '<no installed-state>' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($f in @($st.Files)) {
        if ([string]$f.Platform -ne 'PCSX2') { continue }
        $pm = ''; if ($KeepPromoted) { $pm = '|P=' + $(if ($null -ne (Get-I3Prop $f 'Promoted' $null)) { '1' } else { '0' }) }
        [void]$parts.Add(([System.IO.Path]::GetFileName([string]$f.Destination) + '|' + [string]$f.Ownership + '|' + [string]$f.Presence + $pm + '|' + [string]$f.BeforeSHA256 + '|n=' + @($f.Backups).Count))
    }
    return ([string]::Join(';', [string[]]@($parts | Sort-Object)))
}
# Promoted is information of the promoting run only (the next install builds the record again), so later runs are compared without it (TreeX); the runs that promote are compared with it (Tree)
function TreeI($L, [bool]$KeepPromoted = $true) { $m = Get-I2BManagedTree $L -NormalizeState; $m['x:pcsx2sig'] = Get-Sig $L $KeepPromoted; return $m }
function TreeU($L, [bool]$KeepPromoted = $true) { $m = Get-I2CTree $L -NormalizeState; $m['x:pcsx2sig'] = Get-Sig $L $KeepPromoted; return $m }
function Tree($W) { if ($W.Kind -in @('U', 'E')) { return (TreeU $W.L) } return (TreeI $W.L) }
function TreeX($W) { if ($W.Kind -in @('U', 'E')) { return (TreeU $W.L $false) } return (TreeI $W.L $false) }
function UsSha($L) { $p = Get-I2CUsPath $L; if ([System.IO.File]::Exists($p)) { return (Get-I3Sha $p) } return '<none>' }
function Marker($W) { if ($W.Kind -in @('U', 'E')) { return [System.IO.File]::Exists((Get-I2CUmPath $W.L)) } return [System.IO.File]::Exists((Join-Path $W.L.Product.StateRoot 'installing.json')) }
function Clean($W) { if ($W.Kind -in @('U', 'E')) { return ((Cnt (Test-I2CLeftovers $W.L)) -eq 0) } return ((Cnt (Test-I2BLeftovers $W.L $false)) -eq 0) }
function Reset-World($W) { Release-I2AHeld; Restore-I2ATree $W.L.Root $W.Snap; Reset-I2AFault; $global:I2AFH.IdCounter = $W.Id0; $global:I2AFH.Tick = 100 }

# ---------------------------------------------------------------- invariants
# Origin: the LilyPad.ini record is ReplacedExisting, Backups[0] is the Origin (Backup == Backups[0].Path), the backup file holds exactly the user's content and nothing but Backups[0] is the Origin
function Test-Origin($L, [string]$OriginText) {
    $st = Get-I2BStateObject $L
    if ($null -eq $st) { return [pscustomobject]@{ Ok = $false; Detail = 'no installed-state' } }
    $rec = Get-I3Rec1 $st 'LilyPad.ini'
    if ($null -eq $rec) { return [pscustomobject]@{ Ok = $false; Detail = 'no LilyPad.ini record' } }
    $b = @($rec.Backups)
    $sha = Get-I3TextSha $OriginText
    $ok = ([string]$rec.Ownership -ceq 'ReplacedExisting') -and ($rec.ExistedBefore -eq $true) -and ($b.Count -ge 1) -and ([string]$rec.Backup -ceq [string]$b[0].Path) -and ([string]$rec.BeforeSHA256 -ceq $sha) -and ([string]$b[0].SHA256 -ceq $sha) -and [System.IO.File]::Exists([string]$rec.Backup) -and ((Get-I3Sha ([string]$rec.Backup)) -ceq $sha) -and (@($b | Select-Object -Skip 1 | Where-Object { [string]$_.Path -ceq [string]$rec.Backup }).Count -eq 0)
    return [pscustomobject]@{ Ok = $ok; Detail = ('ownership=' + $rec.Ownership + ' backups=' + $b.Count + ' origin file text=[' + (Txt ([string]$rec.Backup)) + ']') }
}
function Test-Final($W) {
    # what must hold when the world has been driven to its end state (T1) by recovery and re-runs
    $L = $W.L; $d = Get-I3Dest $L 'LilyPad.ini'
    switch ($W.Kind) {
        'I' { $o = Test-Origin $L $script:I3UserOrigin; return [pscustomobject]@{ Ok = ((Txt $d) -ceq $activeV1) -and $o.Ok; Detail = "LilyPad.ini=[$(Txt $d)] origin: $($o.Detail)" } }
        'P' {
            $st = Get-I2BStateObject $L; $recs = @($st.Files | Where-Object { [string]$_.Platform -eq 'PCSX2' })
            $same = ((ConvertTo-I3Json (Get-OriginView $W.Before)) -ceq (ConvertTo-I3Json (Get-OriginView $recs)))
            return [pscustomobject]@{ Ok = ($recs.Count -eq 2) -and (@($recs | Where-Object { [string]$_.Presence -ceq 'InPlan' }).Count -eq 2) -and $same; Detail = "PCSX2 records=$($recs.Count) in plan=$(@($recs | Where-Object { [string]$_.Presence -ceq 'InPlan' }).Count) (promoted=$(@($recs | Where-Object { $null -ne (Get-I3Prop $_ 'Promoted' $null) }).Count)) Origin and Backups byte-identical to before the promotion: $same" }
        }
        'U' { return [pscustomobject]@{ Ok = ((Txt $d) -ceq $W.Gen2Origin) -and ((Txt (Get-I3Dest $L 'DenGo-Controller-Converter.lily')) -ceq $lilyV1) -and [System.IO.File]::Exists($W.Gen1Backup); Detail = "LilyPad.ini=[$(Txt $d)] (generation 2 Origin=[$($W.Gen2Origin)]) generation 1 backup kept=$([System.IO.File]::Exists($W.Gen1Backup))" } }
        'E' { return [pscustomobject]@{ Ok = ((Txt $d) -ceq $W.Edited) -and ((Txt (Get-I3Dest $L 'DenGo-Controller-Converter.lily')) -ceq $lilyV1); Detail = "LilyPad.ini=[$(Txt $d)] (the user's edit=[$($W.Edited)])" } }
    }
}
function Get-OriginView($Recs) { return @(@($Recs) | ForEach-Object { [ordered]@{ Dest = [System.IO.Path]::GetFileName([string]$_.Destination); Ownership = [string]$_.Ownership; ExistedBefore = $_.ExistedBefore; BeforeSHA256 = [string]$_.BeforeSHA256; Backup = [string]$_.Backup; Backups = @($_.Backups) } } | Sort-Object { $_.Dest }) }
# the used backups of the uninstall of a world: only the Origin of THAT generation, never a closed generation's, never a Backups[1..] entry
function Test-UsedBackups($W) {
    if ($W.Kind -ne 'U') { return $true }
    $us = Get-I2CUs $W.L
    if ($null -eq $us) { return $true }
    foreach ($u in @($us.UsedBackups)) { if (([string]$u.Path -notlike ('*\' + $W.Gen2Dir + '\*')) -or ([string]$u.Path -like ('*\' + $W.Gen1Dir + '\*'))) { return $false } }
    return $true
}

# ---------------------------------------------------------------- the worlds (fixtures are built before the harness; generations that must carry harness ids are installed under it)
$worlds = [ordered]@{}
function New-World([string]$Kind, [string]$Name) {
    $L = New-I3Case $Name
    Assert-I2AInsideSandbox $L.Root @($L.Local, $L.Public, $L.Bve5, $L.Bve6, $L.Rpcs3, $L.Pcsx2Inis, $L.Desktop, $L.Stage, $L.Product.StatePath)
    return @{ Kind = $Kind; Name = $Name; L = $L; Id0 = 0; Snap = $null; T0 = $null; T1 = $null; MutN = 0; AllN = 0; MutLabels = @(); AllLabels = @() }
}
$WI = New-World 'I' 'fault-i'
$WI.Snap = Save-I2ATree $WI.L.Root
$WP = New-World 'P' 'fault-p'
$WU = New-World 'U' 'fault-u'
$WE = New-World 'E' 'fault-e'
Install-I2AHarness
Reset-I2AFault; Reset-I2ACounters

# ---- world I: census + T0 / T1
$WI.T0 = TreeI $WI.L
Reset-World $WI
$plan = New-Plan $WI.L $true
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = $WI.Id0
$r = Run-Install $WI.L $plan
$fh = $global:I2AFH; $WI.MutN = [int]$fh.Mut; $WI.AllN = [int]$fh.All; $WI.MutLabels = @($fh.MutLabels); $WI.AllLabels = @($fh.AllLabels)
$WI.T1 = TreeI $WI.L; $WI.T1o = TreeX $WI
$fin = Test-Final $WI
[void](Assert-I2A 'F-I-00-clean-install-census' (($r.Succeeded -eq $true) -and $fin.Ok -and (Clean $WI) -and (-not (Marker $WI))) ("succeeded=$($r.Succeeded) code=$($r.ErrorCode) mutating points=$($WI.MutN) all points=$($WI.AllN); $($fin.Detail)"))
[void](Assert-I2A 'F-I-01-the-census-names-the-origin-backup-and-the-replacement' ((@($WI.MutLabels | Where-Object { $_ -match '^before:Fs-CopyFileDurable:[^:]*\.bak$' }).Count -eq 1) -and (@($WI.MutLabels | Where-Object { $_ -eq 'before:Fs-Replace:LilyPad.ini' }).Count -eq 1) -and (@($WI.MutLabels | Where-Object { $_ -match '^before:Fs-(Replace|MoveNew):installed-state\.json$' }).Count -eq 1)) 'exactly one Origin backup copy, one LilyPad.ini replacement and one state publication were counted from the real primitives')
Add-I2AEvidence @{ id = 'CENSUS-I'; mutPoints = $WI.MutN; allPoints = $WI.AllN }

# ---- world P: a generation whose PCSX2 records are in the I2-B format (DeferredThisRun), then the install that promotes them
Reset-I2AFault; $global:I2AFH.IdCounter = 0
$rp =Run-Install $WP.L (New-Plan $WP.L $true)
Edit-I2CInstalledState $WP.L { param($o) foreach ($f in @($o.Files)) { if ([string]$f.Platform -eq 'PCSX2') { $f.Presence = 'DeferredThisRun' } } }
$WP.Id0 = 1; $WP.Snap = Save-I2ATree $WP.L.Root
$WP.Before = @((Get-I2BStateObject $WP.L).Files | Where-Object { [string]$_.Platform -eq 'PCSX2' })
$WP.T0 = TreeI $WP.L
Reset-World $WP
$plan = New-Plan $WP.L $false
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = $WP.Id0
$r = Run-Install $WP.L $plan
$fh = $global:I2AFH; $WP.MutN = [int]$fh.Mut; $WP.AllN = [int]$fh.All; $WP.MutLabels = @($fh.MutLabels); $WP.AllLabels = @($fh.AllLabels)
$WP.T1 = TreeI $WP.L; $WP.T1o = TreeX $WP
$fin = Test-Final $WP
$promotedNow = @((Get-I2BStateObject $WP.L).Files | Where-Object { [string]$_.Platform -eq 'PCSX2' -and $null -ne (Get-I3Prop $_ 'Promoted' $null) -and [string](Get-I3Prop (Get-I3Prop $_ 'Promoted' $null) 'FromFormat' '') -ceq 'I2B' -and [string](Get-I3Prop (Get-I3Prop $_ 'Promoted' $null) 'FromPresence' '') -ceq 'DeferredThisRun' }).Count
[void](Assert-I2A 'F-P-00-clean-promotion-census' (($rp.Succeeded -eq $true) -and ($r.Succeeded -eq $true) -and $fin.Ok -and ($promotedNow -eq 2) -and (-not (Same $WP.T0 $WP.T1)) -and (Clean $WP) -and (-not (Marker $WP))) ("setup install=$($rp.Succeeded) promotion run=$($r.Succeeded) code=$($r.ErrorCode) mutating points=$($WP.MutN) all points=$($WP.AllN); $($fin.Detail)"))
Add-I2AEvidence @{ id = 'CENSUS-P'; mutPoints = $WP.MutN; allPoints = $WP.AllN }

# ---- world U: generation 1 installed and uninstalled (CLOSED), the user edits LilyPad.ini, generation 2 installed; the uninstall of generation 2 is what is swept
$WU.Gen2Origin = 'USER-ORIGIN-OF-GENERATION-2'
Reset-I2AFault; $global:I2AFH.IdCounter = 0
$g1 =Run-Install $WU.L (New-Plan $WU.L $true)
$WU.Gen1Backup = [string](Get-I3Rec1 (Get-I2BStateObject $WU.L) 'LilyPad.ini').Backup
$u1 = Run-Uninstall $WU.L
[System.IO.File]::WriteAllText((Get-I3Dest $WU.L 'LilyPad.ini'), $WU.Gen2Origin, $script:Utf8)
$g2 = Run-Install $WU.L (New-Plan $WU.L $true)
$WU.Gen2Backup = [string](Get-I3Rec1 (Get-I2BStateObject $WU.L) 'LilyPad.ini').Backup
$WU.Gen1Dir = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($WU.Gen1Backup)); $WU.Gen2Dir = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($WU.Gen2Backup))
$WU.Id0 = $global:I2AFH.IdCounter; $WU.Snap = Save-I2ATree $WU.L.Root; $WU.T0 = TreeU $WU.L; $WU.UsSha0 = UsSha $WU.L
$setupOk = ($g1.Succeeded -eq $true) -and ($u1.Succeeded -eq $true) -and ($g2.Succeeded -eq $true) -and ($WU.Gen1Backup.Length -gt 0) -and ($WU.Gen2Backup.Length -gt 0) -and ($WU.Gen1Backup -cne $WU.Gen2Backup)
Reset-World $WU
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = $WU.Id0
$r = Run-Uninstall $WU.L
$fh = $global:I2AFH; $WU.MutN = [int]$fh.Mut; $WU.AllN = [int]$fh.All; $WU.MutLabels = @($fh.MutLabels); $WU.AllLabels = @($fh.AllLabels)
$WU.T1 = TreeU $WU.L; $WU.T1o = TreeX $WU
$fin = Test-Final $WU
[void](Assert-I2A 'F-U-00-clean-uninstall-census' ($setupOk -and ($r.Succeeded -eq $true) -and $fin.Ok -and (Test-UsedBackups $WU) -and (Clean $WU) -and (-not (Marker $WU))) ("generations: install1=$($g1.Succeeded) uninstall1=$($u1.Succeeded) install2=$($g2.Succeeded); uninstall of generation 2: succeeded=$($r.Succeeded) code=$($r.ErrorCode) mutating points=$($WU.MutN) all points=$($WU.AllN); $($fin.Detail)"))
Add-I2AEvidence @{ id = 'CENSUS-U'; mutPoints = $WU.MutN; allPoints = $WU.AllN }

# ---- world E: the user edited LilyPad.ini after the install; the uninstall must keep it
$WE.Edited = 'USER-EDIT-AFTER-THE-INSTALL'
Reset-I2AFault; $global:I2AFH.IdCounter = 0
$ge =Run-Install $WE.L (New-Plan $WE.L $true)
[System.IO.File]::WriteAllText((Get-I3Dest $WE.L 'LilyPad.ini'), $WE.Edited, $script:Utf8)
$WE.Id0 = $global:I2AFH.IdCounter; $WE.Snap = Save-I2ATree $WE.L.Root; $WE.T0 = TreeU $WE.L; $WE.UsSha0 = UsSha $WE.L
Reset-World $WE
Reset-I2AFault -Record $true; $global:I2AFH.IdCounter = $WE.Id0
$r = Run-Uninstall $WE.L
$fh = $global:I2AFH; $WE.MutN = [int]$fh.Mut; $WE.AllN = [int]$fh.All; $WE.MutLabels = @($fh.MutLabels); $WE.AllLabels = @($fh.AllLabels)
$WE.T1 = TreeU $WE.L; $WE.T1o = TreeX $WE
$fin = Test-Final $WE
[void](Assert-I2A 'F-E-00-clean-uninstall-keeps-the-edited-file' (($ge.Succeeded -eq $true) -and ($r.Succeeded -eq $true) -and $fin.Ok -and (Clean $WE) -and (-not (Marker $WE))) ("install=$($ge.Succeeded) uninstall=$($r.Succeeded) code=$($r.ErrorCode) mutating points=$($WE.MutN) all points=$($WE.AllN); $($fin.Detail)"))
Add-I2AEvidence @{ id = 'CENSUS-E'; mutPoints = $WE.MutN; allPoints = $WE.AllN }
[void](Assert-I2A 'F-00-the-four-worlds-have-different-point-sets' (($WI.MutN -gt 5) -and ($WP.MutN -gt 3) -and ($WU.MutN -gt 5) -and ($WE.MutN -gt 3)) "mutating points: install=$($WI.MutN) promotion=$($WP.MutN) uninstall=$($WU.MutN) uninstall-of-an-edited-file=$($WE.MutN)")

# ---------------------------------------------------------------- one crash case (a simulated crash at the fault, then the product's own recovery and re-runs)
function Invoke-CrashCase($W, [string]$Id, [hashtable]$Fault) {
    $L = $W.L
    Reset-World $W
    $plan = $null; if ($W.Kind -in @('I', 'P')) { $plan = New-Plan $L ($W.Kind -eq 'I') }
    Reset-I2AFault @Fault; $global:I2AFH.IdCounter = $W.Id0
    if ($W.Kind -in @('I', 'P')) { $null = Run-Install $L $plan } else { $null = Run-Uninstall $L }
    $fired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    $faultTree = Tree $W
    $markerAtFault = Marker $W
    # "forward" = the new state has been published: the uninstalled-state for an uninstall, the installed-state for an install (a promotion is told by the PCSX2 record signature: its state is 'NEW' either way)
    $forward = $false
    if ($W.Kind -in @('U', 'E')) { $forward = ((UsSha $L) -cne $W.UsSha0) }      # the uninstalled-state file is new (world U already has generation 1's, so its presence alone tells nothing)
    elseif ($W.Kind -eq 'P') { $forward = ($faultTree['x:pcsx2sig'] -ceq $W.T1['x:pcsx2sig']) }
    else { $forward = ($faultTree['x:state'] -eq 'NEW') }
    $isGone = $(if ($W.Kind -in @('U', 'E')) { -not [System.IO.File]::Exists($L.Product.StatePath) } else { $false })
    $r1 = $(if ($W.Kind -in @('I', 'P')) { Run-Install $L (New-Plan $L ($W.Kind -eq 'I')) } else { Run-Uninstall $L })
    $map1 = $(if ($forward -and $W.Kind -eq 'P' -and -not $markerAtFault) { TreeX $W } else { Tree $W })
    $why = ''
    if ($markerAtFault) {
        $expect = $(if ($forward) { $W.T1 } else { $W.T0 })
        $okFirst = (($r1.Succeeded -eq $false) -and ($r1.ErrorCode -eq 'RecoveryCompletedOperationNotCompleted') -and (Same $expect $map1) -and ($r1.Recovery.Outcome -eq $(if ($forward) { 'RolledForward' } else { 'RolledBack' })))
        $why = "recovery outcome=$($r1.Recovery.Outcome) code=$($r1.ErrorCode) tree==$(if ($forward) { 'T1' } else { 'T0' }):$(Same $expect $map1) [$(Diff3 $expect $map1)]"
    } elseif ($forward -and $isGone) {
        $okFirst = (($r1.Succeeded -eq $true) -and ($r1.AlreadyUninstalled -eq $true) -and (Same $W.T1 $map1))
        $why = "state committed, no marker: AlreadyUninstalled succeeded=$($r1.Succeeded) already=$($r1.AlreadyUninstalled) code=$($r1.ErrorCode)"
    } else {
        $ref1 = $(if ($forward -and $W.Kind -eq 'P') { $W.T1o } else { $W.T1 })
        $okFirst = (($r1.Succeeded -eq $true) -and (Same $ref1 $map1))
        $why = "no marker, nothing to recover: the run completed. succeeded=$($r1.Succeeded) code=$($r1.ErrorCode) tree==T1:$(Same $ref1 $map1) [$(Diff3 $ref1 $map1)]"
    }
    $r2 = $(if ($W.Kind -in @('I', 'P')) { Run-Install $L (New-Plan $L ($W.Kind -eq 'I')) } else { Run-Uninstall $L })
    $map2 = TreeX $W
    $fin = Test-Final $W
    $okSecond = (($r2.Succeeded -eq $true) -and (Same $W.T1o $map2) -and (Clean $W) -and (-not (Marker $W)) -and $fin.Ok -and (Test-UsedBackups $W))
    # recovery is idempotent: asking again changes nothing
    $r3 = $(if ($W.Kind -in @('I', 'P')) { Run-Install $L (New-Plan $L ($W.Kind -eq 'I')) } else { Run-Uninstall $L })
    $map3 = TreeX $W
    $okIdem = ($r3.Succeeded -eq $true) -and (Same $W.T1o $map3)
    $pass = (($fired.Length -gt 0) -and $okFirst -and $okSecond -and $okIdem)
    Add-I2AEvidence @{ id = $Id; world = $W.Name; fault = $fired; markerAtFault = $markerAtFault; forward = $forward; firstOutcome = [string]$r1.ErrorCode; pass = $pass; tree = (Get-I2ATreeDigest $map2) }
    return @{ Pass = $pass; Forward = $forward; Marker = $markerAtFault; Fired = $fired; Detail = ("fired=$fired markerAtFault=$markerAtFault forward=$forward first:[$why] second: succeeded=$($r2.Succeeded) tree==T1:$(Same $W.T1 $map2) final: $($fin.Detail) clean=$(Clean $W) idempotent=$okIdem") }
}
function Invoke-ThrowCase($W, [int]$K) {
    $L = $W.L
    Reset-World $W
    $plan = $null; if ($W.Kind -in @('I', 'P')) { $plan = New-Plan $L ($W.Kind -eq 'I') }
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($K)) -Action 'IO'; $global:I2AFH.IdCounter = $W.Id0
    $r = $(if ($W.Kind -in @('I', 'P')) { Run-Install $L $plan } else { Run-Uninstall $L })
    $map = Tree $W
    $rb = [string]$r.RollbackState
    $expectOk = $false
    if ($r.Succeeded) { $expectOk = (Same $W.T1 $map) -and (Test-Final $W).Ok }
    elseif (@('RolledBack', 'NotStarted', 'NotNeeded') -contains $rb) { $expectOk = (Same $W.T0 $map) }
    $okT = ($expectOk -and (Clean $W) -and (([string]$global:I2AFH.Fired).Length -gt 0) -and (-not (Marker $W)))
    return @{ Pass = $okT; Detail = "fired=$($global:I2AFH.Fired) code=$($r.ErrorCode) rb=$rb succeeded=$($r.Succeeded) diffT0=[$(Diff3 $W.T0 $map)] diffT1=[$(Diff3 $W.T1 $map)] marker=$(Marker $W)" }
}

# ---------------------------------------------------------------- B / C  the sweeps
if (-not $SkipSweeps) {
    foreach ($W in @($WI, $WP, $WU, $WE)) {
        $fail = 0; $ran = 0
        foreach ($k in (Get-Sample $W.MutN $Stride)) {
            $res = Invoke-CrashCase $W ("TC-$($W.Kind)-k$k") @{ Mode = 'CrashMut'; Targets = [int[]]@($k) }
            $ran++
            if (-not $res.Pass) { $fail++; Add-I2AResult ("TC-$($W.Kind)-k$k") $false ($W.MutLabels[$k - 1] + ' :: ' + $res.Detail) }
        }
        if ($fail -eq 0) { Add-I2AResult ("TC-$($W.Kind)-sweep") $true ("crash + the product's own recovery + re-run at $ran of $($W.MutN) mutating points: before the state is published the tree returned to T0, after it moved to T1; the Origin bytes, Backups[0] and the end state are right; a second recovery changes nothing") }
        if ($Stride -eq 1) { [void](Assert-I2A "TC-$($W.Kind)-covers-every-mutating-point" ($ran -eq $W.MutN) "swept $ran of $($W.MutN) mutating points (counted from the recorded run of the real primitives)") }
        $failT = 0; $ranT = 0
        $tStep = [Math]::Max($Stride, $(if ($W.AllN -gt 900) { 7 } elseif ($W.AllN -gt 500) { 4 } elseif ($W.AllN -gt 250) { 2 } else { 1 }))
        if ($FullThrow) { $tStep = 1 }
        foreach ($k in (Get-Sample $W.AllN $tStep)) {
            $res = Invoke-ThrowCase $W $k
            $ranT++
            if (-not $res.Pass) { $failT++; Add-I2AResult ("TB-$($W.Kind)-k$k") $false $res.Detail }
        }
        if ($failT -eq 0) { Add-I2AResult ("TB-$($W.Kind)-sweep") $true ("IO exception injected at $ranT of $($W.AllN) points$(if ($FullThrow) { ' (FullThrow: every point)' }): always a rollback to T0 (state untouched), a committed run (T1, Origin and end state right) or a refusal before any change; no marker, no leftover") }
        if ($FullThrow) { [void](Assert-I2A "TB-$($W.Kind)-fullthrow-covers-every-point" ($ranT -eq $W.AllN) "swept $ranT of $($W.AllN) exception points") }
        Add-I2AEvidence @{ id = "SWEEP-COUNTS-$($W.Kind)"; mutPoints = $W.MutN; crashSwept = $ran; allPoints = $W.AllN; throwSwept = $ranT; fullThrow = [bool]$FullThrow; stride = $Stride }
    }
}

# ---------------------------------------------------------------- D  named boundary cases (each point is looked up in the census; a missing point is a failure, not a skip)
function Invoke-Named($W, [string]$Id, [string]$Pattern, [bool]$ExpectForward) {
    $present = @($W.AllLabels | Where-Object { $_ -match $Pattern }).Count
    if ($present -lt 1) { [void](Assert-I2A $Id $false "the point '$Pattern' does not exist in the recorded run of world $($W.Kind)"); return }
    $res = Invoke-CrashCase $W $Id @{ Mode = 'Label'; Pattern = $Pattern; Nth = 1; Action = 'Crash' }
    [void](Assert-I2A $Id ($res.Pass -and ($res.Forward -eq $ExpectForward)) ("$($res.Detail) | expected direction: $(if ($ExpectForward) { 'forward to T1' } else { 'back to T0' }), got forward=$($res.Forward)"))
}
Invoke-Named $WI 'N-I1-origin-backup-just-before' '^before:Fs-CopyFileDurable:[^:]*\.bak$' $false
Invoke-Named $WI 'N-I2-origin-backup-just-after' '^after:Fs-CopyFileDurable:[^:]*\.bak$' $false
Invoke-Named $WI 'N-I3-LilyPad.ini-replacement-just-before' '^before:Fs-Replace:LilyPad\.ini$' $false
Invoke-Named $WI 'N-I4-LilyPad.ini-replacement-just-after' '^after:Fs-Replace:LilyPad\.ini$' $false
Invoke-Named $WI 'N-I5-state-publication-just-before' '^before:Fs-(Replace|MoveNew):installed-state\.json$' $false
Invoke-Named $WI 'N-I6-state-publication-just-after' '^after:Fs-(Replace|MoveNew):installed-state\.json$' $true
Invoke-Named $WP 'N-P1-promotion-just-before-the-state-is-published' '^before:Fs-(Replace|MoveNew):installed-state\.json$' $false
Invoke-Named $WP 'N-P2-promotion-just-after-the-state-is-published' '^after:Fs-(Replace|MoveNew):installed-state\.json$' $true
Invoke-Named $WU 'N-U1-restore-of-LilyPad.ini-just-before' '^before:Fs-Replace:LilyPad\.ini$' $false
Invoke-Named $WU 'N-U2-restore-of-LilyPad.ini-just-after' '^after:Fs-Replace:LilyPad\.ini$' $false
Invoke-Named $WU 'N-U3-generation-end-just-before-the-uninstalled-state-is-published' '^before:Fs-(Replace|MoveNew):uninstalled-state\.json$' $false
Invoke-Named $WU 'N-U4-generation-end-just-after-the-uninstalled-state-is-published' '^after:Fs-(Replace|MoveNew):uninstalled-state\.json$' $true
Invoke-Named $WE 'N-E1-uninstall-of-an-edited-file-just-before-the-uninstalled-state' '^before:Fs-(Replace|MoveNew):uninstalled-state\.json$' $false
Invoke-Named $WE 'N-E2-uninstall-of-an-edited-file-just-after-the-uninstalled-state' '^after:Fs-(Replace|MoveNew):uninstalled-state\.json$' $true
# the edited file is not even a restore candidate: the census of world E has no write to LilyPad.ini at all
[void](Assert-I2A 'N-E3-an-edited-LilyPad.ini-has-no-write-point-in-the-uninstall' ((@($WE.AllLabels | Where-Object { $_ -match '^(before|after):Fs-(Replace|Delete|MoveNew|CopyFileDurable|WriteTextFile|CreateFileDurable):LilyPad\.ini' }).Count -eq 0)) 'no mutating primitive names LilyPad.ini in the recorded run: the user''s edit is not touched at any point, by construction and (with the sweeps above) at every injected failure')

# a recovery interrupted in the middle (the recovery's own restore is killed by a crash, then recovered again)
$restoreLbl = '^after:Fs-Replace:'
foreach ($W in @($WI, $WU)) {
    $L = $W.L
    Reset-World $W
    $plan = $null; if ($W.Kind -eq 'I') { $plan = New-Plan $L $true }
    # step 1: crash after the LilyPad.ini change (before the commit)
    $pat1 = $(if ($W.Kind -eq 'I') { '^after:Fs-Replace:LilyPad\.ini$' } else { '^after:Fs-Replace:LilyPad\.ini$' })
    Reset-I2AFault -Mode 'Label' -Pattern $pat1 -Nth 1 -Action 'Crash'; $global:I2AFH.IdCounter = $W.Id0
    if ($W.Kind -eq 'I') { $null = Run-Install $L $plan } else { $null = Run-Uninstall $L }
    Resume-I2AAfterCrash
    # step 2: the recovery itself is interrupted at its first file restore
    $plan2 = $null; if ($W.Kind -eq 'I') { $plan2 = New-Plan $L $true }
    Reset-I2AFault -Mode 'Label' -Pattern '^after:Fs-(Replace|MoveNew|Delete):' -Nth 1 -Action 'Crash'
    if ($W.Kind -eq 'I') { $null = Run-Install $L $plan2 } else { $null = Run-Uninstall $L }
    $interrupted = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash
    # step 3: the next run recovers (back to T0), the one after completes
    $plan3 = $null; if ($W.Kind -eq 'I') { $plan3 = New-Plan $L $true }
    $rr = $(if ($W.Kind -eq 'I') { Run-Install $L $plan3 } else { Run-Uninstall $L })
    $mapR = Tree $W
    $plan4 = $null; if ($W.Kind -eq 'I') { $plan4 = New-Plan $L $true }
    $rf = $(if ($W.Kind -eq 'I') { Run-Install $L $plan4 } else { Run-Uninstall $L })
    $mapF = Tree $W
    $fin = Test-Final $W
    [void](Assert-I2A ("N-X-$($W.Kind)-recovery-interrupted-in-the-middle-converges") (($interrupted.Length -gt 0) -and ($rr.Succeeded -eq $false) -and (Same $W.T0 $mapR) -and ($rf.Succeeded -eq $true) -and (Same $W.T1 $mapF) -and $fin.Ok -and (Clean $W) -and (-not (Marker $W))) ("recovery interrupted at '$interrupted'; next run: code=$($rr.ErrorCode) tree==T0:$(Same $W.T0 $mapR); following run: succeeded=$($rf.Succeeded) tree==T1:$(Same $W.T1 $mapF); $($fin.Detail)"))
}

# ---------------------------------------------------------------- E  a change of LilyPad.ini after the plan / right before the write is never overwritten
$tamperText = 'CHANGED-BY-PCSX2-AFTER-THE-PLAN'
$script:i3Tamper = Get-I3Dest $WI.L 'LilyPad.ini'
$firstReplace = [array]::IndexOf($WI.AllLabels, 'before:Fs-Replace:LilyPad.ini') + 1
$backupCopy = [array]::IndexOf(@($WI.AllLabels), (@($WI.AllLabels | Where-Object { $_ -match '^before:Fs-CopyFileDurable:[^:]*\.bak$' })[0])) + 1
[void](Assert-I2A 'TP-00-the-replacement-and-the-origin-backup-points-are-in-the-census' (($firstReplace -ge 1) -and ($backupCopy -ge 1) -and ($backupCopy -lt $firstReplace)) "the Origin backup copy starts at point $backupCopy, LilyPad.ini is replaced at point $firstReplace, of $($WI.AllN) points")
# A change at any point up to and including the start of the Origin backup copy is caught by the product (the backup is verified against the SHA-256 that was planned and journaled).
# A change AFTER the copy (the points between the end of the backup and the replacement) has no further comparison in the I2-A core (a non-atomic check-then-replace): the outcome there is MEASURED and REPORTED
# below, not asserted - see the evidence record TOCTOU-WINDOW and the stage report.
function Invoke-Tamper([int]$K) {
    Reset-World $WI
    $plan = New-Plan $WI.L $true
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($K)) -Action 'Callback' -Callback { param($a) [System.IO.File]::WriteAllText($script:i3Tamper, 'CHANGED-BY-PCSX2-AFTER-THE-PLAN', [System.Text.Encoding]::ASCII) }; $global:I2AFH.IdCounter = $WI.Id0
    $r = Run-Install $WI.L $plan
    $fired = [string]$global:I2AFH.Fired
    return @{ R = $r; Fired = $fired; Now = (Txt $script:i3Tamper) }
}
$tFail = 0; $tRan = 0; $tClasses = @{}
if (($backupCopy -ge 1) -and ($firstReplace -ge 1)) {
    foreach ($k in (Get-Sample $backupCopy $(if ($FullThrow) { 1 } else { [Math]::Max($Stride, 1) }))) {
        $t = Invoke-Tamper $k; $r = $t.R
        $cls = $(if ([string]$r.ErrorCode -eq 'PlanStale') { 'PlanStale' } else { [string]$r.ErrorCode })
        if ($tClasses.ContainsKey($cls)) { $tClasses[$cls]++ } else { $tClasses[$cls] = 1 }
        # the tampered file is NEVER overwritten by the DenGo content; the run does not claim success; a stale plan changes nothing at all; every other refusal asks for a manual check
        $ok = ($t.Fired.Length -gt 0) -and ($t.Now -ceq $tamperText) -and ($r.Succeeded -eq $false) -and (($cls -eq 'PlanStale') -or ($r.ManualCheckRequired -eq $true))
        if ($cls -eq 'PlanStale') { $ok = $ok -and (-not [System.IO.File]::Exists((Get-I3Dest $WI.L 'DenGo-Controller-Converter.lily'))) -and (-not [System.IO.File]::Exists($WI.L.Product.StatePath)) }
        $tRan++
        if (-not $ok) { $tFail++; Add-I2AResult ("TP-k$k") $false ("fired='$($t.Fired)' (label $($WI.AllLabels[$k - 1])) code=$($r.ErrorCode) succeeded=$($r.Succeeded) manual=$($r.ManualCheckRequired) LilyPad.ini=[$($t.Now)]") }
    }
    if ($tFail -eq 0) { Add-I2AResult 'TP-sweep' $true ("a change of LilyPad.ini injected at $tRan of the first $backupCopy points (every point from the start up to the start of the Origin backup copy): never overwritten, never reported as success; outcomes: " + (($tClasses.Keys | Sort-Object | ForEach-Object { $_ + '=' + $tClasses[$_] }) -join ', ')) }
    Add-I2AEvidence @{ id = 'SWEEP-COUNTS-TAMPER'; protectedPoints = $backupCopy; swept = $tRan; classes = (($tClasses.Keys | Sort-Object | ForEach-Object { $_ + '=' + $tClasses[$_] }) -join ', ') }
    # the measured window between the end of the Origin backup and the replacement
    $win = New-Object System.Collections.ArrayList
    foreach ($k in ($backupCopy + 1)..$firstReplace) {
        $t = Invoke-Tamper $k; $r = $t.R
        $overwritten = ($t.Now -cne $tamperText)
        $originOnDisk = Test-Origin $WI.L $script:I3UserOrigin
        [void]$win.Add([ordered]@{ point = $k; label = [string]$WI.AllLabels[$k - 1]; succeeded = [bool]$r.Succeeded; code = [string]$r.ErrorCode; tamperedContentOverwritten = $overwritten; originBackupIsPreTamper = [bool]$originOnDisk.Ok })
    }
    $winOverwritten = @($win | Where-Object { $_.tamperedContentOverwritten }).Count
    Add-I2AEvidence @{ id = 'TOCTOU-WINDOW'; fromPoint = ($backupCopy + 1); toPoint = $firstReplace; points = $win.Count; overwritten = $winOverwritten; detail = @($win) }
    Write-Host ("TOCTOU-WINDOW: {0} points between the end of the Origin backup copy and the replacement; a change of LilyPad.ini injected there was overwritten in {1} of them (core limitation, reported, not asserted)" -f $win.Count, $winOverwritten)
}

# ---------------------------------------------------------------- F  unsupported / unverified / ambiguous PCSX2: no write, no settings file, never a silent choice - also when a read fails
Uninstall-I2AHarness
$zeroRoot = New-I3Sandbox 'fault-zero'
Set-I3DocumentsRoot (Join-Path $zeroRoot 'Documents')
$zSrcLily = Join-Path $zeroRoot 'src\lily.src'; $zSrcActive = Join-Path $zeroRoot 'src\active.src'
Write-I3Text $zSrcLily $lilyV1; Write-I3Text $zSrcActive $activeV1
function New-ZeroScene([string]$Name) {
    $d = Join-Path $zeroRoot $Name
    [System.IO.Directory]::CreateDirectory($d) | Out-Null
    return $d
}
$settingsLeaf = '(?i)(PCSX2(_ui|_vm)?\.ini|LilyPad\.ini|GSdx\.ini|portable\.(ini|txt)|\\inis$|:inis$)'
$zeroScenes = New-Object System.Collections.ArrayList
# unsupported (qt), unsupported (x64), unverified (x86, not on the list)
$sQt = New-ZeroScene 'qt'; [void](New-I3Config (Join-Path $sQt 'Documents\PCSX2'))
$exeQt = New-I3Pcsx2Home (Join-Path $sQt 'App') -ExeName 'pcsx2-qt.exe' -Machine 'x64' -ExeSha ''
[void]$zeroScenes.Add(@{ Name = 'qt'; Dir = $sQt; Cands = @((New-I3Candidate $exeQt)); Want = 'UnsupportedCurrent'; Root = (Join-Path $sQt 'Documents\PCSX2') })
$sX64 = New-ZeroScene 'x64'; [void](New-I3Config (Join-Path $sX64 'Documents\PCSX2'))
$exeX64 = New-I3Pcsx2Home (Join-Path $sX64 'App') -ExeName 'pcsx2.exe' -Machine 'x64' -ExeSha ''
[void]$zeroScenes.Add(@{ Name = 'x64'; Dir = $sX64; Cands = @((New-I3Candidate $exeX64)); Want = 'UnsupportedCurrent'; Root = (Join-Path $sX64 'Documents\PCSX2') })
$sUnv = New-ZeroScene 'unverified'; [void](New-I3Config (Join-Path $sUnv 'Documents\PCSX2'))
$exeUnv = New-I3Pcsx2Home (Join-Path $sUnv 'App') -ExeName 'pcsx2.exe' -Machine 'x86' -ExeSha '' -PluginSha ''
Write-I3Bytes $exeUnv (New-I3PeBytes 'x86' 'STUB-UNVERIFIED')       # distinct bytes: the stub tag of New-I3Pcsx2Home is cut at 32 bytes and would be equal for every folder
[void]$zeroScenes.Add(@{ Name = 'unverified'; Dir = $sUnv; Cands = @((New-I3Candidate $exeUnv)); Want = 'UnsupportedUnverified'; Root = (Join-Path $sUnv 'Documents\PCSX2') })
# ambiguous: a central root and a portable root, both proven; both exe files are on the allow list (the allow list is redefined to the SHA-256 of these two stubs: a test seam)
$sAmb = New-ZeroScene 'ambiguous'
$exeA = New-I3Pcsx2Home (Join-Path $sAmb 'AppA') -ExeSha '' -PluginSha ''; $exeB = New-I3Pcsx2Home (Join-Path $sAmb 'AppB') -ExeSha '' -PluginSha '' -PortableIni $true
Write-I3Bytes $exeA (New-I3PeBytes 'x86' 'STUB-A'); Write-I3Bytes $exeB (New-I3PeBytes 'x86' 'STUB-B')
[void](New-I3Config (Join-Path $sAmb 'Documents\PCSX2')); [void](New-I3Config (Join-Path $sAmb 'AppB'))
$global:I3Pairs = @(
    [pscustomobject]@{ ExeSha256 = (Get-I3Sha $exeA); LilyPadSha256 = (Get-I3Sha (Join-Path $sAmb 'AppA\Plugins\LilyPad.dll')) },
    [pscustomobject]@{ ExeSha256 = (Get-I3Sha $exeB); LilyPadSha256 = (Get-I3Sha (Join-Path $sAmb 'AppB\Plugins\LilyPad.dll')) })
Set-Item -Path 'function:script:Get-DenGoPcsx2KnownPairs' -Value ([scriptblock]::Create('return ,@($global:I3Pairs)'))
[void]$zeroScenes.Add(@{ Name = 'ambiguous'; Dir = $sAmb; Cands = @((New-I3Candidate $exeA), (New-I3Candidate $exeB)); Want = 'Ambiguous'; Root = '' })
Install-I2AHarness
Reset-I2AFault; Reset-I2ACounters
function Invoke-Zero($S) {
    try {
        $g = Group-DenGoPcsx2Candidates -Candidates ([object[]]$S.Cands)
        $items = New-DenGoPcsx2PlanItems -Resolution $g -LilySource $zSrcLily -ActiveSource $zSrcActive -ReplaceConsent $true -Previous $null -Layout $null -LastClosedTransactionId ''
        return @{ Ok = $true; Group = $g; Items = @($items); Error = '' }
    } catch { return @{ Ok = $false; Group = $null; Items = @(); Error = [string]$_.Exception.Message } }
}
foreach ($S in $zeroScenes) {
    Set-I3DocumentsRoot (Join-Path $S.Dir 'Documents')       # each scene has its own central settings root (the seam of the product: Get-DenGoDocumentsRoot)
    $treeBefore = Get-I2ATreeMap $zeroRoot @()
    Reset-I2AFault -Record $true; Reset-I2ACounters
    $z = Invoke-Zero $S
    $fh = $global:I2AFH; $zAll = [int]$fh.All; $zMut = [int]$fh.Mut; $zLabels = @($fh.AllLabels)
    $stat = $(if ($z.Ok -and $null -ne $z.Group) { @($z.Group.Detected | ForEach-Object { [string]$_.SupportStatus }) } else { @() })
    $touch = @($zLabels | Where-Object { $_ -match $settingsLeaf -or $_ -match 'LilyPad\.dll' -or $_ -match 'inis' })
    if ($S.Name -eq 'ambiguous') {
        [void](Assert-I2A "Z-$($S.Name)-census" ($z.Ok -and ([string]$z.Group.Status -ceq 'Ambiguous') -and ($z.Items.Count -eq 0) -and ($zMut -eq 0) -and (Same $treeBefore (Get-I2ATreeMap $zeroRoot @())) -and ($stat -contains 'Ambiguous')) "status=$(if ($z.Ok) { $z.Group.Status } else { $z.Error }) items=$($z.Items.Count) mutating primitives=$zMut of $zAll points; tree unchanged: $(Same $treeBefore (Get-I2ATreeMap $zeroRoot @()))")
    } else {
        [void](Assert-I2A "Z-$($S.Name)-census" ($z.Ok -and ([string]$z.Group.Status -ceq 'None') -and ($stat -contains $S.Want) -and ($z.Items.Count -eq 0) -and ($zMut -eq 0) -and ($touch.Count -eq 0) -and (Same $treeBefore (Get-I2ATreeMap $zeroRoot @()))) "status=$(if ($z.Ok) { $z.Group.Status } else { $z.Error }) support=$($stat -join ',') items=$($z.Items.Count) mutating primitives=$zMut of $zAll points; settings files / LilyPad.dll / inis named by a primitive: $($touch.Count) [$($touch -join ' ; ')]")
    }
    # an IO error at EVERY read point: the planner never throws, never writes, never opens a settings file of an unsupported install, never silently chooses one of two roots
    $zFail = 0; $zRan = 0; $worst = ''
    foreach ($k in (Get-Sample $zAll 1)) {
        Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; Reset-I2ACounters
        $zr = Invoke-Zero $S
        $fh = $global:I2AFH
        $labelsK = @($fh.AllLabels)
        $changed = -not (Same $treeBefore (Get-I2ATreeMap $zeroRoot @()))
        $bad = (-not $zr.Ok) -or ($zr.Items.Count -ne 0) -or $changed -or ([int]$fh.Mut -ne 0)
        if ($S.Name -ne 'ambiguous') { $bad = $bad -or ([string]$zr.Group.Status -cne 'None') }
        else { $bad = $bad -or ([string]$zr.Group.Status -ceq 'Resolved') }     # a failing read must never turn "two roots" into "one root"
        $zRan++
        if ($bad) { $zFail++; $worst = "point $k : ok=$($zr.Ok) status=$(if ($zr.Ok) { $zr.Group.Status } else { $zr.Error }) items=$($zr.Items.Count) mutating=$([int]$fh.Mut) tree changed=$changed"; Add-I2AResult ("Z-$($S.Name)-k$k") $false $worst }
    }
    Reset-I2AFault
    if ($zFail -eq 0) { Add-I2AResult "Z-$($S.Name)-sweep" $true "IO exception injected at $zRan of $zAll read points: never an exception out of the planner, never an item, never a write, never Resolved for an unsupported / ambiguous install" }
    Add-I2AEvidence @{ id = "SWEEP-COUNTS-ZERO-$($S.Name)"; allPoints = $zAll; swept = $zRan }
}

# ---------------------------------------------------------------- F2  a failed read is kept, never "no candidate" (F-D1 contracts; the same two exe files / two roots as the ambiguous scene)
#   C1  the read failure is kept in Reason (CandidateReadFailed: <exe of the candidate whose read failed> | <cause>); the candidates are all kept in Detected
#   C2  an exe header that cannot be read (a real IO failure: an exclusive lock, not an injected primitive) is a failed candidate too
#   C3  one candidate only and a failed read: nothing is chosen (None, never Resolved); two candidates and a failed read: Ambiguous (never None, never Resolved); no plan item, no mutating primitive, tree unchanged
function Invoke-Grp([string]$Dir, [object[]]$Cands) {
    Set-I3DocumentsRoot (Join-Path $Dir 'Documents')
    try {
        $g = Group-DenGoPcsx2Candidates -Candidates $Cands
        $items = New-DenGoPcsx2PlanItems -Resolution $g -LilySource $zSrcLily -ActiveSource $zSrcActive -ReplaceConsent $true -Previous $null -Layout $null -LastClosedTransactionId ''
        return @{ Ok = $true; Group = $g; Items = @($items); Error = '' }
    } catch { return @{ Ok = $false; Group = $null; Items = @(); Error = [string]$_.Exception.Message } }
}
function Get-GrpFacts($R, [string]$Want) {
    if (-not $R.Ok) { return @{ Good = $false; Text = "exception: $($R.Error)" } }
    $g = $R.Group
    $lilyAdd = @($R.Items | Where-Object { [string]$_.Component -ceq 'InputProfile' -and [string]$_.Action -ceq 'Add' }).Count
    $mutItems = @($R.Items | Where-Object { @('Add', 'UpdateOrRepair') -ccontains [string]$_.Action }).Count
    $good = ([string]$g.Status -ceq $Want) -and ([string]$g.SelectedRoot -ceq '') -and ($R.Items.Count -eq 0) -and ($lilyAdd -eq 0) -and ($mutItems -eq 0) -and ([int]$global:I2AFH.Mut -eq 0)
    return @{ Good = $good; Text = "status=$($g.Status) selected=[$($g.SelectedRoot)] items=$($R.Items.Count) lilyAdd=$lilyAdd mutatingItems=$mutItems mutatingPrimitives=$([int]$global:I2AFH.Mut) reason=[$($g.Reason)]" }
}
$f2Both = @((New-I3Candidate $exeA), (New-I3Candidate $exeB)); $f2One = @((New-I3Candidate $exeA))
$f2Tree = Get-I2ATreeMap $zeroRoot @()
# positive expectations: nothing failed -> nothing is recorded, and one proven root stays Resolved
Reset-I2AFault -Record $true; Reset-I2ACounters
$p1 = Invoke-Grp $sAmb $f2One
[void](Assert-I2A 'F2-C1-no-failed-read-nothing-recorded-and-one-proven-root-stays-Resolved' ($p1.Ok -and ([string]$p1.Group.Status -ceq 'Resolved') -and ([string]$p1.Group.Reason -ceq '') -and ($p1.Group.Roots.Count -eq 1) -and ($p1.Items.Count -eq 2)) "status=$(if ($p1.Ok) { $p1.Group.Status } else { $p1.Error }) reason=[$(if ($p1.Ok) { $p1.Group.Reason })] items=$($p1.Items.Count)")
Reset-I2AFault -Record $true; Reset-I2ACounters
$p2 = Invoke-Grp $sAmb $f2Both
$f2PointsBoth = [int]$global:I2AFH.All
[void](Assert-I2A 'F2-C1-no-failed-read-two-roots-stay-Ambiguous-with-an-empty-Reason' ($p2.Ok -and ([string]$p2.Group.Status -ceq 'Ambiguous') -and ([string]$p2.Group.Reason -ceq '') -and ($p2.Items.Count -eq 0)) "status=$(if ($p2.Ok) { $p2.Group.Status } else { $p2.Error }) reason=[$(if ($p2.Ok) { $p2.Group.Reason })] items=$($p2.Items.Count) points=$f2PointsBoth")
# C1 + C3 (two candidates): a failed read at EVERY read point -> Ambiguous, the failure and its candidate are named in Reason
$f2Bad = 0; $f2Ran = 0
for ($k = 1; $k -le $f2PointsBoth; $k++) {
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; Reset-I2ACounters
    $r = Invoke-Grp $sAmb $f2Both
    $fa = Get-GrpFacts $r 'Ambiguous'
    $reason = $(if ($r.Ok) { [string]$r.Group.Reason } else { '' })
    $failedExe = $(if ($k -le ($f2PointsBoth / 2)) { $exeA } else { $exeB })      # the first half of the read points belongs to the first candidate, the second half to the second one
    $named = ($reason -clike 'CandidateReadFailed: *') -and ($reason.IndexOf($failedExe, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    $kept = $r.Ok -and (@($r.Group.Detected).Count -eq 2) -and ($r.Group.Roots.Count -eq 1)
    $changed = -not (Same $f2Tree (Get-I2ATreeMap $zeroRoot @()))
    $f2Ran++
    if (-not ($fa.Good -and $named -and $kept -and -not $changed)) { $f2Bad++; Add-I2AResult ("F2-C1-two-k$k") $false ("point $k : $($fa.Text) namesFailedCandidate=$named candidatesKept=$kept treeChanged=$changed") }
}
Reset-I2AFault
if ($f2Bad -eq 0) { Add-I2AResult 'F2-C1-two-sweep' $true "a failed read at $f2Ran of $f2PointsBoth points: always Ambiguous (never None, never Resolved), SelectedRoot empty, no plan item, no .lily Add, no mutating item or primitive, tree unchanged, both candidates and the one proven root kept, Reason = CandidateReadFailed naming the candidate whose read failed" }
[void](Assert-I2A 'F2-C1-census-28-read-points-for-two-candidates' ($f2PointsBoth -eq 28) "points=$f2PointsBoth")
# C3 (one candidate): a failed read at every read point of the evaluation -> nothing is chosen
Reset-I2AFault -Record $true; Reset-I2ACounters
Set-I3DocumentsRoot (Join-Path $sAmb 'Documents'); $null = Group-DenGoPcsx2Candidates -Candidates $f2One
$f2PointsOne = [int]$global:I2AFH.All
$f2Bad1 = 0
for ($k = 1; $k -le $f2PointsOne; $k++) {
    Reset-I2AFault -Mode 'ThrowAll' -Targets ([int[]]@($k)) -Action 'IO'; Reset-I2ACounters
    $r = Invoke-Grp $sAmb $f2One
    $fa = Get-GrpFacts $r 'None'
    $reason = $(if ($r.Ok) { [string]$r.Group.Reason } else { '' })
    $named = ($reason -clike 'CandidateReadFailed: *') -and ($reason.IndexOf($exeA, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    $changed = -not (Same $f2Tree (Get-I2ATreeMap $zeroRoot @()))
    if (-not ($fa.Good -and $named -and -not $changed)) { $f2Bad1++; Add-I2AResult ("F2-C3-one-k$k") $false ("point $k : $($fa.Text) namesFailedCandidate=$named treeChanged=$changed") }
}
Reset-I2AFault
if ($f2Bad1 -eq 0) { Add-I2AResult 'F2-C3-one-sweep' $true "one candidate, a failed read at $f2PointsOne of $f2PointsOne points: always None (never Resolved), SelectedRoot empty, no plan item, no mutating primitive, tree unchanged, Reason = CandidateReadFailed naming the candidate" }
[void](Assert-I2A 'F2-C3-census-14-read-points-for-one-candidate' ($f2PointsOne -eq 14) "points=$f2PointsOne")
# C2: the exe header of the portable candidate cannot be read (exclusive lock held while the planner runs; the tree is compared after it is released)
$lockFacts = @{}
foreach ($case in @(@('two', $f2Both, 'Ambiguous'), @('one', @((New-I3Candidate $exeB)), 'None'))) {
    $fs = [System.IO.File]::Open($exeB, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { Reset-I2AFault -Record $true; Reset-I2ACounters; $r = Invoke-Grp $sAmb ([object[]]$case[1]); $mutLocked = [int]$global:I2AFH.Mut } finally { $fs.Dispose() }
    $fa = Get-GrpFacts $r ([string]$case[2])
    $reason = $(if ($r.Ok) { [string]$r.Group.Reason } else { '' })
    $named = ($reason -clike 'CandidateReadFailed: *') -and ($reason.IndexOf($exeB, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and ($reason.IndexOf('PeNotX86:Unreadable', [System.StringComparison]::Ordinal) -ge 0)
    $kept = $r.Ok -and (@($r.Group.Detected).Count -eq @($case[1]).Count)
    $unchanged = Same $f2Tree (Get-I2ATreeMap $zeroRoot @())
    [void](Assert-I2A ("F2-C2-unreadable-exe-header-$($case[0])-candidate-" + $case[2]) ($fa.Good -and $named -and $kept -and $unchanged) "$($fa.Text) namesCandidateAndCause=$named candidatesKept=$kept treeUnchanged=$unchanged")
}
Uninstall-I2AHarness
foreach ($W in @($WI, $WP, $WU, $WE)) { Remove-I2ASandbox $W.L.Root }
Remove-I2ASandbox $zeroRoot
Complete-I2ATests
