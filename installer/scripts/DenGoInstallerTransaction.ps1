# DenGo installer transaction core (I2-A). ASCII only. Functions only; no top-level side effects.
# Not connected to any product engine. Dot-source this file; tests may redefine the primitive layer
# (DgFs-*, DgJournal-*, DgClock-*, DgId-*) to inject faults. No test switches exist in this file.
#
# Contract summary
#   - Every destination is registered in the journal (Register records) before anything is changed.
#   - Per item: backup -> Intent (fsync) -> temp copy -> exclusive probe -> Replace/Move -> SHA check -> Applied -> Verified.
#   - Commit point: atomic replace of the state file (CommitIntent before, Committed after).
#   - Recovery is two-phase: Phase 1 is read-only verification of everything; Phase 2 (reverse restore) only if Phase 1 passed.
#   - Any destination SHA that is neither the journaled pre-SHA nor the journaled post-SHA => RepairRequired, zero changes.
#   - Mutex abandonment is never evidence of an interrupted run; the marker + journal are.

function DgConst-ZeroHash { return ('0' * 64) }
function DgConst-TmpSuffix { return '.dengo.tmp' }
function DgConst-Stages { return @('Begin','Register','Intent','Applied','Verified','CommitIntent','Committed','RollbackBegin','RollbackIntent','RolledBack','RollbackIncomplete','RollbackComplete') }
function DgConst-MarkerName { param([string]$Operation) if ([string]::Equals($Operation,'Uninstall',[System.StringComparison]::Ordinal)) { return 'uninstalling.json' } else { return 'installing.json' } }

