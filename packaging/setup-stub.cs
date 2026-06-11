// setup-stub.cs - single-file installer stub. make-release.ps1 compiles this with
// the in-box csc (/target:winexe) and embeds RobocopyTo.zip as a resource.
// Double-click flow: friendly dialog boxes (install? -> top-level menu? -> done),
// no console; the PowerShell installer runs hidden with output captured to a log.
// Passing any of -TopLevelMenu / -SkipTopLevelMenu / -Quiet skips the dialogs and
// forwards the arguments verbatim (scripted use). C# 5 only - in-box compiler.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

static class Setup
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = Path.Combine(Path.GetTempPath(), "robocopyto-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        string log = Path.Combine(dir, "install.log");
        try
        {
            Directory.CreateDirectory(dir);
            string zip = Path.Combine(dir, "bundle.zip");
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("RobocopyTo.zip"))
            {
                if (s == null)
                {
                    MessageBox.Show("The embedded bundle is missing.", "RobocopyTo setup",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 2;
                }
                using (FileStream f = File.Create(zip)) { s.CopyTo(f); }
            }
            ZipFile.ExtractToDirectory(zip, dir);

            // explicit switches mean scripted use: no dialogs, verbatim pass-through
            bool scripted = false;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "-toplevelmenu" || a == "-skiptoplevelmenu" || a == "-quiet") scripted = true;
            }

            string extra = args.Length > 0 ? " " + string.Join(" ", args) : "";
            if (!scripted)
            {
                DialogResult ok = MessageBox.Show(
                    "Install RobocopyTo for this user?\n\nAdds Copy to / Mirror to / Move to / Robopaste / Undo to the right-click menu. No admin rights needed.",
                    "RobocopyTo setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (ok != DialogResult.Yes) return 0;
                DialogResult top = MessageBox.Show(
                    "Also add Robocopy to the Windows 11 top-level right-click menu?\n\nThis trusts the RobocopyTo package certificate - Windows will ask for one admin approval.",
                    "RobocopyTo setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                extra += (top == DialogResult.Yes ? " -TopLevelMenu" : " -SkipTopLevelMenu") + " -Quiet";
            }

            string ps = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell\\v1.0\\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo(ps,
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "install.ps1") + "\"" + extra);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            Process p = Process.Start(psi);
            string output = p.StandardOutput.ReadToEnd();
            output += p.StandardError.ReadToEnd();
            p.WaitForExit();
            File.WriteAllText(log, output);

            if (p.ExitCode == 0)
            {
                if (!scripted)
                {
                    MessageBox.Show("RobocopyTo is installed.\n\nRight-click any file or folder -> Robocopy.",
                        "RobocopyTo setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                try { Directory.Delete(dir, true); } catch { }
                return 0;
            }
            MessageBox.Show("Setup did not finish (code " + p.ExitCode + ").\n\nDetails: " + log,
                "RobocopyTo setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Setup failed: " + ex.Message, "RobocopyTo setup",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
