//
//  PairingStore.cs
//  Screen3R for Windows
//
//  Pairing keys, one per viewer, in %APPDATA%\Screen3R\pairings.json, each encrypted with
//  DPAPI for the current Windows user (the counterpart of the login keychain on the Mac).
//

using System.Security.Cryptography;
using System.Text.Json;

namespace Screen3R;

sealed class PairingStore : IPairingKeys
{
    sealed class Entry
    {
        public string Name { get; set; } = "";
        public string Key { get; set; } = "";   // base64 of the DPAPI-protected key
    }

    static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Screen3R", "pairings.json");
    static readonly byte[] Entropy = "Screen3R pairing key v1"u8.ToArray();
    readonly object _lock = new();

    Dictionary<string, Entry> Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(FilePath)) ?? new();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            Log.Write($"Pairings unreadable: {e.Message}");
        }
        return new();
    }

    void Save(Dictionary<string, Entry> all)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        string tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(all, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, FilePath, overwrite: true);
    }

    public byte[]? Get(string viewerId)
    {
        lock (_lock)
        {
            if (!Load().TryGetValue(viewerId, out var entry)) return null;
            try
            {
                byte[] key = ProtectedData.Unprotect(Convert.FromBase64String(entry.Key), Entropy, DataProtectionScope.CurrentUser);
                return key.Length == RdCrypto.KeyLength ? key : null;
            }
            catch (Exception e) when (e is CryptographicException or FormatException)
            {
                Log.Write($"Pairing key for {viewerId} unusable: {e.Message}");
                return null;
            }
        }
    }

    public void Store(string viewerId, byte[] key, string name)
    {
        lock (_lock)
        {
            var all = Load();
            all[viewerId] = new Entry
            {
                Name = name,
                Key = Convert.ToBase64String(ProtectedData.Protect(key, Entropy, DataProtectionScope.CurrentUser)),
            };
            try { Save(all); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Log.Write($"Could not store the pairing key: {e.Message}");
            }
        }
    }

    public void RemoveAll()
    {
        lock (_lock)
        {
            try { File.Delete(FilePath); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log.Write(e.Message); }
        }
    }
}
