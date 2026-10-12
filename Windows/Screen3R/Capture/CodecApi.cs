//
//  CodecApi.cs
//  Screen3R for Windows
//
//  ICodecAPI (strmif.h): the encoder settings of Media Foundation transforms (low latency,
//  rate control, bit rate, keyframes, quantizer limits). Called directly through the COM
//  vtable: Vortice does not wrap this interface. GUIDs from codecapi.h.
//

using System.Runtime.InteropServices;

namespace Screen3R.Capture;

static class CodecApiKeys
{
    public static readonly Guid LowLatencyMode = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");          // VT_BOOL
    public static readonly Guid RateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");         // VT_UI4
    public static readonly Guid MeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");             // VT_UI4
    public static readonly Guid MaxBitRate = new("9651eae4-39b9-4ebf-85ef-d7f444ec7465");              // VT_UI4
    public static readonly Guid BufferSize = new("0db96574-b6a4-4c8b-8106-3773de0310cd");              // VT_UI4
    public static readonly Guid QualityVsSpeed = new("98332df8-03cd-476b-89fa-3f9e442dec9f");          // VT_UI4
    public static readonly Guid GopSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");                 // VT_UI4
    public static readonly Guid BPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");           // VT_UI4
    public static readonly Guid ForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");           // VT_UI4
    public static readonly Guid MaxQP = new("3daf6f66-a6a7-45e0-a8e5-f2743f46a3a2");                   // VT_UI4
    public static readonly Guid MinQP = new("0ee22c6a-a37c-4568-b5f1-9d4c2b3ab886");                   // VT_UI4

    public const uint RateControlCbr = 0, RateControlLowDelayVbr = 4;
}

sealed unsafe class CodecApi : IDisposable
{
    static readonly Guid IID_ICodecAPI = new("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");

    /// VARIANT: vt + 3 reserved words, then a 16-byte union (24 bytes on 64-bit Windows).
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct Variant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public uint ulVal;
        [FieldOffset(8)] public short boolVal;
    }
    const ushort VT_BOOL = 11, VT_UI4 = 19;

    nint _codecApi;

    CodecApi(nint p) => _codecApi = p;

    /// QueryInterface for ICodecAPI on an MFT; null if the transform has none.
    public static CodecApi? From(nint transform)
    {
        Guid iid = IID_ICodecAPI;
        return Marshal.QueryInterface(transform, in iid, out nint p) >= 0 && p != 0 ? new CodecApi(p) : null;
    }

    int SetValue(Guid api, ref Variant value)
    {
        // slot 9: QueryInterface, AddRef, Release, IsSupported, IsModifiable, GetParameterRange,
        //         GetParameterValues, GetDefaultValue, GetValue, SetValue
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, Variant*, int>)(*(void***)_codecApi)[9];
        fixed (Variant* v = &value)
            return fn(_codecApi, &api, v);
    }

    public bool Set(Guid api, uint value)
    {
        var v = new Variant { vt = VT_UI4, ulVal = value };
        return SetValue(api, ref v) >= 0;
    }

    public bool Set(Guid api, bool value)
    {
        var v = new Variant { vt = VT_BOOL, boolVal = (short)(value ? -1 : 0) };
        return SetValue(api, ref v) >= 0;
    }

    public void Dispose()
    {
        if (_codecApi != 0) Marshal.Release(_codecApi);
        _codecApi = 0;
    }
}
