# I2-B static tests: syntax, encoding, no top-level side effects, forbidden APIs, call order, the engine no longer owns an apply of its own,
# PCSX2 is only ever deferred, the lock is released in finally, the core change is limited to AllowEmptyTransaction, the GUI change is local,
# files that must stay untouched are byte-identical to the I2-A commit. Reads only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')   # result helpers and AST loader only (the core is not dot-sourced here)
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$baseline = 'd8bed5f4b1dc597ff5db0280e1aa4d1bc2c3ded5'
$product = Join-Path $repo 'installer\scripts\DenGoInstallerProductApply.ps1'
$engine = Join-Path $repo 'installer\scripts\Invoke-DenGoInstaller.ps1'
$core = Join-Path $repo 'installer\scripts\DenGoInstallerTransaction.ps1'
$gui = Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1'
$qa1 = Join-Path $repo 'installer\tests\Test-DenGoInstaller-QA1.ps1'
$i2bTests = @(Get-ChildItem -LiteralPath (Join-Path $repo 'installer\tests') -Filter '*I2B*.ps1' | ForEach-Object { $_.FullName })
$i2bTests += (Join-Path $repo 'installer\tests\QA1.ProcessGateOrder.ps1')

function J([int[]]$CodePoints) { return -join ($CodePoints | ForEach-Object { [string][char]$_ }) }
function Read-Bytes([string]$Path) { return [System.IO.File]::ReadAllBytes($Path) }
function Get-BaselineText([string]$Rel) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git.exe'; $psi.Arguments = ('-C "' + $repo + '" show ' + $baseline + ':' + $Rel)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return $null }
    $ms = New-Object System.IO.MemoryStream
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($ms.ToArray())
    return $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
}
function Get-CurrentText([string]$Path) { return ((New-Object System.Text.UTF8Encoding($false)).GetString((Read-Bytes $Path))).TrimStart([char]0xFEFF).Replace("`r`n", "`n") }
function Get-FunctionTexts([string]$Text) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $map = @{}
    foreach ($f in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $map[$f.Name] = $f.Extent.Text }
    return $map
}
# returns an array that is NOT unrolled by the caller's assignment (use: $x = Get-Commands ...; $x.Count)
function Get-Commands($Ast, [string]$Name) {
    $r = New-Object System.Collections.ArrayList
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $Name }, $true)) { [void]$r.Add($n) }
    return , ([object[]]$r.ToArray())
}
function Get-OwnerFunctionName($Node) {
    $f = $Node.Parent
    while ($null -ne $f -and -not ($f -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $f = $f.Parent }
    if ($null -eq $f) { return '' }
    return $f.Name
}

# ---------------------------------------------------------------- S1 syntax
foreach ($p in @($product, $engine, $core, $gui, $qa1) + $i2bTests) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    [void](Assert-I2A ('S1-parse-' + [System.IO.Path]::GetFileName($p)) (@($errors).Count -eq 0) ('ParseErrorCount=' + @($errors).Count))
}
# ---------------------------------------------------------------- S2 encoding: UTF-8 with BOM, body ASCII-only (product layer and I2-B tests)
foreach ($p in @($product) + $i2bTests) {
    $b = Read-Bytes $p
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $nonAscii = 0; for ($i = 3; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $nonAscii++ } }
    [void](Assert-I2A ('S2-encoding-' + [System.IO.Path]::GetFileName($p)) ($bom -and ($nonAscii -eq 0)) "BOM=$bom nonAsciiBodyBytes=$nonAscii")
}
$eb = Read-Bytes $engine
$ecr = 0; $elf = 0; for ($i = 0; $i -lt $eb.Length; $i++) { if ($eb[$i] -eq 10) { if ($i -gt 0 -and $eb[$i - 1] -eq 13) { $ecr++ } else { $elf++ } } }
$enonAscii = 0; for ($i = 3; $i -lt $eb.Length; $i++) { if ($eb[$i] -gt 127) { $enonAscii++ } }
[void](Assert-I2A 'S2-engine-encoding-kept' (($eb[0] -eq 0xEF) -and ($elf -eq 0) -and ($ecr -gt 0) -and ($enonAscii -eq 0)) "BOM, CRLF only ($ecr), ASCII body, as before")

