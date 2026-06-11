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
        if (!string.IsNullOrEmpty(path))        args.Append(" -Path \"").Append(path.TrimEnd('\\')).Append('"');
        if (!string.IsNullOrEmpty(pathFile))    args.Append(" -PathFile \"").Append(pathFile).Append('"');
        if (!string.IsNullOrEmpty(destination)) args.Append(" -Destination \"").Append(destination.TrimEnd('\\')).Append('"');

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                    "WindowsPowerShell\\v1.0\\powershell.exe");
        if (!File.Exists(psi.FileName)) psi.FileName = "powershell.exe";
        psi.Arguments = args.ToString();
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        try {
            Process.Start(psi);
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
