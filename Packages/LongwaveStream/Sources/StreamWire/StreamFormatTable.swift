/// The frames that belong together: a primary frame and every auxiliary frame
/// with the same frame number (section 4.2).
public struct FramePairKey: Sendable, Hashable {
    public var primaryStreamID: UInt32
    public var frameNumber: UInt32

    public init(primaryStreamID: UInt32, frameNumber: UInt32) {
        self.primaryStreamID = primaryStreamID
        self.frameNumber = frameNumber
    }
}

/// A receiver's view of the formats it has been sent, enforcing the
/// stream-level rules that no single message can:
///
/// - an auxiliary stream's primary must already exist and must not itself be
///   an auxiliary (no chains), and a primary has at most one auxiliary per role;
/// - a stream keeps its role for its lifetime (primary stays primary, an
///   auxiliary keeps its role and primary);
/// - each new format for a stream applies from a frame number newer than the
///   previous one's, and frames are matched to the format in force at their
///   number, so a shard that overtakes a format change uses the old one.
public struct StreamFormatTable: Sendable {
    /// Formats kept per stream: the current one and the one before it, which
    /// is enough for frames still in flight across one change.
    public static let historyDepth = 2

    private var history: [UInt32: [FormatDescription]] = [:] // oldest first

    public init() {}

    public var streamIDs: Set<UInt32> { Set(history.keys) }

    public func current(_ streamID: UInt32) -> FormatDescription? {
        history[streamID]?.last
    }

    /// The format in force for `frameNumber`: the newest whose first frame is
    /// not after it. Nil if the frame predates every format kept.
    public func format(streamID: UInt32, frameNumber: UInt32) -> FormatDescription? {
        history[streamID]?.last { !SerialNumber.isNewer($0.firstFrameNumber, than: frameNumber) }
    }

    /// Streams that are auxiliaries of `primaryStreamID`, by role.
    public func auxiliaries(of primaryStreamID: UInt32) -> [AuxiliaryRole: UInt32] {
        var result: [AuxiliaryRole: UInt32] = [:]
        for (id, formats) in history {
            if let auxiliary = formats.last?.auxiliary, auxiliary.primaryStreamID == primaryStreamID {
                result[auxiliary.role] = id
            }
        }
        return result
    }

    public mutating func apply(_ format: FormatDescription) throws(WireError) {
        try format.validate()
        let id = format.streamID
        if let previous = current(id) {
            guard previous.auxiliary == format.auxiliary else { throw .inconsistent("streams.roleChanged") }
            guard SerialNumber.isNewer(format.firstFrameNumber, than: previous.firstFrameNumber) else {
                throw .inconsistent("streams.firstFrameNumber")
            }
        } else if let auxiliary = format.auxiliary {
            guard let primary = current(auxiliary.primaryStreamID) else { throw .missing("streams.primary") }
            guard primary.auxiliary == nil else { throw .inconsistent("streams.auxiliaryChain") }
            if let existing = auxiliaries(of: auxiliary.primaryStreamID)[auxiliary.role], existing != id {
                throw .duplicate("streams.auxiliaryRole")
            }
        }
        var formats = history[id] ?? []
        formats.append(format)
        if formats.count > Self.historyDepth { formats.removeFirst(formats.count - Self.historyDepth) }
        history[id] = formats
    }

    /// Forgets a stream (it ended). Ending a primary ends its auxiliaries too;
    /// returns every stream ID removed.
    @discardableResult
    public mutating func remove(_ streamID: UInt32) -> [UInt32] {
        guard history.removeValue(forKey: streamID) != nil else { return [] }
        var removed = [streamID]
        for (_, auxiliaryID) in auxiliaries(of: streamID) {
            history[auxiliaryID] = nil
            removed.append(auxiliaryID)
        }
        return removed
    }

    /// The pairing key for a shard of a known stream: its own stream for a
    /// primary, its primary's for an auxiliary.
    public func pairKey(for header: VideoShardHeader) -> FramePairKey? {
        guard let format = current(header.streamID) else { return nil }
        return FramePairKey(primaryStreamID: format.auxiliary?.primaryStreamID ?? header.streamID,
                            frameNumber: header.frameNumber)
    }

    /// Checks that an auxiliary frame belongs to a primary frame: the streams
    /// are related, and frame number and capture time are equal.
    public func checkPairing(primary: VideoShardHeader, auxiliary: VideoShardHeader) throws(WireError) {
        guard let primaryFormat = current(primary.streamID), primaryFormat.auxiliary == nil else {
            throw .inconsistent("pairing.primary")
        }
        guard let auxiliaryFormat = current(auxiliary.streamID),
              auxiliaryFormat.auxiliary?.primaryStreamID == primary.streamID else {
            throw .inconsistent("pairing.auxiliary")
        }
        guard auxiliary.frameNumber == primary.frameNumber else { throw .inconsistent("pairing.frameNumber") }
        guard auxiliary.captureTime == primary.captureTime else { throw .inconsistent("pairing.captureTime") }
    }
}
