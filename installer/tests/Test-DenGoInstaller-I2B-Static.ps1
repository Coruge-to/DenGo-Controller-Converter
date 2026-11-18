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
function Get-CurrentTextRaw([string]$Path) { return ((New-Object System.Text.UTF8Encoding($false)).GetString((Read-Bytes $Path))).TrimStart([char]0xFEFF).Replace("`r`n", "`n") }
# I4 follow-up (owner decision 2026-11-18: Japanese GUI error texts). Each GUI gained exactly ONE function (Get-DenGoGuiErrorText) and exactly ONE call-site line. The guards below compare the GUI scripts with the I2-B / I3 baselines,
# so the current text is first normalised back by exactly that known change (the function is cut out, the call line is reverted) and EVERYTHING ELSE is still compared strictly. If the known pieces are not present exactly once, the text is
# returned unchanged and the guards fail. The new behaviour itself is fixed by Test-DenGoInstaller-I4-GuiMessages.ps1.
function Remove-I4GuiMessageChange([string]$Path, [string]$Text) {
    $map = @{
        'DenGoInstallerGui.ps1'   = @('$detail=Get-DenGoGuiErrorText -ErrorCode ([string]$script:plan.ErrorCode) -ErrorMessage ([string]$script:plan.ErrorMessage);', '$detail=[string]$script:plan.ErrorMessage;')
        'DenGoUninstallerGui.ps1' = @('$detail = Get-DenGoGuiErrorText -ErrorCode ([string]$result.ErrorCode) -ErrorMessage ([string]$result.ErrorMessage)', '$detail = [string]$result.ErrorMessage')
    }
    $leaf = [System.IO.Path]::GetFileName($Path)
    if (-not $map.ContainsKey($leaf)) { return $Text }
    $new = $map[$leaf][0]; $old = $map[$leaf][1]
    if (([regex]::Matches($Text, [regex]::Escape($new))).Count -ne 1) { return $Text }
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tk, [ref]$er)
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-DenGoGuiErrorText' }, $true))
    if ($fn.Count -ne 1) { return $Text }
    $st = $fn[0].Extent.StartOffset; $en = $fn[0].Extent.EndOffset
    if (($en -lt $Text.Length) -and ($Text[$en] -eq "`n")) { $en++ }
    return ($Text.Substring(0, $st) + $Text.Substring($en)).Replace($new, $old)
}
function Get-CurrentText([string]$Path) { return (Remove-I4GuiMessageChange $Path (Get-CurrentTextRaw $Path)) }
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

# ---------------------------------------------------------------- S6 PCSX2 / LilyPad: until I3 only deferred; since I3 a real role whose string literals live in a FIXED set of functions
# (I3-D follow-up of the I2-B contract "PCSX2 literals only in DgP-MapPlatform". The set below is the exact list of the functions that hold such a literal in the I3-C product layer;
#  a literal in any other function - or a function of the set that no longer exists - fails. The Deferred pseudo role must be gone from the mapping.)
$pcsx2Literals = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $x.Value -match 'PCSX2|LilyPad|Pcsx2' }, $true))
$pcsx2AllowedFunctions = @('DgP-MapPlatform', 'Get-DenGoRoleSpec', 'DgP-SetOrder', 'DgP-IsPcsx2Record', 'DgP-PromotionBlock', 'DgP-NewResult', 'Invoke-DenGoProductInstall', 'Merge-DenGoInstalledState', 'Get-DenGoClosedGenerationPcsx2Origins',
    'Get-DenGoPcsx2Identity', 'Get-DenGoPcsx2KnownPairs', 'Resolve-DenGoPcsx2Root', 'Test-DenGoPcsx2RootProof', 'Group-DenGoPcsx2Candidates', 'New-DenGoPcsx2PlanItems', 'Test-DenGoPcsx2ExeListed', 'Test-DenGoPcsx2KnownPair')