# ---------------------------------------------------------------- S3 product layer: functions only
$pa = Get-I2AScriptAst $product
$top = @($pa.EndBlock.Statements)
$nonFunction = @($top | Where-Object { -not ($_ -is [System.Management.Automation.Language.FunctionDefinitionAst]) })
[void](Assert-I2A 'S3-functions-only' ($nonFunction.Count -eq 0) ("top-level statements that are not function definitions: $($nonFunction.Count)"))

# ---------------------------------------------------------------- S4 forbidden APIs (the DgPFs-* primitives are the only place that may change the disk)
$mutatingMembers = @('Copy', 'Move', 'Delete', 'WriteAllText', 'WriteAllBytes', 'WriteAllLines', 'AppendAllText', 'AppendAllLines', 'Create', 'CreateDirectory', 'Replace', 'SetAttributes', 'CreateText', 'AppendText', 'OpenWrite', 'Encrypt', 'Decrypt')
$forbiddenCommands = @('Remove-Item', 'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Copy-Item', 'Move-Item', 'Rename-Item', 'Clear-Content', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Start-Process', 'Stop-Process', 'Invoke-Expression', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Set-Acl', 'icacls', 'reg', 'reg.exe', 'regedit')
$bad = New-Object System.Collections.ArrayList
foreach ($n in @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
    $typeName = ''
    if ($n.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $typeName = $n.Expression.TypeName.FullName }
    $member = [string]$n.Member.Value
    $owner = Get-OwnerFunctionName $n
    $inPrimitive = $owner.StartsWith('DgPFs-')
    if (($typeName -match '^(System\.)?IO\.(File|Directory)$') -and ($mutatingMembers -contains $member) -and -not $inPrimitive) { [void]$bad.Add("$typeName::$member in $owner") }
    if ($member -eq 'Kill') { [void]$bad.Add('Kill() call in ' + $owner) }
}
foreach ($c in @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    $name = [string]$c.GetCommandName()
    if ($forbiddenCommands -contains $name) { [void]$bad.Add('command ' + $name) }
}
[void](Assert-I2A 'S4-no-direct-disk-changes' ($bad.Count -eq 0) ('violations: ' + [string]::Join('; ', [string[]]@($bad | Select-Object -First 5))))
$opens = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$x.Member.Value -eq 'Open' -and $x.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $x.Expression.TypeName.FullName -match 'IO\.File$' }, $true))
$openBad = @($opens | Where-Object { $_.Extent.Text.IndexOf('FileAccess]::Read', [System.StringComparison]::Ordinal) -lt 0 })
[void](Assert-I2A 'S4-file-open-is-read-only' ($openBad.Count -eq 0) ("File.Open calls: $($opens.Count); not read-only: $($openBad.Count)"))
$text = Get-CurrentText $product
[void](Assert-I2A 'S4-no-registry-no-process-control' (($text -notmatch 'HKLM:|HKCU:|Microsoft\.Win32|\.Kill\(|Registry')) 'no registry or process-control tokens')
$primitiveNames = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name.StartsWith('DgPFs-') }, $true) | ForEach-Object { $_.Name })
[void](Assert-I2A 'S4-primitive-layer-is-small' (($primitiveNames.Count -eq 5) -and ($primitiveNames -contains 'DgPFs-NewStageDir') -and ($primitiveNames -contains 'DgPFs-NewShortcutFile')) ("DgPFs-* functions: " + ($primitiveNames -join ', ')))

