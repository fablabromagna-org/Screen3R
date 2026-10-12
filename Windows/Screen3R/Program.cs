//
//  Program.cs
//  Screen3R for Windows — sends this PC's screen to Screen3R Viewer on an old Mac.
//

using Vortice.MediaFoundation;

namespace Screen3R;

static class Program
{
    [STAThread]
    static int Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);   // physical pixels: capture and input agree
        using var single = new Mutex(true, @"Local\io.github.screen3r.host", out bool first);
        if (!first)
        {
            MessageBox.Show("Screen3R is already running: look for its icon in the notification area (next to the clock).",
                            "Screen3R", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Log.Write($"Unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"Fatal: {e.ExceptionObject}");

        MediaFactory.MFStartup().CheckError();
        try
        {
            Application.Run(new TrayApp());
        }
        finally
        {
            MediaFactory.MFShutdown();
        }
        return 0;
    }
}