$pcsx2Outside = @($pcsx2Literals | Where-Object { ($pcsx2AllowedFunctions -cnotcontains (Get-OwnerFunctionName $_)) -and ($_.Value -ne 'PCSX2LegacyKeyboardInitialized') })   # the state field name is a flag copied from the earlier state, not PCSX2 handling
$productFunctionNames = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
$pcsx2AllowedMissing = @($pcsx2AllowedFunctions | Where-Object { $productFunctionNames -cnotcontains $_ })
[void](Assert-I2A 'S6-pcsx2-only-in-the-platform-mapping' (($pcsx2Outside.Count -eq 0) -and ($pcsx2AllowedMissing.Count -eq 0) -and ($pcsx2Literals.Count -ge 40)) ("PCSX2 / LilyPad string literals: $($pcsx2Literals.Count); outside the $($pcsx2AllowedFunctions.Count) allowed functions: $($pcsx2Outside.Count) [$(@($pcsx2Outside | ForEach-Object { Get-OwnerFunctionName $_ } | Sort-Object -Unique) -join ',')]; allowed functions that no longer exist: $($pcsx2AllowedMissing.Count)"))
$mapFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'DgP-MapPlatform' }, $true))[0].Extent.Text
[void](Assert-I2A 'S6-pcsx2-maps-to-deferred' (($mapFn -match "DgEq \`$Platform 'PCSX2'\) \{ return @\{ Role = 'Pcsx2'; Root = .*Set = \`$Platform; Deferred = \`$false \}") -and ($mapFn.IndexOf("'Deferred'", [System.StringComparison]::Ordinal) -lt 0) -and ($mapFn.IndexOf('Deferred = $true', [System.StringComparison]::Ordinal) -lt 0)) 'PCSX2 maps to the real Pcsx2 role (Deferred = $false); the Deferred pseudo role is gone from the mapping')

# ---------------------------------------------------------------- S7 lock
$lockFn = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-DenGoLockName' }, $true))[0].Extent.Text
[void](Assert-I2A 'S7-lock-name-constant' ($lockFn -match "return 'Global\\DenGoControllerConverter\.Transaction'") $lockFn)
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
# (I3-D follow-up: DgP-IsDeferredRecord is gone; the closing ban rests on DgP-IsPcsx2Record - "a PCSX2 record is never closed". The lookups are guarded so that a missing function
#  fails the assertion instead of aborting the whole script - S8 to S12 below must always run.)
$defFns = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'DgP-IsPcsx2Record' }, $true))
$defFn = $(if ($defFns.Count -eq 1) { [string]$defFns[0].Extent.Text } else { '' })
$defFnGone = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'DgP-IsDeferredRecord' }, $true))
[void](Assert-I2A 'S7b-deferred-record-uses-the-platform-mapping' (($defFns.Count -eq 1) -and ($defFn.IndexOf("'PCSX2'", [System.StringComparison]::Ordinal) -ge 0) -and ($defFnGone.Count -eq 0)) 'the platform test of the closing ban lives in one function (DgP-IsPcsx2Record); the Deferred-record function is gone')
$mergeFns = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Merge-DenGoInstalledState' }, $true))
$mergeFn = $(if ($mergeFns.Count -eq 1) { [string]$mergeFns[0].Extent.Text } else { '' })
[void](Assert-I2A 'S7b-closing-conditions' (($mergeFn.IndexOf('$inPlan = $entryKeys.ContainsKey($key)', [System.StringComparison]::Ordinal) -ge 0) -and ($mergeFn.IndexOf('(-not $inPlan) -and (-not (DgP-IsPcsx2Record $f))', [System.StringComparison]::Ordinal) -ge 0) -and ($mergeFn.IndexOf('DgP-IsDeferredRecord', [System.StringComparison]::Ordinal) -lt 0)) 'a record is closed only outside the plan and when it is not a PCSX2 record (PCSX2 is never closed)')

