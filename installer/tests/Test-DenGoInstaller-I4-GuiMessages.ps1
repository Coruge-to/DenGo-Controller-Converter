# I4 GUI message test (written RED first). Owner decision 2026-11-18: keep the behaviour after a failure dialog (OK -> back to the start page, window stays open) and make the TEXT Japanese.
# The engine messages (English) are pinned by the I2-D lock tests and are NOT changed; the GUIs map the engine ErrorCode to a Japanese text and show the engine message unchanged for any other code.
#   AnotherOperationRunning                  -> Japanese "another setup/uninstall is running" text (keeps the lock reason in parentheses)
#   RecoveryCompletedOperationNotCompleted   -> Japanese "an interrupted operation was recovered, this operation was not started" text (keeps the outcome in parentheses)
#   any other code / empty                   -> the engine message unchanged (unknown messages are never hidden)
# Each GUI script must define Get-DenGoGuiErrorText (checked through the PowerShell AST, executed in isolation) and its failure dialog must use it with the plan/result ErrorCode.
# ASCII only: Japanese is matched by Unicode ranges.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:pass = 0; $script:fail = 0
function Assert-I4([string]$Id, [bool]$Ok, [string]$Detail) { if ($Ok) { $script:pass++; Write-Output ("PASS {0}" -f $Id) } else { $script:fail++; Write-Output ("FAIL {0} :: {1}" -f $Id, $Detail) } }
$jp = [regex]::new('[' + [char]0x3040 + '-' + [char]0x30FF + [char]0x4E00 + '-' + [char]0x9FFF + ']')   # hiragana, katakana, CJK ideographs (built from code points: this file is ASCII only)
$guis = @(
    @{ Name = 'installer';   Path = (Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1');   Var = '\$script:plan\.ErrorCode'; Verb = 'install';   RecoveryEn = 'An interrupted install was recovered (RolledBack); this operation was not started.' },
    @{ Name = 'uninstaller'; Path = (Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'); Var = '\$result\.ErrorCode';      Verb = 'uninstall'; RecoveryEn = 'An interrupted uninstall was recovered (RolledBack); this operation was not started.' }
)
$lockEn = 'Another DenGo setup or uninstall operation is running (HeldByOther).'
foreach ($g in $guis) {
    $n = $g.Name
    $text = [System.IO.File]::ReadAllText($g.Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    Assert-I4 "$n-parses" (@($errors).Count -eq 0) "parse errors: $(@($errors).Count)"
    $fn = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-DenGoGuiErrorText' }, $true))
    Assert-I4 "$n-defines-Get-DenGoGuiErrorText" ($fn.Count -eq 1) "function count = $($fn.Count)"
    if ($fn.Count -eq 1) {
        . ([scriptblock]::Create($fn[0].Extent.Text))
        $lock = [string](Get-DenGoGuiErrorText -ErrorCode 'AnotherOperationRunning' -ErrorMessage $lockEn)
        Assert-I4 "$n-lock-is-japanese" ($jp.IsMatch($lock)) "text=[$lock]"
        Assert-I4 "$n-lock-has-no-english-sentence" (-not ($lock -match 'Another DenGo|operation is running')) "text=[$lock]"
        Assert-I4 "$n-lock-keeps-reason" ($lock -match 'HeldByOther') "text=[$lock]"
        $rec = [string](Get-DenGoGuiErrorText -ErrorCode 'RecoveryCompletedOperationNotCompleted' -ErrorMessage $g.RecoveryEn)
        Assert-I4 "$n-recovery-is-japanese" ($jp.IsMatch($rec)) "text=[$rec]"
        Assert-I4 "$n-recovery-has-no-english-sentence" (-not ($rec -match 'interrupted|was recovered|this operation was not started')) "text=[$rec]"
        Assert-I4 "$n-recovery-keeps-outcome" ($rec -match 'RolledBack') "text=[$rec]"
        $other = [string](Get-DenGoGuiErrorText -ErrorCode 'SomethingElse' -ErrorMessage 'Raw engine message 123')
        Assert-I4 "$n-unknown-code-keeps-engine-message" ($other -eq 'Raw engine message 123') "text=[$other]"
        $empty = [string](Get-DenGoGuiErrorText -ErrorCode '' -ErrorMessage '')
        Assert-I4 "$n-empty-returns-empty-for-caller-default" ([string]::IsNullOrEmpty($empty)) "text=[$empty]"
        $lockUnknownReason = [string](Get-DenGoGuiErrorText -ErrorCode 'AnotherOperationRunning' -ErrorMessage 'unexpected wording')
        Assert-I4 "$n-lock-code-wins-over-message" ($jp.IsMatch($lockUnknownReason)) "text=[$lockUnknownReason]"
    }
    # the failure dialog must use the mapping with the ErrorCode, and must not hand the raw ErrorMessage to the message box any more
    Assert-I4 "$n-dialog-uses-the-mapping" ($text -match ('Get-DenGoGuiErrorText[^\r\n]{0,200}' + $g.Var) -or $text -match ($g.Var + '[^\r\n]{0,200}Get-DenGoGuiErrorText')) "no call site that passes $($g.Var)"
    # behaviour kept: after the dialog the GUI goes back to its start page and stays open (owner decision (a))
    if ($n -eq 'installer') { Assert-I4 "$n-keeps-back-to-welcome-after-failure" ($text -match "MessageBox\]::Show\(\`$detail[^\r\n]{0,120}Set-RunFailure[^\r\n]{0,60}Set-Page 'welcome'") "failure path no longer ends in Set-Page 'welcome'" }
    else { Assert-I4 "$n-keeps-back-to-start-after-failure" ($text -match "Set-RunFailed 'EngineFailed'\s*\r?\n\s*Set-Page 'start'") "failure path no longer ends in Set-Page 'start'" }
}
Write-Output ("I4-GuiMessages: PASS={0} FAIL={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
