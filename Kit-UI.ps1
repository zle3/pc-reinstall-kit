<#
    Kit-UI.ps1 - application window for PC Reinstall Kit.
    Dot-sourced by Backup-OldPC.ps1 and Setup-NewPC.ps1.

    Host side   : Start-KitApp shows the window and runs the script again in a background
                  runspace ("worker") so the window stays responsive during long copies.
    Worker side : Send-KitMessage / Request-KitAnswer talk to the window through a
                  synchronized queue. Dialogs are always built on the window's own thread.

    Message types (worker -> window):
      log      Text, Level (info|ok|warn|fail|todo|head|sub)
      steps    Titles[]                       builds the step list
      step     Index, State (pending|running|done|warn|failed)
      status   Text                           big title above the log
      subtitle Text                           line under the app name
      progress Text, Value, Max, Indeterminate, Done
      paths    Folder, Report, Apps, Checklist
      busy     Value (bool)
      done     Text
      ask      Id, Kind, ...                  dialog; answer goes to Answers[Id]
#>

# ---------------------------------------------------------------------------
# Worker side
# ---------------------------------------------------------------------------
function Send-KitMessage([hashtable]$Msg) {
    if ($Script:KitSync) { $Script:KitSync.Queue.Enqueue($Msg) }
}

function Request-KitAnswer([hashtable]$Msg) {
    $id = [guid]::NewGuid().ToString()
    $Msg.Id = $id
    $Msg.T = 'ask'
    Send-KitMessage $Msg
    $ans = $null
    while (-not $Script:KitSync.Answers.TryRemove($id, [ref]$ans)) {
        if ($Script:KitSync.Closing) { throw 'The window was closed.' }
        Start-Sleep -Milliseconds 80
    }
    return $ans
}

function Show-KitYesNo([string]$Text, [bool]$Default = $true) { return [bool](Request-KitAnswer @{ Kind = 'yesno'; Text = $Text; Default = $Default }) }
function Show-KitInfo([string]$Text, [string]$Button = 'OK') { [void](Request-KitAnswer @{ Kind = 'info'; Text = $Text; Button = $Button }) }
function Show-KitInput([string]$Text, [string]$Default = '') { return "$(Request-KitAnswer @{ Kind = 'input'; Text = $Text; Default = $Default })" }
function Show-KitFolder([string]$Text) { return "$(Request-KitAnswer @{ Kind = 'folder'; Text = $Text })" }
function Show-KitChoice([string]$Text, [string[]]$Options, [int]$Default = 0) {
    $r = Request-KitAnswer @{ Kind = 'choice'; Text = $Text; Options = $Options; Default = $Default }
    if ($null -eq $r) { return -1 }
    return [int]$r
}
function Show-KitSelect {
    # Rows: array of @{ Main; Sub }. Returns the indexes of the ticked rows (empty = skipped).
    param([string]$Title, [string]$Text, [object[]]$Rows, [bool[]]$Checked, [switch]$Single, [string]$OkText = 'Continue', [string]$SkipText = 'Skip')
    if (-not $Rows) { return @() }
    if (-not $Checked) { $Checked = @($Rows | ForEach-Object { $false }) }
    $r = Request-KitAnswer @{ Kind = 'select'; Title = $Title; Text = $Text; Rows = @($Rows); Checked = @($Checked); Single = [bool]$Single; OkText = $OkText; SkipText = $SkipText }
    return @($r | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
}
function Show-KitChecklist([object[]]$Items) {
    # Items: array of @{ Section; Text; Link; Done }. Returns indexes ticked when closed.
    $r = Request-KitAnswer @{ Kind = 'checklist'; Items = @($Items) }
    return @($r | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
}

# ---------------------------------------------------------------------------
# Host side
# ---------------------------------------------------------------------------
function Test-KitGuiAvailable {
    if ($env:PCKIT_CONSOLE -eq '1') { return $false }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms -ErrorAction Stop
        Initialize-KitNative
        return $true
    } catch { return $false }
}

function Initialize-KitNative {
    if ('PCKit.Win' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PCKit {
public static class Win {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
}
}
'@
}

function Set-KitConsoleVisible([bool]$Visible) {
    try {
        Initialize-KitNative
        $h = [PCKit.Win]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][PCKit.Win]::ShowWindow($h, $(if ($Visible) { 5 } else { 0 })) }
    } catch { }
}

function Get-KitPalette {
    # Mauve / slate palette. Follows the Windows app theme (dark unless Windows is set to light).
    $light = $false
    try { $light = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1) } catch { }
    if ($light) {
        return @{ Dark = $false; Bg = '#FFFFFF'; Side = '#F9F9FB'; Card = '#F9F9FB'; Card2 = '#F8F4F6'; Fg = '#2D2D3F'; Muted = '#606086'; Line = '#CDCDDB'
                  Accent = '#84596F'; Btn = '#84596F'; BtnHover = '#6C495B'; BtnFg = '#FFFFFF'; SecHover = '#F8F4F6'; Chip = '#D9C6D0'; ChipFg = '#533846'
                  Warn = '#BE123C'; Bad = '#E11D48'; Ok = '#6C495B'; Sel = '#F8F4F6' }
    }
    return @{ Dark = $true; Bg = '#3E3E56'; Side = '#35354A'; Card = '#4F4F6E'; Card2 = '#45455F'; Fg = '#FFFFFF'; Muted = '#CDCDDB'; Line = '#606086'
              Accent = '#D9C6D0'; Btn = '#84596F'; BtnHover = '#9B6B84'; BtnFg = '#FFFFFF'; SecHover = '#4F4F6E'; Chip = '#606086'; ChipFg = '#F8F4F6'
              Warn = '#FDA4AF'; Bad = '#FB7185'; Ok = '#D9C6D0'; Sel = '#4F4F6E' }
}

