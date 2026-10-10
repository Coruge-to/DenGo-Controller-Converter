param(
    [switch]$DryRun,
    [switch]$Apply,
    [string]$TestRoot = '',
    [switch]$RealSystem,
    [string]$ConfirmRealApply = '',
    [switch]$AdditionalSearch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($DryRun -and $Apply) {
    throw 'Specify either -DryRun or -Apply, not both.'
}
if (-not $DryRun -and -not $Apply) {
    throw 'Specify -DryRun or -Apply.'
}
if ($RealSystem -and -not $Apply) {
    throw '-RealSystem requires -Apply.'
}
if ($Apply -and $RealSystem) {
    if (-not [string]::Equals($ConfirmRealApply,'INSTALL',[System.StringComparison]::Ordinal)) { throw 'Real-system Apply requires -ConfirmRealApply INSTALL.' }
    if (-not [string]::IsNullOrWhiteSpace($TestRoot)) { throw 'Do not specify -TestRoot with -RealSystem.' }
} elseif ($Apply) {
    if ([string]::IsNullOrWhiteSpace($TestRoot)) { throw 'Sandbox Apply requires -TestRoot.' }
    $TestRoot = [System.IO.Path]::GetFullPath($TestRoot)
    $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $TestRoot.StartsWith($tempRoot,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Sandbox TestRoot must be under the current TEMP directory.' }
}


$scriptRoot = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
$installerRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$repo = [System.IO.Path]::GetFullPath((Join-Path $installerRoot '..'))
$payload = Join-Path $installerRoot 'build\payload'
$assets = Join-Path $installerRoot 'assets\input-profiles'
$outputRoot = Join-Path $env:TEMP 'DenGoInstallerPreview'
$textOutput = Join-Path $outputRoot 'install-plan.txt'
$jsonOutput = Join-Path $outputRoot 'install-plan.json'

function Get-Sha256 {
    param([string]$Path)
    return ([string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
}

function Get-PeMachine {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 'NotPE' }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { return 'InvalidPE' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { return 'InvalidPE' }
        $machine = $reader.ReadUInt16()
        if ($machine -eq 0x014C) { return 'x86' }
        if ($machine -eq 0x8664) { return 'x64' }
        if ($machine -eq 0xAA64) { return 'arm64' }
        return ('0x{0:X4}' -f $machine)
    } finally {
        $stream.Dispose()
    }
}

function Add-Executable {
    param([System.Collections.ArrayList]$List,[string]$Platform,[string]$Path,[string]$Source,[string]$Arguments)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return }
    $full = [System.IO.Path]::GetFullPath($Path.Trim().Trim([char]34))
    $key = $Platform + '|' + $full.ToUpperInvariant()
    if (@($List | Where-Object { [string]::Equals([string]$_.Key,$key,[System.StringComparison]::Ordinal) }).Count -eq 0) {
        [void]$List.Add([pscustomobject]@{Key=$key;Platform=$Platform;Executable=$full;Source=$Source;Arguments=$Arguments})
    }
}

function Get-Platform {
    param([string]$Name)
    if ([string]::Equals($Name,'BveTs.exe',[System.StringComparison]::OrdinalIgnoreCase)) { return 'BVE' }
    if ([string]::Equals($Name,'rpcs3.exe',[System.StringComparison]::OrdinalIgnoreCase)) { return 'RPCS3' }
    if ($Name -match '(?i)\Apcsx2[^\\/]*[.]exe\z') { return 'PCSX2' }
    return ''
}

function Get-DefaultExecutableCandidates {
    $result = New-Object System.Collections.ArrayList
    $paths = @(
        [pscustomobject]@{Platform='BVE';Path='C:\Program Files\mackoy\BveTs6\BveTs.exe'},
        [pscustomobject]@{Platform='BVE';Path='C:\Program Files (x86)\mackoy\BveTs5\BveTs.exe'},
        [pscustomobject]@{Platform='PCSX2';Path=(Join-Path $env:ProgramFiles 'PCSX2\pcsx2-qt.exe')},
        [pscustomobject]@{Platform='PCSX2';Path=(Join-Path $env:ProgramFiles 'PCSX2\pcsx2.exe')},
        [pscustomobject]@{Platform='PCSX2';Path=(Join-Path ${env:ProgramFiles(x86)} 'PCSX2\pcsx2.exe')},
        [pscustomobject]@{Platform='RPCS3';Path=(Join-Path $env:LOCALAPPDATA 'Programs\RPCS3\rpcs3.exe')},
        [pscustomobject]@{Platform='RPCS3';Path=(Join-Path $env:ProgramFiles 'RPCS3\rpcs3.exe')}
    )
    foreach ($item in $paths) {
        if ([System.IO.File]::Exists([string]$item.Path)) { [void]$result.Add($item) }
    }
    return [object[]]@($result)
}

function Add-ShortcutExecutable {
    param([System.Collections.ArrayList]$List,[string]$Scope,[string]$ShortcutPath,[object]$Shell)
    try {
        $shortcut = $Shell.CreateShortcut($ShortcutPath)
        $targetPath = [string]$shortcut.TargetPath
        $targetName = [System.IO.Path]::GetFileName($targetPath)
        $platform = Get-Platform $targetName
        if (-not [string]::IsNullOrWhiteSpace($platform)) {
            Add-Executable $List $platform $targetPath ($Scope + ':' + $ShortcutPath) ([string]$shortcut.Arguments)
            return
        }
        $shortcutName = [System.IO.Path]::GetFileNameWithoutExtension($ShortcutPath)
        $workingDirectory = [string]$shortcut.WorkingDirectory
        if ($shortcutName -match '(?i)bve\s*(?:trainsim)?\s*[56]?' -and -not [string]::IsNullOrWhiteSpace($workingDirectory)) {
            $bveCandidate = Join-Path $workingDirectory 'BveTs.exe'
            if ([System.IO.File]::Exists($bveCandidate)) { Add-Executable $List 'BVE' $bveCandidate ($Scope + '-Advertised:' + $ShortcutPath) '' }
        }
    } catch {
    }
}

function Add-ShortcutRootExecutables {
    param([System.Collections.ArrayList]$List,[string]$Scope,[string]$Root,[bool]$Recurse,[object]$Shell)
    if (-not [System.IO.Directory]::Exists($Root)) { return }
    $files = if ($Recurse) {
        @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    } else {
        @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue)
    }
    foreach ($file in @($files | Where-Object { [string]::Equals($_.Extension,'.lnk',[System.StringComparison]::OrdinalIgnoreCase) })) {
        Add-ShortcutExecutable $List $Scope $file.FullName $Shell
    }
}

function Add-FixedDriveExecutables {
    param([System.Collections.ArrayList]$List,[int]$MaxSecondsPerDrive)
    $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady })
    foreach ($drive in $drives) {
        $deadline = [System.Environment]::TickCount + ($MaxSecondsPerDrive * 1000)
        $pending = New-Object System.Collections.ArrayList
        [void]$pending.Add($drive.RootDirectory.FullName)
        while (@($pending).Count -gt 0 -and [System.Environment]::TickCount -lt $deadline) {
            $lastIndex = @($pending).Count - 1
            $directory = [string]$pending[$lastIndex]
            $pending.RemoveAt($lastIndex)
            try {
                foreach ($fileName in @('BveTs.exe','rpcs3.exe')) {
                    $path = Join-Path $directory $fileName
                    if ([System.IO.File]::Exists($path)) { Add-Executable $List (Get-Platform $fileName) $path ('AdditionalFixedDriveSearch:' + $drive.Name) '' }
                }
                foreach ($path in @([System.IO.Directory]::GetFiles($directory,'pcsx2*.exe',[System.IO.SearchOption]::TopDirectoryOnly))) {
                    $name = [System.IO.Path]::GetFileName($path)
                    if ($name -match '(?i)\Apcsx2[^\\/]*[.]exe\z') { Add-Executable $List 'PCSX2' $path ('AdditionalFixedDriveSearch:' + $drive.Name) '' }
                }
                foreach ($child in @([System.IO.Directory]::GetDirectories($directory))) {
                    $name = [System.IO.Path]::GetFileName($child)
                    if ($name -notin @('$Recycle.Bin','System Volume Information','WindowsApps')) { [void]$pending.Add($child) }
                }
            } catch {
            }
        }
    }
}

