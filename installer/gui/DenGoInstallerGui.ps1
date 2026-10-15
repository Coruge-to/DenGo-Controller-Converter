param(
    [ValidateSet('Normal','Symbols','PCSX2Conflict','RPCS3Conflict','BothConflicts','PCSX2Unsupported','BveEXMissing')]
    [string]$Preview = 'Normal',
    [string]$ResultPath = '',
    [string]$RunId = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)) '..'))
$engine = Join-Path $root 'scripts\Invoke-DenGoInstaller.ps1'
$welcomeImagePath = Join-Path $root 'assets\images\DenGo-Controller-Converter2.png'
$script:runRoot = Join-Path $env:TEMP ('DenGoInstallerGui-' + [System.Guid]::NewGuid().ToString('N'))
$script:outputRoot = Join-Path $script:runRoot 'dryrun'
$script:sandboxRoot = Join-Path $script:runRoot 'sandbox'
$planPath = Join-Path $script:outputRoot 'install-plan.json'
$script:operation = 'idle'
$script:allowClose = $false
$script:lastResultAvailable = $false
$script:process = $null
$script:plan = $null
$script:conflicts = @()
$script:conflictIndex = 0
$script:decisions = @{}
$script:unsupportedPCSX2Shown = $false
$script:missingBveEXShown = $false
$script:bveIntegrationSkipped = $false
$script:finalResult = 'Failed'
$script:finalReason = 'NotCompleted'
$script:applyRunning = $false
$script:engineStarted = $false
$script:engineCompleted = $false
$script:stateCommitted = $false
$script:applyStartedAt = [System.DateTimeOffset]::MinValue
$script:barX = 1
$script:barStep = 7

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DenGo Controller Converter セットアップ'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(560,348)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Yu Gothic UI',9)
$form.BackColor = [System.Drawing.Color]::White

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 61; $header.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($header)
$title = New-Object System.Windows.Forms.Label
$title.Text = 'DenGo Controller Converter'; $title.Font = New-Object System.Drawing.Font('Yu Gothic UI',15,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true; $title.Location = New-Object System.Drawing.Point(28,16)
$header.Controls.Add($title)
$line = New-Object System.Windows.Forms.Panel
$line.Dock = 'Bottom'; $line.Height = 1; $line.BackColor = [System.Drawing.Color]::FromArgb(205,205,205)
$header.Controls.Add($line)

$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($content); $content.BringToFront()

# Footer panel removed; navigation buttons are direct form controls`n
function New-Button([string]$Text,[int]$X,[int]$Width,[bool]$Primary) {
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$Text; $b.Size=New-Object System.Drawing.Size($Width,32); $b.Location=New-Object System.Drawing.Point($X,303); $b.Anchor='Bottom,Right'
    $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=1; $b.Font=New-Object System.Drawing.Font('Yu Gothic UI',10)
    if($Primary){$b.BackColor=[System.Drawing.Color]::FromArgb(0,103,192);$b.ForeColor=[System.Drawing.Color]::White;$b.FlatAppearance.BorderColor=$b.BackColor}
    else{$b.BackColor=[System.Drawing.Color]::White;$b.ForeColor=[System.Drawing.Color]::FromArgb(32,32,32);$b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(145,145,145)}
    $form.Controls.Add($b); $b.BringToFront(); return $b
}
$next=New-Button '次へ' 350 92 $true
$cancel=New-Button 'キャンセル' 450 96 $false
$search=New-Button '追加の環境を検索' 280 162 $false
$finish=New-Button '完了' 450 96 $true
$applyChoice=New-Button '次へ' 350 92 $true
$useExisting=New-Button 'いいえ' 442 96 $true
$replaceSetting=New-Button 'はい' 338 96 $false

function New-LargeCheck([string]$Text,[bool]$Checked) {
    $panel=New-Object System.Windows.Forms.Panel
    $panel.Size=New-Object System.Drawing.Size(360,32)
    $panel.BackColor=[System.Drawing.Color]::White
    $panel.Cursor='Hand'
    $panel.TabStop=$true
    $panel.Tag=[pscustomobject]@{Checked=$Checked;Text=$Text}
    $panel.Add_Paint({param($sender,$e)
        $g=$e.Graphics;$g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $box=New-Object System.Drawing.Rectangle(3,8,14,14)
        $pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70,70,70),1.25)
        $g.DrawRectangle($pen,$box);$pen.Dispose()
        if([bool]$sender.Tag.Checked){
            $checkPen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0,103,192),2.0)
            $checkPen.StartCap=[System.Drawing.Drawing2D.LineCap]::Round;$checkPen.EndCap=[System.Drawing.Drawing2D.LineCap]::Round
            $g.DrawLines($checkPen,[System.Drawing.Point[]]@((New-Object System.Drawing.Point(6,15)),(New-Object System.Drawing.Point(9,18)),(New-Object System.Drawing.Point(15,11))))
            $checkPen.Dispose()
        }
        $font=New-Object System.Drawing.Font('Yu Gothic UI',11)
        $brush=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(28,28,28))
        $g.DrawString([string]$sender.Tag.Text,$font,$brush,24,4)
        $brush.Dispose();$font.Dispose()
        if($sender.Focused){[System.Windows.Forms.ControlPaint]::DrawFocusRectangle($g,(New-Object System.Drawing.Rectangle(22,3,332,25)))}
    })
    $toggle={param($sender,$eventArgs);$sender.Tag.Checked=-not[bool]$sender.Tag.Checked;$sender.Invalidate()}
    $panel.Add_Click($toggle)
    $panel.Add_KeyDown({param($sender,$eventArgs);if($eventArgs.KeyCode-eq[System.Windows.Forms.Keys]::Space){$sender.Tag.Checked=-not[bool]$sender.Tag.Checked;$sender.Invalidate();$eventArgs.Handled=$true}})
    $panel.Add_Enter({param($sender,$eventArgs);$sender.Invalidate()})
    $panel.Add_Leave({param($sender,$eventArgs);$sender.Invalidate()})
    return $panel
}

