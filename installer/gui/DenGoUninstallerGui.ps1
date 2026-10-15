param(
    [switch]$Preview,
    [ValidateSet('Auto','Both','PCSX2','RPCS3','None')]
    [string]$PreviewProfiles = 'Auto',
    [string]$ResultPath = '',
    [string]$RunId = ''
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
$script:hasBveIntegration = $false
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
        $bveItems = @($installedState.Files | Where-Object {
            ([string]$_.Platform -in @('BVE5','BVE6','BveEX Current','AtsEX Legacy')) -and
            [System.IO.File]::Exists([string]$_.Destination)
        })
        $script:hasBveIntegration = @($bveItems).Count -gt 0
    } catch {
        $script:hasPCSX2Profile = $false
        $script:hasRPCS3Profile = $false
        $script:hasBveIntegration = $false
    }
}
function Get-ProfilePreservationText {
    param([bool]$Completed)
    if ($script:hasPCSX2Profile -and $script:hasRPCS3Profile) {
        return $(if ($Completed) { 'PCSX2とRPCS3の各プロファイルは保持されています' } else { 'PCSX2とRPCS3の各プロファイルは保持されます' })
    }
    if ($script:hasPCSX2Profile) {
        return $(if ($Completed) { 'PCSX2のプロファイルは保持されています' } else { 'PCSX2のプロファイルは保持されます' })
    }
    if ($script:hasRPCS3Profile) {
        return $(if ($Completed) { 'RPCS3のプロファイルは保持されています' } else { 'RPCS3のプロファイルは保持されます' })
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
$script:finalResult = 'Failed'
$script:finalReason = 'NotCompleted'
$script:applyRunning = $false
$script:engineStarted = $false
$script:engineCompleted = $false
$script:stateCommitted = $false
$script:applyStartedAt = [System.DateTimeOffset]::MinValue

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
$startText.Text = if ($script:hasBveIntegration) { '本体とBVE連携機能を削除します' } else { '本体を削除します' }
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
$progressText.Text = if ($script:hasBveIntegration) { 'DenGo本体とBVE連携機能を削除しています' } else { 'DenGo本体を削除しています' }
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
$completeText.Text = if ($script:hasBveIntegration) { '本体とBVE連携機能を削除しました' } else { '本体を削除しました' }
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

function Get-PeMachineForRunningProduct {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return '' }
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return '' }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { return '' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { return '' }
        $machine = $reader.ReadUInt16()
        if ($machine -eq 0x014C) { return 'x86' }
        if ($machine -eq 0x8664) { return 'x64' }
        return ''
    } finally {
        $stream.Dispose()
    }
}
function Get-RunningProductNames {
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        [string]::Equals([string]$_.Name,'BveTs.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'rpcs3.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'DenGoControllerConverter.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'pcsx2-qt.exe',[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$_.Name,'pcsx2.exe',[System.StringComparison]::OrdinalIgnoreCase)
    })
    $products = New-Object System.Collections.ArrayList
    foreach ($process in $running) {
        $name = [string]$process.Name
        if ([string]::Equals($name,'BveTs.exe',[System.StringComparison]::OrdinalIgnoreCase)) {
            $machine = Get-PeMachineForRunningProduct ([string]$process.ExecutablePath)
            $product = if ($machine -eq 'x64') { 'BVE Trainsim 6' } elseif ($machine -eq 'x86') { 'BVE Trainsim 5' } else { 'BVE Trainsim' }
        } elseif ([string]::Equals($name,'rpcs3.exe',[System.StringComparison]::OrdinalIgnoreCase)) {
            $product = 'RPCS3'
        } elseif ([string]::Equals($name,'DenGoControllerConverter.exe',[System.StringComparison]::OrdinalIgnoreCase)) {
            $product = 'DenGo Controller Converter'
        } else {
            $product = 'PCSX2'
        }
        if (-not @($products).Contains($product)) { [void]$products.Add($product) }
    }
    $order = @('BVE Trainsim 6','BVE Trainsim 5','BVE Trainsim','PCSX2','RPCS3','DenGo Controller Converter')
    return [string[]]@($products | Sort-Object { [array]::IndexOf($order,[string]$_) })
}
function Confirm-RunningProductsClosed {
    while ($true) {
        $products = @(Get-RunningProductNames)
        if (@($products).Count -eq 0) { return $true }
        $list = [string]::Join([System.Environment]::NewLine,[string[]]@($products | ForEach-Object { [string][char]0x30FB + [string]$_ }))
        $message = '対応ソフトをすべて終了してから「再試行」を押してください' + [System.Environment]::NewLine + [System.Environment]::NewLine + '起動中の対応ソフト：' + [System.Environment]::NewLine + $list
        $answer = [System.Windows.Forms.MessageBox]::Show($message,'対応ソフトが起動しています',[System.Windows.Forms.MessageBoxButtons]::RetryCancel,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Retry) { continue }
        return $false
    }
}

