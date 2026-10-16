# Child process for the I2-D lock tests. Takes only the throw-away lock name it is given (the product lock name is never used).
#   Mode Probe : try the product acquire (DgLock-TryAcquire ... 'Explicit') once, report, release. No signal files needed.
#   Mode Hold  : acquire, write the Signal file ('held' or 'refused:<Reason>'), wait for the Release file, release.
#                Security: Product (the product's own DgLock-TryAcquire / DACL) | Engine (contract DACL built by the test) | SystemOnly (only SYSTEM can open it)
#   Mode Wait  : open the EXISTING mutex and block on it; when the holder is killed this child receives the abandoned mutex.
#                Writes Signal ('waiting'), then ResultPath {Abandoned}. It releases the mutex right away.
#   Mode Keep  : open the EXISTING mutex and keep the handle (never owns it) until the Release file appears. Writes Signal ('kept').
# Every mode writes a small JSON result file (ResultPath) when one is given.
param(
    [Parameter(Mandatory = $true)][string]$LockName,
    [string]$Mode = 'Probe',
    [string]$Security = 'Product',
    [string]$Signal = '',
    [string]$Release = '',
    [string]$ResultPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2D.TestSupport.ps1')
function Wait-File([string]$Path, [int]$Seconds) { for ($i = 0; $i -lt ($Seconds * 20); $i++) { if ([System.IO.File]::Exists($Path)) { return $true }; Start-Sleep -Milliseconds 50 }; return $false }
function Write-Result($Object) { if ($ResultPath.Length -gt 0) { [System.IO.File]::WriteAllText($ResultPath, ($Object | ConvertTo-Json -Compress)) } }

if ($Mode -eq 'Probe') {
    $r = DgLock-TryAcquire $LockName 'Explicit'
    Write-Result ([ordered]@{ Acquired = [bool]$r.Acquired; Reason = [string]$r.Reason; Abandoned = [bool]$r.Abandoned })
    if ($r.Acquired) { [void](DgLock-Release $LockName) }
    exit 0
}
if ($Mode -eq 'Hold') {
    $held = $false; $reason = ''; $mutex = $null
    if ($Security -eq 'Product') {
        $r = DgLock-TryAcquire $LockName 'Explicit'
        $held = [bool]$r.Acquired; $reason = [string]$r.Reason
    } else {
        try {
            $created = $false
            $mutex = New-Object System.Threading.Mutex($false, $LockName, [ref]$created, (New-I2DSecurity $Security))
            $held = $mutex.WaitOne(0)
            if (-not $held) { $reason = 'HeldByOther' }
        } catch { $reason = 'CreateFailed:' + $_.Exception.Message }
    }
    if ($Signal.Length -gt 0) { [System.IO.File]::WriteAllText($Signal, $(if ($held) { 'held' } else { 'refused:' + $reason })) }
    if ($held) { [void](Wait-File $Release 90) }
    if ($Security -eq 'Product') { if ($held) { [void](DgLock-Release $LockName) } }
    elseif ($null -ne $mutex) { if ($held) { try { $mutex.ReleaseMutex() } catch { } }; $mutex.Dispose() }
    Write-Result ([ordered]@{ Held = $held; Reason = $reason })
    exit 0
}
if ($Mode -eq 'Wait') {
    $rights = [System.Security.AccessControl.MutexRights]([int][System.Security.AccessControl.MutexRights]::Synchronize -bor [int][System.Security.AccessControl.MutexRights]::Modify)
    $m = [System.Threading.Mutex]::OpenExisting($LockName, $rights)
    if ($Signal.Length -gt 0) { [System.IO.File]::WriteAllText($Signal, 'waiting') }
    $abandoned = $false
    try { [void]$m.WaitOne() } catch { if ($_.Exception.GetBaseException() -is [System.Threading.AbandonedMutexException]) { $abandoned = $true } else { throw } }
    try { $m.ReleaseMutex() } catch { }
    $m.Dispose()
    Write-Result ([ordered]@{ Abandoned = $abandoned })
    exit 0
}
if ($Mode -eq 'Keep') {
    # keeps an open handle on the EXISTING mutex without ever owning it, so the object survives its owner being killed (as an abandoned mutex)
    $rights = [System.Security.AccessControl.MutexRights]([int][System.Security.AccessControl.MutexRights]::Synchronize -bor [int][System.Security.AccessControl.MutexRights]::Modify)
    $m = [System.Threading.Mutex]::OpenExisting($LockName, $rights)
    if ($Signal.Length -gt 0) { [System.IO.File]::WriteAllText($Signal, 'kept') }
    [void](Wait-File $Release 90)
    $m.Dispose()
    Write-Result ([ordered]@{ Kept = $true })
    exit 0
}
throw ('Unknown mode: ' + $Mode)