$welcome=New-Object System.Windows.Forms.Panel; $welcome.Dock='Fill'; $content.Controls.Add($welcome)
$welcomeText=New-Object System.Windows.Forms.Label
$welcomeText.Text="DenGo Controller Converter`r`nのインストールを開始します";$welcomeText.Font=New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold);$welcomeText.AutoSize=$true;$welcomeText.Location=New-Object System.Drawing.Point(42,45);$welcome.Controls.Add($welcomeText)
$welcomeHint=New-Object System.Windows.Forms.Label
$welcomeHint.Text='「次へ」をクリックして続行してください';$welcomeHint.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$welcomeHint.ForeColor=[System.Drawing.Color]::FromArgb(45,45,45);$welcomeHint.AutoSize=$true;$welcomeHint.Location=New-Object System.Drawing.Point(45,119);$welcome.Controls.Add($welcomeHint)
$shortcut=New-LargeCheck 'デスクトップにショートカットを作成する' $false
$shortcut.Size=New-Object System.Drawing.Size(288,32);$shortcut.Location=New-Object System.Drawing.Point(45,160);$welcome.Controls.Add($shortcut)
$welcomeImage=New-Object System.Windows.Forms.PictureBox
$welcomeImage.Location=New-Object System.Drawing.Point(352,58);$welcomeImage.Size=New-Object System.Drawing.Size(180,120);$welcomeImage.SizeMode='Zoom';$welcomeImage.BorderStyle='None';$welcomeImage.BackColor=[System.Drawing.Color]::White
if([System.IO.File]::Exists($welcomeImagePath)){$sourceImage=[System.Drawing.Image]::FromFile($welcomeImagePath);try{$welcomeImage.Image=New-Object System.Drawing.Bitmap($sourceImage)}finally{$sourceImage.Dispose()}}
$welcome.Controls.Add($welcomeImage)

$progress=New-Object System.Windows.Forms.Panel; $progress.Dock='Fill'; $progress.Visible=$false; $content.Controls.Add($progress)
$progressTitle=New-Object System.Windows.Forms.Label
$progressTitle.Text='インストールしています';$progressTitle.Font=New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold);$progressTitle.AutoSize=$true;$progressTitle.Location=New-Object System.Drawing.Point(42,39);$progress.Controls.Add($progressTitle)
$progressText=New-Object System.Windows.Forms.Label
$progressText.Text='対応ソフトを検出しています';$progressText.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$progressText.AutoSize=$true;$progressText.Location=New-Object System.Drawing.Point(45,84);$progress.Controls.Add($progressText)
$track=New-Object System.Windows.Forms.Panel
$track.Size=New-Object System.Drawing.Size(466,18);$track.Location=New-Object System.Drawing.Point(46,116);$track.BackColor=[System.Drawing.Color]::FromArgb(225,225,225);$track.BorderStyle='FixedSingle';$progress.Controls.Add($track)
$block=New-Object System.Windows.Forms.Panel
$block.Size=New-Object System.Drawing.Size(94,14);$block.Location=New-Object System.Drawing.Point(1,1);$block.BackColor=[System.Drawing.Color]::FromArgb(0,103,192);$track.Controls.Add($block)
$progressHint=New-Object System.Windows.Forms.Label
$progressHint.Text='しばらくお待ちください';$progressHint.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$progressHint.ForeColor=[System.Drawing.Color]::FromArgb(45,45,45);$progressHint.AutoSize=$true;$progressHint.Location=New-Object System.Drawing.Point(43,153);$progress.Controls.Add($progressHint)

$conflict=New-Object System.Windows.Forms.Panel; $conflict.Dock='Fill';$conflict.Visible=$false;$content.Controls.Add($conflict)
$conflictTitle=New-Object System.Windows.Forms.Label
$conflictTitle.Font=New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold);$conflictTitle.AutoSize=$true;$conflictTitle.Location=New-Object System.Drawing.Point(42,45);$conflict.Controls.Add($conflictTitle)
$conflictText=New-Object System.Windows.Forms.Label
$conflictText.Text="既存の入力設定が見つかりました`r`n既存の入力設定を置き換えますか？";$conflictText.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$conflictText.AutoSize=$true;$conflictText.Location=New-Object System.Drawing.Point(45,88);$conflict.Controls.Add($conflictText)
$conflictNote=New-Object System.Windows.Forms.Label
$conflictNote.Text="※仮想ゲームパッドの設定が欠落・破損している場合、コンバータは動作しません";$conflictNote.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$conflictNote.ForeColor=[System.Drawing.Color]::FromArgb(45,45,45);$conflictNote.AutoSize=$true;$conflictNote.Location=New-Object System.Drawing.Point(45,157);$conflict.Controls.Add($conflictNote)

$result=New-Object System.Windows.Forms.Panel;$result.Dock='Fill';$result.Visible=$false;$content.Controls.Add($result)
$resultTitle=New-Object System.Windows.Forms.Label
$resultTitle.Text='インストール結果';$resultTitle.Font=New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold);$resultTitle.AutoSize=$true;$resultTitle.Location=New-Object System.Drawing.Point(28,7);$result.Controls.Add($resultTitle)
$table=New-Object System.Windows.Forms.TableLayoutPanel
$table.Location=New-Object System.Drawing.Point(28,42);$table.Size=New-Object System.Drawing.Size(504,190);$table.ColumnCount=3;$table.RowCount=7;$table.CellBorderStyle='Single';$table.BackColor=[System.Drawing.Color]::White;$table.GrowStyle='FixedSize'
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,58)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,176)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,25)))
1..6|ForEach-Object{[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,26)))}
$result.Controls.Add($table)