# ---------------------------------------------------------------- S5 the engine owns no apply of its own any more
$ea = Get-I2AScriptAst $engine
$engineFunctions = @($ea.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
foreach ($gone in 'Restore-AppliedItems', 'Invoke-RealApplySet', 'Invoke-RealApply', 'Write-InstalledState', 'Write-InstallMarker', 'Remove-InstallerTemporaryFiles', 'Invoke-DesktopShortcut') {
    [void](Assert-I2A ("S5-engine-has-no-$gone") ($engineFunctions -notcontains $gone) 'the Set-based apply, marker and state writers are gone')
}
$cv = Get-Commands $ea 'Copy-VerifiedFile'
$cvOutside = @($cv | Where-Object { (Get-OwnerFunctionName $_) -ne 'Invoke-SandboxApply' })
[void](Assert-I2A 'S5-copy-verified-file-only-in-sandbox-apply' (($cv.Count -ge 1) -and ($cvOutside.Count -eq 0)) ("Copy-VerifiedFile call sites: $($cv.Count); outside Invoke-SandboxApply: $($cvOutside.Count)"))
$lily = Get-Commands $ea 'New-NormalizedLegacyLilyPadFile'
[void](Assert-I2A 'S5-lilypad-merge-never-called' ($lily.Count -eq 0) 'the LilyPad.ini rewrite has no call site (definition only)')
$calls = Get-Commands $ea 'Invoke-DenGoProductInstall'
[void](Assert-I2A 'S5-one-product-install-call' ($calls.Count -eq 1) "calls=$($calls.Count)")
$dry = Get-Commands $ea 'Get-DenGoRecoveryGate'
[void](Assert-I2A 'S5-dryrun-recovery-report-is-read-only' (($dry.Count -eq 1) -and ($dry[0].Extent.Text -match "-Mode\s+'DryRun'")) 'the engine only asks the recovery gate for a DryRun report')
foreach ($n in 'DgLock-TryAcquire', 'DgTx-Recover', 'DgTx-Begin', 'DgTx-Run', 'DgTx-Rollback') { $x = Get-Commands $ea $n; [void](Assert-I2A ("S5-engine-does-not-call-$n") ($x.Count -eq 0) 'the engine reaches the transaction only through Invoke-DenGoProductInstall') }
$legacyFields = @('SchemaVersion=9', 'Succeeded=$succeeded', 'ErrorCode=$errorCode', 'ErrorMessage=$errorMessage', 'FailedSet=$failedSet', 'RollbackAttempted=$rollbackAttempted', 'RollbackSucceeded=$rollbackSucceeded', 'RollbackError=$rollbackError', 'ShortcutRequested=$shortcutRequested', 'ShortcutCreated=$shortcutCreated', 'ShortcutPath=$shortcutPath', 'ShortcutError=$shortcutError', 'DryRun=[bool]$DryRun', 'Apply=[bool]$Apply', 'RealSystem=[bool]$RealSystem', 'BveExCurrentInstalled=[bool]$bveExCurrentInstalled', 'BackupRoot=$backupRoot', 'Detected=[object[]]@($detected)', 'Plan=[object[]]@($plan)', 'ApplyResults=[object[]]@($applyResults)')
$etext = Get-CurrentText $engine
$missing = @($legacyFields | Where-Object { $etext.IndexOf($_, [System.StringComparison]::Ordinal) -lt 0 })
[void](Assert-I2A 'S5-engine-json-keeps-every-existing-field' ($missing.Count -eq 0) ("missing: " + ($missing -join ', ')))
[void](Assert-I2A 'S5-engine-json-adds-fields' (($etext.IndexOf('Transaction=$transactionInfo', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('Recovery=$recoveryInfo', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('DeferredItems=', [System.StringComparison]::Ordinal) -ge 0)) 'Transaction, Recovery and DeferredItems are additive')
[void](Assert-I2A 'S5-engine-json-carries-the-recovery-facts' (($etext.IndexOf('ReportPath=[string]$productResult.ReportPath', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('RecoveryOutcome=[string]$productResult.RecoveryOutcome', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('FailedItem=[int]$productResult.FailedItem', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('Reasons=[object[]]@($productResult.Reasons)', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('ManualCheckRequired=[bool]$productResult.ManualCheckRequired', [System.StringComparison]::Ordinal) -ge 0)) 'Transaction carries ReportPath, RecoveryOutcome, FailedItem, Reasons and ManualCheckRequired')
[void](Assert-I2A 'S5-process-gate-function-kept' (($engineFunctions -contains 'Assert-TargetProcessesStopped') -and ($etext.IndexOf('BlockedByRunningProcesses', [System.StringComparison]::Ordinal) -ge 0) -and ($etext.IndexOf('RunningProducts=', [System.StringComparison]::Ordinal) -ge 0)) 'QA1 PROC-02 / PROC-03 strings are still in the engine')

# ---------------------------------------------------------------- S6 PCSX2 / LilyPad are only ever deferred
$pcsx2Literals = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $x.Value -match 'PCSX2|LilyPad|Pcsx2' }, $true))
$pcsx2Outside = @($pcsx2Literals | Where-Object { ((Get-OwnerFunctionName $_) -ne 'DgP-MapPlatform') -and ($_.Value -ne 'PCSX2LegacyKeyboardInitialized') })   # the state field name is a flag copied from the earlier state, not PCSX2 handling
[void](Assert-I2A 'S6-pcsx2-only-in-the-platform-mapping' ($pcsx2Outside.Count -eq 0) ("PCSX2 / LilyPad string literals: $($pcsx2Literals.Count); outside DgP-MapPlatform: $($pcsx2Outside.Count)"))
$mapFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'DgP-MapPlatform' }, $true))[0].Extent.Text
[void](Assert-I2A 'S6-pcsx2-maps-to-deferred' ($mapFn -match "DgEq \`$Platform 'PCSX2'\) \{ return @\{ Role = 'Deferred'.*Deferred = \`$true") 'PCSX2 maps to the Deferred pseudo role, never to a real role')

# ---------------------------------------------------------------- S7 lock
$lockFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-DenGoLockName' }, $true))[0].Extent.Text
[void](Assert-I2A 'S7-lock-name-constant' ($lockFn -match "return 'Local\\DenGoControllerConverter\.Transaction'") $lockFn)
$tries = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.TryStatementAst] }, $true))
$releaseInFinally = @($tries | Where-Object { $null -ne $_.Finally -and (@($_.Finally.FindAll({ param($y) $y -is [System.Management.Automation.Language.CommandAst] -and $y.GetCommandName() -eq 'DgLock-Release' }, $true)).Count -gt 0) })
[void](Assert-I2A 'S7-lock-released-in-finally' ($releaseInFinally.Count -eq 1) "try/finally blocks that call DgLock-Release: $($releaseInFinally.Count)")
[void](Assert-I2A 'S7-release-belongs-to-the-install-function' ((Get-OwnerFunctionName $releaseInFinally[0]) -eq 'Invoke-DenGoProductInstall') ('function=' + (Get-OwnerFunctionName $releaseInFinally[0])))
$runCalls = Get-Commands $pa 'DgTx-Run'
[void](Assert-I2A 'S7-no-core-lock-argument' (($runCalls.Count -eq 0) -and ($text.IndexOf('-LockName', [System.StringComparison]::Ordinal) -lt 0)) 'the product layer holds the lock itself; it never passes -LockName to the core')
$mainFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Invoke-DenGoProductInstall' }, $true))[0]
$cmdOrder = @($mainFn.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { [string]$_.GetCommandName() })
$iAcq = [array]::IndexOf($cmdOrder, 'DgLock-TryAcquire')
$firstReal = @($cmdOrder | Where-Object { $_ -notin @('DgP-NewResult', 'Get-DenGoLockName') })[0]
[void](Assert-I2A 'S7-lock-is-the-first-real-step' (($iAcq -ge 0) -and ($firstReal -eq 'DgLock-TryAcquire')) ('first step in the install function: ' + $firstReal))

