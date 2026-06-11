# RobocopyTo.Engine.ps1 - operation lifecycle: plan -> protect -> transfer -> settle.
# Library file: dot-source after RobocopyTo.Common.ps1. ASCII-only source.
#
# Safety model: the live robocopy run never overwrites or deletes anything.
# The plan pass (/L) finds every file that would be overwritten (and, for mirror,
# deleted); those are renamed into a hidden staging folder first, so the transfer
# only ever creates files. Every action is journaled (JSONL) for resume/rollback/undo.
#
# Staging is strictly in-flight: it exists so cancel/rollback can revert a running
# or failed operation, and it is purged the moment an operation settles (success,
# completed revert, or the user keeping a failed result). Files live where the user
# put them and nowhere else; undo after settle removes created files and returns
# moved files, but cannot resurrect replaced ones (those are kept and flagged).

# --------------------------------------------------------------------- plan

$script:RtOverwriteClasses = @('Newer', 'Older', 'Changed', 'Modified', 'Tweaked')
$script:RtCopyClasses      = @('New File', 'Newer', 'Older', 'Changed', 'Modified', 'Tweaked', 'Lonely')

# Builds the operation object. Sources may be files and/or folders; paste maps to copy/move upstream.
function New-RtOperation([string]$Mode, [string[]]$Sources, [string]$Destination, [string]$OpId) {
    if (-not $OpId) { $OpId = New-RtOpId }
    $srcInfos = @()
    foreach ($s in $Sources) {
        $p = Get-RtNormalizedPath $s
        if (-not (Test-Path -LiteralPath $p)) { throw "Source not found: $p" }
        $isFile = Test-Path -LiteralPath $p -PathType Leaf
        if ($isFile -and $Mode -eq 'mirror') { throw "Mirror requires folder sources: $p" }
        $srcInfos += @{ Path = $p; IsFile = $isFile }
    }
    $dest = Get-RtNormalizedPath $Destination
    foreach ($si in $srcInfos) {
        if (-not $si.IsFile) {
            $destRoot = Join-Path $dest (Get-RtLeafName $si.Path)
            if ($destRoot -ieq $si.Path) { throw "Source and destination are the same: $($si.Path)" }
            if (Test-RtSubPath $si.Path $destRoot) { throw "Destination is inside the source folder: $destRoot" }
        } else {
            if ((Split-Path $si.Path -Parent) -ieq $dest) { throw "That file is already in this folder: $($si.Path)" }
        }
    }
    return @{
        OpId = $OpId; Mode = $Mode; Sources = $srcInfos; Dest = $dest
        Started = [DateTime]::UtcNow
    }
}

