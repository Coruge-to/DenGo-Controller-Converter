param(
    [switch]$Preview,
    [ValidateSet('Auto','Both','PCSX2','RPCS3','None')]
    [string]$PreviewProfiles = 'Auto'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)) '..'))
$engine = Join-Path $root 'scripts\Invoke-DenGoUninstaller.ps1'
$statePath = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState\installed-state.json'
$script:hasPCSX2Profile = $false
$script:hasRPCS3Profile = $false
if ($Preview -and -not [string]::Equals($PreviewProfiles,'Auto',[System.StringComparison]::Ordinal)) {
    $script:hasPCSX2Profile = $PreviewProfiles -in @('Both','PCSX2')
    $script:hasRPCS3Profile = $PreviewProfiles -in @('Both','RPCS3')
} elseif ([System.IO.File]::Exists($statePath)) {
    try {
        $installedState = [System.IO.File]::ReadAllText($statePath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $profileItems = @($installedState.Files | Where-Object {
            [string]::Equals([string]$_.Component,'InputProfile',[System.StringComparison]::Ordinal) -and
            [System.IO.File]::Exists([string]$_.Destination)
        })
        $script:hasPCSX2Profile = @($profileItems | Where-Object { [string]::Equals([string]$_.Platform,'PCSX2',[System.StringComparison]::Ordinal) }).Count -gt 0
        $script:hasRPCS3Profile = @($profileItems | Where-Object { [string]::Equals([string]$_.Platform,'RPCS3',[System.StringComparison]::Ordinal) }).Count -gt 0
    } catch {
        $script:hasPCSX2Profile = $false
        $script:hasRPCS3Profile = $false
    }
}
function Get-ProfilePreservationText {
    param([bool]$Completed)
    if ($script:hasPCSX2Profile -and $script:hasRPCS3Profile) {
        return $(if ($Completed) { 'PCSX2とRPCS3の入力設定は保持されています' } else { 'PCSX2とRPCS3の入力設定は保持されます' })
    }
    if ($script:hasPCSX2Profile) {
        return $(if ($Completed) { 'PCSX2の入力設定は保持されています' } else { 'PCSX2の入力設定は保持されます' })
    }
    if ($script:hasRPCS3Profile) {
        return $(if ($Completed) { 'RPCS3の入力設定は保持されています' } else { 'RPCS3の入力設定は保持されます' })
    }
    return ''
}
$script:runRoot = Join-Path $env:TEMP ('DenGoUninstallerGui-' + [System.Guid]::NewGuid().ToString('N'))
$script:outputRoot = Join-Path $script:runRoot 'apply'
$script:process = $null
$script:allowClose = $false
$script:barX = 1
$script:barStep = 7
$script:previewTimer = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DenGo Controller Converter アンインストール'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(560,348)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Yu Gothic UI',9)
$form.BackColor = [System.Drawing.Color]::White

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 61
$header.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($header)
$title = New-Object System.Windows.Forms.Label
$title.Text = 'DenGo Controller Converter'
$title.Font = New-Object System.Drawing.Font('Yu Gothic UI',15,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(28,16)
$header.Controls.Add($title)
$line = New-Object System.Windows.Forms.Panel
$line.Dock = 'Bottom'
$line.Height = 1
$line.BackColor = [System.Drawing.Color]::FromArgb(205,205,205)
$header.Controls.Add($line)

$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'
$content.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($content)
$content.BringToFront()

function New-Button {
    param([string]$Text,[int]$X,[int]$Width,[bool]$Primary)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width,32)
    $button.Location = New-Object System.Drawing.Point($X,303)
    $button.Anchor = 'Bottom,Right'
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
    if ($Primary) {
        $button.BackColor = [System.Drawing.Color]::FromArgb(0,103,192)
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $button.BackColor
    } else {
        $button.BackColor = [System.Drawing.Color]::White
        $button.ForeColor = [System.Drawing.Color]::FromArgb(32,32,32)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(145,145,145)
    }
    $form.Controls.Add($button)
    $button.BringToFront()
    return $button
}

