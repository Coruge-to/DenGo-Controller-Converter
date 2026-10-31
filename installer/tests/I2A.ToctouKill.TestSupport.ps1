# Shared helpers for the real-process kill tests of the I2-A TOCTOU contract (conditional replace / move-aside delete). ASCII only.
# Dot-source AFTER DenGoInstallerTransaction.ps1, I2A.TestSupport.ps1 and I2A.Toctou.TestSupport.ps1.
# Writes only below sandboxes under TEMP. Never touches product paths, the registry or any third-party application.
#
# The fixture is two items so that a kill can land inside each contract path:
#   item 0  R  Write over an existing file   (conditional Replace with a displaced name, pushed-aside SHA check, cleanup)
#   item 1  D  Delete of an existing file    (move aside, SHA check, Applied, cleanup, Verified)
# The kill points are never typed in: they are derived from a recorded run (every mutating primitive boundary and every journal append inside an item's span).
$script:KtUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:KtRepPre = 'OLD-REP'; $script:KtRepPost = 'NEW-REP'; $script:KtDelPre = 'OLD-DEL'

function Get-KtLayout([string]$Root) {
    $dest = Join-Path $Root 'Dest'
    $items = @(
        @{ Op = 'Write'; Destination = (Join-Path $dest 'r\rep.dll'); Source = (Join-Path $Root 'Src\0.src'); OwnershipCandidate = 'CreatedByInstaller'; Tag = 'R' },
        @{ Op = 'Delete'; Destination = (Join-Path $dest 'd\del.dll'); Source = ''; OwnershipCandidate = 'CreatedByInstaller'; Tag = 'D' })
    return [pscustomobject]@{
        Root = $Root; Dest = $dest; State = (Join-Path $Root 'State'); Backup = (Join-Path $Root 'Backup'); StatePath = (Join-Path $Root 'State\installed-state.json')
        Policy = (DgPolicy-New @($Root) 'Reject'); Items = $items; RepDest = (Join-Path $dest 'r\rep.dll'); DelDest = (Join-Path $dest 'd\del.dll')
    }
}
function New-KtFixture([string]$Root) {
    $l = Get-KtLayout $Root
    foreach ($d in 'Src', 'Dest\r', 'Dest\d', 'State', 'Backup') { [System.IO.Directory]::CreateDirectory((Join-Path $Root $d)) | Out-Null }
    [System.IO.File]::WriteAllText($l.RepDest, $script:KtRepPre, $script:KtUtf8)
    [System.IO.File]::WriteAllText($l.DelDest, $script:KtDelPre, $script:KtUtf8)
    [System.IO.File]::WriteAllText((Join-Path $Root 'Src\0.src'), $script:KtRepPost, $script:KtUtf8)
    [System.IO.File]::WriteAllText($l.StatePath, 'state-v1', $script:KtUtf8)
    return $l
}
function Invoke-KtRun($L) {
    return (DgTx-Run -StateRoot $L.State -BackupRoot $L.Backup -Operation 'Install' -Items $L.Items -Policy $L.Policy -NewStatePath $L.StatePath -NewStateBytes ($script:KtUtf8.GetBytes('state-v2')))
}
function Invoke-KtRecover($L) { return (DgTx-Recover -StateRoot $L.State -BackupRoot $L.Backup -Policy $L.Policy) }
function Get-KtManaged([string]$Root) { return (Get-I2ATreeMap $Root @('backup', 'state\txn', 'state\history')) }
function Get-KtResidue([string]$Root) {
    $out = New-Object System.Collections.ArrayList
    foreach ($f in [System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($f.EndsWith('.dengo.old', [System.StringComparison]::OrdinalIgnoreCase) -or $f.EndsWith('.dengo.tmp', [System.StringComparison]::OrdinalIgnoreCase)) { [void]$out.Add($f.Substring($Root.Length)) }
    }
    return @($out.ToArray())
}
function Get-KtJournalCount($L) {
    $b = Join-Path $L.State 'txn'
    if (-not [System.IO.Directory]::Exists($b)) { return 0 }
    return @([System.IO.Directory]::GetFiles($b, 'journal.jsonl', [System.IO.SearchOption]::AllDirectories)).Count
}
# Every file below the sandbox (except the Src copy and the backups) whose text equals $Text: where did a third party's content end up?
function Find-KtContent([string]$Root, [string]$Text) {
    $hits = New-Object System.Collections.ArrayList
    foreach ($f in [System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($f.Length -gt 250) { continue }
        try {
            $fs = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { $t = (New-Object System.IO.StreamReader($fs, $script:KtUtf8)).ReadToEnd() } finally { $fs.Dispose() }
            if ($t -ceq $Text) { [void]$hits.Add($f.Substring($Root.Length)) }
        } catch { }
    }
    return @($hits.ToArray())
}

# ---------------------------------------------------------------- primitive call log (recorded around the fault harness; the harness itself is not modified)
$global:KtLog = New-Object System.Collections.ArrayList
$global:KtRecord = $false
$global:KtPrev = (Get-Command Invoke-I2APoint -CommandType Function).ScriptBlock
function global:Invoke-I2APoint([string]$Name, [string]$Label, [bool]$Mut) {
    if ($global:KtRecord -and $Mut -and $Label.StartsWith('before:', [System.StringComparison]::Ordinal) -and ($Name -ne 'DgJournal-Append')) {
        [void]$global:KtLog.Add(($Name + '|' + ((@($global:I2AFH.LastArgs) | ForEach-Object { [string]$_ }) -join '|')))
    }
    & $global:KtPrev $Name $Label $Mut
}
function Start-KtLog { $global:KtLog = New-Object System.Collections.ArrayList; $global:KtRecord = $true }
function Stop-KtLog { $global:KtRecord = $false; return @($global:KtLog.ToArray()) }

# ---------------------------------------------------------------- kill points derived from a recorded run
# Returns one entry per mutating boundary label inside [From, To] (indexes into the full label list); Nth = the occurrence number of that exact label in the run.
function Get-KtPoints([string[]]$All, [string[]]$Mut, [int]$From, [int]$To) {
    $mutSet = @{}
    foreach ($m in $Mut) { $mutSet[$m] = $true }
    $seen = @{}
    $pts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $All.Count; $i++) {
        $lab = $All[$i]
        if ($seen.ContainsKey($lab)) { $seen[$lab]++ } else { $seen[$lab] = 1 }
        if ($i -lt $From -or $i -gt $To) { continue }
        if (-not $mutSet.ContainsKey($lab)) { continue }
        [void]$pts.Add([pscustomobject]@{ Index = $i; Label = $lab; Nth = $seen[$lab]; Pattern = ('^' + [regex]::Escape($lab) + '$') })
    }
    return @($pts.ToArray())
}