# ---------------------------------------------------------------- errors
function DgError {
    param([string]$Code,[string]$Message,[object]$Inner = $null)
    if ($null -ne $Inner) { $e = New-Object System.InvalidOperationException(($Code + ': ' + $Message),[System.Exception]$Inner) }
    else { $e = New-Object System.InvalidOperationException(($Code + ': ' + $Message)) }
    $e.Data['DgCode'] = $Code
    return $e
}
function DgError-Root {
    param([System.Exception]$Exception)
    $e = $Exception
    while ($null -ne $e.InnerException -and ($e -is [System.Management.Automation.MethodInvocationException] -or $e -is [System.Reflection.TargetInvocationException])) { $e = $e.InnerException }
    return $e
}
function DgError-Code {
    param([System.Exception]$Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e.Data.Contains('DgCode')) { return [string]$e.Data['DgCode'] }
        $e = $e.InnerException
    }
    return ''
}
function DgEq { param([string]$A,[string]$B) return [string]::Equals($A,$B,[System.StringComparison]::Ordinal) }
function DgEqI { param([string]$A,[string]$B) return [string]::Equals($A,$B,[System.StringComparison]::OrdinalIgnoreCase) }
function DgProp {
    param([object]$Object,[string]$Name,[object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default } }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

# ---------------------------------------------------------------- primitive layer (the only code that touches disk/clock/ids)
function DgFs-Exists { param([string]$Path) return [System.IO.File]::Exists($Path) }
function DgFs-DirExists { param([string]$Path) return [System.IO.Directory]::Exists($Path) }
function DgFs-Sha256 {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-','')
}
function DgFs-ReadAllBytesShared {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $buffer = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $n = $stream.Read($buffer,$offset,$buffer.Length - $offset)
            if ($n -le 0) { break }
            $offset += $n
        }
        if ($offset -ne $buffer.Length) { $trim = New-Object byte[] $offset; [System.Array]::Copy($buffer,$trim,$offset); $buffer = $trim }
    } finally { $stream.Dispose() }
    return ,$buffer
}
function DgFs-ProbeExclusive {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    } catch {
        $inner = DgError-Root $_.Exception
        $code = 'InUse'
        if ($inner -is [System.UnauthorizedAccessException]) { $code = 'AccessDenied' }
        throw (DgError $code ('Exclusive open failed: ' + $Path + ' (' + $inner.Message + ')') $inner)
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}
function DgFs-GetReparseComponents {
    param([string]$Path,[string]$Root)
    $found = New-Object System.Collections.ArrayList
    $rootFull = $Root.TrimEnd([char[]]@([char]92,[char]47))
    $current = $Path
    $guard = 0
    while ($current.Length -gt $rootFull.Length -and $guard -lt 64) {
        $guard++
        $exists = [System.IO.File]::Exists($current) -or [System.IO.Directory]::Exists($current)
        if ($exists) {
            $attr = [System.IO.File]::GetAttributes($current)
            if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$found.Add($current) }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent)) { break }
        $current = $parent
    }
    return ,([string[]]@($found))
}
function DgFs-CreateFileDurable {
    param([string]$Path,[byte[]]$Bytes)
    $stream = New-Object System.IO.FileStream($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function DgFs-WriteTextFile {
    param([string]$Path,[string]$Text)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $stream = New-Object System.IO.FileStream($Path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function DgFs-CopyFileDurable {
    param([string]$Source,[string]$Destination)
    $in = [System.IO.File]::Open($Source,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $out = New-Object System.IO.FileStream($Destination,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}
function DgFs-Replace {
    param([string]$Temporary,[string]$Destination)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            [System.IO.File]::Replace($Temporary,$Destination,[System.Management.Automation.Language.NullString]::Value)
            return
        } catch {
            $inner = DgError-Root $_.Exception
            $retry = ($inner -is [System.IO.IOException]) -and -not ($inner -is [System.IO.FileNotFoundException]) -and -not ($inner -is [System.IO.DirectoryNotFoundException]) -and ($attempt -lt 3)
            if (-not $retry) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}
function DgFs-MoveNew { param([string]$Source,[string]$Destination) [System.IO.File]::Move($Source,$Destination) }
function DgFs-Delete { param([string]$Path) [System.IO.File]::Delete($Path) }
function DgFs-CreateDir {
    param([string]$Path)
    $missing = New-Object System.Collections.ArrayList
    $current = $Path
    while (-not [string]::IsNullOrEmpty($current) -and -not [System.IO.Directory]::Exists($current)) {
        [void]$missing.Add($current)
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    $missing.Reverse()
    return ,([string[]]@($missing))
}
function DgFs-RemoveDirIfEmpty {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return $false }
    if (@([System.IO.Directory]::GetFileSystemEntries($Path)).Count -ne 0) { return $false }
    [System.IO.Directory]::Delete($Path,$false)
    return $true
}
function DgJournal-Open {
    param([string]$Path)
    return (New-Object System.IO.FileStream($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read))
}
function DgJournal-OpenTruncate {
    param([string]$Path,[long]$ValidLength,[long]$ExpectedLength)
    # The write handle (FileShare.Read) is taken first, so no other writer can change the file afterwards; the length seen by
    # Phase 1 must still be exactly the current length, otherwise nothing is truncated and nothing is written.
    $stream = New-Object System.IO.FileStream($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $ExpectedLength) { throw (DgError 'JournalChangedAfterRead' ('The journal length changed after it was read (read ' + $ExpectedLength + ' bytes, now ' + $stream.Length + ').')) }
        if ($ValidLength -ne $ExpectedLength) { $stream.SetLength($ValidLength) }
        [void]$stream.Seek(0,[System.IO.SeekOrigin]::End)
        $stream.Flush($true)
    } catch { $stream.Dispose(); throw }
    return $stream
}
function DgJournal-Append {
    param([System.IO.FileStream]$Stream,[byte[]]$Bytes)
    $Stream.Write($Bytes,0,$Bytes.Length)
    $Stream.Flush($true)
}
function DgJournal-Close { param([System.IO.FileStream]$Stream) if ($null -ne $Stream) { $Stream.Dispose() } }
function DgClock-Now { return [System.DateTimeOffset]::Now.ToString('o') }
function DgId-New {
    param([string]$Kind)
    return ([System.DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
}

# ---------------------------------------------------------------- hashing helpers (pure)
function DgSha256-Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-','')
}
function DgSha256-Bytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-','')
}

# ---------------------------------------------------------------- path policy
# Policy object: AllowedRoots (normalized, no trailing separator), ReparseMode ('Reject' | 'RecordOnly').
# CONTRACT: the product default is 'Reject'. 'RecordOnly' is allowed only when a caller asks for it explicitly.
# The mode is validated here (case-insensitive, no trimming); anything else - null, empty, a typo, padded text - throws.
# DgPolicy-TestPath additionally treats every value other than exactly 'RecordOnly' as 'Reject' (fail-closed).
function DgPolicy-New {
    param([string[]]$AllowedRoots,[object]$ReparseMode = 'Reject')
    if ($null -eq $ReparseMode) { throw (DgError 'PolicyInvalid' 'ReparseMode must be Reject or RecordOnly (got null).') }
    $modeText = [string]$ReparseMode
    $canonical = ''
    if ([string]::Equals($modeText,'Reject',[System.StringComparison]::OrdinalIgnoreCase)) { $canonical = 'Reject' }
    elseif ([string]::Equals($modeText,'RecordOnly',[System.StringComparison]::OrdinalIgnoreCase)) { $canonical = 'RecordOnly' }
    else { throw (DgError 'PolicyInvalid' ("ReparseMode must be Reject or RecordOnly (got '" + $modeText + "').")) }
    $roots = New-Object System.Collections.ArrayList
    foreach ($r in @($AllowedRoots)) {
        $c = DgPath-Check $r
        if (-not $c.Ok) { throw (DgError 'PolicyInvalid' ('Allowed root rejected: ' + $r + ' (' + $c.Reason + ')')) }
        [void]$roots.Add($c.Normalized.TrimEnd([char[]]@([char]92,[char]47)))
    }
    return [pscustomobject]@{ AllowedRoots = [string[]]@($roots); ReparseMode = $canonical }
}
# Windows reserved device names: the part of a segment before its first dot (trailing spaces ignored) is compared.
function DgPath-IsReservedName {
    param([string]$Segment)
    $base = $Segment
    $dot = $Segment.IndexOf('.')
    if ($dot -ge 0) { $base = $Segment.Substring(0,$dot) }
    $base = $base.TrimEnd(' ').ToUpperInvariant()
    if (@('CON','PRN','AUX','NUL','CONIN$','CONOUT$','CLOCK$') -contains $base) { return $true }
    $digits = '1-9' + [string][char]0x00B9 + [string][char]0x00B2 + [string][char]0x00B3
    return ($base -match ('^(COM|LPT)[' + $digits + ']$'))
}
function DgPath-Check {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return [pscustomobject]@{ Ok = $false; Reason = 'PathEmpty'; Normalized = '' } }
    if ($Path.StartsWith('\\',[System.StringComparison]::Ordinal) -or $Path.StartsWith('//',[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'PathUnc'; Normalized = '' } }
    if ($Path.Length -lt 3 -or -not [char]::IsLetter($Path[0]) -or $Path[1] -ne ':' -or ($Path[2] -ne [char]92 -and $Path[2] -ne [char]47)) { return [pscustomobject]@{ Ok = $false; Reason = 'PathNotAbsolute'; Normalized = '' } }
    if ($Path.IndexOf(':',2) -ge 0) { return [pscustomobject]@{ Ok = $false; Reason = 'PathStream'; Normalized = '' } }
    if ($Path.IndexOf([char]42) -ge 0 -or $Path.IndexOf([char]63) -ge 0) { return [pscustomobject]@{ Ok = $false; Reason = 'PathWildcard'; Normalized = '' } }
    foreach ($segment in @($Path.Split([char[]]@([char]92,[char]47)))) {
        if ([string]::Equals($segment,'..',[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'PathDotDot'; Normalized = '' } }
    }
    $segs = $Path.Split([char[]]@([char]92,[char]47))
    for ($i = 1; $i -lt $segs.Length; $i++) {   # segment 0 is the drive ("C:") and is never confused with a device name
        $seg = $segs[$i]
        if ($seg.Length -eq 0) { continue }
        if ($seg.EndsWith('.',[System.StringComparison]::Ordinal) -or $seg.EndsWith(' ',[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'PathTrailingDotOrSpace'; Normalized = '' } }
        if (DgPath-IsReservedName $seg) { return [pscustomobject]@{ Ok = $false; Reason = 'PathReservedName'; Normalized = '' } }
    }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return [pscustomobject]@{ Ok = $false; Reason = 'PathInvalid'; Normalized = '' } }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Normalized = $full }
}
function DgPolicy-TestPath {
    param([object]$Policy,[string]$Path)
    $c = DgPath-Check $Path
    if (-not $c.Ok) { return [pscustomobject]@{ Allowed = $false; Reason = $c.Reason; Normalized = ''; Root = ''; Reparse = [string[]]@() } }
    $norm = $c.Normalized
    $matched = ''
    foreach ($root in @($Policy.AllowedRoots)) {
        $prefix = $root + [string][char]92
        if ($norm.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase) -and $norm.Length -gt $prefix.Length) {
            if ($root.Length -gt $matched.Length) { $matched = $root }
        }
    }
    if ($matched.Length -eq 0) { return [pscustomobject]@{ Allowed = $false; Reason = 'PathOutsideRoot'; Normalized = $norm; Root = ''; Reparse = [string[]]@() } }
    $found = DgFs-GetReparseComponents $norm $matched
    $reparse = [string[]]@($found)
    # fail-closed: reparse points are tolerated (and recorded) only when the mode is exactly 'RecordOnly'
    if ($reparse.Count -ne 0 -and -not [string]::Equals([string]$Policy.ReparseMode,'RecordOnly',[System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'PathReparse'; Normalized = $norm; Root = $matched; Reparse = $reparse }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = ''; Normalized = $norm; Root = $matched; Reparse = $reparse }
}

# ---------------------------------------------------------------- journal records (pure formatting / verification)
function DgJournal-FormatRecord {
    param([System.Collections.Specialized.OrderedDictionary]$Fields,[string]$PreviousHash)
    $d = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in $Fields.Keys) { $d.Add($k,$Fields[$k]) }
    $d.Add('previousHash',$PreviousHash)
    $d.Add('recordHash',(DgConst-ZeroHash))
    $json = ConvertTo-Json -InputObject $d -Compress -Depth 8
    $tail = ',"recordHash":"' + (DgConst-ZeroHash) + '"}'
    if (-not $json.EndsWith($tail,[System.StringComparison]::Ordinal)) { throw (DgError 'JournalFormat' 'Unexpected JSON layout.') }
    $hash = DgSha256-Text $json
    $line = $json.Substring(0,$json.Length - $tail.Length) + ',"recordHash":"' + $hash + '"}'
    return [pscustomobject]@{ Line = $line; Hash = $hash }
}
function DgJournal-VerifyLine {
    param([string]$Line,[string]$ExpectedPrevious)
    $marker = ',"recordHash":"'
    if ($Line.Length -le 81 -or -not $Line.EndsWith('"}',[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'LineShape'; Record = $null; Hash = '' } }
    $idx = $Line.Length - 81
    if (-not [string]::Equals($Line.Substring($idx,15),$marker,[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'LineShape'; Record = $null; Hash = '' } }
    $hash = $Line.Substring($idx + 15,64)
    if ($hash -cnotmatch '^[0-9A-F]{64}$') { return [pscustomobject]@{ Ok = $false; Reason = 'HashShape'; Record = $null; Hash = '' } }
    $recomputed = DgSha256-Text ($Line.Substring(0,$idx) + $marker + (DgConst-ZeroHash) + '"}')
    if (-not [string]::Equals($recomputed,$hash,[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'RecordHashMismatch'; Record = $null; Hash = '' } }
    try { $rec = $Line | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Reason = 'JsonInvalid'; Record = $null; Hash = '' } }
    if (-not [string]::Equals([string](DgProp $rec 'previousHash' ''),$ExpectedPrevious,[System.StringComparison]::Ordinal)) { return [pscustomobject]@{ Ok = $false; Reason = 'PreviousHashMismatch'; Record = $null; Hash = '' } }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Record = $rec; Hash = $hash }
}
# Parse: only the last physical line may be torn. Anything else invalid => Corrupt.
function DgJournal-Parse {
    param([string]$Path)
    $result = [pscustomobject]@{ Records = @(); ValidLength = [long]0; TotalLength = [long]0; TornTail = $false; TornReason = ''; Corrupt = $false; CorruptReason = ''; CorruptLine = 0; LastHash = (DgConst-ZeroHash) }
    try { $bytes = [byte[]](DgFs-ReadAllBytesShared $Path) } catch { $result.Corrupt = $true; $result.CorruptReason = 'JournalUnreadable'; return $result }
    $result.TotalLength = [long]$bytes.Length
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    $parts = $text.Split([char]10)
    $remainder = $parts[$parts.Length - 1]
    $terminated = @()
    if ($parts.Length -gt 1) { $terminated = @($parts[0..($parts.Length - 2)]) }
    $hasRemainder = ($remainder.Length -gt 0)
    $records = New-Object System.Collections.ArrayList
    $previous = DgConst-ZeroHash
    $valid = [long]0
    $txn = ''
    $op = ''
    $known = DgConst-Stages
    for ($i = 0; $i -lt $terminated.Count; $i++) {
        $line = [string]$terminated[$i]
        $v = DgJournal-VerifyLine $line $previous
        $semantic = ''
        if ($v.Ok) {
            $rec = $v.Record
            if ([int](DgProp $rec 'schemaVersion' 0) -ne 1) { $semantic = 'SchemaVersion' }
            elseif ([int](DgProp $rec 'sequence' 0) -ne ($i + 1)) { $semantic = 'SequenceMismatch' }
            elseif (@($known) -cnotcontains [string](DgProp $rec 'stage' '')) { $semantic = 'UnknownStage' }
            elseif ($i -eq 0) { $txn = [string](DgProp $rec 'transactionId' ''); $op = [string](DgProp $rec 'operation' ''); if ($txn.Length -eq 0 -or $op.Length -eq 0) { $semantic = 'TxnFields' } }
            elseif (-not [string]::Equals([string](DgProp $rec 'transactionId' ''),$txn,[System.StringComparison]::Ordinal) -or -not [string]::Equals([string](DgProp $rec 'operation' ''),$op,[System.StringComparison]::Ordinal)) { $semantic = 'TxnMismatch' }
        }
        if ($v.Ok -and $semantic.Length -eq 0) {
            [void]$records.Add($v.Record)
            $previous = $v.Hash
            $valid += (New-Object System.Text.UTF8Encoding($false)).GetByteCount($line) + 1
            continue
        }
        $reason = if ($v.Ok) { $semantic } else { $v.Reason }
        $isLastPhysical = ($i -eq ($terminated.Count - 1)) -and -not $hasRemainder
        if ($isLastPhysical -and -not $v.Ok) {
            $result.TornTail = $true; $result.TornReason = $reason
            break
        }
        $result.Corrupt = $true; $result.CorruptReason = $reason; $result.CorruptLine = $i + 1
        break
    }
    if (-not $result.Corrupt -and $hasRemainder -and -not $result.TornTail) { $result.TornTail = $true; $result.TornReason = 'UnterminatedTail' }
    $result.Records = @($records)
    $result.ValidLength = $valid
    $result.LastHash = $previous
    return $result
}
function DgJournal-Summarize {
    param([object]$Parse)
    $s = @{ Ok = $false; Reason = ''; Begin = $null; Items = (New-Object System.Collections.ArrayList); CommitIntent = $null; Committed = $false; RollbackBegin = $false; RollbackComplete = $false; TxnId = ''; Operation = '' }
    $recs = @($Parse.Records)
    if ($recs.Count -eq 0) { $s.Reason = 'NoRecords'; return $s }
    $first = $recs[0]
    if (-not [string]::Equals([string](DgProp $first 'stage' ''),'Begin',[System.StringComparison]::Ordinal)) { $s.Reason = 'FirstNotBegin'; return $s }
    $s.Begin = $first
    $s.TxnId = [string]$first.transactionId
    $s.Operation = [string]$first.operation
    $registering = $true
    for ($i = 1; $i -lt $recs.Count; $i++) {
        $r = $recs[$i]
        $stage = [string]$r.stage
        if ($s.Committed -or $s.RollbackComplete) { $s.Reason = 'RecordAfterEnd'; return $s }
        if ([string]::Equals($stage,'Begin',[System.StringComparison]::Ordinal)) { $s.Reason = 'DuplicateBegin'; return $s }
        if ([string]::Equals($stage,'Register',[System.StringComparison]::Ordinal)) {
            if (-not $registering) { $s.Reason = 'RegisterAfterWork'; return $s }
            if ([int](DgProp $r 'itemId' -1) -ne $s.Items.Count) { $s.Reason = 'RegisterIdGap'; return $s }
            $item = @{
                Id = [int]$r.itemId; Op = [string]$r.op; Path = [string]$r.path; Norm = [string]$r.normalizedPath
                Source = [string](DgProp $r 'sourcePath' ''); SourceSha = [string](DgProp $r 'sourceSha' '')
                PreExists = [bool]$r.preExists; PreSha = [string](DgProp $r 'preSha' ''); PostSha = [string](DgProp $r 'expectedPostSha' '')
                Backup = [string](DgProp $r 'backupPath' ''); Tmp = [string](DgProp $r 'tmpPath' '')
                Dirs = [string[]]@(@(DgProp $r 'dirsToCreate' @()) | ForEach-Object { [string]$_ })
                Reparse = [string[]]@(@(DgProp $r 'reparsePoints' @()) | ForEach-Object { [string]$_ })
                Ownership = [string](DgProp $r 'ownershipCandidate' ''); Tag = [string](DgProp $r 'tag' '')
                HasIntent = $false; BackupSha = ''; HasApplied = $false; AppliedSha = ''; HasVerified = $false; HasRollbackIntent = $false; HasRolledBack = $false
            }
            [void]$s.Items.Add($item)
            continue
        }
        $registering = $false
        if ([string]::Equals($stage,'CommitIntent',[System.StringComparison]::Ordinal)) {
            if ($null -ne $s.CommitIntent) { $s.Reason = 'DuplicateCommitIntent'; return $s }
            $s.CommitIntent = $r; continue
        }
        if ([string]::Equals($stage,'Committed',[System.StringComparison]::Ordinal)) {
            if ($null -eq $s.CommitIntent) { $s.Reason = 'CommittedWithoutIntent'; return $s }
            $s.Committed = $true; continue
        }
        if ([string]::Equals($stage,'RollbackBegin',[System.StringComparison]::Ordinal)) { $s.RollbackBegin = $true; continue }
        if ([string]::Equals($stage,'RollbackComplete',[System.StringComparison]::Ordinal)) {
            if (-not $s.RollbackBegin) { $s.Reason = 'RollbackCompleteWithoutBegin'; return $s }
            $s.RollbackComplete = $true; continue
        }
        if ([string]::Equals($stage,'RollbackIncomplete',[System.StringComparison]::Ordinal)) {
            # diagnostic record written when a restore stopped (it never ends the transaction); itemId -1 = not tied to an item
            if (-not $s.RollbackBegin) { $s.Reason = 'RollbackOrder'; return $s }
            $rid = [int](DgProp $r 'itemId' -1)
            if ($rid -ge $s.Items.Count -or $rid -lt -1) { $s.Reason = 'UnregisteredItem'; return $s }
            if ($rid -ge 0 -and (-not [string]::Equals([string](DgProp $r 'normalizedPath' ''),$s.Items[$rid].Norm,[System.StringComparison]::Ordinal))) { $s.Reason = 'UnregisteredPath'; return $s }
            continue
        }
        # item-scoped stages
        $id = [int](DgProp $r 'itemId' -1)
        if ($id -lt 0 -or $id -ge $s.Items.Count) { $s.Reason = 'UnregisteredItem'; return $s }
        $it = $s.Items[$id]
        if (-not [string]::Equals([string](DgProp $r 'path' ''),$it.Path,[System.StringComparison]::Ordinal) -or -not [string]::Equals([string](DgProp $r 'normalizedPath' ''),$it.Norm,[System.StringComparison]::Ordinal)) { $s.Reason = 'UnregisteredPath'; return $s }
        if ([string]::Equals($stage,'Intent',[System.StringComparison]::Ordinal)) {
            if ($it.HasIntent) { $s.Reason = 'DuplicateIntent'; return $s }
            if (-not [string]::Equals([string](DgProp $r 'preSha' ''),$it.PreSha,[System.StringComparison]::Ordinal) -or -not [string]::Equals([string](DgProp $r 'expectedPostSha' ''),$it.PostSha,[System.StringComparison]::Ordinal) -or -not [string]::Equals([string](DgProp $r 'backupPath' ''),$it.Backup,[System.StringComparison]::Ordinal)) { $s.Reason = 'IntentMismatch'; return $s }
            $it.HasIntent = $true; $it.BackupSha = [string](DgProp $r 'backupSha' ''); continue
        }
        if ([string]::Equals($stage,'Applied',[System.StringComparison]::Ordinal)) {
            if (-not $it.HasIntent -or $it.HasApplied) { $s.Reason = 'AppliedOrder'; return $s }
            $it.HasApplied = $true; $it.AppliedSha = [string](DgProp $r 'observedPostSha' ''); continue
        }
        if ([string]::Equals($stage,'Verified',[System.StringComparison]::Ordinal)) {
            if (-not $it.HasApplied -or $it.HasVerified) { $s.Reason = 'VerifiedOrder'; return $s }
            $it.HasVerified = $true; continue
        }
        if ([string]::Equals($stage,'RollbackIntent',[System.StringComparison]::Ordinal)) { if (-not $s.RollbackBegin) { $s.Reason = 'RollbackOrder'; return $s }; $it.HasRollbackIntent = $true; continue }
        if ([string]::Equals($stage,'RolledBack',[System.StringComparison]::Ordinal)) { if (-not $s.RollbackBegin) { $s.Reason = 'RollbackOrder'; return $s }; $it.HasRolledBack = $true; continue }
        $s.Reason = 'UnhandledStage'; return $s
    }
    $s.Ok = $true
    return $s
}

# ---------------------------------------------------------------- context / guard
function DgTx-NewAllowed {
    param([string]$StateRoot,[string]$BackupRoot,[string]$TxnId,[string]$NewStatePath,[object[]]$Items)
    $a = @{ Dest = @{}; Tmp = @{}; Backup = @{}; Dir = @{}; Infra = @{} }
    foreach ($it in @($Items)) {
        $a.Dest[([string]$it.Norm).ToUpperInvariant()] = $true
        $a.Tmp[([string]$it.Tmp).ToUpperInvariant()] = $true
        if (([string]$it.Backup).Length -gt 0) { $a.Backup[([string]$it.Backup).ToUpperInvariant()] = $true }
        foreach ($d in @($it.Dirs)) { $a.Dir[([string]$d).ToUpperInvariant()] = $true }
    }
    $txnDir = [System.IO.Path]::Combine($StateRoot,'txn',$TxnId)
    $history = [System.IO.Path]::Combine($StateRoot,'history')
    foreach ($p in @(
        $StateRoot, [System.IO.Path]::Combine($StateRoot,'txn'), $txnDir, [System.IO.Path]::Combine($txnDir,'journal.jsonl'), [System.IO.Path]::Combine($txnDir,'recovery-report.txt'),
        [System.IO.Path]::Combine($StateRoot,'installing.json'), [System.IO.Path]::Combine($StateRoot,'installing.json.tmp'),
        [System.IO.Path]::Combine($StateRoot,'uninstalling.json'), [System.IO.Path]::Combine($StateRoot,'uninstalling.json.tmp'),
        $history, [System.IO.Path]::Combine($history,('txn-' + $TxnId + '.committed.jsonl')), [System.IO.Path]::Combine($history,('txn-' + $TxnId + '.rolledback.jsonl')),
        $BackupRoot, [System.IO.Path]::Combine($BackupRoot,$TxnId), $NewStatePath, ($NewStatePath + '.tmp'))) {
        $a.Infra[([System.IO.Path]::GetFullPath($p)).ToUpperInvariant()] = $true
    }
    return $a
}
function DgG-Assert {
    param([hashtable]$Ctx,[string]$Path,[string]$Kind)
    # (1) the allowed-root policy (normalization, boundary, device names, reparse points) is enforced at the moment of mutation,
    # (2) the path must be one of the individually registered paths of THIS transaction for the requested kind.
    if ($Ctx.ContainsKey('Policy') -and $null -ne $Ctx.Policy) {
        $pt = DgPolicy-TestPath $Ctx.Policy $Path
        if (-not $pt.Allowed) { throw (DgError 'PathRejected' ('Refusing to mutate a path rejected by the path policy (' + $pt.Reason + '): ' + $Path)) }
    }
    if (-not $Ctx.Allowed.ContainsKey($Kind)) { throw (DgError 'PathNotRegistered' ('Unknown path kind: ' + $Kind)) }
    $key = ([System.IO.Path]::GetFullPath($Path)).ToUpperInvariant()
    if (-not $Ctx.Allowed[$Kind].ContainsKey($key)) { throw (DgError 'PathNotRegistered' ('Refusing to mutate a path that is not registered as ' + $Kind + ': ' + $Path)) }
}
function DgG-CopyFile { param([hashtable]$Ctx,[string]$Source,[string]$Destination,[string]$Kind) DgG-Assert $Ctx $Destination $Kind; DgFs-CopyFileDurable $Source $Destination }
function DgG-CreateFile { param([hashtable]$Ctx,[string]$Path,[byte[]]$Bytes,[string]$Kind) DgG-Assert $Ctx $Path $Kind; DgFs-CreateFileDurable $Path $Bytes }
function DgG-Replace { param([hashtable]$Ctx,[string]$Temporary,[string]$Destination,[string]$Kind,[string]$TmpKind = 'Tmp') DgG-Assert $Ctx $Destination $Kind; DgG-Assert $Ctx $Temporary $TmpKind; DgFs-Replace $Temporary $Destination }
function DgG-MoveNew { param([hashtable]$Ctx,[string]$Source,[string]$Destination,[string]$Kind,[string]$SourceKind) DgG-Assert $Ctx $Destination $Kind; DgG-Assert $Ctx $Source $SourceKind; DgFs-MoveNew $Source $Destination }
function DgG-Delete { param([hashtable]$Ctx,[string]$Path,[string]$Kind) DgG-Assert $Ctx $Path $Kind; DgFs-Delete $Path }
function DgG-CreateDir { param([hashtable]$Ctx,[string]$Path,[string]$Kind) DgG-Assert $Ctx $Path $Kind; return (DgFs-CreateDir $Path) }
function DgG-RemoveDirIfEmpty { param([hashtable]$Ctx,[string]$Path,[string]$Kind) DgG-Assert $Ctx $Path $Kind; return (DgFs-RemoveDirIfEmpty $Path) }
function DgG-WriteText { param([hashtable]$Ctx,[string]$Path,[string]$Text) DgG-Assert $Ctx $Path 'Infra'; DgFs-WriteTextFile $Path $Text }

function DgTx-Journal {
    param([hashtable]$Ctx,[string]$Stage,[System.Collections.Specialized.OrderedDictionary]$Extra)
    if ($Ctx.JournalBroken -and -not $Ctx.InRollback) { throw (DgError 'JournalBroken' 'A previous journal append failed.') }
    if ($Ctx.JournalBroken) { return }
    $f = New-Object System.Collections.Specialized.OrderedDictionary
    $f.Add('schemaVersion',1)
    $f.Add('transactionId',$Ctx.TxnId)
    $f.Add('operation',$Ctx.Operation)
    $f.Add('sequence',[int]($Ctx.Seq + 1))
    $f.Add('timestamp',(DgClock-Now))
    $f.Add('stage',$Stage)
    foreach ($k in $Extra.Keys) { $f.Add($k,$Extra[$k]) }
    $rec = DgJournal-FormatRecord $f $Ctx.PrevHash
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($rec.Line + "`n")
    try { DgJournal-Append $Ctx.Journal $bytes } catch { $Ctx.JournalBroken = $true; throw }
    $Ctx.Seq = [int]($Ctx.Seq + 1)
    $Ctx.PrevHash = $rec.Hash
}
function DgTx-ItemFields {
    param([hashtable]$Item)
    $d = New-Object System.Collections.Specialized.OrderedDictionary
    $d.Add('itemId',[int]$Item.Id)
    $d.Add('path',[string]$Item.Path)
    $d.Add('normalizedPath',[string]$Item.Norm)
    return $d
}

# ---------------------------------------------------------------- Begin
function DgTx-Begin {
    param([string]$StateRoot,[string]$BackupRoot,[string]$Operation,[object[]]$Items,[object]$Policy,[string]$NewStatePath,[switch]$AllowEmptyTransaction)
    if (-not (DgEq $Operation 'Install') -and -not (DgEq $Operation 'Uninstall')) { throw (DgError 'PlanInvalid' 'Operation must be Install or Uninstall.') }
    # A transaction without items is refused unless the caller asks for it explicitly (I2-B: a state-only commit).
    if (@($Items).Count -eq 0 -and -not $AllowEmptyTransaction) { throw (DgError 'PlanInvalid' 'No items.') }
    $infra = @{}
    foreach ($pair in @(@('StateRoot',$StateRoot),@('BackupRoot',$BackupRoot),@('NewStatePath',$NewStatePath))) {
        $t = DgPolicy-TestPath $Policy $pair[1]
        if (-not $t.Allowed) { throw (DgError 'PlanInvalid' ($pair[0] + ' rejected: ' + $t.Reason)) }
        $infra[$pair[0]] = $t.Normalized
    }
    $StateRoot = $infra['StateRoot']; $BackupRoot = $infra['BackupRoot']; $NewStatePath = $infra['NewStatePath']
    $markerPath = [System.IO.Path]::Combine($StateRoot,(DgConst-MarkerName $Operation))
    foreach ($name in @('installing.json','uninstalling.json')) {
        if (DgFs-Exists ([System.IO.Path]::Combine($StateRoot,$name))) { throw (DgError 'MarkerExists' ('A transaction marker is present: ' + $name)) }
    }
    $txnId = DgId-New 'txn'
    $txnDir = [System.IO.Path]::Combine($StateRoot,'txn',$txnId)
    $journalPath = [System.IO.Path]::Combine($txnDir,'journal.jsonl')
    $backupTxnDir = [System.IO.Path]::Combine($BackupRoot,$txnId)
    if (DgFs-DirExists $txnDir) { throw (DgError 'TxnExists' ('Transaction directory already exists: ' + $txnDir)) }
    foreach ($outcomeName in @('committed','rolledback')) {
        if (DgFs-Exists ([System.IO.Path]::Combine($StateRoot,'history',('txn-' + $txnId + '.' + $outcomeName + '.jsonl')))) { throw (DgError 'TxnExists' ('History already contains transaction ' + $txnId)) }
    }

    $built = New-Object System.Collections.ArrayList
    $seen = @{}
    $id = 0
    foreach ($raw in @($Items)) {
        $op = [string]$raw.Op
        if (-not (DgEq $op 'Write') -and -not (DgEq $op 'Delete')) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': Op must be Write or Delete.')) }
        $t = DgPolicy-TestPath $Policy ([string]$raw.Destination)
        if (-not $t.Allowed) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': destination rejected: ' + $t.Reason + ' (' + [string]$raw.Destination + ')')) }
        $norm = $t.Normalized
        $key = $norm.ToUpperInvariant()
        if ($seen.ContainsKey($key)) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': duplicate destination.')) }
        $seen[$key] = $true
        if (DgFs-DirExists $norm) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': destination is a directory.')) }
        $tmp = $norm + (DgConst-TmpSuffix)
        $tt = DgPolicy-TestPath $Policy $tmp
        if (-not $tt.Allowed) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': temporary path rejected: ' + $tt.Reason)) }
        $preExists = DgFs-Exists $norm
        $preSha = ''
        if ($preExists) { $preSha = DgFs-Sha256 $norm }
        $source = ''; $sourceSha = ''; $postSha = ''
        if (DgEq $op 'Write') {
            $source = [System.IO.Path]::GetFullPath([string]$raw.Source)
            if (-not (DgFs-Exists $source)) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': source is missing.')) }
            $sourceSha = DgFs-Sha256 $source
            $postSha = $sourceSha
            if ($preExists -and (DgEq $preSha $sourceSha)) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': ItemUnchanged (pre SHA equals post SHA).')) }
        } else {
            if (-not $preExists) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': delete target is missing.')) }
        }
        $dirs = New-Object System.Collections.ArrayList
        $parent = [System.IO.Path]::GetDirectoryName($norm)
        while (-not [string]::IsNullOrEmpty($parent) -and -not (DgFs-DirExists $parent)) {
            $pt = DgPolicy-TestPath $Policy $parent
            if (-not $pt.Allowed) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': a directory to create is rejected: ' + $pt.Reason + ' (' + $parent + ')')) }
            [void]$dirs.Add($pt.Normalized)
            $parent = [System.IO.Path]::GetDirectoryName($parent)
        }
        $dirs.Reverse()
        if ($dirs.Count -ne 0 -and (DgEq $op 'Delete')) { throw (DgError 'PlanInvalid' ('Item ' + $id + ': delete target has a missing parent.')) }
        [void]$built.Add(@{
            Id = $id; Op = $op; Path = [string]$raw.Destination; Norm = $norm; Source = $source; SourceSha = $sourceSha
            PreExists = $preExists; PreSha = $preSha; PostSha = $postSha
            Backup = $(if ($preExists) { [System.IO.Path]::Combine($backupTxnDir,('{0:D4}.bak' -f $id)) } else { '' })
            Tmp = $tmp; Dirs = [string[]]@($dirs); Reparse = [string[]]@($t.Reparse)
            Ownership = [string](DgProp $raw 'OwnershipCandidate' ''); Tag = [string](DgProp $raw 'Tag' '')
        })
        $id++
    }
    $oldStateSha = ''
    if (DgFs-Exists $NewStatePath) { $oldStateSha = DgFs-Sha256 $NewStatePath }

    $ctx = @{
        TxnId = $txnId; Operation = $Operation; StateRoot = $StateRoot; BackupRoot = $BackupRoot; TxnDir = $txnDir; JournalPath = $journalPath
        BackupTxnDir = $backupTxnDir; MarkerPath = $markerPath; Policy = $Policy; Items = @($built); NewStatePath = $NewStatePath; NewStateTmp = ($NewStatePath + '.tmp')
        OldStateSha = $oldStateSha; Journal = $null; Seq = 0; PrevHash = (DgConst-ZeroHash); JournalBroken = $false; InRollback = $false; Closed = $false; StateCommitted = $false
    }
    $ctx.Allowed = DgTx-NewAllowed $StateRoot $BackupRoot $txnId $NewStatePath $ctx.Items
    try {
        [void](DgG-CreateDir $ctx $StateRoot 'Infra')
        [void](DgG-CreateDir $ctx ([System.IO.Path]::Combine($StateRoot,'txn')) 'Infra')
        [void](DgG-CreateDir $ctx $txnDir 'Infra')
        DgG-Assert $ctx $journalPath 'Infra'
        $ctx.Journal = DgJournal-Open $journalPath
        $b = New-Object System.Collections.Specialized.OrderedDictionary
        $b.Add('stateRoot',$StateRoot); $b.Add('backupRoot',$BackupRoot); $b.Add('oldStateSha',$oldStateSha); $b.Add('newStatePath',$NewStatePath); $b.Add('newStateTmp',$ctx.NewStateTmp); $b.Add('itemCount',@($built).Count)
        DgTx-Journal $ctx 'Begin' $b
        foreach ($it in $ctx.Items) {
            $r = DgTx-ItemFields $it
            $r.Add('op',$it.Op); $r.Add('sourcePath',$it.Source); $r.Add('sourceSha',$it.SourceSha); $r.Add('preExists',[bool]$it.PreExists); $r.Add('preSha',$it.PreSha)
            $r.Add('expectedPostSha',$it.PostSha); $r.Add('backupPath',$it.Backup); $r.Add('tmpPath',$it.Tmp); $r.Add('dirsToCreate',[string[]]@($it.Dirs))
            $r.Add('reparsePoints',[string[]]@($it.Reparse)); $r.Add('ownershipCandidate',$it.Ownership); $r.Add('tag',$it.Tag)
            DgTx-Journal $ctx 'Register' $r
        }
        $markerTmp = $markerPath + '.tmp'
        if (DgFs-Exists $markerTmp) { DgG-Delete $ctx $markerTmp 'Infra' }
        $m = [ordered]@{ SchemaVersion = 1; ProductVersion = ''; State = $(if (DgEq $Operation 'Install') { 'Installing' } else { 'Uninstalling' }); Started = (DgClock-Now); TxnId = $txnId; Operation = $Operation; JournalPath = $journalPath; BackupRoot = $BackupRoot; StateRoot = $StateRoot }
        DgG-CreateFile $ctx $markerTmp ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $m -Compress))) 'Infra'
        DgG-MoveNew $ctx $markerTmp $markerPath 'Infra' 'Infra'
    } catch {
        if ($null -ne $ctx.Journal) { try { DgJournal-Close $ctx.Journal } catch {} ; $ctx.Journal = $null }
        try { $mt = $markerPath + '.tmp'; if ((DgFs-Exists $mt) -and -not (DgFs-Exists $markerPath)) { DgG-Delete $ctx $mt 'Infra' } } catch {}
        # The marker is published as the last step of Begin and nothing is changed yet; finish it cleanly (journal + marker go to history).
        try { if (DgFs-Exists $markerPath) { [void](DgTx-Rollback $ctx 'BeginFailed') } } catch {}
        throw
    }
    return $ctx
}

