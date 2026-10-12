//
//  H264Encoder.cs
//  Screen3R for Windows
//
//  H.264 with a Media Foundation encoder: the GPU's (Intel Quick Sync, NVIDIA NVENC, AMD VCE)
//  when there is one, otherwise Microsoft's software encoder. Settings as on the Mac: High
//  profile, no B-frames, low-latency rate control, keyframes only on request.
//
//  Hardware encoders are "asynchronous" transforms: they ask for input and announce output
//  with events, which a dedicated thread waits for. Input is the NV12 texture itself (GPU
//  memory) when the encoder accepts our Direct3D device, a copy in system memory otherwise.
//

using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace Screen3R.Capture;

sealed class H264Encoder : IDisposable
{
    static readonly Guid Nv12 = new("3231564E-0000-0010-8000-00AA00389B71");     // MFVideoFormat_NV12
    static readonly Guid H264 = new("34363248-0000-0010-8000-00AA00389B71");     // MFVideoFormat_H264
    const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
    const int MF_E_NOTACCEPTING = unchecked((int)0xC00D36B5);
    const int METransformNeedInput = 601, METransformHaveOutput = 602;

    public string Name { get; }
    public bool IsHardware { get; }
    public bool UsesGpuInput { get; private set; }

    /// Encoded access units (Annex B), in order. Called on the encoder's thread.
    public Action<byte[], int>? OnOutput;
    /// The encoder failed; the stream must restart. Called once, on any thread.
    public Action<string>? OnError;

    /// A hardware encoder failed while streaming: use the software one from now on.
    static volatile bool s_hardwareFailed;

    readonly IMFTransform _transform;
    CodecApi? _codecApi;
    IMFMediaEventGenerator? _events;                    // async (hardware) transforms only
    IMFDXGIDeviceManager? _deviceManager;
    readonly ID3D11Device _device;
    readonly ID3D11DeviceContext _context;
    readonly int _width, _height;
    readonly object _lock = new();
    readonly SemaphoreSlim _inputCredits = new(0, 64);  // async: METransformNeedInput received
    ID3D11Texture2D? _staging;                          // system-memory path
    Thread? _eventThread;
    volatile bool _stopped;
    long _time;                                         // 100 ns units, last sample time
    int _pending;                                       // inputs given, outputs not yet out (Interlocked)
    long _lastProgress;                                 // Environment.TickCount64 of the last input/output
    bool _restoreQp;                                    // a refinement frame is in the encoder
    int _outputBufferSize;
    bool _providesSamples;
    Quality _quality;
    bool _maxQpSupported = true;

    H264Encoder(IMFTransform transform, string name, bool hardware, ID3D11Device device, ID3D11DeviceContext context,
                int width, int height, Quality quality)
    {
        _transform = transform;
        Name = name;
        IsHardware = hardware;
        _device = device;
        _context = context;
        _width = width;
        _height = height;
        _quality = quality;
        try
        {
            Configure(transform, name, device, width, height, quality);
        }
        catch
        {
            _codecApi?.Dispose();
            _events?.Dispose();
            _deviceManager?.Dispose();
            _staging?.Dispose();
            throw;
        }
        if (_events != null)
        {
            _eventThread = new Thread(EventLoop) { IsBackground = true, Name = "Screen3R encoder events", Priority = ThreadPriority.AboveNormal };
            _eventThread.Start();
        }
    }

