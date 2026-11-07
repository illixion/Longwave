// The PCVR profile's fixed values (NATIVE_V3_PROTOCOL.md section 4.7), shared by
// the Windows host and the visionOS receiver so neither hard-codes them.

public enum PCVRProfile {
    /// The eye stream's ID. 0 is the desktop's, so a session can carry both.
    public static let streamID: UInt32 = 1
    /// v3's one UDP port: PCVR is a profile of an ordinary v3 session.
    public static let port: UInt16 = 4857
    /// What a PCVR client offers in its hello (each implies `sideData`).
    public static let clientCapabilities = CapabilitySet([.nack, .sideData, .pcvr])
    /// What a PCVR client offers when it has a gaze source with capture times:
    /// the head-pose uplink then carries the wearer's gaze.
    public static let gazeClientCapabilities = CapabilitySet([.nack, .sideData, .pcvr, .gaze])
    /// What the PCVR host answers with. It accepts gaze and hands it to the
    /// frame source's host state, where the compositor reads it.
    public static let hostCapabilities = gazeClientCapabilities
}
