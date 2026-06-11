# CoCreate smoke test for RobocopyToMenu.dll (no Explorer needed).
# This test session is elevated and elevated processes ignore HKCU COM classes,
# so it registers in HKLM temporarily (removed at the end). The real installer
# registers per-user in HKCU - Explorer is not elevated.
$ErrorActionPreference = 'Stop'
$clsid = '{6F1A3B58-2D94-4E1C-9C7A-8B5E0D4F2A17}'
$repo = Split-Path $PSScriptRoot -Parent
$dll = Join-Path $repo 'native\build\RobocopyToMenu.dll'

$key = "HKLM:\Software\Classes\CLSID\$clsid\InprocServer32"
$null = New-Item -Path $key -Force
Set-ItemProperty -Path $key -Name '(default)' -Value $dll
Set-ItemProperty -Path $key -Name 'ThreadingModel' -Value 'Apartment'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace RtTest {
    [ComImport, Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IExplorerCommand {
        void GetTitle(IntPtr psiItemArray, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetIcon(IntPtr psiItemArray, [MarshalAs(UnmanagedType.LPWStr)] out string ppszIcon);
        void GetToolTip(IntPtr psiItemArray, [MarshalAs(UnmanagedType.LPWStr)] out string ppszInfotip);
        void GetCanonicalName(out Guid pguidCommandName);
        void GetState(IntPtr psiItemArray, [MarshalAs(UnmanagedType.Bool)] bool fOkToBeSlow, out uint pCmdState);
        void Invoke(IntPtr psiItemArray, IntPtr pbc);
        void GetFlags(out uint pFlags);
        void EnumSubCommands(out IEnumExplorerCommand ppEnum);
    }
    [ComImport, Guid("a88826f8-186f-4987-aade-ea0cef8fbfe8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IEnumExplorerCommand {
        [PreserveSig] int Next(uint celt, [MarshalAs(UnmanagedType.Interface)] out IExplorerCommand pUICommand, out uint pceltFetched);
        [PreserveSig] int Skip(uint celt);
        void Reset();
        void Clone(out IEnumExplorerCommand ppenum);
    }
    public static class Harness {
        private static IExplorerCommand _root;
        private static List<IExplorerCommand> _subs = new List<IExplorerCommand>();

        public static string Init(string clsid) {
            Type t = Type.GetTypeFromCLSID(new Guid(clsid));
            object o = Activator.CreateInstance(t);
            _root = (IExplorerCommand)o;
            string title; _root.GetTitle(IntPtr.Zero, out title);
            uint flags; _root.GetFlags(out flags);
            IEnumExplorerCommand en; _root.EnumSubCommands(out en);
            List<string> names = new List<string>();
            while (true) {
                IExplorerCommand sub; uint fetched;
                int hr = en.Next(1, out sub, out fetched);
                if (hr != 0 || fetched == 0) break;
                string st; sub.GetTitle(IntPtr.Zero, out st);
                _subs.Add(sub);
                names.Add(st);
            }
            return title + "|0x" + flags.ToString("X") + "|" + string.Join(";", names);
        }
        public static uint StateOf(int index) {
            uint s; _subs[index].GetState(IntPtr.Zero, true, out s);
            return s;
        }
        public static string TitleOf(int index) {
            string t; _subs[index].GetTitle(IntPtr.Zero, out t);
            return t;
        }
    }
}
"@

function Assert($cond, $msg) { if (-not $cond) { Write-Output "FAIL: $msg"; exit 1 } else { Write-Output "ok: $msg" } }

# the Undo entry reads the live HKCU marker - save it, drive it, restore it
$mk = 'HKCU:\Software\RobocopyTo'
$null = New-Item -Path $mk -Force -ErrorAction SilentlyContinue
$prev = Get-ItemProperty -Path $mk -ErrorAction SilentlyContinue
$prevOp = if ($prev) { $prev.LastUndoableOp } else { $null }
$prevVerb = if ($prev) { $prev.LastUndoableVerb } else { $null }

try {
    Set-ItemProperty -Path $mk -Name 'LastUndoableOp' -Value ''
    Set-ItemProperty -Path $mk -Name 'LastUndoableVerb' -Value ''

    $info = [RtTest.Harness]::Init($clsid)
    Write-Output "init: $info"
    $parts = $info.Split('|')
    Assert ($parts[0] -eq 'Robocopy') "root title 'Robocopy'"
    Assert ($parts[1] -eq '0x1') "root flags ECF_HASSUBCOMMANDS (=0x1)"
    $names = $parts[2].Split(';')
    Assert ($names.Count -eq 6) "six subcommands (got $($names.Count): $($parts[2]))"
    # order: 0=copyto 1=mirrorto 2=moveto 3=paste 4=undo 5=settings
    Assert ($names[0] -like 'Copy to*') "first entry is Copy to (got '$($names[0])')"
    Assert ($names[3] -eq 'Robopaste') "fourth entry is Robopaste"
    Assert ($names[5] -eq 'RobocopyTo settings') "last entry is settings"

    [System.Windows.Forms.Clipboard]::Clear()
    $s = [RtTest.Harness]::StateOf(3)
    Assert ($s -eq 1) "Robopaste DISABLED with empty clipboard (state=$s)"

    $files = New-Object System.Collections.Specialized.StringCollection
    $null = $files.Add((Join-Path $repo 'LICENSE'))
    [System.Windows.Forms.Clipboard]::SetFileDropList($files)
    $s = [RtTest.Harness]::StateOf(3)
    Assert ($s -eq 0) "Robopaste ENABLED with files on clipboard (state=$s)"
    [System.Windows.Forms.Clipboard]::Clear()

    $s = [RtTest.Harness]::StateOf(0)
    Assert ($s -eq 0) "'$($names[0])' enabled"

    # undo entry follows the last-op marker: state and dynamic title
    $s = [RtTest.Harness]::StateOf(4)
    Assert ($s -eq 1) "Undo DISABLED with empty marker (state=$s)"
    Assert ([RtTest.Harness]::TitleOf(4) -eq 'Undo') "Undo title plain with empty marker"

    Set-ItemProperty -Path $mk -Name 'LastUndoableOp' -Value '20990101-000000-test'
    Set-ItemProperty -Path $mk -Name 'LastUndoableVerb' -Value 'copy'
    $s = [RtTest.Harness]::StateOf(4)
    Assert ($s -eq 0) "Undo ENABLED with marker set (state=$s)"
    Assert ([RtTest.Harness]::TitleOf(4) -eq 'Undo copy') "Undo title becomes 'Undo copy'"
} finally {
    if ($null -ne $prevOp) { Set-ItemProperty -Path $mk -Name 'LastUndoableOp' -Value $prevOp }
    else { Remove-ItemProperty -Path $mk -Name 'LastUndoableOp' -ErrorAction SilentlyContinue }
    if ($null -ne $prevVerb) { Set-ItemProperty -Path $mk -Name 'LastUndoableVerb' -Value $prevVerb }
    else { Remove-ItemProperty -Path $mk -Name 'LastUndoableVerb' -ErrorAction SilentlyContinue }
    Remove-Item "HKLM:\Software\Classes\CLSID\$clsid" -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'DLL SMOKE PASS'