function Convert-ToSandboxDestination {
    param([string]$Destination,[string]$Root)
    $full = [System.IO.Path]::GetFullPath($Destination)
    $rootPart = [System.IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($rootPart.Length).TrimStart([char[]]@('\','/'))
    $safeRoot = $rootPart.Replace(':','').Replace('\','_').Replace('/','_')
    return Join-Path (Join-Path $Root $safeRoot) $relative
}

function Copy-VerifiedFile {
    param([string]$Source,[string]$Destination,[string]$BackupRoot)
    $parent = [System.IO.Path]::GetDirectoryName($Destination)
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $backup = ''
    if ([System.IO.File]::Exists($Destination)) {
        [System.IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
        $backup = Join-Path $BackupRoot ([System.Guid]::NewGuid().ToString('N') + '.bak')
        [System.IO.File]::Copy($Destination,$backup,$false)
    }
    $temporary = $Destination + '.dengo.tmp'
    [System.IO.File]::Copy($Source,$temporary,$true)
    if ((Get-Sha256 $temporary) -ne (Get-Sha256 $Source)) { throw 'Temporary copy SHA256 mismatch.' }
    [System.IO.File]::Copy($temporary,$Destination,$true)
    [System.IO.File]::Delete($temporary)
    if ((Get-Sha256 $Destination) -ne (Get-Sha256 $Source)) { throw 'Destination SHA256 mismatch.' }
    return $backup
}

function Invoke-SandboxApply {
    param([object[]]$Plan,[string]$Root)
    if ([System.IO.Directory]::Exists($Root)) { Remove-Item -LiteralPath $Root -Recurse -Force }
    [System.IO.Directory]::CreateDirectory($Root) | Out-Null
    $backupRoot = Join-Path $Root '_backups'
    $results = New-Object System.Collections.ArrayList
    foreach ($item in @($Plan)) {
        $sandboxDestination = Convert-ToSandboxDestination ([string]$item.Destination) $Root
        $action = [string]$item.Action
        if ([string]::Equals($action,'PreserveUserModified',[System.StringComparison]::Ordinal) -or [string]::Equals($action,'Unchanged',[System.StringComparison]::Ordinal)) {
            [void]$results.Add([pscustomobject]@{Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$sandboxDestination;Applied=$false})
            continue
        }
        if ([string]::Equals($action,'Add',[System.StringComparison]::Ordinal) -or [string]::Equals($action,'UpdateOrRepair',[System.StringComparison]::Ordinal)) {
            [void](Copy-VerifiedFile ([string]$item.Source) $sandboxDestination $backupRoot)
            [void]$results.Add([pscustomobject]@{Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$sandboxDestination;Applied=$true})
            continue
        }
        [void]$results.Add([pscustomobject]@{Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$sandboxDestination;Applied=$false})
    }
    return [object[]]@($results)
}
function Assert-TargetProcessesStopped {
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        [string]::Equals([string]$_.Name,'BveTs.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'rpcs3.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'DenGoControllerConverter.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.Name -match '(?i)\Apcsx2[^\\/]*[.]exe\z')
    })
    if (@($running).Count -ne 0) {
        $names = [string]::Join(', ',[string[]]@($running | ForEach-Object { [string]$_.Name } | Sort-Object -Unique))
        throw ("Close target processes before Apply: {0}" -f $names)
    }
}

function Restore-AppliedItems {
    param([object[]]$AppliedItems)
    foreach ($entry in @($AppliedItems | Sort-Object Sequence -Descending)) {
        if ([bool]$entry.ExistedBefore) { [System.IO.File]::Copy([string]$entry.Backup,[string]$entry.Destination,$true) }
        elseif ([System.IO.File]::Exists([string]$entry.Destination)) { [System.IO.File]::Delete([string]$entry.Destination) }
    }
}

function Invoke-RealApplySet {
    param([string]$SetName,[object[]]$Items,[string]$BackupRoot,[System.Collections.ArrayList]$Results)
    $changed = New-Object System.Collections.ArrayList
    try {
        foreach ($item in @($Items)) {
            $action = [string]$item.Action
            if ([string]::Equals($action,'Unchanged',[System.StringComparison]::Ordinal) -or [string]::Equals($action,'PreserveUserModified',[System.StringComparison]::Ordinal) -or [string]::Equals($action,'NotInitialized',[System.StringComparison]::Ordinal)) {
                [void]$Results.Add([pscustomobject]@{Set=$SetName;Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$item.Destination;Applied=$false;Backup=''})
                continue
            }
            if (-not [string]::Equals($action,'Add',[System.StringComparison]::Ordinal) -and -not [string]::Equals($action,'UpdateOrRepair',[System.StringComparison]::Ordinal)) { throw ("Unsupported Apply action: {0}" -f $action) }
            $existedBefore = [System.IO.File]::Exists([string]$item.Destination)
            $backup = Copy-VerifiedFile ([string]$item.Source) ([string]$item.Destination) $BackupRoot
            [void]$changed.Add([pscustomobject]@{Sequence=@($changed).Count;Destination=[string]$item.Destination;ExistedBefore=$existedBefore;Backup=$backup})
            [void]$Results.Add([pscustomobject]@{Set=$SetName;Platform=$item.Platform;Component=$item.Component;Action=$action;Destination=$item.Destination;Applied=$true;Backup=$backup})
        }
    } catch {
        Restore-AppliedItems ([object[]]@($changed))
        throw
    }
}

function Invoke-RealApply {
    param([object[]]$Plan,[string]$OutputRoot)
    Assert-TargetProcessesStopped
    $backupRoot = Join-Path $OutputRoot ('backups-' + [System.DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
    [System.IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    $results = New-Object System.Collections.ArrayList
    $setNames = @('Core','BVE5','BVE6','BveEX Current','AtsEX Legacy','PCSX2','RPCS3')
    foreach ($setName in $setNames) {
        $items = @($Plan | Where-Object { [string]::Equals([string]$_.Platform,$setName,[System.StringComparison]::Ordinal) })
        if (@($items).Count -ne 0) { Invoke-RealApplySet $setName ([object[]]@($items)) $backupRoot $results }
    }
    return [pscustomobject]@{BackupRoot=$backupRoot;Results=[object[]]@($results)}
}

function New-PlanItem {
    param([string]$Platform,[string]$Component,[string]$Source,[string]$Destination,[bool]$CreateParent,[bool]$PreserveModified)
    $sourceSha = Get-Sha256 $Source
    $destinationSha = ''
    if ([System.IO.File]::Exists($Destination)) {
        $destinationSha = Get-Sha256 $Destination
        if ([string]::Equals($sourceSha,$destinationSha,[System.StringComparison]::Ordinal)) { $action='Unchanged' }
        elseif ($PreserveModified) { $action='PreserveUserModified' }
        else { $action='UpdateOrRepair' }
    } else {
        $parent = [System.IO.Path]::GetDirectoryName($Destination)
        if ([System.IO.Directory]::Exists($parent) -or $CreateParent) { $action='Add' } else { $action='NotInitialized' }
    }
    return [pscustomobject]@{Platform=$Platform;Component=$Component;Action=$action;Source=$Source;SourceSHA256=$sourceSha;Destination=$Destination;DestinationSHA256=$destinationSha}
}

[System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$sources = @{
    Application=Join-Path $payload 'DenGoControllerConverter.exe'
    Caller=Join-Path $payload 'DenGoControllerConverter.dll'
    CurrentBridge=Join-Path $payload 'DenGoVehicleSpec.BveEx.Bridge.dll'
    CurrentVehicleSpec=Join-Path $payload 'DenGoBveVehicleSpec.dll'
    LegacyBridge=Join-Path $payload 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll'
    LegacyVehicleSpec=Join-Path $payload 'DenGoAtsExLegacyVehicleSpec.dll'
    PCSX2Profile=Join-Path $assets 'pcsx2\DenGo-Controller-Converter.lily'
    RPCS3Profile=Join-Path $assets 'rpcs3\Den-Go-Controller.yml'
}
foreach ($entry in $sources.GetEnumerator()) { if (-not [System.IO.File]::Exists([string]$entry.Value)) { throw ("Source missing: {0}" -f $entry.Value) } }

$candidates = New-Object System.Collections.ArrayList
foreach ($item in @(Get-DefaultExecutableCandidates)) { Add-Executable $candidates ([string]$item.Platform) ([string]$item.Path) 'DefaultLocation' '' }

$shell = New-Object -ComObject WScript.Shell
Add-ShortcutRootExecutables $candidates 'TaskbarPinned' (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar') $false $shell
Add-ShortcutRootExecutables $candidates 'UserDesktop' ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)) $true $shell
Add-ShortcutRootExecutables $candidates 'CommonDesktop' ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonDesktopDirectory)) $true $shell
Add-ShortcutRootExecutables $candidates 'UserStartMenu' ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::StartMenu)) $true $shell
Add-ShortcutRootExecutables $candidates 'CommonStartMenu' ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonStartMenu)) $true $shell

$processes = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '(?i)\A(?:bvets|rpcs3|pcsx2[^\\/]*)[.]exe\z' })
foreach ($process in $processes) { Add-Executable $candidates (Get-Platform ([string]$process.Name)) ([string]$process.ExecutablePath) 'RunningProcess' ([string]$process.CommandLine) }

