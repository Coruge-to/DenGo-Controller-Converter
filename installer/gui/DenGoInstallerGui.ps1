param(
    [ValidateSet('Normal','Symbols','PCSX2Conflict','RPCS3Conflict','BothConflicts','previewPlan','利用可能','welcomeImagePath','PictureBox','標準設定で置き換えますか？','Add_FormClosed','New-Object System.Drawing.Bitmap')]
    [string]$Preview = 'Normal'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)) '..'))
$engine = Join-Path $root 'scripts\Invoke-DenGoInstaller.ps1'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $root '..'))
$welcomeImagePath = Join-Path $repoRoot 'DenGo-Controller-Converter2.png'
$planPath = Join-Path $env:TEMP 'DenGoInstallerPreview\install-plan.json'
$script:process = $null
$script:plan = $null
$script:conflicts = @()
$script:conflictIndex = 0
$script:decisions = @{}
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
$conflictText.Text="既存の入力設定ファイルが見つかりました`r`n標準設定で置き換えますか？";$conflictText.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$conflictText.AutoSize=$true;$conflictText.Location=New-Object System.Drawing.Point(45,88);$conflict.Controls.Add($conflictText)
$conflictNote=New-Object System.Windows.Forms.Label
$conflictNote.Text="「はい」を選ぶと、現在の設定ファイルを`r`nバックアップしてから置き換えます";$conflictNote.Font=New-Object System.Drawing.Font('Yu Gothic UI',10);$conflictNote.ForeColor=[System.Drawing.Color]::FromArgb(45,45,45);$conflictNote.AutoSize=$true;$conflictNote.Location=New-Object System.Drawing.Point(45,157);$conflict.Controls.Add($conflictNote)

