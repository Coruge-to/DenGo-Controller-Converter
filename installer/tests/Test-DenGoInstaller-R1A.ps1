$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$files = @(
    'installer\scripts\Start-DenGoSetup.ps1',
    'installer\scripts\Start-DenGoUninstall.ps1',
    'installer\gui\DenGoInstallerGui.ps1',
    'installer\gui\DenGoUninstallerGui.ps1'
)
$pass = 0
$fail = 0
$results = New-Object System.Collections.ArrayList
function Add-Result {
    param([string]$Id,[bool]$Passed,[string]$Detail)
    if ($Passed) { $script:pass++ } else { $script:fail++ }
    [void]$script:results.Add(('{0} | {1} | {2}' -f $(if($Passed){'PASS'}else{'FAIL'}),$Id,$Detail))
}
foreach ($relative in $files) {
    $path = Join-Path $repo $relative
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Add-Result ('PARSE-' + [System.IO.Path]::GetFileName($relative)) (@($errors).Count -eq 0) ('ParseErrorCount=' + [string]@($errors).Count)
    $text = [System.IO.File]::ReadAllText($path,[System.Text.Encoding]::UTF8)
    Add-Result ('HELPER-' + [System.IO.Path]::GetFileName($relative)) ($text.IndexOf('function Join-NativeArguments',[System.StringComparison]::Ordinal) -ge 0) 'Join-NativeArguments exists'
    Add-Result ('NO-DIRECT-ARRAY-' + [System.IO.Path]::GetFileName($relative)) ($text.IndexOf('-ArgumentList $args',[System.StringComparison]::Ordinal) -lt 0 -and $text.IndexOf('-ArgumentList $arguments',[System.StringComparison]::Ordinal) -lt 0) 'Direct array ArgumentList is absent'
}
$helper = {
    param([string[]]$Values)
    $parts = New-Object System.Collections.ArrayList
    foreach ($value in @($Values)) {
        $text = [string]$value
        if ($text.IndexOf([char]34) -ge 0) { throw 'A process argument contains a double quote.' }
        $trailing = 0
        for ($index = $text.Length - 1; $index -ge 0 -and $text[$index] -eq [char]92; $index--) { $trailing++ }
        $suffix = if ($trailing -gt 0) { [string][char]92 * $trailing } else { '' }
        [void]$parts.Add(([string][char]34 + $text + $suffix + [string][char]34))
    }
    return [string]::Join(' ',[string[]]@($parts))
}
$jp = ([string][char]26085) + ([string][char]26412) + ([string][char]35486)
$deep = ([string][char]28145) + ([string][char]12356)
$scriptPath = 'C:\Temp\DenGo R1A ' + $jp + ' (Test)\installer\scripts\Invoke.ps1'
$resultPath = 'C:\Temp\' + $deep + ' path (A)\result'
$line = & $helper @($scriptPath,'-OutputRoot',$resultPath)
Add-Result 'QUOTED-PATHS' ($line.IndexOf(([string][char]34 + $scriptPath + [string][char]34),[System.StringComparison]::Ordinal) -ge 0 -and $line.IndexOf(([string][char]34 + $resultPath + [string][char]34),[System.StringComparison]::Ordinal) -ge 0) $line
$quoteRejected = $false
try { [void](& $helper @('bad"argument')) } catch { $quoteRejected = $true }
Add-Result 'REJECT-QUOTE' $quoteRejected 'Embedded quote is rejected'
$rootLine = & $helper @('D:\')
Add-Result 'TRAILING-BACKSLASH' ($rootLine -eq '"D:\\"') $rootLine
$installerGui = [System.IO.File]::ReadAllText((Join-Path $repo 'installer\gui\DenGoInstallerGui.ps1'),[System.Text.Encoding]::UTF8)
$uninstallerGui = [System.IO.File]::ReadAllText((Join-Path $repo 'installer\gui\DenGoUninstallerGui.ps1'),[System.Text.Encoding]::UTF8)
$malformedPattern = '\$script:process\s*=\s*\$argumentLine\s*=\s*Join-NativeArguments'
$processCapturePattern = '\$script:process\s*=\s*Start-Process\s+powershell\.exe\s+-ArgumentList\s+\$argumentLine'
$installerMalformedMatches = @([System.Text.RegularExpressions.Regex]::Matches($installerGui,$malformedPattern))
$uninstallerMalformedMatches = @([System.Text.RegularExpressions.Regex]::Matches($uninstallerGui,$malformedPattern))
$installerProcessMatches = @([System.Text.RegularExpressions.Regex]::Matches($installerGui,$processCapturePattern))
$uninstallerProcessMatches = @([System.Text.RegularExpressions.Regex]::Matches($uninstallerGui,$processCapturePattern))
Add-Result 'INSTALLER-NO-MALFORMED-PROCESS-CAPTURE' (@($installerMalformedMatches).Count -eq 0) ('Count=' + [string]@($installerMalformedMatches).Count)
Add-Result 'UNINSTALLER-NO-MALFORMED-PROCESS-CAPTURE' (@($uninstallerMalformedMatches).Count -eq 0) ('Count=' + [string]@($uninstallerMalformedMatches).Count)
Add-Result 'INSTALLER-PROCESS-CAPTURE' (@($installerProcessMatches).Count -eq 2) ('Count=' + [string]@($installerProcessMatches).Count)
Add-Result 'UNINSTALLER-PROCESS-CAPTURE' (@($uninstallerProcessMatches).Count -eq 1) ('Count=' + [string]@($uninstallerProcessMatches).Count)
$runtimeProcess = Start-Process powershell.exe -ArgumentList '-NoProfile -Command "exit 0"' -PassThru -WindowStyle Hidden
try {
    Add-Result 'RUNTIME-PROCESS-TYPE' ($runtimeProcess -is [System.Diagnostics.Process]) ([string]$runtimeProcess.GetType().FullName)
    $runtimeProcess.WaitForExit()
    Add-Result 'RUNTIME-HASEXITED' ([bool]$runtimeProcess.HasExited) ('ExitCode=' + [string]$runtimeProcess.ExitCode)
} finally {
    $runtimeProcess.Dispose()
}Write-Host ('PASS={0} FAIL={1}' -f $pass,$fail)
foreach ($result in $results) { Write-Host $result }
if ($fail -ne 0) { exit 1 }