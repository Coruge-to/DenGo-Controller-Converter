# I3 uninstall tests (written RED first): the decision for a PCSX2 / LilyPad record and the transaction around it, in sandboxes under TEMP.
#   D  the decision table (Get-DenGoUninstallFileDecision) for LilyPad.ini and the lily profile, with and without IncludeInputProfiles
#   O  the Origin proof R1..R7: missing / SHA mismatch / malformed / Backups[0] mismatch / closed generation / old-format backup / contamination
#   T  the whole uninstall (Invoke-DenGoProductUninstall): restore, keep, stop with zero change, dry run, reconfirmation, ClosedRecords
# Installed states are written by hand (Core install + PCSX2 records) so that these tests do not depend on the I3 install side.
# Controls (existing behaviour that must survive): another platform's Effective profile is still kept by default, DeferredRecords of a closed generation are carried verbatim,
# a record in ClosedRecords is never applied.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerTransaction.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoInstallerProductApply.ps1')
. (Join-Path $PSScriptRoot '..\scripts\DenGoUninstallerProductApply.ps1')
. (Join-Path $PSScriptRoot 'I3.TestSupport.ps1')

$activeV1 = 'DENGO-ACTIVE-LILYPAD-V1'; $lilyV1 = 'DENGO-LILY-PROFILE-V1'
$OLD = '20200101T000000Z-aaaaaaaa'      # older than any real transaction: a backup of a closed generation
$NEW = '29990101T000000Z-aaaaaaaa'      # newer than any real transaction: a backup of the current generation
function Txt([string]$Path) { if (-not [System.IO.File]::Exists($Path)) { return '<missing>' } return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Succ($R) { return ($R.Ok -and ($R.Value.Succeeded -eq $true)) }
function CodeOf($R) { if ($R.Ok) { return [string]$R.Value.ErrorCode } return ('<exception: ' + $R.Error + '>') }
function RunUninstall($L, [bool]$Incl = $false, [scriptblock]$Gate = $null) { return (Invoke-I3 { Invoke-I2CUninstall $L $Incl $Gate }) }

# One installed generation (Core only), then PCSX2 files and records on top. -ClosedGen: an earlier generation was installed and uninstalled before.
function New-I3UCase([string]$Name, [switch]$ClosedGen) {
    $L = New-I3Case $Name
    $plan = Get-I2CPlatformPlan $L @('Core')
    $g = Invoke-I2BInstall $L $plan $false
    if (-not $g.Succeeded) { throw ('fixture: Core install failed: ' + $g.ErrorCode) }
    if ($ClosedGen) {
        $u = Invoke-I2CUninstall $L $false
        if (-not $u.Succeeded) { throw ('fixture: first uninstall failed: ' + $u.ErrorCode) }
        Start-Sleep -Milliseconds 1300
        $g2 = Invoke-I2BInstall $L $plan $false
        if (-not $g2.Succeeded) { throw ('fixture: second Core install failed: ' + $g2.ErrorCode) }
    }
    [System.IO.File]::WriteAllText((Get-I3Dest $L 'LilyPad.ini'), $activeV1, $script:Utf8)
    [System.IO.File]::WriteAllText((Get-I3Dest $L 'DenGo-Controller-Converter.lily'), $lilyV1, $script:Utf8)
    return $L
}
function New-I3LilyPadRecord($L, [string]$Txn = $NEW, [string]$Ownership = 'ReplacedExisting') {
    $bk = New-I3OriginBackup $L.Product $Txn $script:I3UserOrigin
    if ($Ownership -eq 'ReplacedExisting') { $rec = New-I3Record 'EffectiveInputProfile' (Get-I3Dest $L 'LilyPad.ini') $Ownership (Get-I3TextSha $activeV1) $bk.Sha $bk.Path $true @($bk.Entry) }
    else { $rec = New-I3Record 'EffectiveInputProfile' (Get-I3Dest $L 'LilyPad.ini') $Ownership (Get-I3TextSha $activeV1) }
    return [pscustomobject]@{ Rec = $rec; Bk = $bk }
}
function New-I3LilyRecord($L, [string]$Ownership = 'CreatedByInstaller') { return (New-I3Record 'InputProfile' (Get-I3Dest $L 'DenGo-Controller-Converter.lily') $Ownership (Get-I3TextSha $lilyV1)) }
# a record of ANOTHER platform (RPCS3) for the controls: the generation / contamination rules must stay as they are
function New-I3Rpcs3Record($L, [string]$Txn = $NEW) {
    $yml = Join-Path $L.Rpcs3Global 'Den-Go-Controller.yml'
    [System.IO.File]::WriteAllText($yml, 'dengo-yml', $script:Utf8)
    $bk = New-I3OriginBackup $L.Product $Txn 'user-yml'
    $rec = New-I3Record 'InputProfile' $yml 'ReplacedExisting' (Get-I3Sha $yml) $bk.Sha $bk.Path $true @($bk.Entry)
    $rec.Platform = 'RPCS3'
    return [pscustomobject]@{ Rec = $rec; Bk = $bk }
}
function Add-I3Records($L, $Records) { foreach ($r in @($Records)) { Add-I2CRecord $L $r } }
function Dec($L, $Rec, [bool]$Incl) {
    return (Invoke-I3 {
            $P = $L.Product
            $prev = Read-DenGoPreviousState $P
            $us = Read-DenGoUninstalledState $P
            $gen = Get-DenGoUninstallGeneration $prev $us
            Get-DenGoUninstallFileDecision $P $Rec $gen $Incl
        })
}
function IsDec($R, [string]$Decision, [string]$Code = '') {
    if (-not $R.Ok) { return $false }
    if (([string]$R.Value.Decision) -cne $Decision) { return $false }
    if ($Code.Length -gt 0 -and (([string]$R.Value.ReasonCode) -cne $Code)) { return $false }
    return $true
}
function DDtl($R) { if (-not $R.Ok) { return ('<exception: ' + $R.Error + '>') } return ('decision=' + $R.Value.Decision + '/' + $R.Value.ReasonCode + ' blocking=' + $R.Value.Blocking) }
function ResidualOf($Us, [string]$Leaf) { if ($null -eq $Us) { return $null } foreach ($x in @($Us.ResidualFiles)) { if ([System.IO.Path]::GetFileName([string]$x.Path) -ieq $Leaf) { return $x } } return $null }

# ================================================================ D  the decision table
$L = New-I3UCase 'd1'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
foreach ($incl in $false, $true) {
    $d = Dec $L $v.Rec $incl
    [void](Assert-I2A ('D-01-ReplacedExisting-with-a-proven-Origin-is-restored-IncludeInputProfiles-' + $incl) ((IsDec $d 'Restore' 'RestoreOrigin') -and ($d.Value.Op -ceq 'Write') -and ($d.Value.UsedBackup -eq $true) -and ($d.Value.Blocking -eq $false) -and ([string]$d.Value.Role -ceq 'Pcsx2')) (DDtl $d))
}
foreach ($incl in $false, $true) {
    $edited = $v.Rec.PSObject.Copy(); $edited.AfterSHA256 = ('AB' * 32)
    $d = Dec $L $edited $incl
    [void](Assert-I2A ('D-02-edited-since-install-is-preserved-IncludeInputProfiles-' + $incl) ((IsDec $d 'PreserveModified' 'ModifiedByUser') -and ($d.Value.ReviewRecommended -eq $true) -and ($d.Value.Op -ceq '') -and ($d.Value.Residual -eq $true)) (DDtl $d))
}
$same = $v.Rec.PSObject.Copy(); $same.BeforeSHA256 = $same.AfterSHA256
$d = Dec $L $same $false
[void](Assert-I2A 'D-03-an-Origin-equal-to-the-installed-file-is-AlreadyOriginal' (IsDec $d 'AlreadyOriginal') (DDtl $d))
[System.IO.File]::Delete($lilyPad)
$d = Dec $L $v.Rec $false
[void](Assert-I2A 'D-04-a-missing-LilyPad.ini-is-AlreadyMissing-and-nothing-is-recreated' ((IsDec $d 'AlreadyMissing') -and ($d.Value.Op -ceq '')) (DDtl $d))
[System.IO.File]::WriteAllText($lilyPad, $activeV1, $script:Utf8)

# --- Origin-less records: never restored, never removed (the effective profile)
foreach ($own in 'MigratedMatchingDenGoFile', 'CreatedByInstaller') {
    $o = New-I3LilyPadRecord $L $NEW $own
    $d = Dec $L $o.Rec $false
    [void](Assert-I2A ('D-05-' + $own + '-LilyPad.ini-is-kept-by-default') ((IsDec $d 'KeepProfile' 'ProfileKept') -and ($d.Value.Op -ceq '')) (DDtl $d))
    $d = Dec $L $o.Rec $true
    [void](Assert-I2A ('D-05b-' + $own + '-LilyPad.ini-is-never-removed-even-with-IncludeInputProfiles') ((IsDec $d 'PreserveModified' 'EffectiveProfileNeverRemoved') -and ($d.Value.Op -ceq '')) (DDtl $d))
}
$pu = New-I3LilyPadRecord $L $NEW 'PreservedUserFile'
$d = Dec $L $pu.Rec $false
[void](Assert-I2A 'D-06-PreservedUserFile-LilyPad.ini-is-kept' ((IsDec $d 'KeepProfile') -and ($d.Value.Op -ceq '')) (DDtl $d))
$d = Dec $L $pu.Rec $true
[void](Assert-I2A 'D-06b-PreservedUserFile-with-IncludeInputProfiles-is-the-users-file' ((IsDec $d 'PreserveUserFile') -and ($d.Value.Op -ceq '')) (DDtl $d))

# --- the lily profile: kept by default, removed only on request and only when unedited, restored from its Origin on request
$lilyRec = New-I3LilyRecord $L
$d = Dec $L $lilyRec $false
[void](Assert-I2A 'D-07-the-lily-profile-is-kept-by-default' ((IsDec $d 'KeepProfile') -and ($d.Value.Op -ceq '')) (DDtl $d))
$d = Dec $L $lilyRec $true
[void](Assert-I2A 'D-07b-an-unedited-created-lily-profile-is-removed-on-request' ((IsDec $d 'Remove' 'Remove') -and ($d.Value.Op -ceq 'Delete')) (DDtl $d))
$ed = New-I3LilyRecord $L; $ed.AfterSHA256 = ('CD' * 32)
$d = Dec $L $ed $true
[void](Assert-I2A 'D-07c-an-edited-lily-profile-is-preserved-even-on-request' ((IsDec $d 'PreserveModified' 'ModifiedByUser') -and ($d.Value.Op -ceq '')) (DDtl $d))
$bkL = New-I3OriginBackup $L.Product $NEW 'USER-OWN-LILY-PROFILE'
$lr = New-I3Record 'InputProfile' (Get-I3Dest $L 'DenGo-Controller-Converter.lily') 'ReplacedExisting' (Get-I3TextSha $lilyV1) $bkL.Sha $bkL.Path $true @($bkL.Entry)
$d = Dec $L $lr $false
[void](Assert-I2A 'D-07d-a-replaced-lily-profile-is-still-kept-by-default' ((IsDec $d 'KeepProfile') -and ($d.Value.Op -ceq '')) ('only LilyPad.ini is restored by default; ' + (DDtl $d)))
$d = Dec $L $lr $true
[void](Assert-I2A 'D-07e-a-replaced-lily-profile-is-restored-from-its-Origin-on-request' ((IsDec $d 'Restore' 'RestoreOrigin')) (DDtl $d))

# --- shape: a PCSX2 record that is not one of the two fixed leaves
$odd = New-I3Record 'EffectiveInputProfile' (Get-I3Dest $L 'PCSX2.ini') 'CreatedByInstaller' (Get-I3Sha (Get-I3Dest $L 'PCSX2.ini'))
$d = Dec $L $odd $true
[void](Assert-I2A 'D-08-an-owning-record-for-PCSX2.ini-blocks-the-uninstall-and-is-never-touched' ((IsDec $d 'UnsafeOrUnknown' 'UnsafeOrUnknown') -and ($d.Value.Blocking -eq $true) -and ($d.Value.Op -ceq '')) (DDtl $d))
$oddU = New-I3Record 'EffectiveInputProfile' (Get-I3Dest $L 'PCSX2.ini') 'PreservedUserFile' (Get-I3Sha (Get-I3Dest $L 'PCSX2.ini'))
$d = Dec $L $oddU $true
[void](Assert-I2A 'D-08b-a-non-owning-record-for-PCSX2.ini-is-only-reported' ((IsDec $d 'PreserveNotOwned' 'ShapeNotVerified') -and ($d.Value.Blocking -eq $false) -and ($d.Value.Op -ceq '')) (DDtl $d))
$unk = New-I3Record 'EffectiveInputProfile' $lilyPad 'SomethingUnknown' (Get-I3TextSha $activeV1)
foreach ($incl in $false, $true) {
    $d = Dec $L $unk $incl
    [void](Assert-I2A ('D-09-an-unknown-ownership-blocks-IncludeInputProfiles-' + $incl) ((IsDec $d 'UnsafeOrUnknown') -and ($d.Value.Blocking -eq $true)) (DDtl $d))
}

# --- control: another platform's Effective profile is still kept by default (the PCSX2 restore is a PCSX2-only contract, DE-I3-3)
$yml = Join-Path $L.Rpcs3Global 'Den-Go-Controller.yml'
[System.IO.File]::WriteAllText($yml, 'dengo-yml', $script:Utf8)
$bkY = New-I3OriginBackup $L.Product $NEW 'user-yml'
$ry = New-I3Record 'EffectiveInputProfile' $yml 'ReplacedExisting' (Get-I3Sha $yml) $bkY.Sha $bkY.Path $true @($bkY.Entry)
$ry.Platform = 'RPCS3'
$d = Dec $L $ry $false
[void](Assert-I2A 'D-10-control-an-RPCS3-Effective-profile-is-still-kept-by-default' ((IsDec $d 'KeepProfile') -and ($d.Value.Op -ceq '')) (DDtl $d))
$d = Dec $L $ry $true
[void](Assert-I2A 'D-10b-control-an-RPCS3-Effective-profile-is-restored-only-on-request' (IsDec $d 'Restore' 'RestoreOrigin') (DDtl $d))
Remove-I2ASandbox $L.Root

# ================================================================ O  the Origin proof
$L = New-I3UCase 'o1'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
function OriginCase([string]$Id, $Rec, [string]$ExpectCode = 'ReplacedExistingBackupInvalid', [string]$ExpectDecision = 'UnsafeOrUnknown') {
    $d = Dec $L $Rec $false
    [void](Assert-I2A ('O-' + $Id) ((IsDec $d $ExpectDecision $ExpectCode) -and ($d.Value.Blocking -eq $true) -and ($d.Value.Op -ceq '')) (DDtl $d))
}
$v = New-I3LilyPadRecord $L
$miss = New-I3LilyPadRecord $L '29990101T000000Z-bbbbbbbb'; [System.IO.File]::Delete($miss.Bk.Path)
OriginCase 'R4-backup-file-missing' $miss.Rec
$alt = New-I3LilyPadRecord $L '29990101T000000Z-cccccccc'; [System.IO.File]::WriteAllText($alt.Bk.Path, 'ALTERED-BACKUP', $script:Utf8)
OriginCase 'R4-backup-sha-mismatch' $alt.Rec
$mal = New-I3LilyPadRecord $L '29990101T000000Z-dddddddd'; $mal.Rec.BeforeSHA256 = 'not-a-sha'
OriginCase 'R1-before-sha-malformed' $mal.Rec
$noex = New-I3LilyPadRecord $L '29990101T000000Z-eeeeeeee'; $noex.Rec.ExistedBefore = $false
OriginCase 'R1-existed-before-false' $noex.Rec
$nob = New-I3LilyPadRecord $L '29990101T000000Z-ffffffff'; $nob.Rec.Backup = ''
OriginCase 'R1-backup-path-empty' $nob.Rec
$bz = New-I3LilyPadRecord $L '29990101T000000Z-99999999'; $bz.Rec.Backups = [object[]]@([pscustomobject][ordered]@{ TransactionId = '29990101T000000Z-99999999'; Path = (Join-Path $L.Product.BackupRoot 'other\0001.bak'); SHA256 = $bz.Bk.Sha })
OriginCase 'R3-Backups-0-is-not-the-Origin-path' $bz.Rec
$b1 = New-I3LilyPadRecord $L '29990101T000000Z-88888888'
$b1.Rec.Backups = [object[]]@([pscustomobject][ordered]@{ TransactionId = '29990101T000000Z-77777777'; Path = 'C:\x\other.bak'; SHA256 = ('11' * 32) }, $b1.Bk.Entry)
OriginCase 'R3-the-Origin-is-Backups-1-not-Backups-0' $b1.Rec
$bt = New-I3LilyPadRecord $L '29990101T000000Z-66666666'; $bt.Rec.Backups = [object[]]@([pscustomobject][ordered]@{ TransactionId = '29990101T000000Z-55555555'; Path = $bt.Bk.Path; SHA256 = $bt.Bk.Sha })
OriginCase 'R3-Backups-0-transaction-differs-from-the-backup-folder' $bt.Rec
$outside = Join-Path $L.Root 'Elsewhere\0001.bak'; [void][System.IO.Directory]::CreateDirectory((Split-Path $outside)); [System.IO.File]::WriteAllText($outside, $script:I3UserOrigin, $script:Utf8)
$ob = New-I3LilyPadRecord $L '29990101T000000Z-44444444'; $ob.Rec.Backup = $outside; $ob.Rec.Backups = [object[]]@([pscustomobject][ordered]@{ TransactionId = '29990101T000000Z-44444444'; Path = $outside; SHA256 = $ob.Bk.Sha })
OriginCase 'R2-backup-outside-the-backup-root' $ob.Rec
$bt2 = New-I3LilyPadRecord $L '29990101T000000Z-33333333'; $bt2.Rec.Backups = [object[]]@()
OriginCase 'R3-Backups-empty-for-a-transaction-backup' $bt2.Rec
# --- I3-D (formal test of the I3-C behaviour): Backups[1..] are update / replacement backups. They are never an Origin, whatever the state of Backups[0]
$ov = New-I3LilyPadRecord $L '29990101T000000Z-12121212'
$upd = New-I3OriginBackup $L.Product '29990101T000000Z-34343434' 'DENGO-UPDATE-BACKUP-NOT-AN-ORIGIN'
$ov.Rec.Backups = [object[]]@($ov.Bk.Entry, $upd.Entry)
$d = Dec $L $ov.Rec $false
[void](Assert-I2A 'O-B1a-a-valid-update-backup-next-to-the-Origin-never-changes-the-restore-source' ((IsDec $d 'Restore' 'RestoreOrigin') -and ($d.Value.Blocking -eq $false) -and ($null -ne $d.Value.Origin) -and ([string]$d.Value.Origin.Path -ceq [string]$ov.Bk.Path) -and ([string]$d.Value.Origin.Sha -ceq [string]$ov.Bk.Sha) -and ([string]$d.Value.Origin.Path -cne [string]$upd.Path) -and ([string]$d.Value.Origin.Sha -cne [string]$upd.Sha)) (DDtl $d))
$ovMiss = New-I3LilyPadRecord $L '29990101T000000Z-56565656'
$updMiss = New-I3OriginBackup $L.Product '29990101T000000Z-78787878' 'DENGO-UPDATE-BACKUP-NOT-AN-ORIGIN-2'
$ovMiss.Rec.Backups = [object[]]@($ovMiss.Bk.Entry, $updMiss.Entry); [System.IO.File]::Delete($ovMiss.Bk.Path)
OriginCase 'B1b-Origin-file-missing-and-a-valid-update-backup-exists-no-fallback' $ovMiss.Rec
$ovSha = New-I3LilyPadRecord $L '29990101T000000Z-9a9a9a9a'
$updSha = New-I3OriginBackup $L.Product '29990101T000000Z-bcbcbcbc' $script:I3UserOrigin
$ovSha.Rec.Backups = [object[]]@([pscustomobject][ordered]@{ TransactionId = '29990101T000000Z-9a9a9a9a'; Path = $ovSha.Bk.Path; SHA256 = ('77' * 32) }, $updSha.Entry)
OriginCase 'B1c-Backups-0-SHA-mismatch-while-Backups-1-would-match-no-fallback' $ovSha.Rec
$ovPtr = New-I3LilyPadRecord $L '29990101T000000Z-dedede01'
$updPtr = New-I3OriginBackup $L.Product '29990101T000000Z-f0f0f0f0' $script:I3UserOrigin
$ovPtr.Rec.Backups = [object[]]@($ovPtr.Bk.Entry, $updPtr.Entry); $ovPtr.Rec.Backup = $updPtr.Path; $ovPtr.Rec.BeforeSHA256 = $updPtr.Sha
OriginCase 'B1d-the-recorded-Origin-pointing-at-Backups-1-is-refused' $ovPtr.Rec
$ovAlt = New-I3LilyPadRecord $L '29990101T000000Z-13131313'
$updAlt = New-I3OriginBackup $L.Product '29990101T000000Z-24242424' $script:I3UserOrigin
$ovAlt.Rec.Backups = [object[]]@($ovAlt.Bk.Entry, $updAlt.Entry); [System.IO.File]::WriteAllText($ovAlt.Bk.Path, 'ALTERED-ORIGIN', $script:Utf8)
OriginCase 'B1e-Origin-altered-while-Backups-1-holds-the-original-content-no-fallback' $ovAlt.Rec
# a valid legacy-format Origin (no closed generation, no old uninstalled state): usable
$legacyDir = Join-Path $L.Product.BackupRoot '20261014-045719'; [void][System.IO.Directory]::CreateDirectory($legacyDir)
$legacyBk = Join-Path $legacyDir '312661c0537d4f4b88f18ed055b43202.bak'; [System.IO.File]::WriteAllText($legacyBk, $script:I3UserOrigin, $script:Utf8)
$lg = New-I3Record 'EffectiveInputProfile' $lilyPad 'ReplacedExisting' (Get-I3TextSha $activeV1) (Get-I3Sha $legacyBk) $legacyBk $true @()
$d = Dec $L $lg $false
[void](Assert-I2A 'O-legacy-backup-is-valid-while-no-generation-was-closed' (IsDec $d 'Restore' 'RestoreOrigin') (DDtl $d))
Remove-I2ASandbox $L.Root

# --- a closed generation exists: its backups are never a restore source
$L = New-I3UCase 'o2' -ClosedGen
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
$ok = New-I3LilyPadRecord $L $NEW
$d = Dec $L $ok.Rec $false
[void](Assert-I2A 'O-R7-control-a-backup-of-the-current-generation-is-valid-after-a-closed-generation' (IsDec $d 'Restore' 'RestoreOrigin') (DDtl $d))
$old = New-I3LilyPadRecord $L $OLD
OriginCase 'R7-backup-of-a-closed-generation' $old.Rec
$legacyDir = Join-Path $L.Product.BackupRoot '20261014-045719'; [void][System.IO.Directory]::CreateDirectory($legacyDir)
$legacyBk = Join-Path $legacyDir '312661c0537d4f4b88f18ed055b43202.bak'; [System.IO.File]::WriteAllText($legacyBk, $script:I3UserOrigin, $script:Utf8)
$lg = New-I3Record 'EffectiveInputProfile' $lilyPad 'ReplacedExisting' (Get-I3TextSha $activeV1) (Get-I3Sha $legacyBk) $legacyBk $true @()
OriginCase 'R7-legacy-backup-after-a-closed-generation' $lg
$d = Dec $L $ok.Rec $true
[void](Assert-I2A 'O-R7b-the-current-generation-backup-is-also-valid-with-IncludeInputProfiles' (IsDec $d 'Restore' 'RestoreOrigin') (DDtl $d))
$ry1 = New-I3Rpcs3Record $L $NEW; $d = Dec $L $ry1.Rec $true
[void](Assert-I2A 'O-ctl-R7-RPCS3-backup-of-the-current-generation-is-restorable-after-a-closed-generation' (IsDec $d 'Restore' 'RestoreOrigin') (DDtl $d))
$ry2 = New-I3Rpcs3Record $L $OLD; $d = Dec $L $ry2.Rec $true
[void](Assert-I2A 'O-ctl-R7-RPCS3-backup-of-a-closed-generation-is-refused' ((IsDec $d 'UnsafeOrUnknown' 'ReplacedExistingBackupInvalid') -and ($d.Value.Blocking -eq $true)) (DDtl $d))
Remove-I2ASandbox $L.Root

# --- contamination: old installed state next to an old uninstalled state (the owner's machine)
$L = New-I3UCase 'o3'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec)
ConvertTo-I2CLegacyState $L
Write-I2CLegacyUninstalledState $L
$legacyRec = $null
foreach ($f in @((Get-I2CIs $L).Files)) { if ([string]$f.Platform -ceq 'PCSX2') { $legacyRec = $f } }
$d = Dec $L $legacyRec $false
[void](Assert-I2A 'O-contamination-blocks-the-restore-with-PreserveSuspect' ((IsDec $d 'PreserveSuspect' 'ContaminationBlocksRestore') -and ($d.Value.Blocking -eq $true) -and ($d.Value.Op -ceq '')) (DDtl $d))
$d = Dec $L $legacyRec $true
[void](Assert-I2A 'O-contamination-blocks-also-with-IncludeInputProfiles' ((IsDec $d 'PreserveSuspect' 'ContaminationBlocksRestore')) (DDtl $d))
$ry3 = New-I3Rpcs3Record $L $NEW; $d = Dec $L $ry3.Rec $true
[void](Assert-I2A 'O-ctl-contamination-also-blocks-an-RPCS3-restore' ((IsDec $d 'PreserveSuspect' 'ContaminationBlocksRestore') -and ($d.Value.Blocking -eq $true)) (DDtl $d))
Remove-I2ASandbox $L.Root