function Get-KitBrush([string]$Hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Get-KitButtonStyleXaml([string]$Key, [string]$Bg, [string]$Fg, [string]$Hover, [string]$Border, [string]$Focus) {
    $keyAttr = if ($Key) { "x:Key=""$Key"" " } else { '' }
    return @"
<Style ${keyAttr}TargetType="Button">
  <Setter Property="Foreground" Value="$Fg"/><Setter Property="Background" Value="$Bg"/>
  <Setter Property="BorderBrush" Value="$Border"/><Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Padding" Value="18,8"/><Setter Property="Margin" Value="8,0,0,0"/>
  <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template"><Setter.Value>
    <ControlTemplate TargetType="Button">
      <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="18" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="$Hover"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="$Focus"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.97" ScaleY="0.97"/></Setter.Value></Setter></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Setter.Value></Setter>
</Style>
"@
}

function Get-KitResourcesXaml($p) {
    $primary = Get-KitButtonStyleXaml '' $p.Btn $p.BtnFg $p.BtnHover $p.Btn $p.Accent
    $secondary = Get-KitButtonStyleXaml 'Sec' 'Transparent' $p.Fg $p.SecHover $p.Line $p.Accent
    return @"
<Window.Resources>
$primary
$secondary
<Style TargetType="ProgressBar">
  <Setter Property="Height" Value="8"/><Setter Property="Foreground" Value="$($p.Btn)"/><Setter Property="Background" Value="$($p.Line)"/>
  <Setter Property="Template"><Setter.Value>
    <ControlTemplate TargetType="ProgressBar">
      <Border CornerRadius="4" Background="{TemplateBinding Background}" ClipToBounds="True">
        <Grid>
          <Border x:Name="PART_Track"/>
          <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="4" Background="{TemplateBinding Foreground}"/>
          <Border x:Name="Ind" CornerRadius="4" Background="{TemplateBinding Foreground}" Opacity="0.55" Visibility="Collapsed"/>
        </Grid>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsIndeterminate" Value="True"><Setter TargetName="Ind" Property="Visibility" Value="Visible"/><Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Setter.Value></Setter>
</Style>
<Style TargetType="TextBox">
  <Setter Property="Background" Value="$($p.Card)"/><Setter Property="Foreground" Value="$($p.Fg)"/><Setter Property="BorderBrush" Value="$($p.Line)"/>
  <Setter Property="CaretBrush" Value="$($p.Fg)"/><Setter Property="Padding" Value="10,7"/><Setter Property="BorderThickness" Value="1"/>
</Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="$($p.Fg)"/><Setter Property="VerticalContentAlignment" Value="Top"/><Setter Property="Cursor" Value="Hand"/></Style>
<Style TargetType="RadioButton"><Setter Property="Foreground" Value="$($p.Fg)"/><Setter Property="VerticalContentAlignment" Value="Top"/><Setter Property="Cursor" Value="Hand"/></Style>
</Window.Resources>
"@
}

function New-KitIcon {
    # Small rounded app icon drawn in code (no image files needed).
    try {
        $p = $Script:Kit.Palette
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRoundedRectangle((Get-KitBrush $p.Btn), $null, (New-Object System.Windows.Rect(0, 0, 64, 64)), 14, 14)
        $ft = New-Object System.Windows.Media.FormattedText('PC', [Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight,
            (New-Object System.Windows.Media.Typeface('Segoe UI Semibold')), 28, [System.Windows.Media.Brushes]::White)
        $x = (64 - $ft.Width) / 2
        $y = (64 - $ft.Height) / 2
        $dc.DrawText($ft, [System.Windows.Point]::new($x, $y))
        $dc.Close()
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($dv)
        return $bmp
    } catch { return $null }
}

function Set-KitDarkTitleBar($Window) {
    if (-not $Script:Kit.Palette.Dark) { return }
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).EnsureHandle()
        $v = 1
        if ([PCKit.Win]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) -ne 0) { [void][PCKit.Win]::DwmSetWindowAttribute($h, 19, [ref]$v, 4) }
    } catch { }
}

function Save-KitSnapshot($Window, [string]$Name) {
    # Test hook: PCKIT_SNAPSHOT=<folder> saves a PNG of each window.
    if (-not $env:PCKIT_SNAPSHOT) { return }
    try {
        $Window.UpdateLayout()
        $w = [int][math]::Max(1, $Window.ActualWidth); $h = [int][math]::Max(1, $Window.ActualHeight)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($Window)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create((Join-Path $env:PCKIT_SNAPSHOT ("{0:D2}-{1}.png" -f (++$Script:Kit.SnapNo), $Name)))
        $enc.Save($fs); $fs.Close()
    } catch { }
}

function Open-KitTarget([string]$Target) {
    if (-not $Target) { return }
    try {
        if ($Target -match '^[a-z][a-z0-9+.-]*:' -and $Target -notmatch '^[a-zA-Z]:\\') { Start-Process $Target -ErrorAction Stop; return }
        if ((Test-Path -LiteralPath $Target)) { Start-Process $Target -ErrorAction Stop; return }
        if ($Target -match '^(\S+)\s+(.+)$') { Start-Process -FilePath $Matches[1] -ArgumentList $Matches[2] -ErrorAction Stop; return }
        Start-Process $Target -ErrorAction Stop
    } catch { Add-KitLog "Could not open $Target" 'warn' }
}