function Join-NativeArguments {
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

# --- I1 result contract: Completed (exit 0) / Cancelled (exit 2) / Failed (exit 1) ---
function Show-GuiError {
    param([string]$Text)
    [void][System.Windows.Forms.MessageBox]::Show($Text,[regex]::Unescape('DenGo \u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB'),[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
}
function Set-RunFailed {
    param([string]$Reason)
    $script:engineCompleted = $false
    $script:stateCommitted = $false
    $script:finalResult = 'Failed'
    $script:finalReason = $Reason
}
function Set-RunCompleted {
    $script:finalResult = 'Completed'
    $script:finalReason = 'Completed'
    $script:engineCompleted = $true
    $script:stateCommitted = $true
}
# Cancelled is reachable only through an explicit, confirmed pre-apply cancel; anything else stays Failed/NotCompleted.
function Set-RunCancelled {
    if ([string]::Equals($script:finalResult,'Failed',[System.StringComparison]::Ordinal) -and [string]::Equals($script:finalReason,'NotCompleted',[System.StringComparison]::Ordinal) -and -not $script:engineStarted) {
        $script:finalResult = 'Cancelled'
        $script:finalReason = 'UserCancelled'
    }
}
function Invoke-UnhandledGuiException {
    param([System.Exception]$Exception)
    if (-not [string]::Equals($script:finalResult,'Completed',[System.StringComparison]::Ordinal) -and [string]::Equals($script:finalReason,'NotCompleted',[System.StringComparison]::Ordinal)) { Set-RunFailed 'UnhandledException' }
    $detail = ''
    if ($null -ne $Exception) { $detail = [System.Environment]::NewLine + [System.Environment]::NewLine + [string]$Exception.Message }
    Show-GuiError ([regex]::Unescape('\u4E88\u671F\u3057\u306A\u3044\u30A8\u30E9\u30FC\u304C\u767A\u751F\u3057\u307E\u3057\u305F\u3002') + $detail)
}
function Test-UninstallCommitted {
    param([object]$Result,[int]$ExitCode)
    try {
        if ($ExitCode -ne 0) { return $false }
        if (-not [bool]$Result.Succeeded) { return $false }
        if (-not [bool]$Result.Apply -or -not [bool]$Result.RealSystem) { return $false }
        $statePath = Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState\uninstalled-state.json'
        if (-not [System.IO.File]::Exists($statePath)) { return $false }
        $state = [System.IO.File]::ReadAllText($statePath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$state.SchemaVersion -ne 1) { return $false }
        if (-not [string]::Equals([string]$state.State,'Uninstalled',[System.StringComparison]::Ordinal)) { return $false }
        $uninstalledAt = [System.DateTimeOffset]::Parse([string]$state.UninstalledAt,[System.Globalization.CultureInfo]::InvariantCulture)
        return ($uninstalledAt -ge $script:applyStartedAt)
    } catch { return $false }
}
function Write-RunResult {
    param([string]$Result,[string]$Reason,[int]$ExitCode)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return $true }
    $temporary = $null
    try {
        if ([string]::IsNullOrWhiteSpace($RunId)) { return $false }
        $final = [System.IO.Path]::GetFullPath($ResultPath)
        $directory = [System.IO.Path]::GetDirectoryName($final)
        if (-not [System.IO.Directory]::Exists($directory)) { return $false }
        if ([System.IO.File]::Exists($final)) { return $false }
        $temporary = $final + '.tmp'
        $document = [ordered]@{schemaVersion=1;operation='Uninstall';runId=$RunId;result=$Result;reason=$Reason;exitCode=$ExitCode;engineStarted=[bool]$script:engineStarted;engineCompleted=[bool]$script:engineCompleted;stateCommitted=[bool]$script:stateCommitted;writtenAt=[System.DateTimeOffset]::Now.ToString('o')}
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($document | ConvertTo-Json))
        $stream = New-Object System.IO.FileStream($temporary,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
        $check = [System.IO.File]::ReadAllText($temporary,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$check.schemaVersion -ne 1 -or -not [string]::Equals([string]$check.runId,$RunId,[System.StringComparison]::Ordinal) -or -not [string]::Equals([string]$check.result,$Result,[System.StringComparison]::Ordinal) -or [int]$check.exitCode -ne $ExitCode) { throw 'Result verification failed.' }
        [System.IO.File]::Move($temporary,$final)
        return $true
    } catch {
        try { if ($null -ne $temporary -and [System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } } catch {}
        return $false
    }
}
function Complete-Run {
    $result = $script:finalResult
    $reason = $script:finalReason
    $invariantOk = $true
    if ([string]::Equals($result,'Completed',[System.StringComparison]::Ordinal)) { $invariantOk = [bool]($script:engineStarted -and $script:engineCompleted -and $script:stateCommitted) }
    elseif ([string]::Equals($result,'Cancelled',[System.StringComparison]::Ordinal)) { $invariantOk = -not [bool]($script:engineStarted -or $script:engineCompleted -or $script:stateCommitted) }
    if (-not $invariantOk) { $result = 'Failed';$reason = 'InvariantViolation' }
    $exitCode = 1
    if ([string]::Equals($result,'Completed',[System.StringComparison]::Ordinal)) { $exitCode = 0 }
    elseif ([string]::Equals($result,'Cancelled',[System.StringComparison]::Ordinal)) { $exitCode = 2 }
    if (-not (Write-RunResult $result $reason $exitCode)) { return 1 }
    return $exitCode
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
    $script:applyRunning = $false
    $exitCode = $script:process.ExitCode
    $script:process.Dispose()
    $script:process = $null
    $resultPath = Join-Path $script:outputRoot 'uninstall-plan.json'
    if (-not [System.IO.File]::Exists($resultPath)) {
        [System.Windows.Forms.MessageBox]::Show(('アンインストール結果を確認できませんでした。 終了コード: ' + $exitCode),'DenGo アンインストール',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Set-RunFailed 'EngineNoResult'
        Set-Page 'start'
        return
    }
    try { $result = [System.IO.File]::ReadAllText($resultPath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
        Set-RunFailed 'EngineResultCorrupt'
        Show-GuiError ([regex]::Unescape('\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002'))
        Set-Page 'start'
        return
    }
    if ($exitCode -ne 0 -or -not [bool]$result.Succeeded) {
        $detail = [string]$result.ErrorMessage
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'アンインストールに失敗しました。' }
        [System.Windows.Forms.MessageBox]::Show($detail,'DenGo アンインストール',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Set-RunFailed 'EngineFailed'
        Set-Page 'start'
        return
    }
    if (-not (Test-UninstallCommitted $result $exitCode)) {
        Set-RunFailed 'EngineStateNotCommitted'
        Show-GuiError ([regex]::Unescape('\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002'))
        Set-Page 'start'
        return
    }
    Set-RunCompleted
    Set-Page 'complete'
})

$startButton.Add_Click({
    if ($Preview) { Set-Page 'progress';$script:previewTimer=New-Object System.Windows.Forms.Timer;$script:previewTimer.Interval=700;$script:previewTimer.Add_Tick({$script:previewTimer.Stop();$script:previewTimer.Dispose();$script:previewTimer=$null;Set-Page 'complete'});$script:previewTimer.Start();return }
    if (-not (Confirm-RunningProductsClosed)) {
        if (Confirm-Cancel) { Set-RunCancelled;$script:allowClose=$true;$form.Close() }
        return
    }
    if (-not [System.IO.File]::Exists($engine)) {
        [System.Windows.Forms.MessageBox]::Show(('アンインストールエンジンが見つかりません。' + [System.Environment]::NewLine + $engine),'DenGo アンインストール',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Set-RunFailed 'EngineNotFound'
        return
    }
    if ([System.IO.Directory]::Exists($script:runRoot)) { Remove-Item -LiteralPath $script:runRoot -Recurse -Force }
    [System.IO.Directory]::CreateDirectory($script:outputRoot) | Out-Null
    Set-Page 'progress'
    $script:barX=1;$script:barStep=7;$block.Left=1
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Apply','-RealSystem','-ConfirmRealApply','UNINSTALL','-OutputRoot',$script:outputRoot)
    $argumentLine=Join-NativeArguments $arguments
    $script:applyStartedAt = [System.DateTimeOffset]::Now
    $script:engineCompleted = $false;$script:stateCommitted = $false
    $script:applyRunning = $true
    try {
        $script:process=Start-Process powershell.exe -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
        $script:engineStarted = $true
    } catch {
        $script:applyRunning = $false;$script:process = $null
        Set-RunFailed 'EngineLaunchFailed'
        Show-GuiError ([regex]::Unescape('\u30A2\u30F3\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002'))
        Set-Page 'start'
        return
    }
    $timer.Start()
})
$cancelButton.Add_Click({ if (Confirm-Cancel) { Set-RunCancelled;$script:allowClose=$true;$form.Close() } })
$finishButton.Add_Click({ $script:allowClose=$true;$form.Close() })
$form.Add_FormClosing({
    if ($script:applyRunning) {
        if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $_.Cancel=$true }
        else { Set-RunFailed 'GuiClosedDuringApply' }
        return
    }
    if ($script:allowClose) { return }
    if ($_.CloseReason -ne [System.Windows.Forms.CloseReason]::UserClosing) { $script:allowClose=$true;return }
    if ([string]::Equals($script:finalResult,'Completed',[System.StringComparison]::Ordinal)) { $script:allowClose=$true;return }
    if (Confirm-Cancel) { Set-RunCancelled;$script:allowClose=$true;$_.Cancel=$false } else { $_.Cancel=$true }
})
$form.Add_FormClosed({
    $timer.Stop()
    if ($null -ne $script:process) { try { $script:process.Dispose() } catch {} }
    if ($null -ne $script:previewTimer) { try { $script:previewTimer.Stop();$script:previewTimer.Dispose() } catch {} }
})
Set-Page 'start'
[System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{ param($sender,$e);Invoke-UnhandledGuiException $e.Exception })
try { [void]$form.ShowDialog() } catch { Set-RunFailed 'GuiException' }
exit ([int](Complete-Run))
