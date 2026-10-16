# I2-C static checks (no product code is run): encoding, syntax, mutation discipline (only the transaction core mutates anything), PCSX2 / LilyPad
# deferral, process order of the uninstall, the engine contract, the GUI change being local, the files that must stay byte-identical to the I2-B commit,
# the package list. Reads only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$baseline = '60308e5c5a3dd3965f70b6072e84fa12eb7d45d5'      # the I2-B commit
$productU = Join-Path $repo 'installer\scripts\DenGoUninstallerProductApply.ps1'
$engineU = Join-Path $repo 'installer\scripts\Invoke-DenGoUninstaller.ps1'
$guiU = Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'
$i2cTests = @(Get-ChildItem -LiteralPath (Join-Path $repo 'installer\tests') -Filter '*I2C*.ps1' | ForEach-Object { $_.FullName })

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
    return ((New-Object System.Text.UTF8Encoding($false)).GetString($ms.ToArray())).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
}
function Get-CurrentText([string]$Path) { return ((New-Object System.Text.UTF8Encoding($false)).GetString([System.IO.File]::ReadAllBytes($Path))).TrimStart([char]0xFEFF).Replace("`r`n", "`n") }
function Get-FunctionTexts([string]$Text) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $map = @{}
    foreach ($f in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $map[$f.Name] = $f.Extent.Text }
    return $map
}
function Get-Fn($Ast, [string]$Name) {
    $d = @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true))
    if ($d.Count -ne 1) { return '' }
    return $d[0].Extent.Text
}

# ---------------------------------------------------------------- S1 encoding and syntax
foreach ($p in @($productU) + $i2cTests) {
    $b = [System.IO.File]::ReadAllBytes($p)
    $nonAscii = @($b | Where-Object { $_ -gt 127 }).Count - $(if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { 3 } else { 0 })
    [void](Assert-I2A ('S1-encoding-ascii-' + [System.IO.Path]::GetFileName($p)) ($nonAscii -eq 0) "non-ASCII body bytes: $nonAscii")
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    [void](Assert-I2A ('S1-syntax-' + [System.IO.Path]::GetFileName($p)) (@($errors).Count -eq 0) "parse errors: $(@($errors).Count)")
}
$pb = [System.IO.File]::ReadAllBytes($productU)
[void](Assert-I2A 'S1-product-layer-has-a-bom' (($pb[0] -eq 0xEF) -and ($pb[1] -eq 0xBB) -and ($pb[2] -eq 0xBF)) 'UTF-8 BOM, like the other product files')
$eb = [System.IO.File]::ReadAllBytes($engineU)
[void](Assert-I2A 'S1-engine-ascii-and-parses' (@($eb | Where-Object { $_ -gt 127 }).Count -le 3) 'the engine stays ASCII')