function New-Cell([string]$Text,[string]$Align,[bool]$Header) {
    $l=New-Object System.Windows.Forms.Label;$l.Text=$Text;$l.Dock='Fill';$l.Margin=New-Object System.Windows.Forms.Padding(0);$l.Padding=New-Object System.Windows.Forms.Padding(7,0,5,0)
    $l.TextAlign=[System.Drawing.ContentAlignment]::$Align;$l.BackColor=if($Header){[System.Drawing.Color]::FromArgb(243,243,243)}else{[System.Drawing.Color]::White}
    $l.ForeColor=[System.Drawing.Color]::FromArgb(28,28,28);$l.Font=if($Header){New-Object System.Drawing.Font('Yu Gothic UI',9,[System.Drawing.FontStyle]::Bold)}else{New-Object System.Drawing.Font('Yu Gothic UI',9.5)}
    $l.Enabled=$true;$l.TabStop=$false;return $l
}
$table.Controls.Add((New-Cell '結果' 'MiddleCenter' $true),0,0)
$table.Controls.Add((New-Cell '対応ソフト' 'MiddleCenter' $true),1,0)
$table.Controls.Add((New-Cell '状態' 'MiddleCenter' $true),2,0)

function New-StatusSymbol([string]$Kind) {
    $p=New-Object System.Windows.Forms.Panel;$p.Dock='Fill';$p.Margin=New-Object System.Windows.Forms.Padding(0);$p.BackColor=[System.Drawing.Color]::White;$p.TabStop=$false;$p.Tag=$Kind
    $p.Add_Paint({param($sender,$e);$g=$e.Graphics;$g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias;$kind=[string]$sender.Tag
        if($kind -eq 'ok'){$pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(16,124,16),3);$g.DrawEllipse($pen,21,6,13,13);$pen.Dispose()}
        elseif($kind -eq 'warn'){$pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(202,80,16),3);$pts=[System.Drawing.Point[]]@((New-Object System.Drawing.Point(28,5)),(New-Object System.Drawing.Point(20,19)),(New-Object System.Drawing.Point(36,19)));$g.DrawPolygon($pen,$pts);$pen.Dispose()}
        elseif($kind -eq 'fail'){$pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(196,43,28),3);$g.DrawLine($pen,22,7,34,19);$g.DrawLine($pen,34,7,22,19);$pen.Dispose()}
        else{$pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(95,95,95),3);$g.DrawLine($pen,22,13,34,13);$pen.Dispose()}
    });return $p
}

$resultHint=New-Object System.Windows.Forms.Label
# Result hint intentionally omitted
$launch=New-LargeCheck 'DenGo Controller Converterを起動する' $true
$complete=New-Object System.Windows.Forms.Panel;$complete.Dock='Fill';$complete.Visible=$false;$content.Controls.Add($complete)
$completeText=New-Object System.Windows.Forms.Label
$completeText.Text="DenGo Controller Converter`r`nのインストールが完了しました";$completeText.Font=New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold);$completeText.AutoSize=$true;$completeText.Location=New-Object System.Drawing.Point(45,58);$complete.Controls.Add($completeText)
$launch.Location=New-Object System.Drawing.Point(45,146);$complete.Controls.Add($launch)

