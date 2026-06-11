# RobocopyTo.Settings.ps1 - settings + history window.
# Library file: dot-sourced by RobocopyTo.psm1. ASCII-only source.
#
# Light mode: deliberately unstyled - default system control rendering so the
# window reads as a plain native Windows dialog (no custom templates or tints).
# Dark mode: the same structure with the shared dark palette applied through
# plain property styles (neutral selection, no accent chips) + dark titlebar.

$script:RtVersion = '1.0.6'

# Builds the window XAML for a given theme. Factored out so tests can parse both
# theme variants without showing a window.
function New-RtSettingsWindowXaml([hashtable]$T) {
    $bg    = if ($T.IsDark) { $T.WindowBg }      else { '{x:Static SystemColors.ControlBrush}' }
    $fg    = if ($T.IsDark) { $T.Text }          else { '{x:Static SystemColors.ControlTextBrush}' }
    $muted = if ($T.IsDark) { $T.TextSecondary } else { '{x:Static SystemColors.GrayTextBrush}' }
    $darkStyles = ''
    if ($T.IsDark) {
        # Plain property styles only. TextBlock foregrounds are set inline (an
        # implicit TextBlock style would leak into control templates such as the
        # ListView column headers); GridViewColumnHeader keeps dark text because
        # its chrome stays light; ComboBox stays default - its popup cannot be
        # recolored safely without custom templates.
        $darkStyles = @"
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="$($T.Text)"/></Style>
    <Style TargetType="GroupBox"><Setter Property="Foreground" Value="$($T.Text)"/><Setter Property="BorderBrush" Value="$($T.BtnBorder)"/></Style>
    <Style TargetType="Button"><Setter Property="Background" Value="$($T.BtnBg)"/><Setter Property="Foreground" Value="$($T.Text)"/><Setter Property="BorderBrush" Value="$($T.BtnBorder)"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="$($T.BtnBg)"/><Setter Property="Foreground" Value="$($T.Text)"/><Setter Property="BorderBrush" Value="$($T.BtnBorder)"/></Style>
    <Style TargetType="ListView"><Setter Property="Background" Value="$($T.BtnBg)"/><Setter Property="Foreground" Value="$($T.Text)"/><Setter Property="BorderBrush" Value="$($T.BtnBorder)"/></Style>
    <Style TargetType="GridViewColumnHeader"><Setter Property="Foreground" Value="#1B1B1B"/></Style>
    <Style TargetType="Hyperlink"><Setter Property="Foreground" Value="$($T.Accent)"/></Style>
    <Style TargetType="TabControl"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/></Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="$($T.TextSecondary)"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" Padding="12,6,12,6" Margin="0,0,2,0" CornerRadius="4">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="$($T.BtnBg)"/>
                <Setter Property="Foreground" Value="$($T.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
"@
    }
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RobocopyTo" Width="620" Height="520" ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen"
        Background="$bg">
  <Window.Resources>
$darkStyles
  </Window.Resources>
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TabControl x:Name="Tabs">
      <TabItem Header="General">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="10">
            <GroupBox Header="Transfer" Padding="8">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Multithreading:" Foreground="$fg" VerticalAlignment="Center" Width="160"/>
                  <ComboBox x:Name="Threads" Width="210" SelectedValuePath="Tag">
                    <ComboBoxItem Tag="auto">Automatic (recommended)</ComboBoxItem>
                    <ComboBoxItem Tag="off">Off - smoothest progress</ComboBoxItem>
                    <ComboBoxItem Tag="8">8 threads</ComboBoxItem>
                    <ComboBoxItem Tag="16">16 threads</ComboBoxItem>
                    <ComboBoxItem Tag="32">32 threads</ComboBoxItem>
                  </ComboBox>
                </StackPanel>
                <CheckBox x:Name="Restartable" Margin="0,8,0,0" Content="Restartable mode (/Z) - resumes inside huge files, slightly slower"/>
                <CheckBox x:Name="XJ" Margin="0,6,0,0" Content="Skip junctions and symlinks (/XJ) - protects against folder loops"/>
                <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                  <TextBlock Text="Extra robocopy options:" Foreground="$fg" VerticalAlignment="Center" Width="160"/>
                  <TextBox x:Name="ExtraArgs" Width="300"/>
                </StackPanel>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="Safety" Padding="8" Margin="0,10,0,0">
              <StackPanel>
                <CheckBox x:Name="ConfirmMirror" Content="Confirm before Mirror (recommended)"/>
                <CheckBox x:Name="ConfirmMove" Margin="0,6,0,0" Content="Confirm before Move"/>
                <TextBlock Margin="0,10,0,0" TextWrapping="Wrap" Foreground="$muted"
                           Text="Transfers never leave copies behind: originals are protected only while an operation is running, so Cancel can put everything back exactly as it was."/>
              </StackPanel>
            </GroupBox>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="History">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <ListView x:Name="HistoryList">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="When" Width="115" DisplayMemberBinding="{Binding When}"/>
                <GridViewColumn Header="Action" Width="60" DisplayMemberBinding="{Binding Op}"/>
                <GridViewColumn Header="Items" Width="50" DisplayMemberBinding="{Binding Files}"/>
                <GridViewColumn Header="Size" Width="70" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Status" Width="80" DisplayMemberBinding="{Binding Status}"/>
                <GridViewColumn Header="From - To" Width="220" DisplayMemberBinding="{Binding FromTo}"/>
              </GridView>
            </ListView.View>
          </ListView>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8,0,0">
            <Button x:Name="UndoBtn" Content="Undo selected" Padding="10,2" Margin="0,0,8,0"/>
            <Button x:Name="OpenLogBtn" Content="Open log" Padding="10,2" Margin="0,0,8,0"/>
            <TextBlock x:Name="HistoryStatus" VerticalAlignment="Center" Foreground="$muted"/>
          </StackPanel>
        </Grid>
      </TabItem>
      <TabItem Header="About">
        <StackPanel Margin="14">
          <TextBlock Text="RobocopyTo" Foreground="$fg" FontSize="18"/>
          <TextBlock x:Name="VersionText" Foreground="$muted" Margin="0,4,0,0"/>
          <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" Foreground="$fg"
                     Text="Explorer context-menu copy, mirror, move and paste powered by Robocopy: resumable, multithreaded, long-path safe - journaled, with undo in the context menu and a native-style progress dialog."/>
          <TextBlock Margin="0,12,0,0"><Hyperlink x:Name="RepoLink">Project page (GitHub)</Hyperlink></TextBlock>
          <TextBlock Margin="0,6,0,0"><Hyperlink x:Name="LogsLink">Open data folder (logs, journals, settings)</Hyperlink></TextBlock>
          <Button x:Name="UninstallBtn" Content="Uninstall RobocopyTo..." Padding="10,2" Margin="0,20,0,0" HorizontalAlignment="Left"/>
          <TextBlock Margin="0,6,0,0" TextWrapping="Wrap" Foreground="$muted"
                     Text="Removes the context menu, the app files, and the package certificate trust. Your files are never touched."/>
        </StackPanel>
      </TabItem>
    </TabControl>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="SaveBtn" Content="Save" Padding="16,3" Margin="0,0,8,0"/>
      <Button x:Name="CloseBtn" Content="Close" Padding="16,3"/>
    </StackPanel>
  </Grid>
</Window>
"@
}

