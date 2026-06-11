# RobocopyTo.Launch.ps1 - entry point for every shell verb. Launched hidden
# (no console) by the launcher exe or the native menu DLL:
#   powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File RobocopyTo.Launch.ps1
#       -Verb copyto|mirrorto|moveto|paste|settings|undo -Path <item> [-PathFile <list>] [-Destination <dir>]
# ASCII-only source.
param(
    [ValidateSet('copyto', 'mirrorto', 'moveto', 'paste', 'settings', 'undo')]
    [string]$Verb = 'settings',
    [string]$Path,
    [string]$PathFile,
    [string]$Destination   # bypasses the folder picker (used by tests)
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RobocopyTo.psm1') -Force

function Show-RtError([string]$Message) {
    Initialize-RtWpf
    [void][Windows.MessageBox]::Show($Message, 'RobocopyTo', 'OK', 'Error')
}
function Show-RtInfo([string]$Message) {
    Initialize-RtWpf
    [void][Windows.MessageBox]::Show($Message, 'RobocopyTo', 'OK', 'Information')
}

try {
    Initialize-RtEnvironment
    $settings = Get-RtSettings

    # resolve selected paths (multi-select arrives via a temp path file from the DLL)
    $sources = @()
    if ($PathFile -and (Test-Path -LiteralPath $PathFile)) {
        $sources = @([System.IO.File]::ReadAllLines($PathFile) | Where-Object { $_ })
        Remove-Item -LiteralPath $PathFile -Force -ErrorAction SilentlyContinue
    } elseif ($Path) {
        $sources = @($Path)
    }

    switch ($Verb) {
        { $_ -in 'copyto', 'mirrorto', 'moveto' } {
            if ($sources.Count -eq 0) { Show-RtError 'Nothing was selected.'; exit 1 }
            $mode = switch ($Verb) { 'mirrorto' { 'mirror' } 'moveto' { 'move' } default { 'copy' } }
            $first = Get-RtNormalizedPath $sources[0]
            $what = if ($sources.Count -eq 1) { "'" + (Split-Path $first -Leaf) + "'" } else { "$($sources.Count) items" }

            $dest = $Destination
            if (-not $dest) {
                $verbWord = switch ($mode) { 'mirror' { 'Mirror' } 'move' { 'Move' } default { 'Copy' } }
                $dest = [RobocopyTo.FolderPicker]::Pick("$verbWord $what to...", $verbWord, [IntPtr]::Zero)
                if (-not $dest) { exit 0 }  # cancelled
            }
            Initialize-RtWpf   # destination chosen: the dialog (and confirms) need WPF now

            $op = New-RtOperation -Mode $mode -Sources $sources -Destination $dest

            if ($mode -eq 'mirror' -and $settings.confirmMirror) {
                $msg = "Make `"$($op.Dest)`" an exact mirror of $what`?`n`n" +
                       'Files in the destination that are not in the source will be removed. ' +
                       'Cancelling during the transfer puts everything back.'
                if ([Windows.MessageBox]::Show($msg, 'Mirror with RobocopyTo', 'YesNo', 'Warning', 'No') -ne 'Yes') { exit 0 }
            }
            if ($mode -eq 'move' -and $settings.confirmMove) {
                if ([Windows.MessageBox]::Show("Move $what to `"$($op.Dest)`"?", 'Move with RobocopyTo', 'YesNo', 'Question') -ne 'Yes') { exit 0 }
            }

            Open-RtLog $op.OpId
            $journal = Open-RtJournal $op.OpId
            Write-RtJournal $journal @{ kind = 'header'; op = $op.Mode; opId = $op.OpId
                                        sources = @($op.Sources | ForEach-Object { $_.Path }); dest = $op.Dest }
            $null = Show-RtOperationUi -Op $op -Settings $settings -Journal $journal -ResumeContext $null
        }

        'paste' {
            if ($sources.Count -eq 0) { Show-RtError 'No destination folder.'; exit 1 }
            $dest = Get-RtNormalizedPath $sources[0]
            $clip = Get-RtClipboardPaste
            if (-not $clip) { Show-RtInfo 'There are no files or folders on the clipboard.'; exit 0 }

            # drop items already in this folder (and impossible self-parents)
            $usable = @()
            foreach ($f in $clip.Files) {
                $p = Get-RtNormalizedPath $f
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $parent = Split-Path $p -Parent
                if ($parent -ieq $dest) { continue }
                if (-not (Test-Path -LiteralPath $p -PathType Leaf) -and (Test-RtSubPath $p $dest)) { continue }
                $usable += $p
            }
            if ($usable.Count -eq 0) { Show-RtInfo 'Those items are already in this folder.'; exit 0 }

            $mode = if ($clip.IsMove) { 'move' } else { 'copy' }
            $op = New-RtOperation -Mode $mode -Sources $usable -Destination $dest
            Open-RtLog $op.OpId
            $journal = Open-RtJournal $op.OpId
            Write-RtJournal $journal @{ kind = 'header'; op = $op.Mode; opId = $op.OpId; paste = $true
                                        sources = @($op.Sources | ForEach-Object { $_.Path }); dest = $op.Dest }
            $status = Show-RtOperationUi -Op $op -Settings $settings -Journal $journal -ResumeContext $null
            if ($status -eq 'success' -and $clip.IsMove) {
                try { [Windows.Clipboard]::Clear() } catch { }   # Explorer clears the clipboard after a cut-paste too
            }
        }

        'settings' {
            Show-RtSettingsWindow
        }

        'undo' {
            Initialize-RtWpf
            # undo the most recent operation that is still undoable
            $target = $null
            foreach ($j in Get-RtJournalList) {
                $records = Read-RtJournal $j.FullName
                $sum = Get-RtOperationSummary $records
                if ($sum.Status -in 'success', 'interrupted', 'failed', 'cancelled' -and $sum.Header -and $sum.Header.op -ne 'undo') {
                    $check = Test-RtUndoable $records
                    if ($check.Ok) { $target = @{ Id = [System.IO.Path]::GetFileNameWithoutExtension($j.Name); Sum = $sum }; break }
                }
            }
            if (-not $target) { Update-RtLastOpMarker; Show-RtInfo 'Nothing to undo.'; exit 0 }
            $h = $target.Sum.Header
            $msg = "Undo the last operation?`n`n$($h.op): $(@($h.sources) -join ', ')`n-> $($h.dest)"
            if ([Windows.MessageBox]::Show($msg, 'Undo - RobocopyTo', 'YesNo', 'Question') -ne 'Yes') { exit 0 }
            $r = Invoke-RtUndo -OpId $target.Id -Settings $settings -OnProgress $null
            $note = if ($r.Flagged.Count -gt 0) { "`n$($r.Flagged.Count) item(s) were kept (they replaced existing files, changed since, or were in the way)." } else { '' }
            Show-RtInfo ("Undone." + $note)
        }
    }
    # hygiene runs after the work, never in front of the picker
    Clear-RtResidue $settings
    exit 0
} catch {
    try { Show-RtError ("RobocopyTo: " + $_.Exception.Message) } catch { }
    exit 99
}