# --- Dialogs (window thread) -------------------------------------------------
function New-KitDialog([string]$Heading, [int]$Width = 520) {
    $p = $Script:Kit.Palette
    $res = Get-KitResourcesXaml $p
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Reinstall Kit" Width="$Width" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Background="$($p.Bg)" Foreground="$($p.Fg)" FontFamily="Segoe UI" FontSize="14" UseLayoutRounding="True">
$res
  <Grid Margin="26,22,26,22">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="Head" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel x:Name="Body" Grid.Row="1"/>
    <DockPanel Grid.Row="2" Margin="0,20,0,0" LastChildFill="False">
      <StackPanel x:Name="Left" Orientation="Horizontal" DockPanel.Dock="Left"/>
      <StackPanel x:Name="Right" Orientation="Horizontal" DockPanel.Dock="Right"/>
    </DockPanel>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    if ($Script:Kit.Window -and $Script:Kit.Window.IsVisible) { $w.Owner = $Script:Kit.Window } else { $w.WindowStartupLocation = 'CenterScreen' }
    if ($Script:Kit.Icon) { $w.Icon = $Script:Kit.Icon }
    $w.FindName('Head').Text = $Heading
    $w.Add_SourceInitialized({ Set-KitDarkTitleBar $this })
    return $w
}

function Set-KitDialogText($w, [string]$Text) {
    # First line = heading; the rest (or a long single line) = normal body text.
    $p = $Script:Kit.Palette
    $head = $w.FindName('Head')
    $parts = $Text -split "`n", 2
    $first = $parts[0].Trim()
    $rest = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
    if (-not $rest -and $first.Length -gt 90) { $rest = $first; $first = '' }
    if ($first) { $head.Text = $first } else { $head.Visibility = 'Collapsed' }
    if ($rest) {
        $t = New-KitText $rest $p.Fg 14
        $t.Margin = '0,0,0,6'; $t.LineHeight = 21
        $w.FindName('Body').Children.Insert(0, $t)
    }
}

function New-KitText([string]$Text, [string]$Color, [double]$Size = 14, [string]$Weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.FontSize = $Size; $t.FontWeight = $Weight
    if ($Color) { $t.Foreground = Get-KitBrush $Color }
    return $t
}

function New-KitButton($Window, [string]$Text, [switch]$Secondary, [switch]$IsDefault, [switch]$IsCancel) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    if ($Secondary) { $b.Style = $Window.FindResource('Sec') }
    $b.IsDefault = [bool]$IsDefault; $b.IsCancel = [bool]$IsCancel
    return $b
}

function Show-KitModal($w, [string]$SnapName) {
    if ($env:PCKIT_SNAPSHOT) {
        $w.Add_ContentRendered({ Save-KitSnapshot $this $this.Tag; if ($env:PCKIT_AUTOANSWER -eq '1') { $this.DialogResult = $true } })
        $w.Tag = $SnapName
    }
    return $w.ShowDialog()
}

