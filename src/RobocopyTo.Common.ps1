# RobocopyTo.Common.ps1 - shared plumbing: paths, settings, journal, interop loader.
# Library file: dot-source it; defines functions/variables only. ASCII-only source (PS 5.1 safe).

$script:RtAppName = 'RobocopyTo'
# ROBOCOPYTO_DATA reroutes all app data (settings, journal, logs, staging preference,
# last-op marker) so the test suite never touches the real per-user store.
$script:RtAppDir  = if ($env:ROBOCOPYTO_DATA) { $env:ROBOCOPYTO_DATA } else { Join-Path $env:LOCALAPPDATA $RtAppName }
$script:RtMarkerKey = if ($env:ROBOCOPYTO_DATA) { 'HKCU:\Software\RobocopyTo-Test' } else { 'HKCU:\Software\RobocopyTo' }
$script:RtLogDir  = Join-Path $RtAppDir 'logs'
$script:RtJournalDir = Join-Path $RtAppDir 'journal'
$script:RtSettingsPath = Join-Path $RtAppDir 'settings.json'
$script:RtRobocopy = Join-Path $env:SystemRoot 'System32\Robocopy.exe'
$script:RtStagingDirName = '$RobocopyTo.staging'

function Initialize-RtEnvironment {
    foreach ($d in @($script:RtAppDir, $script:RtLogDir, $script:RtJournalDir)) {
        if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
    }
    if (-not ('RobocopyTo.Native' -as [type])) {
        # the installer precompiles the interop; Add-Type's per-launch csc spawn is
        # the most expensive piece of menu-click -> dialog latency. Source compile
        # stays as the fallback for repo/test runs.
        $pre = Join-Path $PSScriptRoot 'RobocopyTo.Native.dll'
        if (Test-Path -LiteralPath $pre) { Add-Type -Path $pre }
        else { Add-Type -Path (Join-Path $PSScriptRoot 'Interop.cs') -ReferencedAssemblies 'System.Windows.Forms' }
    }
}

# WPF assemblies load lazily: the folder picker is pure Win32 COM, so the
# click -> picker path never pays for them. Idempotent, cheap once loaded.
function Initialize-RtWpf {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
}

# ----------------------------------------------------------------- settings
$script:RtDefaultSettings = [ordered]@{
    retries                = 2        # robocopy /R
    waitSeconds            = 2        # robocopy /W
    threadsPolicy          = 'auto'   # auto | off | 8 | 16 | 32
    restartableMode        = $false   # robocopy /Z
    excludeJunctions       = $true    # robocopy /XJ
    extraArgs              = @()      # appended verbatim to transfer runs
    journalRetentionCount  = 40       # operations kept in history (logs follow journals)
    detailsExpanded        = $true    # progress dialog graph area expanded
    confirmMirror          = $true
    confirmMove            = $false   # Explorer does not confirm moves either
}

function Get-RtSettings {
    $s = @{}
    foreach ($k in $script:RtDefaultSettings.Keys) { $s[$k] = $script:RtDefaultSettings[$k] }
    if (Test-Path -LiteralPath $script:RtSettingsPath) {
        try {
            $json = Get-Content -LiteralPath $script:RtSettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value }
            }
        } catch { Write-RtLog "settings.json unreadable, using defaults: $_" }
    }
    return $s
}