$commonRoots = @(
    [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments),
    (Join-Path $env:USERPROFILE 'Downloads'),
    [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop),
    (Join-Path $env:LOCALAPPDATA 'Programs')
)
foreach ($root in $commonRoots) {
    if (-not [System.IO.Directory]::Exists($root)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        [string]::Equals($_.Name,'BveTs.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($_.Name,'rpcs3.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        $_.Name -match '(?i)\Apcsx2[^\\/]*[.]exe\z'
    })) {
        Add-Executable $candidates (Get-Platform $file.Name) $file.FullName ('CommonRoot:' + $root) ''
    }
}

if ($AdditionalSearch) { Add-FixedDriveExecutables $candidates 120 }

$detected = New-Object System.Collections.ArrayList
foreach ($candidate in $candidates) {
    $exeDirectory = [System.IO.Path]::GetDirectoryName([string]$candidate.Executable)
    $state = 'Detected'
    $mode = ''
    $inputDevices = ''
    $profileDirectory = ''
    if ([string]::Equals([string]$candidate.Platform,'BVE',[System.StringComparison]::Ordinal)) {
        $architecture = Get-PeMachine ([string]$candidate.Executable)
        $mode = if ([string]::Equals($architecture,'x86',[System.StringComparison]::Ordinal)) { 'BVE5' } elseif ([string]::Equals($architecture,'x64',[System.StringComparison]::Ordinal)) { 'BVE6' } else { 'Ambiguous' }
        if ([string]::Equals($mode,'Ambiguous',[System.StringComparison]::Ordinal)) { $state='Ambiguous' }
        $inputDevices = Join-Path $exeDirectory 'Input Devices'
    } elseif ([string]::Equals([string]$candidate.Platform,'PCSX2',[System.StringComparison]::Ordinal)) {
        $portable = [System.IO.File]::Exists((Join-Path $exeDirectory 'portable.ini')) -or [System.IO.File]::Exists((Join-Path $exeDirectory 'portable.txt')) -or (([string]$candidate.Arguments) -match '(?i)(?:\A|\s)-portable(?:\s|\z)')
        $mode = if ($portable) { 'Portable' } else { 'CentralConfiguration' }
        $configurationRoot = if ($portable) { $exeDirectory } else { Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)) 'PCSX2' }
        $ini = Join-Path $configurationRoot 'inis\LilyPad.ini'
        if ([System.IO.File]::Exists($ini)) {
            $pathLines = @([System.IO.File]::ReadAllLines($ini,[System.Text.Encoding]::Default) | Where-Object { $_ -match '\ALast Config Path=' })
            if (@($pathLines).Count -eq 1) { $profileDirectory=([string]$pathLines[0]).Substring('Last Config Path='.Length).Trim() } else { $state='UnsupportedOrAmbiguous' }
        } else { $state='DetectedButNotInitialized' }
    } elseif ([string]::Equals([string]$candidate.Platform,'RPCS3',[System.StringComparison]::Ordinal)) {
        $mode='ExecutableRelativeConfig'
        $profileDirectory=Join-Path $exeDirectory 'config\input_configs\global'
        if (-not [System.IO.Directory]::Exists($profileDirectory)) { $state='DetectedButNotInitialized' }
    }
    [void]$detected.Add([pscustomobject]@{Platform=$candidate.Platform;Executable=$candidate.Executable;State=$state;Mode=$mode;InputDevices=$inputDevices;ProfileDirectory=$profileDirectory;DetectionSource=$candidate.Source})
}

