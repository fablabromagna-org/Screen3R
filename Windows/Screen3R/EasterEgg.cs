//
//  EasterEgg.cs
//  Screen3R for Windows
//
//  Now and then, connecting a PC to an old iMac makes the iMac a little sad.
//  The iMac decides how much (a hidden panel in the viewer, ⌃⌥⌘C): its HELLO says
//  "cry": "always", "sometimes" or "never". Older viewers don't say: "sometimes".
//

namespace Screen3R;

public static class EasterEgg
{
    public const string Text = "Every time you do this, your iMac cries.";

    /// Cue sent to the viewer once the session runs (the viewer plays a short sound).
    public const byte CryCue = 1;

    /// `countdown` (persisted) = "sometimes" connections left before the next time.
    public static bool ShouldFire(string? mode, ref int countdown, Random random) => mode switch
    {
        "always" => true,
        "never" => false,
        _ => Countdown(ref countdown, random),
    };

    /// "Sometimes": true on the 4th, 5th or 6th call, then again 4–6 calls later.
    public static bool Countdown(ref int countdown, Random random)
    {
        if (countdown < 1 || countdown > 6) countdown = random.Next(4, 7);
        countdown--;
        if (countdown > 0) return false;
        countdown = random.Next(4, 7);
        return true;
    }
}
