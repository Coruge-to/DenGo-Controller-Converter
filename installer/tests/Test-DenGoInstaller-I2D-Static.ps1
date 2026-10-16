# I2-D static tests (written RED first, plan i2d-implementation-plan.md section 5.1). Reads only; nothing is executed from the product.
# Engine side (PowerShell AST): S1 name, S2 one literal / S2b acquire call sites, S3 Explicit only, S4 SIDs, S5 rights, S6 WaitOne(0), S7 no lock in GUI / Start,
#   S8 stale comments, S20 DryRun takes no lock, S21 an abandoned mutex is never read as a decision.
# Wrapper side (Python ast over the templates of Build-DenGo-SetupExe-2.0.0.ps1, run by i2d_wrapper_tests.py in "static" mode): S9..S13, S16, S18, S19.
#   S14 (ASCII only) and S15 (self-delete helper unchanged) are checked here.
# Names used for the wrapper (LOCK_NAME, LOCK_ACCESS, POST_STEP_LOCK_TIMEOUT_SECONDS, POST_STEP_LOCK_POLL_SECONDS, acquire_post_step_lock,
# release_post_step_lock, verify_state_locked, reasons PostStepLockTimeout / PostStepStateChanged) are the ones fixed by plan section 1.2 / Stage D2.
. (Join-Path $PSScriptRoot 'I2D.TestSupport.ps1')
$repo = $script:I2DRepo
$scripts = Join-Path $repo 'installer\scripts'
$product = Join-Path $scripts 'DenGoInstallerProductApply.ps1'
$uninstallProduct = Join-Path $scripts 'DenGoUninstallerProductApply.ps1'
$core = Join-Path $scripts 'DenGoInstallerTransaction.ps1'
$guiFiles = @((Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1'), (Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'))
$startFiles = @((Join-Path $scripts 'Start-DenGoSetup.ps1'), (Join-Path $scripts 'Start-DenGoUninstall.ps1'))
$AstNs = 'System.Management.Automation.Language'

function Get-Text([string]$Path) { return ((New-Object System.Text.UTF8Encoding($false)).GetString([System.IO.File]::ReadAllBytes($Path))).TrimStart([char]0xFEFF) }
function Get-FunctionAst($Ast, [string]$Name) {
    $found = @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { throw ('Function ' + $Name + ' expected once, found ' + $found.Count) }
    return $found[0]
}
# the member name of a member access, or '' for a dynamic member ($obj.$name has no constant Value)
function Get-MemberName($Node) {
    if ($Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$Node.Member.Value }
    return ''
}
function Get-OwnerFunctionName($Node) {
    $f = $Node.Parent
    while ($null -ne $f -and -not ($f -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $f = $f.Parent }
    if ($null -eq $f) { return '' }
    return $f.Name
}
function Get-CommandNodes($Ast, [string]$Name) {
    $r = New-Object System.Collections.ArrayList
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $Name }, $true)) { [void]$r.Add($n) }
    return , ([object[]]$r.ToArray())
}
# the literal a function consists of: function F { return 'literal' } -> 'literal'; $null for anything else
function Get-ReturnedLiteral($FunctionAst) {
    $st = @($FunctionAst.Body.EndBlock.Statements)
    if ($st.Count -ne 1) { return $null }
    if (-not ($st[0] -is [System.Management.Automation.Language.ReturnStatementAst])) { return $null }
    $pipe = $st[0].Pipeline
    if (-not ($pipe -is [System.Management.Automation.Language.PipelineAst])) { return $null }
    $els = @($pipe.PipelineElements)
    if ($els.Count -ne 1 -or -not ($els[0] -is [System.Management.Automation.Language.CommandExpressionAst])) { return $null }
    $ex = $els[0].Expression
    if (-not ($ex -is [System.Management.Automation.Language.StringConstantExpressionAst])) { return $null }
    return [string]$ex.Value
}
function Get-StaticMembers($Ast, [string]$TypeSuffix) {
    $names = New-Object System.Collections.ArrayList
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.MemberExpressionAst] -and $x.Static -and $x.Expression -is [System.Management.Automation.Language.TypeExpressionAst] }, $true)) {
        if ($n.Expression.TypeName.FullName.EndsWith($TypeSuffix, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$names.Add((Get-MemberName $n)) }
    }
    return $names.ToArray()    # callers wrap the call in @(...): one name per element
}

$pa = Get-I2AScriptAst $product
$ua = Get-I2AScriptAst $uninstallProduct
$ca = Get-I2AScriptAst $core