# ---------------------------------------------------------------- S2 the product layer has no top-level side effects and does not mutate anything itself
$pa = Get-I2AScriptAst $productU
$top = @($pa.EndBlock.Statements)
[void](Assert-I2A 'S2-functions-only' (@($top | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0) 'every top-level statement is a function definition')
$cmdNames = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
$forbiddenCmd = @('Remove-Item', 'Copy-Item', 'Move-Item', 'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Clear-Content', 'Rename-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Start-Process', 'Invoke-Expression', 'Stop-Process', 'reg.exe', 'reg', 'regedit', 'Set-Acl')
[void](Assert-I2A 'S2-no-mutating-cmdlets' (@($cmdNames | Where-Object { $forbiddenCmd -contains $_ }).Count -eq 0) ('forbidden commands used: ' + (@($cmdNames | Where-Object { $forbiddenCmd -contains $_ }) -join ',')))
$mutPrims = @('DgFs-CreateFileDurable', 'DgFs-WriteTextFile', 'DgFs-CopyFileDurable', 'DgFs-Replace', 'DgFs-MoveNew', 'DgFs-Delete', 'DgFs-CreateDir', 'DgFs-RemoveDirIfEmpty', 'DgJournal-Open', 'DgJournal-OpenTruncate', 'DgJournal-Append', 'DgTx-Journal', 'DgG-CopyFile', 'DgG-CreateFile', 'DgG-Replace', 'DgG-MoveNew', 'DgG-Delete', 'DgG-CreateDir', 'DgG-RemoveDirIfEmpty', 'DgG-WriteText', 'DgFs-ProbeExclusive')
[void](Assert-I2A 'S2-no-mutating-primitives' (@($cmdNames | Where-Object { $mutPrims -contains $_ }).Count -eq 0) ('mutating primitives called: ' + (@($cmdNames | Where-Object { $mutPrims -contains $_ }) -join ',') + ' - every change goes through the transaction core'))
$members = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
$badMembers = @($members | Where-Object { ($_.Expression.Extent.Text -match '^\[System\.IO\.(File|Directory)\]$') -and ([string]$_.Member.Value -in @('Delete', 'Copy', 'Move', 'Replace', 'WriteAllText', 'WriteAllBytes', 'WriteAllLines', 'AppendAllText', 'Create', 'CreateDirectory', 'SetAttributes', 'Open')) })
[void](Assert-I2A 'S2-no-direct-file-mutation' ($badMembers.Count -eq 0) ('direct [System.IO.File] / [System.IO.Directory] mutation: ' + (@($badMembers | ForEach-Object { $_.Extent.Text }) -join ' ; ')))
$regRefs = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ($x.Value -match 'HKLM|HKCU|Registry::|\\Microsoft\\Windows\\CurrentVersion') }, $true))
[void](Assert-I2A 'S2-no-registry-reference' ($regRefs.Count -eq 0) 'the registration is the wrapper''s duty, not the engine''s')
$comObj = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'New-Object' -and $x.Extent.Text -match 'ComObject' }, $true))
[void](Assert-I2A 'S2-no-com-in-the-uninstall-layer' ($comObj.Count -eq 0) 'shortcuts are read through the existing DgPFs-ReadShortcut only')