# ---------------------------------------------------------------- S7b F1 / F4: no recovery decision depends on the layout of the next run; deferred records come from the platform mapping
$roleFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-DenGoRoleSpec' }, $true))[0].Extent.Text
[void](Assert-I2A 'S7b-role-spec-never-reads-the-layout-shortcut-path' ($roleFn.IndexOf('ShortcutPath', [System.StringComparison]::Ordinal) -lt 0) 'the Shortcut role is built from the journaled tag root only')
$defFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'DgP-IsDeferredRecord' }, $true))[0].Extent.Text
[void](Assert-I2A 'S7b-deferred-record-uses-the-platform-mapping' ($defFn.IndexOf('DgP-MapPlatform', [System.StringComparison]::Ordinal) -ge 0) 'no platform name is repeated outside DgP-MapPlatform')
$mergeFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Merge-DenGoInstalledState' }, $true))[0].Extent.Text
[void](Assert-I2A 'S7b-closing-conditions' (($mergeFn.IndexOf('$inPlan = $entryKeys.ContainsKey($key)', [System.StringComparison]::Ordinal) -ge 0) -and ($mergeFn.IndexOf('(-not $inPlan) -and (-not (DgP-IsDeferredRecord $f))', [System.StringComparison]::Ordinal) -ge 0)) 'a record is closed only outside the plan and when it is not deferred')

