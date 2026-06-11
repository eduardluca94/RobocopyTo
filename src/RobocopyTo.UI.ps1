# RobocopyTo.UI.ps1 - progress dialog replicating the Windows 11 copy dialog.
# Faithful details (sampled from the real dialog on this machine):
#   - expanded mode has no separate progress bar: the graph IS the progress -
#     x axis = fraction of bytes copied, y = throughput, area filled #06B025
#     under the speed curve, remaining region is the #A7E591 panel with
#     #8EDD7B vertical gridlines and a #BCBCBC hairline border
#   - big "N% complete" line, source/dest names accent-colored in the header
#   - speed label top-right inside the graph, chevron + separator on the
#     details toggle, borderless pause/cancel glyph buttons
# One deliberate divergence: the real dialog stays light in dark mode; ours
# follows the app theme.
# Library file: dot-sourced by RobocopyTo.psm1. ASCII-only source.

# WPF assemblies are loaded on demand via Initialize-RtWpf (Common) so that
# launches which never open a window stay light.

$script:RtSrcDir = $PSScriptRoot

function Get-RtTheme {
    $light = 1
    try {
        $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme
    } catch { }
    if ($light -eq 0) {
        return @{
            IsDark = $true
            WindowBg = '#202020'; Text = '#FFFFFF'; TextSecondary = '#C9C9C9'
            BarGreen = '#06B025'; BarPaused = '#CA9F36'; BarError = '#C42B1C'
            GraphPanel = '#233A1E'; GraphGrid = '#2E4A28'; GraphFill = '#06B025'; GraphBorder = '#404040'
            GraphText = '#FFFFFF'
            BtnGlyph = '#C9C9C9'; BtnHover = '#383838'; Accent = '#4CC2FF'
            BarTrack = '#404040'; Separator = '#3A3A3A'
            BtnBg = '#2D2D2D'; BtnBorder = '#454545'
        }
    }
    return @{
        IsDark = $false
        WindowBg = '#FFFFFF'; Text = '#1B1B1B'; TextSecondary = '#494949'
        BarGreen = '#06B025'; BarPaused = '#9D7A00'; BarError = '#C42B1C'
        GraphPanel = '#A7E591'; GraphGrid = '#8EDD7B'; GraphFill = '#06B025'; GraphBorder = '#BCBCBC'
        GraphText = '#1B1B1B'
        BtnGlyph = '#5F5F5F'; BtnHover = '#EAEAEA'; Accent = '#005FB8'
        BarTrack = '#E6E6E6'; Separator = '#E5E5E5'
        BtnBg = '#FBFBFB'; BtnBorder = '#D9D9D9'
    }
}

function Format-RtEta([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return 'Calculating...' }
    $s = [int][Math]::Ceiling($Seconds)
    if ($s -ge 5400) { return ('About {0} hours' -f [int][Math]::Round($s / 3600.0)) }
    if ($s -ge 3300) { return 'About 1 hour' }
    if ($s -ge 120) {
        $m = [int][Math]::Floor($s / 60.0); $r = $s % 60
        if ($r -ge 5) { return ('About {0} minutes and {1} seconds' -f $m, $r) }
        return ('About {0} minutes' -f $m)
    }
    if ($s -ge 60) { return ('About 1 minute and {0} seconds' -f ($s - 60)) }
    if ($s -gt 5) { return ('About {0} seconds' -f $s) }
    return 'A few seconds'
}

function Set-RtDarkTitlebar($Window, [bool]$IsDark) {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        $v = if ($IsDark) { 1 } else { 0 }
        [void][RobocopyTo.Native]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
    } catch { }
}

