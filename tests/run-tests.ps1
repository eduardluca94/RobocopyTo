# run-tests.ps1 - headless test suite for RobocopyTo. No UI, no live shell changes.
# Exercises the engine against real robocopy on synthetic trees, the journal,
# undo/resume, guards, clipboard parsing, and registration (against a temp hive).
# Fully sandboxed: ROBOCOPYTO_DATA reroutes journals/logs/settings/staging into
# the temp work dir and the last-op marker into a test hive - the suite leaves
# nothing behind in the real per-user store.
# Exit code 0 = all pass, 1 = any failure.
[CmdletBinding()]
param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$work = Join-Path $env:TEMP ('rt-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$env:ROBOCOPYTO_DATA = Join-Path $work 'data'

Import-Module (Join-Path $repo 'src\RobocopyTo.psm1') -Force
Initialize-RtEnvironment

$script:Pass = 0; $script:Fail = 0
function Check([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host ("  [PASS] " + $Name) -ForegroundColor Green
        $script:Pass++
    } catch {
        Write-Host ("  [FAIL] " + $Name + " :: " + $_.Exception.Message) -ForegroundColor Red
        $script:Fail++
    }
}
function ShouldBe($actual, $expected, $what) {
    if ($actual -ne $expected) { throw "$what : expected '$expected', got '$actual'" }
}
function ShouldBeTrue($cond, $what) { if (-not $cond) { throw "$what : expected true" } }

Write-Host "RobocopyTo test suite"
Write-Host "work dir: $work"

# helper: run an operation to completion headlessly (no UI), return final state
function Invoke-RtHeadless([string]$Mode, [string[]]$Sources, [string]$Dest, [hashtable]$Settings) {
    $op = New-RtOperation -Mode $Mode -Sources $Sources -Destination $Dest
    Open-RtLog $op.OpId
    $journal = Open-RtJournal $op.OpId
    Write-RtJournal $journal @{ kind = 'header'; op = $op.Mode; opId = $op.OpId
                                sources = @($op.Sources | ForEach-Object { $_.Path }); dest = $op.Dest }
    $plan = Get-RtPlan $op $Settings
    Write-RtPlanRecord $journal $plan
    $staged = Invoke-RtProtect $op $plan $journal
    $state = Start-RtTransfer $op $plan $Settings $journal
    $guard = 0
    while (Step-RtTransfer $state) { Start-Sleep -Milliseconds 20; if (++$guard -gt 3000) { throw 'transfer hang' } }
    $exit = Get-RtWorstExit $state
    Complete-RtOperation $state $(if ($exit -ge 8 -or $state.FailedFiles.Count -gt 0) { 'failed' } else { 'success' })
    return @{ Op = $op; Plan = $plan; State = $state; Staged = $staged }
}

$settings = Get-RtSettings

# ---------------------------------------------------------------- 1. plan parsing
Check 'plan classifies new/overwrite/extra and totals bytes' {
    $s = Join-Path $work 'p1\src'; $d = Join-Path $work 'p1\dst'
    # dest pre-seed goes in $d\src because the source leaf "src" makes the dest root $d\src
    $null = New-Item -ItemType Directory -Force -Path "$s\sub", "$d\src"
    Set-Content "$s\new.txt" ('n' * 100)
    Set-Content "$s\sub\deep.txt" ('d' * 50)
    Set-Content "$s\over.txt" 'source wins'
    Set-Content "$d\src\over.txt" 'old'; (Get-Item "$d\src\over.txt").LastWriteTime = (Get-Date).AddDays(-2)
    Set-Content "$d\src\extra.txt" 'only in dst'
    $op = New-RtOperation -Mode copy -Sources @($s) -Destination $d
    $plan = Get-RtPlan $op $settings
    ShouldBe $plan.TotalFiles 3 'file count'
    ShouldBe $plan.Overwrites.Count 1 'overwrite count'
    # compute from real on-disk sizes (Set-Content appends CRLF) so the figure can't drift
    $expectBytes = (Get-Item "$s\new.txt").Length + (Get-Item "$s\sub\deep.txt").Length + (Get-Item "$s\over.txt").Length
    ShouldBe $plan.TotalBytes $expectBytes 'total bytes match source file sizes'
}

Check 'mirror plan surfaces destination extras' {
    $s = Join-Path $work 'p2\src'; $d = Join-Path $work 'p2\dst'
    # dest root is $d\src (source leaf appended), so extras must live there
    $null = New-Item -ItemType Directory -Force -Path $s, "$d\src\extradir"
    Set-Content "$s\keep.txt" 'k'
    Set-Content "$d\src\gone.txt" 'remove me'
    Set-Content "$d\src\extradir\x.txt" 'remove me too'
    $op = New-RtOperation -Mode mirror -Sources @($s) -Destination $d
    $plan = Get-RtPlan $op $settings
    ShouldBeTrue ($plan.Extras.Count -ge 2) "mirror found extras (got $($plan.Extras.Count))"
}

# ---------------------------------------------------------------- 2. copy + staging + byte accounting
Check 'copy stages overwrite, exact byte total, content replaced' {
    $s = Join-Path $work 'c1\Data'; $d = Join-Path $work 'c1\dst'
    $null = New-Item -ItemType Directory -Force -Path "$s\sub", "$d\Data"
    Set-Content "$s\a.txt" ('a' * 1000)
    Set-Content "$s\sub\b.txt" ('b' * 2000)
    Set-Content "$s\over.txt" 'NEW'
    Set-Content "$d\Data\over.txt" 'ORIGINAL'; (Get-Item "$d\Data\over.txt").LastWriteTime = (Get-Date).AddDays(-2)
    $r = Invoke-RtHeadless copy @($s) $d $settings
    ShouldBe $r.State.FilesDone 3 'files done'
    ShouldBe $r.State.BytesDone $r.Plan.TotalBytes 'byte accounting exact'
    ShouldBe ((Get-Content "$d\Data\over.txt" -Raw).Trim()) 'NEW' 'overwrite applied'
    ShouldBe $r.Staged.Count 1 'one item staged'
    # success settles immediately: staged originals never outlive the operation
    ShouldBeTrue (-not (Test-Path -LiteralPath $r.Staged[0].To)) 'staged original purged after success'
    $recs = Read-RtJournal $r.Op.OpId
    ShouldBeTrue (@($recs | Where-Object { $_.kind -eq 'stagingPurged' }).Count -ge 1) 'stagingPurged journaled'
}

# ---------------------------------------------------------------- 3. undo copy (post-settle semantics)
Check 'undo after success removes created, keeps replaced and modified (flagged)' {
    $s = Join-Path $work 'u1\Data'; $d = Join-Path $work 'u1\dst'
    $null = New-Item -ItemType Directory -Force -Path $s, "$d\Data"
    Set-Content "$s\pure.txt" 'created untouched'
    Set-Content "$s\keep.txt" 'created file'
    Set-Content "$s\over.txt" 'NEW'
    Set-Content "$d\Data\over.txt" 'ORIGINAL'; (Get-Item "$d\Data\over.txt").LastWriteTime = (Get-Date).AddDays(-2)
    $r = Invoke-RtHeadless copy @($s) $d $settings
    # modify one created file after the copy -> undo must keep+flag it
    Set-Content "$d\Data\keep.txt" 'user edited this after copy'
    $undo = Invoke-RtUndo -OpId $r.Op.OpId -Settings $settings -OnProgress $null
    ShouldBeTrue (-not (Test-Path "$d\Data\pure.txt")) 'untouched created file removed'
    ShouldBeTrue (Test-Path "$d\Data\keep.txt") 'modified file kept'
    # staging settled with the success: the replacing file is kept, never deleted into nothing
    ShouldBe ((Get-Content "$d\Data\over.txt" -Raw).Trim()) 'NEW' 'replaced file kept (original unrecoverable)'
    ShouldBe $undo.Flagged.Count 2 'two flagged (modified + replaced)'
}

Check 'cancel before settle: revert restores staged originals' {
    $s = Join-Path $work 'cx\Data'; $d = Join-Path $work 'cx\dst'
    $null = New-Item -ItemType Directory -Force -Path $s, "$d\Data"
    Set-Content "$s\over.txt" 'NEW'
    Set-Content "$d\Data\over.txt" 'ORIGINAL'; (Get-Item "$d\Data\over.txt").LastWriteTime = (Get-Date).AddDays(-2)
    $op = New-RtOperation -Mode copy -Sources @($s) -Destination $d
    Open-RtLog $op.OpId
    $journal = Open-RtJournal $op.OpId
    Write-RtJournal $journal @{ kind = 'header'; op = 'copy'; opId = $op.OpId; sources = @($s); dest = $op.Dest }
    $plan = Get-RtPlan $op $settings
    Write-RtPlanRecord $journal $plan
    $staged = Invoke-RtProtect $op $plan $journal
    ShouldBe $staged.Count 1 'original staged during protect'
    ShouldBeTrue (-not (Test-Path "$d\Data\over.txt")) 'original renamed away during protect'
    Write-RtJournal $journal @{ kind = 'footer'; status = 'cancelled' }
    Close-RtJournal $journal
    $null = Invoke-RtUndo -OpId $op.OpId -Settings $settings -OnProgress $null
    ShouldBe ((Get-Content "$d\Data\over.txt" -Raw).Trim()) 'ORIGINAL' 'original restored by cancel revert'
    ShouldBeTrue (-not (Test-Path -LiteralPath $staged[0].To)) 'staging consumed by the revert'
}

Check 'undo survives a throwing progress callback' {
    $s = Join-Path $work 'u2\Data'; $d = Join-Path $work 'u2\dst'
    $null = New-Item -ItemType Directory -Force -Path $s, "$d\Data"
    Set-Content "$s\new.txt" 'created'
    Set-Content "$s\over.txt" 'NEW'
    Set-Content "$d\Data\over.txt" 'ORIGINAL'; (Get-Item "$d\Data\over.txt").LastWriteTime = (Get-Date).AddDays(-2)
    $r = Invoke-RtHeadless copy @($s) $d $settings
    $undo = Invoke-RtUndo -OpId $r.Op.OpId -Settings $settings -OnProgress { throw 'progress UI exploded' }
    ShouldBeTrue (-not (Test-Path "$d\Data\new.txt")) 'created file removed despite callback failure'
    ShouldBe ((Get-Content "$d\Data\over.txt" -Raw).Trim()) 'NEW' 'replaced file kept despite callback failure'
    ShouldBeTrue ($undo.Done -gt 0) 'undo reported actions done'
}

Check 'last-op marker tracks success and undo' {
    $s = Join-Path $work 'mk\src'; $d = Join-Path $work 'mk\dst'
    $null = New-Item -ItemType Directory -Force -Path $s, $d
    Set-Content "$s\m.txt" 'marker'
    Start-Sleep -Milliseconds 1100   # fresh opId second so this is the newest journal
    $r = Invoke-RtHeadless copy @($s) $d $settings
    $m = Get-RtLastOpMarker
    ShouldBe $m.OpId $r.Op.OpId 'marker points at the fresh operation'
    ShouldBe $m.Verb 'copy' 'marker records the verb'
    $null = Invoke-RtUndo -OpId $r.Op.OpId -Settings $settings -OnProgress $null
    $m2 = Get-RtLastOpMarker
    ShouldBeTrue ($m2.OpId -ne $r.Op.OpId) 'marker moved off the undone operation'
}

Check 'residue sweep: orphans removed, settled staging removed, failed kept' {
    $sroot = Join-Path $env:ROBOCOPYTO_DATA 'staging'
    # orphan: staging dir with no journal at all
    $orphan = Join-Path $sroot '20000101-000000-dead00'
    $null = New-Item -ItemType Directory -Force -Path $orphan
    Set-Content (Join-Path $orphan 'ghost.txt') 'x'
    # failed op with staging: must be kept (its dialog may still offer Roll back)
    $failedOp = New-RtOpId
    $failedDir = Join-Path $sroot $failedOp
    $null = New-Item -ItemType Directory -Force -Path $failedDir
    Set-Content (Join-Path $failedDir 'precious.txt') 'x'
    $j = Open-RtJournal $failedOp
    Write-RtJournal $j @{ kind = 'header'; op = 'copy'; opId = $failedOp; sources = @('x'); dest = 'y' }
    Write-RtJournal $j @{ kind = 'stagingRoot'; path = $failedDir }
    Write-RtJournal $j @{ kind = 'footer'; status = 'failed' }
    Close-RtJournal $j
    # cancelled op with staging left behind (e.g. crash before revert): settled -> swept
    $doneOp = New-RtOpId
    $doneDir = Join-Path $sroot $doneOp
    $null = New-Item -ItemType Directory -Force -Path $doneDir
    Set-Content (Join-Path $doneDir 'leftover.txt') 'x'
    $j2 = Open-RtJournal $doneOp
    Write-RtJournal $j2 @{ kind = 'header'; op = 'copy'; opId = $doneOp; sources = @('x'); dest = 'y' }
    Write-RtJournal $j2 @{ kind = 'stagingRoot'; path = $doneDir }
    Write-RtJournal $j2 @{ kind = 'footer'; status = 'cancelled' }
    Close-RtJournal $j2
    Write-RtJournal (($j3 = Open-RtJournal $doneOp)) @{ kind = 'undone'; by = 'test' }; Close-RtJournal $j3
    Clear-RtResidue $settings
    ShouldBeTrue (-not (Test-Path -LiteralPath $orphan)) 'orphan staging dir removed'
    ShouldBeTrue (-not (Test-Path -LiteralPath $doneDir)) 'settled-op staging removed'
    ShouldBeTrue (Test-Path -LiteralPath $failedDir) 'failed-op staging kept until resolved'
}

Check 'settings window XAML parses in light and dark themes' {
    Initialize-RtWpf
    foreach ($dark in $false, $true) {
        $t = if ($dark) {
            @{ IsDark = $true; WindowBg = '#202020'; Text = '#FFFFFF'; TextSecondary = '#C9C9C9'
               BtnBg = '#2D2D2D'; BtnBorder = '#454545'; Accent = '#4CC2FF' }
        } else {
            @{ IsDark = $false; WindowBg = '#FFFFFF'; Text = '#1B1B1B'; TextSecondary = '#494949'
               BtnBg = '#FBFBFB'; BtnBorder = '#D9D9D9'; Accent = '#005FB8' }
        }
        $w = [Windows.Markup.XamlReader]::Parse((New-RtSettingsWindowXaml $t))
        ShouldBeTrue ($null -ne $w.FindName('HistoryList')) "controls resolvable (dark=$dark)"
        $w.Close()
    }
}

Check 'factory-built undo progress callback works from a foreign scope' {
    $fakeUi = @{ Bar = [pscustomobject]@{ Value = [double]0 }
                 PercentText = [pscustomobject]@{ Text = '' } }
    $cb = New-RtUndoProgress $fakeUi $null 'Undoing... {0}%'
    # invoke from a scope that has no $Ui/$Window/$TextFormat, as Invoke-RtUndo does
    function Invoke-RtTestForeignScope([scriptblock]$Block) { & $Block 40 'deleteCreated' }
    Invoke-RtTestForeignScope $cb
    ShouldBe $fakeUi.Bar.Value 400 'bar value set through captured closure'
    ShouldBe $fakeUi.PercentText.Text 'Undoing... 40%' 'percent text set through captured closure'
}

# ---------------------------------------------------------------- 4. move + undo move
Check 'move relocates then undo returns to source' {
    $s = Join-Path $work 'm1\box'; $d = Join-Path $work 'm1\dst'
    $null = New-Item -ItemType Directory -Force -Path "$s\inner", $d
    Set-Content "$s\f1.txt" '1'; Set-Content "$s\inner\f2.txt" '2'
    $r = Invoke-RtHeadless move @($s) $d $settings
    ShouldBeTrue (-not (Test-Path $s)) 'source root gone after move'
    ShouldBeTrue (Test-Path "$d\box\inner\f2.txt") 'nested moved'
    $undo = Invoke-RtUndo -OpId $r.Op.OpId -Settings $settings -OnProgress $null
    ShouldBeTrue (Test-Path "$s\f1.txt") 'f1 back at source'
    ShouldBeTrue (Test-Path "$s\inner\f2.txt") 'f2 back at source'
    ShouldBeTrue (-not (Test-Path "$d\box")) 'created dest dir removed'
}

# ---------------------------------------------------------------- 5. long path staging
Check 'staging handles >260 char destination paths' {
    $deep = 'lvl_' + ('x' * 80)
    $s = Join-Path $work 'l1\src'
    $d = Join-Path $work ('l1\dst\' + $deep + '\' + $deep + '\' + $deep)   # > 260 chars total
    $null = New-Item -ItemType Directory -Force -Path $s
    [RobocopyTo.Native]::EnsureDirectory($d)
    Set-Content "$s\file.txt" 'NEW'
    $longDest = Join-Path $d 'file.txt'
    [System.IO.File]::WriteAllText("\\?\$longDest", 'ORIGINAL')
    (Get-Item -LiteralPath "\\?\$longDest").LastWriteTime = (Get-Date).AddDays(-2)
    # rename src leaf so destRoot maps onto $d's final segment
    Rename-Item $s (Join-Path (Split-Path $s -Parent) $deep)
    $s2 = Join-Path (Split-Path $s -Parent) $deep
    $destParent = Split-Path $d -Parent
    $r = Invoke-RtHeadless copy @($s2) $destParent $settings
    ShouldBe (([System.IO.File]::ReadAllText("\\?\$longDest")).Trim()) 'NEW' 'long-path overwrite applied'
    ShouldBeTrue ($r.Staged.Count -ge 1) 'long original staged'
}

# ---------------------------------------------------------------- 6. resume after interruption
Check 'resume continues an interrupted copy' {
    $s = Join-Path $work 'r1\src'; $d = Join-Path $work 'r1\dst'
    $null = New-Item -ItemType Directory -Force -Path $s, $d
    1..6 | ForEach-Object { Set-Content (Join-Path $s "f$_.bin") ('z' * 500) }
    # start, then kill mid-way to simulate interruption
    $op = New-RtOperation -Mode copy -Sources @($s) -Destination $d
    Open-RtLog $op.OpId
    $journal = Open-RtJournal $op.OpId
    Write-RtJournal $journal @{ kind = 'header'; op = 'copy'; opId = $op.OpId; sources = @($s); dest = $op.Dest }
    $plan = Get-RtPlan $op $settings
    Write-RtPlanRecord $journal $plan
    $null = Invoke-RtProtect $op $plan $journal
    $state = Start-RtTransfer $op $plan $settings $journal
    Step-RtTransfer $state | Out-Null
    Stop-RtTransfer $state
    Complete-RtOperation $state 'cancelled'
    # resume
    $rc = Get-RtResumeContext $op.OpId
    $journal2 = Open-RtJournal $op.OpId
    Write-RtJournal $journal2 @{ kind = 'resume' }
    $plan2 = Get-RtPlan $rc.Op $settings
    Write-RtPlanRecord $journal2 $plan2
    $null = Invoke-RtProtect $rc.Op $plan2 $journal2 $rc.SkipPaths
    $state2 = Start-RtTransfer $rc.Op $plan2 $settings $journal2
    $guard = 0; while (Step-RtTransfer $state2) { Start-Sleep -Milliseconds 20; if (++$guard -gt 3000) { throw 'hang' } }
    Complete-RtOperation $state2 'success'
    $copied = (Get-ChildItem $d -File -Recurse).Count   # files land in $d\src (leaf appended)
    ShouldBe $copied 6 "all 6 files present after resume (got $copied)"
}

# ---------------------------------------------------------------- 7. guards
Check 'guard: destination inside source folder is rejected' {
    $s = Join-Path $work 'g1\folder'
    $null = New-Item -ItemType Directory -Force -Path $s
    $threw = $false
    try { New-RtOperation -Mode copy -Sources @($s) -Destination $s | Out-Null } catch { $threw = $true }
    ShouldBeTrue $threw 'same src/dst rejected'
    $threw = $false
    try { New-RtOperation -Mode copy -Sources @($s) -Destination (Split-Path $s -Parent) | Out-Null } catch { $threw = $true }
    # copying folder into its own parent is allowed (would create parent\folder == source) -> must reject
    ShouldBeTrue $threw 'copy into own parent rejected (dest == source)'
}

Check 'guard: drive-root paths never resolve drive-relatively (System32 bug)' {
    ShouldBe (Get-RtNormalizedPath 'C:') 'C:\' 'bare drive letter pins to the root'
    ShouldBe (Get-RtNormalizedPath 'C:"') 'C:\' 'quote-mangled drive root pins to the root'
    ShouldBe (Get-RtNormalizedPath 'C:\') 'C:\' 'drive root unchanged'
    ShouldBe (Get-RtNormalizedPath ($env:TEMP + '\')) ([System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) 'normal dirs still trim the trailing slash'
}

Check 'guard: install.ps1 params are never clobbered by body assignments' {
    # PowerShell variables are case-insensitive: assigning $repo in the body
    # silently blanks a $Repo parameter (this 404d every "irm | iex" install).
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'install.ps1'), [ref]$tokens, [ref]$errors)
    ShouldBe @($errors).Count 0 'install.ps1 parses clean'
    $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() })
    $assigned = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
        ForEach-Object { $_.Left } |
        Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } |
        ForEach-Object { $_.VariablePath.UserPath.ToLowerInvariant() })
    $clobbered = @($params | Where-Object { $assigned -contains $_ })
    ShouldBe $clobbered.Count 0 ('params reassigned in body: ' + ($clobbered -join ', '))
}