function Set-Page([string]$Name) {
    $welcome.Visible=$Name -eq 'welcome';$progress.Visible=$Name -eq 'progress';$conflict.Visible=$Name -eq 'conflict';$result.Visible=$Name -eq 'result';$complete.Visible=$Name -eq 'complete'
    $targetHeight=348;if($form.ClientSize.Height-ne$targetHeight){$form.ClientSize=New-Object System.Drawing.Size(560,$targetHeight)}
    # No footer panel visibility switching is required
    $next.Visible=$Name -eq 'welcome';$cancel.Visible=($Name -eq 'welcome' -or ($Name -eq 'progress' -and $script:operation -eq 'additional-search'));$cancel.Text=if($Name -eq 'progress' -and $script:operation -eq 'additional-search'){'検索を中止'}else{'キャンセル'};$cancel.Left=if($Name -eq 'progress' -and $script:operation -eq 'additional-search'){417}else{450};$search.Visible=$Name -eq 'result';$finish.Visible=($Name -eq 'result' -or $Name -eq 'complete');$finish.Text=if($Name -eq 'result'){'次へ'}else{'完了'};$useExisting.Visible=$Name -eq 'conflict';$replaceSetting.Visible=$Name -eq 'conflict';$applyChoice.Visible=$false
    $form.AcceptButton=if($Name -eq 'welcome'){$next}elseif($Name -eq 'result' -or $Name -eq 'complete'){$finish}elseif($Name -eq 'conflict'){$useExisting}else{$null}
    foreach($button in @($next,$cancel,$search,$finish,$useExisting,$replaceSetting)){if($button.Visible){$button.BringToFront()}}
}
function Has-Detected([string]$Platform,[string]$Mode) {return @($script:plan.Detected|Where-Object{$_.Platform -eq $Platform -and ($Mode -eq '' -or $_.Mode -eq $Mode)-and $_.State -eq 'Detected'}).Count-gt 0}
function Has-Conflict([string]$Platform){return @($script:plan.Plan|Where-Object{$_.Platform -eq $Platform -and $_.Action -eq 'PreserveUserModified'}).Count-gt 0}
function Has-DetectedBveWithoutBveEX {
    $hasBve = @($script:plan.Detected | Where-Object {
        [string]::Equals([string]$_.Platform,'BVE',[System.StringComparison]::Ordinal) -and
        [string]::Equals([string]$_.State,'Detected',[System.StringComparison]::Ordinal)
    }).Count -gt 0
    return $hasBve -and -not [bool]$script:plan.BveExCurrentInstalled
}
function Has-UnsupportedCurrentPCSX2 {
    return @($script:plan.Detected | Where-Object {
        [string]::Equals([string]$_.Platform,'PCSX2',[System.StringComparison]::Ordinal) -and
        [string]::Equals([string]$_.State,'Detected',[System.StringComparison]::Ordinal) -and
        ([string]$_.Mode).IndexOf('CurrentIntegrated',[System.StringComparison]::Ordinal) -ge 0
    }).Count -gt 0
}
function Show-DependencyWarningDialog {
    param([string]$MainInstruction,[string]$Content,[string]$DistributionUrl)
    $dialog=New-Object System.Windows.Forms.Form
    $dialog.Text='DenGo Controller Converter セットアップ'
    $dialog.StartPosition='CenterParent'
    $dialog.ClientSize=New-Object System.Drawing.Size(520,220)
    $dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false
    $dialog.MinimizeBox=$false
    $dialog.ShowInTaskbar=$false
    $dialog.Font=New-Object System.Drawing.Font('Yu Gothic UI',9)
    $dialog.BackColor=[System.Drawing.Color]::White
    $mainLabel=New-Object System.Windows.Forms.Label
    $mainLabel.Text=$MainInstruction
    $mainLabel.Font=New-Object System.Drawing.Font('Yu Gothic UI',12,[System.Drawing.FontStyle]::Bold)
    $mainLabel.AutoSize=$true
    $mainLabel.Location=New-Object System.Drawing.Point(28,27)
    $dialog.Controls.Add($mainLabel)
    $contentLabel=New-Object System.Windows.Forms.Label
    $contentLabel.Text=$Content
    $contentLabel.Font=New-Object System.Drawing.Font('Yu Gothic UI',10)
    $contentLabel.AutoSize=$true
    $contentLabel.Location=New-Object System.Drawing.Point(31,74)
    $dialog.Controls.Add($contentLabel)
    $openButton=New-Object System.Windows.Forms.Button
    $openButton.Text='配布ページを開く'
    $openButton.Size=New-Object System.Drawing.Size(150,34)
    $openButton.Location=New-Object System.Drawing.Point(188,163)
    $openButton.FlatStyle='Flat'
    $openButton.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(145,145,145)
    $openButton.BackColor=[System.Drawing.Color]::White
    $dialog.Controls.Add($openButton)
    $skipButton=New-Object System.Windows.Forms.Button
    $skipButton.Text='設定をスキップ'
    $skipButton.Size=New-Object System.Drawing.Size(150,34)
    $skipButton.Location=New-Object System.Drawing.Point(348,163)
    $skipButton.FlatStyle='Flat'
    $skipButton.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(0,103,192)
    $skipButton.BackColor=[System.Drawing.Color]::FromArgb(0,103,192)
    $skipButton.ForeColor=[System.Drawing.Color]::White
    $dialog.Controls.Add($skipButton)
    $dialog.AcceptButton=$skipButton
    $dialog.CancelButton=$skipButton
    $openButton.Add_Click({Start-Process -FilePath $DistributionUrl|Out-Null})
    $skipButton.Add_Click({$dialog.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$dialog.Close()})
    try{[void]$dialog.ShowDialog($form)}finally{$mainLabel.Font.Dispose();$contentLabel.Font.Dispose();$dialog.Dispose()}
}
function Show-UnsupportedPCSX2Dialog {
    Show-DependencyWarningDialog '検出したPCSX2には対応していません' "PCSX2 ver1.7以降の新しい入力設定方式が検出されました`r`n正式対応しているPCSX2はver1.6.0です" 'https://forums.pcsx2.net/Thread-PCSX2-1-6-0-Standalone-Installer'
}
function Show-MissingBveEXDialog {
    Show-DependencyWarningDialog 'BveEXが見つかりません' "BveEXを導入してからセットアップを再実行するか、設定をスキップしてください" 'https://bveex.okaoka-depot.com/download'
}
function Show-Conflict {if($script:conflictIndex -ge @($script:conflicts).Count){Start-SandboxApply;return};$name=[string]$script:conflicts[$script:conflictIndex];$conflictTitle.Text=$name+'の入力設定を確認';if([string]::Equals($name,'PCSX2',[System.StringComparison]::Ordinal)){$conflictText.Text="既存の入力設定が見つかりました`r`n既存の入力設定を置き換えますか？";$conflictNote.Text="※仮想ゲームパッドの設定が欠落・破損している場合、コンバータは動作しません"}else{$conflictText.Text="既存の入力設定ファイルが見つかりました`r`n標準設定で置き換えますか？";$conflictNote.Text="「はい」を選ぶと、現在の設定ファイルをバックアップしてから置き換えます"};Set-Page 'conflict'}
function Resolve-Conflict([string]$Choice){$name=[string]$script:conflicts[$script:conflictIndex];$script:decisions[$name]=$Choice;$script:conflictIndex++;Show-Conflict}
function Add-Row([int]$Row,[string]$Kind,[string]$Software,[string]$State){$table.Controls.Add((New-StatusSymbol $Kind),0,$Row);$table.Controls.Add((New-Cell $Software 'MiddleLeft' $false),1,$Row);$table.Controls.Add((New-Cell $State 'MiddleLeft' $false),2,$Row)}
function Get-ApplyResult([string]$Platform,[string]$Component){return @($script:plan.ApplyResults | Where-Object { $_.Platform -eq $Platform -and ([string]::IsNullOrWhiteSpace($Component) -or $_.Component -eq $Component) })}
function Show-Results {
    for($i=$table.Controls.Count-1;$i-ge 3;$i--){$table.Controls.RemoveAt($i)}
    $core=Get-ApplyResult 'Core' 'Application';if(@($core).Count-eq1){if(Has-Detected 'Steam' 'JRETS'){Add-Row 1 'ok' 'JRETS' '利用可能'}else{Add-Row 1 'none' 'JRETS' '見つかりませんでした'};if(Has-Detected 'Steam' 'RUNNINGTRAIN'){Add-Row 2 'ok' 'RUNNING TRAIN' '利用可能'}else{Add-Row 2 'none' 'RUNNING TRAIN' '見つかりませんでした'}}else{Add-Row 1 'fail' 'JRETS' '本体の導入に失敗しました';Add-Row 2 'fail' 'RUNNING TRAIN' '本体の導入に失敗しました'}
    foreach($entry in @(@('BVE5',3,'BVE Trainsim 5'),@('BVE6',4,'BVE Trainsim 6'))){$p=$entry[0];$r=[int]$entry[1];$n=$entry[2];$a=Get-ApplyResult $p 'Caller';if([bool]$script:bveIntegrationSkipped-and(Has-Detected 'BVE' $p)){Add-Row $r 'warn' $n '設定をスキップしました'}elseif(@($a).Count-eq1){Add-Row $r 'ok' $n '連携済み・利用可能'}elseif(Has-Detected 'BVE' $p){Add-Row $r 'fail' $n '連携機能の導入に失敗しました'}else{Add-Row $r 'none' $n '見つかりませんでした'}}
    $pcsx2Apply=Get-ApplyResult 'PCSX2' 'InputProfile';if(-not(Has-Detected 'PCSX2' '')){Add-Row 5 'none' 'PCSX2' '見つかりませんでした'}elseif(Has-UnsupportedCurrentPCSX2 -and @($pcsx2Apply).Count-eq0){Add-Row 5 'warn' 'PCSX2' 'ver1.7以降・非対応'}elseif(@($pcsx2Apply|Where-Object{$_.Action-eq'PreserveUserModified'}).Count-eq1){Add-Row 5 'warn' 'PCSX2' '既存の設定を使用します'}elseif(@($pcsx2Apply).Count-eq1){Add-Row 5 'ok' 'PCSX2' '設定済み・利用可能'}else{Add-Row 5 'fail' 'PCSX2' '入力設定の追加に失敗しました'}
    $rpcs3Apply=Get-ApplyResult 'RPCS3' 'InputProfile';if(-not(Has-Detected 'RPCS3' '')){Add-Row 6 'none' 'RPCS3' '見つかりませんでした'}elseif(@($rpcs3Apply|Where-Object{$_.Action-eq'PreserveUserModified'}).Count-eq1){Add-Row 6 'warn' 'RPCS3' '既存の設定を使用します'}elseif(@($rpcs3Apply).Count-eq1){Add-Row 6 'ok' 'RPCS3' '設定済み・利用可能'}else{Add-Row 6 'fail' 'RPCS3' '入力設定の追加に失敗しました'}
    Set-Page 'result'
}

