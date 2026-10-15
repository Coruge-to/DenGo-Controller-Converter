# I1 wrapper tests (T2): runs i1_wrapper_tests.py against the Python templates embedded in Build-DenGo-SetupExe-2.0.0.ps1.
# The templates are extracted with the PowerShell AST, written to a sandbox under TEMP and exercised there.
# winreg, MessageBox, the self-delete helper and the child PowerShell are replaced inside the Python test; nothing real is touched.
. (Join-Path $PSScriptRoot 'I1.TestSupport.ps1')

$sandbox = New-I1Sandbox 'wrapper'
try {
    $templates = Get-BuilderTemplates
    $setupPy = Join-Path $sandbox 'setup_module.py'
    $uninstallPy = Join-Path $sandbox 'uninstall_module.py'
    [System.IO.File]::WriteAllText($setupPy, $templates.Setup, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($uninstallPy, $templates.Uninstall, [System.Text.Encoding]::ASCII)

    $python = Join-Path $script:I1Repo 'venv_exe\Scripts\python.exe'
    if (-not [System.IO.File]::Exists($python)) {
        $command = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) { throw 'No Python interpreter was found (venv_exe or PATH).' }
        $python = $command.Source
    }

    $compile = New-Object System.Diagnostics.ProcessStartInfo
    $compile.FileName = $python
    $compile.Arguments = ('-I -m py_compile "{0}" "{1}"' -f $setupPy, $uninstallPy)
    $compile.UseShellExecute = $false; $compile.RedirectStandardOutput = $true; $compile.RedirectStandardError = $true; $compile.CreateNoWindow = $true
    $compileProcess = [System.Diagnostics.Process]::Start($compile)
    [void]$compileProcess.StandardOutput.ReadToEnd(); $compileError = $compileProcess.StandardError.ReadToEnd(); $compileProcess.WaitForExit()
    Add-I1Result 'WRAPPER-PY-COMPILE' ($compileProcess.ExitCode -eq 0) ('py_compile exit=' + $compileProcess.ExitCode + ' ' + $compileError.Trim())

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $python
    $info.Arguments = ('-I "{0}" "{1}" "{2}"' -f (Join-Path $PSScriptRoot 'i1_wrapper_tests.py'), $setupPy, $uninstallPy)
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
    $info.WorkingDirectory = $sandbox
    $info.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $sandbox 'LocalAppData')
    $info.EnvironmentVariables['TEMP'] = (Join-Path $sandbox 'Temp')
    $info.EnvironmentVariables['TMP'] = (Join-Path $sandbox 'Temp')
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd(); $stderr = $process.StandardError.ReadToEnd()
    if (-not $process.WaitForExit(240000)) { $process.Kill(); throw 'Python wrapper tests timed out.' }
    foreach ($line in ($stdout -split "`r?`n")) {
        if ($line -match '^(PASS|FAIL) \| ([^|]+) \| ?(.*)$') { Add-I1Result ('WRAPPER-' + $Matches[2].Trim()) ($Matches[1] -eq 'PASS') $Matches[3] }
    }
    Add-I1Result 'WRAPPER-PY-EXIT' ($process.ExitCode -eq 0) ('python exit=' + $process.ExitCode + $(if ($stderr.Trim()) { ' stderr=' + $stderr.Trim() } else { '' }))
} finally {
    Remove-I1Sandbox $sandbox
}
Complete-I1Tests
