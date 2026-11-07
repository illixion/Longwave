// The PCVR profile's fixed values (NATIVE_V3_PROTOCOL.md section 4.7), shared by
// the Windows host and the visionOS receiver so neither hard-codes them.

public enum PCVRProfile {
    /// The eye stream's ID. 0 is the desktop's, so a session can carry both.
    public static let streamID: UInt32 = 1
    /// v3's one UDP port: PCVR is a profile of an ordinary v3 session.
    public static let port: UInt16 = 4857
    /// What a PCVR client offers in its hello (each implies `sideData`). A
    /// receiver that undoes the centre/edge warp also offers `foveatedVideo`.
    public static let clientCapabilities = CapabilitySet([.nack, .sideData, .pcvr, .foveatedVideo])
    /// What a PCVR client offers when it has a gaze source with capture times:
    /// the head-pose uplink then carries the wearer's gaze.
    public static let gazeClientCapabilities = CapabilitySet([.nack, .sideData, .pcvr, .foveatedVideo, .gaze])
    /// What a PCVR client offers: `gaze` with a gaze source that has capture
    /// times, `depthVideo` when it reprojects by depth (it then subscribes to
    /// the eye stream's depth auxiliary, `depthStreamID`).
    public static func clientCapabilities(gaze: Bool, depth: Bool) -> CapabilitySet {
        var set = gaze ? gazeClientCapabilities : clientCapabilities
        if depth { set.insert(.depthVideo) }
        return set
    }
    /// What the PCVR host answers with. It accepts gaze and hands it to the
    /// frame source's host state, where the compositor reads it, warps the eye
    /// images for a viewer that negotiated `foveatedVideo`, and sends depth to
    /// one that negotiated `depthVideo`.
    public static let hostCapabilities = CapabilitySet([.nack, .sideData, .pcvr, .foveatedVideo, .gaze, .depthVideo])

    /// The eye stream's depth auxiliary (section 4.8): both eyes' inverse depth
    /// side by side, each in its render frustum, unwarped, at `depthDivisor`
    /// of the render eye size, as 8-bit luma (`depthEncoding`). Its frames take
    /// the eye frame's number and capture time.
    public static let depthStreamID: UInt32 = 2
    public static let depthDivisor = 16
    public static let depthEncoding = DepthEncoding(kind: .inverseLinear, valueBits: 8)

    /// One depth eye for a render eye: `depthDivisor` smaller, even sizes.
    public static func depthEye(forRender eye: PixelSize) -> PixelSize {
        func scaled(_ v: UInt16) -> UInt16 { UInt16(max(2, (Int(v) / depthDivisor + 1) & ~1)) }
        return PixelSize(width: scaled(eye.width), height: scaled(eye.height))
    }

    /// The host's default centre/edge warp, sized for eyes rendered at the
    /// Vision Pro's native density over its whole display frusta (about
    /// 5200x4200): 30% of each axis at full density around the gaze, the rest
    /// at 1/3.5. That packs each eye into half its rendered width and height (a
    /// quarter of the pixels), so a native-density stream costs the encoder and
    /// decoder what a 2600x2100 one would. The centre reaches about 23 degrees
    /// from the gaze, wide enough for its capture-to-encode age and tracking
    /// error; at its edge the compressed density is still above what the eye
    /// resolves that far out.
    public static let defaultWarp = CentreEdgeWarp(centreSizeX: 0.3, centreSizeY: 0.3, edgeRatioX: 3.5, edgeRatioY: 3.5)
    /// Wire eye sizes are rounded to this, so both eyes and the codec's
    /// blocks line up.
    public static let wireAlignment = 16
}