# ---------------------------------------------------------------- S1 the name
$nameFn = Get-FunctionAst $pa 'Get-DenGoLockName'
$engineName = Get-ReturnedLiteral $nameFn
[void](Assert-I2A 'S1-lock-name-is-the-global-contract-literal' ($engineName -ceq $script:I2DProductLockName) ('Get-DenGoLockName returns [' + [string]$engineName + '] (contract: ' + $script:I2DProductLockName + ')'))

# ---------------------------------------------------------------- S2 one literal, one place; the acquire call sites
$literalHits = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -LiteralPath $scripts -Filter '*.ps1' | ForEach-Object { $_.FullName })) {
    $ast = Get-I2AScriptAst $f
    foreach ($s in @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ([string]$x.Value).IndexOf('DenGoControllerConverter.Transaction', [System.StringComparison]::Ordinal) -ge 0 }, $true))) { [void]$literalHits.Add([System.IO.Path]::GetFileName($f)) }
}
[void](Assert-I2A 'S2-lock-name-literal-defined-in-one-place' (($literalHits.Count -eq 1) -and ($literalHits[0] -eq 'DenGoInstallerProductApply.ps1')) ('literal occurrences in installer\scripts: ' + [string]::Join(', ', [string[]]@($literalHits))))
$sites = New-Object System.Collections.ArrayList
$engineFiles = @((Join-Path $scripts 'Invoke-DenGoInstaller.ps1'), (Join-Path $scripts 'Invoke-DenGoUninstaller.ps1'))
foreach ($f in @($product, $uninstallProduct) + $engineFiles + $startFiles + $guiFiles) {
    $ast = Get-I2AScriptAst $f
    foreach ($c in (Get-CommandNodes $ast 'DgLock-TryAcquire')) { [void]$sites.Add((Get-OwnerFunctionName $c)) }
}
$siteList = @($sites | Sort-Object)
[void](Assert-I2A 'S2b-acquire-call-sites-are-the-two-product-functions' (($siteList.Count -eq 2) -and ($siteList[0] -eq 'Invoke-DenGoProductInstall') -and ($siteList[1] -eq 'Invoke-DenGoProductUninstall')) ('DgLock-TryAcquire call sites outside the core: ' + [string]::Join(', ', [string[]]$siteList)))

# ---------------------------------------------------------------- S3 Explicit only
foreach ($pair in @(@($pa, 'Invoke-DenGoProductInstall'), @($ua, 'Invoke-DenGoProductUninstall'))) {
    $fn = Get-FunctionAst $pair[0] $pair[1]
    $acq = Get-CommandNodes $fn 'DgLock-TryAcquire'
    $okExplicit = $false
    if ($acq.Count -eq 1) { $els = @($acq[0].CommandElements); $okExplicit = (($els.Count -eq 3) -and ($els[2] -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ([string]$els[2].Value -ceq 'Explicit')) }
    $defaultUsed = @($fn.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$x.Value -ceq 'Default' }, $true)).Count
    [void](Assert-I2A ('S3-explicit-dacl-only-' + $pair[1]) ($okExplicit -and ($defaultUsed -eq 0)) ("acquire calls=$($acq.Count) explicit=$okExplicit 'Default' literals=$defaultUsed"))
}

