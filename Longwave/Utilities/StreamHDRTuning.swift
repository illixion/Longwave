import DebugTrace
import RAVEMedia

/// How bright an HDR stream is drawn on the curved screen, where the app
/// converts the frames itself (`RAVEFrameTexture`). Tunable from the debug
/// panels, since both are matters of how it looks on the headset.
enum StreamHDRTuning {
    static var settings: RAVEFrameConverter.Settings {
        RAVEFrameConverter.Settings(
            // What the stream's SDR white is in nits. Windows puts an HDR
            // desktop's white where its "SDR content brightness" slider
            // says (about 200 nits around the middle), which is also the
            // broadcast reference white.
            referenceWhiteNits: DebugTunables.number(
                "hdr.referenceWhiteNits", 203, range: 80...480, step: 1,
                label: "HDR: nits shown as the window's white"),
            // How far above the window's white highlights may go.
            headroom: DebugTunables.number(
                "hdr.headroom", RAVEDisplayHeadroom.measuredVisionWindow, range: 1...6, step: 0.1,
                label: "HDR: highlight ceiling (× white)")
        )
    }
}