$result=New-Object System.Windows.Forms.Panel;$result.Dock='Fill';$result.Visible=$false;$content.Controls.Add($result)
$resultTitle=New-Object System.Windows.Forms.Label
$resultTitle.Text='インストール結果';$resultTitle.Font=New-Object System.Drawing.Font('Yu Gothic UI',14,[System.Drawing.FontStyle]::Bold);$resultTitle.AutoSize=$true;$resultTitle.Location=New-Object System.Drawing.Point(28,7);$result.Controls.Add($resultTitle)
$table=New-Object System.Windows.Forms.TableLayoutPanel
$table.Location=New-Object System.Drawing.Point(28,42);$table.Size=New-Object System.Drawing.Size(504,190);$table.ColumnCount=3;$table.RowCount=7;$table.CellBorderStyle='Single';$table.BackColor=[System.Drawing.Color]::White;$table.GrowStyle='FixedSize'
$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,58)))
$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,176)))
$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100)))
$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,25)))
1..6|ForEach-Object{$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,26)))}
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
    $next.Visible=$Name -eq 'welcome';$cancel.Visible=$Name -eq 'welcome';$search.Visible=$Name -eq 'result';$finish.Visible=($Name -eq 'result' -or $Name -eq 'complete');$finish.Text=if($Name -eq 'result'){'次へ'}else{'完了'};$useExisting.Visible=$Name -eq 'conflict';$replaceSetting.Visible=$Name -eq 'conflict';$applyChoice.Visible=$false
    $form.AcceptButton=if($Name -eq 'welcome'){$next}elseif($Name -eq 'result' -or $Name -eq 'complete'){$finish}elseif($Name -eq 'conflict'){$useExisting}else{$null}
    foreach($button in @($next,$cancel,$search,$finish,$useExisting,$replaceSetting)){if($button.Visible){$button.BringToFront()}}
}
function Has-Detected([string]$Platform,[string]$Mode) {return @($script:plan.Detected|Where-Object{$_.Platform -eq $Platform -and ($Mode -eq '' -or $_.Mode -eq $Mode)-and $_.State -eq 'Detected'}).Count-gt 0}
function Has-Conflict([string]$Platform){return @($script:plan.Plan|Where-Object{$_.Platform -eq $Platform-and $_.Action -eq 'PreserveUserModified'}).Count-gt 0}
function Show-Conflict {if($script:conflictIndex -ge @($script:conflicts).Count){Show-Results;return};$name=[string]$script:conflicts[$script:conflictIndex];$conflictTitle.Text=$name+'の入力設定を確認';Set-Page 'conflict'}
function Resolve-Conflict([string]$Choice){$name=[string]$script:conflicts[$script:conflictIndex];$script:decisions[$name]=$Choice;$script:conflictIndex++;Show-Conflict}
function Add-Row([int]$Row,[string]$Kind,[string]$Software,[string]$State){$table.Controls.Add((New-StatusSymbol $Kind),0,$Row);$table.Controls.Add((New-Cell $Software 'MiddleLeft' $false),1,$Row);$table.Controls.Add((New-Cell $State 'MiddleLeft' $false),2,$Row)}
function Show-Results {
    for($i=$table.Controls.Count-1;$i-ge 3;$i--){$table.Controls.RemoveAt($i)}
    Add-Row 1 'ok' 'JRETS' '利用可能';Add-Row 2 'ok' 'RUNNING TRAIN' '利用可能'
    if(Has-Detected 'BVE' 'BVE5'){Add-Row 3 'ok' 'BVE Trainsim 5' '連携済み・利用可能'}else{Add-Row 3 'none' 'BVE Trainsim 5' '見つかりませんでした'}
    if(Has-Detected 'BVE' 'BVE6'){Add-Row 4 'ok' 'BVE Trainsim 6' '連携済み・利用可能'}else{Add-Row 4 'none' 'BVE Trainsim 6' '見つかりませんでした'}
    foreach($entry in @(@('PCSX2',5),@('RPCS3',6))){$n=$entry[0];$r=[int]$entry[1];if(-not(Has-Detected $n '')){Add-Row $r 'none' $n '見つかりませんでした'}elseif($script:decisions.ContainsKey($n)-and$script:decisions[$n]-eq'keep'){Add-Row $r 'warn' $n '既存の設定を使用します'}elseif($script:decisions.ContainsKey($n)-and$script:decisions[$n]-eq'replace'){Add-Row $r 'ok' $n '入力設定を追加しました'}else{Add-Row $r 'ok' $n '設定済み・利用可能'}}
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

$timer=New-Object System.Windows.Forms.Timer;$timer.Interval=35
function Start-Detection([bool]$Additional){Set-Page 'progress';$progressText.Text=if($Additional){'追加の環境を検索しています'}else{'対応ソフトを検出しています'};$progressHint.Text=if($Additional){'検索には時間がかかる場合があります'}else{'しばらくお待ちください'};$script:barX=1;$script:barStep=7;$block.Left=1;$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-DryRun');if($Additional){$args+='-AdditionalSearch'};$script:process=Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden;$timer.Start()}
$timer.Add_Tick({$limit=$track.ClientSize.Width-$block.Width-2;$script:barX+=$script:barStep;if($script:barX-ge$limit){$script:barX=$limit;$script:barStep=-7};if($script:barX-le1){$script:barX=1;$script:barStep=7};$block.Left=$script:barX;if($null-eq$script:process-or-not$script:process.HasExited){return};$timer.Stop();$code=$script:process.ExitCode;$script:process.Dispose();$script:process=$null;if($code-ne0-or-not[System.IO.File]::Exists($planPath)){[System.Windows.Forms.MessageBox]::Show('処理に失敗しました','DenGo セットアップ')|Out-Null;Set-Page 'welcome';return};$script:plan=[System.IO.File]::ReadAllText($planPath,[System.Text.Encoding]::UTF8)|ConvertFrom-Json;$script:conflicts=@();foreach($n in @('PCSX2','RPCS3')){if(Has-Conflict $n){$script:conflicts+=$n}};$script:conflictIndex=0;$script:decisions=@{};Show-Conflict})
$next.Add_Click({Start-Detection $false});$search.Add_Click({Start-Detection $true});$cancel.Add_Click({$form.Close()});$finish.Add_Click({if($result.Visible){Set-Page 'complete'}elseif($complete.Visible){$form.Close()}});$useExisting.Add_Click({Resolve-Conflict 'keep'});$replaceSetting.Add_Click({Resolve-Conflict 'replace'})
$form.Add_FormClosing({if($null-ne$script:process-and-not$script:process.HasExited){$_.Cancel=$true}})
$form.Add_FormClosed({try{if($null-ne$welcomeImage.Image){$welcomeImage.Image.Dispose();$welcomeImage.Image=$null}}catch{}})
if($Preview -eq 'Symbols'){Show-SymbolPreview}
elseif($Preview -eq 'PCSX2Conflict'){Start-ConflictPreview @('PCSX2')}
elseif($Preview -eq 'RPCS3Conflict'){Start-ConflictPreview @('RPCS3')}
elseif($Preview -eq 'BothConflicts'){Start-ConflictPreview @('PCSX2','RPCS3')}
else{Set-Page 'welcome'}
[void]$form.ShowDialog()