function Show-SymbolPreview {
    for($i=$table.Controls.Count-1;$i-ge 3;$i--){$table.Controls.RemoveAt($i)}
    Add-Row 1 'ok' 'JRETS' '利用可能'
    Add-Row 2 'ok' 'RUNNING TRAIN' '利用可能'
    Add-Row 3 'ok' 'BVE Trainsim 5' '連携済み・利用可能'
    Add-Row 4 'fail' 'BVE Trainsim 6' '連携機能の導入に失敗しました'
    Add-Row 5 'warn' 'PCSX2' '既存の設定を使用します'
    Add-Row 6 'none' 'RPCS3' '見つかりませんでした'
    Set-Page 'result'
}
function Start-ConflictPreview([string[]]$Names) {
    $detected = @(
        [pscustomobject]@{Platform='BVE';Mode='BVE5';State='Detected'},
        [pscustomobject]@{Platform='BVE';Mode='BVE6';State='Detected'},
        [pscustomobject]@{Platform='PCSX2';Mode='CentralConfiguration';State='Detected'},
        [pscustomobject]@{Platform='RPCS3';Mode='ExecutableRelativeConfig';State='Detected'}
    )
    $previewPlan = New-Object System.Collections.ArrayList
    foreach($name in @($Names)){[void]$previewPlan.Add([pscustomobject]@{Platform=[string]$name;Action='PreserveUserModified'})}
    $script:plan=[pscustomobject]@{Detected=[object[]]@($detected);Plan=[object[]]@($previewPlan)}
    $script:conflicts=@($Names);$script:conflictIndex=0;$script:decisions=@{};Show-Conflict
}

