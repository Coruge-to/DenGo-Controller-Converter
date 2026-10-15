# I2-A static checks: syntax, encoding, structure of the core (functions only, I/O only in the primitive layer),
# banned constructs, required Windows-specific constructs, no product paths, and "no tracked file changed".
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')

$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$core = Join-Path $repo 'installer\scripts\DenGoInstallerTransaction.ps1'
$newFiles = @(
    'installer\scripts\DenGoInstallerTransaction.ps1', 'installer\tests\I2A.TestSupport.ps1', 'installer\tests\I2A.KillChild.ps1',
    'installer\tests\Test-DenGoInstaller-I2A-Static.ps1', 'installer\tests\Test-DenGoInstaller-I2A-Unit.ps1', 'installer\tests\Test-DenGoInstaller-I2A-Fault.ps1',
    'installer\tests\Test-DenGoInstaller-I2A-Kill.ps1', 'installer\tests\Test-DenGoInstaller-I2A-All.ps1')

# ---- S1 files, syntax, encoding
$missing = @($newFiles | Where-Object { -not [System.IO.File]::Exists((Join-Path $repo $_)) })
[void](Assert-I2A 'S1-eight-files' (($newFiles.Count -eq 8) -and ($missing.Count -eq 0)) ("the 8 new files exist" + $(if ($missing.Count -gt 0) { ': missing ' + ($missing -join ',') } else { '' })))
$parseBad = @(); $encBad = @()
foreach ($f in $newFiles) {
    $p = Join-Path $repo $f
    if (-not [System.IO.File]::Exists($p)) { continue }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { $parseBad += $f }
    $b = [System.IO.File]::ReadAllBytes($p)
    $hasBom = ($b.Length -ge 3) -and ($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF)
    $nonAscii = 0; for ($i = 3; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $nonAscii++ } }
    if ((-not $hasBom) -or ($nonAscii -ne 0)) { $encBad += ($f + '(bom=' + $hasBom + ',nonAscii=' + $nonAscii + ')') }
}
[void](Assert-I2A 'S1-parse' ($parseBad.Count -eq 0) ("PowerShell parser: 0 errors in all new files" + $(if ($parseBad.Count -gt 0) { ' - ' + ($parseBad -join ',') } else { '' })))
[void](Assert-I2A 'S1-encoding' ($encBad.Count -eq 0) ("UTF-8 BOM + ASCII-only body in all new files" + $(if ($encBad.Count -gt 0) { ' - ' + ($encBad -join ',') } else { '' })))

# ---- S2 core structure
$ast = Get-I2AScriptAst $core
$stmts = @($ast.EndBlock.Statements)
$nonFn = @($stmts | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
[void](Assert-I2A 'S2-functions-only' (($nonFn.Count -eq 0) -and ($null -eq $ast.ParamBlock) -and ($null -eq $ast.BeginBlock) -and ($null -eq $ast.ProcessBlock)) "the core contains $($stmts.Count) function definitions and no other top-level statement")
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$primitive = { param($name) ($name -like 'DgFs-*') -or (@('DgJournal-Open', 'DgJournal-OpenTruncate', 'DgJournal-Append', 'DgJournal-Close') -contains $name) -or ($name -like 'DgClock-*') -or ($name -like 'DgId-*') }

# ---- S3 I/O only through the primitive layer
$bannedTypes = @('System.IO.File', 'System.IO.Directory', 'System.IO.DriveInfo', 'System.Diagnostics.Process', 'System.IO.FileInfo', 'System.IO.DirectoryInfo', 'File', 'Directory')
$bannedCmds = @('Remove-Item', 'Copy-Item', 'Move-Item', 'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Get-Content', 'Get-FileHash', 'Get-ChildItem', 'Start-Sleep', 'Start-Process', 'Stop-Process', 'Get-Process', 'Invoke-Expression', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Test-Path', 'Get-Date')
$offenders = New-Object System.Collections.ArrayList
foreach ($fn in $fns) {
    if (& $primitive $fn.Name) { continue }
    foreach ($m in @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] }, $true))) {
        if ($bannedTypes -contains $m.TypeName.FullName) { [void]$offenders.Add($fn.Name + ' uses [' + $m.TypeName.FullName + ']') }
    }
    foreach ($c in @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $cn = [string]$c.GetCommandName()
        if ($bannedCmds -contains $cn) { [void]$offenders.Add($fn.Name + ' calls ' + $cn) }
        if (($cn -eq 'New-Object') -and ($c.Extent.Text -match 'System\.IO\.FileStream')) { [void]$offenders.Add($fn.Name + ' opens a FileStream directly') }
    }
}
[void](Assert-I2A 'S3-io-only-in-primitives' ($offenders.Count -eq 0) ("no file, process, clock or sleep access outside the primitive layer ($($fns.Count) functions scanned)" + $(if ($offenders.Count -gt 0) { ': ' + ($offenders -join '; ') } else { '' })))
$harnessNames = @($script:I2APrimitives | ForEach-Object { $_[0] })
$corePrims = @($fns | Where-Object { ($_.Name -like 'DgFs-*') -or (@('DgJournal-Open', 'DgJournal-OpenTruncate', 'DgJournal-Append', 'DgJournal-Close') -contains $_.Name) } | ForEach-Object { $_.Name })
$unwrapped = @($corePrims | Where-Object { $harnessNames -notcontains $_ })
$phantom = @($harnessNames | Where-Object { $corePrims -notcontains $_ })
[void](Assert-I2A 'S3-harness-covers-primitives' (($unwrapped.Count -eq 0) -and ($phantom.Count -eq 0)) ("the fault harness wraps exactly the $($corePrims.Count) primitives of the core" + $(if (($unwrapped.Count + $phantom.Count) -gt 0) { ' - unwrapped: ' + ($unwrapped -join ',') + ' phantom: ' + ($phantom -join ',') } else { '' })))