$startButton = New-Button 'アンインストール' 326 116 $true
$cancelButton = New-Button 'キャンセル' 450 96 $false
$finishButton = New-Button '完了' 450 96 $true

$startPage = New-Object System.Windows.Forms.Panel
$startPage.Dock = 'Fill'
$content.Controls.Add($startPage)
$startTitle = New-Object System.Windows.Forms.Label
$startTitle.Text = "DenGo Controller Converter`r`nのアンインストールを開始します"
$startTitle.Font = New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold)
$startTitle.AutoSize = $true
$startTitle.Location = New-Object System.Drawing.Point(42,45)
$startPage.Controls.Add($startTitle)
$startText = New-Object System.Windows.Forms.Label
$startProfileText = Get-ProfilePreservationText $false
$startText.Text = '本体とBVE連携機能を削除します'
if (-not [string]::IsNullOrWhiteSpace($startProfileText)) { $startText.Text += [System.Environment]::NewLine + $startProfileText }
$startText.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
$startText.AutoSize = $true
$startText.Location = New-Object System.Drawing.Point(45,124)
$startPage.Controls.Add($startText)

$progressPage = New-Object System.Windows.Forms.Panel
$progressPage.Dock = 'Fill'
$progressPage.Visible = $false
$content.Controls.Add($progressPage)
$progressTitle = New-Object System.Windows.Forms.Label
$progressTitle.Text = 'アンインストールしています'
$progressTitle.Font = New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold)
$progressTitle.AutoSize = $true
$progressTitle.Location = New-Object System.Drawing.Point(42,45)
$progressPage.Controls.Add($progressTitle)
$progressText = New-Object System.Windows.Forms.Label
$progressText.Text = 'DenGo本体とBVE連携機能を削除しています'
$progressText.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
$progressText.AutoSize = $true
$progressText.Location = New-Object System.Drawing.Point(45,91)
$progressPage.Controls.Add($progressText)
$track = New-Object System.Windows.Forms.Panel
$track.Size = New-Object System.Drawing.Size(466,18)
$track.Location = New-Object System.Drawing.Point(46,126)
$track.BackColor = [System.Drawing.Color]::FromArgb(225,225,225)
$track.BorderStyle = 'FixedSingle'
$progressPage.Controls.Add($track)
$block = New-Object System.Windows.Forms.Panel
$block.Size = New-Object System.Drawing.Size(94,14)
$block.Location = New-Object System.Drawing.Point(1,1)
$block.BackColor = [System.Drawing.Color]::FromArgb(0,103,192)
$track.Controls.Add($block)
$progressHint = New-Object System.Windows.Forms.Label
$progressHint.Text = 'しばらくお待ちください'
$progressHint.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
$progressHint.ForeColor = [System.Drawing.Color]::FromArgb(45,45,45)
$progressHint.AutoSize = $true
$progressHint.Location = New-Object System.Drawing.Point(43,163)
$progressPage.Controls.Add($progressHint)

$completePage = New-Object System.Windows.Forms.Panel
$completePage.Dock = 'Fill'
$completePage.Visible = $false
$content.Controls.Add($completePage)
$completeTitle = New-Object System.Windows.Forms.Label
$completeTitle.Text = "DenGo Controller Converter`r`nのアンインストールが完了しました"
$completeTitle.Font = New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold)
$completeTitle.AutoSize = $true
$completeTitle.Location = New-Object System.Drawing.Point(42,58)
$completePage.Controls.Add($completeTitle)
$completeText = New-Object System.Windows.Forms.Label
$completeProfileText = Get-ProfilePreservationText $true
$completeText.Text = '本体とBVE連携機能を削除しました'
if (-not [string]::IsNullOrWhiteSpace($completeProfileText)) { $completeText.Text += [System.Environment]::NewLine + $completeProfileText }
$completeText.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
$completeText.AutoSize = $true
$completeText.Location = New-Object System.Drawing.Point(45,139)
$completePage.Controls.Add($completeText)