function Show-KitDialog($m) {
    $p = $Script:Kit.Palette
    switch ($m.Kind) {
        'yesno' {
            $w = New-KitDialog '' 520
            Set-KitDialogText $w "$($m.Text)"
            $right = $w.FindName('Right')
            $no = New-KitButton $w 'No' -Secondary:([bool]$m.Default) -IsDefault:(-not $m.Default) -IsCancel
            $yes = New-KitButton $w 'Yes' -Secondary:(-not $m.Default) -IsDefault:([bool]$m.Default)
            $yes.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
            [void]$right.Children.Add($no); [void]$right.Children.Add($yes)
            $r = Show-KitModal $w 'yesno'
            if ($env:PCKIT_AUTOANSWER -eq '1') { return [bool]$m.Default }
            return [bool]$r
        }
        'info' {
            $w = New-KitDialog '' 520
            Set-KitDialogText $w "$($m.Text)"
            $ok = New-KitButton $w $(if ($m.Button) { $m.Button } else { 'OK' }) -IsDefault -IsCancel
            $ok.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
            [void]$w.FindName('Right').Children.Add($ok)
            [void](Show-KitModal $w 'info')
            return $true
        }
        'input' {
            $w = New-KitDialog '' 560
            Set-KitDialogText $w "$($m.Text)"
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Text = "$($m.Default)"
            [void]$w.FindName('Body').Children.Add($tb)
            $cancel = New-KitButton $w 'Cancel' -Secondary -IsCancel
            $ok = New-KitButton $w 'OK' -IsDefault
            $ok.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
            [void]$w.FindName('Right').Children.Add($cancel); [void]$w.FindName('Right').Children.Add($ok)
            $w.Add_ContentRendered({ $this.FindName('Body').Children[0].Focus() | Out-Null })
            if (Show-KitModal $w 'input') { return $tb.Text }
            return ''
        }
        'folder' {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = "$($m.Text)"
            $dlg.ShowNewFolderButton = $true
            if ($env:PCKIT_AUTOANSWER -eq '1') { return '' }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
            return ''
        }
        'choice' {
            $w = New-KitDialog '' 560
            Set-KitDialogText $w "$($m.Text)"
            $body = $w.FindName('Body')
            $w.Resources['Choice'] = -1
            for ($i = 0; $i -lt @($m.Options).Count; $i++) {
                $b = New-KitButton $w $m.Options[$i] -Secondary:($i -ne [int]$m.Default) -IsDefault:($i -eq [int]$m.Default)
                $b.Margin = '0,0,0,8'; $b.HorizontalContentAlignment = 'Left'; $b.Tag = $i
                $b.Add_Click({ $win = [System.Windows.Window]::GetWindow($this); $win.Resources['Choice'] = [int]$this.Tag; $win.DialogResult = $true })
                [void]$body.Children.Add($b)
            }
            $cancel = New-KitButton $w 'Cancel' -Secondary -IsCancel
            [void]$w.FindName('Right').Children.Add($cancel)
            $r = Show-KitModal $w 'choice'
            if ($env:PCKIT_AUTOANSWER -eq '1') { return [int]$m.Default }
            if ($r) { return [int]$w.Resources['Choice'] }
            return -1
        }
        'select' {
            $title = if ($m.Title) { $m.Title } else { 'Choose' }
            $w = New-KitDialog $title 700
            $body = $w.FindName('Body')
            if ($m.Text) { $t = New-KitText $m.Text $p.Muted; $t.Margin = '0,0,0,12'; [void]$body.Children.Add($t) }
            $boxes = New-Object System.Collections.ArrayList
            $rows = @($m.Rows); $checked = @($m.Checked)
            $search = $null
            if ($rows.Count -gt 10) {
                $search = New-Object System.Windows.Controls.TextBox
                $search.Margin = '0,0,0,10'; $search.ToolTip = 'Type to filter'
                [void]$body.Children.Add($search)
            }
            $sv = New-Object System.Windows.Controls.ScrollViewer
            $sv.MaxHeight = 430; $sv.VerticalScrollBarVisibility = 'Auto'
            $list = New-Object System.Windows.Controls.StackPanel
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                $box = if ($m.Single) { New-Object System.Windows.Controls.RadioButton } else { New-Object System.Windows.Controls.CheckBox }
                if ($m.Single) { $box.GroupName = 'g' }
                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.Margin = '8,-2,0,0'
                [void]$sp.Children.Add((New-KitText "$($row.Main)" $p.Fg 14 'SemiBold'))
                if ($row.Sub) { [void]$sp.Children.Add((New-KitText "$($row.Sub)" $p.Muted 12.5)) }
                $box.Content = $sp
                $box.IsChecked = [bool]$checked[$i]
                $box.Tag = ("$($row.Main) $($row.Sub)").ToLowerInvariant()
                $card = New-Object System.Windows.Controls.Border
                $card.Background = Get-KitBrush $p.Card; $card.CornerRadius = 10; $card.Padding = '12,9'; $card.Margin = '0,0,6,6'
                $card.Child = $box
                [void]$list.Children.Add($card)
                [void]$boxes.Add($box)
            }
            $sv.Content = $list
            [void]$body.Children.Add($sv)
            $count = New-KitText '' $p.Muted 12.5
            $count.Margin = '0,8,0,0'
            [void]$body.Children.Add($count)
            $update = { param($bx, $ct) $n = @($bx | Where-Object { $_.IsChecked }).Count; $ct.Text = "$n of $($bx.Count) selected" }
            & $update $boxes $count
            $w.Resources['Boxes'] = $boxes; $w.Resources['Count'] = $count
            foreach ($bx in $boxes) {
                $handler = { $win = [System.Windows.Window]::GetWindow($this); $bxs = $win.Resources['Boxes']; $n = @($bxs | Where-Object { $_.IsChecked }).Count; $win.Resources['Count'].Text = "$n of $($bxs.Count) selected" }
                $bx.Add_Checked($handler); $bx.Add_Unchecked($handler)
            }
            if ($search) {
                $search.Add_TextChanged({
                    $win = [System.Windows.Window]::GetWindow($this); $q = $this.Text.Trim().ToLowerInvariant()
                    foreach ($bx in $win.Resources['Boxes']) { $bx.Parent.Visibility = $(if (-not $q -or $bx.Tag.Contains($q)) { 'Visible' } else { 'Collapsed' }) }
                })
            }
            if (-not $m.Single) {
                $all = New-KitButton $w 'Select all' -Secondary
                $all.Margin = '0,0,0,0'
                $all.Add_Click({ foreach ($bx in [System.Windows.Window]::GetWindow($this).Resources['Boxes']) { if ($bx.Parent.Visibility -eq 'Visible') { $bx.IsChecked = $true } } })
                $none = New-KitButton $w 'None' -Secondary
                $none.Add_Click({ foreach ($bx in [System.Windows.Window]::GetWindow($this).Resources['Boxes']) { $bx.IsChecked = $false } })
                [void]$w.FindName('Left').Children.Add($all); [void]$w.FindName('Left').Children.Add($none)
            }
            $skip = New-KitButton $w $(if ($m.SkipText) { $m.SkipText } else { 'Skip' }) -Secondary -IsCancel
            $ok = New-KitButton $w $(if ($m.OkText) { $m.OkText } else { 'Continue' }) -IsDefault
            $ok.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
            [void]$w.FindName('Right').Children.Add($skip); [void]$w.FindName('Right').Children.Add($ok)
            $r = Show-KitModal $w 'select'
            if ($r) {
                $out = @()
                for ($i = 0; $i -lt $boxes.Count; $i++) { if ($boxes[$i].IsChecked) { $out += $i } }
                return , $out
            }
            return , @()
        }
        'checklist' {
            $w = New-KitDialog 'Checklist' 760
            $body = $w.FindName('Body')
            $intro = New-KitText 'Go through each item. "Open" takes you to the right setting or page. Tick items as you finish them - ticks are saved, so you can close this and come back later.' $p.Muted
            $intro.Margin = '0,0,0,12'
            [void]$body.Children.Add($intro)
            $sv = New-Object System.Windows.Controls.ScrollViewer
            $sv.MaxHeight = 480; $sv.VerticalScrollBarVisibility = 'Auto'
            $list = New-Object System.Windows.Controls.StackPanel
            $boxes = New-Object System.Collections.ArrayList
            $items = @($m.Items)
            $lastSection = $null
            for ($i = 0; $i -lt $items.Count; $i++) {
                $it = $items[$i]
                if ($it.Section -ne $lastSection) {
                    $h = New-KitText "$($it.Section)" $p.Accent 15 'SemiBold'
                    $h.Margin = '0,10,0,6'
                    [void]$list.Children.Add($h)
                    $lastSection = $it.Section
                }
                $card = New-Object System.Windows.Controls.Border
                $card.Background = Get-KitBrush $p.Card; $card.CornerRadius = 10; $card.Padding = '12,8'; $card.Margin = '0,0,6,6'
                $dock = New-Object System.Windows.Controls.DockPanel
                if ($it.Link) {
                    $open = New-KitButton $w 'Open' -Secondary
                    $open.Padding = '12,4'; $open.Tag = "$($it.Link)"
                    $open.Add_Click({ Open-KitTarget $this.Tag })
                    [System.Windows.Controls.DockPanel]::SetDock($open, 'Right')
                    [void]$dock.Children.Add($open)
                }
                $cb = New-Object System.Windows.Controls.CheckBox
                $tx = New-KitText "$($it.Text)" $p.Fg
                $tx.Margin = '8,-2,0,0'
                $cb.Content = $tx
                $cb.IsChecked = [bool]$it.Done
                $cb.VerticalAlignment = 'Center'
                [void]$dock.Children.Add($cb)
                $card.Child = $dock
                [void]$list.Children.Add($card)
                [void]$boxes.Add($cb)
            }
            $sv.Content = $list
            [void]$body.Children.Add($sv)
            $count = New-KitText '' $p.Muted 12.5
            $count.Margin = '0,8,0,0'
            [void]$body.Children.Add($count)
            $w.Resources['Boxes'] = $boxes; $w.Resources['Count'] = $count
            $n0 = @($boxes | Where-Object { $_.IsChecked }).Count
            $count.Text = "$n0 of $($boxes.Count) done"
            foreach ($bx in $boxes) {
                $handler = { $win = [System.Windows.Window]::GetWindow($this); $bxs = $win.Resources['Boxes']; $n = @($bxs | Where-Object { $_.IsChecked }).Count; $win.Resources['Count'].Text = "$n of $($bxs.Count) done" }
                $bx.Add_Checked($handler); $bx.Add_Unchecked($handler)
            }
            $close = New-KitButton $w 'Save and close' -IsDefault -IsCancel
            $close.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
            [void]$w.FindName('Right').Children.Add($close)
            [void](Show-KitModal $w 'checklist')
            $out = @()
            for ($i = 0; $i -lt $boxes.Count; $i++) { if ($boxes[$i].IsChecked) { $out += $i } }
            return , $out
        }
    }
    return $null
}

