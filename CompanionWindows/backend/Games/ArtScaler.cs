using System.Drawing;
using System.Drawing.Imaging;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>Re-encodes cover art smaller for the headset (ported from the PCVR host).</summary>
internal static class ArtScaler
{
    /// 80 is where jpeg stops paying for quality nobody can see at this size.
    private const long JpegQuality = 80;

    /// <summary>
    /// Jpeg with the long edge capped, or null if that could not be done (corrupt file,
    /// unsupported codec, no GDI+). Never throws: the caller then ships the original.
    /// </summary>
    public static byte[]? TryScale(byte[] source, int maxEdge, ILogger? log)
    {
        if (!OperatingSystem.IsWindows()) return null;
        try
        {
            using var input = new MemoryStream(source, writable: false);
            using var image = Image.FromStream(input, useEmbeddedColorManagement: false, validateImageData: false);
            if (image.Width <= 0 || image.Height <= 0) return null;

            var scale = Math.Min(1.0, (double)maxEdge / Math.Max(image.Width, image.Height));
            var w = Math.Max(1, (int)Math.Round(image.Width * scale));
            var h = Math.Max(1, (int)Math.Round(image.Height * scale));

            using var scaled = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(scaled))
            {
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                g.DrawImage(image, 0, 0, w, h);
            }

            var jpeg = ImageCodecInfo.GetImageEncoders().FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid);
            if (jpeg is null) return null;
            using var parameters = new EncoderParameters(1);
            parameters.Param[0] = new EncoderParameter(Encoder.Quality, JpegQuality);
            using var output = new MemoryStream();
            scaled.Save(output, jpeg, parameters);
            var result = output.ToArray();
            // Only worth it if it actually helped; a tiny source can encode larger.
            return result.Length < source.Length ? result : null;
        }
        catch (Exception ex)
        {
            log?.LogDebug(ex, "Art scaling unavailable; sending the original.");
            return null;
        }
    }
}