    void Configure(IMFTransform transform, string name, ID3D11Device device, int width, int height, Quality quality)
    {
        IMFAttributes? attributes = null;
        try { attributes = transform.Attributes; } catch (SharpGenException) { }
        if (attributes != null && attributes.GetUInt32(TransformAttributeKeys.TransformAsync, out uint isAsync).Success && isAsync != 0)
        {
            attributes.Set(TransformAttributeKeys.TransformAsyncUnlock, 1u);
            _events = transform.QueryInterface<IMFMediaEventGenerator>();
        }

        // Our Direct3D device, so the encoder can read the NV12 textures directly. Must come
        // before the media types. Encoders that can't (the software one) say so here.
        bool d3dAware = attributes != null && attributes.GetUInt32(TransformAttributeKeys.D3D11Aware, out uint aware).Success && aware != 0;
        attributes?.Dispose();
        if (d3dAware)
        {
            IMFDXGIDeviceManager manager = MediaFactory.MFCreateDXGIDeviceManager();
            manager.ResetDevice(device).CheckError();
            try
            {
                transform.ProcessMessage(TMessageType.MessageSetD3DManager, (nuint)manager.NativePointer);
                _deviceManager = manager;
                UsesGpuInput = true;
            }
            catch (SharpGenException e)
            {
                Log.Write($"{name}: no Direct3D input ({e.Message}); using system memory.");
                manager.Dispose();
            }
        }

        _codecApi = CodecApi.From(transform.NativePointer);
        // Before the media types: some encoders only accept these while unconfigured.
        if (_codecApi != null)
        {
            _codecApi.Set(CodecApiKeys.LowLatencyMode, true);
            if (!_codecApi.Set(CodecApiKeys.RateControlMode, CodecApiKeys.RateControlLowDelayVbr))
                _codecApi.Set(CodecApiKeys.RateControlMode, CodecApiKeys.RateControlCbr);
            _codecApi.Set(CodecApiKeys.BPictureCount, 0u);
            // Keyframes only on request (start, viewer): a very long GOP, as on the Mac.
            if (!_codecApi.Set(CodecApiKeys.GopSize, 36000u)) _codecApi.Set(CodecApiKeys.GopSize, 0u);
            _codecApi.Set(CodecApiKeys.QualityVsSpeed, 50u);
        }

        using (IMFMediaType output = MediaFactory.MFCreateMediaType())
        {
            output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            output.Set(MediaTypeAttributeKeys.Subtype, H264);
            output.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)quality.Bitrate());
            output.Set(MediaTypeAttributeKeys.FrameSize, Pack(width, height));
            output.Set(MediaTypeAttributeKeys.FrameRate, Pack(60, 1));
            output.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
            output.Set(MediaTypeAttributeKeys.InterlaceMode, 2u);    // progressive
            output.Set(MediaTypeAttributeKeys.Mpeg2Profile, 100u);   // High (no B-frames, see above)
            transform.SetOutputType(0, output, 0);
        }
        using (IMFMediaType input = MediaFactory.MFCreateMediaType())
        {
            input.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            input.Set(MediaTypeAttributeKeys.Subtype, Nv12);
            input.Set(MediaTypeAttributeKeys.FrameSize, Pack(width, height));
            input.Set(MediaTypeAttributeKeys.FrameRate, Pack(60, 1));
            input.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
            input.Set(MediaTypeAttributeKeys.InterlaceMode, 2u);
            input.Set(MediaTypeAttributeKeys.YuvMatrix, 1u);           // BT.709
            input.Set(MediaTypeAttributeKeys.VideoNominalRange, 2u);   // 16–235
            transform.SetInputType(0, input, 0);
        }
        ApplyRate();

        var info = transform.GetOutputStreamInfo(0);
        _providesSamples = (info.Flags & 0x100) != 0 || (info.Flags & 0x200) != 0;   // PROVIDES_SAMPLES / CAN_PROVIDE_SAMPLES
        _outputBufferSize = Math.Max((int)info.Size, width * height * 3 / 2);

        if (!UsesGpuInput)
        {
            _staging = device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)width,
                Height = (uint)height,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.NV12,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Staging,
                CPUAccessFlags = CpuAccessFlags.Read,
            });
        }

        transform.ProcessMessage(TMessageType.MessageCommandFlush, 0);
        transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, 0);
        transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, 0);
    }

    static ulong Pack(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    // MARK: - Creation

    /// The first encoder that accepts our settings: hardware first.
    public static H264Encoder Create(ID3D11Device device, ID3D11DeviceContext context, int width, int height, Quality quality)
    {
        var errors = new List<string>();
        foreach (bool hardware in s_hardwareFailed ? new[] { false } : new[] { true, false })
        {
            uint flags = hardware
                ? (uint)(EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter)
                : (uint)(EnumFlag.EnumFlagSyncmft | EnumFlag.EnumFlagAsyncmft | EnumFlag.EnumFlagLocalmft | EnumFlag.EnumFlagSortandfilter);
            var input = new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = Nv12 };
            var output = new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = H264 };
            IMFActivateCollection activates;
            try { activates = MediaFactory.MFTEnumEx(TransformCategoryGuids.VideoEncoder, flags, input, output); }
            catch (SharpGenException e) { errors.Add(e.Message); continue; }
            using (activates)
            {
                foreach (var activate in activates)
                {
                    string name = "H.264 encoder";
                    try { name = activate.GetAllocatedString(TransformAttributeKeys.MftFriendlyNameAttribute) ?? name; } catch (SharpGenException) { }
                    IMFTransform? transform = null;
                    try
                    {
                        transform = activate.ActivateObject<IMFTransform>();
                        var encoder = new H264Encoder(transform, name, hardware, device, context, width, height, quality);
                        Log.Write($"Encoder: {name} ({(hardware ? "hardware" : "software")}, "
                                  + $"{(encoder.UsesGpuInput ? "GPU" : "system memory")} input, {(encoder._events != null ? "async" : "sync")})");
                        return encoder;
                    }
                    catch (Exception e) when (e is SharpGenException or COMException or InvalidOperationException)
                    {
                        errors.Add($"{name}: {e.Message}");
                        Log.Write($"Encoder {name} refused: {e.Message}");
                        try { activate.ShutdownObject(); } catch (SharpGenException) { }
                        transform?.Dispose();
                    }
                    finally
                    {
                        activate.Dispose();
                    }
                }
            }
        }
        throw new InvalidOperationException("No H.264 encoder could be started. " + string.Join("; ", errors));
    }

    // MARK: - Settings

    public void SetQuality(Quality quality)
    {
        lock (_lock)
        {
            _quality = quality;
            ApplyRate();
        }
    }

    void ApplyRate()
    {
        if (_codecApi == null) return;
        _codecApi.Set(CodecApiKeys.MeanBitRate, (uint)_quality.Bitrate());
        if (_maxQpSupported) _maxQpSupported = _codecApi.Set(CodecApiKeys.MaxQP, (uint)(_quality.MaxQP() ?? 51));
    }

    // MARK: - Encoding (the streamer's thread)

    /// The encoder can take a frame now (async encoders ask for input), and at most one frame is
    /// still inside it, so frames don't pile up behind the viewer's flow control.
    /// (An encoder may also drop a frame and never return it: after half a second we stop waiting.)
    public bool ReadyForInput =>
        !_stopped && (_events == null || _inputCredits.CurrentCount > 0) &&
        (Volatile.Read(ref _pending) < 2 || Environment.TickCount64 - Interlocked.Read(ref _lastProgress) > 500);

    /// Whether a refinement pass (quantizer capped very low) is possible with this encoder.
    public bool CanRefine => _codecApi != null && _maxQpSupported;

    /// Encodes one NV12 texture. False if the encoder is busy (the caller tries again later).
    /// `refine`: near-lossless quality for this frame (a still screen becomes sharp).
    public bool Encode(ID3D11Texture2D nv12, bool keyframe, bool refine)
    {
        if (_stopped) return false;
        if (_events != null && !_inputCredits.Wait(0)) return false;   // async: wait for METransformNeedInput

        IMFSample sample = MediaFactory.MFCreateSample();
        try
        {
            IMFMediaBuffer buffer;
            if (UsesGpuInput)
            {
                buffer = MediaFactory.MFCreateDXGISurfaceBuffer(typeof(ID3D11Texture2D).GUID, nv12, 0, false);
                using var b2 = buffer.QueryInterfaceOrNull<IMF2DBuffer>();
                buffer.CurrentLength = b2 != null ? b2.ContiguousLength : _width * _height * 3 / 2;
            }
            else
            {
                buffer = CopyToSystemMemory(nv12);
            }
            sample.AddBuffer(buffer);
            buffer.Dispose();
            // Real time stamps (frames come only when the screen changes): rate control then
            // spends the bit rate on the frames that actually exist.
            long now = (long)((UInt128)(ulong)System.Diagnostics.Stopwatch.GetTimestamp() * 10_000_000
                              / (ulong)System.Diagnostics.Stopwatch.Frequency);
            long t = Math.Max(now, _time + 1);
            sample.SampleTime = t;
            sample.SampleDuration = Math.Max(1, Math.Min(t - _time, 10_000_000 / 10));
            _time = t;

            var outputs = new List<byte[]>();
            lock (_lock)
            {
                bool capped = false;
                if (_codecApi != null)
                {
                    if (keyframe) _codecApi.Set(CodecApiKeys.ForceKeyFrame, 1u);
                    if (refine && _maxQpSupported) capped = _codecApi.Set(CodecApiKeys.MaxQP, 14u);
                }
                try
                {
                    _transform.ProcessInput(0, sample, 0);
                }
                catch (SharpGenException e) when (e.ResultCode.Code == MF_E_NOTACCEPTING)
                {
                    if (_events != null) _inputCredits.Release();   // not consumed
                    if (capped) ApplyRate();
                    return false;
                }
                Interlocked.Increment(ref _pending);
                Interlocked.Exchange(ref _lastProgress, Environment.TickCount64);
                // The cap is lifted once this frame has come out of the encoder (see ProcessOneOutput),
                // as the Mac host waits for the frame before restoring it.
                _restoreQp = capped;
                if (_events == null) DrainSync(outputs);
            }
            foreach (var o in outputs) OnOutput?.Invoke(o, o.Length);   // outside the lock: sending may block
            return true;
        }
        catch (SharpGenException e)
        {
            Fail($"Encoding failed: {e.Message}");
            return false;
        }
        finally
        {
            sample.Dispose();
        }
    }

    /// System-memory path: GPU NV12 texture -> staging -> MF buffer (Y plane, then UV plane).
    unsafe IMFMediaBuffer CopyToSystemMemory(ID3D11Texture2D nv12)
    {
        _context.CopyResource(_staging!, nv12);
        var map = _context.Map(_staging!, 0, MapMode.Read);
        try
        {
            int size = _width * _height * 3 / 2;
            IMFMediaBuffer buffer = MediaFactory.MFCreateMemoryBuffer(size);
            buffer.Lock(out nint dst, out _, out _);
            byte* d = (byte*)dst, s = (byte*)map.DataPointer;
            int pitch = (int)map.RowPitch;
            for (int y = 0; y < _height; y++)
                Buffer.MemoryCopy(s + (long)y * pitch, d + (long)y * _width, _width, _width);
            byte* uvSrc = s + (long)pitch * _height, uvDst = d + (long)_width * _height;
            for (int y = 0; y < _height / 2; y++)
                Buffer.MemoryCopy(uvSrc + (long)y * pitch, uvDst + (long)y * _width, _width, _width);
            buffer.Unlock();
            buffer.CurrentLength = size;
            return buffer;
        }
        finally
        {
            _context.Unmap(_staging!, 0);
        }
    }

    /// Synchronous transforms: collect everything the input produced.
    void DrainSync(List<byte[]> outputs)
    {
        while (!_stopped && ProcessOneOutput(outputs)) { }
    }

    /// Asynchronous transforms: the encoder tells us when it wants input and has output.
    void EventLoop()
    {
        try
        {
            while (!_stopped)
            {
                using IMFMediaEvent e = _events!.GetEvent(0);   // blocks
                int type = (int)e.EventType;
                if (type == METransformNeedInput)
                {
                    try { _inputCredits.Release(); } catch (SemaphoreFullException) { }
                }
                else if (type == METransformHaveOutput)
                {
                    var outputs = new List<byte[]>(1);
                    lock (_lock) ProcessOneOutput(outputs);
                    foreach (var o in outputs) OnOutput?.Invoke(o, o.Length);   // outside the lock
                }
                else if (e.Status.Failure && !_stopped)
                {
                    Fail($"Encoder error 0x{e.Status.Code:X8}");
                    return;
                }
            }
        }
        catch (Exception) when (_stopped) { }   // shut down
        catch (Exception e)
        {
            Fail($"Encoder stopped: {e.Message}");
        }
    }

    /// One ProcessOutput call (with _lock held). True if something came out (call again),
    /// false if the encoder needs more input. Encoded data is added to `outputs`.
    bool ProcessOneOutput(List<byte[]> outputs)
    {
        IMFSample? provided = null;
        if (!_providesSamples)
        {
            provided = MediaFactory.MFCreateSample();
            using var b = MediaFactory.MFCreateMemoryBuffer(_outputBufferSize);
            provided.AddBuffer(b);
        }
        var buffer = new OutputDataBuffer { StreamID = 0, Sample = provided };
        Result r = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref buffer, out _);
        // When we provided the sample, buffer.Sample is a second wrapper of the same object
        // (no extra reference): only `provided` may be released.
        IMFSample? sample = buffer.Sample;
        bool ownSample = sample != null && (provided == null || sample.NativePointer != provided.NativePointer);
        try
        {
            buffer.Events?.Dispose();
            if (r.Code == MF_E_TRANSFORM_NEED_MORE_INPUT) return false;
            if (r.Code == MF_E_TRANSFORM_STREAM_CHANGE)
            {
                // The encoder wants its output type confirmed again (some do so before the first frame).
                using IMFMediaType t = _transform.GetOutputAvailableType(0, 0);
                _transform.SetOutputType(0, t, 0);
                var info = _transform.GetOutputStreamInfo(0);
                _providesSamples = (info.Flags & 0x100) != 0 || (info.Flags & 0x200) != 0;
                _outputBufferSize = Math.Max((int)info.Size, _width * _height * 3 / 2);
                return true;
            }
            r.CheckError();
            if (sample == null) return false;
            using IMFMediaBuffer contiguous = sample.ConvertToContiguousBuffer();
            contiguous.Lock(out nint data, out _, out int length);
            try
            {
                if (length > 0)
                {
                    byte[] bytes = new byte[length];
                    Marshal.Copy(data, bytes, 0, length);
                    outputs.Add(bytes);
                }
            }
            finally
            {
                contiguous.Unlock();
            }
            if (Interlocked.Decrement(ref _pending) < 0) Interlocked.Exchange(ref _pending, 0);
            Interlocked.Exchange(ref _lastProgress, Environment.TickCount64);
            if (_restoreQp)
            {
                _restoreQp = false;
                ApplyRate();
            }
            return true;
        }
        finally
        {
            if (ownSample) sample!.Dispose();
            provided?.Dispose();
        }
    }

    void Fail(string message)
    {
        if (_stopped) return;
        _stopped = true;
        if (IsHardware) s_hardwareFailed = true;   // next connection: software encoder
        Log.Write(message);
        OnError?.Invoke(message);
    }

    public void Dispose()
    {
        _stopped = true;
        lock (_lock)
        {
            try
            {
                _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, 0);
                _transform.ProcessMessage(TMessageType.MessageNotifyEndStreaming, 0);
            }
            catch (SharpGenException) { }
            if (_events != null)
            {
                try
                {
                    using var shutdown = _transform.QueryInterfaceOrNull<IMFShutdown>();
                    shutdown?.Shutdown();   // wakes up GetEvent in the event thread
                }
                catch (SharpGenException) { }
            }
        }
        if (_eventThread != null && !_eventThread.Join(2000))
        {
            // Still inside the encoder: releasing what it uses could crash. Leak it instead.
            Log.Write("Encoder did not stop in time; leaving it to the system.");
            return;
        }
        _codecApi?.Dispose();
        _events?.Dispose();
        _transform.Dispose();
        _deviceManager?.Dispose();
        _staging?.Dispose();
        _inputCredits.Dispose();
    }
}
