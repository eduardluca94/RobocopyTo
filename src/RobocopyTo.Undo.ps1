# RobocopyTo.Undo.ps1 - journal-driven resume, rollback and undo.
# Library file: dot-source after Common + Engine. ASCII-only source.
#
# Undo semantics per mode:
#   copy/mirror : delete files the operation created (guarded: size, and mtime when
#                 recorded, must still match the journal - modified files are flagged
#                 and kept), restore staged originals, remove created dirs if empty.
#   move        : move files back to their source paths (recreating source dirs),
#                 restore staged originals at the destination, remove created dirs.

function Get-RtOperationSummary([object[]]$Records) {
    $header = $Records | Where-Object { $_.kind -eq 'header' } | Select-Object -First 1
    $footer = $Records | Where-Object { $_.kind -eq 'footer' } | Select-Object -Last 1
    $plan   = $Records | Where-Object { $_.kind -eq 'plan' }   | Select-Object -First 1
    $undone = $Records | Where-Object { $_.kind -eq 'undone' } | Select-Object -Last 1
    $status = 'interrupted'
    if ($undone) { $status = 'undone' }
    elseif ($footer) { $status = $footer.status }
    $done = @($Records | Where-Object { $_.kind -eq 'fileDone' })
    $bytes = 0L; foreach ($d in $done) { $bytes += [long]$d.size }
    return @{
        Header = $header; Footer = $footer; Plan = $plan; Status = $status
        FilesDone = $done.Count; BytesDone = $bytes
        Failed = @($Records | Where-Object { $_.kind -eq 'fileFailed' }).Count
        StagedCount = @($Records | Where-Object { $_.kind -eq 'staged' }).Count
    }
}

function Test-RtUndoable([object[]]$Records) {
    $s = Get-RtOperationSummary $Records
    if ($s.Status -eq 'undone') { return @{ Ok = $false; Reason = 'Already undone.' } }
    if (-not $s.Header) { return @{ Ok = $false; Reason = 'Journal has no header.' } }
    if ($s.FilesDone -eq 0 -and $s.StagedCount -eq 0) { return @{ Ok = $false; Reason = 'Nothing to undo.' } }
    return @{ Ok = $true; Reason = '' }
}

# Builds the concrete reverse-action list for an operation. Used by Invoke-RtUndo and by tests.
# Once staging has been purged (operation settled), files that replaced existing ones
# are NOT deleted - the original is unrecoverable, so deleting would turn an undo into
# data loss. They become 'keepReplaced' actions (kept + flagged) instead.
function Get-RtUndoActions([object[]]$Records) {
    $header = $Records | Where-Object { $_.kind -eq 'header' } | Select-Object -First 1
    $plan   = $Records | Where-Object { $_.kind -eq 'plan' }   | Select-Object -First 1
    $isMove = ($header.op -eq 'move')
    $purged = [bool]($Records | Where-Object { $_.kind -eq 'stagingPurged' } | Select-Object -First 1)
    $stagedFrom = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @($Records | Where-Object { $_.kind -eq 'staged' })) { [void]$stagedFrom.Add([string]$s.from) }
    $actions = New-Object System.Collections.Generic.List[object]

    # 1) reverse fileDone records (newest first so nested content goes before parents)
    $done = @($Records | Where-Object { $_.kind -eq 'fileDone' })
    [array]::Reverse($done)
    foreach ($d in $done) {
        if ($isMove) {
            $actions.Add(@{ Act = 'moveBack'; From = $d.dest; To = $d.src; Size = [long]$d.size; Mtime = $d.mtime })
        } elseif ($purged -and $stagedFrom.Contains([string]$d.dest)) {
            $actions.Add(@{ Act = 'keepReplaced'; Path = $d.dest })
        } else {
            $actions.Add(@{ Act = 'deleteCreated'; Path = $d.dest; Size = [long]$d.size; Mtime = $d.mtime })
        }
    }
    # 2) restore staged originals (after created files at those paths are gone);
    #    pointless once staging was purged
    if (-not $purged) {
        foreach ($s in @($Records | Where-Object { $_.kind -eq 'staged' })) {
            $actions.Add(@{ Act = 'restoreStaged'; From = $s.to; To = $s.from; Type = $s.type })
        }
    }
    # 3) remove created destination dirs, deepest first, only when empty
    if ($plan -and $plan.destDirs) {
        $dirs = @($plan.destDirs) | Sort-Object { $_.Length } -Descending
        foreach ($d in $dirs) { $actions.Add(@{ Act = 'removeDirIfEmpty'; Path = $d }) }
    }
    return ,$actions.ToArray()
}