# --- Main window -------------------------------------------------------------
function Add-KitLog([string]$Text, [string]$Level = 'info') {
    $k = $Script:Kit; $p = $k.Palette
    $t = New-Object System.Windows.Controls.TextBlock
    $t.TextWrapping = 'Wrap'; $t.Margin = '0,1,0,1'
    $prefix = ''
    switch ($Level) {
        'ok'   { $prefix = [string][char]0x2713 + '  '; $t.Foreground = Get-KitBrush $p.Ok }
        'warn' { $prefix = '!  '; $t.Foreground = Get-KitBrush $p.Warn }
        'fail' { $prefix = [string][char]0x2715 + '  '; $t.Foreground = Get-KitBrush $p.Bad }
        'todo' { $prefix = [string][char]0x2192 + '  '; $t.Foreground = Get-KitBrush $p.Fg; $t.FontWeight = 'SemiBold' }
        'head' { $t.Foreground = Get-KitBrush $p.Fg; $t.FontWeight = 'SemiBold'; $t.FontSize = 16; $t.Margin = '0,12,0,4' }
        'sub'  { $t.Foreground = Get-KitBrush $p.Accent; $t.FontWeight = 'SemiBold'; $t.Margin = '0,8,0,2' }
        default { $prefix = '    '; $t.Foreground = Get-KitBrush $p.Muted }
    }
    $t.Text = $prefix + $Text
    [void]$k.LogPanel.Children.Add($t)
    if ($k.LogPanel.Children.Count -gt 3000) { $k.LogPanel.Children.RemoveAt(0) }
    $k.LogDirty = $true
    if ($Text -match '^\[(\d+)/(\d+)\]\s*(.*)$') { Set-KitProgress -Value ([int]$Matches[1]) -Max ([int]$Matches[2]) -Text $Matches[3] }
}

function Set-KitProgress([string]$Text, [double]$Value = -1, [double]$Max = 0, [switch]$Indeterminate, [switch]$Done) {
    $k = $Script:Kit
    if ($Done) { $k.SubBar.Visibility = 'Hidden'; $k.SubText.Text = ''; return }
    if ($Text -match '^(\d+)/(\d+)\b' -and $Value -lt 0) { $Value = [int]$Matches[1]; $Max = [int]$Matches[2]; $Text = "$Value of $Max" }
    $k.SubText.Text = $Text
    $k.SubBar.Visibility = 'Visible'
    if ($Indeterminate -or $Max -le 0) { $k.SubBar.IsIndeterminate = $true }
    else { $k.SubBar.IsIndeterminate = $false; $k.SubBar.Maximum = $Max; $k.SubBar.Value = [math]::Min($Value, $Max) }
}

