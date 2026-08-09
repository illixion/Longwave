using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace Longwave.WindowsCompanion.Backend.NativeStream;

/// <summary>
/// Fixed-size GPU encode pipeline for one stream: BGRA capture textures →
/// Video Processor MFT (BGRA→NV12, D3D-aware) → hardware HEVC encoder MFT
/// (async model) → Annex-B, re-emitted as 4-byte length-prefixed NAL units
/// with the VPS/SPS/PPS published separately (the wire's
/// <c>hevcParameterSets</c> format kind). The owner recreates the pipeline
/// when the source size changes.
/// </summary>
public sealed class VideoEncodePipeline : IDisposable
{
    /// <summary>Annex-B VPS/SPS/PPS concatenation — fired on first key frame
    /// and whenever the sets change.</summary>
    public event Action<byte[]>? ParameterSetsChanged;
    /// <summary>(length-prefixed sample, isKeyFrame, sequence, ptsNanos).</summary>
    public event Action<byte[], bool, ulong, ulong>? EncodedFrame;
    public event Action<string>? Failed;
    /// <summary>Low-volume diagnostics (first event, provides-samples flags).</summary>
    public event Action<string>? Diagnostic;

    public int Width { get; }
    public int Height { get; }

    private const int FramesPerSecond = 60;

    /// <summary>MF_LOW_LATENCY — not surfaced by Vortice's key catalog.</summary>
    private static readonly Guid MFLowLatency = new("9C27891A-ED7A-40E1-88E8-B22727A024EE");

    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IMFDXGIDeviceManager _deviceManager;
    private readonly IMFTransform? _converter;
    private readonly IMFTransform _encoder;
    private readonly IMFMediaEventGenerator _encoderEvents;
    private readonly bool _converterProvidesSamples;
    /// <summary>True when the encoder accepted ARGB32 input directly (NVIDIA
    /// does its own color conversion) — the video processor is bypassed.</summary>
    private readonly bool _directBgraInput;
    private readonly ID3D11Texture2D _bgraFrame;

    private readonly BlockingCollection<IMFSample> _encoderInput = new(boundedCapacity: 4);
    private readonly CancellationTokenSource _cancel = new();
    private readonly Thread _eventThread;

    private readonly ID3D11Texture2D?[] _nv12Ring = new ID3D11Texture2D?[8];
    private int _ringIndex;
    private long _lastSubmitTicks;
    private byte[]? _lastParameterSets;
    private ulong _sequence;
    private bool _failed;