# ================================================================ T  the whole uninstall
# T-01 default restore: LilyPad.ini goes back to the Origin, the profile stays, the Origin is recorded as used
$L = New-I3UCase 't1'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'; $lily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'T-01a-uninstall-restores-LilyPad.ini-to-the-Origin-without-IncludeInputProfiles' ((Succ $u) -and ((Txt $lilyPad) -ceq $script:I3UserOrigin)) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $lilyPad)]"))
[void](Assert-I2A 'T-01b-the-lily-profile-is-kept-by-default' ((Txt $lily) -ceq $lilyV1) ("lily=[$(Txt $lily)]"))
[void](Assert-I2A 'T-01c-the-state-records-the-restore-the-used-Origin-and-an-empty-DeferredRecords' (($null -ne $us) -and ($us.Counts.Restored -eq 1) -and ($us.Counts.Deferred -eq 0) -and (@($us.UsedBackups | Where-Object { [string]$_.Path -ceq [string]$v.Bk.Path -and [string]$_.SHA256 -ceq [string]$v.Bk.Sha -and [string]$_.Purpose -ceq 'RestoreOrigin' }).Count -eq 1) -and (@($us.DeferredRecords).Count -eq 0)) ("counts=" + $(if ($null -ne $us) { ConvertTo-I3Json $us.Counts } else { '<none>' }) + " used=" + $(if ($null -ne $us) { ConvertTo-I3Json @($us.UsedBackups) } else { '<none>' })))
$resLily = ResidualOf $us 'DenGo-Controller-Converter.lily'
[void](Assert-I2A 'T-01d-the-kept-profile-is-a-residual-and-nothing-PCSX2-is-in-ClosedRecords' (($null -ne $resLily) -and ([string]$resLily.Disposition -ceq 'KeepProfile') -and (@($us.ClosedRecords | Where-Object { [string]$_.Record.Platform -ceq 'PCSX2' }).Count -eq 0)) ("residual=" + $(if ($null -ne $resLily) { ConvertTo-I3Json $resLily } else { '<none>' })))
[void](Assert-I2A 'T-01e-the-Origin-backup-is-never-deleted-and-the-PCSX2-neighbours-are-untouched' ([System.IO.File]::Exists([string]$v.Bk.Path) -and ((Txt (Get-I3Dest $L 'PCSX2.ini')) -ceq 'pcsx2-ini') -and ((Txt (Get-I3Dest $L 'PCSX2_ui.ini')) -ceq 'ui-settings')) 'backup kept; PCSX2.ini / PCSX2_ui.ini unchanged')
Remove-I2ASandbox $L.Root