# ---------------------------------------------------------------- Apply
function DgTx-ApplyItem {
    param([hashtable]$Ctx,[hashtable]$Item)
    $id = [int]$Item.Id
    $isWrite = (DgEq $Item.Op 'Write')
    if ($Item.PreExists) {
        if (-not (DgFs-Exists $Item.Norm)) { throw (DgError 'PlanStale' ('Destination disappeared: ' + $Item.Norm)) }
        if (-not (DgEq (DgFs-Sha256 $Item.Norm) $Item.PreSha)) { throw (DgError 'PlanStale' ('Destination changed since planning: ' + $Item.Norm)) }
    } elseif (DgFs-Exists $Item.Norm) { throw (DgError 'PlanStale' ('Destination appeared since planning: ' + $Item.Norm)) }

    $backupSha = ''
    $backupCreated = $false
    if ($Item.PreExists) {
        if (-not (DgFs-DirExists $Ctx.BackupTxnDir)) {
            [void](DgG-CreateDir $Ctx $Ctx.BackupRoot 'Infra')
            [void](DgG-CreateDir $Ctx $Ctx.BackupTxnDir 'Infra')
        }
        DgG-CopyFile $Ctx $Item.Norm $Item.Backup 'Backup'
        $backupSha = DgFs-Sha256 $Item.Backup
        if (-not (DgEq $backupSha $Item.PreSha)) { throw (DgError 'BackupVerifyFailed' ('Backup SHA mismatch: ' + $Item.Backup)) }
        $backupCreated = $true
    }
    $f = DgTx-ItemFields $Item
    $f.Add('backupPath',$Item.Backup); $f.Add('backupSha',$backupSha); $f.Add('backupCreated',$backupCreated); $f.Add('preSha',$Item.PreSha); $f.Add('expectedPostSha',$Item.PostSha)
    DgTx-Journal $Ctx 'Intent' $f

    foreach ($d in @($Item.Dirs)) { if (-not (DgFs-DirExists $d)) { [void](DgG-CreateDir $Ctx $d 'Dir') } }
    if ($isWrite) {
        if (DgFs-Exists $Item.Tmp) { DgG-Delete $Ctx $Item.Tmp 'Tmp' }
        DgG-CopyFile $Ctx $Item.Source $Item.Tmp 'Tmp'
        if (-not (DgEq (DgFs-Sha256 $Item.Tmp) $Item.PostSha)) { throw (DgError 'TmpVerifyFailed' ('Temporary copy SHA mismatch: ' + $Item.Tmp)) }
        if ($Item.PreExists) {
            DgFs-ProbeExclusive $Item.Norm
            DgG-Replace $Ctx $Item.Tmp $Item.Norm 'Dest'
        } else {
            DgG-MoveNew $Ctx $Item.Tmp $Item.Norm 'Dest' 'Tmp'
        }
        $observed = '<missing>'
        if (DgFs-Exists $Item.Norm) { $observed = DgFs-Sha256 $Item.Norm }
    } else {
        DgFs-ProbeExclusive $Item.Norm
        DgG-Delete $Ctx $Item.Norm 'Dest'
        $observed = ''
        if (DgFs-Exists $Item.Norm) { $observed = '<present>' }
    }
    $a = DgTx-ItemFields $Item
    $a.Add('observedPostSha',$observed)
    DgTx-Journal $Ctx 'Applied' $a
    if (-not (DgEq $observed $Item.PostSha)) { throw (DgError 'PostShaMismatch' ('Post-write SHA mismatch: ' + $Item.Norm)) }
    $v = DgTx-ItemFields $Item
    $v.Add('verifiedSha',$observed)
    DgTx-Journal $Ctx 'Verified' $v
}
function DgTx-Apply {
    param([hashtable]$Ctx)
    foreach ($item in @($Ctx.Items)) {
        try { DgTx-ApplyItem $Ctx $item }
        catch {
            $Ctx.FailedItem = [int]$item.Id
            $Ctx.FailureException = $_.Exception
            throw
        }
    }
}

