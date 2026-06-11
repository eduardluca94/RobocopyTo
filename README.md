# RobocopyTo

Add **Copy to… / Mirror to… / Move to… / Robopaste / Undo** to the Windows right-click
menu, powered by [`robocopy`](https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy)
— resumable, multithreaded, long-path-safe — behind a Windows 11-style progress dialog
with a live throughput graph.

Per-user install, **no admin required**, no background processes, no telemetry, and
**zero disk residue**: your files live where you put them and nowhere else. MIT licensed.

## Why

Explorer's built-in copy is fine until it isn't: a dropped network connection, a path
over 260 characters, a multi-hour transfer with no resume, millions of small files.
`robocopy` handles all of that — but it's a command line. RobocopyTo puts it one
right-click away and wraps it in the dialog you already know.

## What you get

- **Copy to… / Move to…** — pick a destination, watch a native-style progress dialog
  with a throughput graph, speed, time remaining, pause, and cancel. On success the
  dialog closes by itself, like Windows' own.
- **Mirror to…** — make a destination an exact copy of a folder (asks first; files not
  in the source are removed).
- **Robopaste** — paste a copied/cut selection into a folder via robocopy. Greys out
  when the clipboard holds no files.
- **Undo** — right in the context menu, greyed out when there is nothing to undo.
  "Undo copy" removes what the last operation created; "Undo move" puts files back.
- **Cancel = revert** — cancelling a running transfer puts everything back exactly as
  it was, including files the transfer had already replaced.
- The menu is text-only and the dialogs follow your light/dark mode.

## Safety model (zero residue)

Every operation runs in phases:

1. **Plan** — a dry run (`robocopy /L`) computes exactly what will be created, what
   would be overwritten, what a mirror would remove, and the total byte count.
2. **Protect** — anything that would be overwritten or removed is first renamed into a
   hidden same-volume staging folder. The transfer itself only ever *creates* files.
3. **Transfer** — journaled file by file; pause and cancel any time. Cancel stops
   robocopy and restores the staged originals — a seamless revert.
4. **Settle** — the moment an operation succeeds, staging is deleted. No retention
   windows, no shadow copies, no leftovers anywhere.

Because staging never outlives an operation, **Undo after success** is honest about
what it can do: files the operation *created* are removed (skipped if you modified
them since), moved files are moved back, and files that *replaced* existing ones are
kept and flagged — the originals are gone, so deleting the replacements would be data
loss, not undo. Failed transfers keep their staging until you choose **Resume**,
**Roll back**, or **Keep as-is** in the dialog.

## Install

From a [release](https://github.com/eduardluca94/RobocopyTo/releases):

```powershell
# one-liner (downloads the latest release and installs)
irm https://github.com/eduardluca94/RobocopyTo/releases/latest/download/install.ps1 | iex
```

or download **`RobocopyTo.zip`**, extract, and run `install.ps1` — or double-click
**`RobocopyTo-setup.exe`** for a dialog-only flow. (Heads-up: the single-file exe is
the kind of unsigned self-extractor that antivirus heuristics sometimes flag; the zip
and the one-liner are the reliable paths.)

From source:

```powershell
git clone https://github.com/eduardluca94/RobocopyTo
cd RobocopyTo
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Then right-click any file, folder, drive, or folder background → **Robocopy**.

### The Windows 11 top-level menu

By default the entry lives under **Show more options** (Shift+F10). The installer
offers to promote it to the top-level Windows 11 menu; that registers a sparse MSIX
package and — for signed releases — trusts the RobocopyTo package certificate in the
machine's `TrustedPeople` store (one admin approval; that store only governs package
installs). Unsigned builds can do the same with Developer Mode enabled. Drives keep
their entry under "Show more options" — Windows does not allow drive verbs in the
top-level menu.

### Uninstall

Any of: **Settings → Apps → Installed apps → RobocopyTo**, the **Uninstall button** in
RobocopyTo's own settings (About tab), or `uninstall.ps1` (`-Purge` also removes
history/logs/settings, `-RemoveTrust` also removes the package certificate trust).

## Requirements

- Windows 10/11, PowerShell 5.1+ and .NET Framework 4.x (both in-box).
- Releases ship the prebuilt menu component (x64 + ARM64). Building it from source
  needs Visual Studio C++ Build Tools; without either, the installer falls back to a
  registry-verb menu that works the same way.

## Settings

Right-click → **Robocopy → RobocopyTo settings**.

| Setting | Default | Notes |
|---|---|---|
| Multithreading | Automatic | `/MT:8` for many small files; "Off" gives the smoothest single-file progress |
| Restartable mode (`/Z`) | off | Resume inside very large files; slightly slower |
| Skip junctions (`/XJ`) | on | Protects against folder loops |
| Extra robocopy options | — | Appended verbatim to transfer runs |
| Confirm before Mirror | on | Mirror removes destination extras |
| Confirm before Move | off | Explorer does not confirm moves either |

The History tab lists recent operations with per-operation **Undo** and **Open log**.
Logs, journals, and settings live in `%LOCALAPPDATA%\RobocopyTo` (history is pruned
automatically; logs follow).

## How it works

A small PowerShell module (`src/`) drives robocopy and renders the WPF dialog. A
windowless `RobocopyTo.exe` shim (compiled at install time by the in-box C# compiler)
launches it without a console flash. A native `IExplorerCommand` component (`native/`)
provides the menu with live Robopaste/Undo states; a registry-verb fallback covers
machines without it. The sparse-package scaffold for the top-level menu lives in
`packaging/`.

## Development

```powershell
# headless test suite - fully sandboxed, leaves nothing on the machine
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\run-tests.ps1

# native menu component (needs VS C++ tools)
powershell -NoProfile -ExecutionPolicy Bypass -File .\native\build.ps1

# full release bundle (zip, single-file exe, sparse package; -SelfSign to sign)
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\make-release.ps1
```

## License

MIT — see [LICENSE](LICENSE).