# T-02 with IncludeInputProfiles: the same restore plus the removal of the unedited created profile
$L = New-I3UCase 't2'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'; $lily = Get-I3Dest $L 'DenGo-Controller-Converter.lily'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
$u = RunUninstall $L $true
[void](Assert-I2A 'T-02-IncludeInputProfiles-restores-LilyPad.ini-and-removes-the-unedited-profile' ((Succ $u) -and ((Txt $lilyPad) -ceq $script:I3UserOrigin) -and (-not [System.IO.File]::Exists($lily))) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $lilyPad)] lily exists=$([System.IO.File]::Exists($lily))"))
Remove-I2ASandbox $L.Root

# T-03 the Origin file is gone: the whole uninstall stops with nothing changed
$L = New-I3UCase 't3'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
[System.IO.File]::Delete([string]$v.Bk.Path)
$before = Get-I2CTree $L
$u = RunUninstall $L $false
[void](Assert-I2A 'T-03-a-missing-Origin-backup-stops-the-uninstall-with-zero-change' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ReplacedExistingBackupInvalid') -and ($u.Value.ManualCheckRequired -eq $true) -and (Test-I2CNoChange $L $before) -and ((Txt (Get-I3Dest $L 'LilyPad.ini')) -ceq $activeV1)) ("succeeded=$(Succ $u) code=$(CodeOf $u)"))
Remove-I2ASandbox $L.Root
# T-03b the Origin content was altered
$L = New-I3UCase 't3b'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec)
[System.IO.File]::WriteAllText([string]$v.Bk.Path, 'ALTERED', $script:Utf8)
$before = Get-I2CTree $L
$u = RunUninstall $L $false
[void](Assert-I2A 'T-03b-an-altered-Origin-backup-stops-the-uninstall-with-zero-change' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ReplacedExistingBackupInvalid') -and (Test-I2CNoChange $L $before)) ("succeeded=$(Succ $u) code=$(CodeOf $u)"))
Remove-I2ASandbox $L.Root

# T-04 contamination stops the uninstall
$L = New-I3UCase 't4'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
ConvertTo-I2CLegacyState $L
Write-I2CLegacyUninstalledState $L
$before = Get-I2CTree $L
$u = RunUninstall $L $false
$blk = @($(if ($u.Ok) { @($u.Value.Blocking) } else { @() }))
[void](Assert-I2A 'T-04-contamination-stops-the-uninstall-with-zero-change-and-names-the-Origin-backup' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ContaminationBlocksRestore') -and (Test-I2CNoChange $L $before) -and ($blk.Count -ge 1) -and ([string]$blk[0].Backup).Length -gt 0 -and [System.IO.File]::Exists([string]$blk[0].Backup)) ("succeeded=$(Succ $u) code=$(CodeOf $u) blocking=$($blk.Count)"))
Remove-I2ASandbox $L.Root

# T-05 an edited LilyPad.ini is preserved and the uninstall still completes
$L = New-I3UCase 't5'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
[System.IO.File]::WriteAllText($lilyPad, 'USER-EDITED-AFTER-INSTALL', $script:Utf8)
$u = RunUninstall $L $false
$us = $(if (Succ $u) { Get-I2CUs $L } else { $null })
$res = ResidualOf $us 'LilyPad.ini'
[void](Assert-I2A 'T-05-an-edited-LilyPad.ini-is-preserved-reported-and-the-uninstall-completes' ((Succ $u) -and ((Txt $lilyPad) -ceq 'USER-EDITED-AFTER-INSTALL') -and ($null -ne $res) -and ([string]$res.Disposition -ceq 'PreserveModified') -and ($res.ReviewRecommended -eq $true) -and ($us.ManualCheckRequired -eq $true) -and (@($us.UsedBackups).Count -eq 0)) ("succeeded=$(Succ $u) code=$(CodeOf $u) residual=" + $(if ($null -ne $res) { ConvertTo-I3Json $res } else { '<none>' })))
Remove-I2ASandbox $L.Root

# T-06 no Origin: the file is never deleted
$L = New-I3UCase 't6'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
Add-I3Records $L @((New-I3LilyPadRecord $L $NEW 'MigratedMatchingDenGoFile').Rec, (New-I3LilyRecord $L))
$u = RunUninstall $L $false
[void](Assert-I2A 'T-06a-without-an-Origin-LilyPad.ini-stays-by-default' ((Succ $u) -and ((Txt $lilyPad) -ceq $activeV1)) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $lilyPad)]"))
Remove-I2ASandbox $L.Root
$L = New-I3UCase 't6b'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
Add-I3Records $L @((New-I3LilyPadRecord $L $NEW 'CreatedByInstaller').Rec, (New-I3LilyRecord $L))
$u = RunUninstall $L $true
[void](Assert-I2A 'T-06b-without-an-Origin-LilyPad.ini-stays-even-with-IncludeInputProfiles' ((Succ $u) -and ((Txt $lilyPad) -ceq $activeV1) -and (-not [System.IO.File]::Exists((Get-I3Dest $L 'DenGo-Controller-Converter.lily')))) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $lilyPad)]"))
Remove-I2ASandbox $L.Root