$bve = @($detected | Where-Object { [string]::Equals([string]$_.Platform,'BVE',[System.StringComparison]::Ordinal) -and [string]::Equals([string]$_.State,'Detected',[System.StringComparison]::Ordinal) })
$pcsx2 = @($detected | Where-Object { [string]::Equals([string]$_.Platform,'PCSX2',[System.StringComparison]::Ordinal) -and [string]::Equals([string]$_.State,'Detected',[System.StringComparison]::Ordinal) })
$rpcs3 = @($detected | Where-Object { [string]::Equals([string]$_.Platform,'RPCS3',[System.StringComparison]::Ordinal) -and [string]::Equals([string]$_.State,'Detected',[System.StringComparison]::Ordinal) })

$plan = New-Object System.Collections.ArrayList
[void]$plan.Add((New-PlanItem 'Core' 'Application' $sources.Application (Join-Path $env:LOCALAPPDATA 'Programs\DenGo Controller Converter\DenGoControllerConverter.exe') $true $false))
foreach ($item in $bve) { [void]$plan.Add((New-PlanItem ([string]$item.Mode) 'Caller' $sources.Caller (Join-Path ([string]$item.InputDevices) 'DenGoControllerConverter.dll') $true $false)) }
$currentDir='C:\Users\Public\Documents\BveEx\2.0\Extensions'
if ([System.IO.Directory]::Exists($currentDir)) {
    [void]$plan.Add((New-PlanItem 'BveEX Current' 'Bridge' $sources.CurrentBridge (Join-Path $currentDir 'DenGoVehicleSpec.BveEx.Bridge.dll') $false $false))
    [void]$plan.Add((New-PlanItem 'BveEX Current' 'VehicleSpec' $sources.CurrentVehicleSpec (Join-Path $currentDir 'DenGoBveVehicleSpec.dll') $false $false))
}
$legacyDir='C:\Users\Public\Documents\AtsEx\1.0\Extensions'
if ([System.IO.Directory]::Exists($legacyDir)) {
    [void]$plan.Add((New-PlanItem 'AtsEX Legacy' 'Bridge' $sources.LegacyBridge (Join-Path $legacyDir 'DenGoVehicleSpec.AtsExLegacy.Bridge.dll') $false $false))
    [void]$plan.Add((New-PlanItem 'AtsEX Legacy' 'VehicleSpec' $sources.LegacyVehicleSpec (Join-Path $legacyDir 'DenGoAtsExLegacyVehicleSpec.dll') $false $false))
}
if (@($pcsx2).Count -eq 1) { [void]$plan.Add((New-PlanItem 'PCSX2' 'InputProfile' $sources.PCSX2Profile (Join-Path ([string]$pcsx2[0].ProfileDirectory) 'DenGo-Controller-Converter.lily') $false $true)) }
if (@($rpcs3).Count -eq 1) { [void]$plan.Add((New-PlanItem 'RPCS3' 'InputProfile' $sources.RPCS3Profile (Join-Path ([string]$rpcs3[0].ProfileDirectory) 'Den-Go-Controller.yml') $false $true)) }