function Set-Page {
    param([string]$Name)
    $startPage.Visible = [string]::Equals($Name,'start',[System.StringComparison]::Ordinal)
    $progressPage.Visible = [string]::Equals($Name,'progress',[System.StringComparison]::Ordinal)
    $completePage.Visible = [string]::Equals($Name,'complete',[System.StringComparison]::Ordinal)
    $startButton.Visible = [string]::Equals($Name,'start',[System.StringComparison]::Ordinal)
    $cancelButton.Visible = [string]::Equals($Name,'start',[System.StringComparison]::Ordinal)
    $finishButton.Visible = [string]::Equals($Name,'complete',[System.StringComparison]::Ordinal)
    foreach ($button in @($startButton,$cancelButton,$finishButton)) { if ($button.Visible) { $button.BringToFront() } }
    $form.AcceptButton = if ($startButton.Visible) { $startButton } elseif ($finishButton.Visible) { $finishButton } else { $null }
}

function Confirm-Cancel {
    $answer = [System.Windows.Forms.MessageBox]::Show('アンインストールを中止しますか？','DenGo Controller Converter アンインストール',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 35
$timer.Add_Tick({
    $limit = $track.ClientSize.Width - $block.Width - 2
    $script:barX += $script:barStep
    if ($script:barX -ge $limit) { $script:barX=$limit;$script:barStep=-7 }
    if ($script:barX -le 1) { $script:barX=1;$script:barStep=7 }
    $block.Left = $script:barX
    if ($null -eq $script:process -or -not $script:process.HasExited) { return }
    $timer.Stop()
    $exitCode = $script:process.ExitCode
    $script:process.Dispose()
    $script:process = $null
    $resultPath = Join-Path $script:outputRoot 'uninstall-plan.json'
    if (-not [System.IO.File]::Exists($resultPath)) {
        [System.Windows.Forms.MessageBox]::Show(('アンインストール結果を確認できませんでした。 終了コード: ' + $exitCode),'DenGo アンインストール',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Set-Page 'start'
        return
    }
    $result = [System.IO.File]::ReadAllText($resultPath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not [bool]$result.Succeeded) {
        $detail = [string]$result.ErrorMessage
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'アンインストールに失敗しました。' }
        [System.Windows.Forms.MessageBox]::Show($detail,'DenGo アンインストール',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Set-Page 'start'
        return
    }
    Set-Page 'complete'
})

$startButton.Add_Click({
    if ($Preview) { Set-Page 'progress';$script:previewTimer=New-Object System.Windows.Forms.Timer;$script:previewTimer.Interval=700;$script:previewTimer.Add_Tick({$script:previewTimer.Stop();$script:previewTimer.Dispose();$script:previewTimer=$null;Set-Page 'complete'});$script:previewTimer.Start();return }
    if (-not [System.IO.File]::Exists($engine)) {
        [System.Windows.Forms.MessageBox]::Show(('アンインストールエンジンが見つかりません。' + [System.Environment]::NewLine + $engine),'DenGo アンインストール',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ([System.IO.Directory]::Exists($script:runRoot)) { Remove-Item -LiteralPath $script:runRoot -Recurse -Force }
    [System.IO.Directory]::CreateDirectory($script:outputRoot) | Out-Null
    Set-Page 'progress'
    $script:barX=1;$script:barStep=7;$block.Left=1
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Apply','-RealSystem','-ConfirmRealApply','UNINSTALL','-OutputRoot',$script:outputRoot)
    $script:process = Start-Process powershell.exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $timer.Start()
})
$cancelButton.Add_Click({ if (Confirm-Cancel) { $script:allowClose=$true;$form.Close() } })
$finishButton.Add_Click({ $script:allowClose=$true;$form.Close() })
$form.Add_FormClosing({
    if ($script:allowClose) { return }
    if ($progressPage.Visible) { $_.Cancel=$true;return }
    if (Confirm-Cancel) { $script:allowClose=$true;$_.Cancel=$false } else { $_.Cancel=$true }
})
$form.Add_FormClosed({
    $timer.Stop()
    if ($null -ne $script:process) { try { $script:process.Dispose() } catch {} }
    if ($null -ne $script:previewTimer) { try { $script:previewTimer.Stop();$script:previewTimer.Dispose() } catch {} }
})
Set-Page 'start'
[void]$form.ShowDialog()
