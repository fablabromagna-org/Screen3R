//
//  Streamer.cs
//  Screen3R for Windows
//
//  Capture -> NV12 -> H.264, on one thread, with the Mac host's flow control:
//  before encoding a new image we ask `CanSend`; if too many frames are still unacknowledged
//  by the viewer the image is skipped (always safe: the encoder references the last frame it
//  actually encoded) and encoded as soon as the network catches up. When the screen has been
//  still for 150 ms the last image is encoded once more with the quantizer capped very low, so
//  small text becomes sharp.
//

using Screen3R.Capture;

namespace Screen3R;

sealed class Streamer : IDisposable
{
    public Func<bool>? CanSend;
    /// Parameter sets (SPS, PPS) and the NAL length size, before every keyframe.
    public Action<IReadOnlyList<byte[]>, int>? OnFormat;
    /// AVCC data (4-byte lengths), keyframe flag.
    public Action<byte[], bool>? OnFrame;
    /// Capture or encoding stopped for good. Called once, on a background thread.
    public Action<string>? OnError;

    public StreamMapping Mapping { get; }
    public string EncoderName => _encoder.Name;

    const double RefreshDelay = 0.15;

    readonly DesktopDuplicator _duplicator;
    readonly Nv12Converter _converter;
    readonly H264Encoder _encoder;
    readonly Thread _thread;
    volatile bool _stopped;
    volatile bool _forceKeyframe = true;
    long _lastRequestedKeyframe;
    List<byte[]> _parameterSets = new();
    int _errorReported;

    public Streamer(DisplayInfo display, int width, int height, Quality quality)
    {
        Mapping = StreamMapping.Create(display.Left, display.Top, display.Width, display.Height, width, height);
        try
        {
            _duplicator = new DesktopDuplicator(display);
            _converter = new Nv12Converter(_duplicator.Device, _duplicator.Context, _duplicator.Desktop,
                                           display.Width, display.Height, width, height);
            _encoder = H264Encoder.Create(_duplicator.Device, _duplicator.Context, width, height, quality);
        }
        catch
        {
            _converter?.Dispose();
            _duplicator?.Dispose();
            throw;
        }
        Log.Write($"Streaming {display.DeviceName} ({display.Width}×{display.Height}, GPU: {_duplicator.AdapterName}) as {width}×{height}");
        _encoder.OnOutput = HandleEncoded;
        _encoder.OnError = Fail;
        _thread = new Thread(Run) { IsBackground = true, Name = "Screen3R capture", Priority = ThreadPriority.AboveNormal };
    }

    public void Start() => _thread.Start();

    /// Rate-limited: a keyframe is big, and a misbehaving viewer must not get one on every tick.
    public void RequestKeyframe()
    {
        long now = Environment.TickCount64;
        if (now - Interlocked.Read(ref _lastRequestedKeyframe) < 500) return;
        Interlocked.Exchange(ref _lastRequestedKeyframe, now);
        _forceKeyframe = true;
    }

    public void SetQuality(Quality quality) => _encoder.SetQuality(quality);

    void Run()
    {
        bool hasImage = false, pending = false;
        int refreshPasses = 0;
        long lastEncode = 0;
        try
        {
            while (!_stopped)
            {
                if (_duplicator.Acquire(8))
                {
                    hasImage = true;
                    pending = true;
                    refreshPasses = 0;
                }
                if (!hasImage || !(CanSend?.Invoke() ?? true)) continue;
                long now = Environment.TickCount64;
                if (pending || _forceKeyframe)
                {
                    if (Encode(refine: false)) { pending = false; lastEncode = now; }
                }
                else if (refreshPasses < 1 && _encoder.CanRefine && (now - lastEncode) / 1000.0 > RefreshDelay)
                {
                    if (Encode(refine: true)) { refreshPasses++; lastEncode = now; }
                }
            }
        }
        catch (Exception e)
        {
            if (!_stopped) Fail($"Screen capture stopped: {e.Message}");
        }
    }

    bool Encode(bool refine)
    {
        // Convert only when the encoder takes the frame: the NV12 textures form a ring, and one
        // still being read by the encoder must not be overwritten.
        if (!_encoder.ReadyForInput) return false;
        bool keyframe = _forceKeyframe;
        var texture = _converter.Convert();
        if (!_encoder.Encode(texture, keyframe, refine)) return false;
        if (keyframe) _forceKeyframe = false;
        return true;
    }

    /// Encoder thread.
    void HandleEncoded(byte[] annexB, int length)
    {
        if (_stopped) return;
        AccessUnit au = AnnexB.Convert(annexB, length);
        if (au.ParameterSets.Count > 0) _parameterSets = au.ParameterSets;
        if (au.Avcc.Length == 0) return;
        if (au.IsKeyframe)
        {
            if (_parameterSets.Count == 0)
            {
                Log.Write("Keyframe without SPS/PPS: asking for another one");
                _forceKeyframe = true;
                return;
            }
            OnFormat?.Invoke(_parameterSets, AnnexB.NalLengthSize);
        }
        OnFrame?.Invoke(au.Avcc, au.IsKeyframe);
    }

    void Fail(string message)
    {
        if (Interlocked.Exchange(ref _errorReported, 1) != 0 || _stopped) return;
        Log.Write(message);
        OnError?.Invoke(message);
    }

    public void Dispose()
    {
        _stopped = true;
        if (_thread.IsAlive && Thread.CurrentThread != _thread && !_thread.Join(3000))
        {
            Log.Write("Capture thread did not stop in time; leaving its resources to the system.");
            return;
        }
        _encoder.Dispose();
        _converter.Dispose();
        _duplicator.Dispose();
    }
}
