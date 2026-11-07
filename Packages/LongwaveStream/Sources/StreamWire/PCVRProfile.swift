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
    /// What the PCVR host answers with. It accepts gaze and hands it to the
    /// frame source's host state, where the compositor reads it, and warps the
    /// eye images for a viewer that negotiated `foveatedVideo`.
    public static let hostCapabilities = gazeClientCapabilities

    /// The host's default centre/edge warp: 40% of each axis at full density
    /// around the gaze, the rest at 1/2.5. That packs each eye into 64% of its
    /// rendered width and height (41% of the pixels). The centre spans about
    /// ±20 degrees on a Vision Pro eye, wide enough to absorb the gaze's
    /// capture-to-encode age and its tracking error.
    public static let defaultWarp = CentreEdgeWarp(centreSizeX: 0.4, centreSizeY: 0.4, edgeRatioX: 2.5, edgeRatioY: 2.5)
    /// Wire eye sizes are rounded to this, so both eyes and the codec's
    /// blocks line up.
    public static let wireAlignment = 16
}