# T-07 a closed generation's backup is not a restore source
$L = New-I3UCase 't7' -ClosedGen
$old = New-I3LilyPadRecord $L $OLD
Add-I3Records $L @($old.Rec)
$before = Get-I2CTree $L
$u = RunUninstall $L $false
[void](Assert-I2A 'T-07-a-backup-of-a-closed-generation-stops-the-uninstall-with-zero-change' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'ReplacedExistingBackupInvalid') -and (Test-I2CNoChange $L $before)) ("succeeded=$(Succ $u) code=$(CodeOf $u)"))
Remove-I2ASandbox $L.Root

# T-08 PCSX2 running: refused before any change
$L = New-I3UCase 't8'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec)
$before = Get-I2CTree $L
$u = RunUninstall $L $false { param($phase) throw 'Close target processes before uninstall: pcsx2.exe' }
[void](Assert-I2A 'T-08-a-running-PCSX2-refuses-the-uninstall-with-zero-change' ((-not (Succ $u)) -and ((CodeOf $u) -ceq 'BlockedByRunningProcesses') -and (Test-I2CNoChange $L $before) -and ((Txt (Get-I3Dest $L 'LilyPad.ini')) -ceq $activeV1)) ("succeeded=$(Succ $u) code=$(CodeOf $u)"))
Remove-I2ASandbox $L.Root