# ---------------------------------------------------------------- classification / preflight (read-only)
function DgTx-ItemState {
    param([hashtable]$Item)
    $exists = DgFs-Exists $Item.Norm
    if (-not $exists) {
        if (DgFs-DirExists $Item.Norm) { return @{ State = 'unknown'; Sha = '<directory>' } }
        if (-not $Item.PreExists -and (DgEq $Item.Op 'Write')) { return @{ State = 'pre'; Sha = '' } }
        if (DgEq $Item.Op 'Delete') { return @{ State = 'post'; Sha = '' } }
        return @{ State = 'unknown'; Sha = '<missing>' }
    }
    $sha = DgFs-Sha256 $Item.Norm
    if ($Item.PreExists -and (DgEq $sha $Item.PreSha)) { return @{ State = 'pre'; Sha = $sha } }
    if ((DgEq $Item.Op 'Write') -and (DgEq $sha $Item.PostSha)) { return @{ State = 'post'; Sha = $sha } }
    if ($Item.HasApplied -and $Item.AppliedSha.Length -gt 0 -and -not $Item.AppliedSha.StartsWith('<') -and (DgEq $sha $Item.AppliedSha)) { return @{ State = 'post'; Sha = $sha } }
    return @{ State = 'unknown'; Sha = $sha }
}
function DgTx-Preflight {
    param([string]$StateRoot,[string]$BackupRoot,[object]$Policy)
    $reasons = New-Object System.Collections.ArrayList
    $res = @{ Ok = $false; Reasons = $reasons; Summary = $null; Parse = $null; Marker = $null; MarkerPath = ''; Region = ''; Plan = (New-Object System.Collections.ArrayList); TxnId = ''; Operation = '' }
    $add = { param($code,$detail,$item) [void]$reasons.Add([pscustomobject]@{ Code = $code; Item = $item; Detail = $detail }) }
    $StateRoot = [System.IO.Path]::GetFullPath($StateRoot); $BackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
    $markers = @()
    foreach ($name in @('installing.json','uninstalling.json')) { $p = [System.IO.Path]::Combine($StateRoot,$name); if (DgFs-Exists $p) { $markers += $p } }
    if ($markers.Count -eq 0) { $res.Region = 'NoMarker'; $res.Ok = $true; return $res }
    if ($markers.Count -gt 1) { & $add 'MultipleMarkers' 'Both installing.json and uninstalling.json exist.' -1; return $res }
    $res.MarkerPath = $markers[0]
    try { $marker = (New-Object System.Text.UTF8Encoding($false)).GetString([byte[]](DgFs-ReadAllBytesShared $markers[0])).TrimStart([char]0xFEFF) | ConvertFrom-Json }
    catch { & $add 'MarkerUnreadable' 'The marker could not be read or parsed.' -1; return $res }
    $res.Marker = $marker
    $txnId = [string](DgProp $marker 'TxnId' ''); $operation = [string](DgProp $marker 'Operation' '')
    if ($txnId.Length -eq 0 -or ($txnId -notmatch '^[A-Za-z0-9\-]+$') -or -not ((DgEq $operation 'Install') -or (DgEq $operation 'Uninstall')) -or [int](DgProp $marker 'SchemaVersion' 0) -ne 1) { & $add 'MarkerUnreadable' 'Marker fields are missing or invalid.' -1; return $res }
    if (-not (DgEqI ([System.IO.Path]::GetFileName($markers[0])) (DgConst-MarkerName $operation))) { & $add 'MarkerUnreadable' 'Marker name does not match its operation.' -1; return $res }
    if (-not (DgEqI ([string](DgProp $marker 'StateRoot' '')) $StateRoot) -or -not (DgEqI ([string](DgProp $marker 'BackupRoot' '')) $BackupRoot)) { & $add 'StateRootMismatch' 'The marker roots differ from the caller roots.' -1; return $res }
    $res.TxnId = $txnId; $res.Operation = $operation
    $journalPath = [System.IO.Path]::Combine($StateRoot,'txn',$txnId,'journal.jsonl')
    if (-not (DgFs-Exists $journalPath)) { & $add 'JournalMissing' $journalPath -1; return $res }
    $parse = DgJournal-Parse $journalPath
    $res.Parse = $parse
    if ($parse.Corrupt) { & $add 'JournalCorrupt' ($parse.CorruptReason + ' at line ' + $parse.CorruptLine) -1; return $res }
    $sum = DgJournal-Summarize $parse
    $res.Summary = $sum
    if (-not $sum.Ok) { & $add 'JournalCorrupt' ('Semantic: ' + $sum.Reason) -1; return $res }
    if (-not (DgEq $sum.TxnId $txnId) -or -not (DgEq $sum.Operation $operation)) { & $add 'JournalCorrupt' 'Marker and journal disagree on the transaction.' -1; return $res }
    if (-not (DgEqI ([string]$sum.Begin.stateRoot) $StateRoot) -or -not (DgEqI ([string]$sum.Begin.backupRoot) $BackupRoot)) { & $add 'StateRootMismatch' 'The journal roots differ from the caller roots.' -1; return $res }
    if (-not (DgEqI ([string]$marker.JournalPath) $journalPath)) { & $add 'StateRootMismatch' 'The marker journal path is not the expected path.' -1; return $res }
    $newStatePath = [string]$sum.Begin.newStatePath
    $np = DgPolicy-TestPath $Policy $newStatePath
    if (-not $np.Allowed -or -not (DgEq $np.Normalized $newStatePath)) { & $add 'PathRejected' ('State path: ' + $newStatePath) -1; return $res }
    if (-not (DgEq ([string]$sum.Begin.newStateTmp) ($newStatePath + '.tmp'))) { & $add 'PathRejected' 'State temporary path.' -1; return $res }
    foreach ($rootPair in @(@('stateRoot',$StateRoot),@('backupRoot',$BackupRoot))) { $rp = DgPolicy-TestPath $Policy $rootPair[1]; if (-not $rp.Allowed) { & $add 'PathRejected' ($rootPair[0] + ': ' + $rp.Reason) -1; return $res } }
    $backupTxnDir = [System.IO.Path]::Combine($BackupRoot,$txnId)
    $items = @($sum.Items)
    foreach ($it in $items) {
        $pt = DgPolicy-TestPath $Policy $it.Path
        if (-not $pt.Allowed) { & $add 'PathRejected' ($pt.Reason + ': ' + $it.Path) $it.Id; continue }
        if (-not (DgEq $pt.Normalized $it.Norm)) { & $add 'PathRejected' ('Normalized path differs: ' + $it.Path) $it.Id; continue }
        if (-not (DgEq $it.Tmp ($it.Norm + (DgConst-TmpSuffix)))) { & $add 'PathRejected' ('Temporary path: ' + $it.Tmp) $it.Id; continue }
        if ($it.PreExists) { if (-not (DgEq $it.Backup ([System.IO.Path]::Combine($backupTxnDir,('{0:D4}.bak' -f $it.Id))))) { & $add 'PathRejected' ('Backup path: ' + $it.Backup) $it.Id; continue } }
        elseif ($it.Backup.Length -ne 0) { & $add 'PathRejected' 'Unexpected backup path.' $it.Id; continue }
        foreach ($d in @($it.Dirs)) {
            $dt = DgPolicy-TestPath $Policy $d
            if (-not $dt.Allowed -or -not (DgEq $dt.Normalized $d) -or -not $it.Norm.StartsWith(($d + [string][char]92),[System.StringComparison]::OrdinalIgnoreCase)) { & $add 'PathRejected' ('Directory: ' + $d) $it.Id }
        }
        if (-not [string]::Equals([string]$Policy.ReparseMode,'RecordOnly',[System.StringComparison]::Ordinal) -and @($pt.Reparse).Count -ne 0) { & $add 'PathRejected' ('Reparse point: ' + $it.Path) $it.Id }
    }
    if ($reasons.Count -ne 0) { return $res }

    # region
    $region = 'PreCommit'
    if ($null -ne $sum.CommitIntent -or $sum.Committed) {
        $newSha = [string]$sum.CommitIntent.newStateSha
        $stateSha = ''
        if (DgFs-Exists $newStatePath) {
            try { $stateSha = DgFs-Sha256 $newStatePath } catch { & $add 'StateShaUnknown' 'The state file could not be read.' -1; return $res }
        }
        if ((DgEq $stateSha $newSha) -and $newSha.Length -gt 0) { $region = 'RollForward'; if ($sum.RollbackBegin) { & $add 'StateShaUnknown' 'Rollback began after the state was committed.' -1; return $res } }
        elseif ((DgEq $stateSha ([string]$sum.Begin.oldStateSha)) -and -not $sum.Committed) { $region = 'CommitIntentRollback' }
        else { & $add 'StateShaUnknown' 'The state file matches neither the old nor the new SHA.' -1; return $res }
    }
    $res.Region = $region
    if ($region -eq 'RollForward') { $res.Ok = $true; return $res }

    foreach ($it in $items) {
        try { $st = DgTx-ItemState $it } catch { & $add 'DestinationUnreadable' $it.Path $it.Id; continue }
        if ($st.State -eq 'unknown') { & $add 'DestinationUnknownSha' ($it.Path + ' sha=' + $st.Sha) $it.Id; continue }
        $action = 'None'
        if ($st.State -eq 'post') {
            if (-not $it.HasIntent) { & $add 'PostWithoutIntent' $it.Path $it.Id; continue }
            if ($it.PreExists) {
                if (-not (DgFs-Exists $it.Backup)) { & $add 'BackupMissing' $it.Backup $it.Id; continue }
                try { $bs = DgFs-Sha256 $it.Backup } catch { & $add 'BackupMissing' $it.Backup $it.Id; continue }
                if (-not (DgEq $bs $it.BackupSha) -or -not (DgEq $bs $it.PreSha)) { & $add 'BackupShaMismatch' $it.Backup $it.Id; continue }
                $action = if (DgEq $it.Op 'Delete') { 'RestoreDeleted' } else { 'Restore' }
            } else { $action = 'RemoveNew' }
        }
        [void]$res.Plan.Add(@{ Id = $it.Id; Action = $action; State = $st.State; Sha = [string]$st.Sha })
    }
    if ($reasons.Count -ne 0) { return $res }
    $res.Ok = $true
    return $res
}

