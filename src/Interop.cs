// RobocopyTo interop layer. Compiled at runtime via Add-Type (PowerShell 5.1 / C# 5 syntax only).
// Everything here is deliberately boring Win32/COM plumbing; the interesting logic lives in the .ps1 files.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace RobocopyTo
{
    // ---------------------------------------------------------------- Win32
    public static class Native
    {
        public const uint MOVEFILE_COPY_ALLOWED = 0x2;
        public const uint MOVEFILE_WRITE_THROUGH = 0x8;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileExW(string src, string dst, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CreateDirectoryW(string path, IntPtr sa);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool DeleteFileW(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool RemoveDirectoryW(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetFileAttributesW(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetFileAttributesW(string path, uint attrs);

        [DllImport("ntdll.dll")]
        public static extern int NtSuspendProcess(IntPtr handle);

        [DllImport("ntdll.dll")]
        public static extern int NtResumeProcess(IntPtr handle);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        // Prefix a fully-qualified path with \\?\ so renames/deletes survive >260 chars.
        public static string Extend(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path.Substring(2);
            return @"\\?\" + path;
        }

        public static void Rename(string src, string dst)
        {
            if (!MoveFileExW(Extend(src), Extend(dst), MOVEFILE_WRITE_THROUGH))
            {
                int err = Marshal.GetLastWin32Error();
                // cross-volume staging fallback: allow copy+delete
                if (err == 17 /*ERROR_NOT_SAME_DEVICE*/)
                {
                    if (MoveFileExW(Extend(src), Extend(dst), MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH)) return;
                    err = Marshal.GetLastWin32Error();
                }
                throw new System.ComponentModel.Win32Exception(err, "MoveFileEx failed: " + src + " -> " + dst);
            }
        }

        public static void EnsureDirectory(string path)
        {
            // walk up creating; CreateDirectoryW with \\?\ for long-path safety
            if (Directory.Exists(Extend(path)) || Directory.Exists(path)) return;
            string parent = Path.GetDirectoryName(path);
            if (parent != null && parent.Length > 3) EnsureDirectory(parent);
            if (!CreateDirectoryW(Extend(path), IntPtr.Zero))
            {
                int err = Marshal.GetLastWin32Error();
                if (err != 183 /*ERROR_ALREADY_EXISTS*/)
                    throw new System.ComponentModel.Win32Exception(err, "CreateDirectory failed: " + path);
            }
        }

        public static void MakeHiddenSystem(string path)
        {
            uint a = GetFileAttributesW(Extend(path));
            if (a != 0xFFFFFFFF) SetFileAttributesW(Extend(path), a | 0x2 | 0x4); // hidden | system
        }

        public static void SuspendProcess(Process p) { NtSuspendProcess(p.Handle); }
        public static void ResumeProcess(Process p) { NtResumeProcess(p.Handle); }
    }

    // ------------------------------------------------------- robocopy runner
    public enum RoboEventKind { Line = 0, Percent = 1, Exited = 2 }

    public class RoboEvent
    {
        public RoboEventKind Kind;
        public string Text;
        public double Percent;
        public int ExitCode;
    }

    // Spawns robocopy hidden, pumps stdout on a background thread, tokenizes on \r and \n,
    // classifies percent ticks vs. content lines, and exposes a queue the UI thread drains.
    public class RoboRunner
    {
        public ConcurrentQueue<RoboEvent> Events = new ConcurrentQueue<RoboEvent>();
        public Process Process;
        private Thread _pump;
        private static readonly Regex PercentRx = new Regex(@"^\s*(\d{1,3}(?:\.\d+)?)%\s*$", RegexOptions.Compiled);

        public void Start(string exe, string args)
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = exe;
            psi.Arguments = args;
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            try { psi.StandardOutputEncoding = Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage); }
            catch (Exception) { psi.StandardOutputEncoding = Encoding.Default; }
            Process = Process.Start(psi);
            Process.ErrorDataReceived += delegate { };
            Process.BeginErrorReadLine();
            _pump = new Thread(PumpLoop);
            _pump.IsBackground = true;
            _pump.Start();
        }

        private void PumpLoop()
        {
            StringBuilder buf = new StringBuilder(512);
            StreamReader r = Process.StandardOutput;
            char[] one = new char[1];
            while (true)
            {
                int n;
                try { n = r.Read(one, 0, 1); } catch (Exception) { break; }
                if (n <= 0) break;
                char c = one[0];
                if (c == '\r' || c == '\n')
                {
                    EmitToken(buf.ToString());
                    buf.Length = 0;
                }
                else buf.Append(c);
            }
            EmitToken(buf.ToString());
            try { Process.WaitForExit(); } catch (Exception) { }
            RoboEvent done = new RoboEvent();
            done.Kind = RoboEventKind.Exited;
            int code = -1;
            try { code = Process.ExitCode; } catch (Exception) { }
            done.ExitCode = code;
            Events.Enqueue(done);
        }

        private void EmitToken(string token)
        {
            if (token == null || token.Trim().Length == 0) return;
            Match m = PercentRx.Match(token);
            RoboEvent ev = new RoboEvent();
            if (m.Success)
            {
                ev.Kind = RoboEventKind.Percent;
                ev.Percent = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
            }
            else
            {
                ev.Kind = RoboEventKind.Line;
                ev.Text = token;
            }
            Events.Enqueue(ev);
        }

        public void Suspend() { if (Process != null && !Process.HasExited) Native.SuspendProcess(Process); }
        public void Resume() { if (Process != null && !Process.HasExited) Native.ResumeProcess(Process); }

        public void Kill()
        {
            try { if (Process != null && !Process.HasExited) Process.Kill(); }
            catch (Exception) { }
        }
    }

    // --------------------------------------------------- modern folder picker
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr hwndParent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, uint fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogRCW { }

    public static class FolderPicker
    {
        private const uint FOS_PICKFOLDERS = 0x20;
        private const uint FOS_FORCEFILESYSTEM = 0x40;
        private const uint FOS_NOCHANGEDIR = 0x8;
        private const uint FOS_PATHMUSTEXIST = 0x800;
        private const uint SIGDN_FILESYSPATH = 0x80058000;
        private static Guid _client = new Guid("e1b5e2a4-7703-4f2c-9d4a-2f6f0e6a9b51");

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern IShellItem SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid);

        // Returns the chosen folder path, or null on cancel.
        public static string Pick(string title, string okLabel, IntPtr owner)
        {
            IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogRCW();
            try
            {
                dlg.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST);
                dlg.SetClientGuid(ref _client); // Windows remembers last location per client guid
                if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
                if (!string.IsNullOrEmpty(okLabel)) dlg.SetOkButtonLabel(okLabel);
                int hr = dlg.Show(owner);
                if (hr != 0) return null; // cancelled
                IShellItem item;
                dlg.GetResult(out item);
                IntPtr psz;
                item.GetDisplayName(SIGDN_FILESYSPATH, out psz);
                string path = Marshal.PtrToStringUni(psz);
                Marshal.FreeCoTaskMem(psz);
                return path;
            }
            finally { Marshal.ReleaseComObject(dlg); }
        }
    }
}