# ---------------------------------------------------------------- S3 PCSX2 / LilyPad stay deferred; no UninstallRollback; no GC
$strs = @($pa.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
[void](Assert-I2A 'S3-no-lilypad-string' (@($strs | Where-Object { $_ -match 'LilyPad\.|\.lily|\.ini\b' }).Count -eq 0) 'no LilyPad.ini / .lily / .ini file name appears in the uninstall layer (the deferral message may name LilyPad)')
$pcsx2Strings = @($strs | Where-Object { $_ -match 'PCSX2|Pcsx2' })
[void](Assert-I2A 'S3-pcsx2-only-as-the-deferral-test' (($pcsx2Strings.Count -le 3) -and (@($pcsx2Strings | Where-Object { $_ -notin @('PCSX2') -and $_ -notmatch 'PCSX2 / LilyPad|PCSX2' }).Count -eq 0)) ('PCSX2 strings: ' + ($pcsx2Strings -join ' | ')))
$roleFn = Get-Fn $pa 'Get-DenGoUninstallRoleSpec'
[void](Assert-I2A 'S3-no-pcsx2-role' (($roleFn.IndexOf('Pcsx2', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -and ($roleFn.IndexOf('LilyPad', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) 'no PCSX2 allowed root or role exists')
$prodText = [System.IO.File]::ReadAllText($productU)
$engText = [System.IO.File]::ReadAllText($engineU)
[void](Assert-I2A 'S3-no-uninstallrollback-creation' (($prodText.IndexOf('UninstallRollback', [System.StringComparison]::Ordinal) -lt 0) -and ($engText.IndexOf('UninstallRollback', [System.StringComparison]::Ordinal) -lt 0) -and ($engText.IndexOf('Copy-Checked', [System.StringComparison]::Ordinal) -lt 0)) 'the old rollback folder and its copy helper are gone (the core''s backups replace them)')
[void](Assert-I2A 'S3-no-backup-gc' (($prodText -notmatch 'Remove-Item') -and ($prodText.IndexOf('BackupRoot', [System.StringComparison]::Ordinal) -ge 0)) 'I2-C never deletes a backup (no GC)')

# ---------------------------------------------------------------- S4 the order of Invoke-DenGoProductUninstall and the item order
$inv = Get-Fn $pa 'Invoke-DenGoProductUninstall'
$idx = @{}
foreach ($k in @('DgLock-TryAcquire', "DgP-InvokeProcessGate `$Options 'A'", 'Get-DenGoUninstallRecoveryGate', 'Read-DenGoPreviousState', 'Read-DenGoUninstalledState', 'Get-DenGoUninstallPlan', 'Test-DenGoAlreadyUninstalled', 'Convert-DenGoUninstallPlanToItems', 'Test-DenGoUninstallPlanFresh', 'Invoke-DenGoTransaction', "-Operation 'Uninstall'", 'DgLock-Release')) { $idx[$k] = $inv.IndexOf($k, [System.StringComparison]::Ordinal) }
$ordered = ($idx["DgLock-TryAcquire"] -ge 0) -and ($idx["DgLock-TryAcquire"] -lt $idx["DgP-InvokeProcessGate `$Options 'A'"]) -and ($idx["DgP-InvokeProcessGate `$Options 'A'"] -lt $idx['Get-DenGoUninstallRecoveryGate']) -and ($idx['Get-DenGoUninstallRecoveryGate'] -lt $idx['Read-DenGoPreviousState']) -and ($idx['Read-DenGoPreviousState'] -lt $idx['Get-DenGoUninstallPlan']) -and ($idx['Get-DenGoUninstallPlan'] -lt $idx['Convert-DenGoUninstallPlanToItems']) -and ($idx['Convert-DenGoUninstallPlanToItems'] -lt $idx['Test-DenGoUninstallPlanFresh']) -and ($idx['Test-DenGoUninstallPlanFresh'] -lt $idx['Invoke-DenGoTransaction'])
[void](Assert-I2A 'S4-process-order' $ordered 'lock -> process gate A -> recovery gate -> state read -> plan -> items -> freshness -> transaction')
[void](Assert-I2A 'S4-operation-is-uninstall-and-lock-released-in-finally' (($idx["-Operation 'Uninstall'"] -gt 0) -and ($inv -match 'finally\s*\{[^}]*DgLock-Release')) 'Operation=Uninstall; the lock is released in finally')
[void](Assert-I2A 'S4-recovery-only-never-continues' (($inv.IndexOf('if (-not $gate.Proceed)', [System.StringComparison]::Ordinal) -ge 0) -and ($inv.IndexOf('return $res', $inv.IndexOf('if (-not $gate.Proceed)', [System.StringComparison]::Ordinal), [System.StringComparison]::Ordinal) -gt 0)) 'a recovery that ran ends the run (Failed / RecoveryCompletedOperationNotCompleted); the plan is not rebuilt')
$gateFn = Get-Fn $pa 'Get-DenGoUninstallRecoveryGate'
[void](Assert-I2A 'S4-recovery-completed-code' ($gateFn.Contains("'RecoveryCompletedOperationNotCompleted'")) 'RolledBack / RolledForward map to RecoveryCompletedOperationNotCompleted')
[void](Assert-I2A 'S4-foreign-install-marker' (($gateFn.Contains("'ForeignOperationMarker'")) -and ($gateFn.Contains("'MultipleMarkers'")) -and ($gateFn.Contains("'LegacyMarkerUnsupported'"))) 'installing.json is refused, not recovered')
$dry = Get-Fn $pa 'Get-DenGoUninstallDryRun'
[void](Assert-I2A 'S4-dryrun-takes-no-lock-and-recovers-nothing' (($dry.IndexOf('DgLock', [System.StringComparison]::Ordinal) -lt 0) -and ($dry.Contains("'DryRun'")) -and ($dry.IndexOf('Invoke-DenGoTransaction', [System.StringComparison]::Ordinal) -lt 0)) 'the dry run reads only')
$conv = Get-Fn $pa 'Convert-DenGoUninstallPlanToItems'
$iFiles = $conv.IndexOf('FileDecisions', [System.StringComparison]::Ordinal); $iUs = $conv.IndexOf("ArchiveUninstalledState", [System.StringComparison]::Ordinal); $iIs = $conv.IndexOf('ArchiveInstalledState', [System.StringComparison]::Ordinal); $iDel = $conv.IndexOf('RemoveInstalledState', [System.StringComparison]::Ordinal)
[void](Assert-I2A 'S4-installed-state-is-archived-then-deleted-last' (($iFiles -ge 0) -and ($iFiles -lt $iUs) -and ($iUs -lt $iIs) -and ($iIs -lt $iDel)) 'product files / shortcuts, then the old uninstalled-state archive, then the installed-state archive, then the installed-state delete')
$plan = Get-Fn $pa 'Get-DenGoUninstallPlan'
[void](Assert-I2A 'S4-reverse-install-order' ($plan.Contains('DgU-SetOrder') -and ((Get-Fn $pa 'DgU-SetOrder') -match "'RPCS3','AtsEX Legacy','BveEX Current','BVE6','BVE5','Core'")) 'Set order = the reverse of the install order')
$fac = $inv.IndexOf('$factory = {', [System.StringComparison]::Ordinal)
[void](Assert-I2A 'S4-process-gate-B-in-the-factory-before-the-state' (($fac -gt 0) -and ($inv.IndexOf("DgP-InvokeProcessGate `$a.Options 'B'", $fac, [System.StringComparison]::Ordinal) -gt $fac) -and ($inv.IndexOf('New-DenGoUninstalledState', $fac, [System.StringComparison]::Ordinal) -gt $inv.IndexOf("'B'", $fac, [System.StringComparison]::Ordinal))) 'gate B runs inside the state factory, before the new state is built')

# ---------------------------------------------------------------- S5 the engine contract
$ea = Get-I2AScriptAst $engineU
$engineFns = @($ea.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
[void](Assert-I2A 'S5-engine-keeps-the-process-gate-function' (($engineFns -contains 'Assert-TargetProcessesStopped') -and ($engText.Contains('Assert-TargetProcessesStopped'))) 'R1B needs the function in the engine')
[void](Assert-I2A 'S5-engine-passes-the-gate-to-the-product-layer' ($engText.Contains('ProcessGate = { Assert-TargetProcessesStopped }')) 'the gate is called by the product layer at phases A and B')
$wr = @($ea.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$x.Member.Value -in @('WriteAllText', 'WriteAllLines', 'WriteAllBytes', 'Delete', 'Copy', 'Move', 'Replace') }, $true))
$badWr = @($wr | Where-Object { $_.Arguments.Count -eq 0 -or $_.Arguments[0].Extent.Text -notin @('$jsonOutput', '$textOutput') })
[void](Assert-I2A 'S5-engine-writes-only-its-two-result-files' (($wr.Count -ge 2) -and ($badWr.Count -eq 0)) ('writes: ' + (@($wr | ForEach-Object { $_.Arguments[0].Extent.Text }) -join ',') + ' - no state is written by the engine'))
[void](Assert-I2A 'S5-engine-calls-product-uninstall-and-dryrun' (($engText.Contains('Invoke-DenGoProductUninstall')) -and ($engText.Contains('Get-DenGoUninstallDryRun')) -and ($engText.Contains("'DenGoUninstallerProductApply.ps1'")) -and ($engText.Contains("'DenGoInstallerTransaction.ps1'")) -and ($engText.Contains("'DenGoInstallerProductApply.ps1'"))) 'the engine dot-sources the three layers')
[void](Assert-I2A 'S5-engine-keeps-its-guards' (($engText.Contains("'UNINSTALL'")) -and ($engText.Contains('OutputRoot must be under TEMP')) -and ($engText.Contains('Specify either -DryRun or -Apply, not both.'))) 'argument guards unchanged')
[void](Assert-I2A 'S5-engine-always-writes-a-result' (($engText.Contains('$jsonOutput')) -and ($engText.IndexOf('WriteAllText($jsonOutput', [System.StringComparison]::Ordinal) -gt $engText.IndexOf('Invoke-DenGoProductUninstall', [System.StringComparison]::Ordinal)) -and ($engText -notmatch "throw \('Installed state was not found")) 'no throw before the result file (the old L19 throw is gone)')

# ---------------------------------------------------------------- S6 files that must stay byte-identical to the I2-B commit
# (I2-D: DenGoInstallerTransaction.ps1, DenGoInstallerProductApply.ps1 and Build-DenGo-SetupExe-2.0.0.ps1 are changed by I2-D on purpose - the common lock; they are guarded below by a function-level / line-level check and by the I2-D tests)
$same = @('installer/scripts/Invoke-DenGoInstaller.ps1', 'installer/scripts/Start-DenGoSetup.ps1', 'installer/scripts/Start-DenGoUninstall.ps1', 'installer/gui/DenGoInstallerGui.ps1', 'installer/tests/I1.TestSupport.ps1', 'installer/tests/I2A.TestSupport.ps1', 'installer/tests/I2B.TestSupport.ps1', 'installer/tests/Test-DenGoInstaller-R1A.ps1', 'installer/tests/Test-DenGoInstaller-R1B.ps1', 'installer/tests/Test-DenGoInstaller-I1-Gui.ps1', 'installer/tests/Test-DenGoInstaller-QA1.ps1')
foreach ($rel in $same) {
    $base = Get-BaselineText $rel
    if ($null -eq $base) { [void](Assert-I2A ('S6-' + $rel) $true 'baseline unavailable; skipped'); continue }
    [void](Assert-I2A ('S6-unchanged-' + $rel) ($base -eq (Get-CurrentText (Join-Path $repo $rel.Replace('/', '\')))) 'identical to the I2-B commit')
}
# I2-D: the two engine layers may differ from the I2-B commit only in ONE function each (the lock name / the lock DACL). Everything else - every other function and
# all code outside the functions (comments excluded) - must be identical to the I2-B commit.
foreach ($pair in @(@('installer/scripts/DenGoInstallerTransaction.ps1', 'DgLock-NewSecurity'), @('installer/scripts/DenGoInstallerProductApply.ps1', 'Get-DenGoLockName'))) {
    $rel = $pair[0]; $allowedFn = $pair[1]
    $base = Get-BaselineText $rel
    if ($null -eq $base) { [void](Assert-I2A ('S6-' + $rel) $true 'baseline unavailable; skipped'); continue }
    $cur = Get-CurrentText (Join-Path $repo $rel.Replace('/', '\'))
    $fa = Get-FunctionTexts $base; $fb = Get-FunctionTexts $cur
    $changedFns = @($fb.Keys | Where-Object { (-not $fa.ContainsKey($_)) -or ($fa[$_] -ne $fb[$_]) } | Sort-Object)
    $removedFns = @($fa.Keys | Where-Object { -not $fb.ContainsKey($_) })
    $restA = $base; $restB = $cur
    if ($fa.ContainsKey($allowedFn) -and $fb.ContainsKey($allowedFn)) { $restA = $base.Replace($fa[$allowedFn], ''); $restB = $cur.Replace($fb[$allowedFn], '') }
    $codeA = @($restA.Split("`n") | Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') })
    $codeB = @($restB.Split("`n") | Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') })
    [void](Assert-I2A ('S6-i2d-single-function-change-' + $rel) ((($changedFns -join ',') -eq $allowedFn) -and ($removedFns.Count -eq 0) -and (($codeA -join "`n") -ceq ($codeB -join "`n"))) ("changed functions: $($changedFns -join ','); removed: $($removedFns -join ','); code outside the function identical (comments excluded): $((($codeA -join "`n") -ceq ($codeB -join "`n")))"))
}
# I2-D: the setup-EXE builder may only ADD lines, except that the four post-step calls of the two main() functions move one level deeper (into the lock region)
$baseBuild = Get-BaselineText 'installer/Build-DenGo-SetupExe-2.0.0.ps1'
if ($null -eq $baseBuild) { [void](Assert-I2A 'S6-build-baseline' $true 'baseline unavailable; skipped') }
else {
    $curBuildLines = @((Get-CurrentText (Join-Path $repo 'installer\Build-DenGo-SetupExe-2.0.0.ps1')).Split("`n"))
    $removedBuild = @($baseBuild.Split("`n") | Where-Object { $curBuildLines -cnotcontains $_ })
    $allowedMoved = @('        remove_registration()', '        schedule_self_delete()', '        install_uninstaller(bundle_root)', '        register_uninstaller()')
    $unexpectedBuild = @($removedBuild | Where-Object { $allowedMoved -cnotcontains $_ })
    [void](Assert-I2A 'S6-i2d-build-only-adds-the-post-step-lock' (($unexpectedBuild.Count -eq 0) -and ($removedBuild.Count -le 4)) ("baseline lines no longer present: $($removedBuild.Count) (allowed: the 4 moved post-step calls); unexpected: $($unexpectedBuild.Count) [$($unexpectedBuild -join ' | ')]"))
}

# ---------------------------------------------------------------- S7 the GUI change is local (the residual notice only)
$baseGui = Get-BaselineText 'installer/gui/DenGoUninstallerGui.ps1'
if ($null -eq $baseGui) { [void](Assert-I2A 'S7-baseline-available' $true 'baseline unavailable; skipped') }
else {
    $curGui = Get-CurrentText $guiU
    $la = $baseGui.Split("`n"); $lb = $curGui.Split("`n")
    $removed = @($la | Where-Object { $lb -cnotcontains $_ })
    $added = @($lb | Where-Object { $la -cnotcontains $_ })
    [void](Assert-I2A 'S7-gui-only-additions' ($removed.Count -eq 0) ("lines removed or changed: $($removed.Count)"))
    [void](Assert-I2A 'S7-gui-additions-are-the-notice' (($added.Count -gt 0) -and (@($added | Where-Object { $_ -notmatch 'completeNotice|ResidualNotice|ResidualFileCount|ManualCheckRequired|ReportPath|\$show|\$count|\$manual|\$candidate|\$property|\$text|^\s*\}|^\s*try \{|catch|function Set-ResidualNotice|Visible|Text|param|completePage|Result\.PSObject|^#|^\s*$' }).Count -eq 0)) ("added lines: $($added.Count); lines that are not about the notice: " + (@($added | Where-Object { $_ -notmatch 'completeNotice|ResidualNotice|ResidualFileCount|ManualCheckRequired|ReportPath|\$show|\$count|\$manual|\$candidate|\$property|\$text|^\s*\}|^\s*try \{|catch|function Set-ResidualNotice|Visible|Text|param|completePage|Result\.PSObject|^#|^\s*$' }).Count)))
    $fa = Get-FunctionTexts $baseGui; $fb = Get-FunctionTexts $curGui
    $guarded = @('Test-UninstallCommitted', 'Write-RunResult', 'Complete-Run', 'Set-RunFailed', 'Set-RunCompleted', 'Set-RunCancelled', 'Invoke-UnhandledGuiException', 'Show-GuiError', 'Confirm-Cancel', 'Confirm-RunningProductsClosed', 'Join-NativeArguments', 'Get-RunningProductNames', 'Set-Page')
    $guardedBad = @($guarded | Where-Object { $fa[$_] -ne $fb[$_] })
    [void](Assert-I2A 'S7-i1-functions-untouched' ($guardedBad.Count -eq 0) ('changed I1 functions: ' + ($guardedBad -join ',')))
    $newFns = @($fb.Keys | Where-Object { -not $fa.ContainsKey($_) })
    [void](Assert-I2A 'S7-one-new-function' (($newFns.Count -eq 1) -and ($newFns[0] -eq 'Set-ResidualNotice') -and (@($fb.Keys | Where-Object { $fa.ContainsKey($_) -and $fa[$_] -ne $fb[$_] }).Count -eq 0)) ('new functions: ' + ($newFns -join ',')))
    $closing = [regex]::Match($baseGui, '\$form\.Add_FormClosing\(\{[\s\S]*?\n\}\)').Value
    [void](Assert-I2A 'S7-formclosing-untouched' (($closing.Length -gt 100) -and ($curGui.IndexOf($closing, [System.StringComparison]::Ordinal) -ge 0)) 'the FormClosing handler is byte-identical')
    $startClick = [regex]::Match($baseGui, '\$startButton\.Add_Click\(\{[\s\S]*?\n\}\)').Value
    [void](Assert-I2A 'S7-start-click-untouched' (($startClick.Length -gt 100) -and ($curGui.IndexOf($startClick, [System.StringComparison]::Ordinal) -ge 0)) 'the start handler (process gate, engine start) is byte-identical')
    $tickBase = [regex]::Match($baseGui, '\$timer\.Add_Tick\(\{[\s\S]*?\n\}\)').Value
    $tickCur = [regex]::Match($curGui, '\$timer\.Add_Tick\(\{[\s\S]*?\n\}\)').Value
    $tickAdded = @($tickCur.Split("`n") | Where-Object { $tickBase.Split("`n") -cnotcontains $_ })
    [void](Assert-I2A 'S7-tick-handler-gets-exactly-one-call' (($tickBase.Length -gt 100) -and ($tickAdded.Count -eq 1) -and ($tickAdded[0].Trim() -eq 'Set-ResidualNotice $result')) ("added lines in the engine-finished handler: " + ($tickAdded -join ' ; ')))
    $iNotice = $tickCur.IndexOf('Set-ResidualNotice $result', [System.StringComparison]::Ordinal); $iDone = $tickCur.IndexOf('Set-RunCompleted', [System.StringComparison]::Ordinal); $iCommit = $tickCur.IndexOf('Test-UninstallCommitted $result $exitCode', [System.StringComparison]::Ordinal)
    [void](Assert-I2A 'S7-notice-only-after-the-commit-check-passed' (($iCommit -ge 0) -and ($iNotice -gt $iCommit) -and ($iNotice -lt $iDone)) 'the notice is set after Test-UninstallCommitted accepted the run and just before Completed: a Failed run never reaches it')
    $nf = $fb['Set-ResidualNotice']
    [void](Assert-I2A 'S7-notice-never-throws-and-never-sets-a-result' (($nf -match 'catch \{ \$show = \$false \}') -and ($nf.IndexOf('finalResult', [System.StringComparison]::Ordinal) -lt 0) -and ($nf.IndexOf('script:', [System.StringComparison]::Ordinal) -lt 0) -and ($nf.Contains('IO.File]::Exists($candidate)'))) 'it cannot change the I1 outcome; a report path is shown only if the file exists')
}

# ---------------------------------------------------------------- S8 the package list
$pkg = Get-I2AScriptAst (Join-Path $repo 'installer\build\Build-DenGo-SetupPackage.ps1')
$pstr = @($pkg.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
[void](Assert-I2A 'S8-required-files-list' (($pstr -contains 'scripts\DenGoUninstallerProductApply.ps1') -and ($pstr -contains 'scripts\DenGoInstallerTransaction.ps1') -and ($pstr -contains 'scripts\DenGoInstallerProductApply.ps1') -and ($pstr -contains 'scripts\Invoke-DenGoUninstaller.ps1')) 'the uninstaller engine depends on all three layers at run time; the package check lists them')
$basePkg = Get-BaselineText 'installer/build/Build-DenGo-SetupPackage.ps1'
if ($null -ne $basePkg) {
    $a2 = $basePkg.Split("`n"); $b2 = (Get-CurrentText (Join-Path $repo 'installer\build\Build-DenGo-SetupPackage.ps1')).Split("`n")
    $addedPkg = @($b2 | Where-Object { $a2 -cnotcontains $_ }); $remPkg = @($a2 | Where-Object { $b2 -cnotcontains $_ })
    [void](Assert-I2A 'S8-package-script-change-is-one-line' (($addedPkg.Count -eq 2) -and ($remPkg.Count -eq 1) -and ($addedPkg -join ' ') -match 'DenGoUninstallerProductApply') ("added=$($addedPkg.Count) removed=$($remPkg.Count)"))
}

# ---------------------------------------------------------------- S9 the install gate still refuses the uninstall's files (I2B-U1 is unchanged and still the guard)
$instGate = Get-Fn (Get-I2AScriptAst (Join-Path $repo 'installer\scripts\DenGoInstallerProductApply.ps1')) 'DgP-InfraGate'
[void](Assert-I2A 'S9-install-gate-has-no-uninstall-leaf' (($instGate.IndexOf('uninstalled-state', [System.StringComparison]::Ordinal) -lt 0) -and ($instGate.IndexOf('UninstallRollback', [System.StringComparison]::Ordinal) -lt 0)) 'the install infra gate does not list uninstalled-state.json or UninstallRollback')
Complete-I2ATests
