# I2-D wrapper behaviour tests (written RED first; plan section 5.4, W0..W13).
# Extracts the Python modules from Build-DenGo-SetupExe-2.0.0.ps1 with the PowerShell AST (same extraction as the I1 wrapper tests), writes them to a sandbox under
# TEMP and runs i2d_wrapper_tests.py there in "behavior" mode against REAL Win32 mutexes with throw-away names (Global\DenGoI2DTest-<uuid>).
# No generated EXE and no real registry are used: winreg, MessageBox, the self-delete helper process and the engine PowerShell are replaced inside the Python test,
# LOCALAPPDATA / TEMP / TMP point at the sandbox, and the module's LOCK_NAME is patched to the throw-away name before main() runs.
# The structure checks of the same templates (S9..S13, S16, S18, S19) live in Test-DenGoInstaller-I2D-Static.ps1.
. (Join-Path $PSScriptRoot 'I2D.TestSupport.ps1')
$sandbox = New-I2ASandbox 'i2d-wrapper'
try {
    foreach ($sub in 'LocalAppData', 'Temp') { [System.IO.Directory]::CreateDirectory((Join-Path $sandbox $sub)) | Out-Null }
    $templates = Get-I2DBuilderTemplates
    $setupPy = Join-Path $sandbox 'setup_module.py'
    $uninstallPy = Join-Path $sandbox 'uninstall_module.py'
    [System.IO.File]::WriteAllText($setupPy, [string]$templates['Setup'], [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($uninstallPy, [string]$templates['Uninstall'], [System.Text.Encoding]::ASCII)
    $python = Get-I2DPython
    $compile = Invoke-I2DPython $python @('-I', '-m', 'py_compile', $setupPy, $uninstallPy) @{} $sandbox 120000
    [void](Assert-I2A 'WRAPPER-PY-COMPILE' ($compile.ExitCode -eq 0) ('py_compile exit=' + $compile.ExitCode + ' ' + $compile.Stderr.Trim()))
    $environment = @{ LOCALAPPDATA = (Join-Path $sandbox 'LocalAppData'); TEMP = (Join-Path $sandbox 'Temp'); TMP = (Join-Path $sandbox 'Temp') }
    $child = Join-Path $PSScriptRoot 'I2D.LockChild.ps1'
    $run = Invoke-I2DPython $python @('-I', (Join-Path $PSScriptRoot 'i2d_wrapper_tests.py'), 'behavior', $setupPy, $uninstallPy, $child) $environment $sandbox 900000
    $count = Import-I2DPythonResults $run.Stdout 'WRAPPER-'
    [void](Assert-I2A 'WRAPPER-PY-RAN' (($run.ExitCode -in @(0, 1)) -and ($count -ge 40) -and ($run.Stderr.Trim().Length -eq 0)) ("python exit=$($run.ExitCode) results=$count stderr=[$($run.Stderr.Trim())]"))
} finally {
    Remove-I2ASandbox $sandbox
}
Complete-I2ATests