# Parses one /L unilog (UTF-16) into plan entries.
function Read-RtPlanLog([string]$LogPath, [string]$SrcRoot, [string]$DestRoot) {
    $files   = New-Object System.Collections.Generic.List[object]
    $dirs    = New-Object System.Collections.Generic.List[object]
    $extras  = New-Object System.Collections.Generic.List[object]
    $srcPrefix = $SrcRoot.TrimEnd('\') + '\'
    foreach ($line in [System.IO.File]::ReadAllLines($LogPath)) {
        if (-not $line.Trim()) { continue }
        $parts = $line.Split("`t")
        if ($parts.Length -ge 5) {
            $class = $parts[1].Trim()
            $size = 0L; [void][long]::TryParse($parts[3].Trim(), [ref]$size)
            $path = $parts[4]
            if ($class -eq '*EXTRA File') {
                $extras.Add(@{ Type = 'File'; Path = $path; Size = $size })
            } elseif ($script:RtCopyClasses -contains $class) {
                $rel = $null
                if ($path.StartsWith($srcPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $path.Substring($srcPrefix.Length)
                } else { $rel = Split-Path $path -Leaf }
                $files.Add(@{
                    Src = $path; Dest = (Join-Path $DestRoot $rel); Size = $size
                    Overwrite = ($script:RtOverwriteClasses -contains $class); Class = $class
                })
            }
            # 'same' and friends: nothing to do
        } elseif ($parts.Length -eq 3) {
            $head = $parts[1]; $path = $parts[2]
            if ($head -match '^\s*\*EXTRA Dir') {
                $extras.Add(@{ Type = 'Dir'; Path = $path.TrimEnd('\'); Size = 0L })
            } elseif ($head -match '^\s*New Dir') {
                $rel = ''
                $p = $path.TrimEnd('\')
                if (($p + '\').StartsWith($srcPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $p.Substring([Math]::Min($p.Length, $srcPrefix.Length))
                }
                $destDir = if ($rel) { Join-Path $DestRoot $rel } else { $DestRoot }
                $dirs.Add(@{ Src = $p; Dest = $destDir })
            }
            # blank head = existing dir line, ignore
        }
    }
    # plain arrays at the boundary: PS 5.1's dynamic binder chokes on generic Lists in
    # hashtable literals / @() wraps, so no List[object] leaves this file
    return @{ Files = $files.ToArray(); Dirs = $dirs.ToArray(); Extras = $extras.ToArray() }
}

# Runs the /L pass for every source and aggregates the plan.
function Get-RtPlan([hashtable]$Op, [hashtable]$Settings) {
    $runs    = New-Object System.Collections.Generic.List[object]
    $files   = New-Object System.Collections.Generic.List[object]
    $dirs    = New-Object System.Collections.Generic.List[object]
    $extras  = New-Object System.Collections.Generic.List[object]
    foreach ($si in $Op.Sources) {
        $ulog = Join-Path $env:TEMP ('rt-plan-' + [guid]::NewGuid().ToString('N') + '.log')
        try {
            if ($si.IsFile) {
                $srcParent = Split-Path $si.Path -Parent
                $leaf = Split-Path $si.Path -Leaf
                $destRoot = $Op.Dest
                $planArgs = @($srcParent, $destRoot, $leaf, '/L', '/BYTES', '/FP', '/NJH', '/NJS', "/UNILOG:$ulog", '/R:0', '/W:0')
                $transferBase = @($srcParent, $destRoot, $leaf)
            } else {
                $destRoot = Join-Path $Op.Dest (Get-RtLeafName $si.Path)
                $modeFlag = if ($Op.Mode -eq 'mirror') { '/MIR' } else { '/E' }
                $planArgs = @($si.Path, $destRoot, $modeFlag, '/L', '/BYTES', '/FP', '/NJH', '/NJS', "/UNILOG:$ulog", '/R:0', '/W:0')
                $transferBase = @($si.Path, $destRoot)
            }
            if ($Settings.excludeJunctions) { $planArgs += '/XJ' }
            $planArgs += @('/XD', $script:RtStagingDirName)
            $sink = Join-Path $env:TEMP ('rt-plan-sink-' + [guid]::NewGuid().ToString('N') + '.txt')
            try {
                $p = Start-Process -FilePath $script:RtRobocopy -ArgumentList (ConvertTo-RtArgString $planArgs) `
                        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $sink
                if ($p.ExitCode -ge 8) { throw "Plan scan failed for '$($si.Path)' (robocopy exit $($p.ExitCode))" }
            } finally { Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue }
            $parsed = Read-RtPlanLog $ulog $si.Path $destRoot
            foreach ($f in $parsed.Files)  { $files.Add($f) }
            foreach ($d in $parsed.Dirs)   { $dirs.Add($d) }
            if ($Op.Mode -eq 'mirror') { foreach ($x in $parsed.Extras) { $extras.Add($x) } }
            $runs.Add(@{ Source = $si; DestRoot = $destRoot; TransferBase = $transferBase
                         Files = $parsed.Files })
        } finally {
            Remove-Item -LiteralPath $ulog -Force -ErrorAction SilentlyContinue
        }
    }
    $totalBytes = 0L; $largest = 0L
    $overwrites = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $totalBytes += $f.Size
        if ($f.Size -gt $largest) { $largest = $f.Size }
        if ($f.Overwrite) { $overwrites.Add($f) }
    }
    return @{
        Runs = $runs.ToArray(); Files = $files.ToArray(); Dirs = $dirs.ToArray(); Extras = $extras.ToArray()
        TotalBytes = $totalBytes; TotalFiles = $files.Count; LargestFile = $largest
        Overwrites = $overwrites.ToArray()
    }
}

# Journals the plan in the exact shape Undo/History read back.
function Write-RtPlanRecord($Journal, [hashtable]$Plan) {
    $destDirs = New-Object System.Collections.Generic.List[string]
    $srcDirs  = New-Object System.Collections.Generic.List[string]
    foreach ($d in $Plan.Dirs) { $destDirs.Add([string]$d.Dest); $srcDirs.Add([string]$d.Src) }
    Write-RtJournal $Journal @{
        kind = 'plan'
        files = $Plan.TotalFiles; bytes = $Plan.TotalBytes; largest = $Plan.LargestFile
        overwrites = $Plan.Overwrites.Count; extras = $Plan.Extras.Count
        destDirs = $destDirs.ToArray()
        srcDirs  = $srcDirs.ToArray()
    }
}

# ------------------------------------------------------------------ protect

function Resolve-RtStagingRoot([string]$Dest) {
    $candidates = @()
    # sandboxed runs stage inside the rerouted app dir (tests run on one volume)
    if ($env:ROBOCOPYTO_DATA) { $candidates += (Join-Path $script:RtAppDir 'staging') }
    try {
        $volRoot = [System.IO.Path]::GetPathRoot(($Dest.TrimEnd('\') + '\'))
        if ($volRoot) { $candidates += (Join-Path $volRoot $script:RtStagingDirName) }
    } catch { }
    $candidates += (Join-Path $Dest $script:RtStagingDirName)
    $candidates += (Join-Path $script:RtAppDir 'staging')
    foreach ($c in $candidates) {
        try {
            [RobocopyTo.Native]::EnsureDirectory($c)
            [RobocopyTo.Native]::MakeHiddenSystem($c)
            $probe = Join-Path $c ('.probe-' + [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force
            return $c
        } catch { continue }
    }
    throw 'No writable staging location found.'
}

# Renames would-be-overwritten / would-be-deleted items into staging. Returns staged pairs.
# $SkipPaths: dest paths already staged by an earlier interrupted run (resume) - never re-stage
# those, the file now at that path is our own partial output, not user data.
function Invoke-RtProtect([hashtable]$Op, [hashtable]$Plan, $Journal, [System.Collections.Generic.HashSet[string]]$SkipPaths) {
    if (-not $SkipPaths) { $SkipPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
    $staged = New-Object System.Collections.Generic.List[object]
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Plan.Overwrites) {
        if (-not $SkipPaths.Contains($f.Dest)) { $targets.Add(@{ Path = $f.Dest; Type = 'File' }) }
    }
    # mirror extras: whole extra dirs are staged in one rename; skip files under them
    $extraDirs = @($Plan.Extras | Where-Object { $_.Type -eq 'Dir' } | ForEach-Object { $_.Path })
    foreach ($x in $Plan.Extras) {
        if ($x.Type -eq 'Dir') { $targets.Add(@{ Path = $x.Path; Type = 'Dir' }) }
        else {
            $underStagedDir = $false
            foreach ($d in $extraDirs) { if (Test-RtSubPath $d $x.Path) { $underStagedDir = $true; break } }
            if (-not $underStagedDir) { $targets.Add(@{ Path = $x.Path; Type = 'File' }) }
        }
    }
    if ($targets.Count -eq 0) { return ,$staged.ToArray() }

    $stagingRoot = Resolve-RtStagingRoot $Op.Dest
    $opStaging = Join-Path $stagingRoot $Op.OpId
    [RobocopyTo.Native]::EnsureDirectory($opStaging)
    Write-RtJournal $Journal @{ kind = 'stagingRoot'; path = $opStaging }
    $i = 0
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { continue }  # vanished since plan
        $slot = Join-Path $opStaging ('{0:D4}' -f $i); $i++
        [RobocopyTo.Native]::EnsureDirectory($slot)
        $to = Join-Path $slot (Split-Path $t.Path -Leaf)
        [RobocopyTo.Native]::Rename($t.Path, $to)
        Write-RtJournal $Journal @{ kind = 'staged'; from = $t.Path; to = $to; type = $t.Type }
        $staged.Add(@{ From = $t.Path; To = $to; Type = $t.Type })
    }
    return ,$staged.ToArray()
}

# ----------------------------------------------------------------- transfer

function Get-RtTransferArgs([hashtable]$Op, [hashtable]$Run, [hashtable]$Plan, [hashtable]$Settings) {
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in $Run.TransferBase) { $a.Add($x) }
    if (-not $Run.Source.IsFile) {
        $a.Add('/E')
        if ($Op.Mode -eq 'move') { $a.Add('/MOVE') }
    } elseif ($Op.Mode -eq 'move') { $a.Add('/MOV') }
    $a.Add('/COPY:DAT'); $a.Add('/DCOPY:DAT')
    $a.Add('/BYTES'); $a.Add('/FP'); $a.Add('/NJH'); $a.Add('/NDL')
    $a.Add('/R:' + [int]$Settings.retries); $a.Add('/W:' + [int]$Settings.waitSeconds)
    if ($Settings.excludeJunctions) { $a.Add('/XJ') }
    if ($Settings.restartableMode) { $a.Add('/Z') }
    $a.Add('/XD'); $a.Add($script:RtStagingDirName)
    $mt = 0
    switch ([string]$Settings.threadsPolicy) {
        'auto' { if ($Plan.TotalFiles -ge 64 -and $Plan.LargestFile -lt 64MB) { $mt = 8 } }
        'off'  { $mt = 0 }
        default { $v = 0; if ([int]::TryParse([string]$Settings.threadsPolicy, [ref]$v)) { $mt = $v } }
    }
    if ($mt -gt 0) { $a.Add('/MT:' + $mt) }
    foreach ($x in $Settings.extraArgs) { if ($x) { $a.Add([string]$x) } }
    return $a.ToArray()
}

# Loose name equality: robocopy stdout is OEM-encoded so non-ASCII chars arrive mangled.
# Compare only ASCII positions; treat any non-ASCII byte as a wildcard.
function Test-RtLooseNameMatch([string]$MangledPath, [string]$PlanPath) {
    if ($MangledPath -eq $PlanPath) { return $true }
    $m = Split-Path $MangledPath -Leaf
    $p = Split-Path $PlanPath -Leaf
    if ($m.Length -ne $p.Length) { return $false }
    for ($i = 0; $i -lt $m.Length; $i++) {
        $mc = [int][char]$m[$i]; $pc = [int][char]$p[$i]
        if ($mc -lt 127 -and $pc -lt 127 -and ([char]::ToLowerInvariant([char]$mc) -ne [char]::ToLowerInvariant([char]$pc))) { return $false }
    }
    return $true
}

# Creates transfer state; UI drives it by calling Step-RtTransfer until it returns $false.
function Start-RtTransfer([hashtable]$Op, [hashtable]$Plan, [hashtable]$Settings, $Journal) {
    $state = @{
        Op = $Op; Plan = $Plan; Settings = $Settings; Journal = $Journal
        RunIndex = -1; Runner = $null
        BytesDone = [long]0; FilesDone = 0; FailedFiles = New-Object System.Collections.Generic.List[object]
        CurrentFile = $null      # @{ Src; Dest; Size; PlanIndex; Partial }
        CurrentFileBytes = [long]0
        PlanPointer = 0          # index into current run's Files list
        Errors = New-Object System.Collections.Generic.List[string]
        Done = $false; ExitCodes = New-Object System.Collections.Generic.List[int]
        Paused = $false; Cancelled = $false
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        LastError = $null
    }
    Start-RtNextRun $state
    return $state
}

function Start-RtNextRun([hashtable]$State) {
    $State.RunIndex++
    $State.PlanPointer = 0
    $State.CurrentFile = $null
    $State.CurrentFileBytes = 0L
    if ($State.RunIndex -ge $State.Plan.Runs.Count) { $State.Done = $true; return }
    $run = $State.Plan.Runs[$State.RunIndex]
    $args = Get-RtTransferArgs $State.Op $run $State.Plan $State.Settings
    $argStr = ConvertTo-RtArgString $args
    Write-RtJournal $State.Journal @{ kind = 'runStart'; args = $argStr }
    Write-RtLog "robocopy $argStr"
    $runner = New-Object RobocopyTo.RoboRunner
    $runner.Start($script:RtRobocopy, $argStr)
    $State.Runner = $runner
}

function Complete-RtCurrentFile([hashtable]$State) {
    $cf = $State.CurrentFile
    if (-not $cf) { return }
    $State.BytesDone += ($cf.Size - $cf.Counted)
    $State.FilesDone++
    $mtime = $null
    if ($cf.Size -ge 1MB) {
        try { $mtime = ([System.IO.File]::GetLastWriteTimeUtc($cf.Dest)).ToString('o') } catch { }
    }
    Write-RtJournal $State.Journal @{ kind = 'fileDone'; src = $cf.Src; dest = $cf.Dest; size = $cf.Size; mtime = $mtime }
    $State.CurrentFile = $null
    $State.CurrentFileBytes = 0L
}

# Drains pending robocopy events; returns $false when the whole operation is finished.
function Step-RtTransfer([hashtable]$State) {
    if ($State.Done) { return $false }
    $run = $State.Plan.Runs[$State.RunIndex]
    $ev = $null
    while ($State.Runner.Events.TryDequeue([ref]$ev)) {
        switch ($ev.Kind) {
            'Percent' {
                $cf = $State.CurrentFile
                if ($cf) {
                    $newBytes = [long]($cf.Size * $ev.Percent / 100.0)
                    $State.BytesDone += ($newBytes - $cf.Counted)
                    $cf.Counted = $newBytes
                    if ($ev.Percent -ge 100) { Complete-RtCurrentFile $State }
                }
            }
            'Line' {
                $line = $ev.Text
                $parts = $line.Split("`t")
                if ($parts.Length -ge 5 -and ($script:RtCopyClasses -contains $parts[1].Trim())) {
                    $size = 0L; [void][long]::TryParse($parts[3].Trim(), [ref]$size)
                    $path = $parts[4]
                    $cf = $State.CurrentFile
                    if ($cf -and (Test-RtLooseNameMatch $path $cf.Src)) {
                        # retry of the same file: reset in-file progress, don't double count
                        $State.BytesDone -= $cf.Counted
                        $cf.Counted = 0L
                    } else {
                        if ($cf) {
                            # previous file never hit 100% (errored / interleaved): treat as not done
                            $State.BytesDone -= $cf.Counted
                            $State.CurrentFile = $null
                        }
                        # match against the plan: forward window first (single-thread order),
                        # then a full scan of untaken entries (/MT completes out of order)
                        $files = $run.Files; $hit = -1
                        $limit = [Math]::Min($files.Count, $State.PlanPointer + 50)
                        for ($j = $State.PlanPointer; $j -lt $limit; $j++) {
                            if (-not $files[$j].ContainsKey('Taken') -and $files[$j].Size -eq $size -and (Test-RtLooseNameMatch $path $files[$j].Src)) { $hit = $j; break }
                        }
                        if ($hit -lt 0) {
                            for ($j = 0; $j -lt $files.Count; $j++) {
                                if (-not $files[$j].ContainsKey('Taken') -and $files[$j].Size -eq $size -and (Test-RtLooseNameMatch $path $files[$j].Src)) { $hit = $j; break }
                            }
                        }
                        if ($hit -ge 0) {
                            $f = $files[$hit]
                            $f.Taken = $true
                            if ($hit -ge $State.PlanPointer) { $State.PlanPointer = $hit + 1 }
                            $State.CurrentFile = @{ Src = $f.Src; Dest = $f.Dest; Size = $size; Counted = 0L }
                        } else {
                            # not in plan (file appeared after planning): derive dest from path
                            $srcPrefix = $run.Source.Path.TrimEnd('\') + '\'
                            $rel = if ($path.StartsWith($srcPrefix, [StringComparison]::OrdinalIgnoreCase)) { $path.Substring($srcPrefix.Length) } else { Split-Path $path -Leaf }
                            $State.CurrentFile = @{ Src = $path; Dest = (Join-Path $run.DestRoot $rel); Size = $size; Counted = 0L }
                        }
                    }
                } elseif ($line -match '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ERROR (\d+) \(0x[0-9A-Fa-f]+\)\s+(.*)$') {
                    $State.LastError = "ERROR $($Matches[1]): $($Matches[2])"
                    $State.Errors.Add($State.LastError)
                    Write-RtLog $line
                } elseif ($line -match '^ERROR: RETRY LIMIT EXCEEDED') {
                    $cf = $State.CurrentFile
                    if ($cf) {
                        $State.BytesDone -= $cf.Counted
                        $State.FailedFiles.Add(@{ Src = $cf.Src; Error = $State.LastError })
                        Write-RtJournal $State.Journal @{ kind = 'fileFailed'; src = $cf.Src; error = $State.LastError }
                        $State.CurrentFile = $null
                    }
                    Write-RtLog $line
                } elseif ($line -match '^\s+(Dirs|Files|Bytes)\s*:') {
                    Write-RtLog ('summary ' + $line.Trim())
                }
            }
            'Exited' {
                if ($State.CurrentFile -and -not $State.Cancelled) {
                    # exited without 100% on in-flight file (e.g. killed externally)
                    $State.BytesDone -= $State.CurrentFile.Counted
                    $State.CurrentFile = $null
                }
                $State.ExitCodes.Add($ev.ExitCode)
                Write-RtJournal $State.Journal @{ kind = 'runExit'; code = $ev.ExitCode }
                if (-not $State.Cancelled) { Start-RtNextRun $State }
                else { $State.Done = $true }
            }
        }
        if ($State.Done) { break }
    }
    return (-not $State.Done)
}

function Suspend-RtTransfer([hashtable]$State) {
    if ($State.Runner -and -not $State.Paused) { $State.Runner.Suspend(); $State.Paused = $true; $State.Stopwatch.Stop() }
}
function Resume-RtTransfer([hashtable]$State) {
    if ($State.Runner -and $State.Paused) { $State.Runner.Resume(); $State.Paused = $false; $State.Stopwatch.Start() }
}

function Stop-RtTransfer([hashtable]$State) {
    $State.Cancelled = $true
    if ($State.Paused) { Resume-RtTransfer $State }
    if ($State.Runner) { $State.Runner.Kill() }
    # remove the partial in-flight destination file: it is our junk, not user data
    $cf = $State.CurrentFile
    if ($cf -and (Test-Path -LiteralPath $cf.Dest)) {
        try {
            $len = (Get-Item -LiteralPath $cf.Dest -Force).Length
            if ($len -le $cf.Size) {
                [RobocopyTo.Native]::DeleteFileW([RobocopyTo.Native]::Extend($cf.Dest)) | Out-Null
                Write-RtJournal $State.Journal @{ kind = 'partialRemoved'; path = $cf.Dest }
            }
        } catch { }
    }
    $State.BytesDone -= $(if ($cf) { $cf.Counted } else { 0 })
    $State.CurrentFile = $null
    Write-RtJournal $State.Journal @{ kind = 'cancelled' }
}

# Robocopy exit codes are a bitmask; >= 8 means at least one failure.
function Get-RtWorstExit([hashtable]$State) {
    $worst = 0
    foreach ($c in $State.ExitCodes) { if ($c -gt $worst) { $worst = $c } }
    return $worst
}

function Complete-RtOperation([hashtable]$State, [string]$Status) {
    Write-RtJournal $State.Journal @{
        kind = 'footer'; status = $Status
        bytesDone = $State.BytesDone; filesDone = $State.FilesDone
        failed = $State.FailedFiles.Count; exit = (Get-RtWorstExit $State)
        durationMs = $State.Stopwatch.ElapsedMilliseconds
    }
    Close-RtJournal $State.Journal
    # success settles immediately: replaced originals are gone for good (the user
    # chose the overwrite); cancel/failure keep staging until the revert decision.
    if ($Status -eq 'success') { Clear-RtOpStaging $State.Op.OpId }
    Update-RtLastOpMarker
}

# ------------------------------------------------------------------- settle

# Removes an operation's staging folder. Journals the purge so a later undo knows
# replaced originals are gone (it then keeps those files instead of deleting them).
function Clear-RtOpStaging([string]$OpId, $Records) {
    if (-not $Records) { try { $Records = Read-RtJournal $OpId } catch { return } }
    $roots = @($Records | Where-Object { $_.kind -eq 'stagingRoot' } | ForEach-Object { $_.path })
    if ($roots.Count -eq 0) { return }
    $purged = @($Records | Where-Object { $_.kind -eq 'stagingPurged' })
    foreach ($r in $roots) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($purged.Count -eq 0) {
        $j = Open-RtJournal $OpId
        Write-RtJournal $j @{ kind = 'stagingPurged' }
        Close-RtJournal $j
    }
}

# Launch-time tidy. Staging never outlives an operation: settled ops (success,
# cancelled, undone) lose theirs immediately at settle, so anything still present
# for one of those - or for an op with no journal at all - is residue and is
# removed. Failed/interrupted ops keep staging until they are resolved or age out
# of retention. History is pruned to the retention count, logs follow journals.
function Clear-RtResidue([hashtable]$Settings) {
    $journals = @(Get-RtJournalList)   # newest first
    $keep = [int]$Settings.journalRetentionCount
    $roots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $n = 0
    foreach ($j in $journals) {
        $n++
        $opId = [System.IO.Path]::GetFileNameWithoutExtension($j.Name)
        $d = Get-RtJournalDigest $j.FullName
        if ($d -and $d.StagingRoot) {
            try { $null = $roots.Add((Split-Path $d.StagingRoot -Parent)) } catch { }
            if (($d.Status -eq 'success' -or $d.Status -eq 'cancelled' -or $d.Status -eq 'undone') -and
                (Test-Path -LiteralPath $d.StagingRoot)) {
                Remove-Item -LiteralPath $d.StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($n -gt $keep) {
            Remove-Item -LiteralPath $j.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $script:RtLogDir ($opId + '.log')) -Force -ErrorAction SilentlyContinue
        }
    }
    # orphan staging dirs: journals are created before staging ever exists, so a
    # staging dir with no journal belongs to no operation - remove it. A sandboxed
    # run must not judge the real volume-root staging (its journals are elsewhere).
    if (-not $env:ROBOCOPYTO_DATA) {
        try { $null = $roots.Add((Join-Path ([System.IO.Path]::GetPathRoot($script:RtAppDir)) $script:RtStagingDirName)) } catch { }
    }
    $null = $roots.Add((Join-Path $script:RtAppDir 'staging'))
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $script:RtJournalDir ($dir.Name + '.jsonl'))) { continue }
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        # drop the (hidden) staging root itself once it is empty
        if (-not (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
        }
    }
}
