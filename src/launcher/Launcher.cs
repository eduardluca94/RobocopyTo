// Launcher.cs - tiny windowless shim that starts the RobocopyTo PowerShell flow
// without a console flash. Compiled to RobocopyTo.exe at install time by the
// .NET Framework csc.exe already on every Windows box (no shipped binaries, no
// build tools required to install).
//
// It does exactly one thing: translate "--verb X --path Y" (or --pathfile) into
//   powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA
//             -File <dir>\RobocopyTo.Launch.ps1 -Verb X -Path Y
// and launch it hidden. The real work is all in PowerShell + the engine module.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Launcher {
    // Heals a value mangled upstream by \"-escaping (a drive root sent as "C:\"
    // arrives as C:") and makes a bare drive letter mean the root - a drive-
    // relative C: would resolve to the CWD, which is System32 for shell launches.
    private static string CleanPathArg(string v) {
        if (string.IsNullOrEmpty(v)) return v;
        v = v.TrimEnd('"');
        if (v.Length == 2 && v[1] == ':') v += "\\";
        return v;
    }

    // Quotes a value with trailing backslashes doubled so the closing quote
    // survives the next command-line parse (never strip them - "C:" is not "C:\").
    private static void AppendQuoted(StringBuilder b, string name, string v) {
        b.Append(' ').Append(name).Append(" \"").Append(v);
        int bs = 0;
        while (bs < v.Length && v[v.Length - 1 - bs] == '\\') bs++;
        b.Append('\\', bs).Append('"');
    }

    [STAThread]
    private static int Main(string[] argv) {
        string verb = null, path = null, pathFile = null, destination = null;
        for (int i = 0; i < argv.Length; i++) {
            switch (argv[i]) {
                case "--verb":        if (i + 1 < argv.Length) verb = argv[++i]; break;
                case "--path":        if (i + 1 < argv.Length) path = argv[++i]; break;
                case "--pathfile":    if (i + 1 < argv.Length) pathFile = argv[++i]; break;
                case "--destination": if (i + 1 < argv.Length) destination = argv[++i]; break;
            }
        }
        if (string.IsNullOrEmpty(verb)) verb = "settings";

        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "RobocopyTo.Launch.ps1");

        StringBuilder args = new StringBuilder();
        args.Append("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"");
        args.Append(script).Append("\" -Verb ").Append(verb);
        // start-time breadcrumb: lets the op log show where click->window time went
        args.Append(" -T0 ").Append(DateTime.UtcNow.Ticks);
        if (!string.IsNullOrEmpty(path))        AppendQuoted(args, "-Path", CleanPathArg(path));
        if (!string.IsNullOrEmpty(pathFile))    AppendQuoted(args, "-PathFile", pathFile);
        if (!string.IsNullOrEmpty(destination)) AppendQuoted(args, "-Destination", CleanPathArg(destination));

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                    "WindowsPowerShell\\v1.0\\powershell.exe");
        if (!File.Exists(psi.FileName)) psi.FileName = "powershell.exe";
        psi.Arguments = args.ToString();
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        try {
            Process p = Process.Start(psi);
            // Some machines inspect script hosts at length on launch (observed:
            // ~60s before PowerShell runs a single line). Stay silent for 2.5s;
            // after that, show a small cue that closes when the real window shows.
            int waited = 0;
            while (!p.HasExited && waited < 2500) {
                System.Threading.Thread.Sleep(250);
                waited += 250;
                p.Refresh();
                if (p.MainWindowHandle != IntPtr.Zero) return 0;
            }
            if (!p.HasExited && p.MainWindowHandle == IntPtr.Zero) {
                System.Windows.Forms.Form f = new System.Windows.Forms.Form();
                f.Text = "RobocopyTo";
                f.FormBorderStyle = System.Windows.Forms.FormBorderStyle.FixedToolWindow;
                f.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;
                f.MinimizeBox = false; f.MaximizeBox = false; f.TopMost = true;
                f.ClientSize = new System.Drawing.Size(300, 64);
                System.Windows.Forms.Label l = new System.Windows.Forms.Label();
                l.Dock = System.Windows.Forms.DockStyle.Fill;
                l.TextAlign = System.Drawing.ContentAlignment.MiddleCenter;
                l.Text = "Starting RobocopyTo...\r\nWindows is preparing PowerShell.";
                f.Controls.Add(l);
                System.Windows.Forms.Timer tm = new System.Windows.Forms.Timer();
                tm.Interval = 300;
                tm.Tick += delegate {
                    p.Refresh();
                    if (p.HasExited || p.MainWindowHandle != IntPtr.Zero) { tm.Stop(); f.Close(); }
                };
                tm.Start();
                System.Windows.Forms.Application.Run(f);
            }
            return 0;
        } catch (Exception ex) {
            // last-resort visibility: this only fires if PowerShell itself cannot start
            try {
                System.Windows.Forms.MessageBox.Show("RobocopyTo could not start:\n" + ex.Message,
                    "RobocopyTo", System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error);
            } catch { }
            return 1;
        }
    }
}