# ---------------------------------------------------------------- rollback execution (Phase 2) shared by runtime rollback and recovery
function DgTx-ContextFromPreflight {
    param([hashtable]$Pf,[object]$Policy,[bool]$TruncateTornTail)
    $sum = $Pf.Summary
    $ctxItems = @($sum.Items)
    $stateRoot = [string]$sum.Begin.stateRoot; $backupRoot = [string]$sum.Begin.backupRoot
    $ctx = @{
        TxnId = $sum.TxnId; Operation = $sum.Operation; StateRoot = $stateRoot; BackupRoot = $backupRoot; TxnDir = [System.IO.Path]::Combine($stateRoot,'txn',$sum.TxnId)
        JournalPath = [System.IO.Path]::Combine($stateRoot,'txn',$sum.TxnId,'journal.jsonl'); BackupTxnDir = [System.IO.Path]::Combine($backupRoot,$sum.TxnId)
        MarkerPath = $Pf.MarkerPath; Policy = $Policy; Items = $ctxItems; NewStatePath = [string]$sum.Begin.newStatePath; NewStateTmp = ([string]$sum.Begin.newStatePath + '.tmp')
        OldStateSha = [string]$sum.Begin.oldStateSha; Journal = $null; Seq = @($Pf.Parse.Records).Count; PrevHash = [string]$Pf.Parse.LastHash; JournalBroken = $false; InRollback = $true; Closed = $false
    }
    $ctx.Allowed = DgTx-NewAllowed $stateRoot $backupRoot $sum.TxnId $ctx.NewStatePath $ctxItems
    return $ctx
}
# Re-measures the destination right before it is replaced/deleted. $CertifiedSha is the state Phase 1 certified:
# a SHA (the file must still have exactly that SHA) or '' (the file must still be absent). Any difference means somebody
# else changed the file after Phase 1: nothing is touched and the caller stops with DestinationChangedAfterPreflight.
# The window between this re-measurement and Replace/Delete/Move cannot be closed in user mode (documented limitation).
function DgTx-AssertUnchangedSincePreflight {
    param([hashtable]$Item,[string]$CertifiedSha)
    $exists = DgFs-Exists $Item.Norm
    if ($CertifiedSha.Length -eq 0) {
        if ($exists) { throw (DgError 'DestinationChangedAfterPreflight' ('A file appeared after the preflight: ' + $Item.Norm)) }
        return
    }
    if (-not $exists) { throw (DgError 'DestinationChangedAfterPreflight' ('The file disappeared after the preflight: ' + $Item.Norm)) }
    if (-not (DgEq (DgFs-Sha256 $Item.Norm) $CertifiedSha)) { throw (DgError 'DestinationChangedAfterPreflight' ('The file changed after the preflight: ' + $Item.Norm)) }
}
function DgTx-RestoreItem {
    param([hashtable]$Ctx,[hashtable]$Item,[string]$Action,[string]$CertifiedSha = '')
    $f = DgTx-ItemFields $Item
    $f.Add('action',$Action)
    DgTx-Journal $Ctx 'RollbackIntent' $f
    if (DgEq $Action 'Restore') {
        if (DgFs-Exists $Item.Tmp) { DgG-Delete $Ctx $Item.Tmp 'Tmp' }
        DgG-CopyFile $Ctx $Item.Backup $Item.Tmp 'Tmp'
        if (-not (DgEq (DgFs-Sha256 $Item.Tmp) $Item.PreSha)) { throw (DgError 'RestoreVerifyFailed' ('Restore copy SHA mismatch: ' + $Item.Tmp)) }
        DgFs-ProbeExclusive $Item.Norm
        DgTx-AssertUnchangedSincePreflight $Item $CertifiedSha
        DgG-Replace $Ctx $Item.Tmp $Item.Norm 'Dest'
        $result = DgFs-Sha256 $Item.Norm
        if (-not (DgEq $result $Item.PreSha)) { throw (DgError 'RestoreVerifyFailed' ('Restored SHA mismatch: ' + $Item.Norm)) }
    } elseif (DgEq $Action 'RestoreDeleted') {
        if (DgFs-Exists $Item.Tmp) { DgG-Delete $Ctx $Item.Tmp 'Tmp' }
        DgG-CopyFile $Ctx $Item.Backup $Item.Tmp 'Tmp'
        if (-not (DgEq (DgFs-Sha256 $Item.Tmp) $Item.PreSha)) { throw (DgError 'RestoreVerifyFailed' ('Restore copy SHA mismatch: ' + $Item.Tmp)) }
        DgTx-AssertUnchangedSincePreflight $Item ''
        DgG-MoveNew $Ctx $Item.Tmp $Item.Norm 'Dest' 'Tmp'
        $result = DgFs-Sha256 $Item.Norm
        if (-not (DgEq $result $Item.PreSha)) { throw (DgError 'RestoreVerifyFailed' ('Restored SHA mismatch: ' + $Item.Norm)) }
    } elseif (DgEq $Action 'RemoveNew') {
        # a file we added: delete it only while it still has the SHA Phase 1 certified; if it is already gone the work is done
        if (DgFs-Exists $Item.Norm) {
            DgFs-ProbeExclusive $Item.Norm
            if (DgFs-Exists $Item.Norm) {
                DgTx-AssertUnchangedSincePreflight $Item $CertifiedSha
                DgG-Delete $Ctx $Item.Norm 'Dest'
            }
        }
        if (DgFs-Exists $Item.Norm) { throw (DgError 'RestoreVerifyFailed' ('Added file could not be removed: ' + $Item.Norm)) }
        $result = ''
    } else { throw (DgError 'RestoreVerifyFailed' ('Unknown action ' + $Action)) }
    $r = DgTx-ItemFields $Item
    $r.Add('resultSha',$result)
    DgTx-Journal $Ctx 'RolledBack' $r
}
function DgTx-Finalize {
    param([hashtable]$Ctx,[string]$Outcome)
    if ($null -ne $Ctx.Journal) { DgJournal-Close $Ctx.Journal; $Ctx.Journal = $null }
    $historyDir = [System.IO.Path]::Combine($Ctx.StateRoot,'history')
    $target = [System.IO.Path]::Combine($historyDir,('txn-' + $Ctx.TxnId + '.' + $Outcome + '.jsonl'))
    if (DgFs-Exists $Ctx.MarkerPath) { DgG-Delete $Ctx $Ctx.MarkerPath 'Infra' }
    if (DgFs-Exists $Ctx.JournalPath) {
        [void](DgG-CreateDir $Ctx $historyDir 'Infra')
        DgG-MoveNew $Ctx $Ctx.JournalPath $target 'Infra' 'Infra'
    }
    [void](DgG-RemoveDirIfEmpty $Ctx $Ctx.TxnDir 'Infra')
    $Ctx.Closed = $true
}
# Executes Phase 2 for a verified preflight. Returns Outcome: RolledBack | RolledForward | RollbackIncomplete.
function DgTx-ExecuteRecovery {
    param([hashtable]$Pf,[hashtable]$Ctx,[string]$By,[string]$Reason)
    $sum = $Pf.Summary
    if ($Pf.Region -eq 'RollForward') {
        try {
            if (-not $sum.Committed) { DgTx-Journal $Ctx 'Committed' ([ordered]@{}) }
            DgTx-Finalize $Ctx 'committed'
            return @{ Outcome = 'RolledForward'; Error = ''; Code = ''; Reasons = [object[]]@(); ManualCheckRequired = $false }
        } catch { return @{ Outcome = 'RollbackIncomplete'; Error = [string]$_.Exception.Message; Code = (DgError-Code $_.Exception); Reasons = [object[]]@(); ManualCheckRequired = $false } }
    }
    $failedItem = -1
    $ended = [bool]$sum.RollbackComplete     # nothing may be appended after RollbackComplete (the parser treats it as the end of the journal)
    try {
        if (-not $sum.RollbackBegin) { DgTx-Journal $Ctx 'RollbackBegin' ([ordered]@{ reason = $Reason; by = $By }) }
        $items = @($Ctx.Items)
        $plan = @{}
        $planSha = @{}
        foreach ($p in @($Pf.Plan)) { $plan[[int]$p.Id] = [string]$p.Action; $planSha[[int]$p.Id] = [string]$p.Sha }
        foreach ($it in @($items | Sort-Object { [int]$_.Id } -Descending)) {
            $action = [string]$plan[[int]$it.Id]
            if ($action -ne 'None') { $failedItem = [int]$it.Id; DgTx-RestoreItem $Ctx $it $action ([string]$planSha[[int]$it.Id]); $failedItem = -1 }
        }
        foreach ($it in $items) { if (DgFs-Exists $it.Tmp) { DgG-Delete $Ctx $it.Tmp 'Tmp' } }
        if (DgFs-Exists $Ctx.NewStateTmp) { DgG-Delete $Ctx $Ctx.NewStateTmp 'Infra' }
        foreach ($it in @($items | Sort-Object { [int]$_.Id } -Descending)) {
            if (-not $it.HasIntent) { continue }
            $dirs = @($it.Dirs)
            for ($i = $dirs.Count - 1; $i -ge 0; $i--) { [void](DgG-RemoveDirIfEmpty $Ctx $dirs[$i] 'Dir') }
        }
        if (-not $sum.RollbackComplete) { DgTx-Journal $Ctx 'RollbackComplete' ([ordered]@{}); $ended = $true }
        DgTx-Finalize $Ctx 'rolledback'
        return @{ Outcome = 'RolledBack'; Error = ''; Code = ''; Reasons = [object[]]@(); ManualCheckRequired = $false }
    } catch {
        $code = DgError-Code $_.Exception
        if ($code.Length -eq 0) { $code = 'RestoreFailed' }
        $message = [string](DgError-Root $_.Exception).Message
        $why = [pscustomobject]@{ Code = $code; Item = $failedItem; Detail = $message }   # not $reason: variable names are case-insensitive and $Reason is a [string] parameter
        $manual = (@('DestinationChangedAfterPreflight', 'JournalChangedAfterRead') -contains $code)
        # record why the restore stopped (best effort), keep the marker and the journal, and leave a report for the operator
        if ($null -ne $Ctx.Journal) {
            if (-not $ended) { try {
                $inc = New-Object System.Collections.Specialized.OrderedDictionary
                $inc.Add('itemId',$failedItem)
                if ($failedItem -ge 0) { $inc.Add('path',[string]$Ctx.Items[$failedItem].Path); $inc.Add('normalizedPath',[string]$Ctx.Items[$failedItem].Norm) }
                $inc.Add('code',$code); $inc.Add('detail',$message)
                DgTx-Journal $Ctx 'RollbackIncomplete' $inc
            } catch {} }
            try { DgJournal-Close $Ctx.Journal } catch {}
            $Ctx.Journal = $null
        }
        $reportPath = ''
        if ($manual) {
            $repPf = @{ TxnId = $Ctx.TxnId; Operation = $Ctx.Operation; Reasons = @($why); Summary = $Pf.Summary }
            $reportPath = [string](DgTx-WriteReport $repPf $Ctx.StateRoot $Ctx.BackupRoot 'RollbackIncomplete (manual check required)')
        }
        return @{ Outcome = 'RollbackIncomplete'; Error = $message; Code = $code; Reasons = [object[]]@($why); ManualCheckRequired = $manual; ReportPath = $reportPath }
    }
}
function DgTx-WriteReport {
    param([hashtable]$Pf,[string]$StateRoot,[string]$BackupRoot,[string]$Outcome)
    if ([string]::IsNullOrEmpty([string]$Pf.TxnId)) { return '' }
    $txnDir = [System.IO.Path]::Combine($StateRoot,'txn',$Pf.TxnId)
    if (-not (DgFs-DirExists $txnDir)) { return '' }
    $path = [System.IO.Path]::Combine($txnDir,'recovery-report.txt')
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('DenGo installer recovery report')
    [void]$lines.Add('Outcome: ' + $Outcome)
    [void]$lines.Add('TransactionId: ' + $Pf.TxnId)
    [void]$lines.Add('Operation: ' + $Pf.Operation)
    if ($Outcome -like 'RepairRequired*') { [void]$lines.Add('Nothing was changed by recovery. Restore the listed files manually from the backups, or contact support.') }
    else { [void]$lines.Add('Recovery stopped. Files restored before the stop are listed in the journal (RolledBack records); the file named below was NOT touched. Check it by hand, then run recovery again.') }
    foreach ($r in @($Pf.Reasons)) { [void]$lines.Add(('Reason: {0} item={1} {2}' -f $r.Code,$r.Item,$r.Detail)) }
    if ($null -ne $Pf.Summary) { foreach ($it in @($Pf.Summary.Items)) { [void]$lines.Add(('Item {0}: {1} backup={2}' -f $it.Id,$it.Norm,$it.Backup)) } }
    $ctx = @{ Allowed = @{ Infra = @{} } }
    $ctx.Allowed.Infra[([System.IO.Path]::GetFullPath($path)).ToUpperInvariant()] = $true
    try { DgG-WriteText $ctx $path ([string]::Join("`r`n",[string[]]@($lines))); return $path } catch { return '' }
}