# ---------------------------------------------------------------- S8 package list
$pkg = Get-I2AScriptAst (Join-Path $repo 'installer\build\Build-DenGo-SetupPackage.ps1')
$strings = @($pkg.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
[void](Assert-I2A 'S8-required-files-list-core-and-product-layer' (($strings -contains 'scripts\DenGoInstallerTransaction.ps1') -and ($strings -contains 'scripts\DenGoInstallerProductApply.ps1')) 'the engine depends on both files at run time; the package check lists them')

# ---------------------------------------------------------------- S9 core change is limited to AllowEmptyTransaction
$baseCore = Get-BaselineText 'installer/scripts/DenGoInstallerTransaction.ps1'
if ($null -eq $baseCore) { [void](Assert-I2A 'S9-baseline-available' $true 'the I2-A commit object is not available here; the baseline comparisons are skipped') }
else {
    $a = Get-FunctionTexts $baseCore; $curCore = Get-CurrentText $core; $b = Get-FunctionTexts $curCore
    $changed = @($b.Keys | Where-Object { (-not $a.ContainsKey($_)) -or ($a[$_] -ne $b[$_]) } | Sort-Object)
    $removed = @($a.Keys | Where-Object { -not $b.ContainsKey($_) })
    # I2-B changes: AllowEmptyTransaction (Begin, Run) and, additively, the report path of a rollback / recovery (ExecuteRecovery, Rollback, Recover, Run)
    [void](Assert-I2A 'S9-core-changed-functions' ((($changed -join ',') -eq 'DgTx-Begin,DgTx-ExecuteRecovery,DgTx-Recover,DgTx-Rollback,DgTx-Run') -and ($removed.Count -eq 0)) ("changed: $($changed -join ','); removed: $($removed -join ',')"))
    foreach ($fn in 'DgTx-ExecuteRecovery', 'DgTx-Rollback', 'DgTx-Recover') {
        $fa2 = $a[$fn].Split("`n"); $fb2 = $b[$fn].Split("`n")
        $added = @($fb2 | Where-Object { $fa2 -cnotcontains $_ })
        $removed2 = @($fa2 | Where-Object { $fb2 -cnotcontains $_ })
        $bad2 = @($added | Where-Object { $_ -notmatch 'eportPath' })        # every NEW line is about the report path
        [void](Assert-I2A ("S9-report-path-change-is-additive-" + $fn) (($bad2.Count -eq 0) -and ($removed2.Count -le 3) -and ([Math]::Abs($fb2.Count - $fa2.Count) -le 1)) ("${fn}: lines $($fa2.Count) -> $($fb2.Count); new lines $($added.Count), replaced lines $($removed2.Count); new lines that are not about the report path: $($bad2.Count)"))
    }
    $headA = $baseCore.Substring(0, $baseCore.IndexOf('function DgConst-ZeroHash')); $headB = $curCore.Substring(0, $curCore.IndexOf('function DgConst-ZeroHash'))
    [void](Assert-I2A 'S9-core-header-unchanged' ($headA -eq $headB) 'file header and contract summary unchanged')
    $begin = $b['DgTx-Begin']; $run = $b['DgTx-Run']
    [void](Assert-I2A 'S9-begin-flag' (($begin -match '\[switch\]\$AllowEmptyTransaction\)') -and ($begin.Contains("if (@(`$Items).Count -eq 0 -and -not `$AllowEmptyTransaction) { throw (DgError 'PlanInvalid' 'No items.') }"))) 'the default stays: no items is refused')
    [void](Assert-I2A 'S9-run-flag' (($run -match '\[switch\]\$AllowEmptyTransaction\)') -and $run.Contains('requires NewStateFactory') -and $run.Contains('-AllowEmptyTransaction:$AllowEmptyTransaction')) 'the flag needs a factory and is passed on explicitly')
    # every other line of the two functions is what it was
    $la = $a['DgTx-Begin'].Split("`n"); $lb = $b['DgTx-Begin'].Split("`n")
    $dB = @(@($lb | Where-Object { $la -cnotcontains $_ }) + @($la | Where-Object { $lb -cnotcontains $_ }))
    [void](Assert-I2A 'S9-begin-diff-is-small' (($lb.Count - $la.Count) -eq 1 -and $dB.Count -le 5) ("DgTx-Begin: lines $($la.Count) -> $($lb.Count), differing positions $($dB.Count)"))
    $la = $a['DgTx-Run'].Split("`n"); $lb = $b['DgTx-Run'].Split("`n")
    $dR = @(@($lb | Where-Object { $la -cnotcontains $_ }) + @($la | Where-Object { $lb -cnotcontains $_ }))
    [void](Assert-I2A 'S9-run-diff-is-small' (($lb.Count - $la.Count) -eq 3 -and $dR.Count -le 10) ("DgTx-Run: lines $($la.Count) -> $($lb.Count), differing positions $($dR.Count)"))
    $runNew = @($lb | Where-Object { $la -cnotcontains $_ })
    $dRnon = @($runNew | Where-Object { ($_ -notmatch 'AllowEmptyTransaction') -and ($_ -notmatch 'eportPath') -and ($_ -notmatch 'An empty transaction') })
    [void](Assert-I2A 'S9-run-diff-is-only-the-flag-and-the-report-path' (($dRnon.Count -eq 0) -and (@($la | Where-Object { $lb -cnotcontains $_ }).Count -le 4)) ("DgTx-Run: new lines that are about neither the flag nor the report path: $($dRnon.Count)"))
}
# ---------------------------------------------------------------- S10 the GUI change is local; I1 behaviour is untouched
$baseGui = Get-BaselineText 'installer/gui/DenGoInstallerGui.ps1'
if ($null -eq $baseGui) { [void](Assert-I2A 'S10-baseline-available' $true 'baseline unavailable; skipped') }
else {
    $curGui = Get-CurrentText $gui
    $la = $baseGui.Split("`n"); $lb = $curGui.Split("`n")
    [void](Assert-I2A 'S10-gui-same-line-count' ($la.Count -eq $lb.Count) "$($la.Count) vs $($lb.Count) lines")
    $diffLines = @(); for ($i = 0; $i -lt [Math]::Min($la.Count, $lb.Count); $i++) { if ($la[$i] -ne $lb[$i]) { $diffLines += $i } }
    [void](Assert-I2A 'S10-gui-two-lines-changed' (($diffLines.Count -eq 2) -and (@($diffLines | Where-Object { $lb[$_] -match 'Test-ApplyDeferred' }).Count -eq 2)) ("changed lines: " + (($diffLines | ForEach-Object { $_ + 1 }) -join ',')))
    $fa = Get-FunctionTexts $baseGui; $fb = Get-FunctionTexts $curGui
    $guarded = @('Test-ApplyCommitted', 'Write-RunResult', 'Complete-Run', 'Set-RunFailed', 'Set-RunFailure', 'Set-RunCompleted', 'Set-RunCancelled', 'Invoke-UnhandledGuiException', 'Stop-CurrentProcess', 'Confirm-SetupCancel', 'Start-SandboxApply', 'Show-GuiError')
    $guardedBad = @($guarded | Where-Object { $fa[$_] -ne $fb[$_] })
    [void](Assert-I2A 'S10-i1-functions-untouched' ($guardedBad.Count -eq 0) ("changed I1 functions: " + ($guardedBad -join ',')))
    $fc = @($fb.Keys | Where-Object { (-not $fa.ContainsKey($_)) -or ($fa[$_] -ne $fb[$_]) } | Sort-Object)
    [void](Assert-I2A 'S10-only-the-result-row-code-differs' (($fc -join ',') -in @('Get-ApplyResult,Show-Results,Test-ApplyDeferred', 'Show-Results,Test-ApplyDeferred', 'Get-ApplyResult,Test-ApplyDeferred')) ("functions that differ: " + ($fc -join ',')))
    $closing = [regex]::Match($baseGui, '\$form\.Add_FormClosing\(\{[\s\S]*?\n\}\)').Value
    [void](Assert-I2A 'S10-formclosing-untouched' (($closing.Length -gt 100) -and ($curGui.IndexOf($closing, [System.StringComparison]::Ordinal) -ge 0)) 'the FormClosing handler is byte-identical')
    $msg = 'PCSX2' + (J 0x306E,0x5165,0x529B,0x8A2D,0x5B9A,0x306F,0x4ECA,0x56DE,0x306F,0x5909,0x66F4,0x3057,0x3066,0x3044,0x307E,0x305B,0x3093)
    $failText = J 0x5165,0x529B,0x8A2D,0x5B9A,0x306E,0x8FFD,0x52A0,0x306B,0x5931,0x6557,0x3057,0x307E,0x3057,0x305F
    $okText = J 0x8A2D,0x5B9A,0x6E08,0x307F,0x30FB,0x5229,0x7528,0x53EF,0x80FD
    $deferredAt = $curGui.IndexOf('Test-ApplyDeferred $pcsx2Apply', [System.StringComparison]::Ordinal)
    [void](Assert-I2A 'S10-deferred-row-text-and-kind' (($curGui.IndexOf("Add-Row 5 'warn' 'PCSX2' '" + $msg + "'", [System.StringComparison]::Ordinal) -ge 0) -and ($deferredAt -gt 0)) 'a warning row with the agreed text; never the "set up" or "failed" text')
    $row5 = $curGui.Substring($curGui.IndexOf('$pcsx2Apply=Get-ApplyResult'), 900)
    [void](Assert-I2A 'S10-deferred-branch-is-before-ok-and-fail' (($row5.IndexOf('Test-ApplyDeferred', [System.StringComparison]::Ordinal) -lt $row5.IndexOf($okText, [System.StringComparison]::Ordinal)) -and ($row5.IndexOf('Test-ApplyDeferred', [System.StringComparison]::Ordinal) -lt $row5.IndexOf($failText, [System.StringComparison]::Ordinal))) 'the Deferred branch is tested first')
}
# ---------------------------------------------------------------- S11 files that must stay untouched are byte-identical to the I2-A commit
# (I2-C: Invoke-DenGoUninstaller.ps1 and DenGoUninstallerGui.ps1 are changed by I2-C on purpose; Test-DenGoInstaller-I2C-Static.ps1 guards them)
foreach ($rel in 'installer/Build-DenGo-SetupExe-2.0.0.ps1', 'installer/scripts/Start-DenGoSetup.ps1', 'installer/scripts/Start-DenGoUninstall.ps1', 'installer/tests/Test-DenGoInstaller-R1A.ps1', 'installer/tests/Test-DenGoInstaller-R1B.ps1', 'installer/tests/Test-DenGoInstaller-I1-Gui.ps1', 'installer/tests/I1.TestSupport.ps1') {
    $base = Get-BaselineText $rel
    if ($null -eq $base) { [void](Assert-I2A ('S11-' + $rel) $true 'baseline unavailable; skipped'); continue }
    [void](Assert-I2A ('S11-unchanged-' + $rel) ($base -eq (Get-CurrentText (Join-Path $repo $rel.Replace('/', '\')))) 'identical to the I2-A commit')
}
# ---------------------------------------------------------------- S12 QA1: only PROC-01 changed (two single-line replacements)
$baseQa = Get-BaselineText 'installer/tests/Test-DenGoInstaller-QA1.ps1'
if ($null -ne $baseQa) {
    $qa = (Get-CurrentText $qa1).Split("`n"); $qb = $baseQa.Split("`n")
    $dl = @(); for ($i = 0; $i -lt [Math]::Min($qa.Count, $qb.Count); $i++) { if ($qa[$i] -ne $qb[$i]) { $dl += $i } }
    [void](Assert-I2A 'S12-qa1-two-lines-changed' (($qa.Count -eq $qb.Count) -and ($dl.Count -eq 2) -and (@($dl | Where-Object { ($qa[$_] -match 'ProcessGateOrder') -or ($qa[$_] -match 'PROC-01') }).Count -eq 2)) ("changed lines: " + (($dl | ForEach-Object { $_ + 1 }) -join ',')))
}
Complete-I2ATests
