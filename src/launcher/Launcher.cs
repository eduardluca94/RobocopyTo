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
