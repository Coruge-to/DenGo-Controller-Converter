# I2-A unit tests: hash chain, journal parser, summary rules, path policy, plan validation, journal contents, classification,
# primitive behaviour (atomic replace, exclusive probe) and the documented known limitations. Real primitives, TEMP sandboxes only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')

function Cnt($X) { if ($null -eq $X) { return 0 }; return @($X).Count }
function Same($A, $B) { return ((Cnt (Compare-I2ATree $A $B)) -eq 0) }
function U([int[]]$CodePoints) { return -join ($CodePoints | ForEach-Object { [string][char]$_ }) }
function Get-CodeOf([scriptblock]$Block) { try { & $Block | Out-Null; return 'NoError' } catch { $c = DgError-Code $_.Exception; if ($c.Length -gt 0) { return $c }; return ('Other:' + (DgError-Root $_.Exception).GetType().Name) } }

$root = New-I2ASandbox 'unit'
try {
    # ------------------------------------------------ U1 hash chain
    $zero = DgConst-ZeroHash
    $f1 = [ordered]@{ schemaVersion = 1; transactionId = 'T1'; operation = 'Install'; sequence = 1; timestamp = 't'; stage = 'Begin' }
    $r1 = DgJournal-FormatRecord $f1 $zero
    $f2 = [ordered]@{ schemaVersion = 1; transactionId = 'T1'; operation = 'Install'; sequence = 2; timestamp = 't'; stage = 'Committed' }
    $r2 = DgJournal-FormatRecord $f2 $r1.Hash
    [void](Assert-I2A 'U1-line-shape' ($r1.Line.EndsWith('"}') -and ($r1.Line.IndexOf('"recordHash":"' + $r1.Hash + '"}') -eq ($r1.Line.Length - 81 + 1)) -and ($r1.Line.IndexOf("`n") -lt 0)) 'one line, recordHash is the last field and is 64 hex characters')
    $v1 = DgJournal-VerifyLine $r1.Line $zero
    $v2 = DgJournal-VerifyLine $r2.Line $r1.Hash
    [void](Assert-I2A 'U1-chain-ok' ($v1.Ok -and $v2.Ok -and ([string]$v2.Record.previousHash -eq $r1.Hash)) 'records verify; previousHash of record 2 equals recordHash of record 1')
    $flip = $r1.Line.Replace('"Begin"', '"Bagin"')
    [void](Assert-I2A 'U1-body-tamper' ((DgJournal-VerifyLine $flip $zero).Reason -eq 'RecordHashMismatch') 'a changed body byte is detected (RecordHashMismatch)')
    [void](Assert-I2A 'U1-previous-mismatch' ((DgJournal-VerifyLine $r2.Line $zero).Reason -eq 'PreviousHashMismatch') 'a wrong previousHash is detected')
    [void](Assert-I2A 'U1-truncated' ((DgJournal-VerifyLine $r1.Line.Substring(0, 60) $zero).Reason -eq 'LineShape') 'a truncated line is rejected (LineShape)')
    [void](Assert-I2A 'U1-lowercase-hash' ((DgJournal-VerifyLine ($r1.Line.Substring(0, $r1.Line.Length - 81) + ',"recordHash":"' + $r1.Hash.ToLowerInvariant() + '"}') $zero).Reason -eq 'HashShape') 'only upper-case hex hashes are accepted')
    $req = @('schemaVersion', 'transactionId', 'operation', 'sequence', 'previousHash', 'recordHash', 'stage', 'timestamp')
    $miss = @($req | Where-Object { $null -eq $v1.Record.PSObject.Properties[$_] })
    [void](Assert-I2A 'U1-required-fields' ($miss.Count -eq 0) 'every record carries schemaVersion, transactionId, operation, sequence, previousHash, recordHash')

    # ------------------------------------------------ U2 parser
    function New-TestJournal([string]$Path, [object[]]$Extras, [string]$Txn = 'T1') {
        $prev = DgConst-ZeroHash; $sb = New-Object System.Text.StringBuilder; $seq = 0
        foreach ($x in $Extras) {
            $seq++
            $d = New-Object System.Collections.Specialized.OrderedDictionary
            $d.Add('schemaVersion', 1); $d.Add('transactionId', $Txn); $d.Add('operation', 'Install'); $d.Add('sequence', $seq); $d.Add('timestamp', 't'); $d.Add('stage', $x.Stage)
            foreach ($k in $x.Extra.Keys) { $d.Add($k, $x.Extra[$k]) }
            $r = DgJournal-FormatRecord $d $prev
            [void]$sb.Append($r.Line + "`n"); $prev = $r.Hash
        }
        [System.IO.File]::WriteAllBytes($Path, $script:Utf8.GetBytes($sb.ToString()))
    }
    $jp = Join-Path $root 'j.jsonl'
    $four = @(@{ Stage = 'Begin'; Extra = [ordered]@{ stateRoot = 'C:\s'; backupRoot = 'C:\b'; oldStateSha = ''; newStatePath = 'C:\s\installed-state.json'; newStateTmp = 'C:\s\installed-state.json.tmp'; itemCount = 1 } },
        @{ Stage = 'Register'; Extra = [ordered]@{ itemId = 0; path = 'C:\x\a.dll'; normalizedPath = 'C:\x\a.dll'; op = 'Write'; preExists = $false; preSha = ''; expectedPostSha = 'AA'; backupPath = ''; tmpPath = 'C:\x\a.dll.dengo.tmp'; dirsToCreate = @(); reparsePoints = @(); ownershipCandidate = 'CreatedByInstaller'; tag = 'a' } },
        @{ Stage = 'Intent'; Extra = [ordered]@{ itemId = 0; path = 'C:\x\a.dll'; normalizedPath = 'C:\x\a.dll'; backupPath = ''; backupSha = ''; backupCreated = $false; preSha = ''; expectedPostSha = 'AA' } },
        @{ Stage = 'Applied'; Extra = [ordered]@{ itemId = 0; path = 'C:\x\a.dll'; normalizedPath = 'C:\x\a.dll'; observedPostSha = 'AA' } })
    New-TestJournal $jp $four
    $bytes = [System.IO.File]::ReadAllBytes($jp)
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-valid' ((@($p.Records).Count -eq 4) -and (-not $p.TornTail) -and (-not $p.Corrupt) -and ($p.ValidLength -eq $bytes.Length)) 'valid journal: 4 records, ValidLength == file length')
    $lastStart = [array]::LastIndexOf($bytes, [byte]10, $bytes.Length - 2) + 1
    $cut = New-Object byte[] ($bytes.Length - 10); [System.Array]::Copy($bytes, $cut, $cut.Length); [System.IO.File]::WriteAllBytes($jp, $cut)
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-unterminated-tail' ((@($p.Records).Count -eq 3) -and $p.TornTail -and (-not $p.Corrupt) -and ($p.ValidLength -eq $lastStart)) "unterminated last line is a torn tail ($($p.TornReason)); ValidLength points at the end of record 3")
    $g = New-Object byte[] $bytes.Length; [System.Array]::Copy($bytes, $g, $lastStart); for ($i = $lastStart; $i -lt ($bytes.Length - 1); $i++) { $g[$i] = 88 }; $g[$bytes.Length - 1] = 10; [System.IO.File]::WriteAllBytes($jp, $g)
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-terminated-garbage-tail' ((@($p.Records).Count -eq 3) -and $p.TornTail -and (-not $p.Corrupt)) 'a garbage LF-terminated LAST line is tolerated as a torn tail')
    $n = New-Object byte[] ($bytes.Length + 50); [System.Array]::Copy($bytes, $n, $bytes.Length); [System.IO.File]::WriteAllBytes($jp, $n)
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-nul-tail' ((@($p.Records).Count -eq 4) -and $p.TornTail -and (-not $p.Corrupt)) 'trailing NUL padding is a torn tail; the 4 complete records are kept')
    $m = $bytes.Clone(); $m[40] = [byte]([int]$m[40] -bxor 1); [System.IO.File]::WriteAllBytes($jp, $m)
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-middle-corrupt' ($p.Corrupt -and ($p.CorruptLine -eq 1)) "damage in an earlier line is Corrupt ($($p.CorruptReason))")
    $two = @($four[0], $four[1], $four[2], $four[3]); New-TestJournal $jp $two
    $lines = @([System.IO.File]::ReadAllText($jp) -split "`n" | Where-Object { $_.Length -gt 0 })
    [System.IO.File]::WriteAllBytes($jp, $script:Utf8.GetBytes(($lines[0] + "`n" + $lines[2] + "`n" + $lines[3] + "`n")))
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-record-removed' ($p.Corrupt) 'a removed middle record breaks the chain and the sequence (Corrupt)')
    Edit-I2AJournal $jp { param($recs) } { param($s) if ($s -ge 3) { $s + 1 } else { $s } }
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-sequence-gap' ($p.Corrupt -and ($p.CorruptReason -eq 'SequenceMismatch')) "a consistent chain with a sequence gap is Corrupt ($($p.CorruptReason))")
    New-TestJournal $jp $four; Edit-I2AJournal $jp { param($recs) $recs[2]['transactionId'] = 'OTHER' }
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-txn-mismatch' ($p.Corrupt -and ($p.CorruptReason -eq 'TxnMismatch')) 'records of a different transaction in the same file are Corrupt')
    [System.IO.File]::WriteAllBytes($jp, (New-Object byte[] 0))
    $p = DgJournal-Parse $jp
    [void](Assert-I2A 'U2-empty' ((@($p.Records).Count -eq 0) -and (-not $p.Corrupt) -and (-not (DgJournal-Summarize $p).Ok)) 'an empty journal has no records and cannot be summarized')
    $jp2 = Join-Path $root 'jp.jsonl'; $jpath = 'C:\' + (U 0x65E5, 0x672C, 0x8A9E) + '\a.dll'
    $uni = @($four[0], @{ Stage = 'Register'; Extra = [ordered]@{ itemId = 0; path = $jpath; normalizedPath = $jpath; op = 'Write'; preExists = $false; preSha = ''; expectedPostSha = 'AA'; backupPath = ''; tmpPath = ($jpath + '.dengo.tmp'); dirsToCreate = @(); reparsePoints = @(); ownershipCandidate = ''; tag = '' } })
    New-TestJournal $jp2 $uni
    $p = DgJournal-Parse $jp2; $s = DgJournal-Summarize $p
    [void](Assert-I2A 'U2-non-ascii-path' ((-not $p.Corrupt) -and $s.Ok -and ($s.Items[0].Norm -ceq $jpath) -and ($p.ValidLength -eq [System.IO.File]::ReadAllBytes($jp2).Length)) 'a non-ASCII path round-trips; ValidLength counts bytes, not characters')
    # shared read while the single writer is open; a second writer is refused
    $jw = Join-Path $root 'writer.jsonl'
    $ws = DgJournal-Open $jw
    DgJournal-Append $ws ($script:Utf8.GetBytes("abc`n"))
    $read = [System.Text.Encoding]::UTF8.GetString([byte[]](DgFs-ReadAllBytesShared $jw))
    $second = Get-CodeOf { $x = New-Object System.IO.FileStream($jw, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read); $x.Dispose() }
    DgJournal-Close $ws
    [void](Assert-I2A 'U2-shared-read-single-writer' (($read -eq "abc`n") -and ($second -like 'Other:*')) 'readers (FileShare.ReadWrite) see flushed records while the writer is open; a second writer is refused')

    # ------------------------------------------------ U3 summary rules
    function Summ($extras) { $f = Join-Path $root ('s-' + [guid]::NewGuid().ToString('N') + '.jsonl'); New-TestJournal $f $extras; return (DgJournal-Summarize (DgJournal-Parse $f)) }
    function Itm($stage, $id, $path) { return @{ Stage = $stage; Extra = [ordered]@{ itemId = $id; path = $path; normalizedPath = $path; backupPath = ''; backupSha = ''; backupCreated = $false; preSha = ''; expectedPostSha = 'AA'; observedPostSha = 'AA'; verifiedSha = 'AA' } } }
    $B = $four[0]; $R = $four[1]
    [void](Assert-I2A 'U3-ok' ((Summ @($B, $R, $four[2], $four[3], (Itm 'Verified' 0 'C:\x\a.dll'))).Ok) 'Begin, Register, Intent, Applied, Verified is a valid sequence')
    [void](Assert-I2A 'U3-first-not-begin' ((Summ @($R)).Reason -eq 'FirstNotBegin') 'the first record must be Begin')
    [void](Assert-I2A 'U3-applied-without-intent' ((Summ @($B, $R, $four[3])).Reason -eq 'AppliedOrder') 'Applied without Intent is rejected')
    [void](Assert-I2A 'U3-verified-without-applied' ((Summ @($B, $R, $four[2], (Itm 'Verified' 0 'C:\x\a.dll'))).Reason -eq 'VerifiedOrder') 'Verified without Applied is rejected')
    [void](Assert-I2A 'U3-duplicate-intent' ((Summ @($B, $R, $four[2], $four[2])).Reason -eq 'DuplicateIntent') 'a second Intent for one item is rejected')
    [void](Assert-I2A 'U3-unregistered-item' ((Summ @($B, $R, (Itm 'Intent' 5 'C:\x\a.dll'))).Reason -eq 'UnregisteredItem') 'a record for an item that was never registered is rejected')
    [void](Assert-I2A 'U3-path-mismatch' ((Summ @($B, $R, (Itm 'Intent' 0 'C:\x\other.dll'))).Reason -eq 'UnregisteredPath') 'an Intent naming a different path than the Register record is rejected')
    [void](Assert-I2A 'U3-register-gap' ((Summ @($B, $four[1], @{ Stage = 'Register'; Extra = [ordered]@{ itemId = 3; path = 'C:\x\b.dll'; normalizedPath = 'C:\x\b.dll'; op = 'Write'; preExists = $false; preSha = ''; expectedPostSha = 'AA'; backupPath = ''; tmpPath = ''; dirsToCreate = @(); reparsePoints = @(); ownershipCandidate = ''; tag = '' } })).Reason -eq 'RegisterIdGap') 'item ids must be consecutive')
    [void](Assert-I2A 'U3-register-after-work' ((Summ @($B, $R, $four[2], $R)).Reason -eq 'RegisterAfterWork') 'Register records may only precede the work')
    [void](Assert-I2A 'U3-committed-without-intent' ((Summ @($B, $R, @{ Stage = 'Committed'; Extra = [ordered]@{} })).Reason -eq 'CommittedWithoutIntent') 'Committed requires CommitIntent')
    [void](Assert-I2A 'U3-record-after-end' ((Summ @($B, $R, @{ Stage = 'CommitIntent'; Extra = [ordered]@{ newStatePath = 'p'; newStateTmp = 'q'; newStateSha = 'S' } }, @{ Stage = 'Committed'; Extra = [ordered]@{} }, $four[2])).Reason -eq 'RecordAfterEnd') 'nothing may follow Committed')

    # ------------------------------------------------ U4 path policy
    $pr = Join-Path $root 'Allowed'; [System.IO.Directory]::CreateDirectory($pr) | Out-Null
    $sib = $pr + 'X'; [System.IO.Directory]::CreateDirectory($sib) | Out-Null
    $pol = DgPolicy-New @($pr) 'Reject'
    $cases = @(
        @('inside', (Join-Path $pr 'a\b.dll'), $true, ''), @('case-insensitive root', ($pr.ToUpperInvariant() + '\a.dll'), $true, ''), @('forward slashes', ($pr.Replace('\', '/') + '/a.dll'), $true, ''),
        @('root itself', $pr, $false, 'PathOutsideRoot'), @('sibling with same prefix', (Join-Path $sib 'a.dll'), $false, 'PathOutsideRoot'),
        @('dot-dot segment', ($pr + '\a\..\..\Allowed\b.dll'), $false, 'PathDotDot'), @('dot-dot escape', ($pr + '\..\x.dll'), $false, 'PathDotDot'),
        @('unc', '\\server\share\a.dll', $false, 'PathUnc'), @('device path', '\\?\C:\Windows\a.dll', $false, 'PathUnc'), @('relative', 'a\b.dll', $false, 'PathNotAbsolute'),
        @('drive relative', 'C:a.dll', $false, 'PathNotAbsolute'), @('alternate data stream', ($pr + '\a.dll:evil'), $false, 'PathStream'), @('wildcard', ($pr + '\*.dll'), $false, 'PathWildcard'),
        @('empty', '', $false, 'PathEmpty'), @('outside', 'C:\Windows\System32\x.dll', $false, 'PathOutsideRoot'))
    $bad = @()
    foreach ($t in $cases) { $r = DgPolicy-TestPath $pol $t[1]; if (($r.Allowed -ne $t[2]) -or ((-not $t[2]) -and ($r.Reason -ne $t[3]))) { $bad += ($t[0] + ':' + $r.Allowed + '/' + $r.Reason) } }
    [void](Assert-I2A 'U4-path-table' ($bad.Count -eq 0) ("$($cases.Count) path cases (boundary, case, slashes, .., UNC, device, stream, wildcard, sibling prefix): $($bad -join '; ')"))
    [System.IO.Directory]::CreateDirectory((Join-Path $pr 'real')) | Out-Null
    $link = Join-Path $pr 'link'; $o = & cmd.exe /c ('mklink /J "' + $link + '" "' + (Join-Path $pr 'real') + '"')
    $rj = DgPolicy-TestPath $pol (Join-Path $link 'a.dll')
    $polRec = DgPolicy-New @($pr) 'RecordOnly'
    $rr = DgPolicy-TestPath $polRec (Join-Path $link 'a.dll')
    [void](Assert-I2A 'U4-reparse-point' ((-not $rj.Allowed) -and ($rj.Reason -eq 'PathReparse') -and $rr.Allowed -and (Cnt $rr.Reparse) -eq 1) 'a junction inside the root is rejected in Reject mode and recorded (not rejected) in RecordOnly mode')
    $rootPolicy = DgPolicy-New @($pr, (Join-Path $pr 'real')) 'Reject'
    [void](Assert-I2A 'U4-most-specific-root' ((DgPolicy-TestPath $rootPolicy (Join-Path $pr 'real\x.dll')).Root -eq (Join-Path $pr 'real')) 'with nested roots the longest matching root is reported')
    [System.IO.Directory]::Delete($link)   # remove the junction itself, never its target

    # ------------------------------------------------ U5 plan validation (Begin)
    function New-Case([string]$Sc) { $r = New-I2ASandbox ('u5-' + $Sc); $l = New-I2AFixture $r $Sc; return @{ Root = $r; Layout = $l } }
    function Try-Begin($L, $Items, [string]$Operation = 'Install', [object]$Policy = $null) {
        $pol2 = $(if ($null -ne $Policy) { $Policy } else { $L.Policy })
        return (Get-CodeOf { DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation $Operation -Items $Items -Policy $pol2 -NewStatePath $L.StatePath })
    }
    $cs = New-Case 'F4'; $L = $cs.Layout
    $good = Get-I2AScenarioItems $L
    $ctx = DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items $good -Policy $L.Policy -NewStatePath $L.StatePath
    $markerCode = Try-Begin $L $good
    [void](Assert-I2A 'U5-marker-exists' ($markerCode -eq 'MarkerExists') "a second Begin while a marker exists is refused ($markerCode)")
    $journalActive = [System.IO.File]::Exists($ctx.JournalPath); $markerThere = [System.IO.File]::Exists($ctx.MarkerPath)
    $histBefore = Cnt ([System.IO.Directory]::GetFiles($L.State, '*', [System.IO.SearchOption]::AllDirectories) | Where-Object { $_ -like '*\history\*' })
    [void](Assert-I2A 'U5-active-vs-history' ($journalActive -and $markerThere -and ($histBefore -eq 0) -and ($ctx.JournalPath -like '*\State\txn\*')) 'while open: journal under txn\<id>\, marker present, history empty')
    $rb = DgTx-Rollback $ctx 'unit'
    $hist = @([System.IO.Directory]::GetFiles((Join-Path $L.State 'history')))
    [void](Assert-I2A 'U5-rollback-archives' (($rb.Outcome -eq 'RolledBack') -and (-not [System.IO.File]::Exists($ctx.MarkerPath)) -and (-not [System.IO.Directory]::Exists($ctx.TxnDir)) -and ($hist.Count -eq 1) -and ($hist[0] -like '*.rolledback.jsonl')) 'after rollback: marker gone, txn dir gone, journal archived to history\*.rolledback.jsonl (nothing deleted)')
    Remove-I2ASandbox $cs.Root

    $tests = @(
        @('empty-items', { $c = New-Case 'F4'; try { Try-Begin $c.Layout @() } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('bad-operation', { $c = New-Case 'F4'; try { Try-Begin $c.Layout (Get-I2AScenarioItems $c.Layout) 'Repair' } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('bad-item-op', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; $i[0].Op = 'Truncate'; Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('duplicate-destination', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; $i += , @{ Op = 'Write'; Destination = $i[1].Destination.ToUpperInvariant(); Source = $i[1].Source }; Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('delete-missing', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; $i += , @{ Op = 'Delete'; Destination = (Join-Path $c.Layout.Dest 'nothing.dll'); Source = '' }; Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('source-missing', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; $i[0].Source = (Join-Path $c.Layout.Src 'nope.src'); Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('unchanged-item', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; [System.IO.File]::Copy((Join-Path $c.Layout.Dest 'keep\u1.dll'), $i[1].Source, $true); Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('destination-is-directory', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; [System.IO.Directory]::CreateDirectory($i[0].Destination) | Out-Null; Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('destination-outside-root', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; $i[0].Destination = 'C:\Windows\Temp\dengo-i2a-never.dll'; Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('destination-dot-dot', { $c = New-Case 'F4'; try { $i = Get-I2AScenarioItems $c.Layout; $i[0].Destination = ($c.Layout.Dest + '\x\..\..\Guard\g1.txt'); Try-Begin $c.Layout $i } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid'),
        @('state-root-outside', { $c = New-Case 'F4'; try { $L2 = $c.Layout; DgTx-Begin -StateRoot 'C:\Windows\Temp\dengo-i2a-state' -BackupRoot $L2.Backup -Operation 'Install' -Items (Get-I2AScenarioItems $L2) -Policy $L2.Policy -NewStatePath $L2.StatePath } catch { DgError-Code $_.Exception } finally { Remove-I2ASandbox $c.Root } }, 'PlanInvalid')
    )
    foreach ($t in $tests) { $code = & $t[1]; [void](Assert-I2A ('U5-' + $t[0]) ($code -eq $t[2]) "Begin refuses: got '$code', expected '$($t[2])', and nothing was written before the refusal") }
    # nothing is written when Begin refuses
    $cs = New-Case 'F4'; $L = $cs.Layout; $beforeTree = Get-I2AFullTree $L
    $i = Get-I2AScenarioItems $L; $i[0].Destination = 'C:\Windows\Temp\dengo-i2a-never.dll'
    [void](Try-Begin $L $i)
    [void](Assert-I2A 'U5-refusal-writes-nothing' (Same $beforeTree (Get-I2AFullTree $L)) 'a refused plan leaves the whole fixture byte-identical')
    # junction in a destination path
    [System.IO.Directory]::CreateDirectory((Join-Path $L.Dest 'realdir')) | Out-Null
    $o = & cmd.exe /c ('mklink /J "' + (Join-Path $L.Dest 'jl') + '" "' + (Join-Path $L.Dest 'realdir') + '"')
    $i = Get-I2AScenarioItems $L; $i[0].Destination = (Join-Path $L.Dest 'jl\n1.dll')
    $jc = Try-Begin $L $i
    [void](Assert-I2A 'U5-reparse-destination' ($jc -eq 'PlanInvalid') "a destination below a junction is refused ($jc)")
    $polRec = DgPolicy-New @($L.Root) 'RecordOnly'
    $ctx = DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items $i -Policy $polRec -NewStatePath $L.StatePath
    $regLine = @([System.Text.Encoding]::UTF8.GetString([byte[]](DgFs-ReadAllBytesShared $ctx.JournalPath)) -split "`n" | Where-Object { $_ -like '*"stage":"Register"*' })[0] | ConvertFrom-Json
    [void](Assert-I2A 'U5-reparse-recorded' ((Cnt $regLine.reparsePoints) -ge 1) 'in RecordOnly mode the reparse point is recorded in the Register record')
    [void](DgTx-Rollback $ctx 'unit')
    [System.IO.Directory]::Delete((Join-Path $L.Dest 'jl'))
    Remove-I2ASandbox $cs.Root

    # ------------------------------------------------ U6 plan staleness at apply time
    $cs = New-Case 'F4'; $L = $cs.Layout; $pre = Get-I2AManagedTree $L
    $ctx = DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items (Get-I2AScenarioItems $L) -Policy $L.Policy -NewStatePath $L.StatePath
    [System.IO.File]::WriteAllText((Join-Path $L.Dest 'keep\u1.dll'), 'changed after planning', $script:Utf8)
    $code = Get-CodeOf { DgTx-Apply $ctx }
    DgJournal-Close $ctx.Journal; $ctx.Journal = $null   # the writer handle would block hashing the journal
    $beforeRb = Get-I2AFullTree $L
    $rb = DgTx-Rollback $ctx 'unit'
    $afterRb = Get-I2AFullTree $L
    $reportKey = @($afterRb.Keys | Where-Object { $_ -like '*recovery-report.txt' })
    foreach ($k in $reportKey) { $afterRb.Remove($k) }
    $codes = @($rb.Reasons | ForEach-Object { $_.Code })
    # E1: an unknown SHA (here: the user's edit of an item we had not touched yet) makes the WHOLE rollback a no-op -> RepairRequired
    [void](Assert-I2A 'U6-plan-stale' (($code -eq 'PlanStale') -and ($rb.Outcome -eq 'RepairRequired') -and ($codes -contains 'DestinationUnknownSha') -and (Same $beforeRb $afterRb)) "a destination edited after planning stops the apply ($code); the rollback refuses to guess: $($rb.Outcome) [$($codes -join ',')], nothing changed (the user's edit and the already-applied item are untouched)")
    [System.IO.File]::WriteAllText((Join-Path $L.Dest 'keep\u1.dll'), (Get-I2AContent 'F4' 'u1' 'old'), $script:Utf8)
    $rec = DgTx-Recover -StateRoot $L.State -BackupRoot $L.Backup -Policy $L.Policy
    [void](Assert-I2A 'U6-plan-stale-manual-fix' (($rec.Outcome -eq 'RolledBack') -and (Same $pre (Get-I2AManagedTree $L))) 'after the user puts the file back, the next recovery completes the rollback and the tree equals the original')
    Remove-I2ASandbox $cs.Root
    $cs = New-Case 'F4'; $L = $cs.Layout; $pre = Get-I2AManagedTree $L
    $ctx = DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items (Get-I2AScenarioItems $L) -Policy $L.Policy -NewStatePath $L.StatePath
    [System.IO.File]::WriteAllText((Join-Path $L.Src 'u1.src'), 'source changed after planning', $script:Utf8)
    $code = Get-CodeOf { DgTx-Apply $ctx }
    $rb = DgTx-Rollback $ctx 'unit'
    $post2 = Get-I2AManagedTree $L; $post2['f:src\u1.src'] = $pre['f:src\u1.src']
    [void](Assert-I2A 'U6-source-changed' (($code -eq 'TmpVerifyFailed') -and ($rb.Outcome -eq 'RolledBack') -and (Same $pre $post2)) "a source modified after planning is caught by the temp-copy SHA check ($code) and rolled back")
    Remove-I2ASandbox $cs.Root

    # ------------------------------------------------ U7 journal contents of a real run
    $cs = New-Case 'F2'; $L = $cs.Layout
    $res = Invoke-I2ARun $L
    $hj = @([System.IO.Directory]::GetFiles((Join-Path $L.State 'history'), '*.committed.jsonl'))
    $pj = DgJournal-Parse $hj[0]
    $recs = @($pj.Records)
    $byStage = @{}; foreach ($r in $recs) { $byStage[[string]$r.stage] = $r }
    $chainOk = $true; for ($i = 1; $i -lt $recs.Count; $i++) { if ($recs[$i].previousHash -ne $recs[$i - 1].recordHash) { $chainOk = $false } }
    $itemRecs = @($recs | Where-Object { @('Register', 'Intent', 'Applied', 'Verified') -contains [string]$_.stage })
    $pathOk = (Cnt @($itemRecs | Where-Object { ($null -eq $_.PSObject.Properties['path']) -or ($null -eq $_.PSObject.Properties['normalizedPath']) })) -eq 0
    $regs = @($recs | Where-Object { $_.stage -eq 'Register' }); $ints = @($recs | Where-Object { $_.stage -eq 'Intent' })
    $regFields = @('op', 'preExists', 'preSha', 'expectedPostSha', 'backupPath', 'tmpPath', 'dirsToCreate', 'reparsePoints', 'ownershipCandidate')
    $regOk = (Cnt @($regs | Where-Object { $r = $_; (Cnt @($regFields | Where-Object { $null -eq $r.PSObject.Properties[$_] })) -ne 0 })) -eq 0
    $intOk = (Cnt @($ints | Where-Object { $r = $_; ($null -eq $r.PSObject.Properties['backupSha']) -or ($null -eq $r.PSObject.Properties['backupPath']) -or ($null -eq $r.PSObject.Properties['expectedPostSha']) })) -eq 0
    $stagesSeen = @($recs | ForEach-Object { [string]$_.stage } | Select-Object -Unique)
    [void](Assert-I2A 'U7-schema' ($res.Succeeded -and $chainOk -and $pathOk -and $regOk -and $intOk -and ($recs[0].stage -eq 'Begin') -and ($recs[$recs.Count - 1].stage -eq 'Committed') -and ($pj.ValidLength -eq [System.IO.File]::ReadAllBytes($hj[0]).Length)) ("real run: $($recs.Count) records, stages " + ($stagesSeen -join '/') + '; chain intact; every item record has path + normalizedPath; Register has pre/post SHA, backup, tmp, ownershipCandidate; Intent has backupSha'))
    $ownershipOk = (Cnt @($regs | Where-Object { $_.ownershipCandidate -ne 'CreatedByInstaller' })) -eq 0
    [void](Assert-I2A 'U7-ownership-candidate' $ownershipOk 'the ownership candidate supplied by the caller is journaled verbatim (the core does not interpret it)')
    [void](Assert-I2A 'U7-history-separation' ((-not [System.IO.Directory]::Exists((Join-Path $L.State 'txn'))) -or ((Cnt ([System.IO.Directory]::GetFileSystemEntries((Join-Path $L.State 'txn')))) -eq 0)) 'after a committed run the active txn area is empty; the journal lives in history\')
    Remove-I2ASandbox $cs.Root

    # ------------------------------------------------ U8 classification
    $cs = New-Case 'F4'; $L = $cs.Layout
    $c1 = DgTx-Classify $L.State $false
    [System.IO.File]::Delete($L.StatePath); $c0 = DgTx-Classify $L.State $false
    [System.IO.File]::WriteAllText((Join-Path $L.State 'installing.json'), '{}', $script:Utf8); $c2 = DgTx-Classify $L.State $false; $c3 = DgTx-Classify $L.State $true
    [void](Assert-I2A 'U8-classify' (($c0.State -eq 'Pristine') -and ($c1.State -eq 'Installed') -and ($c2.State -eq 'Interrupted') -and ($c3.State -eq 'Busy')) "Pristine/Installed/Interrupted (marker, lock free)/Busy (lock held): $($c0.State)/$($c1.State)/$($c2.State)/$($c3.State)")
    [System.IO.File]::Delete((Join-Path $L.State 'installing.json'))
    [System.IO.File]::WriteAllText((Join-Path $L.State 'installing.json.tmp'), 'x', $script:Utf8)
    $rec = DgTx-Recover -StateRoot $L.State -BackupRoot $L.Backup -Policy $L.Policy
    [void](Assert-I2A 'U8-recover-no-marker' (($rec.Outcome -eq 'NotNeeded') -and (-not [System.IO.File]::Exists((Join-Path $L.State 'installing.json.tmp')))) 'without a marker recovery is NotNeeded and removes only our orphan marker temp file')
    Remove-I2ASandbox $cs.Root

    # ------------------------------------------------ U9 primitives and known limitations
    $pd = Join-Path $root 'prim'; [System.IO.Directory]::CreateDirectory($pd) | Out-Null
    $a = Join-Path $pd 'a.bin'; $t = Join-Path $pd 'a.bin.dengo.tmp'
    [System.IO.File]::WriteAllText($a, 'OLD', $script:Utf8); [System.IO.File]::WriteAllText($t, 'NEW', $script:Utf8)
    DgFs-Replace $t $a
    [void](Assert-I2A 'U9-replace' (([System.IO.File]::ReadAllText($a) -eq 'NEW') -and (-not [System.IO.File]::Exists($t))) 'DgFs-Replace swaps in the temp file (NullString backup argument) and consumes it')
    [System.IO.File]::WriteAllText($t, 'NEW2', $script:Utf8)
    $missingCode = Get-CodeOf { DgFs-Replace $t (Join-Path $pd 'missing.bin') }
    [void](Assert-I2A 'U9-replace-missing-dest' ($missingCode -like 'Other:FileNotFoundException') "Replace onto a missing destination fails fast ($missingCode); new files use MoveNew")
    $mv = Get-CodeOf { DgFs-MoveNew $t $a }
    [void](Assert-I2A 'U9-movenew-existing' ($mv -like 'Other:IOException') "MoveNew never overwrites ($mv)")
    $cp = Get-CodeOf { DgFs-CopyFileDurable $a $t }
    [void](Assert-I2A 'U9-copy-createnew' ($cp -like 'Other:IOException') "CopyFileDurable never overwrites (CreateNew) ($cp)")
    $h = New-Object System.IO.FileStream($a, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { $pc = Get-CodeOf { DgFs-ProbeExclusive $a } } finally { $h.Dispose() }
    [void](Assert-I2A 'U9-probe-detects-holder' ($pc -eq 'InUse') "the exclusive probe detects another open handle ($pc)")
    [System.IO.File]::SetAttributes($a, [System.IO.FileAttributes]::ReadOnly)
    $ro = Get-CodeOf { DgFs-ProbeExclusive $a }
    [System.IO.File]::SetAttributes($a, [System.IO.FileAttributes]::Normal)
    [void](Assert-I2A 'U9-probe-readonly' ($ro -eq 'AccessDenied') "a read-only destination is reported as AccessDenied ($ro)")
    [void](Assert-I2A 'U9-probe-missing' ((Get-CodeOf { DgFs-ProbeExclusive (Join-Path $pd 'none.bin') }) -eq 'NoError') 'probing a missing file is a no-op')
    # known limitation: Replace itself does not detect in-use files; only the probe does, and there is a window between them
    [System.IO.File]::WriteAllText($t, 'NEW3', $script:Utf8)
    $probeFirst = Get-CodeOf { DgFs-ProbeExclusive $a }
    $late = New-Object System.IO.FileStream($a, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { $replaced = Get-CodeOf { DgFs-Replace $t $a } } finally { $late.Dispose() }
    [void](Assert-I2A 'KL-probe-replace-window' (($probeFirst -eq 'NoError') -and ($replaced -eq 'NoError')) 'KNOWN LIMITATION (documented, not fixed): a handle opened with FileShare.Delete after the probe and before Replace does not stop Replace; the in-use window cannot be closed in user mode')
    $ping = Join-Path $pd 'running.exe'; $pingTmp = $ping + '.dengo.tmp'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $ping; Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $pingTmp
    $proc = Start-Process -FilePath $ping -ArgumentList '-n', '20', '127.0.0.1' -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 600
        $probeRun = Get-CodeOf { DgFs-ProbeExclusive $ping }
        $replaceRun = Get-CodeOf { DgFs-Replace $pingTmp $ping }
    } finally { try { $proc.Kill() } catch { }; [void]$proc.WaitForExit(5000) }
    [void](Assert-I2A 'KL-replace-on-running-exe' (($probeRun -eq 'InUse') -and ($replaceRun -eq 'NoError')) "KNOWN LIMITATION: File.Replace succeeds on a running executable (probe says $probeRun, Replace says $replaceRun) - the exclusive probe is what protects us, so it is mandatory before every Replace/Delete")
    # static: every Replace/Delete of a destination in the core is preceded by the probe
    $ast = Get-I2AScriptAst (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $apply = @($fn | Where-Object { $_.Name -eq 'DgTx-ApplyItem' })[0].Extent.Text
    $restore = @($fn | Where-Object { $_.Name -eq 'DgTx-RestoreItem' })[0].Extent.Text
    $probeOk = ($apply.IndexOf('DgFs-ProbeExclusive') -ge 0) -and ($apply.IndexOf('DgFs-ProbeExclusive') -lt $apply.IndexOf('DgG-Replace')) -and ($restore.IndexOf('DgFs-ProbeExclusive') -ge 0)
    [void](Assert-I2A 'U9-probe-before-replace' $probeOk 'ApplyItem and RestoreItem probe the destination before Replace/Delete')

    # ------------------------------------------------ U10 ReparseMode is fail-closed (M1)
    # CONTRACT recorded here and in the core: the product default is 'Reject'; 'RecordOnly' only on explicit request.
    $mr = Join-Path $root 'm1'; [System.IO.Directory]::CreateDirectory((Join-Path $mr 'real\sub')) | Out-Null
    $o = & cmd.exe /c ('mklink /J "' + (Join-Path $mr 'lnk') + '" "' + (Join-Path $mr 'real') + '"')
    $dflt = DgPolicy-New @($mr)
    [void](Assert-I2A 'U10-default-is-reject' ($dflt.ReparseMode -ceq 'Reject') "DgPolicy-New without a mode yields '$($dflt.ReparseMode)' (product default = Reject)")
    $goodModes = @(@('Reject', 'Reject'), @('reject', 'Reject'), @('REJECT', 'Reject'), @('RecordOnly', 'RecordOnly'), @('recordonly', 'RecordOnly'), @('RECORDONLY', 'RecordOnly'))
    $badGood = @(); foreach ($g in $goodModes) { $pp = DgPolicy-New @($mr) $g[0]; if (-not ($pp.ReparseMode -ceq $g[1])) { $badGood += $g[0] } }
    [void](Assert-I2A 'U10-valid-modes-normalized' ($badGood.Count -eq 0) 'Reject/reject/REJECT -> Reject; RecordOnly/recordonly/RECORDONLY -> RecordOnly')
    $badModes = @($null, '', ' ', 'Rejekt', ' Reject', 'Reject ', 'Reject RecordOnly', 'RecordOnly;', 'true', '0', 'None', 'Allow', 'Ignore')
    $accepted = @(); foreach ($bm in $badModes) { $code = Get-CodeOf { DgPolicy-New @($mr) $bm }; if ($code -ne 'PolicyInvalid') { $accepted += ('[' + [string]$bm + ']=' + $code) } }
    [void](Assert-I2A 'U10-invalid-modes-throw' ($accepted.Count -eq 0) ("null, empty, blank, typo, padded and unknown modes all throw PolicyInvalid ($($badModes.Count) values)" + $(if ($accepted.Count -gt 0) { ': accepted ' + ($accepted -join ',') } else { '' })))
    $reject = DgPolicy-New @($mr) 'reject'; $recOnly = DgPolicy-New @($mr) 'recordonly'
    $viaJ = Join-Path $mr 'lnk\x.dll'; $midJ = Join-Path $mr 'lnk\sub\deep.dll'; $plain = Join-Path $mr 'real\sub\ok.dll'
    $tj = DgPolicy-TestPath $reject $viaJ; $tm = DgPolicy-TestPath $reject $midJ; $tp = DgPolicy-TestPath $reject $plain; $tr = DgPolicy-TestPath $recOnly $midJ
    [void](Assert-I2A 'U10-reject-junction' ((-not $tj.Allowed) -and ($tj.Reason -eq 'PathReparse') -and (-not $tm.Allowed) -and ($tm.Reason -eq 'PathReparse') -and $tp.Allowed) 'Reject: a path below a junction is refused, also when the junction is a middle component; a normal path is allowed')
    [void](Assert-I2A 'U10-record-only-explicit' ($tr.Allowed -and ((Cnt $tr.Reparse) -ge 1)) 'RecordOnly (explicit): the junction path is accepted and the reparse point is recorded')
    $forged = [pscustomobject]@{ AllowedRoots = [string[]]@($mr); ReparseMode = 'Rejekt' }
    $tf = DgPolicy-TestPath $forged $midJ
    [void](Assert-I2A 'U10-policy-object-with-unknown-mode' ((-not $tf.Allowed) -and ($tf.Reason -eq 'PathReparse')) 'a policy object that did not come from DgPolicy-New and carries an unknown mode still rejects reparse points (fail-closed)')
    $cs = New-Case 'F4'; $L = $cs.Layout
    [System.IO.Directory]::CreateDirectory((Join-Path $L.Dest 'realdir')) | Out-Null
    $o = & cmd.exe /c ('mklink /J "' + (Join-Path $L.Dest 'jl') + '" "' + (Join-Path $L.Dest 'realdir') + '"')
    $forged2 = [pscustomobject]@{ AllowedRoots = [string[]]@($L.Root); ReparseMode = 'Rejekt' }
    $it = Get-I2AScenarioItems $L; $it[0].Destination = (Join-Path $L.Dest 'jl\n1.dll')
    $before = Get-I2AFullTree $L
    $bc = Try-Begin $L $it 'Install' $forged2
    [void](Assert-I2A 'U10-unknown-mode-changes-nothing' (($bc -eq 'PlanInvalid') -and (Same $before (Get-I2AFullTree $L))) "an unknown mode cannot turn the junction check off: Begin refuses ($bc) and the fixture is byte-identical")
    [System.IO.Directory]::Delete((Join-Path $L.Dest 'jl'))
    Remove-I2ASandbox $cs.Root
    [System.IO.Directory]::Delete((Join-Path $mr 'lnk'))

    # ------------------------------------------------ U11 Windows reserved device names / trailing dot or space (L1)
    $nr = Join-Path $root 'names'; [System.IO.Directory]::CreateDirectory($nr) | Out-Null
    $polN = DgPolicy-New @($nr)
    $ch = [string][char]0x00B9
    $nameCases = @(
        @('NUL', $false), @('nul', $false), @('NUL.txt', $false), @('con.log', $false), @('CON', $false), @('PRN', $false), @('aux', $false), @('AUX.tar.gz', $false),
        @('COM1', $false), @('COM9.txt', $false), @('com5.dll', $false), @('LPT1', $false), @('lpt9.dll', $false), @('CON .txt', $false), @('CONIN$', $false), @(('COM' + $ch), $false),
        @('a.', $false), @('a ', $false), @('dir.', $false),
        @('COM10', $true), @('COM0', $true), @('LPT10', $true), @('CONSOLE', $true), @('NULL', $true), @('PRNT.txt', $true), @('readme.txt', $true), @('a.b.c', $true), @('.hidden', $true))
    $badN = @()
    foreach ($nc in $nameCases) {
        $asFile = DgPolicy-TestPath $polN ($nr + '\' + $nc[0])
        $asDir = DgPolicy-TestPath $polN ($nr + '\' + $nc[0] + '\inner.dll')
        if (($asFile.Allowed -ne $nc[1]) -or ($asDir.Allowed -ne $nc[1])) { $badN += ('{0}: file={1}({2}) dir={3}({4})' -f $nc[0], $asFile.Allowed, $asFile.Reason, $asDir.Allowed, $asDir.Reason) }
    }
    [void](Assert-I2A 'U11-device-names' ($badN.Count -eq 0) ("$($nameCases.Count) names x (file position, directory position): NUL, NUL.txt, con.log, COM1, COM9.txt, LPT1, trailing '.' and trailing space are refused; COM10, COM0, LPT10, CONSOLE, NULL and normal names are allowed" + $(if ($badN.Count -gt 0) { ' - ' + ($badN -join '; ') } else { '' })))
    $drive = DgPath-Check 'C:\ok\x.dll'
    $driveCom = DgPath-Check 'C:\COM1'
    [void](Assert-I2A 'U11-drive-letter-not-confused' ($drive.Ok -and (-not $driveCom.Ok) -and ($driveCom.Reason -eq 'PathReservedName')) "the drive segment 'C:' is never treated as a device name; 'C:\COM1' is ($($driveCom.Reason))")
    $nb = New-Case 'F4'; $Ln = $nb.Layout; $itn = Get-I2AScenarioItems $Ln; $itn[0].Destination = (Join-Path $Ln.Dest 'NUL.txt')
    $beforeN = Get-I2AFullTree $Ln
    $bn = Try-Begin $Ln $itn
    [void](Assert-I2A 'U11-begin-refuses-device-name' (($bn -eq 'PlanInvalid') -and (Same $beforeN (Get-I2AFullTree $Ln))) "a plan that names NUL.txt is refused before anything is written ($bn)")
    Remove-I2ASandbox $nb.Root

    # ------------------------------------------------ U12 orphan marker temporaries are removed only after every condition holds (M3)
    function New-StateDir([string]$Base, [string]$Name) { $d = Join-Path $Base $Name; [System.IO.Directory]::CreateDirectory($d) | Out-Null; return $d }
    function Put([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
    $m3a = New-StateDir $root 'm3a'; $st = New-StateDir $m3a 'State'; $bk = New-StateDir $m3a 'Backup'
    Put (Join-Path $st 'installing.json.tmp') 'x'; Put (Join-Path $st 'uninstalling.json.tmp') 'y'; Put (Join-Path $st 'other.tmp') 'keep'; Put (Join-Path $st 'installing.json.tmp.bak') 'keep'; Put (Join-Path $st 'installed-state.json') 'S'
    $polA = DgPolicy-New @($m3a)
    $r = DgTx-Recover -StateRoot $st -BackupRoot $bk -Policy $polA
    [void](Assert-I2A 'U12-normal-cleanup' (($r.Outcome -eq 'NotNeeded') -and (-not [System.IO.File]::Exists((Join-Path $st 'installing.json.tmp'))) -and (-not [System.IO.File]::Exists((Join-Path $st 'uninstalling.json.tmp'))) -and [System.IO.File]::Exists((Join-Path $st 'other.tmp')) -and [System.IO.File]::Exists((Join-Path $st 'installing.json.tmp.bak')) -and [System.IO.File]::Exists((Join-Path $st 'installed-state.json'))) 'inside the allowed root: exactly the two fixed-name temporaries are removed; every other file stays')
    # B: state root outside the caller's allowed root
    $m3b = New-StateDir $root 'm3b'; $m3o = New-StateDir $root 'm3b-outside'; $stO = New-StateDir $m3o 'State'
    Put (Join-Path $stO 'installing.json.tmp') 'x'
    $rb = DgTx-Recover -StateRoot $stO -BackupRoot (Join-Path $m3o 'Backup') -Policy (DgPolicy-New @($m3b))
    [void](Assert-I2A 'U12-outside-root-refused' (($rb.Outcome -eq 'RepairRequired') -and (@($rb.Reasons | ForEach-Object { $_.Code }) -contains 'PathRejected') -and [System.IO.File]::Exists((Join-Path $stO 'installing.json.tmp'))) 'state root outside the allowed root: refused (PathRejected) and the temp file is untouched')
    $rb2 = DgTx-Recover -StateRoot (New-StateDir $m3b 'S2') -BackupRoot (Join-Path $m3o 'Backup') -Policy (DgPolicy-New @($m3b))
    [void](Assert-I2A 'U12-backup-root-outside-refused' (($rb2.Outcome -eq 'RepairRequired') -and (@($rb2.Reasons | ForEach-Object { $_.Code }) -contains 'PathRejected')) 'a backup root outside the allowed root is refused as well')
    # C: junction in the parents (Reject policy) and D: RecordOnly policy
    $m3c = New-StateDir $root 'm3c'; [void](New-StateDir $m3c 'real\State')
    $o = & cmd.exe /c ('mklink /J "' + (Join-Path $m3c 'lnk') + '" "' + (Join-Path $m3c 'real') + '"')
    Put (Join-Path $m3c 'real\State\installing.json.tmp') 'x'
    $rc = DgTx-Recover -StateRoot (Join-Path $m3c 'lnk\State') -BackupRoot (Join-Path $m3c 'Backup') -Policy (DgPolicy-New @($m3c) 'Reject')
    [void](Assert-I2A 'U12-junction-parent-refused' (($rc.Outcome -eq 'RepairRequired') -and [System.IO.File]::Exists((Join-Path $m3c 'real\State\installing.json.tmp'))) 'a junction in the state root path (Reject): refused, the temp file behind it is untouched')
    $rd = DgTx-Recover -StateRoot (Join-Path $m3c 'lnk\State') -BackupRoot (Join-Path $m3c 'Backup') -Policy (DgPolicy-New @($m3c) 'RecordOnly')
    [void](Assert-I2A 'U12-junction-record-only-still-no-delete' (($rd.Outcome -eq 'NotNeeded') -and (@($rd.CleanupRefused).Count -ge 1) -and [System.IO.File]::Exists((Join-Path $m3c 'real\State\installing.json.tmp'))) "even with RecordOnly the cleanup refuses to delete through a reparse point ($(@($rd.CleanupRefused) -join '; '))")
    [System.IO.Directory]::Delete((Join-Path $m3c 'lnk'))
    # E: a directory with the temp name, F: a junction with the temp name
    $m3e = New-StateDir $root 'm3e'; $stE = New-StateDir $m3e 'State'; [void](New-StateDir $stE 'installing.json.tmp'); Put (Join-Path $stE 'installing.json.tmp\sentinel.txt') 'keep'; Put (Join-Path $stE 'uninstalling.json.tmp') 'z'
    $re = DgTx-Recover -StateRoot $stE -BackupRoot (Join-Path $m3e 'Backup') -Policy (DgPolicy-New @($m3e))
    [void](Assert-I2A 'U12-directory-with-temp-name' (($re.Outcome -eq 'NotNeeded') -and [System.IO.File]::Exists((Join-Path $stE 'installing.json.tmp\sentinel.txt')) -and (-not [System.IO.File]::Exists((Join-Path $stE 'uninstalling.json.tmp'))) -and (@($re.CleanupRefused).Count -eq 1)) "a directory named installing.json.tmp is not touched ($(@($re.CleanupRefused) -join '; ')); the regular file next to it is removed")
    $m3f = New-StateDir $root 'm3f'; $stF = New-StateDir $m3f 'State'; $tgt = New-StateDir $m3f 'target'; Put (Join-Path $tgt 'sentinel.txt') 'keep'
    $o = & cmd.exe /c ('mklink /J "' + (Join-Path $stF 'installing.json.tmp') + '" "' + $tgt + '"')
    $rf = DgTx-Recover -StateRoot $stF -BackupRoot (Join-Path $m3f 'Backup') -Policy (DgPolicy-New @($m3f))
    [void](Assert-I2A 'U12-junction-with-temp-name' (($rf.Outcome -eq 'NotNeeded') -and [System.IO.File]::Exists((Join-Path $tgt 'sentinel.txt')) -and (@($rf.CleanupRefused).Count -eq 1)) 'a junction named installing.json.tmp is refused and its target is untouched')
    [System.IO.Directory]::Delete((Join-Path $stF 'installing.json.tmp'))
    $rg = DgTx-Recover -StateRoot (Join-Path $m3a 'nope\..\State') -BackupRoot $bk -Policy $polA
    [void](Assert-I2A 'U12-dot-dot-state-root' (($rg.Outcome -eq 'RepairRequired') -and (@($rg.Reasons | ForEach-Object { $_.Code }) -contains 'PathRejected')) 'a state root containing .. is refused before anything is read or deleted')

    # ------------------------------------------------ U13 the guard (DgG-Assert) called directly
    function Guard-Code($Ctx, [string]$Path, [string]$Kind) { try { DgG-Assert $Ctx $Path $Kind; return 'OK' } catch { return (DgError-Code $_.Exception) } }
    $cs = New-Case 'F4'; $L = $cs.Layout
    $out = New-I2ASandbox 'guard-outside'
    $ctx = DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items (Get-I2AScenarioItems $L) -Policy $L.Policy -NewStatePath $L.StatePath
    $d0 = $ctx.Items[0].Norm; $t0 = $ctx.Items[0].Tmp; $b1 = $ctx.Items[1].Backup; $dir0 = $ctx.Items[0].Dirs[0]
    $guardCases = @(
        @('registered destination', $d0, 'Dest', 'OK'), @('registered tmp', $t0, 'Tmp', 'OK'), @('registered backup', $b1, 'Backup', 'OK'), @('registered directory', $dir0, 'Dir', 'OK'),
        @('state file', $L.StatePath, 'Infra', 'OK'), @('marker', $ctx.MarkerPath, 'Infra', 'OK'),
        @('unregistered file inside the root', (Join-Path $L.Guard 'g1.txt'), 'Dest', 'PathNotRegistered'),
        @('unregistered new file inside the root', (Join-Path $L.Dest 'never-registered.dll'), 'Dest', 'PathNotRegistered'),
        @('destination asked as tmp', $d0, 'Tmp', 'PathNotRegistered'), @('tmp asked as destination', $t0, 'Dest', 'PathNotRegistered'),
        @('backup asked as tmp', $b1, 'Tmp', 'PathNotRegistered'), @('destination asked as backup', $d0, 'Backup', 'PathNotRegistered'),
        @('unknown kind', $d0, 'Bogus', 'PathNotRegistered'),
        @('outside the allowed root', (Join-Path $out 'x.dll'), 'Dest', 'PathRejected'),
        @('system path', 'C:\Windows\System32\x.dll', 'Dest', 'PathRejected'),
        @('..-escape that normalizes outside the registered set', ($L.Dest + '\keep\..\..\Guard\g1.txt'), 'Dest', 'PathRejected'),
        @('..-detour that returns to a registered file', ($L.Dest + '\fresh\..\fresh\n1.dll'), 'Dest', 'PathRejected'),
        @('reserved device name', (Join-Path $L.Dest 'NUL.txt'), 'Dest', 'PathRejected'), @('trailing dot', ($d0 + '.'), 'Dest', 'PathRejected'),
        @('relative path', 'fresh\n1.dll', 'Dest', 'PathRejected'), @('UNC path', '\\server\share\x.dll', 'Dest', 'PathRejected'), @('alternate data stream', ($d0 + ':evil'), 'Dest', 'PathRejected'))
    $badG = @(); foreach ($gc in $guardCases) { $code = Guard-Code $ctx $gc[1] $gc[2]; if ($code -ne $gc[3]) { $badG += ('{0}: got {1} expected {2}' -f $gc[0], $code, $gc[3]) } }
    [void](Assert-I2A 'U13-guard-table' ($badG.Count -eq 0) ("$($guardCases.Count) direct DgG-Assert calls: registered paths pass only as their own kind; unregistered, outside-root, normalized-outside, device-name and malformed paths are refused" + $(if ($badG.Count -gt 0) { ' - ' + ($badG -join '; ') } else { '' })))
    $guardBefore = Get-I2ATreeMap $L.Guard @()
    $viaMutator = @(
        (Get-CodeOf { DgG-Delete $ctx (Join-Path $L.Guard 'g1.txt') 'Dest' }), (Get-CodeOf { DgG-CopyFile $ctx $d0 (Join-Path $L.Guard 'copy.bin') 'Dest' }),
        (Get-CodeOf { DgG-Replace $ctx $t0 (Join-Path $L.Guard 'g1.txt') 'Dest' }), (Get-CodeOf { DgG-MoveNew $ctx $t0 (Join-Path $out 'm.dll') 'Dest' 'Tmp' }),
        (Get-CodeOf { [void](DgG-CreateDir $ctx (Join-Path $out 'newdir') 'Dir') }), (Get-CodeOf { [void](DgG-RemoveDirIfEmpty $ctx $L.Guard 'Dir') }),
        (Get-CodeOf { DgG-CreateFile $ctx (Join-Path $out 'f.bin') ([byte[]]@(1)) 'Infra' }), (Get-CodeOf { DgG-WriteText $ctx (Join-Path $out 'f.txt') 'x' }))
    [void](Assert-I2A 'U13-every-mutator-guarded' ((@($viaMutator | Where-Object { @('PathNotRegistered', 'PathRejected') -notcontains $_ }).Count -eq 0) -and (Same $guardBefore (Get-I2ATreeMap $L.Guard @())) -and (-not [System.IO.Directory]::Exists((Join-Path $out 'newdir')))) "all 8 DgG-* mutators refuse unregistered/outside paths ($($viaMutator -join ',')); nothing was created or changed")
    # reparse point: a registered path whose parent turned into a junction after Begin is refused at mutation time
    [void](DgTx-Rollback $ctx 'unit')
    [System.IO.Directory]::CreateDirectory((Join-Path $L.Dest 'realdir')) | Out-Null
    $o = & cmd.exe /c ('mklink /J "' + (Join-Path $L.Dest 'jl') + '" "' + (Join-Path $L.Dest 'realdir') + '"')
    $it = Get-I2AScenarioItems $L; $it[0].Destination = (Join-Path $L.Dest 'jl\n1.dll')
    $ctxJ = DgTx-Begin -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items $it -Policy (DgPolicy-New @($L.Root) 'RecordOnly') -NewStatePath $L.StatePath
    $okUnderRecord = Guard-Code $ctxJ $ctxJ.Items[0].Norm 'Dest'
    $ctxJ.Policy = DgPolicy-New @($L.Root) 'Reject'
    $rejUnderReject = Guard-Code $ctxJ $ctxJ.Items[0].Norm 'Dest'
    [void](Assert-I2A 'U13-guard-reparse-point' (($okUnderRecord -eq 'OK') -and ($rejUnderReject -eq 'PathRejected')) "the same registered path: $okUnderRecord with RecordOnly, $rejUnderReject once the policy is Reject (the guard re-checks reparse points at mutation time)")
    DgJournal-Close $ctxJ.Journal; $ctxJ.Journal = $null
    [System.IO.Directory]::Delete((Join-Path $L.Dest 'jl'))
    Remove-I2ASandbox $cs.Root; Remove-I2ASandbox $out
} finally { Remove-I2ASandbox $root }
Complete-I2ATests
