//
//  KeyMap.cs
//  Screen3R for Windows
//
//  The old Mac sends macOS virtual key codes (physical keys, kVK_* in HIToolbox/Events.h).
//  Windows gets PC scan codes (set 1), so the Windows keyboard layout decides the characters,
//  exactly as the Mac host lets its own layout decide.
//
//  - ⌥ Option: left = Alt, right = AltGr, so Italian/European characters typed with the right
//    Option key (@ # [ ] { }) come out as they do with AltGr on a PC keyboard.
//  - ⌘ Command and ⌃ Control: like Boot Camp by default (⌘ = Windows key, ⌃ = Ctrl);
//    with "⌘ as Ctrl" they swap, so ⌘C / ⌘V copy and paste as on the Mac.
//  - ISO keyboards: macOS reports the key left of "1" as kVK_ISO_Section and the key right of
//    the left Shift as kVK_ANSI_Grave (swapped compared with ANSI keyboards), so the mapping of
//    those two keys depends on the keyboard's layout type.
//

namespace Screen3R;

public enum MacKeyboardLayout { Ansi, Iso, Jis }

public readonly record struct ScanCode(ushort Code, bool Extended);

public static class KeyMap
{
    public const ushort CapsLock = 0x39;          // kVK_CapsLock: a state, not a key (see InputInjector)
    public const ushort Function = 0x3F;          // kVK_Function: handled by the Mac itself

    static readonly ScanCode?[] Table = Build();

    static ScanCode?[] Build()
    {
        var t = new ScanCode?[128];
        void S(int mac, ushort sc, bool ext = false) => t[mac] = new ScanCode(sc, ext);
        // Letters, digits, punctuation (positions of a US keyboard; the layout gives meaning).
        S(0x00, 0x1E); S(0x01, 0x1F); S(0x02, 0x20); S(0x03, 0x21); S(0x04, 0x23); S(0x05, 0x22);
        S(0x06, 0x2C); S(0x07, 0x2D); S(0x08, 0x2E); S(0x09, 0x2F); S(0x0B, 0x30); S(0x0C, 0x10);
        S(0x0D, 0x11); S(0x0E, 0x12); S(0x0F, 0x13); S(0x10, 0x15); S(0x11, 0x14); S(0x12, 0x02);
        S(0x13, 0x03); S(0x14, 0x04); S(0x15, 0x05); S(0x16, 0x07); S(0x17, 0x06); S(0x18, 0x0D);
        S(0x19, 0x0A); S(0x1A, 0x08); S(0x1B, 0x0C); S(0x1C, 0x09); S(0x1D, 0x0B); S(0x1E, 0x1B);
        S(0x1F, 0x18); S(0x20, 0x16); S(0x21, 0x1A); S(0x22, 0x17); S(0x23, 0x19); S(0x24, 0x1C);
        S(0x25, 0x26); S(0x26, 0x24); S(0x27, 0x28); S(0x28, 0x25); S(0x29, 0x27); S(0x2A, 0x2B);
        S(0x2B, 0x33); S(0x2C, 0x35); S(0x2D, 0x31); S(0x2E, 0x32); S(0x2F, 0x34); S(0x30, 0x0F);
        S(0x31, 0x39); S(0x33, 0x0E); S(0x34, 0x1C, true); S(0x35, 0x01);
        // Modifiers that do not depend on the mode.
        S(0x38, 0x2A);                 // Shift
        S(0x3C, 0x36);                 // right Shift
        S(0x3A, 0x38);                 // Option -> Alt
        S(0x3D, 0x38, true);           // right Option -> AltGr (right Alt)
        // Keypad.
        S(0x41, 0x53); S(0x43, 0x37); S(0x45, 0x4E); S(0x4B, 0x35, true); S(0x4C, 0x1C, true);
        S(0x4E, 0x4A); S(0x51, 0x59); S(0x52, 0x52); S(0x53, 0x4F); S(0x54, 0x50); S(0x55, 0x51);
        S(0x56, 0x4B); S(0x57, 0x4C); S(0x58, 0x4D); S(0x59, 0x47); S(0x5B, 0x48); S(0x5C, 0x49);
        // Function keys.
        S(0x7A, 0x3B); S(0x78, 0x3C); S(0x63, 0x3D); S(0x76, 0x3E); S(0x60, 0x3F); S(0x61, 0x40);
        S(0x62, 0x41); S(0x64, 0x42); S(0x65, 0x43); S(0x6D, 0x44); S(0x67, 0x57); S(0x6F, 0x58);
        S(0x69, 0x64); S(0x6B, 0x65); S(0x71, 0x66); S(0x6A, 0x67); S(0x40, 0x68); S(0x4F, 0x69);
        S(0x50, 0x6A); S(0x5A, 0x6B);
        // Navigation.
        S(0x72, 0x52, true);           // Help (where Insert is) -> Insert
        S(0x73, 0x47, true); S(0x74, 0x49, true); S(0x75, 0x53, true); S(0x77, 0x4F, true);
        S(0x79, 0x51, true); S(0x7B, 0x4B, true); S(0x7C, 0x4D, true); S(0x7D, 0x50, true);
        S(0x7E, 0x48, true);
        S(0x6E, 0x5D, true);           // PC keyboard's Menu key
        // JIS.
        S(0x5D, 0x7D); S(0x5E, 0x73); S(0x5F, 0x7E); S(0x66, 0x7B); S(0x68, 0x70);
        return t;
    }

    /// Windows scan code for a Mac key, or null for keys with no PC equivalent.
    public static ScanCode? Map(ushort macKey, MacKeyboardLayout layout, bool commandAsControl)
    {
        if (macKey >= 128) return null;
        switch (macKey)
        {
            case 0x37:   // ⌘ Command
                return commandAsControl ? new ScanCode(0x1D, false) : new ScanCode(0x5B, true);
            case 0x36:   // right ⌘
                return commandAsControl ? new ScanCode(0x1D, true) : new ScanCode(0x5C, true);
            case 0x3B:   // ⌃ Control
                return commandAsControl ? new ScanCode(0x5B, true) : new ScanCode(0x1D, false);
            case 0x3E:   // right ⌃
                return commandAsControl ? new ScanCode(0x5C, true) : new ScanCode(0x1D, true);
            case 0x0A:   // kVK_ISO_Section
                return layout == MacKeyboardLayout.Iso ? new ScanCode(0x29, false) : new ScanCode(0x56, false);
            case 0x32:   // kVK_ANSI_Grave
                return layout == MacKeyboardLayout.Iso ? new ScanCode(0x56, false) : new ScanCode(0x29, false);
        }
        return Table[macKey];
    }

    public static MacKeyboardLayout ParseLayout(string? value) => value?.ToLowerInvariant() switch
    {
        "iso" => MacKeyboardLayout.Iso,
        "jis" => MacKeyboardLayout.Jis,
        "ansi" => MacKeyboardLayout.Ansi,
        // Viewers older than v0.4 don't say: most keyboards outside the US and Japan are ISO.
        _ => MacKeyboardLayout.Iso,
    };
}