Check 'guard: mirror requires folder source' {
    $f = Join-Path $work 'g2\file.txt'
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent)
    Set-Content $f 'x'
    $threw = $false
    try { New-RtOperation -Mode mirror -Sources @($f) -Destination (Join-Path $work 'g2\out') | Out-Null } catch { $threw = $true }
    ShouldBeTrue $threw 'mirror on a file rejected'
}

# ---------------------------------------------------------------- 8. clipboard parse (STA)
Check 'clipboard paste reads file drop list and copy/cut intent' {
    $f1 = Join-Path $work 'cb\a.txt'; $f2 = Join-Path $work 'cb\b.txt'
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f1 -Parent)
    Set-Content $f1 '1'; Set-Content $f2 '2'
    # run in a dedicated STA process: clipboard APIs require STA
    $script = @"
Add-Type -AssemblyName System.Windows.Forms, PresentationCore, WindowsBase
Import-Module '$repo\src\RobocopyTo.psm1' -Force
`$files = New-Object System.Collections.Specialized.StringCollection
[void]`$files.Add('$($f1 -replace '\\','\\')'); [void]`$files.Add('$($f2 -replace '\\','\\')')
# COPY intent
[System.Windows.Forms.Clipboard]::SetFileDropList(`$files)
`$c = Get-RtClipboardPaste
if (`$c.Files.Count -ne 2) { throw 'expected 2 files' }
if (`$c.IsMove) { throw 'expected copy, not move' }
# MOVE intent via DataObject + Preferred DropEffect = 2
`$dobj = New-Object System.Windows.Forms.DataObject
`$dobj.SetFileDropList(`$files)
`$ms = New-Object System.IO.MemoryStream
`$ms.Write([BitConverter]::GetBytes([int]2), 0, 4); `$ms.Position = 0
`$dobj.SetData('Preferred DropEffect', `$ms)
[System.Windows.Forms.Clipboard]::SetDataObject(`$dobj, `$true)
`$c2 = Get-RtClipboardPaste
if (-not `$c2.IsMove) { throw 'expected move intent' }
[System.Windows.Forms.Clipboard]::Clear()
Write-Output 'CLIP_OK'
"@
    $tmp = Join-Path $work 'cb\clip.ps1'
    Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $tmp 2>&1 | Out-String
    ShouldBeTrue ($out -match 'CLIP_OK') "clipboard subtest output: $out"
}

# ---------------------------------------------------------------- 9. registration against a temp hive
Check 'registry-verb registration builds the expected tree' {
    . (Join-Path $repo 'packaging\register-shell.ps1')
    $root = 'HKCU:\Software\RobocopyTo-TestHive\Classes'
    Remove-Item -Path 'HKCU:\Software\RobocopyTo-TestHive' -Recurse -Force -ErrorAction SilentlyContinue
    Register-RtRegistryMenu -LauncherExe 'C:\fake\RobocopyTo.exe' -Root $root
    # directory target should have the parent verb pointing at its store
    $dirVerb = "$root\Directory\shell\RobocopyTo"
    ShouldBeTrue (Test-Path $dirVerb) 'directory parent verb exists'
    ShouldBe (Get-ItemProperty $dirVerb).ExtendedSubCommandsKey 'RobocopyTo.Menu.Directory' 'ExtendedSubCommandsKey set'
    ShouldBeTrue ($null -eq (Get-ItemProperty $dirVerb).Icon) 'text-only: no icon on the parent verb'
    $leafCmd = "$root\RobocopyTo.Menu.Directory\shell\00copyto\command"
    ShouldBeTrue (Test-Path $leafCmd) 'copyto leaf command exists'
    ShouldBeTrue ((Get-ItemProperty $leafCmd).'(default)' -match '--verb copyto') 'leaf command has verb'
    # undo rides every target, selection-free (no --path token)
    $undoCmd = "$root\RobocopyTo.Menu.Directory\shell\04undo\command"
    ShouldBeTrue (Test-Path $undoCmd) 'undo leaf exists on Directory'
    ShouldBeTrue ((Get-ItemProperty $undoCmd).'(default)' -notmatch '--path') 'undo command takes no path'
    # background target = paste + undo only
    ShouldBeTrue (-not (Test-Path "$root\RobocopyTo.Menu.Background\shell\00copyto")) 'no copyto on background'
    ShouldBeTrue (Test-Path "$root\RobocopyTo.Menu.Background\shell\00paste") 'paste on background'
    ShouldBeTrue (Test-Path "$root\RobocopyTo.Menu.Background\shell\01undo") 'undo on background'
    # files target = copy/move/undo, no paste or mirror
    ShouldBeTrue (Test-Path "$root\RobocopyTo.Menu.AllFiles\shell\02undo") 'undo on files'
    ShouldBeTrue (-not (Test-Path "$root\RobocopyTo.Menu.AllFiles\shell\01mirrorto")) 'no mirror on files'
    # cleanup + verify unregister is thorough
    Unregister-RtRegistryMenu -Root $root
    ShouldBeTrue (-not (Test-Path $dirVerb)) 'unregister removed parent verb'
    Remove-Item -Path 'HKCU:\Software\RobocopyTo-TestHive' -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 10. native DLL state (if built)
Check 'native DLL: Robopaste state tracks clipboard (skipped if DLL absent)' {
    $dll = Join-Path $repo 'native\build\RobocopyToMenu.dll'
    if (-not (Test-Path $dll)) { Write-Host '      (DLL not built; skipping)' -ForegroundColor DarkGray; return }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\dll-smoke.ps1') 2>&1 | Out-String
    ShouldBeTrue ($out -match 'DLL SMOKE PASS') "DLL smoke output tail: $($out -split "`n" | Select-Object -Last 3)"
}

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host ("Results: $script:Pass passed, $script:Fail failed") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepArtifacts) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "artifacts kept at $work" }
# drop the sandbox: env reroute + the test marker hive
Remove-Item Env:\ROBOCOPYTO_DATA -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\RobocopyTo-Test' -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($script:Fail) { 1 } else { 0 })
