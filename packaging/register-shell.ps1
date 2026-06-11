# register-shell.ps1 - shell context-menu registration helpers (dot-sourced by
# install.ps1 / uninstall.ps1). Two strategies:
#   * Register-RtComMenu      - native IExplorerCommand DLL (grey-out + flyout)
#   * Register-RtRegistryMenu - static verbs (no DLL; cascading submenu)
# Both are per-user (HKCU\Software\Classes); no admin, nothing machine-wide.
#
# Every function takes -Root (default HKCU:\Software\Classes) so the whole tree can
# be built against a throwaway hive in tests without touching the live shell.

$script:RtComClsid = '{6F1A3B58-2D94-4E1C-9C7A-8B5E0D4F2A17}'
$script:RtDefaultRoot = 'HKCU:\Software\Classes'

# Shell targets (relative to -Root) and which verbs make sense on each:
#   *                    = any file (copy/move; no mirror/paste on a file)
#   Directory            = a folder (everything; paste lands inside it)
#   Directory\Background = empty space in a folder (no source selected)
#   Drive                = a drive root (everything)
# Undo acts on the journal, not the selection, so it appears everywhere.
# Token differs: background passes the folder as %V, the rest pass the item as %1.
$script:RtTargets = @(
    @{ Name = 'AllFiles';  Rel = '*\shell';                    Token = '%1'; Verbs = @('copyto','moveto','undo') },
    @{ Name = 'Directory';  Rel = 'Directory\shell';            Token = '%1'; Verbs = @('copyto','mirrorto','moveto','paste','undo') },
    @{ Name = 'Background'; Rel = 'Directory\Background\shell'; Token = '%V'; Verbs = @('paste','undo') },
    @{ Name = 'Drive';      Rel = 'Drive\shell';                Token = '%1'; Verbs = @('copyto','mirrorto','moveto','paste','undo') }
)

# The menu is text-only by design: no Icon values are written, and stale ones
# from earlier versions are actively removed on (re)registration.
$script:RtVerbDefs = [ordered]@{
    copyto   = @{ Label = 'Copy to...';   Multi = $true;  NoPath = $false }
    mirrorto = @{ Label = 'Mirror to...'; Multi = $true;  NoPath = $false }
    moveto   = @{ Label = 'Move to...';   Multi = $true;  NoPath = $false }
    paste    = @{ Label = 'Robopaste';    Multi = $false; NoPath = $false }
    undo     = @{ Label = 'Undo';         Multi = $false; NoPath = $true  }
}

# ----------------------------------------------------------- COM (native DLL)
function Register-RtComMenu {
    param([string]$Dll, [string]$Clsid, [string]$Root = $script:RtDefaultRoot)

    $inproc = "$Root\CLSID\$Clsid\InprocServer32"
    $null = New-Item -Path $inproc -Force
    Set-ItemProperty -Path $inproc -Name '(default)' -Value $Dll
    Set-ItemProperty -Path $inproc -Name 'ThreadingModel' -Value 'Apartment'
    Set-ItemProperty -Path "$Root\CLSID\$Clsid" -Name '(default)' -Value 'RobocopyTo Shell Menu'

    foreach ($t in $script:RtTargets) {
        $verbKey = "$Root\$($t.Rel)\RobocopyTo"
        $null = New-Item -Path $verbKey -Force
        Set-ItemProperty -Path $verbKey -Name '(default)' -Value 'Robocopy'
        Set-ItemProperty -Path $verbKey -Name 'ExplorerCommandHandler' -Value $Clsid
        Remove-ItemProperty -Path $verbKey -Name 'Icon' -ErrorAction SilentlyContinue
    }
}

function Unregister-RtComMenu {
    param([string]$Clsid = $script:RtComClsid, [string]$Root = $script:RtDefaultRoot)
    foreach ($t in $script:RtTargets) {
        Remove-Item -Path "$Root\$($t.Rel)\RobocopyTo" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path "$Root\CLSID\$Clsid" -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------- registry-verb fallback
# Cascading submenu via ExtendedSubCommandsKey: the top "Robocopy" entry points at
# a per-target command store (its own key so the %1 vs %V token is correct), whose
# \shell subkey holds the leaf verbs. Leaf order is set by a 2-digit prefix.
function Register-RtRegistryMenu {
    param([string]$LauncherExe, [string]$Root = $script:RtDefaultRoot)

    foreach ($t in $script:RtTargets) {
        $storeName = "RobocopyTo.Menu.$($t.Name)"    # sibling under $Root
        $storeShell = "$Root\$storeName\shell"
        Remove-Item -Path "$Root\$storeName" -Recurse -Force -ErrorAction SilentlyContinue

        $i = 0
        foreach ($verbId in $t.Verbs) {
            $def = $script:RtVerbDefs[$verbId]
            $leaf = "$storeShell\$('{0:D2}{1}' -f $i, $verbId)"; $i++
            $null = New-Item -Path "$leaf\command" -Force
            Set-ItemProperty -Path $leaf -Name 'MUIVerb' -Value $def.Label
            if ($def.Multi -and $t.Token -eq '%1') { Set-ItemProperty -Path $leaf -Name 'MultiSelectModel' -Value 'Player' }
            $cmd = if ($def.NoPath) { "`"$LauncherExe`" --verb $verbId" }
                   else { "`"$LauncherExe`" --verb $verbId --path `"$($t.Token)`"" }
            Set-ItemProperty -Path "$leaf\command" -Name '(default)' -Value $cmd
        }

        $verbKey = "$Root\$($t.Rel)\RobocopyTo"
        $null = New-Item -Path $verbKey -Force
        Set-ItemProperty -Path $verbKey -Name 'MUIVerb' -Value 'Robocopy'
        Remove-ItemProperty -Path $verbKey -Name 'Icon' -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $verbKey -Name 'ExtendedSubCommandsKey' -Value $storeName
    }
}

function Unregister-RtRegistryMenu {
    param([string]$Root = $script:RtDefaultRoot)
    foreach ($t in $script:RtTargets) {
        Remove-Item -Path "$Root\$($t.Rel)\RobocopyTo" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$Root\RobocopyTo.Menu.$($t.Name)" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path "$Root\RobocopyTo.Commands" -Recurse -Force -ErrorAction SilentlyContinue  # legacy
}
