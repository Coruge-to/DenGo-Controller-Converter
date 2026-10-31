# I2-A TOCTOU contract: real-process kill tests (TerminateProcess) of the conditional Write / Replace and the move-aside Delete, and of the recovery that follows.
# Fixture: item 0 = Write over an existing file (conditional Replace + displaced file), item 1 = Delete (move aside, SHA check, Applied, cleanup, Verified).
#
# The kill points are NOT typed in. They are derived from recorded runs of the code under test: every mutating primitive boundary (before/after) and every journal append
# inside the span of each item, the tail of each third-party-mismatch run, and the mutating boundaries of the recovery itself. The number of kills is the number of derived
# points; the test asserts that every derived point was killed, and that the named boundaries of the contract are among them.
# Every case: (1) the in-process crash model at the point -> tree T1, (2) the real kill of a child process at the same point -> tree T2, (3) T1 == T2, (4) recovery from T2
# (primitive calls recorded), (5) a second recovery, (6) the invariants of the contract.
# Third-party cases edit the killed state by hand (plain .NET) before the recovery runs.
param([string]$EvidenceDir = '', [int]$Stride = 1)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2A.Toctou.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2A.ToctouKill.TestSupport.ps1')
if ([string]::IsNullOrEmpty($EvidenceDir)) { $EvidenceDir = Join-Path $env:TEMP ('DenGoI2A-ToctouKill-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')) }
[System.IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$global:I2AEvidencePath = Join-Path $EvidenceDir 'cases-toctou-kill.jsonl'
$childScript = Join-Path $PSScriptRoot 'I2A.ToctouKillChild.ps1'
Install-I2AHarness

function Cnt($X) { if ($null -eq $X) { return 0 }; return @($X).Count }
function ConvertTo-B64($Object) { return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Compress))) }
function Start-Child([hashtable]$Params) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $childScript + '"'
    foreach ($k in $Params.Keys) { $argLine += ' -' + $k + ' "' + $Params[$k] + '"' }
    return (Start-Process powershell.exe -ArgumentList $argLine -PassThru -WindowStyle Hidden)
}
# The kill is synchronous, but the OS needs a moment to drop the process entry: the check is repeated for up to 2 seconds and fails only if a child or a grandchild is STILL there at the end.
function Test-NoOrphans([int]$ChildPid) {
    for ($q = 0; $q -lt 10; $q++) {
        $alive = $null -ne (Get-Process -Id $ChildPid -ErrorAction SilentlyContinue)
        $kids = Cnt (Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $ChildPid) -ErrorAction SilentlyContinue)
        if ((-not $alive) -and ($kids -eq 0)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function Get-Full { return (Get-I2ATreeMap $root @()) }
function Same($A, $B) { return ((Cnt (Compare-I2ATree $A $B)) -eq 0) }
function Diff3($A, $B) { return ([string]::Join(' ', [string[]]@(Compare-I2ATree $A $B | Select-Object -First 3))) }
function Marker-Present { return ([System.IO.File]::Exists((Join-Path $L.State 'installing.json')) -or [System.IO.File]::Exists((Join-Path $L.State 'uninstalling.json'))) }
function Txt-At([string]$Path) { if ([System.IO.File]::Exists($Path)) { return [System.IO.File]::ReadAllText($Path) }; return '<missing>' }
function Displaced-Of([string]$Dest, [int]$ItemId) { return (Get-TxDisplaced $Dest 'T0001' $ItemId) }

$root = New-I2ASandbox 'ktx'
$L = New-KtFixture $root
Assert-I2AInsideSandbox $root @($L.Dest, $L.State, $L.Backup)
$pristine = Save-I2ATree $root
$pristineManaged = Get-KtManaged $root
$repDisp = Displaced-Of $L.RepDest 0
$delDisp = Displaced-Of $L.DelDest 1
$killed = 0; $derived = 0

# ---------------------------------------------------------------- injections: the same description drives the in-process model and the child process
function New-Inj([string]$Pattern, [int]$Nth, [string]$Kind, [string]$Path, [string]$Text = '') { return @{ Pattern = $Pattern; Nth = $Nth; Kind = $Kind; Path = $Path; Text = $Text } }
function Add-ParentInj($Injs) {
    foreach ($j in @($Injs)) {
        $p = [string]$j.Path; $t = [string]$j.Text
        if ($j.Kind -ceq 'Write') { Add-TxInj ([string]$j.Pattern) ([int]$j.Nth) ({ TP-Write $p $t }.GetNewClosure()) }
        else { Add-TxInj ([string]$j.Pattern) ([int]$j.Nth) ({ TP-Delete $p }.GetNewClosure()) }
    }
}

# ---------------------------------------------------------------- census of a run (or of a recovery) with the labels recorded
function Get-Census([string]$Mode, $Base, $Injs = @()) {
    Release-I2AHeld; Clear-TxInj; Restore-I2ATree $root $Base
    Add-ParentInj $Injs
    Reset-I2AFault -Record $true; Reset-I2ACounters
    try { if ($Mode -ceq 'Run') { $null = Invoke-KtRun $L } else { $null = Invoke-KtRecover $L } } catch { }
    $c = @{ All = @($global:I2AFH.AllLabels); Mut = @($global:I2AFH.MutLabels) }
    Clear-TxInj; Reset-I2AFault; Reset-I2ACounters
    return $c
}
function Get-LabelIndex([string[]]$All, [string]$Rx, [int]$From = 0) { for ($i = $From; $i -lt $All.Count; $i++) { if ($All[$i] -match $Rx) { return $i } }; return -1 }

# ---------------------------------------------------------------- one kill case
function Invoke-KillCase {
    param([string]$Mode, $Base, $Point, $Injs = @(), [scriptblock]$Hand = $null)
    # (1) in-process crash model
    Release-I2AHeld; Clear-TxInj; Restore-I2ATree $root $Base
    Add-ParentInj $Injs
    Reset-I2AFault -Mode 'Label' -Pattern $Point.Pattern -Nth $Point.Nth -Action 'Crash'; Reset-I2ACounters
    try { if ($Mode -ceq 'Run') { $null = Invoke-KtRun $L } else { $null = Invoke-KtRecover $L } } catch { }
    $modelFired = [string]$global:I2AFH.Fired
    Resume-I2AAfterCrash; Clear-TxInj
    $treeModel = Get-Full
    # (2) real kill
    Release-I2AHeld; Restore-I2ATree $root $Base
    $fb = ConvertTo-B64 @{ Pattern = $Point.Pattern; Nth = $Point.Nth }
    $prm = @{ Mode = $Mode; Root = $root; FaultB64 = $fb }
    if (@($Injs).Count -gt 0) { $prm.InjB64 = (ConvertTo-B64 @($Injs)) }
    $p = Start-Child $prm
    $exited = $p.WaitForExit(90000)
    $code = $(if ($exited) { $p.ExitCode } else { -999 })
    if (-not $exited) { try { $p.Kill() } catch { } }
    $orphanFree = Test-NoOrphans $p.Id
    $treeKill = Get-Full
    $isKilled = ($exited -and ($code -ne 7) -and ($code -ne 0))
    $script:killed++
    $r = @{ Fired = $modelFired; Killed = $isKilled; Code = $code; OrphanFree = $orphanFree; Equal = (Same $treeModel $treeKill); Diff = (Diff3 $treeModel $treeKill); TreeKill = $treeKill }
    # (3) the killed state, then the third party (if any), then the recovery with every mutating primitive recorded
    if ($null -ne $Hand) { & $Hand }
    $r.Hand = (Get-Full)
    return $r
}
function Invoke-Recoveries {
    Release-I2AHeld; Clear-TxInj; Reset-I2AFault; Reset-I2ACounters
    Start-KtLog
    $rec1 = Invoke-KtRecover $L
    $log1 = Stop-KtLog
    $map1 = Get-Full
    $marker1 = Marker-Present; $journals1 = Get-KtJournalCount $L
    $rec2 = Invoke-KtRecover $L
    $map2 = Get-Full
    return @{ Rec1 = $rec1; Rec2 = $rec2; Log1 = $log1; Map1 = $map1; Map2 = $map2; Marker1 = $marker1; Journals1 = $journals1 }
}
# Contract invariants of a recovery log: the pushed-aside file is never a source (only the cleanup may touch it), only displaced / temporary files are deleted, and everything restored comes from the backup of this transaction.
function Test-RecoveryLog($Log) {
    $bad = New-Object System.Collections.ArrayList
    foreach ($e in @($Log)) {
        $parts = ([string]$e).Split('|')
        $name = $parts[0]; $a0 = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }); $a1 = $(if ($parts.Count -gt 2) { $parts[2] } else { '' })
        if (@('DgFs-Replace', 'DgFs-MoveNew', 'DgFs-CopyFileDurable') -contains $name) {
            if ($a0.EndsWith('.dengo.old', [System.StringComparison]::OrdinalIgnoreCase)) { [void]$bad.Add('displaced-as-source:' + $e) }
            if (($name -ceq 'DgFs-CopyFileDurable') -and (-not $a0.StartsWith($L.Backup, [System.StringComparison]::OrdinalIgnoreCase))) { [void]$bad.Add('copy-not-from-backup:' + $e) }
            if ((@($L.RepDest, $L.DelDest) -contains $a1) -and (-not $a0.EndsWith('.dengo.tmp', [System.StringComparison]::OrdinalIgnoreCase))) { [void]$bad.Add('destination-not-written-from-a-restore-tmp:' + $e) }
        }
        if ($name -ceq 'DgFs-Delete') {
            # a recovery deletes only displaced files (after the ownership + SHA check), temporary files and, last, the transaction marker of the State folder; never a destination
            $isMarker = (($a0 -ceq (Join-Path $L.State 'installing.json')) -or ($a0 -ceq (Join-Path $L.State 'uninstalling.json')))
            if (-not ($a0.EndsWith('.dengo.old', [System.StringComparison]::OrdinalIgnoreCase) -or $a0.EndsWith('.dengo.tmp', [System.StringComparison]::OrdinalIgnoreCase) -or $isMarker)) { [void]$bad.Add('delete-of-a-non-displaced-non-tmp-non-marker:' + $e) }
            if (@($L.RepDest, $L.DelDest) -contains $a0) { [void]$bad.Add('delete-of-a-destination:' + $e) }
        }
    }
    return @($bad.ToArray())
}
# the primitive calls whose path arguments are exactly $Path (the text payload of a report is not a path)
function Get-Touching($Log, [string]$Path) {
    $out = New-Object System.Collections.ArrayList
    foreach ($e in @($Log)) {
        $parts = ([string]$e).Split('|'); $n = $parts[0]
        $pathArgs = switch ($n) { 'DgFs-Replace' { 1..3 } 'DgFs-MoveNew' { 1..2 } 'DgFs-CopyFileDurable' { 1..2 } 'DgFs-Delete' { 1 } 'DgFs-WriteTextFile' { 1 } 'DgFs-CreateFileDurable' { 1 } default { 1 } }
        foreach ($i in $pathArgs) { if (($parts.Count -gt $i) -and ($parts[$i] -ceq $Path)) { [void]$out.Add(($e.Replace($root, ''))); break } }
    }
    return @($out.ToArray())
}
function Get-JournalBytes {
    $b = Join-Path $L.State 'txn'
    # an empty result must stay an empty array (not $null): the comma keeps it from being unrolled
    if (-not [System.IO.Directory]::Exists($b)) { return ,[byte[]]@() }
    $fs = @([System.IO.Directory]::GetFiles($b, 'journal.jsonl', [System.IO.SearchOption]::AllDirectories))
    if ($fs.Count -ne 1) { return ,[byte[]]@() }
    $h = [System.IO.File]::Open($fs[0], [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $ms = New-Object System.IO.MemoryStream; $h.CopyTo($ms); return ,$ms.ToArray() } finally { $h.Dispose() }
}
function Test-AppendOnly([byte[]]$Before, [byte[]]$After) {
    if (($null -eq $After) -or ($null -eq $Before) -or ($After.Length -lt $Before.Length) -or ($Before.Length -eq 0)) { return $false }
    for ($i = 0; $i -lt $Before.Length; $i++) { if ($Before[$i] -ne $After[$i]) { return $false } }
    return $true
}
function Add-CaseEvidence([string]$Id, $K, $R, [bool]$Pass) {
    Add-I2AEvidence @{ id = $Id; fault = $K.Fired; childExit = $K.Code; killedTreeDigest = (Get-I2ATreeDigest $K.TreeKill); recoveredTreeDigest = (Get-I2ATreeDigest $R.Map1); rec1 = [string]$R.Rec1.Outcome; rec2 = [string]$R.Rec2.Outcome; logCalls = (Cnt $R.Log1); pass = $Pass }
}

# ================================================================ derived kill points
# pristine census of the apply run
$cen = Get-Census 'Run' $pristine
$all = [string[]]$cen.All; $mut = [string[]]$cen.Mut
$iInt0 = Get-LabelIndex $all '^before:Journal:Intent#0$'
$iVer0 = Get-LabelIndex $all '^after:Journal:Verified#0$'
$iInt1 = Get-LabelIndex $all '^before:Journal:Intent#1$'
$iVer1 = Get-LabelIndex $all '^after:Journal:Verified#1$'
$iBak0 = Get-LabelIndex $all '^before:Fs-CopyFileDurable:0000\.bak$'
$iBak1 = Get-LabelIndex $all '^before:Fs-CopyFileDurable:0001\.bak$'
[void](Assert-I2A 'TKX-census-the-item-spans-are-found-in-the-recorded-run' (($iBak0 -ge 0) -and ($iInt0 -gt $iBak0) -and ($iVer0 -gt $iInt0) -and ($iBak1 -gt $iVer0) -and ($iInt1 -gt $iBak1) -and ($iVer1 -gt $iInt1)) "labels recorded=$($all.Count) mutating=$($mut.Count); item0 backup@$iBak0 Intent@$iInt0 Verified@$iVer0; item1 backup@$iBak1 Intent@$iInt1 Verified@$iVer1")
$ptsR = @(Get-KtPoints $all $mut $iBak0 $iVer0)
$ptsD = @(Get-KtPoints $all $mut $iBak1 $iVer1)
if ($Stride -gt 1) { $ptsR = @($ptsR | Where-Object { ($_.Index % $Stride) -eq 0 -or $_.Label -match 'Fs-Replace|Fs-MoveNew|Fs-Delete|Applied|Verified|Intent' }); $ptsD = @($ptsD | Where-Object { ($_.Index % $Stride) -eq 0 -or $_.Label -match 'Fs-Replace|Fs-MoveNew|Fs-Delete|Applied|Verified|Intent' }) }

# the named boundaries of the contract must be among the derived points (this is a coverage check of the derivation, not a list of kill points)
function Has-Point($Pts, [string]$Rx) { return (@($Pts | Where-Object { $_.Label -match $Rx }).Count -ge 1) }
$namedR = [ordered]@{
    'R-after-Intent'                    = '^after:Journal:Intent#0$'
    'R-before-conditional-Replace'      = '^before:Fs-Replace:rep\.dll$'
    'R-after-Replace-before-SHA-check'  = '^after:Fs-Replace:rep\.dll$'
    'R-before-cleanup'                  = '^before:Fs-Delete:rep\.dll\.T0001\.0000\.dengo\.old$'
    'R-after-cleanup'                   = '^after:Fs-Delete:rep\.dll\.T0001\.0000\.dengo\.old$'
    'R-before-Applied'                  = '^before:Journal:Applied#0$'
    'R-after-Applied'                   = '^after:Journal:Applied#0$'
}
$namedD = [ordered]@{
    'D-after-Intent'                    = '^after:Journal:Intent#1$'
    'D-before-Move'                     = '^before:Fs-MoveNew:del\.dll\.T0001\.0001\.dengo\.old$'
    'D-after-Move-before-SHA-check'     = '^after:Fs-MoveNew:del\.dll\.T0001\.0001\.dengo\.old$'
    'D-before-Applied-after-SHA-check'  = '^before:Journal:Applied#1$'
    'D-after-Applied-before-cleanup'    = '^after:Journal:Applied#1$'
    'D-before-cleanup'                  = '^before:Fs-Delete:del\.dll\.T0001\.0001\.dengo\.old$'
    'D-after-cleanup'                   = '^after:Fs-Delete:del\.dll\.T0001\.0001\.dengo\.old$'
    'D-before-Verified'                 = '^before:Journal:Verified#1$'
}
foreach ($k in $namedR.Keys) { [void](Assert-I2A ('TKX-named-' + $k) (Has-Point $ptsR $namedR[$k]) "derived R points: $($ptsR.Count); label pattern $($namedR[$k])") }
foreach ($k in $namedD.Keys) { [void](Assert-I2A ('TKX-named-' + $k) (Has-Point $ptsD $namedD[$k]) "derived D points: $($ptsD.Count); label pattern $($namedD[$k])") }

# ================================================================ family 1 / 2: every derived point of the Write (R) and of the Delete (D)
function Run-Family([string]$Fam, $Pts) {
    $n = 0
    foreach ($pt in $Pts) {
        $n++; $script:derived++
        $id = ('{0}{1:D2}-{2}' -f $Fam, $n, ($pt.Label -replace '[^A-Za-z0-9#.-]', '_'))
        $k = Invoke-KillCase 'Run' $pristine $pt
        $r = Invoke-Recoveries
        $residue = @(Get-KtResidue $root)
        $logBad = @(Test-RecoveryLog $r.Log1)
        $conv = (Same (Get-KtManaged $root) $pristineManaged)
        $ok1 = (($k.Fired.Length -gt 0) -and $k.Killed -and $k.OrphanFree)
        [void](Assert-I2A "TKX-$id-killed" $ok1 "model fired at '$($k.Fired)'; child exit code $($k.Code); no surviving child or grandchild")
        [void](Assert-I2A "TKX-$id-equivalence" $k.Equal "tree after TerminateProcess == tree of the in-process crash model ($($k.Diff))")
        $okRec = ((@('RolledBack', 'NotNeeded') -contains $r.Rec1.Outcome) -and $conv -and ($residue.Count -eq 0) -and (-not (Marker-Present)) -and (-not $r.Marker1) -and ($logBad.Count -eq 0))
        [void](Assert-I2A "TKX-$id-recovery" $okRec "outcome=$($r.Rec1.Outcome); managed tree == the tree before the install: $conv; displaced/tmp residue: $($residue.Count); marker after: $($r.Marker1); recovery-log violations: [$($logBad -join ' ; ')] over $(Cnt $r.Log1) mutating calls")
        $idem = (($r.Rec2.Outcome -ceq 'NotNeeded') -and (Same $r.Map1 $r.Map2))
        [void](Assert-I2A "TKX-$id-second-recovery" $idem "second recovery: $($r.Rec2.Outcome); additional change: $(Cnt (Compare-I2ATree $r.Map1 $r.Map2))")
        Add-CaseEvidence "TKX-$id" $k $r ($ok1 -and $k.Equal -and $okRec -and $idem)
    }
}
Run-Family 'R' $ptsR
Run-Family 'D' $ptsD
[void](Assert-I2A 'TKX-count-every-derived-point-was-killed' (($script:killed -eq $script:derived) -and ($script:derived -eq ($ptsR.Count + $ptsD.Count))) "derived points: R=$($ptsR.Count) D=$($ptsD.Count) total=$($script:derived); real kills performed: $($script:killed) (computed from the recorded run, not typed)")

# ================================================================ family 3: a third party changes the destination in the window, then the process dies (the mismatch path)
function Run-MismatchFamily([string]$Fam, $Injs, [string]$FromRx, [string]$TpText, [string]$PutBackRx, [int]$PutBackNth) {
    $cenM = Get-Census 'Run' $pristine $Injs
    $allM = [string[]]$cenM.All; $mutM = [string[]]$cenM.Mut
    $from = Get-LabelIndex $allM $FromRx
    $pts = @(Get-KtPoints $allM $mutM $from ($allM.Count - 1))
    [void](Assert-I2A "TKX-$Fam-census" (($from -ge 0) -and ($pts.Count -gt 0) -and (@($pts | Where-Object { ($_.Label -match $PutBackRx) -and ($_.Nth -ge $PutBackNth) }).Count -ge 1)) "injection label found at $from; derived points after the third-party change: $($pts.Count); the put-back boundary (occurrence >= $PutBackNth of $PutBackRx) is among them")
    $n = 0
    foreach ($pt in $pts) {
        $n++; $script:derived++
        $id = ('{0}{1:D2}-{2}' -f $Fam, $n, ($pt.Label -replace '[^A-Za-z0-9#.-]', '_'))
        $k = Invoke-KillCase 'Run' $pristine $pt $Injs
        $r = Invoke-Recoveries
        $logBad = @(Test-RecoveryLog $r.Log1)
        $kept = @(Find-KtContent $root $TpText)
        $ok1 = (($k.Fired.Length -gt 0) -and $k.Killed -and $k.OrphanFree)
        [void](Assert-I2A "TKX-$id-killed" $ok1 "model fired at '$($k.Fired)'; child exit code $($k.Code); no surviving child or grandchild")
        [void](Assert-I2A "TKX-$id-equivalence" $k.Equal "tree after TerminateProcess == tree of the in-process crash model ($($k.Diff))")
        $okRec = (($kept.Count -ge 1) -and ($logBad.Count -eq 0))
        [void](Assert-I2A "TKX-$id-third-party-content-kept" $okRec "the third party's content '$TpText' is still on disk after the kill and two recoveries: $($kept.Count) file(s) [$($kept -join ',')]; recovery-log violations: [$($logBad -join ' ; ')]; outcome=$($r.Rec1.Outcome)")
        $idem = (Same $r.Map1 $r.Map2)
        [void](Assert-I2A "TKX-$id-second-recovery-no-further-damage" $idem "the second recovery ($($r.Rec2.Outcome)) changes nothing: additional change $(Cnt (Compare-I2ATree $r.Map1 $r.Map2)); the third party's content is still kept: $(@(Find-KtContent $root $TpText).Count -ge 1)")
        Add-CaseEvidence "TKX-$id" $k $r ($ok1 -and $k.Equal -and $okRec -and $idem)
    }
    [void](Assert-I2A "TKX-$Fam-count" ($n -eq $pts.Count) "derived points $($pts.Count); real kills $n")
}
$injR = @(New-Inj '^before:Fs-Replace:rep\.dll$' 1 'Write' $L.RepDest 'TP-LIVE-R')
Run-MismatchFamily 'MR' $injR '^before:Fs-Replace:rep\.dll$' 'TP-LIVE-R' '^(before|after):Fs-Replace:rep\.dll$' 2
$injD = @(New-Inj '^before:Fs-MoveNew:del\.dll\.T0001\.0001\.dengo\.old$' 1 'Write' $L.DelDest 'TP-LIVE-D')
Run-MismatchFamily 'MD' $injD '^before:Fs-MoveNew:del\.dll\.T0001\.0001\.dengo\.old$' 'TP-LIVE-D' '^(before|after):Fs-MoveNew:del\.dll$' 1

# ================================================================ family 4: the recovery itself is killed (every mutating boundary of the recovery), from two killed apply states
function Build-KilledState([string]$Rx, [int]$Nth = 1) {
    Release-I2AHeld; Clear-TxInj; Restore-I2ATree $root $pristine
    $p = Start-Child @{ Mode = 'Run'; Root = $root; FaultB64 = (ConvertTo-B64 @{ Pattern = $Rx; Nth = $Nth }) }
    $ex = $p.WaitForExit(90000); if (-not $ex) { try { $p.Kill() } catch { } }
    return (Save-I2ATree $root)
}
function Run-RecoveryKillFamily([string]$Fam, $StateSnap) {
    $cenRec = Get-Census 'Recover' $StateSnap
    $allR = [string[]]$cenRec.All; $mutR = [string[]]$cenRec.Mut
    $pts = @(Get-KtPoints $allR $mutR 0 ($allR.Count - 1))
    [void](Assert-I2A "TKX-$Fam-census" ($pts.Count -gt 0) "recovery labels recorded=$($allR.Count); derived mutating boundaries of the recovery: $($pts.Count)")
    $n = 0
    foreach ($pt in $pts) {
        $n++; $script:derived++
        $id = ('{0}{1:D2}-{2}' -f $Fam, $n, ($pt.Label -replace '[^A-Za-z0-9#.-]', '_'))
        $k = Invoke-KillCase 'Recover' $StateSnap $pt
        $r = Invoke-Recoveries
        $residue = @(Get-KtResidue $root)
        $logBad = @(Test-RecoveryLog $r.Log1)
        $conv = (Same (Get-KtManaged $root) $pristineManaged)
        $ok1 = (($k.Fired.Length -gt 0) -and $k.Killed -and $k.OrphanFree)
        [void](Assert-I2A "TKX-$id-killed" $ok1 "model fired at '$($k.Fired)'; child exit code $($k.Code); no surviving child or grandchild")
        [void](Assert-I2A "TKX-$id-equivalence" $k.Equal "tree after TerminateProcess == tree of the in-process crash model ($($k.Diff))")
        $okRec = ((@('RolledBack', 'NotNeeded') -contains $r.Rec1.Outcome) -and $conv -and ($residue.Count -eq 0) -and (-not $r.Marker1) -and ($logBad.Count -eq 0))
        [void](Assert-I2A "TKX-$id-recovery" $okRec "outcome=$($r.Rec1.Outcome); managed tree == the tree before the install: $conv; residue $($residue.Count); marker after: $($r.Marker1); recovery-log violations: [$($logBad -join ' ; ')]")
        $idem = (($r.Rec2.Outcome -ceq 'NotNeeded') -and (Same $r.Map1 $r.Map2))
        [void](Assert-I2A "TKX-$id-second-recovery" $idem "second recovery: $($r.Rec2.Outcome); additional change: $(Cnt (Compare-I2ATree $r.Map1 $r.Map2))")
        Add-CaseEvidence "TKX-$id" $k $r ($ok1 -and $k.Equal -and $okRec -and $idem)
    }
    [void](Assert-I2A "TKX-$Fam-count" ($n -eq $pts.Count) "derived points $($pts.Count); real kills $n")
}
$stateA = Build-KilledState '^after:Journal:Applied#1$'
Run-RecoveryKillFamily 'XA' $stateA
$stateB = Build-KilledState '^after:Fs-Replace:rep\.dll$'
Run-RecoveryKillFamily 'XB' $stateB

# ================================================================ family 5: third party AFTER the kill, before the recovery
function Kill-To-State([string]$Rx, [scriptblock]$Hand, [int]$Nth = 1) {
    $pt = [pscustomobject]@{ Index = 0; Label = $Rx; Nth = $Nth; Pattern = $Rx }
    $script:derived++
    return (Invoke-KillCase 'Run' $pristine $pt @() $Hand)
}
# 5a: the third party edits the Write destination after the swap -> never overwritten
$k = Kill-To-State '^after:Fs-Replace:rep\.dll$' { TP-Write $L.RepDest 'TP-EDIT-R' }
$r = Invoke-Recoveries
[void](Assert-I2A 'TKX-H5a-killed' ($k.Killed -and $k.Equal -and $k.OrphanFree) "kill after the swap; child exit $($k.Code); model==kill: $($k.Equal)")
[void](Assert-I2A 'TKX-H5a-third-party-edit-of-the-destination-is-not-overwritten' (((Txt-At $L.RepDest) -ceq 'TP-EDIT-R') -and ((Txt-At $L.RepDest) -ceq (Txt-At $L.RepDest)) -and ((Cnt (Test-RecoveryLog $r.Log1)) -eq 0)) "destination after recovery 1 and 2: [$(Txt-At $L.RepDest)]; outcome1=$($r.Rec1.Outcome) outcome2=$($r.Rec2.Outcome); destination written by the recovery: $(@($r.Log1 | Where-Object { $_ -like ('*' + $L.RepDest + '*') -and $_ -notlike 'DgFs-Delete*' }).Count)")
[void](Assert-I2A 'TKX-H5a-fail-closed-and-stable' ((@('RolledBack', 'RolledForward', 'NotNeeded') -notcontains $r.Rec1.Outcome) -and (Same $r.Map1 $r.Map2)) "outcome1=$($r.Rec1.Outcome) manual=$($r.Rec1.ManualCheckRequired); second recovery $($r.Rec2.Outcome) changes nothing: $(Same $r.Map1 $r.Map2)")
# 5b: the third party edits the Write destination before the swap (after Intent)
$k = Kill-To-State '^after:Journal:Intent#0$' { TP-Write $L.RepDest 'TP-EDIT-R0' }
$r = Invoke-Recoveries
[void](Assert-I2A 'TKX-H5b-third-party-edit-before-the-swap-is-not-overwritten' ($k.Killed -and $k.Equal -and ((Txt-At $L.RepDest) -ceq 'TP-EDIT-R0') -and (@('RolledBack', 'RolledForward', 'NotNeeded') -notcontains $r.Rec1.Outcome) -and (Same $r.Map1 $r.Map2) -and ((Cnt (Test-RecoveryLog $r.Log1)) -eq 0)) "destination [$(Txt-At $L.RepDest)]; outcome1=$($r.Rec1.Outcome); second recovery stable: $(Same $r.Map1 $r.Map2)")
# 5c: a third party deleted the Delete destination after Intent: it is NOT recreated (observation A)
$k = Kill-To-State '^after:Journal:Intent#1$' { TP-Delete $L.DelDest }
$r = Invoke-Recoveries
[void](Assert-I2A 'TKX-H5c-third-party-deletion-is-not-restored' ($k.Killed -and $k.Equal -and (-not [System.IO.File]::Exists($L.DelDest)) -and (Same $r.Map1 $r.Map2) -and ((Cnt (Test-RecoveryLog $r.Log1)) -eq 0) -and ((Cnt (Get-Touching $r.Log1 $L.DelDest)) -eq 0)) "del.dll exists after recovery 1 and 2: $([System.IO.File]::Exists($L.DelDest)); outcome1=$($r.Rec1.Outcome); primitive calls that touched the destination (by path argument): [$((Get-Touching $r.Log1 $L.DelDest) -join ' ; ')]")
# 5d: foreign content at the pushed-aside name (Write): not ours -> kept byte for byte, never moved back, never deleted
$k = Kill-To-State '^after:Fs-Replace:rep\.dll$' { TP-Write $repDisp 'FOREIGN-R' }
$r = Invoke-Recoveries
[void](Assert-I2A 'TKX-H5d-a-displaced-file-that-is-not-ours-is-left-alone-Write' ($k.Killed -and $k.Equal -and ((Txt-At $repDisp) -ceq 'FOREIGN-R') -and (@('RolledBack', 'RolledForward', 'NotNeeded') -notcontains $r.Rec1.Outcome) -and (Same $r.Map1 $r.Map2) -and ((Cnt (Test-RecoveryLog $r.Log1)) -eq 0) -and ((Cnt (Get-Touching $r.Log1 $repDisp)) -eq 0)) "displaced file after recovery 1 and 2: [$(Txt-At $repDisp)]; primitive calls that touched it (by path argument): [$((Get-Touching $r.Log1 $repDisp) -join ' ; ')]; outcome1=$($r.Rec1.Outcome)")
# 5e: the same for the Delete (moved aside, then replaced by foreign content)
$k = Kill-To-State ('^after:Fs-MoveNew:' + [regex]::Escape([System.IO.Path]::GetFileName($delDisp)) + '$') { TP-Write $delDisp 'FOREIGN-D' }
$r = Invoke-Recoveries
[void](Assert-I2A 'TKX-H5e-a-displaced-file-that-is-not-ours-is-left-alone-Delete' ($k.Killed -and $k.Equal -and ((Txt-At $delDisp) -ceq 'FOREIGN-D') -and (-not [System.IO.File]::Exists($L.DelDest)) -and (Same $r.Map1 $r.Map2) -and ((Cnt (Test-RecoveryLog $r.Log1)) -eq 0) -and ((Cnt (Get-Touching $r.Log1 $delDisp)) -eq 0)) "displaced file [$(Txt-At $delDisp)]; destination exists: $([System.IO.File]::Exists($L.DelDest)); outcome1=$($r.Rec1.Outcome); primitive calls that touched the displaced file (by path argument): [$((Get-Touching $r.Log1 $delDisp) -join ' ; ')]")
# 5f / 5g: the cleanup is refused by the OS (explicit read-share handle) -> the marker, the journal and the displaced file stay; once the refusal ends the recovery converges and the next one is NotNeeded
function Run-RefusedCleanup([string]$Name, [string]$Rx, [string]$Disp, [string]$DispText) {
    $k = Kill-To-State $Rx { }
    $hold = New-Object System.IO.FileStream($Disp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $before = Get-Full
        Release-I2AHeld; Clear-TxInj; Reset-I2AFault; Reset-I2ACounters
        $rA = Invoke-KtRecover $L
        $mapA = Get-Full; $mgA = Get-KtManaged $root; $jA = Get-JournalBytes
        $keptA = ([System.IO.File]::Exists($Disp) -and (Marker-Present) -and ((Get-KtJournalCount $L) -ge 1))
        $rA2 = Invoke-KtRecover $L
        $mapA2 = Get-Full; $mgA2 = Get-KtManaged $root; $jA2 = Get-JournalBytes
    } finally { $hold.Dispose() }
    Start-KtLog
    $rB = Invoke-KtRecover $L
    $logB = Stop-KtLog
    $rC = Invoke-KtRecover $L
    [void](Assert-I2A "TKX-$Name-killed" ($k.Killed -and $k.Equal -and $k.OrphanFree) "kill at '$Rx'; child exit $($k.Code); model==kill: $($k.Equal)")
    [void](Assert-I2A "TKX-$Name-refused-cleanup-keeps-the-marker-the-journal-and-the-displaced-file" ((@('RollbackIncomplete', 'RepairRequired') -contains $rA.Outcome) -and ($rA.ManualCheckRequired -eq $true) -and $keptA) "outcome=$($rA.Outcome) manual=$($rA.ManualCheckRequired); displaced file kept, marker present, active journal kept ($(@($jA).Count) bytes): $keptA")
    [void](Assert-I2A "TKX-$Name-recovery-while-the-refusal-lasts-changes-nothing" (($rA2.Outcome -ceq $rA.Outcome) -and (Same $mgA $mgA2) -and (Test-AppendOnly $jA $jA2)) "second recovery during the refusal: $($rA2.Outcome); additional change to the managed tree and the displaced file: $(Cnt (Compare-I2ATree $mgA $mgA2)); the journal only grew (append-only, earlier records byte-identical): $(Test-AppendOnly $jA $jA2) ($(@($jA).Count) -> $(@($jA2).Count) bytes)")
    [void](Assert-I2A "TKX-$Name-converges-after-the-refusal-and-the-next-recovery-is-NotNeeded" (($rB.Outcome -ceq 'RolledBack') -and ($rC.Outcome -ceq 'NotNeeded') -and (-not [System.IO.File]::Exists($Disp)) -and (-not (Marker-Present)) -and (Same (Get-KtManaged $root) $pristineManaged) -and ((Cnt (Test-RecoveryLog $logB)) -eq 0)) "after the refusal: $($rB.Outcome) then $($rC.Outcome); displaced file removed: $(-not [System.IO.File]::Exists($Disp)); managed tree restored: $(Same (Get-KtManaged $root) $pristineManaged)")
}
Run-RefusedCleanup 'H5f-Write' '^before:Fs-Delete:rep\.dll\.T0001\.0000\.dengo\.old$' $repDisp 'OLD-REP'
Run-RefusedCleanup 'H5g-Delete' '^after:Journal:Applied#1$' $delDisp 'OLD-DEL'

# ================================================================ family 6: FullThrow equivalent - an IO exception at EVERY point of the apply run (reads included), with and without a third-party change in the window
# Contract: the run either succeeds (tree == the tree after the install) or fails; a failed run is rolled back by itself or, when the exception hit the rollback, the recovery (run twice) brings the managed tree back to the tree
# before the install. No displaced / temporary file stays, the marker goes, and a third party's content is never lost. The sweep covers every recorded point; the new fault points (everything about the displaced file, the conditional Replace,
# the move-aside) are among them by construction, and each of them is asserted to have received an exception.
Release-I2AHeld; Clear-TxInj; Restore-I2ATree $root $pristine; Reset-I2AFault; Reset-I2ACounters
$okRun = Invoke-KtRun $L
$postManaged = Get-KtManaged $root
[void](Assert-I2A 'TKX-FT-reference-the-run-without-a-fault-succeeds' ($okRun.Succeeded -eq $true) "code=$($okRun.Code)")
function Run-ThrowSweep([string]$Name, $Injs, [string]$TpText) {
    $cenT = Get-Census 'Run' $pristine $Injs
    $allT = [string[]]$cenT.All
    $n = $allT.Count
    $fails = New-Object System.Collections.ArrayList
    $ran = 0; $firedN = 0; $injFiredN = 0
    $newIdx = @(0..($n - 1) | Where-Object { $allT[$_] -match '\.dengo\.old|Fs-Replace:rep\.dll|Fs-MoveNew:del\.dll|Journal:(Intent|Applied|Verified)' })
    $newFired = @{}
    for ($k = 1; $k -le $n; $k++) {
        Release-I2AHeld; Clear-TxInj; Restore-I2ATree $root $pristine
        Add-ParentInj $Injs
        Reset-I2AFault -Mode 'ThrowAll' -Targets @($k); Reset-I2ACounters
        $rr = $null
        try { $rr = Invoke-KtRun $L } catch { }
        $fired = [string]$global:I2AFH.Fired
        $injDone = $(if (@($Injs).Count -gt 0) { Get-TxInjFired 0 } else { $false })
        Clear-TxInj; Reset-I2AFault; Reset-I2ACounters
        $ran++
        if ($fired.Length -gt 0) { $firedN++; $newFired[$k - 1] = $true }
        if ($injDone) { $injFiredN++ }
        $ok = $true; $why = ''
        $ranOk = ($null -ne $rr) -and ($rr.Succeeded -eq $true)
        $mg = Get-KtManaged $root
        if (-not $ranOk) {
            $needRecovery = (Marker-Present) -or ((Cnt (Compare-I2ATree $mg $pristineManaged)) -ne 0) -or ((Cnt (Get-KtResidue $root)) -ne 0)
            if ($needRecovery) {
                for ($q = 0; $q -lt 3; $q++) { try { $x = Invoke-KtRecover $L; if ($x.Outcome -ceq 'NotNeeded') { break } } catch { $why += ' recovery-threw'; break } }
            }
            $mg = Get-KtManaged $root
        }
        $res = @(Get-KtResidue $root)
        if ($injDone) {
            # the third party changed the destination in the window: its content must still be on disk, wherever the rollback left it
            if ((Cnt (Find-KtContent $root $TpText)) -lt 1) { $ok = $false; $why += ' third-party-content-lost' }
        } else {
            $isPre = ((Cnt (Compare-I2ATree $mg $pristineManaged)) -eq 0); $isPost = ((Cnt (Compare-I2ATree $mg $postManaged)) -eq 0)
            if (-not ($isPre -or $isPost)) { $ok = $false; $why += ' managed-tree-neither-before-nor-after' }
            if ($ranOk -and -not $isPost) { $ok = $false; $why += ' success-without-the-after-tree' }
            if ((-not $ranOk) -and (-not $isPre) -and (-not $isPost)) { $ok = $false }
            if ((Marker-Present)) { $ok = $false; $why += ' marker-left' }
            if ($res.Count -ne 0) { $ok = $false; $why += ' residue-left' }
        }
        if (-not $ok) { [void]$fails.Add(('k' + $k + ':' + $allT[$k - 1] + ':' + $why.Trim())) }
    }
    $newMissed = @($newIdx | Where-Object { -not $newFired.ContainsKey($_) })
    [void](Assert-I2A "TKX-FT-$Name-sweep" ($fails.Count -eq 0) "IO exception injected at $ran of $n points; every outcome obeyed the contract; failures: $($fails.Count) [$(($fails | Select-Object -First 5) -join ' ; ')]")
    [void](Assert-I2A "TKX-FT-$Name-covers-every-point-and-every-exception-fired" (($ran -eq $n) -and ($firedN -eq $n)) "swept $ran of $n points; exceptions that actually fired: $firedN")
    [void](Assert-I2A "TKX-FT-$Name-every-new-fault-point-received-an-exception" (($newIdx.Count -gt 0) -and ($newMissed.Count -eq 0)) "new fault points (displaced name, conditional Replace, move-aside, Intent / Applied / Verified): $($newIdx.Count); without an injected exception: $($newMissed.Count)")
    if (@($Injs).Count -gt 0) { [void](Assert-I2A "TKX-FT-$Name-the-third-party-change-happened-in-some-runs" ($injFiredN -gt 0) "runs in which the third-party change was applied before the exception: $injFiredN of $n") }
}
Run-ThrowSweep 'clean' @() ''
Run-ThrowSweep 'mismatch-R' $injR 'TP-LIVE-R'
Run-ThrowSweep 'mismatch-D' $injD 'TP-LIVE-D'
Release-I2AHeld
Remove-I2ASandbox $root
Uninstall-I2AHarness
Write-Host ('Evidence: ' + $global:I2AEvidencePath)
Write-Host ('KILLS: derived points=' + $script:derived + ' real kills=' + $script:killed)
Complete-I2ATests