# ---------------------------------------------------------------- Rollback (runtime) / Recover
function DgTx-Rollback {
    param([hashtable]$Ctx,[string]$Reason)
    $Ctx.InRollback = $true
    if ($null -ne $Ctx.Journal) { try { DgJournal-Close $Ctx.Journal } catch {} ; $Ctx.Journal = $null }
    try { $pf = DgTx-Preflight $Ctx.StateRoot $Ctx.BackupRoot $Ctx.Policy }
    catch { return [pscustomobject]@{ Outcome = 'RollbackIncomplete'; Reasons = [object[]]@(); TransactionId = $Ctx.TxnId; ReportPath = ''; Error = ('Preflight failed: ' + [string]$_.Exception.Message); ManualCheckRequired = $false } }
    if (-not $pf.Ok -or $pf.Region -eq 'NoMarker') {
        $report = DgTx-WriteReport $pf $Ctx.StateRoot $Ctx.BackupRoot 'RepairRequired'
        return [pscustomobject]@{ Outcome = 'RepairRequired'; Reasons = [object[]]@($pf.Reasons); TransactionId = $Ctx.TxnId; ReportPath = $report; Error = ''; ManualCheckRequired = $true }
    }
    $rc = DgTx-ContextFromPreflight $pf $Ctx.Policy $true
    try { $rc.Journal = DgJournal-OpenTruncate $rc.JournalPath $pf.Parse.ValidLength $pf.Parse.TotalLength }
    catch {
        $c = DgError-Code $_.Exception; if ($c.Length -eq 0) { $c = 'JournalOpenFailed' }
        $why = [pscustomobject]@{ Code = $c; Item = -1; Detail = [string](DgError-Root $_.Exception).Message }
        return [pscustomobject]@{ Outcome = 'RollbackIncomplete'; Reasons = [object[]]@($why); TransactionId = $Ctx.TxnId; ReportPath = ''; Error = $why.Detail; ManualCheckRequired = ($c -eq 'JournalChangedAfterRead') }
    }
    $x = DgTx-ExecuteRecovery $pf $rc 'apply' $Reason
    return [pscustomobject]@{ Outcome = $x.Outcome; Reasons = [object[]]@($x.Reasons); TransactionId = $Ctx.TxnId; ReportPath = [string](DgProp $x 'ReportPath' ''); Error = $x.Error; ManualCheckRequired = [bool]$x.ManualCheckRequired }
}
function DgTx-Recover {
    param([string]$StateRoot,[string]$BackupRoot,[object]$Policy)
    # The roots are validated against the caller's path policy BEFORE anything is read or deleted.
    foreach ($rootPair in @(@('stateRoot',$StateRoot),@('backupRoot',$BackupRoot))) {
        $rootTest = $null
        try { $rootTest = DgPolicy-TestPath $Policy $rootPair[1] } catch { $rootTest = $null }
        if ($null -eq $rootTest -or -not $rootTest.Allowed) {
            $why = [pscustomobject]@{ Code = 'PathRejected'; Item = -1; Detail = ($rootPair[0] + ' is rejected by the path policy: ' + $(if ($null -ne $rootTest) { $rootTest.Reason } else { 'PathInvalid' })) }
            return [pscustomobject]@{ Outcome = 'RepairRequired'; Reasons = [object[]]@($why); TransactionId = ''; Operation = ''; Region = ''; ReportPath = ''; Error = ''; CleanupRefused = [string[]]@(); ManualCheckRequired = $true }
        }
    }
    try { $pf = DgTx-Preflight $StateRoot $BackupRoot $Policy }
    catch {
        # Phase 1 is read-only: an unexpected failure here changed nothing.
        $reason = [pscustomobject]@{ Code = 'PreflightException'; Item = -1; Detail = [string]$_.Exception.Message }
        return [pscustomobject]@{ Outcome = 'RepairRequired'; Reasons = [object[]]@($reason); TransactionId = ''; Operation = ''; Region = ''; ReportPath = ''; Error = ''; CleanupRefused = [string[]]@(); ManualCheckRequired = $true }
    }
    if ($pf.Ok -and $pf.Region -eq 'NoMarker') {
        $clean = DgTx-CleanOrphanMarkerTemps $StateRoot $Policy
        return [pscustomobject]@{ Outcome = 'NotNeeded'; Reasons = [object[]]@(); TransactionId = ''; Operation = ''; Region = 'NoMarker'; ReportPath = ''; Error = ''; CleanupRefused = [string[]]@($clean.Refused); ManualCheckRequired = $false }
    }
    if (-not $pf.Ok) {
        $report = DgTx-WriteReport $pf ([System.IO.Path]::GetFullPath($StateRoot)) ([System.IO.Path]::GetFullPath($BackupRoot)) 'RepairRequired'
        return [pscustomobject]@{ Outcome = 'RepairRequired'; Reasons = [object[]]@($pf.Reasons); TransactionId = $pf.TxnId; Operation = $pf.Operation; Region = $pf.Region; ReportPath = $report; Error = ''; CleanupRefused = [string[]]@(); ManualCheckRequired = $true }
    }
    $ctx = DgTx-ContextFromPreflight $pf $Policy $true
    try { $ctx.Journal = DgJournal-OpenTruncate $ctx.JournalPath $pf.Parse.ValidLength $pf.Parse.TotalLength }
    catch {
        $c = DgError-Code $_.Exception; if ($c.Length -eq 0) { $c = 'JournalOpenFailed' }
        $why = [pscustomobject]@{ Code = $c; Item = -1; Detail = [string](DgError-Root $_.Exception).Message }
        return [pscustomobject]@{ Outcome = 'RollbackIncomplete'; Reasons = [object[]]@($why); TransactionId = $pf.TxnId; Operation = $pf.Operation; Region = $pf.Region; ReportPath = ''; Error = $why.Detail; CleanupRefused = [string[]]@(); ManualCheckRequired = ($c -eq 'JournalChangedAfterRead') }
    }
    $x = DgTx-ExecuteRecovery $pf $ctx 'recovery' 'Recovery'
    return [pscustomobject]@{ Outcome = $x.Outcome; Reasons = [object[]]@($x.Reasons); TransactionId = $pf.TxnId; Operation = $pf.Operation; Region = $pf.Region; ReportPath = [string](DgProp $x 'ReportPath' ''); Error = $x.Error; CleanupRefused = [string[]]@(); ManualCheckRequired = [bool]$x.ManualCheckRequired }
}
# Removes the two fixed-name orphan marker temporaries - and nothing else - after every safety condition holds.
# Returns @{ Deleted = names; Refused = "name: reason" } ; a refused target is never touched.
function DgTx-CleanOrphanMarkerTemps {
    param([string]$StateRoot,[object]$Policy)
    $deleted = New-Object System.Collections.ArrayList
    $refused = New-Object System.Collections.ArrayList
    $t = $null
    try { $t = DgPolicy-TestPath $Policy $StateRoot } catch { $t = $null }
    if ($null -eq $t -or -not $t.Allowed) { [void]$refused.Add('StateRoot: rejected by the path policy'); return @{ Deleted = [string[]]@(); Refused = [string[]]@($refused) } }
    if (@($t.Reparse).Count -ne 0) { [void]$refused.Add('StateRoot: reparse point in the path'); return @{ Deleted = [string[]]@(); Refused = [string[]]@($refused) } }
    $sr = $t.Normalized
    $cleanCtx = @{ Policy = $Policy; Allowed = @{ Infra = @{} } }
    foreach ($n in @('installing.json.tmp','uninstalling.json.tmp')) {
        $p = [System.IO.Path]::Combine($sr,$n)
        if (-not (DgEqI ([System.IO.Path]::GetDirectoryName($p)) $sr)) { [void]$refused.Add($n + ': not directly below the state root'); continue }
        if (DgFs-DirExists $p) { [void]$refused.Add($n + ': is a directory'); continue }
        if (-not (DgFs-Exists $p)) { continue }
        $rp = DgFs-GetReparseComponents $p $sr
        if (@($rp).Count -ne 0) { [void]$refused.Add($n + ': is a reparse point'); continue }
        $cleanCtx.Allowed.Infra[$p.ToUpperInvariant()] = $true
        try { DgG-Delete $cleanCtx $p 'Infra'; [void]$deleted.Add($n) } catch { [void]$refused.Add($n + ': ' + [string](DgError-Root $_.Exception).Message) }
    }
    return @{ Deleted = [string[]]@($deleted); Refused = [string[]]@($refused) }
}