function Set-KitStepState([int]$Index, [string]$State) {
    $k = $Script:Kit; $p = $k.Palette
    if ($Index -lt 0 -or $Index -ge $k.StepRows.Count) { return }
    $row = $k.StepRows[$Index]
    $k.StepStates[$Index] = $State
    switch ($State) {
        'running' { $row.Icon.Text = [string][char]0x25CF; $row.Icon.Foreground = Get-KitBrush $p.Accent; $row.Title.FontWeight = 'SemiBold'; $row.Card.Background = Get-KitBrush $p.Sel }
        'done'    { $row.Icon.Text = [string][char]0x2713; $row.Icon.Foreground = Get-KitBrush $p.Ok; $row.Title.FontWeight = 'Normal'; $row.Card.Background = [System.Windows.Media.Brushes]::Transparent }
        'warn'    { $row.Icon.Text = '!'; $row.Icon.Foreground = Get-KitBrush $p.Warn; $row.Title.FontWeight = 'Normal'; $row.Card.Background = [System.Windows.Media.Brushes]::Transparent }
        'failed'  { $row.Icon.Text = [string][char]0x2715; $row.Icon.Foreground = Get-KitBrush $p.Bad; $row.Title.FontWeight = 'Normal'; $row.Card.Background = [System.Windows.Media.Brushes]::Transparent }
        default   { $row.Icon.Text = [string][char]0x25CB; $row.Icon.Foreground = Get-KitBrush $p.Muted; $row.Title.FontWeight = 'Normal'; $row.Card.Background = [System.Windows.Media.Brushes]::Transparent }
    }
    if ($k.Selected -eq $Index -and $State -ne 'running') { $row.Card.BorderBrush = Get-KitBrush $p.Accent }
    $done = @($k.StepStates | Where-Object { $_ -eq 'done' }).Count
    $k.Overall.Maximum = [math]::Max(1, $k.StepRows.Count); $k.Overall.Value = $done
    $k.OverallText.Text = "$done of $($k.StepRows.Count) steps done"
}

function Set-KitSteps([string[]]$Titles) {
    $k = $Script:Kit; $p = $k.Palette
    $k.StepPanel.Children.Clear()
    $k.StepRows = @(); $k.StepStates = @()
    for ($i = 0; $i -lt $Titles.Count; $i++) {
        $card = New-Object System.Windows.Controls.Border
        $card.CornerRadius = 10; $card.Padding = '10,5'; $card.Margin = '0,0,0,2'; $card.BorderThickness = 1
        $card.BorderBrush = [System.Windows.Media.Brushes]::Transparent; $card.Background = [System.Windows.Media.Brushes]::Transparent
        $card.Tag = $i
        $dock = New-Object System.Windows.Controls.DockPanel
        $icon = New-KitText ([string][char]0x25CB) $p.Muted 14
        $icon.Width = 26; $icon.TextWrapping = 'NoWrap'
        $num = New-KitText ("{0}." -f ($i + 1)) $p.Muted 13
        $num.Width = 24; $num.TextWrapping = 'NoWrap'
        $title = New-KitText $Titles[$i] $p.Fg 14
        [void]$dock.Children.Add($icon); [void]$dock.Children.Add($num); [void]$dock.Children.Add($title)
        $card.Child = $dock
        if ($k.Mode -eq 'Setup') {
            $card.Cursor = 'Hand'
            $card.ToolTip = 'Click to select, then "Run this step"'
            $card.Add_MouseLeftButtonUp({ Select-KitStep ([int]$this.Tag) })
        }
        [void]$k.StepPanel.Children.Add($card)
        $k.StepRows += @{ Card = $card; Icon = $icon; Title = $title }
        $k.StepStates += 'pending'
    }
    Set-KitStepState -Index -1 -State 'pending'
    $k.Overall.Maximum = [math]::Max(1, $Titles.Count); $k.Overall.Value = 0
    $k.OverallText.Text = "0 of $($Titles.Count) steps done"
}

function Select-KitStep([int]$Index) {
    $k = $Script:Kit; $p = $k.Palette
    for ($i = 0; $i -lt $k.StepRows.Count; $i++) {
        $k.StepRows[$i].Card.BorderBrush = $(if ($i -eq $Index) { Get-KitBrush $p.Accent } else { [System.Windows.Media.Brushes]::Transparent })
    }
    $k.Selected = $Index
    Update-KitButtons
}

function Set-KitButtons([object[]]$Defs) {
    # Defs: array of @{ Text; Secondary; Action (scriptblock); Enabled }
    $k = $Script:Kit
    $k.ButtonPanel.Children.Clear()
    foreach ($d in $Defs) {
        $b = New-KitButton $k.Window $d.Text -Secondary:([bool]$d.Secondary)
        $b.Tag = $d.Action
        if ($d.ContainsKey('Enabled')) { $b.IsEnabled = [bool]$d.Enabled }
        $b.Add_Click({ & $this.Tag })
        [void]$k.ButtonPanel.Children.Add($b)
    }
}

function Update-KitButtons {
    $k = $Script:Kit
    $close = @{ Text = 'Close'; Secondary = $true; Action = { $Script:Kit.Window.Close() } }
    $links = @()
    if ($k.Paths.Folder) { $links += @{ Text = 'Backup folder'; Secondary = $true; Action = { Open-KitTarget $Script:Kit.Paths.Folder } } }
    if ($k.Paths.Checklist) { $links += @{ Text = 'Checklist'; Secondary = $true; Action = { Open-KitTarget $Script:Kit.Paths.Checklist } } }
    if ($k.Paths.Report) { $links += @{ Text = 'Report'; Secondary = $true; Action = { Open-KitTarget $Script:Kit.Paths.Report } } }
    if ($k.Paths.Apps) { $links += @{ Text = 'App list'; Secondary = $true; Action = { Open-KitTarget $Script:Kit.Paths.Apps } } }
    if ($k.Mode -eq 'Backup') {
        if (-not $k.Started) {
            Set-KitButtons @($close, @{ Text = 'Start backup'; Action = { Start-KitWorker; Update-KitButtons } })
        } elseif (-not $k.Finished) {
            Set-KitButtons @(@{ Text = 'Working...'; Secondary = $true; Enabled = $false; Action = { } })
        } else {
            Set-KitButtons (@($links) + @($close))
        }
        return
    }
    # Setup
    $busy = [bool]$k.Busy
    $remaining = @($k.StepStates | Where-Object { $_ -ne 'done' }).Count
    $defs = @($links | Where-Object { $_.Text -ne 'Backup folder' -and $_.Text -ne 'Checklist' })
    $defs += $close
    $defs += @{ Text = 'Run this step'; Secondary = $true; Enabled = (-not $busy -and $k.Ready -and $k.Selected -ge 0); Action = { $Script:Kit.Sync.Commands.Enqueue("step:$($Script:Kit.Selected)"); $Script:Kit.Busy = $true; Update-KitButtons } }
    $label = if ($busy) { 'Working...' } elseif ($remaining -eq 0 -and $k.StepRows.Count) { 'All steps done' } elseif (@($k.StepStates | Where-Object { $_ -eq 'done' }).Count) { 'Continue setup' } else { 'Start setup' }
    $defs += @{ Text = $label; Enabled = (-not $busy -and $k.Ready -and $remaining -gt 0); Action = { $Script:Kit.Sync.Commands.Enqueue('all'); $Script:Kit.Busy = $true; Update-KitButtons } }
    Set-KitButtons $defs
}