$applyResults = [object[]]@()
$backupRoot = ''
if ($Apply -and $RealSystem) {
    $realApplyResult = Invoke-RealApply ([object[]]@($plan)) $outputRoot
    $applyResults = [object[]]@($realApplyResult.Results)
    $backupRoot = [string]$realApplyResult.BackupRoot
} elseif ($Apply) {
    $applyResults = Invoke-SandboxApply ([object[]]@($plan)) $TestRoot
}
$result=[pscustomobject]@{SchemaVersion=4;Generated=[System.DateTimeOffset]::Now.ToString('o');DryRun=[bool]$DryRun;Apply=[bool]$Apply;RealSystem=[bool]$RealSystem;AdditionalSearch=[bool]$AdditionalSearch;TestRoot=$TestRoot;BackupRoot=$backupRoot;Detected=[object[]]@($detected);Plan=[object[]]@($plan);ApplyResults=[object[]]@($applyResults)}
[System.IO.File]::WriteAllText($jsonOutput,($result | ConvertTo-Json -Depth 9),(New-Object System.Text.UTF8Encoding($true)))
$lines=New-Object System.Collections.ArrayList
[void]$lines.Add('DenGo installer formal preview plan')
[void]$lines.Add(("Generated: {0}" -f $result.Generated))
foreach ($item in $plan) { [void]$lines.Add(("{0,-18} | {1,-12} | {2,-20} | {3}" -f $item.Platform,$item.Component,$item.Action,$item.Destination)) }
if ($RealSystem) { [void]$lines.Add('Real-system Apply completed. See ApplyResults and BackupRoot.') } elseif ($Apply) { [void]$lines.Add('Sandbox Apply completed. Real installed files were not changed.') } else { [void]$lines.Add('No installed file or profile was changed.') }
[System.IO.File]::WriteAllLines($textOutput,[string[]]@($lines),(New-Object System.Text.UTF8Encoding($true)))

$scriptText=[System.IO.File]::ReadAllText($MyInvocation.MyCommand.Path,[System.Text.Encoding]::UTF8)
if ($scriptText.IndexOf('-Filter ' + [char]42,[System.StringComparison]::Ordinal) -ge 0 -or $scriptText.IndexOf('-Path ' + [char]42,[System.StringComparison]::Ordinal) -ge 0) { throw 'Wildcard path or filter token was found.' }
Write-Host 'RESULT: SUCCESS'
Write-Host ("Plan items: {0}" -f @($plan).Count)
Write-Host ("Text: {0}" -f $textOutput)
Write-Host ("JSON: {0}" -f $jsonOutput)
Write-Host ("Apply mode enabled: {0}" -f ([bool]$Apply))
Write-Host ("Real-system Apply enabled: {0}" -f ([bool]$RealSystem))
if ($Apply -and -not $RealSystem) { Write-Host ("Sandbox TestRoot: {0}" -f $TestRoot) }
if ($RealSystem) { Write-Host ("BackupRoot: {0}" -f $backupRoot) } else { Write-Host 'Real system changes: NONE' }