function Save-RtSettings([hashtable]$Settings) {
    $ordered = [ordered]@{}
    foreach ($k in $script:RtDefaultSettings.Keys) {
        if ($Settings.ContainsKey($k)) { $ordered[$k] = $Settings[$k] } else { $ordered[$k] = $script:RtDefaultSettings[$k] }
    }
    ($ordered | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:RtSettingsPath -Encoding UTF8
}

# ------------------------------------------------------------------ logging
$script:RtLogFile = $null
function Open-RtLog([string]$OpId) {
    $script:RtLogFile = Join-Path $script:RtLogDir ($OpId + '.log')
}
function Write-RtLog([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
    if ($script:RtLogFile) { Add-Content -LiteralPath $script:RtLogFile -Value $line -Encoding UTF8 }
}

# ------------------------------------------------------------------ journal
# One JSONL file per operation: first line = header, then events, last line = footer.
function New-RtOpId {
    return (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Open-RtJournal([string]$OpId) {
    $path = Join-Path $script:RtJournalDir ($OpId + '.jsonl')
    $sw = New-Object System.IO.StreamWriter($path, $true, (New-Object System.Text.UTF8Encoding($false)))
    $sw.AutoFlush = $true
    return @{ Path = $path; Writer = $sw; OpId = $OpId }
}

function Write-RtJournal($Journal, [hashtable]$Record) {
    $Record['t'] = [DateTime]::UtcNow.ToString('o')
    $Journal.Writer.WriteLine(($Record | ConvertTo-Json -Compress -Depth 6))
}

function Close-RtJournal($Journal) {
    if ($Journal -and $Journal.Writer) { $Journal.Writer.Dispose(); $Journal.Writer = $null }
}

function Read-RtJournal([string]$PathOrOpId) {
    $path = $PathOrOpId
    if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $script:RtJournalDir ($PathOrOpId + '.jsonl') }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line.Trim()) { $records.Add((ConvertFrom-Json $line)) }
    }
    return ,$records.ToArray()
}

function Get-RtJournalList {
    Get-ChildItem -LiteralPath $script:RtJournalDir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
}

# Cheap journal digest: first four lines (header/plan/stagingRoot) + last 4KB
# (footer/undone), so callers never parse hundred-thousand-line journals.
function Get-RtJournalDigest([string]$JournalPath) {
    try {
        $header = $null; $plan = $null; $sroot = $null
        $reader = New-Object System.IO.StreamReader($JournalPath)
        try {
            for ($i = 0; $i -lt 4; $i++) {
                $line = $reader.ReadLine()
                if (-not $line) { break }
                $rec = ConvertFrom-Json $line
                if ($rec.kind -eq 'header') { $header = $rec }
                elseif ($rec.kind -eq 'plan') { $plan = $rec }
                elseif ($rec.kind -eq 'stagingRoot') { $sroot = [string]$rec.path }
            }
        } finally { $reader.Dispose() }
        if (-not $header) { return $null }

        $fs = [System.IO.File]::Open($JournalPath, 'Open', 'Read', 'ReadWrite')
        $tailText = ''
        try {
            $take = [Math]::Min(4096L, $fs.Length)
            $fs.Seek(-$take, 'End') | Out-Null
            $buf = New-Object byte[] $take
            $null = $fs.Read($buf, 0, $take)
            $tailText = [System.Text.Encoding]::UTF8.GetString($buf)
        } finally { $fs.Dispose() }
        $footer = $null; $undone = $false
        foreach ($line in ($tailText -split "`n")) {
            $line = $line.Trim()
            if (-not $line -or -not $line.StartsWith('{')) { continue }
            try {
                $rec = ConvertFrom-Json $line
                if ($rec.kind -eq 'footer') { $footer = $rec }
                if ($rec.kind -eq 'undone') { $undone = $true }
            } catch { }
        }
        $status = if ($undone) { 'undone' } elseif ($footer) { [string]$footer.status } else { 'interrupted' }
        return @{
            OpId = [System.IO.Path]::GetFileNameWithoutExtension($JournalPath)
            Op = [string]$header.op; Sources = @($header.sources); Dest = [string]$header.dest
            Files = $(if ($plan) { [long]$plan.files } else { 0 })
            Bytes = $(if ($plan) { [long]$plan.bytes } else { 0 })
            Status = $status; StagingRoot = $sroot
        }
    } catch { return $null }
}

# Last-undoable-operation marker: the context menu's Undo entry reads these two
# registry values for instant GetState/GetTitle. Refreshed after every terminal
# operation and after every undo.
function Set-RtLastOpMarker([string]$OpId, [string]$Verb) {
    try {
        if (-not (Test-Path -LiteralPath $script:RtMarkerKey)) { $null = New-Item -Path $script:RtMarkerKey -Force }
        Set-ItemProperty -LiteralPath $script:RtMarkerKey -Name 'LastUndoableOp' -Value ([string]$OpId)
        Set-ItemProperty -LiteralPath $script:RtMarkerKey -Name 'LastUndoableVerb' -Value ([string]$Verb)
    } catch { }
}

function Get-RtLastOpMarker {
    try {
        $v = Get-ItemProperty -LiteralPath $script:RtMarkerKey -ErrorAction Stop
        return @{ OpId = [string]$v.LastUndoableOp; Verb = [string]$v.LastUndoableVerb }
    } catch { return @{ OpId = ''; Verb = '' } }
}

# ------------------------------------------------------------------ helpers
function Format-RtBytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Format-RtSpeed([double]$BytesPerSec) {
    if ($BytesPerSec -ge 1GB) { return ('{0:N2} GB/s' -f ($BytesPerSec / 1GB)) }
    if ($BytesPerSec -ge 1MB) { return ('{0:N1} MB/s' -f ($BytesPerSec / 1MB)) }
    return ('{0:N0} KB/s' -f ([Math]::Max(0, $BytesPerSec) / 1KB))
}

# Normalize a shell-supplied path: strip the "\." suffix trick, resolve, trim trailing slash
# (drive roots keep "C:\" form).
function Get-RtNormalizedPath([string]$Path) {
    $p = $Path.Trim('"')
    $full = [System.IO.Path]::GetFullPath($p)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-RtSubPath([string]$Parent, [string]$Child) {
    $p = $Parent.TrimEnd('\') + '\'
    $c = $Child.TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RtLeafName([string]$Path) {
    if ($Path -match '^[A-Za-z]:\\?$') { return ($Path.Substring(0, 1) + '_drive') }
    return (Split-Path -Path $Path -Leaf)
}

# Quote args for a robocopy command line. Paths never contain quotes; quote when spaces present.
# Trailing-backslash paths (drive roots) contain no spaces, so they stay unquoted and unmangled.
function ConvertTo-RtArgString([string[]]$Arguments) {
    return (($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
}

# --------------------------------------------------------------- clipboard
# Reads an Explorer copy/cut selection from the clipboard.
# Returns @{ Files = string[]; IsMove = bool } or $null when no files present.
# 'Preferred DropEffect' is 2 (DROPEFFECT_MOVE) after Ctrl+X, 5 (COPY|LINK) after Ctrl+C.
function Get-RtClipboardPaste {
    Initialize-RtWpf
    if (-not [Windows.Clipboard]::ContainsFileDropList()) { return $null }
    $list = [Windows.Clipboard]::GetFileDropList()
    if (-not $list -or $list.Count -eq 0) { return $null }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($f in $list) { if ($f) { $files.Add([string]$f) } }
    if ($files.Count -eq 0) { return $null }
    $isMove = $false
    try {
        $data = [Windows.Clipboard]::GetDataObject()
        $eff = $data.GetData('Preferred DropEffect')
        if ($eff -is [System.IO.Stream]) {
            $buf = New-Object byte[] 4
            $null = $eff.Read($buf, 0, 4)
            $isMove = (([BitConverter]::ToInt32($buf, 0)) -band 2) -eq 2 -and (([BitConverter]::ToInt32($buf, 0)) -band 1) -eq 0
        }
    } catch { }
    return @{ Files = $files.ToArray(); IsMove = $isMove }
}
