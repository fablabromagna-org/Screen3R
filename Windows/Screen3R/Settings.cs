//
//  Settings.cs
//  Screen3R for Windows
//
//  Preferences in %APPDATA%\Screen3R\settings.json.
//

using System.Text.Json;
using System.Text.Json.Serialization;

namespace Screen3R;

public enum Quality { Wifi, Balanced, High }

static class QualityInfo
{
    public static string Title(this Quality q) => q switch
    {
        Quality.Wifi => "Wi-Fi (12 Mbit/s)",
        Quality.High => "Ethernet (50 Mbit/s)",
        _ => "Balanced (25 Mbit/s)",
    };

    public static int Bitrate(this Quality q) => q switch
    {
        Quality.Wifi => 12_000_000,
        Quality.High => 50_000_000,
        _ => 25_000_000,
    };

    /// Upper bound on the quantizer: keeps text readable at the cost of bitrate spikes.
    public static int? MaxQP(this Quality q) => q switch
    {
        Quality.Wifi => null,
        Quality.High => 30,
        _ => 34,
    };
}

sealed class Settings
{
    public string HostId { get; set; } = "";
    public Quality Quality { get; set; } = Quality.Balanced;
    public bool Encrypt { get; set; } = true;
    public bool AllowInput { get; set; }
    /// ⌘ acts as Ctrl and ⌃ as the Windows key (Mac-style shortcuts).
    public bool CommandAsControl { get; set; }
    /// Device name of the display to send (e.g. \\.\DISPLAY1); empty = the main display.
    public string Display { get; set; } = "";
    public string LastManualAddress { get; set; } = "";
    public int CueCountdown { get; set; }

    static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Screen3R", "settings.json");

    static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static Settings Load()
    {
        Settings s;
        try
        {
            s = File.Exists(FilePath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Options) ?? new() : new();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            Log.Write($"Settings unreadable, using defaults: {e.Message}");
            s = new Settings();
        }
        if (!RdCrypto.IsValidId(s.HostId))
        {
            s.HostId = Guid.NewGuid().ToString().ToUpperInvariant();   // this PC's stable identity
            s.Save();
        }
        return s;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Options));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Could not save settings: {e.Message}");
        }
    }
}