function New-RtProgressWindow([hashtable]$T) {
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Calculating..." Width="472" SizeToContent="Height" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="$($T.WindowBg)" ShowInTaskbar="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="GlyphBtn" TargetType="Button">
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="$($T.BtnGlyph)"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="$($T.BtnHover)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Background" Value="$($T.BtnBg)"/>
      <Setter Property="BorderBrush" Value="$($T.BtnBorder)"/>
      <Setter Property="Foreground" Value="$($T.Text)"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="14,5,14,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="$($T.BtnHover)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <StackPanel Margin="32,16,32,8">
    <TextBlock x:Name="HeaderText" FontSize="14" Foreground="$($T.Text)" TextTrimming="CharacterEllipsis"/>
    <Grid Margin="0,2,0,0">
      <TextBlock x:Name="PercentText" Text="Calculating..." FontSize="20" Foreground="$($T.Text)" VerticalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button x:Name="PauseBtn" Style="{StaticResource GlyphBtn}" Content="&#xE769;" Margin="0,0,4,0" ToolTip="Pause"/>
        <Button x:Name="CancelBtn" Style="{StaticResource GlyphBtn}" Content="&#xE711;" ToolTip="Cancel"/>
      </StackPanel>
    </Grid>
    <ProgressBar x:Name="Bar" Height="5" Margin="0,10,0,2" Minimum="0" Maximum="1000" Value="0"
                 Foreground="$($T.BarGreen)" Background="$($T.BarTrack)" BorderThickness="0" IsIndeterminate="True"/>
    <StackPanel x:Name="DetailsPanel">
      <Border x:Name="GraphBorder" BorderBrush="$($T.GraphBorder)" BorderThickness="1" Background="$($T.GraphPanel)"
              Height="86" Margin="0,8,0,10">
        <Grid>
          <Canvas x:Name="GraphCanvas" ClipToBounds="True"/>
          <TextBlock x:Name="SpeedText" Text="" FontSize="12" Foreground="$($T.GraphText)"
                     Margin="0,5,8,0" HorizontalAlignment="Right" VerticalAlignment="Top"/>
        </Grid>
      </Border>
      <TextBlock x:Name="NameText" Text="Name: " FontSize="12" Foreground="$($T.Text)" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="EtaText" Text="Time remaining: Calculating..." FontSize="12" Foreground="$($T.Text)" Margin="0,4,0,0"/>
      <TextBlock x:Name="ItemsText" Text="Items remaining: " FontSize="12" Foreground="$($T.Text)" Margin="0,4,0,0"/>
    </StackPanel>
    <TextBlock x:Name="ErrorText" Visibility="Collapsed" FontSize="12" Foreground="$($T.BarError)" TextWrapping="Wrap" Margin="0,6,0,0"/>
    <StackPanel x:Name="ActionPanel" Orientation="Horizontal" Visibility="Collapsed" Margin="0,10,0,4"/>
    <Border Height="1" Background="$($T.Separator)" Margin="-32,10,-32,0"/>
    <Button x:Name="DetailsToggle" Margin="0,0,0,0" Background="Transparent" Cursor="Hand" HorizontalAlignment="Left">
      <Button.Template>
        <ControlTemplate TargetType="Button">
          <Border Background="Transparent" Padding="0,8,12,8">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="Chevron" Text="&#xE70E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                         FontSize="10" Foreground="$($T.Text)" VerticalAlignment="Center" Margin="0,1,8,0"/>
              <ContentPresenter VerticalAlignment="Center" TextBlock.FontSize="12" TextBlock.Foreground="$($T.Text)"/>
            </StackPanel>
          </Border>
        </ControlTemplate>
      </Button.Template>
      Fewer details
    </Button>
  </StackPanel>
</Window>
"@
    return [Windows.Markup.XamlReader]::Parse($xaml)
}

# Accent-colored location name for the header. When a real folder backs it, it is
# a hyperlink that opens in Explorer, like the Windows dialog (underline on hover
# only). Built by a function so the click closure captures its parameters reliably.
function New-RtHeaderLink([string]$Name, [string]$Path, $Accent) {
    $run = New-Object Windows.Documents.Run $Name
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $run.Foreground = $Accent
        return $run
    }
    $link = New-Object Windows.Documents.Hyperlink $run
    $link.Foreground = $Accent
    $link.TextDecorations = $null
    $link.ToolTip = $Path
    $link.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $Path + '"') }.GetNewClosure())
    $link.Add_MouseEnter({ $link.TextDecorations = [Windows.TextDecorations]::Underline }.GetNewClosure())
    $link.Add_MouseLeave({ $link.TextDecorations = $null }.GetNewClosure())
    return $link
}