# ---------------------------------------------------------------- S4 / S5 the DACL: current user + BUILTIN\Administrators, Synchronize|Modify, Allow only
$secFn = Get-FunctionAst $ca 'DgLock-NewSecurity'
$wk = @(Get-StaticMembers $secFn 'WellKnownSidType' | Sort-Object -Unique)
$loopVars = New-Object System.Collections.ArrayList
foreach ($fe in @($secFn.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))) {
    foreach ($v in @($fe.Condition.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) { [void]$loopVars.Add([string]$v.VariablePath.UserPath) }
}
$secText = $secFn.Extent.Text
[void](Assert-I2A 'S4-dacl-sids-are-current-user-and-administrators-only' (($wk.Count -eq 1) -and ($wk[0] -eq 'BuiltinAdministratorsSid') -and (([string]::Join(',', [string[]]@($loopVars | Sort-Object))) -eq 'adm,me') -and ($secText.IndexOf('GetCurrent().User', [System.StringComparison]::Ordinal) -ge 0)) ('well-known SIDs: ' + [string]::Join(',', $wk) + '; SIDs granted: ' + [string]::Join(',', [string[]]$loopVars)))
$rightsUsed = @(Get-StaticMembers $secFn 'MutexRights' | Sort-Object -Unique)
$typesUsed = @(Get-StaticMembers $secFn 'AccessControlType' | Sort-Object -Unique)
[void](Assert-I2A 'S5-dacl-rights-are-synchronize-and-modify-allow-only' (([string]::Join(',', $rightsUsed) -eq 'Modify,Synchronize') -and ([string]::Join(',', $typesUsed) -eq 'Allow')) ('rights: ' + [string]::Join(',', $rightsUsed) + '; access types: ' + [string]::Join(',', $typesUsed) + ' (no FullControl, no Deny)'))

# ---------------------------------------------------------------- S6 never waits
$tryFn = Get-FunctionAst $ca 'DgLock-TryAcquire'
$waitOnes = @($tryFn.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and (Get-MemberName $x) -like 'Wait*' }, $true))
$waitArgs = @()
if ($waitOnes.Count -eq 1 -and $null -ne $waitOnes[0].Arguments) { $waitArgs = @($waitOnes[0].Arguments) }   # WaitOne() has no arguments: Arguments can be $null
$zeroWait = (($waitOnes.Count -eq 1) -and ((Get-MemberName $waitOnes[0]) -eq 'WaitOne') -and ($waitArgs.Count -eq 1) -and ($waitArgs[0] -is [System.Management.Automation.Language.ConstantExpressionAst]) -and ($waitArgs[0].Value -eq 0))
$sleeps = @($tryFn.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and (([string]$x.GetCommandName()) -like 'Wait-*' -or ([string]$x.GetCommandName()) -eq 'Start-Sleep') }, $true))
[void](Assert-I2A 'S6-acquire-never-waits-WaitOne-0-only' ($zeroWait -and ($sleeps.Count -eq 0)) ("Wait* calls=$($waitOnes.Count) WaitOne(0)=$zeroWait sleep/Wait- commands=$($sleeps.Count)"))

# ---------------------------------------------------------------- S7 the lock belongs to the engine only
foreach ($f in $guiFiles + $startFiles) {
    $t = Get-Text $f
    [void](Assert-I2A ('S7-no-lock-in-' + [System.IO.Path]::GetFileName($f)) (($t.IndexOf('Mutex', [System.StringComparison]::Ordinal) -lt 0) -and ($t.IndexOf('DgLock', [System.StringComparison]::Ordinal) -lt 0)) 'no Mutex / DgLock token (the GUI and the Start scripts never hold a lock)')
}