# ---- S4 banned text, required Windows constructs
$text = [System.IO.File]::ReadAllText($core)
$bannedText = [ordered]@{
    'File.Copy overwrite'     = '\[System\.IO\.File\]::Copy\('
    'recursive delete'        = '(?i)Directory\]::Delete\([^)]*\$true|-Recurse'
    'Remove-Item'             = 'Remove-Item'
    'process kill/exit'       = '(?i)\.Kill\(|Stop-Process|Environment\]::Exit|\bexit\b'
    'WriteAllText/Bytes'      = 'WriteAll(Text|Bytes)'
    'Get-FileHash'            = 'Get-FileHash'
}
foreach ($k in $bannedText.Keys) { [void](Assert-I2A ('S4-banned-' + ($k -replace '\W', '-')) (-not ($text -match $bannedText[$k])) ("the core does not contain: $k")) }
$productTokens = @(('Bve' + 'Ts'), ('Bve' + 'Ex'), ('PC' + 'SX2'), ('RP' + 'CS3'), ('Lily' + 'Pad'), ('Public' + '\Documents'), ('My' + 'Documents'), ('LOCAL' + 'APPDATA'), ('APP' + 'DATA'), ('Program' + 'Data'), ('HK' + 'CU'), ('HK' + 'LM'), ('HK' + 'EY'), ('Microsoft.' + 'Win32'), ('Uninstall' + '.exe'), ('C:\' + 'Users'), ('C:\' + 'Windows'))
$hits = @($productTokens | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
[void](Assert-I2A 'S4-no-product-paths' ($hits.Count -eq 0) ("no product path, registry or application name is hard-coded in the core" + $(if ($hits.Count -gt 0) { ': ' + ($hits -join ',') } else { '' })))
$replaceFn = @($fns | Where-Object { $_.Name -eq 'DgFs-Replace' })[0].Extent.Text
[void](Assert-I2A 'S4-replace-nullstring' (($replaceFn.IndexOf('[System.Management.Automation.Language.NullString]::Value') -ge 0) -and ($replaceFn -notmatch 'Replace\([^)]*\$null')) 'File.Replace is called with NullString.Value (never $null, which PowerShell turns into an illegal empty path)')
$probeFn = @($fns | Where-Object { $_.Name -eq 'DgFs-ProbeExclusive' })[0].Extent.Text
[void](Assert-I2A 'S4-probe-exclusive' (($probeFn.IndexOf('FileShare]::None') -ge 0) -and ($probeFn.IndexOf('FileAccess]::ReadWrite') -ge 0)) 'the exclusive probe opens ReadWrite with FileShare.None')
$flushCount = ([regex]::Matches($text, 'Flush\(\$true\)')).Count
[void](Assert-I2A 'S4-fsync' ($flushCount -ge 5) "Flush(`$true) (FlushFileBuffers) is used $flushCount times: journal append, durable file creation, durable copies, truncation")
$appendFn = @($fns | Where-Object { $_.Name -eq 'DgJournal-Append' })[0].Extent.Text
$openFn = @($fns | Where-Object { $_.Name -eq 'DgJournal-Open' })[0].Extent.Text
$readFn = @($fns | Where-Object { $_.Name -eq 'DgFs-ReadAllBytesShared' })[0].Extent.Text
[void](Assert-I2A 'S4-journal-flush-and-sharing' (($appendFn.IndexOf('Flush($true)') -ge 0) -and ($openFn.IndexOf('FileShare]::Read') -ge 0) -and ($openFn.IndexOf('CreateNew') -ge 0) -and ($readFn.IndexOf('FileShare]::ReadWrite') -ge 0)) 'journal: every record is flushed; one writer (FileShare.Read, CreateNew); readers use FileShare.ReadWrite')
$copyFn = @($fns | Where-Object { $_.Name -eq 'DgFs-CopyFileDurable' })[0].Extent.Text
[void](Assert-I2A 'S4-copy-createnew' (($copyFn.IndexOf('CreateNew') -ge 0) -and ($copyFn.IndexOf('Flush($true)') -ge 0) -and ($copyFn.IndexOf('File]::Copy') -lt 0)) 'copies are CreateNew + flushed streams (never File.Copy, never an overwrite)')
$tryFn = @($fns | Where-Object { $_.Name -eq 'DgLock-TryAcquire' })[0].Extent.Text
[void](Assert-I2A 'S4-mutex-no-wait' (($tryFn.IndexOf('WaitOne(0)') -ge 0) -and ($tryFn.IndexOf('Wait-') -lt 0)) 'the mutex is acquired without waiting (WaitOne(0))')
$evidenceFns = @($fns | Where-Object { @('DgTx-Classify', 'DgTx-Preflight', 'DgTx-Recover', 'DgTx-Rollback', 'DgTx-ExecuteRecovery') -contains $_.Name })
$abandonRef = @($evidenceFns | Where-Object { $_.Extent.Text -match 'Abandon' })
[void](Assert-I2A 'S4-abandon-not-evidence' ($abandonRef.Count -eq 0) 'interruption is decided from the marker and the journal only; mutex abandonment is not referenced by classification or recovery')
$restoreFn = @($fns | Where-Object { $_.Name -eq 'DgTx-RestoreItem' })[0].Extent.Text
$applyFn = @($fns | Where-Object { $_.Name -eq 'DgTx-ApplyItem' })[0].Extent.Text
[void](Assert-I2A 'S4-write-ahead-order' (($applyFn.IndexOf("'Intent'") -ge 0) -and ($applyFn.IndexOf("'Intent'") -lt $applyFn.IndexOf('DgG-Replace')) -and ($applyFn.IndexOf("'Intent'") -lt $applyFn.IndexOf('DgG-MoveNew')) -and ($applyFn.IndexOf("'Intent'") -lt $applyFn.IndexOf('DgG-Delete $Ctx $Item.Norm'))) 'the Intent record is appended before any Replace, MoveNew or Delete of a destination')
$prefn = @($fns | Where-Object { $_.Name -eq 'DgTx-Preflight' })[0].Extent.Text
$mutCalls = @([regex]::Matches($prefn, 'DgG-|DgFs-(Replace|MoveNew|Delete|CreateDir|CreateFileDurable|CopyFileDurable|WriteTextFile|RemoveDirIfEmpty)|DgJournal-(Open|Append)'))
[void](Assert-I2A 'S4-preflight-read-only' ($mutCalls.Count -eq 0) 'Phase 1 (DgTx-Preflight) contains no mutating call')

# ---- S7 pre-commit audit fixes (M1 M2 M3 L1 L2) are present and ordered correctly
function Get-FnText([string]$Name) { return (@($fns | Where-Object { $_.Name -eq $Name })[0].Extent.Text) }
$newFn = Get-FnText 'DgPolicy-New'; $testFn = Get-FnText 'DgPolicy-TestPath'
[void](Assert-I2A 'S7-reparse-mode-contract' (($text.IndexOf('product default is') -ge 0) -and ($newFn -match "PolicyInvalid") -and ($newFn.IndexOf("'Reject'") -ge 0) -and ($newFn.IndexOf("'RecordOnly'") -ge 0) -and ($newFn.IndexOf('$null -eq $ReparseMode') -ge 0)) 'M1: DgPolicy-New accepts only Reject/RecordOnly (null, empty and unknown values throw); the product-default contract is written in the core')
[void](Assert-I2A 'S7-reparse-fail-closed' (($testFn.IndexOf("-not [string]::Equals([string]`$Policy.ReparseMode,'RecordOnly'") -ge 0) -and ($testFn.IndexOf("'Reject',[System.StringComparison]") -lt 0)) 'M1: DgPolicy-TestPath rejects reparse points unless the mode is exactly RecordOnly (an unknown value can never disable the check)')
$rest = Get-FnText 'DgTx-RestoreItem'
$iRe = $rest.IndexOf('DgG-Replace'); $iMv = $rest.IndexOf('DgG-MoveNew'); $iDel = $rest.IndexOf('DgG-Delete $Ctx $Item.Norm')
$firstRe = $rest.IndexOf('DgTx-AssertUnchangedSincePreflight'); $lastRe = $rest.LastIndexOf('DgTx-AssertUnchangedSincePreflight')
[void](Assert-I2A 'S7-restore-recheck-order' (($firstRe -ge 0) -and ($firstRe -lt $iRe) -and (([regex]::Matches($rest, 'DgTx-AssertUnchangedSincePreflight')).Count -ge 3) -and ($lastRe -lt $iDel) -and ($rest.IndexOf('DgTx-AssertUnchangedSincePreflight $Item ''''') -lt $iMv)) 'M2: every Replace, MoveNew and Delete in DgTx-RestoreItem is preceded by a fresh measurement against the Phase-1 certified state')
$assertFn = Get-FnText 'DgTx-AssertUnchangedSincePreflight'
[void](Assert-I2A 'S7-restore-recheck-code' (($assertFn.IndexOf('DestinationChangedAfterPreflight') -ge 0) -and ($assertFn.IndexOf('DgFs-Sha256') -ge 0) -and ((Get-FnText 'DgTx-ExecuteRecovery').IndexOf('DestinationChangedAfterPreflight') -ge 0)) 'M2: the mismatch raises DestinationChangedAfterPreflight, which makes recovery stop with RollbackIncomplete and a manual-check flag')
$recover = Get-FnText 'DgTx-Recover'; $clean = Get-FnText 'DgTx-CleanOrphanMarkerTemps'
[void](Assert-I2A 'S7-cleanup-after-policy' (($recover.IndexOf('DgPolicy-TestPath') -ge 0) -and ($recover.IndexOf('DgPolicy-TestPath') -lt $recover.IndexOf('DgTx-Preflight')) -and ($recover.IndexOf('DgTx-Preflight') -lt $recover.IndexOf('DgTx-CleanOrphanMarkerTemps')) -and ($recover.IndexOf('DgG-Delete') -lt 0) -and ($clean.IndexOf('DgPolicy-TestPath') -ge 0) -and ($clean.IndexOf('Reparse') -ge 0) -and ($clean.IndexOf('DirExists') -ge 0)) 'M3: the path policy is applied before anything is read or deleted; the orphan-temporary cleanup lives in one function that also checks reparse points, directories and the fixed names')
$trunc = Get-FnText 'DgJournal-OpenTruncate'
[void](Assert-I2A 'S7-truncate-length-check' (($trunc.IndexOf('ExpectedLength') -ge 0) -and ($trunc.IndexOf('JournalChangedAfterRead') -ge 0) -and ($trunc.IndexOf('JournalChangedAfterRead') -lt $trunc.IndexOf('SetLength')) -and ((Get-FnText 'DgTx-Recover').IndexOf('TotalLength') -ge 0) -and ((Get-FnText 'DgTx-Rollback').IndexOf('TotalLength') -ge 0)) 'L2: the journal is truncated only after its current length is compared with the length Phase 1 read; both callers pass that length')
$gAssert = Get-FnText 'DgG-Assert'
$mutators = @('DgG-CopyFile', 'DgG-CreateFile', 'DgG-Replace', 'DgG-MoveNew', 'DgG-Delete', 'DgG-CreateDir', 'DgG-RemoveDirIfEmpty', 'DgG-WriteText')
$unguarded = @($mutators | Where-Object { (Get-FnText $_).IndexOf('DgG-Assert') -lt 0 })
[void](Assert-I2A 'S7-guard-covers-mutators' (($unguarded.Count -eq 0) -and ($gAssert.IndexOf('DgPolicy-TestPath') -ge 0) -and ($gAssert.IndexOf('PathNotRegistered') -ge 0)) "the guard applies the path policy and the registered-path check, and all $($mutators.Count) mutating wrappers call it")
$chk = Get-FnText 'DgPath-Check'; $res = Get-FnText 'DgPath-IsReservedName'
[void](Assert-I2A 'S7-reserved-names' (($chk.IndexOf('DgPath-IsReservedName') -ge 0) -and ($chk.IndexOf('PathTrailingDotOrSpace') -ge 0) -and ($res.IndexOf("'CON'") -ge 0) -and ($res.IndexOf("'PRN'") -ge 0) -and ($res.IndexOf("'AUX'") -ge 0) -and ($res.IndexOf("'NUL'") -ge 0) -and ($res.IndexOf('COM|LPT') -ge 0)) 'L1: every path segment is checked for Windows reserved device names (CON PRN AUX NUL COM1-9 LPT1-9, also with an extension) and for a trailing dot or space')
$outcomeLines = @(($text -split "`n") | Where-Object { $_ -match "(pscustomobject\]@\{|return @\{) Outcome = '" })
$noManual = @($outcomeLines | Where-Object { $_ -notmatch 'ManualCheckRequired' })
[void](Assert-I2A 'S7-result-objects-uniform' (($outcomeLines.Count -ge 10) -and ($noManual.Count -eq 0)) "all $($outcomeLines.Count) recovery/rollback result objects carry ManualCheckRequired (strict mode fails on a missing property)")
$unitText = [System.IO.File]::ReadAllText((Join-Path $repo 'installer\tests\Test-DenGoInstaller-I2A-Unit.ps1')); $faultText = [System.IO.File]::ReadAllText((Join-Path $repo 'installer\tests\Test-DenGoInstaller-I2A-Fault.ps1'))
$wanted = @(@($unitText, 'U10-invalid-modes-throw'), @($unitText, 'U11-device-names'), @($unitText, 'U12-outside-root-refused'), @($unitText, 'U13-guard-table'), @($faultText, 'M2-existing-edited'), @($faultText, 'M2-lock-before-restore'), @($faultText, "'shortened' = "), @($faultText, 'L2-$name'),@($faultText, 'OR-F3-partial-rollback-continued'), @($faultText, 'OR-$sc-oracle-agrees-with-run'))
$absent = @($wanted | Where-Object { $_[0].IndexOf($_[1]) -lt 0 } | ForEach-Object { $_[1] })
[void](Assert-I2A 'S7-tests-exist' ($absent.Count -eq 0) ('the tests for M1/M2/M3/L1/L2, the direct guard test and the independent expected trees are present' + $(if ($absent.Count -gt 0) { ': missing ' + ($absent -join ',') } else { '' })))

# ---- S5 tests stay inside TEMP
$unsafe = New-Object System.Collections.ArrayList
$testTokens = @(('HK' + 'CU:'), ('HK' + 'LM:'), ('New-Item' + 'Property'), ('Set-Item' + 'Property'), ('LOCAL' + 'APPDATA'), ('Bve' + 'Ts.exe'), ('pc' + 'sx2'), ('rp' + 'cs3'), ('Program' + ' Files'), ('git ' + 'commit'), ('git ' + 'add'), ('git ' + 'push'))
foreach ($f in $newFiles) {
    if ($f -like '*Static.ps1') { continue }
    $p = Join-Path $repo $f; if (-not [System.IO.File]::Exists($p)) { continue }
    $t = [System.IO.File]::ReadAllText($p)
    foreach ($tok in $testTokens) { if ($t.IndexOf($tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$unsafe.Add($f + ':' + $tok) } }
}
[void](Assert-I2A 'S5-tests-touch-only-temp' ($unsafe.Count -eq 0) ("the new test files mention no registry, product application, install location or git write command" + $(if ($unsafe.Count -gt 0) { ': ' + ($unsafe -join ',') } else { '' })))

# ---- S6 no tracked file changed, only the 8 new files are untracked
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) { Add-I2AResult 'S6-git-clean' $true 'git not available: skipped' }
else {
    $status = @(& git -C $repo status --porcelain)
    $tracked = @($status | Where-Object { -not $_.StartsWith('??') })
    $untracked = @($status | Where-Object { $_.StartsWith('??') } | ForEach-Object { $_.Substring(3).Trim('"').Replace('/', '\') })
    $unexpected = @($untracked | Where-Object { ($_ -ne '.claude\') -and (@($newFiles | ForEach-Object { $_ }) -notcontains $_) })
    [void](Assert-I2A 'S6-no-tracked-change' ($tracked.Count -eq 0) ("git status shows no modified, staged, deleted or renamed tracked file" + $(if ($tracked.Count -gt 0) { ': ' + ($tracked -join '; ') } else { '' })))
    [void](Assert-I2A 'S6-only-new-files' ($unexpected.Count -eq 0) ("untracked files are limited to the 8 new files (and .claude\)" + $(if ($unexpected.Count -gt 0) { ': ' + ($unexpected -join '; ') } else { '' })))
    $diffStat = @(& git -C $repo diff --stat HEAD)
    [void](Assert-I2A 'S6-diff-empty' ($diffStat.Count -eq 0) 'git diff --stat HEAD is empty')
}
Complete-I2ATests