# Header in the real dialog's shape: "Copying 12,002 items from <src> to <dst>"
# with accent-colored, clickable names. Count starts as the selection count and is
# upgraded to the file count once the plan is known.
function Set-RtHeader($TextBlock, [hashtable]$T, [string]$Verb, [long]$Count, [string]$ItemWord, [string]$SrcName, [string]$DstName, [string]$SrcPath, [string]$DstPath) {
    $TextBlock.Inlines.Clear()
    $accent = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($T.Accent))
    $TextBlock.Inlines.Add((New-Object Windows.Documents.Run ("$Verb {0:N0} $ItemWord from " -f $Count)))
    $TextBlock.Inlines.Add((New-RtHeaderLink $SrcName $SrcPath $accent))
    $TextBlock.Inlines.Add((New-Object Windows.Documents.Run ' to '))
    $TextBlock.Inlines.Add((New-RtHeaderLink $DstName $DstPath $accent))
}

# Builds the OnProgress callback for Invoke-RtUndo. Must be a function: GetNewClosure
# captures only the calling scope's locals, so an inline literal created inside a
# click-handler closure silently loses $ui/$w and then dies setting Bar.Value on $null.
# Parameters of this function ARE locals, so the closure reliably captures them.
function New-RtUndoProgress([hashtable]$Ui, $Window, [string]$TextFormat) {
    return {
        param($pct, $what)
        $Ui.Bar.Value = [Math]::Min(1000, $pct * 10)
        if ($TextFormat) { $Ui.PercentText.Text = ($TextFormat -f $pct) }
        if ($Window) { $Window.Dispatcher.Invoke([Action]{}, 'Background') }
    }.GetNewClosure()
}