# ---------------------------------------------------------------- S8 the comments say what the code does now
$coreText = Get-Text $core; $productText = Get-Text $product
[void](Assert-I2A 'S8-core-lock-comment-is-not-stale' ($coreText.IndexOf('not wired to any engine', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'DenGoInstallerTransaction.ps1 no longer says the mutex is not wired to any engine')
[void](Assert-I2A 'S8-product-lock-comment-is-not-provisional' ($productText.IndexOf('provisional', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'DenGoInstallerProductApply.ps1 no longer calls the lock name provisional')

# ---------------------------------------------------------------- S14 / S15 the wrapper templates: ASCII only, helper byte-for-byte the pinned one
$templates = Get-I2DBuilderTemplates
foreach ($kind in 'Setup', 'Uninstall') {
    $text = [string]$templates[$kind]
    $nonAscii = 0; foreach ($ch in $text.ToCharArray()) { if ([int]$ch -gt 127) { $nonAscii++ } }
    [void](Assert-I2A ('S14-template-is-ascii-only-' + $kind) ($nonAscii -eq 0) "non-ASCII characters: $nonAscii (the builder writes the module with ASCII encoding)")
}
$un = [string]$templates['Uninstall']
$b64 = [regex]::Match($un, 'b64decode\("([A-Za-z0-9+/=]+)"\)')
$decodedSha = ''
if ($b64.Success) { $sha = [System.Security.Cryptography.SHA256]::Create(); try { $decodedSha = ([System.BitConverter]::ToString($sha.ComputeHash([System.Convert]::FromBase64String($b64.Groups[1].Value)))).Replace('-', '') } finally { $sha.Dispose() } }
$hexLiterals = @([regex]::Matches($un, '"([0-9A-F]{64})"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne ('0' * 64) })
$otherHex = @($hexLiterals | Where-Object { $_ -ne $script:I2DHelperSha256 })
[void](Assert-I2A 'S15-self-delete-helper-is-unchanged' ($b64.Success -and ($decodedSha -ceq $script:I2DHelperSha256) -and ($hexLiterals.Count -ge 3) -and ($otherHex.Count -eq 0)) ("decoded helper SHA-256 = $decodedSha; pinned literals in the template: $($hexLiterals.Count); other hash literals: $($otherHex.Count)"))

# ---------------------------------------------------------------- S20 a dry run takes no lock; S21 an abandoned mutex is never read as a decision
$lockTokens = New-Object System.Collections.ArrayList
$dryFn = Get-FunctionAst $ua 'Get-DenGoUninstallDryRun'
foreach ($fn in @($dryFn, (Get-FunctionAst $pa 'Get-DenGoRecoveryGate'), (Get-FunctionAst $ua 'Get-DenGoUninstallRecoveryGate'))) {
    foreach ($c in @($fn.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and (([string]$x.GetCommandName()) -like 'DgLock-*' -or ([string]$x.GetCommandName()) -eq 'Get-DenGoLockName') }, $true))) { [void]$lockTokens.Add($fn.Name + ':' + $c.GetCommandName()) }
}
foreach ($f in @((Join-Path $scripts 'Invoke-DenGoInstaller.ps1'), (Join-Path $scripts 'Invoke-DenGoUninstaller.ps1'))) {
    $ast = Get-I2AScriptAst $f
    foreach ($c in @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and (([string]$x.GetCommandName()) -like 'DgLock-*' -or ([string]$x.GetCommandName()) -eq 'Get-DenGoLockName') }, $true))) { [void]$lockTokens.Add([System.IO.Path]::GetFileName($f) + ':' + $c.GetCommandName()) }
}
[void](Assert-I2A 'S20-dryrun-and-recovery-report-take-no-lock' ($lockTokens.Count -eq 0) ('lock commands in the dry-run / report paths and the engine scripts: ' + [string]::Join(', ', [string[]]@($lockTokens))))
$abandonOwners = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -LiteralPath $scripts -Filter '*.ps1' | ForEach-Object { $_.FullName }) + $guiFiles) {
    $ast = Get-I2AScriptAst $f
    $nodes = @($ast.FindAll({ param($x)
        ($x -is [System.Management.Automation.Language.VariableExpressionAst] -and ([string]$x.VariablePath.UserPath) -ieq 'abandoned') -or
        ($x -is [System.Management.Automation.Language.MemberExpressionAst] -and (Get-MemberName $x) -ieq 'Abandoned') -or
        ($x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ([string]$x.Value) -ieq 'Abandoned') }, $true))
    foreach ($n in $nodes) { [void]$abandonOwners.Add([System.IO.Path]::GetFileName($f) + ':' + (Get-OwnerFunctionName $n)) }
}
$badAbandon = @($abandonOwners | Where-Object { $_ -ne 'DenGoInstallerTransaction.ps1:DgLock-TryAcquire' })
[void](Assert-I2A 'S21-abandoned-is-recorded-only-never-read-as-a-decision' (($badAbandon.Count -eq 0) -and ($abandonOwners.Count -ge 1)) ("uses of 'Abandoned' outside DgLock-TryAcquire: $($badAbandon.Count) (" + [string]::Join(', ', [string[]]@($badAbandon | Select-Object -First 4)) + "); inside: $($abandonOwners.Count - $badAbandon.Count)"))

# ---------------------------------------------------------------- wrapper structure (Python ast)
$sandbox = New-I2ASandbox 'i2d-static'
try {
    $setupPy = Join-Path $sandbox 'setup_module.py'; $uninstallPy = Join-Path $sandbox 'uninstall_module.py'
    [System.IO.File]::WriteAllText($setupPy, [string]$templates['Setup'], [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($uninstallPy, [string]$templates['Uninstall'], [System.Text.Encoding]::ASCII)
    $python = Get-I2DPython
    $run = Invoke-I2DPython $python @('-I', (Join-Path $PSScriptRoot 'i2d_wrapper_tests.py'), 'static', $setupPy, $uninstallPy, [string]$engineName) @{} $sandbox 120000
    $n = Import-I2DPythonResults $run.Stdout
    [void](Assert-I2A 'S-wrapper-structure-checks-ran' (($run.ExitCode -in @(0, 1)) -and ($n -ge 20) -and ($run.Stderr.Trim().Length -eq 0)) ("python exit=$($run.ExitCode) results=$n stderr=[$($run.Stderr.Trim())]"))
} finally { Remove-I2ASandbox $sandbox }
Complete-I2ATests
