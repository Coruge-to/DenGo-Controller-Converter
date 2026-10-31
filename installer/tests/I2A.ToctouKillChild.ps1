# Child process of the TOCTOU kill tests. It runs (or recovers) the two-item fixture under the fault harness and kills ITSELF (Process.Kill = TerminateProcess:
# no finally blocks, no handle cleanup by PowerShell) at the requested label. Optional third-party injections run inside the same process at their own labels.
# Exit code 7 = the requested kill point was never reached (the child survived). A killed child exits abnormally.
param(
    [Parameter(Mandatory = $true)][ValidateSet('Run', 'Recover')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$FaultB64,
    [string]$InjB64 = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot 'I2A.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2A.Toctou.TestSupport.ps1')
. (Join-Path $PSScriptRoot 'I2A.ToctouKill.TestSupport.ps1')

$L = Get-KtLayout $Root
Install-I2AHarness
$fault = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($FaultB64)) | ConvertFrom-Json
Reset-I2AFault -Mode 'Label' -Pattern ([string]$fault.Pattern) -Nth ([int]$fault.Nth) -Action 'Kill'
Reset-I2ACounters
if ($InjB64.Length -gt 0) {
    $injs = @([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($InjB64)) | ConvertFrom-Json)
    foreach ($j in $injs) {
        $p = [string]$j.Path; $t = [string]$j.Text
        if ([string]$j.Kind -ceq 'Write') { Add-TxInj ([string]$j.Pattern) ([int]$j.Nth) ({ TP-Write $p $t }.GetNewClosure()) }
        elseif ([string]$j.Kind -ceq 'Delete') { Add-TxInj ([string]$j.Pattern) ([int]$j.Nth) ({ TP-Delete $p }.GetNewClosure()) }
        else { throw ('unknown injection kind: ' + [string]$j.Kind) }
    }
}
if ($Mode -eq 'Run') { $null = Invoke-KtRun $L } else { $null = Invoke-KtRecover $L }
# Reaching this line means the kill point was never hit.
exit 7