# Executes undo. $OnProgress: scriptblock receiving (percentComplete, statusText).
# Returns @{ Done; Flagged (list of @{Path; Reason}); NewOpId }
function Invoke-RtUndo([string]$OpId, [hashtable]$Settings, [scriptblock]$OnProgress, [switch]$Force) {
    $records = Read-RtJournal $OpId
    $check = Test-RtUndoable $records
    if (-not $check.Ok) { throw "Cannot undo: $($check.Reason)" }
    $header = $records | Where-Object { $_.kind -eq 'header' } | Select-Object -First 1
    $actions = Get-RtUndoActions $records

    $undoOpId = New-RtOpId
    Open-RtLog $undoOpId
    $journal = Open-RtJournal $undoOpId
    Write-RtJournal $journal @{ kind = 'header'; op = 'undo'; refOp = $OpId; opId = $undoOpId
                                sources = @($header.sources); dest = $header.dest }
    $flagged = New-Object System.Collections.Generic.List[object]
    $doneCount = 0; $total = [Math]::Max(1, $actions.Count)

    foreach ($a in $actions) {
        $doneCount++
        # progress is cosmetic: a broken callback must never abort a half-done undo
        if ($OnProgress) { try { & $OnProgress ([int](100 * $doneCount / $total)) $a.Act } catch { } }
        try {
            switch ($a.Act) {
                'deleteCreated' {
                    if (-not (Test-Path -LiteralPath $a.Path)) { break }
                    $item = Get-Item -LiteralPath $a.Path -Force
                    $modified = ($item.Length -ne $a.Size)
                    if (-not $modified -and $a.Mtime) {
                        $cur = $item.LastWriteTimeUtc.ToString('o')
                        if ($cur -ne [string]$a.Mtime) { $modified = $true }
                    }
                    if ($modified -and -not $Force) {
                        $flagged.Add(@{ Path = $a.Path; Reason = 'Modified since the copy; kept.' })
                        Write-RtJournal $journal @{ kind = 'skippedModified'; path = $a.Path }
                        break
                    }
                    [void][RobocopyTo.Native]::DeleteFileW([RobocopyTo.Native]::Extend($a.Path))
                    Write-RtJournal $journal @{ kind = 'deleted'; path = $a.Path }
                }
                'moveBack' {
                    if (-not (Test-Path -LiteralPath $a.From)) {
                        $flagged.Add(@{ Path = $a.From; Reason = 'Moved file no longer at destination; skipped.' })
                        break
                    }
                    if (Test-Path -LiteralPath $a.To) {
                        $flagged.Add(@{ Path = $a.To; Reason = 'Source path now occupied; skipped.' })
                        break
                    }
                    [RobocopyTo.Native]::EnsureDirectory((Split-Path $a.To -Parent))
                    [RobocopyTo.Native]::Rename($a.From, $a.To)
                    Write-RtJournal $journal @{ kind = 'movedBack'; from = $a.From; to = $a.To }
                }
                'restoreStaged' {
                    if (-not (Test-Path -LiteralPath $a.From)) {
                        $flagged.Add(@{ Path = $a.From; Reason = 'Staged original missing (staging purged?); skipped.' })
                        break
                    }
                    if (Test-Path -LiteralPath $a.To) {
                        $flagged.Add(@{ Path = $a.To; Reason = 'Original path occupied; staged copy kept in staging.' })
                        break
                    }
                    [RobocopyTo.Native]::EnsureDirectory((Split-Path $a.To -Parent))
                    [RobocopyTo.Native]::Rename($a.From, $a.To)
                    Write-RtJournal $journal @{ kind = 'restored'; from = $a.From; to = $a.To }
                }
                'removeDirIfEmpty' {
                    if ((Test-Path -LiteralPath $a.Path) -and
                        -not (Get-ChildItem -LiteralPath $a.Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                        [void][RobocopyTo.Native]::RemoveDirectoryW([RobocopyTo.Native]::Extend($a.Path))
                        Write-RtJournal $journal @{ kind = 'dirRemoved'; path = $a.Path }
                    }
                }
                'keepReplaced' {
                    $flagged.Add(@{ Path = $a.Path; Reason = 'Replaced an existing file; the original is gone, so it was kept.' })
                    Write-RtJournal $journal @{ kind = 'replacedKept'; path = $a.Path }
                }
            }
        } catch {
            $flagged.Add(@{ Path = ('' + $a.Path + $a.From); Reason = $_.Exception.Message })
            Write-RtJournal $journal @{ kind = 'undoError'; action = $a.Act; error = $_.Exception.Message }
        }
    }

    Write-RtJournal $journal @{ kind = 'footer'; status = 'success'; flagged = $flagged.Count }
    Close-RtJournal $journal
    # mark the original operation as undone (append a record to its journal)
    $orig = Open-RtJournal $OpId
    Write-RtJournal $orig @{ kind = 'undone'; by = $undoOpId }
    Close-RtJournal $orig
    # staging is consumed by the restore; drop emptied staging dirs so nothing lingers.
    # A dir that still holds files means something could not be restored (flagged above)
    # - that is user data, so it stays put.
    foreach ($r in @($records | Where-Object { $_.kind -eq 'stagingRoot' } | ForEach-Object { $_.path })) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            if (-not @(Get-ChildItem -LiteralPath $r -Recurse -Force -File -ErrorAction SilentlyContinue).Count) {
                Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Update-RtLastOpMarker
    return @{ Done = $doneCount; Flagged = $flagged; NewOpId = $undoOpId }
}

# Recomputes the context-menu Undo marker: the newest operation that is still
# undoable, or empty when there is none.
function Update-RtLastOpMarker {
    foreach ($j in Get-RtJournalList) {
        try {
            $d = Get-RtJournalDigest $j.FullName
            if (-not $d -or $d.Op -eq 'undo' -or $d.Status -eq 'undone') { continue }
            $records = Read-RtJournal $j.FullName
            if ((Test-RtUndoable $records).Ok) {
                Set-RtLastOpMarker $d.OpId $d.Op
                return
            }
        } catch { }
    }
    Set-RtLastOpMarker '' ''
}

# Context for resuming an interrupted operation under its original opId:
# the rebuilt Op plus the set of dest paths whose originals are already staged.
function Get-RtResumeContext([string]$OpId) {
    $records = Read-RtJournal $OpId
    $header = $records | Where-Object { $_.kind -eq 'header' } | Select-Object -First 1
    if (-not $header) { throw "Journal $OpId has no header." }
    $undone = $records | Where-Object { $_.kind -eq 'undone' } | Select-Object -Last 1
    if ($undone) { throw 'Operation was undone; start a fresh copy instead.' }
    # a fully-moved source root no longer exists - resume what is left
    $remaining = @($header.sources | Where-Object { Test-Path -LiteralPath $_ })
    if ($remaining.Count -eq 0) { throw 'Nothing left to resume: all sources were fully transferred.' }
    $op = New-RtOperation -Mode $header.op -Sources $remaining -Destination $header.dest -OpId $OpId
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @($records | Where-Object { $_.kind -eq 'staged' })) { [void]$skip.Add([string]$s.from) }
    return @{ Op = $op; SkipPaths = $skip }
}