# Full operation UI. Returns final status string.
function Show-RtOperationUi([hashtable]$Op, [hashtable]$Settings, $Journal, [hashtable]$ResumeContext) {
    Initialize-RtWpf
    $T = Get-RtTheme
    $w = New-RtProgressWindow $T
    $ui = @{}
    foreach ($n in 'HeaderText','PercentText','PauseBtn','CancelBtn','Bar','DetailsPanel','GraphBorder','GraphCanvas','SpeedText','NameText','EtaText','ItemsText','ErrorText','ActionPanel','DetailsToggle') {
        $ui[$n] = $w.FindName($n)
    }

    $verb = switch ($Op.Mode) { 'move' { 'Moving' } 'mirror' { 'Mirroring' } default { 'Copying' } }
    $srcParent = Split-Path $Op.Sources[0].Path -Parent
    $srcName = if ($srcParent) { Split-Path $srcParent -Leaf } else { $Op.Sources[0].Path }
    if (-not $srcName) { $srcName = $Op.Sources[0].Path }
    $dstName = Get-RtLeafName $Op.Dest
    $itemWord = if ($Op.Sources.Count -eq 1) { 'item' } else { 'items' }
    Set-RtHeader $ui.HeaderText $T $verb $Op.Sources.Count $itemWord $srcName $dstName $srcParent $Op.Dest

    $ctx = @{
        Phase = 'plan'
        BgPs = $null; BgHandle = $null
        Plan = $null; State = $null
        FracPoints = New-Object System.Collections.Generic.List[double]
        RatePoints = New-Object System.Collections.Generic.List[double]
        LastSampleTime = $null; LastSampleBytes = [long]0
        SmoothedSpeed = 0.0; LastEtaText = ''; LastEtaUpdate = (Get-Date).AddDays(-1)
        FinalStatus = $null; CloseCountdown = -1; StagingResolved = $false
        Op = $Op; Settings = $Settings; Journal = $Journal
        Resume = $ResumeContext
        Verb = $verb; SrcName = $srcName; DstName = $dstName; ItemWord = $itemWord
        SrcParent = $srcParent
    }

    # bar vs graph visibility: expanded transfers show progress in the graph itself
    $updateChrome = {
        param($ctx, $ui, $Settings)
        $expanded = [bool]$Settings.detailsExpanded
        $ui.DetailsPanel.Visibility = if ($expanded) { 'Visible' } else { 'Collapsed' }
        $ui.DetailsToggle.Content = if ($expanded) { 'Fewer details' } else { 'More details' }
        # chevron mirrors the action like Windows: down = will expand, up = will collapse
        $null = $ui.DetailsToggle.ApplyTemplate()
        $chev = $ui.DetailsToggle.Template.FindName('Chevron', $ui.DetailsToggle)
        if ($chev) { $chev.Text = [string][char]$(if ($expanded) { 0xE70E } else { 0xE70D }) }
        $showBar = (-not $expanded) -or ($ctx.Phase -eq 'plan') -or ($ctx.Phase -eq 'undo')
        $ui.Bar.Visibility = if ($showBar) { 'Visible' } else { 'Collapsed' }
    }
    & $updateChrome $ctx $ui $Settings

    $ui.DetailsToggle.Add_Click({
        $Settings.detailsExpanded = -not [bool]$Settings.detailsExpanded
        Save-RtSettings $Settings
        & $updateChrome $ctx $ui $Settings
    }.GetNewClosure())

    # plan + protect in a background runspace so the window stays live on huge trees
    $startBackgroundPrep = {
        param($ctx)
        $common = Join-Path $script:RtSrcDir 'RobocopyTo.Common.ps1'
        $engine = Join-Path $script:RtSrcDir 'RobocopyTo.Engine.ps1'
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript(@'
param($common, $engine, $op, $settings, $journal, $skipPaths)
try {
    . $common; . $engine
    Initialize-RtEnvironment
    Open-RtLog $op.OpId
    $plan = Get-RtPlan $op $settings
    Write-RtPlanRecord $journal $plan
    $skip = $null
    if ($skipPaths) {
        $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $skipPaths) { [void]$skip.Add($p) }
    }
    $staged = Invoke-RtProtect $op $plan $journal $skip
    return @{ Plan = $plan; StagedCount = $staged.Count }
} catch {
    return @{ Error = $_.Exception.Message }
}
'@)
        $skipList = $null
        if ($ctx.Resume -and $ctx.Resume.SkipPaths) { $skipList = @($ctx.Resume.SkipPaths) }
        $null = $ps.AddArgument($common).AddArgument($engine).AddArgument($ctx.Op).AddArgument($ctx.Settings).AddArgument($ctx.Journal).AddArgument($skipList)
        $ctx.BgPs = $ps
        $ctx.BgHandle = $ps.BeginInvoke()
    }

    # ---- graph: x = progress fraction, y = throughput, fill under the curve ----
    $redrawGraph = {
        param($ctx, $ui, $T)
        $cv = $ui.GraphCanvas
        $cv.Children.Clear()
        $W = [Math]::Max(10.0, $cv.ActualWidth); $H = [Math]::Max(10.0, $cv.ActualHeight)
        $gridBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($T.GraphGrid))
        for ($g = 1; $g -le 8; $g++) {
            $ln = New-Object Windows.Shapes.Line
            $x = [Math]::Round($W * $g / 9.0)
            $ln.X1 = $x; $ln.X2 = $x; $ln.Y1 = 0; $ln.Y2 = $H
            $ln.Stroke = $gridBrush; $ln.StrokeThickness = 1
            [void]$cv.Children.Add($ln)
        }
        $n = $ctx.FracPoints.Count
        if ($n -lt 2) { return }
        $max = 1.0
        foreach ($r in $ctx.RatePoints) { if ($r -gt $max) { $max = $r } }
        $max *= 1.28
        $pts = New-Object Windows.Media.PointCollection
        $pts.Add((New-Object Windows.Point 0, $H))
        for ($i = 0; $i -lt $n; $i++) {
            $x = $W * $ctx.FracPoints[$i]
            $y = ($H - 4) - (($H - 8) * ($ctx.RatePoints[$i] / $max))
            $pts.Add((New-Object Windows.Point $x, $y))
        }
        $pts.Add((New-Object Windows.Point ($W * $ctx.FracPoints[$n - 1]), $H))
        $area = New-Object Windows.Shapes.Polygon
        $area.Points = $pts
        $area.Fill = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($T.GraphFill)))
        [void]$cv.Children.Add($area)
    }

    # ---- completion ----
    $showActions = {
        param($ctx, $ui, $w, $T, $buttons)
        $ui.ActionPanel.Children.Clear()
        foreach ($b in $buttons) {
            $btn = New-Object Windows.Controls.Button
            $btn.Content = $b.Label
            $btn.Style = $w.FindResource('ActionBtn')
            $btn.Add_Click($b.OnClick)
            [void]$ui.ActionPanel.Children.Add($btn)
        }
        $ui.ActionPanel.Visibility = 'Visible'
        $ui.PauseBtn.Visibility = 'Collapsed'
        $ui.CancelBtn.Visibility = 'Collapsed'
    }

    $enterDone = {
        param($ctx, $ui, $w, $T, $status, $showActionsFn, $updateChromeFn, $redrawGraphFn)
        $ctx.Phase = 'done'
        $ctx.FinalStatus = $status
        $st = $ctx.State
        $elapsed = if ($st) { $st.Stopwatch.Elapsed } else { [TimeSpan]::Zero }
        $bytes = [long]$(if ($st) { $st.BytesDone } else { 0 })
        $files = if ($st) { $st.FilesDone } else { 0 }
        $avg = if ($elapsed.TotalSeconds -gt 0.5) { Format-RtSpeed ($bytes / $elapsed.TotalSeconds) } else { '' }
        $verbPast = switch ($ctx.Op.Mode) { 'move' { 'Moved' } 'mirror' { 'Mirrored' } default { 'Copied' } }
        $closeClick = { $w.Close() }.GetNewClosure()
        $logPath = Join-Path $script:RtLogDir ($ctx.Op.OpId + '.log')
        $logClick = { if (Test-Path -LiteralPath $logPath) { Start-Process notepad.exe -ArgumentList ('"' + $logPath + '"') } }.GetNewClosure()

        $ui.Bar.IsIndeterminate = $false
        switch ($status) {
            'success' {
                $w.Title = '100% complete'
                $ui.Bar.Value = 1000
                $mins = [int][Math]::Floor($elapsed.TotalMinutes)
                $ui.PercentText.FontSize = 14
                $ui.PercentText.Text = "$verbPast $('{0:N0}' -f $files) items ($(Format-RtBytes $bytes)) in $mins`:$('{0:D2}' -f $elapsed.Seconds)" + $(if ($avg) { " - $avg average" } else { '' })
                $ui.NameText.Text = 'Done.'
                $ui.EtaText.Text = 'Time remaining: 0 seconds'
                $ui.ItemsText.Text = 'Items remaining: 0'
                # complete the throughput curve to the right edge: the x axis is the
                # whole operation, and the operation just reached 100%
                if ($ctx.FracPoints.Count -ge 1) {
                    $ctx.FracPoints.Add(1.0)
                    $ctx.RatePoints.Add($ctx.RatePoints[$ctx.RatePoints.Count - 1])
                    & $redrawGraphFn $ctx $ui $T
                }
                # like the Windows dialog: no buttons, the window closes by itself
                # (undo lives in the Robocopy context menu)
                $ui.PauseBtn.Visibility = 'Collapsed'
                $ui.CancelBtn.Visibility = 'Collapsed'
                $ctx.CloseCountdown = 8
            }
            default {
                $w.Title = 'Attention required'
                $ui.Bar.Foreground = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($T.BarError)))
                $failedN = if ($st) { $st.FailedFiles.Count } else { 0 }
                $ui.PercentText.FontSize = 14
                $ui.PercentText.Text = "$failedN item(s) could not be copied"
                if ($st -and $st.Errors.Count -gt 0) {
                    $ui.ErrorText.Text = $st.Errors[$st.Errors.Count - 1]
                    $ui.ErrorText.Visibility = 'Visible'
                }
                $resumeClick = {
                    try {
                        $rc = Get-RtResumeContext $ctx.Op.OpId
                        $newJournal = Open-RtJournal $ctx.Op.OpId
                        Write-RtJournal $newJournal @{ kind = 'resume' }
                        $ctx.StagingResolved = $true   # the resumed run owns staging now
                        $w.Close()
                        Show-RtOperationUi -Op $rc.Op -Settings $ctx.Settings -Journal $newJournal -ResumeContext $rc | Out-Null
                    } catch { $ui.ErrorText.Text = 'Resume failed: ' + $_.Exception.Message; $ui.ErrorText.Visibility = 'Visible' }
                }.GetNewClosure()
                $rollbackClick = {
                    $ui.ActionPanel.Visibility = 'Collapsed'
                    $ctx.Phase = 'undo'
                    & $updateChromeFn $ctx $ui $ctx.Settings
                    $ui.PercentText.Text = 'Rolling back...'
                    $ui.Bar.IsIndeterminate = $false
                    $ui.Bar.Value = 0
                    $w.Dispatcher.Invoke([Action]{}, 'Render')
                    try {
                        $r = Invoke-RtUndo -OpId $ctx.Op.OpId -Settings $ctx.Settings -OnProgress (New-RtUndoProgress $ui $w $null)
                        $ui.PercentText.Text = "Rolled back. $($r.Flagged.Count) item(s) flagged."
                    } catch { $ui.PercentText.Text = 'Rollback failed: ' + $_.Exception.Message }
                    # a rollback was attempted: never auto-purge what it could not restore
                    $ctx.StagingResolved = $true
                    & $showActionsFn $ctx $ui $w $T @(@{ Label = 'Close'; OnClick = $closeClick })
                    $ctx.Phase = 'done'
                }.GetNewClosure()
                $keepClick = {
                    # keeping the failed result settles the operation; staged originals
                    # of files that did get replaced go with it
                    Clear-RtOpStaging $ctx.Op.OpId $null
                    $ctx.StagingResolved = $true
                    $w.Close()
                }.GetNewClosure()
                & $showActionsFn $ctx $ui $w $T @(
                    @{ Label = 'Resume'; OnClick = $resumeClick },
                    @{ Label = 'Roll back'; OnClick = $rollbackClick },
                    @{ Label = 'View log'; OnClick = $logClick },
                    @{ Label = 'Keep as-is'; OnClick = $keepClick }
                )
            }
        }
    }

    # ---- pause / cancel ----
    # Cancels whatever is in flight and seamlessly reverts it: stop robocopy, journal
    # the terminal state, then undo everything this operation did so far (remove
    # created files, restore staged originals). Used by the Cancel button and by
    # closing the window mid-operation.
    $cancelOperation = {
        param($ctx, $ui, $w, $withProgress)
        if ($ctx.Phase -eq 'plan') {
            if ($ctx.BgPs) {
                try { $ctx.BgPs.Stop() } catch { }
                try { $ctx.BgPs.Dispose() } catch { }
                $ctx.BgPs = $null; $ctx.BgHandle = $null
            }
            Write-RtJournal $ctx.Journal @{ kind = 'footer'; status = 'cancelled'; note = 'cancelled during planning' }
            Close-RtJournal $ctx.Journal
        } elseif ($ctx.Phase -eq 'transfer' -and $ctx.State) {
            Stop-RtTransfer $ctx.State
            Complete-RtOperation $ctx.State 'cancelled'
        } else { return }
        $ctx.Phase = 'undo'
        $cb = if ($withProgress) { New-RtUndoProgress $ui $w 'Cancelling... {0}%' } else { $null }
        # nothing-to-undo (cancelled before any file landed) is fine - just close
        try { $null = Invoke-RtUndo -OpId $ctx.Op.OpId -Settings $ctx.Settings -OnProgress $cb } catch { }
        $ctx.StagingResolved = $true
        $ctx.FinalStatus = 'cancelled'
        $ctx.Phase = 'done'
    }

    $ui.PauseBtn.Add_Click({
        if ($ctx.Phase -ne 'transfer' -or -not $ctx.State) { return }
        if ($ctx.State.Paused) {
            Resume-RtTransfer $ctx.State
            $ui.PauseBtn.Content = [string][char]0xE769; $ui.PauseBtn.ToolTip = 'Pause'
        } else {
            Suspend-RtTransfer $ctx.State
            $ui.PauseBtn.Content = [string][char]0xE768; $ui.PauseBtn.ToolTip = 'Resume'
        }
    }.GetNewClosure())

    $ui.CancelBtn.Add_Click({
        if ($ctx.Phase -ne 'plan' -and $ctx.Phase -ne 'transfer') { return }
        $w.Title = 'Cancelling'
        $ui.PauseBtn.Visibility = 'Collapsed'
        $ui.CancelBtn.IsEnabled = $false
        $ui.DetailsPanel.Visibility = 'Collapsed'
        $ui.Bar.Visibility = 'Visible'
        $ui.Bar.IsIndeterminate = $false
        $ui.Bar.Value = 0
        $ui.PercentText.Text = 'Cancelling - putting things back...'
        $w.Dispatcher.Invoke([Action]{}, 'Render')
        & $cancelOperation $ctx $ui $w $true
        $w.Close()
    }.GetNewClosure())

    # ---- main tick ----
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        switch ($ctx.Phase) {
            'plan' {
                if ($ctx.BgHandle -and $ctx.BgHandle.IsCompleted) {
                    $result = $null
                    try { $result = ($ctx.BgPs.EndInvoke($ctx.BgHandle))[0] } catch { $result = @{ Error = $_.Exception.Message } }
                    $ctx.BgPs.Dispose(); $ctx.BgPs = $null; $ctx.BgHandle = $null
                    if ($result.Error) {
                        $ui.ErrorText.Text = $result.Error; $ui.ErrorText.Visibility = 'Visible'
                        Write-RtJournal $ctx.Journal @{ kind = 'footer'; status = 'failed'; error = $result.Error }
                        Close-RtJournal $ctx.Journal
                        & $enterDone $ctx $ui $w $T 'failed' $showActions $updateChrome $redrawGraph
                        return
                    }
                    $ctx.Plan = $result.Plan
                    Set-RtHeader $ui.HeaderText $T $ctx.Verb $ctx.Plan.TotalFiles $(if ($ctx.Plan.TotalFiles -eq 1) { 'item' } else { 'items' }) $ctx.SrcName $ctx.DstName $ctx.SrcParent $ctx.Op.Dest
                    if ($ctx.Plan.TotalFiles -eq 0) {
                        Write-RtJournal $ctx.Journal @{ kind = 'footer'; status = 'success'; note = 'nothing to copy' }
                        Close-RtJournal $ctx.Journal
                        $ctx.State = $null
                        & $enterDone $ctx $ui $w $T 'success' $showActions $updateChrome $redrawGraph
                        $ui.PercentText.Text = 'Everything is already up to date.'
                        return
                    }
                    $ctx.State = Start-RtTransfer $ctx.Op $ctx.Plan $ctx.Settings $ctx.Journal
                    $ctx.Phase = 'transfer'
                    & $updateChrome $ctx $ui $ctx.Settings
                    $ctx.LastSampleTime = Get-Date
                    $ctx.LastSampleBytes = 0
                    $ui.Bar.IsIndeterminate = $false
                }
            }
            'transfer' {
                $running = Step-RtTransfer $ctx.State
                $st = $ctx.State; $plan = $ctx.Plan
                $frac = if ($plan.TotalBytes -gt 0) { [Math]::Min(1.0, $st.BytesDone / [double]$plan.TotalBytes) } else { 1.0 }
                $pct = [int](100.0 * $frac)
                $ui.Bar.Value = $frac * 1000
                $w.Title = "$pct% complete"
                $ui.PercentText.Text = if ($st.Paused) { 'Paused' } else { "$pct% complete" }
                $now = Get-Date
                if ($ctx.LastSampleTime -and ($now - $ctx.LastSampleTime).TotalMilliseconds -ge 500) {
                    $dt = ($now - $ctx.LastSampleTime).TotalSeconds
                    $rate = if ($st.Paused) { 0.0 } else { [Math]::Max(0.0, ($st.BytesDone - $ctx.LastSampleBytes) / $dt) }
                    if ($ctx.FracPoints.Count -eq 0) { $rate = $rate * 0.6 }  # first sample swallows startup latency
                    $ctx.FracPoints.Add($frac); $ctx.RatePoints.Add($rate)
                    $ctx.LastSampleTime = $now; $ctx.LastSampleBytes = $st.BytesDone
                    if ($ctx.SmoothedSpeed -le 0) { $ctx.SmoothedSpeed = $rate } else { $ctx.SmoothedSpeed = 0.75 * $ctx.SmoothedSpeed + 0.25 * $rate }
                    $ui.SpeedText.Text = 'Speed: ' + (Format-RtSpeed $ctx.SmoothedSpeed)
                    & $redrawGraph $ctx $ui $T
                    $remBytes = [Math]::Max([long]0, [long]$plan.TotalBytes - [long]$st.BytesDone)
                    $remItems = [Math]::Max(0, [int]$plan.TotalFiles - [int]$st.FilesDone)
                    $ui.ItemsText.Text = ('Items remaining: {0:N0} ({1})' -f $remItems, (Format-RtBytes $remBytes))
                    if (-not $st.Paused -and $ctx.SmoothedSpeed -gt 1) {
                        $etaText = 'Time remaining: ' + (Format-RtEta ($remBytes / $ctx.SmoothedSpeed))
                        if (($now - $ctx.LastEtaUpdate).TotalSeconds -ge 2 -or $ctx.LastEtaText -eq '') {
                            $ui.EtaText.Text = $etaText; $ctx.LastEtaText = $etaText; $ctx.LastEtaUpdate = $now
                        }
                    }
                    if ($st.CurrentFile) { $ui.NameText.Text = 'Name: ' + (Split-Path $st.CurrentFile.Src -Leaf) }
                }
                if (-not $running) {
                    if ($st.Cancelled) { return }   # cancel reverts and closes in its own handler
                    $exit = Get-RtWorstExit $st
                    $status = if ($exit -ge 8 -or $st.FailedFiles.Count -gt 0) { 'failed' } else { 'success' }
                    Complete-RtOperation $st $status
                    & $enterDone $ctx $ui $w $T $status $showActions $updateChrome $redrawGraph
                }
            }
            'done' {
                if ($ctx.CloseCountdown -gt 0) {
                    $ctx.CloseCountdown--
                    if ($ctx.CloseCountdown -eq 0) { $w.Close() }
                }
            }
        }
    }.GetNewClosure())

    $w.Add_SourceInitialized({ Set-RtDarkTitlebar $w $T.IsDark }.GetNewClosure())
    $w.Add_Closed({
        if ($ctx.Phase -eq 'plan' -or $ctx.Phase -eq 'transfer') {
            # closing the window mid-operation = cancel: revert, leave nothing behind
            & $cancelOperation $ctx $ui $w $false
        } elseif ($ctx.FinalStatus -eq 'failed' -and -not $ctx.StagingResolved) {
            # closing the attention screen keeps the result as-is: settle staging
            Clear-RtOpStaging $ctx.Op.OpId $null
        }
        $timer.Stop()
    }.GetNewClosure())

    & $startBackgroundPrep $ctx
    $timer.Start()
    $null = $w.ShowDialog()
    return $ctx.FinalStatus
}

