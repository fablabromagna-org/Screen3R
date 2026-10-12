//
//  AnnexB.cs
//  Screen3R for Windows
//
//  Media Foundation's H.264 encoders produce Annex B (NAL units separated by 00 00 01 start
//  codes, parameter sets in-band). The viewer expects what VideoToolbox produces on the Mac:
//  AVCC (each NAL unit prefixed by its 4-byte length) and the SPS/PPS sent separately in a
//  FORMAT message before every keyframe.
//

namespace Screen3R;

public sealed class AccessUnit
{
    /// NAL units of the picture, each prefixed with its 4-byte big-endian length.
    public required byte[] Avcc { get; init; }
    public required bool IsKeyframe { get; init; }
    /// SPS and PPS found in this access unit (empty if none).
    public required List<byte[]> ParameterSets { get; init; }
}

public static class AnnexB
{
    public const int NalLengthSize = 4;

    public static IEnumerable<(int Start, int Length)> Units(byte[] data, int length)
    {
        int i = FindStart(data, 0, length, out int sc);
        while (i >= 0)
        {
            int start = i + sc;
            int next = FindStart(data, start, length, out int nextSc);
            int end = next >= 0 ? next : length;
            // Trailing zero bytes belong to the next start code (00 00 00 01) or are padding.
            while (end > start && data[end - 1] == 0) end--;
            if (end > start) yield return (start, end - start);
            i = next;
            sc = nextSc;
        }
    }

    /// Index of the next 00 00 01 (or 00 00 00 01) at or after `from`, and its length.
    static int FindStart(byte[] d, int from, int length, out int scLength)
    {
        for (int i = from; i + 2 < length; i++)
        {
            if (d[i] == 0 && d[i + 1] == 0)
            {
                if (d[i + 2] == 1) { scLength = 3; return i; }
                if (d[i + 2] == 0 && i + 3 < length && d[i + 3] == 1) { scLength = 4; return i; }
            }
        }
        scLength = 0;
        return -1;
    }

    public static AccessUnit Convert(byte[] data, int length)
    {
        var parameterSets = new List<byte[]>();
        bool keyframe = false;
        using var avcc = new MemoryStream(length + 16);
        Span<byte> prefix = stackalloc byte[4];
        foreach (var (start, len) in Units(data, length))
        {
            int type = data[start] & 0x1F;
            switch (type)
            {
                case 7: // SPS
                case 8: // PPS
                    if (parameterSets.Count < 8) parameterSets.Add(data.AsSpan(start, len).ToArray());
                    continue;
                case 9:  // access unit delimiter
                case 12: // filler
                    continue;
                case 5:
                    keyframe = true;
                    break;
            }
            prefix[0] = (byte)(len >> 24);
            prefix[1] = (byte)(len >> 16);
            prefix[2] = (byte)(len >> 8);
            prefix[3] = (byte)len;
            avcc.Write(prefix);
            avcc.Write(data, start, len);
        }
        // SPS before PPS, as CMVideoFormatDescriptionCreateFromH264ParameterSets expects.
        parameterSets.Sort((a, b) => (a[0] & 0x1F).CompareTo(b[0] & 0x1F));
        return new AccessUnit { Avcc = avcc.ToArray(), IsKeyframe = keyframe, ParameterSets = parameterSets };
    }
}