function Show-RtSettingsWindow {
    Initialize-RtWpf
    $T = Get-RtTheme
    $settings = Get-RtSettings
    $w = [Windows.Markup.XamlReader]::Parse((New-RtSettingsWindowXaml $T))
    $ui = @{}
    foreach ($n in 'Tabs','Threads','Restartable','XJ','ExtraArgs','ConfirmMirror','ConfirmMove',
                   'HistoryList','UndoBtn','OpenLogBtn','HistoryStatus',
                   'VersionText','RepoLink','LogsLink','UninstallBtn','SaveBtn','CloseBtn') {
        $ui[$n] = $w.FindName($n)
    }

    # load current values
    $ui.Threads.SelectedValue = [string]$settings.threadsPolicy
    if (-not $ui.Threads.SelectedValue) { $ui.Threads.SelectedIndex = 0 }
    $ui.Restartable.IsChecked = [bool]$settings.restartableMode
    $ui.XJ.IsChecked = [bool]$settings.excludeJunctions
    $ui.ExtraArgs.Text = (@($settings.extraArgs) -join ' ')
    $ui.ConfirmMirror.IsChecked = [bool]$settings.confirmMirror
    $ui.ConfirmMove.IsChecked = [bool]$settings.confirmMove
    $ui.VersionText.Text = "Version $script:RtVersion - MIT licensed, no telemetry"

    $refreshHistory = {
        param($ui)
        $rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        foreach ($j in (Get-RtJournalList | Select-Object -First 30)) {
            $d = Get-RtJournalDigest $j.FullName
            if (-not $d) { continue }
            $rows.Add([pscustomobject]@{
                When = $j.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                Op = $d.Op; Files = $d.Files
                Size = (Format-RtBytes $d.Bytes)
                Status = $d.Status
                FromTo = ((@($d.Sources) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + ' - ' + $d.Dest
                OpId = $d.OpId
            })
        }
        $ui.HistoryList.ItemsSource = $rows
    }
    & $refreshHistory $ui

    $ui.UndoBtn.Add_Click({
        $sel = $ui.HistoryList.SelectedItem
        if (-not $sel) { $ui.HistoryStatus.Text = 'Select an operation first.'; return }
        $records = Read-RtJournal $sel.OpId
        $check = Test-RtUndoable $records
        if (-not $check.Ok) { $ui.HistoryStatus.Text = $check.Reason; return }
        if ([Windows.MessageBox]::Show("Undo this $($sel.Op) operation?", 'Undo - RobocopyTo', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.HistoryStatus.Text = 'Undoing...'
        $w.Dispatcher.Invoke([Action]{}, 'Render')
        try {
            $settingsNow = Get-RtSettings
            $r = Invoke-RtUndo -OpId $sel.OpId -Settings $settingsNow -OnProgress $null
            $ui.HistoryStatus.Text = "Undone ($($r.Flagged.Count) item(s) kept and flagged)."
        } catch { $ui.HistoryStatus.Text = 'Undo failed: ' + $_.Exception.Message }
        & $refreshHistory $ui
    }.GetNewClosure())

    $ui.OpenLogBtn.Add_Click({
        $sel = $ui.HistoryList.SelectedItem
        if (-not $sel) { return }
        $log = Join-Path $script:RtLogDir ($sel.OpId + '.log')
        if (Test-Path -LiteralPath $log) { Start-Process notepad.exe -ArgumentList ('"' + $log + '"') }
        else { $ui.HistoryStatus.Text = 'No log for this operation.' }
    }.GetNewClosure())

    $ui.RepoLink.Add_Click({ Start-Process 'https://github.com/eduardluca94/RobocopyTo' })
    $ui.LogsLink.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $script:RtAppDir + '"') }.GetNewClosure())

    $ui.SaveBtn.Add_Click({
        $s = Get-RtSettings
        $s.threadsPolicy = [string]$ui.Threads.SelectedValue
        $s.restartableMode = [bool]$ui.Restartable.IsChecked
        $s.excludeJunctions = [bool]$ui.XJ.IsChecked
        $s.extraArgs = @($ui.ExtraArgs.Text -split '\s+' | Where-Object { $_ })
        $s.confirmMirror = [bool]$ui.ConfirmMirror.IsChecked
        $s.confirmMove = [bool]$ui.ConfirmMove.IsChecked
        Save-RtSettings $s
        $w.Title = 'RobocopyTo - saved'
    }.GetNewClosure())

    $ui.UninstallBtn.Add_Click({
        $installDir = (Get-ItemProperty 'HKCU:\Software\RobocopyTo' -ErrorAction SilentlyContinue).InstallDir
        if (-not $installDir) { $installDir = Join-Path $env:LOCALAPPDATA 'RobocopyTo\app' }
        $unins = Join-Path $installDir 'uninstall.ps1'
        if (-not (Test-Path -LiteralPath $unins)) {
            [void][Windows.MessageBox]::Show('No installed copy was found (running from a source checkout?).', 'Uninstall - RobocopyTo', 'OK', 'Information')
            return
        }
        $m = [Windows.MessageBox]::Show(
            "Remove RobocopyTo from this PC?`n`nThis removes the context menu entries, the app files, and the package certificate trust (one admin prompt).",
            'Uninstall - RobocopyTo', 'YesNo', 'Warning', 'No')
        if ($m -ne 'Yes') { return }
        $purge = [Windows.MessageBox]::Show(
            "Also delete the operation history, logs and settings?`n`nChoose No to keep them in $env:LOCALAPPDATA\RobocopyTo.",
            'Uninstall - RobocopyTo', 'YesNo', 'Question', 'No')
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $unins, '-RemoveTrust', '-Pause')
        if ($purge -eq 'Yes') { $psArgs += '-Purge' }
        # detached so the uninstaller outlives this window; close right away to
        # release our file locks before it sweeps the app folder
        Start-Process powershell -ArgumentList $psArgs
        $w.Close()
    }.GetNewClosure())

    $ui.CloseBtn.Add_Click({ $w.Close() }.GetNewClosure())
    $w.Add_SourceInitialized({ Set-RtDarkTitlebar $w $T.IsDark }.GetNewClosure())
    $null = $w.ShowDialog()
}