    public VideoEncodePipeline(ID3D11Device device, int width, int height, int bitrate)
    {
        _device = device;
        _context = device.ImmediateContext;
        // 4:2:0 needs even dimensions.
        Width = Math.Max(2, width & ~1);
        Height = Math.Max(2, height & ~1);

        MediaFactory.MFStartup(true);

        _deviceManager = MediaFactory.MFCreateDXGIDeviceManager();
        _deviceManager.ResetDevice(device);

        _encoder = CreateHardwareHevcEncoder();
        _directBgraInput = ConfigureEncoder(_encoder, bitrate);
        _encoderEvents = _encoder.QueryInterface<IMFMediaEventGenerator>();

        if (!_directBgraInput)
        {
            _converter = CreateVideoProcessor();
            ConfigureConverter(_converter);
            _converterProvidesSamples = HasProvidesSamples(_converter);
        }

        _bgraFrame = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)Width,
            Height = (uint)Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
        });

        _converter?.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        _converter?.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
        _encoder.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        _encoder.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);

        _eventThread = new Thread(EncoderEventLoop)
        {
            IsBackground = true,
            Name = "native-stream-encoder",
        };
        _eventThread.Start();

        // Watchdog: an async MFT that never raises events means the encoder
        // was mis-initialized — surface that instead of a downstream stall.
        var watchdog = new Thread(() =>
        {
            Thread.Sleep(3000);
            if (!_loggedFirstEvent && !_cancel.IsCancellationRequested)
            {
                Diagnostic?.Invoke(
                    $"no encoder events after 3 s (directBgra={_directBgraInput}, converterProvidesSamples={_converterProvidesSamples})");
            }
        }) { IsBackground = true };
        watchdog.Start();
    }

    /// <summary>
    /// Feeds one captured BGRA frame. Called on the capture callback thread;
    /// the frame is copied immediately (the source texture belongs to the
    /// frame pool). Frames are dropped when the encoder is behind.
    /// </summary>
    public void Submit(ID3D11Texture2D poolTexture, int contentWidth, int contentHeight, long qpcTicks)
    {
        if (_failed || _cancel.IsCancellationRequested) return;
        // Windows.Graphics.Capture fires per composition (up to the monitor's
        // full refresh rate); cap encoding at the declared frame rate.
        if (qpcTicks - _lastSubmitTicks < 10_000_000 / (FramesPerSecond + 5)) return;
        _lastSubmitTicks = qpcTicks;
        if (contentWidth < Width || contentHeight < Height)
        {
            // Transition frame while the owner recreates the pipeline.
            return;
        }

        try
        {
            if (_directBgraInput)
            {
                // Copy into a ring texture the encoder can hold as long as
                // it needs, and queue it straight in.
                var ringTexture = NextRingTexture();
                lock (_bgraFrame)
                {
                    _context.CopySubresourceRegion(
                        ringTexture, 0, 0, 0, 0,
                        poolTexture, 0,
                        new Vortice.Mathematics.Box(0, 0, 0, Width, Height, 1));
                }
                var direct = SampleFromTexture(ringTexture, qpcTicks);
                if (!_encoderInput.TryAdd(direct))
                {
                    direct.Dispose();
                }
                return;
            }

            lock (_bgraFrame)
            {
                _context.CopySubresourceRegion(
                    _bgraFrame, 0, 0, 0, 0,
                    poolTexture, 0,
                    new Vortice.Mathematics.Box(0, 0, 0, Width, Height, 1));
            }

            using var inputSample = SampleFromTexture(_bgraFrame, qpcTicks);
            try
            {
                _converter!.ProcessInput(0, inputSample, 0);
            }
            catch (SharpGen.Runtime.SharpGenException ex)
                when (ex.ResultCode.Code == unchecked((int)0xC00D36B5)) // MF_E_NOTACCEPTING
            {
                // The converter is holding un-drained output (its D3D sample
                // pool can exhaust when the encoder back-pressures) — drain
                // and retry once, dropping the frame if it still refuses.
                var drained = DrainConverter(qpcTicks);
                Diagnostic?.Invoke($"converter NOTACCEPTING; drained={(drained is not null)}");
                drained?.Dispose();
                _converter!.ProcessInput(0, inputSample, 0);
            }
            var converted = DrainConverter(qpcTicks);
            if (converted is null) return;

            // Bounded queue: drop the frame when the encoder is saturated
            // rather than ballooning latency.
            if (!_encoderInput.TryAdd(converted))
            {
                converted.Dispose();
            }
        }
        catch (Exception ex)
        {
            Fail($"Frame conversion failed: {ex.Message}");
        }
    }

    private const int MFETransformNeedMoreInput = unchecked((int)0xC00D6D72);
    private const int MFETransformStreamChange = unchecked((int)0xC00D6D61);

    private IMFSample? DrainConverter(long qpcTicks)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var buffer = new OutputDataBuffer { StreamID = 0 };
            if (!_converterProvidesSamples)
            {
                buffer.Sample = SampleFromTexture(NextRingTexture(), qpcTicks);
            }

            var result = _converter!.ProcessOutput(ProcessOutputFlags.None, 1, ref buffer, out _);
            buffer.Events?.Dispose();
            if (result.Success)
            {
                var output = buffer.Sample!;
                if (_converterProvidesSamples)
                {
                    // The converter's own D3D sample allocator is tiny (it
                    // can be a single sample) and it refuses further input
                    // until its samples come back. Copy into our ring and
                    // release the converter's sample immediately, so the
                    // encoder's queue never starves the converter.
                    var ringTexture = NextRingTexture();
                    using (var vpTexture = TextureFromSample(output))
                    {
                        lock (_bgraFrame)
                        {
                            _context.CopyResource(ringTexture, vpTexture);
                        }
                    }
                    output.Dispose();
                    output = SampleFromTexture(ringTexture, qpcTicks);
                }
                output.SampleTime = qpcTicks;
                output.SampleDuration = 10_000_000 / FramesPerSecond;
                return output;
            }

            buffer.Sample?.Dispose();
            if (result.Code == MFETransformNeedMoreInput)
            {
                return null;
            }
            if (result.Code == MFETransformStreamChange)
            {
                // D3D-aware MFTs renegotiate their output on the first frame
                // (and on device changes): re-set the output type and retry.
                Diagnostic?.Invoke("converter stream change; renegotiating output type");
                ConfigureConverterOutput(_converter!);
                continue;
            }
            throw new InvalidOperationException(
                $"Video processor ProcessOutput failed (0x{result.Code:X8}).");
        }
        return null;
    }

    /// <summary>NV12 targets handed to the encoder, reused round-robin. The
    /// ring (8) comfortably outlasts the encoder's pipeline depth (bounded
    /// queue of 4 plus a frame or two in flight) at 60 fps.</summary>
    private ID3D11Texture2D NextRingTexture()
    {
        if (_nv12Ring[_ringIndex] is null)
        {
            _nv12Ring[_ringIndex] = _device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)Width,
                Height = (uint)Height,
                MipLevels = 1,
                ArraySize = 1,
                Format = _directBgraInput ? Format.B8G8R8A8_UNorm : Format.NV12,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
            });
        }
        var texture = _nv12Ring[_ringIndex]!;
        _ringIndex = (_ringIndex + 1) % _nv12Ring.Length;
        return texture;
    }

    private static ID3D11Texture2D TextureFromSample(IMFSample sample)
    {
        using var mediaBuffer = sample.GetBufferByIndex(0);
        using var dxgiBuffer = mediaBuffer.QueryInterface<IMFDXGIBuffer>();
        return new ID3D11Texture2D(dxgiBuffer.GetResource(typeof(ID3D11Texture2D).GUID));
    }

    private bool _loggedFirstEvent;

    private void EncoderEventLoop()
    {
        try
        {
            while (!_cancel.IsCancellationRequested)
            {
                using var mediaEvent = _encoderEvents.GetEvent(0);
                if (!_loggedFirstEvent)
                {
                    _loggedFirstEvent = true;
                    Diagnostic?.Invoke($"first encoder event: {mediaEvent.EventType}");
                }
                switch (mediaEvent.EventType)
                {
                    case MediaEventTypes.TransformNeedInput:
                    {
                        IMFSample sample;
                        try
                        {
                            sample = _encoderInput.Take(_cancel.Token);
                        }
                        catch (OperationCanceledException)
                        {
                            return;
                        }
                        catch (InvalidOperationException)
                        {
                            return; // input completed
                        }
                        using (sample)
                        {
                            _encoder.ProcessInput(0, sample, 0);
                        }
                        break;
                    }
                    case MediaEventTypes.TransformHaveOutput:
                        DrainEncoder();
                        break;
                    case MediaEventTypes.Error:
                        Fail("The hardware encoder reported an error.");
                        return;
                }
            }
        }
        catch (Exception ex)
        {
            if (!_cancel.IsCancellationRequested)
            {
                Fail($"Encoder event loop failed: {ex.Message}");
            }
        }
    }

    private void DrainEncoder()
    {
        var info = _encoder.GetOutputStreamInfo(0);
        var providesSamples =
            ((OutputStreamInfoFlags)info.Flags & OutputStreamInfoFlags.OutputStreamProvidesSamples) != 0;

        var buffer = new OutputDataBuffer { StreamID = 0 };
        if (!providesSamples)
        {
            var sample = MediaFactory.MFCreateSample();
            using var memory = MediaFactory.MFCreateMemoryBuffer(Math.Max(info.Size, 1024 * 1024));
            sample.AddBuffer(memory);
            buffer.Sample = sample;
        }

        var result = _encoder.ProcessOutput(ProcessOutputFlags.None, 1, ref buffer, out _);
        buffer.Events?.Dispose();
        if (result.Failure)
        {
            buffer.Sample?.Dispose();
            return;
        }

        var output = buffer.Sample!;
        try
        {
            EmitSample(output);
        }
        finally
        {
            output.Dispose();
        }
    }

    private void EmitSample(IMFSample sample)
    {
        using var contiguous = sample.ConvertToContiguousBuffer();
        contiguous.Lock(out var pointer, out _, out var currentLength);
        byte[] annexB;
        try
        {
            annexB = new byte[currentLength];
            Marshal.Copy(pointer, annexB, 0, currentLength);
        }
        finally
        {
            contiguous.Unlock();
        }

        bool isKeyFrame;
        try
        {
            isKeyFrame = sample.GetUInt32(SampleAttributeKeys.CleanPoint) != 0;
        }
        catch
        {
            isKeyFrame = false; // attribute absent — treat as delta frame
        }

        var (parameterSets, lengthPrefixed) = RepackAnnexB(annexB);
        if (parameterSets.Length > 0 &&
            (_lastParameterSets is null || !parameterSets.AsSpan().SequenceEqual(_lastParameterSets)))
        {
            _lastParameterSets = parameterSets;
            ParameterSetsChanged?.Invoke(parameterSets);
        }
        if (lengthPrefixed.Length == 0) return;

        _sequence++;
        var ptsNanos = (ulong)Math.Max(0, sample.SampleTime) * 100;
        EncodedFrame?.Invoke(lengthPrefixed, isKeyFrame, _sequence, ptsNanos);
    }

    /// <summary>
    /// Splits an Annex-B access unit: parameter-set NALs (VPS 32 / SPS 33 /
    /// PPS 34) are returned separately still in Annex-B form (what the format
    /// frame carries); everything else is re-framed as 4-byte big-endian
    /// length-prefixed NAL units (what CMSampleBuffer expects).
    /// </summary>
    internal static (byte[] ParameterSets, byte[] Sample) RepackAnnexB(ReadOnlySpan<byte> annexB)
    {
        using var parameterSets = new MemoryStream();
        using var sample = new MemoryStream();

        var offset = 0;
        var nalStart = -1;
        while (offset + 2 < annexB.Length)
        {
            var isStart3 = annexB[offset] == 0 && annexB[offset + 1] == 0 && annexB[offset + 2] == 1;
            var isStart4 = offset + 3 < annexB.Length
                && annexB[offset] == 0 && annexB[offset + 1] == 0
                && annexB[offset + 2] == 0 && annexB[offset + 3] == 1;
            if (isStart3 || isStart4)
            {
                if (nalStart >= 0)
                {
                    AppendNal(annexB[nalStart..offset], parameterSets, sample);
                }
                offset += isStart3 ? 3 : 4;
                nalStart = offset;
            }
            else
            {
                offset++;
            }
        }
        if (nalStart >= 0 && nalStart < annexB.Length)
        {
            AppendNal(annexB[nalStart..], parameterSets, sample);
        }
        return (parameterSets.ToArray(), sample.ToArray());
    }

    private static void AppendNal(ReadOnlySpan<byte> nal, MemoryStream parameterSets, MemoryStream sample)
    {
        // Trim trailing zero padding some encoders leave before a start code.
        var end = nal.Length;
        while (end > 0 && nal[end - 1] == 0) end--;
        if (end == 0) return;
        nal = nal[..end];

        var nalType = (nal[0] >> 1) & 0x3F;
        if (nalType is 32 or 33 or 34)
        {
            Span<byte> startCode = stackalloc byte[] { 0, 0, 0, 1 };
            parameterSets.Write(startCode);
            parameterSets.Write(nal);
        }
        else
        {
            Span<byte> length = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)nal.Length);
            sample.Write(length);
            sample.Write(nal);
        }
    }

    // MARK: MFT setup

    private static IMFActivate[] EnumTransforms(Guid category, EnumFlag flags, RegisterTypeInfo? outputType)
    {
        MediaFactory.MFTEnumEx(category, (uint)flags, null, outputType, out var activatesPtr, out var count);
        var activates = new IMFActivate[count];
        for (var i = 0; i < count; i++)
        {
            activates[i] = new IMFActivate(Marshal.ReadIntPtr(activatesPtr, i * IntPtr.Size));
        }
        if (activatesPtr != IntPtr.Zero)
        {
            Marshal.FreeCoTaskMem(activatesPtr);
        }
        return activates;
    }

    private IMFTransform CreateHardwareHevcEncoder()
    {
        var activates = EnumTransforms(
            TransformCategoryGuids.VideoEncoder,
            EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter,
            new RegisterTypeInfo
            {
                GuidMajorType = MediaTypeGuids.Video,
                GuidSubtype = VideoFormatGuids.Hevc,
            });
        if (activates.Length == 0)
        {
            throw new InvalidOperationException(
                "No hardware HEVC encoder is available on this machine.");
        }
        try
        {
            var transform = activates[0].ActivateObject<IMFTransform>();

            // Hardware encoders are async MFTs; using them requires the
            // explicit unlock.
            using var attributes = transform.Attributes;
            attributes.Set(TransformAttributeKeys.TransformAsyncUnlock, 1u);
            attributes.Set(MFLowLatency, 1u);

            transform.ProcessMessage(
                TMessageType.MessageSetD3DManager,
                unchecked((UIntPtr)(ulong)_deviceManager.NativePointer.ToInt64()));
            return transform;
        }
        finally
        {
            foreach (var activate in activates) activate.Dispose();
        }
    }

    /// <summary>Configures output + input types. Returns true when the
    /// encoder took ARGB32 input directly (no converter needed).</summary>
    private bool ConfigureEncoder(IMFTransform encoder, int bitrate)
    {
        using (var outputType = MediaFactory.MFCreateMediaType())
        {
            outputType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            outputType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Hevc);
            outputType.Set(MediaTypeAttributeKeys.FrameSize, PackTwo(Width, Height));
            outputType.Set(MediaTypeAttributeKeys.FrameRate, PackTwo(FramesPerSecond, 1));
            outputType.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitrate);
            outputType.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
            // One key frame per second, like the Mac encoder.
            outputType.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, (uint)FramesPerSecond);
            encoder.SetOutputType(0, outputType, 0);
        }

        foreach (var subtype in new[] { VideoFormatGuids.Argb32, VideoFormatGuids.NV12 })
        {
            using var inputType = MediaFactory.MFCreateMediaType();
            inputType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            inputType.Set(MediaTypeAttributeKeys.Subtype, subtype);
            inputType.Set(MediaTypeAttributeKeys.FrameSize, PackTwo(Width, Height));
            inputType.Set(MediaTypeAttributeKeys.FrameRate, PackTwo(FramesPerSecond, 1));
            inputType.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
            try
            {
                encoder.SetInputType(0, inputType, 0);
                return subtype == VideoFormatGuids.Argb32;
            }
            catch (SharpGen.Runtime.SharpGenException)
            {
                // Not accepted — try the next candidate.
            }
        }
        throw new InvalidOperationException("The hardware encoder accepts neither ARGB32 nor NV12 input.");
    }

    private IMFTransform CreateVideoProcessor()
    {
        var activates = EnumTransforms(TransformCategoryGuids.VideoProcessor, EnumFlag.EnumFlagAll, null);
        if (activates.Length == 0)
        {
            throw new InvalidOperationException("The Media Foundation video processor is unavailable.");
        }
        try
        {
            var transform = activates[0].ActivateObject<IMFTransform>();
            transform.ProcessMessage(
                TMessageType.MessageSetD3DManager,
                unchecked((UIntPtr)(ulong)_deviceManager.NativePointer.ToInt64()));
            return transform;
        }
        finally
        {
            foreach (var activate in activates) activate.Dispose();
        }
    }

    private void ConfigureConverter(IMFTransform converter)
    {
        using (var inputType = MediaFactory.MFCreateMediaType())
        {
            inputType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            inputType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Argb32);
            inputType.Set(MediaTypeAttributeKeys.FrameSize, PackTwo(Width, Height));
            inputType.Set(MediaTypeAttributeKeys.FrameRate, PackTwo(FramesPerSecond, 1));
            inputType.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
            converter.SetInputType(0, inputType, 0);
        }

        ConfigureConverterOutput(converter);
    }

    private void ConfigureConverterOutput(IMFTransform converter)
    {
        using var outputType = MediaFactory.MFCreateMediaType();
        outputType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        outputType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.NV12);
        outputType.Set(MediaTypeAttributeKeys.FrameSize, PackTwo(Width, Height));
        outputType.Set(MediaTypeAttributeKeys.FrameRate, PackTwo(FramesPerSecond, 1));
        outputType.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        converter.SetOutputType(0, outputType, 0);
    }

    private static bool HasProvidesSamples(IMFTransform transform)
    {
        var info = transform.GetOutputStreamInfo(0);
        return ((OutputStreamInfoFlags)info.Flags & OutputStreamInfoFlags.OutputStreamProvidesSamples) != 0;
    }

    private IMFSample SampleFromTexture(ID3D11Texture2D texture, long qpcTicks)
    {
        using var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(
            typeof(ID3D11Texture2D).GUID, texture, 0, false);
        var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = qpcTicks;
        sample.SampleDuration = 10_000_000 / FramesPerSecond;
        return sample;
    }

    private static ulong PackTwo(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    private void Fail(string message)
    {
        if (_failed) return;
        _failed = true;
        Failed?.Invoke(message);
    }

    public void Dispose()
    {
        _cancel.Cancel();
        _encoderInput.CompleteAdding();
        try
        {
            _encoder.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
        }
        catch { }
        // GetEvent(0) can block; the thread is background and dies with the
        // process if the MFT never wakes it.
        _eventThread.Join(TimeSpan.FromSeconds(2));
        while (_encoderInput.TryTake(out var sample)) sample.Dispose();
        _encoderInput.Dispose();
        foreach (var texture in _nv12Ring) texture?.Dispose();
        _bgraFrame.Dispose();
        _converter?.Dispose();
        _encoderEvents.Dispose();
        _encoder.Dispose();
        _deviceManager.Dispose();
        _cancel.Dispose();
        // Balance the MFStartup in the constructor — Media Foundation refcounts
        // these, and an unmatched startup keeps its work queues alive for the
        // life of the process.
        try { MediaFactory.MFShutdown(); } catch { }
    }
}
