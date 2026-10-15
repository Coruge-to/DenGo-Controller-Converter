$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = 'C:\Users\tsuru\Documents\Program\DenGo-Controller-Converter-Separate'
$sourceRoot = Join-Path $repo 'installer'
$downloads = Join-Path $env:USERPROFILE 'Downloads'
$packageName = 'DenGo-Controller-Converter-Setup-2.0.0'
$packageRoot = Join-Path $downloads $packageName
$zipPath = Join-Path $downloads ($packageName + '.zip')
$reportPath = Join-Path $downloads 'DenGo-SetupPackage-v1.txt'
$requiredFiles = @(
    'assets\images\DenGo-Controller-Converter2.png',
    'assets\images\DenGo-Controller-Converter.ico',
    'scripts\Start-DenGoSetup.ps1',
    'assets\input-profiles\pcsx2\DenGo-Controller-Converter.lily',
    'assets\input-profiles\rpcs3\Den-Go-Controller.yml',
    'build\payload\DenGoControllerConverter.exe',
    'build\payload\DenGoControllerConverter.dll',
    'build\payload\DenGoVehicleSpec.BveEx.Bridge.dll',
    'build\payload\DenGoBveVehicleSpec.dll',
    'build\payload\DenGoVehicleSpec.AtsExLegacy.Bridge.dll',
    'build\payload\DenGoAtsExLegacyVehicleSpec.dll',
    'build\payload\payload-manifest.json',
    'gui\DenGoInstallerGui.ps1',
    'gui\DenGoUninstallerGui.ps1',
    'scripts\Invoke-DenGoInstaller.ps1',
    'scripts\Invoke-DenGoUninstaller.ps1',
    'scripts\DenGoInstallerTransaction.ps1',
    'scripts\DenGoInstallerProductApply.ps1'
)

try {
    if (-not [System.IO.Directory]::Exists($sourceRoot)) { throw ('Installer source not found: ' + $sourceRoot) }
    $head = ([string](& git.exe -C $repo rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'git rev-parse HEAD failed.' }
    $staged = @(& git.exe -C $repo diff --cached --name-only)
    if ($LASTEXITCODE -ne 0) { throw 'git staged inspection failed.' }
    if (@($staged).Count -ne 0) { throw 'Existing staged changes were found.' }

    foreach ($relative in $requiredFiles) {
        $path = Join-Path $sourceRoot $relative
        if (-not [System.IO.File]::Exists($path)) { throw ('Required package file missing: ' + $relative) }
    }

    if ([System.IO.Directory]::Exists($packageRoot)) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
    if ([System.IO.File]::Exists($zipPath)) { Remove-Item -LiteralPath $zipPath -Force }
    [System.IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    Copy-Item -LiteralPath $sourceRoot -Destination (Join-Path $packageRoot 'installer') -Recurse -Force

    $setupCmd = @(
        '@echo off',
        'setlocal',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\scripts\Start-DenGoSetup.ps1"',
        'set EXITCODE=%ERRORLEVEL%',
        'endlocal & exit /b %EXITCODE%'
    )
    $uninstallCmd = @(
        '@echo off',
        'setlocal',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\scripts\Start-DenGoUninstall.ps1"',
        'set EXITCODE=%ERRORLEVEL%',
        'endlocal & exit /b %EXITCODE%'
    )
    [System.IO.File]::WriteAllLines((Join-Path $packageRoot 'Setup.cmd'),[string[]]@($setupCmd),(New-Object System.Text.ASCIIEncoding))
    [System.IO.File]::WriteAllLines((Join-Path $packageRoot 'Uninstall.cmd'),[string[]]@($uninstallCmd),(New-Object System.Text.ASCIIEncoding))

    $manifestFiles = New-Object System.Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($packageRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        [void]$manifestFiles.Add([pscustomobject][ordered]@{
            Path=$relative
            Bytes=[int64]$file.Length
            SHA256=([string](Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash).ToUpperInvariant()
        })
    }
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion=1
        Product='DenGo Controller Converter'
        ProductVersion='2.0.0'
        SourceCommit=$head
        Generated=[System.DateTimeOffset]::Now.ToString('o')
        Files=[object[]]@($manifestFiles)
    }
    $manifestPath = Join-Path $packageRoot 'package-manifest.json'
    [System.IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),(New-Object System.Text.UTF8Encoding($true)))

    Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $zipSha = ([string](Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash).ToUpperInvariant()
    $packageFileCount = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse).Count
    $lines = @(
        'RESULT: SUCCESS',
        ('SourceCommit: ' + $head),
        ('PackageRoot: ' + $packageRoot),
        ('PackageFileCount: ' + [string]$packageFileCount),
        ('Zip: ' + $zipPath),
        ('ZipBytes: ' + [string](Get-Item -LiteralPath $zipPath).Length),
        ('ZipSHA256: ' + $zipSha),
        'SetupEntryPoint: Setup.cmd',
        'UninstallEntryPoint: Uninstall.cmd'
    )
    [System.IO.File]::WriteAllLines($reportPath,[string[]]@($lines),(New-Object System.Text.UTF8Encoding($true)))
    Write-Host 'RESULT: SUCCESS'
    Write-Host ('SourceCommit: ' + $head)
    Write-Host ('PackageRoot: ' + $packageRoot)
    Write-Host ('PackageFileCount: ' + [string]$packageFileCount)
    Write-Host ('Zip: ' + $zipPath)
    Write-Host ('ZipSHA256: ' + $zipSha)
    Write-Host ('Report: ' + $reportPath)
} catch {
    Write-Host 'RESULT: FAILED'
    Write-Host ('Message: ' + [string]$_.Exception.Message)
    Write-Host ($_ | Out-String)
    throw
}
