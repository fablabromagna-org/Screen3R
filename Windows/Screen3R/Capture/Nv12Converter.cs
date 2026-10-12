//
//  Nv12Converter.cs
//  Screen3R for Windows
//
//  Turns the BGRA desktop image into what the H.264 encoder takes (NV12, BT.709, video range)
//  at the viewer's resolution, keeping the aspect ratio (black bars if needed). Done by the
//  GPU's video processor, so the image never goes through the CPU.
//

using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Screen3R.Capture;

sealed class Nv12Converter : IDisposable
{
    public const int RingSize = 6;

    readonly ID3D11VideoDevice _videoDevice;
    readonly ID3D11VideoContext _videoContext;
    readonly ID3D11VideoProcessorEnumerator _enumerator;
    readonly ID3D11VideoProcessor _processor;
    readonly ID3D11VideoProcessorInputView _input;
    readonly ID3D11Texture2D[] _ring = new ID3D11Texture2D[RingSize];
    readonly ID3D11VideoProcessorOutputView[] _outputs = new ID3D11VideoProcessorOutputView[RingSize];
    int _next;

    public int Width { get; }
    public int Height { get; }
    /// Where the desktop lands in the output (stream pixels).
    public RawRect Content { get; }

    public Nv12Converter(ID3D11Device device, ID3D11DeviceContext context, ID3D11Texture2D desktop,
                         int inWidth, int inHeight, int outWidth, int outHeight)
    {
        Width = outWidth;
        Height = outHeight;
        _videoDevice = device.QueryInterface<ID3D11VideoDevice>();
        _videoContext = context.QueryInterface<ID3D11VideoContext>();

        var desc = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputFrameRate = new Rational(60, 1),
            InputWidth = (uint)inWidth,
            InputHeight = (uint)inHeight,
            OutputFrameRate = new Rational(60, 1),
            OutputWidth = (uint)outWidth,
            OutputHeight = (uint)outHeight,
            Usage = VideoUsage.OptimalQuality,
        };
        _videoDevice.CreateVideoProcessorEnumerator(ref desc, out _enumerator).CheckError();
        _videoDevice.CreateVideoProcessor(_enumerator, 0, out _processor).CheckError();

        // Aspect fit, centred: the same mapping as StreamMapping.
        double scale = Math.Min(outWidth / (double)inWidth, outHeight / (double)inHeight);
        int w = Math.Min(outWidth, (int)Math.Round(inWidth * scale)), h = Math.Min(outHeight, (int)Math.Round(inHeight * scale));
        int x = (outWidth - w) / 2, y = (outHeight - h) / 2;
        Content = new RawRect(x, y, x + w, y + h);

        _videoContext.VideoProcessorSetStreamFrameFormat(_processor, 0, VideoFrameFormat.Progressive);
        _videoContext.VideoProcessorSetStreamAutoProcessingMode(_processor, 0, false);
        _videoContext.VideoProcessorSetStreamSourceRect(_processor, 0, true, new RawRect(0, 0, inWidth, inHeight));
        _videoContext.VideoProcessorSetStreamDestRect(_processor, 0, true, Content);
        _videoContext.VideoProcessorSetOutputTargetRect(_processor, true, new RawRect(0, 0, outWidth, outHeight));
        _videoContext.VideoProcessorSetOutputBackgroundColor(_processor, false, new VideoColor { Rgba = new VideoColorRgba { R = 0, G = 0, B = 0, A = 1 } });
        // Input: full-range RGB. Output: BT.709, studio range (what the Mac encoder sends too).
        _videoContext.VideoProcessorSetStreamColorSpace(_processor, 0, new VideoProcessorColorSpace { RGB_Range = 0, YCbCr_Matrix = 1, Nominal_Range = 2 });
        _videoContext.VideoProcessorSetOutputColorSpace(_processor, new VideoProcessorColorSpace { RGB_Range = 0, YCbCr_Matrix = 1, Nominal_Range = 1 });

        var inputDesc = new VideoProcessorInputViewDescription
        {
            FourCC = 0,
            ViewDimension = VideoProcessorInputViewDimension.Texture2D,
            Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 },
        };
        _videoDevice.CreateVideoProcessorInputView(desktop, _enumerator, inputDesc, out _input).CheckError();

        for (int i = 0; i < RingSize; i++)
        {
            _ring[i] = device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)outWidth,
                Height = (uint)outHeight,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.NV12,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.RenderTarget,
            });
            var outDesc = new VideoProcessorOutputViewDescription
            {
                ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
            };
            _videoDevice.CreateVideoProcessorOutputView(_ring[i], _enumerator, outDesc, out _outputs[i]).CheckError();
        }
    }

    /// Converts the current desktop image into the next NV12 texture of the ring and returns it.
    /// (A ring, because the encoder may still be reading the previous ones.)
    public ID3D11Texture2D Convert()
    {
        int i = _next;
        _next = (_next + 1) % RingSize;
        var stream = new VideoProcessorStream { Enable = true, InputSurface = _input };
        _videoContext.VideoProcessorBlt(_processor, _outputs[i], 0, 1, [stream]).CheckError();
        return _ring[i];
    }

    public void Dispose()
    {
        foreach (var o in _outputs) o?.Dispose();
        foreach (var t in _ring) t?.Dispose();
        _input.Dispose();
        _processor.Dispose();
        _enumerator.Dispose();
        _videoContext.Dispose();
        _videoDevice.Dispose();
    }
}