function Start-UnsupportedPCSX2Preview {
    $script:plan=[pscustomobject]@{Detected=[object[]]@([pscustomobject]@{Platform='PCSX2';Mode='CentralConfiguration-CurrentIntegrated';State='Detected'});Plan=[object[]]@()}
    $script:unsupportedPCSX2Shown=$true
    Show-UnsupportedPCSX2Dialog
    Show-SymbolPreview
}
function Start-MissingBveEXPreview {
    $script:plan=[pscustomobject]@{Detected=[object[]]@([pscustomobject]@{Platform='BVE';Mode='BVE6';State='Detected'});Plan=[object[]]@();BveExCurrentInstalled=$false}
    $script:missingBveEXShown=$true
    $script:bveIntegrationSkipped=$true
    Show-MissingBveEXDialog
    Show-SymbolPreview
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

$timer=New-Object System.Windows.Forms.Timer;$timer.Interval=35
function Read-TextFileShared {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    for ($attempt=0; $attempt -lt 10; $attempt++) {
        $stream=$null
        $reader=$null
        try {
            $stream=New-Object System.IO.FileStream($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
            $reader=New-Object System.IO.StreamReader($stream,[System.Text.Encoding]::Default,$true)
            return $reader.ReadToEnd().Trim()
        } catch [System.IO.IOException] {
            if ($attempt -eq 9) { return '' }
            Start-Sleep -Milliseconds 50
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return ''
}
function Start-Detection([bool]$Additional){$script:operation=if($Additional){'additional-search'}else{'dryrun'};Set-Page 'progress';$progressText.Text=if($Additional){'追加の環境を検索しています'}else{'対応ソフトを検出しています'};$progressHint.Text=if($Additional){'検索には時間がかかる場合があります'}else{'しばらくお待ちください'};$script:barX=1;$script:barStep=7;$block.Left=1;if([System.IO.Directory]::Exists($script:runRoot)){Remove-Item -LiteralPath $script:runRoot -Recurse -Force};[System.IO.Directory]::CreateDirectory($script:outputRoot)|Out-Null;$script:planPath=Join-Path $script:outputRoot 'install-plan.json';$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-DryRun','-OutputRoot',$script:outputRoot);if($Additional){$args+='-AdditionalSearch'};$argumentLine=Join-NativeArguments $args;$detectStdout=Join-Path $script:outputRoot 'engine-stdout.txt';$detectStderr=Join-Path $script:outputRoot 'engine-stderr.txt';$script:process=Start-Process powershell.exe -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $detectStdout -RedirectStandardError $detectStderr;$timer.Start()}
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
function Start-SandboxApply {
    if(-not(Confirm-RunningProductsClosed)){if(Confirm-SetupCancel){Set-RunCancelled;$script:allowClose=$true;$form.Close()}else{Set-Page 'welcome'};return}
    Set-Page 'progress'
    $progressText.Text='インストールしています'
    $progressHint.Text='ファイルと設定を適用しています'
    $applyOutput=Join-Path $script:runRoot 'apply'
    [System.IO.Directory]::CreateDirectory($applyOutput)|Out-Null
    $script:planPath=Join-Path $applyOutput 'install-plan.json'
    $script:operation='real-apply'
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Apply','-RealSystem','-ConfirmRealApply','INSTALL','-OutputRoot',$applyOutput)
    if([bool]$shortcut.Tag.Checked){$args+='-CreateDesktopShortcut'}
    if([bool]$script:bveIntegrationSkipped){$args+='-SkipBveIntegration'}
    if($script:decisions.ContainsKey('PCSX2')-and$script:decisions['PCSX2']-eq'replace'){$args+='-ReplaceModifiedPCSX2Profile'}
    if($script:decisions.ContainsKey('RPCS3')-and$script:decisions['RPCS3']-eq'replace'){$args+='-ReplaceModifiedRPCS3Profile'}
    [System.IO.Directory]::CreateDirectory($applyOutput) | Out-Null
    $applyStdout = Join-Path $applyOutput 'engine-stdout.txt'
    $applyStderr = Join-Path $applyOutput 'engine-stderr.txt'
    $argumentLine=Join-NativeArguments $args
    $script:applyStartedAt=[System.DateTimeOffset]::Now
    $script:engineCompleted=$false;$script:stateCommitted=$false
    $script:applyRunning=$true
    try{
        $script:process=Start-Process powershell.exe -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $applyStdout -RedirectStandardError $applyStderr
        $script:engineStarted=$true
    }catch{
        $script:applyRunning=$false;$script:process=$null;$script:operation='idle'
        Set-RunFailed 'EngineLaunchFailed'
        Show-GuiError ([regex]::Unescape('\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002'))
        Set-Page 'welcome'
        return
    }
    $timer.Start()
}
# --- I1 result contract: Completed (exit 0) / Cancelled (exit 2) / Failed (exit 1) ---
function Show-GuiError([string]$Text) {
    [void][System.Windows.Forms.MessageBox]::Show($Text,[regex]::Unescape('DenGo \u30BB\u30C3\u30C8\u30A2\u30C3\u30D7'),[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
}
function Set-RunFailed([string]$Reason) {
    $script:engineCompleted=$false;$script:stateCommitted=$false
    $script:finalResult='Failed';$script:finalReason=$Reason
}
function Set-RunFailure([bool]$IsApply,[string]$Suffix) {
    if($IsApply){Set-RunFailed ('Engine'+$Suffix);return}
    if(-not [string]::Equals($script:finalResult,'Completed',[System.StringComparison]::Ordinal)){Set-RunFailed ('DryRun'+$Suffix)}
}
function Set-RunCompleted {
    $script:finalResult='Completed';$script:finalReason='Completed'
    $script:engineCompleted=$true;$script:stateCommitted=$true
}
# Cancelled is reachable only through an explicit, confirmed pre-apply cancel; anything else stays Failed/NotCompleted.
function Set-RunCancelled {
    if([string]::Equals($script:finalResult,'Failed',[System.StringComparison]::Ordinal) -and [string]::Equals($script:finalReason,'NotCompleted',[System.StringComparison]::Ordinal) -and -not $script:engineStarted){
        $script:finalResult='Cancelled';$script:finalReason='UserCancelled'
    }
}
function Invoke-UnhandledGuiException([System.Exception]$Exception) {
    if(-not [string]::Equals($script:finalResult,'Completed',[System.StringComparison]::Ordinal) -and [string]::Equals($script:finalReason,'NotCompleted',[System.StringComparison]::Ordinal)){Set-RunFailed 'UnhandledException'}
    $detail=''
    if($null -ne $Exception){$detail=[System.Environment]::NewLine+[System.Environment]::NewLine+[string]$Exception.Message}
    Show-GuiError ([regex]::Unescape('\u4E88\u671F\u3057\u306A\u3044\u30A8\u30E9\u30FC\u304C\u767A\u751F\u3057\u307E\u3057\u305F\u3002')+$detail)
}
function Test-ApplyCommitted([object]$Plan) {
    try {
        if(-not [bool]$Plan.Succeeded){return $false}
        if(-not [bool]$Plan.Apply -or -not [bool]$Plan.RealSystem){return $false}
        $core=@($Plan.ApplyResults|Where-Object{$_.Platform -eq 'Core' -and $_.Component -eq 'Application'})
        if($core.Count -ne 1){return $false}
        $stateRoot=Join-Path $env:LOCALAPPDATA 'DenGo Controller Converter\InstallerState'
        if([System.IO.File]::Exists((Join-Path $stateRoot 'installing.json'))){return $false}
        $statePath=Join-Path $stateRoot 'installed-state.json'
        if(-not [System.IO.File]::Exists($statePath)){return $false}
        $state=[System.IO.File]::ReadAllText($statePath,[System.Text.Encoding]::UTF8)|ConvertFrom-Json
        if([int]$state.SchemaVersion -ne 1){return $false}
        $installedAt=[System.DateTimeOffset]::Parse([string]$state.InstalledAt,[System.Globalization.CultureInfo]::InvariantCulture)
        return ($installedAt -ge $script:applyStartedAt)
    } catch { return $false }
}
function Write-RunResult([string]$Result,[string]$Reason,[int]$ExitCode) {
    if([string]::IsNullOrWhiteSpace($ResultPath)){return $true}
    $temporary=$null
    try {
        if([string]::IsNullOrWhiteSpace($RunId)){return $false}
        $final=[System.IO.Path]::GetFullPath($ResultPath)
        $directory=[System.IO.Path]::GetDirectoryName($final)
        if(-not [System.IO.Directory]::Exists($directory)){return $false}
        if([System.IO.File]::Exists($final)){return $false}
        $temporary=$final+'.tmp'
        $document=[ordered]@{schemaVersion=1;operation='Install';runId=$RunId;result=$Result;reason=$Reason;exitCode=$ExitCode;engineStarted=[bool]$script:engineStarted;engineCompleted=[bool]$script:engineCompleted;stateCommitted=[bool]$script:stateCommitted;writtenAt=[System.DateTimeOffset]::Now.ToString('o')}
        $bytes=(New-Object System.Text.UTF8Encoding($false)).GetBytes(($document|ConvertTo-Json))
        $stream=New-Object System.IO.FileStream($temporary,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        $check=[System.IO.File]::ReadAllText($temporary,[System.Text.Encoding]::UTF8)|ConvertFrom-Json
        if([int]$check.schemaVersion -ne 1 -or -not [string]::Equals([string]$check.runId,$RunId,[System.StringComparison]::Ordinal) -or -not [string]::Equals([string]$check.result,$Result,[System.StringComparison]::Ordinal) -or [int]$check.exitCode -ne $ExitCode){throw 'Result verification failed.'}
        [System.IO.File]::Move($temporary,$final)
        return $true
    } catch {
        try{if($null -ne $temporary -and [System.IO.File]::Exists($temporary)){[System.IO.File]::Delete($temporary)}}catch{}
        return $false
    }
}
function Complete-Run {
    $result=$script:finalResult;$reason=$script:finalReason
    $invariantOk=$true
    if([string]::Equals($result,'Completed',[System.StringComparison]::Ordinal)){$invariantOk=[bool]($script:engineStarted -and $script:engineCompleted -and $script:stateCommitted)}
    elseif([string]::Equals($result,'Cancelled',[System.StringComparison]::Ordinal)){$invariantOk=-not [bool]($script:engineStarted -or $script:engineCompleted -or $script:stateCommitted)}
    if(-not $invariantOk){$result='Failed';$reason='InvariantViolation'}
    $exitCode=1
    if([string]::Equals($result,'Completed',[System.StringComparison]::Ordinal)){$exitCode=0}
    elseif([string]::Equals($result,'Cancelled',[System.StringComparison]::Ordinal)){$exitCode=2}
    if(-not (Write-RunResult $result $reason $exitCode)){return 1}
    return $exitCode
}
function Stop-CurrentProcess {
    if($script:applyRunning){return}
    if($null-ne$script:process-and-not$script:process.HasExited){
        try{$script:process.Kill();$script:process.WaitForExit()}catch{}
    }
    if($null-ne$script:process){try{$script:process.Dispose()}catch{};$script:process=$null}
    $timer.Stop()
}
function Confirm-SetupCancel {
    $answer=[System.Windows.Forms.MessageBox]::Show('セットアップを中止しますか？','DenGo Controller Converter セットアップ',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}
$timer.Add_Tick({$limit=$track.ClientSize.Width-$block.Width-2;$script:barX+=$script:barStep;if($script:barX-ge$limit){$script:barX=$limit;$script:barStep=-7};if($script:barX-le1){$script:barX=1;$script:barStep=7};$block.Left=$script:barX;if($null-eq$script:process-or-not$script:process.HasExited){return};$timer.Stop();$code=$script:process.ExitCode;$script:process.Dispose();$script:process=$null;$wasApply=($script:operation-eq'real-apply');$script:applyRunning=$false;if(-not[System.IO.File]::Exists($script:planPath)){$failureRoot=[System.IO.Path]::GetDirectoryName($script:planPath);$stderrPath=Join-Path $failureRoot 'engine-stderr.txt';$stdoutPath=Join-Path $failureRoot 'engine-stdout.txt';$detail='';if([System.IO.File]::Exists($stderrPath)){$detail=Read-TextFileShared $stderrPath};if([string]::IsNullOrWhiteSpace($detail)-and[System.IO.File]::Exists($stdoutPath)){$detail=Read-TextFileShared $stdoutPath};$message='処理結果を確認できませんでした。 終了コード: '+$code;if(-not[string]::IsNullOrWhiteSpace($detail)){$message+=[System.Environment]::NewLine+[System.Environment]::NewLine+$detail};[System.Windows.Forms.MessageBox]::Show($message,'DenGo セットアップ')|Out-Null;Set-RunFailure $wasApply 'NoResult';Set-Page 'welcome';return};try{$script:plan=[System.IO.File]::ReadAllText($script:planPath,[System.Text.Encoding]::UTF8)|ConvertFrom-Json}catch{Set-RunFailure $wasApply 'ResultCorrupt';Show-GuiError ([regex]::Unescape('\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002'));Set-Page 'welcome';return};if(-not[bool]$script:plan.Succeeded){$detail=[string]$script:plan.ErrorMessage;if([string]::IsNullOrWhiteSpace($detail)){$detail='処理に失敗しました'};[System.Windows.Forms.MessageBox]::Show($detail,'DenGo セットアップ')|Out-Null;Set-RunFailure $wasApply 'Failed';Set-Page 'welcome';return};if($script:operation-eq'real-apply'){$script:operation='idle';if(-not(Test-ApplyCommitted $script:plan)){Set-RunFailure $true 'StateNotCommitted';Show-GuiError ([regex]::Unescape('\u30A4\u30F3\u30B9\u30C8\u30FC\u30EB\u7D50\u679C\u3092\u78BA\u8A8D\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002'));Set-Page 'welcome';return};Set-RunCompleted;$script:lastResultAvailable=$true;Show-Results;return};if(-not$script:missingBveEXShown-and(Has-DetectedBveWithoutBveEX)){$script:missingBveEXShown=$true;$script:bveIntegrationSkipped=$true;Show-MissingBveEXDialog};if(-not$script:unsupportedPCSX2Shown-and(Has-UnsupportedCurrentPCSX2)){$script:unsupportedPCSX2Shown=$true;Show-UnsupportedPCSX2Dialog};$script:conflicts=@();foreach($n in @('PCSX2','RPCS3')){if(Has-Conflict $n){$script:conflicts+=$n}};$script:conflictIndex=0;$script:decisions=@{};if(@($script:conflicts).Count-eq0){Start-SandboxApply}else{Show-Conflict}})
$next.Add_Click({if(-not(Confirm-RunningProductsClosed)){if(Confirm-SetupCancel){Set-RunCancelled;$script:allowClose=$true;$form.Close()};return};Start-Detection $false})
$search.Add_Click({Start-Detection $true})
$cancel.Add_Click({
    if($script:applyRunning){return}
    if($script:operation -eq 'additional-search'){
        Stop-CurrentProcess
        $script:operation='idle'
        if($script:lastResultAvailable){Set-Page 'result'}else{Set-Page 'welcome'}
    } elseif(Confirm-SetupCancel){
        Set-RunCancelled
        Stop-CurrentProcess
        $script:allowClose=$true
        $form.Close()
    }
})
$finish.Add_Click({
    if($result.Visible){Set-Page 'complete'}
    elseif($complete.Visible){
        if([bool]$launch.Tag.Checked){
            $application=Join-Path $env:LOCALAPPDATA 'Programs\DenGo Controller Converter\DenGoControllerConverter.exe'
            try{
                if(-not [System.IO.File]::Exists($application)){throw ('Installed application was not found: ' + $application)}
                Start-Process -FilePath $application -WorkingDirectory ([System.IO.Path]::GetDirectoryName($application)) | Out-Null
            } catch {
                [System.Windows.Forms.MessageBox]::Show(('DenGo Controller Converterを起動できませんでした。' + [System.Environment]::NewLine + $_.Exception.Message),'DenGo セットアップ',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
                return
            }
        }
        $script:allowClose=$true
        $form.Close()
    }
})
$useExisting.Add_Click({Resolve-Conflict 'keep'});$replaceSetting.Add_Click({Resolve-Conflict 'replace'})
$form.Add_FormClosing({
    if($script:applyRunning){
        if($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing){$_.Cancel=$true}
        else{Set-RunFailed 'GuiClosedDuringApply'}
        return
    }
    if($script:allowClose){return}
    if($_.CloseReason -ne [System.Windows.Forms.CloseReason]::UserClosing){
        Stop-CurrentProcess
        $script:allowClose=$true
        return
    }
    if([string]::Equals($script:finalResult,'Completed',[System.StringComparison]::Ordinal)){
        Stop-CurrentProcess
        $script:allowClose=$true
        return
    }
    if(Confirm-SetupCancel){
        Set-RunCancelled
        Stop-CurrentProcess
        $script:allowClose=$true
        $_.Cancel=$false
    } else {
        $_.Cancel=$true
    }
})
$form.Add_FormClosed({try{if($null-ne$welcomeImage.Image){$welcomeImage.Image.Dispose();$welcomeImage.Image=$null}}catch{}})
if($Preview -eq 'Symbols'){Show-SymbolPreview}
elseif($Preview -eq 'PCSX2Conflict'){Start-ConflictPreview @('PCSX2')}
elseif($Preview -eq 'RPCS3Conflict'){Start-ConflictPreview @('RPCS3')}
elseif($Preview -eq 'BothConflicts'){Start-ConflictPreview @('PCSX2','RPCS3')}
elseif($Preview -eq 'PCSX2Unsupported'){Start-UnsupportedPCSX2Preview}
elseif($Preview -eq 'BveEXMissing'){Start-MissingBveEXPreview}
else{Set-Page 'welcome'}
[System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{param($sender,$e);Invoke-UnhandledGuiException $e.Exception})
try{[void]$form.ShowDialog()}catch{Set-RunFailed 'GuiException'}
exit ([int](Complete-Run))