# ---------------------------------------------------------------- Commit / Run
function DgTx-Commit {
    param([hashtable]$Ctx,[byte[]]$NewStateBytes)
    $newSha = DgSha256-Bytes $NewStateBytes
    $current = ''
    if (DgFs-Exists $Ctx.NewStatePath) { $current = DgFs-Sha256 $Ctx.NewStatePath }
    if (-not (DgEq $current $Ctx.OldStateSha)) { throw (DgError 'PlanStale' 'The state file changed since planning.') }
    if (DgFs-Exists $Ctx.NewStateTmp) { DgG-Delete $Ctx $Ctx.NewStateTmp 'Infra' }
    DgG-CreateFile $Ctx $Ctx.NewStateTmp $NewStateBytes 'Infra'
    if (-not (DgEq (DgFs-Sha256 $Ctx.NewStateTmp) $newSha)) { throw (DgError 'CommitFailed' 'State temporary SHA mismatch.') }
    DgTx-Journal $Ctx 'CommitIntent' ([ordered]@{ newStatePath = $Ctx.NewStatePath; newStateTmp = $Ctx.NewStateTmp; newStateSha = $newSha })
    if (DgFs-Exists $Ctx.NewStatePath) {
        DgFs-ProbeExclusive $Ctx.NewStatePath
        DgG-Replace $Ctx $Ctx.NewStateTmp $Ctx.NewStatePath 'Infra' 'Infra'
    } else {
        DgG-MoveNew $Ctx $Ctx.NewStateTmp $Ctx.NewStatePath 'Infra' 'Infra'
    }
    $Ctx.StateCommitted = $true
    if (-not (DgEq (DgFs-Sha256 $Ctx.NewStatePath) $newSha)) { throw (DgError 'CommitFailed' 'State SHA mismatch after commit.') }
    DgTx-Journal $Ctx 'Committed' ([ordered]@{})
    DgTx-Finalize $Ctx 'committed'
}
function DgTx-Run {
    param([string]$StateRoot,[string]$BackupRoot,[string]$Operation,[object[]]$Items,[object]$Policy,[string]$NewStatePath,[byte[]]$NewStateBytes = $null,[scriptblock]$NewStateFactory = $null,[string]$LockName = '',[string]$LockSecurity = 'Explicit',[switch]$AllowEmptyTransaction)
    $result = [pscustomobject]@{ Succeeded = $false; Code = ''; Message = ''; TransactionId = ''; RollbackState = 'NotStarted'; FailedItem = -1; Reasons = [object[]]@(); ManualCheckRequired = $false; ReportPath = '' }
    $lockHeld = $false
    if ($LockName.Length -gt 0) {
        $l = DgLock-TryAcquire $LockName $LockSecurity
        if (-not $l.Acquired) { $result.Code = 'AnotherOperationRunning'; $result.Message = $l.Reason; return $result }
        $lockHeld = $true
    }
    $ctx = $null
    try {
        try {
            # An empty transaction must still commit a new state through the factory; state bytes alone are not accepted.
            if (@($Items).Count -eq 0 -and $AllowEmptyTransaction -and $null -eq $NewStateFactory) { throw (DgError 'PlanInvalid' 'An empty transaction requires NewStateFactory.') }
            $ctx = DgTx-Begin $StateRoot $BackupRoot $Operation $Items $Policy $NewStatePath -AllowEmptyTransaction:$AllowEmptyTransaction
            $result.TransactionId = $ctx.TxnId
            DgTx-Apply $ctx
            $bytes = $NewStateBytes
            if ($null -ne $NewStateFactory) { $bytes = [byte[]](& $NewStateFactory $ctx) }
            if ($null -eq $bytes) { throw (DgError 'PlanInvalid' 'No state bytes or factory.') }
            DgTx-Commit $ctx $bytes
            $result.Succeeded = $true; $result.Code = 'OK'; $result.RollbackState = 'NotNeeded'
        } catch {
            $code = DgError-Code $_.Exception
            if ($code.Length -eq 0) { $code = 'ApplyFailed' }
            $result.Code = $code
            $result.Message = [string](DgError-Root $_.Exception).Message
            if ($null -ne $ctx -and -not $ctx.Closed) {
                if ($ctx.ContainsKey('FailedItem')) { $result.FailedItem = [int]$ctx.FailedItem }
                $markerThere = $true
                try { $markerThere = DgFs-Exists $ctx.MarkerPath } catch {}
                if ($markerThere) {
                    try { $rb = DgTx-Rollback $ctx $code }
                    catch { $rb = [pscustomobject]@{ Outcome = 'RollbackIncomplete'; Reasons = [object[]]@(); TransactionId = $ctx.TxnId; ReportPath = ''; Error = [string]$_.Exception.Message; ManualCheckRequired = $false } }
                    $result.RollbackState = $rb.Outcome
                    $result.Reasons = [object[]]@($rb.Reasons)
                    $result.ManualCheckRequired = (($rb.Outcome -eq 'RepairRequired') -or [bool](DgProp $rb 'ManualCheckRequired' $false))
                    $result.ReportPath = [string](DgProp $rb 'ReportPath' '')
                    if ($rb.Outcome -eq 'RolledForward') { $result.Succeeded = $true; $result.Code = 'OK'; $result.Message = ('Committed (rolled forward after: ' + $code + ')') }
                } elseif ($ctx.StateCommitted) {
                    $result.Succeeded = $true; $result.Code = 'OK'; $result.RollbackState = 'NotNeeded'; $result.Message = 'Committed; post-commit cleanup incomplete.'
                } else { $result.RollbackState = 'NotStarted' }
            }
        }
    } finally {
        if ($lockHeld) { [void](DgLock-Release $LockName) }
    }
    return $result
}

