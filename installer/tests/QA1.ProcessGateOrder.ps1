# QA1 helper (I2-B): checks, on the syntax tree, that the process gate runs before the transaction Begin and before the first disk change.
# Returns @{ Ok; Detail }. ASCII only. Reads the product scripts; writes nothing.
param([string]$RepoRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
function Get-GateAst([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw ('Parse errors in ' + $Path) }
    return $ast
}
function First-Index([string[]]$Names, [string]$Name) { for ($i = 0; $i -lt $Names.Count; $i++) { if ($Names[$i] -eq $Name) { return $i } } return -1 }
function Get-CommandNodes($Ast) {
    return @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Sort-Object { $_.Extent.StartOffset })
}
$engine = Get-GateAst (Join-Path $RepoRoot 'installer\scripts\Invoke-DenGoInstaller.ps1')
$product = Get-GateAst (Join-Path $RepoRoot 'installer\scripts\DenGoInstallerProductApply.ps1')
$notes = New-Object System.Collections.ArrayList
$ok = $true

# (1) engine: the block that starts the product install passes a ProcessGate that runs Assert-TargetProcessesStopped, defined before the call
$calls = @($engine.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-DenGoProductInstall' }, $true))
if ($calls.Count -ne 1) { $ok = $false; [void]$notes.Add('engine calls Invoke-DenGoProductInstall ' + $calls.Count + ' times') }
else {
    $call = $calls[0]
    $parent = $call.Parent
    while ($null -ne $parent -and -not ($parent -is [System.Management.Automation.Language.IfStatementAst])) { $parent = $parent.Parent }
    if ($null -eq $parent) { $ok = $false; [void]$notes.Add('engine call is not inside an if block') }
    else {
        $gates = @($parent.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-TargetProcessesStopped' }, $true))
        $before = @($gates | Where-Object { $_.Extent.StartOffset -lt $call.Extent.StartOffset })
        if ($before.Count -lt 1) { $ok = $false; [void]$notes.Add('engine: no ProcessGate (Assert-TargetProcessesStopped) before the product install call') }
        else {
            $inScriptBlock = $false
            $p = $before[0].Parent
            while ($null -ne $p) { if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $inScriptBlock = $true }; $p = $p.Parent }
            if (-not $inScriptBlock) { $ok = $false; [void]$notes.Add('engine: the gate is not passed as a ProcessGate script block') }
        }
        $hashKeys = @($parent.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq 'ProcessGate' }, $true))
        if ($hashKeys.Count -lt 1) { $ok = $false; [void]$notes.Add('engine: the ProcessGate option is missing') }
    }
}

# (2) product layer: lock -> process gate A -> recovery gate -> staging -> transaction (Begin); no disk change before the gate
$fn = @($product.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DenGoProductInstall' }, $true))
if ($fn.Count -ne 1) { $ok = $false; [void]$notes.Add('Invoke-DenGoProductInstall is not defined exactly once') }
else {
    $cmds = Get-CommandNodes $fn[0]
    $names = @($cmds | ForEach-Object { [string]$_.GetCommandName() })
    $iLock = First-Index $names 'DgLock-TryAcquire'
    $iGate = First-Index $names 'DgP-InvokeProcessGate'
    $iRec = First-Index $names 'Get-DenGoRecoveryGate'
    $iStage = First-Index $names 'New-DenGoStagedShortcut'
    $iTx = First-Index $names 'Invoke-DenGoTransaction'
    if ($iLock -lt 0 -or $iGate -lt 0 -or $iRec -lt 0 -or $iTx -lt 0) { $ok = $false; [void]$notes.Add("missing step lock=$iLock gate=$iGate recovery=$iRec transaction=$iTx") }
    else {
        if (-not ($iLock -lt $iGate -and $iGate -lt $iRec -and $iRec -lt $iTx)) { $ok = $false; [void]$notes.Add("order lock=$iLock gate=$iGate recovery=$iRec transaction=$iTx") }
        if ($iStage -ge 0 -and -not ($iGate -lt $iStage -and $iStage -lt $iTx)) { $ok = $false; [void]$notes.Add("stage order gate=$iGate stage=$iStage tx=$iTx") }
        $gateArg = $cmds[$iGate].CommandElements
        if ($gateArg.Count -lt 3 -or [string]$gateArg[2].Extent.Text -ne "'A'") { $ok = $false; [void]$notes.Add('the first process gate is not phase A') }
        $mutators = @('DgFs-CreateFileDurable', 'DgFs-WriteTextFile', 'DgFs-CopyFileDurable', 'DgFs-Replace', 'DgFs-MoveNew', 'DgFs-Delete', 'DgFs-CreateDir', 'DgFs-RemoveDirIfEmpty', 'DgTx-Begin', 'DgTx-Recover', 'DgTx-Rollback', 'DgTx-Apply', 'DgTx-Commit', 'DgPFs-NewStageDir', 'DgPFs-NewShortcutFile', 'DgPFs-DeleteStageFile', 'DgPFs-RemoveStageDir')
        for ($i = 0; $i -lt $iGate; $i++) { if ($mutators -contains $names[$i] -or $names[$i].StartsWith('DgG-')) { $ok = $false; [void]$notes.Add('a disk-changing command (' + $names[$i] + ') precedes the process gate') } }
    }
}
# (3) the recovery gate is the only caller of the recovery (Recover) and runs after the process gate in the product function above
$txFn = @($product.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DenGoTransaction' }, $true))
if ($txFn.Count -ne 1) { $ok = $false; [void]$notes.Add('Invoke-DenGoTransaction is not defined exactly once') }
else {
    $txNames = @((Get-CommandNodes $txFn[0]) | ForEach-Object { [string]$_.GetCommandName() })
    $iBegin = First-Index $txNames 'DgTx-Begin'
    $iApply = First-Index $txNames 'DgTx-Apply'
    $iCommit = First-Index $txNames 'DgTx-Commit'
    if (-not ($iBegin -ge 0 -and $iBegin -lt $iApply -and $iApply -lt $iCommit)) { $ok = $false; [void]$notes.Add("transaction order begin=$iBegin apply=$iApply commit=$iCommit") }
}
return [pscustomobject]@{ Ok = $ok; Detail = $(if ($ok) { 'lock < process gate A < recovery gate < staging < DgTx-Begin; the engine passes the gate as ProcessGate before the call' } else { [string]::Join('; ', [string[]]@($notes)) }) }
