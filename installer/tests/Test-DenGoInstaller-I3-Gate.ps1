# I3 process-gate tests (written RED first; owner decision DE-I3-8): every gate that guards a PCSX2 write uses ONE name rule, pcsx2*.exe, which includes pcsx2.exe and pcsx2-qt.exe.
# The real gate functions are extracted from the product scripts by AST (the scripts themselves are never run) and called with a fake process list: Get-CimInstance is replaced by a
# function that returns synthetic processes, so no real process is looked at. The process name or count is never a version decision (see C-07 in the Unit suite).
#   G-1x  installer engine: Get-RunningTargetProducts / Assert-TargetProcessesStopped
#   G-2x  installer GUI and uninstaller GUI: Get-RunningProductNames
#   G-3x  uninstaller engine: Assert-TargetProcessesStopped
#   G-4x  the other products keep their own gates (controls)
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')
$repo = $script:I3Repo
$engineI = Join-Path $repo 'installer\scripts\Invoke-DenGoInstaller.ps1'
$engineU = Join-Path $repo 'installer\scripts\Invoke-DenGoUninstaller.ps1'
$guiI = Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1'
$guiU = Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'

function Get-Fn([string]$Path, [string]$Name) {
    $ast = Get-I2AScriptAst $Path
    $f = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true))
    if ($f.Count -ne 1) { return $null }
    return $f[0]
}
$global:I3Procs = @()
function global:Get-CimInstance { param([Parameter(Position = 0)][string]$ClassName) return @($global:I3Procs) }
function Set-Procs([string[]]$Names) { $global:I3Procs = @($Names | ForEach-Object { [pscustomobject]@{ Name = $_; ExecutablePath = ('C:\fake\' + $_); CommandLine = ('C:\fake\' + $_) } }) }

$blocked = @('pcsx2.exe', 'PCSX2.EXE', 'pcsx2-qt.exe', 'Pcsx2-Qt.exe', 'pcsx2-r5875.exe', 'pcsx2x64-avx2.exe', 'pcsx2_dev.exe', 'pcsx2-1.7.0-dev.exe', 'pcsx2-setup.exe')
$notBlocked = @('Uninst-pcsx2.exe', 'xpcsx2.exe', 'pcsx2.exe.bak', 'pcsx2', 'pcsx2.dll', 'notepad.exe', 'my-pcsx2.exe')

# ---------------------------------------------------------------- the product-name list of the engine and of both GUIs
$fnProducts = Get-Fn $engineI 'Get-RunningTargetProducts'
$fnGiNames = Get-Fn $guiI 'Get-RunningProductNames'
$fnGiPe = Get-Fn $guiI 'Get-PeMachineForRunningProduct'
$fnGuNames = Get-Fn $guiU 'Get-RunningProductNames'
$fnGuPe = Get-Fn $guiU 'Get-PeMachineForRunningProduct'
$fnAssertI = Get-Fn $engineI 'Assert-TargetProcessesStopped'
$fnAssertU = Get-Fn $engineU 'Assert-TargetProcessesStopped'
[void](Assert-I2A 'G-00-every-gate-function-exists-once' (($null -ne $fnProducts) -and ($null -ne $fnGiNames) -and ($null -ne $fnGuNames) -and ($null -ne $fnAssertI) -and ($null -ne $fnAssertU)) 'engine Get-RunningTargetProducts / Assert-TargetProcessesStopped (x2), GUI Get-RunningProductNames (x2)')

function Invoke-Products([string]$Which, [string[]]$Names) {
    Set-Procs $Names
    return (Invoke-I3 {
            if ($Which -eq 'engine') { Invoke-Expression $fnProducts.Extent.Text; return @(Get-RunningTargetProducts) }
            if ($Which -eq 'guiI') { Invoke-Expression $fnGiPe.Extent.Text; Invoke-Expression $fnGiNames.Extent.Text; return @(Get-RunningProductNames) }
            if ($Which -eq 'guiU') { Invoke-Expression $fnGuPe.Extent.Text; Invoke-Expression $fnGuNames.Extent.Text; return @(Get-RunningProductNames) }
        })
}
foreach ($which in @(@('engine', 'G-1'), @('guiI', 'G-2a'), @('guiU', 'G-2b'))) {
    foreach ($n in $blocked) {
        $r = Invoke-Products $which[0] @($n)
        [void](Assert-I2A ($which[1] + '-' + $which[0] + '-blocks-' + $n) ($r.Ok -and (@($r.Value) -contains 'PCSX2')) ('products: [' + $(if ($r.Ok) { @($r.Value) -join ',' } else { $r.Error }) + ']'))
    }
    foreach ($n in $notBlocked) {
        $r = Invoke-Products $which[0] @($n)
        [void](Assert-I2A ($which[1] + '-' + $which[0] + '-does-not-block-' + $n) ($r.Ok -and (@($r.Value) -cnotcontains 'PCSX2')) ('products: [' + $(if ($r.Ok) { @($r.Value) -join ',' } else { $r.Error }) + ']'))
    }
    # one process of the family among others: the family is named once
    $r = Invoke-Products $which[0] @('notepad.exe', 'pcsx2-qt.exe', 'pcsx2.exe', 'pcsx2-r5875.exe')
    [void](Assert-I2A ($which[1] + '-' + $which[0] + '-names-PCSX2-once-for-several-processes') ($r.Ok -and (@(@($r.Value) | Where-Object { $_ -ceq 'PCSX2' }).Count -eq 1)) ('products: [' + $(if ($r.Ok) { @($r.Value) -join ',' } else { $r.Error }) + ']'))
}

# ---------------------------------------------------------------- the engines' Assert-TargetProcessesStopped refuse (they throw) and name the products
function Invoke-Assert([string]$Which, [string[]]$Names) {
    Set-Procs $Names
    return (Invoke-I3 {
            if ($Which -eq 'engineI') { Invoke-Expression $fnProducts.Extent.Text; & $fnAssertI.Body.GetScriptBlock() }
            else { & $fnAssertU.Body.GetScriptBlock() }
        })
}
foreach ($which in @(@('engineI', 'G-1x'), @('engineU', 'G-3'))) {
    foreach ($n in $blocked) {
        $r = Invoke-Assert $which[0] @($n)
        [void](Assert-I2A ($which[1] + '-' + $which[0] + '-assert-refuses-' + $n) ((-not $r.Ok) -and ($r.Error -imatch 'pcsx2|BlockedByRunningProcesses|Close target processes')) ('threw: ' + $r.Error))
    }
    foreach ($n in $notBlocked) {
        $r = Invoke-Assert $which[0] @($n)
        [void](Assert-I2A ($which[1] + '-' + $which[0] + '-assert-passes-' + $n) $r.Ok ('threw: ' + $r.Error))
    }
}
$r = Invoke-Assert 'engineI' @('pcsx2-r5875.exe')
[void](Assert-I2A 'G-1y-the-installer-refusal-carries-the-BlockedByRunningProcesses-contract-text' ((-not $r.Ok) -and ($r.Error -like '*BlockedByRunningProcesses|RunningProducts=PCSX2*')) ('threw: ' + $r.Error))

# ---------------------------------------------------------------- controls: the other products are gated as before
foreach ($case in @(@('BveTs.exe', 'BVE Trainsim'), @('rpcs3.exe', 'RPCS3'), @('DenGoControllerConverter.exe', 'DenGo Controller Converter'))) {
    $r = Invoke-Products 'engine' @($case[0])
    [void](Assert-I2A ('G-4-control-the-installer-engine-still-gates-' + $case[0]) ($r.Ok -and (@($r.Value) -contains $case[1])) ('products: [' + $(if ($r.Ok) { @($r.Value) -join ',' } else { $r.Error }) + ']'))
    $r = Invoke-Assert 'engineU' @($case[0])
    [void](Assert-I2A ('G-4b-control-the-uninstaller-engine-still-gates-' + $case[0]) (-not $r.Ok) ('threw: ' + $r.Error))
}
Remove-Item 'function:global:Get-CimInstance'
Complete-I2ATests