function Start-KitWorker {
    $k = $Script:Kit
    if ($k.Started) { return }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand($k.ScriptPath)
    [void]$ps.AddParameter('KitWorker', $true)
    [void]$ps.AddParameter('KitSync', $k.Sync)
    foreach ($kv in $k.ScriptArgs.GetEnumerator()) {
        if ($null -eq $kv.Value) { continue }
        if ($kv.Value -is [string] -and $kv.Value -eq '') { continue }
        [void]$ps.AddParameter($kv.Key, $kv.Value)
    }
    $k.PS = $ps
    $k.Handle = $ps.BeginInvoke()
    $k.Started = $true
}

function Invoke-KitTick {
    $k = $Script:Kit
    $sync = $k.Sync
    $msg = $null
    $n = 0
    while ($n -lt 400 -and $sync.Queue.TryDequeue([ref]$msg)) {
        $n++
        try {
            switch ($msg.T) {
                'log'      { Add-KitLog $msg.Text $msg.Level }
                'steps'    { Set-KitSteps @($msg.Titles); Update-KitButtons }
                'step'     { Set-KitStepState ([int]$msg.Index) $msg.State; if ($k.Mode -eq 'Setup') { Update-KitButtons } }
                'status'   { $k.StatusTitle.Text = $msg.Text }
                'subtitle' { $k.Subtitle.Text = $msg.Text }
                'progress' { Set-KitProgress -Text "$($msg.Text)" -Value $(if ($null -ne $msg.Value) { [double]$msg.Value } else { -1 }) -Max $(if ($msg.Max) { [double]$msg.Max } else { 0 }) -Indeterminate:([bool]$msg.Indeterminate) -Done:([bool]$msg.Done) }
                'paths'    { foreach ($key in 'Folder', 'Report', 'Apps', 'Checklist') { if ($msg[$key]) { $k.Paths[$key] = $msg[$key] } }; Update-KitButtons }
                'busy'     {
                    $k.Busy = [bool]$msg.Value
                    if (-not $k.Busy) { Set-KitProgress -Done }
                    Update-KitButtons
                    if (-not $k.Busy -and $env:PCKIT_AUTOCLOSE -eq '1') { $k.LogScroll.ScrollToEnd(); Save-KitSnapshot $k.Window 'main-idle'; $k.Window.Close() }
                }
                'ready'    { $k.Ready = $true; Update-KitButtons }
                'done'     {
                    $k.Finished = $true; $k.DoneMsg = $true
                    $k.StatusTitle.Text = "$($msg.Text)"
                    Set-KitProgress -Done
                    Update-KitButtons
                    if ($env:PCKIT_SNAPSHOT) { $k.LogScroll.ScrollToEnd(); Save-KitSnapshot $k.Window 'main-done' }
                }
                'ask'      {
                    $k.Timer.Stop()
                    $ans = $null
                    try { $ans = Show-KitDialog $msg } catch { Add-KitLog "Dialog error: $($_.Exception.Message)" 'fail' }
                    $sync.Answers[$msg.Id] = $ans
                    $k.Timer.Start()
                }
            }
        } catch { }
    }
    if ($k.LogDirty) { $k.LogScroll.ScrollToEnd(); $k.LogDirty = $false }

    if ($k.Started -and -not $k.Ended -and $k.Handle.IsCompleted) {
        $k.Ended = $true
        try { [void]$k.PS.EndInvoke($k.Handle) } catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            if (-not $sync.Closing) { Add-KitLog "Stopped because of an error: $($e.Message)" 'fail' }
        }
        if (-not $k.DoneMsg -and -not $sync.Closing) {
            $k.Finished = $true
            $k.StatusTitle.Text = 'Stopped'
            Add-KitLog 'The task ended early. Details are in the Logs folder of the backup.' 'warn'
            for ($i = 0; $i -lt $k.StepStates.Count; $i++) { if ($k.StepStates[$i] -eq 'running') { Set-KitStepState $i 'failed' } }
            Update-KitButtons
        }
        if ($env:PCKIT_AUTOCLOSE -eq '1') { $k.Window.Close() }
    }
}

function Start-KitApp {
    param(
        [ValidateSet('Backup', 'Setup')][string]$Mode,
        [string]$ScriptPath,
        [hashtable]$ScriptArgs = @{},
        [string]$Version,
        [string]$Subtitle,
        [string[]]$IntroLines,
        [string[]]$Steps,
        [switch]$AutoStart
    )
    $p = Get-KitPalette
    $sync = [hashtable]::Synchronized(@{
        Queue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Answers  = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,object]'
        Commands = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Closing  = $false
    })
    $Script:Kit = @{
        Palette = $p; Mode = $Mode; ScriptPath = $ScriptPath; ScriptArgs = $ScriptArgs; Version = $Version; Sync = $sync
        StepRows = @(); StepStates = @(); Selected = -1; Busy = $false; Ready = $false; Paths = @{}
        Started = $false; Finished = $false; Ended = $false; DoneMsg = $false; LogDirty = $false; SnapNo = 0
    }
    $Script:Kit.Icon = New-KitIcon
    $res = Get-KitResourcesXaml $p
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Reinstall Kit $Version" Width="1000" Height="700" MinWidth="780" MinHeight="540" WindowStartupLocation="CenterScreen"
        Background="$($p.Bg)" Foreground="$($p.Fg)" FontFamily="Segoe UI" FontSize="14" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