# ---------------------------------------------------------------- S8 package list
$pkg = Get-I2AScriptAst (Join-Path $repo 'installer\build\Build-DenGo-SetupPackage.ps1')
$strings = @($pkg.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
[void](Assert-I2A 'S8-required-files-list-core-and-product-layer' (($strings -contains 'scripts\DenGoInstallerTransaction.ps1') -and ($strings -contains 'scripts\DenGoInstallerProductApply.ps1')) 'the engine depends on both files at run time; the package check lists them')

# ---------------------------------------------------------------- S9 core change is limited to AllowEmptyTransaction
# the core is exactly the approved I2-A TOCTOU core (F-D2 GREEN, local close 2026-10-31); this pin does not depend on the git baseline being available
$coreShaNow = ([System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create()).ComputeHash([System.IO.File]::ReadAllBytes($core)))).Replace('-', '')
[void](Assert-I2A 'S9-core-is-the-approved-TOCTOU-core' ($coreShaNow -ceq '24BD327A05504F397B770ECC4FE07AE871A1FDBA4CF5C675B2E861B28B6D0F27') "sha=$coreShaNow")
$baseCore = Get-BaselineText 'installer/scripts/DenGoInstallerTransaction.ps1'
if ($null -eq $baseCore) { [void](Assert-I2A 'S9-baseline-available' $true 'the I2-A commit object is not available here; the baseline comparisons are skipped') }
else {
    $a = Get-FunctionTexts $baseCore; $curCore = Get-CurrentText $core; $b = Get-FunctionTexts $curCore
    $changed = @($b.Keys | Where-Object { (-not $a.ContainsKey($_)) -or ($a[$_] -ne $b[$_]) } | Sort-Object)
    $removed = @($a.Keys | Where-Object { -not $b.ContainsKey($_) })
    # I2-B changes: AllowEmptyTransaction (Begin, Run) and, additively, the report path of a rollback / recovery (ExecuteRecovery, Rollback, Recover, Run)
    # I2-D change: the DACL of the common lock (DgLock-NewSecurity); Test-DenGoInstaller-I2D-Static.ps1 guards its content
    # I2-A TOCTOU contract (F-D2 GREEN, approved 2026-10-31) adds to that exactly nine core functions: the displaced-name derivation / inspection, the conditional DgFs-Replace / DgG-Replace,
# ApplyItem (conditional Write / move-aside Delete), ItemState / Preflight (observations A-D), NewAllowed (Displaced kind) and DgConst-DisplacedSuffix. The set stays an EXACT list: one more or one fewer changed function fails.
$i2bCoreSet = @('DgLock-NewSecurity', 'DgTx-Begin', 'DgTx-ExecuteRecovery', 'DgTx-Recover', 'DgTx-Rollback', 'DgTx-Run')
$toctouCoreSet = @('DgConst-DisplacedSuffix', 'DgFs-Replace', 'DgG-Replace', 'DgTx-ApplyItem', 'DgTx-DisplacedInspect', 'DgTx-DisplacedPath', 'DgTx-ItemState', 'DgTx-NewAllowed', 'DgTx-Preflight')
$expectedCoreSet = @(@($i2bCoreSet) + @($toctouCoreSet) | Sort-Object)
    [void](Assert-I2A 'S9-core-changed-functions' ((((@($changed) -join ',')) -ceq ($expectedCoreSet -join ',')) -and ($removed.Count -eq 0)) ("changed: $($changed -join ','); removed: $($removed -join ','); expected (I2-B/I2-D 6 + TOCTOU 9): $($expectedCoreSet -join ',')"))
    $secFn = [string]$b['DgLock-NewSecurity']
    [void](Assert-I2A 'S9-lock-security-is-the-i2d-dacl' (($secFn.Contains('BuiltinAdministratorsSid')) -and ($secFn.Contains('Synchronize')) -and ($secFn.Contains('Modify')) -and ($secFn.Contains('AccessControlType]::Allow')) -and (-not $secFn.Contains('LocalSystemSid')) -and (-not $secFn.Contains('FullControl')) -and (-not $secFn.Contains('Deny'))) 'the only core change besides I2-B: Allow Synchronize|Modify for the current user and Administrators; no SYSTEM, no FullControl, no Deny')
    foreach ($fn in 'DgTx-Rollback', 'DgTx-Recover') {
        $fa2 = $a[$fn].Split("`n"); $fb2 = $b[$fn].Split("`n")
        $added = @($fb2 | Where-Object { $fa2 -cnotcontains $_ })
        $removed2 = @($fa2 | Where-Object { $fb2 -cnotcontains $_ })
        $bad2 = @($added | Where-Object { $_ -notmatch 'eportPath' })        # every NEW line is about the report path
        [void](Assert-I2A ("S9-report-path-change-is-additive-" + $fn) (($bad2.Count -eq 0) -and ($removed2.Count -le 3) -and ([Math]::Abs($fb2.Count - $fa2.Count) -le 1)) ("${fn}: lines $($fa2.Count) -> $($fb2.Count); new lines $($added.Count), replaced lines $($removed2.Count); new lines that are not about the report path: $($bad2.Count)"))
    }
    # DgTx-ExecuteRecovery is also where the TOCTOU contract drops an owned displaced file after the restored destination was verified. The I2-B report-path change must still be there and still additive;
    # every other new line must be about that cleanup (displaced / cleanup / ownership / manual-check), and the baseline lines that disappeared are exactly the four the cleanup contract replaced.
    $fa2 = $a['DgTx-ExecuteRecovery'].Split("`n"); $fb2 = $b['DgTx-ExecuteRecovery'].Split("`n")
    $added = @($fb2 | Where-Object { $fa2 -cnotcontains $_ })
    $removed2 = @($fa2 | Where-Object { $fb2 -cnotcontains $_ })
    $reportNew = @($added | Where-Object { $_ -match 'eportPath' })
    $notReport = @($added | Where-Object { $_ -notmatch 'eportPath' })
    $badCleanup = @($notReport | Where-Object { $_ -notmatch '(isplaced|leanup|Cleanup|DgProp \$p|\$manual =|RestoreVerifyFailed|\$failedItem|\$Pf\.Plan|\$ins\.State -eq ''Owned'')' })
    $badRemoved = @($removed2 | Where-Object { $_ -notmatch '(\$Pf\.Plan|\$manual =|WriteReport|Outcome = ''RollbackIncomplete'')' })
    [void](Assert-I2A 'S9-report-path-change-is-additive-DgTx-ExecuteRecovery' (($reportNew.Count -ge 2) -and ($badCleanup.Count -eq 0) -and ($badRemoved.Count -eq 0) -and ($removed2.Count -le 4) -and (($fb2.Count - $fa2.Count) -ge 0) -and (($fb2.Count - $fa2.Count) -le 14)) ("DgTx-ExecuteRecovery: lines $($fa2.Count) -> $($fb2.Count); new lines $($added.Count) (report path $($reportNew.Count), cleanup $($notReport.Count - $badCleanup.Count)), replaced lines $($removed2.Count); new lines that are neither about the report path nor the displaced-file cleanup: $($badCleanup.Count); removed lines that are not the four replaced ones: $($badRemoved.Count)"))
    $headA = $baseCore.Substring(0, $baseCore.IndexOf('function DgConst-ZeroHash')); $headB = $curCore.Substring(0, $curCore.IndexOf('function DgConst-ZeroHash'))
    # the header and contract summary are the I2-A / I2-B ones plus exactly the three comment lines the TOCTOU contract added (and nothing removed)
    $hl = $headA.Split("`n"); $hr = $headB.Split("`n")
    $hNew = @($hr | Where-Object { $hl -cnotcontains $_ }); $hGone = @($hl | Where-Object { $hr -cnotcontains $_ })
    [void](Assert-I2A 'S9-core-header-unchanged' (($hGone.Count -eq 0) -and ($hNew.Count -eq 3) -and (@($hNew | Where-Object { ($_ -notmatch '^#') -or ($_ -notmatch '(onditional|isplaced|dropped|overwritten)') }).Count -eq 0) -and ($headB.StartsWith($headA.Substring(0, [Math]::Min(200, $headA.Length))))) "file header and contract summary: I2-A/I2-B text unchanged; added comment lines (TOCTOU contract): $($hNew.Count); removed: $($hGone.Count)")
    $begin = $b['DgTx-Begin']; $run = $b['DgTx-Run']
    [void](Assert-I2A 'S9-begin-flag' (($begin -match '\[switch\]\$AllowEmptyTransaction\)') -and ($begin.Contains("if (@(`$Items).Count -eq 0 -and -not `$AllowEmptyTransaction) { throw (DgError 'PlanInvalid' 'No items.') }"))) 'the default stays: no items is refused')
    [void](Assert-I2A 'S9-run-flag' (($run -match '\[switch\]\$AllowEmptyTransaction\)') -and $run.Contains('requires NewStateFactory') -and $run.Contains('-AllowEmptyTransaction:$AllowEmptyTransaction')) 'the flag needs a factory and is passed on explicitly')
    # every other line of the two functions is what it was
    $la = $a['DgTx-Begin'].Split("`n"); $lb = $b['DgTx-Begin'].Split("`n")
    $dB = @(@($lb | Where-Object { $la -cnotcontains $_ }) + @($la | Where-Object { $lb -cnotcontains $_ }))
    # I2-B added 1 line (the AllowEmptyTransaction flag, 5 differing positions at most). The TOCTOU contract adds the derived displaced name (check, length limit, collision of a destination with another item's displaced name): 14 more lines,
    # all about the displaced name, and only the three baseline lines that those additions replace disappear (param, the empty-items check, the item record).
    $newB = @($lb | Where-Object { $la -cnotcontains $_ }); $goneB = @($la | Where-Object { $lb -cnotcontains $_ })
    $badNewB = @($newB | Where-Object { $_ -notmatch '(AllowEmptyTransaction|state-only|isplaced|\$built|\$bi\b|if \(\$preExists\) \{)' })
    $badGoneB = @($goneB | Where-Object { $_ -notmatch '(^\s*param\(|No items|Tmp = \$tmp)' })
    [void](Assert-I2A 'S9-begin-diff-is-small' ((($lb.Count - $la.Count) -eq 15) -and ($goneB.Count -le 3) -and ($badNewB.Count -eq 0) -and ($badGoneB.Count -eq 0)) ("DgTx-Begin: lines $($la.Count) -> $($lb.Count) (I2-B +1, TOCTOU +14), differing positions $($dB.Count); new lines that are neither the flag nor the displaced name: $($badNewB.Count); removed lines other than the three replaced: $($badGoneB.Count)"))
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
    # I3-D follow-up: the I2-B line-count / two-line guard becomes a FUNCTION-level guard. The GUI may differ from the I1 baseline only in a fixed set of functions
    # (I2-B: Test-ApplyDeferred (new), Show-Results; I3: Test-Pcsx2Status (new), Has-UnsupportedCurrentPCSX2, Show-Results, Show-UnsupportedPCSX2Dialog, Get-RunningProductNames);
    # everything outside those functions - the script body, the event handlers and every other function - must still be identical to the baseline.
    $guiChangedAllowed = @('Get-RunningProductNames', 'Has-UnsupportedCurrentPCSX2', 'Show-Results', 'Show-UnsupportedPCSX2Dialog')
    $guiNewAllowed = @('Test-ApplyDeferred', 'Test-Pcsx2Status')
    function Get-TextWithoutFunctions([string]$Text, [string[]]$Names) {
        $tk = $null; $er = $null
        $ast2 = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tk, [ref]$er)
        $spans = @($ast2.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $Names -ccontains $_.Name } | Sort-Object { $_.Extent.StartOffset } -Descending)
        $t2 = $Text
        foreach ($s in $spans) { $st = $s.Extent.StartOffset; $en = $s.Extent.EndOffset; if (($st -gt 0) -and ($t2[$st - 1] -eq ';')) { $st-- }; $t2 = $t2.Substring(0, $st) + $t2.Substring($en) }
        return (@($t2.Split("`n") | Where-Object { $_.Trim() -ne '' }) -join "`n")
    }
    $outsideBase = Get-TextWithoutFunctions $baseGui ($guiChangedAllowed + $guiNewAllowed)
    $outsideCur = Get-TextWithoutFunctions $curGui ($guiChangedAllowed + $guiNewAllowed)
    [void](Assert-I2A 'S10-gui-same-line-count' (($outsideBase.Length -gt 10000) -and ($outsideBase -ceq $outsideCur)) "script text outside the 6 allowed functions: $($outsideBase.Split("`n").Count) vs $($outsideCur.Split("`n").Count) non-empty lines, identical = $($outsideBase -ceq $outsideCur)")
    $fa = Get-FunctionTexts $baseGui; $fb = Get-FunctionTexts $curGui
    $chgNow = @($fb.Keys | Where-Object { $fa.ContainsKey($_) -and ($fa[$_] -ne $fb[$_]) } | Sort-Object)
    $newNow = @($fb.Keys | Where-Object { -not $fa.ContainsKey($_) } | Sort-Object)
    $goneNow = @($fa.Keys | Where-Object { -not $fb.ContainsKey($_) })
    [void](Assert-I2A 'S10-gui-two-lines-changed' ((($chgNow -join ',') -ceq (($guiChangedAllowed | Sort-Object) -join ',')) -and (($newNow -join ',') -ceq (($guiNewAllowed | Sort-Object) -join ',')) -and ($goneNow.Count -eq 0)) ("changed: $($chgNow -join ','); new: $($newNow -join ','); removed: $($goneNow -join ',')"))
    $guarded = @('Test-ApplyCommitted', 'Write-RunResult', 'Complete-Run', 'Set-RunFailed', 'Set-RunFailure', 'Set-RunCompleted', 'Set-RunCancelled', 'Invoke-UnhandledGuiException', 'Stop-CurrentProcess', 'Confirm-SetupCancel', 'Start-SandboxApply', 'Show-GuiError')
    $guardedBad = @($guarded | Where-Object { $fa[$_] -ne $fb[$_] })
    [void](Assert-I2A 'S10-i1-functions-untouched' ($guardedBad.Count -eq 0) ("changed I1 functions: " + ($guardedBad -join ',')))
    $fc = @($fb.Keys | Where-Object { (-not $fa.ContainsKey($_)) -or ($fa[$_] -ne $fb[$_]) } | Sort-Object)
    [void](Assert-I2A 'S10-only-the-result-row-code-differs' (($fc -join ',') -ceq ((@($guiChangedAllowed) + @($guiNewAllowed) | Sort-Object) -join ',')) ("functions that differ: " + ($fc -join ',')))
    $closing = [regex]::Match($baseGui, '\$form\.Add_FormClosing\(\{[\s\S]*?\n\}\)').Value
    [void](Assert-I2A 'S10-formclosing-untouched' (($closing.Length -gt 100) -and ($curGui.IndexOf($closing, [System.StringComparison]::Ordinal) -ge 0)) 'the FormClosing handler is byte-identical')
    $msg = 'PCSX2' + (J 0x306E,0x5165,0x529B,0x8A2D,0x5B9A,0x306F,0x4ECA,0x56DE,0x306F,0x5909,0x66F4,0x3057,0x3066,0x3044,0x307E,0x305B,0x3093)
    $failText = J 0x5165,0x529B,0x8A2D,0x5B9A,0x306E,0x8FFD,0x52A0,0x306B,0x5931,0x6557,0x3057,0x307E,0x3057,0x305F
    $okText = 'PCSX2 1.6.0' + (J 0x5BFE,0x5FDC)   # I3-D follow-up (DE-I3-5): the applied-and-OK PCSX2 row reads "PCSX2 1.6.0 supported" (it used to read "set up / usable")
    $deferredAt = $curGui.IndexOf('Test-ApplyDeferred $pcsx2Apply', [System.StringComparison]::Ordinal)
    [void](Assert-I2A 'S10-deferred-row-text-and-kind' (($curGui.IndexOf("Add-Row 5 'warn' 'PCSX2' '" + $msg + "'", [System.StringComparison]::Ordinal) -ge 0) -and ($deferredAt -gt 0)) 'a warning row with the agreed text; never the "set up" or "failed" text')
    # I3-D follow-up: the PCSX2 row grew with the I3 branches, so the window is the whole row (up to the RPCS3 row) instead of a fixed 900 characters; the order check itself is unchanged
    $row5Start = $curGui.IndexOf('$pcsx2Apply=Get-ApplyResult'); $row5End = $curGui.IndexOf('$rpcs3Apply=Get-ApplyResult')
    $row5 = $(if (($row5Start -ge 0) -and ($row5End -gt $row5Start)) { $curGui.Substring($row5Start, $row5End - $row5Start) } else { '' })
    [void](Assert-I2A 'S10-deferred-branch-is-before-ok-and-fail' (($row5.IndexOf($okText, [System.StringComparison]::Ordinal) -gt 0) -and ($row5.IndexOf($failText, [System.StringComparison]::Ordinal) -gt 0) -and ($row5.IndexOf('Test-ApplyDeferred', [System.StringComparison]::Ordinal) -ge 0) -and ($row5.IndexOf('Test-ApplyDeferred', [System.StringComparison]::Ordinal) -lt $row5.IndexOf($okText, [System.StringComparison]::Ordinal)) -and ($row5.IndexOf('Test-ApplyDeferred', [System.StringComparison]::Ordinal) -lt $row5.IndexOf($failText, [System.StringComparison]::Ordinal))) 'the Deferred branch is tested first')
}
# ---------------------------------------------------------------- S11 files that must stay untouched are byte-identical to the I2-A commit
# (I2-C: Invoke-DenGoUninstaller.ps1 and DenGoUninstallerGui.ps1 are changed by I2-C on purpose; Test-DenGoInstaller-I2C-Static.ps1 guards them)
# (I2-D: Build-DenGo-SetupExe-2.0.0.ps1 is changed by I2-D on purpose - the post-step lock; it is guarded below by a line-level check and by Test-DenGoInstaller-I2D-Static.ps1 / -Wrapper.ps1)
foreach ($rel in 'installer/scripts/Start-DenGoSetup.ps1', 'installer/scripts/Start-DenGoUninstall.ps1', 'installer/tests/Test-DenGoInstaller-R1A.ps1', 'installer/tests/Test-DenGoInstaller-R1B.ps1', 'installer/tests/Test-DenGoInstaller-I1-Gui.ps1', 'installer/tests/I1.TestSupport.ps1') {
    $base = Get-BaselineText $rel
    if ($null -eq $base) { [void](Assert-I2A ('S11-' + $rel) $true 'baseline unavailable; skipped'); continue }
    [void](Assert-I2A ('S11-unchanged-' + $rel) ($base -eq (Get-CurrentText (Join-Path $repo $rel.Replace('/', '\')))) 'identical to the I2-A commit')
}
# I2-D: the setup-EXE builder may only ADD lines, except that the four unlocked post-step calls of the two main() functions move one level deeper (into the lock region).
# Every other line of the I2-A builder (the I1 result contract, the helper bytes and SHA, the exit codes, the registration) must still be present unchanged.
$baseBuild = Get-BaselineText 'installer/Build-DenGo-SetupExe-2.0.0.ps1'
if ($null -eq $baseBuild) { [void](Assert-I2A 'S11-build-baseline' $true 'baseline unavailable; skipped') }
else {
    $curBuildLines = @((Get-CurrentText (Join-Path $repo 'installer\Build-DenGo-SetupExe-2.0.0.ps1')).Split("`n"))
    $removedBuild = @($baseBuild.Split("`n") | Where-Object { $curBuildLines -cnotcontains $_ })
    $allowedMoved = @('        remove_registration()', '        schedule_self_delete()', '        install_uninstaller(bundle_root)', '        register_uninstaller()')
    # B-2 / G (P1): the two $expectedZipSha / $expectedSourceCommit pin lines may change value, but only to a well-formed value, and exactly one of each must exist in the current builder
    $pinRe = '^\$expected(ZipSha|SourceCommit) = ''(?:[0-9A-F]{64}|[0-9a-f]{40})''\s*$'
    $curPins = @($curBuildLines | Where-Object { $_ -cmatch $pinRe })
    $pinsOk = ($curPins.Count -eq 2) -and (@($curPins | Where-Object { $_ -cmatch '^\$expectedZipSha = ''[0-9A-F]{64}''\s*$' }).Count -eq 1) -and (@($curPins | Where-Object { $_ -cmatch '^\$expectedSourceCommit = ''[0-9a-f]{40}''\s*$' }).Count -eq 1)
    $unexpectedBuild = @($removedBuild | Where-Object { ($allowedMoved -cnotcontains $_) -and ($_ -cnotmatch $pinRe) })
    [void](Assert-I2A 'S11-build-only-adds-the-post-step-lock' (($unexpectedBuild.Count -eq 0) -and $pinsOk -and ($removedBuild.Count -le 6)) ("baseline lines no longer present: $($removedBuild.Count) (allowed: the 4 moved post-step calls and the 2 well-formed pin lines; pins ok: $pinsOk); unexpected: $($unexpectedBuild.Count) [$($unexpectedBuild -join ' | ')]"))
}
# ---------------------------------------------------------------- S12 QA1: only PROC-01 changed (two single-line replacements)
$baseQa = Get-BaselineText 'installer/tests/Test-DenGoInstaller-QA1.ps1'
if ($null -ne $baseQa) {
    # I3-D follow-up: the I2-B "two lines" guard becomes a guard on the FOLLOW-UP SET. QA1 may differ from the baseline only in the lines that belong to PROC-01 (I2-B) and to the five PCSX2
    # assertions that the I3 design retires on purpose (L01, C01, S01, S02: detection moved into the product layer; GUI-PCSX2-01: version-neutral wording) plus the new GUI-PCSX2-05.
    # Every other QA1 line (PROC-02/03, GUI-*, ENGINE-*, PCSX2-C02..C04, GUI-PCSX2-02..04, the parser checks, the report) must still be the baseline's, exactly.
    $qa = (Get-CurrentText $qa1).Split("`n"); $qb = $baseQa.Split("`n")
    $followTokens = @('ProcessGateOrder', 'markerCallIndex', 'PROC-01','PCSX2-L01', 'PCSX2-C01', 'PCSX2-S01', 'PCSX2-S02', 'GUI-PCSX2-05', 'productPath', '$product =', 'productTokens', 'productErrors', 'productAst', 'productFunction', 'rootProof', 'engineGroupCall', 'legacyDetection',
        'currentIni', 'currentInputSources', 'currentPad1', 'settingsReaders', 'scriptFile', 'scriptText', 'needle', 'unsupportedMode', 'unsupportedStatus', 'supportedList', 'groupFunction', 'statusAssigned', 'statusInRow', 'planFunction', 'engineResolvedOnly',
        'planResolvedOnly', 'planFromGroup', '$message1 =', '$message2 =', 'uninstallerGui', 'guessedVersionWords', 'guessedHits', 'agreedWords', 'missingWords')
    function Test-QaFollowLine([string]$Line) { foreach ($tk in $followTokens) { if ($Line.IndexOf($tk, [System.StringComparison]::Ordinal) -ge 0) { return $true } }; return $false }
    function Test-QaNeutralLine([string]$Line) { $tr = $Line.Trim(); return (($tr -eq '') -or ($tr -eq '}')) }   # blank lines and lone closing braces of the follow-up blocks
    $keepB = @($qb | Where-Object { (-not (Test-QaFollowLine $_)) -and (-not (Test-QaNeutralLine $_)) })
    $keepA = @($qa | Where-Object { (-not (Test-QaFollowLine $_)) -and (-not (Test-QaNeutralLine $_)) })
    $lostFromBaseline = @($keepB | Where-Object { $keepA -cnotcontains $_ })
    $addedOutside = @($keepA | Where-Object { $keepB -cnotcontains $_ })
    $idsB = @($qb | Where-Object { $_ -match "Add-TestResult '([^']+)'" } | ForEach-Object { [regex]::Match($_, "Add-TestResult '([^']+)'").Groups[1].Value } | Sort-Object -Unique)
    $idsA = @($qa | Where-Object { $_ -match "Add-TestResult '([^']+)'" } | ForEach-Object { [regex]::Match($_, "Add-TestResult '([^']+)'").Groups[1].Value } | Sort-Object -Unique)
    $idsAdded = @($idsA | Where-Object { $idsB -cnotcontains $_ }); $idsLost = @($idsB | Where-Object { $idsA -cnotcontains $_ })
    [void](Assert-I2A 'S12-qa1-two-lines-changed' (($lostFromBaseline.Count -eq 0) -and ($addedOutside.Count -eq 0) -and ($keepA.Count -eq $keepB.Count) -and ($keepB.Count -gt 50) -and (($idsAdded -join ',') -ceq 'GUI-PCSX2-05') -and ($idsLost.Count -eq 0)) ("baseline lines no longer present outside the follow-up set: $($lostFromBaseline.Count); lines added outside it: $($addedOutside.Count); kept lines $($keepB.Count) vs $($keepA.Count); assertion ids added: $($idsAdded -join ','); lost: $($idsLost -join ',')"))
}
Complete-I2ATests
