//
//  Log.cs
//  Screen3R for Windows
//
//  A small text log (%LOCALAPPDATA%\Screen3R\Screen3R.log, rotated at 1 MB): which encoder and
//  capture path were chosen, and why a connection ended. Helpful when something doesn't work.
//

using System.Diagnostics;

namespace Screen3R;

static class Log
{
    static readonly object Gate = new();
    public static string Folder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Screen3R");
    public static string FilePath { get; } = Path.Combine(Folder, "Screen3R.log");

    public static void Write(string message)
    {
        string line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{Environment.CurrentManagedThreadId}] {message}";
        Debug.WriteLine(line);
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 1_000_000)
                    File.Move(FilePath, Path.ChangeExtension(FilePath, ".old.log"), overwrite: true);
                File.AppendAllText(FilePath, line + Environment.NewLine);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
