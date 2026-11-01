// The PCVR profile's fixed values (NATIVE_V3_PROTOCOL.md section 4.7), shared by
// the Windows host and the visionOS receiver so neither hard-codes them.

public enum PCVRProfile {
    /// The eye stream's ID. 0 is the desktop's, so a session can carry both.
    public static let streamID: UInt32 = 1
    /// v3's one UDP port: PCVR is a profile of an ordinary v3 session.
    public static let port: UInt16 = 4857
    /// What a PCVR client offers in its hello (each implies `sideData`).
    public static let clientCapabilities = CapabilitySet([.nack, .sideData, .pcvr])
}