$res
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="290"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <Border Grid.ColumnSpan="2" Background="$($p.Side)" BorderBrush="$($p.Line)" BorderThickness="0,0,0,1" Padding="24,16">
      <DockPanel>
        <Border DockPanel.Dock="Right" Background="$($p.Chip)" CornerRadius="11" Padding="11,3" VerticalAlignment="Center">
          <TextBlock x:Name="VersionText" Foreground="$($p.ChipFg)" FontSize="12.5"/>
        </Border>
        <Image x:Name="Logo" Width="40" Height="40" Margin="0,0,14,0" DockPanel.Dock="Left"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="PC Reinstall Kit" FontSize="21" FontWeight="SemiBold"/>
          <TextBlock x:Name="Subtitle" Foreground="$($p.Muted)" FontSize="13.5" TextWrapping="Wrap"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border Grid.Row="1" Background="$($p.Side)" BorderBrush="$($p.Line)" BorderThickness="0,0,1,0">
      <DockPanel Margin="14,16,14,14">
        <StackPanel DockPanel.Dock="Bottom" Margin="4,12,4,0">
          <ProgressBar x:Name="Overall" Height="6" Maximum="1" Value="0"/>
          <TextBlock x:Name="OverallText" Foreground="$($p.Muted)" FontSize="12.5" Margin="0,6,0,0"/>
        </StackPanel>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="StepPanel"/></ScrollViewer>
      </DockPanel>
    </Border>

    <Grid Grid.Row="1" Grid.Column="1" Margin="26,20,26,10">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <TextBlock x:Name="StatusTitle" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <StackPanel Grid.Row="1" Margin="0,10,0,12">
        <TextBlock x:Name="SubText" Foreground="$($p.Muted)" FontSize="13" TextWrapping="Wrap"/>
        <ProgressBar x:Name="SubBar" Height="6" Margin="0,6,0,0" Visibility="Hidden"/>
      </StackPanel>
      <Border Grid.Row="2" Background="$($p.Card2)" BorderBrush="$($p.Line)" BorderThickness="1" CornerRadius="14">
        <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" Padding="18,12">
          <StackPanel x:Name="LogPanel"/>
        </ScrollViewer>
      </Border>
    </Grid>

    <Border Grid.Row="2" Grid.ColumnSpan="2" BorderBrush="$($p.Line)" BorderThickness="0,1,0,0" Padding="20,12">
      <StackPanel x:Name="ButtonPanel" Orientation="Horizontal" HorizontalAlignment="Right"/>
    </Border>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $k = $Script:Kit
    $k.Window = $w
    foreach ($n in 'VersionText', 'Logo', 'Subtitle', 'Overall', 'OverallText', 'StepPanel', 'StatusTitle', 'SubText', 'SubBar', 'LogScroll', 'LogPanel', 'ButtonPanel') { $k[$n] = $w.FindName($n) }
    $k.VersionText.Text = "v$Version"
    $k.Subtitle.Text = $Subtitle
    if ($k.Icon) { $w.Icon = $k.Icon; $k.Logo.Source = $k.Icon }
    $k.StatusTitle.Text = $(if ($Mode -eq 'Backup') { 'Back up this PC' } else { 'Set up this PC' })
    if ($Steps) { Set-KitSteps $Steps }
    foreach ($l in $IntroLines) { if ($l -like '#*') { Add-KitLog $l.TrimStart('#').Trim() 'head' } elseif ($l -like '>*') { Add-KitLog $l.TrimStart('>').Trim() 'todo' } else { Add-KitLog $l 'info' } }
    $w.Add_SourceInitialized({ Set-KitDarkTitleBar $this })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(90)
    $timer.Add_Tick({ Invoke-KitTick })
    $k.Timer = $timer

    $w.Add_Closing({
        param($sender, $e)
        $k = $Script:Kit
        $running = $k.Started -and -not $k.Ended
        $working = ($k.Mode -eq 'Backup' -and $running -and -not $k.Finished) -or ($k.Mode -eq 'Setup' -and $k.Busy)
        if ($working -and $env:PCKIT_AUTOCLOSE -ne '1') {
            $r = [System.Windows.MessageBox]::Show($k.Window, 'Work is still in progress. Stop it and close?', 'PC Reinstall Kit', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $e.Cancel = $true; return }
        }
        $k.Sync.Closing = $true
        $k.Timer.Stop()
        if ($running) { try { [void]$k.PS.BeginStop($null, $null) } catch { } }
    })
    $w.Add_Loaded({
        $Script:Kit.Timer.Start()
        Update-KitButtons
        if ($Script:Kit.AutoStart) { Start-KitWorker; Update-KitButtons }
        if ($env:PCKIT_AUTOCMD) { foreach ($c in ($env:PCKIT_AUTOCMD -split ',')) { $Script:Kit.Sync.Commands.Enqueue($c) } }
        if ($env:PCKIT_SNAPSHOT) { Save-KitSnapshot $Script:Kit.Window 'main-start' }
    })
    $k.AutoStart = [bool]$AutoStart -or ($env:PCKIT_AUTOSTART -eq '1')
    Update-KitButtons
    [void]$w.ShowDialog()
    $sync.Closing = $true
}