# T-11 the dry run decides the same and writes nothing
$L = New-I3UCase 't11'
$v = New-I3LilyPadRecord $L
Add-I3Records $L @($v.Rec, (New-I3LilyRecord $L))
$before = Get-I2CTree $L
$d = Invoke-I3 { Get-I2CDryRun $L $false }
[void](Assert-I2A 'T-11a-the-dry-run-reports-the-restore-and-writes-nothing' ($d.Ok -and ($d.Value.Succeeded -eq $true) -and ($d.Value.Counts.Restored -eq 1) -and ($d.Value.Counts.Deferred -eq 0) -and (@($d.Value.DeferredRecords).Count -eq 0) -and (Test-I2CNoChange $L $before)) ("restored=$(if ($d.Ok) { $d.Value.Counts.Restored } else { '?' }) deferred=$(if ($d.Ok) { $d.Value.Counts.Deferred } else { '?' })" + (Get-I3Err $d)))
Remove-I2ASandbox $L.Root

# ---------------------------------------------------------------- controls (existing behaviour that must survive)
# T-09 the DeferredRecords of a closed generation are carried verbatim and never promoted or applied (reconfirmation of an already uninstalled state)
$L = New-I3Case 't9'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
$g = Invoke-I3 { Invoke-I2BInstall $L (Get-I2CPlatformPlan $L @('Core')) $false }
$u1 = RunUninstall $L $false
$closedDir = Join-Path $L.Product.BackupRoot '20250101-000000'; [void][System.IO.Directory]::CreateDirectory($closedDir)
$closedBk = Join-Path $closedDir 'aaaaaaaabbbbbbbbccccccccdddddddd.bak'; [System.IO.File]::WriteAllText($closedBk, 'ORIGIN-OF-THE-CLOSED-GENERATION', $script:Utf8)
$closedRec = [pscustomobject][ordered]@{ Platform = 'PCSX2'; Component = 'EffectiveInputProfile'; Destination = $lilyPad; InstallAction = 'UpdateOrRepair'; Ownership = 'ReplacedExisting'; ExistedBefore = $true; BeforeSHA256 = (Get-I3Sha $closedBk); AfterSHA256 = (Get-I3TextSha $activeV1); Backup = $closedBk }
$usObj = Get-I2CUs $L
Set-I2CProperty $usObj 'DeferredRecords' ([object[]]@([pscustomobject][ordered]@{ Record = $closedRec; Reason = 'DeferredToI3' }))
Write-I2CJson (Get-I2CUsPath $L) $usObj
$injected = ConvertTo-I3Json @((Get-I2CUs $L).DeferredRecords)
$userSha = Get-I3Sha $lilyPad
$u2 = RunUninstall $L $false
$us2 = $(if (Succ $u2) { Get-I2CUs $L } else { $null })
[void](Assert-I2A 'T-09-control-an-already-uninstalled-state-carries-the-closed-DeferredRecords-verbatim' ((Succ $g) -and (Succ $u1) -and (Succ $u2) -and ($u2.Value.AlreadyUninstalled -eq $true) -and ($null -ne $us2) -and ((ConvertTo-I3Json @($us2.DeferredRecords)) -ceq $injected) -and ((Get-I3Sha $lilyPad) -ceq $userSha) -and ((Txt $closedBk) -ceq 'ORIGIN-OF-THE-CLOSED-GENERATION')) ("install=$(CodeOf $g) uninstall1=$(CodeOf $u1) uninstall2=$(CodeOf $u2) deferred kept=$($null -ne $us2 -and (ConvertTo-I3Json @($us2.DeferredRecords)) -ceq $injected)"))
Remove-I2ASandbox $L.Root

# T-10 a PCSX2 record inside ClosedRecords is never applied
$L = New-I3UCase 't10'
$lilyPad = Get-I3Dest $L 'LilyPad.ini'
$v = New-I3LilyPadRecord $L
Edit-I2CInstalledState $L { param($o) $o.ClosedRecords = [object[]]@([pscustomobject][ordered]@{ Record = $v.Rec; ClosedAt = '2026-10-01T00:00:00Z'; ClosedTransactionId = '20261001T000000Z-aaaaaaaa'; Reason = 'NoOwnershipAndMissing' }) }
$u = RunUninstall $L $false
[void](Assert-I2A 'T-10-control-a-PCSX2-record-in-ClosedRecords-is-never-applied' ((Succ $u) -and ((Txt $lilyPad) -ceq $activeV1)) ("succeeded=$(Succ $u) code=$(CodeOf $u) LilyPad.ini=[$(Txt $lilyPad)]"))
Remove-I2ASandbox $L.Root
Complete-I2ATests
