//
//  DesktopDuplicator.cs
//  Screen3R for Windows
//
//  Captures one display with the DXGI Desktop Duplication API: a new image arrives only when
//  something on that screen changes, it stays on the GPU, and the mouse pointer is not in it
//  (the viewer draws the pointer itself, see CursorTracker).
//

using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Screen3R.Capture;

public sealed record DisplayInfo(string DeviceName, string Title, int Left, int Top, int Width, int Height, bool IsPrimary);

static class Displays
{
    /// The displays attached to the desktop, main display first.
    public static List<DisplayInfo> All()
    {
        var list = new List<DisplayInfo>();
        using IDXGIFactory1 factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        for (uint a = 0; factory.EnumAdapters1(a, out IDXGIAdapter1? adapter).Success; a++)
        {
            using (adapter)
            {
                for (uint o = 0; adapter!.EnumOutputs(o, out IDXGIOutput? output).Success; o++)
                {
                    using (output)
                    {
                        OutputDescription d = output!.Description;
                        if (!d.AttachedToDesktop) continue;
                        var r = d.DesktopCoordinates;
                        bool primary = r.Left == 0 && r.Top == 0;
                        string number = new string(d.DeviceName.Where(char.IsDigit).ToArray());
                        string title = $"Display {(number.Length > 0 ? number : (list.Count + 1).ToString())} — "
                                     + $"{r.Right - r.Left}×{r.Bottom - r.Top}{(primary ? " (main)" : "")}";
                        if (list.All(x => x.DeviceName != d.DeviceName))
                            list.Add(new DisplayInfo(d.DeviceName, title, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, primary));
                    }
                }
            }
        }
        list.Sort((x, y) => x.IsPrimary == y.IsPrimary ? string.CompareOrdinal(x.DeviceName, y.DeviceName) : x.IsPrimary ? -1 : 1);
        return list;
    }
}

sealed class DesktopDuplicator : IDisposable
{
    static readonly Result WaitTimeout = new(unchecked((int)0x887A0027));    // DXGI_ERROR_WAIT_TIMEOUT
    static readonly Result AccessLost = new(unchecked((int)0x887A0026));     // DXGI_ERROR_ACCESS_LOST

    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }
    public DisplayInfo Display { get; }
    /// Our copy of the last desktop image (BGRA), usable as video processor input.
    public ID3D11Texture2D Desktop { get; }
    public int Width => Display.Width;
    public int Height => Display.Height;
    public string AdapterName { get; }

    readonly IDXGIOutput1 _output;
    IDXGIOutputDuplication? _duplication;

    public DesktopDuplicator(DisplayInfo display)
    {
        Display = display;
        using IDXGIFactory1 factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        IDXGIAdapter1? found = null;
        IDXGIOutput1? foundOutput = null;
        for (uint a = 0; found == null && factory.EnumAdapters1(a, out IDXGIAdapter1? adapter).Success; a++)
        {
            for (uint o = 0; adapter!.EnumOutputs(o, out IDXGIOutput? output).Success; o++)
            {
                if (output!.Description.DeviceName == display.DeviceName)
                {
                    found = adapter;
                    foundOutput = output.QueryInterface<IDXGIOutput1>();
                    output.Dispose();
                    break;
                }
                output.Dispose();
            }
            if (found == null) adapter.Dispose();
        }
        if (found == null || foundOutput == null) throw new InvalidOperationException($"Display {display.DeviceName} not found.");
        _output = foundOutput;
        AdapterName = found.Description1.Description;

        // The device must belong to the adapter that drives this display. Video support: the
        // NV12 conversion and the hardware encoder use the same device.
        D3D11.D3D11CreateDevice(found, DriverType.Unknown,
            DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
            [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1, FeatureLevel.Level_10_0],
            out ID3D11Device? device, out ID3D11DeviceContext? context).CheckError();
        found.Dispose();
        Device = device!;
        Context = context!;
        using (var mt = Device.QueryInterface<ID3D11Multithread>())
            mt.SetMultithreadProtected(true);   // Media Foundation uses the device from its own threads

        Desktop = Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)display.Width,
            Height = (uint)display.Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
        });
        try
        {
            Duplicate();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    void Duplicate()
    {
        _duplication?.Dispose();
        _duplication = _output.DuplicateOutput(Device);
        var rotation = _duplication.Description.Rotation;
        if (rotation != ModeRotation.Identity && rotation != ModeRotation.Unspecified)
        {
            _duplication.Dispose();
            _duplication = null;
            throw new NotSupportedException($"{Display.Title} is rotated: rotated displays can't be sent yet. Choose another one in Display to Send.");
        }
    }

    /// Waits up to `timeoutMs` for a change. True when Desktop holds a new image.
    /// Throws if capture is no longer possible (display gone, mode change…): the caller reconnects.
    public bool Acquire(int timeoutMs)
    {
        if (_duplication == null)
        {
            try { Duplicate(); }
            catch (SharpGenException) { Thread.Sleep(Math.Max(timeoutMs, 50)); return false; }   // e.g. secure desktop
        }
        Result r = _duplication!.AcquireNextFrame((uint)timeoutMs, out OutduplFrameInfo info, out IDXGIResource? resource);
        if (r == WaitTimeout) return false;
        if (r == AccessLost)
        {
            // Secure desktop (UAC prompt, Ctrl+Alt+Del), mode change, fullscreen switch: duplicate again.
            _duplication.Dispose();
            _duplication = null;
            return false;
        }
        r.CheckError();
        try
        {
            if (info.LastPresentTime == 0) return false;   // only the mouse moved
            using var texture = resource!.QueryInterface<ID3D11Texture2D>();
            var d = texture.Description;
            if (d.Width != (uint)Display.Width || d.Height != (uint)Display.Height)
                throw new InvalidOperationException("The display changed resolution.");
            Context.CopyResource(Desktop, texture);
            return true;
        }
        finally
        {
            resource?.Dispose();
            _duplication.ReleaseFrame();
        }
    }

    public void Dispose()
    {
        _duplication?.Dispose();
        _output.Dispose();
        Desktop.Dispose();
        Context.ClearState();
        Context.Dispose();
        Device.Dispose();
    }
}
