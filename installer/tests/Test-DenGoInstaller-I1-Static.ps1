# I1 static tests (T1): structural guarantees checked on the PowerShell AST and on the embedded Python templates.
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')

$repo = $script:I1Repo
$productFiles = @(
    'installer\Build-DenGo-SetupExe-2.0.0.ps1',
    'installer\scripts\Start-DenGoSetup.ps1',
    'installer\scripts\Start-DenGoUninstall.ps1',
    'installer\gui\DenGoInstallerGui.ps1',
    'installer\gui\DenGoUninstallerGui.ps1'
)
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | ForEach-Object { 'installer\tests\' + $_.Name })

# ---- parse and hygiene ----
foreach ($relative in @($productFiles + $testFiles)) {
    $path = Join-Path $repo $relative
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Add-I1Result ('PARSE-' + $relative) (@($errors).Count -eq 0) ('ParseErrorCount=' + @($errors).Count)
}
foreach ($relative in @('installer\scripts\Start-DenGoSetup.ps1', 'installer\scripts\Start-DenGoUninstall.ps1', 'installer\gui\DenGoInstallerGui.ps1', 'installer\gui\DenGoUninstallerGui.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo $relative))
    Add-I1Result ('BOM-KEPT-' + $relative) ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'UTF-8 BOM present (needed for Japanese text under Windows PowerShell 5.1)'
}
$builderBytes = [System.IO.File]::ReadAllBytes((Join-Path $repo 'installer\Build-DenGo-SetupExe-2.0.0.ps1'))
Add-I1Result 'BUILDER-ASCII-ONLY' (@($builderBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'the builder writes the Python source as ASCII; Japanese must stay as \u escapes'
foreach ($relative in $testFiles + @('installer\tests\i1_wrapper_tests.py')) {
    if (([System.IO.Path]::GetFileName($relative)) -notmatch 'I1|i1_') { continue }
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo $relative))
    Add-I1Result ('I1-TEST-ASCII-ONLY-' + [System.IO.Path]::GetFileName($relative)) (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'new test files stay ASCII so no BOM is needed'
}

# ---- GUIs: one explicit exit, last in the script, driven by Complete-Run ----
foreach ($gui in @(@{ Tag = 'INSTALLER'; Path = 'installer\gui\DenGoInstallerGui.ps1' }, @{ Tag = 'UNINSTALLER'; Path = 'installer\gui\DenGoUninstallerGui.ps1' })) {
    $ast = Get-ScriptAst (Join-Path $repo $gui.Path)
    $exits = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
    $last = $ast.EndBlock.Statements[$ast.EndBlock.Statements.Count - 1]
    Add-I1Result ($gui.Tag + '-GUI-SINGLE-EXPLICIT-EXIT') ($exits.Count -eq 1 -and $exits[0].Pipeline.Extent.Text -eq '([int](Complete-Run))') ('exit statements: ' + ($exits | ForEach-Object { $_.Extent.Text }) -join ' | ')
    Add-I1Result ($gui.Tag + '-GUI-EXIT-IS-LAST-STATEMENT') ($last -is [System.Management.Automation.Language.ExitStatementAst]) ('last statement type: ' + $last.GetType().Name)
    $text = [System.IO.File]::ReadAllText((Join-Path $repo $gui.Path), [System.Text.Encoding]::UTF8)
    $assignments = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:finalResult' }, $true))
    $toCompleted = @($assignments | Where-Object { $_.Right.Extent.Text -eq "'Completed'" })
    $insideSetter = @($toCompleted | Where-Object { $p = $_.Parent; while ($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }; $null -ne $p -and $p.Name -eq 'Set-RunCompleted' })
    Add-I1Result ($gui.Tag + '-GUI-COMPLETED-ASSIGNED-ONLY-IN-SETTER') ($toCompleted.Count -eq 1 -and $insideSetter.Count -eq 1) ("finalResult='Completed' assignments: $($toCompleted.Count) (in Set-RunCompleted: $($insideSetter.Count))")
    $enclosingFunction = { param($node) $p = $node.Parent; while ($null -ne $p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }; if ($null -ne $p) { $p.Name } else { '' } }
    $topLevelResult = @($assignments | Where-Object { (& $enclosingFunction $_) -eq '' })
    $reasonAssignments = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:finalReason' }, $true))
    $topLevelReason = @($reasonAssignments | Where-Object { (& $enclosingFunction $_) -eq '' })
    Add-I1Result ($gui.Tag + '-GUI-INITIAL-STATE-IS-FAILED-NOTCOMPLETED') ($topLevelResult.Count -eq 1 -and $topLevelResult[0].Right.Extent.Text -eq "'Failed'" -and $topLevelReason.Count -eq 1 -and $topLevelReason[0].Right.Extent.Text -eq "'NotCompleted'") 'the only top-level initialisation of the result is Failed/NotCompleted; Cancelled is no longer a default'
    $toCancelled = @($assignments | Where-Object { $_.Right.Extent.Text -eq "'Cancelled'" })
    Add-I1Result ($gui.Tag + '-GUI-CANCELLED-ASSIGNED-ONLY-IN-SET-RUN-CANCELLED') ($toCancelled.Count -eq 1 -and (& $enclosingFunction $toCancelled[0]) -eq 'Set-RunCancelled') ("finalResult='Cancelled' assignments: $($toCancelled.Count)")
    $guardedByConfirmation = {
        param($call)
        $p = $call.Parent
        while ($null -ne $p) {
            if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $p.Clauses) {
                    if ($call.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $call.Extent.EndOffset -le $clause.Item2.Extent.EndOffset -and $clause.Item1.Extent.Text -match 'Confirm-(Setup)?Cancel') { return $true }
                }
            }
            $p = $p.Parent
        }
        return $false
    }
    $cancelCalls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-RunCancelled' }, $true))
    $unguarded = @($cancelCalls | Where-Object { -not (& $guardedByConfirmation $_) })
    Add-I1Result ($gui.Tag + '-GUI-CANCEL-ONLY-AFTER-USER-CONFIRMATION') ($cancelCalls.Count -ge 3 -and $unguarded.Count -eq 0) ("Set-RunCancelled call sites: $($cancelCalls.Count); not inside a confirmed-cancel branch: $($unguarded.Count)")
    Add-I1Result ($gui.Tag + '-GUI-UNHANDLED-EXCEPTION-GUARD-REGISTERED') ($text.Contains('add_ThreadException') -and $text.Contains('Invoke-UnhandledGuiException $e.Exception')) 'unexpected handler exceptions are routed to Failed instead of the default dialog'
    $setCompleted = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-RunCompleted' }, $true))
    Add-I1Result ($gui.Tag + '-GUI-SET-RUN-COMPLETED-CALLED-ONCE') ($setCompleted.Count -eq 1) ('call sites: ' + $setCompleted.Count)
    $tickText =$text.Substring($text.IndexOf('Add_Tick', [System.StringComparison]::Ordinal))
    $checkName = if ($gui.Tag -eq 'INSTALLER') { 'Test-ApplyCommitted' } else { 'Test-UninstallCommitted' }
    $checkAt = $tickText.IndexOf($checkName, [System.StringComparison]::Ordinal); $completedAt = $tickText.IndexOf('Set-RunCompleted', [System.StringComparison]::Ordinal)
    Add-I1Result ($gui.Tag + '-GUI-COMMIT-CHECK-PRECEDES-COMPLETED') ($checkAt -gt 0 -and $completedAt -gt $checkAt) "check at $checkAt, completed at $completedAt (inside the Tick handler)"
}

# ---- the engine process is never killed while applying ----
$installerAst = Get-ScriptAst (Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1')
$kills = @($installerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'Kill' }, $true))
$stopFn = @($installerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-CurrentProcess' }, $true))
$killInStop = ($kills.Count -eq 1 -and $stopFn.Count -eq 1 -and $kills[0].Extent.StartOffset -gt $stopFn[0].Extent.StartOffset -and $kills[0].Extent.EndOffset -lt $stopFn[0].Extent.EndOffset)
Add-I1Result 'INSTALLER-ONLY-KILL-IS-IN-STOP-CURRENT-PROCESS' $killInStop ('Kill() call sites: ' + $kills.Count)
$firstStatement = $stopFn[0].Body.EndBlock.Statements[0]
Add-I1Result 'INSTALLER-STOP-CURRENT-PROCESS-GUARDED-FIRST' ($firstStatement -is [System.Management.Automation.Language.IfStatementAst] -and $firstStatement.Clauses[0].Item1.Extent.Text.Contains('applyRunning') -and $firstStatement.Clauses[0].Item2.Extent.Text.Contains('return')) ('first statement: ' + $firstStatement.Extent.Text)
$stopCallers = @($installerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-CurrentProcess' }, $true))
Add-I1Result 'INSTALLER-STOP-CALLS-ARE-GUARDED-OR-IDLE' ($stopCallers.Count -ge 2) ('Stop-CurrentProcess call sites: ' + $stopCallers.Count + ' (all go through the guarded function)')
$uninstallerAst = Get-ScriptAst (Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1')
$uninstallKills = @($uninstallerAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'Kill') -or ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-Process') }, $true))
Add-I1Result 'UNINSTALLER-NEVER-KILLS' ($uninstallKills.Count -eq 0) ('kill/Stop-Process call sites: ' + $uninstallKills.Count)

# ---- FormClosing decides on CloseReason.UserClosing and the applyRunning flag ----
foreach ($gui in @(@{ Tag = 'INSTALLER'; Path = 'installer\gui\DenGoInstallerGui.ps1' }, @{ Tag = 'UNINSTALLER'; Path = 'installer\gui\DenGoUninstallerGui.ps1' })) {
    $handler = (Get-EventHandlerBlock (Join-Path $repo $gui.Path) 'Add_FormClosing').Ast.Extent.Text
    $applyAt = $handler.IndexOf('$script:applyRunning', [System.StringComparison]::Ordinal); $allowAt = $handler.IndexOf('$script:allowClose', [System.StringComparison]::Ordinal)
    Add-I1Result ($gui.Tag + '-CLOSING-CHECKS-APPLYRUNNING-FIRST') ($applyAt -ge 0 -and $applyAt -lt $allowAt) 'applyRunning is evaluated before allowClose'
    Add-I1Result ($gui.Tag + '-CLOSING-USES-CLOSEREASON-USERCLOSING') ($handler.Contains('CloseReason]::UserClosing')) 'only UserClosing is treated as a user action'
    Add-I1Result ($gui.Tag + '-CLOSING-NOT-BLOCKING-OTHER-REASONS') (-not $handler.Contains('WindowsShutDown') -and -not $handler.Contains('TaskManagerClosing')) 'no reason other than UserClosing is named for blocking'
}
$uninstallerText = [System.IO.File]::ReadAllText((Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'), [System.Text.Encoding]::UTF8)
Add-I1Result 'UNINSTALLER-LOCK-NOT-BASED-ON-PAGE-VISIBILITY' (-not (Get-EventHandlerBlock (Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1') 'Add_FormClosing').Ast.Extent.Text.Contains('progressPage.Visible')) 'the apply lock follows the engine process, so a failing Tick handler cannot lock the window forever'
Add-I1Result 'APPLYRUNNING-CLEARED-BEFORE-RESULT-PARSING' ($uninstallerText.IndexOf('$script:applyRunning = $false', [System.StringComparison]::Ordinal) -lt $uninstallerText.IndexOf('ConvertFrom-Json } catch', [System.StringComparison]::Ordinal)) 'uninstaller: the flag is cleared as soon as the engine has exited'

# ---- wrapper (Python templates): side effects only behind the Completed gate ----
$templates = Get-BuilderTemplates
foreach ($pair in @(@{ Tag = 'SETUP'; Text = $templates.Setup; Effects = @('install_uninstaller(bundle_root)', 'register_uninstaller()') }, @{ Tag = 'UNINSTALL'; Text = $templates.Uninstall; Effects = @('remove_registration()', 'schedule_self_delete()') })) {
    $lines = @($pair.Text -split "`r?`n")
    $mainAt = [array]::IndexOf($lines, 'def main():')
    $mainLines = @($lines[($mainAt)..($lines.Count - 1)] | ForEach-Object { $_.Trim() })
    $gateAt = [array]::IndexOf($mainLines, 'if outcome != "Completed":')
    Add-I1Result ($pair.Tag + '-WRAPPER-GATE-PRESENT') ($mainAt -ge 0 -and $gateAt -ge 0) 'main() contains the Completed gate'
    foreach ($effect in $pair.Effects) {
        $callAt = [array]::IndexOf($mainLines, $effect)
        $calls = @($lines | Where-Object { $_.Trim() -eq $effect })
        Add-I1Result ($pair.Tag + '-WRAPPER-EFFECT-AFTER-GATE-' + ($effect -replace '[^A-Za-z]', '')) ($callAt -gt $gateAt -and $gateAt -ge 0 -and $calls.Count -eq 1) "$effect is called once, after the gate (gate line $gateAt, call line $callAt)"
    }
    Add-I1Result ($pair.Tag + '-WRAPPER-NO-ZERO-PASSTHROUGH') (-not ($mainLines -contains 'code = run_script(package_root, "Start-DenGoSetup.ps1")') -and -not ($pair.Text.Contains('if code != 0:'))) 'the child exit code is no longer passed through or trusted on its own'
}
Complete-I1Tests