# ---------------------------------------------------------------- classification (pure; lock liveness is an input)
function DgTx-Classify {
    param([string]$StateRoot,[bool]$LockHeld)
    $inst = DgFs-Exists ([System.IO.Path]::Combine($StateRoot,'installing.json'))
    $unin = DgFs-Exists ([System.IO.Path]::Combine($StateRoot,'uninstalling.json'))
    $stateExists = DgFs-Exists ([System.IO.Path]::Combine($StateRoot,'installed-state.json'))
    $state = 'Pristine'
    if ($LockHeld) { $state = 'Busy' }
    elseif ($inst -or $unin) { $state = 'Interrupted' }
    elseif ($stateExists) { $state = 'Installed' }
    return [pscustomobject]@{ State = $state; InstallingMarker = $inst; UninstallingMarker = $unin; StateFileExists = $stateExists; LockHeld = $LockHeld }
}

# ---------------------------------------------------------------- named mutex (isolated; not wired to any engine)
function DgLock-Registry {
    $v = Get-Variable -Name DgLockRegistry -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $v) { Set-Variable -Name DgLockRegistry -Scope Script -Value (@{}) ; $v = Get-Variable -Name DgLockRegistry -Scope Script }
    return $v.Value
}
function DgLock-NewSecurity {
    $sec = New-Object System.Security.AccessControl.MutexSecurity
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $adm = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)
    $sys = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid,$null)
    foreach ($sid in @($me,$adm,$sys)) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($sid,[System.Security.AccessControl.MutexRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Allow)))
    }
    return $sec
}
# Name includes the namespace prefix (Global\ or Local\), chosen by the caller (policy). Never waits.
function DgLock-TryAcquire {
    param([string]$Name,[string]$Security = 'Explicit')
    $reg = DgLock-Registry
    if ($reg.ContainsKey($Name)) { return [pscustomobject]@{ Acquired = $false; Reason = 'AlreadyHeldInProcess'; Name = $Name; Abandoned = $false } }
    $created = $false
    try {
        if ([string]::Equals($Security,'Explicit',[System.StringComparison]::Ordinal)) { $m = New-Object System.Threading.Mutex($false,$Name,[ref]$created,(DgLock-NewSecurity)) }
        else { $m = New-Object System.Threading.Mutex($false,$Name,[ref]$created) }
    } catch {
        $root = DgError-Root $_.Exception
        $reason = 'CreateFailed'
        if ($root -is [System.UnauthorizedAccessException]) { $reason = 'AccessDenied' }
        return [pscustomobject]@{ Acquired = $false; Reason = $reason; Name = $Name; Abandoned = $false }
    }
    $got = $false; $abandoned = $false
    try { $got = $m.WaitOne(0) }
    catch {
        $root = DgError-Root $_.Exception
        if ($root -is [System.Threading.AbandonedMutexException]) { $got = $true; $abandoned = $true } else { $m.Dispose(); throw }
    }
    if (-not $got) { $m.Dispose(); return [pscustomobject]@{ Acquired = $false; Reason = 'HeldByOther'; Name = $Name; Abandoned = $false } }
    $reg[$Name] = $m
    return [pscustomobject]@{ Acquired = $true; Reason = ''; Name = $Name; Abandoned = $abandoned }
}
function DgLock-Release {
    param([string]$Name)
    $reg = DgLock-Registry
    if (-not $reg.ContainsKey($Name)) { return $false }
    $m = $reg[$Name]
    try { $m.ReleaseMutex() } catch {}
    $m.Dispose()
    $reg.Remove($Name)
    return $true
}
